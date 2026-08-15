#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Bonus Step 9: SNS topics + a Lambda that renders events into Slack.
#
#   SLACK_WEBHOOK_URL=https://hooks.slack.com/services/... ./chatops/setup-chatops.sh
#
# Creates:
#   * SNS topic  streamingapp-deployments  (Jenkins publishes build outcomes)
#   * SNS topic  streamingapp-alarms       (CloudWatch alarm state changes)
#   * IAM role   streamingapp-chatops-lambda
#   * Lambda     streamingapp-slack-notifier, subscribed to both topics
#
# Re-running updates the function code in place.
# ---------------------------------------------------------------------------
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../infra/env.sh
source "${SCRIPT_DIR}/../infra/env.sh"

require_cmd aws jq zip
require_account

FUNCTION_NAME="${PROJECT}-slack-notifier"
ROLE_NAME="${PROJECT}-chatops-lambda"

if [[ -z "${SLACK_WEBHOOK_URL:-}" ]]; then
  cat <<'EOF'

SLACK_WEBHOOK_URL is not set.

Create an incoming webhook:
  1. https://api.slack.com/apps  ->  Create New App  ->  From scratch
  2. Name it "StreamFlix Deploys", pick your workspace
  3. Features -> Incoming Webhooks -> toggle On -> Add New Webhook to Workspace
  4. Choose the channel (e.g. #deployments) and copy the URL

Then re-run:
  SLACK_WEBHOOK_URL='https://hooks.slack.com/services/T.../B.../xxx' ./chatops/setup-chatops.sh

EOF
  die "missing SLACK_WEBHOOK_URL"
fi

# ---------------------------------------------------------------------------
log "1/5  SNS topics"
# ---------------------------------------------------------------------------
declare -A TOPIC_ARNS
for topic in "${SNS_TOPIC_DEPLOY}" "${SNS_TOPIC_ALARMS}"; do
  ARN="$(aws sns create-topic \
    --name "${topic}" \
    --region "${AWS_REGION}" \
    --tags "Key=Project,Value=${PROJECT}" \
    --query TopicArn --output text)"
  TOPIC_ARNS["${topic}"]="${ARN}"
  ok "${topic} -> ${ARN}"
done

# ---------------------------------------------------------------------------
log "2/5  IAM role for the Lambda"
# ---------------------------------------------------------------------------
if aws iam get-role --role-name "${ROLE_NAME}" >/dev/null 2>&1; then
  ok "role ${ROLE_NAME} already exists"
else
  aws iam create-role --role-name "${ROLE_NAME}" \
    --description "Lets the StreamingApp ChatOps Lambda write its own logs" \
    --assume-role-policy-document '{
      "Version":"2012-10-17",
      "Statement":[{"Effect":"Allow","Principal":{"Service":"lambda.amazonaws.com"},"Action":"sts:AssumeRole"}]
    }' >/dev/null
  aws iam attach-role-policy --role-name "${ROLE_NAME}" \
    --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole
  log "Waiting 15s for IAM propagation"
  sleep 15
  ok "role created"
fi
ROLE_ARN="arn:aws:iam::${AWS_ACCOUNT_ID}:role/${ROLE_NAME}"

# ---------------------------------------------------------------------------
log "3/5  Packaging the function"
# ---------------------------------------------------------------------------
BUILD_DIR="$(mktemp -d)"
trap 'rm -rf "${BUILD_DIR}"' EXIT
cp "${SCRIPT_DIR}/lambda/index.mjs" "${BUILD_DIR}/"
( cd "${BUILD_DIR}" && zip -q -r function.zip index.mjs )
ok "packaged ($(du -h "${BUILD_DIR}/function.zip" | cut -f1))"

# ---------------------------------------------------------------------------
log "4/5  Lambda function"
# ---------------------------------------------------------------------------
if aws lambda get-function --function-name "${FUNCTION_NAME}" --region "${AWS_REGION}" >/dev/null 2>&1; then
  log "Updating existing function code"
  aws lambda update-function-code \
    --function-name "${FUNCTION_NAME}" \
    --zip-file "fileb://${BUILD_DIR}/function.zip" \
    --region "${AWS_REGION}" >/dev/null
  aws lambda wait function-updated --function-name "${FUNCTION_NAME}" --region "${AWS_REGION}"
  aws lambda update-function-configuration \
    --function-name "${FUNCTION_NAME}" \
    --environment "Variables={SLACK_WEBHOOK_URL=${SLACK_WEBHOOK_URL},CONSOLE_REGION=${AWS_REGION}}" \
    --region "${AWS_REGION}" >/dev/null
  ok "function updated"
