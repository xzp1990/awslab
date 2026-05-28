# EKS 集群 ServiceAccount Token Kubeconfig 生成工具

## 简介

该脚本用于为 EKS 集群创建基于 ServiceAccount 长期 Token 的 kubeconfig 文件。生成的 kubeconfig 不依赖 AWS CLI/IAM 认证，可直接分发给其他人或系统使用。

## 前置条件

- 已安装 `aws` CLI 并配置好凭证
- 已安装 `kubectl`
- 当前 IAM 身份对目标 EKS 集群有管理权限

## 脚本

```bash
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
```

## 使用方式

### 1. 保存脚本并赋予执行权限

```bash
chmod +x create-eks-sa-kubeconfig.sh
```

### 2. 执行脚本

```bash
./create-eks-sa-kubeconfig.sh <集群名称> <区域>
```

示例：

```bash
./create-eks-sa-kubeconfig.sh sagemaker-test-inference-g8-dfd381d9-eks us-west-2
```

### 3. 使用生成的 kubeconfig

```bash
# 方式1: 通过 --kubeconfig 参数
kubectl --kubeconfig kubeconfig-sagemaker-test-inference-g8-dfd381d9-eks.yaml get pods -A

# 方式2: 通过环境变量
export KUBECONFIG=kubeconfig-sagemaker-test-inference-g8-dfd381d9-eks.yaml
kubectl get pods -A

# 方式3: 分发到其他机器
scp kubeconfig-xxx.yaml user@remote-host:~/.kube/config
```

## 注意事项

- 生成的 token 是**长期有效**的，不会过期，请妥善保管
- ServiceAccount 绑定了 `cluster-admin` 角色，拥有集群完全管理权限
- 如需限制权限，可将脚本中的 `cluster-admin` 替换为自定义 ClusterRole
- 脚本可重复执行（幂等），不会重复创建资源
