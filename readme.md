# Canary Deployment with Colima, K3d & Nginx

A GitOps-style canary deployment pipeline for an Nginx application across three Kubernetes clusters (dev, qa, prod) using [Colima](https://github.com/abiosoft/colima) and [K3d](https://k3d.io), orchestrated via GitHub Actions.

---

## Overview

This project demonstrates a complete multi-environment Kubernetes deployment workflow with:

- **Local Kubernetes clusters** via Colima + K3d (no cloud required)
- **Canary deployments** to safely roll out changes with controlled traffic splitting
- **Environment-specific versioning** — SHA-based tags for dev/qa, dual semver + SHA tags for prod
- **GitHub Actions CI/CD** to automate build, tag, and deploy across all environments

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

Sized for stable + canary workloads running side by side. The stable deployment holds 3 replicas; the canary holds 1, giving a natural 75/25 traffic split when both are live.

| Property | Value |
|----------|-------|
| K3d nodes | 1 server + 2 agents |
| Stable replicas | 3 |
| Canary replicas | 1 |
| CPU request / limit | `100m` / `500m` |
| Memory request / limit | `64Mi` / `256Mi` |
| Host port | `8082 → 80` |

```bash
k3d cluster create prod \
  --servers 1 --agents 2 \
  --port "8082:80@loadbalancer"
```

> **Colima host resources** — the three clusters together need roughly **4 vCPU** and **6 GB RAM** from Colima. Start Colima accordingly:
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

### Approach 2 — Istio VirtualService Weighted Routing ✅ Used in this project

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

### Approach 3 — Argo Rollouts + Istio (Enterprise / Automated)

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

| | Replica Ratio | **Istio VirtualService** | Argo Rollouts + Istio |
|---|---|---|---|
| Traffic precision | Coarse (tied to replicas) | **Exact %** | **Exact %** |
| Extra tooling | None | Istio | Istio + Argo Rollouts + Prometheus |
| Rollback | Manual | Manual (delete canary) | **Automatic (metric-gated)** |
| Header-based routing | No | **Yes** | **Yes** |
| Production-ready | No | Yes | **Yes (enterprise)** |
| Used in this project | No | **Yes** | Future roadmap |

> **This project uses Approach 2 — Istio VirtualService weighted routing.** It gives precise, configurable traffic splitting with header-based testing support, and serves as the foundation for graduating to Argo Rollouts when metric automation is needed.

---

## Rollback Strategy

Rollback decisions are based on the severity and timing of the issue detected.

### Scenario 1 — Issue detected during canary phase

The canary is still live alongside the stable deployment. Stable pods are unaffected.

```bash
# Delete the canary deployment — traffic falls back to stable immediately
kubectl delete deployment nginx-canary -n prod
```

No image change is needed; stable was never replaced.

---

### Scenario 2 — Issue detected after full promotion

The canary has been promoted and all replicas run the new (bad) version. Roll back to the previous known-good semver image.

```bash
# Identify the previous good version from the image tag or release notes
PREVIOUS=v1.2.2

kubectl set image deployment/nginx-stable \
  nginx=ghcr.io/<owner>/nginx-app:${PREVIOUS} \
  -n prod

kubectl rollout status deployment/nginx-stable -n prod
```

The SHA-anchored tag (`v1.2.2-a1b2c3d`) confirms you are pulling exactly the right image:
```bash
kubectl set image deployment/nginx-stable \
  nginx=ghcr.io/<owner>/nginx-app:v1.2.2-a1b2c3d \
  -n prod
```

---

### Scenario 3 — Emergency: automated rollback via GitHub Actions

The prod workflow can trigger a rollback job on failure. It reads the last successful release tag from the GitHub API and re-deploys it:

```yaml
rollback:
  if: failure()
  runs-on: ubuntu-latest
  steps:
    - name: Get last stable release
      id: prev
      run: |
        TAG=$(gh release list --limit 2 --json tagName -q '.[1].tagName')
        echo "tag=$TAG" >> $GITHUB_OUTPUT

    - name: Roll back deployment
      run: |
        kubectl set image deployment/nginx-stable \
          nginx=ghcr.io/${{ github.repository }}:${{ steps.prev.outputs.tag }} \
          -n prod
```

---

### Rollback Decision Matrix

| When detected | Action | Command |
|---------------|--------|---------|
| Canary still live | Delete canary deployment | `kubectl delete deployment nginx-canary -n prod` |
| After full promotion | `kubectl set image` to previous semver | `kubectl set image deployment/nginx-stable nginx=...:v1.2.2 -n prod` |
| Automated (CI failure) | GitHub Actions rollback job | Triggered automatically on workflow failure |

> **Tip:** Always verify the rollback with `kubectl rollout status` and confirm the running image with:
> ```bash
> kubectl get pods -n prod -o jsonpath='{.items[*].spec.containers[*].image}'
> ```

---

## Project Structure

```
.
├── .github/
│   └── workflows/
│       ├── dev.yml          # Build & deploy to dev on push to main
│       ├── qa.yml           # Deploy to qa on PR merge or manual trigger
│       └── prod.yml         # Canary release to prod on semver tag push
├── k8s/
│   ├── dev/
│   │   └── deployment.yaml
│   ├── qa/
│   │   └── deployment.yaml
│   └── prod/
│       ├── deployment-stable.yaml
│       ├── deployment-canary.yaml
│       └── service.yaml
├── nginx/
│   ├── Dockerfile
│   └── default.conf
└── readme.md
```

---

## Prerequisites

- [Colima](https://github.com/abiosoft/colima) — `brew install colima`
- [K3d](https://k3d.io) — `brew install k3d`
- [kubectl](https://kubernetes.io/docs/tasks/tools/) — `brew install kubectl`
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

# Prod — 1 server + 2 agents (supports stable + canary side by side)
k3d cluster create prod \
  --servers 1 --agents 2 \
  --port "8082:80@loadbalancer"
```

### 3. Switch Context

```bash
kubectl config use-context k3d-dev
```

---

## CI/CD Pipeline

| Trigger | Workflow | Target |
|---------|----------|--------|
| Push to `main` | `dev.yml` | dev cluster |
| PR merged to `main` | `qa.yml` | qa cluster |
| Git tag `v*.*.*` pushed | `prod.yml` | prod cluster (canary) |

---

## Canary Rollout via GitHub Actions

The production workflow:
1. Builds and pushes the image tagged with the semver release
2. Deploys the canary Kubernetes manifest (reduced replica count, traffic split via labels)
3. Waits for a configurable stabilization period
4. Promotes to full rollout or triggers rollback on failure

---

## Limitations & Enterprise Roadmap

This project is a local learning environment. The table below maps each limitation to the enterprise-grade alternative.

### Traffic Splitting

| This project | Enterprise equivalent |
|---|---|
| Canary traffic split via replica ratio (1:3 = 25%) — crude, not percentage-based | Weighted routing at the proxy layer via **Argo Rollouts** or **Flagger** + **Istio / Linkerd** — precise `5% → 20% → 50% → 100%` steps independent of replica count |

### Promotion & Rollback

| This project | Enterprise equivalent |
|---|---|
| Manual rollback triggered by a human or on CI job failure | SLO-driven automatic promotion/rollback — **Flagger / Argo Rollouts** query Prometheus metrics (error rate, p99 latency) and roll back automatically if a threshold is breached |

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
| No metrics, logs, or traces; rollback decisions are manual | Full stack: **Prometheus + Grafana** for metrics, **Loki / ELK** for logs, **Jaeger / OpenTelemetry** for traces — all feeding into the automated promotion gate |

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
Feature                  This Project          Enterprise Target
─────────────────────────────────────────────────────────────────
Traffic splitting        Replica ratio         Istio + Argo Rollouts
Auto promotion/rollback  Manual / CI failure   SLO-based (Prometheus)
GitOps                   kubectl apply         ArgoCD / Flux
Secrets                  GitHub Actions vars   Vault + OIDC
Image security           None                  Trivy + Cosign + OPA
Observability            None                  Prometheus + Loki + OTEL
Approval gates           None                  Environment protection rules
Infrastructure           Local single-machine  Managed K8s multi-AZ
Compliance               None                  OPA + audit logs
```

---

## License

MIT
