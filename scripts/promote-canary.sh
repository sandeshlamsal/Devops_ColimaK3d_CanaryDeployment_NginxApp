#!/usr/bin/env bash
# promote-canary.sh — Manual canary promotion helper.
# Usage:
#   ./scripts/promote-canary.sh           # promote to next step
#   ./scripts/promote-canary.sh --full    # skip all remaining steps and fully promote
#   ./scripts/promote-canary.sh --abort   # abort canary, restore stable
set -euo pipefail

NAMESPACE=prod
ROLLOUT=nginx

kubectl config use-context k3d-prod

ACTION=${1:-""}

case "$ACTION" in
  --full)
    echo "==> Fully promoting canary (skipping remaining steps)"
    kubectl argo rollouts promote "$ROLLOUT" -n "$NAMESPACE" --full
    ;;
  --abort)
    echo "==> Aborting canary — traffic will be restored to stable"
    kubectl argo rollouts abort "$ROLLOUT" -n "$NAMESPACE"
    ;;
  *)
    echo "==> Promoting to next canary step"
    kubectl argo rollouts promote "$ROLLOUT" -n "$NAMESPACE"
    ;;
esac

echo ""
echo "==> Current rollout state:"
kubectl argo rollouts get rollout "$ROLLOUT" -n "$NAMESPACE"
