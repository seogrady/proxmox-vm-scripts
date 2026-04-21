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
import urllib.parse
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


def request(method, url, api_key, payload=None, allow=(400, 409)):
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
        if err.code in allow:
            return None
        raise


def parse_root_and_base(url):
    parsed = urllib.parse.urlparse(url)
    root = f"{parsed.scheme}://{parsed.netloc}"
    base = parsed.path.rstrip("/")
    if base == "/":
        base = ""
    return root, base


def detect_api_base(name, configured_url, api_key):
    root, configured_base = parse_root_and_base(configured_url)
    for base in [configured_base, ""]:
        for _ in range(30):
            try:
                request("GET", f"{root}{base}/api/v3/system/status", api_key, allow=())
                return root, base
            except Exception:
                time.sleep(2)
    raise RuntimeError(f"{name} did not become ready at {configured_url}")


def ensure_ui_base(url, api_key, desired_base):
    ui = request("GET", f"{url}/api/v3/config/ui", api_key, allow=())
    if not ui:
        return
    normalized = desired_base if desired_base.startswith("/") else f"/{desired_base}"
    if normalized == "/" or normalized == "":
        normalized = ""
    if ui.get("urlBase") == normalized:
        return
    payload = {
        "firstDayOfWeek": ui.get("firstDayOfWeek", 0),
        "calendarWeekColumnHeader": ui.get("calendarWeekColumnHeader", "Wed"),
        "shortDateFormat": ui.get("shortDateFormat", "MMM D YYYY"),
        "longDateFormat": ui.get("longDateFormat", "dddd, MMMM D YYYY"),
        "timeFormat": ui.get("timeFormat", "h(:mm)tt"),
        "showRelativeDates": ui.get("showRelativeDates", True),
        "enableColorImpairedMode": ui.get("enableColorImpairedMode", False),
        "theme": ui.get("theme", "auto"),
        "uiLanguage": ui.get("uiLanguage", "en"),
        "weekColumnHeader": ui.get("weekColumnHeader", "ddd"),
        "movieRuntimeFormat": ui.get("movieRuntimeFormat", "Hours"),
        "showReleaseDate": ui.get("showReleaseDate", False),
        "sendAnonymousUsageData": ui.get("sendAnonymousUsageData", False),
        "urlBase": normalized,
    }
    request("PUT", f"{url}/api/v3/config/ui", api_key, payload, allow=(400, 409))


def app_base(url, discovered_base):
    root, _ = parse_root_and_base(url)
    return f"{root}{discovered_base}"


def ensure_prowlarr_app_sync(prowlarr_url, prowlarr_key, arr_name, arr_url, arr_key):
    apps = request("GET", f"{prowlarr_url}/api/v1/applications", prowlarr_key, allow=()) or []
    if any(app.get("name") == arr_name for app in apps):
        return
    payload = {
        "name": arr_name,
        "syncLevel": "fullSync",
        "implementation": arr_name,
        "configContract": f"{arr_name}Settings",
        "enable": True,
        "fields": [
            {"name": "prowlarrUrl", "value": prowlarr_url},
            {"name": "baseUrl", "value": arr_url},
            {"name": "apiKey", "value": arr_key},
            {"name": "syncCategories", "value": [5000, 5030, 5040]},
        ],
    }
    request("POST", f"{prowlarr_url}/api/v1/applications", prowlarr_key, payload, allow=(400, 409))


def ensure_indexer_sync_clients(prowlarr_url, prowlarr_key):
    request("POST", f"{prowlarr_url}/api/v1/indexer/sync", prowlarr_key, {}, allow=(400, 409))


def wait_app(name, url, api_key):
    for _ in range(60):
        try:
            request("GET", f"{url}/api/v3/system/status", api_key, allow=())
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
        "base": os.environ.get("SONARR_BASE_URL", "/sonarr"),
        "root": "/media/tv",
        "category": "tv",
    },
    "radarr": {
        "url": os.environ.get("RADARR_URL", "http://radarr:7878"),
        "base": os.environ.get("RADARR_BASE_URL", "/radarr"),
        "root": "/media/movies",
        "category": "movies",
    },
}

resolved = {}
for app, cfg in apps.items():
    key = read_api_key(app)
    root, discovered_base = detect_api_base(app, cfg["url"], key)
    api_url = f"{root}{discovered_base}"
    ensure_root_folder(api_url, key, cfg["root"])
    ensure_qbittorrent_download_client(app, api_url, key, cfg["category"])
    ensure_ui_base(api_url, key, cfg["base"])
    resolved[app] = {"url": app_base(cfg["url"], cfg["base"]), "key": key}

prowlarr_url = os.environ.get("PROWLARR_URL", "http://localhost:9696")
prowlarr_base = os.environ.get("PROWLARR_BASE_URL", "/prowlarr")
prowlarr_key = read_api_key("prowlarr")
prowlarr_root, prowlarr_discovered_base = detect_api_base("prowlarr", prowlarr_url, prowlarr_key)
prowlarr_api = f"{prowlarr_root}{prowlarr_discovered_base}"
ensure_ui_base(prowlarr_api, prowlarr_key, prowlarr_base)

for app_name, values in resolved.items():
    ensure_prowlarr_app_sync(
        prowlarr_api,
        prowlarr_key,
        app_name.capitalize(),
        values["url"],
        values["key"],
    )
ensure_indexer_sync_clients(prowlarr_api, prowlarr_key)
PY
