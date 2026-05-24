#!/usr/bin/env bash
# ==============================================================================
#  talos-upgrade.sh
#
#  Rolling Talos OS upgrade — control planes first, then workers, one at a time.
#  Each node must return to Kubernetes Ready before the next one is upgraded.
#
#  The installer image is assembled from TALOS_INSTALLER_HASH + TALOS_VERSION
#  (both read from .env):
#    factory.talos.dev/installer/<TALOS_INSTALLER_HASH>:<TALOS_VERSION>
#
#  Update TALOS_VERSION and TALOS_INSTALLER_HASH in .env before running.
#  The installer hash for a new version is found at https://factory.talos.dev.
#
#  Usage:
#    ./scripts/talos-upgrade.sh         # home-cluster (default)
#    ./scripts/talos-upgrade.sh mgmt    # Management cluster (single node)
# ==============================================================================
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
[[ -f "$REPO_ROOT/.env" ]] || { echo "❌ .env missing." >&2; exit 1; }
set -a; source "$REPO_ROOT/.env"; set +a

TARGET="${1:-both}"
CONFIG_DIR="${HOME}/.config/home-infra"
KUBECONFIG_FILE="${KUBECONFIG_OUT:-$HOME/.kube/home-infra}"
KUBECONFIG_FILE="${KUBECONFIG_FILE/#\~/$HOME}"
MGMT_TALOSCONFIG="${CONFIG_DIR}/mgmt/talosconfig"

[[ -n "${TALOS_INSTALLER_HASH:-}" && "${TALOS_INSTALLER_HASH}" != "<hash-from-factory.talos.dev>" ]] || {
  echo "❌ TALOS_INSTALLER_HASH not set in .env." >&2
  echo "   Get the hash for Talos ${TALOS_VERSION} at https://factory.talos.dev." >&2
  exit 1
}

INSTALLER_IMAGE="factory.talos.dev/installer/${TALOS_INSTALLER_HASH}:${TALOS_VERSION}"

# ─── Helpers ─────────────────────────────────────────────────────────────────

mgmt_kubectl() {
  KUBECONFIG="$KUBECONFIG_FILE" kubectl --context home-mgmt "$@"
}

# Retrieve the admin talosconfig for a workload cluster from the mgmt cluster.
# Tries the CABPT-generated secret first, then TalosConfig status as fallback.
get_workload_talosconfig() {
  local cluster="$1"
  local tc=""

  tc=$(mgmt_kubectl get secret "${cluster}-talosconfig" \
    -o jsonpath='{.data.talosconfig}' 2>/dev/null | base64 -d 2>/dev/null) || true
  [[ -n "$tc" ]] && { echo "$tc"; return 0; }

  tc=$(mgmt_kubectl get talosconfig \
    -l "cluster.x-k8s.io/cluster-name=${cluster}" \
    -o jsonpath='{.items[0].status.talosConfig}' 2>/dev/null) || true
  [[ -n "$tc" ]] && { echo "$tc"; return 0; }

  echo "❌ Could not retrieve talosconfig for ${cluster}." >&2
  return 1
}

