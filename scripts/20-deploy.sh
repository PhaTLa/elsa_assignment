#!/bin/bash
set -eu

RETRY_COUNT=0
MAX_RETRIES=3

retry_cmd() {
  local cmd="$@"
  RETRY_COUNT=0
  while [ $RETRY_COUNT -lt $MAX_RETRIES ]; do
    if eval "$cmd"; then
      return 0
    fi
    RETRY_COUNT=$((RETRY_COUNT + 1))
    if [ $RETRY_COUNT -lt $MAX_RETRIES ]; then
      echo "  Retry $RETRY_COUNT/$MAX_RETRIES..."
      sleep 5
    fi
  done
  return 1
}

echo "=== Quote API Deployment via ArgoCD ==="

# Get git commit SHA
GIT_SHA=$(git rev-parse --short HEAD 2>/dev/null || echo "latest")
echo "Git commit SHA: ${GIT_SHA}"

# Ensure default namespace exists
kubectl create namespace default 2>/dev/null || true

# Check if ArgoCD project exists
if ! kubectl get appproject quote-api -n argocd >/dev/null 2>&1; then
  echo "Creating ArgoCD Project..."
  kubectl apply -f - <<EOF
apiVersion: argoproj.io/v1alpha1
kind: AppProject
metadata:
  name: quote-api
  namespace: argocd
spec:
  sourceRepos:
  - 'https://github.com/PhaTLa/alex_assignment.git'
  destinations:
  - namespace: '*'
    server: '*'
  clusterResourceWhitelist:
  - group: '*'
    kind: '*'
EOF
else
  echo "✓ ArgoCD Project already exists"
fi

# Create/Update ArgoCD Application (idempotent with kubectl apply)
echo "Creating/Updating ArgoCD Application..."
kubectl apply -f - <<EOF
apiVersion: argoproj.io/v1alpha1
kind: Application
metadata:
  name: quote-api
  namespace: argocd
spec:
  project: quote-api
  source:
    repoURL: https://github.com/PhaTLa/alex_assignment.git
    path: helm/quote-api
    targetRevision: HEAD
    helm:
      releaseName: quote-api
      parameters:
      - name: image.tag
        value: ${GIT_SHA}
      - name: image.repository
        value: ghcr.io/phatla/quote-api
  destination:
    server: https://kubernetes.default.svc
    namespace: default
  syncPolicy:
    automated:
      prune: true
      selfHeal: true
    syncOptions:
    - CreateNamespace=true
EOF

echo "✓ ArgoCD Application created/updated"

# Wait for ArgoCD sync
echo "Waiting for ArgoCD sync (max 2 minutes)..."
# Old wait logic that hung because kubectl wait doesn't support custom ArgoCD status values natively:
# SYNC_RESULT=$(retry_cmd "kubectl wait --for=condition=Synced application/quote-api -n argocd --timeout=120s")
# if [ $? -eq 0 ]; then
#   echo "✓ ArgoCD sync completed"
# else
#   echo "✗ ArgoCD sync timeout - may be cloning repo, checking status..."
# fi

SUCCESS=0
for i in {1..24}; do
  SYNC_STATUS=$(kubectl get application quote-api -n argocd -o jsonpath='{.status.sync.status}' 2>/dev/null || echo "Unknown")
  HEALTH_STATUS=$(kubectl get application quote-api -n argocd -o jsonpath='{.status.health.status}' 2>/dev/null || echo "Unknown")
  
  if [ "${SYNC_STATUS}" = "Synced" ] && [ "${HEALTH_STATUS}" = "Healthy" ]; then
    echo "✓ ArgoCD sync completed and application is healthy"
    SUCCESS=1
    break
  fi
  
  echo "  Status: Sync=${SYNC_STATUS}, Health=${HEALTH_STATUS}. Waiting..."
  sleep 5
done

if [ $SUCCESS -ne 1 ]; then
  echo "✗ ArgoCD sync timeout - may be cloning repo, checking status..."
fi

# Wait for deployment to be ready (argocd creates the deployment)
echo "Waiting for Quote API deployment to be ready (max 5 minutes)..."
retry_cmd "kubectl rollout status deployment/quote-api -n default --timeout=120s"

# Verify deployment
echo ""
echo "=== Quote API Deployment Status ==="
kubectl get pods -n default -l app=quote-api
echo ""
kubectl get deployment -n default quote-api

# Check ArgoCD Application final status
SYNC_STATUS=$(kubectl get application quote-api -n argocd -o jsonpath='{.status.sync.status}' 2>/dev/null || echo "Unknown")
HEALTH_STATUS=$(kubectl get application quote-api -n argocd -o jsonpath='{.status.health.status}' 2>/dev/null || echo "Unknown")

echo ""
echo "ArgoCD Application Status: ${SYNC_STATUS} | ${HEALTH_STATUS}"
echo "✓ Quote API deployed successfully via ArgoCD"
