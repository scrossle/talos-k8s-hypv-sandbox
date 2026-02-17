#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Tears down the Talos Linux Hyper-V cluster created by create-cluster.ps1.
.DESCRIPTION
    Stops and removes the control-plane and worker VMs, deletes their VHDX
    files, and cleans up the generated config directory (_out/).
.PARAMETER Force
    Skip the confirmation prompt before destroying the cluster.
.EXAMPLE
    .\destroy-cluster.ps1
    .\destroy-cluster.ps1 -Force
#>
[CmdletBinding()]
param(
    [switch]$Force
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ── Configuration (must match create-cluster.ps1) ────────────────────────────
$ClusterName = 'talos-hypv'
$OutDir      = Join-Path $PSScriptRoot '_out'

# Find all VMs belonging to this cluster (including scaled nodes)
$VmNames = Get-VM -Name "$ClusterName-*" -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name
if (-not $VmNames) {
    Write-Host "No VMs found matching pattern '$ClusterName-*'" -ForegroundColor Yellow
    exit 0
}

# ── Helper functions ─────────────────────────────────────────────────────────

function Write-Step { param([string]$Message) Write-Host "`n>> $Message" -ForegroundColor Cyan }
function Write-Ok   { param([string]$Message) Write-Host "   $Message" -ForegroundColor Green }
function Write-Warn { param([string]$Message) Write-Host "   $Message" -ForegroundColor Yellow }

# ── Confirmation prompt ──────────────────────────────────────────────────────

if (-not $Force) {
    Write-Host "`n" -NoNewline
    Write-Host "═══════════════════════════════════════════════" -ForegroundColor Red
    Write-Host " WARNING: About to destroy the entire cluster" -ForegroundColor Red
    Write-Host "═══════════════════════════════════════════════" -ForegroundColor Red
    Write-Host "  VMs to be destroyed: $($VmNames -join ', ')"
    Write-Host "  This will also delete all VHDX files and the _out/ directory."
    Write-Host ""
    $confirm = Read-Host "Type 'yes' to proceed with cluster destruction"
    if ($confirm -ne 'yes') {
        Write-Host "Aborted." -ForegroundColor Yellow
        exit 0
    }
}

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
