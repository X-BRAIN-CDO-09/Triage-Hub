"""
conftest.py — shared pytest fixtures for ai-engine tests

Key fixture: `isolate_auth_env`
  - Ensures tests run WITHOUT SERVICE_AUTH_TOKEN even if it is set in the
    developer's shell (local dev sets this; CI does not).
  - Applied autouse=True to all tests in this package.
  - Individual tests that specifically want to test auth enforcement can
    override by setting os.environ["SERVICE_AUTH_TOKEN"] inside the test.
"""

from __future__ import annotations

import pytest
import sys
import os
from unittest.mock import MagicMock
sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), '..')))

# 2. Giả lập (Mock) hoàn toàn thư viện numpy để Python không báo lỗi thiếu module
sys.modules['numpy'] = MagicMock()
sys.modules['sklearn'] = MagicMock()
sys.modules['sklearn.ensemble'] = MagicMock()
mock_otlp = MagicMock()
sys.modules['opentelemetry.exporter'] = mock_otlp
sys.modules['opentelemetry.exporter.otlp'] = mock_otlp
sys.modules['opentelemetry.exporter.otlp.proto'] = mock_otlp
sys.modules['opentelemetry.exporter.otlp.proto.http'] = mock_otlp
sys.modules['opentelemetry.exporter.otlp.proto.http.trace_exporter'] = mock_otlp

@pytest.fixture(autouse=True)
def isolate_auth_env(monkeypatch: pytest.MonkeyPatch) -> None:
    """
    Strip SERVICE_AUTH_TOKEN from the environment for every test.

    Rationale: The engine only enforces auth when this var is set.
    Unit tests exercise business logic — not deployment auth — so they
    should run without a token, exactly as they do in CI.

    Tests that need to verify auth enforcement explicitly set the var
    themselves (e.g. the dedicated auth tests).
    """
    monkeypatch.delenv("SERVICE_AUTH_TOKEN", raising=False)
