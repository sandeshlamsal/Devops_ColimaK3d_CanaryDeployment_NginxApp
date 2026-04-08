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

Production releases follow a canary pattern:

1. Deploy the new version alongside the stable version
2. Route a small percentage of traffic (e.g., 25%) to the canary via replica ratio (1 canary / 3 stable)
3. Monitor metrics and health checks
4. Promote canary to stable or roll back if issues are detected

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

## License

MIT
