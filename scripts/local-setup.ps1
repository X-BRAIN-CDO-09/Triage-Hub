# scripts/local-setup.ps1
# Chuẩn bị môi trường local test — chạy 1 lần sau khi docker compose up
# Usage: .\scripts\local-setup.ps1
#
# Yêu cầu: Docker Desktop đang chạy, docker compose đã up

param(
    [string]$LocalStackUrl = "http://localhost:4566",
    [string]$AuthToken = "local-dev-token-abc123",
    [string]$QueueName = "triage-buffer-local"
)

$ErrorActionPreference = "Stop"
$env:AWS_ACCESS_KEY_ID = "test"
$env:AWS_SECRET_ACCESS_KEY = "test"
$env:AWS_DEFAULT_REGION = "us-east-1"

Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host " TF1 Triage Hub — Local Setup" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

# ── 1. Verify LocalStack is up ────────────────
Write-Host "[1/4] Checking LocalStack health..." -ForegroundColor Yellow
try {
    $health = Invoke-RestMethod "$LocalStackUrl/_localstack/health" -TimeoutSec 5
    Write-Host "  LocalStack OK — services: $($health.services.PSObject.Properties.Name -join ', ')" -ForegroundColor Green
} catch {
    Write-Error "LocalStack not reachable at $LocalStackUrl. Run: docker compose -f docker-compose.local.yml up -d"
}

# ── 2. Create SQS queues ──────────────────────
Write-Host "[2/4] Creating SQS queues on LocalStack..." -ForegroundColor Yellow
aws --endpoint-url=$LocalStackUrl sqs create-queue `
    --queue-name $QueueName `
    --region us-east-1 2>&1 | Out-Null
aws --endpoint-url=$LocalStackUrl sqs create-queue `
    --queue-name "$QueueName-dlq" `
    --region us-east-1 2>&1 | Out-Null

$queueUrl = (aws --endpoint-url=$LocalStackUrl sqs get-queue-url `
    --queue-name $QueueName `
    --region us-east-1 | ConvertFrom-Json).QueueUrl
Write-Host "  Queue URL: $queueUrl" -ForegroundColor Green

# ── 3. Create Secret ──────────────────────────
Write-Host "[3/4] Creating Secrets Manager secret..." -ForegroundColor Yellow
$secretValue = "{`"SERVICE_AUTH_TOKEN`":`"$AuthToken`"}"
aws --endpoint-url=$LocalStackUrl secretsmanager create-secret `
    --name "triage-hub/ai-engine" `
    --secret-string $secretValue `
    --region us-east-1 2>&1 | Out-Null
Write-Host "  Secret 'triage-hub/ai-engine' created" -ForegroundColor Green

# ── 4. Verify tf1-api health ──────────────────
Write-Host "[4/4] Checking tf1-api health..." -ForegroundColor Yellow
try {
    $engineHealth = Invoke-RestMethod "http://localhost:8080/healthz" -TimeoutSec 5
    Write-Host "  tf1-api: $($engineHealth.status) (service: $($engineHealth.service))" -ForegroundColor Green
} catch {
    Write-Warning "tf1-api not reachable — make sure Docker container is running (triage-tf1-api)"
}

# ── 5. Print env vars for Lambda testing ─────
Write-Host ""
Write-Host "========================================" -ForegroundColor Cyan
Write-Host " ENV VARS for Lambda local testing" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "Copy these to your terminal before running Lambda tests:" -ForegroundColor White
Write-Host ""
Write-Host "`$env:AWS_ACCESS_KEY_ID = 'test'" -ForegroundColor Gray
Write-Host "`$env:AWS_SECRET_ACCESS_KEY = 'test'" -ForegroundColor Gray
Write-Host "`$env:AWS_DEFAULT_REGION = 'us-east-1'" -ForegroundColor Gray
Write-Host "`$env:SQS_QUEUE_URL = '$queueUrl'" -ForegroundColor Gray
Write-Host "`$env:SERVICE_AUTH_TOKEN_ARN = 'arn:aws:secretsmanager:us-east-1:000000000000:secret:triage-hub/ai-engine'" -ForegroundColor Gray
Write-Host "`$env:AI_ENGINE_URL = 'http://localhost:8080/v1/triage'" -ForegroundColor Gray
Write-Host ""
Write-Host "Setup complete!" -ForegroundColor Green
