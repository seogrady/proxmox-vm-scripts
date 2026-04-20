#!/usr/bin/env bash
set -euo pipefail

VMCTL_TAILSCALE_ENABLED=1
if [[ "$VMCTL_TAILSCALE_ENABLED" != "1" ]]; then
  echo "tailscale disabled for this resource"
  exit 0
fi

VMCTL_TAILSCALE_AUTH_KEY="tskey-fixture"
VMCTL_TAILSCALE_HOSTNAME="kodi-htpc"
VMCTL_TAILSCALE_ROUTES=""
VMCTL_TAILSCALE_TAGS="tag:homelab"
VMCTL_TAILSCALE_ACCEPT_ROUTES=0
VMCTL_TAILSCALE_EXIT_NODE=0

already_authenticated=0
if command -v tailscale >/dev/null 2>&1 && tailscale status --json >/tmp/vmctl-tailscale-status.json 2>/dev/null; then
  already_authenticated="$(python3 - <<'PY'
import json
try:
    with open("/tmp/vmctl-tailscale-status.json", encoding="utf-8") as handle:
        status = json.load(handle)
    print(1 if status.get("HaveNodeKey") and status.get("BackendState") in {"Running", "Starting"} else 0)
except Exception:
    print(0)
PY
)"
fi

if [[ "$already_authenticated" == "1" ]]; then
  set_args=()
  set_args+=(--hostname "$VMCTL_TAILSCALE_HOSTNAME")
  if ((${#set_args[@]} > 0)); then
    tailscale set "${set_args[@]}"
  fi
  exit 0
fi

if [[ -z "$VMCTL_TAILSCALE_AUTH_KEY" ]]; then
  echo "tailscale is not authenticated and no auth key is configured"
  exit 1
fi

args=(--reset --auth-key "$VMCTL_TAILSCALE_AUTH_KEY")
args+=(--hostname "$VMCTL_TAILSCALE_HOSTNAME")
args+=(--advertise-tags "$VMCTL_TAILSCALE_TAGS")


tailscale up "${args[@]}"
