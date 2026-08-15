# Jenkins Setup

Step 4 of the brief: stand up Jenkins, wire it to AWS and GitHub, and get the
pipeline building on every commit.

---

## 1. Provision the controller

```bash
# t3.medium, 30 GB gp3, Amazon Linux 2023
aws ec2 run-instances \
  --image-id resolve:ssm:/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64 \
  --instance-type t3.medium \
  --key-name <your-keypair> \
  --security-group-ids <sg-with-22-and-8080> \
  --block-device-mappings '[{"DeviceName":"/dev/xvda","Ebs":{"VolumeSize":30,"VolumeType":"gp3"}}]' \
  --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=streamingapp-jenkins}]'
```

Then on the box:

```bash
git clone https://github.com/<you>/StreamingApp.git
sudo ./StreamingApp/jenkins/setup-jenkins-ec2.sh
```

The script installs Java 17, Jenkins LTS, Docker, AWS CLI v2, kubectl, Helm,
eksctl, and the optional hadolint/trivy/shellcheck gates, then prints the
unlock password.

> **Sizing note.** The frontend's `npm run build` needs roughly 1.5 GB of RAM.
> A `t3.micro` gets OOM-killed mid-build and the failure looks like a random
> webpack crash, which is a miserable thing to debug. Use `t3.medium`.

### Using the shared Hero Vired Jenkins instead

If you are using `https://jenkinsacademics.herovired.com/` rather than your own
EC2 controller, skip the provisioning above. Everything from section 2 onward
still applies — create the job, add the credentials, point it at your fork.
The one difference is that AWS access must come from an IAM **user** access key
(section 3b) because you cannot attach an instance profile to a machine you do
not own.

---

## 2. Plugins

Install the suggested set during first-run, then add the ones in
[`plugins.txt`](plugins.txt):

```bash
sudo jenkins-plugin-cli --plugin-file /path/to/jenkins/plugins.txt
sudo systemctl restart jenkins
```

---

## 3. Credentials

**Manage Jenkins → Credentials → System → Global credentials → Add**

| ID | Kind | Value |
|---|---|---|
| `aws-account-id` | Secret text | Your 12-digit AWS account ID |
| `github-credentials` | Username with password | GitHub username + a PAT with `repo` scope |

### 3a. AWS access via instance profile (preferred)

No AWS credential goes into Jenkins at all. Create the role and attach it:

```bash
./infra/scripts/50-jenkins-iam.sh --instance-profile

aws ec2 associate-iam-instance-profile \
  --instance-id <i-xxxxxxxx> \
  --iam-instance-profile Name=streamingapp-jenkins-role
```

The SDK on the instance picks the role up from IMDS automatically. Nothing to
rotate, nothing to leak.

### 3b. AWS access via access keys (fallback)

```bash
./infra/scripts/50-jenkins-iam.sh --iam-user
```

Store the printed key as an **AWS Credentials** entry with ID
`aws-credentials`, then wrap the AWS-touching stages in `withAWS(credentials: 'aws-credentials')`.

Either way, `50-jenkins-iam.sh` also maps the principal into the cluster's
`aws-auth` ConfigMap and binds it to a namespace-scoped Role — without that,
`helm upgrade` fails with `error: You must be logged in to the server`.

---

## 4. Create the job

**New Item → Multibranch Pipeline** (recommended) or **Pipeline**.

- **Branch Sources:** GitHub → `github-credentials` → your fork's URL
- **Build Configuration:** by Jenkinsfile, script path `Jenkinsfile`
- **Scan Multibranch Pipeline Triggers:** every 1 hour (a backstop; the webhook
  does the real work)

For a plain Pipeline job instead: *Pipeline script from SCM* → Git → your fork
→ branch `main` → script path `Jenkinsfile`.

---

## 5. Automatic builds on commit

**On GitHub:** Settings → Webhooks → Add webhook

- Payload URL: `http://<jenkins-host>:8080/github-webhook/`
- Content type: `application/json`
- Events: *Just the push event*

**On Jenkins:** the `githubPush()` trigger in the Jenkinsfile is already
declared, so nothing else is needed. A `pollSCM('H/5 * * * *')` trigger sits
behind it as a safety net for when GitHub cannot reach the controller (private
subnet, no public IP, expired webhook).

Verify: push a trivial commit and watch the build appear within a few seconds.
If it does not, check **Recent Deliveries** on the GitHub webhook page — a
`403` there almost always means Jenkins requires authentication for anonymous
read, which the webhook endpoint needs.

---

## 6. What the pipeline does

| Stage | What happens |
|---|---|
| Checkout | Resolves the commit, derives `IMAGE_TAG=build-<n>-<sha>` |
| Preflight | Asserts docker / aws / kubectl / helm exist and the AWS identity resolves |
| Static checks | `helm lint` + full `helm template` render, hadolint, shellcheck — in parallel |
| ECR login | `aws ecr get-login-password \| docker login` |
| Build & push | Five `docker build`s **in parallel**, each tagged `:$IMAGE_TAG` and `:latest`, pushed to its own ECR repo |
| Vulnerability scan | Trivy HIGH/CRITICAL report per image, archived as a build artifact |
| Deploy to EKS | `helm upgrade --install --atomic --wait` against the prod values file |
| Verify | `kubectl rollout status` per component, then `helm test` |
| Post | Publishes a JSON event to SNS → Lambda → Slack |

Two details worth knowing:

- **`--atomic`** means a deploy that fails to become ready inside 12 minutes is
  rolled back automatically. The cluster is never left half-upgraded.
- **Secrets are read back out of the cluster** before each `helm upgrade`. If
  the pipeline minted a fresh `JWT_SECRET` on every deploy it would sign users
  out on every release, and a fresh Mongo password would lock the app out of
  its own database on the second deploy.

---

## 7. Troubleshooting

| Symptom | Cause and fix |
|---|---|
| `docker: permission denied ... /var/run/docker.sock` | The `jenkins` user was added to the `docker` group but the service still has the old group set. `sudo systemctl restart jenkins`. |
| `no basic auth credentials` on push | The ECR login token expired (12 h). The pipeline logs in each run; if you re-ran only the deploy stage, re-run from the top. |
| `You must be logged in to the server (Unauthorized)` | The Jenkins IAM principal is not in `aws-auth`. Re-run `infra/scripts/50-jenkins-iam.sh`. |
| `Error: UPGRADE FAILED: another operation is in progress` | A previous run died mid-upgrade. `helm rollback streamingapp -n streamingapp`, then re-run. |
| Frontend build OOMs | Instance too small — resize to `t3.medium` or larger. |
| Webhook fires but nothing builds | Multibranch jobs only build branches they have already indexed. Run *Scan Repository Now* once. |
