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

exports.handler = async (event) => {
  console.log("Processing SQS batch of size:", event.Records.length);

  // Contract ai-api-contract:64 — Authorization bắt buộc khi gọi /v1/triage
  const authToken = await getAuthToken();

  for (const record of event.Records) {
    try {
      console.log("Forwarding message to EKS:", record.messageId);

      const payload = JSON.parse(record.body);

      const headers = {
        "Content-Type": "application/json",
        "X-Correlation-Id": payload.correlation_id || "unknown",
        "X-Tenant-Id": payload.tenant_id || "unknown"
      };
      if (authToken) headers["Authorization"] = `Bearer ${authToken}`;

      const response = await fetch(AI_ENGINE_URL, {
        method: "POST",
        headers,
        body: record.body
      });

      if (!response.ok) {
        throw new Error(`EKS Triage Engine returned status: ${response.status}`);
      }

      const result = await response.json();
      console.log("Successfully triaged incident. EKS Result:", JSON.stringify(result));
      
    } catch (err) {
      console.error("Failed to forward record to EKS:", err);
      // Ném lỗi để SQS đưa vào DLQ hoặc retry
      throw err;
    }
  }

  return { status: "processed" };
};
