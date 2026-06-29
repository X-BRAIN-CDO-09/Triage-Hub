resource "aws_cloudwatch_log_group" "triage_logs" {
  name              = "/${var.project_name}/${var.environment}/triage-logs"
  retention_in_days = var.retention_in_days

  tags = {
    Environment = var.environment
    Project     = var.project_name
  }
}

resource "aws_cloudwatch_log_group" "eks_logs" {
  name              = "/${var.project_name}/${var.environment}/eks-logs"
  retention_in_days = var.retention_in_days

  tags = {
    Environment = var.environment
    Project     = var.project_name
  }
}

resource "aws_cloudwatch_log_group" "metrics_logs" {
  name              = "/${var.project_name}/${var.environment}/metrics"
  retention_in_days = var.retention_in_days

  tags = {
    Environment = var.environment
    Project     = var.project_name
  }
}


resource "aws_cloudwatch_dashboard" "triage_dashboard" {
  dashboard_name = "${var.project_name}-dashboard-${var.environment}"

  dashboard_body = jsonencode({
    widgets = [
      {
        type   = "log",
        x      = 0,
        y      = 0,
        width  = 24,
        height = 6,
        properties = {
          query  = "SOURCE '/aws/lambda/${var.project_name}-alert-ingest' | SOURCE '/aws/lambda/${var.project_name}-jira-dispatcher' | SOURCE '/aws/lambda/${var.project_name}-notify-dispatcher' | SOURCE '/aws/lambda/${var.project_name}-push-to-ai' | fields @timestamp, @message | sort @timestamp desc | limit 20",
          region = "us-east-1",
          title  = "Recent Lambda Logs",
          view   = "table"
        }
      },
      {
        type   = "log",
        x      = 0,
        y      = 6,
        width  = 24,
        height = 6,
        properties = {
          query  = "SOURCE '${aws_cloudwatch_log_group.eks_logs.name}' | fields @timestamp, @logStream, @message | sort @timestamp desc | limit 20",
          region = "us-east-1",
          title  = "EKS Container Logs",
          view   = "table"
        }
      }
    ]
  })
}
