// =============================================================================
// notify-dispatcher Lambda
// Giai đoạn 2: Bắn thông báo lên Slack sau khi AI triage xong
//
// Trigger: Invoked bởi EKS tf1-worker (lambda:InvokeFunction)
// Flow:
//   1. Nhận payload triage result từ EKS
//   2. Query DynamoDB lấy jira_issue_key đã mapping
//   3. Lấy Slack Bot Token từ Secrets Manager
//   4. Build Slack Block Kit message
//   5. Gọi Slack chat.postMessage API
// =============================================================================

const { DynamoDBClient, GetItemCommand, PutItemCommand } = require("@aws-sdk/client-dynamodb");
const { SecretsManagerClient, GetSecretValueCommand } = require("@aws-sdk/client-secrets-manager");
const { LambdaClient, InvokeCommand } = require("@aws-sdk/client-lambda");

// Timeout mặc định cho các request HTTP bên ngoài (ms)
const EXTERNAL_API_TIMEOUT_MS = 10000;

const dynamoClient = new DynamoDBClient({});
const secretsClient = new SecretsManagerClient({});

// Environment variables (set by Terraform)
const DYNAMODB_TABLE = process.env.DYNAMODB_TABLE;
const SLACK_BOT_TOKEN_ARN = process.env.SLACK_BOT_TOKEN_ARN;
const JIRA_SECRET_ARN = process.env.JIRA_SECRET_ARN;

// Cache secrets trong warm Lambda container
let cachedSlackSecret = null;
let cachedJiraSecret = null;

// =============================================================================
// Structured Logging Helper
// =============================================================================
const SERVICE_NAME = process.env.SERVICE_NAME || "notify-dispatcher";
const ENVIRONMENT = process.env.ENVIRONMENT || "unknown";

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

async function getSlackSecret() {
  if (cachedSlackSecret) return cachedSlackSecret;
  const raw = await getSecret(SLACK_BOT_TOKEN_ARN);
  cachedSlackSecret = JSON.parse(raw); // { token: "xoxb-...", default_channel: "#oncall-alerts" }
  return cachedSlackSecret;
}

async function getJiraSecret() {
  if (cachedJiraSecret) return cachedJiraSecret;
  const raw = await getSecret(JIRA_SECRET_ARN);
  cachedJiraSecret = JSON.parse(raw); // { email, token, base_url }
  return cachedJiraSecret;
}

// =============================================================================
// Helper: Lấy thông tin Jira user
// =============================================================================
async function getJiraUserDetails(jiraCreds, accountId, correlationId) {
  const { email, token, base_url } = jiraCreds;
  const auth = Buffer.from(`${email}:${token}`).toString("base64");
  
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), EXTERNAL_API_TIMEOUT_MS);

  let response;
  try {
    response = await fetch(`${base_url}/rest/api/3/user?accountId=${encodeURIComponent(accountId)}`, {
      method: "GET",
      headers: {
        Authorization: `Basic ${auth}`,
        Accept: "application/json",
      },
      signal: controller.signal,
    });
  } catch (e) {
    log("warn", "Jira user API fetch failed", correlationId, { error: e.message });
    return null;
  } finally {
    clearTimeout(timeout);
  }

  if (!response.ok) {
    log("warn", `Jira user API error: status ${response.status}`, correlationId);
    return null;
  }
  return await response.json();
}

// =============================================================================
// Helper: Query DynamoDB lấy Jira issue key theo incident_id
// =============================================================================
async function getJiraMapping(incidentId, tenantId, correlationId) {
  const command = new GetItemCommand({
    TableName: DYNAMODB_TABLE,
    Key: {
      PK: { S: `TENANT#${tenantId}` },
      SK: { S: `INCIDENT#${incidentId}` },
    },
  });

  const response = await dynamoClient.send(command);
  if (!response.Item) {
    log("warn", `No Jira mapping found for incident ${incidentId}`, correlationId);
    return null;
  }

  return {
    issueKey: response.Item.jira_issue_key?.S || null,
    alertId: response.Item.alert_id?.S || null,
    createdAt: response.Item.created_at?.S || null,
  };
}

