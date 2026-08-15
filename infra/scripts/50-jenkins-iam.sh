#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Grants the Jenkins node exactly the AWS permissions the pipeline needs, and
# maps it into the cluster's RBAC so `helm upgrade` works from a build.
#
#   ./infra/scripts/50-jenkins-iam.sh --instance-profile   # Jenkins on EC2 (preferred)
#   ./infra/scripts/50-jenkins-iam.sh --iam-user           # Jenkins elsewhere (access keys)
#
# Prefer the instance profile: no long-lived keys to leak into Jenkins creds.
# ---------------------------------------------------------------------------
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INFRA_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=../env.sh
source "${INFRA_DIR}/env.sh"

require_cmd aws jq eksctl
require_account

MODE="${1:---instance-profile}"
POLICY_NAME="${PROJECT}-jenkins-ci"
ROLE_NAME="${PROJECT}-jenkins-role"
USER_NAME="${PROJECT}-jenkins-user"
POLICY_ARN="arn:aws:iam::${AWS_ACCOUNT_ID}:policy/${POLICY_NAME}"

# ---- shared managed policy --------------------------------------------------
if aws iam get-policy --policy-arn "${POLICY_ARN}" >/dev/null 2>&1; then
  ok "policy ${POLICY_NAME} already exists"
else
  log "Creating IAM policy ${POLICY_NAME}"
  aws iam create-policy \
    --policy-name "${POLICY_NAME}" \
    --description "Least-privilege CI permissions for the StreamingApp Jenkins pipeline" \
    --policy-document "file://${INFRA_DIR}/iam/jenkins-ci-policy.json" >/dev/null
  ok "policy created"
fi

case "${MODE}" in
  --instance-profile)
    if ! aws iam get-role --role-name "${ROLE_NAME}" >/dev/null 2>&1; then
      log "Creating role ${ROLE_NAME} for EC2"
      aws iam create-role --role-name "${ROLE_NAME}" \
        --assume-role-policy-document '{
          "Version":"2012-10-17",
          "Statement":[{"Effect":"Allow","Principal":{"Service":"ec2.amazonaws.com"},"Action":"sts:AssumeRole"}]
        }' >/dev/null
    fi
    aws iam attach-role-policy --role-name "${ROLE_NAME}" --policy-arn "${POLICY_ARN}"

    if ! aws iam get-instance-profile --instance-profile-name "${ROLE_NAME}" >/dev/null 2>&1; then
      aws iam create-instance-profile --instance-profile-name "${ROLE_NAME}" >/dev/null
      aws iam add-role-to-instance-profile \
        --instance-profile-name "${ROLE_NAME}" --role-name "${ROLE_NAME}"
    fi
    PRINCIPAL_ARN="arn:aws:iam::${AWS_ACCOUNT_ID}:role/${ROLE_NAME}"
    ok "instance profile ready: ${ROLE_NAME}"
    cat <<EOF

Attach it to the Jenkins EC2 instance:
  aws ec2 associate-iam-instance-profile \\
    --instance-id <i-xxxxxxxx> \\
    --iam-instance-profile Name=${ROLE_NAME}

EOF
    ;;

  --iam-user)
    if ! aws iam get-user --user-name "${USER_NAME}" >/dev/null 2>&1; then
      log "Creating IAM user ${USER_NAME}"
      aws iam create-user --user-name "${USER_NAME}" >/dev/null
    fi
    aws iam attach-user-policy --user-name "${USER_NAME}" --policy-arn "${POLICY_ARN}"
    PRINCIPAL_ARN="arn:aws:iam::${AWS_ACCOUNT_ID}:user/${USER_NAME}"

    log "Creating an access key — store it in Jenkins as credential id 'aws-ecr-credentials'"
    aws iam create-access-key --user-name "${USER_NAME}" \
      --query 'AccessKey.{AccessKeyId:AccessKeyId,SecretAccessKey:SecretAccessKey}' --output table
    warn "this secret is shown exactly once — copy it into Jenkins now"
    ;;

  *) die "unknown mode '${MODE}' (use --instance-profile or --iam-user)" ;;
esac

# ---- let that principal talk to the cluster --------------------------------
log "Mapping ${PRINCIPAL_ARN} into the cluster's aws-auth (group: ${PROJECT}-deployers)"
eksctl create iamidentitymapping \
  --cluster "${CLUSTER_NAME}" \
  --region "${AWS_REGION}" \
  --arn "${PRINCIPAL_ARN}" \
  --group "${PROJECT}-deployers" \
  --username "jenkins" \
  --no-duplicate-arns || warn "mapping may already exist"

log "Binding RBAC for group ${PROJECT}-deployers in namespace ${K8S_NAMESPACE}"
kubectl apply -f - <<EOF
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: ${PROJECT}-deployer
  namespace: ${K8S_NAMESPACE}
rules:
  - apiGroups: ["", "apps", "batch", "autoscaling", "networking.k8s.io", "policy"]
    resources: ["*"]
    verbs: ["*"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: ${PROJECT}-deployer
  namespace: ${K8S_NAMESPACE}
subjects:
  - kind: Group
    name: ${PROJECT}-deployers
    apiGroup: rbac.authorization.k8s.io
roleRef:
  kind: Role
  name: ${PROJECT}-deployer
  apiGroup: rbac.authorization.k8s.io
EOF

ok "Jenkins can now push to ECR and deploy to ${K8S_NAMESPACE}"
