#!/usr/bin/env bash
set -euo pipefail

VMCTL_TAILSCALE_ENABLED=1
if [[ "$VMCTL_TAILSCALE_ENABLED" != "1" ]]; then
  echo "tailscale disabled for this resource"
  exit 0
fi

args=(--auth-key "tskey-auth-dummy")
args+=(--hostname "tailscale-gateway")
args+=(--advertise-routes "192.168.86.0/24")
args+=(--advertise-tags "tag:homelab")

tailscale up "${args[@]}"
