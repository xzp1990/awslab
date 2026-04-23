# HyperPod EKS 突破 maxPods 限制指南

## 背景

SageMaker HyperPod EKS 集群中，每个实例只支持 1 个 ENI。对于 `ml.g6e.xlarge`，默认 maxPods 为 **14**（单 ENI 最多 15 个 IPv4 地址 - 1 个主 IP = 14）。

当集群系统组件较多时，14 个 pod 不够用，会导致大量 pod 处于 Pending 状态。

## 解决方案

通过两步操作将 maxPods 从 14 提升到 **58**：

1. **开启 VPC CNI Prefix Delegation** — 集群级别，一次性操作
2. **修改 kubelet maxPods** — 节点级别，通过 lifecycle script + systemd 自动化

> 58 是 kubelet 主配置 `/etc/kubernetes/kubelet/config.json` 中的原始值，也是 EKS 为该实例类型在 prefix delegation 模式下计算的推荐值。HyperPod 的 override 文件 `40-nodeadm.conf` 将其强制覆盖为 14，我们将其恢复为 58。

### 原理

| 配置 | 默认模式 | Prefix Delegation 模式 |
|------|---------|----------------------|
| IP 分配方式 | 逐个分配 secondary IP | 分配 /28 前缀（每个 16 个 IP） |
| 单 ENI 可用 pod IP | 14 | 58（EKS 推荐值） |
| 子网 IP 消耗 | 按需 1 个 | 按块 16 个 |

## 操作步骤

### 步骤 1：开启 VPC CNI Prefix Delegation（集群级别，一次性）

HyperPod 使用 EKS 托管 addon 管理 VPC CNI，直接用 `kubectl set env` 修改会被控制面覆盖。必须通过 EKS addon API 配置：

```bash
aws eks update-addon \
  --cluster-name <EKS_CLUSTER_NAME> \
  --addon-name vpc-cni \
  --region <REGION> \
  --resolve-conflicts OVERWRITE \
  --configuration-values '{"env":{"ENABLE_PREFIX_DELEGATION":"true","WARM_PREFIX_TARGET":"2","WARM_IP_TARGET":"5","MINIMUM_IP_TARGET":"30"}}'
```

或使用提供的脚本：

```bash
./enable-prefix-delegation.sh <EKS_CLUSTER_NAME> <REGION>
```

验证配置已持久化：

```bash
aws eks describe-addon \
  --cluster-name <EKS_CLUSTER_NAME> \
  --addon-name vpc-cni \
  --region <REGION> \
  --query 'addon.configurationValues'
```

### 步骤 2：创建带 maxPods 修改的 Instance Group

将 `on_create.sh` 上传到 S3：

```bash
aws s3 cp on_create.sh s3://<YOUR_BUCKET>/<INSTANCE_GROUP_NAME>/on_create.sh --region <REGION>
```

创建新的 instance group：

```bash
aws sagemaker update-cluster \
  --cluster-name <CLUSTER_NAME> \
  --region <REGION> \
  --instance-groups '[{
    "InstanceGroupName": "<INSTANCE_GROUP_NAME>",
    "InstanceType": "ml.g6e.xlarge",
    "InstanceCount": 1,
    "ExecutionRole": "<EXECUTION_ROLE_ARN>",
    "ThreadsPerCore": 2,
    "InstanceStorageConfigs": [{"EbsVolumeConfig": {"VolumeSizeInGB": 200}}],
    "LifeCycleConfig": {
      "SourceS3Uri": "s3://<YOUR_BUCKET>/<INSTANCE_GROUP_NAME>",
      "OnCreate": "on_create.sh"
    }
  }]'
```

### 步骤 3：对已有节点手动修改（可选）

如果有已经运行的节点需要立即生效，通过 SSM 连接修改：

```bash
aws ssm start-session \
  --target "sagemaker-cluster:<CLUSTER_ID>_<INSTANCE_GROUP>-<INSTANCE_ID>" \
  --region <REGION>

# 在节点上执行
python3 -c "
import json
f = '/etc/kubernetes/kubelet/config.json.d/40-nodeadm.conf'
c = json.load(open(f))
c['maxPods'] = 58
json.dump(c, open(f, 'w'), indent=4)
"
systemctl restart kubelet
```

## 验证

```bash
# 检查所有节点的 allocatable pods
kubectl get nodes -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.status.allocatable.pods}{"\n"}{end}'

# 检查是否还有 Pending pod
kubectl get pods --all-namespaces --field-selector=status.phase=Pending

# 检查 VPC CNI IP pool（在节点上）
tail -20 /var/log/aws-routed-eni/ipamd.log

# 检查 systemd patch 状态（在节点上）
cat /var/log/provision/patch-maxpods.log
systemctl status patch-maxpods.path
systemctl status patch-maxpods.service
```

