#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Deploys Cilium CNI on the Talos cluster, replacing Flannel and kube-proxy.
.DESCRIPTION
    1. Patches all nodes to disable the default Flannel CNI and kube-proxy.
    2. Nodes reboot automatically after the config change.
    3. Installs Cilium via Helm while nodes are rebooting.
    4. Waits for all nodes to become Ready and Cilium pods to be Running.
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepoRoot     = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$OutDir       = Join-Path $RepoRoot '_out'
$Talosconfig  = Join-Path $OutDir 'talosconfig'
$Kubeconfig   = Join-Path $OutDir 'kubeconfig'
$PatchFile    = Join-Path $PSScriptRoot 'talos-patch.yaml'
$ValuesFile   = Join-Path $PSScriptRoot 'cilium-values.yaml'

function Write-Step { param([string]$Message) Write-Host "`n>> $Message" -ForegroundColor Cyan }
function Write-Ok   { param([string]$Message) Write-Host "   $Message" -ForegroundColor Green }
function Write-Warn { param([string]$Message) Write-Host "   $Message" -ForegroundColor Yellow }

# ── Preflight ─────────────────────────────────────────────────────────────────

Write-Step 'Checking prerequisites'

if (-not (Test-Path $Talosconfig)) { throw "talosconfig not found at $Talosconfig" }
if (-not (Test-Path $Kubeconfig))  { throw "kubeconfig not found at $Kubeconfig" }
if (-not (Get-Command helm -ErrorAction SilentlyContinue)) { throw 'helm not found in PATH.' }

$env:KUBECONFIG = $Kubeconfig
$env:TALOSCONFIG = $Talosconfig

# Discover node IPs
$nodes = kubectl get nodes -o jsonpath='{.items[*].status.addresses[?(@.type=="InternalIP")].address}' 2>&1
$nodeIps = $nodes -split '\s+'
Write-Ok "Cluster nodes: $($nodeIps -join ', ')"

# ── Patch machine config ─────────────────────────────────────────────────────

Write-Step 'Patching machine config on all nodes (disable Flannel + kube-proxy)'
Write-Warn 'Nodes will reboot after this change!'

foreach ($ip in $nodeIps) {
    Write-Ok "Patching $ip ..."
    talosctl patch machineconfig --nodes $ip --patch @$PatchFile
    if ($LASTEXITCODE -ne 0) { throw "Failed to patch node $ip" }
}

Write-Warn 'Waiting 30s for nodes to begin rebooting...'
Start-Sleep -Seconds 30

# ── Install Cilium via Helm ───────────────────────────────────────────────────

Write-Step 'Adding Cilium Helm repo and installing Cilium'

helm repo add cilium https://helm.cilium.io/ 2>&1 | Out-Null
helm repo update cilium 2>&1 | Out-Null

helm upgrade --install cilium cilium/cilium `
    --namespace kube-system `
    --values $ValuesFile `
    --wait `
    --timeout 10m

if ($LASTEXITCODE -ne 0) { throw 'Cilium Helm install failed.' }
Write-Ok 'Cilium installed successfully'

# ── Wait for nodes to become Ready ────────────────────────────────────────────

Write-Step 'Waiting for all nodes to become Ready (up to 5 minutes)'

$timeout = 300
$elapsed = 0
while ($elapsed -lt $timeout) {
    $notReady = kubectl get nodes --no-headers 2>&1 |
                Select-String -Pattern 'NotReady'
    if (-not $notReady) {
        $allReady = kubectl get nodes --no-headers 2>&1
        if ($allReady) { break }
    }
    Start-Sleep -Seconds 10
    $elapsed += 10
    Write-Host '.' -NoNewline
}
if ($elapsed -ge $timeout) { throw 'Timed out waiting for nodes to become Ready.' }
Write-Ok "`nAll nodes are Ready"

# ── Verify ────────────────────────────────────────────────────────────────────

Write-Step 'Verifying Cilium pods'

kubectl -n kube-system get pods -l app.kubernetes.io/name=cilium
kubectl -n kube-system get pods -l app.kubernetes.io/name=cilium-operator

Write-Step 'Verifying Hubble'

kubectl -n kube-system get pods -l app.kubernetes.io/name=hubble-relay
kubectl -n kube-system get pods -l app.kubernetes.io/name=hubble-ui

Write-Host "`n" -NoNewline
Write-Host '══════════════════════════════════════════════════════════' -ForegroundColor Green
Write-Host '  Cilium CNI deployed successfully!' -ForegroundColor Green
Write-Host '══════════════════════════════════════════════════════════' -ForegroundColor Green
Write-Host '  Hubble UI: kubectl -n kube-system port-forward svc/hubble-ui 12000:80' -ForegroundColor Yellow
Write-Host ''
