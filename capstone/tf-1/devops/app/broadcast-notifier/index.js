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

async function getSlackUserIdByEmail(botToken, email) {
  const response = await fetchWithRetry(
    `https://slack.com/api/users.lookupByEmail?email=${encodeURIComponent(email)}`,
    { method: "GET", headers: { Authorization: `Bearer ${botToken}` } }
  );
  if (!response || !response.ok) {
    throw new Error(`Slack users.lookupByEmail HTTP ${response ? response.status : "timeout"}`);
  }
  const data = await response.json();
  if (!data.ok) {
    throw new Error(`Slack users.lookupByEmail error: ${data.error}`);
  }
  return data.user?.id;
}

exports.handler = async (event) => {
  console.log("Received EventBridge event:", JSON.stringify(event));

  // EventBridge puts the payload in the "detail" object
  const detail = event.detail;
  if (!detail || !detail.incident_id) {
    console.warn("Invalid event detail. Missing incident_id.");
    return { statusCode: 400, body: "Invalid payload" };
  }

  const { incident_id, jira_issue_key, assignee_name, assignee_email, slack_user_id, title, service, severity, jira_url } = detail;
  
  // You can define target_channel dynamically or fixed
  const targetChannel = detail.target_channel || "#incident-updates"; 
  
  let assigneeText = assignee_name && assignee_name !== "unknown" ? assignee_name : `<@${slack_user_id}>`;
  
  if (assignee_email && !assigneeText.startsWith("<@")) {
    try {
      const botToken = await getSlackBotToken();
      const targetSlackId = await getSlackUserIdByEmail(botToken, assignee_email);
      if (targetSlackId) {
        assigneeText = `<@${targetSlackId}>`;
      }
    } catch (err) {
      console.warn("Could not lookup Slack user by email:", err.message);
    }
  }

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
    let cleanUrl = jira_url || "";
    if (cleanUrl.startsWith("<") && cleanUrl.includes("|")) {
      cleanUrl = cleanUrl.substring(1, cleanUrl.indexOf("|"));
    } else if (cleanUrl.startsWith("<") && cleanUrl.endsWith(">")) {
      cleanUrl = cleanUrl.substring(1, cleanUrl.length - 1);
    }

    if (cleanUrl && !cleanUrl.includes("undefined")) {
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
            url: cleanUrl,
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
