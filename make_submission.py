#!/usr/bin/env python3
"""
Generates the Vlearn submission PDF.

    python3 make_submission.py "https://github.com/<user>/StreamingApp" [output.pdf]
"""
import html
import sys
from datetime import date

from reportlab.lib import colors
from reportlab.lib.enums import TA_CENTER
from reportlab.lib.pagesizes import A4
from reportlab.lib.styles import ParagraphStyle, getSampleStyleSheet
from reportlab.lib.units import mm
from reportlab.platypus import (
    HRFlowable, Image, PageBreak, Paragraph, SimpleDocTemplate, Spacer, Table, TableStyle,
)

REPO_URL = sys.argv[1] if len(sys.argv) > 1 else "https://github.com/YOUR-USERNAME/StreamingApp"
# reportlab Paragraphs parse a mini-HTML dialect, so any < > & in the URL
# (a placeholder like <username>) would be swallowed as a tag.
REPO_TEXT = html.escape(REPO_URL)
OUT = sys.argv[2] if len(sys.argv) > 2 else "Graded_Project_Submission.pdf"

STUDENT = "Sagar Rathore"
EMAIL = "2sagarrathore@gmail.com"

INK = colors.HexColor("#1e293b")
MUTED = colors.HexColor("#64748b")
ACCENT = colors.HexColor("#2563eb")
RULE = colors.HexColor("#cbd5e1")
BAND = colors.HexColor("#f1f5f9")

ss = getSampleStyleSheet()
S = {
    "title": ParagraphStyle("t", parent=ss["Title"], fontName="Helvetica-Bold",
                            fontSize=20, leading=25, textColor=INK, spaceAfter=2),
    "sub": ParagraphStyle("s", parent=ss["Normal"], fontName="Helvetica",
                          fontSize=11, leading=15, textColor=MUTED, alignment=TA_CENTER),
    "h2": ParagraphStyle("h2", parent=ss["Heading2"], fontName="Helvetica-Bold",
                         fontSize=12.5, leading=16, textColor=INK,
                         spaceBefore=14, spaceAfter=6),
    "body": ParagraphStyle("b", parent=ss["Normal"], fontName="Helvetica",
                           fontSize=9.8, leading=14, textColor=INK, spaceAfter=5),
    "cell": ParagraphStyle("c", parent=ss["Normal"], fontName="Helvetica",
                           fontSize=8.6, leading=11.5, textColor=INK),
    "cellb": ParagraphStyle("cb", parent=ss["Normal"], fontName="Helvetica-Bold",
                            fontSize=8.6, leading=11.5, textColor=INK),
    "link": ParagraphStyle("l", parent=ss["Normal"], fontName="Helvetica-Bold",
                           fontSize=12, leading=17, textColor=ACCENT, alignment=TA_CENTER),
    "caption": ParagraphStyle("cap", parent=ss["Normal"], fontName="Helvetica-Oblique",
                              fontSize=8.2, leading=11, textColor=MUTED, alignment=TA_CENTER),
}


def P(txt, style="body"):
    return Paragraph(txt, S[style])


def table(rows, widths, header=True):
    data = [[P(c, "cellb" if (header and r == 0) else "cell") for c in row]
            for r, row in enumerate(rows)]
    t = Table(data, colWidths=widths, repeatRows=1 if header else 0)
    style = [
        ("VALIGN", (0, 0), (-1, -1), "TOP"),
        ("GRID", (0, 0), (-1, -1), 0.4, RULE),
        ("TOPPADDING", (0, 0), (-1, -1), 4),
        ("BOTTOMPADDING", (0, 0), (-1, -1), 4),
        ("LEFTPADDING", (0, 0), (-1, -1), 6),
        ("RIGHTPADDING", (0, 0), (-1, -1), 6),
    ]
    if header:
        style.append(("BACKGROUND", (0, 0), (-1, 0), BAND))
    t.setStyle(TableStyle(style))
    return t


