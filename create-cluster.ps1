#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Creates a minimal two-node Talos Linux cluster on Hyper-V.
.DESCRIPTION
    Downloads the Talos ISO (if needed), creates one control-plane and one
    worker VM on the Hyper-V Default Switch, applies machine configs, and
    bootstraps the cluster.
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ── Configuration ────────────────────────────────────────────────────────────
$ClusterName  = 'talos-hypv'
$TalosVersion = 'v1.12.4'
$VmSwitch     = 'Default Switch'

$CpName       = "$ClusterName-cp-01"
$WorkerName   = "$ClusterName-worker-01"

$CpuCount     = 2
$MemoryBytes  = 4GB
$DiskSizeBytes = 20GB

$IsoDir       = Join-Path $PSScriptRoot 'iso'
$OutDir       = Join-Path $PSScriptRoot '_out'

# Detect host architecture for correct ISO
$Arch = if ([System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture -eq 'Arm64') { 'arm64' } else { 'amd64' }
$IsoFilename  = "metal-$Arch.iso"
$IsoPath      = Join-Path $IsoDir $IsoFilename
$IsoUrl       = "https://github.com/siderolabs/talos/releases/download/$TalosVersion/$IsoFilename"

$IpTimeout    = 180   # seconds to wait for VMs to get an IP
$BootTimeout  = 300   # seconds to wait for nodes after config apply

# ── Helper functions ─────────────────────────────────────────────────────────

function Write-Step { param([string]$Message) Write-Host "`n>> $Message" -ForegroundColor Cyan }
function Write-Ok   { param([string]$Message) Write-Host "   $Message" -ForegroundColor Green }
function Write-Warn { param([string]$Message) Write-Host "   $Message" -ForegroundColor Yellow }

function Wait-ForVmIp {
    param(
        [string]$VMName,
        [int]$TimeoutSeconds = 180
    )
    $elapsed = 0
    while ($elapsed -lt $TimeoutSeconds) {
        $addrs = (Get-VMNetworkAdapter -VMName $VMName).IPAddresses |
                 Where-Object { $_ -match '^\d+\.\d+\.\d+\.\d+$' }
        if ($addrs) { return $addrs[0] }
        Start-Sleep -Seconds 5
        $elapsed += 5
        Write-Host "." -NoNewline
    }
    throw "Timed out waiting for $VMName to obtain an IPv4 address."
}

function New-TalosVM {
    param(
        [string]$Name,
        [string]$SwitchName,
        [string]$IsoPath,
        [int]$Cpu,
        [long]$Memory,
        [long]$DiskSize
    )

    $defaultVhdPath = (Get-VMHost).VirtualHardDiskPath
    $vhdPath = Join-Path $defaultVhdPath "$Name.vhdx"

    Write-Ok "Creating VM: $Name"
    New-VM -Name $Name `
           -Generation 2 `
           -MemoryStartupBytes $Memory `
           -SwitchName $SwitchName `
           -NewVHDPath $vhdPath `
           -NewVHDSizeBytes $DiskSize | Out-Null

    Set-VM -Name $Name -ProcessorCount $Cpu -CheckpointType Disabled
    Set-VMFirmware -VMName $Name -EnableSecureBoot Off

    # Attach ISO and set boot order: DVD first, then HDD
    Add-VMDvdDrive -VMName $Name -Path $IsoPath
    $dvd = Get-VMDvdDrive -VMName $Name
    $hdd = Get-VMHardDiskDrive -VMName $Name
    Set-VMFirmware -VMName $Name -BootOrder $dvd, $hdd
}

# ── Preflight checks ────────────────────────────────────────────────────────

Write-Step 'Checking prerequisites'

if (-not (Get-Module -ListAvailable -Name Hyper-V)) {
    throw 'Hyper-V PowerShell module not found. Enable the Hyper-V feature first.'
}
Write-Ok 'Hyper-V module available'

if (-not (Get-Command talosctl -ErrorAction SilentlyContinue)) {
    throw 'talosctl not found in PATH. Install it first.'
}
Write-Ok "talosctl found: $(talosctl version --client --short 2>&1)"

# ── Download ISO ─────────────────────────────────────────────────────────────

Write-Step 'Ensuring Talos ISO is available'

if (Test-Path $IsoPath) {
    Write-Ok "ISO already exists at $IsoPath"
} else {
    New-Item -ItemType Directory -Path $IsoDir -Force | Out-Null
    Write-Ok "Downloading $IsoUrl ..."
    $ProgressPreference = 'SilentlyContinue'   # speed up Invoke-WebRequest
    Invoke-WebRequest -Uri $IsoUrl -OutFile $IsoPath -UseBasicParsing
    $ProgressPreference = 'Continue'
    Write-Ok "ISO saved to $IsoPath"
}

# ── Create VMs ───────────────────────────────────────────────────────────────

Write-Step 'Creating Hyper-V virtual machines'

foreach ($name in @($CpName, $WorkerName)) {
    if (Get-VM -Name $name -ErrorAction SilentlyContinue) {
        throw "VM '$name' already exists. Run destroy-cluster.ps1 first."
    }
}

New-TalosVM -Name $CpName     -SwitchName $VmSwitch -IsoPath $IsoPath -Cpu $CpuCount -Memory $MemoryBytes -DiskSize $DiskSizeBytes
New-TalosVM -Name $WorkerName -SwitchName $VmSwitch -IsoPath $IsoPath -Cpu $CpuCount -Memory $MemoryBytes -DiskSize $DiskSizeBytes

# ── Start VMs & wait for IPs ────────────────────────────────────────────────

Write-Step 'Starting VMs and waiting for IP addresses'

Start-VM -Name $CpName
Start-VM -Name $WorkerName

Write-Host "   Waiting for $CpName IP " -NoNewline
$CpIp = Wait-ForVmIp -VMName $CpName -TimeoutSeconds $IpTimeout
Write-Ok "`n   $CpName -> $CpIp"

Write-Host "   Waiting for $WorkerName IP " -NoNewline
$WorkerIp = Wait-ForVmIp -VMName $WorkerName -TimeoutSeconds $IpTimeout
Write-Ok "`n   $WorkerName -> $WorkerIp"

# ── Generate Talos configs ───────────────────────────────────────────────────

Write-Step 'Generating Talos machine configurations'

if (Test-Path $OutDir) { Remove-Item -Recurse -Force $OutDir }
New-Item -ItemType Directory -Path $OutDir -Force | Out-Null

talosctl gen config $ClusterName "https://${CpIp}:6443" --output-dir $OutDir
if ($LASTEXITCODE -ne 0) { throw 'talosctl gen config failed.' }
Write-Ok "Configs written to $OutDir"

# ── Apply configs ────────────────────────────────────────────────────────────

Write-Step 'Applying machine configurations'

talosctl apply-config --insecure --nodes $CpIp --file (Join-Path $OutDir 'controlplane.yaml')
if ($LASTEXITCODE -ne 0) { throw 'Failed to apply controlplane config.' }
Write-Ok "Applied controlplane.yaml to $CpIp"

talosctl apply-config --insecure --nodes $WorkerIp --file (Join-Path $OutDir 'worker.yaml')
if ($LASTEXITCODE -ne 0) { throw 'Failed to apply worker config.' }
Write-Ok "Applied worker.yaml to $WorkerIp"

# ── Wait for nodes to install and reboot ─────────────────────────────────────

Write-Step "Waiting for nodes to install Talos and reboot ($BootTimeout`s timeout)"

$talosconfig = Join-Path $OutDir 'talosconfig'

# Configure talosctl to talk to the control plane
talosctl --talosconfig $talosconfig config endpoint $CpIp
talosctl --talosconfig $talosconfig config node $CpIp

$elapsed = 0
while ($elapsed -lt $BootTimeout) {
    $result = talosctl --talosconfig $talosconfig version 2>&1
    if ($LASTEXITCODE -eq 0) { break }
    Start-Sleep -Seconds 10
    $elapsed += 10
    Write-Host "." -NoNewline
}
if ($elapsed -ge $BootTimeout) { throw 'Timed out waiting for Talos API on control plane.' }
Write-Ok "`nTalos API is responding on $CpIp"

# ── Bootstrap cluster ────────────────────────────────────────────────────────

Write-Step 'Bootstrapping the cluster'

talosctl --talosconfig $talosconfig bootstrap
if ($LASTEXITCODE -ne 0) { throw 'talosctl bootstrap failed.' }
Write-Ok 'Bootstrap initiated'

# Wait for etcd and Kubernetes API
Write-Warn 'Waiting for Kubernetes API to become ready (this may take a few minutes)...'
$elapsed = 0
while ($elapsed -lt $BootTimeout) {
    $result = talosctl --talosconfig $talosconfig health --wait-timeout 10s 2>&1
    if ($LASTEXITCODE -eq 0) { break }
    Start-Sleep -Seconds 15
    $elapsed += 15
    Write-Host "." -NoNewline
}
Write-Ok "`nCluster is healthy"

# ── Retrieve kubeconfig ──────────────────────────────────────────────────────

Write-Step 'Retrieving kubeconfig'

$kubeconfigPath = Join-Path $OutDir 'kubeconfig'
talosctl --talosconfig $talosconfig kubeconfig $kubeconfigPath
if ($LASTEXITCODE -ne 0) { throw 'Failed to retrieve kubeconfig.' }
Write-Ok "Kubeconfig saved to $kubeconfigPath"

# ── Summary ──────────────────────────────────────────────────────────────────

Write-Host "`n" -NoNewline
Write-Host '══════════════════════════════════════════════════════════' -ForegroundColor Green
Write-Host '  Talos cluster is ready!' -ForegroundColor Green
Write-Host '══════════════════════════════════════════════════════════' -ForegroundColor Green
Write-Host "  Cluster name : $ClusterName"
Write-Host "  Control plane: $CpName ($CpIp)"
Write-Host "  Worker       : $WorkerName ($WorkerIp)"
Write-Host "  Talosconfig  : $talosconfig"
Write-Host "  Kubeconfig   : $kubeconfigPath"
Write-Host ''
Write-Host "  kubectl --kubeconfig '$kubeconfigPath' get nodes" -ForegroundColor Yellow
Write-Host ''
