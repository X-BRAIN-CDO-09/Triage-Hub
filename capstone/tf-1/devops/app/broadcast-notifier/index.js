const { SecretsManagerClient, GetSecretValueCommand } = require("@aws-sdk/client-secrets-manager");

const secretsClient = new SecretsManagerClient({});
const SLACK_BOT_TOKEN_ARN = process.env.SLACK_BOT_TOKEN_ARN;
let cachedSlackBotToken = null;

const EXTERNAL_API_TIMEOUT_MS = 10000;
const MAX_RETRIES = 3;
const BASE_RETRY_DELAY_MS = 500;

async function getSlackBotToken() {
  if (cachedSlackBotToken) return cachedSlackBotToken;
  const command = new GetSecretValueCommand({ SecretId: SLACK_BOT_TOKEN_ARN });
  const response = await secretsClient.send(command);
  try {
    const parsed = JSON.parse(response.SecretString);
    cachedSlackBotToken = parsed.token || parsed.bot_token || response.SecretString.trim();
  } catch (err) {
    cachedSlackBotToken = response.SecretString.trim(); // fallback if not json
  }
  return cachedSlackBotToken;
}

async function fetchWithRetry(url, options, retries = MAX_RETRIES) {
  for (let attempt = 1; attempt <= retries; attempt++) {
    const controller = new AbortController();
    const timeout = setTimeout(() => controller.abort(), EXTERNAL_API_TIMEOUT_MS);

    let response;
    try {
      response = await fetch(url, { ...options, signal: controller.signal });
    } catch (err) {
      console.warn(`Fetch error on attempt ${attempt}:`, err.message);
    } finally {
      clearTimeout(timeout);
    }

    if (response) {
      const isRetryable = response.status === 429 || (response.status >= 500 && response.status < 600);
      if (!isRetryable || attempt === retries) {
        return response;
      }
    } else if (attempt === retries) {
      return null;
    }

    const delay = BASE_RETRY_DELAY_MS * Math.pow(2, attempt - 1) + Math.random() * 100;
    await new Promise((r) => setTimeout(r, delay));
  }
  return null;
}

function getSeverityDisplay(severity) {
  const map = {
    critical: { emoji: "🔴", label: "CRITICAL" },
    high: { emoji: "🟠", label: "HIGH" },
    medium: { emoji: "🟡", label: "MEDIUM" },
    low: { emoji: "🟢", label: "LOW" },
  };
  const key = (severity || "medium").toLowerCase();
  return map[key] || map.medium;
}

function escapeSlackMrkdwn(text) {
  if (!text) return "";
  return String(text).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
}

exports.handler = async (event) => {
  console.log("Received EventBridge event:", JSON.stringify(event));

  // EventBridge puts the payload in the "detail" object
  const detail = event.detail;
  if (!detail || !detail.incident_id) {
    console.warn("Invalid event detail. Missing incident_id.");
    return { statusCode: 400, body: "Invalid payload" };
  }

  const { incident_id, jira_issue_key, assignee_name, slack_user_id, title, service, severity, jira_url } = detail;
  
  // You can define target_channel dynamically or fixed
  const targetChannel = detail.target_channel || "#incident-updates"; 
  
  const assigneeText = assignee_name && assignee_name !== "unknown" ? assignee_name : `<@${slack_user_id}>`;
  const sevDisplay = getSeverityDisplay(severity);

  const fallbackText = `🚨 [${sevDisplay.label}] ${title || "Incident Update"} has been assigned to ${assigneeText}`;

  const blocks = [
    {
      type: "header",
      text: {
        type: "plain_text",
        text: `${sevDisplay.emoji} [${sevDisplay.label}] ${escapeSlackMrkdwn(title || "Incident Update")}`,
        emoji: true
      }
    },
    {
      type: "section",
      fields: [
        {
          type: "mrkdwn",
          text: `*Service:*\n\`${escapeSlackMrkdwn(service || "unknown")}\``
        },
        {
          type: "mrkdwn",
          text: `*Incident ID:*\n\`${escapeSlackMrkdwn(incident_id)}\``
        },
        {
          type: "mrkdwn",
          text: `*Assigned To:*\n${assigneeText}`
        },
        {
          type: "mrkdwn",
          text: `*Time:*\n${new Date().toISOString()}`
        }
      ]
    }
  ];

  if (jira_url || jira_issue_key) {
    // If we only have issue key but no URL, we cannot reliably construct the url without base_url secret.
    // However, if jira_url was passed, we use it. If not, omit the button or provide a placeholder.
    if (jira_url && !jira_url.includes("undefined")) {
      blocks.push({ type: "divider" });
      blocks.push({
        type: "actions",
        elements: [
          {
            type: "button",
            text: {
              type: "plain_text",
              text: "🎫 View Details in Jira",
              emoji: true
            },
            url: jira_url,
            action_id: "open_jira_ticket_broadcast_action"
          }
        ]
      });
    }
  }

  try {
    const token = await getSlackBotToken();
    const response = await fetchWithRetry("https://slack.com/api/chat.postMessage", {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Authorization: `Bearer ${token}`
      },
      body: JSON.stringify({
        channel: targetChannel,
        text: fallbackText,
        blocks: blocks
      })
    });

    if (!response || !response.ok) {
       console.error("Failed to notify public channel. HTTP status:", response ? response.status : "timeout");
       return { statusCode: 500, body: "Failed to post to Slack" };
    }

    const result = await response.json();
    if (!result.ok) {
       console.error("Slack API error:", result.error);
       return { statusCode: 500, body: `Slack error: ${result.error}` };
    }

    console.log(`Successfully broadcasted message to ${targetChannel}`);
    return { statusCode: 200, body: "Broadcast successful" };
  } catch (err) {
    console.error("Error broadcasting message:", err);
    return { statusCode: 500, body: "Internal server error" };
  }
};
