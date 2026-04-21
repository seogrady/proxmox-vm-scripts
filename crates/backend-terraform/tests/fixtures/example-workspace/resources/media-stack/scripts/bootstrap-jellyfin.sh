#!/usr/bin/env bash
set -euo pipefail

STACK_DIR="/opt/media"
ENV_FILE="$STACK_DIR/.env"

if [[ -f "$ENV_FILE" ]]; then
  set -a
  . "$ENV_FILE"
  set +a
fi

python3 <<'PY'
import json
import os
import time
import urllib.error
import urllib.request

base = os.environ.get("JELLYFIN_URL") or "http://localhost:8096"
user = os.environ.get("JELLYFIN_ADMIN_USER") or "admin"
password = os.environ.get("JELLYFIN_ADMIN_PASSWORD") or ""


def call(method, path, payload=None, token=None, allow=(200, 204)):
    data = None
    headers = {
        "Content-Type": "application/json",
        "Authorization": 'MediaBrowser Client="vmctl", Device="bootstrap", DeviceId="vmctl", Version="1.0"',
    }
    if token:
        headers["X-Emby-Token"] = token
    if payload is not None:
        data = json.dumps(payload).encode()
    req = urllib.request.Request(base + path, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=20) as response:
            body = response.read().decode()
            if body:
                return json.loads(body)
            return None
    except urllib.error.HTTPError as err:
        if err.code in allow:
            return None
        raise


def try_call(method, path, payload=None, token=None):
    try:
        return call(method, path, payload, token, allow=(200, 204))
    except urllib.error.HTTPError:
        return None


for _ in range(90):
    try:
        call("GET", "/System/Info/Public")
        break
    except Exception:
        time.sleep(2)
else:
    raise RuntimeError(f"Jellyfin did not become ready at {base}")

try:
    call("POST", "/Startup/Configuration", {
        "UICulture": "en-US",
        "MetadataCountryCode": "US",
        "PreferredMetadataLanguage": "en",
    }, allow=(200, 204, 400))
    if password:
        call("POST", "/Startup/User", {"Name": user, "Password": password}, allow=(200, 204, 400))
    call("POST", "/Startup/RemoteAccess", {
        "EnableRemoteAccess": True,
        "EnableAutomaticPortMapping": False,
    }, allow=(200, 204, 400))
    call("POST", "/Startup/Complete", allow=(200, 204, 400))
except urllib.error.HTTPError:
    pass

token = None
auth = None
if password:
    auth = try_call("POST", "/Users/AuthenticateByName", {"Username": user, "Pw": password})
if not auth:
    startup_user = try_call("GET", "/Startup/User")
    existing_user = startup_user.get("Name") if startup_user else None
    if existing_user:
        auth = try_call("POST", "/Users/AuthenticateByName", {"Username": existing_user, "Pw": ""})
token = auth.get("AccessToken") if auth else None

if token:
    for name, path, collection_type in [
        ("Movies", "/media/movies", "movies"),
        ("TV", "/media/tv", "tvshows"),
    ]:
        os.makedirs(path, exist_ok=True)
        call("POST", "/Library/VirtualFolders", {
            "Name": name,
            "CollectionType": collection_type,
            "Paths": [path],
            "LibraryOptions": {},
        }, token=token, allow=(200, 204, 400))
PY

jellyfin_tailscale_https_enabled="${JELLYFIN_TAILSCALE_HTTPS_ENABLED:-true}"
jellyfin_tailscale_https_target="${JELLYFIN_TAILSCALE_HTTPS_TARGET:-http://127.0.0.1:8096}"

if [[ "${jellyfin_tailscale_https_enabled,,}" == "false" || "${jellyfin_tailscale_https_enabled}" == "0" ]]; then
  if command -v tailscale >/dev/null 2>&1; then
    tailscale serve reset >/dev/null 2>&1 || true
  fi
  exit 0
fi

if ! command -v tailscale >/dev/null 2>&1; then
  echo "tailscale not installed; skipping Jellyfin tailnet HTTPS exposure"
  exit 0
fi

if ! tailscale status --json >/tmp/vmctl-tailscale-status.json 2>/dev/null; then
  echo "tailscale is not authenticated; skipping Jellyfin tailnet HTTPS exposure"
  exit 0
fi

tailscale_ready="$(python3 <<'PY'
import json
try:
    with open("/tmp/vmctl-tailscale-status.json", encoding="utf-8") as handle:
        status = json.load(handle)
    print(1 if status.get("BackendState") in {"Running", "Starting"} else 0)
except Exception:
    print(0)
PY
)"
if [[ "$tailscale_ready" != "1" ]]; then
  echo "tailscale backend is not running; skipping Jellyfin tailnet HTTPS exposure"
  exit 0
fi

tailscale serve --yes --bg "$jellyfin_tailscale_https_target"
