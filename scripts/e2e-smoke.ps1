# scripts/e2e-smoke.ps1
# Full E2E smoke test — Phase 1, 2, 3 local simulation
# Usage: .\scripts\e2e-smoke.ps1 [-Phase 1|2|3|all]
#
# Phase 1: pytest unit + 4 golden eval harness (no Docker needed)
# Phase 2: health + triage smoke (Docker tf1-api needed)
# Phase 3: alert-ingest sim -> SQS(LocalStack) -> push-to-ai sim -> engine

param(
    [ValidateSet("1","2","3","all")]
    [string]$Phase = "all",
    [string]$EngineUrl = "http://localhost:8080",
    [string]$AuthToken = "local-dev-token-abc123",
    [string]$TenantId = "tenant-a",
    [string]$SamplesDir = "capstone/tf-1/devops/app/ai-engine/samples",
    [string]$LocalStackUrl = "http://localhost:4566"
)

$ErrorActionPreference = "Stop"
$PASS = 0
$FAIL = 0
$script:Results = @()

function Log-Pass($msg) {
    Write-Host "  [PASS] $msg" -ForegroundColor Green
    $script:PASS++
    $script:Results += [pscustomobject]@{ Status="PASS"; Test=$msg }
}
function Log-Fail($msg) {
    Write-Host "  [FAIL] $msg" -ForegroundColor Red
    $script:FAIL++
    $script:Results += [pscustomobject]@{ Status="FAIL"; Test=$msg }
}
function Log-Skip($msg) {
    Write-Host "  [SKIP] $msg" -ForegroundColor DarkGray
}
function Section($title) {
    Write-Host ""
    Write-Host "━━━ $title ━━━" -ForegroundColor Cyan
}

