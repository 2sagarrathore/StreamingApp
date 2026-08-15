#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Step 5.2 of the brief: deploy the stack to EKS with Helm.
#
#   ./infra/scripts/60-deploy.sh                 # deploy :latest
#   IMAGE_TAG=build-42 ./infra/scripts/60-deploy.sh
#   ./infra/scripts/60-deploy.sh --dry-run       # render without applying
#
# Secrets: generated once and stored in a Kubernetes Secret. On subsequent
# runs the existing values are reused so a redeploy never invalidates every
# user's session token or locks the app out of its own database.
# ---------------------------------------------------------------------------
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
# shellcheck source=../env.sh
source "${SCRIPT_DIR}/../env.sh"

require_cmd aws kubectl helm jq openssl
require_account

CHART="${REPO_ROOT}/helm/streamingapp"
IMAGE_TAG="${IMAGE_TAG:-latest}"
EXTRA_ARGS=()
[[ "${1:-}" == "--dry-run" ]] && EXTRA_ARGS+=(--dry-run --debug)

log "Refreshing kubeconfig for ${CLUSTER_NAME}"
aws eks update-kubeconfig --name "${CLUSTER_NAME}" --region "${AWS_REGION}" >/dev/null
kubectl create namespace "${K8S_NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f - >/dev/null

# ---- reuse existing secrets, or mint new ones on first install -------------
SECRET_NAME="${HELM_RELEASE}-secrets"
MONGO_SECRET_NAME="${HELM_RELEASE}-mongodb"

read_secret_key() {  # $1=secret $2=key
  kubectl get secret "$1" -n "${K8S_NAMESPACE}" -o jsonpath="{.data.$2}" 2>/dev/null \
    | base64 -d 2>/dev/null || true
}

JWT_SECRET="${JWT_SECRET:-$(read_secret_key "${SECRET_NAME}" JWT_SECRET)}"
if [[ -z "${JWT_SECRET}" ]]; then
  JWT_SECRET="$(openssl rand -hex 32)"
  log "Generated a new JWT signing secret"
else
  ok "reusing the existing JWT secret"
fi

MONGO_PASSWORD="${MONGO_PASSWORD:-$(read_secret_key "${MONGO_SECRET_NAME}" MONGO_INITDB_ROOT_PASSWORD)}"
if [[ -z "${MONGO_PASSWORD}" ]]; then
  MONGO_PASSWORD="$(openssl rand -hex 24)"
  log "Generated a new MongoDB root password"
else
  ok "reusing the existing MongoDB password"
fi

# ---- IRSA role created by eksctl -------------------------------------------
IRSA_ROLE_ARN="arn:aws:iam::${AWS_ACCOUNT_ID}:role/${PROJECT}-app-irsa"
if aws iam get-role --role-name "${PROJECT}-app-irsa" >/dev/null 2>&1; then
  ok "IRSA role found: ${IRSA_ROLE_ARN}"
else
  warn "IRSA role ${PROJECT}-app-irsa not found — pods will fall back to node credentials for S3"
  IRSA_ROLE_ARN=""
fi

log "Deploying ${HELM_RELEASE} (image tag: ${IMAGE_TAG})"
helm upgrade --install "${HELM_RELEASE}" "${CHART}" \
  --namespace "${K8S_NAMESPACE}" \
  --create-namespace \
  --set global.image.registry="${ECR_REGISTRY}" \
  --set global.image.tag="${IMAGE_TAG}" \
  --set global.awsRegion="${AWS_REGION}" \
  --set config.awsS3Bucket="${S3_BUCKET}" \
  --set secrets.jwtSecret="${JWT_SECRET}" \
  --set mongodb.auth.rootPassword="${MONGO_PASSWORD}" \
  ${IRSA_ROLE_ARN:+--set serviceAccount.annotations."eks\.amazonaws\.com/role-arn"="${IRSA_ROLE_ARN}"} \
  --atomic \
  --timeout 12m \
  "${EXTRA_ARGS[@]}"

[[ "${1:-}" == "--dry-run" ]] && { ok "dry run complete"; exit 0; }

log "Rollout status"
kubectl get pods,svc,hpa,ingress -n "${K8S_NAMESPACE}"

log "Running the chart's smoke test"
helm test "${HELM_RELEASE}" -n "${K8S_NAMESPACE}" --logs || warn "smoke test reported failures — see the output above"

log "Waiting for the ALB address (up to 5 minutes)"
for _ in $(seq 1 60); do
  ALB="$(kubectl get ingress "${HELM_RELEASE}" -n "${K8S_NAMESPACE}" \
        -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)"
  [[ -n "${ALB}" ]] && break
  sleep 5
done

if [[ -n "${ALB:-}" ]]; then
  ok "Application URL: http://${ALB}"
  log "Note: the ALB target group needs another 1-2 minutes to report healthy."
else
  warn "no ALB hostname yet — check: kubectl describe ingress ${HELM_RELEASE} -n ${K8S_NAMESPACE}"
fi
