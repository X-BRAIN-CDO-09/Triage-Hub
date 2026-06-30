// =============================================================================
// jira-dispatcher Lambda
// Giai đoạn 1: Tạo Jira Ticket (Unassigned) + lưu mapping DynamoDB
// Giai đoạn 3: Xử lý Slack callback (Confirm & Assign)
//
// Trigger: API Gateway POST /slack
// Flow GĐ1: Nhận alert payload → tạo Jira ticket → lưu mapping DynamoDB
// Flow GĐ3: Nhận Slack callback → verify signature → assign Jira → audit
// =============================================================================

const { DynamoDBClient, PutItemCommand, GetItemCommand } = require("@aws-sdk/client-dynamodb");
const { SecretsManagerClient, GetSecretValueCommand } = require("@aws-sdk/client-secrets-manager");
const { LambdaClient, InvokeCommand } = require("@aws-sdk/client-lambda");
const { EventBridgeClient, PutEventsCommand } = require("@aws-sdk/client-eventbridge");
const crypto = require("crypto");

// Timeout mặc định cho các request HTTP bên ngoài (ms)
const EXTERNAL_API_TIMEOUT_MS = 10000;

// Retry settings for external API calls (429/5xx)
const MAX_RETRIES = 3;
const BASE_RETRY_DELAY_MS = 500;

let cachedJiraSecret = null;
let cachedSlackSigningSecret = null;
let cachedSlackBotToken = null;

const dynamoClient = new DynamoDBClient({});
const secretsClient = new SecretsManagerClient({});
const lambdaClient = new LambdaClient({});
const eventBridgeClient = new EventBridgeClient({});

// Environment variables (set by Terraform)
const DYNAMODB_TABLE = process.env.DYNAMODB_TABLE;
const JIRA_SECRET_ARN = process.env.JIRA_SECRET_ARN;
const SLACK_SIGNING_SECRET_ARN = process.env.SLACK_SIGNING_SECRET_ARN;
const EVENT_BUS_NAME = process.env.EVENT_BUS_NAME;
const SLACK_BOT_TOKEN_ARN = process.env.SLACK_BOT_TOKEN_ARN;

// =============================================================================
// Helper: Lấy secret từ AWS Secrets Manager (có cache)
// =============================================================================
async function getSecret(secretArn) {
  const command = new GetSecretValueCommand({ SecretId: secretArn });
  const response = await secretsClient.send(command);
  return response.SecretString;
}

async function getJiraSecret() {
  if (cachedJiraSecret) return cachedJiraSecret;
  const raw = await getSecret(JIRA_SECRET_ARN);
  cachedJiraSecret = JSON.parse(raw); // { email, token, base_url }
  return cachedJiraSecret;
}

async function getSlackSigningSecret() {
  if (cachedSlackSigningSecret) return cachedSlackSigningSecret;
  const raw = await getSecret(SLACK_SIGNING_SECRET_ARN);
  try {
    const parsed = JSON.parse(raw);
    cachedSlackSigningSecret = parsed.signing_secret || parsed.token || raw;
  } catch (err) {
    cachedSlackSigningSecret = raw.trim();
  }
  return cachedSlackSigningSecret;
}

async function getSlackBotToken() {
  if (cachedSlackBotToken) return cachedSlackBotToken;
  const raw = await getSecret(SLACK_BOT_TOKEN_ARN);
  try {
    const parsed = JSON.parse(raw);
    cachedSlackBotToken = parsed.token || parsed.bot_token || raw;
  } catch (err) {
    cachedSlackBotToken = raw.trim();
  }
  return cachedSlackBotToken;
}

