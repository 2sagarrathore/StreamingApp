#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Builds and pushes all five images to ECR using AWS CodeBuild, so no Docker
# daemon is needed on the machine running this.
#
#   ./infra/scripts/25-build-images-codebuild.sh
#
# Use this when you are driving the deployment from AWS CloudShell (which has
# no Docker), or from a laptop where you would rather not run builds. On a
# machine that does have Docker, ./infra/scripts/20-create-ecr.sh --push is
# simpler and faster.
#
# Cost: a five-image build takes roughly 8-12 minutes on a general1.medium
# instance, which is about $0.02.
# ---------------------------------------------------------------------------
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
# shellcheck source=../env.sh
source "${SCRIPT_DIR}/../env.sh"

require_cmd aws jq zip
require_account

PROJECT_NAME="${PROJECT}-image-builder"
ROLE_NAME="${PROJECT}-codebuild-role"
SOURCE_BUCKET="${PROJECT}-codebuild-source-${AWS_ACCOUNT_ID}"
SOURCE_KEY="source.zip"
IMAGE_TAG="${IMAGE_TAG:-build-$(date +%Y%m%d%H%M%S)}"

# ---------------------------------------------------------------------------
log "1/5  Source bucket"
# ---------------------------------------------------------------------------
if aws s3api head-bucket --bucket "${SOURCE_BUCKET}" 2>/dev/null; then
  ok "bucket s3://${SOURCE_BUCKET} exists"
else
  log "Creating s3://${SOURCE_BUCKET}"
  if [[ "${AWS_REGION}" == "us-east-1" ]]; then
    aws s3api create-bucket --bucket "${SOURCE_BUCKET}" --region us-east-1 >/dev/null
  else
    aws s3api create-bucket --bucket "${SOURCE_BUCKET}" --region "${AWS_REGION}" \
      --create-bucket-configuration "LocationConstraint=${AWS_REGION}" >/dev/null
  fi
  aws s3api put-public-access-block --bucket "${SOURCE_BUCKET}" \
    --public-access-block-configuration \
    "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"
  ok "bucket created"
fi

# ---------------------------------------------------------------------------
log "2/5  Packaging the repository"
# ---------------------------------------------------------------------------
TMP_ZIP="$(mktemp -d)/source.zip"
( cd "${REPO_ROOT}" && zip -qr "${TMP_ZIP}" . \
    -x '.git/*' '*/node_modules/*' 'docs/evidence/*' '*.zip' )
ok "packaged ($(du -h "${TMP_ZIP}" | cut -f1))"

aws s3 cp "${TMP_ZIP}" "s3://${SOURCE_BUCKET}/${SOURCE_KEY}" --region "${AWS_REGION}" >/dev/null
rm -rf "$(dirname "${TMP_ZIP}")"
ok "uploaded to s3://${SOURCE_BUCKET}/${SOURCE_KEY}"

# ---------------------------------------------------------------------------
log "3/5  IAM role for CodeBuild"
# ---------------------------------------------------------------------------
if aws iam get-role --role-name "${ROLE_NAME}" >/dev/null 2>&1; then
  ok "role ${ROLE_NAME} exists"
else
  aws iam create-role --role-name "${ROLE_NAME}" \
    --description "Lets CodeBuild build the StreamingApp images and push them to ECR" \
    --assume-role-policy-document '{
      "Version":"2012-10-17",
      "Statement":[{"Effect":"Allow","Principal":{"Service":"codebuild.amazonaws.com"},"Action":"sts:AssumeRole"}]
    }' >/dev/null
  ok "role created"
fi

