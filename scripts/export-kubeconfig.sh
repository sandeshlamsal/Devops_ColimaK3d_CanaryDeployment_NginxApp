#!/usr/bin/env bash
# export-kubeconfig.sh — Exports each K3d cluster kubeconfig as a base64 string
# ready to paste into GitHub Actions repository secrets.
#
# Secrets required by the workflows:
#   KUBECONFIG_DEV_B64   → used by dev.yml
#   KUBECONFIG_QA_B64    → used by qa.yml
#   KUBECONFIG_PROD_B64  → used by prod.yml
#
# Usage:
#   ./scripts/export-kubeconfig.sh
#
# Then go to:
#   GitHub repo → Settings → Secrets and variables → Actions → New repository secret
# and paste each value.
set -euo pipefail

export_cluster() {
  local cluster=$1
  local secret_name=$2

  echo "==> Exporting kubeconfig for cluster: k3d-${cluster}"

  # k3d writes a standalone kubeconfig with the internal API server address.
  # --server rewrites it to 127.0.0.1 so it works from the GitHub runner
  # only if the runner has direct access (self-hosted). For cloud runners you
  # would replace this with a tunnel or a cloud-hosted cluster endpoint.
  KUBECONFIG_RAW=$(k3d kubeconfig get "${cluster}")

  # Encode to base64 (no line wrapping)
  KUBECONFIG_B64=$(echo "${KUBECONFIG_RAW}" | base64 | tr -d '\n')

  echo ""
  echo "  Secret name : ${secret_name}"
  echo "  Value (copy everything between the lines):"
  echo "  ────────────────────────────────────────────"
  echo "  ${KUBECONFIG_B64}"
  echo "  ────────────────────────────────────────────"
  echo ""
}

export_cluster "dev"  "KUBECONFIG_DEV_B64"
export_cluster "qa"   "KUBECONFIG_QA_B64"
export_cluster "prod" "KUBECONFIG_PROD_B64"

echo "Done. Add the three secrets to:"
echo "  https://github.com/sandeshlamsal/Devops_ColimaK3d_CanaryDeployment_NginxApp/settings/secrets/actions"
