#!/usr/bin/env bash
set -euo pipefail

STACK_DIR="/opt/media"
ENV_FILE="$STACK_DIR/.env"

if [[ ! -f "$ENV_FILE" ]]; then
  exit 0
fi

set -a
. "$ENV_FILE"
set +a

MEDIA_SERVICES_CSV="${MEDIA_SERVICES:-}"

service_enabled() {
  local name="$1"
  case ",${MEDIA_SERVICES_CSV}," in
    *,"$name",*) return 0 ;;
    *) return 1 ;;
  esac
}

python3 <<'PY'
import json
import os
import subprocess
import urllib.error
import urllib.request

JELLYFIN_BASE = "http://127.0.0.1:8096"
STREAMYFIN_ID = "1e9e5d386e6746158719e98a5c34f004"
JELLIO_ID = "e874be83fe364568abacf5ce0574b409"
ADMIN_USER = os.environ.get("JELLYFIN_ADMIN_USER", "admin")
ADMIN_PASSWORD = os.environ.get("JELLYFIN_ADMIN_PASSWORD", "")


def get_json(url: str):
    with urllib.request.urlopen(url, timeout=20) as response:
        return json.loads(response.read().decode("utf-8"))


def jellyfin_token() -> str:
    headers = {
        "Content-Type": "application/json",
        "Authorization": 'MediaBrowser Client="vmctl", Device="validate", DeviceId="vmctl-validate", Version="1.0"',
    }
    req = urllib.request.Request(
        f"{JELLYFIN_BASE}/Users/AuthenticateByName",
        data=json.dumps({"Username": ADMIN_USER, "Pw": ADMIN_PASSWORD}).encode("utf-8"),
        headers=headers,
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=20) as response:
        payload = json.loads(response.read().decode("utf-8"))
    return payload["AccessToken"]


if "jellyfin" in (os.environ.get("MEDIA_SERVICES", "")):
    get_json(f"{JELLYFIN_BASE}/System/Info/Public")
    token = jellyfin_token()
    headers = {
        "Authorization": 'MediaBrowser Client="vmctl", Device="validate", DeviceId="vmctl-validate", Version="1.0"',
        "X-Emby-Token": token,
    }
    req = urllib.request.Request(f"{JELLYFIN_BASE}/Plugins", headers=headers, method="GET")
    with urllib.request.urlopen(req, timeout=20) as response:
        plugins = json.loads(response.read().decode("utf-8"))
    ids = {plugin.get("Id") for plugin in plugins}
    if STREAMYFIN_ID not in ids:
        raise RuntimeError("streamyfin plugin not installed")
    if JELLIO_ID not in ids:
        raise RuntimeError("jellio plugin not installed")

if "meilisearch" in (os.environ.get("MEDIA_SERVICES", "")):
    with urllib.request.urlopen("http://127.0.0.1:7700/health", timeout=20) as response:
        if response.status != 200:
            raise RuntimeError("meilisearch health check failed")

if "jellysearch" in (os.environ.get("MEDIA_SERVICES", "")):
    with urllib.request.urlopen("http://127.0.0.1:5000/Items?SearchTerm=test&Limit=1", timeout=20) as response:
        if response.status != 200:
            raise RuntimeError("jellysearch integration check failed")

for key in ("JELLIO_STREMIO_MANIFEST_URL_LAN", "JELLIO_STREMIO_MANIFEST_URL_TAILNET"):
    value = (os.environ.get(key) or "").strip()
    if not value:
        continue
    try:
        manifest = get_json(value)
        if "resources" not in manifest:
            raise RuntimeError(f"{key} does not point to a valid stremio manifest")
    except (urllib.error.HTTPError, urllib.error.URLError) as err:
        print(f"warning: unable to validate {key}: {err}")

if os.environ.get("TAILSCALE_HTTPS_ENABLED", "true").lower() not in {"false", "0"}:
    try:
        status_raw = subprocess.check_output(["tailscale", "status", "--json"], text=True)
        status = json.loads(status_raw)
        if status.get("BackendState") not in {"Running", "Starting"}:
            raise RuntimeError("tailscale backend is not running")
        serve_status = subprocess.check_output(["tailscale", "serve", "status"], text=True)
        if "http://127.0.0.1:80" not in serve_status:
            raise RuntimeError("tailscale serve target mismatch")
    except FileNotFoundError:
        raise RuntimeError("tailscale binary is not installed")
PY
