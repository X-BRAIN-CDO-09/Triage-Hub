const { SQSClient, SendMessageCommand } = require("@aws-sdk/client-sqs");
const sqsClient = new SQSClient({});
const QUEUE_URL = process.env.SQS_QUEUE_URL;

exports.handler = async (event) => {
  console.log("Received alert ingestion request:", JSON.stringify(event));

  try {
    if (!event.body) {
      return {
        statusCode: 400,
        body: JSON.stringify({ error: "Missing request body" })
      };
    }

    const payload = JSON.parse(event.body);
    
    // Gửi message vào SQS
    const command = new SendMessageCommand({
      QueueUrl: QUEUE_URL,
      MessageBody: event.body,
      MessageAttributes: {
        TenantId: {
          DataType: "String",
          StringValue: payload.tenant_id || "unknown"
        }
      }
    });

    const result = await sqsClient.send(command);
    console.log("Successfully pushed alert to SQS. Message ID:", result.MessageId);

    return {
      statusCode: 202,
      body: JSON.stringify({
        status: "Accepted",
        message_id: result.MessageId
      })
    };
  } catch (err) {
    console.error("Error in alert ingest:", err);
    return {
      statusCode: 500,
      body: JSON.stringify({ error: "Internal Server Error" })
    };
  }
};
