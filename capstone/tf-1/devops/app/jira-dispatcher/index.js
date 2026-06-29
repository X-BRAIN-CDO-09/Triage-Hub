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
const crypto = require("crypto");

// Timeout mặc định cho các request HTTP bên ngoài (ms)
const EXTERNAL_API_TIMEOUT_MS = 10000;

// Retry settings for external API calls (429/5xx)
const MAX_RETRIES = 3;
const BASE_RETRY_DELAY_MS = 500;

let cachedJiraSecret = null;
let cachedSlackSigningSecret = null;

const dynamoClient = new DynamoDBClient({});
const secretsClient = new SecretsManagerClient({});

// Environment variables (set by Terraform)
const DYNAMODB_TABLE = process.env.DYNAMODB_TABLE;
const JIRA_SECRET_ARN = process.env.JIRA_SECRET_ARN;
const SLACK_SIGNING_SECRET_ARN = process.env.SLACK_SIGNING_SECRET_ARN;

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
  cachedSlackSigningSecret = await getSecret(SLACK_SIGNING_SECRET_ARN);
  return cachedSlackSigningSecret;
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
    } finally {
      clearTimeout(timeout);
    }

    const isRetryable = response.status === 429 || (response.status >= 500 && response.status < 600);
    if (!isRetryable || attempt === retries) {
      return response;
    }

    const delay = BASE_RETRY_DELAY_MS * Math.pow(2, attempt - 1) + Math.random() * 100;
    logStructured("WARN", "Retryable response, backing off", {
      attempt,
      status: response.status,
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
// Helper: Convert plain text / Markdown to Atlassian Document Format (ADF)
// =============================================================================
function markdownToAdf(text) {
  if (!text) {
    return { type: "doc", version: 1, content: [{ type: "paragraph", content: [] }] };
  }
  const lines = text.split("\n");
  const content = [];
  for (const line of lines) {
    content.push({
      type: "paragraph",
      content: [{ type: "text", text: line || " " }],
    });
  }
  return { type: "doc", version: 1, content };
}

// =============================================================================
// Helper: Map AI confidence & status → Jira priority + labels
// =============================================================================
function confidenceRouting(confidence, aiStatus) {
  const result = { priority: null, extraLabels: [] };

  // Priority based on confidence level
  if (confidence != null) {
    if (confidence > 0.7) {
      result.priority = { id: "2" }; // High
    } else if (confidence >= 0.4) {
      result.priority = { id: "3" }; // Medium
    } else {
      result.priority = { id: "4" }; // Low
    }
  }

  // Extra labels based on AI status
  if (aiStatus) {
    switch (aiStatus) {
      case "INVESTIGATE":
        result.extraLabels.push("investigation");
        break;
      case "INSUFFICIENT_CONTEXT":
        result.extraLabels.push("needs-context");
        break;
      case "UNSAFE_SUGGESTION_BLOCKED":
        result.extraLabels.push("safety-blocked");
        break;
    }
  }

  return result;
}

// Default Jira reporter account ID (Project Lead — Phong).
// Override via alertPayload.ownership?.jira_reporter_account_id.
const DEFAULT_JIRA_REPORTER_ACCOUNT_ID = "70121:f5ca0e65-3bf5-4102-ad3d-1313fdcb9f7e";

// =============================================================================
// GĐ 1: Tạo Jira Ticket qua REST API
// =============================================================================
async function createJiraTicket(jiraCreds, alertPayload) {
  const { email, token, base_url } = jiraCreds;

  // Basic auth: email:token → base64
  const auth = Buffer.from(`${email}:${token}`).toString("base64");

  // Detect input mode: AI contract (ticket_payload) vs legacy flat alert
  let fields;
  if (alertPayload.ticket_payload) {
    const tp = alertPayload.ticket_payload;
    const extra = tp.fields || {};

    const descParts = [];
    if (tp.description) descParts.push(tp.description);
    if (alertPayload.incident_id) descParts.push(`\nIncident ID: ${alertPayload.incident_id}`);
    if (extra.audit_id) descParts.push(`Audit ID: ${extra.audit_id}`);
    if (extra.confidence != null) descParts.push(`Confidence: ${Math.round(extra.confidence * 100)}%`);
    if (extra.owner_team) descParts.push(`Owner Team: ${extra.owner_team}`);
    if (extra.suggestion_reason) descParts.push(`Suggestion: ${extra.suggestion_reason}`);
    descParts.push("\nGenerated by Triage Hub AI System.");

    // Confidence-based routing: priority + extra labels
    const confidence = extra.confidence != null ? extra.confidence : alertPayload.confidence;
    const routing = confidenceRouting(confidence, alertPayload.status);

    const labels = [...new Set([...(tp.labels || []), "ai-triage", ...routing.extraLabels])];

    fields = {
      project: { key: tp.project || "TRIAGE" },
      summary: tp.summary || "Untitled incident",
      description: markdownToAdf(descParts.join("\n")),
      issuetype: { name: "Bug" },
      labels,
      reporter: { id: alertPayload.ownership?.jira_reporter_account_id || DEFAULT_JIRA_REPORTER_ACCOUNT_ID },
    };

    if (routing.priority) {
      fields.priority = routing.priority;
    }

    // Map suggested_assignee_account_id to assignee if present (human must
    // confirm per AI contract — this is consumed by GĐ 3 Slack callback,
    // not for auto-assignment here).
    if (extra.suggested_assignee_account_id) {
      fields.assignee = { id: extra.suggested_assignee_account_id };
    }
  } else {
    fields = {
      project: {
        key: alertPayload.ownership?.jira_project || "TRIAGE",
      },
      summary: `[${(alertPayload.alert?.severity || "unknown").toUpperCase()}] ${alertPayload.alert?.title || alertPayload.alert?.service || "New Incident"}`,
      description: {
        type: "doc",
        version: 1,
        content: [
          {
            type: "paragraph",
            content: [
              {
                type: "text",
                text: `Incident ID: ${alertPayload.incident_id || "N/A"}\nService: ${alertPayload.alert?.service || "unknown"}\nSeverity: ${alertPayload.alert?.severity || "unknown"}\nDescription: ${alertPayload.alert?.description || "No description"}\n\nGenerated by Triage Hub AI System.`,
              },
            ],
          },
        ],
      },
      issuetype: {
        name: "Bug",
      },
      labels: ["ai-triage", alertPayload.tenant_id || "unknown-tenant"],
      reporter: { id: alertPayload.ownership?.jira_reporter_account_id || DEFAULT_JIRA_REPORTER_ACCOUNT_ID },
    };
  }

  const ticketPayload = { fields };

  const startTime = Date.now();
  logStructured("INFO", "Creating Jira ticket", {
    incident_id: alertPayload.incident_id,
    project: fields.project.key,
  });

  let response;
  response = await fetchWithRetry(`${base_url}/rest/api/3/issue`, {
    method: "POST",
    headers: {
      Authorization: `Basic ${auth}`,
      "Content-Type": "application/json",
      Accept: "application/json",
    },
    body: JSON.stringify(ticketPayload),
  });

  if (!response.ok) {
    const errorBody = await response.text();
    logStructured("ERROR", "Jira API error", {
      incident_id: alertPayload.incident_id,
      status: response.status,
      error_body: errorBody,
      execution_time_ms: Date.now() - startTime,
    });
    throw new Error(`Jira API error: status ${response.status}`);
  }

  const result = await response.json();
  logStructured("INFO", "Jira ticket created", {
    incident_id: alertPayload.incident_id,
    issue_key: result.key,
    issue_id: result.id,
    execution_time_ms: Date.now() - startTime,
  });

  return {
    issueKey: result.key,     // e.g. "TRIAGE-42"
    issueId: result.id,       // e.g. "10042"
    self: result.self,        // API URL
  };
}

// =============================================================================
// GĐ 1: Reserve mapping trước khi tạo Jira (idempotent via conditional write)
// =============================================================================
async function reserveIncidentMapping(incidentId, tenantId, alertId) {
  const command = new PutItemCommand({
    TableName: DYNAMODB_TABLE,
    Item: {
      PK: { S: `TENANT#${tenantId}` },
      SK: { S: `INCIDENT#${incidentId}` },
      incident_id: { S: incidentId },
      tenant_id: { S: tenantId },
      alert_id: { S: alertId || "unknown" },
      status: { S: "PENDING" },
      created_at: { S: new Date().toISOString() },
    },
    ConditionExpression: "attribute_not_exists(PK)",
  });

  await dynamoClient.send(command);
  logStructured("INFO", "Incident reserved in DynamoDB", {
    tenant_id: tenantId,
    incident_id: incidentId,
    table_key: `TENANT#${tenantId}#INCIDENT#${incidentId}`,
  });
}

// =============================================================================
// GĐ 1: Cập nhật mapping sau khi Jira ticket tạo thành công
// =============================================================================
async function updateJiraMapping(incidentId, tenantId, jiraResult) {
  const command = new PutItemCommand({
    TableName: DYNAMODB_TABLE,
    Item: {
      PK: { S: `TENANT#${tenantId}` },
      SK: { S: `INCIDENT#${incidentId}` },
      incident_id: { S: incidentId },
      tenant_id: { S: tenantId },
      jira_issue_key: { S: jiraResult.issueKey },
      jira_issue_id: { S: jiraResult.issueId },
      status: { S: "UNASSIGNED" },
      created_at: { S: new Date().toISOString() },
    },
  });

  await dynamoClient.send(command);
  logStructured("INFO", "Jira mapping updated in DynamoDB", {
    tenant_id: tenantId,
    incident_id: incidentId,
    jira_issue_key: jiraResult.issueKey,
  });
}

// =============================================================================
// DLQ: Capture failed ticket creation to DynamoDB
// =============================================================================
async function dlqCapture(incidentId, tenantId, alertId, errorMessage) {
  try {
    const command = new PutItemCommand({
      TableName: DYNAMODB_TABLE,
      Item: {
        PK: { S: `TENANT#${tenantId}` },
        SK: { S: `DLQ#${incidentId}` },
        incident_id: { S: incidentId },
        tenant_id: { S: tenantId },
        alert_id: { S: alertId || "unknown" },
        status: { S: "FAILED" },
        error: { S: errorMessage || "unknown" },
        failed_at: { S: new Date().toISOString() },
      },
    });
    await dynamoClient.send(command);
    logStructured("INFO", "DLQ record written", { incident_id: incidentId, tenant_id: tenantId });
  } catch (dlqErr) {
    logStructured("ERROR", "Failed to write DLQ record", { incident_id: incidentId, error: dlqErr.message });
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

  if (!response.ok) {
    logStructured("ERROR", "Jira assign error", {
      issue_key: issueKey,
      status: response.status,
    });
    throw new Error(`Jira assign error: status ${response.status}`);
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
// Main Handler — Route theo loại event
// =============================================================================
exports.handler = async (event) => {
  const route = event.headers?.["x-slack-signature"] ? "slack-callback" : "create-ticket";
  logStructured("INFO", "jira-dispatcher invoked", { route });

  try {
    // =========================================================================
    // Route 1: Slack Interactive Callback (GĐ 3)
    // Slack gửi POST với body là "payload=..." (URL-encoded)
    // =========================================================================
    const rawBody = event.body || "";

    if (rawBody.startsWith("payload=") || (event.headers && event.headers["x-slack-signature"])) {
      return await handleSlackCallback(event);
    }

    // =========================================================================
    // Route 2: Direct invoke / API Gateway tạo Jira ticket (GĐ 1)
    // =========================================================================
    return await handleCreateTicket(event);

  } catch (err) {
    logStructured("ERROR", "jira-dispatcher unhandled error", { error: err.message });
    return {
      statusCode: 500,
      body: JSON.stringify({ error: "Internal server error" }),
    };
  }
};

// =============================================================================
// Handler: GĐ 1 — Tạo Jira Ticket
// =============================================================================
async function handleCreateTicket(event) {
  // Parse payload
  let alertPayload;
  if (event.body) {
    alertPayload = typeof event.body === "string" ? JSON.parse(event.body) : event.body;
  } else {
    alertPayload = event;
  }

  const incidentId = alertPayload.incident_id || alertPayload.correlation_id;
  if (!incidentId) {
    return {
      statusCode: 400,
      body: JSON.stringify({ error: "Missing incident_id or correlation_id" }),
    };
  }
  const tenantId = alertPayload.tenant_id || "unknown";
  const alertId = alertPayload.alert?.alert_id || "unknown";

  // 1. Reserve DynamoDB mapping trước (idempotent — nếu đã tồn tại thì trả về existing)
  try {
    await reserveIncidentMapping(incidentId, tenantId, alertId);
  } catch (err) {
    if (err.name === "ConditionalCheckFailedException") {
      logStructured("INFO", "Incident already exists, returning existing mapping", { incident_id: incidentId });
      const existing = await dynamoClient.send(new GetItemCommand({
        TableName: DYNAMODB_TABLE,
        Key: { PK: { S: `TENANT#${tenantId}` }, SK: { S: `INCIDENT#${incidentId}` } },
      }));
      return {
        statusCode: 200,
        body: JSON.stringify({
          status: "already_exists",
          incident_id: incidentId,
          jira_issue_key: existing.Item?.jira_issue_key?.S || "pending",
        }),
      };
    }
    throw err;
  }

  // 2. Lấy Jira credentials từ Secrets Manager
  const jiraCreds = await getJiraSecret();

  // 3. Tạo Jira ticket (nếu fail → DLQ + cleanup PENDING)
  let jiraResult;
  try {
    jiraResult = await createJiraTicket(jiraCreds, alertPayload);
    await updateJiraMapping(incidentId, tenantId, jiraResult);
  } catch (err) {
    await dlqCapture(incidentId, tenantId, alertId, err.message);
    logStructured("ERROR", "Jira ticket creation failed, removing PENDING reservation", { incident_id: incidentId, error: err.message });
    try {
      const { DeleteItemCommand } = require("@aws-sdk/client-dynamodb");
      await dynamoClient.send(new DeleteItemCommand({
        TableName: DYNAMODB_TABLE,
        Key: { PK: { S: `TENANT#${tenantId}` }, SK: { S: `INCIDENT#${incidentId}` } },
      }));
    } catch (deleteErr) {
      logStructured("ERROR", "Failed to clean up PENDING reservation", { incident_id: incidentId, error: deleteErr.message });
    }
    throw err;
  }

  return {
    statusCode: 201,
    body: JSON.stringify({
      status: "ticket_created",
      incident_id: incidentId,
      jira_issue_key: jiraResult.issueKey,
    }),
  };
}

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

    if (!response.ok) {
      logStructured("ERROR", "Slack response_url error", { status: response.status, response_url: responseUrl });
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
  const rawBody = event.body || "";
  const headers = event.headers || {};

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

  // 2. Parse Slack payload (Slack gửi x-www-form-urlencoded)
  const params = new URLSearchParams(rawBody);
  const payloadStr = params.get("payload");
  if (!payloadStr) {
    logStructured("ERROR", "Missing payload field in Slack callback body");
    return { statusCode: 400, body: "Bad Request: missing payload" };
  }

  let payload;
  try {
    payload = JSON.parse(payloadStr);
  } catch {
    logStructured("ERROR", "Invalid JSON in Slack callback payload");
    return { statusCode: 400, body: "Bad Request: invalid payload" };
  }

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
      jiraCreds = await getJiraSecret();
      try {
        await assignJiraTicket(jiraCreds, issueKey, assigneeAccountId);
      } catch (err) {
        logStructured("ERROR", "Assign ticket failed", { issue_key: issueKey, error: err.message });
        status = "FAILED_API";
      }
    } else {
      status = "MISSING_INFO";
    }

    await saveCallbackAudit(incidentId, tenantId, slackUser, "CONFIRM_ASSIGN", issueKey, assigneeAccountId, status);

    // Lấy thông tin assignee từ Jira để hiển thị tên
    let assigneeName = assigneeAccountId || "N/A";
    let jiraBaseUrl = "";
    if (jiraCreds && assigneeAccountId) {
      jiraBaseUrl = jiraCreds.base_url;
      try {
        const auth = Buffer.from(`${jiraCreds.email}:${jiraCreds.token}`).toString("base64");
        let userResp;
        userResp = await fetchWithRetry(`${jiraCreds.base_url}/rest/api/3/user?accountId=${encodeURIComponent(assigneeAccountId)}`, {
          method: "GET",
          headers: { Authorization: `Basic ${auth}`, Accept: "application/json" },
        });
        if (userResp.ok) {
          const userData = await userResp.json();
          const name = userData.displayName || assigneeAccountId;
          const email = userData.emailAddress ? ` (${userData.emailAddress})` : "";
          assigneeName = `${name}${email}`;
        }
      } catch (err) {
        logStructured("WARN", "Failed to fetch assignee name", { error: err.message });
      }
    }

    // Build Jira ticket link
    const jiraLink = issueKey && jiraBaseUrl
      ? `<${jiraBaseUrl}/browse/${issueKey}|${issueKey}>`
      : (issueKey || "N/A");

    // Cập nhật Slack message qua response_url (xóa nút bấm, thêm trạng thái)
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

    return { statusCode: 200, body: "" };
  }

  if (action.action_id === "self_assign_incident_action") {
    // Self-assign — cần lấy Jira account ID từ Slack user mapping
    // Hiện tại chỉ lưu audit, vì cần mapping Slack → Jira account
    await saveCallbackAudit(incidentId, tenantId, slackUser, "SELF_ASSIGN", issueKey, "pending_lookup", "PENDING");

    // Cập nhật Slack message qua response_url (xóa nút bấm)
    const originalBlocks = payload.message?.blocks || [];
    const updatedBlocks = originalBlocks.filter(b => b.type !== "actions");
    updatedBlocks.push({
      type: "context",
      elements: [
        {
          type: "mrkdwn",
          text: `🙋 *Ticket ${issueKey || "N/A"}* was self-assigned by <@${slackUserId}>.`
        }
      ]
    });

    if (responseUrl) {
      await updateSlackMessage(responseUrl, updatedBlocks);
    }

    return { statusCode: 200, body: "" };
  }

  // Action không xác định
  return { statusCode: 200, body: "OK" };
}
