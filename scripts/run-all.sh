#!/bin/bash
set -eu

REPO_URL=${REPO_URL:-$(git remote get-url origin)}
GIT_SHA=$(git rev-parse --short HEAD)

echo "╔════════════════════════════════════════════════════════════╗"
echo "║ DevOps Assignment — Full Automation                        ║"
echo "║ Repository: $REPO_URL"
echo "║ Commit: $GIT_SHA"
echo "╚════════════════════════════════════════════════════════════╝"

# Check prerequisites
command -v docker >/dev/null || { echo "ERROR: docker not found"; exit 1; }
command -v git >/dev/null || { echo "ERROR: git not found"; exit 1; }

echo ""
echo "=== Phase 0: Cluster Bootstrap ==="
if docker compose ps 2>/dev/null | grep -q "elsa-toolbox"; then
  echo "Cluster already running. Skipping docker compose up."
else
  echo "Starting cluster..."
  docker compose up -d
  sleep 30
fi
kubectl get nodes

echo ""
echo "=== Phase 1: Build & Push App Image ==="
bash scripts/10-build.sh

echo ""
echo "=== Phase 2: Deploy ArgoCD & Application ==="
bash scripts/15-deploy-argocd.sh
bash scripts/20-deploy.sh

echo ""
echo "=== Phase 2.4: Node Reclaim Drill ==="
bash scripts/25-reclaim-drill.sh

echo ""
echo "=== Phase 3: Troubleshooting (Part 3) ==="
bash scripts/30-troubleshoot.sh

echo ""
echo "╔════════════════════════════════════════════════════════════╗"
echo "║ ✓ All phases complete!                                    ║"
echo "╚════════════════════════════════════════════════════════════╝"

echo ""
echo "📋 Verify everything is working:"
echo "   $ curl http://localhost:8080/api/quote"
echo "   $ bash troubleshoot/verify.sh"

echo ""
echo "🔍 View cluster state:"
echo "   $ kubectl get all -n troubleshoot"
echo "   $ kubectl get all -n default"

echo ""
echo "🎯 Next steps:"
echo "   • View ArgoCD UI: http://localhost:8888 (admin / 6FjraTi5ll6TWtx2)"
echo "   • Check app logs: kubectl logs -n default -l app=quote-api --tail=20"
echo "   • Run Part 6 (load testing): bash scripts/50-load-test-setup.sh && bash scripts/60-loadtest.sh"
