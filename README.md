# pharmops-gitops

GitOps configuration repository for the PharmOps platform. ArgoCD watches this repo and syncs everything on the cluster automatically.

> **Companion repo:** [`pharmops`](https://github.com/ravdy/pharmops) contains Terraform for AWS infrastructure.

---

## What Lives Here

| Folder | Purpose |
|--------|---------|
| `pharma-service/` | Shared Helm chart used by 4 microservices |
| `envs/` | Per-environment values files (dev / qa / prod) |
| `k8s-manifests/` | Raw Kubernetes manifests (pharma-ui — no Helm) |
| `argocd/` | ArgoCD AppProject + per-service Application manifests |
| `k8s/` | Namespaces, RBAC, ingress config, External Secrets |
| `db-init/` | PostgreSQL schema initialisation scripts |

---

## Repository Structure

```
pharmops-gitops/
├── pharma-service/                   # Shared Helm chart
│   ├── Chart.yaml
│   ├── values.yaml                   # Default values (overridden per service)
│   └── templates/
│       ├── deployment.yaml
│       ├── service.yaml
│       ├── ingress.yaml
│       ├── configmap.yaml
│       ├── serviceaccount.yaml
│       ├── hpa.yaml
│       └── _helpers.tpl
│
├── envs/                             # Per-environment Helm values
│   ├── dev/
│   │   ├── values-api-gateway.yaml
│   │   ├── values-auth-service.yaml
│   │   ├── values-catalog-service.yaml
│   │   └── values-notification-service.yaml
│   ├── qa/
│   └── prod/
│
├── k8s-manifests/                    # Raw K8s manifests (no Helm)
│   └── pharma-ui/                    # pharma-ui deployed without Helm
│       ├── serviceaccount.yaml
│       ├── configmap.yaml
│       ├── deployment.yaml
│       ├── service.yaml
│       └── ingress.yaml
│
├── argocd/
│   ├── install/
│   │   ├── argocd-namespace.yaml
│   │   └── argocd-ingress.yaml
│   ├── projects/
│   │   └── pharma-project.yaml       # ArgoCD AppProject
│   └── apps/
│       └── dev/
│           ├── pharma-ui/application.yaml
│           ├── api-gateway/application.yaml
│           ├── auth-service/application.yaml
│           ├── notification-service/application.yaml
│           └── catalog-service/application.yaml
│
├── k8s/
│   ├── namespaces.yaml
│   ├── rbac/
│   ├── ingress/
│   └── external-secrets/
│
└── db-init/
    └── 01-schemas.sql
```

---

## Deployment Strategy

| Service | Strategy | Why |
|---------|----------|-----|
| `pharma-ui` | Raw K8s manifests | Demonstrates the difficulty without Helm |
| `api-gateway` | Helm | Shared chart + values file |
| `auth-service` | Helm | Shared chart + values file |
| `catalog-service` | Helm | Shared chart + values file |
| `notification-service` | Helm | Shared chart + values file |

### How Helm works here

One chart (`pharma-service/`) is shared across all Helm-managed services. Each service gets its own values file that overrides the defaults:

```
pharma-service/values.yaml           ← defaults
      +
envs/dev/values-auth-service.yaml    ← service-specific overrides
      =
Final Kubernetes manifests for auth-service
```

ArgoCD Application config for a Helm service:
```yaml
source:
  repoURL: https://github.com/ravdy/pharmops-gitops.git
  path: pharma-service
  helm:
    valueFiles:
      - ../envs/dev/values-auth-service.yaml
```

ArgoCD Application config for pharma-ui (raw manifests):
```yaml
source:
  repoURL: https://github.com/ravdy/pharmops-gitops.git
  path: k8s-manifests/pharma-ui      # ArgoCD auto-detects plain YAML
```

---

## ArgoCD Applications (dev)

| ArgoCD App | Source path | Namespace |
|------------|-------------|-----------|
| `pharma-ui-dev` | `k8s-manifests/pharma-ui` | dev |
| `api-gateway-dev` | `pharma-service` + values | dev |
| `auth-service-dev` | `pharma-service` + values | dev |
| `notification-service-dev` | `pharma-service` + values | dev |
| `catalog-service-dev` | `pharma-service` + values | dev |

Apply all applications:

```bash
kubectl apply -f argocd/projects/pharma-project.yaml
kubectl apply -f argocd/apps/dev/pharma-ui/application.yaml
kubectl apply -f argocd/apps/dev/api-gateway/application.yaml
kubectl apply -f argocd/apps/dev/auth-service/application.yaml
kubectl apply -f argocd/apps/dev/notification-service/application.yaml
kubectl apply -f argocd/apps/dev/catalog-service/application.yaml
```

---

## Updating Image Tags

**Helm services** — edit the values file:
```bash
# envs/dev/values-auth-service.yaml
image:
  tag: v1.2.0
```

**pharma-ui** — edit the deployment manifest directly:
```bash
# k8s-manifests/pharma-ui/deployment.yaml
image: <AWS_ACCOUNT_ID>.dkr.ecr.us-east-1.amazonaws.com/pharma-ui:v1.2.0
```

Push the change — ArgoCD detects it and syncs automatically.

---

## Full Setup Guide

See [`pharmops/PLATFORM_BOOTSTRAP.md`](https://github.com/ravdy/pharmops/blob/main/PLATFORM_BOOTSTRAP.md) for the complete step-by-step bootstrap guide.