# Scoped to this project's own repositories and source bucket.
aws iam put-role-policy --role-name "${ROLE_NAME}" --policy-name "${PROJECT}-codebuild-inline" \
  --policy-document "$(jq -nc \
    --arg bucket "arn:aws:s3:::${SOURCE_BUCKET}" \
    --arg bucketObjs "arn:aws:s3:::${SOURCE_BUCKET}/*" \
    --arg ecr "arn:aws:ecr:${AWS_REGION}:${AWS_ACCOUNT_ID}:repository/${PROJECT}/*" '{
      Version: "2012-10-17",
      Statement: [
        { Effect:"Allow", Action:["logs:CreateLogGroup","logs:CreateLogStream","logs:PutLogEvents"], Resource:"*" },
        { Effect:"Allow", Action:["ecr:GetAuthorizationToken"], Resource:"*" },
        { Effect:"Allow",
          Action:["ecr:BatchCheckLayerAvailability","ecr:CompleteLayerUpload","ecr:InitiateLayerUpload",
                  "ecr:PutImage","ecr:UploadLayerPart","ecr:BatchGetImage","ecr:GetDownloadUrlForLayer",
                  "ecr:DescribeImages","ecr:DescribeRepositories"],
          Resource: $ecr },
        { Effect:"Allow", Action:["s3:GetObject","s3:GetObjectVersion"], Resource: $bucketObjs },
        { Effect:"Allow", Action:["s3:ListBucket"], Resource: $bucket }
      ]
    }')" >/dev/null
ok "permissions attached"

ROLE_ARN="arn:aws:iam::${AWS_ACCOUNT_ID}:role/${ROLE_NAME}"

# ---------------------------------------------------------------------------
log "4/5  CodeBuild project"
# ---------------------------------------------------------------------------
ENV_VARS="$(jq -nc \
  --arg region "${AWS_REGION}" \
  --arg account "${AWS_ACCOUNT_ID}" \
  --arg registry "${ECR_REGISTRY}" \
  --arg project "${PROJECT}" \
  --arg tag "${IMAGE_TAG}" '[
    {name:"AWS_REGION",     value:$region,   type:"PLAINTEXT"},
    {name:"AWS_ACCOUNT_ID", value:$account,  type:"PLAINTEXT"},
    {name:"ECR_REGISTRY",   value:$registry, type:"PLAINTEXT"},
    {name:"PROJECT",        value:$project,  type:"PLAINTEXT"},
    {name:"IMAGE_TAG",      value:$tag,      type:"PLAINTEXT"}
  ]')"

# privilegedMode is required for a Docker daemon inside the build container.
ENVIRONMENT="$(jq -nc --argjson vars "${ENV_VARS}" '{
  type: "LINUX_CONTAINER",
  image: "aws/codebuild/amazonlinux2-x86_64-standard:5.0",
  computeType: "BUILD_GENERAL1_MEDIUM",
  privilegedMode: true,
  environmentVariables: $vars
}')"

SOURCE="$(jq -nc --arg loc "${SOURCE_BUCKET}/${SOURCE_KEY}" '{
  type: "S3",
  location: $loc,
  buildspec: "infra/codebuild/buildspec.yml"
}')"

if aws codebuild batch-get-projects --names "${PROJECT_NAME}" --region "${AWS_REGION}" \
     --query 'projects[0].name' --output text 2>/dev/null | grep -q "${PROJECT_NAME}"; then
  log "Updating existing project"
  aws codebuild update-project --name "${PROJECT_NAME}" --region "${AWS_REGION}" \
    --source "${SOURCE}" --environment "${ENVIRONMENT}" --service-role "${ROLE_ARN}" \
    --artifacts '{"type":"NO_ARTIFACTS"}' >/dev/null
else
  log "Creating project ${PROJECT_NAME}"
  # IAM role propagation lags behind role creation; retry briefly.
  for attempt in 1 2 3 4 5 6; do
    if aws codebuild create-project --name "${PROJECT_NAME}" --region "${AWS_REGION}" \
        --description "Builds the five StreamingApp container images and pushes them to ECR" \
        --source "${SOURCE}" --environment "${ENVIRONMENT}" --service-role "${ROLE_ARN}" \
        --artifacts '{"type":"NO_ARTIFACTS"}' \
        --tags "key=Project,value=${PROJECT}" >/dev/null 2>&1; then
      break
    fi
    warn "waiting for IAM role to propagate (attempt ${attempt}/6)"
    sleep 10
  done
fi
ok "project ready"

# ---------------------------------------------------------------------------
log "5/5  Running the build (8-12 minutes)"
# ---------------------------------------------------------------------------
BUILD_ID="$(aws codebuild start-build --project-name "${PROJECT_NAME}" \
  --region "${AWS_REGION}" --query 'build.id' --output text)"
ok "build started: ${BUILD_ID}"

LAST_PHASE=""
while true; do
  sleep 15
  read -r STATUS PHASE < <(aws codebuild batch-get-builds --ids "${BUILD_ID}" \
    --region "${AWS_REGION}" --query 'builds[0].[buildStatus,currentPhase]' --output text)

  if [[ "${PHASE}" != "${LAST_PHASE}" ]]; then
    log "  phase: ${PHASE}"
    LAST_PHASE="${PHASE}"
  fi

  case "${STATUS}" in
    SUCCEEDED) ok "build succeeded"; break ;;
    FAILED|FAULT|STOPPED|TIMED_OUT)
      LOG_GROUP="$(aws codebuild batch-get-builds --ids "${BUILD_ID}" --region "${AWS_REGION}" \
        --query 'builds[0].logs.groupName' --output text)"
      LOG_STREAM="$(aws codebuild batch-get-builds --ids "${BUILD_ID}" --region "${AWS_REGION}" \
        --query 'builds[0].logs.streamName' --output text)"
      warn "build ${STATUS} — last 40 log lines:"
      aws logs get-log-events --log-group-name "${LOG_GROUP}" --log-stream-name "${LOG_STREAM}" \
        --region "${AWS_REGION}" --limit 40 --query 'events[].message' --output text 2>/dev/null || true
      die "image build failed"
      ;;
  esac
done

log "Images now in ECR"
for r in frontend auth-service streaming-service admin-service chat-service; do
  aws ecr describe-images --repository-name "${PROJECT}/${r}" --region "${AWS_REGION}" \
    --image-ids imageTag="${IMAGE_TAG}" \
    --query 'imageDetails[0].{Repository:repositoryName,Tag:imageTags[0],SizeMB:imageSizeInBytes,Pushed:imagePushedAt}' \
    --output text 2>/dev/null || warn "  ${r}: not found"
done

echo "${IMAGE_TAG}" > "${REPO_ROOT}/.last-image-tag"
ok "Deploy this build with: IMAGE_TAG=${IMAGE_TAG} ./infra/scripts/60-deploy.sh"
