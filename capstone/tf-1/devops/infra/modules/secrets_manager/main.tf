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

# AI engine CONFIG (không phải credential) — tên path mà ESO của engine đọc
# (key: triage-hub/ai-engine). Token KHÔNG ở đây — token nằm ở secret standalone
# service_auth_token (khớp file teammate). Đây chỉ giữ config: model id, slack webhook, queue url.
resource "aws_secretsmanager_secret" "ai_engine" {
  name                    = "${var.project_name}/ai-engine"
  description             = "AI engine non-credential config (JSON)"
  recovery_window_in_days = var.environment == "prod" ? 30 : 0

  tags = { Name = "${var.project_name}/ai-engine" }
}

# JSON placeholder hợp lệ để ESO parse property. Điền giá trị thật qua put-secret-value.
resource "aws_secretsmanager_secret_version" "ai_engine" {
  secret_id = aws_secretsmanager_secret.ai_engine.id
  secret_string = jsonencode({
    BEDROCK_MODEL_ID  = "us.anthropic.claude-opus-4-8"
    SLACK_WEBHOOK_URL = "placeholder-change-me"
    SQS_QUEUE_URL     = "placeholder-change-me"
  })

  lifecycle {
    ignore_changes = [secret_string]
  }
}
