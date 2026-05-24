# 🏠 home-infra

Fully automated Kubernetes home lab on Proxmox using **Talos Linux** and **Cluster API (CAPMOX)**.

## 🎯 What is this?

This repo provisions a **Kubernetes cluster** on Proxmox VE:
- **Management Cluster**: Runs CAPI/CAPMOX for infrastructure orchestration
- **Workload Cluster**: HA Kubernetes with 3 control planes + autoscaling workers
- **Talos OS**: Immutable, minimal, secure Linux for Kubernetes
- **CAPMOX**: Creates and manages VMs on Proxmox automatically

## 🏗️ Architecture

```
┌─────────────────────────┐
│  Management Cluster     │  Single node running CAPI/CAPMOX
└─────────┬───────────────┘
          │
          ├─── Workload Cluster (home-cluster)
          │    ├─ 3× Control Planes - Run workloads!
          │    └─ 0-4× Workers (auto-scaled) - Created on demand
          │
          └─── API VIP
```

## 🚀 Quick Start

### Prerequisites

```bash
# Install tools via mise (recommended)
curl https://mise.run | sh
mise install
mise run install-python-deps
mise run install-gum

# OR install manually
brew install talosctl clusterctl kubectl just age cue gum
pipx install makejinja
```

### Setup

```bash
# 1. Clone repo
git clone https://github.com/your-username/home-infra.git
cd home-infra

# 2. Install dependencies
mise install

# 3. Create configuration
cp cluster.sample.toml cluster.toml
$EDITOR cluster.toml  # Fill in your details

# 4. Initialize secrets (creates age key, deploy key, push token)
just template init

# 5. Deploy everything
just up
```

### What `just up` does

1. **Renders** templates from `cluster.toml` into `capmox/` and `bootstrap/`
2. **Provisions** management cluster VM on Proxmox
3. **Deploys** CAPI/CAPMOX to management cluster
4. **Creates** workload cluster (3 CPs + autoscaler)
5. **Bootstraps** Cilium CNI and KubeVIP

## 📋 Configuration

Edit `cluster.toml` with your values:

```toml
[proxmox]
api_url = "https://192.168.1.1:8006/api2/json"
node = "pve"
user = "root@pam"
token = "your-api-token"
storage = "local-lvm"
bridge = "vmbr0"

[network]
lan_cidr = "192.168.1.0/24"
dns_servers = ["1.1.1.1", "1.0.0.1"]

[kubernetes.api]
addr = "192.168.1.100"  # VIP for API server

[[controlplane_nodes]]
name = "cp-01"
address = "192.168.1.11"
mac_addr = "bc:24:11:00:01:01"
schematic_id = "your-talos-schematic-id"
cores = 4
memory = 16384  # 16GB
disk_size = 100

# ... repeat for cp-02, cp-03

[autoscaler]
enabled = true
min_workers = 0
max_workers = 4
```

## 🛠️ Common Tasks

```bash
# Check cluster status
just capmox status

# Scale workers manually
just capmox scale 2

# Get kubeconfig
just capmox kubeconfig
kubectl get nodes

# Destroy cluster
just capmox delete
```

## 🐛 Troubleshooting

```bash
# Check template rendering
just template doctor

# Validate schema
cue export cluster.toml template/resources/config.schema.cue

# Check CAPI resources
kubectl --context home-mgmt get cluster,machine -A

# Get node status
kubectl get nodes -o wide
```

## 🙏 Credits

Built with:
- [Talos Linux](https://www.talos.dev/)
- [Cluster API](https://cluster-api.sigs.k8s.io/)
- [CAPMOX](https://github.com/ionos-cloud/cluster-api-provider-proxmox)
- [Cilium](https://cilium.io/)
