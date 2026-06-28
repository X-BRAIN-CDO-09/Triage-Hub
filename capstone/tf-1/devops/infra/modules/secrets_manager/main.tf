# =============================================================================
# Secrets Manager Module
# =============================================================================

resource "aws_secretsmanager_secret" "this" {
  for_each = var.secrets

  name                    = "${var.project_name}-${each.key}-${var.environment}"
  description             = each.value
  recovery_window_in_days = var.environment == "prod" ? 30 : 0

  tags = {
    Name = "${var.project_name}-${each.key}-${var.environment}"
  }
}

# Khởi tạo version rỗng để tránh ứng dụng bị crash khi fetch secret chưa tồn tại
resource "aws_secretsmanager_secret_version" "this" {
  for_each = var.secrets

  secret_id     = aws_secretsmanager_secret.this[each.key].id
  secret_string = "placeholder-change-me"

  lifecycle {
    ignore_changes = [
      secret_string,
    ]
  }
}

# AI engine combined config — tên đúng path mà External Secrets Operator của engine đọc
# (key: triage-hub/ai-engine). Cả engine (qua ESO) lẫn push-to-ai Lambda đọc CÙNG secret
# này → 1 nguồn token duy nhất, hết lệch token (gotcha #3).
resource "aws_secretsmanager_secret" "ai_engine" {
  name                    = "${var.project_name}/ai-engine"
  description             = "AI engine combined runtime config (JSON)"
  recovery_window_in_days = var.environment == "prod" ? 30 : 0

  tags = { Name = "${var.project_name}/ai-engine" }
}

# JSON placeholder hợp lệ để ESO parse được property trước khi điền giá trị thật.
# Giá trị thật điền qua: aws secretsmanager put-secret-value (không nằm trong TF state).
resource "aws_secretsmanager_secret_version" "ai_engine" {
  secret_id = aws_secretsmanager_secret.ai_engine.id
  secret_string = jsonencode({
    SERVICE_AUTH_TOKEN = "placeholder-change-me"
    BEDROCK_MODEL_ID   = "us.anthropic.claude-opus-4-8"
    SLACK_WEBHOOK_URL  = "placeholder-change-me"
    SQS_QUEUE_URL      = "placeholder-change-me"
  })

  lifecycle {
    ignore_changes = [secret_string]
  }
}
