#!/usr/bin/env bash
# =============================================================================
# Helper script to configure kubectl context
# =============================================================================
set -euo pipefail

CLUSTER_NAME="triage-hub-eks"
REGION="us-east-1"

echo "==> Configuring kubectl for EKS cluster: $CLUSTER_NAME..."
aws eks update-kubeconfig --region "$REGION" --name "$CLUSTER_NAME"
