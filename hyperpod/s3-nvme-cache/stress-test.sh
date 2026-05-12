#!/bin/bash
# 压力测试：反复删除/创建 Pod + 删除 Mountpoint Pod，尝试复现 FailedMount
set -o pipefail

LOG="/tmp/s3-cache-stress.log"
> $LOG

echo "=== 开始压力测试 $(date) ===" | tee -a $LOG

# 测试1: 反复 scale 0 → 5，看 mount 是否 hang
for i in $(seq 1 5); do
  echo "--- Round $i: scale 0 → 5 ---" | tee -a $LOG
  kubectl scale deployment s3-cache-stress --replicas=0
  sleep 5
  kubectl scale deployment s3-cache-stress --replicas=5
  sleep 15
  kubectl get pods -l app=s3-cache-stress --no-headers | tee -a $LOG
  # 检查是否有非 Running 的 pod
  NOT_READY=$(kubectl get pods -l app=s3-cache-stress --no-headers | grep -v Running | wc -l)
  echo "Not ready pods: $NOT_READY" | tee -a $LOG
done

# 测试2: 在 Pod 读取时删除 Mountpoint Pod
echo "--- Test 2: 删除 Mountpoint Pod ---" | tee -a $LOG
kubectl scale deployment s3-cache-stress --replicas=5
sleep 15

# 启动后台读取
for pod in $(kubectl get pods -l app=s3-cache-stress -o name | head -3); do
  kubectl exec $pod -- bash -c "for j in \$(seq 1 10); do dd if=/data/s3/test-20gb.bin of=/dev/null bs=1M 2>/dev/null; done" &
done

sleep 3
# 删除 mountpoint pod
MP_POD=$(kubectl get pods -n mount-s3 -o name | head -1)
echo "Deleting $MP_POD while pods are reading..." | tee -a $LOG
kubectl delete $MP_POD -n mount-s3 --force 2>&1 | tee -a $LOG

sleep 10
echo "--- Pods after MP deletion ---" | tee -a $LOG
kubectl get pods -l app=s3-cache-stress --no-headers | tee -a $LOG
kubectl get pods -n mount-s3 --no-headers | tee -a $LOG

# 等后台读取完成
wait 2>/dev/null

# 测试3: 删除 MP Pod 后立即创建新 workload Pod
echo "--- Test 3: 删 MP Pod + 立即创建新 Pod ---" | tee -a $LOG
sleep 10
MP_POD=$(kubectl get pods -n mount-s3 -o name | head -1)
echo "Deleting $MP_POD and immediately scaling up..." | tee -a $LOG
kubectl delete $MP_POD -n mount-s3 --force &
kubectl scale deployment s3-cache-stress --replicas=0
sleep 2
kubectl scale deployment s3-cache-stress --replicas=5
sleep 30

echo "--- Final status ---" | tee -a $LOG
kubectl get pods -l app=s3-cache-stress --no-headers | tee -a $LOG
kubectl get pods -n mount-s3 --no-headers | tee -a $LOG

# 检查 events 中是否有 FailedMount
echo "--- FailedMount events ---" | tee -a $LOG
kubectl get events --field-selector reason=FailedMount --sort-by='.lastTimestamp' 2>/dev/null | tail -20 | tee -a $LOG

echo "=== 测试完成 $(date) ===" | tee -a $LOG
