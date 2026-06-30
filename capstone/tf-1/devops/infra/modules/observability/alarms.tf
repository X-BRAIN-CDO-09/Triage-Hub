# =============================================================================
# SNS Topic & Subscriptions for Alarms
# =============================================================================

resource "aws_sns_topic" "alerts" {
  count = var.enable_notifications ? 1 : 0
  name  = "${var.project_name}-alerts-${var.environment}"

  tags = {
    Name        = "${var.project_name}-alerts-${var.environment}"
    Environment = var.environment
  }
}

resource "aws_sns_topic_subscription" "email" {
  count     = var.enable_notifications && var.notification_email != "" ? 1 : 0
  topic_arn = aws_sns_topic.alerts[0].arn
  protocol  = "email"
  endpoint  = var.notification_email
}

resource "aws_sns_topic_subscription" "sms" {
  count     = var.enable_notifications && var.notification_sms != "" ? 1 : 0
  topic_arn = aws_sns_topic.alerts[0].arn
  protocol  = "sms"
  endpoint  = var.notification_sms
}

locals {
  alarm_actions = var.enable_notifications ? [aws_sns_topic.alerts[0].arn] : []
}

# =============================================================================
# API Gateway Alarms
# =============================================================================

resource "aws_cloudwatch_metric_alarm" "api_gw_latency" {
  count               = var.api_gateway_name != "" ? 1 : 0
  alarm_name          = "${var.project_name}-apigw-latency-high"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "Latency"
  namespace           = "AWS/ApiGateway"
  period              = 60
  statistic           = "Average"
  threshold           = var.alarm_thresholds.api_gw_latency
  alarm_description   = "API Gateway latency is too high"
  alarm_actions       = local.alarm_actions
  ok_actions          = local.alarm_actions

  dimensions = {
    ApiName = var.api_gateway_name
  }
}

resource "aws_cloudwatch_metric_alarm" "api_gw_4xx" {
  count               = var.api_gateway_name != "" ? 1 : 0
  alarm_name          = "${var.project_name}-apigw-4xx-high"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "4XXError"
  namespace           = "AWS/ApiGateway"
  period              = 60
  statistic           = "Sum"
  threshold           = var.alarm_thresholds.api_gw_4xx_rate
  alarm_description   = "API Gateway 4XX error rate is too high"
  alarm_actions       = local.alarm_actions
  ok_actions          = local.alarm_actions

  dimensions = {
    ApiName = var.api_gateway_name
  }
}

resource "aws_cloudwatch_metric_alarm" "api_gw_5xx" {
  count               = var.api_gateway_name != "" ? 1 : 0
  alarm_name          = "${var.project_name}-apigw-5xx-high"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "5XXError"
  namespace           = "AWS/ApiGateway"
  period              = 60
  statistic           = "Sum"
  threshold           = var.alarm_thresholds.api_gw_5xx_rate
  alarm_description   = "API Gateway 5XX error rate is too high"
  alarm_actions       = local.alarm_actions
  ok_actions          = local.alarm_actions

  dimensions = {
    ApiName = var.api_gateway_name
  }
}

# =============================================================================
# Lambda Alarms
# =============================================================================

resource "aws_cloudwatch_metric_alarm" "lambda_errors" {
  for_each            = toset(var.lambda_functions)
  alarm_name          = "${each.value}-errors-high"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "Errors"
  namespace           = "AWS/Lambda"
  period              = 60
  statistic           = "Sum"
  threshold           = var.alarm_thresholds.lambda_error_rate
  alarm_description   = "Lambda ${each.value} error rate is too high"
  alarm_actions       = local.alarm_actions
  ok_actions          = local.alarm_actions

  dimensions = {
    FunctionName = each.value
  }
}

resource "aws_cloudwatch_metric_alarm" "lambda_duration" {
  for_each            = toset(var.lambda_functions)
  alarm_name          = "${each.value}-duration-high"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "Duration"
  namespace           = "AWS/Lambda"
  period              = 60
  statistic           = "Average"
  threshold           = var.alarm_thresholds.lambda_duration
  alarm_description   = "Lambda ${each.value} duration is too high"
  alarm_actions       = local.alarm_actions
  ok_actions          = local.alarm_actions

  dimensions = {
    FunctionName = each.value
  }
}

resource "aws_cloudwatch_metric_alarm" "lambda_throttles" {
  for_each            = toset(var.lambda_functions)
  alarm_name          = "${each.value}-throttles-high"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "Throttles"
  namespace           = "AWS/Lambda"
  period              = 60
  statistic           = "Sum"
  threshold           = var.alarm_thresholds.lambda_throttle_rate
  alarm_description   = "Lambda ${each.value} throttles is too high"
  alarm_actions       = local.alarm_actions
  ok_actions          = local.alarm_actions

  dimensions = {
    FunctionName = each.value
  }
}

# =============================================================================
# SQS Alarms
# =============================================================================

resource "aws_cloudwatch_metric_alarm" "sqs_queue_depth" {
  for_each            = toset(var.sqs_queues)
  alarm_name          = "${each.value}-queue-depth-high"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "ApproximateNumberOfMessagesVisible"
  namespace           = "AWS/SQS"
  period              = 60
  statistic           = "Maximum"
  threshold           = var.alarm_thresholds.sqs_queue_depth
  alarm_description   = "SQS Queue ${each.value} depth is too high"
  alarm_actions       = local.alarm_actions
  ok_actions          = local.alarm_actions

  dimensions = {
    QueueName = each.value
  }
}

resource "aws_cloudwatch_metric_alarm" "sqs_oldest_message" {
  for_each            = toset(var.sqs_queues)
  alarm_name          = "${each.value}-oldest-message-high"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "ApproximateAgeOfOldestMessage"
  namespace           = "AWS/SQS"
  period              = 60
  statistic           = "Maximum"
  threshold           = var.alarm_thresholds.sqs_oldest_message
  alarm_description   = "SQS Queue ${each.value} oldest message age is too high"
  alarm_actions       = local.alarm_actions
  ok_actions          = local.alarm_actions

  dimensions = {
    QueueName = each.value
  }
}

# =============================================================================
# DynamoDB Alarms
# =============================================================================

resource "aws_cloudwatch_metric_alarm" "dynamodb_throttles" {
  count               = var.dynamodb_table_name != "" ? 1 : 0
  alarm_name          = "${var.dynamodb_table_name}-throttles-high"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "ThrottledRequests"
  namespace           = "AWS/DynamoDB"
  period              = 60
  statistic           = "Sum"
  threshold           = var.alarm_thresholds.dynamodb_throttle
  alarm_description   = "DynamoDB Table ${var.dynamodb_table_name} throttled requests is too high"
  alarm_actions       = local.alarm_actions
  ok_actions          = local.alarm_actions

  dimensions = {
    TableName = var.dynamodb_table_name
  }
}

resource "aws_cloudwatch_metric_alarm" "dynamodb_system_errors" {
  count               = var.dynamodb_table_name != "" ? 1 : 0
  alarm_name          = "${var.dynamodb_table_name}-system-errors-high"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "SystemErrors"
  namespace           = "AWS/DynamoDB"
  period              = 60
  statistic           = "Sum"
  threshold           = var.alarm_thresholds.dynamodb_sys_error
  alarm_description   = "DynamoDB Table ${var.dynamodb_table_name} system errors is too high"
  alarm_actions       = local.alarm_actions
  ok_actions          = local.alarm_actions

  dimensions = {
    TableName = var.dynamodb_table_name
  }
}
