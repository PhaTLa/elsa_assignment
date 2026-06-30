#!/bin/bash
# ═══════════════════════════════════════════════════════════════════════════════
# DevOps Assignment — Observability and Load Testing Environment Setup
# Purpose: Idempotent installation of Metrics Server, Prometheus & Grafana
# ═══════════════════════════════════════════════════════════════════════════════
set -eu

log() {
  echo "[$(date +'%Y-%m-%d %H:%M:%S')] $*"
}

log_step() {
  echo ""
  echo "╔════════════════════════════════════════════════════════════════╗"
  echo "║ $1"
  echo "╚════════════════════════════════════════════════════════════════╝"
}

# ─────────────────────────────────────────────────────────────────────────────
# Step 1: Install & Configure Kubernetes Metrics Server (required for HPA)
# ─────────────────────────────────────────────────────────────────────────────
log_step "Step 1: Setup Kubernetes Metrics Server"

if kubectl get deployment metrics-server -n kube-system >/dev/null 2>&1; then
  log "✓ Metrics Server deployment already exists"
else
  log "Installing Metrics Server..."
  kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
fi

# Verify patch configurations for Kind
log "Checking Metrics Server args for TLS settings..."
ARGS=$(kubectl get deployment metrics-server -n kube-system -o jsonpath='{.spec.template.spec.containers[0].args}')
if echo "$ARGS" | grep -q -- "--kubelet-insecure-tls"; then
  log "✓ Metrics Server already configured with --kubelet-insecure-tls"
else
  log "Patching Metrics Server for local Kind cluster (adding --kubelet-insecure-tls)..."
  kubectl patch deployment metrics-server -n kube-system --type='json' \
    -p='[{"op": "add", "path": "/spec/template/spec/containers/0/args/-", "value": "--kubelet-insecure-tls"}]'
fi

log "Waiting for Metrics Server to become Ready..."
kubectl rollout status deployment/metrics-server -n kube-system --timeout=90s

log "Verifying metrics API connectivity..."
# Loop a few times to allow the metrics server to gather its first scrape values
for i in {1..10}; do
  if kubectl get --raw /apis/metrics.k8s.io/v1beta1 >/dev/null 2>&1; then
    log "✓ Metrics API is active and responding"
    break
  fi
  log "  Waiting for metrics API... ($i/10)"
  sleep 3
done

# ─────────────────────────────────────────────────────────────────────────────
# Step 2: Install kube-prometheus-stack (Prometheus + Grafana)
# ─────────────────────────────────────────────────────────────────────────────
log_step "Step 2: Setup Prometheus & Grafana (kube-prometheus-stack)"

log "Configuring Prometheus Helm repo..."
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts 2>/dev/null || true
helm repo update prometheus-community

kubectl create namespace monitoring 2>/dev/null || true

# Idempotently install or upgrade Prometheus Stack (without using blocking --wait)
if helm status prometheus -n monitoring >/dev/null 2>&1; then
  log "✓ Prometheus release already exists, running upgrade..."
else
  log "Installing Prometheus Stack..."
fi

# Install or upgrade the Prometheus Stack chart
# Old config that let Grafana use default port 80 (which conflicts with ArgoCD):
# helm upgrade --install prometheus prometheus-community/kube-prometheus-stack \
#   --namespace monitoring \
#   --set prometheus.prometheusSpec.retention=24h \
#   --set grafana.adminPassword=admin \
#   --set grafana.service.type=LoadBalancer
# Old config before adding additionalScrapeConfigsSecret:
# helm upgrade --install prometheus prometheus-community/kube-prometheus-stack \
#   --namespace monitoring \
#   --set prometheus.prometheusSpec.retention=24h \
#   --set grafana.adminPassword=admin \
#   --set grafana.service.type=LoadBalancer \
#   --set grafana.service.port=81 \
#   --set grafana.service.targetPort=3000
helm upgrade --install prometheus prometheus-community/kube-prometheus-stack \
  --namespace monitoring \
  --set prometheus.prometheusSpec.retention=24h \
  --set grafana.adminPassword=admin \
  --set grafana.service.type=LoadBalancer \
  --set grafana.service.port=81 \
  --set grafana.service.targetPort=3000

log "Waiting for Prometheus Operator to be ready..."
kubectl rollout status deployment/prometheus-kube-prometheus-operator -n monitoring --timeout=120s

log "Waiting for Grafana deployment to be ready..."
kubectl rollout status deployment/prometheus-grafana -n monitoring --timeout=120s

# ─────────────────────────────────────────────────────────────────────────────
# Step 3: Configure Prometheus Scrape Job for Quote API
# ─────────────────────────────────────────────────────────────────────────────
log_step "Step 3: Apply Prometheus Custom Configuration"

log "Applying Prometheus ServiceMonitor configuration..."
# Old ConfigMap/Secret apply call:
# SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# kubectl apply -f "${SCRIPT_DIR}/../manifests/prometheus-additional.yaml"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
kubectl apply -f "${SCRIPT_DIR}/../manifests/quote-api-monitor.yaml"

log "✓ Setup Complete"
log "  Prometheus API: http://localhost:9090"
# Old log displaying default Grafana port:
# log "  Grafana Web UI: http://localhost:3000 (User: admin / Pass: admin)"
log "  Grafana Web UI: http://localhost:81 (User: admin / Pass: admin)"
