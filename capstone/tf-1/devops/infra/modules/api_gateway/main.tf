# =============================================================================
# API Gateway Module
# =============================================================================

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
resource "aws_api_gateway_integration" "this" {
  for_each = var.integrations

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

# 4. Lambda Permissions
resource "aws_lambda_permission" "apigw" {
  for_each = var.integrations

  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = each.value.lambda_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_api_gateway_rest_api.this.execution_arn}/*/*"
}

# 5. Deployment & Stage
resource "aws_api_gateway_deployment" "this" {
  rest_api_id = aws_api_gateway_rest_api.this.id

  lifecycle {
    create_before_destroy = true
  }

  depends_on = [
    aws_api_gateway_integration.this
  ]
}

resource "aws_api_gateway_stage" "this" {
  deployment_id = aws_api_gateway_deployment.this.id
  rest_api_id   = aws_api_gateway_rest_api.this.id
  stage_name    = var.environment
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

data "aws_region" "current" {}
