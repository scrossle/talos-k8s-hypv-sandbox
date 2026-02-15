<#
.SYNOPSIS
    Deploys MetalLB load balancer and reconfigures Traefik to use it.
.DESCRIPTION
    1. Installs MetalLB via Helm.
    2. Auto-detects the node subnet and allocates a small IP pool at the top.
    3. Switches Traefik from NodePort to LoadBalancer (ports 80/443).
    4. Updates Windows hosts file entries to point to the new LoadBalancer IP.
#>
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$RepoRoot    = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$OutDir      = Join-Path $RepoRoot '_out'
$Kubeconfig  = Join-Path $OutDir 'kubeconfig'
$PoolTemplate = Join-Path $PSScriptRoot 'metallb-pool.yaml'

function Write-Step { param([string]$Message) Write-Host "`n>> $Message" -ForegroundColor Cyan }
function Write-Ok   { param([string]$Message) Write-Host "   $Message" -ForegroundColor Green }
function Write-Warn { param([string]$Message) Write-Host "   $Message" -ForegroundColor Yellow }

# ── Preflight ─────────────────────────────────────────────────────────────────

Write-Step 'Checking prerequisites'

if (-not (Test-Path $Kubeconfig)) { throw "kubeconfig not found at $Kubeconfig" }
if (-not (Get-Command helm -ErrorAction SilentlyContinue)) { throw 'helm not found in PATH.' }

$env:KUBECONFIG = $Kubeconfig

# ── Detect subnet and compute IP pool ─────────────────────────────────────────

Write-Step 'Detecting node subnet for MetalLB IP pool'

# Get the first node's IP and compute a pool at the top of the /20
$nodeIp = kubectl get nodes -o jsonpath='{.items[0].status.addresses[?(@.type=="InternalIP")].address}'
$octets = $nodeIp -split '\.'
# For a /20 subnet, the third octet's base is aligned to 16-block boundaries
$thirdBase = [int]$octets[2] -band 0xF0
$poolStart = "$($octets[0]).$($octets[1]).$($thirdBase + 15).240"
$poolEnd   = "$($octets[0]).$($octets[1]).$($thirdBase + 15).250"
$poolRange = "$poolStart-$poolEnd"

Write-Ok "Node IP: $nodeIp"
Write-Ok "MetalLB pool: $poolRange"

# ── Install MetalLB ───────────────────────────────────────────────────────────

Write-Step 'Installing MetalLB via Helm'

helm repo add metallb https://metallb.github.io/metallb 2>&1 | Out-Null
helm repo update metallb 2>&1 | Out-Null

kubectl create namespace metallb-system --dry-run=client -o yaml | kubectl apply -f - 2>&1 | Out-Null
kubectl label namespace metallb-system pod-security.kubernetes.io/enforce=privileged --overwrite 2>&1 | Out-Null

helm upgrade --install metallb metallb/metallb `
    --namespace metallb-system `
    --wait `
    --timeout 5m

if ($LASTEXITCODE -ne 0) { throw 'MetalLB Helm install failed.' }
Write-Ok 'MetalLB installed'

# ── Apply IP pool config ──────────────────────────────────────────────────────

Write-Step 'Configuring MetalLB IP address pool'

# Wait for MetalLB CRDs to be available
$elapsed = 0
while ($elapsed -lt 60) {
    $crd = kubectl get crd ipaddresspools.metallb.io 2>&1
    if ($LASTEXITCODE -eq 0) { break }
    Start-Sleep -Seconds 5
    $elapsed += 5
}

$poolYaml = (Get-Content $PoolTemplate -Raw) -replace 'PLACEHOLDER_RANGE', $poolRange
$poolYaml | kubectl apply -f - 2>&1
if ($LASTEXITCODE -ne 0) { throw 'Failed to apply MetalLB pool config.' }
Write-Ok "IP pool configured: $poolRange"

# ── Switch Traefik to LoadBalancer ────────────────────────────────────────────

Write-Step 'Switching Traefik service from NodePort to LoadBalancer'

$traefikValues = Join-Path $RepoRoot 'deployments' 'traefik' 'traefik-values.yaml'

helm upgrade traefik traefik/traefik `
    --namespace traefik `
    --values $traefikValues `
    --set service.type=LoadBalancer `
    --set 'ports.web.nodePort=null' `
    --set 'ports.websecure.nodePort=null' `
    --wait `
    --timeout 5m

if ($LASTEXITCODE -ne 0) { throw 'Traefik upgrade failed.' }

# Wait for LoadBalancer IP assignment
$elapsed = 0
$lbIp = $null
while ($elapsed -lt 60) {
    $lbIp = kubectl -n traefik get svc traefik -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>&1
    if ($lbIp) { break }
    Start-Sleep -Seconds 5
    $elapsed += 5
}
if (-not $lbIp) { throw 'Timed out waiting for LoadBalancer IP.' }
Write-Ok "Traefik LoadBalancer IP: $lbIp"

# ── Update hosts file ─────────────────────────────────────────────────────────

Write-Step 'Updating Windows hosts file'

$hostsFile = "$env:SystemRoot\System32\drivers\etc\hosts"
$marker = '# talos-sandbox-ingress'

# Remove old entries
$content = Get-Content $hostsFile | Where-Object { $_ -notmatch $marker }

# Add new entries pointing to LoadBalancer IP
$hostnames = @('grafana', 'prometheus', 'hubble', 'traefik')
foreach ($name in $hostnames) {
    $content += "$lbIp  $name.talos.local  $marker"
}

Set-Content -Path $hostsFile -Value $content
Write-Ok "Hosts file updated (pointing to $lbIp)"

# ── Summary ───────────────────────────────────────────────────────────────────

Write-Host "`n" -NoNewline
Write-Host '══════════════════════════════════════════════════════════' -ForegroundColor Green
Write-Host '  MetalLB deployed — Traefik on standard ports!' -ForegroundColor Green
Write-Host '══════════════════════════════════════════════════════════' -ForegroundColor Green
Write-Host "  LoadBalancer IP: $lbIp" -ForegroundColor Yellow
Write-Host "  Grafana:    http://grafana.talos.local" -ForegroundColor Yellow
Write-Host "  Prometheus: http://prometheus.talos.local" -ForegroundColor Yellow
Write-Host "  Hubble UI:  http://hubble.talos.local" -ForegroundColor Yellow
Write-Host "  Traefik:    http://traefik.talos.local/dashboard/" -ForegroundColor Yellow
Write-Host ''
