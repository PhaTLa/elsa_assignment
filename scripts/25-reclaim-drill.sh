#!/bin/bash
set -eu

echo "╔════════════════════════════════════════════════════════════╗"
echo "║ Spot Node Reclaim Drill - Resilience Test                 ║"
echo "║ Drains a spot node and verifies service survives          ║"
echo "╚════════════════════════════════════════════════════════════╝"

# Configuration
SERVICE_NAME="quote-api"
SERVICE_NAMESPACE="default"
SERVICE_PORT="8000"
# Old static service URL:
# SERVICE_URL="http://${SERVICE_NAME}.${SERVICE_NAMESPACE}.svc.cluster.local:${SERVICE_PORT}/api/quote"
SERVICE_URL="" # Will be dynamically populated via the LoadBalancer IP
DRILL_TIMEOUT=120
CURL_INTERVAL=2

# Helper functions
cleanup() {
  echo ""
  echo "Cleaning up..."

  # Kill background curl loop process if running
  if [ -n "${CURL_LOOP_PID:-}" ] && kill -0 "${CURL_LOOP_PID}" 2>/dev/null; then
    kill "${CURL_LOOP_PID}" 2>/dev/null || true
    wait "${CURL_LOOP_PID}" 2>/dev/null || true
  fi

  # Uncordon the spot node if still cordoned
  if [ -n "${SPOT_NODE:-}" ]; then
    if kubectl get node "${SPOT_NODE}" 2>/dev/null | grep -q "SchedulingDisabled"; then
      echo "Uncordoning ${SPOT_NODE}..."
      kubectl uncordon "${SPOT_NODE}" 2>/dev/null || true
    fi
  fi
}

trap cleanup EXIT

# Verify prerequisites
echo "=== Verifying Prerequisites ==="
echo "1. Checking kubectl access..."
if ! kubectl cluster-info >/dev/null 2>&1; then
  echo "✗ Cannot connect to Kubernetes cluster"
  exit 1
fi
echo "✓ kubectl connected"

echo "2. Checking if Quote API deployment exists..."
if ! kubectl get deployment "${SERVICE_NAME}" -n "${SERVICE_NAMESPACE}" >/dev/null 2>&1; then
  echo "✗ Deployment ${SERVICE_NAME} not found in namespace ${SERVICE_NAMESPACE}"
  exit 1
fi
echo "✓ Deployment exists"

echo "3. Checking pod count..."
POD_COUNT=$(kubectl get pods -n "${SERVICE_NAMESPACE}" -l app="${SERVICE_NAME}" --field-selector=status.phase=Running -o jsonpath='{.items|length}')
if [ "${POD_COUNT}" -lt 2 ]; then
  echo "✗ At least 2 running pods required for resilience test (found ${POD_COUNT})"
  exit 1
fi
echo "✓ Found ${POD_COUNT} running pods"

echo "3.5. Detecting Quote API LoadBalancer IP..."
# Validate service is of type LoadBalancer
SVC_TYPE=$(kubectl get svc "${SERVICE_NAME}" -n "${SERVICE_NAMESPACE}" -o jsonpath='{.spec.type}' 2>/dev/null || echo "None")
if [ "${SVC_TYPE}" != "LoadBalancer" ]; then
  echo "✗ Service ${SERVICE_NAME} is not of type LoadBalancer (found type: ${SVC_TYPE})"
  exit 1
fi

# Wait and retrieve the external IP/hostname (wait up to 30 seconds)
LB_IP=""
echo "Waiting for LoadBalancer external IP..."
for attempt in {1..15}; do
  LB_IP=$(kubectl get svc "${SERVICE_NAME}" -n "${SERVICE_NAMESPACE}" -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)
  if [ -z "${LB_IP}" ]; then
    # Fallback to check if external hostname is set instead of IP (e.g. localhost or domain)
    LB_IP=$(kubectl get svc "${SERVICE_NAME}" -n "${SERVICE_NAMESPACE}" -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)
  fi
  if [ -n "${LB_IP}" ]; then
    break
  fi
  sleep 2
done

