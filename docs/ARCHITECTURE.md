# System Architecture

StreamFlix is a MERN video-streaming platform decomposed into four Node
microservices plus a React SPA, deployed to Amazon EKS behind an Application
Load Balancer, built and released by Jenkins, and observed through CloudWatch.

![Architecture](diagrams/architecture.png)

---

## 1. Components

| Component | Port | Responsibility | Scaling |
|---|---|---|---|
| **frontend** | 8080 | React SPA served by nginx, which also reverse-proxies every backend | HPA 3 → 12 |
| **auth-service** | 3001 | Registration, login, bcrypt hashing, JWT issuance | HPA 3 → 12 |
| **streaming-service** | 3002 | Video catalogue, S3 presigned playback URLs | HPA 3 → 20 |
| **admin-service** | 3003 | Video ingestion, metadata, featured curation | 2 replicas, no HPA |
| **chat-service** | 3004 | Socket.IO watch-party chat + REST history | **1 replica** (see §6) |
| **mongodb** | 27017 | Shared datastore, StatefulSet on encrypted gp3 EBS | 1 replica (see §7) |

Supporting cluster components: AWS Load Balancer Controller, metrics-server,
Cluster Autoscaler, CloudWatch Agent, Fluent Bit, EBS CSI driver.

---

## 2. Network topology

```
Internet
   │
   ▼
ALB (public subnets, 2 AZs, target-type: ip)
   │  single target group → frontend pods
   ▼
frontend pod (nginx :8080)
   ├── /                     → React SPA (try_files → index.html)
   ├── /svc/auth/*           → auth-service:3001
   ├── /svc/streaming/*      → streaming-service:3002
   ├── /svc/admin/*          → admin-service:3003
   ├── /svc/chat/*           → chat-service:3004
   └── /socket.io/*          → chat-service:3004 (WebSocket upgrade)
                                   │
                                   ▼
                            MongoDB StatefulSet
```

Nodes sit in **private subnets** and reach the internet through a single NAT
gateway. Only the ALB is publicly addressable.

### Why one ALB target instead of path-based routing to five services

This is the most consequential design decision in the deployment, so it is
worth stating the reasoning.

The obvious alternative is five Ingress path rules, one per service, giving the
ALB five target groups. That was rejected for three reasons:

1. **CORS disappears.** With everything on one origin the browser never sends a
   preflight and the services' `CLIENT_URLS` allow-lists stop mattering. The
   alternative means keeping four independent CORS configurations in sync with
   whatever hostname the ALB happened to get.
2. **The React build becomes portable.** Create React App inlines every
   `REACT_APP_*` value at *build* time. If the API URLs are absolute, the image
   is pinned to one environment and has to be rebuilt to promote. With relative
   paths (`/svc/auth/api`) the exact same image runs locally under
   docker-compose and in production on EKS.
3. **One health check.** The ALB has a single target group to reason about
   instead of five, which makes "is the app up?" a question with one answer.

The cost is one extra network hop (ALB → nginx → service) and the frontend
becoming a availability dependency for the APIs. Both are acceptable here:
the hop is sub-millisecond inside the VPC, and the frontend runs 3+ replicas
across AZs with its own HPA.

---

## 3. Request flow

![Request flow](diagrams/request-flow.png)

Note the media path: the streaming service returns **presigned S3 URLs** and
the browser fetches video bytes straight from S3. Video never transits the
cluster, so the pods stay small and playback bandwidth does not compete with
API traffic.

---

## 4. CI/CD

![CI/CD pipeline](diagrams/cicd-pipeline.png)

A push to `main` fires a GitHub webhook. Jenkins tags the build
`build-<number>-<short-sha>`, lints, builds and pushes all five images **in
parallel**, scans them, then runs `helm upgrade --install --atomic --wait`.

`--atomic` is the important flag: if any pod fails to become ready inside the
12-minute timeout, Helm rolls the entire release back to the previous revision.
A bad build never leaves the cluster in a half-upgraded state.

Two subtleties in the deploy stage:

- **Secrets are read back out of the cluster before each upgrade.** Minting a
  fresh `JWT_SECRET` every deploy would sign out every logged-in user; minting
  a fresh MongoDB password would lock the app out of its own database on the
  second deploy, because the PVC already has the first password baked into it.
- **Image tags are unique per build.** Deploying `:latest` would make
  `helm upgrade` a no-op whenever no other value changed — the Deployment spec
  would be byte-identical and Kubernetes would not roll the pods.

---

## 5. Security posture

| Layer | Control |
|---|---|
| Images | Multi-stage builds, `npm ci --omit=dev`, non-root UID 10001, `tini` as PID 1, ECR scan-on-push, Trivy in the pipeline |
| Pods | `runAsNonRoot`, `allowPrivilegeEscalation: false`, all capabilities dropped, `seccompProfile: RuntimeDefault` |
| AWS access | **IRSA** — pods assume `streamingapp-app-irsa` via a projected token. No static AWS keys exist anywhere in the cluster |
| Secrets | `JWT_SECRET` and `MONGO_URI` (which embeds the DB password) live in a Kubernetes Secret, never a ConfigMap |
| Network | Nodes in private subnets; optional NetworkPolicies for default-deny plus explicit frontend→backend→mongo allows |
| Data | S3 bucket: public access blocked, SSE-AES256. EBS volumes encrypted. TLS at the ALB when an ACM cert is supplied |
| CI | Jenkins uses an EC2 instance profile scoped to `streamingapp/*` ECR repos and `streamingapp-*` SNS topics — no long-lived keys |

