#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Everything, from AWS CloudShell. No Docker, no local AWS credentials.
#
#   curl -fsSL https://raw.githubusercontent.com/2sagarrathore/StreamingApp/main/cloudshell-run.sh | bash
#
# CloudShell is already authenticated as your console identity, so this runs
# start to finish unattended. Images are built by CodeBuild inside AWS rather
# than by a local Docker daemon, which CloudShell does not have.
#
# Sequence:
#   1. ECR repositories
#   2. Images built and pushed by CodeBuild        (~10 min)
#   3. EKS cluster                                 (~18 min)
#   4. Cluster add-ons (ALB controller, HPA, autoscaler)
#   5. Helm deploy
#   6. CloudWatch monitoring, dashboard, alarms
#   7. Functional validation, captured to docs/evidence/
#
# Total: roughly 45 minutes. Safe to re-run — every phase is idempotent and
# completed phases are skipped.
#
# When you are done:  ./infra/scripts/99-teardown.sh
# ---------------------------------------------------------------------------
set -uo pipefail

REPO_URL="${REPO_URL:-https://github.com/2sagarrathore/StreamingApp.git}"
WORK_DIR="${WORK_DIR:-$HOME/streamingapp}"

blue()  { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
green() { printf '\033[1;32m  ✔\033[0m %s\n' "$*"; }
red()   { printf '\033[1;31m  ✘\033[0m %s\n' "$*" >&2; }

cat <<'BANNER'

  ╭──────────────────────────────────────────────────────────────╮
  │  StreamFlix on EKS — full deployment from CloudShell         │
  │                                                              │
  │  ~45 minutes. Leave this tab open; CloudShell keeps the      │
  │  session alive while output is streaming.                    │
  ╰──────────────────────────────────────────────────────────────╯

BANNER

# ---- preflight --------------------------------------------------------------
blue "Checking the environment"
command -v aws >/dev/null || { red "aws CLI not found — are you in CloudShell?"; exit 1; }

IDENTITY="$(aws sts get-caller-identity --output json 2>/dev/null)" || {
  red "No AWS credentials. Open CloudShell from the AWS console and re-run."
  exit 1
}
green "Account $(echo "${IDENTITY}" | jq -r .Account)"
green "Identity $(echo "${IDENTITY}" | jq -r .Arn)"
green "Region ${AWS_REGION:-${AWS_DEFAULT_REGION:-ap-south-1}}"

# CloudShell gives 1 GB of home storage; the repo plus a source zip fits, but
# a leftover clone from a previous run does not.
AVAIL_MB="$(df -m "${HOME}" | awk 'NR==2 {print $4}')"
[[ "${AVAIL_MB}" -lt 300 ]] && red "only ${AVAIL_MB}MB free in ${HOME} — run 'rm -rf ~/streamingapp' first"

# ---- fetch ------------------------------------------------------------------
blue "Fetching the repository"
if [[ -d "${WORK_DIR}/.git" ]]; then
  git -C "${WORK_DIR}" fetch --quiet origin && git -C "${WORK_DIR}" reset --hard --quiet origin/main
  green "updated existing clone"
else
  git clone --quiet "${REPO_URL}" "${WORK_DIR}"
  green "cloned to ${WORK_DIR}"
fi
cd "${WORK_DIR}" || { red "could not enter ${WORK_DIR}"; exit 1; }
chmod +x run-project.sh infra/scripts/*.sh monitoring/*.sh chatops/*.sh 2>/dev/null || true

# ---- toolchain --------------------------------------------------------------
blue "Installing kubectl, eksctl and helm into ~/.local/bin"
mkdir -p "${HOME}/.local/bin"
export PATH="${HOME}/.local/bin:${PATH}"

if ! command -v kubectl >/dev/null; then
  curl -fsSLo "${HOME}/.local/bin/kubectl" \
    "https://dl.k8s.io/release/v1.30.0/bin/linux/amd64/kubectl" && chmod +x "${HOME}/.local/bin/kubectl"
fi
green "kubectl $(kubectl version --client -o json 2>/dev/null | jq -r .clientVersion.gitVersion 2>/dev/null || echo ready)"

if ! command -v eksctl >/dev/null; then
  curl -fsSL "https://github.com/eksctl-io/eksctl/releases/latest/download/eksctl_Linux_amd64.tar.gz" \
    | tar xz -C "${HOME}/.local/bin"
fi
green "eksctl $(eksctl version 2>/dev/null || echo ready)"

if ! command -v helm >/dev/null; then
  curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 \
    | HELM_INSTALL_DIR="${HOME}/.local/bin" USE_SUDO=false bash >/dev/null 2>&1
fi
green "helm $(helm version --short 2>/dev/null || echo ready)"

# ---- run --------------------------------------------------------------------
# CodeBuild replaces the local Docker build; everything else is unchanged.
export BUILD_MODE=codebuild

blue "Starting the deployment"
echo
./run-project.sh "$@"
STATUS=$?

echo
if [[ ${STATUS} -eq 0 ]]; then
  green "Deployment finished. Evidence is in ${WORK_DIR}/docs/evidence/"
  cat <<EOF

  Next:
    1. Take the browser screenshots listed at the end of the run
    2. Commit and push the evidence:

         cd ${WORK_DIR}
         git add docs/evidence docs/screenshots
         git commit -m "Add validation evidence"
         git push

    3. Tear it down so it stops billing:

         ./infra/scripts/99-teardown.sh

EOF
else
  red "Deployment exited with status ${STATUS} — see docs/evidence/*.log"
fi
exit ${STATUS}
