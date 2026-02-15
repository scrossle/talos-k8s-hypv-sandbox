# Talos K8s Hyper-V Sandbox

A minimal two-node Kubernetes cluster running [Talos Linux](https://www.talos.dev/) on Hyper-V, with a production-style platform stack: Cilium CNI, Traefik ingress, MetalLB load balancer, and Prometheus/Grafana monitoring.

Built for local development and learning on Windows (including ARM64/Windows-on-ARM).

## Architecture

```
┌─────────────────────────────────────────────────────────┐
│  Windows Host (Hyper-V)                                 │
│                                                         │
│  ┌─────────────────────┐  ┌─────────────────────────┐   │
│  │ talos-hypv-cp-01    │  │ talos-hypv-worker-01    │   │
│  │ Control Plane       │  │ Worker                  │   │
│  │ 2 vCPU / 4GB RAM    │  │ 2 vCPU / 4GB RAM        │   │
│  │ 20GB VHDX           │  │ 20GB VHDX               │   │
│  │ Talos v1.12.4       │  │ Talos v1.12.4           │   │
│  └─────────────────────┘  └─────────────────────────┘   │
│         Default Switch (NAT, DHCP)                      │
└─────────────────────────────────────────────────────────┘
```

### Platform Stack

| Component | Purpose | Version |
|-----------|---------|---------|
| **Cilium** | CNI + kube-proxy replacement (eBPF) | Latest via Helm |
| **Hubble** | Network observability (part of Cilium) | Bundled with Cilium |
| **MetalLB** | LoadBalancer IP allocation (L2 mode) | Latest via Helm |
| **Traefik** | Ingress controller | Latest via Helm |
| **Prometheus** | Metrics collection (7d retention) | kube-prometheus-stack |
| **Grafana** | Dashboards and visualization | kube-prometheus-stack |

## Prerequisites

- Windows 10/11 with **Hyper-V** enabled
- **talosctl** in PATH ([install guide](https://www.talos.dev/v1.12/introduction/getting-started/))
- **kubectl** in PATH
- **Helm** in PATH (`winget install Helm.Helm`)

## Quick Start

### 1. Create the cluster

```powershell
# Run as Administrator
.\create-cluster.ps1
```

This downloads the Talos ISO, creates two VMs, applies configs, bootstraps the cluster, and saves credentials to `_out/`.

### 2. Deploy the platform stack

Run each script in order from an elevated PowerShell prompt:

```powershell
# Replace Flannel with Cilium CNI + Hubble
.\deployments\cilium\deploy.ps1

# Install MetalLB for LoadBalancer support
.\deployments\metallb\deploy.ps1

# Install Traefik ingress controller
.\deployments\traefik\deploy.ps1

# Set up hostname-based routing for dashboards
.\deployments\ingress\deploy.ps1

# Install Prometheus + Grafana monitoring
.\deployments\monitoring\deploy.ps1
```

### 3. Access dashboards

After running the ingress deploy script (which updates your hosts file):

| URL | Service | Credentials |
|-----|---------|-------------|
| `http://grafana.talos.local` | Grafana | admin / admin |
| `http://prometheus.talos.local` | Prometheus | — |
| `http://hubble.talos.local` | Hubble UI | — |
| `http://traefik.talos.local/dashboard/` | Traefik | — |

> **Grafana login:** The default username and password are both `admin`. You'll be prompted to change the password on first login — you can skip this for a sandbox.

## Tear Down

```powershell
# Run as Administrator
.\destroy-cluster.ps1
```

This stops and deletes both VMs, removes their VHDX disks, and cleans up `_out/`.

You may also want to remove the `# talos-sandbox-ingress` entries from your hosts file (`C:\Windows\System32\drivers\etc\hosts`).

## Project Structure

```
├── create-cluster.ps1              # Provision VMs and bootstrap Talos
├── destroy-cluster.ps1             # Tear down VMs and clean up
├── _out/                           # Generated configs (gitignored)
│   ├── controlplane.yaml
│   ├── worker.yaml
│   ├── talosconfig
│   └── kubeconfig
├── iso/                            # Cached Talos ISO (gitignored)
└── deployments/
    ├── cilium/
    │   ├── talos-patch.yaml        # Disable Flannel + kube-proxy
    │   ├── cilium-values.yaml      # Helm values (Talos-specific)
    │   └── deploy.ps1
    ├── metallb/
    │   ├── metallb-pool.yaml       # L2 advertisement + IP pool template
    │   └── deploy.ps1              # Auto-detects subnet for IP pool
    ├── traefik/
    │   ├── traefik-values.yaml     # Helm values (LoadBalancer service)
    │   └── deploy.ps1
    ├── ingress/
    │   ├── ingressroutes.yaml      # Traefik routes for all dashboards
    │   └── deploy.ps1              # Applies routes + updates hosts file
    └── monitoring/
        ├── kube-prometheus-values.yaml  # Helm values (laptop-sized)
        └── deploy.ps1
```

## Notes

### Hyper-V Default Switch

The Default Switch uses NAT with DHCP, and the subnet changes on host reboot. After a reboot:

1. Node IPs will change (DHCP reassignment)
2. MetalLB pool range will be invalid
3. Hosts file entries will point to old IPs

To recover, re-run `deployments/metallb/deploy.ps1` and `deployments/ingress/deploy.ps1`.

### Cilium on Talos

Cilium requires Talos-specific Helm values because Talos is immutable:

- `ipam.mode=kubernetes` — use Kubernetes IPAM (Talos best practice)
- `cgroup.autoMount.enabled=false` — Talos pre-mounts cgroupv2
- `kubeProxyReplacement=true` — Cilium replaces kube-proxy via eBPF
- `k8sServiceHost=localhost:7445` — KubePrism local API proxy
- SYS_MODULE capability dropped — Talos doesn't allow kernel module loading from pods

### Monitoring on Talos

Several kube-prometheus-stack monitors are disabled because Talos doesn't expose those components:

- `kubeProxy` — replaced by Cilium
- `kubeScheduler`, `kubeControllerManager`, `kubeEtcd` — not accessible on Talos

The `monitoring` namespace requires the `pod-security.kubernetes.io/enforce=privileged` label for node-exporter to function.
