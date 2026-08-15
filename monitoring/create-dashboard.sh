#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Builds a single CloudWatch dashboard covering the whole platform: cluster
# health, per-service CPU/memory, pod counts, ALB traffic, and a live tail of
# application errors.
#
#   ./monitoring/create-dashboard.sh
# ---------------------------------------------------------------------------
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../infra/env.sh
source "${SCRIPT_DIR}/../infra/env.sh"

require_cmd aws jq
require_account

DASHBOARD_NAME="${PROJECT}-overview"

# Resolve the ALB dimension if the app is already deployed.
ALB_ARN="$(aws elbv2 describe-load-balancers --region "${AWS_REGION}" \
  --query "LoadBalancers[?contains(LoadBalancerName, '${PROJECT}')].LoadBalancerArn | [0]" \
  --output text 2>/dev/null || echo "None")"
if [[ "${ALB_ARN}" != "None" && -n "${ALB_ARN}" ]]; then
  ALB_DIM="$(echo "${ALB_ARN}" | sed 's|.*:loadbalancer/||')"
else
  ALB_DIM=""
  warn "no ALB found yet — the traffic widgets will be empty until the first deploy"
fi

# Build the per-service metric arrays with jq so quoting stays sane.
services='["frontend","auth","streaming","admin","chat"]'

cpu_metrics="$(jq -nc --arg c "${CLUSTER_NAME}" --arg ns "${K8S_NAMESPACE}" --arg r "${HELM_RELEASE}" --argjson s "${services}" '
  [ $s[] | ["ContainerInsights","pod_cpu_utilization","ClusterName",$c,"Namespace",$ns,"PodName",($r+"-"+.),{"label":.}] ]')"

mem_metrics="$(jq -nc --arg c "${CLUSTER_NAME}" --arg ns "${K8S_NAMESPACE}" --arg r "${HELM_RELEASE}" --argjson s "${services}" '
  [ $s[] | ["ContainerInsights","pod_memory_utilization","ClusterName",$c,"Namespace",$ns,"PodName",($r+"-"+.),{"label":.}] ]')"

restart_metrics="$(jq -nc --arg c "${CLUSTER_NAME}" --arg ns "${K8S_NAMESPACE}" --arg r "${HELM_RELEASE}" --argjson s "${services}" '
  [ $s[] | ["ContainerInsights","pod_number_of_container_restarts","ClusterName",$c,"Namespace",$ns,"PodName",($r+"-"+.),{"label":.}] ]')"

if [[ -n "${ALB_DIM}" ]]; then
  alb_traffic="$(jq -nc --arg d "${ALB_DIM}" '[
    ["AWS/ApplicationELB","RequestCount","LoadBalancer",$d,{"label":"requests","stat":"Sum"}],
    [".","HTTPCode_Target_2XX_Count",".",$d,{"label":"2xx","stat":"Sum"}],
    [".","HTTPCode_Target_4XX_Count",".",$d,{"label":"4xx","stat":"Sum"}],
    [".","HTTPCode_Target_5XX_Count",".",$d,{"label":"5xx","stat":"Sum"}]
  ]')"
  alb_latency="$(jq -nc --arg d "${ALB_DIM}" '[
    ["AWS/ApplicationELB","TargetResponseTime","LoadBalancer",$d,{"label":"p50","stat":"p50"}],
    ["...",{"label":"p95","stat":"p95"}],
    ["...",{"label":"p99","stat":"p99"}]
  ]')"
else
  alb_traffic='[]'
  alb_latency='[]'
fi

# Built here rather than inside the jq program: the Logs Insights SOURCE clause
# needs literal single quotes, which would terminate jq's single-quoted script.
APP_LOG_GROUP="/aws/containerinsights/${CLUSTER_NAME}/application"
LOG_QUERY="SOURCE '${APP_LOG_GROUP}'
| fields @timestamp, kubernetes.container_name as service, @message
| filter @message like /(?i)(error|exception|fatal)/
| sort @timestamp desc
| limit 50"

