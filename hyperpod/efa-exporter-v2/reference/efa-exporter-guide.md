# EFA Metrics Exporter 部署指南

## 概述

EFA (Elastic Fabric Adapter) 指标通过读取 Linux sysfs 路径 `/sys/class/infiniband/<device>/ports/<port>/hw_counters/` 获取，以 Prometheus 格式暴露，供 OpenTelemetry Collector 采集。

### 可用指标

| 指标名 | 类型 | 说明 |
|--------|------|------|
| `node_amazonefa_info` | gauge | EFA 设备信息，值恒为 1 |
| `node_amazonefa_tx_bytes` | counter | 发送字节数 |
| `node_amazonefa_rx_bytes` | counter | 接收字节数 |
| `node_amazonefa_tx_pkts` | counter | 发送包数 |
| `node_amazonefa_rx_pkts` | counter | 接收包数 |
| `node_amazonefa_rx_drops` | counter | 接收丢包数 |
| `node_amazonefa_rdma_read_bytes` | counter | RDMA 读字节数 |
| `node_amazonefa_rdma_write_bytes` | counter | RDMA 写字节数 |
| `node_amazonefa_rdma_read_wrs` | counter | RDMA 读请求数 |
| `node_amazonefa_rdma_write_wrs` | counter | RDMA 写请求数 |
| `node_amazonefa_rdma_read_wr_err` | counter | RDMA 读错误数 |
| `node_amazonefa_rdma_write_wr_err` | counter | RDMA 写错误数 |
| `node_amazonefa_rdma_read_resp_bytes` | counter | RDMA 读响应字节数 |
| `node_amazonefa_rdma_write_recv_bytes` | counter | RDMA 写接收字节数 |
| `node_amazonefa_send_bytes` | counter | 发送字节数 (SQ) |
| `node_amazonefa_recv_bytes` | counter | 接收字节数 (RQ) |
| `node_amazonefa_send_wrs` | counter | 发送请求数 (SQ) |
| `node_amazonefa_recv_wrs` | counter | 接收请求数 (RQ) |
| `node_amazonefa_lifespan` | counter | 端口生命周期 |

> sysfs 中还有 `retrans_bytes`、`retrans_pkts`、`retrans_timeout_events`、`impaired_remote_conn_events`、`unresponsive_remote_events` 等计数器，但 HyperPod 镜像未暴露这些指标。如需采集，参考下方"自建镜像"章节。

---

## 方案一：复用 HyperPod EFA Exporter 镜像（推荐）

直接使用 HyperPod 提供的镜像，本质是一个只启用 `amazonefa` collector 的 prometheus node_exporter。

### DaemonSet YAML

```yaml
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: efa-exporter
  namespace: default
  labels:
    app: efa-exporter
spec:
  selector:
    matchLabels:
      app: efa-exporter
  template:
    metadata:
      labels:
        app: efa-exporter
    spec:
      hostNetwork: true
      hostPID: true
      nodeSelector:
        kubernetes.io/os: linux
      affinity:
        nodeAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            nodeSelectorTerms:
              - matchExpressions:
                  - key: node.kubernetes.io/instance-type
                    operator: In
                    values:
                      - ml.g5.8xlarge
                      - ml.p5en.48xlarge
                      - ml.p5e.48xlarge
                      - ml.p6-b300.48xlarge
                      - ml.p5.48xlarge
      tolerations:
        - operator: Exists
      containers:
        - name: efa-exporter
          image: 296578399912.dkr.ecr.ap-southeast-3.amazonaws.com/hyperpod/efa_exporter:1.0.0
          args:
            - --path.procfs=/host/proc
            - --path.sysfs=/host/sys
            - --path.rootfs=/host/root
            - --web.listen-address=0.0.0.0:9119
            - --collector.disable-defaults
            - --collector.amazonefa
          ports:
            - containerPort: 9119
              name: metrics
          resources:
            requests:
              cpu: 100m
              memory: 128Mi
            limits:
              cpu: 200m
              memory: 256Mi
          securityContext:
            readOnlyRootFilesystem: true
          volumeMounts:
            - name: proc
              mountPath: /host/proc
              readOnly: true
            - name: sys
              mountPath: /host/sys
              readOnly: true
            - name: root
              mountPath: /host/root
              readOnly: true
              mountPropagation: HostToContainer
      securityContext:
        fsGroup: 65534
        runAsGroup: 65534
        runAsNonRoot: true
        runAsUser: 65534
      volumes:
        - name: proc
          hostPath:
            path: /proc
        - name: sys
          hostPath:
            path: /sys
        - name: root
          hostPath:
            path: /
```

