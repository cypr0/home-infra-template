#!/usr/bin/env bash
# ==============================================================================
#  config-loader.sh
#
#  Helper library to load configuration from cluster.toml
#  Replaces .env sourcing across all scripts
#
#  Usage:
#    source "${REPO_ROOT}/scripts/lib/config-loader.sh"
#    load_config
#    # Now all variables from cluster.toml are available
# ==============================================================================

# Load cluster.toml and export all values as environment variables
load_config() {
  local config_file="${REPO_ROOT}/cluster.toml"
  
  if [[ ! -f "$config_file" ]]; then
    echo "❌ cluster.toml not found at ${config_file}" >&2
    echo "   Run: just init" >&2
    exit 1
  fi

  # Check if yq is available
  if ! command -v yq >/dev/null 2>&1; then
    echo "❌ yq is required to parse cluster.toml" >&2
    echo "   Install: brew install yq" >&2
    exit 1
  fi

  # Export Proxmox configuration
  eval "$(yq -p toml -o shell '.proxmox' "$config_file" | sed 's/^/PROXMOX_/; s/PROXMOX_PROXMOX_/PROXMOX_/')"
  
  # Export OPNsense configuration
  eval "$(yq -p toml -o shell '.opnsense' "$config_file" | sed 's/^/OPNSENSE_/')"
  
  # Export Network configuration
  eval "$(yq -p toml -o shell '.network' "$config_file" | sed 's/^/NETWORK_/')"
  
  # Compute network values
  export LAN_NETWORK="${NETWORK_lan_cidr%/*}"  # 192.168.10.0/24 → 192.168.10.0
  export LAN_SUBNET_PREFIX="${NETWORK_lan_cidr#*/}"  # 192.168.10.0/24 → 24
  export VPN_NETWORK="${NETWORK_vpn_cidr%/*}"  # 192.168.20.0/24 → 192.168.20.0
  export VPN_SUBNET_PREFIX="${NETWORK_vpn_cidr#*/}"  # 192.168.20.0/24 → 24
  
  # Export Kubernetes configuration
  eval "$(yq -p toml -o shell '.kubernetes' "$config_file" | sed 's/^/K8S_/')"
  eval "$(yq -p toml -o shell '.kubernetes.api' "$config_file" | sed 's/^/K8S_API_/')"
  
  # Export Gateway configuration
  eval "$(yq -p toml -o shell '.gateways' "$config_file" | sed 's/^/GATEWAY_/')"
  
  # Export Repository configuration
  eval "$(yq -p toml -o shell '.repository' "$config_file" | sed 's/^/REPO_/')"
  
  # Export Cloudflare configuration (optional)
  if yq -p toml '.cloudflare' "$config_file" >/dev/null 2>&1; then
    eval "$(yq -p toml -o shell '.cloudflare' "$config_file" | sed 's/^/CLOUDFLARE_/')"
  fi
  
  # Export Cilium configuration (optional)
  if yq -p toml '.cilium' "$config_file" >/dev/null 2>&1; then
    eval "$(yq -p toml -o shell '.cilium' "$config_file" | sed 's/^/CILIUM_/')"
  fi
  
  # Export first management node as MGMT_* variables
  if yq -p toml '.mgmt_nodes[0]' "$config_file" >/dev/null 2>&1; then
    eval "$(yq -p toml -o shell '.mgmt_nodes[0]' "$config_file" | sed 's/^/MGMT_NODE_/')"
  fi
  
  # Compute derived values (backward compatibility)
  export MGMT_NETWORK="$LAN_NETWORK"
  export MGMT_SUBNET_PREFIX="$LAN_SUBNET_PREFIX"
  export HOME_NETWORK="$LAN_NETWORK"
  export HOME_SUBNET_PREFIX="$LAN_SUBNET_PREFIX"
  export MGMT_VIP="${K8S_API_addr}"
  export HOME_VIP="${K8S_API_addr}"
  
  # DNS/NTP from network config
  export MGMT_DNS="${NETWORK_dns_servers}"
  export MGMT_NTP="${NETWORK_ntp_servers}"
  
  # Gateways
  export MGMT_GATEWAY="${NETWORK_default_gateway:-${LAN_NETWORK%.*}.1}"
  export HOME_GATEWAY="$MGMT_GATEWAY"
  
  # Proxmox settings
  export PROXMOX_HOST="${PROXMOX_api_url#https://}"
  export PROXMOX_HOST="${PROXMOX_HOST%%:*}"
  export PROXMOX_PUBLIC_IP="$PROXMOX_HOST"
  export PROXMOX_STORAGE="${PROXMOX_storage}"
  export PROXMOX_NODE="${PROXMOX_node}"
  export MGMT_BRIDGE="${PROXMOX_bridge}"
  export HOME_BRIDGE="${PROXMOX_bridge}"
  
  # OPNsense
  export OPNSENSE_HOST="${OPNSENSE_api_url#https://}"
  export FW_KEY="${OPNSENSE_api_key}"
  export FW_SECRET="${OPNSENSE_api_secret}"
  
  # VM settings from mgmt node
  export MGMT_VM_NAME="${MGMT_NODE_name}"
  export MGMT_NODE_IP="${MGMT_NODE_address}"
  export MGMT_VM_MEMORY_MIB="${MGMT_NODE_memory}"
  export MGMT_VM_CORES="${MGMT_NODE_cores}"
  export MGMT_VMID="${MGMT_NODE_vmid:-100}"  # Default VMID if not specified
}

# Helper to get all control plane nodes as array
get_controlplane_nodes() {
  yq -p toml -o json '.controlplane_nodes[]' "${REPO_ROOT}/cluster.toml"
}

# Helper to get all worker nodes as array
get_worker_nodes() {
  yq -p toml -o json '.worker_nodes[]' "${REPO_ROOT}/cluster.toml"
}

# Helper to get node count
get_node_count() {
  local type="$1"  # mgmt_nodes, controlplane_nodes, worker_nodes
  yq -p toml ".${type} | length" "${REPO_ROOT}/cluster.toml"
}