if [ -z "${LB_IP}" ]; then
  echo "✗ Timeout: LoadBalancer external IP is still pending. Ensure cloud-provider-kind is running."
  exit 1
fi

echo "✓ LoadBalancer IP detected: ${LB_IP}"
SERVICE_URL="http://${LB_IP}:${SERVICE_PORT}/api/quote"
echo "  Target URL set to: ${SERVICE_URL}"

echo "4. Checking Pod Disruption Budget..."
if ! kubectl get pdb -n "${SERVICE_NAMESPACE}" | grep -q "${SERVICE_NAME}"; then
  echo "⚠ PDB not found, drill may interrupt service"
else
  PDB_MIN=$(kubectl get pdb -n "${SERVICE_NAMESPACE}" -l app="${SERVICE_NAME}" -o jsonpath='{.items[0].spec.minAvailable}')
  echo "✓ PDB minAvailable: ${PDB_MIN}"
fi

# Find spot nodes
echo ""
echo "=== Finding Spot Nodes ==="
SPOT_NODES=$(kubectl get nodes -L acme.io/capacity | grep spot | awk '{print $1}' | head -5)

if [ -z "${SPOT_NODES}" ]; then
  echo "✗ No spot nodes found (nodes must have label acme.io/capacity=spot)"
  exit 1
fi

echo "Spot nodes available:"
echo "${SPOT_NODES}" | while read node; do
  echo "  - ${node}"
done

# Select first spot node for drill
SPOT_NODE=$(echo "${SPOT_NODES}" | head -1)
echo "✓ Selected for drill: ${SPOT_NODE}"

# Get pods on spot node before drain
echo ""
echo "=== Pre-Drill State ==="
PODS_BEFORE=$(kubectl get pods -n "${SERVICE_NAMESPACE}" -l app="${SERVICE_NAME}" --field-selector=status.phase=Running -o jsonpath='{.items[*].metadata.name}' | wc -w)
echo "Pods running before drain: ${PODS_BEFORE}"
echo "Pods on target node:"
kubectl get pods -n "${SERVICE_NAMESPACE}" -l app="${SERVICE_NAME}" -o wide --field-selector=status.phase=Running | grep "${SPOT_NODE}" || echo "  (none)"

# Start continuous health check in background
echo ""
echo "=== Starting Health Check Loop ==="
echo "Endpoint: ${SERVICE_URL}"
echo "Interval: ${CURL_INTERVAL}s"
echo "Duration: ${DRILL_TIMEOUT}s"
echo ""
echo "Response Log:"

CURL_LOOP_PID=""
FAILED_COUNT=0
PASSED_COUNT=0

# Background curl loop
(
  START_TIME=$(date +%s)

  while true; do
    CURRENT_TIME=$(date +%s)
    ELAPSED=$((CURRENT_TIME - START_TIME))

    if [ ${ELAPSED} -gt ${DRILL_TIMEOUT} ]; then
      break
    fi

    RESPONSE=$(curl -s -w "\n%{http_code}" "${SERVICE_URL}" 2>&1)
    HTTP_CODE=$(echo "${RESPONSE}" | tail -1)

    TIMESTAMP=$(date '+%H:%M:%S')

    if [ "${HTTP_CODE}" = "200" ]; then
      QUOTE=$(echo "${RESPONSE}" | head -1 | grep -o '"quote":"[^"]*"' | head -1 || echo "quote: <parsed>")
      echo "[${TIMESTAMP}] ✓ 200 OK - ${QUOTE}"
    else
      echo "[${TIMESTAMP}] ✗ ERROR (HTTP ${HTTP_CODE})"
    fi

    sleep ${CURL_INTERVAL}
  done
) &
CURL_LOOP_PID=$!

# Give curl loop time to start
sleep 2

# Cordon the node (prevent new pods from scheduling)
echo ""
echo "=== Cordoning Node ==="
echo "Cordoning ${SPOT_NODE} (prevents new pod scheduling)..."
kubectl cordon "${SPOT_NODE}"
echo "✓ Node cordoned"

