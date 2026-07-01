"""
conftest.py — shared pytest fixtures for ai-engine tests

Mục đích: mock tất cả heavy/external dependencies để test chạy được
mà không cần cài đầy đủ packages (numpy, sklearn, boto3, opentelemetry...).

Import chain cần mock (theo thứ tự app/main.py load):
  observability.py  → opentelemetry.*, prometheus_client
  context_tools.py  → requests
  llm.py            → boto3
  rca.py            → numpy, sklearn

Key fixture: isolate_auth_env
  - Xóa SERVICE_AUTH_TOKEN khỏi env cho mọi test.
  - Test nào muốn kiểm tra auth enforcement thì tự set lại trong test body.
"""

from __future__ import annotations

import os
import sys
from unittest.mock import MagicMock

import pytest

# ---------------------------------------------------------------------------
# 0. Đảm bảo package root nằm trong sys.path
# ---------------------------------------------------------------------------
sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), "..")))


# ---------------------------------------------------------------------------
# 1. Mock numpy + sklearn (rca.py dùng IsolationForest, np.array, np.corrcoef)
# ---------------------------------------------------------------------------
mock_np = MagicMock()
mock_np.array = lambda x, **kw: x  # trả lại list thô — đủ để test chạy
mock_np.std = lambda x, **kw: 1.0
mock_np.corrcoef = lambda *a, **kw: [[0.0, 0.0], [0.0, 0.0]]
sys.modules["numpy"] = mock_np

mock_sklearn = MagicMock()
mock_isolation_forest_cls = MagicMock()
# fit_predict trả -1 (outlier) hay 1 (normal) — trả 1 để không trigger anomaly trong test cơ bản
mock_isolation_forest_cls.return_value.fit_predict.return_value = [1]
mock_isolation_forest_cls.return_value.score_samples.return_value = [-0.1]
mock_sklearn.ensemble.IsolationForest = mock_isolation_forest_cls
sys.modules["sklearn"] = mock_sklearn
sys.modules["sklearn.ensemble"] = mock_sklearn.ensemble


# ---------------------------------------------------------------------------
# 2. Mock opentelemetry — cả api lẫn sdk lẫn exporter
#    observability.py import:
#      from opentelemetry import trace
#      from opentelemetry.exporter.otlp.proto.http.trace_exporter import OTLPSpanExporter
#      from opentelemetry.sdk.resources import Resource
#      from opentelemetry.sdk.trace import TracerProvider
#      from opentelemetry.sdk.trace.export import BatchSpanProcessor
# ---------------------------------------------------------------------------
mock_otel = MagicMock()

# opentelemetry.trace — get_tracer().start_as_current_span() phải là context manager
mock_span_ctx = MagicMock()
mock_span_ctx.__enter__ = MagicMock(return_value=MagicMock())
mock_span_ctx.__exit__ = MagicMock(return_value=False)
mock_otel.trace.get_tracer.return_value.start_as_current_span.return_value = mock_span_ctx
mock_otel.trace.set_tracer_provider = MagicMock()

sys.modules["opentelemetry"] = mock_otel
sys.modules["opentelemetry.trace"] = mock_otel.trace

# sdk
mock_sdk = MagicMock()
sys.modules["opentelemetry.sdk"] = mock_sdk
sys.modules["opentelemetry.sdk.resources"] = mock_sdk
sys.modules["opentelemetry.sdk.trace"] = mock_sdk
sys.modules["opentelemetry.sdk.trace.export"] = mock_sdk

# exporter
mock_otlp = MagicMock()
sys.modules["opentelemetry.exporter"] = mock_otlp
sys.modules["opentelemetry.exporter.otlp"] = mock_otlp
sys.modules["opentelemetry.exporter.otlp.proto"] = mock_otlp
sys.modules["opentelemetry.exporter.otlp.proto.http"] = mock_otlp
sys.modules["opentelemetry.exporter.otlp.proto.http.trace_exporter"] = mock_otlp