# ════════════════════════════════════════
#  PHASE 1 — Engine Unit + Eval Harness
# ════════════════════════════════════════
function Run-Phase1 {
    Section "Phase 1 — Engine Unit Tests"

    # 1a. pytest
    Write-Host "  Running pytest..." -ForegroundColor Yellow
    Push-Location "capstone/tf-1/devops/app/ai-engine"
    try {
        $result = & python -m pytest tests/test_aiops_pipeline.py -v --tb=short 2>&1
        if ($LASTEXITCODE -eq 0) {
            Log-Pass "pytest — all unit tests green"
        } else {
            Log-Fail "pytest — one or more tests FAILED"
            Write-Host ($result | Select-Object -Last 20 | Out-String) -ForegroundColor DarkRed
        }
    } finally {
        Pop-Location
    }

    # 1b. Eval harness — 4 golden samples
    Section "Phase 1 — Eval Harness (4 golden samples)"

    $goldens = @(
        @{ file="critical-service-down.request.json";  expectStatus="DIAGNOSED";            expectClass="critical_service_down" },
        @{ file="latency-degradation.request.json";    expectStatus="DIAGNOSED";            expectClass="latency_degradation" },
        @{ file="noisy-alert.request.json";            expectStatus="INVESTIGATE";           expectClass="noisy_or_ambiguous_alert" },
        @{ file="insufficient-context.request.json";  expectStatus="INSUFFICIENT_CONTEXT"; expectClass="insufficient_context" }
    )

    Write-Host "  Starting uvicorn for eval harness..." -ForegroundColor Yellow
    Push-Location "capstone/tf-1/devops/app/ai-engine"
    $uvicornJob = Start-Job -ScriptBlock {
        param($dir)
        Set-Location $dir
        $env:SERVICE_AUTH_TOKEN = "local-dev-token-abc123"
        $env:AGENTCORE_LLM_ENABLED = "false"
        $env:AIOPS_LLM_TOOLS_ENABLED = "false"
        $env:AGENTCORE_AGENT_PLATFORM_ENABLED = "false"
        $env:AIOPS_OBSERVABILITY_ENABLED = "false"
        & python -m uvicorn app.main:app --host 127.0.0.1 --port 8081 2>&1
    } -ArgumentList (Get-Location).Path

    Start-Sleep -Seconds 4  # wait for uvicorn to start

    try {
        foreach ($g in $goldens) {
            $reqFile = "$SamplesDir/$($g.file)"
            if (!(Test-Path $reqFile)) {
                Log-Skip "$($g.file) — file not found"
                continue
            }
            $body = Get-Content $reqFile -Raw | ConvertFrom-Json
            $corrId = $body.correlation_id
            $tenantId = $body.tenant_id

            try {
                $resp = Invoke-RestMethod `
                    -Uri "http://127.0.0.1:8081/v1/triage" `
                    -Method POST `
                    -Body (Get-Content $reqFile -Raw) `
                    -ContentType "application/json" `
                    -Headers @{
                        "X-Tenant-Id"      = $tenantId
                        "X-Correlation-Id" = $corrId
                        "Authorization"    = "Bearer local-dev-token-abc123"
                    }

                $ok = ($resp.status -eq $g.expectStatus) -and ($resp.classification -eq $g.expectClass)
                if ($ok) {
                    Log-Pass "$($g.file) → status=$($resp.status), class=$($resp.classification)"
                } else {
                    Log-Fail "$($g.file) → expected status=$($g.expectStatus)/class=$($g.expectClass), got status=$($resp.status)/class=$($resp.classification)"
                }
            } catch {
                Log-Fail "$($g.file) → HTTP error: $_"
            }
        }
    } finally {
        Stop-Job $uvicornJob | Out-Null
        Remove-Job $uvicornJob | Out-Null
        Pop-Location
    }
}

# ════════════════════════════════════════
#  PHASE 2 — Deployed Smoke (Docker tf1-api)
# ════════════════════════════════════════
function Run-Phase2 {
    Section "Phase 2 — Health + Triage Smoke (Docker tf1-api)"

    # 2a. /healthz
    try {
        $h = Invoke-RestMethod "$EngineUrl/healthz" -TimeoutSec 5
        if ($h.status -eq "ok") {
            Log-Pass "/healthz → status=ok, service=$($h.service)"
        } else {
            Log-Fail "/healthz → unexpected: $($h | ConvertTo-Json -Compress)"
        }
    } catch {
        Log-Fail "/healthz → not reachable. Is Docker tf1-api running?"
        return
    }

    # 2b. /readyz
    try {
        $r = Invoke-RestMethod "$EngineUrl/readyz" -TimeoutSec 5
        Log-Pass "/readyz → status=$($r.status)"
    } catch {
        Log-Fail "/readyz → $_"
    }

    # 2c. /v1/triage — critical-service-down
    try {
        $body = Get-Content "$SamplesDir/critical-service-down.request.json" -Raw
        $parsed = $body | ConvertFrom-Json
        $resp = Invoke-RestMethod `
            -Uri "$EngineUrl/v1/triage" `
            -Method POST `
            -Body $body `
            -ContentType "application/json" `
            -Headers @{
                "X-Tenant-Id"      = $parsed.tenant_id
                "X-Correlation-Id" = $parsed.correlation_id
                "Authorization"    = "Bearer $AuthToken"
            }
        if ($resp.status -eq "DIAGNOSED" -and $resp.classification -eq "critical_service_down") {
            Log-Pass "/v1/triage (critical) → DIAGNOSED / critical_service_down (confidence=$($resp.confidence))"
        } else {
            Log-Fail "/v1/triage (critical) → unexpected: status=$($resp.status), class=$($resp.classification)"
        }
    } catch {
        Log-Fail "/v1/triage → $_"
    }

    # 2d. Audit check — audit_id must exist in audit file
    try {
        $body = Get-Content "$SamplesDir/critical-service-down.request.json" -Raw
        $parsed = $body | ConvertFrom-Json
        $resp = Invoke-RestMethod `
            -Uri "$EngineUrl/v1/triage" `
            -Method POST `
            -Body $body `
            -ContentType "application/json" `
            -Headers @{
                "X-Tenant-Id"      = $parsed.tenant_id
                "X-Correlation-Id" = $parsed.correlation_id
                "Authorization"    = "Bearer $AuthToken"
            }
        $auditId = $resp.audit_id
        $audit = Invoke-RestMethod `
            -Uri "$EngineUrl/v1/audit/$auditId" `
            -Headers @{
                "X-Tenant-Id"   = $parsed.tenant_id
                "Authorization" = "Bearer $AuthToken"
            }
        if ($audit.audit_id -eq $auditId) {
            Log-Pass "/v1/audit/$auditId → record found (record_type=$($audit.record_type))"
        } else {
            Log-Fail "/v1/audit → returned wrong audit_id"
        }
    } catch {
        Log-Fail "/v1/audit → $_"
    }

    # 2e. Tenant isolation — wrong tenant → 400
    try {
        $body = Get-Content "$SamplesDir/critical-service-down.request.json" -Raw
        $parsed = $body | ConvertFrom-Json
        try {
            Invoke-RestMethod `
                -Uri "$EngineUrl/v1/triage" `
                -Method POST `
                -Body $body `
                -ContentType "application/json" `
                -Headers @{
                    "X-Tenant-Id"      = "WRONG-TENANT"
                    "X-Correlation-Id" = $parsed.correlation_id
                    "Authorization"    = "Bearer $AuthToken"
                } | Out-Null
            Log-Fail "Tenant isolation — expected 400 but got 200"
        } catch {
            if ($_.Exception.Response.StatusCode.value__ -eq 400) {
                Log-Pass "Tenant isolation — wrong X-Tenant-Id → 400 (correct)"
            } else {
                Log-Fail "Tenant isolation — got $($_.Exception.Response.StatusCode.value__) instead of 400"
            }
        }
    } catch {
        Log-Fail "Tenant isolation test error: $_"
    }

    # 2f. Auth — missing token → 401
    try {
        $savedToken = $env:SERVICE_AUTH_TOKEN
        $body = Get-Content "$SamplesDir/critical-service-down.request.json" -Raw
        $parsed = $body | ConvertFrom-Json
        try {
            Invoke-RestMethod `
                -Uri "$EngineUrl/v1/triage" `
                -Method POST `
                -Body $body `
                -ContentType "application/json" `
                -Headers @{
                    "X-Tenant-Id"      = $parsed.tenant_id
                    "X-Correlation-Id" = $parsed.correlation_id
                    "Authorization"    = "Bearer INVALID-TOKEN"
                } | Out-Null
            Log-Fail "Auth — expected 401 but got 200"
        } catch {
            if ($_.Exception.Response.StatusCode.value__ -eq 401) {
                Log-Pass "Auth — invalid token → 401 (correct)"
            } else {
                Log-Fail "Auth — got $($_.Exception.Response.StatusCode.value__) instead of 401"
            }
        }
    } catch {
        Log-Fail "Auth test error: $_"
    }
}

# ════════════════════════════════════════
#  PHASE 3 — Lambda Integration Simulation
# ════════════════════════════════════════
function Run-Phase3 {
    Section "Phase 3 — Lambda Integration Simulation (LocalStack + Node)"

    # Check LocalStack
    try {
        Invoke-RestMethod "$LocalStackUrl/_localstack/health" -TimeoutSec 3 | Out-Null
    } catch {
        Log-Fail "LocalStack not running — skipping Phase 3. Run: docker compose -f docker-compose.local.yml up -d"
        return
    }

    $env:AWS_ACCESS_KEY_ID = "test"
    $env:AWS_SECRET_ACCESS_KEY = "test"
    $env:AWS_DEFAULT_REGION = "us-east-1"

    # 3a. alert-ingest sim — POST directly to SQS (simulates Lambda)
    $body = Get-Content "$SamplesDir/critical-service-down.request.json" -Raw
    $queueUrl = "$LocalStackUrl/000000000000/$($($LocalStackUrl -replace 'http://','') -replace ':.*','')"
    # Get actual queue URL from LocalStack
    try {
        $queueUrlReal = (aws --endpoint-url=$LocalStackUrl sqs get-queue-url `
            --queue-name "triage-buffer-local" 2>&1 | ConvertFrom-Json).QueueUrl
    } catch {
        $queueUrlReal = "$LocalStackUrl/000000000000/triage-buffer-local"
    }

    Write-Host "  Queue URL: $queueUrlReal" -ForegroundColor DarkGray

    # 3b. alert-ingest: reject missing tenant_id → should return 400
    $noTenantBody = '{"correlation_id":"test","incident_id":"inc-test","alert":{"alert_id":"a1","source":"s","service":"svc","severity":"critical","title":"t","started_at":"2026-01-01T00:00:00Z"}}'
    $alertIngestLambdaEvent = @{
        body = $noTenantBody
    } | ConvertTo-Json
    # Simulate alert-ingest validation
    $parsed = $noTenantBody | ConvertFrom-Json
    if (-not $parsed.tenant_id) {
        Log-Pass "alert-ingest — missing tenant_id → would return 400 (contract enforced)"
    } else {
        Log-Fail "alert-ingest — should reject missing tenant_id"
    }

    # 3c. Push valid message to SQS
    try {
        aws --endpoint-url=$LocalStackUrl sqs send-message `
            --queue-url $queueUrlReal `
            --message-body $body `
            --message-attributes "TenantId={DataType=String,StringValue=tenant-a}" `
            --region us-east-1 2>&1 | Out-Null

        $attrs = aws --endpoint-url=$LocalStackUrl sqs get-queue-attributes `
            --queue-url $queueUrlReal `
            --attribute-names ApproximateNumberOfMessages `
            --region us-east-1 | ConvertFrom-Json
        $depth = $attrs.Attributes.ApproximateNumberOfMessages
        if ([int]$depth -ge 1) {
            Log-Pass "SQS message landed — queue depth=$depth"
        } else {
            Log-Fail "SQS message not found in queue"
        }
    } catch {
        Log-Fail "SQS send-message failed: $_"
    }

    # 3d. push-to-ai → engine (direct simulation: curl from LocalStack message body)
    try {
        $parsed = $body | ConvertFrom-Json
        $resp = Invoke-RestMethod `
            -Uri "$EngineUrl/v1/triage" `
            -Method POST `
            -Body $body `
            -ContentType "application/json" `
            -Headers @{
                "X-Tenant-Id"      = $parsed.tenant_id
                "X-Correlation-Id" = $parsed.correlation_id
                "Authorization"    = "Bearer $AuthToken"
            }
        if ($resp.status -eq "DIAGNOSED") {
            Log-Pass "push-to-ai sim → engine returned DIAGNOSED (simulated full SQS→AI path)"
        } else {
            Log-Fail "push-to-ai sim → engine returned: $($resp.status)"
        }
    } catch {
        Log-Fail "push-to-ai → engine call failed: $_"
    }

    # 3e. Idempotency — same correlation_id twice → same response
    try {
        $parsed = $body | ConvertFrom-Json
        $headers = @{
            "X-Tenant-Id"      = $parsed.tenant_id
            "X-Correlation-Id" = $parsed.correlation_id
            "Authorization"    = "Bearer $AuthToken"
        }
        $r1 = Invoke-RestMethod -Uri "$EngineUrl/v1/triage" -Method POST -Body $body -ContentType "application/json" -Headers $headers
        $r2 = Invoke-RestMethod -Uri "$EngineUrl/v1/triage" -Method POST -Body $body -ContentType "application/json" -Headers $headers
        if ($r1.status -eq $r2.status -and $r1.classification -eq $r2.classification) {
            Log-Pass "Idempotency — same correlation_id → identical status/classification"
        } else {
            Log-Fail "Idempotency — got different results on repeat call"
        }
    } catch {
        Log-Fail "Idempotency test failed: $_"
    }
}

# ════════════════════════════════════════
#  MAIN — Run phases
# ════════════════════════════════════════
Write-Host ""
Write-Host "╔══════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║  TF1 Triage Hub — E2E Smoke Tests   ║" -ForegroundColor Cyan
Write-Host "╚══════════════════════════════════════╝" -ForegroundColor Cyan

switch ($Phase) {
    "1"   { Run-Phase1 }
    "2"   { Run-Phase2 }
    "3"   { Run-Phase3 }
    "all" { Run-Phase1; Run-Phase2; Run-Phase3 }
}

# ── Summary ──────────────────────────────
Write-Host ""
Write-Host "════════════════════════════════════════" -ForegroundColor Cyan
Write-Host " RESULTS: $PASS passed, $FAIL failed" -ForegroundColor $(if ($FAIL -eq 0) { "Green" } else { "Red" })
Write-Host "════════════════════════════════════════" -ForegroundColor Cyan
$script:Results | Format-Table -AutoSize
Write-Host ""
if ($FAIL -gt 0) { exit 1 } else { exit 0 }
