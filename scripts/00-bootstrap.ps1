# ═══════════════════════════════════════════════════════════════════════════════
# ELSA DevOps Assignment — Bootstrap Script (PowerShell)
# ═══════════════════════════════════════════════════════════════════════════════
# Purpose: One-shot setup of entire local DevOps environment
# Usage: .\scripts\00-bootstrap.ps1
# ═══════════════════════════════════════════════════════════════════════════════

param(
    [switch]$Force = $false
)

# ─────────────────────────────────────────────────────────────────────────────
# Configuration & Helpers
# ─────────────────────────────────────────────────────────────────────────────
$SCRIPT_DIR = Split-Path -Parent $PSScriptRoot
$CLUSTER_NAME = "elsa"
$KUBECONFIG_DIR = Join-Path $SCRIPT_DIR ".kube"
$KUBECONFIG_FILE = Join-Path $KUBECONFIG_DIR "config"
$KIND_CONFIG = Join-Path $SCRIPT_DIR "kind-config.yaml"
$PREPARE_SCRIPT = Join-Path (Join-Path $SCRIPT_DIR "troubleshoot") "prepare.sh"
$CALICO_MANIFEST = Join-Path $SCRIPT_DIR "calico-custom-resources.yaml"

function Log {
    param([string]$Message)
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Write-Host "[$timestamp] $Message" -ForegroundColor Cyan
}

