set no-exit-message
set quiet
set shell := ['bash', '-euo', 'pipefail', '-c']
set script-interpreter := ['bash', '-euo', 'pipefail']

cluster_dir := justfile_dir()

[private]
default:
    just capmox -l

[doc('Deploy home-cluster via CAPMOX')]
[group('capmox')]
deploy: deploy-check deploy-apply deploy-wait deploy-kubeconfig
    just log info "Home cluster is provisioned and ready"

[doc('Show CAPI cluster status')]
[group('capmox')]
status:
    kubectl --context home-mgmt get cluster,taloscontrolplane,machinedeployment,machine,proxmoxmachine -A

[doc('Get kubeconfig for workload cluster')]
[group('capmox')]
kubeconfig:
    just log info "Fetching workload cluster kubeconfig"
    clusterctl get kubeconfig home-cluster > "$HOME/.kube/home-cluster"
    kubectl --kubeconfig "$HOME/.kube/home-cluster" config set-context --current --namespace=default
    just log info "Kubeconfig saved to ~/.kube/home-cluster"

[doc('Delete home-cluster (DESTRUCTIVE)')]
[group('capmox')]
[confirm("Really delete the workload cluster? [y/N]")]
delete:
    kubectl --context home-mgmt delete cluster home-cluster --ignore-not-found
    just log info "Cluster deletion initiated — CAPI will decommission VMs"

[doc('Scale workers')]
[group('capmox')]
scale count:
    kubectl --context home-mgmt patch machinedeployment home-cluster-workers \
        --type merge --patch '{"spec":{"replicas":{{ count }}}}'
    just log info "Scaling workers to {{ count }}"

# ─── Private Tasks ────────────────────────────────────────────────────────────

[private]
[script]
deploy-check:
    if ! kubectl --context home-mgmt get nodes &>/dev/null; then
        just log error "Management cluster not reachable"
        just log info "Run: just bootstrap mgmt"
        exit 1
    fi

[private]
[script]
deploy-apply:
    just log info "Applying CAPI cluster manifests"
    kubectl --context home-mgmt apply --filename "{{ cluster_dir }}/cluster.yaml"
    kubectl --context home-mgmt apply --filename "{{ cluster_dir }}/controlplane.yaml"
    kubectl --context home-mgmt apply --filename "{{ cluster_dir }}/workers.yaml"

[private]
[script]
deploy-wait:
    just log info "Waiting for cluster to be provisioned (this may take 10+ minutes)"
    kubectl --context home-mgmt wait cluster/home-cluster \
        --for=condition=ControlPlaneReady --timeout=20m
    kubectl --context home-mgmt wait cluster/home-cluster \
        --for=condition=Ready --timeout=20m
    just log info "Cluster is provisioned"

[private]
deploy-kubeconfig: kubeconfig
