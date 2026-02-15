##Requires -RunAsAdministrator
<#
.SYNOPSIS
    Adds a new control plane or worker node to the Talos cluster.
.DESCRIPTION
    Creates a new Hyper-V VM, applies the appropriate Talos machine config,
    and joins it to the existing cluster. Auto-detects the next available node number.
.PARAMETER NodeType
    Type of node to add: 'controlplane' or 'worker'
.EXAMPLE
    .\scale-add-node.ps1 -NodeType worker
    .\scale-add-node.ps1 -NodeType controlplane
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('controlplane', 'worker')]
    [string]$NodeType
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ── Configuration ────────────────────────────────────────────────────────────
$ClusterName  = 'talos-hypv'
$VmSwitch     = 'Default Switch'

$CpuCount     = 2
$MemoryBytes  = 4GB
$DiskSizeBytes = 20GB

$IsoDir       = Join-Path $PSScriptRoot 'iso'
$OutDir       = Join-Path $PSScriptRoot '_out'

# Detect host architecture for correct ISO
$OsArch = (Get-CimInstance Win32_OperatingSystem).OSArchitecture
$Arch = if ($OsArch -match 'ARM') { 'arm64' } else { 'amd64' }
$IsoFilename  = "metal-$Arch.iso"
$IsoPath      = Join-Path $IsoDir $IsoFilename

$IpTimeout    = 180   # seconds to wait for VM to get an IP
$BootTimeout  = 300   # seconds to wait for node after config apply

# ── Helper functions ─────────────────────────────────────────────────────────

function Write-Step { param([string]$Message) Write-Host "`n>> $Message" -ForegroundColor Cyan }
function Write-Ok   { param([string]$Message) Write-Host "   $Message" -ForegroundColor Green }
function Write-Warn { param([string]$Message) Write-Host "   $Message" -ForegroundColor Yellow }

