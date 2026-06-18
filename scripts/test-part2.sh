#!/bin/bash
set -eu

echo "╔════════════════════════════════════════════════════════════╗"
echo "║ Part 2 Validation: Helm Chart & ArgoCD Installation       ║"
echo "╚════════════════════════════════════════════════════════════╝"

RETRY_COUNT=0
MAX_RETRIES=3

test_result() {
  if [ $? -eq 0 ]; then
    echo "✓ $1"
  else
    echo "✗ $1"
    exit 1
  fi
}

# Test 2.1: Helm Chart Validity
echo ""
echo "=== Test 2.1: Helm Chart Validation ==="

echo "1. Linting Helm chart..."
helm lint helm/quote-api
test_result "Helm chart lint passed"

echo "2. Rendering Helm templates..."
helm template helm/quote-api > /tmp/rendered.yaml
test_result "Helm templates rendered"

echo "3. Validating rendering has all required manifests..."
grep -q "kind: Deployment" /tmp/rendered.yaml
test_result "  - Deployment manifest found"
grep -q "kind: Service" /tmp/rendered.yaml
test_result "  - Service manifest found"
grep -q "kind: Ingress" /tmp/rendered.yaml
test_result "  - Ingress manifest found"
grep -q "kind: HorizontalPodAutoscaler" /tmp/rendered.yaml
test_result "  - HPA manifest found"
grep -q "kind: PodDisruptionBudget" /tmp/rendered.yaml
test_result "  - PDB manifest found"
grep -q "kind: PrometheusRule" /tmp/rendered.yaml
test_result "  - PrometheusRule manifest found"

echo "4. Validating placement constraints..."
grep -q "acme.io/capacity" /tmp/rendered.yaml
test_result "  - Spot/on-demand affinity rules present"
grep -q "podAntiAffinity" /tmp/rendered.yaml
test_result "  - Pod anti-affinity rules present"

# Test 2.2: ArgoCD Installation
echo ""
echo "=== Test 2.2: ArgoCD Installation (Dry Run) ==="

echo "1. Checking kubectl connection..."
kubectl cluster-info > /dev/null
test_result "Kubectl connected to cluster"

echo "2. Checking ArgoCD namespace..."
kubectl get namespace argocd 2>/dev/null || kubectl create namespace argocd
test_result "ArgoCD namespace created"

echo "3. Checking Helm repo connectivity..."
helm repo add argo https://argoproj.github.io/argo-helm 2>/dev/null || true
helm repo update argo
test_result "ArgoCD Helm repo accessible"

echo "4. Dry-run ArgoCD install..."
helm upgrade --install argocd argo/argo-cd \
  --namespace argocd \
  --set 'server.service.type=LoadBalancer' \
  --set 'server.insecure=true' \
  --dry-run \
  --wait \
  --timeout=5m > /tmp/argocd-dry-run.yaml

grep -q "kind: Deployment" /tmp/argocd-dry-run.yaml
test_result "ArgoCD Helm chart renders correctly"

# Test ArgoCD Application
echo ""
echo "=== Test 2.3: ArgoCD Application Validation ==="

echo "1. Validating ArgoCD Application manifest syntax..."
grep -q "kind: Application" helm/quote-api/argocd-app.yaml
test_result "Application manifest is correct type"

grep -q "quote-api" helm/quote-api/argocd-app.yaml
test_result "Application references quote-api"

grep -q "helm/quote-api" helm/quote-api/argocd-app.yaml
test_result "Application references Helm chart path"

echo ""
echo "╔════════════════════════════════════════════════════════════╗"
echo "║ ✓ All validation tests passed!                             ║"
echo "║                                                              ║"
echo "║ Ready to deploy. Run:                                       ║"
echo "║   bash scripts/15-deploy-argocd.sh                          ║"
echo "║   bash scripts/20-deploy.sh                                 ║"
echo "╚════════════════════════════════════════════════════════════╝"
