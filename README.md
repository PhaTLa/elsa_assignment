# DevOps Assignment: ELSA (Kubernetes, GitOps, Troubleshooting, CI/CD)

A self-contained, reproducible DevOps workflow demonstrating containerization, GitOps deployment, troubleshooting, CI/CD pipelines, and load testing on a local Kubernetes cluster.

**Status:** ✅ Parts 1-3 Complete | Parts 4, 6, 7 Ready  
**Repo:** https://github.com/PhaTLa/elsa_assignment  
**Image:** ghcr.io/phatla/quote-api

---

## Quick Start — The One Command

### Prerequisites
- Docker Desktop or Docker Engine
- kubectl (v1.35+)
- Bash

### Run Everything (Golden Rule)

```bash
# Clone repo
git clone https://github.com/PhaTLa/elsa_assignment.git
cd elsa_assignment

# Run all phases: build → deploy → test → troubleshoot
bash scripts/run-all.sh
```

**What it does:**
- Starts KinD cluster with 5 nodes (2 spot, 1 on-demand, 1 GPU, 1 control plane)
- Builds app image and pushes to GHCR
- Installs ArgoCD and deploys app via GitOps
- Runs reclaim drill (spot node failure test)
- Applies Part 3 troubleshooting fixes and verifies

**Expected duration:** ~5 minutes  
**Expected result:** `verify.sh → PASS`

### Quick Tests

```bash
# Test API
curl http://localhost:8000/api/quote

# Verify all checks
bash troubleshoot/verify.sh

# View ArgoCD
open http://localhost:8888  # admin / 6FjraTi5ll6TWtx2
```

---

## Architecture

### Local Development Cluster

```mermaid
graph TB
    subgraph "Developer Workstation"
        DC["Docker Desktop / Engine"]
    end

    subgraph "KinD Cluster (Kubernetes 1.35)"
        subgraph "Control Plane"
            CP["kube-apiserver, etcd, controller-manager, scheduler"]
        end
        
        subgraph "Worker Nodes"
            WS1["elsa-worker<br/>spot"]
            WS2["elsa-worker2<br/>spot"]
            WOD["elsa-worker3<br/>on-demand"]
            WGPU["elsa-worker4<br/>GPU<br/>taint: nvidia.com/gpu"]
        end
        
        subgraph "System Components"
            ARG["ArgoCD<br/>GitOps Controller"]
            ING["NGINX Ingress<br/>localhost:8080"]
            DNE["Calico CNI<br/>NetworkPolicy"]
        end
        
        subgraph "Application"
            APP["Quote API<br/>3 replicas<br/>HPA enabled"]
            SVC["Service<br/>quote-api"]
            HPA["HPA 3-10 replicas<br/>70% CPU target"]
            PDB["PDB<br/>minAvailable: 2"]
        end
        
        subgraph "Observability"
            PROM["Prometheus<br/>metrics scraper"]
            GRAF["Grafana<br/>localhost:3000"]
        end
    end

    subgraph "GitHub Registry"
        REPO["GitHub Repo<br/>elsa_assignment"]
        GHCR["GHCR Image<br/>ghcr.io/phatla/quote-api"]
    end

    DC -->|runs| CP
    DC -->|runs| WS1
    DC -->|runs| WS2
    DC -->|runs| WOD
    DC -->|runs| WGPU
    
    REPO -->|sync| ARG
    ARG -->|deploy| APP
    APP -->|endpoint| SVC
    SVC -->|route| ING
    ING -->|expose| DC
    
    APP -->|metrics| PROM
    PROM -->|visualize| GRAF
    
    ARG -->|pull| GHCR

    classDef working fill:#51cf66,stroke:#2f9e44,color:#fff
    classDef system fill:#74c0fc,stroke:#1971c2,color:#fff
    classDef external fill:#ffd43b,stroke:#f59f00,color:#000
    
    class APP,SVC working
    class ARG,ING,DNE system
    class REPO,GHCR external
```

---

## Data Flow: Request to Response

