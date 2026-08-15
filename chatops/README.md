# ChatOps — SNS → Slack

Bonus Step 9. Deployment outcomes and CloudWatch alarms land in Slack as
formatted Block Kit messages instead of email.

```
Jenkins ──publish──▶ SNS: streamingapp-deployments ──┐
                                                     ├──▶ Lambda ──▶ Slack webhook
CloudWatch alarms ──▶ SNS: streamingapp-alarms ──────┘
```

## Setup

**1. Create a Slack incoming webhook**

<https://api.slack.com/apps> → *Create New App* → *From scratch* → name it and
pick your workspace → *Incoming Webhooks* → toggle **On** → *Add New Webhook to
Workspace* → choose a channel → copy the URL.

**2. Run the setup script**

```bash
SLACK_WEBHOOK_URL='https://hooks.slack.com/services/T.../B.../xxxxx' \
  ./chatops/setup-chatops.sh
```

It creates both SNS topics, the Lambda execution role, the
`streamingapp-slack-notifier` function, both subscriptions, and publishes a
test event so you can confirm the whole path in one go.

**3. Point the alarms at the topic**

```bash
./monitoring/create-alarms.sh
```

(If you ran this before the topics existed, the alarms were created with a
valid-looking but non-existent topic ARN. Re-running fixes them.)

**4. Confirm Jenkins can publish**

The pipeline's `SNS_TOPIC_ARN` is derived from the `aws-account-id` credential,
and the IAM policy in `infra/iam/jenkins-ci-policy.json` already allows
`sns:Publish` on `streamingapp-*`. Nothing else to do.

## What the messages look like

**Deployment (from Jenkins):** header with a status emoji, one-line summary,
then a field grid — environment, image tag, branch, commit, author, duration —
the commit message as context, and buttons linking to the build and the live app.

**Alarm (from CloudWatch):** ALARM/RESOLVED header, the alarm description, the
metric, threshold and dimensions, the state-change reason, and a deep link into
the CloudWatch console.

Anything else published to either topic is forwarded as a code block rather
than dropped.

## Design notes

**Notification failures never fail a build.** `notifySns()` in the Jenkinsfile
runs with `set +e` and always exits 0. A rotated webhook or a Slack outage
should not turn a successful deploy red — that trains people to ignore red
builds.

**The Lambda swallows a missing webhook.** If `SLACK_WEBHOOK_URL` is unset it
logs an error and returns 500 rather than throwing. Throwing would make SNS
retry the delivery repeatedly, and the retries would all fail the same way.

**Zero dependencies.** Node 20 has `fetch` built in, so the deployment package
is a single file — no `npm install`, no layer, no supply chain.

## Using Telegram instead

Swap `postToSlack` in `lambda/index.mjs` for:

```js
async function postToSlack(payload) {                 // same call site
  const text = payload.text;                          // plain-text fallback
  const url = `https://api.telegram.org/bot${process.env.TELEGRAM_BOT_TOKEN}/sendMessage`;
  const res = await fetch(url, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({
      chat_id: process.env.TELEGRAM_CHAT_ID,
      text,
      parse_mode: 'Markdown',
    }),
  });
  return { status: res.status, body: await res.text() };
}
```

Then set `TELEGRAM_BOT_TOKEN` (from @BotFather) and `TELEGRAM_CHAT_ID` on the
function instead of `SLACK_WEBHOOK_URL`.

## Troubleshooting

| Symptom | Fix |
|---|---|
| No Slack message at all | `aws logs tail /aws/lambda/streamingapp-slack-notifier --follow` |
| Lambda logs `invalid_payload` | Slack rejects blocks over 50 per attachment or text over 3000 chars — the code truncates, but a very long commit message can still trip it |
| Lambda not invoked | Check the subscription exists: `aws sns list-subscriptions-by-topic --topic-arn <arn>` |
| Jenkins logs "SNS notification failed" | The build's IAM principal is missing `sns:Publish`, or `aws-account-id` is wrong so the ARN points nowhere |
| Alarms fire but no Slack | The alarms were created before the topic. Re-run `monitoring/create-alarms.sh` |
