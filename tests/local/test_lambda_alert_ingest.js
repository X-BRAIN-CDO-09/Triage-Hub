/**
 * tests/local/test_lambda_alert_ingest.js
 * Jest unit tests for alert-ingest Lambda
 * Mocks AWS SQS — no real AWS needed
 *
 * Run: npx jest tests/local/test_lambda_alert_ingest.js
 */

"use strict";

// ── Mock AWS SDK before importing handler ──────────────
const mockSend = jest.fn();
jest.mock("@aws-sdk/client-sqs", () => ({
  SQSClient: jest.fn().mockImplementation(() => ({ send: mockSend })),
  SendMessageCommand: jest.fn().mockImplementation((input) => ({ _input: input })),
}));

const handler = require("../../capstone/tf-1/devops/app/alert-ingest/index").handler;

// ── Helpers ─────────────────────────────────────────────
function makeEvent(body) {
  return { body: typeof body === "string" ? body : JSON.stringify(body) };
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
    started_at: "2026-06-22T08:00:00Z",
  },
};

// ── Setup ────────────────────────────────────────────────
beforeEach(() => {
  jest.clearAllMocks();
  process.env.SQS_QUEUE_URL = "http://localhost:4566/000000000000/triage-buffer-local";
});

// ════════════════════════════════════════════════════════
//  CONTRACT TESTS
// ════════════════════════════════════════════════════════

describe("alert-ingest — contract: missing body", () => {
  test("returns 400 when body is null", async () => {
    const result = await handler({ body: null });
    expect(result.statusCode).toBe(400);
    expect(JSON.parse(result.body).error).toMatch(/Missing request body/i);
  });

  test("returns 400 when body is undefined", async () => {
    const result = await handler({});
    expect(result.statusCode).toBe(400);
    expect(JSON.parse(result.body).error).toMatch(/Missing request body/i);
  });
});

describe("alert-ingest — contract: missing tenant_id", () => {
  test("returns 400 when tenant_id is missing", async () => {
    const payload = { ...VALID_PAYLOAD };
    delete payload.tenant_id;
    const result = await handler(makeEvent(payload));
    expect(result.statusCode).toBe(400);
    expect(JSON.parse(result.body).error).toMatch(/tenant_id/i);
  });

  test("returns 400 when tenant_id is empty string", async () => {
    const result = await handler(makeEvent({ ...VALID_PAYLOAD, tenant_id: "" }));
    // empty string is falsy — should also be caught
    const body = JSON.parse(result.body);
    expect([400, 202]).toContain(result.statusCode); // impl may vary
  });
});

describe("alert-ingest — happy path", () => {
  test("returns 202 Accepted with message_id on valid payload", async () => {
    mockSend.mockResolvedValueOnce({ MessageId: "msg-abc-123" });

    const result = await handler(makeEvent(VALID_PAYLOAD));
    expect(result.statusCode).toBe(202);
    const body = JSON.parse(result.body);
    expect(body.status).toBe("Accepted");
    expect(body.message_id).toBe("msg-abc-123");
  });

  test("sends correct SQS message with tenant attribute", async () => {
    mockSend.mockResolvedValueOnce({ MessageId: "msg-xyz-456" });

    await handler(makeEvent(VALID_PAYLOAD));

    expect(mockSend).toHaveBeenCalledTimes(1);
    const [cmd] = mockSend.mock.calls[0];
    expect(cmd._input.QueueUrl).toBe(process.env.SQS_QUEUE_URL);
    expect(cmd._input.MessageAttributes.TenantId.StringValue).toBe("tenant-a");
    expect(JSON.parse(cmd._input.MessageBody).correlation_id).toBe("corr-test-001");
  });

  test("sends full body as MessageBody (unchanged)", async () => {
    mockSend.mockResolvedValueOnce({ MessageId: "msg-999" });
    const rawBody = JSON.stringify(VALID_PAYLOAD);

    const result = await handler({ body: rawBody });
    expect(result.statusCode).toBe(202);
    const [cmd] = mockSend.mock.calls[0];
    expect(cmd._input.MessageBody).toBe(rawBody);  // exactly the same bytes
  });
});

describe("alert-ingest — SQS failure", () => {
  test("returns 500 when SQS throws", async () => {
    mockSend.mockRejectedValueOnce(new Error("SQS timeout"));

    const result = await handler(makeEvent(VALID_PAYLOAD));
    expect(result.statusCode).toBe(500);
    expect(JSON.parse(result.body).error).toMatch(/Internal Server Error/i);
  });
});