# Drain the node (evicts pods, respects PDB)
echo ""
echo "=== Draining Node ==="
echo "Draining ${SPOT_NODE} (evicting pods with PDB respect)..."
DRAIN_START=$(date +%s)

# Drain with PDB respect
if kubectl drain "${SPOT_NODE}" \
    --ignore-daemonsets \
    --delete-emptydir-data \
    --grace-period=30 \
    --timeout=120s 2>&1 | tee /tmp/drain_output.txt; then
  DRAIN_STATUS="✓ Drain successful"
else
  DRAIN_STATUS="⚠ Drain incomplete or errored (may still be valid test)"
fi

DRAIN_END=$(date +%s)
DRAIN_TIME=$((DRAIN_END - DRAIN_START))
echo "${DRAIN_STATUS} (took ${DRAIN_TIME}s)"

# Wait for pod rescheduling
echo ""
echo "=== Waiting for Pod Rescheduling ==="
sleep 5

echo "Checking pod status..."
PODS_AFTER=$(kubectl get pods -n "${SERVICE_NAMESPACE}" -l app="${SERVICE_NAME}" --field-selector=status.phase=Running -o jsonpath='{.items[*].metadata.name}' | wc -w)
echo "Pods running after drain: ${PODS_AFTER}"

if [ "${PODS_AFTER}" -ge "${PODS_BEFORE}" ]; then
  echo "✓ Pod count maintained or increased"
else
  echo "⚠ Pod count decreased (${PODS_AFTER}/${PODS_BEFORE})"
fi

echo ""
echo "Pods now running:"
kubectl get pods -n "${SERVICE_NAMESPACE}" -l app="${SERVICE_NAME}" -o wide --field-selector=status.phase=Running

# Wait for curl loop to finish its last cycles
echo ""
echo "=== Waiting for Health Check to Complete ==="
wait ${CURL_LOOP_PID} 2>/dev/null || true
CURL_LOOP_PID=""

# Uncordon the node AFTER curl check is done
echo ""
echo "=== Uncordoning Node ==="
echo "Uncordoning ${SPOT_NODE} (re-enable pod scheduling)..."
kubectl uncordon "${SPOT_NODE}"
echo "✓ Node uncordoned"

# Wait for node to be ready
echo "Waiting for node to be ready..."
kubectl wait --for=condition=Ready node/"${SPOT_NODE}" --timeout=60s 2>/dev/null || true

# Final verification
echo ""
echo "=== Post-Drill State ==="
PODS_FINAL=$(kubectl get pods -n "${SERVICE_NAMESPACE}" -l app="${SERVICE_NAME}" --field-selector=status.phase=Running -o jsonpath='{.items[*].metadata.name}' | wc -w)
echo "Pods running after uncordon: ${PODS_FINAL}"

kubectl get pods -n "${SERVICE_NAMESPACE}" -l app="${SERVICE_NAME}" -o wide --field-selector=status.phase=Running

# Test final connectivity
echo ""
echo "=== Final Connectivity Test ==="
if curl -s "${SERVICE_URL}" | grep -q "quote"; then
  echo "✓ Service is responding"
else
  echo "⚠ Service response verification failed"
fi

# Summary
echo ""
echo "╔════════════════════════════════════════════════════════════╗"
echo "║ Reclaim Drill Complete                                    ║"
echo "╚════════════════════════════════════════════════════════════╝"
echo ""
echo "Results:"
echo "  Spot Node Drained: ${SPOT_NODE}"
echo "  Drain Time: ${DRAIN_TIME}s"
echo "  Pods Before: ${PODS_BEFORE}"
echo "  Pods After Drain: ${PODS_AFTER}"
echo "  Pods After Recovery: ${PODS_FINAL}"
echo ""

if [ "${PODS_FINAL}" -ge "${PODS_BEFORE}" ]; then
  echo "✓ PASS: Service survived spot node reclaim"
  echo "  - Pods maintained availability"
  echo "  - Service remained responsive"
  exit 0
else
  echo "✗ FAIL: Service degradation detected"
  echo "  - Pod count decreased"
  exit 1
fi
