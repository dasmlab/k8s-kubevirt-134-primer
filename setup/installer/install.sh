#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

MODE="single"
NODE_NAME=""
CONTROL_HOST=""
NODES_FILE=""
SSH_OPTS_STRING=${SSH_OPTS:-"-o BatchMode=yes -o StrictHostKeyChecking=no"}
JOINED_WORKERS=()

CONTROL_USER=${SUDO_USER:-$(id -un)}
CONTROL_USER_GROUP="$(id -gn "$CONTROL_USER")"
CONTROL_USER_HOME="$(eval echo "~${CONTROL_USER}")"

# shellcheck disable=SC2206
SSH_OPTS=($SSH_OPTS_STRING)

control_user_run() {
    if [[ ${SUDO_USER:-} ]]; then
        sudo -H -u "$CONTROL_USER" "$@"
    else
        "$@"
    fi
}

control_ssh() {
    # shellcheck disable=SC2086
    control_user_run ssh ${SSH_OPTS[@]} "$@"
}

control_scp() {
    # shellcheck disable=SC2086
    control_user_run scp ${SSH_OPTS[@]} "$@"
}

control_ssh_keygen() {
    control_user_run ssh-keygen "$@"
}

control_ssh_keyscan() {
    control_user_run ssh-keyscan "$@"
}

control_mkdir() {
    control_user_run mkdir -p "$@"
}

control_touch() {
    control_user_run touch "$@"
}

control_chmod() {
    control_user_run chmod "$@"
}

require_local_sudo() {
    if ! sudo -n true 2>/dev/null; then
        echo "Passwordless sudo is required on the control node." >&2
        exit 1
    fi
}

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

verify_dependencies() {
    command -v curl >/dev/null 2>&1 || { echo "curl is required" >&2; exit 1; }
    command -v tar >/dev/null 2>&1 || { echo "tar is required" >&2; exit 1; }
    command -v install >/dev/null 2>&1 || { echo "install utility (coreutils) is required" >&2; exit 1; }
    if [[ "$MODE" == "cluster" ]]; then
        command -v ssh >/dev/null 2>&1 || { echo "ssh is required for cluster mode" >&2; exit 1; }
        command -v scp >/dev/null 2>&1 || { echo "scp is required for cluster mode" >&2; exit 1; }
    fi
}

prepare_tmp() {
    mkdir -p "$TMP_DIR"
}

install_k3s() {
    if systemctl is-active --quiet k3s 2>/dev/null; then
        log "k3s already running; skipping installation"
        return
    fi

    local exec_args="$INSTALL_K3S_EXEC_BASE"
    if [[ -n "$NODE_NAME" ]]; then
        exec_args+=" --node-name ${NODE_NAME}"
    fi

    log "Installing k3s ${K3S_VERSION} in ${MODE} mode"
    curl -sfL https://get.k3s.io | sudo INSTALL_K3S_EXEC="$exec_args" INSTALL_K3S_VERSION="$K3S_VERSION" K3S_CHANNEL="$K3S_CHANNEL" sh -
    sudo systemctl enable --now k3s
}

make_kubeconfig_readable() {
    if sudo test -f "$K3S_KUBECONFIG"; then
        sudo chmod 755 /etc/rancher /etc/rancher/k3s 2>/dev/null || true
        sudo chmod 644 "$K3S_KUBECONFIG"
    fi
}

wait_for_k3s() {
    log "Waiting for k3s API server to become ready"
    until sudo $KUBECTL --kubeconfig "$K3S_KUBECONFIG" get nodes >/dev/null 2>&1; do
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
    sudo install -m 0755 "$TMP_DIR/virtctl" "$VIRTCTL_PATH"
}

install_kubevirt() {
    log "Deploying KubeVirt operator ${KUBEVIRT_VERSION}"
    sudo $KUBECTL --kubeconfig "$K3S_KUBECONFIG" apply -f "https://github.com/kubevirt/kubevirt/releases/download/${KUBEVIRT_VERSION}/kubevirt-operator.yaml"
    sudo $KUBECTL --kubeconfig "$K3S_KUBECONFIG" apply -f "https://github.com/kubevirt/kubevirt/releases/download/${KUBEVIRT_VERSION}/kubevirt-cr.yaml"
}

install_cdi() {
    log "Deploying Containerized Data Importer ${CDI_VERSION}"
    sudo $KUBECTL --kubeconfig "$K3S_KUBECONFIG" apply -f "https://github.com/kubevirt/containerized-data-importer/releases/download/${CDI_VERSION}/cdi-operator.yaml"
    sudo $KUBECTL --kubeconfig "$K3S_KUBECONFIG" apply -f "https://github.com/kubevirt/containerized-data-importer/releases/download/${CDI_VERSION}/cdi-cr.yaml"
}

setup_crds() {
    local manifests_dir="${PROJECT_ROOT}/features/134-kubevirt-integration/manifests"
    if [[ -d "$manifests_dir" ]]; then
        if [[ -f "${manifests_dir}/kustomization.yaml" ]]; then
            log "Applying base CRDs via kustomize from ${manifests_dir}"
            sudo $KUBECTL --kubeconfig "$K3S_KUBECONFIG" apply -k "$manifests_dir"
        else
            log "Skipping CRD apply: no kustomization.yaml in ${manifests_dir}"
        fi
    else
        log "Skipping CRD apply: manifests directory not found at ${manifests_dir}"
    fi
}

