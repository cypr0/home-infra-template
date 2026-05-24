#!/usr/bin/env bash
# ==============================================================================
#  verify-opnsense-services.sh
#
#  Ensures the following services are running on OPNsense and reachable from
#  the internal networks:
#    • ntpd    (port 123) — central time source for Mgmt + home-cluster
#    • unbound (port 53)  — DNS for all Talos nodes
#
#  Both services bind to all interfaces by default in OPNsense; this script
#  verifies their status via API and prints clear errors if something is wrong.
#
#  Usage: ./scripts/verify-opnsense-services.sh
# ==============================================================================
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
[[ -f "$REPO_ROOT/.env" ]] || { echo "Error: .env not found." >&2; exit 1; }
set -a; source "$REPO_ROOT/.env"; set +a

: "${OPNSENSE_HOST:?OPNSENSE_HOST must be set in .env}"
: "${FW_KEY:?FW_KEY must be set in .env}"
: "${FW_SECRET:?FW_SECRET must be set in .env}"

API="https://${OPNSENSE_HOST}/api"

api_get() {
  curl -sk --max-time 10 -u "${FW_KEY}:${FW_SECRET}" "${API}/$1"
}

api_post() {
  curl -sk --max-time 10 -u "${FW_KEY}:${FW_SECRET}" \
    -X POST -H "Content-Type: application/json" \
    "${API}/$1" -d "${2:-{\}}"
}

# Check service status (expects running=1)
check_service() {
  local name="$1"
  api_get "core/service/search" \
    | python3 -c "
import sys, json
rows = json.load(sys.stdin).get('rows', [])
r = next((r for r in rows if r.get('name') == '$name' or r.get('id') == '$name'), None)
print(r.get('running', 0) if r else 'missing')
" 2>/dev/null
}

start_service() {
  local id="$1"
  api_post "core/service/start/${id}" '{}' >/dev/null
  echo "    → Service '${id}' started."
}

list_services() {
  api_get "core/service/search" | python3 -c "
import sys, json
for r in json.load(sys.stdin).get('rows', []):
    print(f\"      {r.get('id',''):20} running={r.get('running','?')}  {r.get('description','')}\")"
}

echo "=== Verifying OPNsense services ==="
echo "  Host: ${OPNSENSE_HOST}"
echo ""

# ─── ntpd ─────────────────────────────────────────────────────────────────────
echo ">>> [1/2] ntpd (network time, port 123)"
NTP=$(check_service "ntpd")
case "$NTP" in
  1|true)
    echo "    ✓ ntpd running."
    ;;
  0|false)
    echo "    ⚠️  ntpd is installed but stopped — starting..."
    start_service "ntpd"
    ;;
  missing)
    echo "    ❌ ntpd service not found. Active services:" >&2
    list_services >&2
    echo "    If the service uses a different name, check the OPNsense UI." >&2
    exit 1
    ;;
  *)
    echo "    ⚠️  Unclear status: $NTP — please check manually."
    ;;
esac

# ─── unbound (DNS) ────────────────────────────────────────────────────────────
echo ""
echo ">>> [2/2] unbound (DNS resolver, port 53)"
DNS=$(check_service "unbound")
case "$DNS" in
  1|true)
    echo "    ✓ unbound running."
    ;;
  0|false)
    echo "    ⚠️  unbound is installed but stopped — starting..."
    start_service "unbound"
    ;;
  missing)
    echo "    ❌ unbound service not found. Active services:" >&2
    list_services >&2
    exit 1
    ;;
  *)
    echo "    ⚠️  Unclear status: $DNS"
    ;;
esac

echo ""
echo "=== Done ==="
echo ""
echo "Note: ntpd & unbound bind to all interfaces by default."
echo "Reachability from home-cluster only requires the firewall rules from"
echo "configure-opnsense-firewall.sh (HOME → (self):53 + 123)."
