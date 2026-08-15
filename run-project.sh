#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# One-command end-to-end run.
#
#   ./run-project.sh
#
# Executes every provisioning step in order and records the real output of
# each one into docs/evidence/, so the validation record fills itself in as
# the deployment proceeds. At the end it prints the short list of things that
# can only be captured from a browser.
#
# Safe to re-run: every underlying script is idempotent, and this one skips
# phases that have already completed unless you pass --force.
#
# Flags:
#   --codebuild       build the images in AWS CodeBuild instead of locally.
#                     Applied automatically when no Docker daemon is reachable,
#                     which is what makes this runnable from AWS CloudShell.
#   --docker          force local Docker builds
#   --skip-ecr-push   create the ECR repos but let Jenkins build the images
#   --skip-monitoring skip the CloudWatch phase
#   --force           re-run phases that already recorded success
# ---------------------------------------------------------------------------
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${REPO_ROOT}"

# shellcheck source=infra/env.sh
source "${REPO_ROOT}/infra/env.sh"

EVIDENCE_DIR="${REPO_ROOT}/docs/evidence"
STATE_DIR="${EVIDENCE_DIR}/.state"
mkdir -p "${EVIDENCE_DIR}" "${STATE_DIR}"

SKIP_ECR_PUSH=false
SKIP_MONITORING=false
FORCE=false
# docker    = build locally, needs a Docker daemon
# codebuild = build inside AWS, needs nothing local
BUILD_MODE="${BUILD_MODE:-docker}"
for arg in "$@"; do
  case "${arg}" in
    --skip-ecr-push)   SKIP_ECR_PUSH=true ;;
    --skip-monitoring) SKIP_MONITORING=true ;;
    --codebuild)       BUILD_MODE=codebuild ;;
    --docker)          BUILD_MODE=docker ;;
    --force)           FORCE=true ;;
    -h|--help)         sed -n '2,26p' "$0"; exit 0 ;;
    *) die "unknown flag: ${arg}" ;;
  esac
done

START_TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
FAILED_PHASES=()

banner() {
  printf '\n\033[1;36m%s\033[0m\n' "════════════════════════════════════════════════════════════════"
  printf '\033[1;36m  %s\033[0m\n' "$*"
  printf '\033[1;36m%s\033[0m\n\n' "════════════════════════════════════════════════════════════════"
}

# phase <id> <description> <command...>
phase() {
  local id="$1" desc="$2"; shift 2
  local marker="${STATE_DIR}/${id}.done"
  local logfile="${EVIDENCE_DIR}/${id}.log"

  if [[ -f "${marker}" && "${FORCE}" == "false" ]]; then
    ok "${desc} — already completed (delete ${marker} or pass --force to re-run)"
    return 0
  fi

  banner "${desc}"
  {
    echo "# ${desc}"
    echo "# started: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "# command: $*"
    echo
  } > "${logfile}"

  # tee so the operator watches it live and the file keeps the record
  if "$@" 2>&1 | tee -a "${logfile}"; then
    echo -e "\n# completed: $(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "${logfile}"
    touch "${marker}"
    ok "${desc} — done (log: docs/evidence/${id}.log)"
    return 0
  else
    echo -e "\n# FAILED: $(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "${logfile}"
    warn "${desc} — FAILED. See docs/evidence/${id}.log"
    FAILED_PHASES+=("${desc}")
    return 1
  fi
}

# Records a command's output as a standalone evidence file.
capture() {
  local name="$1"; shift
  local out="${EVIDENCE_DIR}/${name}.txt"
  {
    echo "\$ $*"
    echo
    "$@" 2>&1
  } > "${out}"
  ok "captured docs/evidence/${name}.txt"
}

# ---------------------------------------------------------------------------
banner "StreamFlix — full deployment, $(date -u +%Y-%m-%d\ %H:%M) UTC"
# ---------------------------------------------------------------------------
cat <<EOF
  Region      : ${AWS_REGION}
  Cluster     : ${CLUSTER_NAME}
  Namespace   : ${K8S_NAMESPACE}
  Registry    : ${ECR_REGISTRY}
  Evidence to : docs/evidence/

EOF