// =============================================================================
// GĐ 3: Map Slack user (người bấm "Assign Me") -> Jira accountId
//   Slack users.info (cần scope users:read.email) -> email
//   -> Jira /user/search?query=email -> accountId
// =============================================================================
async function getSlackUserEmail(botToken, slackUserId) {
  const response = await fetchWithRetry(
    `https://slack.com/api/users.info?user=${encodeURIComponent(slackUserId)}`,
    { method: "GET", headers: { Authorization: `Bearer ${botToken}` } }
  );
  if (!response || !response.ok) {
    throw new Error(`Slack users.info HTTP ${response ? response.status : "timeout"}`);
  }
  const data = await response.json();
  if (!data.ok) {
    throw new Error(`Slack users.info error: ${data.error}`);
  }
  const email = data.user?.profile?.email;
  if (!email) {
    throw new Error("Slack user profile has no email (thiếu scope users:read.email?)");
  }
  return email;
}

async function findJiraAccountIdByEmail(jiraCreds, email) {
  const { email: jiraEmail, token, base_url } = jiraCreds;
  const auth = Buffer.from(`${jiraEmail}:${token}`).toString("base64");

  const response = await fetchWithRetry(
    `${base_url}/rest/api/3/user/search?query=${encodeURIComponent(email)}`,
    { method: "GET", headers: { Authorization: `Basic ${auth}`, Accept: "application/json" } }
  );
  if (!response || !response.ok) {
    throw new Error(`Jira user search HTTP ${response ? response.status : "timeout"}`);
  }
  const users = await response.json();
  if (!Array.isArray(users) || users.length === 0) {
    throw new Error(`No Jira user matched email ${email}`);
  }
  // Ưu tiên khớp chính xác email + account atlassian (tránh app/bot account)
  const exact = users.find(
    (u) => (u.emailAddress || "").toLowerCase() === email.toLowerCase() && u.accountType === "atlassian"
  );
  const chosen = exact || users.find((u) => u.accountType === "atlassian") || users[0];
  if (!chosen.accountId) {
    throw new Error(`Jira user for ${email} has no accountId`);
  }
  return { accountId: chosen.accountId, displayName: chosen.displayName, emailAddress: chosen.emailAddress };
}

