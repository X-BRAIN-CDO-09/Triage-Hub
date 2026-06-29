const AWSXRay = require('aws-xray-sdk-core');
const { SQSClient, SendMessageCommand } = require("@aws-sdk/client-sqs");

// Wrap the SQS Client with AWS X-Ray to automatically trace SDK calls
const sqsClient = AWSXRay.captureAWSv3Client(new SQSClient({}));
const QUEUE_URL = process.env.SQS_QUEUE_URL;

const SERVICE_NAME = process.env.SERVICE_NAME || "alert-ingest";
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
  let correlationId = "unknown";
  
  // Get the Root Span generated automatically by AWS Lambda
  const segment = AWSXRay.getSegment();
  // Create a Child Span (Subsegment)
  const subsegment = segment ? segment.addNewSubsegment('ProcessAlertRequest') : null;

  try {
    if (event.headers && event.headers['x-correlation-id']) {
      correlationId = event.headers['x-correlation-id'];
    }

    log("info", "Received alert ingestion request", correlationId);

    if (!event.body) {
      log("error", "Missing request body", correlationId);
      if (subsegment) subsegment.close();
      return {
        statusCode: 400,
        body: JSON.stringify({ error: "Missing request body" })
      };
    }

    const payload = JSON.parse(event.body);
    if (payload.correlation_id) {
        correlationId = payload.correlation_id;
    }
    
    if (subsegment) {
      subsegment.addAnnotation('CorrelationId', correlationId);
      subsegment.addMetadata('AlertSummary', {
        tenant_id: payload.tenant_id,
        alert_type: payload.type || payload.alert_type || 'unknown',
        source: payload.source || 'unknown',
        status: payload.status || 'unknown'
      });
    }
    
    // Gửi message vào SQS (trace sẽ tự động truyền X-Amzn-Trace-Id vào metadata của HTTP request tới AWS)

    // Contract (telemetry-contract): tenant_id bắt buộc — reject nếu thiếu,
    // KHÔNG default "unknown" (tránh đẩy incident không có tenant vào pipeline).
    if (!payload.tenant_id) {
      return {
        statusCode: 400,
        body: JSON.stringify({ error: "Missing required field: tenant_id" })
      };
    }

    // Gửi message vào SQS
    const command = new SendMessageCommand({
      QueueUrl: QUEUE_URL,
      MessageBody: event.body,
      MessageAttributes: {
        TenantId: {
          DataType: "String",
          StringValue: payload.tenant_id || "unknown"
        },
        CorrelationId: {
          DataType: "String",
          StringValue: correlationId
        }
      }
    });

    const result = await sqsClient.send(command);
    log("info", "Successfully pushed alert to SQS", correlationId, { MessageId: result.MessageId });

    if (subsegment) subsegment.close();

    return {
      statusCode: 202,
      body: JSON.stringify({
        status: "Accepted",
        message_id: result.MessageId
      })
    };
  } catch (err) {
    log("error", "Error in alert ingest", correlationId, { error: err.message, stack: err.stack });
    
    if (subsegment) {
      // Record Exception Trace in X-Ray
      subsegment.addError(err);
      subsegment.close();
    }
    
    return {
      statusCode: 500,
      body: JSON.stringify({ error: "Internal Server Error" })
    };
  }
};
