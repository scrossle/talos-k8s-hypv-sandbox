#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Removes a control plane or worker node from the Talos cluster.
.DESCRIPTION
    Gracefully drains the node (if worker), removes it from Kubernetes,
    shuts down the Hyper-V VM, and deletes its VHDX disk.
.PARAMETER NodeName
    Name of the VM/node to remove (e.g., 'talos-hypv-worker-02', 'talos-hypv-cp-02')
.PARAMETER Force
    Skip confirmation prompts and drain checks
.EXAMPLE
    .\scale-remove-node.ps1 -NodeName talos-hypv-worker-02
    .\scale-remove-node.ps1 -NodeName talos-hypv-cp-03 -Force
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$NodeName,

    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ── Configuration ────────────────────────────────────────────────────────────
$OutDir = Join-Path $PSScriptRoot '_out'
$talosconfig = Join-Path $OutDir 'talosconfig'
$kubeconfigPath = Join-Path $OutDir 'kubeconfig'

# ── Helper functions ─────────────────────────────────────────────────────────

function Write-Step { param([string]$Message) Write-Host "`n>> $Message" -ForegroundColor Cyan }
function Write-Ok   { param([string]$Message) Write-Host "   $Message" -ForegroundColor Green }
function Write-Warn { param([string]$Message) Write-Host "   $Message" -ForegroundColor Yellow }
function Write-Err  { param([string]$Message) Write-Host "   $Message" -ForegroundColor Red }

# ── Preflight checks ────────────────────────────────────────────────────────

Write-Step 'Checking prerequisites'

if (-not (Get-Module -ListAvailable -Name Hyper-V)) {
    throw 'Hyper-V PowerShell module not found.'
}
Write-Ok 'Hyper-V module available'

if (-not (Get-Command kubectl -ErrorAction SilentlyContinue)) {
    throw 'kubectl not found in PATH.'
}
Write-Ok 'kubectl found'

if (-not (Get-Command talosctl -ErrorAction SilentlyContinue)) {
    throw 'talosctl not found in PATH.'
}
Write-Ok 'talosctl found'

if (-not (Test-Path $talosconfig) -or -not (Test-Path $kubeconfigPath)) {
    throw "Cluster config files not found in $OutDir."
}
Write-Ok 'Cluster config files found'

# ── Resolve VM and node names ───────────────────────────────────────────────

Write-Step "Resolving VM and Kubernetes node"

$env:KUBECONFIG = $kubeconfigPath

# Try to find VM by exact name first
$vm = Get-VM -Name $NodeName -ErrorAction SilentlyContinue
$k8sNodeName = $NodeName

if (-not $vm) {
    # Not a VM name - check if it's a Kubernetes node name
    Write-Warn "No VM named '$NodeName' found. Checking if it's a Kubernetes node name..."

    $nodeJson = kubectl get node $NodeName -o json 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "Neither a VM nor a Kubernetes node named '$NodeName' was found."
    }

    $nodeInfo = $nodeJson | ConvertFrom-Json
    $nodeIp = ($nodeInfo.status.addresses | Where-Object { $_.type -eq 'InternalIP' }).address

    if (-not $nodeIp) {
        throw "Could not determine IP address for node '$NodeName'."
    }

    Write-Ok "Found Kubernetes node '$NodeName' with IP $nodeIp"

    # Find the VM with this IP by checking ARP table
    $allVms = Get-VM -Name 'talos-hypv-*' -ErrorAction SilentlyContinue
    foreach ($candidateVm in $allVms) {
        $rawMac = (Get-VMNetworkAdapter -VMName $candidateVm.Name).MacAddress
        $mac = ($rawMac -replace '(.{2})', '$1-').TrimEnd('-')
        $neighbour = Get-NetNeighbor -LinkLayerAddress $mac -ErrorAction SilentlyContinue |
                     Where-Object { $_.AddressFamily -eq 'IPv4' -and $_.IPAddress -eq $nodeIp }
        if ($neighbour) {
            $vm = $candidateVm
            Write-Ok "Matched to VM: $($vm.Name)"
            break
        }
    }

    if (-not $vm) {
        throw "Could not find Hyper-V VM for Kubernetes node '$NodeName' (IP: $nodeIp)."
    }
} else {
    Write-Ok "Found VM: $NodeName"

    # Get the corresponding Kubernetes node name
    $vmIp = $null
    $rawMac = (Get-VMNetworkAdapter -VMName $vm.Name).MacAddress
    $mac = ($rawMac -replace '(.{2})', '$1-').TrimEnd('-')
    $neighbour = Get-NetNeighbor -LinkLayerAddress $mac -ErrorAction SilentlyContinue |
                 Where-Object { $_.AddressFamily -eq 'IPv4' -and $_.IPAddress -notlike '169.254.*' }
    if ($neighbour) {
        $vmIp = $neighbour.IPAddress
    }

    if ($vmIp) {
        # Find k8s node with this IP
        $nodes = kubectl get nodes -o json | ConvertFrom-Json
        foreach ($node in $nodes.items) {
            $nodeIp = ($node.status.addresses | Where-Object { $_.type -eq 'InternalIP' }).address
            if ($nodeIp -eq $vmIp) {
                $k8sNodeName = $node.metadata.name
                Write-Ok "Matched to Kubernetes node: $k8sNodeName"
                break
            }
        }
    }
}

