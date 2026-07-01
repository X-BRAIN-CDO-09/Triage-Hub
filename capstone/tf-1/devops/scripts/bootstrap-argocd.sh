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

echo "==> Waiting for ArgoCD Server to be ready..."
kubectl rollout status deployment/argocd-server -n "$NAMESPACE" --timeout=300s

echo "==> Automatically applying Prometheus ServiceMonitor CRD..."
kubectl apply -f https://raw.githubusercontent.com/prometheus-operator/prometheus-operator/main/example/prometheus-operator-crd/monitoring.coreos.com_servicemonitors.yaml

echo "==> Automatically applying triage-hub AppProject..."
kubectl apply -f "$(dirname "$0")/../platform/argocd/projects/triage-hub-project.yaml" -n "$NAMESPACE"

echo "==> Automatically applying triage-hub-app Application..."
kubectl apply -f "$(dirname "$0")/../platform/argocd/apps/triage-hub-app.yaml" -n "$NAMESPACE"

echo "==> ArgoCD bootstrap complete!"
