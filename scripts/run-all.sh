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
command -v kubectl >/dev/null || { echo "ERROR: kubectl not found"; exit 1; }

echo ""
echo "=== Phase 0: Cluster Bootstrap ==="
echo "Running bootstrap script (KinD cluster, Calico, kubeconfig, toolbox)..."
bash scripts/00-bootstrap.sh

echo ""
echo "Waiting for cluster to stabilize..."
sleep 5
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

