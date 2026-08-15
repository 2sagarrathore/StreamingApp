#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Destroys everything this project created, in dependency order.
#
#   ./infra/scripts/99-teardown.sh
#
# Run this the moment you finish demoing. An idle EKS control plane alone is
# ~$0.10/hour, and a stranded ALB or NAT gateway will quietly keep billing.
# ---------------------------------------------------------------------------
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
# shellcheck source=../env.sh
source "${SCRIPT_DIR}/../env.sh"

require_cmd aws eksctl kubectl helm

cat <<EOF

This will permanently delete:
  * Helm release   ${HELM_RELEASE} (namespace ${K8S_NAMESPACE})
  * EKS cluster    ${CLUSTER_NAME} (region ${AWS_REGION}) — including its VPC, NAT GW and nodes
  * ECR repos      ${ECR_REPOS[*]}
  * Jenkins        the ${PROJECT}-jenkins EC2 controller, if one is running
  * CodeBuild      ${PROJECT}-image-builder and its S3 source bucket
  * SNS topics     ${SNS_TOPIC_DEPLOY}, ${SNS_TOPIC_ALARMS}
  * CloudWatch alarms and dashboard for ${PROJECT}

The S3 media bucket (${S3_BUCKET}) is NOT deleted — remove it by hand if you
want the uploaded videos gone.

EOF
read -r -p "Type the cluster name to confirm: " CONFIRM
[[ "${CONFIRM}" == "${CLUSTER_NAME}" ]] || die "confirmation did not match — nothing was deleted"

# 1. Uninstall the release first so the ALB Ingress is deleted by the
#    controller. Deleting the cluster with a live Ingress orphans the ALB.
log "Uninstalling Helm release"
helm uninstall "${HELM_RELEASE}" -n "${K8S_NAMESPACE}" 2>/dev/null || warn "release not found"
log "Waiting 60s for the load balancer controller to tear down the ALB"
sleep 60

# 2. Monitoring stack
log "Removing CloudWatch agent / Fluent Bit"
kubectl delete namespace amazon-cloudwatch --ignore-not-found --timeout=5m 2>/dev/null || true

log "Deleting CloudWatch alarms"
mapfile -t ALARMS < <(aws cloudwatch describe-alarms --region "${AWS_REGION}" \
  --alarm-name-prefix "${PROJECT}-" --query 'MetricAlarms[].AlarmName' --output text | tr '\t' '\n')
if [[ ${#ALARMS[@]} -gt 0 && -n "${ALARMS[0]:-}" ]]; then
  aws cloudwatch delete-alarms --region "${AWS_REGION}" --alarm-names "${ALARMS[@]}"
  ok "deleted ${#ALARMS[@]} alarms"
fi
aws cloudwatch delete-dashboards --region "${AWS_REGION}" \
  --dashboard-names "${PROJECT}-overview" 2>/dev/null || true

# 3. Jenkins — must go before the cluster. The controller sits in the cluster's
#    VPC, and CloudFormation cannot delete a VPC that still has an instance and
#    a security group in it, so leaving this until later wedges the whole stack.
if [[ -x "${REPO_ROOT}/jenkins/provision-jenkins.sh" ]]; then
  log "Removing the Jenkins controller"
  "${REPO_ROOT}/jenkins/provision-jenkins.sh" --destroy || \
    warn "Jenkins teardown reported an error — check for a leftover instance in the cluster VPC"
fi

# 4. Image build scratch space
log "Removing the CodeBuild project and its source bucket"
aws codebuild delete-project --name "${PROJECT}-image-builder" \
  --region "${AWS_REGION}" 2>/dev/null || true
SOURCE_BUCKET="${PROJECT}-codebuild-source-${AWS_ACCOUNT_ID}"
aws s3 rm "s3://${SOURCE_BUCKET}" --recursive --region "${AWS_REGION}" >/dev/null 2>&1 || true
aws s3api delete-bucket --bucket "${SOURCE_BUCKET}" --region "${AWS_REGION}" 2>/dev/null \
  && ok "deleted s3://${SOURCE_BUCKET}" || true

# 5. Cluster (this also removes the VPC, NAT gateway and node group)
log "Deleting EKS cluster — 10-15 minutes"
eksctl delete cluster --name "${CLUSTER_NAME}" --region "${AWS_REGION}" --wait || \
  warn "cluster delete reported an error — check the CloudFormation console for stuck stacks"

# 6. Registries
for repo in "${ECR_REPOS[@]}"; do
  log "Deleting ECR repository ${repo}"
  aws ecr delete-repository --repository-name "${repo}" --region "${AWS_REGION}" --force >/dev/null 2>&1 \
    || warn "could not delete ${repo}"
done

# 7. ChatOps
for topic in "${SNS_TOPIC_DEPLOY}" "${SNS_TOPIC_ALARMS}"; do
  ARN="arn:aws:sns:${AWS_REGION}:${AWS_ACCOUNT_ID}:${topic}"
  aws sns delete-topic --topic-arn "${ARN}" --region "${AWS_REGION}" 2>/dev/null \
    && ok "deleted topic ${topic}" || warn "topic ${topic} not found"
done
aws lambda delete-function --function-name "${PROJECT}-slack-notifier" \
  --region "${AWS_REGION}" 2>/dev/null || true

log "Teardown complete. Verify in Billing > Cost Explorer that nothing is still running."
