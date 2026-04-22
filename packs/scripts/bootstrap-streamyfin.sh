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

if ! service_enabled "jellyfin"; then
  exit 0
fi

python3 <<'PY'
import json
import os
import sys
import time
import urllib.error
import urllib.request

PLUGIN_ID = "1e9e5d386e6746158719e98a5c34f004"
BASE_URL = "http://127.0.0.1:8096"
ADMIN_USER = os.environ.get("JELLYFIN_ADMIN_USER", "admin")
ADMIN_PASSWORD = os.environ.get("JELLYFIN_ADMIN_PASSWORD", "")
SEERR_URL = (os.environ.get("JELLYSEERR_INTERNAL_URL") or "http://jellyseerr:5055").rstrip("/")


def request_json(method: str, path: str, payload=None, token=None, allow=(200, 204)):
    url = f"{BASE_URL}{path}"
    body = None
    headers = {
        "Content-Type": "application/json",
        "Authorization": 'MediaBrowser Client="vmctl", Device="bootstrap", DeviceId="vmctl-streamyfin", Version="1.0"',
    }
    if token:
        headers["X-Emby-Token"] = token
    if payload is not None:
        body = json.dumps(payload).encode("utf-8")
    req = urllib.request.Request(url, data=body, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=20) as response:
            raw = response.read().decode("utf-8")
            return json.loads(raw) if raw else None
    except urllib.error.HTTPError as err:
        if err.code in allow:
            return None
        raise


for _ in range(120):
    try:
        request_json("GET", "/System/Info/Public", allow=())
        break
    except Exception:
        time.sleep(2)
else:
    raise RuntimeError(f"jellyfin did not become ready at {BASE_URL}")

auth = request_json(
    "POST",
    "/Users/AuthenticateByName",
    {"Username": ADMIN_USER, "Pw": ADMIN_PASSWORD},
    allow=(),
)
token = auth["AccessToken"]

config = None
for _ in range(120):
    try:
        config = request_json("GET", f"/Plugins/{PLUGIN_ID}/Configuration", token=token, allow=())
        if config:
            break
    except urllib.error.HTTPError as err:
        if err.code != 404:
            raise
    time.sleep(2)
if config is None:
    print("warning: streamyfin plugin configuration endpoint unavailable; skipping config patch")
    sys.exit(0)

settings = config.setdefault("Config", {}).setdefault("settings", {})
seerr = settings.setdefault("seerrServerUrl", {})
hidden = settings.setdefault("hiddenLibraries", {})

changed = False
if seerr.get("value") != SEERR_URL:
    seerr["value"] = SEERR_URL
    changed = True
if hidden.get("value") != []:
    hidden["value"] = []
    changed = True

if changed:
    try:
        request_json(
            "POST",
            f"/Plugins/{PLUGIN_ID}/Configuration",
            config,
            token=token,
            allow=(),
        )
    except urllib.error.HTTPError as err:
        if err.code >= 500:
            print(f"warning: streamyfin configuration patch failed ({err.code}); leaving defaults")
        else:
            raise
PY
