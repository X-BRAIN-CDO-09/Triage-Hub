# =============================================================================
# DynamoDB Shared Table for Tenant Configurations and Audit Trail
# =============================================================================

resource "aws_dynamodb_table" "this" {
  name         = "${var.project_name}-state-${var.environment}"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "PK"
  range_key    = "SK"

  attribute {
    name = "PK"
    type = "S"
  }

  attribute {
    name = "SK"
    type = "S"
  }

  point_in_time_recovery {
    enabled = var.environment == "prod"
  }

  server_side_encryption {
    enabled = true
  }

  tags = {
    Name = "${var.project_name}-state-${var.environment}"
  }
}