else
  aws lambda create-function \
    --function-name "${FUNCTION_NAME}" \
    --runtime nodejs20.x \
    --role "${ROLE_ARN}" \
    --handler index.handler \
    --zip-file "fileb://${BUILD_DIR}/function.zip" \
    --timeout 15 \
    --memory-size 256 \
    --description "Renders SNS deployment and alarm events as Slack messages" \
    --environment "Variables={SLACK_WEBHOOK_URL=${SLACK_WEBHOOK_URL},CONSOLE_REGION=${AWS_REGION}}" \
    --tags "Project=${PROJECT}" \
    --region "${AWS_REGION}" >/dev/null
  aws lambda wait function-active --function-name "${FUNCTION_NAME}" --region "${AWS_REGION}"
  ok "function created"
fi

# Keep the function's own logs from accumulating forever.
aws logs put-retention-policy \
  --log-group-name "/aws/lambda/${FUNCTION_NAME}" \
  --retention-in-days 14 \
  --region "${AWS_REGION}" 2>/dev/null || true

FUNCTION_ARN="$(aws lambda get-function --function-name "${FUNCTION_NAME}" \
  --region "${AWS_REGION}" --query 'Configuration.FunctionArn' --output text)"

# ---------------------------------------------------------------------------
log "5/5  Subscribing the Lambda to both topics"
# ---------------------------------------------------------------------------
for topic in "${SNS_TOPIC_DEPLOY}" "${SNS_TOPIC_ALARMS}"; do
  ARN="${TOPIC_ARNS[${topic}]}"

  # SNS needs explicit permission to invoke; the statement id must be unique
  # per topic, and re-adding an existing one is a harmless conflict.
  aws lambda add-permission \
    --function-name "${FUNCTION_NAME}" \
    --statement-id "sns-invoke-${topic}" \
    --action lambda:InvokeFunction \
    --principal sns.amazonaws.com \
    --source-arn "${ARN}" \
    --region "${AWS_REGION}" >/dev/null 2>&1 || true

  EXISTING="$(aws sns list-subscriptions-by-topic --topic-arn "${ARN}" --region "${AWS_REGION}" \
    --query "Subscriptions[?Endpoint=='${FUNCTION_ARN}'].SubscriptionArn | [0]" --output text)"

  if [[ "${EXISTING}" == "None" || -z "${EXISTING}" ]]; then
    aws sns subscribe \
      --topic-arn "${ARN}" \
      --protocol lambda \
      --notification-endpoint "${FUNCTION_ARN}" \
      --region "${AWS_REGION}" >/dev/null
    ok "subscribed to ${topic}"
  else
    ok "already subscribed to ${topic}"
  fi
done

# ---------------------------------------------------------------------------
log "Sending a test message"
# ---------------------------------------------------------------------------
aws sns publish \
  --topic-arn "${TOPIC_ARNS[${SNS_TOPIC_DEPLOY}]}" \
  --region "${AWS_REGION}" \
  --subject "[SUCCESS] StreamingApp ChatOps test" \
  --message "$(jq -nc \
      --arg tag "setup-test" \
      --arg env "${ENVIRONMENT}" '{
        status: "SUCCESS",
        project: "StreamingApp",
        environment: $env,
        imageTag: $tag,
        branch: "main",
        commit: "0000000",
        author: "setup-chatops.sh",
        message: "Verifying the SNS -> Lambda -> Slack path",
        summary: "ChatOps integration is wired up correctly.",
        durationMs: 1234,
        buildUrl: "https://example.com/job/streamingapp/1/"
      }')" >/dev/null

cat <<EOF

ChatOps is live. Check your Slack channel for the test message.

  Deployments topic : ${TOPIC_ARNS[${SNS_TOPIC_DEPLOY}]}
  Alarms topic      : ${TOPIC_ARNS[${SNS_TOPIC_ALARMS}]}
  Lambda            : ${FUNCTION_ARN}

If nothing arrived:
  aws logs tail /aws/lambda/${FUNCTION_NAME} --follow --region ${AWS_REGION}

Now re-run ./monitoring/create-alarms.sh so the alarms point at the alarms topic.

EOF
