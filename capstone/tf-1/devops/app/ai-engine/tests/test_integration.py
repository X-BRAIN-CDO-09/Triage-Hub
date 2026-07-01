"""
Integration tests — ai-engine
Đối chiếu với: AIO_Contract/ai-api-contract.md
  - GET /healthz  → response shape (status, service, version)
  - POST /v1/triage → tenant isolation, header enforcement
"""

from fastapi.testclient import TestClient

from app.main import app

client = TestClient(app)


# ---------------------------------------------------------------------------
# GET /healthz
# Contract: response body must contain {"status": "ok",
#           "service": "tf1-ai-triage-engine", "version": "v1"}
# ---------------------------------------------------------------------------

def test_healthz_returns_200():
    response = client.get("/healthz")
    assert response.status_code == 200


def test_healthz_response_shape():
    """Contract: /healthz phải trả đủ 3 fields: status, service, version."""
    response = client.get("/healthz")
    body = response.json()
    assert body["status"] == "ok"
    assert body["service"] == "tf1-ai-triage-engine"
    assert "version" in body


# ---------------------------------------------------------------------------
# POST /v1/triage — Tenant isolation
# Contract: "X-Tenant-Id must match body tenant_id → 400"
# ---------------------------------------------------------------------------

def test_tenant_isolation_header_body_mismatch_returns_400():
    """
    Contract: X-Tenant-Id header khác body.tenant_id → 400, không phải 422/403.
    422 là Pydantic schema error — không được accept thay cho tenant mismatch.
    """
    headers = {
        "X-Tenant-Id": "tenant-A",
        "X-Correlation-Id": "corr-iso-001",
        "Authorization": "Bearer test-token",
    }
    payload = {
        "correlation_id": "corr-iso-001",
        "tenant_id": "tenant-B",          # mismatch với header
        "incident_id": "inc-iso-001",
        "environment": "sandbox",
        "received_at": "2026-06-22T08:05:00Z",
        "alert": {
            "alert_id": "alert-iso-001",
            "source": "synthetic-pack",
            "service": "checkout-api",
            "severity": "high",
            "title": "High latency",
            "started_at": "2026-06-22T08:00:00Z",
        },
    }
    response = client.post("/v1/triage", json=payload, headers=headers)
    # Contract §Error Codes: tenant mismatch → 400
    assert response.status_code == 400


def test_tenant_isolation_matching_tenant_accepted():
    """Khi X-Tenant-Id khớp body.tenant_id thì không bị chặn ở tầng isolation."""
    headers = {
        "X-Tenant-Id": "tenant-A",
        "X-Correlation-Id": "corr-iso-002",
        "Authorization": "Bearer test-token",
    }
    payload = {
        "correlation_id": "corr-iso-002",
        "tenant_id": "tenant-A",          # khớp với header
        "incident_id": "inc-iso-002",
        "environment": "sandbox",
        "received_at": "2026-06-22T08:05:00Z",
        "alert": {
            "alert_id": "alert-iso-002",
            "source": "synthetic-pack",
            "service": "checkout-api",
            "severity": "high",
            "title": "High latency",
            "started_at": "2026-06-22T08:00:00Z",
        },
    }
    response = client.post("/v1/triage", json=payload, headers=headers)
    # Không bị 400 do tenant mismatch — có thể 200 hoặc lỗi khác không liên quan isolation
    assert response.status_code != 400 or "tenant" not in response.text.lower()


# ---------------------------------------------------------------------------
# POST /v1/triage — X-Correlation-Id mismatch
# Contract: "X-Correlation-Id must match body correlation_id → 400"
# ---------------------------------------------------------------------------

def test_correlation_id_mismatch_returns_400():
    """Contract: X-Correlation-Id header khác body.correlation_id → 400."""
    headers = {
        "X-Tenant-Id": "tenant-A",
        "X-Correlation-Id": "corr-HEADER",   # khác body
        "Authorization": "Bearer test-token",
    }
    payload = {
        "correlation_id": "corr-BODY",        # mismatch
        "tenant_id": "tenant-A",
        "incident_id": "inc-corr-001",
        "environment": "sandbox",
        "received_at": "2026-06-22T08:05:00Z",
        "alert": {
            "alert_id": "alert-corr-001",
            "source": "synthetic-pack",
            "service": "checkout-api",
            "severity": "high",
            "title": "High latency",
            "started_at": "2026-06-22T08:00:00Z",
        },
    }
    response = client.post("/v1/triage", json=payload, headers=headers)
    assert response.status_code == 400