# ---------------------------------------------------------------------------
# 3. Mock prometheus_client
#    observability.py dùng Counter, Gauge, Histogram, CollectorRegistry,
#    generate_latest, CONTENT_TYPE_LATEST
# ---------------------------------------------------------------------------
mock_prom = MagicMock()


class _FakeMetric:
    """Stub đủ để Counter/Gauge/Histogram hoạt động mà không cần thư viện thật."""

    def __init__(self, *a, **kw):
        pass

    def labels(self, **kw):
        return self

    def inc(self, *a):
        pass

    def dec(self, *a):
        pass

    def set(self, *a):
        pass

    def observe(self, *a):
        pass


mock_prom.Counter = _FakeMetric
mock_prom.Gauge = _FakeMetric
mock_prom.Histogram = _FakeMetric
mock_prom.CollectorRegistry = MagicMock(return_value=MagicMock())
mock_prom.generate_latest = MagicMock(return_value=b"")
mock_prom.openmetrics = MagicMock()
mock_prom.openmetrics.exposition = MagicMock()
mock_prom.openmetrics.exposition.CONTENT_TYPE_LATEST = "text/plain"

sys.modules["prometheus_client"] = mock_prom
sys.modules["prometheus_client.openmetrics"] = mock_prom.openmetrics
sys.modules["prometheus_client.openmetrics.exposition"] = mock_prom.openmetrics.exposition


# ---------------------------------------------------------------------------
# 4. Mock requests (context_tools.py dùng requests.get cho Prometheus/Loki/Jaeger)
# ---------------------------------------------------------------------------
mock_requests = MagicMock()
mock_requests.get.return_value.status_code = 200
mock_requests.get.return_value.raise_for_status = MagicMock()
mock_requests.get.return_value.json.return_value = {"status": "success", "data": {"result": []}}
mock_requests.post.return_value.status_code = 200
mock_requests.post.return_value.raise_for_status = MagicMock()

sys.modules["requests"] = mock_requests


# ---------------------------------------------------------------------------
# 5. Mock boto3 — phải mock như một package thật vì dynamodb_store.py import:
#    from boto3.dynamodb.conditions import Attr, Key
# ---------------------------------------------------------------------------
mock_boto3 = MagicMock()


# Stub Attr / Key đủ để dynamodb_store.py import thành công
class _FakeAttr:
    def eq(self, v):
        return self

    def begins_with(self, v):
        return self

    def __and__(self, other):
        return self

    def __or__(self, other):
        return self


class _FakeKey(_FakeAttr):
    pass


mock_dynamodb_conditions = MagicMock()
mock_dynamodb_conditions.Attr = _FakeAttr
mock_dynamodb_conditions.Key = _FakeKey

mock_boto3.dynamodb = MagicMock()
mock_boto3.dynamodb.conditions = mock_dynamodb_conditions

mock_boto3.client.return_value.invoke_agent_runtime.return_value = {
    "contentType": "application/json",
    "response": iter([b'{"summary": "mock summary"}']),
}

sys.modules["boto3"] = mock_boto3
sys.modules["boto3.dynamodb"] = mock_boto3.dynamodb
sys.modules["boto3.dynamodb.conditions"] = mock_dynamodb_conditions


# ---------------------------------------------------------------------------
# 6. Fixture: xóa SERVICE_AUTH_TOKEN cho mọi test
# ---------------------------------------------------------------------------
@pytest.fixture(autouse=True)
def isolate_auth_env(monkeypatch: pytest.MonkeyPatch) -> None:
    """
    Strip SERVICE_AUTH_TOKEN khỏi environment cho mọi test.

    Rationale: Engine chỉ enforce auth khi var này được set.
    Unit/integration tests kiểm tra business logic, không phải deployment auth
    — phải chạy không có token, giống hệt CI environment.

    Test nào muốn verify auth enforcement thì tự set var trong body test.
    """
    monkeypatch.delenv("SERVICE_AUTH_TOKEN", raising=False)
