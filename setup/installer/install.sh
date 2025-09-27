#!/usr/bin/env bash
set -euo pipefail

K3S_VERSION="v1.34.1+k3s1"
K3S_CHANNEL="stable"
INSTALL_K3S_EXEC="server --disable traefik"
KUBEVIRT_VERSION="release-1.2"
CDI_VERSION="v1.60.1"
TMP_DIR="/tmp/k8s-134-installer"
KUBECTL="/usr/local/bin/kubectl"
K3S_KUBECONFIG="/etc/rancher/k3s/k3s.yaml"

log() {
    echo "[install] $*"
}

require_root() {
    if [[ $EUID -ne 0 ]]; then
        echo "This installer must be run as root or with sudo." >&2
        exit 1
    fi
}

verify_dependencies() {
    command -v curl >/dev/null 2>&1 || { echo "curl is required" >&2; exit 1; }
    command -v tar >/dev/null 2>&1 || { echo "tar is required" >&2; exit 1; }
}

prepare_tmp() {
    mkdir -p "$TMP_DIR"
}

install_k3s() {
    if systemctl is-active --quiet k3s; then
        log "k3s already running; skipping installation"
        return
    fi

    log "Installing k3s ${K3S_VERSION}"
    curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="$INSTALL_K3S_EXEC" INSTALL_K3S_VERSION="$K3S_VERSION" K3S_CHANNEL="$K3S_CHANNEL" sh -
    systemctl enable --now k3s
}

wait_for_k3s() {
    log "Waiting for k3s API server to become ready"
    until $KUBECTL --kubeconfig "$K3S_KUBECONFIG" get nodes >/dev/null 2>&1; do
        sleep 5
    done
    log "k3s is ready"
}

install_virtctl() {
    if [[ -x /usr/local/bin/virtctl ]]; then
        log "virtctl already installed"
        return
    fi

    local arch
    arch=$(uname -m)
    case "$arch" in
        x86_64) arch="amd64" ;;
        aarch64) arch="arm64" ;;
        *) echo "Unsupported architecture: $arch" >&2; exit 1 ;;
    esac

    local url="https://github.com/kubevirt/kubevirt/releases/download/${KUBEVIRT_VERSION}/virtctl-${KUBEVIRT_VERSION}-linux-${arch}"
    log "Downloading virtctl from $url"
    curl -L "$url" -o "$TMP_DIR/virtctl"
    install -m 0755 "$TMP_DIR/virtctl" /usr/local/bin/virtctl
}

install_kubevirt() {
    log "Deploying KubeVirt operator ${KUBEVIRT_VERSION}"
    $KUBECTL --kubeconfig "$K3S_KUBECONFIG" apply -f "https://github.com/kubevirt/kubevirt/releases/download/${KUBEVIRT_VERSION}/kubevirt-operator.yaml"
    $KUBECTL --kubeconfig "$K3S_KUBECONFIG" apply -f "https://github.com/kubevirt/kubevirt/releases/download/${KUBEVIRT_VERSION}/kubevirt-cr.yaml"
}

install_cdi() {
    log "Deploying Containerized Data Importer ${CDI_VERSION}"
    $KUBECTL --kubeconfig "$K3S_KUBECONFIG" apply -f "https://github.com/kubevirt/containerized-data-importer/releases/download/${CDI_VERSION}/cdi-operator.yaml"
    $KUBECTL --kubeconfig "$K3S_KUBECONFIG" apply -f "https://github.com/kubevirt/containerized-data-importer/releases/download/${CDI_VERSION}/cdi-cr.yaml"
}

setup_crds() {
    log "Applying base CRDs"
    $KUBECTL --kubeconfig "$K3S_KUBECONFIG" apply -k /home/dasm/k8s-134-installer/features/134-kubevirt-integration/manifests || true
}

wait_for_kubevirt() {
    log "Waiting for KubeVirt components to become ready"
    $KUBECTL --kubeconfig "$K3S_KUBECONFIG" -n kubevirt wait kv kubevirt --for condition=Available --timeout=10m
}

summary() {
    log "Installation complete"
    cat <<EOF

Cluster access:
  export KUBECONFIG=${K3S_KUBECONFIG}

Validate components:
  kubectl get nodes
  kubectl get pods -n kubevirt
  virtctl version

Next steps:
  Explore feature labs under /home/dasm/k8s-134-installer/features
EOF
}

main() {
    require_root
    verify_dependencies
    prepare_tmp
    install_k3s
    wait_for_k3s
    install_virtctl
    install_kubevirt
    install_cdi
    setup_crds
    wait_for_kubevirt
    summary
}

main "$@"

