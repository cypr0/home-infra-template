set no-exit-message
set quiet
set shell := ['bash', '-euo', 'pipefail', '-c']
set script-interpreter := ['bash', '-euo', 'pipefail']

kubernetes_dir := justfile_dir() + '/kubernetes'

[private]
default:
    just bootstrap -l

[doc('Bootstrap the management cluster')]
[group('bootstrap')]
mgmt: mgmt-check mgmt-vm mgmt-talos mgmt-cilium mgmt-capi
    just log info "Management cluster is ready"

[doc('Bootstrap apps into the workload cluster')]
[group('bootstrap')]
apps: apps-ready apps-namespaces apps-secrets apps-crds apps-helm
    just log info "Cluster is bootstrapped — Flux will start syncing the Git repository"

# ─── Management Cluster ───────────────────────────────────────────────────────

[private]
[script]
mgmt-check:
    if [ -z "${PROXMOX_HOST:-}" ] || [ -z "${PROXMOX_USER:-}" ]; then
        just log error "PROXMOX_HOST and PROXMOX_USER must be set in .env"
        exit 1
    fi

[private]
[script]
mgmt-vm:
    just log info "Creating management VM"
    cd "{{ justfile_dir() }}/../scripts"
    ./create-mgmt-vm.sh

[private]
[script]
mgmt-talos:
    just log info "Configuring Talos on management node"
    cd "{{ justfile_dir() }}/../scripts"
    ./configure-mgmt-talos.sh

[private]
[script]
mgmt-cilium:
    just log info "Installing Cilium on management cluster"
    cd "{{ justfile_dir() }}/../scripts"
    ./install-mgmt-cilium.sh

[private]
[script]
mgmt-capi:
    just log info "Installing CAPI providers"
    cd "{{ justfile_dir() }}/../scripts"
    ./install-capi-providers.sh

# ─── Workload Cluster Apps ───────────────────────────────────────────────────

[private]
[script]
apps-crds:
    just log info "Applying CRDs"
    if ! helmfile --file "{{ source_directory() }}/helmfile/crds.yaml" template --quiet | yq eval-all --exit-status 'select(.kind == "CustomResourceDefinition")' | kubectl apply --server-side --force-conflicts --filename -; then
        just log fatal "Failed to apply crds"
    fi

[private]
[script]
apps-helm:
    just log info "Syncing helmfile"
    if ! helmfile --file "{{ source_directory() }}/helmfile/apps.yaml" sync --hide-notes; then
        just log fatal "Failed to sync helmfile"
    fi

[private]
[script]
apps-namespaces:
    just log info "Applying namespaces for apps"
    for app in "{{ kubernetes_dir }}/apps"/*/; do
        ns="$(basename "$app")"
        if kubectl get namespace "$ns" &>/dev/null; then
            just log info "Namespace already exists" namespace "$ns"
        elif kubectl create namespace "$ns" --dry-run=client -o yaml \
                | kubectl annotate --filename=- --local --overwrite \
                    kustomize.toolkit.fluxcd.io/prune=disabled --output=yaml \
                | kubectl apply --filename=-; then
            just log info "Created namespace" namespace "$ns"
        else
            just log error "Failed to create namespace" namespace "$ns"
        fi
    done

[private]
[script]
apps-ready:
    just log info "Waiting for cluster to be ready"
    timeout_sec=900
    elapsed=0
    while [ "$elapsed" -lt "$timeout_sec" ]; do
        if kubectl wait --for=condition=Ready nodes --all --timeout=0s &>/dev/null; then
            just log info "Cluster is ready"
            exit 0
        fi
        sleep 10
        elapsed=$((elapsed + 10))
    done
    just log fatal "Timed out waiting for cluster"

[private]
[script]
apps-secrets:
    just log info "Applying bootstrap secrets"
    sops --decrypt "{{ source_directory() }}/sops-age.sops.yaml" | kubectl apply --filename=-
    kubectl wait --for=condition=Ready --namespace flux-system secret/sops-age
