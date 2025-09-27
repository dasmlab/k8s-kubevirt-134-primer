#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

MODE="single"
NODE_NAME=""
CONTROL_HOST=""
NODES_FILE=""
SSH_OPTS=${SSH_OPTS:-"-o BatchMode=yes"}
JOINED_WORKERS=()

K3S_VERSION="v1.34.1+k3s1"
K3S_CHANNEL="stable"
INSTALL_K3S_EXEC_BASE="server --disable traefik"
KUBEVIRT_VERSION="v1.2.0"
CDI_VERSION="v1.60.1"
TMP_DIR="/tmp/k8s-134-installer"
KUBECTL="/usr/local/bin/kubectl"
K3S_KUBECONFIG="/etc/rancher/k3s/k3s.yaml"
VIRTCTL_PATH="/usr/local/bin/virtctl"
JOIN_TOKEN=""

log() {
    echo "[install] $*"
}

usage() {
    cat <<EOF
Usage: sudo ./install.sh [options]

Options:
  --mode <single|cluster>     Deployment mode (default: single).
  --node-name <name>          Override k3s node name for this host.
  --control-host <hostname>   Address workers use to reach the control plane (cluster mode).
  --nodes-file <path>         File containing worker SSH targets for automated join (cluster mode).
  --help                      Show this help message.

Nodes file format (cluster mode): one worker per line, optional node name column.
  user@worker-01 worker-01
  user@worker-02 worker-02
Lines starting with # are ignored. SSH keys and passwordless sudo must be pre-configured.
EOF
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --mode)
                MODE=${2:-}
                shift 2
                ;;
            --node-name)
                NODE_NAME=${2:-}
                shift 2
                ;;
            --control-host)
                CONTROL_HOST=${2:-}
                shift 2
                ;;
            --nodes-file)
                NODES_FILE=${2:-}
                shift 2
                ;;
            --help|-h)
                usage
                exit 0
                ;;
            *)
                echo "Unknown option: $1" >&2
                usage
                exit 1
                ;;
        esac
    done

    case "$MODE" in
        single|cluster) ;;
        *)
            echo "Invalid mode: $MODE" >&2
            exit 1
            ;;
    esac
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
    command -v install >/dev/null 2>&1 || { echo "install utility (coreutils) is required" >&2; exit 1; }
    if [[ "$MODE" == "cluster" ]]; then
        command -v ssh >/dev/null 2>&1 || { echo "ssh is required for cluster mode" >&2; exit 1; }
    fi
}

prepare_tmp() {
    mkdir -p "$TMP_DIR"
}

install_k3s() {
    if systemctl is-active --quiet k3s; then
        log "k3s already running; skipping installation"
        return
    fi

    local exec_args="$INSTALL_K3S_EXEC_BASE"
    if [[ -n "$NODE_NAME" ]]; then
        exec_args+=" --node-name ${NODE_NAME}"
    fi

    log "Installing k3s ${K3S_VERSION} in ${MODE} mode"
    curl -sfL https://get.k3s.io | INSTALL_K3S_EXEC="$exec_args" INSTALL_K3S_VERSION="$K3S_VERSION" K3S_CHANNEL="$K3S_CHANNEL" sh -
    systemctl enable --now k3s
}

wait_for_k3s() {
    log "Waiting for k3s API server to become ready"
    until $KUBECTL --kubeconfig "$K3S_KUBECONFIG" get nodes >/dev/null 2>&1; do
        sleep 5
    done
    log "k3s is ready"
}

get_current_virtctl_version() {
    if [[ -x "$VIRTCTL_PATH" ]]; then
        "$VIRTCTL_PATH" version --client 2>/dev/null | sed -n 's/.*GitVersion:"\(v[^"[:space:]]*\)".*/\1/p'
    fi
}

