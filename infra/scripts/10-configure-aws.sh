#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Step 3 of the project brief: install and configure the AWS CLI.
#
#   ./infra/scripts/10-configure-aws.sh
#
# Runs `aws configure` only when no working credentials are found, then proves
# the identity and region are usable. Safe to run repeatedly.
# ---------------------------------------------------------------------------
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../env.sh
source "${SCRIPT_DIR}/../env.sh"

require_cmd aws jq

log "Checking for existing AWS credentials"
if ! aws sts get-caller-identity >/dev/null 2>&1; then
  warn "no usable credentials found — starting interactive configuration"
  cat <<'EOF'

You need an IAM user (or SSO role) with permissions for:
  ECR, EKS, EC2, IAM, CloudFormation, CloudWatch, Logs, SNS, Lambda, S3

Create an access key:  IAM console -> Users -> <you> -> Security credentials
                       -> Create access key -> "Command Line Interface (CLI)"

EOF
  aws configure
fi

AWS_ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
CALLER_ARN="$(aws sts get-caller-identity --query Arn --output text)"
export AWS_ACCOUNT_ID

# Make sure a default region is actually set — eksctl fails cryptically without one.
CURRENT_REGION="$(aws configure get region || true)"
if [[ -z "${CURRENT_REGION}" ]]; then
  log "No default region configured; setting it to ${AWS_REGION}"
  aws configure set region "${AWS_REGION}"
  CURRENT_REGION="${AWS_REGION}"
fi

ok "Account : ${AWS_ACCOUNT_ID}"
ok "Identity: ${CALLER_ARN}"
ok "Region  : ${CURRENT_REGION}"
ok "Registry: ${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"

if [[ "${CURRENT_REGION}" != "${AWS_REGION}" ]]; then
  warn "CLI default region (${CURRENT_REGION}) differs from infra/env.sh AWS_REGION (${AWS_REGION})."
  warn "The scripts pass --region explicitly, so this is fine — just be aware when running ad-hoc commands."
fi

log "Verifying service reachability"
aws ecr describe-repositories --region "${AWS_REGION}" --max-items 1 >/dev/null 2>&1 \
  && ok "ECR reachable" || warn "ECR call failed — check IAM permissions"
aws eks list-clusters --region "${AWS_REGION}" >/dev/null 2>&1 \
  && ok "EKS reachable" || warn "EKS call failed — check IAM permissions"

log "AWS CLI configured. Next: ./infra/scripts/20-create-ecr.sh"