```mermaid
graph LR
    CLIENT["Client<br/>curl / browser"]
    ING["NGINX Ingress<br/>localhost:8080"]
    SVC["Service<br/>quote-api:80"]
    POD1["Pod 1<br/>nginx"]
    POD2["Pod 2<br/>nginx"]
    POD3["Pod 3<br/>nginx"]
    APP["Flask App<br/>:8000"]
    
    CLIENT -->|GET /api/quote| ING
    ING -->|route| SVC
    SVC -->|balance| POD1
    SVC -->|balance| POD2
    SVC -->|balance| POD3
    
    POD1 -->|request| APP
    POD2 -->|request| APP
    POD3 -->|request| APP
    
    APP -->|200 OK + JSON| POD1
    POD1 -->|response| SVC
    SVC -->|response| ING
    ING -->|response| CLIENT

    classDef pod fill:#51cf66
    classDef ing fill:#74c0fc
    classDef app fill:#ffd43b
    
    class POD1,POD2,POD3 pod
    class ING,SVC ing
    class APP app
```

---

## Script Reference

| Script | Purpose | Part |
|--------|---------|------|
| `run-all.sh` | Orchestrate all phases (1-3 + optional) | Main |
| `10-build.sh` | Build & push app image to GHCR | 1 |
| `15-deploy-argocd.sh` | Install ArgoCD controller | 2 |
| `20-deploy.sh` | Deploy app via ArgoCD (GitOps) | 2 |
| `25-reclaim-drill.sh` | Drain spot node, verify resilience | 2 |
| `30-troubleshoot.sh` | Apply fixed manifests, run verify.sh | 3 |
| `40-validate-tf.sh` | Terraform validation | 5 |
| `50-load-test-setup.sh` | Install Prometheus + Grafana | 6 |
| `60-loadtest.sh` | Run k6 load test | 6 |

---

## Design Decisions & Trade-offs

### 1. **KinD vs k3d**
- **Chosen:** KinD
- **Why:** Production-like K8s; real CNI (Calico); NetworkPolicy enforcement
- **Trade-off:** Heavier (~2min startup vs k3d ~1min)

### 2. **Python Flask for Service**
- **Chosen:** Python 3.12 + Flask
- **Why:** Fast iteration, Prometheus client mature, clear metrics
- **Trade-off:** Go smaller, Node more familiar

### 3. **Soft Affinity (not Hard Required)**
- **Chosen:** Preferred affinity + pod anti-affinity
- **Why:** Pods reschedule when nodes vanish (production-realistic)
- **Trade-off:** May consolidate under low load

### 4. **ArgoCD for GitOps**
- **Chosen:** ArgoCD + Helm
- **Why:** GitOps best practice, separates code from operators
- **Trade-off:** Extra layer vs direct Helm apply

### 5. **Semgrep for SAST**
- **Chosen:** Semgrep (lightweight)
- **Why:** No setup overhead, GitHub Actions friendly, OWASP-focused
- **Trade-off:** Less feedback than SonarQube

### 6. **Namespace Isolation (not Multi-Cluster)**
- **Chosen:** troubleshoot namespace (local)
- **Why:** Simple testing, no infrastructure scaling
- **Trade-off:** Can't test real cross-namespace NetworkPolicy

---

## Troubleshooting

### Port Conflict (localhost:8080)

**Symptom:** `docker compose up` fails: "bind: address already in use"

**Fix:**
```bash
# Find process using port 8080
lsof -i :8080  # macOS/Linux
netstat -ano | grep 8080  # Windows

# Kill it or change docker-compose.yml port mapping
```

### Insufficient Memory

**Symptom:** Pods in Pending: "Insufficient memory"

**Fix:**
```bash
# Docker Desktop: Increase RAM
# Settings → Resources → Memory Slider → 8GB+

# Or reduce replicas in scripts/20-deploy.sh
# Change: --set replicaCount=1
```

### Image Pull Fails

**Symptom:** Pod in `ImagePullBackOff`: "failed to pull image"

**Fix:**
1. Verify image is public:  GitHub → Settings → Packages → Make public
2. Or create pull secret if private:
```bash
kubectl create secret docker-registry ghcr-login \
  --docker-server=ghcr.io \
  --docker-username=<user> \
  --docker-password=<token>
```

---

## Production Architecture (AWS)

