#!/usr/bin/env bash
# =============================================================================
# Script to validate deployment status of workloads
# =============================================================================
set -euo pipefail

echo "==> Checking pods in triage-hub namespace..."
kubectl -n triage-hub get pods -o wide

echo "==> Checking services..."
kubectl -n triage-hub get svc

echo "==> Checking HPAs..."
kubectl -n triage-hub get hpa

echo "==> Checking ingress/ALB controller..."
kubectl -n kube-system get pods -l app.kubernetes.io/name=aws-load-balancer-controller