// =============================================================================
// Helper: Get Jira User details by accountId
// =============================================================================
async function getJiraUser(jiraCreds, accountId) {
  const { email, token, base_url } = jiraCreds;
  const auth = Buffer.from(`${email}:${token}`).toString("base64");

  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), EXTERNAL_API_TIMEOUT_MS);

  let response;
  try {
    response = await fetch(`${base_url}/rest/api/3/user?accountId=${encodeURIComponent(accountId)}`, {
      method: "GET",
      headers: {
        Authorization: `Basic ${auth}`,
        Accept: "application/json",
      },
      signal: controller.signal,
    });
  } finally {
    clearTimeout(timeout);
  }

  if (!response.ok) {
    throw new Error(`Jira user API error: status ${response.status}`);
  }

  const data = await response.json();
  // Xử lý trường hợp Jira trả về array hoặc object
  if (Array.isArray(data) && data.length > 0) return data[0];
  return data;
}

// =============================================================================
// Helper: Lưu notification audit trail vào DynamoDB
// =============================================================================
async function saveNotificationAudit(incidentId, tenantId, slackResponse, correlationId) {
  const command = new PutItemCommand({
    TableName: DYNAMODB_TABLE,
    Item: {
      PK: { S: `TENANT#${tenantId}` },
      SK: { S: `NOTIFICATION#${incidentId}#${Date.now()}` },
      incident_id: { S: incidentId },
      tenant_id: { S: tenantId },
      slack_channel: { S: slackResponse.channel || "unknown" },
      slack_ts: { S: slackResponse.ts || "unknown" },
      notified_at: { S: new Date().toISOString() },
      status: { S: "SENT" },
    },
  });

  await dynamoClient.send(command);
  log("info", "Notification audit saved", correlationId, { incidentId, channel: slackResponse.channel });
}

// =============================================================================
// Helper: Map severity thành emoji + label
// =============================================================================
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

// =============================================================================
// Helper: Map AI status thành hiển thị
// =============================================================================
function getStatusDisplay(status) {
  const map = {
    DIAGNOSED: "✅ Diagnosed",
    INVESTIGATE: "🔍 Needs Investigation",
    INSUFFICIENT_CONTEXT: "⚠️ Insufficient Context",
    UNSAFE_SUGGESTION_BLOCKED: "🛑 Unsafe Suggestion Blocked",
  };
  return map[status] || `ℹ️ ${status}`;
}

// =============================================================================
// Helper: Escape Slack mrkdwn special characters
// =============================================================================
function escapeSlackMrkdwn(text) {
  if (!text) return "";
  return String(text).replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
}

