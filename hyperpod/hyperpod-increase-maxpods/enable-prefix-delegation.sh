#!/bin/bash
# Enable VPC CNI prefix delegation for HyperPod EKS cluster
# Uses EKS managed addon API so config persists across addon updates
#
# Usage: ./enable-prefix-delegation.sh <EKS_CLUSTER_NAME> <REGION>

set -ex

CLUSTER_NAME="${1:?Usage: $0 <EKS_CLUSTER_NAME> <REGION>}"
REGION="${2:?Usage: $0 <EKS_CLUSTER_NAME> <REGION>}"

echo "Updating VPC CNI addon for cluster: $CLUSTER_NAME in $REGION..."

aws eks update-addon \
  --cluster-name "$CLUSTER_NAME" \
  --addon-name vpc-cni \
  --region "$REGION" \
  --resolve-conflicts OVERWRITE \
  --configuration-values '{"env":{"ENABLE_PREFIX_DELEGATION":"true","WARM_PREFIX_TARGET":"2","WARM_IP_TARGET":"5","MINIMUM_IP_TARGET":"30"}}'

echo "Waiting for addon update..."
aws eks wait addon-active \
  --cluster-name "$CLUSTER_NAME" \
  --addon-name vpc-cni \
  --region "$REGION" 2>/dev/null || sleep 30

echo "Done. Verify with:"
echo "  aws eks describe-addon --cluster-name $CLUSTER_NAME --addon-name vpc-cni --region $REGION --query 'addon.configurationValues'"
