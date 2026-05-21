# HyperPod GPU 掉卡模拟实验

## 实验环境

- **集群名称**: tencent
- **Region**: ap-southeast-3
- **GPU 节点**: i-0008e4b1d060011b3 (ml.g6e.xlarge, NVIDIA L40S)
- **NodeRecovery**: None (已关闭)
- **Health Monitoring Agent**: v1.0.1481.0_1.0.392.0

## 实验目的

验证 HyperPod health-monitoring-agent 对 GPU 故障的检测能力，以及平台的自动响应行为。

## 复现步骤

### 1. 安装 health-monitoring-agent

```bash
# 更新仓库
cd /home/ec2-user/sagemaker-hyperpod-cli && git pull

# 安装 helm chart
helm install health-monitoring-agent \
  /home/ec2-user/sagemaker-hyperpod-cli/helm_chart/HyperPodHelmChart/charts/health-monitoring-agent \
  -n aws-hyperpod --take-ownership --force-conflicts
```

### 2. 通过 PCI unbind 模拟 GPU 消失

```bash
# SSM 连接 GPU 节点 (格式: sagemaker-cluster:{cluster-id}_{instance-group}-{instance-id})
aws ssm start-session \
  --target sagemaker-cluster:v72pd0n2n89w_g6e-i-0008e4b1d060011b3 \
  --region ap-southeast-3

# 在节点上执行 unbind
echo 0000:30:00.0 > /sys/bus/pci/drivers/nvidia/unbind

# 验证 nvidia-smi 失败
nvidia-smi
# 输出: No devices were found (EXIT_CODE=6)
```

### 3. 重启 nvidia-device-plugin 使其感知 GPU 丢失

```bash
kubectl delete pod nvidia-device-plugin-daemonset-7g7kf -n kube-system
```

**结果**: device-plugin 重启后进入 CrashLoopBackOff，节点 GPU allocatable 变为 0。

### 4. 注入 XID 错误触发 health-monitoring-agent

```bash
# SSM 进入节点后执行
echo "kernel: NVRM: Xid (PCI:0000:30:00): 79, pid=1234, GPU has fallen off the bus." > /dev/kmsg
```

### 5. 验证检测结果

```bash
# 查看 health-monitoring-agent 日志
kubectl logs -n aws-hyperpod -l app.kubernetes.io/name=health-monitoring-agent --tail=10

# 查看节点标签
kubectl get node <node-name> -o jsonpath='{.metadata.labels.sagemaker\.amazonaws\.com/node-health-status}'

# 查看节点 taint
kubectl get node <node-name> -o json | jq '.spec.taints'
```

## 实验结果

### PCI unbind 方式（不触发 health-monitoring-agent）

| 检测组件 | 是否感知 | 说明 |
|---------|---------|------|
| nvidia-smi | ✅ | 返回 "No devices were found" |
| nvidia-device-plugin | ✅ | CrashLoopBackOff, allocatable=0 |
| health-monitoring-agent | ❌ | 只监听 kernel log XID，不主动探测设备 |
| HyperPod 平台 | ❌ | 节点状态仍为 Running |

### XID 注入方式（触发完整链路）

| 时间 | 事件 |
|------|------|
| 08:22:44 | health-monitoring-agent 检测到 XID 79 |
| 08:22:44 | 节点 condition `NvidiaGPUUnhealthy` → True |
| 08:22:44 | 节点标签变为 `UnschedulablePendingReplacement` |
| 08:22:44 | 节点添加 taint `NoSchedule` |
| 08:22:48 | health-monitoring-agent 上报 CloudWatch Logs |
| 08:22:50 | HyperPod 平台服务 (`AWSServiceRoleForSageMakerHyperPod`) 开始响应 |
| 08:22:48 | 平台内部触发 replacement 操作 |

### health-monitoring-agent 检测机制

- **数据源**: `/var/log/messages` (kernel log)
- **匹配规则**: 正则 `kernel: (.*)`
- **GPU 故障规则**:
  - XID 94 → `NvidiaGpuXidRestartApp`
  - XID 64/74/79 → `NvidiaGpuXidErrorPendingReplacement`
  - SXid Fatal → `NvidiaGpuXidErrorPendingReplacement`
  - 其他 XID → `NvidiaGpuXidErrorPendingReboot`
