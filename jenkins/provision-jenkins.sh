#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Launches a Jenkins controller on EC2, fully configured, from one command.
#
#   ./jenkins/provision-jenkins.sh
#   ./jenkins/provision-jenkins.sh --destroy
#
# jenkins/setup-jenkins-ec2.sh installs Jenkins *on* a box; this script creates
# the box, gives it the IAM identity and network access it needs, and feeds it
# a Configuration-as-Code file so the controller boots with its admin user,
# credentials and pipeline job already defined. No setup wizard, no clicking
# through the UI.
#
# Prerequisites: the EKS cluster must already exist — the instance lands in the
# cluster's VPC and is mapped into the cluster's RBAC so the pipeline's
# `helm upgrade` can actually reach the API server.
#
# Cost: t3.medium is about $0.042/hour in ap-south-1. Run --destroy when done,
# or let infra/scripts/99-teardown.sh clean it up with everything else.
# ---------------------------------------------------------------------------
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=../infra/env.sh
source "${REPO_ROOT}/infra/env.sh"

require_cmd aws jq eksctl
require_account

INSTANCE_NAME="${PROJECT}-jenkins"
SG_NAME="${PROJECT}-jenkins-sg"
INSTANCE_TYPE="${JENKINS_INSTANCE_TYPE:-t3.medium}"
IAM_PROFILE="${PROJECT}-jenkins"
REPO_URL="${JENKINS_REPO_URL:-https://github.com/2sagarrathore/StreamingApp.git}"
ADMIN_USER="${JENKINS_ADMIN_USER:-admin}"

find_instance() {
  aws ec2 describe-instances --region "${AWS_REGION}" \
    --filters "Name=tag:Name,Values=${INSTANCE_NAME}" \
              "Name=instance-state-name,Values=pending,running,stopping,stopped" \
    --query 'Reservations[0].Instances[0].InstanceId' --output text 2>/dev/null \
    | grep -v '^None$' || true
}

# ---------------------------------------------------------------------------
if [[ "${1:-}" == "--destroy" ]]; then
  EXISTING="$(find_instance)"
  if [[ -n "${EXISTING}" ]]; then
    log "Terminating ${EXISTING}"
    aws ec2 terminate-instances --instance-ids "${EXISTING}" --region "${AWS_REGION}" >/dev/null
    aws ec2 wait instance-terminated --instance-ids "${EXISTING}" --region "${AWS_REGION}"
    ok "instance terminated"
  else
    ok "no Jenkins instance running"
  fi
  SG_ID="$(aws ec2 describe-security-groups --region "${AWS_REGION}" \
    --filters "Name=group-name,Values=${SG_NAME}" \
    --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null | grep -v '^None$' || true)"
  if [[ -n "${SG_ID}" ]]; then
    # The ENI can linger for a few seconds after the instance goes away.
    for _ in $(seq 1 10); do
      aws ec2 delete-security-group --group-id "${SG_ID}" --region "${AWS_REGION}" 2>/dev/null && break
      sleep 6
    done
    ok "security group removed"
  fi
  exit 0
fi

# ---------------------------------------------------------------------------
log "1/6  IAM role, instance profile and cluster RBAC"
# ---------------------------------------------------------------------------
"${REPO_ROOT}/infra/scripts/50-jenkins-iam.sh" --instance-profile
ok "Jenkins can reach ECR, EKS and SNS without any stored keys"

# ---------------------------------------------------------------------------
log "2/6  Network placement"
# ---------------------------------------------------------------------------
VPC_ID="$(aws eks describe-cluster --name "${CLUSTER_NAME}" --region "${AWS_REGION}" \
          --query 'cluster.resourcesVpcConfig.vpcId' --output text)"
[[ -n "${VPC_ID}" && "${VPC_ID}" != "None" ]] || die "cluster ${CLUSTER_NAME} not found — create it first"

# A public subnet, so the pipeline can be reached and can reach GitHub directly.
SUBNET_ID="$(aws ec2 describe-subnets --region "${AWS_REGION}" \
  --filters "Name=vpc-id,Values=${VPC_ID}" "Name=map-public-ip-on-launch,Values=true" \
  --query 'Subnets[0].SubnetId' --output text)"
[[ -n "${SUBNET_ID}" && "${SUBNET_ID}" != "None" ]] || die "no public subnet in ${VPC_ID}"
ok "vpc ${VPC_ID}, subnet ${SUBNET_ID}"

MY_IP="$(curl -fsS --max-time 10 https://checkip.amazonaws.com | tr -d '[:space:]')"
[[ -n "${MY_IP}" ]] || die "could not determine this machine's public IP"

SG_ID="$(aws ec2 describe-security-groups --region "${AWS_REGION}" \
  --filters "Name=group-name,Values=${SG_NAME}" "Name=vpc-id,Values=${VPC_ID}" \
  --query 'SecurityGroups[0].GroupId' --output text 2>/dev/null | grep -v '^None$' || true)"

