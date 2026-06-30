/**
 * tests/local/test_lambda_alert_ingest.js
 * Jest unit tests for the alert-ingest Lambda.
 *
 * Khớp với contract HIỆN TẠI của handler:
 *   - Validate tenant qua DynamoDB (GetItemCommand) trước khi đẩy SQS.
 *   - Trả 500 nếu thiếu env config (QUEUE_URL / DYNAMODB_TABLE).
 *   - Trả 202 { status: "Processed", accepted, dropped, ... } cho luồng xử lý.
 * Mock cả @aws-sdk/client-dynamodb và @aws-sdk/client-sqs — không cần AWS thật.
 *
 * Run: npx jest test_lambda_alert_ingest.js
 */

"use strict";

// ── Mock AWS SDK trước khi import handler ──────────────────
const mockSqsSend = jest.fn();
jest.mock("@aws-sdk/client-sqs", () => ({
  SQSClient: jest.fn().mockImplementation(() => ({ send: mockSqsSend })),
  SendMessageCommand: jest.fn().mockImplementation((input) => ({ _input: input })),
}));

const mockDynamoSend = jest.fn();
jest.mock("@aws-sdk/client-dynamodb", () => ({
  DynamoDBClient: jest.fn().mockImplementation(() => ({ send: mockDynamoSend })),
  GetItemCommand: jest.fn().mockImplementation((input) => ({ _input: input })),
}));

const HANDLER_PATH = "../../capstone/tf-1/devops/app/alert-ingest/index";

// Handler đọc QUEUE_URL/DYNAMODB_TABLE ở MODULE LOAD time, nên phải require lại
// sau khi set process.env trong từng test (không require 1 lần ở top-level).
function loadHandler() {
  let handler;
  jest.isolateModules(() => {
    handler = require(HANDLER_PATH).handler;
  });
  return handler;
}

// ── Helpers ─────────────────────────────────────────────
function makeEvent(body) {
  return { body: typeof body === "string" ? body : JSON.stringify(body) };
}

// Tenant active trong DynamoDB
function activeTenant() {
  return { Item: { PK: { S: "TENANT#tenant-a" }, SK: { S: "CONFIG" }, status: { S: "active" } } };
}

const VALID_PAYLOAD = {
  correlation_id: "corr-test-001",
  tenant_id: "tenant-a",
  incident_id: "inc-test-001",
  environment: "sandbox",
  received_at: "2026-06-22T08:05:00Z",
  alert: {
    alert_id: "alert-001",
    source: "synthetic",
    service: "checkout-api",
    severity: "critical",
    title: "checkout-api is down",
    tenant_id: "tenant-a",
    labels: { service: "checkout-api", severity: "critical", tenant_id: "tenant-a" },
    started_at: "2026-06-22T08:00:00Z",
  },
};

// ── Setup ────────────────────────────────────────────────
beforeEach(() => {
  jest.clearAllMocks();
  process.env.SQS_QUEUE_URL = "http://localhost:4566/000000000000/triage-buffer-local.fifo";
  process.env.DYNAMODB_TABLE = "triage-hub-state-sandbox";
});

// ════════════════════════════════════════════════════════
//  CONFIG GUARDS
// ════════════════════════════════════════════════════════
describe("alert-ingest — config guards", () => {
  test("returns 500 when DYNAMODB_TABLE is missing", async () => {
    delete process.env.DYNAMODB_TABLE;
    const result = await loadHandler()(makeEvent(VALID_PAYLOAD));
    expect(result.statusCode).toBe(500);
    expect(JSON.parse(result.body).error).toMatch(/configuration error/i);
  });

  test("returns 500 when SQS_QUEUE_URL is missing", async () => {
    delete process.env.SQS_QUEUE_URL;
    const result = await loadHandler()(makeEvent(VALID_PAYLOAD));
    expect(result.statusCode).toBe(500);
  });
});

