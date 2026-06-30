# =============================================================================
# API Gateway Module
# =============================================================================

data "aws_region" "current" {}
data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

locals {
  lambda_integrations = {
    for k, v in var.integrations : k => v
    if try(v.integration_type, "lambda_proxy") == "lambda_proxy"
  }

  sqs_integrations = {
    for k, v in var.integrations : k => v
    if try(v.integration_type, "lambda_proxy") == "sqs_send_message"
  }
}

resource "aws_api_gateway_rest_api" "this" {
  name        = "${var.project_name}-apigw-${var.environment}"
  description = "API Gateway for Triage Hub ${var.environment}"

  endpoint_configuration {
    types = ["REGIONAL"]
  }
}

# 1. API Resources
resource "aws_api_gateway_resource" "this" {
  for_each = var.integrations

  rest_api_id = aws_api_gateway_rest_api.this.id
  parent_id   = aws_api_gateway_rest_api.this.root_resource_id
  path_part   = each.value.path_part
}

# 2. API Methods
resource "aws_api_gateway_method" "this" {
  for_each = var.integrations

  rest_api_id      = aws_api_gateway_rest_api.this.id
  resource_id      = aws_api_gateway_resource.this[each.key].id
  http_method      = each.value.http_method
  authorization    = "NONE"
  api_key_required = each.value.api_key_required
}

# 3. Lambda Integrations
resource "aws_api_gateway_integration" "lambda_proxy" {
  for_each = local.lambda_integrations

  rest_api_id             = aws_api_gateway_rest_api.this.id
  resource_id             = aws_api_gateway_resource.this[each.key].id
  http_method             = aws_api_gateway_method.this[each.key].http_method
  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = each.value.lambda_function_arn

  depends_on = [
    aws_api_gateway_method.this
  ]
}

# 4. SQS Integrations
resource "aws_iam_role" "apigw_sqs" {
  count = length(local.sqs_integrations) > 0 ? 1 : 0

  name = "${var.project_name}-apigw-sqs-role-${var.environment}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "apigateway.amazonaws.com"
        }
      }
    ]
  })
}

resource "aws_iam_role_policy" "apigw_sqs" {
  count = length(local.sqs_integrations) > 0 ? 1 : 0

  name = "${var.project_name}-apigw-sqs-policy-${var.environment}"
  role = aws_iam_role.apigw_sqs[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["sqs:SendMessage"]
        Resource = [for integration in values(local.sqs_integrations) : integration.sqs_queue_arn]
      }
    ]
  })
}

resource "aws_api_gateway_integration" "sqs_send_message" {
  for_each = local.sqs_integrations

  rest_api_id             = aws_api_gateway_rest_api.this.id
  resource_id             = aws_api_gateway_resource.this[each.key].id
  http_method             = aws_api_gateway_method.this[each.key].http_method
  integration_http_method = "POST"
  type                    = "AWS"
  credentials             = aws_iam_role.apigw_sqs[0].arn
  uri                     = "arn:${data.aws_partition.current.partition}:apigateway:${data.aws_region.current.name}:sqs:path/${data.aws_caller_identity.current.account_id}/${each.value.sqs_queue_name}"

  request_parameters = {
    "integration.request.header.Content-Type" = "'application/x-www-form-urlencoded'"
  }

  request_templates = {
    "application/json" = <<-EOT
#set($attributeIndex = 1)##
Action=SendMessage&MessageBody=$util.urlEncode($input.body)#if($input.params('X-Tenant-Id') != "")&MessageAttribute.$${attributeIndex}.Name=TenantId&MessageAttribute.$${attributeIndex}.Value.DataType=String&MessageAttribute.$${attributeIndex}.Value.StringValue=$util.urlEncode($input.params('X-Tenant-Id'))#set($attributeIndex = $attributeIndex + 1)#end#if($input.params('X-Correlation-Id') != "")&MessageAttribute.$${attributeIndex}.Name=CorrelationId&MessageAttribute.$${attributeIndex}.Value.DataType=String&MessageAttribute.$${attributeIndex}.Value.StringValue=$util.urlEncode($input.params('X-Correlation-Id'))#set($attributeIndex = $attributeIndex + 1)#end#if($input.params('X-Source') != "")&MessageAttribute.$${attributeIndex}.Name=Source&MessageAttribute.$${attributeIndex}.Value.DataType=String&MessageAttribute.$${attributeIndex}.Value.StringValue=$util.urlEncode($input.params('X-Source'))#end#set($tg = $input.params('X-Tenant-Id'))#if($tg == "")#set($tg = "default-group")#end&MessageGroupId=$util.urlEncode($tg)
    EOT
  }

  depends_on = [
    aws_api_gateway_method.this,
    aws_iam_role_policy.apigw_sqs
  ]
}

