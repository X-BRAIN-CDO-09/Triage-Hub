// =============================================================================
// jira-dispatcher Lambda
// Giai đoạn 1: Tạo Jira Ticket (Unassigned) + lưu mapping DynamoDB
// Giai đoạn 3: Xử lý Slack callback (Confirm & Assign)
//
// Trigger: API Gateway POST /slack
// Flow GĐ1: Nhận alert payload → tạo Jira ticket → lưu mapping DynamoDB
// Flow GĐ3: Nhận Slack callback → verify signature → assign Jira → audit
// =============================================================================

const { DynamoDBClient, PutItemCommand, GetItemCommand, DeleteItemCommand } = require("@aws-sdk/client-dynamodb");
const { SecretsManagerClient, GetSecretValueCommand } = require("@aws-sdk/client-secrets-manager");
const crypto = require("crypto");

// Timeout mặc định cho các request HTTP bên ngoài (ms)
const EXTERNAL_API_TIMEOUT_MS = 10000;

const SERVICE_NAME = process.env.SERVICE_NAME || "jira-dispatcher";
const ENVIRONMENT = process.env.ENVIRONMENT || "unknown";
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
// Structured Logging Helper
// =============================================================================
function log(severity, message, correlationId, data = {}) {
  const logEntry = {
    timestamp: new Date().toISOString(),
    severity,
    message,
    "service.name": SERVICE_NAME,
    environment: ENVIRONMENT,
    trace_id: process.env._X_AMZN_TRACE_ID || "unknown",
    span_id: "unknown",
    correlation_id: correlationId || "unknown",
    ...data
  };
  console[severity === "error" ? "error" : "log"](JSON.stringify(logEntry));
}

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
    log("warn", "Retryable response, backing off", "unknown", {
      attempt,
      status: response.status,
      delay_ms: Math.round(delay),
      url: url.split("/").pop(),
    });
    await new Promise((r) => setTimeout(r, delay));
  }
  return null;
}


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
async function createJiraTicket(jiraCreds, alertPayload, correlationId) {
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

  log("info", "Creating Jira ticket", correlationId, { incident_id: alertPayload.incident_id, project: fields.project.key });

  const startTime = Date.now();
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
    log("error", "Jira API error", "unknown", {
      incident_id: alertPayload.incident_id,
      status: response.status,
      error_body: errorBody,
      execution_time_ms: Date.now() - startTime,
    });
    throw new Error(`Jira API error: status ${response.status}`);
  }

  const result = await response.json();
  log("info", "Jira ticket created", correlationId, { key: result.key, id: result.id });

  return {
    issueKey: result.key,
    issueId: result.id,
    self: result.self,
  };

  log("info", "Jira ticket created", "unknown", {
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
async function reserveIncidentMapping(incidentId, tenantId, alertId, jiraResult, correlationId) {
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
  log("info", "Incident reserved in DynamoDB", correlationId, { PK: `TENANT#${tenantId}`, SK: `INCIDENT#${incidentId}` });
  console.log("Incident reserved in DynamoDB:", `TENANT#${tenantId}`, `INCIDENT#${incidentId}`);
  log("info", "Incident reserved in DynamoDB", "unknown", {
    tenant_id: tenantId,
    incident_id: incidentId,
    table_key: `TENANT#${tenantId}#INCIDENT#${incidentId}`,
  });
}

// =============================================================================
// GĐ 1: Cập nhật mapping sau khi Jira ticket tạo thành công
// =============================================================================
async function updateJiraMapping(incidentId, tenantId, jiraResult, correlationId) {
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
  log("info", "Jira mapping updated in DynamoDB", correlationId, { PK: `TENANT#${tenantId}`, SK: `INCIDENT#${incidentId}` });
  console.log("Jira mapping saved to DynamoDB:", `TENANT#${tenantId}`, `INCIDENT#${incidentId}`);
  log("info", "Jira mapping updated in DynamoDB", "unknown", {
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
    log("info", "DLQ record written", "unknown", { incident_id: incidentId, tenant_id: tenantId });
  } catch (dlqErr) {
    log("error", "Failed to write DLQ record", "unknown", { incident_id: incidentId, error: dlqErr.message });
  }
}

// =============================================================================
// GĐ 3: Verify Slack Request Signature
// =============================================================================
function verifySlackSignature(signingSecret, requestBody, timestamp, signature, correlationId) {
  const now = Math.floor(Date.now() / 1000);
  if (Math.abs(now - parseInt(timestamp)) > 300) {
    log("warn", "Slack request timestamp is stale", correlationId, { timestamp, now });
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
async function assignJiraTicket(jiraCreds, issueKey, accountId, correlationId) {
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
    const errorBody = await response.text();
    log("error", "Jira assign error", correlationId, { status: response.status, body: errorBody });
    throw new Error(`Jira assign error: status ${response.status}`);
  }

  log("info", "Jira ticket assigned", correlationId, { issueKey, accountId });
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
// GĐ 3: Gọi Slack response_url để cập nhật message gốc
// =============================================================================
async function updateSlackMessage(responseUrl, updatedBlocks, correlationId) {
  try {
    const controller = new AbortController();
    const timeout = setTimeout(() => controller.abort(), EXTERNAL_API_TIMEOUT_MS);

    let response;
    try {
      response = await fetch(responseUrl, {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          replace_original: true,
          blocks: updatedBlocks,
        }),
        signal: controller.signal,
      });
    } finally {
      clearTimeout(timeout);
    }

    if (!response.ok) {
      log("error", "Slack response_url error", correlationId, { status: response.status });
    } else {
      log("info", "Slack message updated successfully via response_url", correlationId);
    }
  } catch (err) {
    log("error", "Failed to update Slack message (non-fatal)", correlationId, { error: err.message });
  }
}

// =============================================================================
// Handler: GĐ 1 — Tạo Jira Ticket
// =============================================================================
async function handleCreateTicket(event, correlationId) {
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

  try {
    await reserveIncidentMapping(incidentId, tenantId, alertId, correlationId);
  } catch (err) {
    if (err.name === "ConditionalCheckFailedException") {
      log("info", "Incident already exists, returning existing mapping", correlationId, { incidentId });
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

  const jiraCreds = await getJiraSecret();

  let jiraResult;
  try {
    jiraResult = await createJiraTicket(jiraCreds, alertPayload, correlationId);
    await updateJiraMapping(incidentId, tenantId, jiraResult, correlationId);
  } catch (err) {
    log("error", "Jira ticket creation failed, removing PENDING reservation", correlationId, { error: err.message });
    try {
      await dynamoClient.send(new DeleteItemCommand({
        TableName: DYNAMODB_TABLE,
        Key: { PK: { S: `TENANT#${tenantId}` }, SK: { S: `INCIDENT#${incidentId}` } },
      }));
    } catch (deleteErr) {
      log("error", "Failed to clean up PENDING reservation", correlationId, { error: deleteErr.message });
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
// Handler: GĐ 3 — Slack Callback (Confirm & Assign)
// =============================================================================
async function handleSlackCallback(event, correlationId) {
  let rawBody = event.body || "";
  if (event.isBase64Encoded) {
    rawBody = Buffer.from(rawBody, "base64").toString("utf8");
  }
  const headers = event.headers || {};

  // Nếu có cờ isAsyncBackground, tiến hành xử lý ngầm (bỏ qua bước parse rawBody vì payload đã được parse)
  if (event.isAsyncBackground) {
    return await processAsyncSlackCallback(event, correlationId);
  }

  if (!SLACK_SIGNING_SECRET_ARN) {
    log("error", "SLACK_SIGNING_SECRET_ARN is not configured — rejecting request", correlationId);
    return { statusCode: 500, body: "Server misconfiguration" };
  }

  const signingSecret = await getSlackSigningSecret();
  const timestamp = headers["x-slack-request-timestamp"] || headers["X-Slack-Request-Timestamp"];
  const signature = headers["x-slack-signature"] || headers["X-Slack-Signature"];

  if (!timestamp || !signature || !verifySlackSignature(signingSecret, rawBody, timestamp, signature, correlationId)) {
    log("error", "Slack signature verification failed", correlationId);
    return { statusCode: 401, body: "Unauthorized" };
  }

  // 2. Invoke Self Asynchronously
  try {
    const params = new URLSearchParams(rawBody);
    const payloadStr = params.get("payload");
    if (!payloadStr) {
      log("error", "Missing payload field in Slack callback body", correlationId);
      return { statusCode: 400, body: "Bad Request: missing payload" };
    }

    let payloadObj;
    try {
      payloadObj = JSON.parse(payloadStr);
    } catch {
      log("error", "Invalid JSON in Slack callback payload", correlationId);
      return { statusCode: 400, body: "Bad Request: invalid payload" };
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
    
    log("info", "Dispatched to background execution successfully", correlationId);
  } catch (err) {
    log("error", "Failed to dispatch async background process", correlationId, { error: err.message });
    return { statusCode: 500, body: "Internal Server Error" };
  }

  // 3. Lập tức trả về 200 OK cho Slack trong vòng 100ms
  return { statusCode: 200, body: "" };
}

// =============================================================================
// Background Worker (Asynchronous)
// =============================================================================
async function processAsyncSlackCallback(event, correlationId) {
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

  log("info", "Slack action received", correlationId, { action_id: action.action_id, user: slackUserName });

  let actionValue;
  try {
    actionValue = JSON.parse(action.value);
  } catch {
    actionValue = { incident_id: action.value };
  }

  const incidentId = actionValue.incident_id || "unknown";
  const issueKey = actionValue.jira_issue_key;
  const tenantId = actionValue.tenant_id || "unknown";

  if (action.action_id === "assign_incident_action") {
    const assigneeAccountId = actionValue.suggested_assignee_account_id;
    let status = "SUCCESS";
    let jiraCreds;

    if (issueKey && assigneeAccountId) {
      jiraCreds = await jiraCredsPromise;
      
      // Chạy song song Jira API và DynamoDB để tiết kiệm tối đa thời gian (tránh timeout 3s)
      const assignPromise = assignJiraTicket(jiraCreds, issueKey, assigneeAccountId, correlationId).catch(err => {
        log("error", "Assign ticket failed", correlationId, { issue_key: issueKey, error: err.message });
        status = "FAILED_API";
      });
      
      const auditPromise = saveCallbackAudit(incidentId, tenantId, slackUser, "CONFIRM_ASSIGN", issueKey, assigneeAccountId, "SUCCESS").catch(err => {
        log("warn", "Failed to save audit", correlationId, { error: err.message });
      });

      await Promise.all([assignPromise, auditPromise]);
    } else {
      status = "MISSING_INFO";
      await saveCallbackAudit(incidentId, tenantId, slackUser, "CONFIRM_ASSIGN", issueKey, assigneeAccountId, status);
    }

    let assigneeName = assigneeAccountId || "N/A";
    let jiraBaseUrl = jiraCreds?.base_url || "";
    
    if (actionValue.assignee_name) {
      assigneeName = `*${actionValue.assignee_name}*`;
      if (actionValue.assignee_email) assigneeName += ` (${actionValue.assignee_email})`;
    } else {
      if (jiraCreds && assigneeAccountId) {
        try {
          const auth = Buffer.from(`${jiraCreds.email}:${jiraCreds.token}`).toString("base64");

          const controller = new AbortController();
          const timeout = setTimeout(() => controller.abort(), EXTERNAL_API_TIMEOUT_MS);

          const userResp = await fetch(`${jiraCreds.base_url}/rest/api/3/user?accountId=${encodeURIComponent(assigneeAccountId)}`, {
            method: "GET",
            headers: { Authorization: `Basic ${auth}`, Accept: "application/json" },
            signal: controller.signal
          });
          clearTimeout(timeout);

          if (userResp.ok) {
            const userData = await userResp.json();
            const name = userData.displayName || assigneeAccountId;
            const email = userData.emailAddress ? ` (${userData.emailAddress})` : "";
            assigneeName = `${name}${email}`;
          }
        } catch (err) {
          log("warn", "Failed to fetch assignee name", correlationId, { error: err.message });
        }
      }
    }

    const jiraLink = issueKey && jiraBaseUrl
      ? `<${jiraBaseUrl}/browse/${issueKey}|${issueKey}>`
      : (issueKey || "N/A");

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
      await updateSlackMessage(responseUrl, updatedBlocks, correlationId);
    }

    return { statusCode: 200, body: "" };
  }

  if (action.action_id === "self_assign_incident_action") {
    await saveCallbackAudit(incidentId, tenantId, slackUser, "SELF_ASSIGN", issueKey, "pending_lookup", "PENDING");

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
      await updateSlackMessage(responseUrl, updatedBlocks, correlationId);
    }

    return { statusCode: 200, body: "" };
  }

  return { statusCode: 200, body: "OK" };
}

// =============================================================================
// Main Handler
// =============================================================================
exports.handler = async (event) => {
  let correlationId = "unknown";

  if (event.Records && event.Records.length > 0 && event.Records[0].messageAttributes) {
    if (event.Records[0].messageAttributes.CorrelationId) {
      correlationId = event.Records[0].messageAttributes.CorrelationId.stringValue;
    }
  }

  log("info", "Jira Dispatcher Event", correlationId, {
    route: event.headers?.["x-slack-signature"] ? "slack-callback" : "create-ticket"
  });

  try {
    const rawBody = event.body || "";

    if (rawBody.startsWith("payload=") || (event.headers && event.headers["x-slack-signature"])) {
      return await handleSlackCallback(event, correlationId);
    }

    return await handleCreateTicket(event, correlationId);

  } catch (err) {
    log("error", "jira-dispatcher error", correlationId, { error: err.message, stack: err.stack });
    return {
      statusCode: 500,
      body: JSON.stringify({ error: "Internal server error" }),
    };
  }
};
