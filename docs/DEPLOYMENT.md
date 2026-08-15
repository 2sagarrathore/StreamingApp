# Deployment Runbook

End-to-end, from an empty AWS account to a running platform. Roughly 45 minutes
of wall-clock time, most of it waiting on CloudFormation.

Every script is idempotent — re-running one is safe.

---

## Prerequisites

- An AWS account with admin (or the equivalents listed in step 1)
- A GitHub account
- A machine with bash (your laptop, an EC2 box, or CloudShell)

---

## Step 1 — Fork and clone

```bash
# Fork https://github.com/UnpredictablePrashant/StreamingApp on GitHub first
git clone https://github.com/<your-username>/StreamingApp.git
cd StreamingApp

# Track the original so you can pull updates later
git remote add upstream https://github.com/UnpredictablePrashant/StreamingApp.git
git remote -v
```

Syncing with upstream later:

```bash
git fetch upstream
git checkout main
git merge upstream/main      # or: git rebase upstream/main
git push origin main
```

---

## Step 2 — Install the toolchain

```bash
./infra/scripts/00-prereqs.sh
```

Installs AWS CLI v2, kubectl, eksctl, Helm 3, Docker, jq. Log out and back in
afterwards so your shell picks up the `docker` group.

Verify:

```bash
aws --version && kubectl version --client && eksctl version && helm version --short && docker --version
```

---

## Step 3 — Configure AWS

```bash
./infra/scripts/10-configure-aws.sh
```

Prompts for credentials only if none are found, then proves ECR and EKS are
reachable.

Everything downstream reads its configuration from
[`infra/env.sh`](../infra/env.sh). Change the region, cluster name or instance
types there — not in the individual scripts.

```bash
# to deploy somewhere other than ap-south-1:
export AWS_REGION=us-east-1
```

### Building on Apple Silicon

Container images must match the CPU architecture of the worker nodes. An
`arm64` image on an `x86_64` node fails with `exec format error`, which
surfaces as a crash loop with no useful message in the logs — one of the more
annoying ways to lose an afternoon.

If you build on an Apple Silicon Mac, run everything as `arm64` and skip
cross-compilation entirely:

```bash
export NODE_ARCH=arm64      # nodes become t4g.medium, builds target linux/arm64
```

On an Intel machine, an EC2 builder or Jenkins, leave it alone — the default is
`x86_64` / `t3.medium` / `linux/amd64`.

`t4g` instances are Graviton-based and run roughly 10% cheaper than the `t3`
equivalents, so `arm64` is a small win regardless of where you build.

---

## Step 4 — Create the ECR repositories

```bash
./infra/scripts/20-create-ecr.sh
```

Creates five repositories with scan-on-push, AES256 encryption, and a lifecycle
policy that expires untagged layers after a day and keeps the 20 newest builds.

To also build and push an initial image set right now (useful for testing before
Jenkins exists):

```bash
./infra/scripts/20-create-ecr.sh --push
```

---

## Step 5 — Create the EKS cluster

```bash
./infra/scripts/30-create-eks.sh          # 15-20 minutes
```

This creates the S3 media bucket, renders
[`infra/eksctl-cluster.yaml`](../infra/eksctl-cluster.yaml), and builds:

- A dedicated VPC (10.42.0.0/16), public + private subnets across 2 AZs
- A managed node group: 3 × t3.medium, min 2 / max 5, private networking
- An OIDC provider and IRSA roles for the app, ALB controller, Fluent Bit,
  CloudWatch agent and Cluster Autoscaler
- Managed addons: vpc-cni, coredns, kube-proxy, aws-ebs-csi-driver
- Control-plane logging to CloudWatch

Verify:

```bash
kubectl get nodes -o wide
eksctl get cluster --name streamingapp-eks --region ap-south-1
```

> **If it fails partway:** eksctl works through CloudFormation, so a failed run
> leaves a stack in `ROLLBACK_COMPLETE`. Delete it in the CloudFormation console
> before retrying, or `eksctl delete cluster --name streamingapp-eks` first.
> Re-running on top of a wedged stack produces confusing errors.

---

## Step 6 — Install the cluster add-ons

```bash
./infra/scripts/40-cluster-addons.sh
```

Installs the AWS Load Balancer Controller, metrics-server, Cluster Autoscaler,
and a gp3 StorageClass (promoted to default, demoting gp2).

Verify:

```bash
kubectl get pods -n kube-system
kubectl get sc                     # gp3 should be (default)
kubectl top nodes                  # proves metrics-server works
```

`kubectl top nodes` failing with `Metrics API not available` just means
metrics-server is still warming up. Give it 60 seconds. If it never works, the
HPAs will never scale.

---

## Step 7 — Deploy the application

