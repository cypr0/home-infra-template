#!/usr/bin/env bash
# ==============================================================================
#  configure-proxmox-mgmt-ip.sh
#
#  Goal: The Proxmox host has 192.168.10.254/24 on the mgmt bridge (vnetlan).
#        This allows CAPMOX (on the mgmt cluster) to reach the Proxmox API
#        internally instead of going via the public IP.
#
#  Behavior:
#    • SDN VNets (vnetlan) are NOT managed via the Proxmox API — they live in
#      /etc/network/interfaces.d/sdn (auto-generated) or must be added to
#      /etc/network/interfaces manually. The script therefore only verifies
#      and provides instructions when the IP is missing.
#    • Classic vmbr bridges (e.g. vmbr1) are set via the Proxmox API.
#
#  Usage: ./scripts/configure-proxmox-mgmt-ip.sh [--dry-run]
# ==============================================================================
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
[[ -f "$REPO_ROOT/.env" ]] || { echo "❌ .env missing." >&2; exit 1; }
set -a; source "$REPO_ROOT/.env"; set +a

DRY_RUN=false
[[ "${1:-}" == "--dry-run" ]] && DRY_RUN=true

BRIDGE="${MGMT_BRIDGE:-vnetlan}"
MGMT_IP="192.168.10.0"
MGMT_PREFIX="24"
CIDR="${MGMT_IP}/${MGMT_PREFIX}"

PROXMOX_HOST_IP="${PROXMOX_PUBLIC_IP:-95.216.8.94}"

echo "=== Proxmox management IP configuration ==="
echo "  Host   : ${PROXMOX_HOST_IP}"
echo "  Bridge : ${BRIDGE}"
echo "  Target : ${CIDR}"
echo ""

# ─── SSH helper ───────────────────────────────────────────────────────────────
pve_ssh() {
  if [[ -n "${PVE_SSH_PASS:-}" ]] && command -v sshpass >/dev/null 2>&1; then
    sshpass -p "${PVE_SSH_PASS}" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 \
      "root@${PROXMOX_HOST_IP}" "$@"
  else
    ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 \
      "root@${PROXMOX_HOST_IP}" "$@"
  fi
}

# ─── 1. Determine current IP on the bridge (via SSH, OS view) ─────────────────
echo ">>> [1/3] Reading current IP on ${BRIDGE} via SSH..."
current=$(pve_ssh "ip -br -4 addr show ${BRIDGE} 2>/dev/null | awk '{print \$3}'" 2>/dev/null || echo "")

if [[ "$current" == "$CIDR" ]]; then
  echo "    ✓ ${CIDR} is already set on ${BRIDGE}."
  echo ""
  echo "=== Done ==="
  exit 0
fi

# ─── 2. IP missing — decide: API (vmbr*) or manual (vnet*) ───────────────────
echo "    ⚠️  IP on ${BRIDGE}: ${current:-none}"
echo ""

if [[ "$BRIDGE" =~ ^vmbr ]]; then
  # Classic Linux bridge → Proxmox API can set the IP
  echo ">>> [2/3] Classic bridge detected — setting IP via Proxmox API..."
  AUTH_HEADER="Authorization: PVEAPIToken=${PROXMOX_TOKEN}=${PROXMOX_SECRET}"
  BASE_URL="${PROXMOX_URL%/api2/json}/api2/json/nodes/${PROXMOX_NODE}"

  if $DRY_RUN; then
    echo "    [DRY-RUN] PUT ${BASE_URL}/network/${BRIDGE}"
    echo "    [DRY-RUN] address=${MGMT_IP} netmask=255.255.255.0"
  else
    curl -sk -H "$AUTH_HEADER" -X PUT \
      "${BASE_URL}/network/${BRIDGE}" \
      --data-urlencode "type=bridge" \
      --data-urlencode "address=${MGMT_IP}" \
      --data-urlencode "netmask=255.255.255.0" \
      --data-urlencode "autostart=1" \
      --data-urlencode "comments=Mgmt IP for CAPMOX (home-infra)"
    curl -sk -H "$AUTH_HEADER" -X PUT "${BASE_URL}/network" >/dev/null
    echo "    ✓ IP set + reload."
  fi
else
  # SDN VNet → manual configuration required (API cannot manage it)
  echo "❌ ${BRIDGE} is an SDN VNet — cannot be set via the Proxmox API." >&2
  echo "" >&2
  echo "   Please configure this once manually on the Proxmox host:" >&2
  echo "" >&2
  echo "     ssh root@${PROXMOX_HOST_IP}" >&2
  echo "     # Add the following to /etc/network/interfaces:" >&2
  echo "     #   iface vnetlan inet static" >&2
  echo "     #     address ${CIDR}" >&2
  echo "     # Then apply:" >&2
  echo "     ifreload -a" >&2
  echo "" >&2
  echo "   Then re-run \`task up\`." >&2
  exit 1
fi

echo ""
echo "=== Done ==="
