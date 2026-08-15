#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Bootstraps a Jenkins controller on a fresh EC2 instance (Amazon Linux 2023
# or Ubuntu 22.04) with everything the StreamingApp pipeline needs.
#
# Run it ON the EC2 instance:
#   curl -fsSL <raw-url>/jenkins/setup-jenkins-ec2.sh | bash
# or, if you cloned the repo there:
#   sudo ./jenkins/setup-jenkins-ec2.sh
#
# Recommended instance: t3.medium (2 vCPU / 4 GB) with a 30 GB gp3 root volume.
# Docker builds are memory-hungry; t3.micro will OOM partway through the
# frontend's `npm run build`.
#
# Security group inbound: 22 from your IP, 8080 from your IP (or an ALB).
# ---------------------------------------------------------------------------
set -euo pipefail

log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
ok()  { printf '\033[1;32m  ✔\033[0m %s\n' "$*"; }

[[ "${EUID}" -eq 0 ]] || { echo "run this with sudo"; exit 1; }

if command -v dnf >/dev/null 2>&1; then
  PKG_MGR=dnf; JENKINS_USER=jenkins
elif command -v apt-get >/dev/null 2>&1; then
  PKG_MGR=apt-get; JENKINS_USER=jenkins
  apt-get update -y
else
  echo "unsupported distro"; exit 1
fi

# ---------------------------------------------------------------------------
log "1/7  Base packages + Java 17 (required by Jenkins 2.4xx+)"
# ---------------------------------------------------------------------------
if [[ "${PKG_MGR}" == "dnf" ]]; then
  dnf install -y java-17-amazon-corretto-headless git curl wget unzip tar jq which
else
  apt-get install -y openjdk-17-jdk git curl wget unzip tar jq
fi
ok "java $(java -version 2>&1 | head -1)"

# ---------------------------------------------------------------------------
log "2/7  Jenkins LTS"
# ---------------------------------------------------------------------------
if ! command -v jenkins >/dev/null 2>&1 && [[ ! -d /var/lib/jenkins ]]; then
  if [[ "${PKG_MGR}" == "dnf" ]]; then
    wget -qO /etc/yum.repos.d/jenkins.repo https://pkg.jenkins.io/redhat-stable/jenkins.repo
    rpm --import https://pkg.jenkins.io/redhat-stable/jenkins.io-2023.key
    dnf install -y jenkins
  else
    curl -fsSL https://pkg.jenkins.io/debian-stable/jenkins.io-2023.key \
      | tee /usr/share/keyrings/jenkins-keyring.asc >/dev/null
    echo "deb [signed-by=/usr/share/keyrings/jenkins-keyring.asc] https://pkg.jenkins.io/debian-stable binary/" \
      > /etc/apt/sources.list.d/jenkins.list
    apt-get update -y
    apt-get install -y jenkins
  fi
fi
systemctl enable jenkins
ok "jenkins installed"

# ---------------------------------------------------------------------------
log "3/7  Docker (the pipeline builds images on this node)"
# ---------------------------------------------------------------------------
if ! command -v docker >/dev/null 2>&1; then
  if [[ "${PKG_MGR}" == "dnf" ]]; then
    dnf install -y docker
  else
    curl -fsSL https://get.docker.com | sh
  fi
fi
systemctl enable --now docker
# Let the jenkins service account drive the Docker daemon without sudo.
usermod -aG docker "${JENKINS_USER}"
ok "docker $(docker --version)"

# ---------------------------------------------------------------------------
log "4/7  AWS CLI v2, kubectl, helm, eksctl"
# ---------------------------------------------------------------------------
ARCH="$(uname -m)"; [[ "${ARCH}" == "aarch64" ]] && K_ARCH=arm64 || K_ARCH=amd64
[[ "${ARCH}" == "aarch64" ]] && AWS_ARCH=aarch64 || AWS_ARCH=x86_64

if ! command -v aws >/dev/null 2>&1; then
  curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-${AWS_ARCH}.zip" -o /tmp/awscliv2.zip
  unzip -q /tmp/awscliv2.zip -d /tmp && /tmp/aws/install --update