wait_for_kubevirt() {
    log "Waiting for KubeVirt components to become ready"
    sudo $KUBECTL --kubeconfig "$K3S_KUBECONFIG" -n kubevirt wait kv kubevirt --for condition=Available --timeout=10m
}

fetch_join_token() {
    if [[ -z "$JOIN_TOKEN" ]]; then
        if sudo test -f /var/lib/rancher/k3s/server/node-token; then
            JOIN_TOKEN=$(sudo cat /var/lib/rancher/k3s/server/node-token)
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

extract_ssh_host() {
    local target="$1"
    target=${target#*@}
    echo "${target%%:*}"
}

ensure_known_host() {
    local ssh_target="$1"
    local host
    host=$(extract_ssh_host "$ssh_target")
    [[ -z "$host" ]] && return
    control_mkdir "$CONTROL_USER_HOME/.ssh"
    control_touch "$CONTROL_USER_HOME/.ssh/known_hosts"
    control_chmod 600 "$CONTROL_USER_HOME/.ssh/known_hosts"
    if ! control_ssh_keygen -F "$host" >/dev/null 2>&1; then
        log "Scanning SSH host key for ${host}"
        if ! control_ssh_keyscan -T 5 "$host" >> "$CONTROL_USER_HOME/.ssh/known_hosts" 2>/dev/null; then
            log "Warning: unable to retrieve host key for ${host}; continuing"
        fi
    fi
}

build_worker_join_script() {
    local script_path="$1"
    local agent_exec="$2"
    cat >"$script_path" <<EOF
#!/usr/bin/env bash
set -euo pipefail
mkdir -p ~/.ssh
chmod 700 ~/.ssh
if [[ ! -f ~/.ssh/authorized_keys ]]; then
    touch ~/.ssh/authorized_keys
    chmod 600 ~/.ssh/authorized_keys
fi
for pub in ~/.ssh/id_ed25519.pub ~/.ssh/id_rsa.pub; do
    if [[ -f "\$pub" ]]; then
        key=\$(cat "\$pub")
        grep -qxF "\$key" ~/.ssh/authorized_keys 2>/dev/null || echo "\$key" >> ~/.ssh/authorized_keys
        break
    fi
done
if ! sudo -n true 2>/dev/null; then
    cat <<'MSG' >&2
Passwordless sudo is required on this worker. Update /etc/sudoers, for example:
  $(whoami) ALL=(ALL) NOPASSWD:ALL
MSG
    exit 1
fi
curl -sfL https://get.k3s.io | sudo INSTALL_K3S_VERSION="$K3S_VERSION" K3S_CHANNEL="$K3S_CHANNEL" K3S_URL="https://$CONTROL_HOST:6443" K3S_TOKEN="$JOIN_TOKEN" INSTALL_K3S_EXEC="$agent_exec" sh -
for _ in {1..10}; do
    if sudo test -f /etc/rancher/k3s/k3s.yaml; then
        sudo chmod 644 /etc/rancher/k3s/k3s.yaml
        break
    fi
    sleep 2
done
EOF
    chown "$CONTROL_USER:$CONTROL_USER_GROUP" "$script_path"
    chmod 600 "$script_path"
}

remote_install_worker() {
    local ssh_target="$1"
    local worker_name="$2"
    local agent_exec="agent"
    if [[ -n "$worker_name" ]]; then
        agent_exec+=" --node-name ${worker_name}"
    fi

    ensure_known_host "$ssh_target"
    log "Verifying SSH access to ${worker_name:-$ssh_target}"
    local ssh_check
    if ! ssh_check=$(control_ssh "$ssh_target" "exit 0" 2>&1 >/dev/null); then
        cat >&2 <<EOF
Failed to SSH into ${ssh_target}. Ensure that the control plane user's public key is present in ${ssh_target}:~/.ssh/authorized_keys.
SSH error: ${ssh_check}
EOF
        exit 1
    fi

    if ! control_ssh "$ssh_target" "sudo -n true" >/dev/null 2>&1; then
        cat >&2 <<EOF
Passwordless sudo is not configured on ${ssh_target}. Update /etc/sudoers, e.g. add:
  ${CONTROL_USER} ALL=(ALL) NOPASSWD:ALL
Then rerun the installer.
EOF
        exit 1
    fi

    local safe_id
    safe_id=$(echo "${worker_name:-$ssh_target}" | tr -c '[:alnum:]' '_')
    local worker_script="$TMP_DIR/worker-${safe_id:-node}.sh"
    build_worker_join_script "$worker_script" "$agent_exec"

    log "Uploading worker join script to ${worker_name:-$ssh_target}"
    control_scp "$worker_script" "$ssh_target:/tmp/k3s-worker-join.sh"
    rm -f "$worker_script"
    log "Joining worker ${worker_name:-$ssh_target} via ${ssh_target}"
    if ! control_ssh "$ssh_target" "bash /tmp/k3s-worker-join.sh"; then
        cat >&2 <<EOF
Worker bootstrap failed on ${ssh_target}. Check remote /var/log/syslog or journalctl for details.
EOF
        exit 1
    fi
    control_ssh "$ssh_target" "rm -f /tmp/k3s-worker-join.sh"
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
    require_local_sudo
    verify_dependencies
    prepare_tmp
    install_k3s
    make_kubeconfig_readable
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

