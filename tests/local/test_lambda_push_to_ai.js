/**
 * tests/local/test_lambda_push_to_ai.js
 * Jest unit tests for push-to-ai Lambda
 * Mocks: Secrets Manager, global fetch — no real AWS or EKS needed
 *
 * Run: npx jest tests/local/test_lambda_push_to_ai.js
 */

"use strict";

// ── Mock AWS Secrets Manager ────────────────────────────
const mockSmSend = jest.fn();
jest.mock("@aws-sdk/client-secrets-manager", () => ({
  SecretsManagerClient: jest.fn().mockImplementation(() => ({ send: mockSmSend })),
  GetSecretValueCommand: jest.fn().mockImplementation((input) => ({ _input: input })),
}));

// ── Mock global fetch ───────────────────────────────────
const mockFetch = jest.fn();
global.fetch = mockFetch;

// Reset module cache between tests (cachedToken is module-level)
let handler;
function loadHandler() {
  jest.resetModules();
  // Re-apply mocks after reset
  jest.doMock("@aws-sdk/client-secrets-manager", () => ({
    SecretsManagerClient: jest.fn().mockImplementation(() => ({ send: mockSmSend })),
    GetSecretValueCommand: jest.fn().mockImplementation((input) => ({ _input: input })),
  }));
  global.fetch = mockFetch;
  handler = require("../../capstone/tf-1/devops/app/push-to-ai/index").handler;
}

// ── Helpers ─────────────────────────────────────────────
function makeRecord(body, messageId = "msg-001") {
  return {
    Records: [{
      messageId,
      body: typeof body === "string" ? body : JSON.stringify(body),
    }],
  };
}

function makeResponse(status, json) {
  return {
    ok: status >= 200 && status < 300,
    status,
    json: jest.fn().mockResolvedValue(json),
  };
}

const VALID_PAYLOAD = {
  correlation_id: "corr-push-001",
  tenant_id: "tenant-a",
  incident_id: "inc-push-001",
  environment: "sandbox",
  received_at: "2026-06-22T08:05:00Z",
  alert: {
    alert_id: "alert-push-001",
    source: "synthetic",
    service: "checkout-api",
    severity: "critical",
    title: "checkout-api is down",
    started_at: "2026-06-22T08:00:00Z",
  },
};

const TRIAGE_SUCCESS_RESPONSE = {
  incident_id: "inc-push-001",
  classification: "critical_service_down",
  status: "DIAGNOSED",
  confidence: 0.86,
};

// ════════════════════════════════════════════════════════
//  SETUP
// ════════════════════════════════════════════════════════
beforeEach(() => {
  jest.clearAllMocks();
  loadHandler();
  process.env.AI_ENGINE_URL = "http://localhost:8080/v1/triage";
  process.env.SERVICE_AUTH_TOKEN_ARN = "arn:aws:secretsmanager:us-east-1:000000000000:secret:triage-hub/ai-engine";
});

// ════════════════════════════════════════════════════════
//  CONTRACT: Authorization header
// ════════════════════════════════════════════════════════
describe("push-to-ai — Authorization header", () => {
  test("fetches secret from Secrets Manager and sends Bearer token", async () => {
    mockSmSend.mockResolvedValueOnce({
      SecretString: JSON.stringify({ SERVICE_AUTH_TOKEN: "secret-token-xyz" }),
    });
    mockFetch.mockResolvedValueOnce(makeResponse(200, TRIAGE_SUCCESS_RESPONSE));

    await handler(makeRecord(VALID_PAYLOAD));

    const [url, opts] = mockFetch.mock.calls[0];
    expect(url).toBe("http://localhost:8080/v1/triage");
    expect(opts.headers["Authorization"]).toBe("Bearer secret-token-xyz");
  });

  test("sends X-Correlation-Id and X-Tenant-Id headers", async () => {
    mockSmSend.mockResolvedValueOnce({
      SecretString: JSON.stringify({ SERVICE_AUTH_TOKEN: "token-abc" }),
    });
    mockFetch.mockResolvedValueOnce(makeResponse(200, TRIAGE_SUCCESS_RESPONSE));

    await handler(makeRecord(VALID_PAYLOAD));

    const [, opts] = mockFetch.mock.calls[0];
    expect(opts.headers["X-Correlation-Id"]).toBe("corr-push-001");
    expect(opts.headers["X-Tenant-Id"]).toBe("tenant-a");
    expect(opts.headers["Content-Type"]).toBe("application/json");
  });

  test("sends no Authorization header when SERVICE_AUTH_TOKEN_ARN is not set", async () => {
    delete process.env.SERVICE_AUTH_TOKEN_ARN;
    loadHandler(); // reload without ARN
    mockFetch.mockResolvedValueOnce(makeResponse(200, TRIAGE_SUCCESS_RESPONSE));

    await handler(makeRecord(VALID_PAYLOAD));

    const [, opts] = mockFetch.mock.calls[0];
    expect(opts.headers["Authorization"]).toBeUndefined();
  });

  test("parses raw SecretString fallback (non-JSON)", async () => {
    mockSmSend.mockResolvedValueOnce({ SecretString: "raw-token-fallback" });
    mockFetch.mockResolvedValueOnce(makeResponse(200, TRIAGE_SUCCESS_RESPONSE));

    await handler(makeRecord(VALID_PAYLOAD));

    const [, opts] = mockFetch.mock.calls[0];
    expect(opts.headers["Authorization"]).toBe("Bearer raw-token-fallback");
  });
});

