#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Single source of truth for every name this project creates in AWS.
# Every script under infra/, monitoring/ and chatops/ sources this file.
# Override any value by exporting it before you run a script, e.g.
#     AWS_REGION=us-east-1 ./infra/scripts/30-create-eks.sh
# ---------------------------------------------------------------------------
set -euo pipefail

# ---- core ------------------------------------------------------------------
export AWS_REGION="${AWS_REGION:-ap-south-1}"
export PROJECT="${PROJECT:-streamingapp}"
export ENVIRONMENT="${ENVIRONMENT:-prod}"

# ---- EKS -------------------------------------------------------------------
export CLUSTER_NAME="${CLUSTER_NAME:-${PROJECT}-eks}"
export K8S_VERSION="${K8S_VERSION:-1.30}"
export K8S_NAMESPACE="${K8S_NAMESPACE:-${PROJECT}}"
export NODEGROUP_NAME="${NODEGROUP_NAME:-${PROJECT}-ng}"
# CPU architecture of the worker nodes. This MUST match the architecture the
# container images were built for, or pods fail with "exec format error" —
# which surfaces as a crash loop with no useful message.
#
#   x86_64  -> t3.medium   (build with --platform linux/amd64)
#   arm64   -> t4g.medium  (native on an Apple Silicon Mac, ~10% cheaper)
#
# Building on Apple Silicon? Use arm64 and skip cross-compilation entirely.
export NODE_ARCH="${NODE_ARCH:-x86_64}"
if [[ "${NODE_ARCH}" == "arm64" ]]; then
  export NODE_INSTANCE_TYPE="${NODE_INSTANCE_TYPE:-t4g.medium}"
  export DOCKER_PLATFORM="${DOCKER_PLATFORM:-linux/arm64}"
else
  export NODE_INSTANCE_TYPE="${NODE_INSTANCE_TYPE:-t3.medium}"
  export DOCKER_PLATFORM="${DOCKER_PLATFORM:-linux/amd64}"
fi
export NODE_MIN="${NODE_MIN:-2}"
export NODE_MAX="${NODE_MAX:-5}"
export NODE_DESIRED="${NODE_DESIRED:-3}"

# ---- container images ------------------------------------------------------
# Repository short names; the full URI is <acct>.dkr.ecr.<region>.amazonaws.com/<name>
export ECR_REPOS=(
  "${PROJECT}/frontend"
  "${PROJECT}/auth-service"
  "${PROJECT}/streaming-service"
  "${PROJECT}/admin-service"
  "${PROJECT}/chat-service"
)

# ---- application ------------------------------------------------------------
export HELM_RELEASE="${HELM_RELEASE:-${PROJECT}}"
export S3_BUCKET="${S3_BUCKET:-${PROJECT}-media-$(whoami 2>/dev/null || echo user)}"

# ---- ChatOps ----------------------------------------------------------------
export SNS_TOPIC_DEPLOY="${SNS_TOPIC_DEPLOY:-${PROJECT}-deployments}"
export SNS_TOPIC_ALARMS="${SNS_TOPIC_ALARMS:-${PROJECT}-alarms}"

# ---- derived (do not edit) --------------------------------------------------
AWS_ACCOUNT_ID="${AWS_ACCOUNT_ID:-$(aws sts get-caller-identity --query Account --output text 2>/dev/null || true)}"
export AWS_ACCOUNT_ID
export ECR_REGISTRY="${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"

# ---- pretty logging helpers -------------------------------------------------
log()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m  ✔\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m  !\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m  ✘\033[0m %s\n' "$*" >&2; exit 1; }

require_cmd() {
  for c in "$@"; do
    command -v "$c" >/dev/null 2>&1 || die "required command '$c' not found in PATH — run infra/scripts/00-prereqs.sh"
  done
}

require_account() {
  [[ -n "${AWS_ACCOUNT_ID}" ]] || die "could not resolve AWS account — run 'aws configure' first (see infra/scripts/10-configure-aws.sh)"
}
