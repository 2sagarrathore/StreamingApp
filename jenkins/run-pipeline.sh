#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Triggers the Jenkins pipeline and streams its console output, so a pipeline
# run can be driven and captured from a terminal instead of a browser.
#
#   ./jenkins/run-pipeline.sh
#   ./jenkins/run-pipeline.sh --no-deploy       # build and scan only
#
# The full console log is written to docs/evidence/06-jenkins-build-<n>.log
# and the outcome is appended to docs/evidence/06-jenkins.txt.
#
# Requires jenkins/provision-jenkins.sh to have run first — it writes the
# controller URL into docs/evidence/06-jenkins.txt and the admin password into
# .jenkins-admin-password.
# ---------------------------------------------------------------------------
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
# shellcheck source=../infra/env.sh
source "${REPO_ROOT}/infra/env.sh"

require_cmd curl jq

JOB_NAME="${JENKINS_JOB:-streamingapp-pipeline}"
ADMIN_USER="${JENKINS_ADMIN_USER:-admin}"
EVIDENCE="${REPO_ROOT}/docs/evidence/06-jenkins.txt"

JENKINS_URL="${JENKINS_URL:-$(awk '/^url:/ {print $2}' "${EVIDENCE}" 2>/dev/null || true)}"
[[ -n "${JENKINS_URL}" ]] || die "no Jenkins URL — run ./jenkins/provision-jenkins.sh first"

ADMIN_PASSWORD="${JENKINS_ADMIN_PASSWORD:-$(cat "${REPO_ROOT}/.jenkins-admin-password" 2>/dev/null || true)}"
[[ -n "${ADMIN_PASSWORD}" ]] || die "no admin password — expected ${REPO_ROOT}/.jenkins-admin-password"

AUTH=(-u "${ADMIN_USER}:${ADMIN_PASSWORD}")
DEPLOY=true
[[ "${1:-}" == "--no-deploy" ]] && DEPLOY=false

log "Jenkins at ${JENKINS_URL}, job ${JOB_NAME}"

# Jenkins protects POSTs with a CSRF crumb; fetch one and reuse the session
# cookie, because the crumb is bound to it.
COOKIE_JAR="$(mktemp)"
trap 'rm -f "${COOKIE_JAR}"' EXIT
CRUMB="$(curl -fsS "${AUTH[@]}" -c "${COOKIE_JAR}" \
  "${JENKINS_URL}/crumbIssuer/api/json" | jq -r '.crumb')"
[[ -n "${CRUMB}" && "${CRUMB}" != "null" ]] || die "could not get a CSRF crumb — check the credentials"
ok "authenticated"

# ---------------------------------------------------------------------------
log "Triggering a build (DEPLOY=${DEPLOY})"
# ---------------------------------------------------------------------------
QUEUE_URL="$(curl -fsS "${AUTH[@]}" -b "${COOKIE_JAR}" -H "Jenkins-Crumb: ${CRUMB}" \
  -D - -o /dev/null -X POST \
  "${JENKINS_URL}/job/${JOB_NAME}/buildWithParameters?ENVIRONMENT=prod&DEPLOY=${DEPLOY}&RUN_SCAN=true" \
  | awk 'tolower($1)=="location:" {print $2}' | tr -d '\r')"
[[ -n "${QUEUE_URL}" ]] || die "Jenkins accepted the request but returned no queue item"
ok "queued: ${QUEUE_URL}"

# ---------------------------------------------------------------------------
log "Waiting for an executor"
# ---------------------------------------------------------------------------
BUILD_NUMBER=""
for _ in $(seq 1 60); do
  ITEM="$(curl -fsS "${AUTH[@]}" -b "${COOKIE_JAR}" "${QUEUE_URL}api/json" 2>/dev/null || true)"
  BUILD_NUMBER="$(echo "${ITEM}" | jq -r '.executable.number // empty' 2>/dev/null || true)"
  [[ -n "${BUILD_NUMBER}" ]] && break
  BLOCKED="$(echo "${ITEM}" | jq -r '.why // empty' 2>/dev/null || true)"
  [[ -n "${BLOCKED}" ]] && log "  ${BLOCKED}"
  sleep 5
done
[[ -n "${BUILD_NUMBER}" ]] || die "the build never started — check ${JENKINS_URL}/job/${JOB_NAME}/"

BUILD_URL="${JENKINS_URL}/job/${JOB_NAME}/${BUILD_NUMBER}"
LOG_FILE="${REPO_ROOT}/docs/evidence/06-jenkins-build-${BUILD_NUMBER}.log"
ok "build #${BUILD_NUMBER} started"

# ---------------------------------------------------------------------------
log "Streaming the console (a full build takes 12-18 minutes)"
# ---------------------------------------------------------------------------
echo
OFFSET=0
while true; do
  RESPONSE="$(curl -fsS "${AUTH[@]}" -b "${COOKIE_JAR}" -D /tmp/jenkins-headers.$$ \
    "${BUILD_URL}/logText/progressiveText?start=${OFFSET}" 2>/dev/null || true)"
  [[ -n "${RESPONSE}" ]] && printf '%s' "${RESPONSE}" | tee -a "${LOG_FILE}"

  NEW_OFFSET="$(awk 'tolower($1)=="x-text-size:" {print $2}' /tmp/jenkins-headers.$$ | tr -d '\r')"
  MORE="$(awk 'tolower($1)=="x-more-data:" {print $2}' /tmp/jenkins-headers.$$ | tr -d '\r')"
  [[ -n "${NEW_OFFSET}" ]] && OFFSET="${NEW_OFFSET}"
  [[ "${MORE}" == "true" ]] || break
  sleep 5
done
rm -f /tmp/jenkins-headers.$$
echo

# ---------------------------------------------------------------------------
RESULT="$(curl -fsS "${AUTH[@]}" -b "${COOKIE_JAR}" "${BUILD_URL}/api/json" \
  | jq -r '.result // "UNKNOWN"')"
DURATION="$(curl -fsS "${AUTH[@]}" -b "${COOKIE_JAR}" "${BUILD_URL}/api/json" \
  | jq -r '(.duration / 1000 | floor)')"

{
  echo
  echo "build #${BUILD_NUMBER}: ${RESULT} in ${DURATION}s"
  echo "  console: docs/evidence/06-jenkins-build-${BUILD_NUMBER}.log"
  echo "  url:     ${BUILD_URL}/"
} >> "${EVIDENCE}"

if [[ "${RESULT}" == "SUCCESS" ]]; then
  ok "build #${BUILD_NUMBER} succeeded in ${DURATION}s"
  ok "console log saved to docs/evidence/06-jenkins-build-${BUILD_NUMBER}.log"
else
  warn "build #${BUILD_NUMBER} finished ${RESULT} — see ${LOG_FILE}"
  exit 1
fi