// ════════════════════════════════════════════════════════
//  ENGINE RESPONSE HANDLING
// ════════════════════════════════════════════════════════
describe("push-to-ai — engine response handling", () => {
  test("succeeds when engine returns 200", async () => {
    mockSmSend.mockResolvedValueOnce({
      SecretString: JSON.stringify({ SERVICE_AUTH_TOKEN: "t" }),
    });
    mockFetch.mockResolvedValueOnce(makeResponse(200, TRIAGE_SUCCESS_RESPONSE));

    const result = await handler(makeRecord(VALID_PAYLOAD));
    expect(result).toEqual({ status: "processed" });
  });

  test("throws when engine returns 4xx (→ SQS retry)", async () => {
    mockSmSend.mockResolvedValueOnce({
      SecretString: JSON.stringify({ SERVICE_AUTH_TOKEN: "t" }),
    });
    mockFetch.mockResolvedValueOnce(makeResponse(401, { detail: "Unauthorized" }));

    await expect(handler(makeRecord(VALID_PAYLOAD))).rejects.toThrow("401");
  });

  test("throws when engine returns 500 (→ SQS DLQ)", async () => {
    mockSmSend.mockResolvedValueOnce({
      SecretString: JSON.stringify({ SERVICE_AUTH_TOKEN: "t" }),
    });
    mockFetch.mockResolvedValueOnce(makeResponse(500, { detail: "error" }));

    await expect(handler(makeRecord(VALID_PAYLOAD))).rejects.toThrow("500");
  });

  test("throws when fetch itself fails (network error → DLQ)", async () => {
    mockSmSend.mockResolvedValueOnce({
      SecretString: JSON.stringify({ SERVICE_AUTH_TOKEN: "t" }),
    });
    mockFetch.mockRejectedValueOnce(new Error("ECONNREFUSED"));

    await expect(handler(makeRecord(VALID_PAYLOAD))).rejects.toThrow("ECONNREFUSED");
  });
});

// ════════════════════════════════════════════════════════
//  BATCH PROCESSING
// ════════════════════════════════════════════════════════
describe("push-to-ai — batch processing", () => {
  test("processes multiple SQS records", async () => {
    mockSmSend.mockResolvedValue({
      SecretString: JSON.stringify({ SERVICE_AUTH_TOKEN: "t" }),
    });
    mockFetch
      .mockResolvedValueOnce(makeResponse(200, { ...TRIAGE_SUCCESS_RESPONSE, incident_id: "inc-1" }))
      .mockResolvedValueOnce(makeResponse(200, { ...TRIAGE_SUCCESS_RESPONSE, incident_id: "inc-2" }));

    const event = {
      Records: [
        { messageId: "m1", body: JSON.stringify({ ...VALID_PAYLOAD, incident_id: "inc-1", correlation_id: "c1" }) },
        { messageId: "m2", body: JSON.stringify({ ...VALID_PAYLOAD, incident_id: "inc-2", correlation_id: "c2" }) },
      ],
    };

    const result = await handler(event);
    expect(result.status).toBe("processed");
    expect(mockFetch).toHaveBeenCalledTimes(2);
  });

  test("throws on first failure in batch (partial batch behavior)", async () => {
    mockSmSend.mockResolvedValue({
      SecretString: JSON.stringify({ SERVICE_AUTH_TOKEN: "t" }),
    });
    mockFetch
      .mockResolvedValueOnce(makeResponse(200, TRIAGE_SUCCESS_RESPONSE))
      .mockRejectedValueOnce(new Error("Engine down"));

    const event = {
      Records: [
        { messageId: "m1", body: JSON.stringify({ ...VALID_PAYLOAD, incident_id: "inc-1" }) },
        { messageId: "m2", body: JSON.stringify({ ...VALID_PAYLOAD, incident_id: "inc-2" }) },
      ],
    };

    await expect(handler(event)).rejects.toThrow("Engine down");
  });
});
