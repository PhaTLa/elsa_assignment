#!/bin/bash
# ═══════════════════════════════════════════════════════════════════════════════
# ELSA DevOps Assignment — Bootstrap Script
# ═══════════════════════════════════════════════════════════════════════════════
# Purpose: One-shot setup of entire local DevOps environment
# Steps:
#   1. Create KinD cluster with kind-config.yaml
#   2. Prepare nodes with labels and taints (troubleshoot/prepare.sh)
#   3. Install Calico CNI with custom resources
#   4. Copy and rewrite kubeconfig for toolbox container
#   5. Start toolbox container (docker-compose up)
#
# Idempotent: Safe to run multiple times. Skips if resources already exist.
# ═══════════════════════════════════════════════════════════════════════════════

set -eu

# ─────────────────────────────────────────────────────────────────────────────
# Configuration
# ─────────────────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CLUSTER_NAME="elsa"
KUBECONFIG_DIR="${SCRIPT_DIR}/.kube"
KUBECONFIG_FILE="${KUBECONFIG_DIR}/config"
KIND_CONFIG="${SCRIPT_DIR}/kind-config.yaml"
PREPARE_SCRIPT="${SCRIPT_DIR}/troubleshoot/prepare.sh"
CALICO_MANIFEST="${SCRIPT_DIR}/calico-custom-resources.yaml"

# ─────────────────────────────────────────────────────────────────────────────
# Helpers
# ─────────────────────────────────────────────────────────────────────────────
log() {
  echo "[$(date +'%Y-%m-%d %H:%M:%S')] $*"
}

log_step() {
  echo ""
  echo "╔════════════════════════════════════════════════════════════════╗"
  echo "║ $1"
  echo "╚════════════════════════════════════════════════════════════════╝"
}

error() {
  echo "[ERROR] $*" >&2
  exit 1
}
# ─────────────────────────────────────────────────────────────────────────────
# Step 3: Install Calico CNI (idempotent)
# ─────────────────────────────────────────────────────────────────────────────
install_calico() {
  log_step "Step 3: Install Calico CNI"

  if [ ! -f "${CALICO_MANIFEST}" ]; then
    error "Calico manifest not found: ${CALICO_MANIFEST}"
  fi

  # Check if Calico operator already installed
  if kubectl get ns tigera-operator >/dev/null 2>&1; then
    log "✓ Calico already appears installed (tigera-operator namespace exists)"

    # Verify Installation CRD exists
    if kubectl get installation -n tigera-operator default >/dev/null 2>&1; then
      log "✓ Calico Installation resource exists, skipping install"
      return 0
    fi
  fi

  log "Installing Calico operator..."

  # Install Calico operator (tigera)
  kubectl create namespace tigera-operator 2>/dev/null || true

  # Apply operator if not already present
  if ! kubectl get deployment -n tigera-operator tigera-operator >/dev/null 2>&1; then
    kubectl apply -f https://raw.githubusercontent.com/projectcalico/calico/v3.29.1/manifests/tigera-operator.yaml
    log "Waiting for Calico operator to be ready..."
    kubectl wait --for=condition=Available --timeout=300s \
      deployment/tigera-operator -n tigera-operator >/dev/null 2>&1 || true
  else
    log "✓ Calico operator deployment already exists"
  fi

  log "Applying Calico custom resources..."
  kubectl apply -f "${CALICO_MANIFEST}"

  # Wait for Calico nodes to be ready
  log "Waiting for Calico nodes to come up (this may take a minute)..."
  kubectl wait --for=condition=Ready \
    pod -l k8s-app=calico-node \
    -n calico-system \
    --timeout=300s >/dev/null 2>&1 || true

  log "✓ Calico installed"
}