// =============================================================================
// Core: Build Slack Block Kit message từ AI triage result
// =============================================================================
function buildSlackBlocks(triageResult, jiraMapping, jiraBaseUrl, assigneeDetails) {
  const severity = getSeverityDisplay(triageResult.severity);
  const service = triageResult.ticket_payload?.fields?.owner_team || triageResult.alert?.service || "unknown-service";
  const incidentId = triageResult.incident_id;
  const classification = triageResult.classification || "unknown";
  const confidence = triageResult.confidence != null ? `🎯 ${Math.round(triageResult.confidence * 100)}%` : "N/A";
  const status = getStatusDisplay(triageResult.status);
  const jiraIssueKey = jiraMapping?.issueKey || "Pending...";
  const jiraUrl = jiraMapping?.issueKey ? `${jiraBaseUrl}/browse/${jiraMapping.issueKey}` : null;

  const blocks = [
    {
      type: "header",
      text: {
        type: "plain_text",
        text: `🚨 New Incident Alert: Triage Hub`,
        emoji: true,
      },
    },

    // Overview fields
    {
      type: "section",
      fields: [
        {
          type: "mrkdwn",
          text: `*Service:*\n\`${service}\``,
        },
        {
          type: "mrkdwn",
          text: `*Severity:*\n${severity.emoji} ${severity.label}`,
        },
        {
          type: "mrkdwn",
          text: `*AI Confidence Score:*\n${confidence}`,
        },
        {
          type: "mrkdwn",
          text: `*Incident ID:*\n\`${incidentId}\``,
        },
      ],
    },

    // Status + Classification
    {
      type: "section",
      fields: [
        {
          type: "mrkdwn",
          text: `*AI Status:*\n${status}`,
        },
        {
          type: "mrkdwn",
          text: `*Classification:*\n\`${classification}\``,
        },
      ],
    },

    { type: "divider" },
  ];

  // Root Cause section
  if (triageResult.suspected_root_cause) {
    const rootCause = triageResult.suspected_root_cause;
    blocks.push({
      type: "section",
      text: {
        type: "mrkdwn",
        text: `*🔍 Root Cause Diagnosis:*\n${rootCause.summary}`,
      },
    });

    // Evidence items
    if (rootCause.evidence && rootCause.evidence.length > 0) {
      const evidenceText = rootCause.evidence
        .map((e, i) => `${i + 1}. ${e}`)
        .join("\n");
      blocks.push({
        type: "section",
        text: {
          type: "mrkdwn",
          text: `*📋 Evidence:*\n${evidenceText}`,
        },
      });
    }
  }

  // Recommended actions
  if (triageResult.recommended_actions && triageResult.recommended_actions.length > 0) {
    const actionsText = triageResult.recommended_actions
      .map((a, i) => `${i + 1}. *[${a.type}]* ${a.summary}`)
      .join("\n");
    blocks.push({
      type: "section",
      text: {
        type: "mrkdwn",
        text: `*🛠️ Recommended Actions:*\n${actionsText}`,
      },
    });
  }

  blocks.push({ type: "divider" });

  if (triageResult.suggested_assignee_account_id) {
    let assigneeText = `\`${escapeSlackMrkdwn(triageResult.suggested_assignee_account_id)}\``;
    if (assigneeDetails && assigneeDetails.displayName) {
      assigneeText = `*${escapeSlackMrkdwn(assigneeDetails.displayName)}* (${escapeSlackMrkdwn(assigneeDetails.emailAddress || "No email")})`;
    }

    const suggestionReason = escapeSlackMrkdwn(triageResult.suggestion_reason || "AI recommends assigning this incident.");

    blocks.push({
      type: "section",
      text: {
        type: "mrkdwn",
        text: `*🤖 AI Assignment Suggestion:*\n${suggestionReason}\n\n*Suggested Assignee:* ${assigneeText}`,
      },
    });

    blocks.push({ type: "divider" });

    // Interactive buttons: Confirm & Assign + View Jira (chỉ render khi có Jira mapping)
    if (jiraMapping?.issueKey) {
      const actionElements = [
        {
          type: "button",
          text: {
            type: "plain_text",
            text: "👤 Confirm & Assign",
            emoji: true,
          },
          style: "primary",
          action_id: "assign_incident_action",
          value: JSON.stringify({
            incident_id: incidentId,
            tenant_id: triageResult.tenant_id || "unknown",
            jira_issue_key: jiraMapping.issueKey,
            suggested_assignee_account_id: triageResult.suggested_assignee_account_id,
            audit_id: triageResult.audit_id || null,
          }),
        },
      ];

      if (jiraUrl) {
        actionElements.push({
          type: "button",
          text: {
            type: "plain_text",
            text: "🎫 View Jira Ticket",
            emoji: true,
          },
          url: jiraUrl,
          action_id: "open_jira_ticket_action",
        });
      }

      blocks.push({
        type: "actions",
        elements: actionElements,
      });
    } else {
      blocks.push({
        type: "context",
        elements: [{
          type: "mrkdwn",
          text: `⚠️ Jira ticket not yet created. Assignment will be available once ticket is ready.`,
        }],
      });
    }
  } else {
    // Không có AI suggestion -> hiển thị nút "Assign Me"
    blocks.push({
      type: "section",
      text: {
        type: "mrkdwn",
        text: `*🤖 AI Assignment Suggestion:*\nNo specific assignee suggested. An on-call engineer can self-assign below.`,
      },
    });

    blocks.push({ type: "divider" });

    if (jiraMapping?.issueKey) {
      const actionElements = [
        {
          type: "button",
          text: {
            type: "plain_text",
            text: "🙋 Assign Me",
            emoji: true,
          },
          style: "primary",
          action_id: "self_assign_incident_action",
          value: JSON.stringify({
            incident_id: incidentId,
            tenant_id: triageResult.tenant_id || "unknown",
            jira_issue_key: jiraMapping.issueKey,
            audit_id: triageResult.audit_id || null,
          }),
        },
      ];

      if (jiraUrl) {
        actionElements.push({
          type: "button",
          text: {
            type: "plain_text",
            text: "🎫 View Jira Ticket",
            emoji: true,
          },
          url: jiraUrl,
          action_id: "open_jira_ticket_action",
        });
      }

      blocks.push({
        type: "actions",
        elements: actionElements,
      });
    } else {
      blocks.push({
        type: "context",
        elements: [{
          type: "mrkdwn",
          text: `⚠️ Jira ticket not yet created. Self-assignment will be available once ticket is ready.`,
        }],
      });
    }
  }

  // Footer / Context
  blocks.push({
    type: "context",
    elements: [
      {
        type: "mrkdwn",
        text: `⏱️ Alert generated at: ${new Date().toISOString()} | Jira: ${jiraIssueKey} | Triage Hub System`,
      },
    ],
  });

  return blocks;
}

