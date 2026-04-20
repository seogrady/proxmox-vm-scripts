#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Expose the Proxmox Web UI privately inside the tailnet with Tailscale Serve.

This serves https://<proxmox-node>.<tailnet>.ts.net/ to tailnet clients and
proxies it to the local Proxmox UI at https://localhost:8006. It does not use
Tailscale Funnel and does not expose the UI to the public internet.

Usage:
  scripts/proxmox-host-serve-ui.sh [options]

Options:
  --backend URL       Local Proxmox UI URL. Default: https+insecure://localhost:8006
  --https-port PORT   Tailnet HTTPS port. Default: Tailscale Serve default, 443.
  --wait-seconds N    Max time to wait for Tailscale Serve consent. Default: 120.
  --status           Show current Tailscale Serve status.
  --disable          Disable this Tailscale Serve mapping.
  -h, --help         Show this help.

Examples:
  sudo scripts/proxmox-host-serve-ui.sh
  sudo scripts/proxmox-host-serve-ui.sh --status
  sudo scripts/proxmox-host-serve-ui.sh --disable
EOF
}

backend="https+insecure://localhost:8006"
https_port=""
mode="enable"
wait_seconds=120

while [[ $# -gt 0 ]]; do
  case "$1" in
    --backend)
      backend="${2:-}"
      shift 2
      ;;
    --https-port)
      https_port="${2:-}"
      shift 2
      ;;
    --wait-seconds)
      wait_seconds="${2:-}"
      shift 2
      ;;
    --status)
      mode="status"
      shift
      ;;
    --disable)
      mode="disable"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ "$(id -u)" -ne 0 ]]; then
  echo "must run as root on the Proxmox host" >&2
  exit 1
fi

if ! command -v tailscale >/dev/null 2>&1; then
  echo "tailscale is not installed; run scripts/proxmox-host-tailscale.sh first" >&2
  exit 1
fi

if [[ "$mode" == "status" ]]; then
  tailscale serve status
  exit 0
fi

if ! [[ "$wait_seconds" =~ ^[0-9]+$ ]]; then
  echo "--wait-seconds must be a non-negative integer" >&2
  exit 1
fi

args=(serve)
if [[ -n "$https_port" ]]; then
  args+=(--https "$https_port")
fi

if [[ "$mode" == "disable" ]]; then
  args+=(--yes "$backend" off)
  tailscale "${args[@]}"
  tailscale serve status
  exit 0
fi

args+=(--yes --bg "$backend")
if [[ "$wait_seconds" -gt 0 ]] && command -v timeout >/dev/null 2>&1; then
  if timeout --foreground "$wait_seconds" tailscale "${args[@]}"; then
    :
  else
    code="$?"
    if [[ "$code" -eq 124 ]]; then
      echo "tailscale serve did not finish within ${wait_seconds}s." >&2
      echo "If a Tailscale consent URL was printed above, open it, approve Serve, then rerun this script." >&2
      exit 1
    fi
    exit "$code"
  fi
else
  tailscale "${args[@]}"
fi

dns_name="$(tailscale status --json 2>/dev/null | sed -n 's/.*"DNSName":[[:space:]]*"\([^"]*\)".*/\1/p' | head -1)"
dns_name="${dns_name%.}"

cat <<EOF

Proxmox Web UI is now served privately over Tailscale.

Open:
  https://${dns_name:-<your-proxmox-node>.<tailnet>.ts.net}/

Status:
EOF
tailscale serve status
