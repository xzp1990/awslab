# EFA Exporter v2 - Pod-Level EFA Metrics for Kubernetes

Fork of [aws-samples/awsome-distributed-training/efa-node-exporter](https://github.com/awslabs/awsome-distributed-ai/tree/main/4.validation_and_observability/3.efa-node-exporter) with **Pod-level device mapping** via kubelet PodResources API.

## Problem

The original EFA exporter only reports device-level metrics:

```
node_amazonefa_tx_bytes{device="rdmap47s0",port="1"} 24167820008
```

You cannot tell which Pod is using the EFA device. This makes per-job network monitoring impossible.

## Solution

EFA Exporter v2 queries the kubelet PodResources API to map `vpc.amazonaws.com/efa` devices to Pods, injecting `pod`, `namespace`, and `container` labels:

```
node_amazonefa_tx_bytes{device="rdmap47s0",port="1",pod="nccl-test-g6e-worker-0",namespace="default",container="nccl-worker"} 24167820008
```

## Architecture

```
┌──────────────────────────────────────────────────────┐
│  EFA Exporter v2 (DaemonSet, per EFA node)           │
│                                                       │
│  ┌──────────────────┐    ┌─────────────────────────┐ │
│  │ amazonefa         │    │ PodResources Client     │ │
│  │ collector         │    │ (gRPC, polls every 15s) │ │
│  │ reads /sys/class/ │    │ queries kubelet socket  │ │
│  │ infiniband/       │    │ maps EFA device → pod   │ │
│  └────────┬──────────┘    └───────────┬─────────────┘ │
│           └──────── merge labels ─────┘               │
│                       │                                │
│               /metrics (port 9119)                     │
└──────────────────────────────────────────────────────┘
```

## Changes from Upstream

Only `amazon_efa_linux.go` is modified:

1. Added PodResources gRPC client (background goroutine, 15s poll interval)
2. Queries `vpc.amazonaws.com/efa` device assignments from kubelet
3. Extended metric labels from `[device, port]` to `[device, port, pod, namespace, container]`
4. When no Pod uses the device, labels are empty strings

## Validation

### Metric Value Consistency (V1 vs V2)

Both versions ran simultaneously on the same node during NCCL all_reduce test:

| Metric | V1 (original) | V2 (with pod labels) | Match |
|--------|---------------|---------------------|-------|
| rdma_read_bytes | 2.378e+10 | 2.378e+10 | ✅ |
| rdma_read_wrs | 22,680 | 22,680 | ✅ |
| tx_bytes | 2.417e+10 | 2.417e+10 | ✅ |
| rx_bytes | 2.417e+10 | 2.417e+10 | ✅ |
| tx_pkts | 3,179,567 | 3,179,567 | ✅ |
| rx_pkts | 3,179,567 | 3,179,567 | ✅ |
| rdma_write_bytes | 0 | 0 | ✅ |
| rx_drops | 0 | 0 | ✅ |

**Conclusion: V2 produces identical metric values to V1. Only additional labels differ.**

### NCCL All-Reduce Benchmark (2 × ml.g6e.8xlarge)

- GPU: NVIDIA L40S (1 per node)
- Network: EFA (1 per node, 25 Gbps)
- Transport: EFA RDMA read via aws-ofi-nccl

| Message Size | Algorithm BW | Bus BW |
|-------------|-------------|--------|
| 1 MB | 2.40 GB/s | 2.40 GB/s |
| 4 MB | 3.20 GB/s | 3.20 GB/s |
| 16 MB | 3.12 GB/s | 3.12 GB/s |
| 64 MB | 3.12 GB/s | 3.12 GB/s |
| 128 MB | 3.12 GB/s | 3.12 GB/s |
| 256 MB | 3.12 GB/s | 3.12 GB/s |

Peak bus bandwidth: **3.12 GB/s ≈ 25 Gbps** (line rate for g6e.8xlarge EFA)

### EFA Latency (fi_pingpong)

| Message Size | Latency |
|-------------|---------|
| 64 B | 18.85 μs |
| 256 B | 17.09 μs |
| 1 KB | 17.19 μs |
| 4 KB | 17.59 μs |

## Quick Start

### Build

```bash
docker build -t <your-ecr>/efa_exporter:2.0.0 .
docker push <your-ecr>/efa_exporter:2.0.0
```

### Deploy

```bash
# Update image in deploy/daemonset.yaml, then:
kubectl apply -f deploy/daemonset.yaml
```

### Key Requirements

| Config | Reason |
|--------|--------|
| `runAsUser: 0` | kubelet pod-resources socket is 750 root:root |
| `pod-resources` volume | Mount kubelet PodResources gRPC socket |
| `hostNetwork: true` | Required for sysfs access |

### Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `KUBELET_SOCKET` | `/var/lib/kubelet/pod-resources/kubelet.sock` | Override kubelet socket path |
| `SYSFS_ROOT` | (from `--path.sysfs`) | Sysfs mount point |

## Prometheus Queries

```promql
# Per-pod EFA send bandwidth
rate(node_amazonefa_tx_bytes{pod!=""}[5m]) * 8

# Per-namespace RDMA read throughput
sum by (namespace) (rate(node_amazonefa_rdma_read_bytes[5m]))

# Detect packet drops
node_amazonefa_rx_drops{pod!=""} > 0

# Per-pod retransmission rate
rate(node_amazonefa_retrans_pkts{pod!=""}[5m])
```

## Comparison with DCGM Exporter

| | DCGM Exporter | EFA Exporter V2 |
|---|---|---|
| Pod mapping | Built-in (`-k` flag) | Fork with PodResources query |
| Resource type | `nvidia.com/gpu` | `vpc.amazonaws.com/efa` |
| Additional labels | pod, namespace, container | pod, namespace, container |
| Requires root | No | Yes (kubelet socket permission) |

## File Structure

```
efa-exporter-v2/
├── README.md
├── amazon_efa_linux.go    # Modified collector with PodResources mapping
├── class_amazon_efa.go    # Sysfs parser (unchanged from upstream)
├── Dockerfile             # Multi-stage build
├── Makefile
├── deploy/
│   └── daemonset.yaml     # Production DaemonSet
├── examples/
│   └── nccl-test-mpijob.yaml  # NCCL benchmark MPIJob
└── reference/
    ├── efa-exporter-ds.yaml    # Original V1 DaemonSet (HyperPod image)
    └── efa-exporter-guide.md   # Original V1 deployment guide
```

## Reference

The `reference/` directory contains the original EFA exporter V1 deployment files using the HyperPod-provided image (`296578399912.dkr.ecr.ap-southeast-3.amazonaws.com/hyperpod/efa_exporter:1.0.0`). These are kept for comparison and rollback purposes.

## License

Apache License 2.0 (same as upstream)
