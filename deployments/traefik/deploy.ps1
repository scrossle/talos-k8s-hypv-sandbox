<#
.SYNOPSIS
    Deploys Traefik ingress controller on the Talos cluster.
.DESCRIPTION
    Installs Traefik via Helm as a NodePort service (HTTP 30080, HTTPS 30443).
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepoRoot    = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$Kubeconfig  = Join-Path $RepoRoot '_out' 'kubeconfig'
$ValuesFile  = Join-Path $PSScriptRoot 'traefik-values.yaml'

function Write-Step { param([string]$Message) Write-Host "`n>> $Message" -ForegroundColor Cyan }
function Write-Ok   { param([string]$Message) Write-Host "   $Message" -ForegroundColor Green }

# ── Preflight ─────────────────────────────────────────────────────────────────

Write-Step 'Checking prerequisites'

if (-not (Test-Path $Kubeconfig)) { throw "kubeconfig not found at $Kubeconfig" }
if (-not (Get-Command helm -ErrorAction SilentlyContinue)) { throw 'helm not found in PATH.' }

$env:KUBECONFIG = $Kubeconfig

# ── Install Traefik ───────────────────────────────────────────────────────────

Write-Step 'Adding Traefik Helm repo and installing Traefik'

helm repo add traefik https://traefik.github.io/charts 2>&1 | Out-Null
helm repo update traefik 2>&1 | Out-Null

kubectl create namespace traefik --dry-run=client -o yaml | kubectl apply -f - 2>&1 | Out-Null

helm upgrade --install traefik traefik/traefik `
    --namespace traefik `
    --values $ValuesFile `
    --wait `
    --timeout 5m

if ($LASTEXITCODE -ne 0) { throw 'Traefik Helm install failed.' }

# ── Verify ────────────────────────────────────────────────────────────────────

Write-Step 'Verifying Traefik pods'

kubectl -n traefik get pods
kubectl -n traefik get svc

# Get a node IP for the access URL
$nodeIp = kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}'

Write-Host "`n" -NoNewline
Write-Host '══════════════════════════════════════════════════════════' -ForegroundColor Green
Write-Host '  Traefik ingress deployed successfully!' -ForegroundColor Green
Write-Host '══════════════════════════════════════════════════════════' -ForegroundColor Green
Write-Host "  HTTP:      http://${nodeIp}:30080" -ForegroundColor Yellow
Write-Host "  HTTPS:     https://${nodeIp}:30443" -ForegroundColor Yellow
Write-Host "  Dashboard: kubectl -n traefik port-forward svc/traefik 9000:9000" -ForegroundColor Yellow
Write-Host ''
