#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Installs the CLI toolchain this project needs on a fresh Amazon Linux 2023
# or Ubuntu 22.04 box (works for your laptop, the Jenkins EC2 node, or Cloud9).
#
#   ./infra/scripts/00-prereqs.sh
#
# Installs: awscli v2, kubectl, eksctl, helm, docker, jq, git
# Idempotent — re-running skips anything already present.
# ---------------------------------------------------------------------------
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../env.sh
source "${SCRIPT_DIR}/../env.sh"

ARCH="$(uname -m)"
case "${ARCH}" in
  x86_64)  AWS_ARCH=x86_64; K_ARCH=amd64 ;;
  aarch64|arm64) AWS_ARCH=aarch64; K_ARCH=arm64 ;;
  *) die "unsupported architecture: ${ARCH}" ;;
esac

if command -v dnf >/dev/null 2>&1;      then PKG="sudo dnf install -y"
elif command -v yum >/dev/null 2>&1;    then PKG="sudo yum install -y"
elif command -v apt-get >/dev/null 2>&1; then sudo apt-get update -y; PKG="sudo apt-get install -y"
else die "no supported package manager (dnf/yum/apt-get) found"
fi

log "Installing base packages"
${PKG} curl unzip tar gzip jq git >/dev/null
ok "base packages present"

# ---- AWS CLI v2 -------------------------------------------------------------
if ! command -v aws >/dev/null 2>&1; then
  log "Installing AWS CLI v2"
  tmp="$(mktemp -d)"
  curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-${AWS_ARCH}.zip" -o "${tmp}/awscliv2.zip"
  unzip -q "${tmp}/awscliv2.zip" -d "${tmp}"
  sudo "${tmp}/aws/install" --update
  rm -rf "${tmp}"
fi
ok "aws $(aws --version 2>&1 | awk '{print $1}')"

# ---- kubectl ----------------------------------------------------------------
if ! command -v kubectl >/dev/null 2>&1; then
  log "Installing kubectl ${K8S_VERSION}"
  curl -fsSLo /tmp/kubectl "https://dl.k8s.io/release/v${K8S_VERSION}.0/bin/linux/${K_ARCH}/kubectl"
  sudo install -o root -g root -m 0755 /tmp/kubectl /usr/local/bin/kubectl
  rm -f /tmp/kubectl
fi
ok "kubectl $(kubectl version --client -o json 2>/dev/null | jq -r .clientVersion.gitVersion || echo installed)"

# ---- eksctl -----------------------------------------------------------------
if ! command -v eksctl >/dev/null 2>&1; then
  log "Installing eksctl"
  curl -fsSL "https://github.com/eksctl-io/eksctl/releases/latest/download/eksctl_Linux_${K_ARCH}.tar.gz" \
    | tar xz -C /tmp
  sudo install -o root -g root -m 0755 /tmp/eksctl /usr/local/bin/eksctl
  rm -f /tmp/eksctl
fi
ok "eksctl $(eksctl version)"

# ---- helm -------------------------------------------------------------------
if ! command -v helm >/dev/null 2>&1; then
  log "Installing Helm 3"
  curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
fi
ok "helm $(helm version --short)"

# ---- docker -----------------------------------------------------------------
if ! command -v docker >/dev/null 2>&1; then
  log "Installing Docker"
  if command -v dnf >/dev/null 2>&1 || command -v yum >/dev/null 2>&1; then
    ${PKG} docker
  else
    curl -fsSL https://get.docker.com | sudo sh
  fi
  sudo systemctl enable --now docker
  sudo usermod -aG docker "$(whoami)" || true
  warn "you were added to the 'docker' group — log out and back in for it to take effect"
fi
ok "docker $(docker --version 2>/dev/null || echo 'installed (daemon may need a re-login)')"

log "Toolchain ready. Next: ./infra/scripts/10-configure-aws.sh"