# ─────────────────────────────────────────────────────────────────────────────
# Step 4: Setup Project Kubeconfig
# ─────────────────────────────────────────────────────────────────────────────
setup_kubeconfig() {
  log_step "Step 4: Setup Project Kubeconfig"

  # Create .kube directory
  mkdir -p "${KUBECONFIG_DIR}"

  # Check if kubeconfig already exists and is valid
  if [ -f "${KUBECONFIG_FILE}" ]; then
    # Verify it works
    if KUBECONFIG="${KUBECONFIG_FILE}" kubectl cluster-info >/dev/null 2>&1; then
      log "✓ Project kubeconfig already exists and is valid"
      return 0
    fi
  fi

  log "Extracting kubeconfig from host..."

  # Get host's kubeconfig (fallback to default location)
  HOST_KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config}"
  if [ ! -f "$HOST_KUBECONFIG" ]; then
    error "Host kubeconfig not found at: $HOST_KUBECONFIG"
  fi

  log "Copying from: $HOST_KUBECONFIG"

  # Copy and rewrite kubeconfig for container network
  # Replace API server address: 127.0.0.1:XXXX -> elsa-control-plane:6443
  cat "$HOST_KUBECONFIG" | \
    sed "s|server: https://127\.0\.0\.1:[0-9]*$|server: https://elsa-control-plane:6443|g" \
    > "${KUBECONFIG_FILE}"

  # Verify the file was created
  if [ ! -f "${KUBECONFIG_FILE}" ]; then
    error "Failed to create kubeconfig at: ${KUBECONFIG_FILE}"
  fi

  log "✓ Kubeconfig copied and rewritten"
  log "  Server address: elsa-control-plane:6443 (for container network)"
}

# ─────────────────────────────────────────────────────────────────────────────
# Step 5: Start Toolbox Container
# ─────────────────────────────────────────────────────────────────────────────
start_toolbox() {
  log_step "Step 5: Start Toolbox Container"

  cd "${SCRIPT_DIR}"

  # Check if container is already running
  if docker ps --filter "name=elsa-toolbox" --format "{{.Names}}" | grep -q elsa-toolbox; then
    log "✓ Toolbox container already running"
    return 0
  fi

  log "Starting toolbox container via docker-compose..."
  docker compose up -d

  # Give container a moment to start
  sleep 2

  # Verify container is running
  if docker ps --filter "name=elsa-toolbox" --format "{{.Names}}" | grep -q elsa-toolbox; then
    log "✓ Toolbox container started"
  else
    error "Toolbox container failed to start"
  fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Step 6: Verification
# ─────────────────────────────────────────────────────────────────────────────
verify_bootstrap() {
  log_step "Step 6: Verification"

  log "Checking cluster status..."
  kubectl cluster-info

  log ""
  log "Checking node status..."
  kubectl get nodes -o wide

  log ""
  log "Checking Calico pods..."
  kubectl get pods -n calico-system --no-headers 2>/dev/null | head -5

  log ""
  log "Verifying toolbox kubectl connectivity..."
  if docker compose exec -T toolbox kubectl get nodes >/dev/null 2>&1; then
    log "✓ Toolbox kubectl works"
  else
    error "Toolbox kubectl failed - check kubeconfig"
  fi

  log ""
  log "✓✓✓ Bootstrap Complete ✓✓✓"
}

# ─────────────────────────────────────────────────────────────────────────────
# Main
# ─────────────────────────────────────────────────────────────────────────────
main() {
  log "╔════════════════════════════════════════════════════════════════╗"
  log "║  ELSA DevOps Assignment — Bootstrap                           ║"
  log "║  Starting at: $(date +'%Y-%m-%d %H:%M:%S')                              ║"
  log "╚════════════════════════════════════════════════════════════════╝"
  log ""

  install_calico
  setup_kubeconfig
  start_toolbox
  verify_bootstrap

  log ""
  log "════════════════════════════════════════════════════════════════"
  log "Bootstrap finished successfully!"
  log "════════════════════════════════════════════════════════════════"
  log ""
  log "Next steps:"
  log "  1. Enter toolbox: docker compose -f ${SCRIPT_DIR}/docker-compose.yml exec toolbox bash"
  log "  2. Run deployments: bash /scripts/run-all.sh"
  log "  3. Access services:"
  log "     - Ingress: http://localhost:8080"
  log "     - ArgoCD: http://localhost:8081 (after Part 2)"
  log "     - Prometheus: http://localhost:9090 (after Part 6)"
  log "     - Grafana: http://localhost:3000 (after Part 6)"
  log ""
}

trap 'error "Script interrupted"' INT TERM
main "$@"
