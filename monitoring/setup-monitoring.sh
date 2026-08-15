#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Step 6 of the brief: metrics, logs and alarms.
#
#   ./monitoring/setup-monitoring.sh
#
# Installs:
#   * CloudWatch Container Insights  -> cluster/node/pod/container metrics
#   * Fluent Bit                     -> every container's stdout into CloudWatch Logs
#   * Log group retention            -> so logs do not bill forever
#   * A CloudWatch dashboard         -> one screen for the whole platform
#   * Metric alarms                  -> wired to the SNS topic ChatOps listens on
# ---------------------------------------------------------------------------
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../infra/env.sh
source "${SCRIPT_DIR}/../infra/env.sh"

require_cmd aws kubectl eksctl jq
require_account

# ---------------------------------------------------------------------------
log "1/5  Container Insights (CloudWatch agent + Fluent Bit)"
# ---------------------------------------------------------------------------
# The managed EKS addon is the current, supported path: it installs the
# CloudWatch Agent Operator, which in turn runs the agent DaemonSet and
# Fluent Bit, and keeps them patched.
if aws eks describe-addon --cluster-name "${CLUSTER_NAME}" \
     --addon-name amazon-cloudwatch-observability --region "${AWS_REGION}" >/dev/null 2>&1; then
  ok "amazon-cloudwatch-observability addon already installed"
else
  log "Creating the IRSA role for the CloudWatch agent"
  eksctl create iamserviceaccount \
    --name cloudwatch-agent \
    --namespace amazon-cloudwatch \
    --cluster "${CLUSTER_NAME}" \
    --region "${AWS_REGION}" \
    --role-name "${PROJECT}-cloudwatch-agent" \
    --attach-policy-arn arn:aws:iam::aws:policy/CloudWatchAgentServerPolicy \
    --role-only --approve 2>/dev/null || warn "role may already exist"

  log "Installing the observability addon"
  aws eks create-addon \
    --cluster-name "${CLUSTER_NAME}" \
    --addon-name amazon-cloudwatch-observability \
    --region "${AWS_REGION}" \
    --service-account-role-arn "arn:aws:iam::${AWS_ACCOUNT_ID}:role/${PROJECT}-cloudwatch-agent" \
    --resolve-conflicts OVERWRITE >/dev/null

  log "Waiting for the addon to become ACTIVE"
  aws eks wait addon-active \
    --cluster-name "${CLUSTER_NAME}" \
    --addon-name amazon-cloudwatch-observability \
    --region "${AWS_REGION}"
  ok "Container Insights active"
fi

kubectl get pods -n amazon-cloudwatch 2>/dev/null || warn "amazon-cloudwatch namespace not ready yet"

# ---------------------------------------------------------------------------
log "2/5  Application log parsing rules"
# ---------------------------------------------------------------------------
# Layers our own parsers on top of the addon's Fluent Bit so JSON log lines
# from the Node services land in CloudWatch as structured fields rather than
# one opaque string.
kubectl apply -f "${SCRIPT_DIR}/fluent-bit-custom.yaml"
ok "custom parsers applied"

# ---------------------------------------------------------------------------
log "3/5  Log group retention"
# ---------------------------------------------------------------------------
# Container Insights creates these on first write. Without an explicit
# retention they keep data forever, which is the single most common way a
# demo cluster generates a surprising bill.
for suffix in application dataplane host performance; do
  GROUP="/aws/containerinsights/${CLUSTER_NAME}/${suffix}"
  aws logs create-log-group --log-group-name "${GROUP}" --region "${AWS_REGION}" 2>/dev/null || true
  aws logs put-retention-policy --log-group-name "${GROUP}" \
    --retention-in-days 30 --region "${AWS_REGION}" 2>/dev/null \
    && ok "retention 30d on ${GROUP}" || warn "could not set retention on ${GROUP}"
done

# ---------------------------------------------------------------------------
log "4/5  Metric filters — turn error logs into a graphable metric"
# ---------------------------------------------------------------------------
APP_LOG_GROUP="/aws/containerinsights/${CLUSTER_NAME}/application"

aws logs put-metric-filter \
  --region "${AWS_REGION}" \
  --log-group-name "${APP_LOG_GROUP}" \
  --filter-name "${PROJECT}-application-errors" \
  --filter-pattern '?ERROR ?Error ?"Unhandled" ?"UnhandledPromiseRejection"' \
  --metric-transformations \
    "metricName=ApplicationErrors,metricNamespace=${PROJECT},metricValue=1,defaultValue=0" \
  2>/dev/null && ok "error metric filter created" || warn "metric filter failed (log group may not exist yet — re-run after the first deploy)"

aws logs put-metric-filter \
  --region "${AWS_REGION}" \
  --log-group-name "${APP_LOG_GROUP}" \
  --filter-name "${PROJECT}-mongo-connection-errors" \
  --filter-pattern '"MongoServerError" ?"MongoNetworkError" ?"ECONNREFUSED"' \
  --metric-transformations \
    "metricName=DatabaseConnectionErrors,metricNamespace=${PROJECT},metricValue=1,defaultValue=0" \
  2>/dev/null && ok "database error metric filter created" || warn "metric filter failed"

# ---------------------------------------------------------------------------
log "5/5  Dashboard and alarms"
# ---------------------------------------------------------------------------
"${SCRIPT_DIR}/create-dashboard.sh"
"${SCRIPT_DIR}/create-alarms.sh"

cat <<EOF

Monitoring is live.

  Metrics    https://${AWS_REGION}.console.aws.amazon.com/cloudwatch/home?region=${AWS_REGION}#container-insights:infrastructure
  Dashboard  https://${AWS_REGION}.console.aws.amazon.com/cloudwatch/home?region=${AWS_REGION}#dashboards:name=${PROJECT}-overview
  Logs       https://${AWS_REGION}.console.aws.amazon.com/cloudwatch/home?region=${AWS_REGION}#logsV2:log-groups/log-group/\$252Faws\$252Fcontainerinsights\$252F${CLUSTER_NAME}\$252Fapplication
  Alarms     https://${AWS_REGION}.console.aws.amazon.com/cloudwatch/home?region=${AWS_REGION}#alarmsV2:

Container Insights metrics take 5-10 minutes to start appearing.

EOF
