#!/usr/bin/env bash
set -euo pipefail

if [[ $(id -u) -ne 0 ]]; then
  echo "Run uninstall.sh with sudo." >&2
  exit 1
fi

if command -v /usr/local/bin/kubectl >/dev/null 2>&1; then
  echo "Removing feature components"
  /usr/local/bin/kubectl delete kubevirt kubevirt -n kubevirt >/dev/null 2>&1 || true
  /usr/local/bin/kubectl delete cdi cdi -n cdi >/dev/null 2>&1 || true
fi

if [[ -x /usr/local/bin/k3s-uninstall.sh ]]; then
  echo "Uninstalling k3s"
  /usr/local/bin/k3s-uninstall.sh
fi

if [[ -x /usr/local/bin/k3s-agent-uninstall.sh ]]; then
  /usr/local/bin/k3s-agent-uninstall.sh || true
fi

echo "Cleanup complete"