// =============================================================================
// Helper: Fetch with retry (exponential backoff + jitter)
// =============================================================================
async function fetchWithRetry(url, options, retries = MAX_RETRIES) {
  for (let attempt = 1; attempt <= retries; attempt++) {
    const controller = new AbortController();
    const timeout = setTimeout(() => controller.abort(), EXTERNAL_API_TIMEOUT_MS);

    let response;
    try {
      response = await fetch(url, { ...options, signal: controller.signal });
    } catch (err) {
      logStructured("WARN", `Fetch error on attempt ${attempt}`, { error: err.message });
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
    logStructured("WARN", "Retryable response, backing off", {
      attempt,
      status: response ? response.status : "error",
      delay_ms: Math.round(delay),
      url: url.split("/").pop(),
    });
    await new Promise((r) => setTimeout(r, delay));
  }
  return null;
}

// =============================================================================
// Structured JSON logger
// =============================================================================
function logStructured(level, message, extra = {}) {
  const entry = {
    timestamp: new Date().toISOString(),
    level,
    service: "jira-dispatcher",
    message,
    ...extra,
  };
  if (level === "ERROR") {
    console.error(JSON.stringify(entry));
  } else {
    console.log(JSON.stringify(entry));
  }
}


// =============================================================================
// GĐ 3: Verify Slack Request Signature
// =============================================================================
function verifySlackSignature(signingSecret, requestBody, timestamp, signature) {
  // Reject stale requests (> 5 phút)
  const now = Math.floor(Date.now() / 1000);
  if (Math.abs(now - parseInt(timestamp)) > 300) {
    logStructured("WARN", "Slack request timestamp is stale", { timestamp, now });
    return false;
  }

  const sigBasestring = `v0:${timestamp}:${requestBody}`;
  const mySignature = "v0=" + crypto
    .createHmac("sha256", signingSecret)
    .update(sigBasestring, "utf8")
    .digest("hex");

  // timingSafeEqual throws khi length khác nhau → guard trước
  const myBuf = Buffer.from(mySignature, "utf8");
  const theirBuf = Buffer.from(signature, "utf8");
  if (myBuf.length !== theirBuf.length) return false;

  return crypto.timingSafeEqual(myBuf, theirBuf);
}

// =============================================================================
// GĐ 3: Assign Jira Ticket
// =============================================================================
async function assignJiraTicket(jiraCreds, issueKey, accountId) {
  const { email, token, base_url } = jiraCreds;
  const auth = Buffer.from(`${email}:${token}`).toString("base64");

  const response = await fetchWithRetry(`${base_url}/rest/api/3/issue/${issueKey}/assignee`, {
    method: "PUT",
    headers: {
      Authorization: `Basic ${auth}`,
      "Content-Type": "application/json",
    },
    body: JSON.stringify({ accountId }),
  });

  if (!response || !response.ok) {
    logStructured("ERROR", "Jira assign error", {
      issue_key: issueKey,
      status: response ? response.status : "timeout/null",
    });
    throw new Error(`Jira assign error: status ${response ? response.status : "timeout"}`);
  }

  logStructured("INFO", "Jira ticket assigned", { issue_key: issueKey, account_id: accountId });
}

// =============================================================================
// GĐ 3: Lưu audit trail khi user bấm nút trên Slack
// =============================================================================
async function saveCallbackAudit(incidentId, tenantId, slackUser, actionType, issueKey, assigneeJiraId, status) {
  const timestamp = Math.floor(Date.now() / 1000);
  const command = new PutItemCommand({
    TableName: DYNAMODB_TABLE,
    Item: {
      PK: { S: `TENANT#${tenantId}#INCIDENT#${incidentId}` },
      SK: { S: `AUDIT#${timestamp}` },
      incident_id: { S: incidentId },
      tenant_id: { S: tenantId },
      jira_issue_key: { S: issueKey || "unknown" },
      action_type: { S: actionType },
      approver_slack_id: { S: slackUser.id },
      approver_slack_name: { S: slackUser.name },
      assigned_jira_id: { S: assigneeJiraId || "unknown" },
      status: { S: status },
      actioned_at: { S: new Date().toISOString() },
    },
  });

  await dynamoClient.send(command);
}

// =============================================================================
// Main Handler — Slack Callback Only
// =============================================================================
exports.handler = async (event) => {
  logStructured("INFO", "jira-dispatcher invoked for Slack callback");

  try {
    return await handleSlackCallback(event);
  } catch (err) {
    logStructured("ERROR", "jira-dispatcher unhandled error", { error: err.message });
    return {
      statusCode: 500,
      body: JSON.stringify({ error: "Internal server error" }),
    };
  }
};


// =============================================================================
// GĐ 3: Gọi Slack response_url để cập nhật message gốc
// =============================================================================
async function updateSlackMessage(responseUrl, updatedBlocks) {
  try {
    const response = await fetchWithRetry(responseUrl, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        replace_original: true,
        blocks: updatedBlocks,
      }),
    });

    if (!response || !response.ok) {
      logStructured("ERROR", "Slack response_url error", { status: response ? response.status : "timeout/null", response_url: responseUrl });
    } else {
      logStructured("INFO", "Slack message updated via response_url", { response_url: responseUrl });
    }
  } catch (err) {
    logStructured("ERROR", "Failed to update Slack message (non-fatal)", { error: err.message });
  }
}

