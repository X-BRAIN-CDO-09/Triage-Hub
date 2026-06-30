# =============================================================================
# Environment: sandbox
# Module composition — gọi các shared modules
# =============================================================================

data "aws_caller_identity" "current" {}

locals {
  lambda_bootstrap_source_dir = "../../modules/lambda/bootstrap/nodejs20"
}

# 1. Platform VPC Module
module "vpc_platform" {
  source = "../../modules/vpc"

  vpc_name                = "triage-platform-vpc-${var.environment}"
  cidr_block              = var.platform_vpc_cidr
  public_subnets          = var.platform_public_subnets
  private_subnets         = var.platform_private_subnets
  enable_nat_gateway      = true
  enable_internet_gateway = true
  environment             = var.environment
}

# 2. Customer VPC Module (Simulating Customer Environment)
module "vpc_customer" {
  source = "../../modules/vpc"

  vpc_name                = "triage-customer-vpc-${var.environment}"
  cidr_block              = var.customer_vpc_cidr
  public_subnets          = var.customer_public_subnets
  private_subnets         = []
  enable_nat_gateway      = false
  enable_internet_gateway = true
  environment             = var.environment
}

# 3. Customer App Simulation EC2 Module
module "customer_app" {
  source = "../../modules/customer_app"

  vpc_id                = module.vpc_customer.vpc_id
  subnet_id             = module.vpc_customer.public_subnet_ids[0]
  environment           = var.environment
  instance_type         = var.customer_instance_type
  api_gateway_url       = "${module.api_gateway.invoke_url}/alerts"
  api_key               = module.api_gateway.api_key_value
  tenant_id             = "tenant-a"
  allowed_inbound_cidrs = formatlist("%s/32", module.vpc_platform.nat_public_ips)
}


# 4. ECR Module
module "ecr" {
  source = "../../modules/ecr"

  project_name = var.project_name
  repositories = {
    # 1 image dùng chung cho cả tf1-api & tf1-worker (khác nhau ở command K8s)
    "tf1-engine" = {}
  }
}

# 5. EKS Module
module "eks" {
  source = "../../modules/eks"

  project_name           = var.project_name
  cluster_version        = var.cluster_version
  private_subnet_ids     = module.vpc_platform.private_subnet_ids
  node_instance_types    = var.node_instance_types
  node_scaling           = var.node_scaling
  endpoint_public_access = var.endpoint_public_access
  public_access_cidrs    = var.public_access_cidrs
  cluster_admin_arns     = var.cluster_admin_arns
}

# 6. SQS Module (Buffer and Dispatch queues)
module "sqs" {
  source = "../../modules/sqs"

  project_name = var.project_name
  queues = {
    "raw-alert-queue" = {
      visibility_timeout_seconds  = 60
      message_retention_seconds   = 345600
      max_receive_count           = 5
      fifo_queue                  = true
      content_based_deduplication = true
    }
    "buffer-queue" = {
      fifo_queue                  = true
      content_based_deduplication = true
    }
    "dispatch-queue" = {}
  }
}

# 8. DynamoDB Module
module "dynamodb" {
  source       = "../../modules/dynamodb"
  project_name = var.project_name
  environment  = var.environment
}

# 9. Secrets Manager Module
module "secrets_manager" {
  source       = "../../modules/secrets_manager"
  project_name = var.project_name
  environment  = var.environment
}

# 10. Security Group for Lambdas
module "lambda_sg" {
  source = "../../modules/security_group"

  project_name = var.project_name
  vpc_id       = module.vpc_platform.vpc_id
  name_suffix  = "lambdas-sg"
  description  = "Security Group for Triage Lambdas in VPC"

  ingress_rules = []
  egress_rules = [{
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
    description = "Allow all outbound traffic"
  }]
}

# 11. Lambda Module
module "lambda" {
  source = "../../modules/lambda"

  project_name                   = var.project_name
  default_vpc_subnet_ids         = null
  default_vpc_security_group_ids = null