// ════════════════════════════════════════════════════════
//  CONTRACT: body parsing
// ════════════════════════════════════════════════════════
describe("alert-ingest — contract: body", () => {
  test("returns 400 when body is null", async () => {
    const result = await loadHandler()({ body: null });
    expect(result.statusCode).toBe(400);
    expect(JSON.parse(result.body).error).toMatch(/Missing request body/i);
  });

  test("returns 400 on invalid JSON body", async () => {
    const result = await loadHandler()({ body: "{not-json" });
    expect(result.statusCode).toBe(400);
    expect(JSON.parse(result.body).error).toMatch(/Invalid JSON body/i);
  });

  test("returns 202 with reason no_alerts when payload has no alert", async () => {
    const result = await loadHandler()(makeEvent({ correlation_id: "c1", foo: "bar" }));
    expect(result.statusCode).toBe(202);
    const body = JSON.parse(result.body);
    expect(body.status).toBe("Processed");
    expect(body.reason).toBe("no_alerts");
  });
});

// ════════════════════════════════════════════════════════
//  TENANT GATING (DynamoDB)
// ════════════════════════════════════════════════════════
describe("alert-ingest — tenant gating", () => {
  test("drops alert when tenant_id is missing", async () => {
    const payload = JSON.parse(JSON.stringify(VALID_PAYLOAD));
    delete payload.tenant_id;
    delete payload.alert.tenant_id;
    delete payload.alert.labels.tenant_id;

    const result = await loadHandler()(makeEvent(payload));
    expect(result.statusCode).toBe(202);
    const body = JSON.parse(result.body);
    expect(body.accepted).toBe(0);
    expect(body.dropped).toBe(1);
    expect(body.dropped_alerts[0].reason).toBe("missing_tenant_id");
    expect(mockSqsSend).not.toHaveBeenCalled();
  });

  test("drops alert when tenant does not exist in DynamoDB", async () => {
    mockDynamoSend.mockResolvedValueOnce({}); // no Item
    const result = await loadHandler()(makeEvent(VALID_PAYLOAD));
    const body = JSON.parse(result.body);
    expect(body.accepted).toBe(0);
    expect(body.dropped_alerts[0].reason).toBe("invalid_tenant");
    expect(mockSqsSend).not.toHaveBeenCalled();
  });

  test("drops alert when tenant is inactive", async () => {
    mockDynamoSend.mockResolvedValueOnce({
      Item: { PK: { S: "TENANT#tenant-a" }, SK: { S: "CONFIG" }, status: { S: "suspended" } },
    });
    const result = await loadHandler()(makeEvent(VALID_PAYLOAD));
    const body = JSON.parse(result.body);
    expect(body.accepted).toBe(0);
    expect(body.dropped_alerts[0].reason).toBe("inactive_tenant");
    expect(mockSqsSend).not.toHaveBeenCalled();
  });
});

// ════════════════════════════════════════════════════════
//  HAPPY PATH
// ════════════════════════════════════════════════════════
describe("alert-ingest — happy path", () => {
  test("accepts valid alert for active tenant and pushes to SQS", async () => {
    mockDynamoSend.mockResolvedValueOnce(activeTenant());
    mockSqsSend.mockResolvedValueOnce({ MessageId: "msg-abc-123" });

    const result = await loadHandler()(makeEvent(VALID_PAYLOAD));
    expect(result.statusCode).toBe(202);
    const body = JSON.parse(result.body);
    expect(body.status).toBe("Processed");
    expect(body.accepted).toBe(1);
    expect(body.dropped).toBe(0);
    expect(body.accepted_alerts[0].tenant_id).toBe("tenant-a");
    expect(body.accepted_alerts[0].service).toBe("checkout-api");
  });

  test("sends FIFO SQS message with tenant attributes + MessageGroupId", async () => {
    mockDynamoSend.mockResolvedValueOnce(activeTenant());
    mockSqsSend.mockResolvedValueOnce({ MessageId: "msg-xyz-456" });

    await loadHandler()(makeEvent(VALID_PAYLOAD));

    expect(mockSqsSend).toHaveBeenCalledTimes(1);
    const [cmd] = mockSqsSend.mock.calls[0];
    expect(cmd._input.QueueUrl).toBe(process.env.SQS_QUEUE_URL);
    expect(cmd._input.MessageGroupId).toBe("tenant-a"); // FIFO yêu cầu group id
    expect(cmd._input.MessageAttributes.TenantId.StringValue).toBe("tenant-a");
    expect(cmd._input.MessageAttributes.Severity.StringValue).toBe("critical");
    const seed = JSON.parse(cmd._input.MessageBody);
    expect(seed.tenant_id).toBe("tenant-a");
    expect(seed.service).toBe("checkout-api");
    expect(seed.schema_version).toBe("tf1.incident_seed.v1");
  });
});
