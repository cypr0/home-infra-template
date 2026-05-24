#!/usr/bin/env bash
# ==============================================================================
#  kubeconfig-merge.sh
#
#  Fetches kubeconfigs from both clusters and merges them into a single file
#  with renamed contexts:
#    home-mgmt    → Management cluster
#    home-cluster → Home workload cluster
#
#  Output: ${KUBECONFIG_OUT} (default ~/.kube/home-infra)
#
#  Usage:
#    ./scripts/kubeconfig-merge.sh
#    export KUBECONFIG=~/.kube/home-infra
#    kubectl config use-context home-cluster
# ==============================================================================
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
[[ -f "$REPO_ROOT/.env" ]] || { echo "❌ .env missing." >&2; exit 1; }
set -a; source "$REPO_ROOT/.env"; set +a

# Ensure kubectl uses the mgmt kubeconfig.
# Set AFTER sourcing .env to prevent .env from overriding it with an empty value.
export KUBECONFIG="$HOME/.kube/config"

OUT="${KUBECONFIG_OUT:-$HOME/.kube/home-infra}"
OUT="${OUT/#\~/$HOME}"   # expand ~
mkdir -p "$(dirname "$OUT")"

CONFIG_DIR="${HOME}/.config/home-infra"
mkdir -p "$CONFIG_DIR"

MGMT_KC="${CONFIG_DIR}/mgmt-kubeconfig"
HOME_KC="${CONFIG_DIR}/home-cluster-kubeconfig"

echo "=== Kubeconfig merge ==="

# ─── 1. Mgmt kubeconfig via talosctl ─────────────────────────────────────────
echo ">>> Fetching mgmt kubeconfig..."
talosctl kubeconfig \
  --nodes "${MGMT_NODE_IP}" \
  --talosconfig "${CONFIG_DIR}/mgmt/talosconfig" \
  --force "$MGMT_KC"
chmod 600 "$MGMT_KC"

# ─── 2. home-cluster via clusterctl (against mgmt cluster) ───────────────────
KUBECONFIG="$MGMT_KC" clusterctl get kubeconfig home-cluster > "$HOME_KC" 2>/dev/null && \
  echo "  ✓ home-cluster kubeconfig" || echo "  ⚠️  home-cluster not available — skipping."

chmod 600 "$HOME_KC" 2>/dev/null || true

# ─── 3. Rename contexts + merge ──────────────────────────────────────────────
echo ""
echo ">>> Renaming contexts..."
rename_context() {
  local file="$1" newname="$2"
  [[ -f "$file" && -s "$file" ]] || return 0
  # Read old context name + cluster + user and rename all three
  local oldctx oldcluster olduser
  oldctx=$(KUBECONFIG="$file" kubectl config current-context 2>/dev/null)
  oldcluster=$(KUBECONFIG="$file" kubectl config view -o jsonpath="{.contexts[?(@.name==\"$oldctx\")].context.cluster}")
  olduser=$(KUBECONFIG="$file" kubectl config view -o jsonpath="{.contexts[?(@.name==\"$oldctx\")].context.user}")

  # Idempotent: if target context already exists, delete it first
  if KUBECONFIG="$file" kubectl config get-contexts "$newname" >/dev/null 2>&1; then
    KUBECONFIG="$file" kubectl config delete-context "$newname" >/dev/null 2>&1 || true
  fi
  KUBECONFIG="$file" kubectl config rename-context "$oldctx" "$newname" >/dev/null
  # Rename cluster + user via yq (kubectl has no rename command for these)
  yq -i "
    (.clusters[] | select(.name == \"${oldcluster}\") | .name) = \"${newname}\" |
    (.users[]   | select(.name == \"${olduser}\")    | .name) = \"${newname}\" |
    (.contexts[] | select(.name == \"${newname}\") | .context.cluster) = \"${newname}\" |
    (.contexts[] | select(.name == \"${newname}\") | .context.user)    = \"${newname}\"
  " "$file"
}

rename_context "$MGMT_KC" home-mgmt
[[ -s "$HOME_KC" ]] && rename_context "$HOME_KC" home-cluster

echo ""
echo ">>> Merging → $OUT"
files=("$MGMT_KC")
[[ -s "$HOME_KC" ]] && files+=("$HOME_KC")
KUBECONFIG="$(IFS=:; echo "${files[*]}")" kubectl config view --flatten > "$OUT"
KUBECONFIG="$OUT" kubectl config use-context home-mgmt >/dev/null
chmod 600 "$OUT"

echo ""
echo "✅ Kubeconfig written: $OUT"
echo ""
echo "Available contexts:"
KUBECONFIG="$OUT" kubectl config get-contexts -o name | sed 's/^/  /'

# ─── 4. Merge talosconfigs ────────────────────────────────────────────────────
echo ""
echo ">>> Merging talosconfigs → ${CONFIG_DIR}/talosconfig"
HOME_TC="${CONFIG_DIR}/home-talosconfig"
MERGED_TC="${CONFIG_DIR}/talosconfig"

if [[ -s "$HOME_TC" ]]; then
  cp "$HOME_TC" "$MERGED_TC"
  echo "✅ Talosconfig written: ${MERGED_TC}"
  echo ""
  TALOSCONFIG="$MERGED_TC" talosctl config contexts | sed 's/^/  /'
else
  echo "  ⚠️  No workload talosconfigs found — skipping talosconfig merge."
fi

echo ""
echo "Activate with:"
echo "  set -gx KUBECONFIG $OUT     # fish"
echo "  export KUBECONFIG=$OUT      # bash/zsh"
echo "  kubectl config use-context home-cluster"
