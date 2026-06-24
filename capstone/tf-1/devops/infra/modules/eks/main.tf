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
    endpoint_private_access = true  # Invariant: private engine
    endpoint_public_access  = false # Invariant: no internet route
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

# --- Managed node group (private, autoscaling KAN-205) --------------------
resource "aws_eks_node_group" "this" {
  cluster_name    = aws_eks_cluster.this.name
  node_group_name = "${var.project_name}-ng"
  node_role_arn   = aws_iam_role.node.arn
  subnet_ids      = var.private_subnet_ids
  instance_types  = var.node_instance_types

  scaling_config {
    min_size     = var.node_scaling.min_size
    max_size     = var.node_scaling.max_size
    desired_size = var.node_scaling.desired_size
  }

  depends_on = [aws_iam_role_policy_attachment.node_policies]

  tags = { Name = "${var.project_name}-ng" }
}