```bash
IMAGE_TAG=latest ./infra/scripts/60-deploy.sh
```

Generates (or reuses) the JWT and MongoDB secrets, wires up the IRSA role
annotation, runs `helm upgrade --install --atomic`, runs the chart's smoke test,
and prints the ALB URL.

Verify:

```bash
kubectl get pods -n streamingapp
kubectl get ingress -n streamingapp
helm test streamingapp -n streamingapp --logs
```

The ALB takes 2–4 minutes to provision and another 1–2 for its targets to pass
health checks. `curl` returning 503 during that window is expected.

---

## Step 8 — Set up monitoring

```bash
./monitoring/setup-monitoring.sh
```

Container Insights, Fluent Bit, log retention, metric filters, the dashboard,
and 24 alarms.

Metrics take 5–10 minutes to start appearing.

---

## Step 9 — Set up Jenkins

Full detail in [`jenkins/README.md`](../jenkins/README.md). Short version:

```bash
# On a fresh t3.medium EC2 instance:
sudo ./jenkins/setup-jenkins-ec2.sh

# Back on your workstation:
./infra/scripts/50-jenkins-iam.sh --instance-profile
aws ec2 associate-iam-instance-profile \
  --instance-id <i-xxxx> --iam-instance-profile Name=streamingapp-jenkins-role
```

Then in the Jenkins UI: install the plugins from `jenkins/plugins.txt`, add the
`aws-account-id` and `github-credentials` credentials, create a Multibranch
Pipeline against your fork, and add the GitHub webhook
`http://<jenkins>:8080/github-webhook/`.

Test it: push a trivial commit and watch a build start within seconds.

---

## Step 10 — Set up ChatOps (bonus)

```bash
SLACK_WEBHOOK_URL='https://hooks.slack.com/services/...' ./chatops/setup-chatops.sh
./monitoring/create-alarms.sh    # re-run so alarms point at the now-existing topic
```

---

## Step 11 — Validate

```bash
APP_URL=$(kubectl get ingress streamingapp -n streamingapp \
  -o jsonpath='{.status.loadBalancer.ingress[0].hostname}')

curl -sI  "http://$APP_URL/"                        # 200, text/html
curl -s   "http://$APP_URL/healthz"                 # {"status":"ok",...}
curl -s   "http://$APP_URL/svc/auth/health"
curl -s   "http://$APP_URL/svc/streaming/api/health"
curl -s   "http://$APP_URL/svc/admin/api/health"
curl -s   "http://$APP_URL/svc/chat/api/health"
```

Then in a browser at `http://$APP_URL`:

1. Register an account and log in
2. Browse the catalogue
3. Open a video and confirm playback
4. Open the same video in two tabs and confirm chat broadcasts between them
5. Upload a video through the admin dashboard (needs valid S3 credentials)

### Prove autoscaling works

```bash
kubectl run load-gen --rm -it --image=busybox:1.36 --restart=Never -n streamingapp -- \
  sh -c 'while true; do wget -q -O- http://streamingapp-auth:3001/health; done'

# in another terminal
kubectl get hpa -n streamingapp -w
```

`REPLICAS` should climb within a couple of minutes. Ctrl-C the load generator
and watch it scale back down after the 5-minute stabilisation window.

### Prove self-healing works

```bash
kubectl delete pod -n streamingapp -l app.kubernetes.io/component=auth --force
kubectl get pods -n streamingapp -w      # replacements come up immediately
```

---

## Step 12 — Tear down

```bash
./infra/scripts/99-teardown.sh
```

Uninstalls the release first (so the controller deletes the ALB), waits, then
deletes the cluster, ECR repos, SNS topics, alarms and dashboard. The S3 bucket
is deliberately left alone.

**Do this as soon as you are finished.** An idle EKS cluster costs the same as a
busy one — roughly $270/month for this setup.

Afterwards, confirm nothing was orphaned:

```bash
aws elbv2 describe-load-balancers --region ap-south-1 --query 'LoadBalancers[].LoadBalancerName'
aws ec2 describe-nat-gateways --region ap-south-1 --filter Name=state,Values=available
aws ec2 describe-volumes --region ap-south-1 --filters Name=status,Values=available
```

Orphaned ALBs and NAT gateways are the two things that survive a botched
teardown and keep billing quietly.

---

## Troubleshooting

