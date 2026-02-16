##Requires -RunAsAdministrator
<#
.SYNOPSIS
    Tears down the Talos Linux Hyper-V cluster created by create-cluster.ps1.
.DESCRIPTION
    Stops and removes the control-plane and worker VMs, deletes their VHDX
    files, and cleans up the generated config directory (_out/).
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ── Configuration (must match create-cluster.ps1) ────────────────────────────
$ClusterName = 'talos-hypv'
$VmNames     = @("$ClusterName-cp-01", "$ClusterName-worker-01")
$OutDir      = Join-Path $PSScriptRoot '_out'

# ── Helper functions ─────────────────────────────────────────────────────────

function Write-Step { param([string]$Message) Write-Host "`n>> $Message" -ForegroundColor Cyan }
function Write-Ok   { param([string]$Message) Write-Host "   $Message" -ForegroundColor Green }
function Write-Warn { param([string]$Message) Write-Host "   $Message" -ForegroundColor Yellow }

# ── Stop and remove VMs ──────────────────────────────────────────────────────

Write-Step 'Stopping and removing VMs'

$defaultVhdPath = (Get-VMHost).VirtualHardDiskPath

foreach ($name in $VmNames) {
    $vm = Get-VM -Name $name -ErrorAction SilentlyContinue
    if (-not $vm) {
        Write-Warn "VM '$name' not found, skipping."
        continue
    }

    # Collect VHD paths before removing the VM
    $vhdPaths = @()
    Get-VMHardDiskDrive -VMName $name | ForEach-Object {
        if ($_.Path) { $vhdPaths += $_.Path }
    }
    # Also include the expected path from create-cluster.ps1 as a fallback
    $expectedVhd = Join-Path $defaultVhdPath "$name.vhdx"
    if ($expectedVhd -notin $vhdPaths) { $vhdPaths += $expectedVhd }

    if ($vm.State -ne 'Off') {
        Write-Ok "Stopping $name ..."
        Stop-VM -Name $name -TurnOff -Force
    }

    Write-Ok "Removing $name ..."
    Remove-VM -Name $name -Force

    # Brief pause to let Hyper-V release file handles
    Start-Sleep -Seconds 2

    # Delete associated VHDX files
    foreach ($vhd in $vhdPaths) {
        if (Test-Path $vhd) {
            Remove-Item -Path $vhd -Force
            Write-Ok "Deleted $vhd"
        }
    }
}

# ── Clean up generated configs ───────────────────────────────────────────────

Write-Step 'Cleaning up generated files'

if (Test-Path $OutDir) {
    Remove-Item -Recurse -Force $OutDir
    Write-Ok "Removed $OutDir"
} else {
    Write-Warn "$OutDir not found, nothing to clean."
}

# ── Summary ──────────────────────────────────────────────────────────────────

Write-Host ''
Write-Host '══════════════════════════════════════════════════════════' -ForegroundColor Green
Write-Host '  Cluster destroyed successfully.' -ForegroundColor Green
Write-Host '══════════════════════════════════════════════════════════' -ForegroundColor Green
Write-Host ''
