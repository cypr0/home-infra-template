#!/usr/bin/env bash
# ==============================================================================
#  configure-opnsense-firewall.sh
#
#  Configures the OPNsense firewall via REST API for the CAPMOX/Talos setup.
#  Idempotent: aliases and rules are only created if they do not already exist.
#
#  Interfaces are resolved via the OPNsense API by subnet from cluster.toml
#  (node_cidr) — no hardcoded interface names.
#
#  Usage: 
#    ./scripts/configure-opnsense-firewall.sh [--dry-run] [--mode=permissive|production]
#
#  Modes:
#    --mode=permissive   : Allow all LAN/HOME traffic (recommended for initial setup)
#    --mode=production   : Explicit rules only (default, for hardened setup)
# ==============================================================================
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "${REPO_ROOT}/scripts/lib/config-loader.sh"
load_config

: "${OPNSENSE_HOST:?OPNSENSE_HOST must be set in cluster.toml}"
: "${FW_KEY:?FW_KEY must be set in cluster.toml}"
: "${FW_SECRET:?FW_SECRET must be set in cluster.toml}"

DRY_RUN=false
MODE="production"

for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=true; echo ">>> DRY-RUN — no changes will be made." ;;
    --mode=permissive) MODE="permissive"; echo ">>> MODE: permissive (allow all LAN/HOME traffic)" ;;
    --mode=production) MODE="production"; echo ">>> MODE: production (explicit rules only)" ;;
    *) echo "Unknown flag: $arg" >&2; exit 1 ;;
  esac
done

FW_BASE="https://${OPNSENSE_HOST}/api"

# ─── Helpers ──────────────────────────────────────────────────────────────────
fw_get() {
  curl -sk --max-time 10 -u "${FW_KEY}:${FW_SECRET}" "${FW_BASE}/$1"
}

fw_post() {
  curl -sk --max-time 10 -u "${FW_KEY}:${FW_SECRET}" \
    -X POST -H "Content-Type: application/json" \
    "${FW_BASE}/$1" -d "$2"
}

# Finds the OPNsense interface name (e.g. "lan", "opt2") for a subnet like 192.168.11.0
resolve_iface() {
  local network="$1"
  fw_get "interfaces/overview/interfacesInfo" \
  | python3 -c "
import sys, json, ipaddress
data = json.load(sys.stdin).get('rows', [])
target = '${network}'
for row in data:
    addrs = row.get('addr4', '') or ''
    if not addrs:
        continue
    try:
        for entry in addrs.split(','):
            entry = entry.strip()
            if not entry:
                continue
            net = ipaddress.ip_network(entry, strict=False)
            if str(net.network_address) == target:
                # device='igb1' identifier='opt2' — we want the identifier field
                print(row.get('identifier', row.get('device', '')))
                sys.exit(0)
    except (ValueError, KeyError):
        continue
" 2>/dev/null
}

alias_uuid() {
  fw_get "firewall/alias/searchItem" \
  | python3 -c "
import sys, json
rows = json.load(sys.stdin).get('rows', [])
r = next((r for r in rows if r.get('name') == '$1'), None)
print(r.get('uuid', '') if r else '')
" 2>/dev/null
}

