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
import xml.etree.ElementTree as ET

CONFIG_PATH = os.environ.get("CONFIG_PATH", "/opt/media/config")
VPN_ENABLED = os.environ.get("MEDIA_VPN_ENABLED", "").lower() == "true"
QBIT_HOST = "gluetun" if VPN_ENABLED else "qbittorrent-vpn"
QBIT_PORT = int(os.environ.get("QBITTORRENT_WEBUI_PORT", "8080"))


def read_api_key(app):
    path = os.path.join(CONFIG_PATH, app, "config.xml")
    for _ in range(60):
        if os.path.exists(path):
            root = ET.parse(path).getroot()
            key = root.findtext("ApiKey")
            if key:
                return key
        time.sleep(2)
    raise RuntimeError(f"{app} API key was not created at {path}")


def request(method, url, api_key, payload=None):
    data = None
    headers = {"X-Api-Key": api_key}
    if payload is not None:
        data = json.dumps(payload).encode()
        headers["Content-Type"] = "application/json"
    req = urllib.request.Request(url, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=15) as response:
            body = response.read()
            return json.loads(body.decode() or "null")
    except urllib.error.HTTPError as err:
        if err.code in (400, 409):
            return None
        raise


def wait_app(name, url, api_key):
    for _ in range(60):
        try:
            request("GET", f"{url}/api/v3/system/status", api_key)
            return
        except Exception:
            time.sleep(2)
    raise RuntimeError(f"{name} did not become ready at {url}")


def ensure_root_folder(url, api_key, path):
    existing = request("GET", f"{url}/api/v3/rootfolder", api_key) or []
    if any(item.get("path") == path for item in existing):
        return
    os.makedirs(path, exist_ok=True)
    request("POST", f"{url}/api/v3/rootfolder", api_key, {"path": path})


def ensure_qbittorrent_download_client(app, url, api_key, category):
    existing = request("GET", f"{url}/api/v3/downloadclient", api_key) or []
    for item in existing:
        if item.get("name") == "qBittorrent":
            return
    fields = [
        {"name": "host", "value": QBIT_HOST},
        {"name": "port", "value": QBIT_PORT},
        {"name": "urlBase", "value": ""},
        {"name": "username", "value": ""},
        {"name": "password", "value": ""},
        {"name": "category", "value": category},
        {"name": "recentTvPriority", "value": 0},
        {"name": "olderTvPriority", "value": 0},
        {"name": "initialState", "value": 0},
    ]
    payload = {
        "enable": True,
        "protocol": "torrent",
        "priority": 1,
        "removeCompletedDownloads": True,
        "removeFailedDownloads": True,
        "name": "qBittorrent",
        "implementation": "QBittorrent",
        "configContract": "QBittorrentSettings",
        "fields": fields,
    }
    request("POST", f"{url}/api/v3/downloadclient", api_key, payload)


apps = {
    "sonarr": {
        "url": os.environ.get("SONARR_URL", "http://sonarr:8989"),
        "root": "/media/tv",
        "category": "tv",
    },
    "radarr": {
        "url": os.environ.get("RADARR_URL", "http://radarr:7878"),
        "root": "/media/movies",
        "category": "movies",
    },
}

for app, cfg in apps.items():
    key = read_api_key(app)
    wait_app(app, cfg["url"], key)
    ensure_root_folder(cfg["url"], key, cfg["root"])
    ensure_qbittorrent_download_client(app, cfg["url"], key, cfg["category"])
PY
