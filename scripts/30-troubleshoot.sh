#!/bin/bash
set -eu

echo "=== Part 3: Troubleshooting ==="

# Check if namespace already exists
if kubectl get namespace troubleshoot >/dev/null 2>&1; then
  echo "Namespace 'troubleshoot' already exists. Deleting for clean restart..."
  kubectl delete namespace troubleshoot --wait=true
  sleep 5
fi

echo "Applying fixed manifests from troubleshoot/fixed-app.yaml..."
kubectl apply -f troubleshoot/fixed-app.yaml

echo "Waiting for deployments to stabilize (30 seconds)..."
sleep 30

echo ""
echo "=== Running verification ==="
bash troubleshoot/verify.sh

echo ""
echo "✓ Part 3 troubleshooting complete. All checks passed."
