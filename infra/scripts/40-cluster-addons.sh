#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Installs the cluster-level components the app depends on:
#
#   * AWS Load Balancer Controller -> turns our Ingress into a real ALB
#   * metrics-server               -> feeds CPU/memory to the HorizontalPodAutoscalers
#   * Cluster Autoscaler           -> grows/shrinks the node group behind the HPAs
#   * gp3 StorageClass             -> default storage for the MongoDB PVC
#
#   ./infra/scripts/40-cluster-addons.sh
# ---------------------------------------------------------------------------
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../env.sh
source "${SCRIPT_DIR}/../env.sh"

require_cmd aws kubectl helm eksctl jq
require_account

VPC_ID="$(aws eks describe-cluster --name "${CLUSTER_NAME}" --region "${AWS_REGION}" \
          --query 'cluster.resourcesVpcConfig.vpcId' --output text)"

# ---------------------------------------------------------------------------
log "1/4  AWS Load Balancer Controller"
# ---------------------------------------------------------------------------
helm repo add eks https://aws.github.io/eks-charts >/dev/null 2>&1 || true
helm repo update >/dev/null

helm upgrade --install aws-load-balancer-controller eks/aws-load-balancer-controller \
  --namespace kube-system \
  --set clusterName="${CLUSTER_NAME}" \
  --set region="${AWS_REGION}" \
  --set vpcId="${VPC_ID}" \
  --set serviceAccount.create=false \
  --set serviceAccount.name=aws-load-balancer-controller \
  --set replicaCount=2 \
  --wait --timeout 10m
ok "load balancer controller running"

# ---------------------------------------------------------------------------
log "2/4  metrics-server (required by HPA)"
# ---------------------------------------------------------------------------
if kubectl get deployment metrics-server -n kube-system >/dev/null 2>&1; then
  ok "metrics-server already installed"
else
  kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
  kubectl rollout status deployment/metrics-server -n kube-system --timeout=5m
  ok "metrics-server running"
fi

# ---------------------------------------------------------------------------
log "3/4  Cluster Autoscaler"
# ---------------------------------------------------------------------------
helm repo add autoscaler https://kubernetes.github.io/autoscaler >/dev/null 2>&1 || true
helm repo update >/dev/null

helm upgrade --install cluster-autoscaler autoscaler/cluster-autoscaler \
  --namespace kube-system \
  --set autoDiscovery.clusterName="${CLUSTER_NAME}" \
  --set awsRegion="${AWS_REGION}" \
  --set rbac.serviceAccount.create=false \
  --set rbac.serviceAccount.name=cluster-autoscaler \
  --set extraArgs.balance-similar-node-groups=true \
  --set extraArgs.skip-nodes-with-system-pods=false \
  --wait --timeout 10m
ok "cluster autoscaler running"

# ---------------------------------------------------------------------------
log "4/4  gp3 StorageClass (default)"
# ---------------------------------------------------------------------------
kubectl apply -f - <<'EOF'
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: gp3
  annotations:
    storageclass.kubernetes.io/is-default-class: "true"
provisioner: ebs.csi.aws.com
volumeBindingMode: WaitForFirstConsumer
allowVolumeExpansion: true
reclaimPolicy: Retain
parameters:
  type: gp3
  fsType: ext4
  encrypted: "true"
EOF

# The gp2 class EKS ships with is marked default; demote it so PVCs land on gp3.
kubectl patch storageclass gp2 \
  -p '{"metadata":{"annotations":{"storageclass.kubernetes.io/is-default-class":"false"}}}' \
  >/dev/null 2>&1 || true
ok "gp3 is the default StorageClass"

log "Add-ons installed. Next: ./monitoring/setup-monitoring.sh, then deploy with Helm."
kubectl get pods -n kube-system