  lambdas = {
    "alert-ingest" = {
      handler    = "index.handler"
      runtime    = "nodejs20.x"
      source_dir = local.lambda_bootstrap_source_dir
      environment_variables = {
        SQS_QUEUE_URL  = module.sqs.queue_urls["buffer-queue"]
        DYNAMODB_TABLE = module.dynamodb.table_name
      }
      iam_policy_statements = [
        {
          effect = "Allow"
          actions = [
            "sqs:ReceiveMessage",
            "sqs:DeleteMessage",
            "sqs:GetQueueAttributes"
          ]
          resources = [module.sqs.queue_arns["raw-alert-queue"]]
        },
        {
          effect    = "Allow"
          actions   = ["sqs:SendMessage"]
          resources = [module.sqs.queue_arns["buffer-queue"]]
        },
        {
          effect    = "Allow"
          actions   = ["dynamodb:Query", "dynamodb:GetItem", "dynamodb:PutItem", "dynamodb:UpdateItem"]
          resources = [module.dynamodb.table_arn]
        }
      ]
    }

    "jira-dispatcher" = {
      handler    = "index.handler"
      runtime    = "nodejs20.x"
      source_dir = local.lambda_bootstrap_source_dir
      environment_variables = {
        DYNAMODB_TABLE           = module.dynamodb.table_name
        JIRA_SECRET_ARN          = module.secrets_manager.secret_arns["jira_api_token"]
        SLACK_SIGNING_SECRET_ARN = module.secrets_manager.secret_arns["slack_signing_secret"]
        # Cần cho "Assign Me": map Slack user -> email (users.info) -> Jira accountId
        SLACK_BOT_TOKEN_ARN = module.secrets_manager.secret_arns["slack_bot_token"]
        EVENT_BUS_NAME      = aws_cloudwatch_event_bus.triage_hub_bus.name
      }
      iam_policy_statements = [
        {
          effect    = "Allow"
          actions   = ["dynamodb:PutItem", "dynamodb:GetItem"]
          resources = [module.dynamodb.table_arn]
        },
        {
          effect  = "Allow"
          actions = ["secretsmanager:GetSecretValue"]
          resources = [
            module.secrets_manager.secret_arns["jira_api_token"],
            module.secrets_manager.secret_arns["slack_signing_secret"],
            module.secrets_manager.secret_arns["slack_bot_token"]
          ]
        },
        {
          effect    = "Allow"
          actions   = ["lambda:InvokeFunction"]
          resources = ["arn:aws:lambda:us-east-1:*:function:triage-hub-jira-dispatcher"]
        },
        {
          effect    = "Allow"
          actions   = ["events:PutEvents"]
          resources = [aws_cloudwatch_event_bus.triage_hub_bus.arn]
        }
      ]
    }

    "broadcast-notifier" = {
      handler    = "index.handler"
      runtime    = "nodejs20.x"
      source_dir = local.lambda_bootstrap_source_dir
      environment_variables = {
        SLACK_BOT_TOKEN_ARN = module.secrets_manager.secret_arns["slack_bot_token"]
      }
      iam_policy_statements = [
        {
          effect    = "Allow"
          actions   = ["secretsmanager:GetSecretValue"]
          resources = [module.secrets_manager.secret_arns["slack_bot_token"]]
        }
      ]
    }

    "notify-dispatcher" = {
      handler    = "index.handler"
      runtime    = "nodejs20.x"
      source_dir = local.lambda_bootstrap_source_dir
      environment_variables = {
        DYNAMODB_TABLE      = module.dynamodb.table_name
        JIRA_SECRET_ARN     = module.secrets_manager.secret_arns["jira_api_token"]
        SLACK_BOT_TOKEN_ARN = module.secrets_manager.secret_arns["slack_bot_token"]
        JIRA_DISPATCHER_ARN = "arn:aws:lambda:${var.aws_region}:${data.aws_caller_identity.current.account_id}:function:${var.project_name}-jira-dispatcher"
      }
      iam_policy_statements = [
        {
          effect    = "Allow"
          actions   = ["dynamodb:PutItem", "dynamodb:GetItem", "dynamodb:UpdateItem"]
          resources = [module.dynamodb.table_arn]
        },
        {
          effect  = "Allow"
          actions = ["secretsmanager:GetSecretValue"]
          resources = [
            module.secrets_manager.secret_arns["jira_api_token"],
            module.secrets_manager.secret_arns["slack_bot_token"]
          ]
        },
        {
          effect    = "Allow"
          actions   = ["lambda:InvokeFunction"]
          resources = ["arn:aws:lambda:${var.aws_region}:${data.aws_caller_identity.current.account_id}:function:${var.project_name}-jira-dispatcher"]
        },
        {
          effect    = "Allow"
          actions   = ["sqs:ReceiveMessage", "sqs:DeleteMessage", "sqs:GetQueueAttributes"]
          resources = [module.sqs.queue_arns["dispatch-queue"]]
        }
      ]
    }
  }
}

