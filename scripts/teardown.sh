#!/usr/bin/env bash
# teardown.sh — Removes all project infrastructure in reverse order.
#
# What it removes:
#   1. Argo Rollouts resources (Rollout, AnalysisTemplate) from prod
#   2. Istio resources (Gateway, VirtualService, DestinationRule) from prod
#   3. Prometheus / Grafana (Helm release + namespace)
#   4. Argo Rollouts controller (namespace)
#   5. Istio control plane
#   6. K3d clusters: prod, qa, dev
#   7. Stale kubectl contexts
#   8. Colima (optional — prompts before stopping)
#
# Usage:
#   ./scripts/teardown.sh              # full teardown, prompts before stopping Colima
#   ./scripts/teardown.sh --all        # full teardown including Colima, no extra prompt
#   ./scripts/teardown.sh --clusters   # remove only K3d clusters (keep Colima running)
set -euo pipefail

MODE=${1:-""}

# ── helpers ────────────────────────────────────────────────────────────────────

log()  { echo ""; echo "==> $*"; }
warn() { echo "    [warn] $*"; }

cluster_exists() { k3d cluster list 2>/dev/null | grep -q "^$1 "; }
context_exists() { kubectl config get-contexts "$1" &>/dev/null 2>&1; }

# ── prod workloads ─────────────────────────────────────────────────────────────

teardown_prod_workloads() {
  if ! cluster_exists prod; then
    warn "prod cluster not found — skipping workload teardown"
    return
  fi

  log "Switching to k3d-prod"
  kubectl config use-context k3d-prod

  log "Aborting any in-progress Argo Rollout"
  kubectl argo rollouts abort nginx -n prod 2>/dev/null || true

  log "Removing Argo Rollouts resources from prod"
  kubectl delete rollout nginx                -n prod --ignore-not-found
  kubectl delete analysistemplate nginx-error-rate -n prod --ignore-not-found

  log "Removing Istio resources from prod"
  kubectl delete -f k8s/prod/istio/ --ignore-not-found 2>/dev/null || true

  log "Removing prod workload manifests"
  kubectl delete -f k8s/prod/prometheus-servicemonitor.yaml --ignore-not-found 2>/dev/null || true
  kubectl delete -f k8s/prod/service.yaml                   --ignore-not-found 2>/dev/null || true

  log "Uninstalling Prometheus / Grafana (Helm)"
  helm uninstall prometheus -n monitoring 2>/dev/null || warn "Prometheus Helm release not found — skipping"
  kubectl delete namespace monitoring --ignore-not-found

  log "Uninstalling Argo Rollouts controller"
  kubectl delete -n argo-rollouts \
    -f https://github.com/argoproj/argo-rollouts/releases/latest/download/install.yaml \
    --ignore-not-found 2>/dev/null || true
  kubectl delete namespace argo-rollouts --ignore-not-found

  log "Uninstalling Istio control plane"
  istioctl uninstall --purge -y 2>/dev/null || warn "istioctl not found or Istio already removed"
  kubectl delete namespace istio-system --ignore-not-found

  log "Removing prod namespace"
  kubectl delete namespace prod --ignore-not-found
}

# ── k3d clusters ───────────────────────────────────────────────────────────────

teardown_clusters() {
  for cluster in prod qa dev; do
    if cluster_exists "$cluster"; then
      log "Deleting K3d cluster: $cluster"
      k3d cluster delete "$cluster"
    else
      warn "K3d cluster '$cluster' not found — skipping"
    fi
  done

  log "Removing stale kubectl contexts"
  for ctx in k3d-dev k3d-qa k3d-prod; do
    if context_exists "$ctx"; then
      kubectl config delete-context "$ctx" 2>/dev/null && echo "    removed context: $ctx" || true
    fi
  done
}

# ── colima ─────────────────────────────────────────────────────────────────────

teardown_colima() {
  log "Stopping Colima"
  colima stop 2>/dev/null || warn "Colima already stopped"
}

# ── main ───────────────────────────────────────────────────────────────────────

case "$MODE" in
  --clusters)
    log "Mode: clusters only (Colima stays running)"
    teardown_clusters
    ;;
  --all)
    log "Mode: full teardown including Colima"
    teardown_prod_workloads
    teardown_clusters
    teardown_colima
    ;;
  *)
    log "Mode: full teardown"
    teardown_prod_workloads
    teardown_clusters

    echo ""
    read -r -p "Stop Colima as well? [y/N] " answer
    if [[ "${answer,,}" == "y" ]]; then
      teardown_colima
    else
      echo "    Colima left running."
    fi
    ;;
esac

log "Teardown complete."
echo ""
echo "    To rebuild everything:"
echo "      ./scripts/setup-clusters.sh"
echo "      ./scripts/install-istio.sh"
echo "      ./scripts/install-argo.sh"
