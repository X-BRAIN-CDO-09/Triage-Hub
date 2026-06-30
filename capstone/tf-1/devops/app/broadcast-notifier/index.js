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
  const parsed = JSON.parse(response.SecretString);
  cachedSlackBotToken = parsed.token || parsed.bot_token;
  if (!cachedSlackBotToken) {
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
    } finally {
      clearTimeout(timeout);
    }

    const isRetryable = response.status === 429 || (response.status >= 500 && response.status < 600);
    if (!isRetryable || attempt === retries) {
      return response;
    }

    const delay = BASE_RETRY_DELAY_MS * Math.pow(2, attempt - 1) + Math.random() * 100;
    await new Promise((r) => setTimeout(r, delay));
  }
  return null;
}

exports.handler = async (event) => {
  console.log("Received EventBridge event:", JSON.stringify(event));

  // EventBridge puts the payload in the "detail" object
  const detail = event.detail;
  if (!detail || !detail.incident_id) {
    console.warn("Invalid event detail. Missing incident_id.");
    return { statusCode: 400, body: "Invalid payload" };
  }

  const { incident_id, jira_issue_key, assignee_name, slack_user_id } = detail;
  
  // You can define target_channel dynamically or fixed
  const targetChannel = detail.target_channel || "#incident-updates"; 
  
  const assigneeText = assignee_name && assignee_name !== "unknown" ? assignee_name : `<@${slack_user_id}>`;
  const messageText = `📣 *Incident Update*\nThe incident \`${incident_id}\` (Ticket: *${jira_issue_key || "N/A"}*) has been assigned to ${assigneeText} and is now being investigated.`;

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
        text: messageText
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