# 12. API Gateway Module
module "api_gateway" {
  source = "../../modules/api_gateway"

  project_name = var.project_name
  environment  = var.environment

  integrations = {
    "alerts" = {
      path_part        = "alerts"
      http_method      = "POST"
      api_key_required = true

      integration_type = "sqs_send_message"
      sqs_queue_arn    = module.sqs.queue_arns["raw-alert-queue"]
      sqs_queue_name   = "${var.project_name}-raw-alert-queue.fifo"
    }
    "slack" = {
      path_part           = "slack"
      http_method         = "POST"
      integration_type    = "lambda_proxy"
      lambda_function_arn = module.lambda.invoke_arns["jira-dispatcher"]
      lambda_name         = module.lambda.function_names["jira-dispatcher"]
      api_key_required    = false
    }
  }
}

# 13. SQS Event Source Mappings (Triggers)
resource "aws_lambda_event_source_mapping" "alert_ingest_raw_alert_queue" {
  event_source_arn = module.sqs.queue_arns["raw-alert-queue"]
  function_name    = module.lambda.function_names["alert-ingest"]
  batch_size       = 1
  enabled          = true
}

resource "aws_lambda_event_source_mapping" "notify_dispatcher" {
  event_source_arn = module.sqs.queue_arns["dispatch-queue"]
  function_name    = module.lambda.function_names["notify-dispatcher"]
  batch_size       = 10
  enabled          = true
}

# 14. VPC Endpoints (Gateway for DynamoDB)
resource "aws_vpc_endpoint" "dynamodb" {
  vpc_id            = module.vpc_platform.vpc_id
  service_name      = "com.amazonaws.${var.aws_region}.dynamodb"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = module.vpc_platform.private_route_table_ids

  tags = {
    Name = "${var.project_name}-dynamodb-vpce-${var.environment}"
  }
}

# 15. Security Group for VPC Interface Endpoints
module "vpc_endpoints_sg" {
  source = "../../modules/security_group"

  project_name = var.project_name
  vpc_id       = module.vpc_platform.vpc_id
  name_suffix  = "vpc-endpoints-sg"
  description  = "Security Group for VPC Interface Endpoints"

  ingress_rules = [{
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [var.platform_vpc_cidr]
    description = "Allow HTTPS inbound from VPC resources"
  }]
}

# 16. Secrets Manager VPC Endpoint (Interface)
resource "aws_vpc_endpoint" "secretsmanager" {
  vpc_id              = module.vpc_platform.vpc_id
  service_name        = "com.amazonaws.${var.aws_region}.secretsmanager"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = module.vpc_platform.private_subnet_ids
  security_group_ids  = [module.vpc_endpoints_sg.security_group_id]
  private_dns_enabled = true

  tags = {
    Name = "${var.project_name}-secrets-vpce-${var.environment}"
  }
}

