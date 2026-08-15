#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Step 5.1 of the brief: create the EKS cluster with eksctl.
#
#   ./infra/scripts/30-create-eks.sh
#
# Renders infra/eksctl-cluster.yaml with the values from infra/env.sh, creates
# the S3 media bucket the IRSA policy references, then builds the cluster.
# Expect this to take 15-20 minutes (CloudFormation is doing the work).
# ---------------------------------------------------------------------------
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=../env.sh
source "${INFRA_DIR}/env.sh"

require_cmd aws eksctl kubectl jq
require_account

if eksctl get cluster --name "${CLUSTER_NAME}" --region "${AWS_REGION}" >/dev/null 2>&1; then
  ok "cluster ${CLUSTER_NAME} already exists — skipping creation"
else
  # The IRSA policy in the cluster config scopes S3 access to this bucket, so
  # it has to exist (or at least be named) before the cluster is built.
  if aws s3api head-bucket --bucket "${S3_BUCKET}" 2>/dev/null; then
    ok "media bucket s3://${S3_BUCKET} already exists"
  else
    log "Creating media bucket s3://${S3_BUCKET}"
    if [[ "${AWS_REGION}" == "us-east-1" ]]; then
      aws s3api create-bucket --bucket "${S3_BUCKET}" --region us-east-1 >/dev/null
    else
      aws s3api create-bucket --bucket "${S3_BUCKET}" --region "${AWS_REGION}" \
        --create-bucket-configuration "LocationConstraint=${AWS_REGION}" >/dev/null
    fi
    aws s3api put-public-access-block --bucket "${S3_BUCKET}" \
      --public-access-block-configuration \
      "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"
    aws s3api put-bucket-encryption --bucket "${S3_BUCKET}" \
      --server-side-encryption-configuration \
      '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'
    # The SPA fetches media directly from presigned S3 URLs, so CORS matters.
    aws s3api put-bucket-cors --bucket "${S3_BUCKET}" --cors-configuration '{
      "CORSRules": [{
        "AllowedHeaders": ["*"],
        "AllowedMethods": ["GET","PUT","POST","HEAD"],
        "AllowedOrigins": ["*"],
        "ExposeHeaders": ["ETag","Content-Range","Accept-Ranges"],
        "MaxAgeSeconds": 3000
      }]
    }'
    ok "bucket ready"
  fi

  RENDERED="$(mktemp /tmp/eksctl-cluster.XXXXXX.yaml)"
  log "Rendering cluster manifest -> ${RENDERED}"
  sed \
    -e "s|__CLUSTER_NAME__|${CLUSTER_NAME}|g" \
    -e "s|__AWS_REGION__|${AWS_REGION}|g" \
    -e "s|__K8S_VERSION__|${K8S_VERSION}|g" \
    -e "s|__PROJECT__|${PROJECT}|g" \
    -e "s|__ENVIRONMENT__|${ENVIRONMENT}|g" \
    -e "s|__K8S_NAMESPACE__|${K8S_NAMESPACE}|g" \
    -e "s|__NODEGROUP_NAME__|${NODEGROUP_NAME}|g" \
    -e "s|__NODE_INSTANCE_TYPE__|${NODE_INSTANCE_TYPE}|g" \
    -e "s|__NODE_MIN__|${NODE_MIN}|g" \
    -e "s|__NODE_MAX__|${NODE_MAX}|g" \
    -e "s|__NODE_DESIRED__|${NODE_DESIRED}|g" \
    -e "s|__S3_BUCKET__|${S3_BUCKET}|g" \
    "${INFRA_DIR}/eksctl-cluster.yaml" > "${RENDERED}"

  log "Creating cluster ${CLUSTER_NAME} — this takes 15-20 minutes"
  eksctl create cluster -f "${RENDERED}"
  ok "cluster created"
fi

log "Writing kubeconfig"
aws eks update-kubeconfig --name "${CLUSTER_NAME}" --region "${AWS_REGION}"

log "Cluster nodes"
kubectl get nodes -o wide

log "Creating application namespace ${K8S_NAMESPACE}"
kubectl create namespace "${K8S_NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -

log "Cluster ready. Next: ./infra/scripts/40-cluster-addons.sh"