| Symptom | Cause | Fix |
|---|---|---|
| Pods `Pending` | No node has room | `kubectl describe pod` — check for `Insufficient cpu`. Raise `NODE_DESIRED` or lower resource requests |
| Pods `ImagePullBackOff` | Node role cannot read ECR, or the tag does not exist | `aws ecr list-images --repository-name streamingapp/frontend`. The node group needs `imageBuilder: true` (it does by default) |
| Pods `CrashLoopBackOff` | Usually MongoDB unreachable | `kubectl logs -n streamingapp deploy/streamingapp-auth`. Check the mongo pod is `Running` and the `MONGO_URI` secret is right |
| Init container stuck on `wait-for-mongo` | MongoDB never became ready | `kubectl logs -n streamingapp streamingapp-mongodb-0` — often the PVC could not bind because no gp3 StorageClass exists |
| Ingress has no ADDRESS | ALB controller not running or lacking permissions | `kubectl logs -n kube-system deploy/aws-load-balancer-controller` |
| ALB returns 503 | Targets not healthy yet, or the health check path is wrong | `aws elbv2 describe-target-health --target-group-arn <arn>` |
| HPA shows `<unknown>/70%` | metrics-server not ready | `kubectl top pods -n streamingapp` |
| `helm upgrade` hangs then rolls back | A pod never became ready | `kubectl get events -n streamingapp --sort-by=.lastTimestamp` |
| PVC `Pending` | No default StorageClass | Re-run `40-cluster-addons.sh` |
| Chat messages not broadcasting | More than one chat replica | See [ARCHITECTURE.md §6](ARCHITECTURE.md#6-the-chat-service-runs-one-replica--on-purpose). Keep it at 1 |

### Failures hit during the real deployment

Every row below actually happened while deploying this project on 15 Aug 2026.
All are fixed in the repository; they are recorded because the error messages
are misleading enough to cost an afternoon if you meet them cold.

| Symptom | Real cause |
|---|---|
| `eksctl` fails instantly: `unknown field "cloudWatch"` | `wellKnownPolicies.cloudWatch` does not exist under `iam.serviceAccounts[]`. That key only exists under a nodegroup's `withAddonPolicies`. Attach `CloudWatchAgentServerPolicy` by ARN instead |
| `invalid version, 1.30 is no longer supported` | EKS retires minor versions on a rolling schedule. Check `aws eks describe-cluster-versions` before pinning |
| `another operation (install/upgrade/rollback) is in progress` | A previous run was killed mid-deploy. Helm's `pending-*` marker survives with nothing behind it. `60-deploy.sh` now clears the stale lock |
| Every service dies on `AuthenticationFailed` after a redeploy | `helm uninstall` removed the mongo Secret so a new password was minted, but the StatefulSet's PVC survived (`reclaimPolicy: Retain`) still holding the old one. Mongo only creates its root user against an empty data directory |
| admin pod `CrashLoopBackOff`, `EACCES … mkdir '/app/tmp-uploads'` | The service creates its multer scratch directory at module load, but runs as UID 10001 against a root-owned image. Mount an `emptyDir` there — `fsGroup` makes it group-writable |
| Ingress created but no ALB ever appears | A folded YAML scalar (`>-`) in the `load-balancer-attributes` annotation joins lines with spaces, so the controller sends ` routing.http2.enabled` to the ELB API and it is rejected as unknown. Keep that annotation on one line |
| `helm test` reports failure for a test that passed | `hook-delete-policy: hook-succeeded` deletes the pod before `--logs` can read it |
| Zero alarms created, monitoring otherwise fine | CloudWatch rejects `put-metric-alarm` when `--alarm-actions` names a topic that does not exist. The SNS topics must be created first — `run-project.sh` now runs ChatOps before monitoring |
| `Bus error (core dumped)` running kubectl | A truncated download. CloudShell's proxy fails with `HTTP/2 stream not closed cleanly: PROTOCOL_ERROR`; verify checksums and use `--http1.1` |
| Jenkins EC2: cloud-init "finished" in 41s with nothing installed | `dnf install curl` conflicts with AL2023's preinstalled `curl-minimal` and aborts the whole transaction |
| `jenkins.service` fails, five restarts, then gives up | Current Jenkins LTS requires Java 21. Installing Java 17 leaves it unable to start |
| Orphaned EBS volumes after teardown | `reclaimPolicy: Retain` protects data across redeploys and therefore strands the volume when the cluster is deleted |

### Diagnostic one-liners

```bash
# everything at once
kubectl get all -n streamingapp

# recent events, newest last
kubectl get events -n streamingapp --sort-by=.lastTimestamp | tail -30

# logs from every pod of one component
kubectl logs -n streamingapp -l app.kubernetes.io/component=auth --tail=100 --prefix

# what did the last deploy actually change
helm history streamingapp -n streamingapp
helm get values streamingapp -n streamingapp

# roll back
helm rollback streamingapp -n streamingapp

# shell into a running service
kubectl exec -it -n streamingapp deploy/streamingapp-auth -- sh

# reach a service without the ALB
kubectl port-forward -n streamingapp svc/streamingapp-frontend 8080:80
```
