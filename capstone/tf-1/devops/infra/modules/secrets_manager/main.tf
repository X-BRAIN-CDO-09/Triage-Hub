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
