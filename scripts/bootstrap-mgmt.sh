#!/usr/bin/env bash
# ==============================================================================
#  bootstrap-mgmt.sh
#
#  Bootstraps the management cluster fully automated and idempotently.
#  Phase 0: Clone Proxmox VM (skip if exists), push Talos config, bootstrap
#  Phase 1: Fetch kubeconfig, install Cilium (helm upgrade --install)
#  Phase 2: CAPI providers via clusterctl init (skip if capi-system exists)
#
#  Idempotent: safe to run any number of times.
#
#  Usage:
#    ./scripts/bootstrap-mgmt.sh
#    ./scripts/bootstrap-mgmt.sh --skip-vm --skip-talos    # CNI + CAPI only
# ==============================================================================
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIG_DIR="${HOME}/.config/home-infra/mgmt"

# ─── Flags ───────────────────────────────────────────────────────────────────
SKIP_VM=false; SKIP_TALOS=false; SKIP_CNI=false; SKIP_CAPI=false
for arg in "$@"; do
  case "$arg" in
    --skip-vm)    SKIP_VM=true ;;
    --skip-talos) SKIP_TALOS=true ;;
    --skip-cni)   SKIP_CNI=true ;;
    --skip-capi)  SKIP_CAPI=true ;;
    *) echo "Unknown flag: $arg" >&2; exit 1 ;;
  esac
done

# ─── Load cluster.toml ───────────────────────────────────────────────────────
source "${REPO_ROOT}/scripts/lib/config-loader.sh"
load_config

mkdir -p "$CONFIG_DIR"

# ─── SSH helper for Proxmox ──────────────────────────────────────────────────
pve_ssh() {
  local cmd="$*"
  if command -v sshpass &>/dev/null && [[ -n "${PVE_SSH_PASS:-}" ]]; then
    sshpass -p "${PVE_SSH_PASS}" ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
      "root@${PROXMOX_PUBLIC_IP}" "$cmd"
  else
    ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
      "root@${PROXMOX_PUBLIC_IP}" "$cmd"
  fi
}

# Password prompt only when VM phase is active and sshpass is available
if ! $SKIP_VM && command -v sshpass &>/dev/null && [[ -z "${PVE_SSH_PASS:-}" ]]; then
  read -rsp "SSH password for root@${PROXMOX_PUBLIC_IP} (leave empty for key auth): " PVE_SSH_PASS
  echo ""
  export PVE_SSH_PASS
fi

# ─── Phase 0: VM ─────────────────────────────────────────────────────────────
echo ""
echo "╔══════════════════════════════════════════╗"
echo "║  Phase 0: Management VM                  ║"
echo "╚══════════════════════════════════════════╝"

DHCP_IP=""

if $SKIP_VM; then
  echo "  → --skip-vm: VM phase skipped."
