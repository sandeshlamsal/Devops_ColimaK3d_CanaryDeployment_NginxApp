#!/usr/bin/env bash
# install-istio.sh — Installs Istio (minimal profile) on the prod K3d cluster.
set -euo pipefail

echo "==> Switching context to k3d-prod-cluster"
kubectl config use-context k3d-prod-cluster

echo ""
echo "==> Installing Istio (minimal profile + IngressGateway)"
istioctl install --set profile=minimal \
  --set 'components.ingressGateways[0].enabled=true' \
  --set 'components.ingressGateways[0].name=istio-ingressgateway' \
  -y

echo ""
echo "==> Waiting for Istio ingress gateway to be ready"
kubectl -n istio-system rollout status deployment/istio-ingressgateway --timeout=180s

echo ""
echo "==> Enabling sidecar injection on prod namespace"
kubectl apply -f k8s/prod/namespace.yaml

echo ""
echo "==> Verifying Istio installation"
istioctl verify-install

echo ""
echo "Done. Istio is installed. Continue with scripts/install-argo.sh"
