# Canary Deployment with Colima, K3d & Nginx

A GitOps-style canary deployment pipeline for an Nginx application across three Kubernetes clusters (dev, qa, prod) using [Colima](https://github.com/abiosoft/colima) and [K3d](https://k3d.io), orchestrated via GitHub Actions.

---

## Overview

This project demonstrates a complete multi-environment Kubernetes deployment workflow with:

- **Local Kubernetes clusters** via Colima + K3d (no cloud required)
- **Canary deployments** to safely roll out changes with controlled traffic splitting
- **Environment-specific versioning** — SHA-based tags for dev/qa, semantic versions for prod
- **GitHub Actions CI/CD** to automate build, tag, and deploy across all environments

---

## Clusters

| Cluster | Purpose | Image Tag Format |
|---------|---------|-----------------|
| `dev` | Active development, continuous integration | `dev-<git-sha>` |
| `qa` | Staging and validation | `qa-<git-sha>` |
| `prod` | Production traffic with canary rollout | `v1.2.3` (semantic version) |

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

- **dev / qa** — Docker images are tagged with an environment prefix and the short Git commit SHA:
  ```
  ghcr.io/<owner>/nginx-app:dev-a1b2c3d
  ghcr.io/<owner>/nginx-app:qa-a1b2c3d
  ```
- **prod** — Images are tagged with a semantic release version, triggered by a Git tag push:
  ```
  ghcr.io/<owner>/nginx-app:v1.2.3
  ```

---

## Canary Deployment Strategy

Production releases follow a canary pattern:

1. Deploy the new version alongside the stable version
2. Route a small percentage of traffic (e.g., 10–20%) to the canary
3. Monitor metrics and health checks
4. Gradually shift traffic or roll back if issues are detected
5. Promote canary to stable once validated

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
