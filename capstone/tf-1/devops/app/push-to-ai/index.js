const AI_ENGINE_URL = process.env.AI_ENGINE_URL || "http://ai-engine.tf1.internal:8080/v1/triage";

exports.handler = async (event) => {
  console.log("Processing SQS batch of size:", event.Records.length);

  for (const record of event.Records) {
    try {
      console.log("Forwarding message to EKS:", record.messageId);
      
      const payload = JSON.parse(record.body);
      
      const response = await fetch(AI_ENGINE_URL, {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "X-Correlation-Id": payload.correlation_id || "unknown",
          "X-Tenant-Id": payload.tenant_id || "unknown"
        },
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
