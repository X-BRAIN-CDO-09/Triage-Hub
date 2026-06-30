/**
 * load/k6-local.js
 * k6 load test — Phase 5: 30 req/min, p99 < 2s target
 *
 * Run:
 *   k6 run load/k6-local.js
 *   k6 run --vus 5 --duration 2m load/k6-local.js
 *
 * Install k6: https://k6.io/docs/get-started/installation/
 * Windows: winget install k6 --source winget
 */

import http from "k6/http";
import { check, sleep } from "k6";
import { Counter, Rate, Trend } from "k6/metrics";

// ── Custom metrics ────────────────────────────────────────
const triageErrors = new Counter("triage_errors");
const triageSuccessRate = new Rate("triage_success_rate");
const triageP99 = new Trend("triage_duration_ms", true);

// ── Config ────────────────────────────────────────────────
const ENGINE_URL = __ENV.ENGINE_URL || "http://localhost:8080";
const AUTH_TOKEN = __ENV.AUTH_TOKEN || "local-dev-token-abc123";

// ── Load profile ──────────────────────────────────────────
// Phase 5 target: 30 req/min = 0.5 req/s
// Use 3 VUs × sleep(6s) = ~0.5 req/s per VU × 3 = 1.5 req/s total = 90 req/min
// Adjust VUs and sleep to hit exactly 30 req/min: 1 VU, sleep(2s) = 30/min

export const options = {
  scenarios: {
    // Ramp up to target, hold, ramp down
    load_test: {
      executor: "ramping-vus",
      stages: [
        { duration: "30s", target: 1 },   // Warm up
        { duration: "90s", target: 2 },   // ~30-60 req/min
        { duration: "60s", target: 2 },   // Hold
        { duration: "30s", target: 0 },   // Cool down
      ],
    },
  },
  thresholds: {
    // p99 < 2000ms — Phase 5 pass criterion
    http_req_duration: ["p(99)<2000"],
    triage_success_rate: ["rate>0.95"],   // 95%+ success rate
    triage_errors: ["count<5"],           // Less than 5 hard errors
  },
};

// ── Sample payloads (rotate to hit different code paths) ───
const PAYLOADS = [
  // critical-service-down → DIAGNOSED
  {
    correlation_id: `corr-load-critical-${__VU}-${__ITER}`,
    tenant_id: "tenant-load",
    incident_id: `inc-load-critical-${__VU}-${__ITER}`,
    environment: "sandbox",
    received_at: new Date().toISOString(),
    alert: {
      alert_id: `alert-load-${__VU}-${__ITER}`,
      source: "k6-load-test",
      service: "checkout-api",
      severity: "critical",
      title: "checkout-api is down",
      started_at: new Date().toISOString(),
    },
    metrics: [{
      metric_name: "availability_success_rate",
      service: "checkout-api",
      unit: "percent",
      points: [
        { ts: new Date(Date.now() - 120000).toISOString(), value: 99.9 },
        { ts: new Date().toISOString(), value: 42.0 },
      ],
    }],
    logs: [{
      service: "checkout-api",
      ts: new Date().toISOString(),
      level: "error",
      message: "health check failed: dependency connection refused",
    }],
    recent_deploys: [{
      service: "checkout-api",
      version: "sha-load-test",
      deployed_at: new Date(Date.now() - 600000).toISOString(),
      deployed_by: "k6",
      change_summary: "load test deploy",
    }],
    ownership: {
      service: "checkout-api",
      owner_team: "payments-platform",
      jira_project: "PAY",
    },
  },
  // latency-degradation → DIAGNOSED
  {
    correlation_id: `corr-load-latency-${__VU}-${__ITER}`,
    tenant_id: "tenant-load",
    incident_id: `inc-load-latency-${__VU}-${__ITER}`,
    environment: "sandbox",
    received_at: new Date().toISOString(),
    alert: {
      alert_id: `alert-latency-${__VU}-${__ITER}`,
      source: "k6-load-test",
      service: "order-service",
      severity: "high",
      title: "order-service p95 latency elevated",
      started_at: new Date().toISOString(),
    },
    metrics: [{
      metric_name: "p95_latency_ms",
      service: "order-service",
      unit: "ms",
      points: [
        { ts: new Date().toISOString(), value: 1800 },
      ],
    }],
    logs: [{
      service: "order-service",
      ts: new Date().toISOString(),
      level: "warn",
      message: "timeout exceeded on database query",
    }],
    ownership: {
      service: "order-service",
      owner_team: "orders-team",
      jira_project: "ORD",
    },
  },
];

// ── Main test function ─────────────────────────────────────
export default function () {
  // Rotate payloads across VUs
  const payload = PAYLOADS[__ITER % PAYLOADS.length];

  const headers = {
    "Content-Type": "application/json",
    "X-Tenant-Id": payload.tenant_id,
    "X-Correlation-Id": payload.correlation_id,
    Authorization: `Bearer ${AUTH_TOKEN}`,
  };

  const start = Date.now();
  const res = http.post(
    `${ENGINE_URL}/v1/triage`,
    JSON.stringify(payload),
    { headers, timeout: "10s" }
  );
  const duration = Date.now() - start;

  triageP99.add(duration);

  const success = check(res, {
    "status is 200": (r) => r.status === 200,
    "has incident_id": (r) => {
      try { return JSON.parse(r.body).incident_id !== undefined; }
      catch { return false; }
    },
    "status is DIAGNOSED or INVESTIGATE": (r) => {
      try {
        const b = JSON.parse(r.body);
        return ["DIAGNOSED", "INVESTIGATE", "INSUFFICIENT_CONTEXT"].includes(b.status);
      } catch { return false; }
    },
    "p99 < 2000ms": () => duration < 2000,
  });

  triageSuccessRate.add(success);
  if (!success || res.status !== 200) {
    triageErrors.add(1);
    console.error(`FAIL VU=${__VU} ITER=${__ITER} status=${res.status} duration=${duration}ms`);
  }

  // 2s sleep → ~30 req/min per VU
  sleep(2);
}

// ── Teardown report ───────────────────────────────────────
export function handleSummary(data) {
  const p99 = data.metrics?.http_req_duration?.values?.["p(99)"] || 0;
  const successRate = (data.metrics?.triage_success_rate?.values?.rate || 0) * 100;
  const errors = data.metrics?.triage_errors?.values?.count || 0;
  const reqs = data.metrics?.http_reqs?.values?.count || 0;

  const pass = p99 < 2000 && successRate >= 95 && errors < 5;

  console.log("\n");
  console.log("═══════════════════════════════════════");
  console.log(" Phase 5 Load Test Results");
  console.log("═══════════════════════════════════════");
  console.log(`  Total requests : ${reqs}`);
  console.log(`  p99 latency    : ${p99.toFixed(0)}ms  (target: < 2000ms) ${p99 < 2000 ? "✓" : "✗"}`);
  console.log(`  Success rate   : ${successRate.toFixed(1)}%  (target: > 95%) ${successRate >= 95 ? "✓" : "✗"}`);
  console.log(`  Hard errors    : ${errors}  (target: < 5) ${errors < 5 ? "✓" : "✗"}`);
  console.log(`  OVERALL        : ${pass ? "PASS ✓" : "FAIL ✗"}`);
  console.log("═══════════════════════════════════════\n");

  return {
    stdout: JSON.stringify(data, null, 2),
  };
}
