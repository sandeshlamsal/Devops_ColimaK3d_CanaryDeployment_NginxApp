#!/usr/bin/env bash
# install-argo.sh — Installs Argo Rollouts controller and Prometheus on prod cluster.
set -euo pipefail

echo "==> Switching context to k3d-prod-cluster"
kubectl config use-context k3d-prod-cluster

echo ""
echo "==> Installing Argo Rollouts controller"
kubectl create namespace argo-rollouts --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -n argo-rollouts \
  -f https://github.com/argoproj/argo-rollouts/releases/latest/download/install.yaml

echo ""
echo "==> Waiting for Argo Rollouts controller to be ready"
kubectl -n argo-rollouts rollout status deployment/argo-rollouts --timeout=120s

echo ""
echo "==> Installing Prometheus + Grafana (kube-prometheus-stack)"
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update

helm upgrade --install prometheus prometheus-community/kube-prometheus-stack \
  --namespace monitoring --create-namespace \
  --set grafana.enabled=true \
  --set prometheus.prometheusSpec.serviceMonitorSelectorNilUsesHelmValues=false \
  --wait --timeout 5m

echo ""
echo "==> Applying prod manifests"
kubectl apply -f k8s/prod/istio/
kubectl apply -f k8s/prod/service.yaml
kubectl apply -f k8s/prod/analysis-template.yaml
kubectl apply -f k8s/prod/prometheus-servicemonitor.yaml
kubectl apply -f k8s/prod/rollout.yaml

echo ""
echo "==> Rollout status"
kubectl argo rollouts get rollout nginx -n prod

echo ""
echo "Done. Stack is ready. Push a semver tag (e.g. git tag v1.0.0 && git push --tags) to trigger a canary release."