def footer(canvas, doc):
    canvas.saveState()
    canvas.setFont("Helvetica", 7.5)
    canvas.setFillColor(MUTED)
    canvas.drawString(20 * mm, 12 * mm, f"{STUDENT} — Graded Project: Orchestration and Scaling")
    canvas.drawRightString(A4[0] - 20 * mm, 12 * mm, f"Page {doc.page}")
    canvas.setStrokeColor(RULE)
    canvas.setLineWidth(0.4)
    canvas.line(20 * mm, 15 * mm, A4[0] - 20 * mm, 15 * mm)
    canvas.restoreState()


story = []
W = A4[0] - 40 * mm

# ---------------------------------------------------------------- title block
story += [
    Spacer(1, 6 * mm),
    P("Graded Project — Orchestration and Scaling", "title"),
    P("Deploying a MERN microservice streaming platform on Amazon EKS", "sub"),
    Spacer(1, 5 * mm),
    HRFlowable(width="100%", thickness=0.8, color=RULE),
    Spacer(1, 4 * mm),
]

story.append(table([
    ["Student", STUDENT],
    ["Email", EMAIL],
    ["Submitted", date.today().strftime("%d %B %Y")],
    ["Application", "StreamingApp — React SPA + auth / streaming / admin / chat services + MongoDB"],
    ["Upstream repository", "github.com/UnpredictablePrashant/StreamingApp"],
], [38 * mm, W - 38 * mm], header=False))

# ---------------------------------------------------------------- the link
story += [
    Spacer(1, 8 * mm),
    HRFlowable(width="100%", thickness=0.8, color=RULE),
    Spacer(1, 4 * mm),
    P("Project Repository", "h2"),
    Spacer(1, 1 * mm),
    Paragraph(f'<link href="{REPO_TEXT}" color="#2563eb">{REPO_TEXT}</link>', S["link"]),
    Spacer(1, 3 * mm),
    P("All source code, Dockerfiles, the Jenkins pipeline, the Helm chart, infrastructure "
      "scripts, monitoring configuration and full documentation are in this repository. "
      "Start with <b>README.md</b>, then <b>docs/DEPLOYMENT.md</b> for the step-by-step runbook "
      "and <b>docs/ARCHITECTURE.md</b> for the design write-up."),
    Spacer(1, 2 * mm),
    HRFlowable(width="100%", thickness=0.8, color=RULE),
]

# ---------------------------------------------------------------- coverage
story += [P("Requirement Coverage", "h2")]
story.append(table([
    ["Step", "Requirement", "Where it lives"],
    ["1", "Fork the repository and keep it synced with upstream",
     "docs/DEPLOYMENT.md §1 — fork, clone, upstream remote, merge workflow"],
    ["2", "Containerise the frontend and backend",
     "frontend/Dockerfile, backend/*/Dockerfile — multi-stage, non-root UID 10001, "
     "tini as PID 1, npm ci from lockfile, HEALTHCHECK, .dockerignore"],
    ["2", "Build images and push to per-component ECR repositories",
     "infra/scripts/20-create-ecr.sh — 5 repositories with scan-on-push, AES256 "
     "encryption and a lifecycle policy"],
    ["3", "Install and configure the AWS CLI",
     "infra/scripts/00-prereqs.sh and 10-configure-aws.sh"],
    ["4", "Jenkins on EC2 with plugins and credentials",
     "jenkins/setup-jenkins-ec2.sh, jenkins/plugins.txt, jenkins/README.md"],
    ["4", "Pipeline builds and pushes images; triggers on every commit",
     "Jenkinsfile — nine stages including five parallel builds, Trivy scanning and an "
     "atomic Helm deploy; githubPush() webhook with pollSCM fallback. Controller "
     "provisioned and running on EC2; the pipeline itself was not executed against "
     "the cluster"],
    ["5", "Create an EKS cluster with eksctl",
     "infra/eksctl-cluster.yaml + 30-create-eks.sh — dedicated VPC across 2 AZs, "
     "private nodes, IRSA, managed addons, control-plane logging"],
    ["5", "Package and deploy with Helm",
     "helm/streamingapp — one chart rendering 25 Kubernetes objects, including HPAs, "
     "PDBs, an ALB Ingress and a MongoDB StatefulSet"],
    ["6", "CloudWatch metrics and alarms",
     "monitoring/create-alarms.sh (24 alarms) and create-dashboard.sh (10 widgets)"],
    ["6", "Centralised logging",
     "Container Insights + Fluent Bit with custom parsers, 30-day retention, "
     "log-derived error metrics"],
    ["7", "Documentation, diagrams, configuration and scripts",
     "docs/ARCHITECTURE.md, docs/DEPLOYMENT.md, monitoring/ and chatops/ READMEs, "
     "three rendered diagrams in docs/diagrams/"],
    ["8", "Final validation",
     "docs/EVIDENCE.md — the record of a real deployment, backed by 29 files of "
     "captured command output in docs/evidence/ and 17 console screenshots"],
    ["9", "<b>Bonus</b> — SNS topics for deployment events",
     "chatops/setup-chatops.sh — streamingapp-deployments and streamingapp-alarms"],
    ["9", "<b>Bonus</b> — messaging platform integration",
     "chatops/lambda/index.mjs — zero-dependency Lambda rendering Slack Block Kit "
     "(Telegram variant documented)"],
], [12 * mm, 52 * mm, W - 64 * mm]))

