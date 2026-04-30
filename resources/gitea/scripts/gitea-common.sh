#!/usr/bin/env bash
set -euo pipefail

RESOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="$RESOURCE_DIR/gitea.env"

load_gitea_env() {
  if [[ -f "$ENV_FILE" ]]; then
    set -a
    . "$ENV_FILE"
    set +a
  fi

  GITEA_ENABLED="${GITEA_ENABLED:-true}"
  GITEA_ADMIN_USER="${GITEA_ADMIN_USER:-admin}"
  GITEA_ADMIN_PASSWORD="${GITEA_ADMIN_PASSWORD:-changeme}"
  GITEA_ADMIN_EMAIL="${GITEA_ADMIN_EMAIL:-admin@gitea.local}"
  GITEA_DOMAIN="${GITEA_DOMAIN:-${VMCTL_RESOURCE_NAME:-gitea}}"
  GITEA_HTTP_PORT="${GITEA_HTTP_PORT:-3000}"
  GITEA_SSH_PORT="${GITEA_SSH_PORT:-2222}"
  GITEA_DATA_ROOT="${GITEA_DATA_ROOT:-/var/lib/gitea}"
  GITEA_REPO_ROOT="${GITEA_REPO_ROOT:-$GITEA_DATA_ROOT/repositories}"
  GITEA_SSH_KEY_SOURCE="${GITEA_SSH_KEY_SOURCE:-/root/.ssh/authorized_keys}"
  GITEA_BASE_URL="${GITEA_BASE_URL:-}"
  GITEA_SSH_HOST="${GITEA_SSH_HOST:-}"
  GITEA_ADMIN_SSH_PUBLIC_KEYS="${GITEA_ADMIN_SSH_PUBLIC_KEYS:-}"
  GITEA_TAILSCALE_HTTPS_ENABLED="${GITEA_TAILSCALE_HTTPS_ENABLED:-true}"
  GITEA_TAILSCALE_HTTPS_TARGET="${GITEA_TAILSCALE_HTTPS_TARGET:-}"

  export GITEA_ENABLED GITEA_ADMIN_USER GITEA_ADMIN_PASSWORD GITEA_ADMIN_EMAIL
  export GITEA_DOMAIN GITEA_HTTP_PORT GITEA_SSH_PORT GITEA_DATA_ROOT GITEA_REPO_ROOT
  export GITEA_SSH_KEY_SOURCE GITEA_BASE_URL GITEA_SSH_HOST GITEA_ADMIN_SSH_PUBLIC_KEYS
  export GITEA_TAILSCALE_HTTPS_ENABLED GITEA_TAILSCALE_HTTPS_TARGET
}

is_truthy() {
  local value="${1:-}"
  case "${value,,}" in
    1|true|yes|on) return 0 ;;
    *) return 1 ;;
  esac
}

detect_tailscale_hostname() {
  if ! command -v tailscale >/dev/null 2>&1; then
    return 0
  fi
  local status_file
  status_file="$(mktemp)"
  if ! tailscale status --json >"$status_file" 2>/dev/null; then
    rm -f "$status_file"
    return 0
  fi

  python3 - "$status_file" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
try:
    data = json.loads(path.read_text(encoding="utf-8"))
except Exception:
    print("")
    raise SystemExit(0)

name = str(data.get("Self", {}).get("DNSName") or "").strip().rstrip(".")
print(name)
PY
  rm -f "$status_file"
}

resolve_gitea_http_host() {
  local host="${GITEA_DOMAIN:-}"
  if [[ -z "$host" || "$host" == "gitea" ]]; then
    local ts
    ts="$(detect_tailscale_hostname || true)"
    if [[ -n "$ts" ]]; then
      host="$ts"
    fi
  fi
  if [[ -z "$host" ]]; then
    host="${VMCTL_RESOURCE_NAME:-gitea}"
  fi
  printf '%s\n' "$host"
}

resolve_gitea_ssh_host() {
  if [[ -n "${GITEA_SSH_HOST:-}" ]]; then
    printf '%s\n' "$GITEA_SSH_HOST"
    return 0
  fi
  resolve_gitea_http_host
}

resolve_gitea_root_url() {
  if [[ -n "$GITEA_BASE_URL" ]]; then
    printf '%s\n' "$GITEA_BASE_URL"
    return 0
  fi
  local host
  host="$(resolve_gitea_http_host)"
  if is_truthy "$GITEA_TAILSCALE_HTTPS_ENABLED"; then
    printf 'https://%s/\n' "$host"
    return 0
  fi
  printf 'http://%s:%s/\n' "$host" "$GITEA_HTTP_PORT"
}

wait_for_gitea_version() {
  local root_url="$1"
  local deadline=$((SECONDS + 180))
  while ((SECONDS < deadline)); do
    if curl -fsS "${root_url%/}/api/v1/version" >/tmp/vmctl-gitea-version.json 2>/dev/null; then
      return 0
    fi
    sleep 2
  done
  return 1
}