- **不检测**: nvidia-smi 可用性、GPU 设备是否存在、device-plugin 状态

### 平台行为

- 即使 `NodeRecovery=None`，HyperPod 平台在检测到 `UnschedulablePendingReplacement` 标签后仍然尝试触发 replacement
- CloudTrail 中无显式 `BatchReplaceClusterNodes` API 调用，是平台内部服务行为
- replacement 操作卡住：节点 kubelet 仍然 Ready，平台状态仍显示 Running，但内部有 active replacement operation

## 遗留问题

1. **Replacement 卡住**: 操作从 08:22:48 开始一直未完成，节点状态仍为 Running。可能原因：
   - `NodeRecovery=None` 阻止了实际执行但操作状态已创建
   - 平台无法终止一个 kubelet 仍然 Ready 的节点
   - 需要联系 AWS support 清理 stale operation

2. **节点被锁死，无法 reboot 或 replace**: CLI 和 Console 均被拒绝，ErrorCode 为 `InstanceIdInUse`：
   ```bash
   # CLI reboot 失败
   aws sagemaker batch-reboot-cluster-nodes --cluster-name tencent --node-ids i-0008e4b1d060011b3 --region ap-southeast-3
   # {
   #   "Failed": [{
   #     "NodeId": "i-0008e4b1d060011b3",
   #     "ErrorCode": "InstanceIdInUse",
   #     "Message": "Node has active replacement operation (started: 2026-05-21T08:22:48.103Z). Wait for completion or retry if operation is stale."
   #   }]
   # }

   # CLI replace 同样失败
   aws sagemaker batch-replace-cluster-nodes --cluster-name tencent --node-ids i-0008e4b1d060011b3 --region ap-southeast-3
   # 同样报错 InstanceIdInUse

   # Console 中操作也报同样的错误
   ```

## 恢复方法

### GPU 设备恢复

简单的 `echo 0000:30:00.0 > /sys/bus/pci/drivers/nvidia/bind` 可能不够，因为 unbind 后驱动状态已不一致。实际验证有效的恢复步骤：

```bash
# SSM 进入节点
aws ssm start-session \
  --target sagemaker-cluster:v72pd0n2n89w_g6e-i-0008e4b1d060011b3 \
  --region ap-southeast-3

# 1. 杀掉占用 nvidia 设备的进程 (nv-hostengine, nvidia-persistenced)
fuser -k /dev/nvidia*

# 2. 卸载 nvidia 内核模块（按依赖顺序）
rmmod nvidia_uvm
rmmod nvidia_modeset
rmmod nvidia

# 3. 重新加载模块（会自动 bind PCI 设备）
modprobe nvidia
modprobe nvidia_uvm

# 4. 验证
nvidia-smi
```

> **注意**: 如果 `rmmod nvidia_uvm` 报 "Module is in use"，需要先 `fuser -k /dev/nvidia*` 杀掉占用进程。
> 如果仍然失败，可能需要 `rmmod gdrdrv; rmmod efa_nv_peermem; rmmod nvidia_fs` 先卸载上层依赖模块。

### Kubernetes 层面恢复

```bash
# 清除 taint
kubectl taint node <node-name> sagemaker.amazonaws.com/node-health-status-

# 恢复标签
kubectl label node <node-name> sagemaker.amazonaws.com/node-health-status=Schedulable --overwrite

# 重启 device-plugin 使其重新注册 GPU
kubectl delete pod -n kube-system -l app=nvidia-device-plugin-daemonset --field-selector spec.nodeName=<node-name>
```

### 恢复验证

```bash
# 确认 GPU 资源恢复
kubectl get node <node-name> -o json | jq '{
  health_label: .metadata.labels["sagemaker.amazonaws.com/node-health-status"],
  taints: .spec.taints,
  gpu_capacity: .status.capacity["nvidia.com/gpu"],
  gpu_allocatable: .status.allocatable["nvidia.com/gpu"]
}'
# 期望: health_label=Schedulable, taints=null, gpu=1/1
```

### 恢复后仍存在的问题

恢复 GPU 和 K8s 状态后，平台内部的 stale replacement operation 仍然存在，导致后续 `batch-reboot-cluster-nodes` 和 `batch-replace-cluster-nodes` 操作仍会被拒绝（`InstanceIdInUse`）。此问题需要联系 AWS support 或等待平台自动清理。