require_cmd aws
require_account || die "AWS credentials are not usable — run 'aws configure' or refresh your SSO session first"

capture "00-aws-identity" aws sts get-caller-identity
capture "00-aws-version"  aws --version

# The images have to be built somewhere with a Docker daemon. If there isn't
# one here — CloudShell, a locked-down workstation — fall back to CodeBuild,
# which has Docker, sits next to ECR, and costs a couple of cents per run.
if [[ "${BUILD_MODE}" == "docker" ]] && ! docker info >/dev/null 2>&1; then
  warn "no Docker daemon reachable — switching image builds to AWS CodeBuild"
  BUILD_MODE=codebuild
fi
log "Image build mode: ${BUILD_MODE}"

# ---------------------------------------------------------------------------
if [[ "${BUILD_MODE}" == "codebuild" ]]; then
  phase "01-ecr" "Create ECR repositories" "${REPO_ROOT}/infra/scripts/20-create-ecr.sh"

  if [[ "${SKIP_ECR_PUSH}" == "false" ]]; then
    phase "01b-images" "Build and push the five images with CodeBuild (8-12 minutes)" \
      "${REPO_ROOT}/infra/scripts/25-build-images-codebuild.sh"

    # 25-build-images-codebuild.sh records the tag it produced so the deploy
    # phase installs exactly what was just built rather than a stale :latest.
    if [[ -f "${REPO_ROOT}/.last-image-tag" ]]; then
      IMAGE_TAG="$(cat "${REPO_ROOT}/.last-image-tag")"
      export IMAGE_TAG
      ok "deploying image tag ${IMAGE_TAG}"
    fi
  fi
else
  phase "01-ecr" "Create ECR repositories$([[ "${SKIP_ECR_PUSH}" == "false" ]] && echo " and push images")" \
    bash -c "'${REPO_ROOT}/infra/scripts/20-create-ecr.sh' $([[ "${SKIP_ECR_PUSH}" == "false" ]] && echo '--push')"
fi

capture "01-ecr-repositories" aws ecr describe-repositories --region "${AWS_REGION}" \
  --query 'repositories[].{Repository:repositoryName,URI:repositoryUri,Scan:imageScanningConfiguration.scanOnPush}' --output table

# ---------------------------------------------------------------------------
phase "02-eks" "Create the EKS cluster (15-20 minutes)" \
  "${REPO_ROOT}/infra/scripts/30-create-eks.sh"

capture "02-eks-cluster" eksctl get cluster --region "${AWS_REGION}"
capture "02-nodes"       kubectl get nodes -o wide

# ---------------------------------------------------------------------------
phase "03-addons" "Install cluster add-ons (ALB controller, metrics-server, autoscaler)" \
  "${REPO_ROOT}/infra/scripts/40-cluster-addons.sh"

capture "03-storageclass" kubectl get storageclass
capture "03-kube-system"  kubectl get pods -n kube-system

# ---------------------------------------------------------------------------
phase "04-deploy" "Deploy the application with Helm" \
  "${REPO_ROOT}/infra/scripts/60-deploy.sh"

capture "04-workloads"    kubectl get all -n "${K8S_NAMESPACE}"
capture "04-helm-release" helm list -n "${K8S_NAMESPACE}"
capture "04-helm-history" helm history "${HELM_RELEASE}" -n "${K8S_NAMESPACE}"
capture "04-hpa"          kubectl get hpa -n "${K8S_NAMESPACE}"
capture "04-ingress"      kubectl describe ingress "${HELM_RELEASE}" -n "${K8S_NAMESPACE}"
capture "04-pvc"          kubectl get pvc -n "${K8S_NAMESPACE}"

# ---------------------------------------------------------------------------
if [[ "${SKIP_MONITORING}" == "false" ]]; then
  phase "05-monitoring" "Set up CloudWatch monitoring and logging" \
    "${REPO_ROOT}/monitoring/setup-monitoring.sh"

  capture "05-alarms" aws cloudwatch describe-alarms --region "${AWS_REGION}" \
    --alarm-name-prefix "${PROJECT}-" \
    --query 'MetricAlarms[].{Alarm:AlarmName,State:StateValue,Metric:MetricName}' --output table
  capture "05-log-groups" aws logs describe-log-groups --region "${AWS_REGION}" \
    --log-group-name-prefix "/aws/containerinsights/${CLUSTER_NAME}" \
    --query 'logGroups[].{Group:logGroupName,RetentionDays:retentionInDays}' --output table
