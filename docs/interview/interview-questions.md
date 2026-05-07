# Real-Time Interview Questions & Answers
### Based on zen-gitops Pharma GitOps Repository
> Top-tier MNC / FAANG-style questions — 2025/2026

---

## Table of Contents

| ID | Topic | Group |
|----|-------|-------|
| [B1](#b1) | Single Helm chart vs separate charts per service | Helm |
| [B7](#b7) | Helm chart versioning across environments | Helm |
| [D2](#d2) | RBAC design — dev/qa/prod roles + GxP compliance | Security |
| [D3](#d3) | Developer can't access pod logs in qa namespace | RBAC Debug |
| [D4](#d4) | ArgoCD ClusterRole wildcard — security implications | Security |
| [E1](#e1) | Observability stack end-to-end architecture | Monitoring |
| [E4](#e4) | 2am incident — service UP but 40% requests failing | Incident |
| [E5](#e5) | SLIs/SLOs for auth-service with Prometheus/Grafana | SRE |

---

## B1

### Question
> "You're using a single Helm chart for 8 different microservices. What are the trade-offs compared to separate charts per service? When would you switch strategies?"

### What the interviewer is really testing
- Whether you understand DRY vs operational independence
- Your ability to articulate trade-offs rather than give a one-size-fits-all answer
- Awareness of Helm library charts, umbrella charts, and chart versioning strategies

---

### Model Answer

**Our setup:** A single `pharma-service` chart at `helm-charts/` is deployed 8 times — once per service — with environment-specific overrides in `envs/dev/`, `envs/qa/`, `envs/prod/`. Every service (auth, catalog, inventory, etc.) is homogeneous: Spring Boot, same port pattern, same probe endpoints, same security context.

**Why this works for us:**
- All 8 services are structurally identical — Spring Boot, `/actuator/health`, ECR images, same resource shape
- One change to the template (e.g., adding `topologySpreadConstraints`) propagates to all services in one PR
- Onboarding a new service = just add a values file, no new chart to write or maintain
- Reduces chart version drift — all services are always on the same chart version

**The hidden cost:**
- **Blast radius**: A breaking change to the shared chart affects all 8 services simultaneously. If you add a required field that `pharma-ui` doesn't set, every service breaks at the same time.
- **No independent versioning**: You cannot upgrade auth-service to chart v1.2 while keeping catalog-service on v1.1. They move together.
- **Forced convergence**: If one service needs a sidecar container but others don't, you must add that optional block to the shared chart and keep it backward-compatible.
- **Template complexity creep**: Over time, the chart accumulates many `if/else` conditions to handle outlier services, making it harder to reason about.

---

### Trade-off Comparison Table

| Dimension | Single Shared Chart | Separate Charts Per Service |
|-----------|--------------------|-----------------------------|
| Consistency | High — enforced by template | Low — each chart can drift |
| Independence | Low — coupled versioning | High — deploy/upgrade independently |
| Maintenance overhead | Low — one place to fix | High — 8 PRs for one structural change |
| Blast radius | High — one bug affects all | Low — isolated per service |
| Onboarding new service | Fast — just a values file | Slow — scaffold a new chart |
| Works best when | Services are structurally homogeneous | Services have fundamentally different deployment models |

---

### When to switch to separate charts

Switch when **any** of these become true:
1. One service needs something the others never will (e.g., a DaemonSet, init containers with heavy logic, or StatefulSet semantics)
2. Services have different release cadences and you need to pin chart versions independently
3. The shared chart has accumulated 20+ `if` blocks — it's now a liability, not an asset
4. Teams are split: one team owns `auth-service` and wants to evolve its chart without coordinating with 7 other teams

**Pragmatic middle ground — Helm Library Charts:**
```
helm-charts/
  pharma-lib/          # Library chart with shared templates (_deployment.tpl, _service.tpl)
  auth-service/        # Thin chart that calls library templates
  catalog-service/     # Thin chart that calls library templates
```
Each service gets its own chart (independent versioning, isolated blast radius) but they all call shared templates from `pharma-lib`. This is the pattern used at scale (Netflix, Spotify-style platform teams).

---

### Step-by-step: How to migrate to library chart pattern

```bash
# 1. Create the library chart
helm create pharma-lib
# Edit Chart.yaml → set type: library

# 2. Move templates to _helpers-style partials
# pharma-lib/templates/_deployment.tpl
{{- define "pharma-lib.deployment" -}}
# full deployment template here
{{- end -}}

# 3. Each service chart calls it
# auth-service/templates/deployment.yaml
{{ include "pharma-lib.deployment" . }}

# 4. Add pharma-lib as a dependency in each service Chart.yaml
dependencies:
  - name: pharma-lib
    version: "1.0.0"
    repository: "oci://873135413040.dkr.ecr.us-east-1.amazonaws.com/helm"
```

---

## B7

### Question
> "How would you manage Helm chart versioning across environments when you need to test a new chart version in dev before promoting it?"

### What the interviewer is really testing
- Your understanding of immutable chart versioning
- How GitOps + Helm version pinning interact
- Your promotion strategy and rollback plan

---

### Model Answer

**The core principle:** Helm chart versions must be immutable and pinned per environment. Never use `latest` or a floating version for a chart — the same image tag mistake, but for charts.

---

### Current repo pattern

This repo uses a single chart stored in-tree (`helm-charts/`). ArgoCD points directly at the Git repo path. The "chart version" is implicitly the Git commit SHA — ArgoCD syncs whatever is at `HEAD` of the target branch.

**Problem with this:** There's no independent chart version. Changing the chart and promoting to prod happens in the same commit as changing the values. You can't test chart v1.1 in dev while prod stays on chart v1.0.

---

### Production-grade versioning strategy

**Step 1: Publish chart to OCI registry (ECR or Artifact Hub)**

```bash
# Bump version in Chart.yaml before publishing
# helm-charts/Chart.yaml
version: 1.1.0   # was 1.0.0

# Package and push to ECR
helm package helm-charts/
helm push pharma-service-1.1.0.tgz oci://873135413040.dkr.ecr.us-east-1.amazonaws.com/helm-charts
```

**Step 2: Pin chart version per environment in ArgoCD Application manifests**

```yaml
# argocd/apps/dev/auth-service.yaml
spec:
  source:
    repoURL: oci://873135413040.dkr.ecr.us-east-1.amazonaws.com/helm-charts
    chart: pharma-service
    targetRevision: 1.1.0      # ← dev gets new chart version
    helm:
      valueFiles:
        - envs/dev/values-auth-service.yaml

# argocd/apps/prod/auth-service.yaml
spec:
  source:
    repoURL: oci://873135413040.dkr.ecr.us-east-1.amazonaws.com/helm-charts
    chart: pharma-service
    targetRevision: 1.0.0      # ← prod stays on old chart version
```

**Step 3: Promotion flow**

```
Chart PR merged → CI builds & publishes pharma-service:1.1.0 to ECR
       ↓
Update dev ArgoCD app → targetRevision: 1.1.0
       ↓
Observe in dev for 24-48h (liveness, readiness, no regressions)
       ↓
PR to update qa ArgoCD app → targetRevision: 1.1.0
       ↓
Regression test in qa
       ↓
PR to update prod ArgoCD app → targetRevision: 1.1.0 (requires senior approval)
```

---

### Architecture Diagram

```
Git Repo (zen-gitops)
├── helm-charts/          ← source of truth for chart code
│   └── Chart.yaml        ← version: 1.1.0
│
├── argocd/apps/
│   ├── dev/auth-service.yaml    → chart: 1.1.0  ✅ testing
│   ├── qa/auth-service.yaml     → chart: 1.1.0  ✅ validated
│   └── prod/auth-service.yaml   → chart: 1.0.0  ← not yet promoted
│
CI Pipeline
└── On chart PR merge:
    helm package → helm push → ECR OCI registry
                                    ↓
                         873135413040.dkr.ecr.us-east-1.amazonaws.com
                         /helm-charts/pharma-service:1.1.0 (immutable)
```

---

### Rollback procedure

```bash
# If 1.1.0 breaks in qa, revert the PR that bumped it
# OR directly patch the ArgoCD app:
kubectl patch application auth-service-qa -n argocd \
  --type merge \
  -p '{"spec":{"source":{"targetRevision":"1.0.0"}}}'

# ArgoCD will immediately sync back to chart 1.0.0
```

---

### Key principle to state in interview

> "Chart version and app image version are two different concerns. The chart version controls **how** we deploy; the image tag controls **what** we deploy. We version them independently and promote them separately."

---

## D2

### Question
> "Walk me through the RBAC design in this repo — how are dev, qa, and prod roles different? How does this map to a pharma compliance requirement like GxP?"

### What the interviewer is really testing
- Can you read and explain RBAC YAML fluently
- Do you understand least-privilege and why it matters in regulated industries
- Awareness of GxP/21 CFR Part 11 compliance concepts

---

### Model Answer

**This repo defines three `pharma-deployer` Roles — one per namespace — all bound to the same subject: `gitlab-runner` ServiceAccount in the `gitlab-runner` namespace.**

---

### Role Comparison (derived from actual YAML)

| Permission | dev | qa | prod |
|-----------|-----|----|----|
| Create/Update/Delete Deployments | ✅ | ✅ | ✅ (no delete) |
| Create/Update/Delete Secrets | ✅ | ✅ | ✅ (no delete) |
| Create/Update/Delete ConfigMaps | ✅ | ✅ | ✅ (no delete) |
| pods/exec (shell into pod) | ✅ | ✅ | ❌ |
| pods/log (read logs) | ✅ | ✅ | ✅ |
| Delete resources | ✅ | ✅ | ❌ |

**The critical difference:** Prod role has **no `delete` verb** on any resource, and **no `pods/exec`**.

This means:
- The CI/CD pipeline (`gitlab-runner`) can deploy to prod (create/patch/update) but **cannot delete** a running deployment or shell into a prod pod
- If something goes wrong in prod, the pipeline can roll forward (new deployment) but cannot arbitrarily delete resources
- Nobody can `kubectl exec` into a prod container via this SA — protecting against data exfiltration

---

### GxP / 21 CFR Part 11 Mapping

GxP (Good Practice) and FDA 21 CFR Part 11 require in computerized systems:

| GxP Requirement | How this RBAC satisfies it |
|----------------|---------------------------|
| **Access control** — only authorized users can modify production | prod Role bound only to `gitlab-runner` SA; humans need separate RBAC or go through GitOps PRs |
| **Audit trail** — every change must be traceable to an identity | GitOps PR + ArgoCD sync history = immutable audit trail (who merged what, when) |
| **No direct manipulation of validated environment** | `pods/exec` removed from prod — no ad-hoc changes inside running containers |
| **Separation of duties** — dev team can't self-approve to prod | Git branch protection + ArgoCD project roles enforce review gates |
| **Data integrity** — no unauthorized deletion of records | `delete` verb absent from prod role — resources can only be replaced, not wiped |

---

### What's missing (and you should mention to impress)

1. **No human RBAC defined here** — only `gitlab-runner`. In a real GxP setup you'd also define roles for `pharma-devops-team` (read-only on prod), `release-manager` (approve-only), etc.
2. **No NetworkPolicy** — pods in prod can still talk to pods in dev within the cluster
3. **`pods/log` on prod** — log data may contain PII in a pharma app; in a strict GxP environment you'd route logs to a centralized, immutable log store and remove direct `kubectl logs` access

---

### Architecture Diagram

```
gitlab-runner ServiceAccount (namespace: gitlab-runner)
        |
        ├── RoleBinding (namespace: dev)  → pharma-deployer Role (dev)
        │     Full CRUD + exec + delete
        │
        ├── RoleBinding (namespace: qa)   → pharma-deployer Role (qa)
        │     Full CRUD + exec + delete
        │
        └── RoleBinding (namespace: prod) → pharma-deployer Role (prod)
              CRUD only — NO delete, NO exec
              (read logs only on pods)

ArgoCD argocd-application-controller SA
        └── ClusterRoleBinding → argocd-manager ClusterRole
              Full cluster-wide access (separate concern — see D4)
```

---

## D3

### Question
> "A developer reports they can't access pod logs in the qa namespace. How do you debug and fix this RBAC issue?"

### What the interviewer is really testing
- Systematic RBAC debugging using `kubectl auth can-i`
- Understanding the difference between Role, ClusterRole, RoleBinding, ClusterRoleBinding
- Practical kubectl fluency

---

### Model Answer

**Do not guess. Use `kubectl auth can-i` to get a binary answer first, then trace the gap.**

---

### Step-by-step debugging procedure

**Step 1: Reproduce the exact error**
```bash
# Run as the developer (impersonate their user/SA)
kubectl auth can-i get pods/log -n qa --as=<developer-username>
# Expected output if broken: "no"

# Also check list pods (needed to know pod names before reading logs)
kubectl auth can-i list pods -n qa --as=<developer-username>
```

**Step 2: Identify what identity the developer is using**
```bash
# If they're using a ServiceAccount:
kubectl get rolebindings -n qa -o wide
kubectl get clusterrolebindings -o wide | grep <developer-username>

# If using a user cert/OIDC token:
kubectl config view --minify   # shows current context & user
kubectl auth whoami            # Kubernetes 1.28+
```

**Step 3: Check what roles are bound to their identity**
```bash
kubectl get rolebindings -n qa -o yaml | grep -A5 <username>
kubectl describe rolebinding pharma-deployer-binding -n qa
```

**Step 4: Read the actual Role rules**
```bash
kubectl describe role pharma-deployer -n qa
```

From this repo's `qa-role.yaml` we can see:
```yaml
- apiGroups: [""]
  resources: ["pods", "pods/log", "pods/exec"]
  verbs: ["get", "list", "watch"]
```
`pods/log` IS in the qa role. So if the developer can't access logs, the problem is **they are not bound to this role**.

**Step 5: Check if the RoleBinding subject matches the developer**
```bash
kubectl describe rolebinding pharma-deployer-binding -n qa
```
From `rolebindings.yaml`:
```yaml
subjects:
  - kind: ServiceAccount
    name: gitlab-runner
    namespace: gitlab-runner
```
The binding only covers `gitlab-runner` SA. **A human developer is not covered.** This is the root cause.

---

### Fix

**Option A: Add the developer to the existing RoleBinding (quick fix)**
```yaml
subjects:
  - kind: ServiceAccount
    name: gitlab-runner
    namespace: gitlab-runner
  - kind: User
    name: developer@pharma.com
    apiGroup: rbac.authorization.k8s.io
```

**Option B: Create a read-only role for developers (better)**
```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: pharma-developer-readonly
  namespace: qa
rules:
  - apiGroups: [""]
    resources: ["pods", "pods/log"]
    verbs: ["get", "list", "watch"]
  - apiGroups: ["apps"]
    resources: ["deployments", "replicasets"]
    verbs: ["get", "list", "watch"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: pharma-developer-readonly-binding
  namespace: qa
subjects:
  - kind: Group
    name: pharma-developers    # OIDC group from your IdP
    apiGroup: rbac.authorization.k8s.io
roleRef:
  kind: Role
  name: pharma-developer-readonly
  apiGroup: rbac.authorization.k8s.io
```

**Option B is better because:**
- Least-privilege — developers get read-only, not deploy rights
- Uses OIDC group — adding a new developer doesn't require a YAML change
- Managed in Git → audit trail for compliance

---

### Verification after fix
```bash
kubectl auth can-i get pods/log -n qa --as=developer@pharma.com
# Should return: "yes"

kubectl logs -n qa <pod-name> --as=developer@pharma.com
# Should return log output
```

---

## D4

### Question
> "The ArgoCD controller has a ClusterRole with full wildcard permissions (`* * *`). Is this acceptable? How would you scope it down without breaking ArgoCD?"

### What the interviewer is really testing
- Security-first thinking without breaking operational requirements
- Understanding of why ArgoCD needs broad permissions (and the minimum it actually needs)
- Ability to make pragmatic trade-offs in security discussions

---

### Model Answer

From `cluster-roles.yaml`:
```yaml
rules:
  - apiGroups: ["*"]
    resources: ["*"]
    verbs: ["*"]
  - nonResourceURLs: ["*"]
    verbs: ["*"]
```

**Is this acceptable?** In a production pharma environment, no — but it is a pragmatic starting point that many teams use and then tighten. The full wildcard is acceptable for **initial cluster setup or a dev cluster**, but **must be scoped before production goes live**.

---

### Why ArgoCD needs broad permissions

ArgoCD's application controller must:
- Read/write any CRD that applications deploy (including custom operators, cert-manager, external-secrets, etc.)
- Watch all resources across all managed namespaces
- Create/delete resources to reconcile desired vs actual state
- Access `nonResourceURLs` for health checks

This is why the default ArgoCD install gives it full cluster-admin. The risk is: if ArgoCD itself is compromised, an attacker has full cluster access.

---

### How to scope it down

**Approach 1: Restrict to managed namespaces only (practical, most common)**

```yaml
# Instead of ClusterRole, give ArgoCD namespace-scoped Roles
# for the namespaces it manages (dev, qa, prod)
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: argocd-manager
  namespace: prod   # repeat for dev, qa
rules:
  - apiGroups: ["apps"]
    resources: ["deployments", "replicasets", "statefulsets", "daemonsets"]
    verbs: ["*"]
  - apiGroups: [""]
    resources: ["services", "configmaps", "secrets", "serviceaccounts", "pods"]
    verbs: ["*"]
  - apiGroups: ["networking.k8s.io"]
    resources: ["ingresses"]
    verbs: ["*"]
  - apiGroups: ["autoscaling"]
    resources: ["horizontalpodautoscalers"]
    verbs: ["*"]
  - apiGroups: ["external-secrets.io"]
    resources: ["externalsecrets"]
    verbs: ["*"]
```

ArgoCD still needs a **minimal ClusterRole** for cluster-level reads (nodes, namespaces, CRDs):
```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: argocd-manager-cluster-readonly
rules:
  - apiGroups: [""]
    resources: ["namespaces", "nodes"]
    verbs: ["get", "list", "watch"]
  - apiGroups: ["apiextensions.k8s.io"]
    resources: ["customresourcedefinitions"]
    verbs: ["get", "list", "watch"]
```

**Approach 2: Use ArgoCD's built-in namespace isolation mode (ArgoCD v2.5+)**

```yaml
# argocd-cmd-params-cm ConfigMap
data:
  application.namespaces: "dev,qa,prod"  # ArgoCD only manages these
```
Combined with namespace-scoped roles, this prevents ArgoCD from touching `kube-system` or any other namespace.

---

### Trade-off Analysis

| Approach | Security | Operational complexity | Breakage risk |
|----------|----------|----------------------|---------------|
| Full wildcard (current) | Low | Low | None |
| Namespace-scoped Roles | High | Medium — must update when deploying new CRDs | High if a new CRD is added and not in the Role |
| Namespace isolation mode | High | Medium | Medium |

**Recommendation for pharma production:** Use namespace isolation mode + namespace-scoped roles. Accept that you'll need to update the Role when adding new CRD types. Track this in your change management process — which in a GxP environment is mandatory anyway.

---

### What to say to close the question

> "The wildcard role is a conscious trade-off — operationally simple but a security debt. I'd accept it for dev/qa and schedule hardening before first prod go-live. The key mitigation in the meantime is: restrict who can commit to the ArgoCD application manifests in Git, because that's the blast radius — not the RBAC itself."

---

## E1

### Question
> "Walk me through the observability stack in this repo — how does a metric from the auth-service end up as a Grafana alert email to devops@pharma.com?"

### What the interviewer is really testing
- End-to-end understanding of the Prometheus/Grafana/Alertmanager stack
- How Kubernetes ServiceMonitors work
- Whether you've actually operated this stack, not just read about it

---

### Model Answer

**The full chain has 6 stages:**

```
auth-service pod
    └── exposes /actuator/prometheus (Micrometer → Prometheus format)
            ↓
    Prometheus scrapes via ServiceMonitor
            ↓
    PromQL alert rule evaluates (e.g., error rate > 5%)
            ↓
    Alertmanager receives firing alert
            ↓
    Alertmanager routes to email-notifications receiver
            ↓
    SMTP → devops@pharma.com
```

---

### Stage 1: Auth-service exposes metrics

From `envs/prod/values-auth-service.yaml`:
```yaml
configmap:
  MANAGEMENT_ENDPOINTS_WEB_EXPOSURE_INCLUDE: "health,info,metrics,prometheus"
```

Spring Boot's Micrometer library exposes metrics at:
```
http://auth-service:8081/actuator/prometheus
```
Format: Prometheus text exposition (counter, gauge, histogram).
Key metrics exposed: `http_server_requests_seconds`, `jvm_memory_used_bytes`, `hikaricp_connections_active`, etc.

---

### Stage 2: Prometheus discovers and scrapes auth-service

Prometheus doesn't scrape pods directly — it uses **ServiceMonitor** CRDs (part of the kube-prometheus-stack).

```yaml
# You'd create this (not in repo yet — it's a gap worth mentioning):
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: auth-service
  namespace: prod
  labels:
    release: kube-prometheus-stack   # must match Prometheus selector
spec:
  selector:
    matchLabels:
      app.kubernetes.io/name: auth-service
  endpoints:
    - port: http
      path: /actuator/prometheus
      interval: 30s
```

From `prometheus-values.yaml`:
```yaml
prometheus:
  prometheusSpec:
    serviceMonitorSelectorNilUsesHelmValues: false  # scrape ALL ServiceMonitors
```
This means Prometheus watches for ServiceMonitor objects across all namespaces.

---

### Stage 3: Alert rule evaluates

```yaml
# Example PrometheusRule for auth-service error rate
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: auth-service-alerts
  namespace: prod
spec:
  groups:
    - name: auth-service
      rules:
        - alert: AuthServiceHighErrorRate
          expr: |
            rate(http_server_requests_seconds_count{
              app="auth-service", status=~"5.."
            }[5m]) /
            rate(http_server_requests_seconds_count{
              app="auth-service"
            }[5m]) > 0.05
          for: 2m
          labels:
            severity: critical
          annotations:
            summary: "Auth service error rate above 5%"
```

Prometheus evaluates this expression every 30s (default). If the condition is true for 2 consecutive minutes, alert state becomes `FIRING`.

---

### Stage 4 & 5: Alertmanager routes the alert

From `prometheus-values.yaml`:
```yaml
alertmanager:
  config:
    route:
      group_by: ["alertname", "cluster", "service"]
      group_wait: 30s          # wait 30s to batch alerts
      group_interval: 5m       # send grouped alerts every 5m
      repeat_interval: 12h     # re-notify every 12h if still firing
      receiver: "email-notifications"
      routes:
        - match:
            severity: critical
          receiver: "email-notifications"
    receivers:
      - name: "email-notifications"
        email_configs:
          - to: "devops@pharma.com"
            send_resolved: true   # also email when alert clears
```

Alertmanager receives the FIRING alert from Prometheus, waits 30s for grouping, then sends one email per group.

---

### Stage 6: Email arrives at devops@pharma.com

```yaml
smtp_smarthost: "smtp.pharma.com:587"
smtp_from: "alertmanager@pharma.com"
smtp_auth_username: "alertmanager@pharma.com"
```

The email contains:
- Alert name: `AuthServiceHighErrorRate`
- Labels: severity, cluster, service
- Annotations: summary text
- A link back to Grafana dashboard
- A "resolved" notification when the alert clears

---

### Full Architecture Diagram

```
┌─────────────────────────────────────────────────────────────┐
│  prod namespace                                              │
│                                                             │
│  auth-service pod                                           │
│  :8081/actuator/prometheus ──────────────────────────────┐  │
│                                                          │  │
└──────────────────────────────────────────────────────────┼──┘
                                                           │
                                        scrape (30s)       │
┌──────────────────────────────────────────────────────────┼──┐
│  monitoring namespace                                    │  │
│                                                          ▼  │
│  ServiceMonitor ──► Prometheus ──► PrometheusRule        │  │
│                         │              evaluates         │  │
│                         │              every 30s         │  │
│                         │                               │  │
│                         ▼                               │  │
│                   Time Series DB                        │  │
│                   (20Gi PVC, gp2)   ◄──────────────────┘  │
│                         │                                  │
│                         ▼                                  │
│                   Alertmanager                             │
│                         │                                  │
│                   Grafana (10Gi PVC) ◄── dashboards        │
│                                                            │
└────────────────────────────────────────────────────────────┘
         │
         │ SMTP :587
         ▼
   devops@pharma.com
```

---

## E4

### Question
> "Your SRE team gets paged at 2am. A microservice is UP (passes liveness) but 40% of requests are failing. How would you debug this using this monitoring stack?"

### What the interviewer is really testing
- Structured incident response under pressure
- Understanding that liveness ≠ correctness
- Ability to use Prometheus/Grafana queries to isolate root cause

---

### Model Answer

**The first principle: liveness probe passing only means "the process is alive and can answer HTTP." It does not mean the application is functioning correctly.** A service can be alive but have a broken DB connection, exhausted thread pool, or misconfigured downstream.

---

### Incident Response Procedure (step by step)

**0. Acknowledge and orient (< 2 minutes)**
```bash
# Who is paged, what service, what time did it start?
# Check ArgoCD — was there a recent deployment?
argocd app history <service-name>

# Was there a config change?
git log --since="2 hours ago" -- envs/prod/
```

**1. Quantify the blast radius**
```promql
-- In Grafana, run:
-- What % of requests are failing RIGHT NOW?
sum(rate(http_server_requests_seconds_count{namespace="prod",status=~"5.."}[5m]))
/
sum(rate(http_server_requests_seconds_count{namespace="prod"}[5m]))
* 100

-- Which specific endpoints are failing?
sum by (uri, status) (
  rate(http_server_requests_seconds_count{namespace="prod",app="auth-service",status=~"5.."}[5m])
)
```

**2. Check if it's one pod or all pods**
```bash
kubectl get pods -n prod -l app=auth-service
# If 1 of 3 pods is sick, it's a pod-level issue (OOM, bad state)
# If all pods are sick simultaneously, it's a config/dependency issue

# Check events on each pod
kubectl describe pod <pod-name> -n prod | tail -20
```

**3. Read the application logs**
```bash
kubectl logs -n prod deployment/auth-service --since=30m | grep -i "error\|exception\|failed"

# Common findings:
# - HikariCP connection timeout → DB is down or pool exhausted
# - JWT secret not found → External secret failed to sync
# - Connection refused to downstream service
```

**4. Check downstream dependencies**
```promql
-- Is the DB connection pool exhausted?
hikaricp_connections_active{app="auth-service", namespace="prod"}
hikaricp_connections_pending{app="auth-service", namespace="prod"}

-- Is latency spiking (not just errors)?
histogram_quantile(0.99,
  rate(http_server_requests_seconds_bucket{app="auth-service",namespace="prod"}[5m])
)
```

**5. Check if secrets are fresh**
```bash
# External secret might have failed to refresh (refreshInterval: 1h)
kubectl get externalsecret -n prod
# Look for READY=False or LastSyncTime being old

kubectl describe externalsecret db-credentials -n prod
```

**6. Check resource pressure**
```bash
kubectl top pods -n prod
kubectl describe node <node-name> | grep -A5 "Conditions:"

# OOM → pod restarts mid-request
# CPU throttling → requests timeout at client before completing
```

---

### Decision tree

```
40% requests failing, liveness OK
           │
           ├─ Recent deployment? ──YES──► Rollback immediately, investigate after
           │
           ├─ One pod or all pods?
           │      │
           │      ├─ One pod ──► Delete the pod, let it restart fresh
           │      │              Check for memory leak in logs
           │      │
           │      └─ All pods ──► Dependency issue (DB, secret, downstream)
           │
           ├─ Logs show DB error? ──► Check RDS status, check HikariCP metrics
           │
           ├─ Logs show auth/JWT error? ──► Check ExternalSecret sync status
           │
           └─ No obvious log error? ──► CPU throttling or thread pool exhaustion
                                        kubectl top + increase resources or scale out
```

---

### Mitigation options

| Severity | Action |
|----------|--------|
| Recent deployment caused it | `argocd app rollback <app> <revision>` |
| One bad pod | `kubectl delete pod <pod-name> -n prod` |
| DB connection exhausted | Restart pods OR increase `hikari.maximum-pool-size` |
| ESO secret stale | `kubectl annotate externalsecret db-credentials -n prod force-sync=$(date +%s)` |
| High CPU/memory | Horizontal scale: `kubectl scale deployment auth-service -n prod --replicas=5` |

---

### Post-incident

Write a blameless postmortem covering:
1. Timeline (when did it start, when detected, when resolved)
2. Root cause
3. Impact (number of users affected, duration)
4. Detection gap (why did it take X minutes to page?)
5. Action items (add the missing alert, fix the probe to catch this scenario)

---

## E5

### Question
> "What SLIs/SLOs would you define for the auth-service and how would you implement them with this Prometheus/Grafana stack?"

### What the interviewer is really testing
- SRE fundamentals — you understand SLI vs SLO vs SLA vs error budget
- Ability to translate business requirements into concrete Prometheus queries
- Knowing which metrics matter for an auth service specifically

---

### Model Answer

**Definitions first:**
- **SLI** (Service Level Indicator): A measurable metric (e.g., error rate)
- **SLO** (Service Level Objective): Target for that metric (e.g., error rate < 1% over 30 days)
- **Error Budget**: 100% - SLO. If SLO is 99.9%, error budget = 0.1% of requests can fail per month
- **SLA**: Legal/commercial commitment to customers (typically looser than SLO)

---

### SLIs and SLOs for auth-service

Auth-service is a critical path service — every user request passes through it for token validation. A strict SLO is justified.

| SLI | What it measures | SLO Target | Rationale |
|-----|-----------------|------------|-----------|
| **Availability** | % of requests returning non-5xx | 99.9% over 30d | Auth is critical path — any 5xx blocks all users |
| **Latency (p99)** | 99th percentile response time for `/auth/**` | < 500ms | Token validation must be fast to avoid cascading slowness |
| **Latency (p50)** | Median response time | < 100ms | Typical request should be very fast |
| **Error rate** | % of 5xx responses | < 0.1% over 5m window | Alert threshold for incident response |
| **Token validation success rate** | % of valid tokens accepted (business-level) | > 99.95% | Catch issues with JWT signing/verification |

---

### Prometheus queries for each SLI

**Availability SLI (30-day window):**
```promql
-- Success rate over 30 days (good requests / total)
sum(increase(http_server_requests_seconds_count{
  app="auth-service", namespace="prod",
  status!~"5.."
}[30d]))
/
sum(increase(http_server_requests_seconds_count{
  app="auth-service", namespace="prod"
}[30d]))
```

**Latency p99 SLI:**
```promql
histogram_quantile(0.99,
  sum by (le) (
    rate(http_server_requests_seconds_bucket{
      app="auth-service",
      namespace="prod",
      uri=~"/auth/.*"
    }[5m])
  )
)
```

**Error Budget Burn Rate Alert (multi-window — Google SRE approach):**
```yaml
# Alert when you're burning error budget 14x faster than expected
# This catches both fast burns (incident) and slow burns (silent degradation)
- alert: AuthServiceHighErrorBudgetBurn
  expr: |
    (
      # 1h burn rate
      1 - (
        sum(rate(http_server_requests_seconds_count{app="auth-service",status!~"5.."}[1h]))
        / sum(rate(http_server_requests_seconds_count{app="auth-service"}[1h]))
      )
    ) > (14 * 0.001)   # 14x the 0.1% error budget
  for: 2m
  labels:
    severity: critical
  annotations:
    summary: "Auth service burning error budget at 14x rate"
```

---

### Grafana Dashboard Structure

```
Auth Service SLO Dashboard
├── Row 1: Current SLO Status
│   ├── Availability % (30d rolling)          [Stat panel — green/red]
│   ├── Error budget remaining (%)            [Gauge — 0-100%]
│   └── Time until budget exhausted           [Stat panel]
│
├── Row 2: Request Rates & Errors
│   ├── Request rate (rps) by status code     [Time series]
│   └── Error rate % over time               [Time series]
│
├── Row 3: Latency
│   ├── p50/p95/p99 latency                  [Time series]
│   └── Latency heatmap                      [Heatmap]
│
└── Row 4: Dependencies
    ├── HikariCP active connections           [Time series]
    └── External secrets last sync time      [Stat]
```

---

### Implementation step-by-step

```bash
# Step 1: Verify auth-service exposes the right metrics
kubectl exec -n prod deployment/auth-service -- \
  curl -s localhost:8081/actuator/prometheus | grep http_server_requests

# Step 2: Create ServiceMonitor
kubectl apply -f - <<EOF
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: auth-service
  namespace: prod
  labels:
    release: kube-prometheus-stack
spec:
  selector:
    matchLabels:
      app.kubernetes.io/name: auth-service
  endpoints:
    - port: http
      path: /actuator/prometheus
      interval: 15s   # tighter scrape for auth service
EOF

# Step 3: Verify Prometheus is scraping it
# In Prometheus UI → Status → Targets → look for auth-service

# Step 4: Apply PrometheusRule with SLO alerts
kubectl apply -f k8s/monitoring/auth-service-slo-rules.yaml

# Step 5: Import Grafana dashboard
# Grafana → Dashboards → Import → use dashboard JSON
```

---

### What to say about error budgets in an interview

> "The error budget is the key artifact. Once we define a 99.9% SLO, we have 0.1% of requests per month — roughly 43 minutes of downtime — as our budget. When we're burning through it fast (say during a deployment), we stop all non-critical releases and focus engineering time on reliability. When we have budget to spare, we can move faster and accept more risk. It's how we operationalize the reliability vs velocity trade-off without it being a purely political argument."

---

## Quick Reference — Skipped Questions

The following questions were **excluded** from this document per your selection:
- **G3** — FDA 21 CFR Part 11 compliance mapping (skipped)
- **C5** — Chicken-and-egg problem with secrets during bootstrap (skipped)
- **A4** — App of Apps pattern in ArgoCD (skipped)

All other questions from Groups A, B, C, D, E, F, G, H, I remain in the master list and can be written up on request.