# Get all machine IPs for a cluster: control planes first, then workers.
get_node_ips_ordered() {
  local cluster="$1"

  local cp_ips worker_ips
  cp_ips=$(mgmt_kubectl get machines \
    -l "cluster.x-k8s.io/cluster-name=${cluster}" \
    -o json 2>/dev/null \
    | jq -r '.items[]
        | select(.metadata.labels | has("cluster.x-k8s.io/control-plane"))
        | .status.addresses[]
        | select(.type == "InternalIP")
        | .address') || true

  worker_ips=$(mgmt_kubectl get machines \
    -l "cluster.x-k8s.io/cluster-name=${cluster}" \
    -o json 2>/dev/null \
    | jq -r '.items[]
        | select(.metadata.labels | has("cluster.x-k8s.io/control-plane") | not)
        | .status.addresses[]
        | select(.type == "InternalIP")
        | .address') || true

  printf '%s\n%s\n' "$cp_ips" "$worker_ips" | grep -v '^$' || true
}

# Wait for a Kubernetes node (matched by its internal IP) to report Ready.
wait_kubernetes_ready() {
  local node_ip="$1"
  local kube_context="$2"
  local timeout=300
  local elapsed=0

  echo "    ⏳ Waiting for Kubernetes node ${node_ip} to be Ready..."
  while [[ $elapsed -lt $timeout ]]; do
    ready=$(KUBECONFIG="$KUBECONFIG_FILE" kubectl --context "$kube_context" \
      get nodes -o wide --no-headers 2>/dev/null \
      | awk -v ip="$node_ip" '($6==ip || $7==ip) {print $2}' || true)
    if [[ "$ready" == "Ready" ]]; then
      echo "    ✓ Node ${node_ip} Ready (after ${elapsed}s)."
      return 0
    fi
    sleep 10
    elapsed=$((elapsed + 10))
    echo -n "."
  done
  echo ""
  echo "    ❌ Timeout: ${node_ip} did not reach Ready within ${timeout}s." >&2
  return 1
}

# Upgrade a single node. talosctl upgrade --wait (default: true) blocks until
# the node has rebooted and the Talos API is responsive again.
upgrade_node() {
  local node_ip="$1"
  local talosconfig_file="$2"
  local kube_context="${3:-}"

  echo ""
  echo "  → Upgrading ${node_ip} → ${TALOS_VERSION} ..."
  talosctl --talosconfig "$talosconfig_file" \
    --endpoints "$node_ip" --nodes "$node_ip" \
    upgrade --image "$INSTALLER_IMAGE"
  echo "    ✓ Talos API back on ${node_ip}."

  if [[ -n "$kube_context" ]]; then
    wait_kubernetes_ready "$node_ip" "$kube_context"
  fi
}

# Rolling upgrade for a CAPI-managed workload cluster.
upgrade_workload_cluster() {
  local name="$1"     # e.g. home
  local cluster="$2"  # e.g. home-cluster
  local context="$3"  # e.g. home-cluster

  echo ""
  echo "═══ Rolling Talos upgrade: ${name^^} (${cluster}) ═══"
  echo "    Installer: ${INSTALLER_IMAGE}"

  [[ -f "$KUBECONFIG_FILE" ]] || {
    echo "  ❌ Kubeconfig not found: $KUBECONFIG_FILE. Run: task kubeconfig:merge" >&2; return 1
  }

  local talosconfig_content
  talosconfig_content=$(get_workload_talosconfig "$cluster")

  local tmp_tc
  tmp_tc=$(mktemp /tmp/talosconfig-XXXXXX)
  # shellcheck disable=SC2064
  trap "rm -f '$tmp_tc'" RETURN
  printf '%s' "$talosconfig_content" > "$tmp_tc"

  local node_ips
  node_ips=$(get_node_ips_ordered "$cluster")
  if [[ -z "$node_ips" ]]; then
    echo "  ❌ No nodes found for ${cluster}." >&2; return 1
  fi

  echo "  Upgrade order (control planes first, then workers):"
  echo "$node_ips" | sed 's/^/    /'

  while IFS= read -r ip; do
    [[ -z "$ip" ]] && continue
    upgrade_node "$ip" "$tmp_tc" "$context"
  done <<< "$node_ips"

  echo ""
  echo "  ✅ ${name^^}: Talos ${TALOS_VERSION} upgrade complete."
}

# Upgrade the single-node management cluster.
upgrade_mgmt_cluster() {
  echo ""
  echo "═══ Rolling Talos upgrade: Management cluster ═══"
  echo "    Installer: ${INSTALLER_IMAGE}"
  echo "    Node:      ${MGMT_NODE_IP}"

  [[ -f "$MGMT_TALOSCONFIG" ]] || {
    echo "  ❌ Mgmt talosconfig not found: $MGMT_TALOSCONFIG" >&2; return 1
  }

  echo ""
  echo "  → Upgrading ${MGMT_NODE_IP} → ${TALOS_VERSION} ..."
  talosctl --talosconfig "$MGMT_TALOSCONFIG" \
    --endpoints "$MGMT_NODE_IP" --nodes "$MGMT_NODE_IP" \
    upgrade --image "$INSTALLER_IMAGE"
  echo "  ✓ Talos API back on ${MGMT_NODE_IP}."

  echo "  ✅ Management cluster: Talos ${TALOS_VERSION} upgrade complete."
}

# ─── Main ─────────────────────────────────────────────────────────────────────

echo ""
echo "╔══════════════════════════════════════════╗"
echo "║  Talos Rolling Upgrade                   ║"
echo "╚══════════════════════════════════════════╝"
echo "  Target:    ${TARGET}"
echo "  Version:   ${TALOS_VERSION}"
echo "  Installer: ${INSTALLER_IMAGE}"

case "$TARGET" in
  mgmt) upgrade_mgmt_cluster ;;
  home|both) upgrade_workload_cluster home home-cluster home-cluster ;;
  *) echo "Usage: $0 [home|mgmt]" >&2; exit 1 ;;
esac

echo ""
echo "✅ Talos upgrade complete."
echo "   Verify: talosctl version --endpoints <ip> --nodes <ip> --talosconfig <tc>"