### Known gaps

Being explicit about what is *not* production-grade here:

- **Secrets are passed via `--set`**, which puts them in the Helm release
  history and in the Jenkins process table. Real production wants External
  Secrets Operator or the AWS Secrets Manager CSI driver.
- **MongoDB is a single pod.** See §7.
- **NetworkPolicy is off by default** because the VPC CNI needs
  `ENABLE_NETWORK_POLICY=true` to enforce it. The manifests are written and
  render correctly, but they have not been exercised against a CNI that
  actually enforces them, so treat them as a starting point rather than a
  proven policy set.
- **No WAF** in front of the ALB.

---

## 6. The chat service runs one replica — on purpose

Socket.IO holds long-lived connections and broadcasts through an **in-process**
room registry. With two replicas, two users in the same watch party can land on
different pods and simply never see each other's messages. There is no error,
no log line — the feature is just silently half-broken, which is worse than an
outage.

Sticky sessions do not fix it either: nginx proxies from a handful of frontend
pods, so source-IP affinity would pin nearly all chat traffic onto one pod
anyway.

The correct fix is `@socket.io/redis-adapter` backed by ElastiCache, which
moves the room registry out of process. That is out of scope here, so the chart
pins `chat.replicaCount: 1` with the reasoning written into `values.yaml`
rather than quietly setting 2 and shipping a subtle bug.

---

## 7. Data tier trade-off

MongoDB runs as a **single-replica StatefulSet** on an encrypted gp3 EBS volume
with `reclaimPolicy: Retain`.

| | In-cluster StatefulSet (chosen) | Amazon DocumentDB | MongoDB Atlas |
|---|---|---|---|
| Cost | ~$4/mo (EBS only) | ~$200/mo minimum | Free tier available |
| HA | None — one pod, one AZ | Multi-AZ, automatic failover | Multi-AZ |
| Backups | Manual `mongodump` | Automated, PITR | Automated |
| Ops burden | Yours | Managed | Managed |

The StatefulSet was chosen because this is a cost-bounded project deployment
and it keeps everything reproducible from one `helm install`. The chart makes
switching a one-line change:

```yaml
mongodb:
  enabled: false
  externalUri: "mongodb://user:pass@docdb-cluster.ap-south-1.docdb.amazonaws.com:27017/streamingapp?tls=true&replicaSet=rs0"
```

Because the connection string is the only coupling, nothing else in the chart
changes.

**What single-replica actually costs you:** the pod's AZ going down takes the
whole platform offline until the EBS volume can be reattached, and there is no
point-in-time recovery. For a graded deployment that is the right call; for
real users it is not.

---

## 8. Scaling behaviour

**Pods.** HorizontalPodAutoscalers on frontend, auth and streaming, driven by
metrics-server, targeting 60–70% CPU with memory as a secondary signal. The
`behavior` block scales *up* aggressively (100% or +2 pods per 30 s, 30 s
stabilisation) and *down* slowly (50% per minute, 300 s stabilisation) so a
brief traffic lull does not thrash the fleet.

**Nodes.** Cluster Autoscaler watches for unschedulable pods and grows the
managed node group from 3 to 5 `t3.medium` instances.

**Availability.** `topologySpreadConstraints` keep replicas of a component in
different AZs. PodDisruptionBudgets (`minAvailable: 1`) are emitted only for
components running more than one replica — a PDB on a single-replica Deployment
blocks node drains indefinitely, which turns a routine cluster upgrade into an
incident.

**Rollouts.** `maxUnavailable: 0, maxSurge: 1` plus a `preStop: sleep 10` hook.
The sleep matters: it gives the endpoint controller time to remove the pod from
the Service before the process starts shutting down, which is what eliminates
the burst of 502s that otherwise accompanies every deploy.

---

## 9. Observability

**Metrics** — CloudWatch Container Insights (managed EKS addon) collects
cluster, node, pod and container metrics.

**Logs** — Fluent Bit ships every container's stdout to
`/aws/containerinsights/streamingapp-eks/application` with 30-day retention.
Custom parsers promote JSON log lines and morgan access logs to structured
fields so Logs Insights can query on `level`, `status` and `latency_ms`
directly.

**Derived metrics** — log metric filters turn error lines into the graphable
`ApplicationErrors` and `DatabaseConnectionErrors` metrics.

**Alarms** — 21+ alarms across cluster capacity, per-service restarts and
resource use, application error rate, and ALB 5xx/latency/unhealthy targets.

**Dashboard** — one `streamingapp-overview` dashboard with ten widgets,
including a live tail of error log lines.

**ChatOps** — CloudWatch alarms and Jenkins build outcomes both publish to SNS;
a Lambda renders them as Slack Block Kit messages.

Full detail in [`monitoring/README.md`](../monitoring/README.md).

---

## 10. Cost estimate (ap-south-1, running 24/7)

| Item | Monthly |
|---|---|
| EKS control plane | ~$73 |
| 3 × t3.medium nodes | ~$90 |
| NAT gateway (single) | ~$35 + data |
| ALB | ~$20 + LCU |
| EBS (3 × 40 GB nodes + 50 GB mongo) | ~$14 |
| Jenkins t3.medium | ~$30 |
| ECR, S3, CloudWatch, SNS, Lambda | ~$5–15 |
| **Total** | **~$270/month** |

For a graded project this is *not* a bill you want to accrue. Run
`./infra/scripts/99-teardown.sh` as soon as you have your screenshots — an idle
cluster costs the same as a busy one.