```mermaid
graph TB
    subgraph "Ingress & CDN"
        CF["Cloudflare<br/>caching, DDoS"]
        ALB["AWS ALB<br/>Layer 7"]
    end

    subgraph "EKS Clusters (Multi-AZ)"
        subgraph "Compute"
            GPU["GPU NodePool<br/>g4dn on-demand"]
            SPOT["Spot NodePool<br/>cost-optimized"]
            OD["On-Demand NodePool<br/>baseline"]
        end
        
        subgraph "Apps"
            APP["Quote API<br/>10-50 replicas<br/>HPA + Karpenter"]
        end
        
        subgraph "GitOps"
            ARG["ArgoCD<br/>manage from Git"]
        end
    end

    subgraph "Data"
        RDS["RDS PostgreSQL<br/>managed, replicated"]
        CACHE["ElastiCache Redis<br/>session cache"]
    end

    subgraph "Secrets & Monitoring"
        SM["Secrets Manager<br/>credential rotation"]
        CW["CloudWatch<br/>logs + metrics"]
        PROM["Prometheus<br/>custom metrics"]
    end

    CF -->|HTTPS| ALB
    ALB -->|route| APP
    APP -->|query| RDS
    APP -->|cache| CACHE
    APP -->|secrets| SM
    APP -->|logs| CW
    APP -->|metrics| PROM
    
    ARG -->|deploy| APP
    GPU -->|host| APP
    SPOT -->|host| APP
    OD -->|host| APP

    classDef cloud fill:#ff6961,stroke:#ff0000,color:#fff
    classDef compute fill:#1890ff,stroke:#0050b3,color:#fff
    classDef data fill:#52c41a,stroke:#389e0d,color:#fff
    
    class CF,ALB cloud
    class APP,ARG compute
    class RDS,CACHE,SM,CW data
```

**Key additions for production:**
- Multi-AZ redundancy
- Managed services (RDS, ElastiCache, Secrets Manager)
- Karpenter for intelligent node provisioning
- CloudWatch for centralized logging
- Auto-scaling at both pod (HPA) and node levels
- WAF + DDoS protection

---

## File Structure

```
elsa/
├── README.md                      # This file
├── TROUBLESHOOTING.md             # Part 3 diagnostics
├── AI-USAGE.md                    # AI tool transparency
│
├── app/
│   ├── src/app.py                 # Flask: /healthz, /readyz, /metrics, /api/quote
│   ├── requirements.txt           # Dependencies
│   └── Dockerfile                 # Multi-stage, non-root
│
├── helm/quote-api/
│   ├── Chart.yaml
│   ├── values.yaml
│   └── templates/
│       ├── deployment.yaml        # Affinity, probes, security context
│       ├── service.yaml
│       ├── ingress.yaml
│       ├── hpa.yaml               # 3-10 replicas at 70% CPU
│       ├── pdb.yaml               # minAvailable: 2
│       └── prometheusrule.yaml    # Alert thresholds
│
├── troubleshoot/
│   ├── broken-app.yaml            # Provided (with 8 issues)
│   ├── fixed-app.yaml             # All issues resolved
│   ├── verify.sh                  # Provided (7 checks)
│   ├── smoke-job.yaml             # Smoke test
│   └── prepare.sh / prepare.ps1   # Node labeling
│
├── scripts/
│   ├── 10-build.sh                # Build & push image
│   ├── 15-deploy-argocd.sh        # Install ArgoCD
│   ├── 20-deploy.sh               # Deploy app via ArgoCD
│   ├── 25-reclaim-drill.sh        # Test spot resilience
│   ├── 30-troubleshoot.sh         # Apply fixes + verify
│   ├── 40-validate-tf.sh          # Terraform validation
│   ├── 50-load-test-setup.sh      # Install Prometheus/Grafana
│   ├── 60-loadtest.sh             # Run k6 test
│   └── run-all.sh                 # Orchestrate all
│
├── docker-compose.yml             # KinD + toolbox
└── .github/workflows/
    └── build-and-deploy.yml       # GitHub Actions (SAST + scan)
```

---

## Part Completion Status

| Part | Task | Status |
|------|------|--------|
| 1 | Build & Ship | ✅ Complete |
| 2.1 | Helm Chart | ✅ Complete |
| 2.2 | ArgoCD | ✅ Complete |
| 2.3 | Deploy | ✅ Complete |
| 2.4 | Reclaim Drill | ✅ Complete |
| 3 | Troubleshooting | ✅ Complete |
| 4 | CI/CD Migration | 🟡 Ready (optional) |
| 6 | Load Testing | 🟡 Ready (optional) |
| 7 | Ops Questions | 🟡 Ready (optional) |

---

## Quick Verification

```bash
# Everything passes?
bash troubleshoot/verify.sh

# Expected: PASS

# See status
kubectl get all -n troubleshoot
kubectl get networkpolicies -n troubleshoot
```

---

**Last Updated:** 2026-06-19  
**License:** MIT