# 16b. Bedrock Runtime VPC Endpoint (Interface) — Required for AI Engine Bedrock calls
resource "aws_vpc_endpoint" "bedrock_runtime" {
  vpc_id              = module.vpc_platform.vpc_id
  service_name        = "com.amazonaws.${var.aws_region}.bedrock-runtime"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = module.vpc_platform.private_subnet_ids
  security_group_ids  = [module.vpc_endpoints_sg.security_group_id]
  private_dns_enabled = true

  tags = {
    Name = "${var.project_name}-bedrock-vpce-${var.environment}"
  }
}

# 16b-2. Bedrock AgentCore VPC Endpoint (Interface) — data plane InvokeAgentRuntime.
# Để pod tf1-api gọi AgentCore runtime (cross-account 589077667575) qua PrivateLink
# thay vì đi NAT ra public API (private-first). Service data plane: bedrock-agentcore.
resource "aws_vpc_endpoint" "bedrock_agentcore" {
  vpc_id              = module.vpc_platform.vpc_id
  service_name        = "com.amazonaws.${var.aws_region}.bedrock-agentcore"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = module.vpc_platform.private_subnet_ids
  security_group_ids  = [module.vpc_endpoints_sg.security_group_id]
  private_dns_enabled = true

  tags = {
    Name = "${var.project_name}-bedrock-agentcore-vpce-${var.environment}"
  }
}

# 16c. SQS VPC Endpoint (Interface) — Cho phép Pod giao tiếp SQS ngầm nội bộ
resource "aws_vpc_endpoint" "sqs" {
  vpc_id              = module.vpc_platform.vpc_id
  service_name        = "com.amazonaws.${var.aws_region}.sqs"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = module.vpc_platform.private_subnet_ids
  security_group_ids  = [module.vpc_endpoints_sg.security_group_id]
  private_dns_enabled = true

  tags = {
    Name = "${var.project_name}-sqs-vpce-${var.environment}"
  }
}

# 16d. ECR API + ECR DKR VPC Endpoints — Required for EKS private node image pulling
resource "aws_vpc_endpoint" "ecr_api" {
  vpc_id              = module.vpc_platform.vpc_id
  service_name        = "com.amazonaws.${var.aws_region}.ecr.api"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = module.vpc_platform.private_subnet_ids
  security_group_ids  = [module.vpc_endpoints_sg.security_group_id]
  private_dns_enabled = true

  tags = {
    Name = "${var.project_name}-ecr-api-vpce-${var.environment}"
  }
}

resource "aws_vpc_endpoint" "ecr_dkr" {
  vpc_id              = module.vpc_platform.vpc_id
  service_name        = "com.amazonaws.${var.aws_region}.ecr.dkr"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = module.vpc_platform.private_subnet_ids
  security_group_ids  = [module.vpc_endpoints_sg.security_group_id]
  private_dns_enabled = true

  tags = {
    Name = "${var.project_name}-ecr-dkr-vpce-${var.environment}"
  }
}

# 16d. Internal ALB security group and module
module "alb_sg" {
  source = "../../modules/security_group"

  project_name = var.project_name
  vpc_id       = module.vpc_platform.vpc_id
  name_suffix  = "ai-alb-sg"
  description  = "Security Group for AI Engine internal ALB"

  ingress_rules = [{
    from_port   = 8080
    to_port     = 8080
    protocol    = "tcp"
    cidr_blocks = [var.platform_vpc_cidr]
    description = "Allow inbound port 8080 traffic from Platform VPC"
  }]
}

module "alb" {
  source = "../../modules/alb"

  project_name          = var.project_name
  environment           = var.environment
  vpc_id                = module.vpc_platform.vpc_id
  private_subnet_ids    = module.vpc_platform.private_subnet_ids
  alb_security_group_id = module.alb_sg.security_group_id
}