fi

# ---------------------------------------------------------------------------
banner "Functional validation"
# ---------------------------------------------------------------------------

log "Waiting for the ALB to publish an address"
ALB=""
for _ in $(seq 1 60); do
  ALB="$(kubectl get ingress "${HELM_RELEASE}" -n "${K8S_NAMESPACE}" \
        -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)"
  [[ -n "${ALB}" ]] && break
  sleep 10
done

if [[ -n "${ALB}" ]]; then
  ok "ALB: http://${ALB}"
  echo "http://${ALB}" > "${EVIDENCE_DIR}/app-url.txt"

  log "Waiting for the ALB targets to pass their health check"
  for _ in $(seq 1 40); do
    code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "http://${ALB}/healthz" || echo 000)"
    [[ "${code}" == "200" ]] && break
    sleep 15
  done

  {
    echo "# Endpoint checks against http://${ALB}"
    echo "# $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo
    for path in / /healthz /svc/auth/health /svc/streaming/api/health /svc/admin/api/health /svc/chat/api/chat; do
      code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 "http://${ALB}${path}" || echo 000)"
      printf '%-40s HTTP %s\n' "${path}" "${code}"
    done
    echo
    echo "# Response bodies"
    for path in /healthz /svc/auth/health /svc/streaming/api/health /svc/admin/api/health; do
      echo "--- ${path}"
      curl -s --max-time 15 "http://${ALB}${path}" || true
      echo
    done
  } > "${EVIDENCE_DIR}/06-endpoint-checks.txt"
  ok "captured docs/evidence/06-endpoint-checks.txt"
else
  warn "no ALB address after 10 minutes — check: kubectl describe ingress ${HELM_RELEASE} -n ${K8S_NAMESPACE}"
fi

log "Running the chart's smoke test"
helm test "${HELM_RELEASE}" -n "${K8S_NAMESPACE}" --logs \
  > "${EVIDENCE_DIR}/06-helm-smoke-test.txt" 2>&1 \
  && ok "smoke test passed" || warn "smoke test reported failures — see the log"

# ---- self-healing -----------------------------------------------------------
log "Self-healing check: deleting an auth pod and watching it come back"
{
  echo "# Before"
  kubectl get pods -n "${K8S_NAMESPACE}" -l app.kubernetes.io/component=auth
  echo
  POD="$(kubectl get pods -n "${K8S_NAMESPACE}" -l app.kubernetes.io/component=auth \
        -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  if [[ -n "${POD}" ]]; then
    echo "\$ kubectl delete pod ${POD} -n ${K8S_NAMESPACE}"
    kubectl delete pod "${POD}" -n "${K8S_NAMESPACE}"
    echo
    sleep 20
    echo "# After (Kubernetes scheduled a replacement)"
    kubectl get pods -n "${K8S_NAMESPACE}" -l app.kubernetes.io/component=auth
  fi
} > "${EVIDENCE_DIR}/07-self-healing.txt" 2>&1
ok "captured docs/evidence/07-self-healing.txt"

# ---- autoscaling ------------------------------------------------------------
log "Autoscaling check: driving load at the auth service for 4 minutes"
{
  echo "# HPA before load"
  kubectl get hpa -n "${K8S_NAMESPACE}"
  echo
} > "${EVIDENCE_DIR}/08-hpa-scaling.txt" 2>&1

kubectl delete pod load-gen -n "${K8S_NAMESPACE}" --ignore-not-found >/dev/null 2>&1
kubectl run load-gen -n "${K8S_NAMESPACE}" --image=busybox:1.36 --restart=Never -- \
  sh -c "while true; do wget -q -O- http://${HELM_RELEASE}-auth:3001/health >/dev/null 2>&1; done" >/dev/null 2>&1

