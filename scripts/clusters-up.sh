#!/usr/bin/env bash
# ==============================================================================
#  clusters-up.sh
#
#  Creates the home-cluster workload cluster on the management cluster.
#  Idempotent: kubectl apply is already idempotent, plus clean wait-for-ready.
#
#  Usage:
#    ./scripts/clusters-up.sh
# ==============================================================================
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
[[ -f "$REPO_ROOT/.env" ]] || { echo "❌ .env missing." >&2; exit 1; }
set -a; source "$REPO_ROOT/.env"; set +a

# Ensure kubectl uses the mgmt kubeconfig.
# Set AFTER sourcing .env to prevent .env from overriding it with an empty value.
export KUBECONFIG="$HOME/.kube/config"

# envsubst whitelist: only our ENV vars are substituted — Talos templates
# like ${ds.meta_data.local_ipv4} are left untouched.
ENV_VARS='$HOME_DNS $HOME_GATEWAY $HOME_SUBNET_PREFIX $HOME_VIP $HOME_BRIDGE $HOME_NETWORK $HOME_IP_POOL '
ENV_VARS+='$HOME_CP_REPLICAS $HOME_WORKER_REPLICAS $HOME_WORKER_MIN $HOME_WORKER_MAX '
ENV_VARS+='$HOME_CP_CORES $HOME_CP_MEM_MIB $HOME_CP_DISK_GB $HOME_WORKER_CORES $HOME_WORKER_MEM_MIB $HOME_WORKER_DISK_GB '
ENV_VARS+='$TALOS_INSTALLER_HASH $TALOS_VERSION $KUBERNETES_VERSION $NODE_LABEL_DOMAIN '
ENV_VARS+='$PROXMOX_NODE $PROXMOX_STORAGE $PROXMOX_TEMPLATE_ID $AUTOSCALER_NS $AUTOSCALER_IMAGE'

apply_dir() {
  local dir="$1"
  shopt -s nullglob
  for f in "$dir"/*.yaml; do
    echo "    → $(basename "$f")"
    envsubst "$ENV_VARS" < "$f" | kubectl apply -f -
  done
}

BASE="$REPO_ROOT/Cluster/workload-clusters"
CLUSTER_NAME="home-cluster"

echo ""
echo "═══ home-cluster ═══"
echo "  [1/3] Applying cluster definition..."
apply_dir "$BASE/cluster"
echo "  [2/3] Applying control planes..."
apply_dir "$BASE/control-planes"
echo "  [3/3] Applying workers..."
apply_dir "$BASE/workers"

echo ""
echo "  ⏳ Waiting for cluster ${CLUSTER_NAME} Phase=Provisioned (timeout 15min)..."
for i in $(seq 1 90); do
  phase=$(kubectl get cluster "$CLUSTER_NAME" -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
  if [[ "$phase" == "Provisioned" ]]; then
    echo "  ✓ ${CLUSTER_NAME}: Phase=Provisioned (after $((i*10))s)."
    break
  fi
  sleep 10
  echo -n "."
done
if [[ "$phase" != "Provisioned" ]]; then
  echo ""
  echo "  ⚠️  Timeout — cluster not Provisioned. Status:"
  kubectl get cluster,taloscontrolplane,machinedeployment,machine -A | grep -E "${CLUSTER_NAME}|NAME" || true
  exit 1
fi

echo ""
echo "✅ Cluster provisioning complete."
echo "   Next step: task addons:install"