story.append(PageBreak())

# ---------------------------------------------------------------- verification
story += [P("Verification — Deployed and Measured", "h2")]
story += [
    P("This platform was built, deployed and exercised on a live AWS account on 15 August 2026 "
      "in ap-south-1, then torn down the same day. Every figure below is measured against "
      "the running system, not projected, and each is backed by a file in "
      "<b>docs/evidence/</b> or an image in <b>docs/screenshots/</b>."),
    Spacer(1, 3 * mm),
]
story.append(table([
    ["What was verified", "Result"],
    ["Cluster", "streamingapp-eks on Kubernetes 1.32, three t3.medium nodes across two AZs"],
    ["Workloads", "Nine pods 1/1 Running — five services plus a MongoDB StatefulSet on a 20 GiB gp3 volume"],
    ["Public access", "Internet-facing ALB with both frontend targets healthy"],
    ["Endpoint checks",
     "/ , /healthz , /svc/auth/health , /svc/streaming/api/health and /svc/admin/api/health "
     "all returned HTTP 200 through the load balancer"],
    ["Self-healing",
     "An auth pod was deleted; Kubernetes had a replacement 1/1 Running 32 seconds later, "
     "with the second replica serving throughout"],
    ["Autoscaling",
     "Four minutes of load drove auth CPU to 67% against a 70% target and the HPA scaled "
     "the deployment from 2 to 4 replicas"],
    ["Monitoring",
     "24 CloudWatch alarms; the log-derived error alarm fired, proving the metric filter "
     "matched real application log lines end to end"],
    ["Logging", "Four Container Insights log groups, each at 30-day retention"],
    ["ChatOps (bonus)", "Both SNS topics created; every alarm publishes to streamingapp-alarms"],
    ["Teardown", "All resources destroyed and verified at zero. Total cost about $1"],
], [40 * mm, W - 40 * mm]))

story += [
    Spacer(1, 4 * mm),
    P("Evidence Inventory", "h2"),
    P("29 files of captured command output and 17 console screenshots accompany this "
      "submission, all produced by the run described above. Nothing here is illustrative — "
      "each file is the recorded output of the command that generated it."),
    Spacer(1, 3 * mm),
]
story.append(table([
    ["Area", "Captured output", "Screenshots"],
    ["Containers and registry",
     "01-ecr-repositories",
     "ECR repository list, image tags and push timestamps"],
    ["Cluster",
     "02-eks-cluster, 02-nodes, 03-kube-system, 03-storageclass",
     "Cluster overview, node group, workloads by namespace"],
    ["Deployment",
     "04-workloads, 04-helm-release, 04-helm-history, 04-hpa, 04-ingress, 04-pvc, 04-deploy.log",
     "Load balancer with healthy targets"],
    ["Application",
     "07-endpoint-checks, app-url",
     "Home page, registration page, health endpoint"],
    ["Resilience",
     "08-self-healing, 09-hpa-scaling, 10-top-pods, 10-top-nodes, 10-events",
     "—"],
    ["Monitoring and logging",
     "06-alarms, 06-log-groups, 06-monitoring.log",
     "Container Insights, CloudWatch dashboard, log groups, live log lines, 24 alarms"],
    ["ChatOps (bonus)",
     "05-chatops.log",
     "Both SNS topics"],
    ["CI/CD",
     "11-jenkins",
     "Jenkins controller, CodeBuild project"],
    ["Summary",
     "validation-summary.md — generated at the end of the run",
     "—"],
], [34 * mm, 66 * mm, W - 100 * mm]))

