#!/usr/bin/env bash
# setup-clusters.sh — Creates dev, qa, and prod K3d clusters with correct flags.
# Run once on a fresh Colima instance.
set -euo pipefail

echo "==> Starting Colima (4 vCPU / 6 GB RAM)"
colima start --cpu 4 --memory 6 || echo "Colima already running — skipping"

echo ""
echo "==> Creating dev cluster (1 server, port 8080)"
k3d cluster create dev \
  --servers 1 \
  --port "8080:80@loadbalancer" \
  --wait

echo ""
echo "==> Creating qa cluster (1 server + 1 agent, port 8081)"
k3d cluster create qa \
  --servers 1 --agents 1 \
  --port "8081:80@loadbalancer" \
  --wait

echo ""
echo "==> Creating prod cluster (1 server + 2 agents, port 8082, Traefik disabled)"
k3d cluster create prod \
  --servers 1 --agents 2 \
  --port "8082:80@loadbalancer" \
  --k3s-arg "--disable=traefik@server:0" \
  --wait

echo ""
echo "==> Cluster contexts:"
kubectl config get-contexts | grep k3d

echo ""
echo "Done. Run scripts/install-istio.sh and scripts/install-argo.sh to set up the prod cluster."
