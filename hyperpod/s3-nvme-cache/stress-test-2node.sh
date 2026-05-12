#!/bin/bash
# 两节点压测：反复创建/删除 Deployment + 删除 Mountpoint Pod，观察 mount-s3 ns 中的 error pods
set -o pipefail

echo "=== 压测开始 $(date) ==="
echo ""

# 先预热缓存
echo "--- 预热两台节点缓存 ---"
for pod in $(kubectl get pods -l app=s3-cache-test -o name); do
  kubectl exec $pod -- dd if=/data/s3/test-20gb.bin of=/dev/null bs=1M 2>/dev/null &
done
wait
echo "预热完成"

# 创建 Deployment 用于压测
cat <<EOF | kubectl apply -f -
apiVersion: apps/v1
kind: Deployment
metadata:
  name: s3-stress
spec:
  replicas: 8
  selector:
    matchLabels:
      app: s3-stress
  template:
    metadata:
      labels:
        app: s3-stress
    spec:
      nodeSelector:
        node.kubernetes.io/instance-type: ml.g5.8xlarge
      tolerations:
        - key: nvidia.com/gpu
          operator: Equal
          value: "true"
          effect: NoSchedule
      containers:
        - name: app
          image: amazonlinux:2023
          command: ["bash", "-c", "while true; do dd if=/data/s3/test-20gb.bin of=/dev/null bs=1M 2>/dev/null; done"]
          volumeMounts:
            - name: s3-vol
              mountPath: /data/s3
      volumes:
        - name: s3-vol
          persistentVolumeClaim:
            claimName: s3-pvc-cached
EOF

echo "等待 8 replicas 启动..."
sleep 30
kubectl get pods -l app=s3-stress -o wide --no-headers
echo ""

# 压测循环
for round in $(seq 1 10); do
  echo "=== Round $round/10 $(date +%H:%M:%S) ==="

  # 随机操作
  case $((round % 4)) in
    0)
      echo "操作: scale 0 → 8"
      kubectl scale deployment s3-stress --replicas=0
      sleep 3
      kubectl scale deployment s3-stress --replicas=8
      ;;
    1)
      echo "操作: 删除所有 mountpoint pods"
      kubectl delete pods -n mount-s3 --all --force 2>/dev/null
      ;;
    2)
      echo "操作: scale 0 → 8 + 同时删 mountpoint pods"
      kubectl scale deployment s3-stress --replicas=0
      sleep 2
      kubectl delete pods -n mount-s3 --all --force 2>/dev/null &
      kubectl scale deployment s3-stress --replicas=8
      wait
      ;;
    3)
      echo "操作: 删除随机 stress pods"
      kubectl get pods -l app=s3-stress -o name | shuf | head -4 | xargs kubectl delete --force 2>/dev/null
      ;;
  esac

  sleep 15

  # 收集状态
  echo "mount-s3 pods:"
  kubectl get pods -n mount-s3 --no-headers 2>/dev/null
  ERROR_COUNT=$(kubectl get pods -n mount-s3 --no-headers 2>/dev/null | grep -cE "Error|CrashLoop|Failed" || true)
  PENDING_COUNT=$(kubectl get pods -n mount-s3 --no-headers 2>/dev/null | grep -c "Pending" || true)
  TOTAL_MP=$(kubectl get pods -n mount-s3 --no-headers 2>/dev/null | wc -l)
  echo "→ mount-s3: total=$TOTAL_MP error=$ERROR_COUNT pending=$PENDING_COUNT"
  echo ""
done

# 最终状态
echo "=== 最终状态 ==="
echo "--- stress pods ---"
kubectl get pods -l app=s3-stress -o wide --no-headers
echo ""
echo "--- mount-s3 pods (全部) ---"
kubectl get pods -n mount-s3 --no-headers
echo ""
echo "--- mount-s3 中 Error/Failed pods ---"
kubectl get pods -n mount-s3 --no-headers | grep -E "Error|CrashLoop|Failed" || echo "(无)"
echo ""
echo "--- FailedMount events (最近) ---"
kubectl get events --field-selector reason=FailedMount --sort-by='.lastTimestamp' 2>/dev/null | tail -10
echo ""
echo "=== 压测结束 $(date) ==="
