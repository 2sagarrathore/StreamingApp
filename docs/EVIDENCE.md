# Validation Record

Step 8 of the brief asks for verification that the deployed platform is
functional and accessible. This is the record of a real deployment, run against
a live AWS account on **15 August 2026** and torn down the same day.

Everything below is backed by a file in [`docs/evidence/`](evidence/) or an
image in [`docs/screenshots/`](screenshots/). Where something did not work, it
says so — see [§7](#7-what-did-not-work).

---

## 1. Deployment details

| | |
|---|---|
| Date of run | 2026-08-15, 11:31–11:41 UTC |
| AWS account | 400398151988 |
| AWS region | ap-south-1 (Mumbai) |
| Cluster | `streamingapp-eks`, Kubernetes **1.32** (`v1.32.13-eks-254016e`) |
| Nodes | 3 × t3.medium, private subnets, Amazon Linux 2023 |
| Namespace | `streamingapp` |
| Image tag | `build-20260815075746` (built by AWS CodeBuild) |
| Application URL | `http://k8s-streamingapp-ac32464491-1158707937.ap-south-1.elb.amazonaws.com` |
| Identity | `AWSReservedSSO_AdministratorAccess/SagarRathore` |

The ALB address is dead now — the environment was destroyed after capture, as
[§8](#8-teardown) records.

---

## 2. What was deployed

Nine pods, all `1/1 Running` — five services plus a MongoDB StatefulSet, each
backend at two replicas except admin, behind six ClusterIP Services and one
internet-facing ALB. Full listing in
[`04-workloads.txt`](evidence/04-workloads.txt).

| Component | Replicas | Image |
|---|---|---|
| frontend (nginx + React) | 2 | `…/streamingapp/frontend:build-20260815075746` |
| auth-service | 2 | `…/streamingapp/auth-service:build-20260815075746` |
| streaming-service | 2 | `…/streamingapp/streaming-service:build-20260815075746` |
| admin-service | 1 | `…/streamingapp/admin-service:build-20260815075746` |
| chat-service | 1 | `…/streamingapp/chat-service:build-20260815075746` |
| MongoDB | 1 (StatefulSet) | `mongo:6.0`, 20 GiB gp3 PVC |

---

## 3. Automated checks

| # | What was checked | Result | Evidence |
|---|---|---|---|
| 1 | Five ECR repositories exist, scan-on-push enabled | pass | [`01-ecr-repositories.txt`](evidence/01-ecr-repositories.txt) |
| 2 | Cluster active, three nodes `Ready` on 1.32 | pass | [`02-eks-cluster.txt`](evidence/02-eks-cluster.txt), [`02-nodes.txt`](evidence/02-nodes.txt) |
| 3 | gp3 is the default StorageClass, gp2 demoted | pass | [`03-storageclass.txt`](evidence/03-storageclass.txt) |
| 4 | ALB controller, metrics-server, autoscaler running | pass | [`03-kube-system.txt`](evidence/03-kube-system.txt) |
| 5 | Helm release deployed, all workloads healthy | pass | [`04-workloads.txt`](evidence/04-workloads.txt), [`04-helm-release.txt`](evidence/04-helm-release.txt) |
| 6 | MongoDB PVC bound on gp3 | pass | [`04-pvc.txt`](evidence/04-pvc.txt) |
| 7 | Ingress provisioned a real ALB with healthy targets | pass | [`04-ingress.txt`](evidence/04-ingress.txt) |
| 8 | SNS topics created before alarms reference them | pass | [`05-chatops.log`](evidence/05-chatops.log) |
| 9 | Container Insights, Fluent Bit, dashboard, alarms | pass | [`06-monitoring.log`](evidence/06-monitoring.log), [`06-alarms.txt`](evidence/06-alarms.txt) |
| 10 | Four log groups at 30-day retention | pass | [`06-log-groups.txt`](evidence/06-log-groups.txt) |
| 11 | Every endpoint answers through the ALB | pass | [`07-endpoint-checks.txt`](evidence/07-endpoint-checks.txt) |
| 12 | Deleted pod is rescheduled automatically | pass | [`08-self-healing.txt`](evidence/08-self-healing.txt) |
| 13 | HPA scales out under sustained load | pass | [`09-hpa-scaling.txt`](evidence/09-hpa-scaling.txt) |
| 14 | Resource utilisation and cluster events | pass | [`10-top-pods.txt`](evidence/10-top-pods.txt), [`10-events.txt`](evidence/10-events.txt) |
| 15 | Helm smoke test | see [§7](#7-what-did-not-work) | [`07-helm-smoke-test.txt`](evidence/07-helm-smoke-test.txt) |
| 16 | Jenkins pipeline build | **not achieved** | [`11-jenkins.txt`](evidence/11-jenkins.txt) |

### Endpoint checks, in full

Measured through the load balancer, not from inside the cluster:

```
/                            HTTP 200     <title>StreamFlix</title>
/healthz                     HTTP 200     {"status":"ok","component":"frontend"}
/svc/auth/health             HTTP 200     {"status":"OK"}
/svc/streaming/api/health    HTTP 200     {"msg":"OK"}
/svc/admin/api/health        HTTP 200     {"success":true,"service":"admin","status":"ok"}
/svc/chat/api/chat           HTTP 404     (expected — chat is Socket.IO on /socket.io)
```

These four backends answering under `/svc/*` on the same origin as the SPA is
the whole point of the nginx reverse-proxy design: one ALB target group, one
health check, no CORS.

### Self-healing

An auth pod was deleted outright. Kubernetes scheduled a replacement that was
`1/1 Running` **32 seconds** later, with the second replica serving throughout —
so the deletion was invisible to users.

### Autoscaling

Four minutes of sustained load against the auth service:

```
before   streamingapp-auth   cpu: 1%/70%    replicas 2
during   streamingapp-auth   cpu: 67%/70%   replicas 4
after    streamingapp-auth   cpu: 63%/70%   replicas 4
```

The HPA scaled 2 → 4 as CPU approached its 70% target. frontend and streaming
stayed at 2, correctly, since the load was aimed only at auth.

---

## 4. Monitoring and logging

24 CloudWatch alarms across CPU, memory, pod restarts, ALB 5xx, target latency,
unhealthy hosts and log-derived error counts — 20 `OK` and 4 `INSUFFICIENT_DATA`
or `In alarm` at capture time. The `streamingapp-application-errors` alarm
firing is itself evidence that the log metric filter was matching real
application log lines end to end.

Four log groups, all at 30-day retention so they cannot bill indefinitely:

```
/aws/containerinsights/streamingapp-eks/application    30 days
/aws/containerinsights/streamingapp-eks/dataplane      30 days
/aws/containerinsights/streamingapp-eks/host           30 days
/aws/containerinsights/streamingapp-eks/performance    30 days
```

Both SNS topics (`streamingapp-deployments`, `streamingapp-alarms`) were created
and every alarm publishes to the alarms topic. The Slack Lambda is optional and
was not configured, since no webhook was supplied — the topics exist regardless,
which is what the alarm actions need.

---

## 5. Browser captures

17 screenshots in [`docs/screenshots/`](screenshots/), each mapped to the step
it evidences in [SCREENSHOTS.md](SCREENSHOTS.md): the running application, ECR
repositories and image tags, the EKS cluster and its nodes and workloads, the
ALB with healthy targets, CodeBuild, Container Insights, the CloudWatch
dashboard, log groups, application log lines, the 24 alarms, and the SNS topics.

---

## 6. How this was produced

```bash
./run-project.sh          # phases 01→10, writing docs/evidence/ as it goes
```

Each phase records a checkpoint under `docs/evidence/.state/`, so an interrupted
run resumes rather than repeating work — which mattered, because this run was
interrupted twice by session timeouts.

Images were built by **AWS CodeBuild** rather than a local Docker daemon
(`infra/scripts/25-build-images-codebuild.sh`). That was not the original
design; it exists because the deployment was driven from AWS CloudShell, which
has no Docker. It turned out to be the better default: builds happen next to
ECR, natively on x86_64, for about two cents a run.

---

## 7. What did not work

Recorded rather than quietly omitted.

**The Jenkins pipeline never ran.** The controller was provisioned, installed
and served HTTP 200, but plugin installation never completed, so
Configuration-as-Code never applied and the job was never created. Five
sequential causes are documented in [`11-jenkins.txt`](evidence/11-jenkins.txt);
two are fixed in this repository. Step 4 of the brief is therefore evidenced by
the pipeline definition (`Jenkinsfile`) and the provisioning automation
(`jenkins/`), not by a live build.

**The Helm smoke test reported a failure it did not have.** The test pod carried
`hook-delete-policy: hook-succeeded`, which deletes it the moment it passes — so
`helm test --logs` found nothing and reported failure for a test that had in
fact succeeded. Fixed in the chart; the fix landed after this run, so
[`07-helm-smoke-test.txt`](evidence/07-helm-smoke-test.txt) still shows the
misleading output. The same health checks pass in
[`07-endpoint-checks.txt`](evidence/07-endpoint-checks.txt).

**NetworkPolicies are written but unenforced.** The default VPC CNI does not
enforce them, so they render and apply without doing anything. `values-prod.yaml`
leaves them disabled deliberately rather than implying protection that is not
there.

---

## 8. Teardown

Everything was destroyed the same day. Verified zero afterwards: EKS clusters,
EC2 instances, NAT gateways, load balancers, ECR repositories, EBS volumes,
elastic IPs, CloudWatch alarms, SNS topics, CodeBuild projects, S3 buckets.

Two 20 GiB EBS volumes survived the first pass, because the gp3 StorageClass
uses `reclaimPolicy: Retain` — which protects the database across redeploys but
orphans the volume when the cluster is deleted. They were found in a manual
sweep and removed; `99-teardown.sh` now deletes volumes still tagged as owned by
the cluster, while unattached. Total cost of the exercise was roughly **$1**.

```bash
./infra/scripts/99-teardown.sh
```
