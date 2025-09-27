#!/usr/bin/env bash
set -euo pipefail

CONTROL_USER=${SUDO_USER:-$(id -un)}
CONTROL_USER_HOME="$(eval echo "~${CONTROL_USER}")"
SSH_OPTS_STRING=${SSH_OPTS:-"-o BatchMode=yes -o StrictHostKeyChecking=no"}
# shellcheck disable=SC2206
SSH_OPTS=($SSH_OPTS_STRING)
NODES_FILE=""

usage() {
  cat <<EOF
Usage: sudo ./uninstall.sh [--nodes-file path]

Options:
  --nodes-file <file>  List of worker SSH targets (same format as install).
  --help               Show this message.
EOF
}

control_user_run() {
  if [[ ${SUDO_USER:-} ]]; then
    sudo -H -u "$CONTROL_USER" "$@"
  else
    "$@"
  fi
}

control_ssh() {
  # shellcheck disable=SC2086
  control_user_run ssh -n ${SSH_OPTS[@]} "$@"
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
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
}

cleanup_worker_fs() {
  control_ssh "$1" "sudo rm -rf /etc/rancher/k3s" || true
  control_ssh "$1" "sudo rm -rf /var/lib/rancher/k3s" || true
  control_ssh "$1" "rm -f ~/.kube/config" || true
}

remote_uninstall_worker() {
  local ssh_target="$1"
  echo "Removing worker components on ${ssh_target}"
  if ! control_ssh "$ssh_target" "sudo -n true" >/dev/null 2>&1; then
    echo "Passwordless sudo required on ${ssh_target}; skipping" >&2
    return
  fi
  control_ssh "$ssh_target" "sudo systemctl stop k3s-agent.service >/dev/null 2>&1 || true"
  control_ssh "$ssh_target" "if [[ -x /usr/local/bin/k3s-agent-uninstall.sh ]]; then sudo /usr/local/bin/k3s-agent-uninstall.sh; fi"
  cleanup_worker_fs "$ssh_target"
}

cleanup_workers() {
  [[ -z "$NODES_FILE" ]] && return

  local resolved_file
  if [[ -f "$NODES_FILE" ]]; then
    resolved_file="$NODES_FILE"
  elif [[ -f "${CONTROL_USER_HOME}/${NODES_FILE}" ]]; then
    resolved_file="${CONTROL_USER_HOME}/${NODES_FILE}"
  else
    echo "Nodes file not found: $NODES_FILE" >&2
    exit 1
  fi

  local processed=0
  while read -r target _; do
    target=${target%%$'\r'*}
    [[ -z "$target" || ${target:0:1} == "#" ]] && continue
    remote_uninstall_worker "$target"
    processed=$((processed + 1))
  done < "$resolved_file"

  echo "Worker uninstall entries processed: $processed"
}

cleanup_control_plane_fs() {
  sudo rm -rf /etc/rancher/k3s || true
  sudo rm -rf /var/lib/rancher/k3s || true
  sudo rm -rf /var/lib/kubelet || true
  sudo rm -rf /var/lib/longhorn || true
  rm -f "$CONTROL_USER_HOME/.kube/config" || true
}

main() {
  if [[ $(id -u) -ne 0 ]]; then
    echo "Run uninstall.sh with sudo." >&2
    exit 1
  fi

  parse_args "$@"

  if command -v /usr/local/bin/kubectl >/dev/null 2>&1; then
    echo "Removing feature components"
    /usr/local/bin/kubectl delete kubevirt kubevirt -n kubevirt >/dev/null 2>&1 || true
    /usr/local/bin/kubectl delete cdi cdi -n cdi >/dev/null 2>&1 || true
  fi

  cleanup_workers

  if [[ -x /usr/local/bin/k3s-uninstall.sh ]]; then
    echo "Uninstalling k3s"
    /usr/local/bin/k3s-uninstall.sh
  fi

  if [[ -x /usr/local/bin/k3s-agent-uninstall.sh ]]; then
    /usr/local/bin/k3s-agent-uninstall.sh || true
  fi

  cleanup_control_plane_fs

  echo "Cleanup complete"
}

main "$@"
