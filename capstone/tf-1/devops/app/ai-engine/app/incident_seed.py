from __future__ import annotations

from typing import Any, Literal

from pydantic import BaseModel, Field

from app.context_enrichment import enrich_triage_context
from app.context_tools import ToolRegistry
from app.main import LogEntry, MetricSeries, Ownership, RecentDeploy


class IncidentSeed(BaseModel):
    schema_version: Literal["tf1.incident_seed.v1"]
    tenant_id: str = Field(min_length=1)
    correlation_id: str = Field(min_length=1)
    incident_id: str = Field(min_length=1)
    environment: Literal["prod", "staging", "sandbox"]
    service: str = Field(min_length=1)
    severity: Literal["critical", "high", "medium", "low", "unknown"]
    title: str = Field(min_length=1)
    description: str | None = None
    started_at: str = Field(min_length=1)
    received_at: str = Field(min_length=1)
    labels: dict[str, Any] = Field(default_factory=dict)
    # Bổ sung các trường với kiểu class chuẩn
    metrics: list[MetricSeries] = Field(default_factory=list)
    logs: list[LogEntry] = Field(default_factory=list)
    traces: list[dict[str, Any]] = Field(default_factory=list)
    recent_deploys: list[RecentDeploy] = Field(default_factory=list)
    ownership: Ownership | None = None


def build_triage_request_from_seed(seed: IncidentSeed, registry: ToolRegistry | None = None) -> dict[str, Any]:
    body = {
        "correlation_id": seed.correlation_id,
        "tenant_id": seed.tenant_id,
        "incident_id": seed.incident_id,
        "environment": seed.environment,
        "received_at": seed.received_at,
        "alert": {
            "alert_id": str(seed.labels.get("alert_id") or seed.incident_id),
            "source": str(seed.labels.get("source") or "cdo-detector"),
            "service": seed.service,
            "severity": seed.severity,
            "title": seed.title,
            "description": seed.description,
            "started_at": seed.started_at,
            "labels": seed.labels,
        },
        # Truyền tiếp context nhận được từ SQS thay vì ép về rỗng []
        "metrics": seed.metrics,
        "logs": seed.logs,
        "traces": seed.traces,
        "recent_deploys": seed.recent_deploys,
        "ownership": seed.ownership,
    }
    return enrich_triage_context(body, registry)