BODY="$(jq -nc \
  --arg region "${AWS_REGION}" \
  --arg logQuery "${LOG_QUERY}" \
  --arg cluster "${CLUSTER_NAME}" \
  --arg ns "${K8S_NAMESPACE}" \
  --arg project "${PROJECT}" \
  --argjson cpu "${cpu_metrics}" \
  --argjson mem "${mem_metrics}" \
  --argjson restarts "${restart_metrics}" \
  --argjson albTraffic "${alb_traffic}" \
  --argjson albLatency "${alb_latency}" '
{
  widgets: [
    { type:"text", x:0, y:0, width:24, height:1,
      properties:{ markdown:("# StreamFlix — " + $cluster + "  \n_Cluster health, per-service resource use, edge traffic, and live errors._") } },

    { type:"metric", x:0, y:1, width:8, height:6,
      properties:{ title:"Cluster CPU / Memory %", view:"timeSeries", region:$region, period:300, stat:"Average",
        yAxis:{ left:{ min:0, max:100 } },
        metrics:[
          ["ContainerInsights","node_cpu_utilization","ClusterName",$cluster,{label:"cpu"}],
          [".","node_memory_utilization",".",$cluster,{label:"memory"}],
          [".","node_filesystem_utilization",".",$cluster,{label:"disk"}]
        ] } },

    { type:"metric", x:8, y:1, width:8, height:6,
      properties:{ title:"Nodes & Pods", view:"timeSeries", region:$region, period:300, stat:"Average",
        metrics:[
          ["ContainerInsights","cluster_node_count","ClusterName",$cluster,{label:"nodes"}],
          [".","cluster_failed_node_count",".",$cluster,{label:"failed nodes"}],
          [".","namespace_number_of_running_pods","ClusterName",$cluster,"Namespace",$ns,{label:"running pods"}]
        ] } },

    { type:"metric", x:16, y:1, width:8, height:6,
      properties:{ title:"Container restarts (crash-loop signal)", view:"timeSeries", region:$region, period:300, stat:"Sum",
        metrics:$restarts } },

    { type:"metric", x:0, y:7, width:12, height:6,
      properties:{ title:"CPU % by service", view:"timeSeries", region:$region, period:300, stat:"Average",
        yAxis:{ left:{ min:0 } }, metrics:$cpu } },

    { type:"metric", x:12, y:7, width:12, height:6,
      properties:{ title:"Memory % by service", view:"timeSeries", region:$region, period:300, stat:"Average",
        yAxis:{ left:{ min:0 } }, metrics:$mem } },

    { type:"metric", x:0, y:13, width:12, height:6,
      properties:{ title:"ALB requests by response class", view:"timeSeries", region:$region, period:300, stat:"Sum",
        metrics:$albTraffic } },

    { type:"metric", x:12, y:13, width:12, height:6,
      properties:{ title:"ALB target response time", view:"timeSeries", region:$region, period:300,
        metrics:$albLatency } },

    { type:"metric", x:0, y:19, width:12, height:6,
      properties:{ title:"Application errors (from log metric filters)", view:"timeSeries", region:$region, period:300, stat:"Sum",
        metrics:[
          [$project,"ApplicationErrors",{label:"app errors"}],
          [$project,"DatabaseConnectionErrors",{label:"db errors"}]
        ] } },

    { type:"log", x:12, y:19, width:12, height:6,
      properties:{ title:"Recent error log lines", region:$region,
        query:$logQuery,
        view:"table" } }
  ]
}')"

log "Publishing dashboard ${DASHBOARD_NAME}"
aws cloudwatch put-dashboard \
  --region "${AWS_REGION}" \
  --dashboard-name "${DASHBOARD_NAME}" \
  --dashboard-body "${BODY}" >/dev/null

ok "https://${AWS_REGION}.console.aws.amazon.com/cloudwatch/home?region=${AWS_REGION}#dashboards:name=${DASHBOARD_NAME}"