# Publish ALB target group ARN vào SSM để CI/CD pipeline tự patch TargetGroupBinding
# (overlays/sandbox/kustomization.yaml). TG ARN đổi mỗi lần cluster/ALB tạo lại nên
# KHÔNG hardcode lâu dài — CI đọc /triage-hub/sandbox/alb_target_group_arn rồi patch.
resource "aws_ssm_parameter" "alb_target_group_arn" {
  name        = "/${var.project_name}/${var.environment}/alb_target_group_arn"
  description = "Internal ALB target group ARN cho TargetGroupBinding (KEDA/ArgoCD overlay)"
  type        = "String"
  value       = module.alb.target_group_arn
  overwrite   = true

  tags = {
    Environment = var.environment
  }
}

# 16e. Observability Module
module "observability" {
  source = "../../modules/observability"

  project_name        = var.project_name
  environment         = var.environment
  aws_region          = var.aws_region
  api_gateway_name    = "${var.project_name}-apigw-${var.environment}"
  dynamodb_table_name = module.dynamodb.table_name
  eks_cluster_name    = module.eks.cluster_name

  lambda_functions = [
    "${var.project_name}-alert-ingest",
    "${var.project_name}-jira-dispatcher",
    "${var.project_name}-notify-dispatcher"
  ]

  sqs_queues = [
    "${var.project_name}-raw-alert-queue.fifo",
    "${var.project_name}-buffer-queue.fifo",
    "${var.project_name}-dispatch-queue"
  ]

  enable_notifications = var.enable_notifications
  notification_email   = var.notification_email
  notification_sms     = var.notification_sms
  alarm_thresholds     = var.alarm_thresholds

  alb_arn                  = module.alb.alb_arn
  alb_target_group_arn     = module.alb.target_group_arn
  customer_app_instance_id = module.customer_app.instance_id
  s3_bucket_id             = module.s3.bucket_id

  monitor_alb = true
  monitor_ec2 = true
}

# 17. EKS IRSA Roles for Workloads

data "aws_iam_policy_document" "tf1_api_assume_role" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    effect  = "Allow"

    principals {
      type        = "Federated"
      identifiers = [local.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_provider_url}:sub"
      values   = ["system:serviceaccount:triage-hub:tf1-api-sa"]
    }
  }
}

# IAM Role for tf1-api (Needs to read DynamoDB & Secrets Manager)
resource "aws_iam_role" "tf1_api_irsa" {
  name = "${var.project_name}-tf1-api-irsa-${var.environment}"

  assume_role_policy = data.aws_iam_policy_document.tf1_api_assume_role.json

  tags = {
    Environment = var.environment
  }
}

resource "aws_iam_role_policy" "tf1_api_policy" {
  name = "${var.project_name}-tf1-api-policy-${var.environment}"
  role = aws_iam_role.tf1_api_irsa.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "dynamodb:GetItem",
          "dynamodb:PutItem",
          "dynamodb:UpdateItem",
          "dynamodb:Query"
        ]
        Resource = module.dynamodb.table_arn
      },
      {
        Effect = "Allow"
        Action = [
          "secretsmanager:GetSecretValue"
        ]
        Resource = [
          module.secrets_manager.secret_arns["jira_api_token"],
          module.secrets_manager.secret_arns["slack_bot_token"]
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "bedrock:InvokeModel",
          "bedrock:InvokeModelWithResponseStream"
        ]
        Resource = ["arn:aws:bedrock:${var.aws_region}::foundation-model/*"]
      },
      {
        Effect   = "Allow"
        Action   = ["bedrock:InvokeAgent"]
        Resource = ["arn:aws:bedrock-agentcore:us-east-1:589077667575:runtime/tf1_ai_investigator-D48STMEUHo"]
      },
      {
        Effect   = "Allow"
        Action   = ["bedrock-agentcore:InvokeAgentRuntime"]
        Resource = ["arn:aws:bedrock-agentcore:${var.aws_region}:*:runtime/*"]
      }
    ]
  })
}