### 实测结果（ml.g6e.xlarge）

在单节点上验证 maxPods=58 的效果：

| 指标 | 修改前 | 修改后 |
|------|--------|--------|
| allocatable pods | 14 | 58 |
| 系统组件 pod | 14（满载，大量 Pending） | 32（全部 Running） |
| 可用于业务 pod | 0 | 26 |
| 第 59 个 pod | — | Pending（`Too many pods`） |

测试方法：部署 nginx 填满节点至 58 个 pod，全部 Running；第 59 个 pod 被调度器拒绝，确认 maxPods 限制生效。

## on_create.sh 关键设计

### HyperPod 启动时序

```
1. lifecycle script (on_create.sh) 执行
   ├── containerd 配置（systemd override + data-root 迁移到 EBS）
   └── 注册 systemd path unit（监听 kubelet 配置文件）
2. HyperPod 等待 on_create.sh 所有子进程退出
3. HyperPod 标记 lifecycle script succeeded
4. HyperPod 控制面下发 nodeadm-config.yaml
5. nodeadm 启动 containerd → 配置 kubelet → 注册节点到 EKS
6. kubelet 配置文件 40-nodeadm.conf 创建
   └── systemd path unit 检测到文件，触发 patch-maxpods.service
       ├── 修改 maxPods: 14 → 58
       ├── 重启 kubelet
       └── 禁用 path watcher（避免重复触发）
7. 节点以 maxPods=58 加入集群
```

### 为什么用 systemd path unit

**HyperPod 的 provisioning agent 会等待 on_create.sh 的所有子进程退出**，包括 `nohup &` 启动的后台进程。如果有后台进程在运行，HyperPod 不会标记 lifecycle script 为 succeeded，后续的 nodeadm/EKS 注册流程会被无限期阻塞。

| 方案 | 是否阻塞 HyperPod | 结果 |
|------|-------------------|------|
| `nohup script.sh &` | ❌ 阻塞（子进程未退出） | 节点卡在 provisioning |
| `systemd path unit` | ✅ 不阻塞（systemctl 立即返回） | 正常工作 |

systemd path unit 的 `PathExists` 指令会监听文件系统，当目标文件出现时自动触发关联的 service，无需轮询，无需后台进程。

### 日志位置

| 日志 | 路径 |
|------|------|
| lifecycle 主日志 | `/var/log/provision/provisioning.log` |
| maxPods 修改日志 | `/var/log/provision/patch-maxpods.log` |

## 踩坑记录

### 1. nohup 后台进程阻塞 HyperPod provisioning

早期方案用 `nohup /opt/sagemaker/patch-maxpods.sh &` 启动后台轮询进程。HyperPod agent 等待所有子进程退出，导致节点卡在 provisioning 15+ 分钟无法注册到 EKS。

**修复**：改用 systemd path unit，`systemctl enable --now` 立即返回，不产生子进程。

### 2. containerd override 不影响 nodeadm

最初怀疑 on_create.sh 中创建的 containerd systemd override 会阻塞 nodeadm。经对比正常节点（g6e）确认：原始脚本也创建了相同的 override，nodeadm 能正常处理。containerd override 本身不是问题。

### 3. 等待超时不够

早期后台脚本 `MAX_WAIT=300`（5 分钟），但 HyperPod 从 lifecycle script 完成到 kubelet 配置文件创建可能需要 5-10 分钟，导致超时。systemd path unit 方案没有超时限制，彻底解决了这个问题。

## 风险与注意事项

1. **子网 IP 消耗加速** — Prefix delegation 按 /28 块分配（16 个 IP/块），确保子网有足够 IP
2. **节点替换后自动生效** — kubelet 修改通过 systemd path unit 自动处理；VPC CNI 配置是集群级别，不受影响
3. **非官方支持** — HyperPod 文档明确限制了每种实例类型的 max pods，此方案绕过了该限制
4. **Addon 升级注意** — 升级 VPC CNI addon 版本时需确认 `configurationValues` 是否保留，建议升级时显式传入配置

## 文件说明

```
├── README.md                      # 本文档
├── on_create.sh                   # lifecycle script（上传到 S3）
└── enable-prefix-delegation.sh    # 一键开启 VPC CNI prefix delegation（集群级别）
```

## 测试总结

在 ap-southeast-3 区域的 HyperPod EKS 集群上，使用 `ml.g6e.xlarge` 单节点完成验证。通过开启 VPC CNI Prefix Delegation 并修改 kubelet maxPods，节点可调度 pod 数从 14 提升至 58。实测部署 58 个 pod（32 个系统组件 + 26 个 nginx）全部 Running，第 59 个 pod 被调度器拒绝（`Too many pods`），确认限制生效。新节点启动后 maxPods 通过 systemd path unit 自动修改，无需人工干预。