function LogStep {
    param([string]$Message)
    Write-Host ""
    Write-Host (@"
+================================================================+
| $Message
+================================================================+
"@) -ForegroundColor Green
}

function LogSuccess {
    param([string]$Message)
    Write-Host "[OK] $Message" -ForegroundColor Green
}

function LogError {
    param([string]$Message)
    Write-Host "[ERROR] $Message" -ForegroundColor Red
    exit 1
}

# ─────────────────────────────────────────────────────────────────────────────
# Step 1: Create KinD Cluster (idempotent)
# ─────────────────────────────────────────────────────────────────────────────
function Bootstrap-Cluster {
    LogStep "Step 1: Create KinD Cluster"

    $clusters = kind get clusters 2>$null
    if ($clusters -match $CLUSTER_NAME) {
        LogSuccess "Cluster '$CLUSTER_NAME' already exists, skipping creation"
        return
    }

    if (-not (Test-Path $KIND_CONFIG)) {
        LogError "KinD config not found: $KIND_CONFIG"
    }

    Log "Creating KinD cluster '$CLUSTER_NAME' with config: $KIND_CONFIG"
    kind create cluster --name $CLUSTER_NAME --config $KIND_CONFIG
    LogSuccess "KinD cluster created"

    # Wait for control plane
    Log "Waiting for control plane to be ready..."
    $timeout = 300
    $elapsed = 0
    while ($elapsed -lt $timeout) {
        $ready = kubectl get node -l node-role.kubernetes.io/control-plane --no-headers 2>$null | Select-Object -First 1
        if ($ready -and $ready.Split()[1] -eq "Ready") {
            LogSuccess "Control plane ready"
            return
        }
        Start-Sleep -Seconds 5
        $elapsed += 5
    }
    LogError "Control plane failed to become ready within timeout"
}

# ─────────────────────────────────────────────────────────────────────────────
# Step 2: Prepare Nodes (labels/taints)
# ─────────────────────────────────────────────────────────────────────────────
function Prepare-Nodes {
    LogStep "Step 2: Prepare Cluster Nodes (labels & taints)"

    if (-not (Test-Path $PREPARE_SCRIPT)) {
        LogError "Prepare script not found: $PREPARE_SCRIPT"
    }

    # Check if nodes already labeled (idempotence)
    $spotCount = (kubectl get nodes -L acme.io/capacity --no-headers 2>$null | Where-Object { $_ -like "*spot*" } | Measure-Object).Count
    if ($spotCount -ge 2) {
        LogSuccess "Nodes already prepared (found $spotCount spot nodes), skipping"
        return
    }

    Log "Running node preparation script..."
    bash $PREPARE_SCRIPT
    LogSuccess "Nodes prepared"
}

# ─────────────────────────────────────────────────────────────────────────────
# Step 3: Install Calico CNI (idempotent)
# ─────────────────────────────────────────────────────────────────────────────
function Install-Calico {
    LogStep "Step 3: Install Calico CNI"

    if (-not (Test-Path $CALICO_MANIFEST)) {
        LogError "Calico manifest not found: $CALICO_MANIFEST"
    }

    # Check if Calico operator already installed
    $calicoNS = kubectl get ns tigera-operator 2>$null
    if ($calicoNS) {
        LogSuccess "Calico already appears installed (tigera-operator namespace exists)"

        # Verify Installation CRD
        $calicoInstall = kubectl get installation -n tigera-operator default 2>$null
        if ($calicoInstall) {
            LogSuccess "Calico Installation resource exists, skipping install"
            return
        }
    }

    Log "Installing Calico operator..."

    # Create namespace
    kubectl create namespace tigera-operator 2>$null
    Start-Sleep -Seconds 1

    # Apply operator if not already present
    $operatorDeploy = kubectl get deployment -n tigera-operator tigera-operator 2>$null
    if (-not $operatorDeploy) {
        Log "Deploying Calico operator from remote manifest..."
        kubectl apply -f https://raw.githubusercontent.com/projectcalico/calico/v3.29.1/manifests/tigera-operator.yaml
        Log "Waiting for Calico operator to be ready..."
        Start-Sleep -Seconds 10
    }
    else {
        LogSuccess "Calico operator deployment already exists"
    }

    Log "Applying Calico custom resources..."
    kubectl apply -f $CALICO_MANIFEST

    Log "Waiting for Calico nodes to come up (this may take a minute)..."
    $timeout = 300
    $elapsed = 0
    while ($elapsed -lt $timeout) {
        $readyPods = (kubectl get pods -l k8s-app=calico-node -n calico-system --no-headers 2>$null | Where-Object { $_ -like "*1/1*" } | Measure-Object).Count
        if ($readyPods -ge 3) {
            LogSuccess "Calico installed"
            return
        }
        Start-Sleep -Seconds 5
        $elapsed += 5
    }
    Log "⚠ Calico install timeout, but continuing..."
}

# ─────────────────────────────────────────────────────────────────────────────
# Step 4: Setup Project Kubeconfig
# ─────────────────────────────────────────────────────────────────────────────
function Setup-Kubeconfig {
    LogStep "Step 4: Setup Project Kubeconfig"

    # Create .kube directory
    if (-not (Test-Path $KUBECONFIG_DIR)) {
        New-Item -ItemType Directory -Path $KUBECONFIG_DIR -Force | Out-Null
    }

    # Check if kubeconfig already exists and is valid
    if (Test-Path $KUBECONFIG_FILE) {
        $env:KUBECONFIG = $KUBECONFIG_FILE
        $test = kubectl cluster-info 2>$null
        if ($test) {
            LogSuccess "Project kubeconfig already exists and is valid"
            Remove-Item env:KUBECONFIG
            return
        }
    }

    Log "Extracting kubeconfig from host..."

    # Get host's kubeconfig
    $hostKubeconfig = if ($env:KUBECONFIG) { $env:KUBECONFIG } else { "$env:USERPROFILE\.kube\config" }
    if (-not (Test-Path $hostKubeconfig)) {
        LogError "Host kubeconfig not found at: $hostKubeconfig"
    }

    Log "Copying from: $hostKubeconfig"

    # Read, modify, and write kubeconfig
    $content = Get-Content $hostKubeconfig -Raw
    $content = $content -replace 'server: https://127\.0\.0\.1:\d+', 'server: https://elsa-control-plane:6443'
    Set-Content -Path $KUBECONFIG_FILE -Value $content

    if (-not (Test-Path $KUBECONFIG_FILE)) {
        LogError "Failed to create kubeconfig at: $KUBECONFIG_FILE"
    }

    LogSuccess "Kubeconfig copied and rewritten"
    Write-Host "  Server address: elsa-control-plane:6443 (for container network)"
}

# ─────────────────────────────────────────────────────────────────────────────
# Step 5: Start Toolbox Container
# ─────────────────────────────────────────────────────────────────────────────
function Start-Toolbox {
    LogStep "Step 5: Start Toolbox Container"

    Set-Location $SCRIPT_DIR

    # Check if container is already running
    $container = docker ps --filter "name=elsa-toolbox" --format "{{.Names}}" 2>$null
    if ($container) {
        LogSuccess "Toolbox container already running"
        return
    }

    Log "Starting toolbox container via docker-compose..."
    docker compose up -d

    # Give container a moment to start
    Start-Sleep -Seconds 2

    # Verify container is running
    $container = docker ps --filter "name=elsa-toolbox" --format "{{.Names}}" 2>$null
    if ($container) {
        LogSuccess "Toolbox container started"
    }
    else {
        LogError "Toolbox container failed to start"
    }
}

# ─────────────────────────────────────────────────────────────────────────────
# Step 6: Verification
# ─────────────────────────────────────────────────────────────────────────────
function Verify-Bootstrap {
    LogStep "Step 6: Verification"

    Log "Checking cluster status..."
    kubectl cluster-info

    Write-Host ""
    Log "Checking node status..."
    kubectl get nodes -o wide

    Write-Host ""
    Log "Checking Calico pods..."
    kubectl get pods -n calico-system --no-headers 2>$null | Select-Object -First 5

    Write-Host ""
    Log "Verifying toolbox kubectl connectivity..."
    $test = docker compose exec -T toolbox kubectl get nodes 2>$null
    if ($test) {
        LogSuccess "Toolbox kubectl works"
    }
    else {
        LogError "Toolbox kubectl failed - check kubeconfig"
    }

    Write-Host ""
}

# ─────────────────────────────────────────────────────────────────────────────
# Main
# ─────────────────────────────────────────────────────────────────────────────
function Main {
    Write-Host ""
    Write-Host @"
+================================================================+
|  ELSA DevOps Assignment - Bootstrap
|  Starting at: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
+================================================================+
"@ -ForegroundColor Green
    Write-Host ""

    try {
        Bootstrap-Cluster
        Prepare-Nodes
        Install-Calico
        Setup-Kubeconfig
        Start-Toolbox
        Verify-Bootstrap

        Write-Host ""
        Write-Host ("=" * 68) -ForegroundColor Green
        Write-Host "Bootstrap finished successfully!" -ForegroundColor Green
        Write-Host ("=" * 68) -ForegroundColor Green
        Write-Host ""
        Write-Host "Next steps:" -ForegroundColor Cyan
        Write-Host "  1. Enter toolbox: docker compose -f $SCRIPT_DIR\docker-compose.yml exec toolbox bash"
        Write-Host "  2. Run deployments: bash /scripts/run-all.sh"
        Write-Host "  3. Access services:"
        Write-Host "     - Ingress: http://localhost:8080"
        Write-Host "     - ArgoCD: http://localhost:8081 (after Part 2)"
        Write-Host "     - Prometheus: http://localhost:9090 (after Part 6)"
        Write-Host "     - Grafana: http://localhost:3000 (after Part 6)"
        Write-Host ""

    }
    catch {
        LogError "Bootstrap failed: $_"
    }
}

Main
