# Screenshot checklist

> **Note on the captures in this repository.** The 12 images in
> `docs/screenshots/` are from the 15 August 2026 deployment. Five further
> captures were taken and then discarded: two caught the wrong browser window,
> one an expired console session, one a blank page, and one showed a password
> manager overlay. They are not in the repository. Where a discarded capture was
> the only visual for a step, `docs/evidence/` carries the equivalent as captured
> command output.

`run-project.sh` captures everything that has a command-line form into
`docs/evidence/`. This file covers the rest — the console views that only exist
in a browser. Save each one into `docs/screenshots/` using the filename in the
first column, then commit the folder.

All links assume region **ap-south-1**. Nothing here needs to be done in any
particular order, but the app itself is worth capturing first: it is the only
one that disappears the moment you tear the cluster down.

## The application

| File | Where | What should be visible |
|---|---|---|
| `01-app-home.png` | The URL in `docs/evidence/app-url.txt` | The StreamFlix homepage rendering, served through the ALB |
| `02-app-signup.png` | `<app-url>/register` | The registration form — proves the React SPA routes and the auth service are both reachable |
| `03-app-healthz.png` | `<app-url>/healthz` | `{"status":"ok","component":"frontend"}` |

The ALB address takes a minute or two after the deploy before its targets pass
their health check. If you get a 502, wait and reload rather than assuming it
failed — `docs/evidence/07-endpoint-checks.txt` records what the run itself saw.

## Step 3 — containers and registry

| File | Where | What should be visible |
|---|---|---|
| `04-ecr-repositories.png` | [ECR repositories](https://ap-south-1.console.aws.amazon.com/ecr/repositories?region=ap-south-1) | All five `streamingapp/*` repositories |
| `05-ecr-images.png` | Any one repository, e.g. `streamingapp/frontend` | The image tags and pushed-at timestamps |

## Step 4 — CI/CD

| File | Where | What should be visible |
|---|---|---|
| `06-jenkins-dashboard.png` | The URL in `docs/evidence/11-jenkins.txt` | The `streamingapp-pipeline` job |
| `07-jenkins-pipeline.png` | That job's build page | The stage-by-stage view with every stage green |
| `08-jenkins-console.png` | The build's Console Output | The deploy stage's `helm upgrade` output |
| `09-codebuild.png` | [CodeBuild projects](https://ap-south-1.console.aws.amazon.com/codesuite/codebuild/projects) | `streamingapp-image-builder` and its succeeded build |

## Step 5 — EKS and Helm

| File | Where | What should be visible |
|---|---|---|
| `10-eks-cluster.png` | [EKS cluster](https://ap-south-1.console.aws.amazon.com/eks/home?region=ap-south-1#/clusters/streamingapp-eks) | Status Active, Kubernetes 1.32 |
| `11-eks-nodes.png` | That cluster's Compute tab | The three nodes in the `streamingapp-ng` node group |
| `12-eks-workloads.png` | That cluster's Resources tab, namespace `streamingapp` | The five Deployments and the MongoDB StatefulSet |
| `13-load-balancer.png` | [Load balancers](https://ap-south-1.console.aws.amazon.com/ec2/home?region=ap-south-1#LoadBalancers:) | The ALB the Ingress created, with healthy targets |

## Step 6 — monitoring and logging

| File | Where | What should be visible |
|---|---|---|
| `14-container-insights.png` | [Container Insights](https://ap-south-1.console.aws.amazon.com/cloudwatch/home?region=ap-south-1#container-insights:infrastructure) | CPU and memory graphs for the cluster |
| `15-cloudwatch-dashboard.png` | [Dashboard](https://ap-south-1.console.aws.amazon.com/cloudwatch/home?region=ap-south-1#dashboards:name=streamingapp-overview) | The `streamingapp-overview` dashboard with data |
| `16-log-groups.png` | [Log groups](https://ap-south-1.console.aws.amazon.com/cloudwatch/home?region=ap-south-1#logsV2:log-groups) | The four `/aws/containerinsights/streamingapp-eks/*` groups with 30-day retention |
| `17-application-logs.png` | The `.../application` log group | Actual log lines from the Node services |
| `18-alarms.png` | [Alarms](https://ap-south-1.console.aws.amazon.com/cloudwatch/home?region=ap-south-1#alarmsV2:) | The `streamingapp-*` alarms and their states |

Container Insights needs five to ten minutes of pod activity before the graphs
have anything in them. Take these last.

## Step 9 — ChatOps (bonus)

| File | Where | What should be visible |
|---|---|---|
| `19-sns-topics.png` | [SNS topics](https://ap-south-1.console.aws.amazon.com/sns/v3/home?region=ap-south-1#/topics) | `streamingapp-deployments` and `streamingapp-alarms` |
| `20-slack-message.png` | Your Slack channel | A deployment or alarm notification, if you configured `SLACK_WEBHOOK_URL` |

The Slack half is optional — without a webhook the topics still exist and the
alarms still publish to them, which is what the previous row shows.

## After the screenshots

```bash
git add docs/evidence docs/screenshots
git commit -m "Add deployment evidence"
git push
```

Then tear the infrastructure down, because it bills by the hour whether or not
anyone is looking at it:

```bash
./infra/scripts/99-teardown.sh
```