### 部署与验证

```bash
# 部署
kubectl apply -f efa-exporter-ds.yaml

# 检查 pod 状态
kubectl get pods -l app=efa-exporter -o wide

# 验证指标
kubectl port-forward pod/<pod-name> 19119:9119
curl http://127.0.0.1:19119/metrics | grep node_amazonefa
```

### 关键配置说明

| 配置 | 说明 |
|------|------|
| `hostNetwork: true` | 使用宿主机网络，OTel 可直接通过 `<node_ip>:9119` 采集 |
| `hostPID: true` | 访问宿主机进程信息 |
| `--collector.disable-defaults` | 禁用所有默认 collector，只采 EFA |
| `--collector.amazonefa` | 启用 Amazon EFA collector |
| 挂载 `/proc`、`/sys`、`/` | 让容器内 node_exporter 读取宿主机 sysfs |
| `nodeAffinity` | 只在有 EFA 的机型上调度 |

### OTel Collector 配置示例

```yaml
receivers:
  prometheus:
    config:
      scrape_configs:
        - job_name: efa-exporter
          scrape_interval: 30s
          static_configs:
            - targets: ["<node_ip>:9119"]
```

---

## 方案二：自建镜像

当需要采集 HyperPod 镜像未暴露的指标（如 `retrans_pkts`、`unresponsive_remote_events`）时，可自建采集程序。

### Go 实现

```go
package main

import (
	"fmt"
	"log"
	"net/http"
	"os"
	"path/filepath"
	"strings"
)

var sysfsRoot = "/host/sys"

func main() {
	if v := os.Getenv("SYSFS_ROOT"); v != "" {
		sysfsRoot = v
	}
	http.HandleFunc("/metrics", metricsHandler)
	log.Fatal(http.ListenAndServe(":9119", nil))
}

func metricsHandler(w http.ResponseWriter, r *http.Request) {
	devices, _ := filepath.Glob(filepath.Join(sysfsRoot, "class/infiniband/*"))
	for _, dev := range devices {
		devName := filepath.Base(dev)
		ports, _ := filepath.Glob(filepath.Join(dev, "ports/*"))
		for _, port := range ports {
			portNum := filepath.Base(port)
			counters, _ := filepath.Glob(filepath.Join(port, "hw_counters/*"))
			for _, c := range counters {
				name := filepath.Base(c)
				val, err := os.ReadFile(c)
				if err != nil {
					continue
				}
				fmt.Fprintf(w, "efa_%s{device=%q,port=%q} %s\n",
					name, devName, portNum, strings.TrimSpace(string(val)))
			}
		}
	}
}
```

### Dockerfile

```dockerfile
FROM golang:1.22-alpine AS build
WORKDIR /app
COPY main.go .
RUN CGO_ENABLED=0 go build -o efa-exporter main.go

FROM scratch
COPY --from=build /app/efa-exporter /efa-exporter
ENTRYPOINT ["/efa-exporter"]
```

### 构建与推送

```bash
# 构建
docker build -t efa-exporter:custom .

# 推送到 ECR
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
REGION=ap-southeast-3
REPO=$ACCOUNT_ID.dkr.ecr.$REGION.amazonaws.com/efa-exporter

aws ecr create-repository --repository-name efa-exporter --region $REGION
aws ecr get-login-password --region $REGION | docker login --username AWS --password-stdin $REPO
docker tag efa-exporter:custom $REPO:custom
docker push $REPO:custom
```

然后将 DaemonSet 中的 `image` 替换为你的镜像地址，`args` 去掉（自建程序不需要 node_exporter 参数），即可部署。

### 自建方案优势

- 可采集所有 sysfs hw_counters（包括 `retrans_*`、`impaired_*`、`unresponsive_*`）
- 可自定义指标名称、标签
- 可添加额外逻辑（如速率计算、告警阈值）
