#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# CloudWatch alarms for the StreamingApp platform, all routed to the SNS topic
# the ChatOps Lambda subscribes to.
#
#   ./monitoring/create-alarms.sh
#
# Every alarm sets treat-missing-data explicitly. The default ("missing" is
# neither breach nor OK) means an alarm on a metric that stops being published
# — which is exactly what happens when a service dies — silently stays green.
# ---------------------------------------------------------------------------
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../infra/env.sh
source "${SCRIPT_DIR}/../infra/env.sh"

require_cmd aws jq
require_account

ALARM_TOPIC_ARN="arn:aws:sns:${AWS_REGION}:${AWS_ACCOUNT_ID}:${SNS_TOPIC_ALARMS}"

if ! aws sns get-topic-attributes --topic-arn "${ALARM_TOPIC_ARN}" --region "${AWS_REGION}" >/dev/null 2>&1; then
  warn "SNS topic ${SNS_TOPIC_ALARMS} does not exist yet — run chatops/setup-chatops.sh first"
  warn "creating the alarms anyway; they will start notifying once the topic exists"
fi

CI_NS="ContainerInsights"

# put_alarm <name> <description> <namespace> <metric> <stat> <period> <evals> <op> <threshold> <missing> [dimensions...]
put_alarm() {
  local name="$1" desc="$2" ns="$3" metric="$4" stat="$5" period="$6" evals="$7" op="$8" threshold="$9" missing="${10}"
  shift 10
  local dims=("$@")

  local args=(
    --region "${AWS_REGION}"
    --alarm-name "${PROJECT}-${name}"
    --alarm-description "${desc}"
    --namespace "${ns}"
    --metric-name "${metric}"
    --statistic "${stat}"
    --period "${period}"
    --evaluation-periods "${evals}"
    --comparison-operator "${op}"
    --threshold "${threshold}"
    --treat-missing-data "${missing}"
    --alarm-actions "${ALARM_TOPIC_ARN}"
    --ok-actions "${ALARM_TOPIC_ARN}"
  )
  # Only append --dimensions when there are dimensions; an empty array
  # expansion under `set -u` would abort the script.
  if [[ ${#dims[@]} -gt 0 ]]; then
    args+=(--dimensions "${dims[@]}")
  fi

  aws cloudwatch put-metric-alarm "${args[@]}"
  ok "alarm: ${PROJECT}-${name}"
}

log "Cluster-level alarms"

put_alarm "cluster-cpu-high" \
  "Cluster CPU above 80% for 10 minutes — the node group is close to saturated" \
  "${CI_NS}" node_cpu_utilization Average 300 2 GreaterThanThreshold 80 breaching \
  "Name=ClusterName,Value=${CLUSTER_NAME}"

put_alarm "cluster-memory-high" \
  "Cluster memory above 85% for 10 minutes — pods risk being OOMKilled" \
  "${CI_NS}" node_memory_utilization Average 300 2 GreaterThanThreshold 85 breaching \
  "Name=ClusterName,Value=${CLUSTER_NAME}"

put_alarm "node-disk-high" \
  "Node filesystem above 85% — the kubelet will start evicting pods at 90%" \
  "${CI_NS}" node_filesystem_utilization Average 300 2 GreaterThanThreshold 85 breaching \
  "Name=ClusterName,Value=${CLUSTER_NAME}"

put_alarm "cluster-failed-nodes" \
  "One or more nodes are NotReady" \
  "${CI_NS}" cluster_failed_node_count Maximum 300 1 GreaterThanThreshold 0 notBreaching \
  "Name=ClusterName,Value=${CLUSTER_NAME}"

log "Per-service alarms"

for svc in frontend auth streaming admin chat; do
  DEPLOY="${HELM_RELEASE}-${svc}"

  # Pods that keep restarting are the clearest early signal of a bad release.
  put_alarm "${svc}-pod-restarts" \
    "${svc}: containers restarting — likely a crash loop or a failing liveness probe" \
    "${CI_NS}" pod_number_of_container_restarts Sum 300 1 GreaterThanThreshold 3 notBreaching \
    "Name=ClusterName,Value=${CLUSTER_NAME}" \
    "Name=Namespace,Value=${K8S_NAMESPACE}" \
    "Name=PodName,Value=${DEPLOY}"

  put_alarm "${svc}-cpu-high" \
    "${svc}: pod CPU above 85% — check whether the HPA is at its ceiling" \
    "${CI_NS}" pod_cpu_utilization Average 300 2 GreaterThanThreshold 85 notBreaching \
    "Name=ClusterName,Value=${CLUSTER_NAME}" \
    "Name=Namespace,Value=${K8S_NAMESPACE}" \
    "Name=PodName,Value=${DEPLOY}"

  put_alarm "${svc}-memory-high" \
    "${svc}: pod memory above 90% of its limit — OOMKill is imminent" \
    "${CI_NS}" pod_memory_utilization Average 300 2 GreaterThanThreshold 90 notBreaching \
    "Name=ClusterName,Value=${CLUSTER_NAME}" \
    "Name=Namespace,Value=${K8S_NAMESPACE}" \
    "Name=PodName,Value=${DEPLOY}"
done

log "Application log alarms"

put_alarm "application-errors" \
  "More than 10 ERROR log lines in 5 minutes across the platform" \
  "${PROJECT}" ApplicationErrors Sum 300 1 GreaterThanThreshold 10 notBreaching

put_alarm "database-errors" \
  "MongoDB connection errors appearing in the application logs" \
  "${PROJECT}" DatabaseConnectionErrors Sum 300 1 GreaterThanThreshold 0 notBreaching

log "Load balancer alarms"
# The ALB name is only known after the Ingress is created, so this alarm is
# best-effort — skipped cleanly when nothing is deployed yet.
ALB_ARN="$(aws elbv2 describe-load-balancers --region "${AWS_REGION}" \
  --query "LoadBalancers[?contains(LoadBalancerName, '${PROJECT}')].LoadBalancerArn | [0]" \
  --output text 2>/dev/null || echo "None")"

if [[ "${ALB_ARN}" != "None" && -n "${ALB_ARN}" ]]; then
  ALB_DIM="$(echo "${ALB_ARN}" | sed 's|.*:loadbalancer/||')"

  put_alarm "alb-5xx" \
    "ALB returning 5xx responses — the frontend or a backend is failing" \
    AWS/ApplicationELB HTTPCode_ELB_5XX_Count Sum 300 1 GreaterThanThreshold 10 notBreaching \
    "Name=LoadBalancer,Value=${ALB_DIM}"

  put_alarm "alb-target-latency" \
    "p95 response time above 2 seconds" \
    AWS/ApplicationELB TargetResponseTime Average 300 2 GreaterThanThreshold 2 notBreaching \
    "Name=LoadBalancer,Value=${ALB_DIM}"

  put_alarm "alb-unhealthy-hosts" \
    "The ALB has unhealthy targets — pods are failing their health check" \
    AWS/ApplicationELB UnHealthyHostCount Maximum 60 3 GreaterThanThreshold 0 notBreaching \
    "Name=LoadBalancer,Value=${ALB_DIM}"
else
  warn "no ALB found for ${PROJECT} — re-run this script after the first deploy to add the load balancer alarms"
fi

log "Alarm inventory"
aws cloudwatch describe-alarms --region "${AWS_REGION}" \
  --alarm-name-prefix "${PROJECT}-" \
  --query 'MetricAlarms[].{Name:AlarmName,State:StateValue,Metric:MetricName}' \
  --output table