resource "aws_api_gateway_method_response" "sqs_send_message_200" {
  for_each = local.sqs_integrations

  rest_api_id = aws_api_gateway_rest_api.this.id
  resource_id = aws_api_gateway_resource.this[each.key].id
  http_method = aws_api_gateway_method.this[each.key].http_method
  status_code = "200"
}

resource "aws_api_gateway_integration_response" "sqs_send_message_200" {
  for_each = local.sqs_integrations

  rest_api_id = aws_api_gateway_rest_api.this.id
  resource_id = aws_api_gateway_resource.this[each.key].id
  http_method = aws_api_gateway_method.this[each.key].http_method
  status_code = aws_api_gateway_method_response.sqs_send_message_200[each.key].status_code

  depends_on = [
    aws_api_gateway_integration.sqs_send_message
  ]
}

# 5. Lambda Permissions
resource "aws_lambda_permission" "apigw" {
  for_each = local.lambda_integrations

  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = each.value.lambda_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_api_gateway_rest_api.this.execution_arn}/*/*"
}

# 6. Deployment & Stage
resource "aws_api_gateway_deployment" "this" {
  rest_api_id = aws_api_gateway_rest_api.this.id

  lifecycle {
    create_before_destroy = true
  }

  depends_on = [
    aws_api_gateway_integration.lambda_proxy,
    aws_api_gateway_integration.sqs_send_message,
    aws_api_gateway_integration_response.sqs_send_message_200
  ]
}

resource "aws_cloudwatch_log_group" "apigw" {
  name              = "API-Gateway-Execution-Logs_${aws_api_gateway_rest_api.this.id}/${var.environment}"
  retention_in_days = 7
}

resource "aws_api_gateway_stage" "this" {
  deployment_id = aws_api_gateway_deployment.this.id
  rest_api_id   = aws_api_gateway_rest_api.this.id
  stage_name    = var.environment

  depends_on = [aws_api_gateway_account.this]

  xray_tracing_enabled = true

  access_log_settings {
    destination_arn = aws_cloudwatch_log_group.apigw.arn
    format = jsonencode({
      requestId      = "$context.requestId"
      ip             = "$context.identity.sourceIp"
      caller         = "$context.identity.caller"
      user           = "$context.identity.user"
      requestTime    = "$context.requestTime"
      httpMethod     = "$context.httpMethod"
      resourcePath   = "$context.resourcePath"
      status         = "$context.status"
      protocol       = "$context.protocol"
      responseLength = "$context.responseLength"
    })
  }
}

resource "aws_api_gateway_method_settings" "all" {
  rest_api_id = aws_api_gateway_rest_api.this.id
  stage_name  = aws_api_gateway_stage.this.stage_name
  method_path = "*/*"

  settings {
    metrics_enabled = true
    logging_level   = "INFO"
  }
}

# 6. API Key (Tạo API Key ngẫu nhiên cho Tenant/Client)
resource "aws_api_gateway_api_key" "this" {
  name        = "${var.project_name}-key-${var.environment}"
  description = "Primary API Key for Triage Hub Ingestion"
  enabled     = true
}

# 7. Usage Plan (Giới hạn Quota & Rate Limit tránh Noisy Neighbor)
resource "aws_api_gateway_usage_plan" "this" {
  name        = "${var.project_name}-usage-plan-${var.environment}"
  description = "Usage plan with rate limit for Triage Hub"

  api_stages {
    api_id = aws_api_gateway_rest_api.this.id
    stage  = aws_api_gateway_stage.this.stage_name
  }

  throttle_settings {
    burst_limit = 100
    rate_limit  = 60 # 60 requests/phút (hoặc giây theo cấu hình AWS)
  }

  quota_settings {
    limit  = 100000
    offset = 0
    period = "MONTH"
  }
}

# 8. Associate API Key with Usage Plan
resource "aws_api_gateway_usage_plan_key" "this" {
  key_id        = aws_api_gateway_api_key.this.id
  key_type      = "API_KEY"
  usage_plan_id = aws_api_gateway_usage_plan.this.id
}

# 9. API Gateway Account Settings for CloudWatch Logging
resource "aws_iam_role" "apigw_cloudwatch" {
  name = "${var.project_name}-apigw-cw-role-${var.environment}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "apigateway.amazonaws.com"
        }
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "apigw_cloudwatch" {
  role       = aws_iam_role.apigw_cloudwatch.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonAPIGatewayPushToCloudWatchLogs"
}

resource "aws_api_gateway_account" "this" {
  cloudwatch_role_arn = aws_iam_role.apigw_cloudwatch.arn
}
