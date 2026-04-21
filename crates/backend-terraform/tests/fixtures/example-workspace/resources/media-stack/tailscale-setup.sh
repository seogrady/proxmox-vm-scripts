#!/usr/bin/env bash
set -euo pipefail

VMCTL_TAILSCALE_ENABLED=1
if [[ "$VMCTL_TAILSCALE_ENABLED" != "1" ]]; then
  echo "tailscale disabled for this resource"
  exit 0
fi

VMCTL_TAILSCALE_AUTH_KEY="tskey-fixture"
VMCTL_TAILSCALE_HOSTNAME="media-stack"
VMCTL_TAILSCALE_ROUTES=""
VMCTL_TAILSCALE_TAGS="tag:homelab"
VMCTL_TAILSCALE_ACCEPT_ROUTES=0
VMCTL_TAILSCALE_EXIT_NODE=0

already_authenticated=0
backend_state=""
if command -v tailscale >/dev/null 2>&1 && tailscale status --json >/tmp/vmctl-tailscale-status.json 2>/dev/null; then
  readarray -t ts_state < <(python3 - <<'PY'
import json
try:
    with open("/tmp/vmctl-tailscale-status.json", encoding="utf-8") as handle:
        status = json.load(handle)
    have_key = bool(status.get("HaveNodeKey"))
    backend = str(status.get("BackendState", ""))
    print("1" if have_key and backend in {"Running", "Starting"} else "0")
    print(backend)
except Exception:
    print("0")
    print("")
PY
)
  already_authenticated="${ts_state[0]}"
  backend_state="${ts_state[1]}"
fi

set_args=()
set_args+=(--hostname "$VMCTL_TAILSCALE_HOSTNAME")

if [[ "$already_authenticated" == "1" ]]; then
  if ((${#set_args[@]} > 0)); then
    tailscale set "${set_args[@]}"
  fi
  exit 0
fi

# Keep existing node identity whenever possible.
if [[ "$backend_state" == "Stopped" || "$backend_state" == "NoState" ]]; then
  tailscale up "${set_args[@]}"
  exit 0
fi

if [[ "$backend_state" != "NeedsLogin" ]]; then
  if tailscale up "${set_args[@]}"; then
    exit 0
  fi
fi

if [[ -z "$VMCTL_TAILSCALE_AUTH_KEY" ]]; then
  echo "tailscale is not authenticated and no auth key is configured"
  exit 1
fi

args=(--auth-key "$VMCTL_TAILSCALE_AUTH_KEY")
args+=("${set_args[@]}")
args+=(--advertise-tags "$VMCTL_TAILSCALE_TAGS")


tailscale up "${args[@]}"
