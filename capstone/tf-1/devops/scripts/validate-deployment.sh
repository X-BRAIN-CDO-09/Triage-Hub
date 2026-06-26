#!/usr/bin/env bash
# =============================================================================
# Script to validate deployment status of workloads
# =============================================================================
set -euo pipefail

echo "==> Waiting for tf1-api deployment rollout to complete..."
kubectl -n triage-hub rollout status deployment/tf1-api --timeout=3m

echo "==> Waiting for tf1-worker deployment rollout to complete..."
kubectl -n triage-hub rollout status deployment/tf1-worker --timeout=3m

echo "==> Checking pods in triage-hub namespace..."
kubectl -n triage-hub get pods -o wide

echo "==> Checking services..."
kubectl -n triage-hub get svc

echo "==> Checking HPAs..."
kubectl -n triage-hub get hpa

echo "==> Checking ingress/ALB controller..."
kubectl -n kube-system get pods -l app.kubernetes.io/name=aws-load-balancer-controller

echo "==> Verifying pods status..."
if ! kubectl -n triage-hub get pods | grep -q "Running"; then
  echo "Error: No running pods found!"
  exit 1
fi
echo "==> Deployment successfully validated!"