for i in 1 2 3 4; do
  sleep 60
  {
    echo "# HPA after ${i} minute(s) of load"
    kubectl get hpa -n "${K8S_NAMESPACE}"
    kubectl get pods -n "${K8S_NAMESPACE}" -l app.kubernetes.io/component=auth --no-headers | wc -l \
      | xargs echo "auth pod count:"
    echo
  } >> "${EVIDENCE_DIR}/08-hpa-scaling.txt" 2>&1
done

kubectl delete pod load-gen -n "${K8S_NAMESPACE}" --ignore-not-found >/dev/null 2>&1
{
  echo "# Load generator stopped. The HPA scales back down after its"
  echo "# 300-second stabilisation window."
} >> "${EVIDENCE_DIR}/08-hpa-scaling.txt"
ok "captured docs/evidence/08-hpa-scaling.txt"

capture "09-top-pods"  kubectl top pods -n "${K8S_NAMESPACE}"
capture "09-top-nodes" kubectl top nodes
capture "09-events"    kubectl get events -n "${K8S_NAMESPACE}" --sort-by=.lastTimestamp

# ---------------------------------------------------------------------------
# Validation summary
# ---------------------------------------------------------------------------
SUMMARY="${EVIDENCE_DIR}/validation-summary.md"
{
  echo "# Validation Summary"
  echo
  echo "Automated run by \`run-project.sh\`."
  echo
  echo "| | |"
  echo "|---|---|"
  echo "| Started | ${START_TS} |"
  echo "| Finished | $(date -u +%Y-%m-%dT%H:%M:%SZ) |"
  echo "| Region | ${AWS_REGION} |"
  echo "| Cluster | ${CLUSTER_NAME} |"
  echo "| Namespace | ${K8S_NAMESPACE} |"
  echo "| Application URL | ${ALB:-not published} |"
  echo
  echo "## Cluster state at the end of the run"
  echo
  echo '```'
  kubectl get all -n "${K8S_NAMESPACE}" 2>&1 || echo "(cluster unreachable)"
  echo '```'
  echo
  echo "## Endpoint checks"
  echo
  echo '```'
  cat "${EVIDENCE_DIR}/06-endpoint-checks.txt" 2>/dev/null || echo "(not captured)"
  echo '```'
  echo
  echo "## Autoscaling"
  echo
  echo '```'
  cat "${EVIDENCE_DIR}/08-hpa-scaling.txt" 2>/dev/null || echo "(not captured)"
  echo '```'
  echo
  echo "## Self-healing"
  echo
  echo '```'
  cat "${EVIDENCE_DIR}/07-self-healing.txt" 2>/dev/null || echo "(not captured)"
  echo '```'
  echo
  if [[ ${#FAILED_PHASES[@]} -gt 0 ]]; then
    echo "## Phases that failed"
    echo
    for p in "${FAILED_PHASES[@]}"; do echo "- ${p}"; done
    echo
  fi
  echo "## Files in this directory"
  echo
  echo '```'
  find "${EVIDENCE_DIR}" -maxdepth 1 -type f -printf '%f\n' | sort
  echo '```'
} > "${SUMMARY}"

# ---------------------------------------------------------------------------
banner "Run complete"
# ---------------------------------------------------------------------------

if [[ ${#FAILED_PHASES[@]} -gt 0 ]]; then
  warn "${#FAILED_PHASES[@]} phase(s) failed:"
  for p in "${FAILED_PHASES[@]}"; do echo "      - ${p}"; done
  echo
fi

cat <<EOF
  Text evidence written to docs/evidence/ (see validation-summary.md).

  ${ALB:+Application: http://${ALB}}

  Still to capture by hand — these only exist in a browser:

    docs/screenshots/15-app-homepage.png        the app at the URL above
    docs/screenshots/16-app-catalogue.png       logged in, browsing videos
    docs/screenshots/17-app-playback.png        a video playing
    docs/screenshots/18-app-chat.png            chat across two tabs
    docs/screenshots/11-container-insights.png  CloudWatch > Container Insights
    docs/screenshots/12-cloudwatch-dashboard.png  dashboard "${PROJECT}-overview"
    docs/screenshots/06-jenkins-pipeline.png    a green pipeline run

  Then:
    git add docs/evidence docs/screenshots && git commit -m "Add validation evidence" && git push

  And when you are finished:
    ./infra/scripts/99-teardown.sh

EOF