if [[ -z "${SG_ID}" ]]; then
  SG_ID="$(aws ec2 create-security-group --region "${AWS_REGION}" \
    --group-name "${SG_NAME}" --vpc-id "${VPC_ID}" \
    --description "Jenkins controller for ${PROJECT} — web UI restricted to the provisioning IP" \
    --query 'GroupId' --output text)"
  ok "security group ${SG_ID} created"
fi

# Only the machine that ran this script may reach the UI. Re-running with a new
# IP adds a rule rather than replacing one, which is intentional: you may be
# provisioning from CloudShell and browsing from a laptop.
aws ec2 authorize-security-group-ingress --region "${AWS_REGION}" --group-id "${SG_ID}" \
  --ip-permissions "IpProtocol=tcp,FromPort=8080,ToPort=8080,IpRanges=[{CidrIp=${MY_IP}/32,Description=jenkins-ui}]" \
  >/dev/null 2>&1 || true
ok "port 8080 open to ${MY_IP}/32 only"

# ---------------------------------------------------------------------------
log "3/6  Reusing or creating the instance"
# ---------------------------------------------------------------------------
EXISTING="$(find_instance)"
if [[ -n "${EXISTING}" ]]; then
  ok "instance ${EXISTING} already exists — reusing it (pass --destroy to start over)"
  INSTANCE_ID="${EXISTING}"
