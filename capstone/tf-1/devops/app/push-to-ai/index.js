const { SecretsManagerClient, GetSecretValueCommand } = require("@aws-sdk/client-secrets-manager");

const AI_ENGINE_URL = process.env.AI_ENGINE_URL || "http://ai-engine.tf1.internal:8080/v1/triage";
const SERVICE_AUTH_TOKEN_ARN = process.env.SERVICE_AUTH_TOKEN_ARN;
const smClient = new SecretsManagerClient({});

// Cache token ngoài handler (tái dùng giữa các invocation cùng container)
let cachedToken = null;
async function getAuthToken() {
  if (!SERVICE_AUTH_TOKEN_ARN) return null;
  if (cachedToken) return cachedToken;
  const out = await smClient.send(new GetSecretValueCommand({ SecretId: SERVICE_AUTH_TOKEN_ARN }));
  // service_auth_token là secret PLAINTEXT (khớp file teammate), engine cũng đọc cùng secret.
  // Hỗ trợ cả JSON ({SERVICE_AUTH_TOKEN}) lẫn plaintext để an toàn.
  try {
    cachedToken = JSON.parse(out.SecretString).SERVICE_AUTH_TOKEN;
  } catch {
    cachedToken = out.SecretString;
  }
  return cachedToken;
}

const SERVICE_NAME = process.env.SERVICE_NAME || "push-to-ai";
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

exports.handler = async (event) => {
  log("info", "Processing SQS batch", "unknown", { batchSize: event.Records.length });

  // Contract ai-api-contract:64 — Authorization bắt buộc khi gọi /v1/triage
  const authToken = await getAuthToken();

  for (const record of event.Records) {
    let correlationId = "unknown";
    if (record.messageAttributes && record.messageAttributes.CorrelationId) {
      correlationId = record.messageAttributes.CorrelationId.stringValue;
    }

    try {
      log("info", "Forwarding message to EKS", correlationId, { messageId: record.messageId });
      
      console.log("Forwarding message to EKS:", record.messageId);

      const payload = JSON.parse(record.body);

      const requestHeaders = {
        "Content-Type": "application/json",
        "X-Correlation-Id": correlationId !== "unknown" ? correlationId : (payload.correlation_id || "unknown"),
        "X-Tenant-Id": payload.tenant_id || "unknown"
      };
      if (authToken) {
        requestHeaders["Authorization"] = `Bearer ${authToken}`;
      }

      const response = await fetch(AI_ENGINE_URL, {
        method: "POST",
        headers: requestHeaders,
        body: record.body
      });

      if (!response.ok) {
        throw new Error(`EKS Triage Engine returned status: ${response.status}`);
      }

      const result = await response.json();
      log("info", "Successfully triaged incident", correlationId, { EKSResult: result });
      
    } catch (err) {
      log("error", "Failed to forward record to EKS", correlationId, { error: err.message, stack: err.stack });
      // Ném lỗi để SQS đưa vào DLQ hoặc retry
      throw err;
    }
  }

  return { status: "processed" };
};
