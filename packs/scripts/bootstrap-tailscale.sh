#!/usr/bin/env bash
set -euo pipefail

RESOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SETUP_SCRIPT="$RESOURCE_DIR/tailscale-setup.sh"

if [[ ! -f "$SETUP_SCRIPT" ]]; then
  echo "no tailscale setup script found"
  exit 0
fi

if ! grep -q '^VMCTL_TAILSCALE_ENABLED=1$' "$SETUP_SCRIPT"; then
  bash "$SETUP_SCRIPT"
  exit 0
fi

if ! command -v curl >/dev/null 2>&1; then
  apt-get update
  apt-get install -y ca-certificates curl
fi

curl -fsSL https://tailscale.com/install.sh | sh
systemctl enable --now tailscaled
bash "$SETUP_SCRIPT"
