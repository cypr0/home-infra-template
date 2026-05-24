#!/usr/bin/env bash
# ==============================================================================
#  k8s-upgrade.sh
#
#  Upgrades the Kubernetes version across a cluster using talosctl upgrade-k8s,
#  which handles the rolling update internally:
#    1. Updates static control-plane pods (apiserver, controller-manager,
#       scheduler) on each control-plane node
#    2. Updates kubelet + kube-proxy on every node
#
#  Unlike talos-upgrade.sh this does NOT reboot nodes. The kubelet binary is
#  replaced in-place; components are restarted one at a time.
#
#  Set KUBERNETES_VERSION in .env to the desired target version before running.
#  Ensure that version is supported by the running Talos release:
#    https://www.talos.dev/latest/introduction/support-matrix/
#
#  Usage:
#    ./scripts/k8s-upgrade.sh         # home-cluster (default)
#    ./scripts/k8s-upgrade.sh mgmt    # Management cluster
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

# ─── Helpers ─────────────────────────────────────────────────────────────────

mgmt_kubectl() {
  KUBECONFIG="$KUBECONFIG_FILE" kubectl --context home-mgmt "$@"
}

# Retrieve the admin talosconfig for a workload cluster from the mgmt cluster.
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

# Get the IP of any one control-plane node in the cluster.
# upgrade-k8s only needs a single CP endpoint to orchestrate the full upgrade.
get_any_cp_ip() {
  local cluster="$1"
  mgmt_kubectl get machines \
    -l "cluster.x-k8s.io/cluster-name=${cluster}" \
    -o json 2>/dev/null \
    | jq -r '[.items[]
        | select(.metadata.labels | has("cluster.x-k8s.io/control-plane"))
        | .status.addresses[]
        | select(.type == "InternalIP")
        | .address] | first // empty' \
    2>/dev/null
}

# ─── Upgrade functions ────────────────────────────────────────────────────────

upgrade_workload_cluster() {
  local name="$1"     # e.g. home
  local cluster="$2"  # e.g. home-cluster

  echo ""
  echo "═══ Kubernetes upgrade: ${name^^} (${cluster}) ═══"
  echo "    Target: ${KUBERNETES_VERSION}"

  [[ -f "$KUBECONFIG_FILE" ]] || {
    echo "  ❌ Kubeconfig not found: $KUBECONFIG_FILE. Run: task kubeconfig:merge" >&2; return 1
  }

  local talosconfig_content
  talosconfig_content=$(get_workload_talosconfig "$cluster")

  local cp_ip
  cp_ip=$(get_any_cp_ip "$cluster")
  if [[ -z "$cp_ip" ]]; then
    echo "  ❌ No control-plane IP found for ${cluster}." >&2; return 1
  fi

  local tmp_tc
  tmp_tc=$(mktemp /tmp/talosconfig-XXXXXX)
  # shellcheck disable=SC2064
  trap "rm -f '$tmp_tc'" RETURN
  printf '%s' "$talosconfig_content" > "$tmp_tc"

  echo "  Control-plane endpoint: ${cp_ip}"
  echo "  Running talosctl upgrade-k8s — this updates all nodes and may take several minutes..."
  talosctl --talosconfig "$tmp_tc" \
    --endpoints "$cp_ip" --nodes "$cp_ip" \
    upgrade-k8s --to "${KUBERNETES_VERSION}"

  echo ""
  echo "  ✅ ${name^^}: Kubernetes ${KUBERNETES_VERSION} upgrade complete."
}

upgrade_mgmt_cluster() {
  echo ""
  echo "═══ Kubernetes upgrade: Management cluster ═══"
  echo "    Target: ${KUBERNETES_VERSION}"

  [[ -f "$MGMT_TALOSCONFIG" ]] || {
    echo "  ❌ Mgmt talosconfig not found: $MGMT_TALOSCONFIG" >&2; return 1
  }

  echo "  Control-plane endpoint: ${MGMT_NODE_IP}"
  echo "  Running talosctl upgrade-k8s — this updates all nodes and may take several minutes..."
  talosctl --talosconfig "$MGMT_TALOSCONFIG" \
    --endpoints "$MGMT_NODE_IP" --nodes "$MGMT_NODE_IP" \
    upgrade-k8s --to "${KUBERNETES_VERSION}"

  echo ""
  echo "  ✅ Management cluster: Kubernetes ${KUBERNETES_VERSION} upgrade complete."
}

# ─── Main ─────────────────────────────────────────────────────────────────────

echo ""
echo "╔══════════════════════════════════════════╗"
echo "║  Kubernetes Version Upgrade              ║"
echo "╚══════════════════════════════════════════╝"
echo "  Target:  ${KUBERNETES_VERSION}"
echo "  Cluster: ${TARGET}"
echo ""
echo "  Compatibility matrix: https://www.talos.dev/latest/introduction/support-matrix/"

case "$TARGET" in
  mgmt) upgrade_mgmt_cluster ;;
  home|both) upgrade_workload_cluster home home-cluster ;;
  *) echo "Usage: $0 [home|mgmt]" >&2; exit 1 ;;
esac

echo ""
echo "✅ Kubernetes upgrade complete."
echo "   Verify: kubectl get nodes -o wide"