else
  AMI_ID="$(aws ssm get-parameter --region "${AWS_REGION}" \
    --name /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64 \
    --query 'Parameter.Value' --output text)"
  ok "ami ${AMI_ID} (Amazon Linux 2023)"

  ADMIN_PASSWORD="$(openssl rand -base64 18 | tr -d '/+=' | cut -c1-20)"

  # jenkins-plugin-cli wants a bare plugin per line; plugins.txt carries inline
  # comments for humans, so strip them here rather than degrade the docs.
  PLUGIN_LIST="$(sed -e 's/#.*//' -e 's/[[:space:]]*$//' "${SCRIPT_DIR}/plugins.txt" \
                 | grep -v '^$' | tr '\n' ' ')"
  # JCasC itself plus the Job DSL engine that renders the jobs: block. Neither
  # is in plugins.txt because neither is a pipeline dependency — they exist to
  # configure the controller, not to run builds.
  PLUGIN_LIST="configuration-as-code job-dsl ${PLUGIN_LIST}"

  USERDATA_FILE="$(mktemp)"
  trap 'rm -f "${USERDATA_FILE}"' EXIT

  {
    echo '#!/bin/bash'
    echo 'set -xuo pipefail'
    echo 'exec > >(tee /var/log/jenkins-bootstrap.log) 2>&1'
    echo
    echo "REPO_URL='${REPO_URL}'"
    echo "ADMIN_USER='${ADMIN_USER}'"
    echo "ADMIN_PASSWORD='${ADMIN_PASSWORD}'"
    echo "AWS_ACCOUNT_ID='${AWS_ACCOUNT_ID}'"
    echo "PLUGIN_LIST='${PLUGIN_LIST}'"
    cat <<'BOOTSTRAP'

dnf install -y git
git clone --depth 1 "${REPO_URL}" /opt/streamingapp
chmod +x /opt/streamingapp/jenkins/*.sh
/opt/streamingapp/jenkins/setup-jenkins-ec2.sh

# ---- plugins ---------------------------------------------------------------
# The distro package ships jenkins-plugin-cli in /opt/jenkins-plugin-manager.jar
# on some builds and on $PATH on others; handle both.
mkdir -p /var/lib/jenkins/plugins
if command -v jenkins-plugin-cli >/dev/null 2>&1; then
  jenkins-plugin-cli --verbose --plugin-download-directory /var/lib/jenkins/plugins \
    --plugins ${PLUGIN_LIST}
else
  curl -fsSLo /tmp/plugin-manager.jar \
    "https://github.com/jenkinsci/plugin-installation-manager-tool/releases/latest/download/jenkins-plugin-manager.jar"
  java -jar /tmp/plugin-manager.jar --war /usr/share/java/jenkins.war \
    --plugin-download-directory /var/lib/jenkins/plugins --plugins ${PLUGIN_LIST}
fi
chown -R jenkins:jenkins /var/lib/jenkins/plugins

# ---- configuration as code -------------------------------------------------
TOKEN="$(curl -fsS -X PUT http://169.254.169.254/latest/api/token \
         -H 'X-aws-ec2-metadata-token-ttl-seconds: 300')"
PUBLIC_IP="$(curl -fsS -H "X-aws-ec2-metadata-token: ${TOKEN}" \
             http://169.254.169.254/latest/meta-data/public-ipv4)"

sed -e "s|__ADMIN_USER__|${ADMIN_USER}|g" \
    -e "s|__ADMIN_PASSWORD__|${ADMIN_PASSWORD}|g" \
    -e "s|__AWS_ACCOUNT_ID__|${AWS_ACCOUNT_ID}|g" \
    -e "s|__PUBLIC_IP__|${PUBLIC_IP}|g" \
    -e "s|__ADMIN_EMAIL__|admin@example.com|g" \
    -e "s|__REPO_URL__|${REPO_URL}|g" \
    /opt/streamingapp/jenkins/casc.yaml > /var/lib/jenkins/casc.yaml
chown jenkins:jenkins /var/lib/jenkins/casc.yaml
chmod 0600 /var/lib/jenkins/casc.yaml

# Skip the unlock wizard — JCasC owns the security realm now.
mkdir -p /etc/systemd/system/jenkins.service.d
cat > /etc/systemd/system/jenkins.service.d/override.conf <<OVERRIDE
[Service]
Environment="JAVA_OPTS=-Djenkins.install.runSetupWizard=false -Djava.awt.headless=true"
Environment="CASC_JENKINS_CONFIG=/var/lib/jenkins/casc.yaml"
OVERRIDE

systemctl daemon-reload
systemctl restart jenkins
touch /var/lib/jenkins/.bootstrap-complete
BOOTSTRAP
  } > "${USERDATA_FILE}"

  log "Launching ${INSTANCE_TYPE}"
  INSTANCE_ID="$(aws ec2 run-instances --region "${AWS_REGION}" \
    --image-id "${AMI_ID}" \
    --instance-type "${INSTANCE_TYPE}" \
    --subnet-id "${SUBNET_ID}" \
    --security-group-ids "${SG_ID}" \
    --associate-public-ip-address \
    --iam-instance-profile "Name=${IAM_PROFILE}" \
    --block-device-mappings 'DeviceName=/dev/xvda,Ebs={VolumeSize=30,VolumeType=gp3,DeleteOnTermination=true}' \
    --metadata-options 'HttpTokens=required,HttpEndpoint=enabled' \
    --user-data "file://${USERDATA_FILE}" \
    --tag-specifications \
      "ResourceType=instance,Tags=[{Key=Name,Value=${INSTANCE_NAME}},{Key=Project,Value=${PROJECT}},{Key=ManagedBy,Value=provision-jenkins.sh}]" \
    --query 'Instances[0].InstanceId' --output text)"
  ok "instance ${INSTANCE_ID} launching"

  echo "${ADMIN_PASSWORD}" > "${REPO_ROOT}/.jenkins-admin-password"
  chmod 600 "${REPO_ROOT}/.jenkins-admin-password"
fi

# ---------------------------------------------------------------------------
log "4/6  Waiting for the instance to boot"
# ---------------------------------------------------------------------------
aws ec2 wait instance-running --instance-ids "${INSTANCE_ID}" --region "${AWS_REGION}"
PUBLIC_IP="$(aws ec2 describe-instances --instance-ids "${INSTANCE_ID}" --region "${AWS_REGION}" \
  --query 'Reservations[0].Instances[0].PublicIpAddress' --output text)"
ok "running at ${PUBLIC_IP}"

# ---------------------------------------------------------------------------
log "5/6  Waiting for Jenkins (installing Java, Docker and plugins takes 5-8 minutes)"
# ---------------------------------------------------------------------------
JENKINS_URL="http://${PUBLIC_IP}:8080"
READY=false
for attempt in $(seq 1 60); do
  CODE="$(curl -fsS -o /dev/null -w '%{http_code}' --max-time 8 "${JENKINS_URL}/login" 2>/dev/null || echo 000)"
  if [[ "${CODE}" == "200" ]]; then READY=true; break; fi
  [[ $((attempt % 5)) -eq 0 ]] && log "  still booting (${attempt}/60, last HTTP ${CODE})"
  sleep 15
done

# ---------------------------------------------------------------------------
log "6/6  Result"
# ---------------------------------------------------------------------------
mkdir -p "${REPO_ROOT}/docs/evidence"
{
  echo "# Jenkins controller"
  echo "provisioned: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "instance:    ${INSTANCE_ID} (${INSTANCE_TYPE}, Amazon Linux 2023)"
  echo "url:         ${JENKINS_URL}"
  echo "vpc/subnet:  ${VPC_ID} / ${SUBNET_ID}"
  echo "ingress:     tcp/8080 from ${MY_IP}/32 only"
  echo "iam:         instance profile ${IAM_PROFILE} (no static keys)"
  echo "job:         streamingapp-pipeline (Jenkinsfile from ${REPO_URL})"
} > "${REPO_ROOT}/docs/evidence/11-jenkins.txt"

if [[ "${READY}" == "true" ]]; then
  ok "Jenkins is up at ${JENKINS_URL}"
  cat <<EOF

  Sign in:  ${ADMIN_USER} / $(cat "${REPO_ROOT}/.jenkins-admin-password" 2>/dev/null || echo '(see .jenkins-admin-password)')

  The 'streamingapp-pipeline' job is already created. Run it with:

      ./jenkins/run-pipeline.sh

  Tear the controller down when you have the evidence:

      ./jenkins/provision-jenkins.sh --destroy

EOF
else
  warn "Jenkins did not answer on 8080 within 15 minutes"
  echo "  Check the bootstrap log:"
  echo "    aws ssm start-session --target ${INSTANCE_ID} --region ${AWS_REGION}"
  echo "    sudo tail -50 /var/log/jenkins-bootstrap.log"
  exit 1
fi
