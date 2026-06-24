output "cluster_name" {
  value       = aws_eks_cluster.this.name
  description = "Tên EKS cluster"
}

output "cluster_endpoint" {
  value       = aws_eks_cluster.this.endpoint
  description = "Endpoint API server (private)"
}

output "cluster_certificate_authority" {
  value       = aws_eks_cluster.this.certificate_authority[0].data
  description = "CA data để kubeconfig kết nối cluster"
}

output "oidc_provider_arn" {
  value       = aws_iam_openid_connect_provider.this.arn
  description = "ARN của OIDC provider — dùng cho IRSA trust policy"
}

output "oidc_provider_url" {
  value       = aws_iam_openid_connect_provider.this.url
  description = "URL OIDC issuer — dùng cho IRSA condition"
}

output "node_group_name" {
  value       = aws_eks_node_group.this.node_group_name
  description = "Tên managed node group"
}
