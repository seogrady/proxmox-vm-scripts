#!/usr/bin/env bash
set -euo pipefail

target_host="${VMCTL_RESOURCE_NAME:-media-stack}"
target_user="${VMCTL_MEDIA_SSH_USER:-ubuntu}"
ssh_key="${DEFAULT_SSH_PRIVATE_KEY_FILE:-${VMCTL_ENV_DEFAULT_SSH_PRIVATE_KEY_FILE:-}}"
vmid="${VMCTL_RESOURCE_VMID:-}"

if [[ -z "$ssh_key" ]]; then
  ssh_key="$HOME/.ssh/id_ed25519"
fi

if [[ ! -f "$ssh_key" ]]; then
  echo "missing SSH key for remote hook execution: $ssh_key" >&2
  exit 1
fi

resolve_target_host() {
  local host="$1"
  local vmid="$2"
  if getent ahostsv4 "$host" >/dev/null 2>&1; then
    printf '%s\n' "$host"
    return 0
  fi

  if [[ -n "$vmid" ]] && command -v qm >/dev/null 2>&1; then
    local ip
    ip="$(
      qm guest cmd "$vmid" network-get-interfaces 2>/dev/null | python3 - <<'PY'
import json
import sys

try:
    data = json.load(sys.stdin)
except Exception:
    print("")
    raise SystemExit(0)

for iface in data:
    for addr in iface.get("ip-addresses", []) or []:
        ip = str(addr.get("ip-address") or "").strip()
        if not ip or ":" in ip or ip.startswith("127."):
            continue
        print(ip)
        raise SystemExit(0)
print("")
PY
    )"
    if [[ -n "$ip" ]]; then
      printf '%s\n' "$ip"
      return 0
    fi
  fi

  return 1
}

if ! resolved_host="$(resolve_target_host "$target_host" "$vmid")"; then
  echo "failed to resolve media target host. tried hostname '$target_host' and qm guest lookup for VMID '$vmid'" >&2
  exit 1
fi

remote_cmd="sudo env PYTHONUNBUFFERED=1 /usr/local/lib/vmctl/media_download_unpack.py --scan-existing"
set +e
ssh -o BatchMode=yes -o IdentitiesOnly=yes -o IdentityAgent=none -o ConnectTimeout=20 -o StrictHostKeyChecking=accept-new -i "$ssh_key" "${target_user}@${resolved_host}" "$remote_cmd" 2>&1 \
  | sed '/^warning: Jellyfin refresh skipped:/d'
ssh_status=${PIPESTATUS[0]}
set -e
exit "$ssh_status"
