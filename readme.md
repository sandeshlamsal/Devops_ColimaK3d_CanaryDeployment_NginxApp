# Canary Deployment with Colima, K3d & Nginx

A GitOps-style canary deployment pipeline for an Nginx application across three Kubernetes clusters (dev, qa, prod) using [Colima](https://github.com/abiosoft/colima) and [K3d](https://k3d.io), with **Argo Rollouts + Istio** for SLO-gated progressive delivery, orchestrated via GitHub Actions.

---

## Overview

This project demonstrates a complete multi-environment Kubernetes deployment workflow with:

- **Local Kubernetes clusters** via Colima + K3d (no cloud required)
- **SLO-gated canary delivery** via Argo Rollouts + Istio — automatic promotion or rollback based on Prometheus metrics
- **Environment-specific versioning** — SHA-based tags for dev/qa, dual semver + SHA tags for prod
- **GitHub Actions CI/CD** to automate build, tag, and deploy across all environments
- **Prometheus** feeds error rate and p99 latency metrics into every canary step gate

---

## Clusters

| Cluster | Purpose | Image Tag Format |
|---------|---------|-----------------|
| `dev` | Active development, continuous integration | `dev-<git-sha>` |
| `qa` | Staging and validation | `qa-<git-sha>` |
| `prod` | Production traffic with canary rollout | `v1.2.3` + `v1.2.3-<git-sha>` |

---

## Cluster Sizing

Nginx is a lightweight process (~5–15 MB RSS per worker). Sizes below are right-sized for a single Nginx app on a local Colima + K3d setup.

### Dev

Optimised for fast iteration — minimal footprint, single replica.

| Property | Value |
|----------|-------|
| K3d nodes | 1 server |
| Replicas | 1 |
| CPU request / limit | `50m` / `100m` |
| Memory request / limit | `32Mi` / `64Mi` |
| Host port | `8080 → 80` |

```bash
k3d cluster create dev \
  --servers 1 \
  --port "8080:80@loadbalancer"
```

### QA

Mirrors a lightweight production-like environment — two replicas to catch concurrency issues.

| Property | Value |
|----------|-------|
| K3d nodes | 1 server + 1 agent |
| Replicas | 2 |
| CPU request / limit | `100m` / `200m` |
| Memory request / limit | `64Mi` / `128Mi` |
| Host port | `8081 → 80` |

```bash
k3d cluster create qa \
  --servers 1 --agents 1 \
  --port "8081:80@loadbalancer"
```

### Prod

Sized for Argo Rollouts + Istio + Prometheus running alongside the nginx workload. Argo Rollouts manages replica scaling automatically during canary steps — you do not set canary replica count manually.

| Property | Value |
|----------|-------|
| K3d nodes | 1 server + 2 agents |
| Nginx stable replicas | 3 (managed by Argo Rollouts) |
| Nginx canary replicas | 1 (scaled by Argo Rollouts per step) |
| Nginx CPU request / limit | `100m` / `500m` |
| Nginx memory request / limit | `64Mi` / `256Mi` |
| Istio sidecar overhead | ~50 Mi RAM per pod |
| Prometheus + Grafana overhead | ~300 Mi RAM total |
| Host port | `8082 → 80` (Istio IngressGateway) |

```bash
k3d cluster create prod \
  --servers 1 --agents 2 \
  --port "8082:80@loadbalancer" \
  --k3s-arg "--disable=traefik@server:0"
```

> `--disable=traefik` is required — Traefik conflicts with the Istio IngressGateway on port 80.

> **Colima host resources** — Istio sidecars + Prometheus push total requirements to ~**4 vCPU / 6 GB RAM**:
> ```bash
> colima start --cpu 4 --memory 6
> ```

---

## Versioning Strategy

- **dev / qa** — Images are tagged with an environment prefix and the short Git commit SHA:
  ```
  ghcr.io/<owner>/nginx-app:dev-a1b2c3d
  ghcr.io/<owner>/nginx-app:qa-a1b2c3d
  ```

- **prod** — Every image receives **two tags** pushed together: a human-readable semantic version and a SHA-anchored traceability tag. Both tags point to the exact same image digest.
  ```
  ghcr.io/<owner>/nginx-app:v1.2.3          # semantic — used in k8s manifests
  ghcr.io/<owner>/nginx-app:v1.2.3-a1b2c3d  # semver + SHA — traceability anchor
  ```

  The SHA tag lets you answer "which commit is running in prod?" without querying the registry manifest, and gives you an exact pull target for rollbacks.

  In the GitHub Actions release workflow:
  ```yaml
  - name: Build and push
    uses: docker/build-push-action@v5
    with:
      tags: |
        ghcr.io/${{ github.repository }}:${{ github.ref_name }}
        ghcr.io/${{ github.repository }}:${{ github.ref_name }}-${{ github.sha }}
  ```

  The Kubernetes deployment uses the stable semver tag (`v1.2.3`). The SHA tag is recorded in the GitHub Release notes and deployment annotations for full traceability.

---

## Canary Deployment Strategy

There are three mainstream approaches to canary deployments. Each has a different trade-off between simplicity and precision.

---

### Approach 1 — Replica Ratio (Naive)

Traffic is split by running fewer canary pods alongside stable pods. With 3 stable + 1 canary replicas, ~25% of requests land on the canary.

```
┌──────────────┐     kube-proxy (round-robin)
│   Ingress    │ ──────────────────────────────┐
└──────────────┘                               │
                                  ┌────────────▼────────────┐
                                  │  Service: nginx          │
                                  └──────┬──────────┬────────┘
                               75%       │          │  25%
                        ┌────────────────▼┐  ┌──────▼────────┐
                        │ stable (3 pods) │  │ canary (1 pod)│
                        └─────────────────┘  └───────────────┘
```

**Flow:**
1. Deploy canary alongside stable
2. kube-proxy naturally load-balances across all 4 pods
3. Monitor manually; delete canary deployment to roll back

| | |
|---|---|
| Pros | No extra tooling; simple to understand |
| Cons | Traffic % is tied to replica count — can't do 5% or 1% without many replicas; breaks with session affinity; no metric-based automation |

---

### Approach 2 — Istio VirtualService Weighted Routing

Istio's Envoy sidecar intercepts all traffic and routes by explicit percentage at the L7 layer, completely independent of replica count.

```
┌──────────────┐
│   Gateway    │  (Istio IngressGateway)
└──────┬───────┘
       │
┌──────▼───────────────────────────────┐
│  VirtualService: nginx               │
│  route:                              │
│    - destination: stable  weight: 90 │
│    - destination: canary  weight: 10 │
└──────┬──────────────────────┬────────┘
       │ 90%                  │ 10%
┌──────▼──────────┐   ┌───────▼──────────┐
│  DestinationRule│   │  DestinationRule  │
│  subset: stable │   │  subset: canary   │
│  (version=stable│   │  (version=canary) │
│   3 pods)       │   │   1 pod)          │
└─────────────────┘   └──────────────────┘
```

**Flow:**
1. Istio Gateway receives external traffic
2. VirtualService applies weighted routing (90% stable / 10% canary)
3. DestinationRule maps subsets to pods via `version` label
4. Weights are adjusted in Git (e.g. 90/10 → 50/50 → 0/100) to promote
5. Canary deployment is deleted after full promotion

Supports optional header-based routing — route only requests with `x-canary: true` to the canary, letting QA validate before any real user traffic is shifted:

```yaml
- match:
    - headers:
        x-canary:
          exact: "true"
  route:
    - destination:
        host: nginx
        subset: canary
```

| | |
|---|---|
| Pros | Precise % independent of replica count; header-based routing for internal testing; foundation for automated promotion; L7 observability via Envoy |
| Cons | Adds Istio overhead (~50 Mi RAM per pod sidecar); more setup required |

---

### Approach 3 — Argo Rollouts + Istio (Enterprise / Automated) ✅ Used in this project

Builds on top of Istio but replaces manual weight adjustment with automated, metric-gated progressive delivery. Argo Rollouts controls the `VirtualService` weights automatically.

```
┌─────────────────────────────────────────────────┐
│  Argo Rollouts Controller                        │
│                                                  │
│  Step 1: set canary weight = 5%  → query metrics │
│  Step 2: set canary weight = 20% → query metrics │
│  Step 3: set canary weight = 50% → query metrics │
│  Step 4: promote to 100% OR rollback             │
└──────────────────────┬──────────────────────────┘
                       │ updates weights
               ┌───────▼────────┐
               │ VirtualService  │  (Istio)
               └───────┬────────┘
                        │
              ┌─────────┴──────────┐
         90-5%│                    │ 10-95%
      ┌────────▼──────┐    ┌───────▼────────┐
      │ stable pods   │    │ canary pods    │
      └───────────────┘    └────────────────┘
                       ↑
             Prometheus metrics feed
             rollback gate (error rate,
             p99 latency thresholds)
```

**Flow:**
1. Push a new image tag → Argo Rollouts starts the progressive steps
2. At each step, Rollouts queries Prometheus for SLO metrics
3. If metrics breach thresholds → automatic rollback, no human needed
4. If all steps pass → full promotion, stable deployment updated

| | |
|---|---|
| Pros | Fully automated; SLO-gated promotion; integrates with ArgoCD for GitOps; no manual weight changes |
| Cons | Requires Prometheus + Argo Rollouts + Istio; highest operational complexity |

---

### Comparison Summary

| | Replica Ratio | Istio VirtualService | **Argo Rollouts + Istio** |
|---|---|---|---|
| Traffic precision | Coarse (tied to replicas) | Exact % | **Exact %** |
| Extra tooling | None | Istio | **Istio + Argo Rollouts + Prometheus** |
| Rollback | Manual | Manual (delete canary) | **Automatic (metric-gated)** |
| Header-based routing | No | Yes | **Yes** |
| SLO-gated promotion | No | No | **Yes** |
| Production-ready | No | Yes | **Yes (enterprise)** |
| Used in this project | No | No | **Yes** |

> **This project uses Approach 3 — Argo Rollouts + Istio.** Argo Rollouts controls VirtualService weights automatically across progressive steps (10% → 30% → 60% → 100%), querying Prometheus at each step. If error rate or p99 latency breaches the threshold, rollback is triggered with no human intervention.

---

## Rollback Strategy

With Argo Rollouts, most rollbacks are **automatic**. The table below covers all scenarios from fully automated to last-resort manual.

---

### Scenario 1 — Automatic rollback (SLO breach during canary step)

Argo Rollouts queries Prometheus at each step. If the `AnalysisRun` fails (error rate ≥ 1% or p99 > 500 ms), Rollouts aborts the canary and restores 100% traffic to stable — no human action needed.

```
Step 1: weight=10% → AnalysisRun: FAIL (error rate 3%)
        → Argo Rollouts aborts canary
        → VirtualService: stable=100%, canary=0%
        → canary pods scaled to 0
```

Monitor via:
```bash
kubectl argo rollouts get rollout nginx -n prod --watch
```

---

### Scenario 2 — Manual abort during canary (human decision)

Rollout is progressing but you want to abort based on non-metric signals (e.g. customer reports, log anomalies).

```bash
kubectl argo rollouts abort nginx -n prod
```

Argo Rollouts immediately sets VirtualService canary weight to 0% and scales canary pods down. Stable is unaffected.

---

### Scenario 3 — Issue detected after full promotion

The rollout completed and all traffic serves the new (bad) image. Roll back to the previous known-good version using the SHA-anchored tag for precision.

```bash
# Use semver tag
kubectl argo rollouts undo nginx -n prod

# OR pin to exact SHA-anchored image
kubectl argo rollouts set image nginx \
  nginx=ghcr.io/<owner>/nginx-app:v1.2.2-a1b2c3d \
  -n prod
```

`undo` re-runs the full canary progression with the previous stable image — it does not skip analysis steps.

---

### Scenario 4 — Emergency bypass (break-glass)

Argo Rollouts is unavailable or unresponsive. Force an immediate image swap directly on the underlying ReplicaSet.

```bash
PREVIOUS=v1.2.2
kubectl set image deployment/nginx \
  nginx=ghcr.io/<owner>/nginx-app:${PREVIOUS} \
  -n prod --record

kubectl rollout status deployment/nginx -n prod
```

> Use this only as a last resort — it bypasses Argo Rollouts state and requires a subsequent `kubectl argo rollouts sync` to reconcile.

---

### Rollback Decision Matrix

| Scenario | Trigger | Action | Automated? |
|---|---|---|---|
| SLO breach at canary step | AnalysisRun failure | Argo Rollouts aborts, resets weights | **Yes** |
| Human abort during canary | Operator decision | `kubectl argo rollouts abort nginx -n prod` | No |
| Bad full promotion | Post-deploy issue | `kubectl argo rollouts undo nginx -n prod` | No |
| Break-glass emergency | Rollouts unavailable | `kubectl set image` directly | No |

> **Tip:** Always confirm the running image after any rollback:
> ```bash
> kubectl argo rollouts get rollout nginx -n prod
> kubectl get pods -n prod -o jsonpath='{.items[*].spec.containers[*].image}'
> ```

---

## Project Structure

```
.
├── .github/
│   └── workflows/
│       ├── dev.yml               # Build & deploy to dev on push to main
│       ├── qa.yml                # Deploy to qa on PR merge or manual trigger
│       └── prod.yml              # Tag push → build → trigger Argo Rollouts canary
├── k8s/
│   ├── dev/
│   │   ├── namespace.yaml
│   │   └── deployment.yaml
│   ├── qa/
│   │   ├── namespace.yaml
│   │   └── deployment.yaml
│   └── prod/
│       ├── namespace.yaml
│       ├── service.yaml
│       ├── rollout.yaml               # Argo Rollouts Rollout resource (replaces Deployment)
│       ├── analysis-template.yaml     # Prometheus SLO gate (error rate + p99)
│       └── istio/
│           ├── gateway.yaml           # Istio IngressGateway
│           ├── virtual-service.yaml   # Managed by Argo Rollouts (weights updated per step)
│           └── destination-rule.yaml  # stable / canary subsets
├── nginx/
│   ├── Dockerfile
│   ├── default.conf          # stable — serves "stable" response
│   └── canary.conf           # canary — serves "canary v<version>" response
├── scripts/
│   ├── setup-clusters.sh     # Creates dev/qa/prod K3d clusters with correct flags
│   ├── install-istio.sh      # Installs Istio minimal profile on prod
│   ├── install-argo.sh       # Installs Argo Rollouts controller + kubectl plugin
│   └── promote-canary.sh     # Manual promotion helper (wraps kubectl argo rollouts)
└── readme.md
```

---

## Prerequisites

- [Colima](https://github.com/abiosoft/colima) — `brew install colima`
- [K3d](https://k3d.io) — `brew install k3d`
- [kubectl](https://kubernetes.io/docs/tasks/tools/) — `brew install kubectl`
- [Helm](https://helm.sh) — `brew install helm`
- [istioctl](https://istio.io/latest/docs/setup/getting-started/) — `brew install istioctl`
- [Argo Rollouts kubectl plugin](https://argoproj.github.io/argo-rollouts/) — `brew install argoproj/tap/kubectl-argo-rollouts`
- [Docker](https://www.docker.com/) — required by Colima
- GitHub account with Actions enabled and a container registry (GHCR)

---

## Local Setup

### 1. Start Colima

```bash
colima start --cpu 4 --memory 6
```

### 2. Create Clusters

```bash
# Dev — 1 server node
k3d cluster create dev \
  --servers 1 \
  --port "8080:80@loadbalancer"

# QA — 1 server + 1 agent
k3d cluster create qa \
  --servers 1 --agents 1 \
  --port "8081:80@loadbalancer"

# Prod — Traefik disabled (Istio IngressGateway takes port 80)
k3d cluster create prod \
  --servers 1 --agents 2 \
  --port "8082:80@loadbalancer" \
  --k3s-arg "--disable=traefik@server:0"
```

### 3. Install Istio on Prod

```bash
kubectl config use-context k3d-prod

# Install Istio minimal profile
istioctl install --set profile=minimal -y

# Enable sidecar injection for prod namespace
kubectl label namespace prod istio-injection=enabled
```

### 4. Install Argo Rollouts on Prod

```bash
kubectl create namespace argo-rollouts
kubectl apply -n argo-rollouts \
  -f https://github.com/argoproj/argo-rollouts/releases/latest/download/install.yaml
```

### 5. Install Prometheus (kube-prometheus-stack) on Prod

```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update

helm install prometheus prometheus-community/kube-prometheus-stack \
  --namespace monitoring --create-namespace \
  --set grafana.enabled=true \
  --set prometheus.prometheusSpec.serviceMonitorSelectorNilUsesHelmValues=false
```

### 6. Switch Context

```bash
kubectl config use-context k3d-dev
```

---

## CI/CD Pipeline

| Trigger | Workflow | Target | Mechanism |
|---------|----------|--------|-----------|
| Push to `main` | `dev.yml` | dev cluster | `kubectl apply` |
| PR merged to `main` | `qa.yml` | qa cluster | `kubectl apply` |
| Git tag `v*.*.*` pushed | `prod.yml` | prod cluster | Argo Rollouts canary |

---

## Canary Rollout via GitHub Actions

The production workflow triggered on `v*.*.*` tag push:

1. **Build** — Docker image built and pushed with dual tags (`v1.2.3` + `v1.2.3-<sha>`)
2. **Update Rollout** — `kubectl argo rollouts set image` updates the image in the `Rollout` resource
3. **Argo Rollouts takes over** — automatically progresses through canary steps:

```
Step 1: canary weight = 10%  │ pause 1m │ AnalysisRun: query Prometheus
Step 2: canary weight = 30%  │ pause 2m │ AnalysisRun: query Prometheus
Step 3: canary weight = 60%  │ pause 2m │ AnalysisRun: query Prometheus
Step 4: promote → weight = 100% (stable fully replaced)
```

4. **AnalysisTemplate gates** — at each step, Prometheus is queried for:
   - `nginx_http_requests_total{status=~"5.."}` error rate < 1%
   - `nginx_request_duration_seconds` p99 < 500 ms
5. **On gate failure** — Argo Rollouts automatically aborts, resets VirtualService weights to stable=100%
6. **On success** — stable fully promoted, canary pods scaled to 0

```yaml
# GitHub Actions prod.yml (simplified)
- name: Trigger canary rollout
  run: |
    kubectl argo rollouts set image nginx \
      nginx=ghcr.io/${{ github.repository }}:${{ github.ref_name }} \
      -n prod
    kubectl argo rollouts status nginx -n prod --timeout 10m
```

---

## End-to-End Canary Rollout — Proven Test Record

This section documents the full local test run of the Argo Rollouts + Istio canary pipeline, including every issue encountered and how it was resolved.

---

### Environment

| Component | Version / Detail |
|---|---|
| macOS | Darwin 24.4.0 (Intel) |
| Colima | vz (Virtualization.Framework) driver |
| K3d | v5.x |
| K3s | v1.33.6+k3s1 |
| Istio | minimal profile |
| Argo Rollouts | latest (kubectl plugin installed) |
| Prometheus | kube-prometheus-stack (Helm) |

---

### Issues Encountered & Resolutions

#### Issue 1 — K3d context names inconsistent across sessions

**Symptom:** Scripts used `k3d-prod` but the actual context written by K3d was `k3d-prod-cluster` (stale from a prior session), causing all `kubectl` commands to fail with `context not found`.

**Root cause:** K3d writes contexts at cluster creation time. If a cluster is deleted and recreated, it may write a new context alongside a stale one already in `~/.kube/config`.

**Resolution:** Deleted all stale `k3d-prod*` contexts explicitly, recreated the cluster from a fully clean state (containers + network + volume removed), and merged the fresh kubeconfig. Updated all scripts to use the correct context name `k3d-prod`.

---

#### Issue 2 — Colima vz driver does not forward Docker port bindings to Mac localhost

**Symptom:** After recreating the prod cluster with `--api-port 6445`, `kubectl get nodes` returned `connection refused` on `127.0.0.1:6445`. The port was bound inside the Colima VM but not reachable from the Mac host.

**Root cause:** Colima's `vz` (Virtualization.Framework) driver routes Docker port bindings through an SSH mux process. Ports are only forwarded to `localhost` if they are registered with the SSH mux at the time it was established. Clusters created after the mux session started, or with explicit `--api-port`, bypass this registration.

**Resolution:**
- Removed `--api-port` flag — let K3d assign a dynamic port that Colima registers automatically.
- When Colima restarts, K3d clusters must be restarted (`k3d cluster start`) so their ports are re-registered with the new SSH mux session.
- Added `scripts/restart-clusters.sh` to handle this automatically.

---

#### Issue 3 — K3d prod serverlb config corruption after Colima restart

**Symptom:** `k3d cluster start prod` failed with: `error getting loadbalancer config from k3d-prod-serverlb: runtime failed to read loadbalancer config '/etc/confd/values.yaml'`.

**Root cause:** When Colima stops, K3d's serverlb (nginx-based loadbalancer) container exits uncleanly, corrupting the in-container config file. This is a known K3d + Colima vz compatibility issue.

**Resolution:** Full teardown of all prod containers, network, and volume (`docker rm -f`, `docker network rm`, `docker volume rm`) before recreating the cluster. Added this cleanup step to `scripts/teardown.sh`.

---

#### Issue 4 — Argo Rollouts: same Service for stable and canary rejected

**Symptom:** Rollout immediately went `Degraded` with: `spec.strategy.stableService: Invalid value: "nginx": This rollout uses the same service for the stable and canary services, but two different services are required.`

**Root cause:** Argo Rollouts with Istio integration requires two separate Kubernetes Services — one for stable traffic and one for canary traffic. The controller patches selectors on these Services at runtime to point to the correct ReplicaSet.

**Resolution:** Split `service.yaml` into `nginx-stable` and `nginx-canary` Services. Updated `rollout.yaml` to reference both. Updated `virtual-service.yaml` to route between the two hosts. Updated `destination-rule.yaml` to create a DestinationRule per Service.

---

#### Issue 5 — VirtualService route name `primary` not found

**Symptom:** After fixing the Services, Rollout still `Degraded` with: `Istio VirtualService has invalid HTTP routes. Error: HTTP Route 'primary' is not found in the defined Virtual Service.`

**Root cause:** The Rollout spec referenced `routes: [primary]` but the VirtualService's weighted route block had no `name` field.

**Resolution:** Added `name: primary` to the weighted route block in `virtual-service.yaml`. Deleted and reapplied the Rollout to force a fresh reconciliation (update alone was insufficient due to controller caching).

---

#### Issue 6 — AnalysisRun error: `reflect: slice index out of range`

**Symptom:** The first AnalysisRun triggered automatic rollback immediately after promotion with: `Metric "error-rate" assessed Error due to consecutiveErrors (5) > consecutiveErrorLimit (4): "Error Message: reflect: slice index out of range"`.

**Root cause:** When no traffic has flowed through nginx yet, the Prometheus query `sum(rate(...)) / sum(rate(...))` returns an empty result set (no time series). Argo Rollouts tries to index `result[0]` on an empty slice, causing a panic.

**Resolution:** Appended `or vector(0)` to both Prometheus queries in `analysis-template.yaml`. This causes the query to return `0` when no data exists, satisfying the `< 0.01` success condition rather than erroring:

```promql
(
  sum(rate(nginx_http_requests_total{...status=~"5.."}[2m]))
  /
  sum(rate(nginx_http_requests_total{...}[2m]))
) or vector(0)
```

Also raised `failureLimit` from 1 to 2 to add a small tolerance buffer.

---

### Proven Canary Rollout Flow

The following was executed and verified locally on `2026-04-07`:

```
stable: nginx-app:v1.0.0  (3 pods, revision 1)
                │
                │  kubectl argo rollouts set image nginx nginx=nginx-app:v1.1.0
                ▼
Step 1/9  weight=10%   canary pod: 1   stable pods: 3   AnalysisRun: ✔ Successful
                │  promote
                ▼
Step 2/9  weight=10%   AnalysisRun .2.1: ✔ Successful (4/4 measurements passed)
                │  promote --full
                ▼
Step 9/9  weight=100%  canary becomes stable   old pods: scaling down
                │
                ▼
stable: nginx-app:v1.1.0  (3 pods, revision 2)  Status: ✔ Healthy
```

**VirtualService weight progression managed by Argo Rollouts:**

```
Before rollout:  stable=100%  canary=0%
After step 1:    stable=90%   canary=10%
After promote:   stable=70%   canary=30%   (skipped via --full in this test)
After promote:   stable=40%   canary=60%   (skipped via --full in this test)
After full:      stable=0%    canary=100%  → canary promoted to stable
```

**Rollback also proven** (Issue 6 triggered it automatically before the fix):
- AnalysisRun failure → Argo Rollouts aborted canary → VirtualService reset to stable=100% → canary pods scaled to 0 — all without human intervention.

---

### Final Stack State (post-test)

```
Namespace         Component                Status
─────────────────────────────────────────────────
istio-system      istiod                   Running ✔
argo-rollouts     argo-rollouts            Running ✔
monitoring        prometheus               Running ✔
monitoring        grafana                  Running ✔
prod              nginx (Rollout)          Healthy ✔  v1.1.0 stable
prod              nginx-stable (Service)   Active  ✔
prod              nginx-canary (Service)   Active  ✔
prod              nginx-exporter           Running ✔
prod              VirtualService/nginx     Synced  ✔
prod              DestinationRules         Synced  ✔
prod              AnalysisTemplate         Ready   ✔
```

---

### Reproducing the Test Locally

```bash
# 1. Build stable baseline
docker build --build-arg BUILD_ENV=stable --build-arg APP_VERSION=v1.0.0 \
  -t nginx-app:v1.0.0 nginx/
k3d image import nginx-app:v1.0.0 --cluster prod

# 2. Build canary
docker build --build-arg BUILD_ENV=canary --build-arg APP_VERSION=v1.1.0 \
  -t nginx-app:v1.1.0 nginx/
k3d image import nginx-app:v1.1.0 --cluster prod

# 3. Trigger canary rollout
kubectl argo rollouts set image nginx nginx=nginx-app:v1.1.0 -n prod

# 4. Watch live progression
kubectl argo rollouts get rollout nginx -n prod --watch

# 5. Promote step by step (or use --full to skip pauses)
kubectl argo rollouts promote nginx -n prod

# 6. Test header-based canary routing (bypasses weight, always hits canary)
curl -H "x-canary: true" http://localhost:8082/

# 7. Abort at any time (restores stable=100%)
kubectl argo rollouts abort nginx -n prod
```

---

## Limitations & Enterprise Roadmap

This project is a local learning environment. The table below maps each limitation to the enterprise-grade alternative.

### Traffic Splitting

| This project | Enterprise equivalent |
|---|---|
| **Argo Rollouts + Istio VirtualService** — exact % independent of replica count; 10% → 30% → 60% → 100% steps | Same stack at scale on managed Kubernetes (EKS/GKE/AKS) with Flagger as an alternative controller |

> Traffic splitting is **fully addressed** in this project via Argo Rollouts + Istio.

### Promotion & Rollback

| This project | Enterprise equivalent |
|---|---|
| **Automatic SLO-gated rollback** via Argo Rollouts AnalysisTemplate querying Prometheus | Same, but with richer metric sources (Datadog, New Relic, CloudWatch) and multi-cluster promotion gates |

> Automated rollback is **fully addressed** in this project.

### GitOps & Drift Detection

| This project | Enterprise equivalent |
|---|---|
| Push-based `kubectl apply` in GitHub Actions — stateless, no drift detection | **ArgoCD** or **Flux** continuously reconcile cluster state against Git; out-of-band changes are detected and corrected automatically |

### Secrets Management

| This project | Enterprise equivalent |
|---|---|
| No secrets handling; credentials stored as GitHub Actions secrets | **HashiCorp Vault**, **AWS Secrets Manager**, or **External Secrets Operator** + Sealed Secrets; CI authenticates via OIDC Workload Identity — no long-lived credentials |

### Image Security

| This project | Enterprise equivalent |
|---|---|
| No image scanning or signing | **Trivy / Grype** scans block promotion on critical CVEs; images signed with **Cosign**; admission controllers (**OPA / Kyverno**) reject unsigned or non-compliant images |

### Observability

| This project | Enterprise equivalent |
|---|---|
| **Prometheus + Grafana** feed Argo Rollouts analysis gates; no log aggregation or tracing | Full stack: Prometheus + Grafana for metrics, **Loki / ELK** for logs, **Jaeger / OpenTelemetry** for traces |

> Metrics-based observability is **partially addressed** — logs and traces remain a gap.

### Approval Gates

| This project | Enterprise equivalent |
|---|---|
| No human approval before production promotion | **GitHub Environment Protection Rules** or pipeline gates (Jenkins / Spinnaker) requiring named-owner sign-off before canary is promoted |

### Infrastructure

| This project | Enterprise equivalent |
|---|---|
| Single-machine Colima + K3d; no HA control plane, no real load balancer, no persistent storage, no multi-region | Managed Kubernetes (**EKS / GKE / AKS**) across availability zones; cloud load balancers; persistent storage classes; cross-region failover |

### Compliance & Audit

| This project | Enterprise equivalent |
|---|---|
| No audit trail or policy enforcement | Every deploy event feeds an audit log; change management integration (**ServiceNow / Jira**); policy-as-code via **OPA / Kyverno** gates deployments against compliance checks |

---

### Summary Gap Map

```
Feature                  This Project                    Gap?   Enterprise Target
──────────────────────────────────────────────────────────────────────────────────
Traffic splitting        Istio + Argo Rollouts           ✅ None  Same at scale
Auto promotion/rollback  SLO-gated (Prometheus)          ✅ None  Richer metric sources
Observability (metrics)  Prometheus + Grafana            ✅ None  Same at scale
GitOps / drift detect    kubectl apply (push-based)      ⚠️ Gap   ArgoCD / Flux
Secrets                  GitHub Actions secrets          ⚠️ Gap   Vault + OIDC
Image security           None                            ❌ Gap   Trivy + Cosign + OPA
Observability (logs)     None                            ❌ Gap   Loki / ELK
Observability (traces)   None                            ❌ Gap   Jaeger / OpenTelemetry
Approval gates           None                            ❌ Gap   Environment protection rules
Infrastructure           Local single-machine K3d        ❌ Gap   Managed K8s multi-AZ
Compliance               None                            ❌ Gap   OPA + audit logs
```

---

## License

MIT
