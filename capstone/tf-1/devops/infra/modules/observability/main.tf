# =============================================================================
# Observability Module - CloudWatch Dashboard
# =============================================================================

locals {
  all_invocations = concat(["api_c"], [for i, _ in var.lambda_functions: "li_${i}"])
  all_errors      = concat(["api_e"], [for i, _ in var.lambda_functions: "le_${i}"])
  
  # --- 1. HEALTH OVERVIEW ---
  health_overview_header = [{
    type   = "text"
    x      = 0
    y      = 0
    width  = 24
    height = 1
    properties = { markdown = "## Health Overview" }
  }]

  health_overview_widgets = [
    {
      type = "metric", x = 0, y = 1, width = 6, height = 4
      properties = {
        metrics = [["AWS/ApiGateway", "Count", "ApiName", var.api_gateway_name, { "stat": "Sum" }]]
        view = "singleValue", region = var.aws_region, title = "API Request Count", period = 300
      }
    },
    {
      type = "metric", x = 6, y = 1, width = 6, height = 4
      properties = {
        metrics = [["AWS/ApiGateway", "Latency", "ApiName", var.api_gateway_name, { "stat": "Average" }]]
        view = "singleValue", region = var.aws_region, title = "API Latency", period = 300
      }
    },
    {
      type = "metric", x = 12, y = 1, width = 6, height = 4
      properties = {
        metrics = concat(
          [for i, func in var.lambda_functions : ["AWS/Lambda", "Errors", "FunctionName", func, { "stat": "Sum", "id": "e_${i}", "visible": false }]],
          [[ { "expression": "SUM(METRICS())", "label": "Total Errors", "id": "e_total", "stat": "Sum" } ]]
        )
        view = "singleValue", region = var.aws_region, title = "Lambda Errors", period = 300
      }
    },
    {
      type = "metric", x = 18, y = 1, width = 6, height = 4
      properties = {
        metrics = concat(
          [for i, func in var.lambda_functions : ["AWS/Lambda", "Duration", "FunctionName", func, { "stat": "Average", "id": "d_${i}", "visible": false }]],
          [[ { "expression": "AVG(METRICS())", "label": "Avg Duration", "id": "d_avg", "stat": "Average" } ]]
        )
        view = "singleValue", region = var.aws_region, title = "Lambda Duration", period = 300
      }
    },
    {
      type = "metric", x = 0, y = 5, width = 6, height = 4
      properties = {
        metrics = concat(
          [for i, q in var.sqs_queues : ["AWS/SQS", "ApproximateNumberOfMessagesVisible", "QueueName", q, { "stat": "Maximum", "id": "q_${i}", "visible": false }]],
          [[ { "expression": "MAX(METRICS())", "label": "Max Queue Depth", "id": "q_max", "stat": "Maximum" } ]]
        )
        view = "singleValue", region = var.aws_region, title = "Queue Depth", period = 300
      }
    },
    {
      type = "metric", x = 6, y = 5, width = 6, height = 4
      properties = {
        metrics = concat(
          [for i, q in var.sqs_queues : ["AWS/SQS", "ApproximateAgeOfOldestMessage", "QueueName", q, { "stat": "Maximum", "id": "a_${i}", "visible": false }]],
          [[ { "expression": "MAX(METRICS())", "label": "Oldest Message Age", "id": "a_max", "stat": "Maximum" } ]]
        )
        view = "singleValue", region = var.aws_region, title = "Oldest Message Age", period = 300
      }
    },
    {
      type = "metric", x = 12, y = 5, width = 6, height = 4
      properties = {
        metrics = [["AWS/DynamoDB", "ThrottledRequests", "TableName", var.dynamodb_table_name, { "stat": "Sum" }]]
        view = "singleValue", region = var.aws_region, title = "DynamoDB Throttled Requests", period = 300
      }
    },
    {
      type = "metric", x = 18, y = 5, width = 6, height = 4
      properties = {
        metrics = concat(
          [
            ["AWS/ApiGateway", "Count", "ApiName", var.api_gateway_name, { "stat": "Sum", "id": "api_c", "visible": false }],
            ["AWS/ApiGateway", "5XXError", "ApiName", var.api_gateway_name, { "stat": "Sum", "id": "api_e", "visible": false }]
          ],
          [for i, func in var.lambda_functions : ["AWS/Lambda", "Invocations", "FunctionName", func, { "stat": "Sum", "id": "li_${i}", "visible": false }]],
          [for i, func in var.lambda_functions : ["AWS/Lambda", "Errors", "FunctionName", func, { "stat": "Sum", "id": "le_${i}", "visible": false }]],
          [[ { "expression": "IF((${join(" + ", local.all_invocations)}) == 0, 0, (${join(" + ", local.all_errors)}) / (${join(" + ", local.all_invocations)}) * 100)", "label": "Overall Error Rate %", "id": "err_rate", "stat": "Average" } ]]
        )
        view = "singleValue", region = var.aws_region, title = "Overall Error Rate", period = 300
      }
    }
  ]

  # --- 2. PIPELINE ---
  pipeline_header = [{
    type   = "text", x = 0, y = 9, width = 24, height = 1
    properties = { markdown = "## End-to-End Processing Pipeline" }
  }]

  pipeline_widgets = [
    {
      type = "metric", x = 0, y = 10, width = 3, height = 6
      properties = {
        metrics = [["AWS/ApiGateway", "Count", "ApiName", var.api_gateway_name, { "stat": "Sum" }]]
        view = "timeSeries", region = var.aws_region, title = "1. API Requests", period = 300
      }
    },
    {
      type = "metric", x = 3, y = 10, width = 4, height = 6
      properties = {
        metrics = [["AWS/Lambda", "Invocations", "FunctionName", "${var.project_name}-alert-ingest", { "stat": "Sum" }]]
        view = "timeSeries", region = var.aws_region, title = "2. Alert Ingest", period = 300
      }
    },
    {
      type = "metric", x = 7, y = 10, width = 4, height = 6
      properties = {
        metrics = [["AWS/SQS", "NumberOfMessagesSent", "QueueName", "${var.project_name}-buffer-queue", { "stat": "Sum" }]]
        view = "timeSeries", region = var.aws_region, title = "3. Buffer Queue", period = 300
      }
    },
    {
      type = "metric", x = 11, y = 10, width = 4, height = 6
      properties = {
        metrics = [["AWS/Lambda", "Invocations", "FunctionName", "${var.project_name}-jira-dispatcher", { "stat": "Sum" }]]
        view = "timeSeries", region = var.aws_region, title = "4. Dispatcher", period = 300
      }
    },
    {
      type = "metric", x = 15, y = 10, width = 4, height = 6
      properties = {
        metrics = [["AWS/SQS", "NumberOfMessagesSent", "QueueName", "${var.project_name}-dispatch-queue", { "stat": "Sum" }]]
        view = "timeSeries", region = var.aws_region, title = "5. Dispatch Queue", period = 300
      }
    },
    {
      type = "metric", x = 19, y = 10, width = 5, height = 6
      properties = {
        metrics = [
          ["AWS/Lambda", "Invocations", "FunctionName", "${var.project_name}-notify-dispatcher", { "stat": "Sum" }],
          ["AWS/DynamoDB", "ConsumedWriteCapacityUnits", "TableName", var.dynamodb_table_name, { "stat": "Sum" }]
        ]
        view = "timeSeries", region = var.aws_region, title = "6. Notify & DynamoDB", period = 300
      }
    }
  ]

  # --- 3. DETAILED METRICS ---
  detailed_header = [{
    type   = "text", x = 0, y = 16, width = 24, height = 1
    properties = { markdown = "## Detailed Service Metrics" }
  }]

  api_gw_widget = var.api_gateway_name != "" ? [{
    type = "metric", x = 0, y = 17, width = 24, height = 6
    properties = {
      metrics = [
        ["AWS/ApiGateway", "Count", "ApiName", var.api_gateway_name, { "stat": "Sum" }],
        [".", "4XXError", ".", ".", { "stat": "Sum" }],
        [".", "5XXError", ".", ".", { "stat": "Sum" }],
        [".", "Latency", ".", ".", { "stat": "Average" }],
        [".", "IntegrationLatency", ".", ".", { "stat": "Average" }],
        [".", "CacheHitCount", ".", ".", { "stat": "Sum" }],
        [".", "CacheMissCount", ".", ".", { "stat": "Sum" }]
      ]
      view = "timeSeries", region = var.aws_region, title = "API Gateway: ${var.api_gateway_name}", period = 300
    }
  }] : []

  lambda_widgets = [
    for i, func_name in var.lambda_functions : {
      type = "metric", x = (i % 2) * 12, y = 23 + floor(i / 2) * 6, width = 12, height = 6
      properties = {
        metrics = [
          ["AWS/Lambda", "Invocations", "FunctionName", func_name, { "stat": "Sum", "id": "inv" }],
          [".", "Errors", ".", ".", { "stat": "Sum", "id": "err" }],
          [".", "Throttles", ".", ".", { "stat": "Sum" }],
          [".", "ConcurrentExecutions", ".", ".", { "stat": "Maximum" }],
          [".", "Duration", ".", ".", { "stat": "Average" }],
          [".", "Duration", ".", ".", { "stat": "Maximum" }],
          [".", "IteratorAge", ".", ".", { "stat": "Maximum" }],
          [{ "expression": "IF(inv == 0, 100, 100 - (err / inv * 100))", "label": "Success Rate %", "id": "success_rate", "stat": "Average" }],
          [{ "expression": "IF(inv == 0, 0, err / inv * 100)", "label": "Error Rate %", "id": "error_rate", "stat": "Average", "visible": false }]
        ]
        view = "timeSeries", region = var.aws_region, title = "Lambda: ${func_name}", period = 300
      }
    }
  ]

  sqs_y_offset = 23 + ceil(length(var.lambda_functions) / 2) * 6
  sqs_widgets = [
    for i, queue_name in var.sqs_queues : {
      type = "metric", x = (i % 2) * 12, y = local.sqs_y_offset + floor(i / 2) * 6, width = 12, height = 6
      properties = {
        metrics = [
          ["AWS/SQS", "NumberOfMessagesSent", "QueueName", queue_name, { "stat": "Sum" }],
          [".", "NumberOfMessagesReceived", ".", ".", { "stat": "Sum" }],
          [".", "ApproximateNumberOfMessagesVisible", ".", ".", { "stat": "Maximum" }],
          [".", "ApproximateAgeOfOldestMessage", ".", ".", { "stat": "Maximum" }],
          [".", "ApproximateNumberOfMessagesNotVisible", ".", ".", { "stat": "Maximum" }],
          [".", "NumberOfMessagesDeleted", ".", ".", { "stat": "Sum" }],
          [".", "NumberOfEmptyReceives", ".", ".", { "stat": "Sum" }]
        ]
        view = "timeSeries", region = var.aws_region, title = "SQS: ${queue_name}", period = 300
      }
    }
  ]

  dynamo_y_offset = local.sqs_y_offset + ceil(length(var.sqs_queues) / 2) * 6
  dynamodb_widget = var.dynamodb_table_name != "" ? [{
    type = "metric", x = 0, y = local.dynamo_y_offset, width = 24, height = 6
    properties = {
      metrics = [
        ["AWS/DynamoDB", "ConsumedReadCapacityUnits", "TableName", var.dynamodb_table_name, { "stat": "Sum" }],
        [".", "ConsumedWriteCapacityUnits", ".", ".", { "stat": "Sum" }],
        [".", "SystemErrors", ".", ".", { "stat": "Sum" }],
        [".", "SuccessfulRequestLatency", ".", ".", { "stat": "Average" }],
        [".", "ThrottledRequests", ".", ".", { "stat": "Sum" }],
        [".", "UserErrors", ".", ".", { "stat": "Sum" }],
        [".", "ConditionalCheckFailedRequests", ".", ".", { "stat": "Sum" }]
      ]
      view = "timeSeries", region = var.aws_region, title = "DynamoDB: ${var.dynamodb_table_name}", period = 300
    }
  }] : []

  eks_y_offset = local.dynamo_y_offset + 6
  eks_widget = var.eks_cluster_name != "" ? [{
    type = "metric", x = 0, y = local.eks_y_offset, width = 24, height = 6
    properties = {
      metrics = [
        ["ContainerInsights", "node_cpu_utilization", "ClusterName", var.eks_cluster_name, { "stat": "Average" }],
        [".", "node_memory_utilization", ".", ".", { "stat": "Average" }],
        [".", "pod_number_of_container_restarts", ".", ".", { "stat": "Sum" }],
        [".", "node_status_condition_ready", ".", ".", { "stat": "Average" }]
      ]
      view = "timeSeries", region = var.aws_region, title = "EKS Cluster: ${var.eks_cluster_name} (Requires Container Insights)", period = 300
    }
  }] : []

  # --- 4. CLOUDWATCH LOGS INSIGHTS ---
  logs_y_offset = local.eks_y_offset + 6
  logs_header = [{
    type   = "text", x = 0, y = local.logs_y_offset, width = 24, height = 1
    properties = { markdown = "## CloudWatch Logs Insights" }
  }]

  log_sources = join(" | ", [for func in var.lambda_functions : "SOURCE '/aws/lambda/${func}'"])

  logs_widgets = [
    {
      type = "log", x = 0, y = local.logs_y_offset + 1, width = 12, height = 6
      properties = {
        query = "${local.log_sources} | filter @message like /ERROR|Error|error|Exception/ | stats count() as errorCount by @message | sort errorCount desc | limit 10"
        region = var.aws_region
        title = "Top Error Messages (Lambdas)"
        view = "table"
      }
    },
    {
      type = "log", x = 12, y = local.logs_y_offset + 1, width = 12, height = 6
      properties = {
        query = "${local.log_sources} | filter @message like /ERROR|Error|error|Exception/ | stats count() by bin(5m)"
        region = var.aws_region
        title = "Error Trend (5-min bins)"
        view = "timeSeries"
      }
    },
    {
      type = "log", x = 0, y = local.logs_y_offset + 7, width = 12, height = 6
      properties = {
        query = "${local.log_sources} | filter @type = \"REPORT\" | sort @duration desc | limit 10 | fields @timestamp, @log, @duration, @billedDuration, @memorySize"
        region = var.aws_region
        title = "Slowest Lambda Invocations"
        view = "table"
      }
    },
    {
      type = "log", x = 12, y = local.logs_y_offset + 7, width = 12, height = 6
      properties = {
        query = "${local.log_sources} | filter @message like /Exception/ | parse @message \"*Exception*\" as pre, exc | stats count() as excCount by exc | sort excCount desc | limit 10"
        region = var.aws_region
        title = "Top Exception Types"
        view = "table"
      }
    }
  ]

  all_widgets = concat(
    local.health_overview_header,
    local.health_overview_widgets,
    local.pipeline_header,
    local.pipeline_widgets,
    local.detailed_header,
    local.api_gw_widget,
    local.lambda_widgets,
    local.sqs_widgets,
    local.dynamodb_widget,
    local.eks_widget,
    local.logs_header,
    local.logs_widgets
  )
}

resource "aws_cloudwatch_dashboard" "main" {
  dashboard_name = "${var.project_name}-dashboard-${var.environment}"

  dashboard_body = jsonencode({
    widgets = local.all_widgets
  })
}
