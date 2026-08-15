#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Creates one ECR repository per component, with image scanning, immutable
# tags for releases, and a lifecycle policy so the registry does not grow
# without bound. Optionally builds and pushes an initial image set.
#
#   ./infra/scripts/20-create-ecr.sh            # create repos only
#   ./infra/scripts/20-create-ecr.sh --push     # create repos, then build+push
# ---------------------------------------------------------------------------
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
# shellcheck source=../env.sh
source "${SCRIPT_DIR}/../env.sh"

require_cmd aws jq
require_account

DO_PUSH=false
[[ "${1:-}" == "--push" ]] && DO_PUSH=true

# Keep the 20 newest tagged images, expire untagged layers after a day.
LIFECYCLE_POLICY='{
  "rules": [
    {
      "rulePriority": 1,
      "description": "Expire untagged images after 1 day",
      "selection": {
        "tagStatus": "untagged",
        "countType": "sinceImagePushed",
        "countUnit": "days",
        "countNumber": 1
      },
      "action": { "type": "expire" }
    },
    {
      "rulePriority": 2,
      "description": "Keep only the 20 most recent build images",
      "selection": {
        "tagStatus": "tagged",
        "tagPrefixList": ["build-"],
        "countType": "imageCountMoreThan",
        "countNumber": 20
      },
      "action": { "type": "expire" }
    }
  ]
}'

for repo in "${ECR_REPOS[@]}"; do
  if aws ecr describe-repositories --repository-names "${repo}" --region "${AWS_REGION}" >/dev/null 2>&1; then
    ok "repository already exists: ${repo}"
  else
    log "Creating ECR repository ${repo}"
    aws ecr create-repository \
      --repository-name "${repo}" \
      --region "${AWS_REGION}" \
      --image-scanning-configuration scanOnPush=true \
      --image-tag-mutability MUTABLE \
      --encryption-configuration encryptionType=AES256 \
      --tags Key=Project,Value="${PROJECT}" Key=ManagedBy,Value=eks-project \
      >/dev/null
    ok "created ${repo}"
  fi

  aws ecr put-lifecycle-policy \
    --repository-name "${repo}" \
    --region "${AWS_REGION}" \
    --lifecycle-policy-text "${LIFECYCLE_POLICY}" >/dev/null
done

log "Repository URIs"
for repo in "${ECR_REPOS[@]}"; do
  printf '    %s/%s\n' "${ECR_REGISTRY}" "${repo}"
done

if [[ "${DO_PUSH}" == "true" ]]; then
  require_cmd docker
  TAG="${IMAGE_TAG:-manual-$(date +%Y%m%d%H%M%S)}"

  log "Logging Docker in to ${ECR_REGISTRY}"
  aws ecr get-login-password --region "${AWS_REGION}" \
    | docker login --username AWS --password-stdin "${ECR_REGISTRY}"

  # repo-short-name : build-context : dockerfile
  build_and_push() {
    local repo="$1" ctx="$2" dockerfile="$3"
    local uri="${ECR_REGISTRY}/${repo}"
    log "Building ${repo}:${TAG} for ${DOCKER_PLATFORM}"
    # --platform is explicit so an Apple Silicon build cannot silently produce
    # arm64 images destined for x86_64 nodes (or the reverse).
    docker buildx build \
      --platform "${DOCKER_PLATFORM}" \
      --load \
      -f "${REPO_ROOT}/${dockerfile}" \
      -t "${uri}:${TAG}" -t "${uri}:latest" \
      "${REPO_ROOT}/${ctx}"
    docker push "${uri}:${TAG}"
    docker push "${uri}:latest"
    ok "pushed ${uri}:${TAG}"
  }

  build_and_push "${PROJECT}/frontend"          "frontend" "frontend/Dockerfile"
  build_and_push "${PROJECT}/auth-service"      "backend"  "backend/authService/Dockerfile"
  build_and_push "${PROJECT}/streaming-service" "backend"  "backend/streamingService/Dockerfile"
  build_and_push "${PROJECT}/admin-service"     "backend"  "backend/adminService/Dockerfile"
  build_and_push "${PROJECT}/chat-service"      "backend"  "backend/chatService/Dockerfile"

  log "All images pushed with tag ${TAG}"
fi

log "Done. Next: ./infra/scripts/30-create-eks.sh"
