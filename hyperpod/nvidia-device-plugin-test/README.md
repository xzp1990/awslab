# NVIDIA Device Plugin 测试记录

## 测试日期
2026-05-12

## 测试环境
- 集群: HyperPod (tencent)
- 区域: ap-southeast-3
- GPU节点: hyperpod-i-0f98b52057650cdcd (ml.g5.8xlarge, NVIDIA A10G)
- Plugin版本: nvcr.io/nvidia/k8s-device-plugin:v0.16.1
- Driver: 580.126.09, CUDA: 13.0

## 测试1: 删除Device Plugin对运行中GPU Pod的影响

### 目的
验证删除NVIDIA device plugin后，已运行的GPU Pod是否仍能正常使用GPU。

### 步骤
1. 启动GPU测试Pod（请求nvidia.com/gpu: 1）
2. 确认nvidia-smi正常
3. 通过patch DaemonSet nodeSelector使plugin pod消失
4. 再次执行nvidia-smi验证GPU可用性
5. 检查节点资源变化
6. 尝试启动新GPU Pod
7. 恢复plugin

### 结果

| 测试项 | 结果 |
|--------|------|
| 删除plugin后，运行中GPU Pod能否继续使用GPU | ✅ 不受影响 |
| 删除plugin后，节点GPU资源变化 | capacity=1, allocatable=0 |
| 删除plugin后，新GPU Pod能否调度 | ❌ 无法调度 (Insufficient nvidia.com/gpu) |
| 恢复plugin后，资源是否恢复 | ✅ allocatable恢复为1 |

### 结论
- Device plugin只在**调度和启动阶段**参与GPU设备分配
- 运行中的容器已持有GPU设备挂载（/dev/nvidia*），不依赖plugin
- 删除plugin后节点allocatable归零，新Pod无法获得GPU
- 替换plugin期间对已有workload无影响，但需快速恢复以避免新Pod调度失败

### 操作命令参考

```bash
# 停止plugin（不删除DaemonSet）
kubectl patch daemonset dependencies-nvidia-device-plugin -n kube-system \
  -p '{"spec":{"template":{"spec":{"nodeSelector":{"non-existing":"true"}}}}}'

# 恢复plugin
kubectl patch daemonset dependencies-nvidia-device-plugin -n kube-system \
  --type=json -p='[{"op":"remove","path":"/spec/template/spec/nodeSelector/non-existing"}]'
```

---

## 测试2: 从独立Device Plugin迁移到GPU Operator

### 目的
将HyperPod自带的独立nvidia-device-plugin替换为GPU Operator管理，为后续H200 MIG功能做准备。

### 背景
- HyperPod默认通过 `dependencies` helm chart安装独立的nvidia-device-plugin v0.16.1
- GPU Operator (v26.3.1) 包含device plugin + MIG Manager + GFD等组件
- A10G (g5) 不支持MIG，但H200 (p5en) 支持
- 参考: https://github.com/aws/sagemaker-hyperpod-cli/blob/main/helm_chart/HyperPodHelmChart/charts/gpu-operator/values.yaml

### 安装步骤

```bash
# 1. 禁用旧的device plugin（不删除DaemonSet，避免helm状态不一致）
kubectl patch daemonset dependencies-nvidia-device-plugin -n kube-system \
  -p '{"spec":{"template":{"spec":{"nodeSelector":{"non-existing":"true"}}}}}'

# 2. 克隆/更新repo
git clone https://github.com/aws/sagemaker-hyperpod-cli.git
cd sagemaker-hyperpod-cli

# 3. 添加nvidia helm repo并build dependencies
helm repo add nvidia https://helm.ngc.nvidia.com/nvidia && helm repo update
helm dependency build helm_chart/HyperPodHelmChart/charts/gpu-operator/

# 4. 安装GPU Operator（需要额外set initContainer解决CRD验证问题）
helm install gpuo helm_chart/HyperPodHelmChart/charts/gpu-operator \
  -f helm_chart/HyperPodHelmChart/charts/gpu-operator/regional-values/values-ap-southeast-3.yaml \
  --set gpu-operator.operator.initContainer.image=mirror-gpu-operator \
  --set gpu-operator.operator.initContainer.version=v26.3.1 \
  --set gpu-operator.operator.initContainer.enabled=false \
  -n kube-system
```

### 结果
- ✅ GPU Operator v26.3.1 安装成功
- ✅ 所有组件正常运行：gpu-operator, gpu-feature-discovery, nvidia-device-plugin-daemonset, nvidia-container-toolkit, nvidia-operator-validator, node-feature-discovery
- ✅ GPU资源正常注册 (capacity=1, allocatable=1)
- ✅ 测试Pod成功调度并执行nvidia-smi

### 注意事项
- `dependencies` helm chart中的旧DaemonSet仍然存在（只是被patch禁用），不影响功能
- 如果HyperPod做集群升级可能恢复旧plugin，需要再次patch
- 当前A10G不支持MIG，后续开H200时可通过label启用MIG：
  ```bash
  kubectl label node $NODE nvidia.com/mig.config=mixed-3-1g.18gb-1-4g.71gb --overwrite
  ```

### 卸载/回滚命令
```bash
# 卸载GPU Operator
helm uninstall gpuo -n kube-system

# 恢复旧device plugin
kubectl patch daemonset dependencies-nvidia-device-plugin -n kube-system \
  --type=json -p='[{"op":"remove","path":"/spec/template/spec/nodeSelector/non-existing"}]'
```

---

## 测试3: 新节点自动部署验证 (g6e)

### 目的
验证GPU Operator安装后，新加入的GPU节点是否自动部署所有GPU组件。

### 环境
- 新节点: hyperpod-i-015cbb2fa1b80ee3c (ml.g6e.xlarge)
- GPU: NVIDIA L40S, 46GB显存
- Driver: 580.126.09, CUDA 13.0

### 结果
- ✅ GPU Operator自动在新节点部署所有DaemonSet组件：
  - gpu-feature-discovery
  - nvidia-device-plugin-daemonset
  - nvidia-container-toolkit-daemonset
  - nvidia-operator-validator
  - nvidia-cuda-validator (Completed)
  - node-feature-discovery-worker
- ✅ GPU资源自动注册 (capacity=1, allocatable=1)
- ✅ 测试Pod成功调度，nvidia-smi正常

### 结论
GPU Operator对新节点实现了零干预自动配置，比独立device plugin方案更完善（自动包含GFD、toolkit、validator等）。

---

## 后续测试计划

- [ ] 开H200 (ml.p5en.48xlarge) 实例测试MIG分区
- [ ] 测试MIG配置切换（mixed profile）
- [ ] 测试MIG分区上的推理workload
