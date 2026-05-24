#!/usr/bin/env bash
# ==============================================================================
#  install-addons.sh
#
#  For the home-cluster workload cluster:
#    1. Fetch kubeconfig from CAPI cluster + create secrets in the mgmt cluster
#    2. Install Cilium (in the workload cluster)
#    3. ProviderID-Patcher + Taint-Remover (Helm, in the mgmt cluster)
#    4. Cluster Autoscaler (in the mgmt cluster)
#
#  Idempotent: all operations use upgrade --install / apply.
#
#  Usage: ./scripts/install-addons.sh
# ==============================================================================
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
[[ -f "$REPO_ROOT/.env" ]] || { echo "❌ .env missing." >&2; exit 1; }
set -a; source "$REPO_ROOT/.env"; set +a

# Ensure kubectl/helm use the mgmt kubeconfig.
# Set AFTER sourcing .env to prevent .env from overriding it with an empty value.
export KUBECONFIG="$HOME/.kube/config"

TARGET="${1:-both}"
CONFIG_DIR="${HOME}/.config/home-infra"
mkdir -p "$CONFIG_DIR"

# Ensure kubectl context points at the mgmt cluster
if ! kubectl get ns capi-system >/dev/null 2>&1; then
  echo "❌ Current kubectl context does not point at the mgmt cluster (capi-system missing)." >&2
  exit 1
fi

