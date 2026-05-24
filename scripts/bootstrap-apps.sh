#!/usr/bin/env bash
set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${0}")/.." && pwd)"
source "${REPO_ROOT}/.env"

CLUSTER_NAME="${1:-home-cluster}"
KUBECONFIG_FILE="${KUBECONFIG_OUT:-$HOME/.kube/home-infra}"
CONTEXT_NAME="${CLUSTER_NAME}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

log() {
    echo -e "${GREEN}[$(date +'%Y-%m-%d %H:%M:%S')]${NC} $*"
}

error() {
    echo -e "${RED}[$(date +'%Y-%m-%d %H:%M:%S')] ERROR:${NC} $*" >&2
}

warn() {
    echo -e "${YELLOW}[$(date +'%Y-%m-%d %H:%M:%S')] WARN:${NC} $*"
}

# Check prerequisites
check_prerequisites() {
    log "Checking prerequisites..."

    local -a required_tools=(kubectl helmfile sops age)
    for tool in "${required_tools[@]}"; do
        if ! command -v "${tool}" &>/dev/null; then
            error "Required tool not found: ${tool}"
            error "Install with: brew install ${tool}"
            exit 1
        fi
    done

    if [[ ! -f "${KUBECONFIG_FILE}" ]]; then
        error "Kubeconfig not found: ${KUBECONFIG_FILE}"
        error "Run 'task up' first to create the cluster"
        exit 1
    fi

    log "✓ Prerequisites OK"
}

# Wait for nodes to be ready
wait_for_nodes() {
    log "Waiting for nodes to be ready..."

    local retries=60
    local count=0

    until kubectl --kubeconfig "${KUBECONFIG_FILE}" --context "${CONTEXT_NAME}" \
        wait nodes --for=condition=Ready=True --all --timeout=10s &>/dev/null; do

        count=$((count + 1))
        if [[ ${count} -ge ${retries} ]]; then
            error "Timeout waiting for nodes to be ready"
            exit 1
        fi

        log "Waiting for nodes... (attempt ${count}/${retries})"
        sleep 10
    done

    log "✓ All nodes are ready"
}

# Apply namespaces
apply_namespaces() {
    log "Creating namespaces..."

    local -a namespaces=(
        "flux-system"
        "kube-system"
        "cert-manager"
        "database"
        "network"
        "observability"
        "security"
    )

    for ns in "${namespaces[@]}"; do
        if kubectl --kubeconfig "${KUBECONFIG_FILE}" --context "${CONTEXT_NAME}" \
            get namespace "${ns}" &>/dev/null; then
            log "  • ${ns} (exists)"
        else
            kubectl --kubeconfig "${KUBECONFIG_FILE}" --context "${CONTEXT_NAME}" \
                create namespace "${ns}" &>/dev/null
            log "  ✓ ${ns} (created)"
        fi
    done
}

# Apply SOPS secrets
apply_sops_secrets() {
    log "Applying SOPS secrets..."

    local -a secrets=(
        "${REPO_ROOT}/bootstrap/sops-age.sops.yaml"
        "${REPO_ROOT}/bootstrap/github-deploy-key.sops.yaml"
    )

    for secret in "${secrets[@]}"; do
        local name="$(basename "${secret}" .sops.yaml)"

        if [[ ! -f "${secret}" ]]; then
            warn "Secret not found, skipping: ${secret}"
            continue
        fi

        # Check if secret needs update
        if sops exec-file "${secret}" \
            "kubectl --kubeconfig ${KUBECONFIG_FILE} --context ${CONTEXT_NAME} --namespace flux-system diff --filename {} 2>/dev/null" &>/dev/null; then
            log "  • ${name} (up-to-date)"
        else
            sops exec-file "${secret}" \
                "kubectl --kubeconfig ${KUBECONFIG_FILE} --context ${CONTEXT_NAME} --namespace flux-system apply --server-side --filename {}" &>/dev/null
            log "  ✓ ${name} (applied)"
        fi
    done
}

# Apply CRDs
apply_crds() {
    log "Applying CRDs..."

    local crds_file="${REPO_ROOT}/bootstrap/helmfile.d/00-crds.yaml"

    if [[ ! -f "${crds_file}" ]]; then
        error "CRDs file not found: ${crds_file}"
        exit 1
    fi

    cd "${REPO_ROOT}/bootstrap/helmfile.d"

    helmfile -f 00-crds.yaml template \
        | kubectl --kubeconfig "${KUBECONFIG_FILE}" --context "${CONTEXT_NAME}" apply -f - &>/dev/null

    log "✓ CRDs applied"
}

# Install core apps via Helmfile
install_apps() {
    log "Installing core applications..."

    local apps_file="${REPO_ROOT}/bootstrap/helmfile.d/01-apps.yaml"

    if [[ ! -f "${apps_file}" ]]; then
        error "Apps file not found: ${apps_file}"
        exit 1
    fi

    cd "${REPO_ROOT}/bootstrap/helmfile.d"

    # Export environment variables for helmfile templating
    export FLUX_REPO_URL="${FLUX_REPO_URL:-https://github.com/cypr0/home-ops}"
    export FLUX_REPO_BRANCH="${FLUX_REPO_BRANCH:-main}"
    export FLUX_REPO_PATH="${FLUX_REPO_PATH:-kubernetes/flux}"
    export FLUX_KUSTOMIZE_PATH="${FLUX_KUSTOMIZE_PATH:-./kubernetes/flux}"

    KUBECONFIG="${KUBECONFIG_FILE}" helmfile -f 01-apps.yaml apply \
        --context "${CONTEXT_NAME}" --skip-deps

    log "✓ Core applications installed"
}

# Wait for Flux to be ready
wait_for_flux() {
    log "Waiting for Flux to be ready..."

    local retries=60
    local count=0

    until kubectl --kubeconfig "${KUBECONFIG_FILE}" --context "${CONTEXT_NAME}" \
        --namespace flux-system wait pod --for=condition=Ready --all --timeout=10s &>/dev/null; do

        count=$((count + 1))
        if [[ ${count} -ge ${retries} ]]; then
            error "Timeout waiting for Flux pods to be ready"
            exit 1
        fi

        log "Waiting for Flux... (attempt ${count}/${retries})"
        sleep 10
    done

    log "✓ Flux is ready"
}

# Main execution
main() {
    log "========================================="
    log "Bootstrap Apps for ${CLUSTER_NAME}"
    log "========================================="

    check_prerequisites
    wait_for_nodes
    apply_namespaces
    apply_sops_secrets
    apply_crds
    install_apps
    wait_for_flux

    log ""
    log "========================================="
    log "✅ Bootstrap complete!"
    log "========================================="
    log ""
    log "Next steps:"
    log "  1. Check Flux status:"
    log "     flux --context ${CONTEXT_NAME} get all"
    log ""
    log "  2. Reconcile Flux to pull from Git:"
    log "     flux --context ${CONTEXT_NAME} reconcile kustomization flux-system --with-source"
    log ""
}

main "$@"