ensure_alias() {
  local name="$1" type="$2" content="$3" desc="$4"
  local uuid
  uuid=$(alias_uuid "$name")
  if [[ -n "$uuid" ]]; then
    # Alias exists — check if content matches and update if needed
    local current
    current=$(fw_get "firewall/alias/getAliasUUID/${uuid}" \
      | python3 -c "
import sys, json
d = json.load(sys.stdin).get('alias', {})
print(d.get('content', {}) if isinstance(d.get('content'), str) else list(d.get('content', {}).keys())[0] if d.get('content') else '')
" 2>/dev/null || true)
    if [[ "$current" == "$content" ]]; then
      echo "    ✓ Alias '$name' exists."
    else
      if $DRY_RUN; then
        echo "    [DRY-RUN] setAliasUUID $uuid name=$name content=$content (was: $current)"
        return
      fi
      fw_post "firewall/alias/setAliasUUID/${uuid}" \
        "{\"alias\":{\"name\":\"${name}\",\"type\":\"${type}\",\"content\":\"${content}\",\"description\":\"${desc}\",\"enabled\":\"1\"}}" \
        >/dev/null
      echo "    ✓ Alias '$name' updated ($current → $content)."
    fi
    return
  fi
  if $DRY_RUN; then
    echo "    [DRY-RUN] addItem alias name=$name type=$type content=$content"
    return
  fi
  fw_post "firewall/alias/addItem" \
    "{\"alias\":{\"name\":\"${name}\",\"type\":\"${type}\",\"content\":\"${content}\",\"description\":\"${desc}\",\"enabled\":\"1\"}}" \
    >/dev/null
  echo "    ✓ Alias '$name' created."
}

ensure_rule() {
  local desc="$1" iface="$2" src="$3" dst="$4" proto="$5" dstport="$6"
  local exists
  exists=$(fw_get "firewall/filter/searchRule" \
    | python3 -c "
import sys, json
rows = json.load(sys.stdin).get('rows', [])
print('yes' if any(r.get('description') == '${desc}' for r in rows) else 'no')
" 2>/dev/null)

  if [[ "$exists" == "yes" ]]; then
    echo "    ✓ Rule '$desc' exists."
    return
  fi
  if $DRY_RUN; then
    echo "    [DRY-RUN] addRule [$iface] $src→$dst $proto/$dstport # $desc"
    return
  fi
  local payload
  payload=$(python3 -c "
import json
r = {'rule': {
    'enabled': '1', 'action': 'pass', 'interface': '${iface}',
    'direction': 'in', 'ipprotocol': 'inet', 'protocol': '${proto}',
    'source_net': '${src}', 'destination_net': '${dst}',
    'description': '${desc}',
}}
if '${dstport}': r['rule']['destination_port'] = '${dstport}'
print(json.dumps(r))")
  local result
  result=$(fw_post "firewall/filter/addRule" "$payload")
  local status
  status=$(echo "$result" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('result','?'))" 2>/dev/null || echo "?")
  echo "    ✓ Rule '$desc' created: $status"
}

apply_all() {
  if $DRY_RUN; then
    echo "    [DRY-RUN] alias/reconfigure + filter/apply + nat/apply"
    return
  fi
  fw_post "firewall/alias/reconfigure" '{}' >/dev/null
  fw_post "firewall/filter/apply" '{}' >/dev/null
  fw_post "firewall/d_nat/apply" '{}' >/dev/null
  echo "    ✓ Configuration applied."
}

ensure_nat() {
  local desc="$1" iface="$2" dst="$3" dstport="$4" target="$5" targetport="$6"
  local exists
  exists=$(fw_get "firewall/d_nat/searchRule" \
    | python3 -c "
import sys, json
rows = json.load(sys.stdin).get('rows', [])
print('yes' if any(r.get('descr') == '${desc}' for r in rows) else 'no')
" 2>/dev/null)

  if [[ "$exists" == "yes" ]]; then
    echo "    ✓ NAT rule '$desc' exists."
    return
  fi
  if $DRY_RUN; then
    echo "    [DRY-RUN] addRule DNAT [$iface] *:$dstport → $target:$targetport # $desc"
    return
  fi
  local payload
  payload=$(python3 -c "
import json
r = {'rule': {
    'disabled': '0',
    'interface': '${iface}',
    'protocol': 'tcp',
    'destination': {'network': '${dst}', 'port': '${dstport}'},
    'target': '${target}',
    'local-port': '${targetport}',
    'descr': '${desc}',
}}
print(json.dumps(r))")
  local result
  result=$(fw_post "firewall/d_nat/addRule" "$payload")
  local status
  status=$(echo "$result" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('result','?'))" 2>/dev/null || echo "?")
  echo "    ✓ NAT rule '$desc' created: $status"
}

# ─── 1. Resolve interfaces ────────────────────────────────────────────────────
echo "=== [1/4] Interface discovery ==="
echo "  Simplified 3-interface setup: WAN, LAN, VPN"
echo ""

LAN_IF=$(resolve_iface "${LAN_NETWORK}")

# VPN interface: resolve from VPN_NETWORK,
# fallback: first wg* device in the interface list.
VPN_IF=""
if [[ -n "${VPN_NETWORK:-}" ]]; then
  VPN_IF=$(resolve_iface "${VPN_NETWORK}")
fi
if [[ -z "$VPN_IF" ]]; then
  VPN_IF=$(fw_get "interfaces/overview/interfacesInfo" \
    | python3 -c "
import sys, json
data = json.load(sys.stdin).get('rows', [])
for row in data:
    if row.get('device','').startswith('wg'):
        print(row.get('identifier', row.get('device','')))
        break
" 2>/dev/null)
fi

[[ -n "$LAN_IF" ]] || {
  echo "❌ Could not resolve LAN interface:" >&2
  echo "  LAN  ($LAN_NETWORK) → ${LAN_IF:-MISSING}" >&2
  echo "  Check: curl -sku '${FW_KEY}:***' ${FW_BASE}/interfaces/overview/interfacesInfo" >&2
  exit 1
}
echo "  LAN  ($LAN_NETWORK) → $LAN_IF"
if [[ -n "$VPN_IF" ]]; then
  echo "  VPN  ($VPN_NETWORK) → $VPN_IF"
else
  echo "  VPN  → not configured, VPN rules will be skipped"
fi

# ─── 2. Aliases ──────────────────────────────────────────────────────────────
echo ""
echo "=== [2/5] Creating aliases ==="
ensure_alias "proxmox_api_port"  "port" "8006"          "Proxmox Web UI + API"
ensure_alias "talos_api_port"    "port" "50000"         "Talos Machine API"
ensure_alias "k8s_api_port"      "port" "6443"          "Kubernetes API server"
ensure_alias "etcd_ports"        "port" "2379\n2380"    "etcd client + peer"
ensure_alias "http_https_ports"  "port" "80\n443"       "HTTP + HTTPS for internet access"
ensure_alias "lan_network"       "network" "${LAN_NETWORK}/${LAN_SUBNET_PREFIX}"  "LAN network (all K8s nodes)"
ensure_alias "k8s_vip"           "host" "${K8S_API_addr}"  "Kubernetes API VIP (mgmt + home)"

# ─── 3. Firewall rules ───────────────────────────────────────────────────────
echo ""
echo "=== [3/5] Creating firewall rules ==="

if [[ "$MODE" == "permissive" ]]; then
  echo ""
  echo ">>> PERMISSIVE MODE: Creating minimal allow-all rules for setup"
  echo ""
  
  # Allow all traffic on LAN interface (mgmt + home cluster)
  ensure_rule "SETUP: Allow all LAN traffic" \
    "$LAN_IF" "${LAN_IF}" "any" "any" ""
  
  # Allow VPN to access LAN
  if [[ -n "$VPN_IF" ]]; then
    ensure_rule "SETUP: Allow VPN to LAN" \
      "$VPN_IF" "${VPN_IF}" "lan_network" "any" ""
  fi
  
  echo ""
  echo "  ⚠️  PERMISSIVE MODE ACTIVE - Remember to switch to production mode after setup:"
  echo "     ./scripts/configure-opnsense-firewall.sh --mode=production"
  echo ""
  
else
  # PROD    Single LAN network (192.168.10.0/24) for all K8s nodes"
  echo ""
  
  # === LAN Rules (all K8s nodes) ===
  
  # DNS + NTP
  ensure_rule "DNS - Talos nodes via OPNsense" \
    "$LAN_IF" "${LAN_IF}" "(self)" "TCP/UDP" "53"
  ensure_rule "NTP - Talos nodes via OPNsense" \
    "$LAN_IF" "${LAN_IF}" "(self)" "UDP" "123"
  # NTP outbound to internet (required during Talos bootstrap)
  ensure_rule "NTP outbound - LAN" \
    "$LAN_IF" "${LAN_IF}" "any" "UDP" "123"

  # Internet egress for image pull
  ensure_rule "Internet HTTP/HTTPS - LAN" \
    "$LAN_IF" "${LAN_IF}" "any" "TCP" "http_https_ports"

  # Kubernetes API (intra-cluster)
  ensure_rule "K8s API - LAN internal" \
    "$LAN_IF" "${LAN_IF}" "k8s_vip" "TCP" "k8s_api_port"

  # Talos API (CAPMOX + inter-node)
  ensure_rule "Talos API - LAN internal" \
    "$LAN_IF" "${LAN_IF}" "lan_network" "TCP" "talos_api_port"

  # etcd peer (CP nodes among themselves)
  ensure_rule "etcd peer - LAN" \
    "$LAN_IF" "${LAN_IF}" "${LAN_IF}" "TCP" "etcd_ports"

  # KubeSpan WireGuard (optional)
  ensure_rule "KubeSpan - LAN" \
    "$LAN_IF" "${LAN_IF}" "${LAN_IF}" "UDP" "51820"
  
  # === VPN Rules (if configured) ===
  if [[ -n "$VPN_IF" ]]; then
    echo ""
    echo "--- VPN rules (${VPN_IF}) ---"
    
    # VPN → Kubernetes API
    ensure_rule "K8s API - VPN to LAN" \
      "$VPN_IF" "${VPN_IF}" "k8s_vip" "TCP" "k8s_api_port"
    
    # VPN → Talos API (for remote management)
    ensure_rule "Talos API - VPN to LAN" \
      "$VPN_IF" "${VPN_IF}" "lan_network" "TCP" "talos_api_port"
  fi
  # KubeSpan WireGuard
  ensure_rule "KubeSpan - HOME" \
    "$HOME_IF" "${HOME_IF}" "${HOME_IF}" "UDP" "51820"
fi

# ─── VPN rules (WireGuard → all cluster networks) ───────────────────────────
if [[ -n "$VPN_IF" ]]; then
fi

# ─── 4. NAT / Port-Forwards ─────────────────────────────────────────────────
echo ""
echo "=== [4/5] NAT rules ==="
echo "  → No NAT rules needed (KubeVIP handles API VIP)"

# ─── 5. Apply ────────────────────────────────────────────────────────────────
echo ""
echo "=== [5/5] Applying configuration ==="
apply_all

echo ""
echo "=== Done ==="