# Creates an OPNsense Unbound host override as a DNS fallback (idempotent).
ensure_dns_override() {
  local host="$1" domain="$2" ip="$3"
  [[ -n "${OPNSENSE_HOST:-}" && -n "${FW_KEY:-}" && -n "${FW_SECRET:-}" ]] || return 0
  local existing
  existing=$(curl -sk --max-time 5 -u "${FW_KEY}:${FW_SECRET}" \
    "https://${OPNSENSE_HOST}/api/unbound/settings/searchHostOverride" \
    | python3 -c "
import sys,json
rows=json.load(sys.stdin).get('rows',[])
r=next((r for r in rows if r.get('host')=='${host}' and r.get('domain')=='${domain}'),None)
print(r['uuid'] if r else '')
" 2>/dev/null || true)
  if [[ -z "$existing" ]]; then
    curl -sk --max-time 5 -u "${FW_KEY}:${FW_SECRET}" \
      -X POST -H "Content-Type: application/json" \
      "https://${OPNSENSE_HOST}/api/unbound/settings/addHostOverride" \
      -d "{\"host\":{\"enabled\":\"1\",\"host\":\"${host}\",\"domain\":\"${domain}\",\"rr\":\"A\",\"server\":\"${ip}\",\"description\":\"${host}.${domain} CAPI VIP\"}}" \
      >/dev/null 2>&1 || true
    curl -sk --max-time 5 -u "${FW_KEY}:${FW_SECRET}" \
      -X POST "https://${OPNSENSE_HOST}/api/unbound/service/reconfigure" -d "{}" \
      >/dev/null 2>&1 || true
  fi
}

kubevip_install() {
  local vip="$1" kubeconfig="$2" cluster="$3"
  echo "  [KubeVIP] Deploy/update on cluster (VIP=${vip})..."

  # Same as Cilium: VIP only exists after the first ready node → fall back to node IP
  local install_kubeconfig="$kubeconfig"
  if ! KUBECONFIG="$kubeconfig" kubectl get --raw /readyz >/dev/null 2>&1; then
    local node_ip
    node_ip=$(kubectl get machines -n default \
      -l "cluster.x-k8s.io/cluster-name=${cluster}" \
      -o jsonpath="{range .items[*]}{.status.addresses[?(@.type==\"InternalIP\")].address}{\" \"}{end}" \
      2>/dev/null | tr ' ' '\n' | while read -r ip; do
        nc -z -w2 "$ip" 6443 2>/dev/null && echo "$ip" && break
      done)
    if [[ -n "$node_ip" ]]; then
      install_kubeconfig="${kubeconfig%.yaml}-bootstrap.yaml"
      sed "s|server: https://.*:6443|server: https://${node_ip}:6443|" \
        "$kubeconfig" > "$install_kubeconfig"
    fi
  fi

  # Talos disables the static pod directory — deploy KubeVIP as a DaemonSet.
  # RBAC applied manually instead of via kube-vip.io/manifests/rbac.yaml because
  # that manifest is missing the coordination.k8s.io/leases permission for leader election.
  KUBECONFIG="$install_kubeconfig" kubectl apply -f - >/dev/null <<RBAC
apiVersion: v1
kind: ServiceAccount
metadata:
  name: kube-vip
  namespace: kube-system
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: system:kube-vip-role
rules:
- apiGroups: [""]
  resources: ["services/status"]
  verbs: ["update"]
- apiGroups: [""]
  resources: ["services", "endpoints"]
  verbs: ["list","get","watch","update"]
- apiGroups: [""]
  resources: ["nodes"]
  verbs: ["list","get","watch","update","patch"]
- apiGroups: ["coordination.k8s.io"]
  resources: ["leases"]
  verbs: ["list","get","watch","create","update"]
- apiGroups: ["discovery.k8s.io"]
  resources: ["endpointslices"]
  verbs: ["list","get","watch","update"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: system:kube-vip-binding
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: system:kube-vip-role
subjects:
- kind: ServiceAccount
  name: kube-vip
  namespace: kube-system
RBAC

  KUBECONFIG="$install_kubeconfig" kubectl apply -f - <<EOF
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: kube-vip-ds
  namespace: kube-system
spec:
  selector:
    matchLabels:
      app: kube-vip-ds
  template:
    metadata:
      labels:
        app: kube-vip-ds
    spec:
      nodeSelector:
        node-role.kubernetes.io/control-plane: ""
      tolerations:
      - effect: NoSchedule
        operator: Exists
      - effect: NoExecute
        operator: Exists
      hostNetwork: true
      serviceAccountName: kube-vip
      containers:
      - name: kube-vip
        image: ghcr.io/kube-vip/kube-vip:v0.8.9
        args:
        - manager
        env:
        - name: vip_arp
          value: "true"
        - name: port
          value: "6443"
        - name: vip_interface
          value: eth0
        - name: vip_cidr
          value: "32"
        - name: cp_enable
          value: "true"
        - name: cp_namespace
          value: kube-system
        - name: svc_enable
          value: "false"
        - name: vip_leaderelection
          value: "true"
        - name: vip_leaseduration
          value: "5"
        - name: vip_renewdeadline
          value: "3"
        - name: vip_retryperiod
          value: "1"
        - name: address
          value: "${vip}"
        securityContext:
          capabilities:
            add:
            - NET_ADMIN
            - NET_RAW
        volumeMounts:
        - mountPath: /etc/kubernetes/admin.conf
          name: kubeconfig
      volumes:
      - hostPath:
          path: /etc/kubernetes/admin.conf
        name: kubeconfig
EOF
  echo "  ✓ KubeVIP DaemonSet ready."
}

# Patches cluster.controlPlane.endpoint on all reachable CP nodes.
# Required because CAPMOX writes the controlPlaneEndpoint hostname (e.g. home-api.lan)
# from the ProxmoxCluster spec into the Talos machine config. That hostname is not
# resolvable via the local stub resolver (127.0.0.53).
# Idempotent: patch is only applied when the endpoint is not yet in IP format.
patch_cp_endpoint() {
  local cluster="$1" vip="$2" talosconfig="$3"
  echo "  [Endpoint-Patch] Setting controlPlane.endpoint to ${vip}..."
  local patch
  patch=$(printf 'cluster:\n  controlPlane:\n    endpoint: https://%s:6443' "$vip")
  local ips
  ips=$(kubectl get machines -n default \
    -l "cluster.x-k8s.io/cluster-name=${cluster}" \
    -o jsonpath="{range .items[*]}{.status.addresses[?(@.type==\"InternalIP\")].address}{\" \"}{end}" \
    2>/dev/null | tr ' ' '\n' | grep -v '^$')
  while IFS= read -r ip; do
    nc -z -w1 "$ip" 50000 2>/dev/null || continue
    # Check whether the patch is needed (endpoint still contains a hostname instead of an IP)
    local current
    current=$(talosctl --talosconfig "$talosconfig" \
      --endpoints "$ip" --nodes "$ip" \
      get machineconfig -o yaml 2>/dev/null \
      | grep 'endpoint:' | head -1 | awk '{print $2}')
    if [[ "$current" == "https://${vip}:6443" ]]; then
      echo "    ✓ ${ip} already correct."
      continue
    fi
    printf '%s' "$patch" | talosctl --talosconfig "$talosconfig" \
      --endpoints "$ip" --nodes "$ip" \
      patch machineconfig --patch-file /dev/stdin >/dev/null 2>&1 \
      && echo "    ✓ ${ip} patched (${current} → https://${vip}:6443)" \
      || echo "    ⚠ ${ip} patch failed (non-critical)"
  done <<< "$ips"
}

cilium_install() {
  local cluster="$1" vip="$2" kubeconfig="$3"
  echo "  [Cilium] Install/upgrade on ${cluster}..."
  helm repo add cilium https://helm.cilium.io/ >/dev/null 2>&1 || true
  helm repo update cilium >/dev/null

  # KubeVIP only exists after at least one CP node is Ready. On the first install
  # fall back to a directly reachable CP node IP as the temporary API server.
  local install_kubeconfig="$kubeconfig"
  if ! KUBECONFIG="$kubeconfig" kubectl get --raw /readyz >/dev/null 2>&1; then
    echo "  [Cilium] VIP not reachable — looking for a reachable CP node directly..."
    local node_ip
    node_ip=$(kubectl get machines -n default \
      -l "cluster.x-k8s.io/cluster-name=${cluster}" \
      -o jsonpath="{range .items[*]}{.status.addresses[?(@.type==\"InternalIP\")].address}{\" \"}{end}" \
      2>/dev/null | tr ' ' '\n' | while read -r ip; do
        nc -z -w2 "$ip" 6443 2>/dev/null && echo "$ip" && break
      done)
    if [[ -n "$node_ip" ]]; then
      echo "  [Cilium] Using node IP ${node_ip} instead of VIP."
      install_kubeconfig="${kubeconfig%.yaml}-bootstrap.yaml"
      sed "s|server: https://.*:6443|server: https://${node_ip}:6443|" \
        "$kubeconfig" > "$install_kubeconfig"
    else
      echo "  [Cilium] ⚠ No CP node reachable, trying VIP..." >&2
    fi
  fi

  KUBECONFIG="$install_kubeconfig" helm upgrade --install cilium cilium/cilium \
    --namespace kube-system \
    --set kubeProxyReplacement=true \
    --set k8sServiceHost=localhost \
    --set k8sServicePort=7445 \
    --set ipam.mode=kubernetes \
    --set cgroup.autoMount.enabled=false \
    --set cgroup.hostRoot=/sys/fs/cgroup \
    --set securityContext.capabilities.ciliumAgent="{CHOWN,KILL,NET_ADMIN,NET_RAW,IPC_LOCK,SYS_ADMIN,SYS_RESOURCE,DAC_OVERRIDE,FOWNER,SETGID,SETUID}" \
    --set securityContext.capabilities.cleanCiliumState="{NET_ADMIN,SYS_ADMIN,SYS_RESOURCE}" \
    --set operator.replicas=1 \
    --wait --timeout 5m
}

addons_for() {
  local name="$1"      # e.g. home
  local pretty="$2"    # directory name, e.g. Cluster
  local clusterName="$3"
  local vip="$4"

  echo ""
  echo "═══ ${pretty} cluster addons ═══"

  # ─── 1. Fetch workload kubeconfig + create secrets ──────────────────────────
  local wkc="${CONFIG_DIR}/${name}-cluster-kubeconfig"
  echo "  [Kubeconfig] Fetching from ${clusterName}..."
  clusterctl get kubeconfig "$clusterName" \
    | sed "s|server: https://.*:6443|server: https://${vip}:6443|" \
    > "$wkc"
  chmod 600 "$wkc"

  echo "  [Secrets] Creating in mgmt cluster..."
  kubectl create secret generic "${name}-cluster-kubeconfig" \
    --from-file=value="$wkc" \
    --dry-run=client -o yaml | kubectl apply -f -
  kubectl create secret generic "${name}-kubeconfig" \
    --namespace="${AUTOSCALER_NS}" \
    --from-file=kubeconfig="$wkc" \
    --dry-run=client -o yaml | kubectl apply -f -

  # ─── 2. Cilium + KubeVIP in the workload cluster ────────────────────────────
  # Retry because Cilium upgrade fails transiently when nodes are joining
  local cilium_ok=false
  for _attempt in 1 2 3; do
    cilium_install "$clusterName" "$vip" "$wkc" && cilium_ok=true && break || {
      echo "  ⚠ Cilium attempt ${_attempt}/3 failed — waiting 30s..."
      sleep 30
    }
  done
  $cilium_ok || { echo "  ❌ Cilium could not be installed." >&2; exit 1; }
  kubevip_install "$vip" "$wkc" "$clusterName"

  # ─── 2b. kubelet-csr-approver ────────────────────────────────────────────────
  echo "  [CSR-Approver] Deploy/update..."
  # RBAC first (ServiceAccount must exist before Deployment)
  KUBECONFIG="$wkc" kubectl apply -f - >/dev/null 2>&1 <<'CSREOF'
apiVersion: v1
kind: ServiceAccount
metadata:
  name: kubelet-csr-approver
  namespace: kube-system
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: kubelet-csr-approver
rules:
- apiGroups: ["certificates.k8s.io"]
  resources: ["certificatesigningrequests"]
  verbs: ["get","list","watch"]
- apiGroups: ["certificates.k8s.io"]
  resources: ["certificatesigningrequests/approval"]
  verbs: ["update"]
- apiGroups: ["certificates.k8s.io"]
  resources: ["signers"]
  resourceNames: ["kubernetes.io/kubelet-serving"]
  verbs: ["approve"]
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: kubelet-csr-approver
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: kubelet-csr-approver
subjects:
- kind: ServiceAccount
  name: kubelet-csr-approver
  namespace: kube-system
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: kubelet-csr-approver
  namespace: kube-system
spec:
  replicas: 1
  selector:
    matchLabels:
      app: kubelet-csr-approver
  template:
    metadata:
      labels:
        app: kubelet-csr-approver
    spec:
      nodeSelector:
        node-role.kubernetes.io/control-plane: ""
      tolerations:
      - operator: Exists
      serviceAccountName: kubelet-csr-approver
      containers:
      - name: approver
        image: ghcr.io/postfinance/kubelet-csr-approver:v1.2.2
        env:
        - name: PROVIDER_REGEX
          value: ".*"
        - name: BYPASS_DNS_RESOLUTION
          value: "true"
        - name: MAX_EXPIRATION_SEC
          value: "86400"
        - name: IGNORE_NON_SYSTEM_NODE
          value: "true"
CSREOF
  echo "  ✓ CSR-Approver ready."

  # ─── 2c. DNS override + controlPlane.endpoint patch ─────────────────────────
  # CAPMOX writes the hostname from proxmox-cluster.yaml (e.g. home-api.lan)
  # into the Talos machine config. Fallback: create a DNS override in Unbound.
  ensure_dns_override "${name}-api" "lan" "$vip"
  local talosconfig_file="${CONFIG_DIR}/${name}-talosconfig"
  kubectl get secret -n default "${clusterName}-talosconfig" \
    -o jsonpath="{.data.talosconfig}" 2>/dev/null | base64 -d > "$talosconfig_file" || true
  [[ -s "$talosconfig_file" ]] && patch_cp_endpoint "$clusterName" "$vip" "$talosconfig_file" || true

  # ─── 3. ProviderID-Patcher + Taint-Remover (in the mgmt cluster) ─────────────
  echo "  [Helm] providerid-patcher-${name}..."
  helm upgrade --install "providerid-patcher-${name}" \
    "$REPO_ROOT/Cluster/management-cluster/providerid-patcher" \
    --set "target.name=${name}" \
    --set "target.kubeconfigSecretName=${name}-cluster-kubeconfig"

  echo "  [Helm] taint-remover-${name}..."
  helm upgrade --install "taint-remover-${name}" \
    "$REPO_ROOT/Cluster/management-cluster/taint-remover" \
    --set "target.name=${name}" \
    --set "target.kubeconfigSecretName=${name}-cluster-kubeconfig"

  # ─── 4. Cluster Autoscaler ──────────────────────────────────────────────────
  echo "  [Autoscaler] Applying..."
  shopt -s nullglob
  for f in "$REPO_ROOT/Cluster/management-cluster/autoscalers"/*.yaml; do
    envsubst < "$f" | kubectl apply -f -
  done

  echo "  ✓ ${name} addons done."
}

addons_for home Cluster home-cluster "$HOME_VIP"

echo ""
echo "✅ Addons installed."
echo "   Next step: task kubeconfig:merge"