// =============================================================================
// Helper: Gọi Slack API chat.postMessage
// =============================================================================
async function postToSlack(token, channel, blocks, fallbackText) {
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), EXTERNAL_API_TIMEOUT_MS);

  let response;
  try {
    response = await fetch("https://slack.com/api/chat.postMessage", {
      method: "POST",
      headers: {
        "Content-Type": "application/json; charset=utf-8",
        Authorization: `Bearer ${token}`,
      },
      body: JSON.stringify({
        channel: channel,
        text: fallbackText,
        blocks: blocks,
      }),
      signal: controller.signal,
    });
  } finally {
    clearTimeout(timeout);
  }

  const result = await response.json();

  if (!result.ok) {
    console.error("Slack API error:", result.error, result.response_metadata);
    throw new Error(`Slack API error: ${result.error}`);
  }

  console.log("Slack message posted successfully. ts:", result.ts, "channel:", result.channel);
  return result;
}

// =============================================================================
// Main Handler
// =============================================================================
exports.handler = async (event) => {
  console.log("notify-dispatcher invoked. Event:", JSON.stringify(event));

  try {
    let triageResult;

    if (event.Records && event.Records.length > 0) {
      triageResult = JSON.parse(event.Records[0].body);
    } else if (event.body) {
      triageResult = typeof event.body === "string" ? JSON.parse(event.body) : event.body;
    } else {
      triageResult = event;
    }

    console.log("Triage result parsed:", JSON.stringify(triageResult));

    if (!triageResult.incident_id) {
      console.error("Missing incident_id in triage result");
      return {
        statusCode: 400,
        body: JSON.stringify({ error: "Missing incident_id in triage result" }),
      };
    }

    const incidentId = triageResult.incident_id;
    const tenantId = triageResult.tenant_id || "unknown";

    // 1. Invoke jira-dispatcher to create the Jira issue synchronously
    let jiraMapping = null;
    const JIRA_DISPATCHER_ARN = process.env.JIRA_DISPATCHER_ARN;
    if (JIRA_DISPATCHER_ARN) {
      try {
        const lambdaClient = new LambdaClient({});
        const invokeCommand = new InvokeCommand({
          FunctionName: JIRA_DISPATCHER_ARN,
          InvocationType: "RequestResponse",
          Payload: Buffer.from(JSON.stringify(triageResult)),
        });
        const response = await lambdaClient.send(invokeCommand);
        const payloadString = Buffer.from(response.Payload).toString();
        const payloadObj = JSON.parse(payloadString);
        
        if (payloadObj.statusCode === 201 || payloadObj.statusCode === 200) {
          const bodyObj = typeof payloadObj.body === "string" ? JSON.parse(payloadObj.body) : payloadObj.body;
          jiraMapping = { issueKey: bodyObj.jira_issue_key };
          console.log("Jira ticket created/found:", jiraMapping.issueKey);
        } else {
          console.warn("Jira dispatcher returned non-success:", payloadString);
          jiraMapping = await getJiraMapping(incidentId, tenantId);
        }
      } catch (err) {
        console.error("Failed to invoke jira-dispatcher:", err.message);
        jiraMapping = await getJiraMapping(incidentId, tenantId);
      }
    } else {
      try {
        jiraMapping = await getJiraMapping(incidentId, tenantId);
        console.log("Jira mapping found:", jiraMapping?.issueKey || "none");
      } catch (err) {
        console.warn("Failed to fetch Jira mapping, continuing without it:", err.message);
      }
    }

    // 2. Lấy Secrets từ Secrets Manager
    const slackSecret = await getSlackSecret();
    const jiraSecret = await getJiraSecret();

    // 3. Fetch Jira user details if we have an assignee suggestion
    let assigneeDetails = null;
    if (triageResult.suggested_assignee_account_id) {
      try {
        assigneeDetails = await getJiraUser(jiraSecret, triageResult.suggested_assignee_account_id);
        console.log("Fetched Jira user details successfully");
      } catch (err) {
        console.warn("Failed to fetch Jira user details:", err.message);
      }
    }

    // 4. Build Slack Block Kit message
    const blocks = buildSlackBlocks(triageResult, jiraMapping, jiraSecret.base_url, assigneeDetails);

    const fallbackText = `🚨 [${(triageResult.severity || "unknown").toUpperCase()}] Incident ${incidentId}: ${triageResult.suspected_root_cause?.summary || triageResult.classification || "New incident detected"}`;

    let targetChannel = slackSecret.default_channel || "#oncall-alerts";
    const requestedChannel = triageResult.ownership?.slack_channel;
    if (requestedChannel && /^(#[a-zA-Z0-9_-]+|[CG][A-Z0-9]+)$/.test(requestedChannel)) {
      targetChannel = requestedChannel;
    } else if (requestedChannel) {
      console.warn("Invalid slack_channel in payload, using default:", requestedChannel);
    }

    // 5. Post to Slack
    const slackResponse = await postToSlack(slackSecret.token, targetChannel, blocks, fallbackText);

    // 6. Lưu notification audit trail
    try {
      await saveNotificationAudit(incidentId, tenantId, slackResponse);
      console.log("Notification audit saved to DynamoDB");
    } catch (err) {
      console.error("Failed to save notification audit (non-fatal):", err.message);
    }

    return {
      statusCode: 200,
      body: JSON.stringify({
        status: "notified",
        incident_id: incidentId,
        slack_channel: targetChannel,
        slack_ts: slackResponse.ts,
        jira_issue_key: jiraMapping?.issueKey || null,
      }),
    };
  } catch (err) {
    console.error("notify-dispatcher error:", err.message);
    return {
      statusCode: 500,
      body: JSON.stringify({
        error: "Failed to dispatch notification",
        message: err.message,
      }),
    };
  }
};

// =============================================================================
// Core processing logic (shared by SQS batch & direct invoke)
// =============================================================================
async function processTriageResult(triageResult) {
  console.log("Processing triage result for incident:", triageResult.incident_id);

  // Validate required fields theo AI API contract
  if (!triageResult.incident_id) {
    throw new Error("Missing incident_id in triage result");
  }

  const incidentId = triageResult.incident_id;
  const tenantId = triageResult.tenant_id || "unknown";

  // 1. Query DynamoDB lấy Jira issue mapping
  let jiraMapping = null;
  try {
    jiraMapping = await getJiraMapping(incidentId, tenantId);
    console.log("Jira mapping found:", jiraMapping?.issueKey || "none");
  } catch (err) {
    console.warn("Failed to fetch Jira mapping, continuing without it:", err.message);
  }

  // 2. Lấy Secrets từ Secrets Manager
  const slackSecret = await getSlackSecret();
  const jiraSecret = await getJiraSecret();

  // 3. Fetch Jira user details if we have an assignee suggestion
  let assigneeDetails = null;
  if (triageResult.suggested_assignee_account_id) {
    try {
      assigneeDetails = await getJiraUser(jiraSecret, triageResult.suggested_assignee_account_id);
      console.log("Fetched Jira user details successfully");
    } catch (err) {
      console.warn("Failed to fetch Jira user details:", err.message);
    }
  }

  // 4. Build Slack Block Kit message
  const blocks = buildSlackBlocks(triageResult, jiraMapping, jiraSecret.base_url, assigneeDetails);

  // Fallback text cho notification / email
  const fallbackText = `🚨 [${(triageResult.severity || "unknown").toUpperCase()}] Incident ${incidentId}: ${triageResult.suspected_root_cause?.summary || triageResult.classification || "New incident detected"}`;

  // Determine target channel: payload ownership > secret default
  // Validate: chỉ cho phép channel bắt đầu bằng # hoặc là Slack channel ID (C/G prefix)
  let targetChannel = slackSecret.default_channel || "#oncall-alerts";
  const requestedChannel = triageResult.ownership?.slack_channel;
  if (requestedChannel && /^(#[a-zA-Z0-9_-]+|[CG][A-Z0-9]+)$/.test(requestedChannel)) {
    targetChannel = requestedChannel;
  } else if (requestedChannel) {
    console.warn("Invalid slack_channel in payload, using default:", requestedChannel);
  }

  // 5. Post to Slack
  const slackResponse = await postToSlack(slackSecret.token, targetChannel, blocks, fallbackText);

  // 6. Lưu notification audit trail
  try {
    await saveNotificationAudit(incidentId, tenantId, slackResponse);
    console.log("Notification audit saved to DynamoDB");
  } catch (err) {
    // Không fail cả Lambda nếu chỉ lỗi audit
    console.error("Failed to save notification audit (non-fatal):", err.message);
  }

  return {
    status: "notified",
    incident_id: incidentId,
    slack_channel: targetChannel,
    slack_ts: slackResponse.ts,
    jira_issue_key: jiraMapping?.issueKey || null,
  };
}
