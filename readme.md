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
colima start --cpu 4 --memory 8 --kubernetes
```

### 2. Create Clusters

```bash
k3d cluster create dev  --port "8080:80@loadbalancer"
k3d cluster create qa   --port "8081:80@loadbalancer"
k3d cluster create prod --port "8082:80@loadbalancer"
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