else
  echo ""
  echo ">>> [0.1] Ensuring VM ${MGMT_VMID} (${MGMT_VM_NAME})..."
  pve_ssh "
    set -e
    if qm status ${MGMT_VMID} >/dev/null 2>&1; then
      echo '  ✓ VM ${MGMT_VMID} exists.'
    else
      echo '  → Cloning template ${PROXMOX_TEMPLATE_ID} → VMID ${MGMT_VMID}'
      qm clone ${PROXMOX_TEMPLATE_ID} ${MGMT_VMID} \
        --name ${MGMT_VM_NAME} --full --storage ${PROXMOX_STORAGE}
      qm set ${MGMT_VMID} \
        --memory ${MGMT_VM_MEMORY_MIB} --cores ${MGMT_VM_CORES} \
        --net0 virtio,bridge=${MGMT_BRIDGE}
    fi
    if [[ \"\$(qm status ${MGMT_VMID} | awk '{print \$2}')\" != 'running' ]]; then
      qm start ${MGMT_VMID}
      echo '  ✓ VM started.'
    else
      echo '  ✓ VM already running.'
    fi
  "

  # Before waiting for DHCP IP: check if mgmt is already on its static IP
  if talosctl --nodes "${MGMT_NODE_IP}" --talosconfig "${CONFIG_DIR}/talosconfig" version >/dev/null 2>&1; then
    echo "  ✓ Mgmt VM already reachable at ${MGMT_NODE_IP} — skipping DHCP discovery."
    DHCP_IP="${MGMT_NODE_IP}"
  else
    echo ""
    echo ">>> [0.2] Finding Talos VM on LAN..."

    # Derive range from DHCP pool (default: .200-.250 if unset)
    DHCP_SCAN_RANGE="${DHCP_SCAN_RANGE:-200-250}"
    DHCP_NET="${MGMT_NETWORK%.0}"   # 192.168.10.0 → 192.168.10
    DHCP_FROM="${DHCP_SCAN_RANGE%-*}"
    DHCP_TO="${DHCP_SCAN_RANGE#*-}"

    # One-shot lease lookup (errors silently ignored — fall-through to range scan)
    set +e
    LEASE_IPS=$(curl -sk --max-time 3 -u "${FW_KEY}:${FW_SECRET}" \
      "https://${OPNSENSE_HOST}/api/dnsmasq/leases/search" 2>/dev/null \
      | python3 -c "
import sys, json
try:
    rows = json.load(sys.stdin).get('rows', [])
    for r in rows:
        ip = r.get('address', '')
        mac = (r.get('hwaddr', '') or '').lower()
        if ip.startswith('${DHCP_NET}.') and mac.startswith('bc:24:11:'):
            print(ip)
except Exception:
    pass
" 2>/dev/null)
    set -e

    # Range IPs as fallback
    RANGE_IPS=""
    for last in $(seq "$DHCP_FROM" "$DHCP_TO"); do
      RANGE_IPS="${RANGE_IPS}${DHCP_NET}.${last}"$'\n'
    done

    # Deduplicated candidates; lease IPs first (higher priority than range)
    CANDIDATES=$(printf "%s\n%s" "$LEASE_IPS" "$RANGE_IPS" | awk 'NF && !seen[$0]++')
    NUM_CAND=$(echo "$CANDIDATES" | wc -l | tr -d ' ')
    echo "  → Probing $NUM_CAND candidates in parallel (lease + range $DHCP_FROM-$DHCP_TO)"

    find_talos_ip_parallel() {
      # Bash-native parallel: start all nc simultaneously in background,
      # first IP that responds wins. Avoids xargs/SIGPIPE issues.
      local tmpfile
      tmpfile=$(mktemp)
      while IFS= read -r ip; do
        [[ -z "$ip" ]] && continue
        ( nc -z -w1 "$ip" 50000 2>/dev/null && echo "$ip" >> "$tmpfile" ) &
      done <<< "$CANDIDATES"
      wait
      head -n 1 "$tmpfile" 2>/dev/null
      rm -f "$tmpfile"
    }

    # 15 iterations × 2s = max 30s wait (VM boot + Talos API ready)
    for i in $(seq 1 15); do
      DHCP_IP=$(find_talos_ip_parallel || true)
      if [[ -n "$DHCP_IP" ]]; then
        echo "  ✓ Talos VM at ${DHCP_IP} (port 50000 open, after $((i*2))s)."
        break
      fi
      sleep 2
      echo -n "."
    done
    [[ -n "$DHCP_IP" ]] || {
      echo ""
      echo "❌ No Talos VM found in ${DHCP_NET}.${DHCP_FROM}-${DHCP_TO}." >&2
      echo "   Check: is the VM running? Is bridge ${MGMT_BRIDGE} correct? Is DHCP issuing a lease?" >&2
      exit 1
    }
  fi
fi

# ─── Phase 0.3–0.7: Talos ────────────────────────────────────────────────────
echo ""
echo "╔══════════════════════════════════════════╗"
echo "║  Phase 0: Provisioning Talos             ║"
echo "╚══════════════════════════════════════════╝"

if $SKIP_TALOS; then
  echo "  → --skip-talos: Talos phase skipped."
else
  # Idempotency: if talosconfig exists AND mgmt VM is reachable on static IP AND etcd is bootstrapped
  ALREADY_BOOTSTRAPPED=false
  if [[ -f "${CONFIG_DIR}/talosconfig" ]] && \
     talosctl --nodes "${MGMT_NODE_IP}" --talosconfig "${CONFIG_DIR}/talosconfig" \
              etcd status >/dev/null 2>&1; then
    ALREADY_BOOTSTRAPPED=true
    echo "  ✓ Mgmt cluster already bootstrapped (etcd member on ${MGMT_NODE_IP})."
  fi

  if ! $ALREADY_BOOTSTRAPPED; then
    echo ""
    echo ">>> [0.3] Rendering Talos patch..."
    envsubst < "$REPO_ROOT/bootstrap/mgmt-talos-patch.yaml" > "${CONFIG_DIR}/mgmt-patch.yaml"
    echo "  ✓ ${CONFIG_DIR}/mgmt-patch.yaml"

    echo ""
    echo ">>> [0.4] Generating machine config..."
    # Regenerate if patch is newer than existing config or config is missing
    REGEN=false
    if [[ ! -f "${CONFIG_DIR}/controlplane.yaml" ]] || [[ ! -f "${CONFIG_DIR}/talosconfig" ]]; then
      REGEN=true
    elif [[ "${CONFIG_DIR}/mgmt-patch.yaml" -nt "${CONFIG_DIR}/controlplane.yaml" ]]; then
      echo "  ↻ Patch is newer than controlplane.yaml — regenerating."
      REGEN=true
    fi
    if $REGEN; then
      talosctl gen config "k8s-mgmt" "https://${MGMT_VIP}:6443" \
        --config-patch-control-plane "@${CONFIG_DIR}/mgmt-patch.yaml" \
        --output-dir "${CONFIG_DIR}" \
        --force
      echo "  ✓ controlplane.yaml + talosconfig generated."
    else
      echo "  ✓ Machine config exists (${CONFIG_DIR})."
    fi

    # Persist endpoints + default node in talosconfig so subsequent
    # `talosctl bootstrap` etc. work without explicit flags.
    talosctl --talosconfig "${CONFIG_DIR}/talosconfig" \
      config endpoint "${MGMT_NODE_IP}" >/dev/null
    talosctl --talosconfig "${CONFIG_DIR}/talosconfig" \
      config node "${MGMT_NODE_IP}" >/dev/null

    [[ -n "$DHCP_IP" ]] || { echo "❌ DHCP_IP unknown — VM must be provisioned first." >&2; exit 1; }

    if [[ "$DHCP_IP" != "${MGMT_NODE_IP}" ]]; then
      echo ""
      echo ">>> [0.5] Waiting for Talos API on ${DHCP_IP}:50000..."
      for i in $(seq 1 36); do
        nc -z -w2 "${DHCP_IP}" 50000 2>/dev/null && { echo "  ✓ Reachable after $((i*5))s."; break; }
        sleep 5
      done

      echo ""
      echo ">>> [0.6] Pushing config to VM (${DHCP_IP})..."
      talosctl apply-config \
        --nodes "${DHCP_IP}" \
        --file "${CONFIG_DIR}/controlplane.yaml" \
        --insecure
      echo "  ✓ Config applied — VM rebooting with ${MGMT_NODE_IP}."
    else
      echo "  ✓ VM already on ${MGMT_NODE_IP} — skipping apply-config."
    fi

    echo ""
    echo ">>> [0.7] Waiting for Talos API on ${MGMT_NODE_IP}..."
    for i in $(seq 1 36); do
      if talosctl --nodes "${MGMT_NODE_IP}" --talosconfig "${CONFIG_DIR}/talosconfig" version >/dev/null 2>&1; then
        echo "  ✓ Reachable after $((i*5))s."
        break
      fi
      sleep 5
    done

    echo ""
    echo ">>> [0.8] Bootstrapping etcd..."
    if talosctl --nodes "${MGMT_NODE_IP}" --endpoints "${MGMT_NODE_IP}" \
         --talosconfig "${CONFIG_DIR}/talosconfig" etcd status >/dev/null 2>&1; then
      echo "  ✓ etcd already initialized."
    else
      talosctl --nodes "${MGMT_NODE_IP}" --endpoints "${MGMT_NODE_IP}" \
        --talosconfig "${CONFIG_DIR}/talosconfig" bootstrap
      echo "  ✓ Bootstrap triggered. Waiting 30s for API server..."
      sleep 30
    fi
  fi
fi

# ─── Phase 1: Kubeconfig + CNI ───────────────────────────────────────────────
echo ""
echo "╔══════════════════════════════════════════╗"
echo "║  Phase 1: Kubeconfig + Cilium            ║"
echo "╚══════════════════════════════════════════╝"

echo ""
echo ">>> [1.1] Fetching kubeconfig → ~/.kube/config..."
talosctl kubeconfig \
  --nodes "${MGMT_NODE_IP}" \
  --talosconfig "${CONFIG_DIR}/talosconfig" \
  --force ~/.kube/config
export KUBECONFIG="$HOME/.kube/config"
echo "  ✓ ~/.kube/config updated"

# Wait for API server (KubeVIP reachability)
echo ""
echo ">>> [1.2] Waiting for API server (${MGMT_VIP}:6443)..."
api_ready=false
for i in $(seq 1 60); do
  if kubectl --kubeconfig "$HOME/.kube/config" get --raw /readyz >/dev/null 2>&1; then
    echo "  ✓ API server ready after $((i*5))s."
    api_ready=true
    break
  fi
  sleep 5
  echo -n "."
done
echo ""
if ! $api_ready; then
  echo "  ❌ API server did not become ready within 5 minutes." >&2
  echo "     Check: talosctl --nodes ${MGMT_NODE_IP} service kubelet status" >&2
  echo "     Check: talosctl --nodes ${MGMT_NODE_IP} dmesg | tail -20" >&2
  exit 1
fi

if $SKIP_CNI; then
  echo "  → --skip-cni: Cilium install skipped."
else
  echo ""
  echo ">>> [1.3] Installing / upgrading Cilium..."
  helm repo add cilium https://helm.cilium.io/ >/dev/null 2>&1 || true
  helm repo update cilium >/dev/null
  helm upgrade --install cilium cilium/cilium \
    --namespace kube-system \
    --set kubeProxyReplacement=true \
    --set k8sServiceHost=localhost \
    --set k8sServicePort=7445 \
    --set ipam.mode=kubernetes \
    --set operator.replicas=1 \
    --set cgroup.autoMount.enabled=false \
    --set cgroup.hostRoot=/sys/fs/cgroup \
    --set securityContext.capabilities.ciliumAgent="{CHOWN,KILL,NET_ADMIN,NET_RAW,IPC_LOCK,SYS_ADMIN,SYS_RESOURCE,DAC_OVERRIDE,FOWNER,SETGID,SETUID}" \
    --set securityContext.capabilities.cleanCiliumState="{NET_ADMIN,SYS_ADMIN,SYS_RESOURCE}" \
    --wait --timeout 5m
  kubectl wait --for=condition=Ready node --all --timeout=180s
  echo "  ✓ Cilium installed, node Ready."
fi

# ─── Phase 2: CAPI providers ─────────────────────────────────────────────────
echo ""
echo "╔══════════════════════════════════════════╗"
echo "║  Phase 2: CAPI Providers                 ║"
echo "╚══════════════════════════════════════════╝"

if $SKIP_CAPI; then
  echo "  → --skip-capi: clusterctl init skipped."
else
  # CAPMOX needs the LAN-internal Proxmox URL (mgmt cluster speaks internally).
  # Falls back to PROXMOX_URL if PROXMOX_URL_INTERNAL is not set.
  CAPMOX_PROXMOX_URL="${PROXMOX_URL_INTERNAL:-$PROXMOX_URL}"

  if kubectl get ns capi-system >/dev/null 2>&1; then
    echo "  ✓ CAPI providers already installed (capi-system exists)."
  else
    echo ""
    echo ">>> [2.1] clusterctl init (CAPMOX → ${CAPMOX_PROXMOX_URL})..."
    PROXMOX_URL="$CAPMOX_PROXMOX_URL" clusterctl init \
      --config "$REPO_ROOT/bootstrap/clusterctl.yaml" \
      --infrastructure proxmox \
      --bootstrap talos \
      --control-plane talos \
      --ipam in-cluster
  fi

  # Install IPAM provider if it was omitted in a previous init
  if ! kubectl get ns capi-ipam-in-cluster-system >/dev/null 2>&1; then
    echo "  ↻ Installing missing IPAM in-cluster provider..."
    PROXMOX_URL="$CAPMOX_PROXMOX_URL" clusterctl init \
      --config "$REPO_ROOT/bootstrap/clusterctl.yaml" --ipam in-cluster
  fi

  # Ensure the CAPMOX secret is current (also on re-runs).
  # Secret name is 'capmox-manager-credentials' with keys url/token/secret.
  if kubectl get secret -n capmox-system capmox-manager-credentials >/dev/null 2>&1; then
    current=$(kubectl get secret -n capmox-system capmox-manager-credentials \
      -o jsonpath='{.data.url}' 2>/dev/null | base64 -d 2>/dev/null || true)
    if [[ -n "$current" && "$current" != "$CAPMOX_PROXMOX_URL" ]]; then
      echo "  ↻ Correcting CAPMOX secret: $current → $CAPMOX_PROXMOX_URL"
      kubectl create secret generic capmox-manager-credentials -n capmox-system \
        --from-literal=url="$CAPMOX_PROXMOX_URL" \
        --from-literal=token="$PROXMOX_TOKEN" \
        --from-literal=secret="$PROXMOX_SECRET" \
        --dry-run=client -o yaml | kubectl apply -f -
      kubectl rollout restart -n capmox-system deploy/capmox-controller-manager
    else
      echo "  ✓ CAPMOX secret correctly points to ${CAPMOX_PROXMOX_URL}"
    fi
  fi

  echo ""
  echo ">>> [2.2] Waiting for provider pods..."
  for ns in capi-system capmox-system cabpt-system cacppt-system capi-ipam-in-cluster-system; do
    if ! kubectl get ns "$ns" >/dev/null 2>&1; then
      echo "  ⚠️  Namespace $ns missing — skipping."
      continue
    fi
    if kubectl wait --for=condition=Available deployment --all \
         -n "$ns" --timeout=180s 2>&1 | grep -E '^(deployment|error)'; then
      :
    else
      echo "  ❌ Deployments in $ns not Available — pod status:"
      kubectl get pods -n "$ns"
      exit 1
    fi
  done
  echo "  ✓ All providers available."

  # Disable CAPMOX webhooks — known issue: Cilium socketLB +
  # hostNetwork apiserver + ClusterIP webhook gives EPERM on Talos.
  # CAPMOX controllers validate their resources themselves; the webhook is
  # only defense-in-depth at admission. Workaround sets failurePolicy to
  # Ignore so kubectl apply does not block.
  echo ""
  echo ">>> [2.3] Setting CAPMOX webhooks to failurePolicy=Ignore..."
  for wh in capmox-validating-webhook-configuration capmox-mutating-webhook-configuration; do
    if kubectl get validatingwebhookconfiguration "$wh" >/dev/null 2>&1; then
      kubectl get validatingwebhookconfiguration "$wh" -o json \
        | jq '.webhooks |= map(.failurePolicy = "Ignore")' \
        | kubectl apply -f - >/dev/null
      echo "  ✓ $wh → failurePolicy=Ignore"
    elif kubectl get mutatingwebhookconfiguration "$wh" >/dev/null 2>&1; then
      kubectl get mutatingwebhookconfiguration "$wh" -o json \
        | jq '.webhooks |= map(.failurePolicy = "Ignore")' \
        | kubectl apply -f - >/dev/null
      echo "  ✓ $wh → failurePolicy=Ignore"
    fi
  done
fi

echo ""
echo "╔══════════════════════════════════════════════════════╗"
echo "║  ✅  Management cluster ready                         ║"
echo "╚══════════════════════════════════════════════════════╝"
echo ""
echo "  Talosconfig: ${CONFIG_DIR}/talosconfig"
echo "  Kubeconfig:  ~/.kube/config"
echo ""
echo "  Next step: task clusters:up"
