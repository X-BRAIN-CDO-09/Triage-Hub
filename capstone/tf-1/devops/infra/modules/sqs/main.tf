# =============================================================================
# SQS Queues & DLQs Module
# =============================================================================

# 1. Dead Letter Queues (DLQ)
resource "aws_sqs_queue" "dlq" {
  for_each = var.queues

  name                      = "${var.project_name}-${each.key}-dlq"
  message_retention_seconds = 1209600 # 14 days (max retention for debugging)

  tags = {
    Name = "${var.project_name}-${each.key}-dlq"
  }
}

# 2. Main Queues
resource "aws_sqs_queue" "this" {
  for_each = var.queues

  name                       = "${var.project_name}-${each.key}"
  visibility_timeout_seconds = each.value.visibility_timeout_seconds
  message_retention_seconds  = each.value.message_retention_seconds

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.dlq[each.key].arn
    maxReceiveCount     = each.value.max_receive_count
  })

  tags = {
    Name = "${var.project_name}-${each.key}"
  }
}
