// ===========================================================================
// SNS -> Slack notifier  (Node.js 20.x, ESM, zero dependencies)
//
// Subscribes to two topics and renders both into Slack Block Kit messages:
//
//   streamingapp-deployments : JSON published by the Jenkins pipeline
//   streamingapp-alarms      : CloudWatch alarm state-change notifications
//
// Config (environment variables):
//   SLACK_WEBHOOK_URL  required — the incoming-webhook URL
//   AWS_REGION         provided by Lambda
//   CONSOLE_REGION     optional override for console deep links
// ===========================================================================

const WEBHOOK = process.env.SLACK_WEBHOOK_URL;
const REGION = process.env.CONSOLE_REGION || process.env.AWS_REGION || 'ap-south-1';

// Slack attachment colours
const COLOR = {
  SUCCESS: '#2eb886',
  FAILURE: '#d40e0d',
  UNSTABLE: '#daa038',
  ALARM: '#d40e0d',
  OK: '#2eb886',
  INSUFFICIENT_DATA: '#8e8e8e',
  DEFAULT: '#3aa3e3',
};

const EMOJI = {
  SUCCESS: ':white_check_mark:',
  FAILURE: ':rotating_light:',
  UNSTABLE: ':warning:',
  ALARM: ':fire:',
  OK: ':white_check_mark:',
  INSUFFICIENT_DATA: ':grey_question:',
  DEFAULT: ':information_source:',
};

export const handler = async (event) => {
  if (!WEBHOOK) {
    // Fail loudly in logs but do not throw: a missing webhook must not put the
    // message back on the queue forever.
    console.error('SLACK_WEBHOOK_URL is not set — dropping notification');
    return { statusCode: 500, body: 'missing SLACK_WEBHOOK_URL' };
  }

  const results = [];

  for (const record of event.Records ?? []) {
    const sns = record.Sns ?? {};
    let message;

    try {
      message = JSON.parse(sns.Message);
    } catch {
      // Not JSON — forward the raw text rather than dropping it.
      message = { raw: sns.Message };
    }

    const payload = message.AlarmName
      ? buildAlarmMessage(message)
      : message.status
        ? buildDeploymentMessage(message)
        : buildGenericMessage(sns.Subject, message);

    results.push(await postToSlack(payload));
  }

  return { statusCode: 200, body: JSON.stringify(results) };
};

// ---------------------------------------------------------------------------
// Jenkins deployment events
// ---------------------------------------------------------------------------
function buildDeploymentMessage(m) {
  const status = (m.status || 'DEFAULT').toUpperCase();
  const emoji = EMOJI[status] || EMOJI.DEFAULT;
  const color = COLOR[status] || COLOR.DEFAULT;

  const fields = [
    field('Environment', m.environment || 'n/a'),
    field('Image tag', '`' + (m.imageTag || 'n/a') + '`'),
    field('Branch', m.branch || 'n/a'),
    field('Commit', '`' + (m.commit || 'n/a') + '`'),
    field('Author', m.author || 'n/a'),
    field('Duration', formatDuration(m.durationMs)),
  ];

  const blocks = [
    {
      type: 'header',
      text: { type: 'plain_text', text: `${emoji} ${m.project || 'StreamingApp'} — ${status}`, emoji: true },
    },
    {
      type: 'section',
      text: { type: 'mrkdwn', text: m.summary || 'Pipeline finished.' },
    },
    { type: 'section', fields },
  ];

  if (m.message) {
    blocks.push({
      type: 'context',
      elements: [{ type: 'mrkdwn', text: `:memo: ${truncate(m.message, 200)}` }],
    });
  }

  const buttons = [];
  if (m.buildUrl) buttons.push(button('View build', m.buildUrl));
  if (m.appUrl) buttons.push(button('Open app', startsWithProtocol(m.appUrl)));
  if (buttons.length) blocks.push({ type: 'actions', elements: buttons });

  return {
    text: `${emoji} ${m.project || 'StreamingApp'} ${status}: ${m.summary || ''}`, // notification fallback
    attachments: [{ color, blocks }],
  };
}

// ---------------------------------------------------------------------------
// CloudWatch alarm state changes
// ---------------------------------------------------------------------------
function buildAlarmMessage(a) {
  const state = a.NewStateValue || 'DEFAULT';
  const emoji = EMOJI[state] || EMOJI.DEFAULT;
  const color = COLOR[state] || COLOR.DEFAULT;
  const trigger = a.Trigger || {};

  const dimensions = (trigger.Dimensions || [])
    .map((d) => `${d.name}=${d.value}`)
    .join(', ') || 'none';

  const blocks = [
    {
      type: 'header',
      text: {
        type: 'plain_text',
        text: `${emoji} ${state === 'OK' ? 'RESOLVED' : 'ALARM'} — ${a.AlarmName}`,
        emoji: true,
      },
    },
    {
      type: 'section',
      text: { type: 'mrkdwn', text: a.AlarmDescription || a.NewStateReason || 'No description.' },
    },
    {
      type: 'section',
      fields: [
        field('Metric', `${trigger.Namespace || '?'} / ${trigger.MetricName || '?'}`),
        field('Threshold', `${trigger.Statistic || ''} ${trigger.ComparisonOperator || ''} ${trigger.Threshold ?? ''}`),
        field('Dimensions', dimensions),
        field('Region', a.Region || REGION),
      ],
    },
    {
      type: 'context',
      elements: [{ type: 'mrkdwn', text: truncate(a.NewStateReason || '', 300) }],
    },
    {
      type: 'actions',
      elements: [
        button(
          'Open in CloudWatch',
          `https://${REGION}.console.aws.amazon.com/cloudwatch/home?region=${REGION}#alarmsV2:alarm/${encodeURIComponent(a.AlarmName)}`,
        ),
      ],
    },
  ];

  return {
    text: `${emoji} ${state}: ${a.AlarmName}`,
    attachments: [{ color, blocks }],
  };
}

// ---------------------------------------------------------------------------
function buildGenericMessage(subject, body) {
  return {
    text: subject || 'StreamingApp notification',
    attachments: [
      {
        color: COLOR.DEFAULT,
        blocks: [
          { type: 'section', text: { type: 'mrkdwn', text: `*${subject || 'Notification'}*` } },
          {
            type: 'section',
            text: {
              type: 'mrkdwn',
              text: '```' + truncate(typeof body === 'string' ? body : JSON.stringify(body, null, 2), 2500) + '```',
            },
          },
        ],
      },
    ],
  };
}

// ---------------------------------------------------------------------------
// helpers
// ---------------------------------------------------------------------------
const field = (label, value) => ({ type: 'mrkdwn', text: `*${label}*\n${value}` });

const button = (text, url) => ({
  type: 'button',
  text: { type: 'plain_text', text, emoji: true },
  url,
});

const startsWithProtocol = (u) => (/^https?:\/\//i.test(u) ? u : `http://${u}`);

const truncate = (s, n) => (s && s.length > n ? `${s.slice(0, n)}…` : s || '');

function formatDuration(ms) {
  if (!ms || Number.isNaN(ms)) return 'n/a';
  const total = Math.round(ms / 1000);
  const m = Math.floor(total / 60);
  const s = total % 60;
  return m > 0 ? `${m}m ${s}s` : `${s}s`;
}

async function postToSlack(payload) {
  const res = await fetch(WEBHOOK, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(payload),
  });
  const text = await res.text();
  if (!res.ok) {
    console.error('Slack rejected the message', res.status, text);
  }
  return { status: res.status, body: text };
}
