#!/bin/bash
set -e

CLUSTER_NAME=${1:?"Usage: $0 <cluster-name> <region>"}
REGION=${2:?"Usage: $0 <cluster-name> <region>"}
NAMESPACE="vela-system"
SA_NAME="eks-admin-sa"
SECRET_NAME="eks-admin-token"
OUTPUT_FILE="kubeconfig-${CLUSTER_NAME}.yaml"

# 更新 kubeconfig 连接集群
aws eks update-kubeconfig --region "$REGION" --name "$CLUSTER_NAME"

# 创建 namespace
kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

# 创建 ServiceAccount
kubectl create serviceaccount "$SA_NAME" -n "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f -

# 创建 ClusterRoleBinding
kubectl create clusterrolebinding "${SA_NAME}-binding" \
  --clusterrole=cluster-admin \
  --serviceaccount="${NAMESPACE}:${SA_NAME}" \
  --dry-run=client -o yaml | kubectl apply -f -

# 创建长期 token Secret
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: Secret
metadata:
  name: ${SECRET_NAME}
  namespace: ${NAMESPACE}
  annotations:
    kubernetes.io/service-account.name: ${SA_NAME}
type: kubernetes.io/service-account-token
EOF

# 等待 token 生成
sleep 3

# 获取集群信息
SERVER=$(kubectl config view --raw -o jsonpath="{.clusters[?(@.name==\"arn:aws:eks:${REGION}:$(aws sts get-caller-identity --query Account --output text):cluster/${CLUSTER_NAME}\")].cluster.server}")
CA_DATA=$(kubectl config view --raw -o jsonpath="{.clusters[?(@.name==\"arn:aws:eks:${REGION}:$(aws sts get-caller-identity --query Account --output text):cluster/${CLUSTER_NAME}\")].cluster.certificate-authority-data}")
TOKEN=$(kubectl get secret "$SECRET_NAME" -n "$NAMESPACE" -o jsonpath='{.data.token}' | base64 -d)
CLUSTER_ARN="arn:aws:eks:${REGION}:$(aws sts get-caller-identity --query Account --output text):cluster/${CLUSTER_NAME}"

# 生成 kubeconfig
cat > "$OUTPUT_FILE" <<EOF
apiVersion: v1
clusters:
- cluster:
    certificate-authority-data: ${CA_DATA}
    server: ${SERVER}
  name: ${CLUSTER_ARN}
contexts:
- context:
    cluster: ${CLUSTER_ARN}
    namespace: ${NAMESPACE}
    user: ${SA_NAME}
  name: eks-admin-context
current-context: eks-admin-context
kind: Config
users:
- name: ${SA_NAME}
  user:
    token: ${TOKEN}
EOF

echo "✅ kubeconfig 已生成: ${OUTPUT_FILE}"
echo "使用方式: kubectl --kubeconfig ${OUTPUT_FILE} get nodes"
