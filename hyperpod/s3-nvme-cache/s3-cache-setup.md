# S3 Mountpoint CSI Cache 配置指南（多节点自动化 + 本地 NVMe）

## 环境信息

| 项目 | 值 |
|------|-----|
| 集群 | SageMaker HyperPod (ap-southeast-3) |
| 机器类型 | ml.g5.8xlarge (32 vCPU, 824G NVMe) / ml.g6e.xlarge (2 vCPU, 229G NVMe) |
| 本地 NVMe 挂载点 | `/opt/dlami/nvme` |
| S3 Bucket | `testbucketjason99` (ap-southeast-1) |
| 缓存方式 | ephemeral + Local Volume Static Provisioner（自动发现 NVMe） |
| GPU Taint | `nvidia.com/gpu=true:NoSchedule`（g5 有，g6e 无） |

## 前置条件

- 集群已安装 [Mountpoint S3 CSI Driver](https://github.com/awslabs/mountpoint-s3-csi-driver)
- S3 bucket 访问权限已通过 IRSA 或 Pod Identity 配置
- 本地 NVMe 已 mount 到 `/opt/dlami/nvme`（HyperPod 默认配置）

## 架构说明

```
┌─────────────────────────────────────────────────────────┐
│  Local Volume Static Provisioner (DaemonSet)            │
│  - 自动发现每个节点的 /opt/dlami/nvme 挂载点            │
│  - 自动创建 PV（StorageClass: nvme-local）              │
│  - 节点上下线无需手工操作                                │
└─────────────────────────────────────────────────────────┘
         │ 自动创建 PV
         ▼
┌─────────────────────────────────────────────────────────┐
│  S3 CSI Driver (Mountpoint)                             │
│  - cache: ephemeral                                     │
│  - cacheEphemeralStorageClassName: nvme-local            │
│  - 每个节点的 Mountpoint Pod 自动绑定本地 NVMe 缓存      │
└─────────────────────────────────────────────────────────┘
         │
         ▼
┌─────────────────────────────────────────────────────────┐
│  工作负载 Pod (DaemonSet / Deployment)                   │
│  - 挂载 S3 PVC → 读取时自动命中本地 NVMe 缓存           │
└─────────────────────────────────────────────────────────┘
```

**关键优势**：新节点加入集群后，provisioner 自动发现 NVMe → 创建 PV → 工作负载 Pod 自动获得缓存加速，**支持 100+ 节点零手工操作**。

## 部署文件

### 文件 1：`local-volume-provisioner.yaml`

自动发现每个节点的 NVMe 并创建 PV：

```yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: nvme-local
provisioner: kubernetes.io/no-provisioner
volumeBindingMode: WaitForFirstConsumer
reclaimPolicy: Delete
---
apiVersion: v1
kind: Namespace
metadata:
  name: local-provisioner
---
apiVersion: v1
kind: ConfigMap
metadata:
  name: local-provisioner-config
  namespace: local-provisioner
data:
  storageClassMap: |
    nvme-local:
      hostDir: /opt/dlami
      mountDir: /opt/dlami
      blockCleanerCommand:
        - "/scripts/shred.sh"
        - "2"
      volumeMode: Filesystem
---
apiVersion: v1
kind: ServiceAccount
metadata:
  name: local-provisioner
  namespace: local-provisioner
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: local-provisioner
rules:
  - apiGroups: [""]
    resources: ["persistentvolumes"]
    verbs: ["get", "list", "watch", "create", "delete"]
  - apiGroups: ["storage.k8s.io"]
    resources: ["storageclasses"]
    verbs: ["get", "list", "watch"]
  - apiGroups: [""]
    resources: ["events"]
    verbs: ["watch", "create", "update", "patch"]
  - apiGroups: [""]
    resources: ["nodes"]
    verbs: ["get"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: local-provisioner
subjects:
  - kind: ServiceAccount
    name: local-provisioner
    namespace: local-provisioner
roleRef:
  kind: ClusterRole
  name: local-provisioner
  apiGroup: rbac.authorization.k8s.io
---
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: local-volume-provisioner
  namespace: local-provisioner
spec:
  selector:
    matchLabels:
      app: local-volume-provisioner
  template:
    metadata:
      labels:
        app: local-volume-provisioner
    spec:
      serviceAccountName: local-provisioner
      affinity:
        nodeAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            nodeSelectorTerms:
              - matchExpressions:
                  - key: node.kubernetes.io/instance-type
                    operator: In
                    values:
                      - ml.g6e.xlarge
                      - ml.g5.8xlarge
      tolerations:
        - key: nvidia.com/gpu
          operator: Equal
          value: "true"
          effect: NoSchedule
      containers:
        - name: provisioner
          image: registry.k8s.io/sig-storage/local-volume-provisioner:v2.7.0
          env:
            - name: MY_NODE_NAME
              valueFrom:
                fieldRef:
                  fieldPath: spec.nodeName
          volumeMounts:
            - name: provisioner-config
              mountPath: /etc/provisioner/config
              readOnly: true
            - name: local-disks
              mountPath: /opt/dlami
              mountPropagation: HostToContainer
      volumes:
        - name: provisioner-config
          configMap:
            name: local-provisioner-config
        - name: local-disks
          hostPath:
            path: /opt/dlami
```

关键配置说明：
- `hostDir: /opt/dlami` — provisioner 扫描此路径下的**挂载点**（发现 `nvme` 子目录因为它是独立 mount point），自动创建的 PV 的 `spec.local.path` 为 `/opt/dlami/nvme`，即实际缓存写入路径
- `WaitForFirstConsumer` — PVC 绑定延迟到 Pod 调度时，确保绑定到正确节点
- `affinity` — 只在有 NVMe 的 GPU 节点上运行（按需添加实例类型）
- `tolerations` — 容忍 GPU taint

> **扩展节点类型**：新增实例类型时，只需在 `affinity.values` 列表中添加即可。

### 文件 2：`s3-cache-multinode.yaml`

S3 PV/PVC + 测试 DaemonSet：

```yaml
apiVersion: v1
kind: PersistentVolume
metadata:
  name: s3-pv-cached
spec:
  capacity:
    storage: 1200Gi
  accessModes:
    - ReadWriteMany
  mountOptions:
    - allow-delete
    - metadata-ttl indefinite
    - region ap-southeast-1
    - read-part-size 67108864
    - maximum-throughput-gbps 25
  csi:
    driver: s3.csi.aws.com
    volumeHandle: s3-csi-testbucketjason99-cached
    volumeAttributes:
      bucketName: testbucketjason99
      cache: ephemeral
      cacheEphemeralStorageClassName: nvme-local
      cacheEphemeralStorageResourceRequest: 200Gi
---
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: s3-pvc-cached
spec:
  accessModes:
    - ReadWriteMany
  storageClassName: ""
  resources:
    requests:
      storage: 1200Gi
  volumeName: s3-pv-cached
---
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: s3-cache-test
spec:
  selector:
    matchLabels:
      app: s3-cache-test
  template:
    metadata:
      labels:
        app: s3-cache-test
    spec:
      affinity:
        nodeAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            nodeSelectorTerms:
              - matchExpressions:
                  - key: node.kubernetes.io/instance-type
                    operator: In
                    values:
                      - ml.g6e.xlarge
                      - ml.g5.8xlarge
      tolerations:
        - key: nvidia.com/gpu
          operator: Equal
          value: "true"
          effect: NoSchedule
      containers:
        - name: app
          image: amazonlinux:2023
          command: ["sleep", "infinity"]
          volumeMounts:
            - name: s3-vol
              mountPath: /data/s3
      volumes:
        - name: s3-vol
          persistentVolumeClaim:
            claimName: s3-pvc-cached
```

关键配置说明：
- `cache: ephemeral` — 使用 generic ephemeral volume 作为本地缓存
- `cacheEphemeralStorageClassName: nvme-local` — 指向 provisioner 自动创建的 PV
- `cacheEphemeralStorageResourceRequest: 200Gi` — 每个节点请求 200G 缓存空间
- `metadata-ttl indefinite` — 元数据缓存永不过期
- `region ap-southeast-1` — S3 bucket 所在区域（跨区域场景需显式指定）

## 部署与验证

```bash
# 1. 部署 Local Volume Static Provisioner
kubectl apply -f local-volume-provisioner.yaml

# 2. 等待 provisioner 自动发现 NVMe 并创建 PV
kubectl get pv | grep nvme-local
# 预期：每个 GPU 节点对应一个 PV

# 3. 部署 S3 缓存测试
kubectl apply -f s3-cache-multinode.yaml

# 4. 检查资源状态
kubectl get pods -l app=s3-cache-test -o wide
kubectl get pods -n mount-s3 -o wide
kubectl get pvc -n mount-s3

# 5. 验证 S3 挂载
kubectl exec <pod-name> -- ls /data/s3
```

### 验证 provisioner 自动创建 PV

```bash
$ kubectl get pv | grep nvme-local
local-pv-3610f02b   228Gi   RWO   Delete   Bound   mount-s3/mp-ndpbt-local-cache   nvme-local
local-pv-d981df73   228Gi   RWO   Delete   Bound   mount-s3/mp-b4m6h-local-cache   nvme-local
local-pv-7bca1511   823Gi   RWO   Delete   Bound   mount-s3/mp-8dv5p-local-cache   nvme-local
```

每个节点自动创建了对应容量的 PV（g6e: 228Gi, g5: 823Gi）。

### 验证缓存 PVC 绑定

```bash
$ kubectl get pvc -n mount-s3
NAME                   STATUS   VOLUME              CAPACITY   STORAGECLASS
mp-ndpbt-local-cache   Bound    local-pv-3610f02b   228Gi      nvme-local
mp-b4m6h-local-cache   Bound    local-pv-d981df73   228Gi      nvme-local
mp-8dv5p-local-cache   Bound    local-pv-7bca1511   823Gi      nvme-local
```

## 缓存加速测试

### 测试脚本

```bash
#!/bin/bash
# 单文件读取测试
POD=$1
echo "=== 冷读 20GB ==="
kubectl exec $POD -- bash -c "time dd if=/data/s3/test-20gb.bin of=/dev/null bs=1M 2>&1"
echo "=== 热读 20GB ==="
kubectl exec $POD -- bash -c "time dd if=/data/s3/test-20gb.bin of=/dev/null bs=1M 2>&1"

# 并发读取测试（20×1GB 分片）
echo "=== 并发热读 20x1GB ==="
kubectl exec $POD -- bash -c '
start=$(date +%s%N)
for i in $(seq -w 0 19); do
  dd if=/data/s3/chunks/part-$i of=/dev/null bs=1M 2>/dev/null &
done
wait
end=$(date +%s%N)
elapsed=$(( (end - start) / 1000000 ))
echo "Total: ${elapsed}ms, Throughput: $(( 20 * 1024 * 1000 / elapsed )) MB/s"
'
```

### 测试结果（20GB 数据，跨区域 ap-southeast-3 → ap-southeast-1）

#### ml.g5.8xlarge（32 vCPU, 824G NVMe）

| 测试 | 耗时 | 吞吐 | 说明 |
|------|------|------|------|
| 单文件冷读 | 41.1s | 523 MB/s | 数据从 S3 拉取，同时写入 NVMe 缓存 |
| 单文件热读 | 18.2s | **1.2 GB/s** | 数据从本地 NVMe 缓存读取 |
| 并发冷读 (20×1GB) | 17.8s | 1,151 MB/s | S3 并发拉取 |
| 并发热读 (20×1GB) | 4.4s | **4,626 MB/s** | NVMe 缓存并发读取 |

#### ml.g6e.xlarge（2 vCPU, 229G NVMe）

| 测试 | 耗时 | 吞吐 | 说明 |
|------|------|------|------|
| 单文件冷读 | 99s | 217 MB/s | S3 拉取，CPU 瓶颈 |
| 单文件热读 | 56s | 386 MB/s | NVMe 缓存，受 2 vCPU 限制 |
| 并发冷读 (20×1GB) | 96s | 212 MB/s | CPU 瓶颈明显 |
| 并发热读 (20×1GB) | 44s | 470 MB/s | CPU 限制并发 IO |

#### 对比分析

| 指标 | g5.8xlarge | g6e.xlarge | 差距 |
|------|-----------|-----------|------|
| 单文件热读 | 1.2 GB/s | 385 MB/s | 3.1x |
| 并发热读 | 4.6 GB/s | 470 MB/s | 10x |
| 缓存加速比（并发） | 4.0x | 2.2x | — |

**结论**：
- 缓存加速在所有实例类型上都有效
- g5.8xlarge（32 vCPU）并发热读达 **4.6 GB/s**，充分利用 NVMe 并行 IO
- g6e.xlarge（2 vCPU）受 CPU 限制，FUSE 开销大，吞吐受限
- **CPU 核数是影响缓存吞吐的关键因素**，建议使用 8+ vCPU 的实例

## 多 Pod 共享同一 PVC

`s3-pvc-cached` 的 accessMode 为 `ReadWriteMany`，支持同一节点上多个 Pod 同时挂载。所有 Pod 共享同一个 Mountpoint Pod（FUSE 进程），不会重复创建。

### 测试结果（g5.8xlarge，同节点多 Pod 同时热读 20GB）

| 场景 | 每 Pod 吞吐 | 合计吞吐 |
|------|-----------|---------|
| 单 Pod 热读 | 1.1~1.2 GB/s | 1.2 GB/s |
| 两 Pod 同时热读 | 571~586 MB/s | ~1.17 GB/s |

合计吞吐基本不变，带宽被多个 Pod 平分。原因是所有 Pod 共享同一个 Mountpoint FUSE 进程，总带宽受限于该进程的吞吐上限。

> 如果需要多 Pod 各自跑满带宽，需创建多个独立的 S3 PV/PVC（不同 `volumeHandle`），每个 PVC 会有自己的 Mountpoint Pod。但会受到单节点只有一个 NVMe PV 的缓存限制（见注意事项第 7 条）。

## 已知问题：FailedMount（mountpoint pod not found）

### 错误现象

```
FailedMount: MountVolume.SetUp failed for volume "xxx" : rpc error: code = Internal desc =
Could not mount "bucket" at "...": Failed to wait for Mountpoint Pod "mp-xxxxx" to be ready:
mppod/watcher: mountpoint pod not found.
```

### 触发条件

通过压力测试（5 replicas 反复 scale 0→5 + 强制删除 Mountpoint Pod）成功复现。以下场景会触发：

1. **NVMe PV 不可用**（Released 状态未清理、指向已下线节点）→ Mountpoint Pod 的 cache PVC Pending → Mountpoint Pod 无法启动
2. **Mountpoint Pod 被意外删除或驱逐** → 正在等待挂载的工作负载 Pod 立即报错
3. **DNS 暂时性故障** → Mountpoint Pod 启动失败（`AWS_IO_DNS_QUERY_FAILED`）
4. **节点 Pod 数量达到上限** → Mountpoint Pod 无法调度

### 影响

- 这是**暂时性错误**，kubelet 会自动重试挂载（默认每 ~2 分钟）
- S3 CSI controller 会自动重新创建 Mountpoint Pod
- 压力测试中所有 Pod 最终都恢复到 Running 状态

### 排查步骤

```bash
# 1. 查看 Mountpoint Pod 状态
kubectl get pods -n mount-s3 -o wide
kubectl describe pods -n mount-s3

# 2. 查看 cache PVC 是否绑定
kubectl get pvc -n mount-s3

# 3. 查看 NVMe PV 状态（是否有 Released 未清理的）
kubectl get pv | grep nvme-local

# 4. 查看 FailedMount 事件
kubectl get events --field-selector reason=FailedMount --sort-by='.lastTimestamp'

# 5. 清理 Released 状态的 PV（provisioner 会自动重建）
kubectl get pv -o name | while read pv; do
  status=$(kubectl get $pv -o jsonpath='{.status.phase}')
  sc=$(kubectl get $pv -o jsonpath='{.spec.storageClassName}')
  if [ "$status" = "Released" ] && [ "$sc" = "nvme-local" ]; then
    kubectl delete $pv
  fi
done
```

## 注意事项

1. **Provisioner 发现机制**：`hostDir` 设为 `/opt/dlami`（父目录），provisioner 发现其下的 `nvme` **挂载点**。普通子目录不会被发现，必须是独立 mount point
2. **Pod 数量限制**：小实例（如 g6e.xlarge）只有 14 个 pod 位置，需确保有空间给 provisioner pod + mountpoint pod + 工作负载 pod
3. **GPU Taint**：g5 等 GPU 节点有 `nvidia.com/gpu=true:NoSchedule` taint，provisioner 和工作负载 Pod 都需要加 toleration
4. **跨区域 S3**：必须在 `mountOptions` 中指定 `region`，否则报 `IncorrectRegion` 错误
5. **扩展实例类型**：新增节点类型时，在 provisioner 和工作负载的 `affinity.values` 中添加即可
6. **Mountpoint Pod Pending**：如果 cache PVC 无法绑定，通过 `kubectl describe pods -n mount-s3` 排查
7. **单节点多 S3 mount 的缓存限制**：每个配置了 `cache: ephemeral` 的 S3 PV 会为其 Mountpoint Pod 请求一个独立的 cache PVC。由于每个节点只有 1 个 NVMe PV（`ReadWriteOnce`），**同一节点上只有一个 S3 mount 能绑定 NVMe 缓存**，第二个会因无可用 PV 而 Pending。解决方案：
   - 只给最需要加速的 S3 PV 配置 `cache: ephemeral`，其他不配缓存
   - 改用 `cache: emptyDir`（不依赖 PV，但缓存落在根盘而非 NVMe）
   - 在 NVMe 上用 `mount --bind` 创建多个挂载点，让 provisioner 发现多个 PV

## 参考

- [Mountpoint S3 CSI Driver Caching 文档](https://github.com/awslabs/mountpoint-s3-csi-driver/blob/main/docs/CACHING.md)
- [Mountpoint 缓存配置](https://github.com/awslabs/mountpoint-s3/blob/main/doc/CONFIGURATION.md#caching-configuration)
- [Local Volume Static Provisioner](https://github.com/kubernetes-sigs/sig-storage-local-static-provisioner)
- [EKS Persistent Volumes for Instance Store](https://aws.amazon.com/blogs/containers/eks-persistent-volumes-for-instance-store/)
