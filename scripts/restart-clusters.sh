#!/usr/bin/env bash
# restart-clusters.sh — Restores all K3d clusters after a Colima restart.
#
# Colima's vz driver registers API port forwards via its SSH mux at startup.
# When Colima restarts, K3d clusters are left stopped. This script starts them
# back up so the new SSH mux session picks up their ports.
#
# Usage:
#   ./scripts/restart-clusters.sh
set -euo pipefail

log() { echo ""; echo "==> $*"; }

log "Starting Colima (if not already running)"
colima start --cpu 4 --memory 6 2>/dev/null || echo "    Already running"

log "Starting K3d clusters"
for cluster in dev qa prod; do
  echo -n "    Starting ${cluster}... "
  k3d cluster start "${cluster}" 2>&1 | grep -E "Started|already running|ERRO" | head -1 || true
  echo "done"
done

log "Waiting 30s for K3s APIs to become ready"
sleep 30

log "Cluster connectivity check"
all_ok=true
for cluster in dev qa prod; do
  echo -n "    k3d-${cluster}: "
  if kubectl get nodes --context "k3d-${cluster}" --no-headers 2>/dev/null | awk '{print $1, $2}' | tr '\n' ' '; then
    echo ""
  else
    echo "NOT READY — wait a few more seconds and retry"
    all_ok=false
  fi
done

echo ""
if $all_ok; then
  echo "All clusters are up. Continue with your workflow."
else
  echo "Some clusters are still starting. Run: kubectl get nodes --context k3d-<name>"
fi