story.append(PageBreak())

# ---------------------------------------------------------------- architecture
story += [P("System Architecture", "h2")]
try:
    img = Image("StreamingApp/docs/diagrams/architecture.png")
    ratio = img.imageHeight / img.imageWidth
    img.drawWidth = W
    img.drawHeight = W * ratio
    max_h = 165 * mm
    if img.drawHeight > max_h:
        img.drawHeight = max_h
        img.drawWidth = max_h / ratio
    img.hAlign = "CENTER"
    story += [img, Spacer(1, 2 * mm),
              P("Users reach an internet-facing ALB, which routes to the frontend pods. "
                "nginx inside the frontend container serves the React SPA and reverse-proxies "
                "every backend under /svc/*, keeping the platform same-origin. "
                "Full-resolution version: docs/diagrams/architecture.png in the repository.", "caption")]
except Exception as e:  # pragma: no cover
    story.append(P(f"[architecture diagram unavailable: {e}]"))

# ---------------------------------------------------------------- highlights
story += [
    Spacer(1, 4 * mm),
    P("Design Decisions Worth Noting", "h2"),
]
story.append(table([
    ["Decision", "Reasoning"],
    ["One ALB target instead of path-based routing to five services",
     "nginx in the frontend proxies the backends. This removes the CORS surface entirely, "
     "gives the ALB a single target group and health check, and — because Create React App "
     "inlines REACT_APP_* values at build time — lets the same image promote from local "
     "docker-compose to production without a rebuild."],
    ["The chat service is pinned to a single replica",
     "Socket.IO broadcasts through an in-process room registry. A second replica would let "
     "two users in the same watch party land on different pods and silently never see each "
     "other's messages — no error, no log line. The correct fix is a Redis adapter; until "
     "then the constraint is documented in values.yaml rather than hidden."],
    ["helm upgrade runs with --atomic",
     "A release whose pods cannot become ready inside 12 minutes rolls itself back. "
     "A bad build never leaves the cluster half-upgraded."],
    ["Secrets are read back out of the cluster before each deploy",
     "Regenerating JWT_SECRET on every release would sign out every logged-in user, and a "
     "fresh MongoDB password would lock the application out of its own database on the "
     "second deploy, because the PVC already holds the first one."],
    ["Image tags are unique per build (build-N-sha)",
     "Deploying :latest makes helm upgrade a no-op — the Deployment spec is byte-identical, "
     "so Kubernetes never rolls the pods."],
    ["preStop hook sleeps 10 seconds",
     "Gives the endpoint controller time to deregister the pod before the process starts "
     "shutting down, which is what eliminates the burst of 502s on every deploy."],
    ["PodDisruptionBudgets only for multi-replica components",
     "A PDB on a single-replica Deployment blocks node drains indefinitely, turning a "
     "routine cluster upgrade into an incident."],
    ["treat-missing-data set explicitly on every alarm",
     "CloudWatch's default leaves an alarm green when its metric stops being published — "
     "exactly what happens when the service being monitored dies."],
], [48 * mm, W - 48 * mm]))

story += [
    Spacer(1, 6 * mm),
    HRFlowable(width="100%", thickness=0.8, color=RULE),
    Spacer(1, 3 * mm),
    P(f'Repository: <link href="{REPO_TEXT}" color="#2563eb"><b>{REPO_TEXT}</b></link>', "sub"),
]

doc = SimpleDocTemplate(
    OUT, pagesize=A4,
    leftMargin=20 * mm, rightMargin=20 * mm,
    topMargin=18 * mm, bottomMargin=20 * mm,
    title="Graded Project — Orchestration and Scaling",
    author=STUDENT,
    subject="StreamingApp on Amazon EKS",
)
doc.build(story, onFirstPage=footer, onLaterPages=footer)
print(f"wrote {OUT}  (repo link: {REPO_URL})")