// =============================================================================
// Handler: GĐ 3 — Slack Callback (Confirm & Assign)
// =============================================================================
async function handleSlackCallback(event) {
  let rawBody = event.body || "";
  if (event.isBase64Encoded) {
    rawBody = Buffer.from(rawBody, "base64").toString("utf8");
  }
  const headers = event.headers || {};

  // Nếu có cờ isAsyncBackground, tiến hành xử lý ngầm (bỏ qua bước parse rawBody vì payload đã được parse)
  if (event.isAsyncBackground) {
    return await processAsyncSlackCallback(event);
  }

  // 1. Verify Slack Signature (fail-closed: bắt buộc có signing secret)
  if (!SLACK_SIGNING_SECRET_ARN) {
    logStructured("ERROR", "SLACK_SIGNING_SECRET_ARN not configured — rejecting request");
    return { statusCode: 500, body: "Server misconfiguration" };
  }

  const signingSecret = await getSlackSigningSecret();
  const timestamp = headers["x-slack-request-timestamp"] || headers["X-Slack-Request-Timestamp"];
  const signature = headers["x-slack-signature"] || headers["X-Slack-Signature"];

  if (!timestamp || !signature || !verifySlackSignature(signingSecret, rawBody, timestamp, signature)) {
    logStructured("ERROR", "Slack signature verification failed");
    return { statusCode: 401, body: "Unauthorized" };
  }

  // 2. Invoke Self Asynchronously
  try {
    const payloadStr = new URLSearchParams(rawBody).get("payload");
    if (!payloadStr) {
      logStructured("WARN", "Slack callback missing payload");
      return { statusCode: 400, body: "Missing payload" };
    }

    const payloadObj = JSON.parse(payloadStr);
    if (!payloadObj || typeof payloadObj !== "object") {
      logStructured("WARN", "Slack callback payload is invalid");
      return { statusCode: 400, body: "Invalid payload" };
    }
    
    await lambdaClient.send(new InvokeCommand({
      FunctionName: process.env.AWS_LAMBDA_FUNCTION_NAME,
      InvocationType: "Event", // Background execution
      Payload: JSON.stringify({
        ...event,
        isAsyncBackground: true,
        parsedSlackPayload: payloadObj // Truyền thẳng payload đã parse
      })
    }));
    
    logStructured("INFO", "Dispatched to background execution successfully");
  } catch (err) {
    logStructured("ERROR", "Failed to dispatch async background process", { error: err.message });
    return { statusCode: 500, body: "Internal Server Error" };
  }

  // 3. Lập tức trả về 200 OK cho Slack trong vòng 100ms
  return { statusCode: 200, body: "" };
}