data "aws_iam_policy_document" "tf1_worker_assume_role" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    effect  = "Allow"

    principals {
      type        = "Federated"
      identifiers = [local.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_provider_url}:sub"
      values   = ["system:serviceaccount:triage-hub:tf1-worker-sa"]
    }
  }
}

# IAM Role for tf1-worker (Needs SQS, DynamoDB, Secrets Manager, and invoke notify-dispatcher Lambda)
resource "aws_iam_role" "tf1_worker_irsa" {
  name = "${var.project_name}-tf1-worker-irsa-${var.environment}"

  assume_role_policy = data.aws_iam_policy_document.tf1_worker_assume_role.json

  tags = {
    Environment = var.environment
  }
}

resource "aws_iam_role_policy" "tf1_worker_policy" {
  name = "${var.project_name}-tf1-worker-policy-${var.environment}"
  role = aws_iam_role.tf1_worker_irsa.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "dynamodb:GetItem",
          "dynamodb:PutItem",
          "dynamodb:UpdateItem",
          "dynamodb:Query"
        ]
        Resource = module.dynamodb.table_arn
      },
      {
        Effect = "Allow"
        Action = [
          "secretsmanager:GetSecretValue"
        ]
        Resource = [
          module.secrets_manager.secret_arns["jira_api_token"],
          module.secrets_manager.secret_arns["slack_bot_token"]
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "sqs:ReceiveMessage",
          "sqs:DeleteMessage",
          "sqs:GetQueueAttributes"
        ]
        Resource = [
          module.sqs.queue_arns["buffer-queue"]
        ]
      },
      {
        Effect = "Allow"
        Action = [
          "sqs:SendMessage"
        ]
        Resource = [
          module.sqs.queue_arns["dispatch-queue"]
        ]
      }
    ]
  })
}

# IRSA cho KEDA operator — KEDA dùng podIdentity.provider=aws nên LUÔN xài identity
# của chính operator (không ủy quyền sang workload role). Operator cần quyền đọc độ sâu
# SQS để tính scale. Least-privilege: chỉ GetQueueAttributes trên buffer-queue.
data "aws_iam_policy_document" "keda_operator_assume_role" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    effect  = "Allow"

    principals {
      type        = "Federated"
      identifiers = [local.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_provider_url}:sub"
      values   = ["system:serviceaccount:keda:keda-operator"]
    }
  }
}

resource "aws_iam_role" "keda_operator_irsa" {
  name = "${var.project_name}-keda-operator-irsa-${var.environment}"

  assume_role_policy = data.aws_iam_policy_document.keda_operator_assume_role.json

  tags = {
    Environment = var.environment
  }
}

resource "aws_iam_role_policy" "keda_operator_policy" {
  name = "${var.project_name}-keda-operator-policy-${var.environment}"
  role = aws_iam_role.keda_operator_irsa.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["sqs:GetQueueAttributes"]
        Resource = [module.sqs.queue_arns["buffer-queue"]]
      }
    ]
  })
}

data "aws_iam_policy_document" "aws_lbc_assume_role" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    effect  = "Allow"

    principals {
      type        = "Federated"
      identifiers = [local.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.oidc_provider_url}:sub"
      values   = ["system:serviceaccount:kube-system:aws-load-balancer-controller"]
    }
  }
}

resource "aws_iam_role" "aws_lbc_irsa" {
  name = "${var.project_name}-aws-lbc-irsa-${var.environment}"

  assume_role_policy = data.aws_iam_policy_document.aws_lbc_assume_role.json

  tags = {
    Environment = var.environment
  }
}

resource "aws_iam_role_policy_attachment" "aws_lbc_policy" {
  role       = aws_iam_role.aws_lbc_irsa.name
  policy_arn = "arn:aws:iam::aws:policy/ElasticLoadBalancingFullAccess"
}

