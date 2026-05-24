#!/usr/bin/env bash
# ==============================================================================
#  preflight.sh
#
#  Checks prerequisites before `task up`:
#    1. Local tools are installed
#    2. .env exists + all variables are set (no <placeholders>)
#    3. Proxmox API is reachable
#    4. OPNsense API is reachable
#    5. Talos VM template (PROXMOX_TEMPLATE_ID) exists
# ==============================================================================
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
source "${REPO_ROOT}/scripts/lib/config-loader.sh"
load_config

errors=0
warn() { echo "  ⚠️  $*"; }
fail() { echo "  ❌ $*" >&2; errors=$((errors + 1)); }
ok()   { echo "  ✓ $*"; }

echo "=== [1/5] Local tools ==="
for tool in talosctl clusterctl kubectl helm yq jq curl python3 just; do
  if command -v "$tool" >/dev/null 2>&1; then
    ok "$tool"
  else
    case "$tool" in
      yq) fail "$tool missing — brew install yq (REQUIRED for cluster.toml parsing!)" ;;
      just) fail "$tool missing — brew install just (REQUIRED for task runner!)" ;;
      *) fail "$tool missing — brew install $tool" ;;
    esac
  fi
done

echo ""
echo "=== [2/5] cluster.toml completeness ==="
required=(
  PROXMOX_api_url PROXMOX_node PROXMOX_storage PROXMOX_bridge
  NETWORK_node_cidr NETWORK_dns_servers NETWORK_ntp_servers
  K8S_pod_cidr K8S_svc_cidr K8S_API_addr
  GATEWAY_external GATEWAY_internal
  REPO_name REPO_branch REPO_flux_path
  OPNSENSE_HOST FW_KEY FW_SECRET
  MGMT_NODE_name MGMT_NODE_address MGMT_NODE_cores MGMT_NODE_memory
)
for var in "${required[@]}"; do
  val="${!var:-}"
  if [[ -z "$val" ]]; then
    fail "$var is empty in cluster.toml"
  elif [[ "$val" =~ (example\.com|your-username|CHANGEME) ]]; then
    fail "$var still contains a placeholder: $val"
  else
    ok "$var set"
  fi
done

echo ""
echo "=== [3/5] Proxmox API ==="
# Extract token from PROXMOX_user if it contains ! (format: user@realm!tokenname)
if [[ "${PROXMOX_user}" == *"!"* ]]; then
  PROXMOX_TOKEN="${PROXMOX_user}"
else
  PROXMOX_TOKEN="${PROXMOX_user}!${PROXMOX_token_id:-token1}"
fi

if curl -sk --max-time 5 -H "Authorization: PVEAPIToken=${PROXMOX_TOKEN}=${PROXMOX_token}" \
    "${PROXMOX_api_url}/version" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d['data']['version'])" 2>/dev/null; then
  ok "Proxmox API reachable (${PROXMOX_api_url})"
else
  fail "Proxmox API NOT reachable — check cluster.toml: proxmox.api_url, user, token"
fi

echo ""
echo "=== [4/5] OPNsense API ==="
if curl -sk --max-time 5 -u "${FW_KEY}:${FW_SECRET}" \
    "${OPNSENSE_api_url}/api/core/firmware/status" >/dev/null 2>&1; then
  ok "OPNsense API reachable (${OPNSENSE_api_url})"
else
  fail "OPNsense API NOT reachable==="
# Check if schematic_id is set on first mgmt node
if [[ -n "${MGMT_NODE_schematic_id:-}" ]]; then
  ok "Talos schematic_id configured: ${MGMT_NODE_schematic_id:0:16}..."
  echo "     Factory URL: https://factory.talos.dev/image/${MGMT_NODE_schematic_id}/v1.8.0/nocloud-amd64.raw.xz"
else
  fail "mgmt_nodes[0].schematic_id not set in cluster.toml"
  echo "     Generate at: https://factory.talos.devnt(d.get('template',0))" 2>/dev/null || echo "")
if [[ "$template_check" == "1" ]]; then
  ok "Template ${PROXMOX_TEMPLATE_ID} exists."
elif [[ "$template_check" == "0" ]]; then
  warn "VM ${PROXMOX_TEMPLATE_ID} exists but is not a template (template=0)"
else
  fail "Template ${PROXMOX_TEMPLATE_ID} not found on node ${PROXMOX_NODE}"
fi

echo ""
if [[ $errors -gt 0 ]]; then
  echo "❌ Preflight FAILED ($errors error(s)) — please fix the above." >&2
  exit 1
fi
echo "✅ Preflight OK"
