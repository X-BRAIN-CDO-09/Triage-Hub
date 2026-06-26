# =============================================================================
# Environment: sandbox
# Module composition — gọi các shared modules
# =============================================================================

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

  vpc_id          = module.vpc_customer.vpc_id
  subnet_id       = module.vpc_customer.public_subnet_ids[0]
  environment     = var.environment
  instance_type   = var.customer_instance_type
  api_gateway_url = "${module.api_gateway.invoke_url}/alerts"
  api_key         = module.api_gateway.api_key_value
  tenant_id       = "tenant-a"
}

# 4. ECR Module
module "ecr" {
  source = "../../modules/ecr"

  project_name = var.project_name
  repositories = {
    "tf1-api"    = {}
    "tf1-worker" = {}
  }
}

# 5. EKS Module
module "eks" {
  source = "../../modules/eks"

  project_name        = var.project_name
  cluster_version     = var.cluster_version
  private_subnet_ids  = module.vpc_platform.private_subnet_ids
  node_instance_types = var.node_instance_types
  node_scaling        = var.node_scaling
  public_access_cidrs = var.public_access_cidrs
  cluster_admin_arns  = var.cluster_admin_arns
}

# 6. SQS Module (Buffer and Dispatch queues)
module "sqs" {
  source = "../../modules/sqs"

  project_name = var.project_name
  queues = {
    "buffer-queue" = {}
  }
}

# 7. S3 Module
module "s3" {
  source       = "../../modules/s3"
  project_name = var.project_name
  environment  = var.environment
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
      source_dir = "../../../app/alert-ingest"
      environment_variables = {
        SQS_QUEUE_URL  = module.sqs.queue_urls["buffer-queue"]
        DYNAMODB_TABLE = module.dynamodb.table_name
      }
      iam_policy_statements = [
        {
          effect    = "Allow"
          actions   = ["sqs:SendMessage"]
          resources = [module.sqs.queue_arns["buffer-queue"]]
        },
        {
          effect    = "Allow"
          actions   = ["dynamodb:Query", "dynamodb:GetItem"]
          resources = [module.dynamodb.table_arn]
        }
      ]
    }

    "jira-dispatcher" = {
      handler    = "index.handler"
      runtime    = "nodejs20.x"
      source_dir = "../../../app/jira-dispatcher"
      environment_variables = {
        DYNAMODB_TABLE          = module.dynamodb.table_name
        JIRA_SECRET_ARN         = module.secrets_manager.secret_arns["jira_api_token"]
        SLACK_SIGNING_SECRET_ARN = module.secrets_manager.secret_arns["slack_signing_secret"]
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
            module.secrets_manager.secret_arns["slack_signing_secret"]
          ]
        }
      ]
    }

    "push-to-ai" = {
      handler                = "index.handler"
      runtime                = "nodejs20.x"
      source_dir             = "../../../app/push-to-ai"
      vpc_subnet_ids         = module.vpc_platform.private_subnet_ids
      vpc_security_group_ids = [module.lambda_sg.security_group_id]
      environment_variables = {
        SQS_QUEUE_URL = module.sqs.queue_urls["buffer-queue"]
        AI_ENGINE_URL = "http://internal-tf1-alb-123456789.us-east-1.elb.amazonaws.com:8080/v1/triage" # Update this to your real internal ALB DNS once deployed
      }
      iam_policy_statements = [
        {
          effect    = "Allow"
          actions   = ["sqs:ReceiveMessage", "sqs:DeleteMessage", "sqs:GetQueueAttributes"]
          resources = [module.sqs.queue_arns["buffer-queue"]]
        }
      ]
    }

    "notify-dispatcher" = {
      handler    = "index.handler"
      runtime    = "nodejs20.x"
      source_dir = "../../../app/notify-dispatcher"
      environment_variables = {
        DYNAMODB_TABLE      = module.dynamodb.table_name
        JIRA_SECRET_ARN     = module.secrets_manager.secret_arns["jira_api_token"]
        SLACK_BOT_TOKEN_ARN = module.secrets_manager.secret_arns["slack_bot_token"]
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
      path_part           = "alerts"
      http_method         = "POST"
      lambda_function_arn = module.lambda.invoke_arns["alert-ingest"]
      lambda_name         = module.lambda.function_names["alert-ingest"]
      api_key_required    = true
    }
    "slack" = {
      path_part           = "slack"
      http_method         = "POST"
      lambda_function_arn = module.lambda.invoke_arns["jira-dispatcher"]
      lambda_name         = module.lambda.function_names["jira-dispatcher"]
      api_key_required    = false
    }
  }
}

# 13. SQS Event Source Mappings (Triggers)
resource "aws_lambda_event_source_mapping" "push_to_ai" {
  event_source_arn = module.sqs.queue_arns["buffer-queue"]
  function_name    = module.lambda.function_names["push-to-ai"]
  batch_size       = 10
  enabled          = true
}

# 14. VPC Endpoints (Gateway for S3 and DynamoDB)
resource "aws_vpc_endpoint" "s3" {
  vpc_id            = module.vpc_platform.vpc_id
  service_name      = "com.amazonaws.${var.aws_region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = module.vpc_platform.private_route_table_ids

  tags = {
    Name = "${var.project_name}-s3-vpce-${var.environment}"
  }
}

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

# 17. EKS IRSA Roles for Workloads

# IAM Role for tf1-api (Needs to read DynamoDB & Secrets Manager)
resource "aws_iam_role" "tf1_api_irsa" {
  name = "${var.project_name}-tf1-api-irsa-${var.environment}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Federated = local.oidc_provider_arn
        }
        Action = "sts:AssumeRoleWithWebIdentity"
        Condition = {
          StringEquals = {
            "${local.oidc_provider_url}:sub" = "system:serviceaccount:default:tf1-api-sa"
          }
        }
      }
    ]
  })

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
      }
    ]
  })
}

# IAM Role for tf1-worker (Needs S3, DynamoDB, Secrets Manager, and invoke notify-dispatcher Lambda)
resource "aws_iam_role" "tf1_worker_irsa" {
  name = "${var.project_name}-tf1-worker-irsa-${var.environment}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Federated = local.oidc_provider_arn
        }
        Action = "sts:AssumeRoleWithWebIdentity"
        Condition = {
          StringEquals = {
            "${local.oidc_provider_url}:sub" = "system:serviceaccount:default:tf1-worker-sa"
          }
        }
      }
    ]
  })

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
          "s3:PutObject",
          "s3:GetObject",
          "s3:ListBucket"
        ]
        Resource = [
          module.s3.bucket_arn,
          "${module.s3.bucket_arn}/*"
        ]
      },
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
          "lambda:InvokeFunction"
        ]
        Resource = [
          module.lambda.function_arns["notify-dispatcher"]
        ]
      }
    ]
  })
}

