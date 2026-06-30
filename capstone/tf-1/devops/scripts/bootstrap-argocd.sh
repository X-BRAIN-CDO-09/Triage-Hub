#!/usr/bin/env bash
# =============================================================================
# Bootstrap script for ArgoCD on EKS (KAN-204)
# =============================================================================
set -euo pipefail

CLUSTER_NAME="triage-hub-eks"
REGION="us-east-1"
NAMESPACE="argocd"

echo "==> Configuring kubectl for EKS cluster: $CLUSTER_NAME..."
aws eks update-kubeconfig --region "$REGION" --name "$CLUSTER_NAME"

echo "==> Creating namespace $NAMESPACE..."
kubectl create namespace "$NAMESPACE" || echo "Namespace $NAMESPACE already exists"

echo "==> Adding ArgoCD Helm chart repository..."
helm repo add argo https://argoproj.github.io/argo-helm
helm repo update

echo "==> Installing ArgoCD..."
helm install argocd argo/argo-cd \
  --namespace "$NAMESPACE" \
  --set server.service.type=ClusterIP \
  --set server.rdp.enabled=false

echo "==> ArgoCD bootstrap complete!"