install_virtctl() {
    local current
    current=$(get_current_virtctl_version || true)

    if [[ -n "$current" && "$current" == "$KUBEVIRT_VERSION" ]]; then
        log "virtctl ${current} already installed"
        return
    fi

    if [[ -n "$current" ]]; then
        log "Updating virtctl from ${current} to ${KUBEVIRT_VERSION}"
    else
        log "Installing virtctl ${KUBEVIRT_VERSION}"
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
    curl -Lf "$url" -o "$TMP_DIR/virtctl"
    install -m 0755 "$TMP_DIR/virtctl" "$VIRTCTL_PATH"
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
    local manifests_dir="${PROJECT_ROOT}/features/134-kubevirt-integration/manifests"
    if [[ -d "$manifests_dir" ]]; then
        if [[ -f "${manifests_dir}/kustomization.yaml" ]]; then
            log "Applying base CRDs via kustomize from ${manifests_dir}"
            $KUBECTL --kubeconfig "$K3S_KUBECONFIG" apply -k "$manifests_dir"
        else
            log "Skipping CRD apply: no kustomization.yaml in ${manifests_dir}"
        fi
    else
        log "Skipping CRD apply: manifests directory not found at ${manifests_dir}"
    fi
}

wait_for_kubevirt() {
    log "Waiting for KubeVirt components to become ready"
    $KUBECTL --kubeconfig "$K3S_KUBECONFIG" -n kubevirt wait kv kubevirt --for condition=Available --timeout=10m
}

fetch_join_token() {
    if [[ -z "$JOIN_TOKEN" ]]; then
        if [[ -f /var/lib/rancher/k3s/server/node-token ]]; then
            JOIN_TOKEN=$(cat /var/lib/rancher/k3s/server/node-token)
        else
            echo "Unable to locate k3s node token" >&2
            exit 1
        fi
    fi
}

resolve_control_host() {
    if [[ -z "$CONTROL_HOST" ]]; then
        CONTROL_HOST=$(hostname -I | awk '{print $1}')
        log "Resolved control host to ${CONTROL_HOST}"
    fi
}

remote_install_worker() {
    local ssh_target="$1"
    local worker_name="$2"
    local agent_exec="agent"
    if [[ -n "$worker_name" ]]; then
        agent_exec+=" --node-name ${worker_name}"
    fi

    log "Joining worker ${worker_name:-$ssh_target} via ${ssh_target}"
    ssh $SSH_OPTS "$ssh_target" <<EOF
set -euo pipefail
curl -sfL https://get.k3s.io | sudo INSTALL_K3S_VERSION='$K3S_VERSION' K3S_CHANNEL='$K3S_CHANNEL' K3S_URL='https://${CONTROL_HOST}:6443' K3S_TOKEN='$JOIN_TOKEN' INSTALL_K3S_EXEC='$agent_exec' sh -
EOF
    JOINED_WORKERS+=("${worker_name:-$ssh_target}")
}

join_workers() {
    [[ "$MODE" != "cluster" ]] && return

    if [[ -z "$NODES_FILE" ]]; then
        log "Cluster mode enabled but no nodes file supplied; skipping worker joins"
        return
    fi

    local resolved_file
    if [[ -f "$NODES_FILE" ]]; then
        resolved_file="$NODES_FILE"
    elif [[ -f "${PROJECT_ROOT}/${NODES_FILE}" ]]; then
        resolved_file="${PROJECT_ROOT}/${NODES_FILE}"
    else
        echo "Nodes file not found: $NODES_FILE" >&2
        exit 1
    fi

    resolve_control_host
    fetch_join_token

    while IFS= read -r line || [[ -n "$line" ]]; do
        # Trim leading/trailing whitespace
        line="${line##*( )}"
        line="${line%%*( )}"
        [[ -z "$line" || "$line" == \#* ]] && continue
        # shellcheck disable=SC2086
        set -- $line
        local target="$1"
        local worker_name="${2:-}"
        remote_install_worker "$target" "$worker_name"
    done < "$resolved_file"
}

summary() {
    log "Installation complete"
    cat <<EOF

Cluster access:
  export KUBECONFIG=${K3S_KUBECONFIG}

Validate components:
  kubectl get nodes
  kubectl get pods -A
  virtctl version --client
EOF

    if [[ "$MODE" == "cluster" ]]; then
        printf '\nWorkers joined (%d): %s\n' "${#JOINED_WORKERS[@]}" "${JOINED_WORKERS[*]:-none}" | sed 's/  / /g'
        printf 'Control plane endpoint: https://%s:6443\n' "$CONTROL_HOST"
    fi

    cat <<EOF

Next steps:
  Explore feature labs under ${PROJECT_ROOT}/features
EOF
}

main() {
    parse_args "$@"
    require_root
    verify_dependencies
    prepare_tmp
    install_k3s
    wait_for_k3s
    join_workers
    install_virtctl
    install_kubevirt
    install_cdi
    setup_crds
    wait_for_kubevirt
    summary
}

main "$@"

