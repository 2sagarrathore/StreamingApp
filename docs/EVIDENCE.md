# Validation Record

Step 8 of the project brief requires verification that the deployed platform is
functional and accessible. This document is the record of that verification.

Most of it is produced automatically. From the repository root:

```bash
./run-project.sh
```

That provisions everything in order and writes the real output of each step to
`docs/evidence/`, including endpoint checks, autoscaling behaviour under load,
self-healing, and a generated `validation-summary.md`. The handful of items
that only exist in a browser are listed in [§3](#3-browser-captures) and are
printed again at the end of the run.

---

## 1. Deployment details

Fill in from `docs/evidence/validation-summary.md` after the run.

| | |
|---|---|
| Date of run | |
| AWS region | |
| Cluster name | `streamingapp-eks` |
| Namespace | `streamingapp` |
| Application URL | |
| Image tag deployed | |

---

## 2. Automated checks

Each row is written by `run-project.sh`. Mark the result once the run finishes.

| # | Step | What is checked | Evidence file | Result |
|---|---|---|---|---|
| 1 | 3 | AWS CLI authenticates and resolves an identity | `docs/evidence/00-aws-identity.txt` | |
| 2 | 2 | Five ECR repositories exist with scan-on-push enabled | `docs/evidence/01-ecr-repositories.txt` | |
| 3 | 5 | EKS cluster is ACTIVE | `docs/evidence/02-eks-cluster.txt` | |
| 4 | 5 | Worker nodes are Ready across two availability zones | `docs/evidence/02-nodes.txt` | |
| 5 | 5 | gp3 is the default StorageClass | `docs/evidence/03-storageclass.txt` | |
| 6 | 5 | ALB controller, metrics-server and autoscaler are running | `docs/evidence/03-kube-system.txt` | |
| 7 | 5 | All five Deployments plus MongoDB are Running | `docs/evidence/04-workloads.txt` | |
| 8 | 5 | Helm release is deployed, with revision history | `docs/evidence/04-helm-release.txt`, `04-helm-history.txt` | |
| 9 | 5 | MongoDB PersistentVolumeClaim is Bound | `docs/evidence/04-pvc.txt` | |
| 10 | 5 | Ingress has an ALB address and healthy targets | `docs/evidence/04-ingress.txt` | |
| 11 | 6 | CloudWatch alarms exist and are in OK state | `docs/evidence/05-alarms.txt` | |
| 12 | 6 | Log groups exist with 30-day retention | `docs/evidence/05-log-groups.txt` | |
| 13 | 8 | Every public endpoint returns HTTP 200 | `docs/evidence/06-endpoint-checks.txt` | |
| 14 | 8 | Chart smoke test passes for all five components | `docs/evidence/06-helm-smoke-test.txt` | |
| 15 | 8 | A deleted pod is rescheduled automatically | `docs/evidence/07-self-healing.txt` | |
| 16 | 8 | HPA scales replicas up under sustained load | `docs/evidence/08-hpa-scaling.txt` | |
| 17 | 8 | Resource consumption is within configured limits | `docs/evidence/09-top-pods.txt` | |

---

## 3. Browser captures

These cannot be produced from a terminal. Save each to `docs/screenshots/`
with the filename shown.

| # | Step | What to capture | Filename |
|---|---|---|---|
| 18 | 1 | The fork on GitHub, showing it derives from `UnpredictablePrashant/StreamingApp` | `01-github-fork.png` |
| 19 | 4 | Jenkins dashboard with the pipeline job | `05-jenkins-dashboard.png` |
| 20 | 4 | A completed pipeline run in stage view, all stages green | `06-jenkins-pipeline.png` |
| 21 | 4 | A build whose cause is a GitHub push, proving the webhook trigger | `07-jenkins-webhook-trigger.png` |
| 22 | 6 | Container Insights showing live cluster metrics | `11-container-insights.png` |
| 23 | 6 | The `streamingapp-overview` dashboard with data | `12-cloudwatch-dashboard.png` |
| 24 | 8 | The application homepage at the ALB URL | `15-app-homepage.png` |
| 25 | 8 | Logged in, browsing the video catalogue | `16-app-catalogue.png` |
| 26 | 8 | A video playing back | `17-app-playback.png` |
| 27 | 8 | Chat broadcasting between two browser tabs | `18-app-chat.png` |
| 28 | 9 | Slack showing a deployment notification and an alarm notification | `22-slack-chatops.png` |

---

## 4. Notes and observations

Anything that behaved unexpectedly, and how it was resolved. A record of what
went wrong and why is worth as much as a record of what went right.

| Observation | Resolution |
|---|---|
| | |

---

## 5. Teardown

| | |
|---|---|
| Date torn down | |
| `99-teardown.sh` completed | |
| ALBs, NAT gateways and volumes confirmed removed | |

Confirm with:

```bash
aws elbv2 describe-load-balancers --region <region> --query 'LoadBalancers[].LoadBalancerName'
aws ec2 describe-nat-gateways --region <region> --filter Name=state,Values=available
aws ec2 describe-volumes --region <region> --filters Name=status,Values=available
```
