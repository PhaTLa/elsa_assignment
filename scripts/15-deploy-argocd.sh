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
  echo "ERROR: Command failed after $MAX_RETRIES retries: $cmd"
  return 1
}

echo "=== ArgoCD Deployment ==="

# Create namespace (idempotent)
kubectl create namespace argocd 2>/dev/null || true

# Check if ArgoCD is already deployed
if kubectl get deployment argocd-server -n argocd >/dev/null 2>&1; then
  echo "✓ ArgoCD already deployed, verifying and updating..."
else
  echo "Deploying ArgoCD..."
fi

# Add Helm repo (idempotent)
echo "Configuring ArgoCD Helm repo..."
helm repo add argo https://argoproj.github.io/argo-helm 2>/dev/null || true
helm repo update argo

# Deploy/upgrade ArgoCD using helm (idempotent with --install)
echo "Installing/upgrading ArgoCD release..."
retry_cmd "helm upgrade --install argocd argo/argo-cd \
  --namespace argocd \
  --set 'server.service.type=LoadBalancer' \
  --set 'server.insecure=true' \
  --wait \
  --timeout=5m"

# Wait for API server to be ready (idempotent)
echo "Verifying ArgoCD API server is ready..."
retry_cmd "kubectl rollout status deployment/argocd-server -n argocd --timeout=5m"

echo ""
echo "=== ArgoCD Deployment Status ==="
kubectl get svc argocd-server -n argocd

# Display access information
ARGOCD_URL=$(kubectl get svc argocd-server -n argocd -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || echo "localhost")
ARGOCD_PORT=$(kubectl get svc argocd-server -n argocd -o jsonpath='{.spec.ports[0].port}' 2>/dev/null || echo "443")
ARGOCD_PASS=$(kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' 2>/dev/null | base64 -d 2>/dev/null || echo "N/A")

echo ""
echo "✓ ArgoCD is ready"
echo "  UI: http://${ARGOCD_URL}:${ARGOCD_PORT}"
echo "  User: admin"
echo "  Pass: ${ARGOCD_PASS}"