function Wait-ForVmIp {
    param(
        [string]$VMName,
        [int]$TimeoutSeconds = 180
    )

    # First, wait for the VM network adapter to have a valid MAC address
    $macTimeout = 30
    $macElapsed = 0
    $rawMac = $null

    Write-Host " (waiting for valid MAC" -NoNewline
    while ($macElapsed -lt $macTimeout) {
        $adapter = Get-VMNetworkAdapter -VMName $VMName -ErrorAction SilentlyContinue
        if ($adapter -and $adapter.MacAddress -and $adapter.MacAddress -ne '000000000000') {
            $rawMac = $adapter.MacAddress
            break
        }
        Start-Sleep -Seconds 2
        $macElapsed += 2
        Write-Host "." -NoNewline
    }

    if (-not $rawMac -or $rawMac -eq '000000000000') {
        throw "VM network adapter did not initialize with a valid MAC address"
    }

    $mac = ($rawMac -replace '(.{2})', '$1-').TrimEnd('-')
    Write-Host ") " -NoNewline

    $elapsed = 0
    while ($elapsed -lt $TimeoutSeconds) {
        # Look for IPs in the Hyper-V Default Switch range (172.x.x.x) ONLY
        $neighbour = Get-NetNeighbor -LinkLayerAddress $mac -ErrorAction SilentlyContinue |
                     Where-Object {
                         $_.AddressFamily -eq 'IPv4' -and
                         $_.IPAddress -like '172.*' -and
                         $_.IPAddress -notlike '169.254.*' -and
                         $_.IPAddress -notmatch '\.\d+\.1$'  # Exclude gateway IPs (*.*.*.1)
                     } |
                     Select-Object -First 1

        if ($neighbour) { return $neighbour.IPAddress }

        Start-Sleep -Seconds 5
        $elapsed += 5
        Write-Host "." -NoNewline
    }
    throw "Timed out waiting for $VMName (MAC $mac) to obtain an IPv4 address in the 172.x range (Default Switch)."
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

function Get-NextNodeNumber {
    param([string]$Prefix)

    $existingVms = Get-VM -Name "${Prefix}-*" -ErrorAction SilentlyContinue
    if (-not $existingVms) { return 1 }

    $numbers = @()
    foreach ($vm in $existingVms) {
        if ($vm.Name -match "${Prefix}-(\d+)`$") {
            $numbers += [int]$matches[1]
        }
    }

    if ($numbers.Count -gt 0) {
        $max = ($numbers | Measure-Object -Maximum).Maximum
        return [int]$max + 1
    }
    return 1
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

if (-not (Test-Path $IsoPath)) {
    throw "Talos ISO not found at $IsoPath. Run create-cluster.ps1 first to download it."
}
Write-Ok "ISO found at $IsoPath"

$talosconfig = Join-Path $OutDir 'talosconfig'
$kubeconfigPath = Join-Path $OutDir 'kubeconfig'

if (-not (Test-Path $talosconfig) -or -not (Test-Path $kubeconfigPath)) {
    throw "Cluster config files not found in $OutDir. Run create-cluster.ps1 first."
}
Write-Ok 'Cluster config files found'

# ── Determine node name ──────────────────────────────────────────────────────

Write-Step "Finding next available $NodeType node number"

$prefix = if ($NodeType -eq 'controlplane') { "$ClusterName-cp" } else { "$ClusterName-worker" }
$nodeNumber = Get-NextNodeNumber -Prefix $prefix
$nodeName = "{0}-{1:D2}" -f $prefix, $nodeNumber

Write-Ok "Will create: $nodeName"

# ── Get control plane endpoint ───────────────────────────────────────────────

Write-Step 'Detecting control plane endpoint'

# Read the first control plane IP from talosconfig
$talosConfigContent = Get-Content $talosconfig -Raw
if ($talosConfigContent -match 'endpoints:\s*-\s*([0-9.]+)') {
    $cpEndpoint = $matches[1]
    Write-Ok "Control plane endpoint: $cpEndpoint"
} else {
    throw 'Could not determine control plane endpoint from talosconfig.'
}

# ── Create and start VM ──────────────────────────────────────────────────────

Write-Step 'Creating Hyper-V virtual machine'

if (Get-VM -Name $nodeName -ErrorAction SilentlyContinue) {
    throw "VM '$nodeName' already exists."
}

New-TalosVM -Name $nodeName -SwitchName $VmSwitch -IsoPath $IsoPath `
            -Cpu $CpuCount -Memory $MemoryBytes -DiskSize $DiskSizeBytes

Start-VM -Name $nodeName

Write-Host "   Waiting for $nodeName IP " -NoNewline
$nodeIp = Wait-ForVmIp -VMName $nodeName -TimeoutSeconds $IpTimeout
Write-Ok "`n   $nodeName -> $nodeIp"

# ── Wait for Talos API to become available ──────────────────────────────────

Write-Step 'Waiting for Talos API to become available'

# In maintenance mode, the Version endpoint is not implemented, so we'll just
# wait a bit for the node to boot and be ready to accept config
Write-Warn "Waiting 30 seconds for Talos maintenance service to be ready..."
Start-Sleep -Seconds 30

# ── Apply machine config ─────────────────────────────────────────────────────

Write-Step 'Applying machine configuration'

$configFile = if ($NodeType -eq 'controlplane') { 'controlplane.yaml' } else { 'worker.yaml' }
$configPath = Join-Path $OutDir $configFile

talosctl apply-config --insecure --nodes $nodeIp --file $configPath
if ($LASTEXITCODE -ne 0) { throw "Failed to apply $configFile to $nodeIp" }
Write-Ok "Applied $configFile to $nodeIp"

# ── Eject ISO and reboot from disk ───────────────────────────────────────────

Write-Step 'Waiting for Talos to install to disk before ejecting ISO'

Start-Sleep -Seconds 30
Write-Ok 'Ejecting ISO media and restarting VM to boot from disk'

Get-VMDvdDrive -VMName $nodeName | Set-VMDvdDrive -Path $null
Stop-VM -Name $nodeName -TurnOff -Force
Start-VM -Name $nodeName
Write-Ok "$nodeName restarted (booting from disk)"

# ── Wait for node to come up ─────────────────────────────────────────────────

Write-Step "Waiting for $nodeName to boot from disk ($BootTimeout`s timeout)"

$elapsed = 0
while ($elapsed -lt $BootTimeout) {
    $result = talosctl --talosconfig $talosconfig --nodes $nodeIp version 2>&1
    if ($LASTEXITCODE -eq 0) { break }
    Start-Sleep -Seconds 10
    $elapsed += 10
    Write-Host "." -NoNewline
}
if ($elapsed -ge $BootTimeout) {
    throw "Timed out waiting for Talos API on $nodeName ($nodeIp)."
}
Write-Ok "`nTalos API is responding on $nodeIp"

# ── Verify node joined cluster ──────────────────────────────────────────────

Write-Step 'Verifying node joined the cluster'

Start-Sleep -Seconds 10   # Give node time to register with API server

$env:KUBECONFIG = $kubeconfigPath
kubectl wait --for=condition=Ready "node/$nodeName" --timeout=300s 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Warn "Node may not be ready yet. Check with: kubectl get nodes"
} else {
    Write-Ok "$nodeName is Ready"
}

# ── Summary ──────────────────────────────────────────────────────────────────

Write-Host "`n" -NoNewline
Write-Host '══════════════════════════════════════════════════════════' -ForegroundColor Green
Write-Host "  Node added successfully!" -ForegroundColor Green
Write-Host '══════════════════════════════════════════════════════════' -ForegroundColor Green
Write-Host "  Node name: $nodeName"
Write-Host "  Node type: $NodeType"
Write-Host "  IP       : $nodeIp"
Write-Host ''
Write-Host "  kubectl --kubeconfig '$kubeconfigPath' get nodes" -ForegroundColor Yellow
Write-Host ''