// =============================================================================
// Background Worker (Asynchronous)
// =============================================================================
async function processAsyncSlackCallback(event) {
  const payload = event.parsedSlackPayload;
  const jiraCredsPromise = getJiraSecret(); // Fetch sớm

  const action = payload.actions?.[0];
  const slackUserId = payload.user?.id || "unknown";
  const slackUserName = payload.user?.username || payload.user?.name || "unknown";
  const slackUser = { id: slackUserId, name: slackUserName };
  const responseUrl = payload.response_url;

  if (!action) {
    return { statusCode: 200, body: "No action found" };
  }

  logStructured("INFO", "Slack action received", {
    action_id: action.action_id,
    slack_user: slackUserName,
  });

  // 3. Parse action value
  let actionValue;
  try {
    actionValue = JSON.parse(action.value);
  } catch {
    actionValue = { incident_id: action.value };
  }

  const incidentId = actionValue.incident_id || "unknown";
  const issueKey = actionValue.jira_issue_key;
  const tenantId = actionValue.tenant_id || "unknown";

  // 4. Handle từng loại action
  if (action.action_id === "assign_incident_action") {
    // Confirm & Assign — dùng suggested_assignee từ AI
    const assigneeAccountId = actionValue.suggested_assignee_account_id;
    let status = "SUCCESS";
    let jiraCreds;

    if (issueKey && assigneeAccountId) {
      jiraCreds = await jiraCredsPromise;
      
      // Chạy song song Jira API và DynamoDB để tiết kiệm tối đa thời gian (tránh timeout 3s)
      const assignPromise = assignJiraTicket(jiraCreds, issueKey, assigneeAccountId).catch(err => {
        logStructured("ERROR", "Assign ticket failed", { issue_key: issueKey, error: err.message });
        status = "FAILED_API";
      });
      
      const auditPromise = saveCallbackAudit(incidentId, tenantId, slackUser, "CONFIRM_ASSIGN", issueKey, assigneeAccountId, "SUCCESS").catch(err => {
        logStructured("WARN", "Failed to save audit", { error: err.message });
      });

      await Promise.all([assignPromise, auditPromise]);
    } else {
      status = "MISSING_INFO";
      await saveCallbackAudit(incidentId, tenantId, slackUser, "CONFIRM_ASSIGN", issueKey, assigneeAccountId, status);
    }

    // Hiển thị tên từ payload (được truyền sẵn từ notify-dispatcher) để tiết kiệm thời gian lấy data
    let assigneeName = assigneeAccountId || "N/A";
    let broadcastAssigneeName = assigneeName;
    if (actionValue.assignee_name) {
      assigneeName = `*${actionValue.assignee_name}*`;
      broadcastAssigneeName = actionValue.assignee_name;
      if (actionValue.assignee_email) assigneeName += ` (${actionValue.assignee_email})`;
    }
    let jiraBaseUrl = jiraCreds?.base_url || "";

    // Build Jira ticket link
    const jiraLink = issueKey && jiraBaseUrl
      ? `<${jiraBaseUrl}/browse/${issueKey}|${issueKey}>`
      : (issueKey || "N/A");

    // Cập nhật Slack message qua response_url (chạy nền, không sợ timeout)
    const originalBlocks = payload.message?.blocks || [];
    const updatedBlocks = originalBlocks.filter(b => b.type !== "actions");
    updatedBlocks.push({
      type: "section",
      text: {
        type: "mrkdwn",
        text: `✅ *Assigned!*\n• *Ticket:* ${jiraLink}\n• *Assigned to:* ${assigneeName}\n• *Confirmed by:* <@${slackUserId}>`
      }
    });

    if (responseUrl) {
      await updateSlackMessage(responseUrl, updatedBlocks);
    }
    
    // Broadcast notification via EventBridge
    if (EVENT_BUS_NAME && status === "SUCCESS") {
      try {
        const command = new PutEventsCommand({
          Entries: [{
            EventBusName: EVENT_BUS_NAME,
            Source: "triage-hub.jira",
            DetailType: "IncidentAssigned",
            Detail: JSON.stringify({
              incident_id: incidentId,
              jira_issue_key: issueKey,
              assignee_name: broadcastAssigneeName,
              slack_user_id: slackUserId,
              title: actionValue.title || "Untitled incident",
              service: actionValue.service || "unknown",
              severity: actionValue.severity || "medium",
              jira_url: actionValue.jira_url || jiraLink,
              target_channel: "#incident-updates"
            })
          }]
        });
        await eventBridgeClient.send(command);
        logStructured("INFO", "Published broadcast event to EventBridge");
      } catch (err) {
        logStructured("ERROR", "Failed to publish broadcast event", { error: err.message });
      }
    }
    
    return { statusCode: 200, body: "" };
  }

  if (action.action_id === "self_assign_incident_action") {
    // Self-assign: map Slack user (người bấm) -> email -> Jira accountId -> assign THẬT
    let status = "SUCCESS";
    let assigneeAccountId = null;
    let assigneeLabel = `<@${slackUserId}>`;
    let failureReason = null;

    if (!issueKey) {
      status = "MISSING_INFO";
      failureReason = "Thiếu jira_issue_key";
    } else if (!SLACK_BOT_TOKEN_ARN) {
      status = "FAILED_CONFIG";
      failureReason = "SLACK_BOT_TOKEN_ARN chưa được cấu hình cho jira-dispatcher";
      logStructured("ERROR", "SLACK_BOT_TOKEN_ARN not configured — cannot resolve Slack→Jira for self-assign");
    } else {
      try {
        const [jiraCreds, botToken] = await Promise.all([jiraCredsPromise, getSlackBotToken()]);
        const email = await getSlackUserEmail(botToken, slackUserId);
        const jiraUser = await findJiraAccountIdByEmail(jiraCreds, email);
        assigneeAccountId = jiraUser.accountId;

        await assignJiraTicket(jiraCreds, issueKey, assigneeAccountId);

        assigneeLabel = jiraUser.displayName
          ? `*${jiraUser.displayName}*${jiraUser.emailAddress ? ` (${jiraUser.emailAddress})` : ""}`
          : `<@${slackUserId}>`;
        logStructured("INFO", "Self-assign succeeded", {
          issue_key: issueKey, account_id: assigneeAccountId, slack_user: slackUserName,
        });
      } catch (err) {
        status = "FAILED_API";
        failureReason = err.message;
        logStructured("ERROR", "Self-assign failed", {
          issue_key: issueKey, slack_user: slackUserName, error: err.message,
        });
      }
    }

    await saveCallbackAudit(
      incidentId, tenantId, slackUser, "SELF_ASSIGN", issueKey, assigneeAccountId || "lookup_failed", status
    ).catch((err) => logStructured("WARN", "Failed to save audit", { error: err.message }));

    // Cập nhật Slack message qua response_url (chạy nền)
    const originalBlocks = payload.message?.blocks || [];
    const updatedBlocks = originalBlocks.filter(b => b.type !== "actions");

    if (status === "SUCCESS") {
      const jiraCreds = await jiraCredsPromise.catch(() => null);
      const jiraBaseUrl = jiraCreds?.base_url || "";
      const jiraLink = issueKey && jiraBaseUrl
        ? `<${jiraBaseUrl}/browse/${issueKey}|${issueKey}>`
        : (issueKey || "N/A");
      updatedBlocks.push({
        type: "section",
        text: {
          type: "mrkdwn",
          text: `✅ *Assigned!*\n• *Ticket:* ${jiraLink}\n• *Assigned to:* ${assigneeLabel}\n• *Self-assigned by:* <@${slackUserId}>`
        }
      });
      
      // Broadcast notification via EventBridge
      if (EVENT_BUS_NAME) {
        try {
          const command = new PutEventsCommand({
            Entries: [{
              EventBusName: EVENT_BUS_NAME,
              Source: "triage-hub.jira",
              DetailType: "IncidentAssigned",
              Detail: JSON.stringify({
                incident_id: incidentId,
                jira_issue_key: issueKey,
                assignee_name: assigneeLabel,
                slack_user_id: slackUserId,
                title: actionValue.title || "Untitled incident",
                service: actionValue.service || "unknown",
                severity: actionValue.severity || "medium",
                jira_url: actionValue.jira_url || jiraLink,
                target_channel: "#incident-updates"
              })
            }]
          });
          await eventBridgeClient.send(command);
          logStructured("INFO", "Published broadcast event to EventBridge for self-assign");
        } catch (err) {
          logStructured("ERROR", "Failed to publish broadcast event for self-assign", { error: err.message });
        }
      }
    } else {
      // KHÔNG báo thành công giả — hiển thị lỗi rõ ràng + giữ nút để retry
      updatedBlocks.push({
        type: "section",
        text: {
          type: "mrkdwn",
          text: `⚠️ *Chưa gán được ${issueKey || "ticket"} trên Jira*\nLý do: ${failureReason || status}. Hãy thử lại hoặc gán thủ công.`
        }
      });
      const retryActions = originalBlocks.find(b => b.type === "actions");
      if (retryActions) updatedBlocks.push(retryActions);
    }

    if (responseUrl) {
      await updateSlackMessage(responseUrl, updatedBlocks);
    }

    return { statusCode: 200, body: "" };
  }

  // Action không xác định
  return { statusCode: 200, body: "OK" };
}