resource "aws_iam_role_policy" "aws_lbc_ec2_policy" {
  name = "${var.project_name}-aws-lbc-ec2-policy-${var.environment}"
  role = aws_iam_role.aws_lbc_irsa.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ec2:DescribeAccountAttributes",
          "ec2:DescribeAddresses",
          "ec2:DescribeAvailabilityZones",
          "ec2:DescribeInternetGateways",
          "ec2:DescribeVpcs",
          "ec2:DescribeSubnets",
          "ec2:DescribeSecurityGroups",
          "ec2:DescribeInstances",
          "ec2:DescribeNetworkInterfaces",
          "ec2:CreateSecurityGroup",
          "ec2:CreateTags",
          "ec2:DeleteSecurityGroup",
          "ec2:AuthorizeSecurityGroupIngress",
          "ec2:AuthorizeSecurityGroupEgress",
          "ec2:RevokeSecurityGroupIngress",
          "ec2:RevokeSecurityGroupEgress"
        ]
        Resource = "*"
      }
    ]
  })
}

# 19. GitOps Bootstrapping: ArgoCD được cài bởi CI/CD pipeline (bootstrap-argocd job)
# Xem: .github/workflows/ci-infra.yml → job bootstrap-argocd
# Lý do tách ra: tránh lỗi EKS token hết hạn khi terraform apply chạy lâu

# Tự động truy vấn IP của EC2 Prometheus bằng filter động
data "aws_instances" "prometheus_ec2" {
  filter {
    name   = "tag:Name"
    values = ["*prometheus*"]
  }
}

# Lưu IP động của EC2 Prometheus vào SSM Parameter để CI/CD pipeline đọc (fallback về 127.0.0.1 nếu không tìm thấy)
resource "aws_ssm_parameter" "prometheus_ip" {
  name      = "/${var.project_name}/${var.environment}/prometheus_ip"
  type      = "String"
  value     = length(data.aws_instances.prometheus_ec2.public_ips) > 0 ? data.aws_instances.prometheus_ec2.public_ips[0] : "127.0.0.1"
  overwrite = true

  tags = {
    Environment = var.environment
  }
}

# 20. EventBridge for Broadcast Notifications
resource "aws_cloudwatch_event_bus" "triage_hub_bus" {
  name = "${var.project_name}-event-bus-${var.environment}"
}

resource "aws_cloudwatch_event_rule" "jira_assigned" {
  name           = "${var.project_name}-jira-assigned-rule-${var.environment}"
  event_bus_name = aws_cloudwatch_event_bus.triage_hub_bus.name
  description    = "Capture Jira assignment events from jira-dispatcher"
  event_pattern = jsonencode({
    "source"      = ["triage-hub.jira"],
    "detail-type" = ["IncidentAssigned"]
  })
}

resource "aws_cloudwatch_event_target" "broadcast_notifier" {
  rule           = aws_cloudwatch_event_rule.jira_assigned.name
  event_bus_name = aws_cloudwatch_event_bus.triage_hub_bus.name
  target_id      = "BroadcastNotifier"
  arn            = module.lambda.invoke_arns["broadcast-notifier"]
}

resource "aws_lambda_permission" "allow_eventbridge_invoke" {
  statement_id  = "AllowExecutionFromEventBridge"
  action        = "lambda:InvokeFunction"
  function_name = module.lambda.function_names["broadcast-notifier"]
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.jira_assigned.arn
}

# Cấp quyền SQS cho EKS Node Group để KEDA Operator có thể quét độ dài hàng đợi
resource "aws_iam_role_policy" "eks_node_sqs_policy" {
  name = "${var.project_name}-eks-node-sqs-policy-${var.environment}"
  role = "${var.project_name}-eks-node-role" # Tên role của Node Group

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "sqs:GetQueueAttributes",
          "sqs:ReceiveMessage",
          "sqs:DeleteMessage"
        ]
        Resource = module.sqs.queue_arns["buffer-queue"]
      }
    ]
  })
}

