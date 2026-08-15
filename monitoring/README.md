# Monitoring & Logging

Step 6 of the brief. One command sets all of it up:

```bash
./monitoring/setup-monitoring.sh
```

## What gets installed

| Piece | How | What it gives you |
|---|---|---|
| **Container Insights** | EKS managed addon `amazon-cloudwatch-observability` | Cluster, node, pod and container CPU / memory / network / disk metrics in the `ContainerInsights` namespace |
| **Fluent Bit** | Ships with the same addon | Every container's stdout/stderr into CloudWatch Logs |
| **Custom parsers** | `fluent-bit-custom.yaml` | JSON log lines and morgan access logs promoted to structured fields |
| **Control-plane logs** | `cloudWatch.clusterLogging` in the eksctl config | API server, audit, authenticator, controller-manager, scheduler |
| **Metric filters** | `setup-monitoring.sh` | `ApplicationErrors` and `DatabaseConnectionErrors` custom metrics derived from log content |
| **Dashboard** | `create-dashboard.sh` | 10 widgets: cluster health, per-service CPU/memory, restarts, ALB traffic and latency, error rate, live error tail |
| **Alarms** | `create-alarms.sh` | 21+ alarms, all routed to the `streamingapp-alarms` SNS topic |

## Log groups

| Group | Contents | Retention |
|---|---|---|
| `/aws/containerinsights/streamingapp-eks/application` | Container stdout/stderr — this is where the app logs are | 30 days |
| `/aws/containerinsights/streamingapp-eks/dataplane` | kubelet, kube-proxy, container runtime | 30 days |
| `/aws/containerinsights/streamingapp-eks/host` | Node-level `/var/log/messages` | 30 days |
| `/aws/containerinsights/streamingapp-eks/performance` | The raw embedded-metric-format stream Insights builds its charts from | 30 days |
| `/aws/eks/streamingapp-eks/cluster` | Control-plane logs | 30 days |

Retention is set explicitly on purpose. CloudWatch log groups default to
*never expire*, and an EKS cluster left running with default retention is the
most common way a learning project produces an unpleasant bill.

## Alarms

**Cluster:** CPU > 80%, memory > 85%, disk > 85%, any node NotReady.

**Per service** (frontend, auth, streaming, admin, chat): container restarts > 3
in 5 min, pod CPU > 85%, pod memory > 90%.

**Application:** more than 10 ERROR lines in 5 min; any MongoDB connection error.

**Load balancer:** ELB 5xx > 10 in 5 min, p-average response time > 2 s, any
unhealthy target.

Every alarm sets `--treat-missing-data` explicitly. The default treats missing
data as neither breaching nor OK, which means an alarm on a metric that *stops
being published* — precisely what happens when a service dies — stays green
and tells you nothing. Cluster-level alarms use `breaching`; per-pod alarms use
`notBreaching`, because a pod legitimately disappears every time the HPA scales
in.

## Useful Logs Insights queries

Errors across the platform, newest first:

```
fields @timestamp, kubernetes.container_name as service, @message
| filter @message like /(?i)(error|exception|fatal)/
| sort @timestamp desc
| limit 100
```

Slowest API calls (needs the morgan parser):

```
fields @timestamp, kubernetes.container_name as service, method, path, status, latency_ms
| filter ispresent(latency_ms)
| sort latency_ms desc
| limit 50
```

Request volume per service per minute:

```
stats count(*) as requests by bin(1m), kubernetes.container_name as service
| sort @timestamp desc
```

Failed logins (auth service):

```
fields @timestamp, @message
| filter kubernetes.container_name = "auth"
| filter @message like /401|Invalid credentials/
| stats count(*) as failures by bin(5m)
```

## Verifying it works

```bash
# metrics flowing?
aws cloudwatch list-metrics --namespace ContainerInsights \
  --dimensions Name=ClusterName,Value=streamingapp-eks --region ap-south-1 | head -40

# logs flowing?
aws logs tail /aws/containerinsights/streamingapp-eks/application \
  --follow --region ap-south-1

# alarms healthy?
aws cloudwatch describe-alarms --alarm-name-prefix streamingapp- \
  --region ap-south-1 --query 'MetricAlarms[].{Name:AlarmName,State:StateValue}' --output table
```

Container Insights metrics take 5–10 minutes to appear after install. If the
`ContainerInsights` namespace is still empty after 15 minutes, check the agent:

```bash
kubectl get pods -n amazon-cloudwatch
kubectl logs -n amazon-cloudwatch -l app.kubernetes.io/name=cloudwatch-agent --tail=50
```

The usual cause is a missing IRSA annotation on the `cloudwatch-agent` service
account — `setup-monitoring.sh` creates that role, so re-running it fixes it.