fi

if ! command -v kubectl >/dev/null 2>&1; then
  curl -fsSLo /tmp/kubectl "https://dl.k8s.io/release/v1.30.0/bin/linux/${K_ARCH}/kubectl"
  install -m 0755 /tmp/kubectl /usr/local/bin/kubectl
fi

if ! command -v helm >/dev/null 2>&1; then
  curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
fi

if ! command -v eksctl >/dev/null 2>&1; then
  curl -fsSL "https://github.com/eksctl-io/eksctl/releases/latest/download/eksctl_Linux_${K_ARCH}.tar.gz" \
    | tar xz -C /tmp && install -m 0755 /tmp/eksctl /usr/local/bin/eksctl
fi
ok "aws / kubectl / helm / eksctl installed"

# ---------------------------------------------------------------------------
log "5/7  Optional quality gates: hadolint + trivy + shellcheck"
# ---------------------------------------------------------------------------
if ! command -v hadolint >/dev/null 2>&1; then
  curl -fsSLo /usr/local/bin/hadolint \
    "https://github.com/hadolint/hadolint/releases/latest/download/hadolint-Linux-$(uname -m)" || true
  chmod +x /usr/local/bin/hadolint 2>/dev/null || true
fi
if ! command -v trivy >/dev/null 2>&1; then
  curl -fsSL https://raw.githubusercontent.com/aquasecurity/trivy/main/contrib/install.sh \
    | sh -s -- -b /usr/local/bin || true
fi
if [[ "${PKG_MGR}" == "dnf" ]]; then dnf install -y ShellCheck || true; else apt-get install -y shellcheck || true; fi
ok "lint/scan tools installed (any failures above are non-fatal)"

# ---------------------------------------------------------------------------
log "6/7  Jenkins home + kubeconfig directory"
# ---------------------------------------------------------------------------
install -d -o "${JENKINS_USER}" -g "${JENKINS_USER}" -m 0700 "/var/lib/jenkins/.kube"
install -d -o "${JENKINS_USER}" -g "${JENKINS_USER}" -m 0700 "/var/lib/jenkins/.aws"
ok "jenkins home prepared"

# ---------------------------------------------------------------------------
log "7/7  Starting Jenkins"
# ---------------------------------------------------------------------------
systemctl restart docker
systemctl restart jenkins
sleep 20

# Amazon Linux 2023 requires IMDSv2, so the metadata call needs a session token
# first — an unauthenticated GET returns 401 and would leave the URL blank.
IMDS_TOKEN="$(curl -fsS --max-time 5 -X PUT http://169.254.169.254/latest/api/token \
  -H 'X-aws-ec2-metadata-token-ttl-seconds: 300' 2>/dev/null || true)"
PUBLIC_IP="$(curl -fsS --max-time 5 -H "X-aws-ec2-metadata-token: ${IMDS_TOKEN}" \
  http://169.254.169.254/latest/meta-data/public-ipv4 2>/dev/null || echo '<ec2-public-ip>')"

cat <<EOF

===========================================================================
Jenkins is up.

  URL:      http://${PUBLIC_IP}:8080
  Password: $(cat /var/lib/jenkins/secrets/initialAdminPassword 2>/dev/null || echo '(check /var/lib/jenkins/secrets/initialAdminPassword)')

Next steps — see jenkins/README.md for the detail:
  1. Unlock Jenkins, install the suggested plugins, then add the ones in
     jenkins/plugins.txt.
  2. Add credentials:
       aws-account-id     (Secret text)  -> your 12-digit AWS account ID
       github-credentials (Username+PAT) -> for cloning and status checks
     AWS access itself comes from the EC2 instance profile created by
     infra/scripts/50-jenkins-iam.sh — no keys needed in Jenkins.
  3. Attach that instance profile to this EC2 instance.
  4. Create a Multibranch Pipeline (or Pipeline from SCM) pointing at your
     fork; the Jenkinsfile at the repo root does the rest.
  5. Add a GitHub webhook: http://${PUBLIC_IP}:8080/github-webhook/
===========================================================================

EOF