# ── Check node type ──────────────────────────────────────────────────────────

$nodeInfo = kubectl get node $k8sNodeName -o json 2>&1 | ConvertFrom-Json
$labels = $nodeInfo.metadata.labels
$isControlPlane = if ($labels.PSObject.Properties['node-role.kubernetes.io/control-plane']) {
    $labels.'node-role.kubernetes.io/control-plane' -eq 'true'
} else {
    $false
}
$nodeType = if ($isControlPlane) { 'control-plane' } else { 'worker' }

Write-Ok "Node type: $nodeType"

# ── Confirmation prompt ──────────────────────────────────────────────────────

if (-not $Force) {
    Write-Host "`n" -NoNewline
    Write-Host "═══════════════════════════════════════════════" -ForegroundColor Yellow
    Write-Host " WARNING: About to remove $nodeType node" -ForegroundColor Yellow
    Write-Host "═══════════════════════════════════════════════" -ForegroundColor Yellow
    Write-Host "  VM name: $($vm.Name)"
    Write-Host "  K8s node: $k8sNodeName"
    Write-Host "  Type: $nodeType"

    if ($isControlPlane) {
        Write-Host ""
        Write-Warn "Removing a control-plane node reduces cluster HA."
        Write-Warn "Ensure you have sufficient control-plane nodes remaining."
        Write-Warn "A single-node control plane will lose quorum!"
    }

    Write-Host ""
    $confirm = Read-Host "Type 'yes' to proceed with removal"
    if ($confirm -ne 'yes') {
        Write-Host "Aborted." -ForegroundColor Yellow
        exit 0
    }
}

# ── Drain node (if worker) ───────────────────────────────────────────────────

if (-not $isControlPlane) {
    Write-Step 'Draining workloads from worker node'

    kubectl drain $k8sNodeName --ignore-daemonsets --delete-emptydir-data --timeout=300s 2>&1
    if ($LASTEXITCODE -ne 0) {
        if (-not $Force) {
            throw "Failed to drain $k8sNodeName. Use -Force to skip drain checks."
        }
        Write-Warn "Drain failed, continuing anyway (Force mode)"
    } else {
        Write-Ok "$k8sNodeName drained successfully"
    }
} else {
    Write-Warn "Control-plane nodes are not drained (workloads should not run here)"
}

# ── Delete node from Kubernetes ──────────────────────────────────────────────

Write-Step 'Deleting node from Kubernetes'

kubectl delete node $k8sNodeName --timeout=60s 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Warn "Failed to delete node from Kubernetes (it may already be gone)"
} else {
    Write-Ok "$k8sNodeName deleted from Kubernetes"
}

# ── Shutdown and remove VM ───────────────────────────────────────────────────

Write-Step 'Shutting down and removing VM'

if ($vm.State -eq 'Running') {
    Write-Ok "Stopping VM: $($vm.Name)"
    Stop-VM -Name $vm.Name -Force -TurnOff
}

# Get VHDX path before removing VM
$vhdx = Get-VMHardDiskDrive -VMName $vm.Name
$vhdxPath = $vhdx.Path

Write-Ok "Removing VM: $($vm.Name)"
Remove-VM -Name $vm.Name -Force

if ($vhdxPath -and (Test-Path $vhdxPath)) {
    Write-Ok "Deleting disk: $vhdxPath"
    Remove-Item -Path $vhdxPath -Force
}

# ── Summary ──────────────────────────────────────────────────────────────────

Write-Host "`n" -NoNewline
Write-Host '══════════════════════════════════════════════════════════' -ForegroundColor Green
Write-Host "  Node removed successfully!" -ForegroundColor Green
Write-Host '══════════════════════════════════════════════════════════' -ForegroundColor Green
Write-Host "  VM name: $($vm.Name)"
Write-Host "  K8s node: $k8sNodeName"
Write-Host "  Node type: $nodeType"
Write-Host ''
Write-Host "  kubectl --kubeconfig '$kubeconfigPath' get nodes" -ForegroundColor Yellow
Write-Host ''
