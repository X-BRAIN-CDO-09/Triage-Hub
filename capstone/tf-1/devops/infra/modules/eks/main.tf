# =============================================================================
# EKS Cluster — AI Engine Runtime (KAN-204)
# Angle: EKS + ArgoCD GitOps (xem docs/reports/08_adrs.md ADR-003)
# Invariants:
#   - Private: control plane endpoint private-only, node group ở private subnet
#   - IRSA: OIDC provider để map ServiceAccount → IAM Role (no static creds)
#   - GitOps add-ons (ArgoCD/ESO/Gatekeeper) KHÔNG nằm trong Terraform state
# =============================================================================

data "aws_partition" "current" {}

# --- IAM role cho EKS control plane ---------------------------------------
resource "aws_iam_role" "cluster" {
  name = "${var.project_name}-eks-cluster-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "eks.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "cluster_policy" {
  role       = aws_iam_role.cluster.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonEKSClusterPolicy"
}

# --- EKS cluster (private endpoint) ---------------------------------------
resource "aws_eks_cluster" "this" {
  name     = "${var.project_name}-eks"
  version  = var.cluster_version
  role_arn = aws_iam_role.cluster.arn

  vpc_config {
    subnet_ids              = var.private_subnet_ids
    endpoint_private_access = true
    endpoint_public_access  = var.endpoint_public_access
    public_access_cidrs     = var.endpoint_public_access ? var.public_access_cidrs : null
  }

  # Bật API_AND_CONFIG_MAP để dùng được aws_eks_access_entry
  access_config {
    authentication_mode = "API_AND_CONFIG_MAP"
  }

  # Audit + API server logs → CloudWatch (khớp 03_security_design.md §5)
  enabled_cluster_log_types = ["api", "audit", "authenticator"]

  depends_on = [aws_iam_role_policy_attachment.cluster_policy]

  tags = { Name = "${var.project_name}-eks" }
}

# --- IRSA: OIDC provider --------------------------------------------------
data "tls_certificate" "oidc" {
  url = aws_eks_cluster.this.identity[0].oidc[0].issuer
}

resource "aws_iam_openid_connect_provider" "this" {
  url             = aws_eks_cluster.this.identity[0].oidc[0].issuer
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.oidc.certificates[0].sha1_fingerprint]
}

# --- IAM role cho managed node group --------------------------------------
resource "aws_iam_role" "node" {
  name = "${var.project_name}-eks-node-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "node_policies" {
  for_each = toset([
    "AmazonEKSWorkerNodePolicy",
    "AmazonEKS_CNI_Policy",
    "AmazonEC2ContainerRegistryReadOnly", # pull signed image từ ECR
  ])
  role       = aws_iam_role.node.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/${each.value}"
}

# Launch Template để cấu hình Metadata Options (hop limit = 2 cho IMDSv2)
resource "aws_launch_template" "eks_node" {
  name_prefix = "${var.project_name}-eks-node-"

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 2
  }

  tag_specifications {
    resource_type = "instance"
    tags = {
      Name = "${var.project_name}-ng-node"
    }
  }
}

# --- Managed node group (private, autoscaling KAN-205) --------------------
resource "aws_eks_node_group" "this" {
  cluster_name    = aws_eks_cluster.this.name
  node_group_name = "${var.project_name}-ng-v4"
  node_role_arn   = aws_iam_role.node.arn
  subnet_ids      = var.private_subnet_ids
  instance_types  = var.node_instance_types

  launch_template {
    id      = aws_launch_template.eks_node.id
    version = aws_launch_template.eks_node.latest_version
  }

  scaling_config {
    min_size     = var.node_scaling.min_size
    max_size     = var.node_scaling.max_size
    desired_size = var.node_scaling.desired_size
  }

  depends_on = [aws_iam_role_policy_attachment.node_policies]

  tags = { Name = "${var.project_name}-ng" }
}

# --- EKS Access Entries: Cấp quyền admin cho IAM User/Role bên ngoài ------
resource "aws_eks_access_entry" "admin" {
  for_each = toset(var.cluster_admin_arns)

  cluster_name  = aws_eks_cluster.this.name
  principal_arn = each.value
  type          = "STANDARD"

  tags = { Name = "${var.project_name}-eks-admin-access" }
}

resource "aws_eks_access_policy_association" "admin" {
  for_each = toset(var.cluster_admin_arns)

  cluster_name  = aws_eks_cluster.this.name
  principal_arn = each.value
  policy_arn    = "arn:${data.aws_partition.current.partition}:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"

  access_scope {
    type = "cluster"
  }

  depends_on = [aws_eks_access_entry.admin]
}
