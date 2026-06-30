# =============================================================================
# Lambda — Best Practice Sample
# Pattern: for_each multi-lambda, auto-zip, dynamic VPC/env, per-lambda IAM
# =============================================================================

data "aws_region" "current" {}
data "aws_partition" "current" {}

locals {
  # Lọc lambda có source_dir để auto-zip
  lambdas_with_source_dir = {
    for k, v in var.lambdas : k => v if v.source_dir != null
  }

  # Lọc lambda chạy trong VPC
  lambdas_in_vpc = {
    for k, v in var.lambdas : k => v
    if v.vpc_subnet_ids != null || var.default_vpc_subnet_ids != null
  }

  # Lọc lambda có custom IAM policy
  lambdas_with_custom_policies = {
    for k, v in var.lambdas : k => v
    if v.iam_policy_statements != null && length(v.iam_policy_statements) > 0
  }
}

# 1. Auto-zip source code
data "archive_file" "lambda_zip" {
  for_each    = local.lambdas_with_source_dir
  type        = "zip"
  source_dir  = each.value.source_dir
  output_path = "${path.module}/files/${each.key}_payload.zip"
}

# 2. IAM Role per-lambda
resource "aws_iam_role" "this" {
  for_each = var.lambdas

  name = "${var.project_name}-lambda-${each.key}-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })

  tags = { Name = "${var.project_name}-lambda-${each.key}-role" }
}

# 3. Basic execution policy (dùng partition thay vì hardcode)
resource "aws_iam_role_policy_attachment" "basic_execution" {
  for_each   = var.lambdas
  role       = aws_iam_role.this[each.key].name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# 4. VPC execution policy (chỉ attach khi lambda chạy trong VPC)
resource "aws_iam_role_policy_attachment" "vpc_execution" {
  for_each   = local.lambdas_in_vpc
  role       = aws_iam_role.this[each.key].name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"
}

# 4b. X-Ray Daemon Write Access
resource "aws_iam_role_policy_attachment" "xray_access" {
  for_each   = var.lambdas
  role       = aws_iam_role.this[each.key].name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AWSXRayDaemonWriteAccess"
}

# 5. Custom IAM policy per-lambda
resource "aws_iam_policy" "custom" {
  for_each = local.lambdas_with_custom_policies
  name     = "${var.project_name}-lambda-${each.key}-policy"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      for stmt in each.value.iam_policy_statements : {
        Effect   = stmt.effect
        Action   = stmt.actions
        Resource = stmt.resources
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "custom" {
  for_each   = local.lambdas_with_custom_policies
  role       = aws_iam_role.this[each.key].name
  policy_arn = aws_iam_policy.custom[each.key].arn
}

# 6. Lambda Function
resource "aws_lambda_function" "this" {
  for_each = var.lambdas

  function_name = "${var.project_name}-${each.key}"
  handler       = each.value.handler
  runtime       = each.value.runtime
  memory_size   = each.value.memory_size
  timeout       = each.value.timeout
  role          = aws_iam_role.this[each.key].arn

  # Concurrency guard — tránh ăn hết account quota
  reserved_concurrent_executions = each.value.reserved_concurrency

  # Source code (priority: source_dir > local_zip > s3)
  filename         = each.value.source_dir != null ? data.archive_file.lambda_zip[each.key].output_path : each.value.local_zip_path
  source_code_hash = each.value.source_dir != null ? data.archive_file.lambda_zip[each.key].output_base64sha256 : null
  s3_bucket        = each.value.s3_bucket
  s3_key           = each.value.s3_key

  dynamic "environment" {
    for_each = each.value.environment_variables != null && length(each.value.environment_variables) > 0 ? [1] : []
    content {
      variables = each.value.environment_variables
    }
  }

  dynamic "vpc_config" {
    for_each = (each.value.vpc_subnet_ids != null || var.default_vpc_subnet_ids != null) ? [1] : []
    content {
      subnet_ids         = coalesce(each.value.vpc_subnet_ids, var.default_vpc_subnet_ids)
      security_group_ids = coalesce(each.value.vpc_security_group_ids, var.default_vpc_security_group_ids)
    }
  }

  tracing_config {
    mode = "Active"
  }

  lifecycle {
    ignore_changes = [
      filename,
      source_code_hash,
      s3_bucket,
      s3_key
    ]
  }

  tags = { Name = "${var.project_name}-${each.key}" }
}
