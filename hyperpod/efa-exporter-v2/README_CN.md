# EFA Exporter v2 - Kubernetes Pod 级别 EFA 指标采集器

基于 AWS 官方 [efa-node-exporter](https://github.com/awslabs/awsome-distributed-ai/tree/main/4.validation_and_observability/3.efa-node-exporter) 改造，通过 kubelet PodResources API 实现 **EFA 设备到 Pod 的映射**。

## 问题背景

原版 EFA exporter 只能输出设备级别的指标：

```
node_amazonefa_tx_bytes{device="rdmap47s0",port="1"} 24167820008
```

无法知道是哪个 Pod 在使用这个 EFA 设备，导致无法做 per-job 的网络流量监控。

## 解决方案

V2 版本通过查询 kubelet PodResources API，获取 `vpc.amazonaws.com/efa` 设备的分配关系，自动注入 `pod`、`namespace`、`container` label：

```
node_amazonefa_tx_bytes{device="rdmap47s0",port="1",pod="nccl-test-g6e-worker-0",namespace="default",container="nccl-worker"} 24167820008
```

## 架构

```
┌──────────────────────────────────────────────────────┐
│  EFA Exporter v2 (DaemonSet, 每个 EFA 节点一个)       │
│                                                       │
│  ┌──────────────────┐    ┌─────────────────────────┐ │
│  │ amazonefa         │    │ PodResources Client     │ │
│  │ collector         │    │ (gRPC, 每15秒轮询)       │ │
│  │ 读取 /sys/class/  │    │ 查询 kubelet socket     │ │
│  │ infiniband/       │    │ 映射 EFA device → pod   │ │
│  └────────┬──────────┘    └───────────┬─────────────┘ │
│           └──────── 合并 labels ──────┘               │
│                       │                                │
│               /metrics (端口 9119)                     │
└──────────────────────────────────────────────────────┘
```

## 代码修改详解

仅修改 `amazon_efa_linux.go` 一个文件。`class_amazon_efa.go`（sysfs 解析）保持不变。

### 1. 新增依赖和常量

```go
import (
    "context"
    "net"
    "sync"
    "time"

    "google.golang.org/grpc"
    "google.golang.org/grpc/credentials/insecure"
    podresourcesv1 "k8s.io/kubelet/pkg/apis/podresources/v1"
)

const (
    efaResource       = "vpc.amazonaws.com/efa"
    kubeletSocketPath = "/var/lib/kubelet/pod-resources/kubelet.sock"
    podPollInterval   = 15 * time.Second
)
```

### 2. Pod 映射数据结构和后台轮询

使用全局 map `podDevMap` 存储 EFA 设备名（如 `rdmap47s0`）到 Pod 信息的映射。通过 `sync.Once` 确保只启动一个后台 goroutine，每 15 秒刷新一次。

```go
type podInfo struct {
    Pod       string
    Namespace string
    Container string
}

var (
    podMapMu   sync.RWMutex
    podDevMap  = map[string]podInfo{} // device_id -> podInfo
    podMapOnce sync.Once
)

func startPodMapper(logger *slog.Logger) {
    podMapOnce.Do(func() {
        go func() {
            for {
                m := fetchPodResources(logger)
                podMapMu.Lock()
                podDevMap = m
                podMapMu.Unlock()
                time.Sleep(podPollInterval)
            }
        }()
    })
}
```

### 3. PodResources gRPC 查询逻辑

连接 kubelet 的 PodResources gRPC socket（与 DCGM exporter 的 `-k` 参数使用相同机制），列出所有 Pod 的资源分配，过滤出 `vpc.amazonaws.com/efa` 设备：

```go
func fetchPodResources(logger *slog.Logger) map[string]podInfo {
    result := map[string]podInfo{}
    // 连接 unix:///var/lib/kubelet/pod-resources/kubelet.sock
    conn, err := grpc.DialContext(ctx, "unix://"+socketPath, ...)
    client := podresourcesv1.NewPodResourcesListerClient(conn)
    resp, err := client.List(ctx, &podresourcesv1.ListPodResourcesRequest{})

    for _, pod := range resp.GetPodResources() {
        for _, container := range pod.GetContainers() {
            for _, dev := range container.GetDevices() {
                if dev.GetResourceName() == "vpc.amazonaws.com/efa" {
                    for _, id := range dev.GetDeviceIds() {
                        // id 就是 EFA 设备名（如 "rdmap47s0"）
                        result[id] = podInfo{
                            Pod:       pod.GetName(),
                            Namespace: pod.GetNamespace(),
                            Container: container.GetName(),
                        }
                    }
                }
            }
        }
    }
    return result
}
```

**核心原理**：当 Pod 在 resource limits 中请求 `vpc.amazonaws.com/efa: 1` 时，EFA device plugin 会将具体设备（如 `rdmap47s0`）分配给该 Pod。kubelet 记录了这个分配关系并通过 PodResources API 暴露。返回的 device ID 与 `/sys/class/infiniband/` 下的设备名一致，正好是 EFA collector 遍历的对象。

### 4. 扩展指标 label

原始 label 为 `["device", "port"]`，扩展为包含 Pod 信息：

```go
// 修改前 (V1):
prometheus.NewDesc(..., []string{"device", "port"}, nil)

// 修改后 (V2):
prometheus.NewDesc(..., []string{"device", "port", "pod", "namespace", "container"}, nil)
```

### 5. 修改 `pushMetric` 注入 Pod labels

输出指标时，查询 pod map 并注入 labels：

```go
func (c *AmazonEfaCollector) pushMetric(...) {
    podMapMu.RLock()
    info, hasPod := podDevMap[deviceName]
    podMapMu.RUnlock()

    pod, ns, container := "", "", ""
    if hasPod {
        pod = info.Pod
        ns = info.Namespace
        container = info.Container
    }

    ch <- prometheus.MustNewConstMetric(c.metricDescs[name], valueType, float64(value),
        deviceName, port, pod, ns, container)
}
```

### 6. Collector 初始化时启动 Pod Mapper

```go
func NewAmazonEfaCollector(logger *slog.Logger) (Collector, error) {
    // ... 原有初始化代码 ...
    startPodMapper(logger)  // <-- 新增：启动后台 pod 映射
    return &i, nil
}
```

### 7. Dockerfile 改动

新增两行拉取 PodResources API 依赖：

```dockerfile
RUN go get k8s.io/kubelet@v0.30.2
RUN go get google.golang.org/grpc@v1.65.0
```

### 数据流总结

```
1. kubelet 通过 EFA device plugin 将设备 "rdmap47s0" 分配给 Pod "training-worker-0"

2. EFA Exporter 后台 goroutine（每 15 秒）：
   gRPC → kubelet:///var/lib/kubelet/pod-resources/kubelet.sock
   → ListPodResources()
   → 过滤 resource_name == "vpc.amazonaws.com/efa"
   → 构建映射: {"rdmap47s0" → {pod:"training-worker-0", ns:"default", container:"nccl"}}

3. Prometheus 抓取 /metrics 时：
   → 读取 /sys/class/infiniband/rdmap47s0/ports/1/hw_counters/*
   → 查询 "rdmap47s0" 在 pod map 中的映射
   → 输出: node_amazonefa_tx_bytes{device="rdmap47s0",port="1",
            pod="training-worker-0",namespace="default",container="nccl"} 12345
```

## 验证结果

### 指标数值一致性（V1 vs V2）

在同一节点同时运行 V1（端口 9120）和 V2（端口 9119），跑 NCCL all_reduce 后对比：

| 指标 | V1（原版） | V2（带 pod label） | 一致 |
|------|-----------|-------------------|------|
| rdma_read_bytes | 2.378e+10 | 2.378e+10 | ✅ |
| rdma_read_wrs | 22,680 | 22,680 | ✅ |
| tx_bytes | 2.417e+10 | 2.417e+10 | ✅ |
| rx_bytes | 2.417e+10 | 2.417e+10 | ✅ |
| tx_pkts | 3,179,567 | 3,179,567 | ✅ |
| rx_pkts | 3,179,567 | 3,179,567 | ✅ |
| rdma_write_bytes | 0 | 0 | ✅ |
| rx_drops | 0 | 0 | ✅ |

**结论：V2 与 V1 指标数值完全一致，仅多出 pod/namespace/container label。**

### NCCL All-Reduce 性能测试（2 × ml.g6e.8xlarge）

- GPU：NVIDIA L40S（每节点 1 张）
- 网络：EFA（每节点 1 个，25 Gbps）
- 传输协议：EFA RDMA read（通过 aws-ofi-nccl）

| 消息大小 | 算法带宽 | 总线带宽 |
|---------|---------|---------|
| 1 MB | 2.40 GB/s | 2.40 GB/s |
| 4 MB | 3.20 GB/s | 3.20 GB/s |
| 16 MB | 3.12 GB/s | 3.12 GB/s |
| 64 MB | 3.12 GB/s | 3.12 GB/s |
| 128 MB | 3.12 GB/s | 3.12 GB/s |
| 256 MB | 3.12 GB/s | 3.12 GB/s |

峰值总线带宽：**3.12 GB/s ≈ 25 Gbps**（g6e.8xlarge EFA 线速）

### EFA 延迟测试（fi_pingpong）

| 消息大小 | 延迟 |
|---------|------|
| 64 B | 18.85 μs |
| 256 B | 17.09 μs |
| 1 KB | 17.19 μs |
| 4 KB | 17.59 μs |

## 快速开始

### 构建镜像

```bash
docker build -t <your-ecr>/efa_exporter:2.0.0 .
docker push <your-ecr>/efa_exporter:2.0.0
```

### 部署

```bash
# 修改 deploy/daemonset.yaml 中的镜像地址后：
kubectl apply -f deploy/daemonset.yaml
```

### 关键配置说明

| 配置 | 原因 |
|------|------|
| `runAsUser: 0` | kubelet pod-resources socket 权限为 750 root:root |
| `pod-resources` volume | 挂载 kubelet PodResources gRPC socket |
| `hostNetwork: true` | 访问 sysfs 需要 |

### 环境变量

| 变量 | 默认值 | 说明 |
|------|--------|------|
| `KUBELET_SOCKET` | `/var/lib/kubelet/pod-resources/kubelet.sock` | 覆盖 kubelet socket 路径 |

## Prometheus 查询示例

```promql
# 按 Pod 查看 EFA 发送带宽
rate(node_amazonefa_tx_bytes{pod!=""}[5m]) * 8

# 按 namespace 聚合 RDMA 读取吞吐
sum by (namespace) (rate(node_amazonefa_rdma_read_bytes[5m]))

# 检测丢包
node_amazonefa_rx_drops{pod!=""} > 0

# 按 Pod 查看重传率
rate(node_amazonefa_retrans_pkts{pod!=""}[5m])
```

## 与 DCGM Exporter 对比

| | DCGM Exporter | EFA Exporter V2 |
|---|---|---|
| Pod 映射方式 | 内置 `-k` 参数 | Fork 源码加入 PodResources 查询 |
| 映射资源类型 | `nvidia.com/gpu` | `vpc.amazonaws.com/efa` |
| 额外 label | pod, namespace, container | pod, namespace, container |
| 需要 root | 否 | 是（kubelet socket 权限限制） |

## 目录结构

```
efa-exporter-v2/
├── README.md              # 英文文档
├── README_CN.md           # 中文文档
├── amazon_efa_linux.go    # 核心修改：加入 PodResources 映射
├── class_amazon_efa.go    # sysfs 解析（未修改）
├── Dockerfile             # 多阶段构建
├── Makefile
├── deploy/
│   └── daemonset.yaml     # 生产 DaemonSet
├── examples/
│   └── nccl-test-mpijob.yaml  # NCCL 测试 MPIJob 示例
└── reference/
    ├── efa-exporter-ds.yaml    # 原版 V1 DaemonSet（HyperPod 镜像）
    └── efa-exporter-guide.md   # 原版 V1 部署指南
```

## Reference

`reference/` 目录包含原版 EFA exporter V1 的部署文件，使用 HyperPod 提供的镜像（`296578399912.dkr.ecr.ap-southeast-3.amazonaws.com/hyperpod/efa_exporter:1.0.0`），用于对比和回滚。

## License

Apache License 2.0（与上游一致）
