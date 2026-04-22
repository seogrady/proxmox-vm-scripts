#!/usr/bin/env bash
set -euo pipefail

RESOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STACK_DIR="/opt/media"
ENV_FILE="$STACK_DIR/.env"
COMPOSE_FILE="$STACK_DIR/docker-compose.yml"

if [[ ! -f "$ENV_FILE" || ! -f "$COMPOSE_FILE" ]]; then
  exit 0
fi

. "$ENV_FILE"
HOMARR_USER="${HOMARR_USER:-${JELLYFIN_ADMIN_USER:-admin}}"
HOMARR_PASSWORD="${HOMARR_PASSWORD:-${JELLYFIN_ADMIN_PASSWORD:-}}"
MEDIA_SERVICES_CSV="${MEDIA_SERVICES:-}"

service_enabled() {
  local name="$1"
  case ",${MEDIA_SERVICES_CSV}," in
    *,"$name",*) return 0 ;;
    *) return 1 ;;
  esac
}

if ! service_enabled "homarr"; then
  exit 0
fi

if [[ -z "$HOMARR_PASSWORD" ]]; then
  exit 0
fi

compose() {
  docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE" "$@"
}

run_homarr_cli() {
  local -a cmd=(
    docker compose --env-file "$ENV_FILE" -f "$COMPOSE_FILE"
    exec -T homarr node /app/apps/cli/cli.cjs "$@"
  )
  timeout 10 "${cmd[@]}" >/dev/null 2>&1 || {
    local rc=$?
    if [[ "$rc" -ne 124 ]]; then
      return "$rc"
    fi
  }
}

wait_for_homarr() {
  local retries=60
  while ((retries > 0)); do
    if curl -fsS "http://127.0.0.1:7575/" >/dev/null 2>&1; then
      return 0
    fi
    retries=$((retries - 1))
    sleep 2
  done
  return 1
}

homarr_db_query() {
  local query="$1"
  python3 - "$query" <<'PY'
import sqlite3
import sys

query = sys.argv[1]
con = sqlite3.connect('/opt/media/config/homarr/db/db.sqlite')
cur = con.cursor()
cur.execute(query)
row = cur.fetchone()
if row and row[0] is not None:
    print(row[0])
PY
}

user_exists() {
  local username="$1"
  local count
  count="$(homarr_db_query "SELECT COUNT(1) FROM user WHERE provider='credentials' AND name='${username}';")"
  [[ "${count:-0}" != "0" ]]
}

first_user_name() {
  homarr_db_query "SELECT name FROM user WHERE provider='credentials' ORDER BY rowid LIMIT 1;"
}

compose up -d homarr
wait_for_homarr

if ! user_exists "$HOMARR_USER"; then
  run_homarr_cli recreate-admin --username "$HOMARR_USER"
fi

TARGET_USER="$HOMARR_USER"
if ! user_exists "$TARGET_USER"; then
  TARGET_USER="$(first_user_name || true)"
fi

if [[ -z "$TARGET_USER" ]]; then
  echo "homarr bootstrap failed: no credentials user exists after recreate-admin" >&2
  exit 1
fi

run_homarr_cli users update-password --username "$TARGET_USER" --password "$HOMARR_PASSWORD"

seed_homarr_dashboard() {
  python3 <<'PY'
import json
import os
import pathlib
import sqlite3
import time
import urllib.parse

db_path = pathlib.Path("/opt/media/config/homarr/db/db.sqlite")
for _ in range(180):
    if db_path.exists():
        break
    time.sleep(2)
if not db_path.exists():
    raise RuntimeError(f"homarr database not found at {db_path}")

con = sqlite3.connect(db_path)
con.execute("PRAGMA foreign_keys = ON")
cur = con.cursor()

def columns(table):
    cur.execute(f"PRAGMA table_info({table})")
    return [row[1] for row in cur.fetchall()]

def has_column(table, column):
    return column in columns(table)

def upsert(table, key_column, row):
    table_columns = [column for column in row if column in columns(table)]
    if key_column not in table_columns:
        return
    values = [row[column] for column in table_columns]
    assignments = ", ".join(
        f"{column}=excluded.{column}" for column in table_columns if column != key_column
    )
    if assignments:
        sql = (
            f"INSERT INTO {table} ({', '.join(table_columns)}) "
            f"VALUES ({', '.join('?' for _ in table_columns)}) "
            f"ON CONFLICT({key_column}) DO UPDATE SET {assignments}"
        )
    else:
        sql = (
            f"INSERT INTO {table} ({', '.join(table_columns)}) "
            f"VALUES ({', '.join('?' for _ in table_columns)}) "
            f"ON CONFLICT({key_column}) DO NOTHING"
        )
    cur.execute(sql, values)

def first_value(query, params=()):
    cur.execute(query, params)
    row = cur.fetchone()
    return row[0] if row else None

def json_super(value):
    return json.dumps({"json": value}, separators=(",", ":"))

def external_root():
    jellyfin_url = os.environ.get("JELLYFIN_URL", "http://media-stack.home.arpa:8096")
    parsed = urllib.parse.urlparse(jellyfin_url if "://" in jellyfin_url else f"http://{jellyfin_url}")
    scheme = parsed.scheme or "http"
    hostname = parsed.hostname or parsed.netloc or "media-stack.home.arpa"
    return scheme, hostname

scheme, hostname = external_root()
services = {
    "jellyfin": {
        "title": "Jellyfin",
        "description": "Media library",
        "port": 8096,
        "icon": "jellyfin",
    },
    "sonarr": {
        "title": "Sonarr",
        "description": "TV automation",
        "port": 8989,
        "icon": "sonarr",
    },
    "radarr": {
        "title": "Radarr",
        "description": "Movie automation",
        "port": 7878,
        "icon": "radarr",
    },
    "prowlarr": {
        "title": "Prowlarr",
        "description": "Indexer management",
        "port": 9696,
        "icon": "prowlarr",
    },
    "qbittorrent-vpn": {
        "title": "qBittorrent",
        "description": "Downloads",
        "port": 8080,
        "icon": "qbittorrent",
    },
    "jellyseerr": {
        "title": "Jellyseerr",
        "description": "Requests",
        "port": 5055,
        "icon": "jellyseerr",
    },
    "bazarr": {
        "title": "Bazarr",
        "description": "Subtitles",
        "port": 6767,
        "icon": "bazarr",
    },
    "jellystat": {
        "title": "Jellystat",
        "description": "Library analytics",
        "port": 3000,
        "icon": "jellystat",
    },
}

enabled = {
    service.strip()
    for service in os.environ.get("MEDIA_SERVICES", "").split(",")
    if service.strip()
}
tiles = [name for name in services if name in enabled]
if not tiles:
    con.commit()
    con.close()
    raise SystemExit(0)

cur.execute("SELECT id FROM user WHERE provider='credentials' ORDER BY rowid LIMIT 1")
user_row = cur.fetchone()
if user_row is None:
    raise RuntimeError("homarr bootstrap requires a credentials user")
user_id = user_row[0]

board_id = first_value("SELECT id FROM board ORDER BY rowid LIMIT 1") or "vmctl-media-board"
layout_id = f"{board_id}-layout"
section_id = f"{board_id}-apps"

upsert(
    "board",
    "id",
    {
        "id": board_id,
        "name": "Media Stack",
        "is_public": 0,
        "creator_id": user_id,
        "page_title": "Media Stack",
        "meta_title": "Media Stack",
        "disable_status": 0,
        "item_radius": 0,
    },
)
upsert(
    "layout",
    "id",
    {
        "id": layout_id,
        "name": "Default",
        "board_id": board_id,
        "column_count": 4,
        "breakpoint": 0,
    },
)
upsert(
    "section",
    "id",
    {
        "id": section_id,
        "board_id": board_id,
        "kind": "apps",
        "x_offset": 0,
        "y_offset": 0,
        "name": "Applications",
        "options": json_super({}),
    },
)
upsert(
    "section_layout",
    "section_id",
    {
        "section_id": section_id,
        "layout_id": layout_id,
        "parent_section_id": None,
        "x_offset": 0,
        "y_offset": 0,
        "width": 4,
        "height": 4,
    },
)

for index, service_name in enumerate(tiles):
    spec = services[service_name]
    app_id = f"{board_id}-{service_name}-app"
    item_id = f"{board_id}-{service_name}-tile"
    href = f"{scheme}://{hostname}:{spec['port']}"
    icon_url = f"https://cdn.jsdelivr.net/gh/homarr-labs/dashboard-icons/svg/{spec['icon']}.svg"
    upsert(
        "app",
        "id",
        {
            "id": app_id,
            "name": spec["title"],
            "description": spec["description"],
            "icon_url": icon_url,
            "href": href,
            "ping_url": href,
        },
    )
    upsert(
        "item",
        "id",
        {
            "id": item_id,
            "board_id": board_id,
            "kind": "app",
            "options": json_super(
                {
                    "appId": app_id,
                    "openInNewTab": True,
                    "pingEnabled": False,
                    "showTitle": True,
                    "layout": "horizontal",
                    "descriptionDisplayMode": "hidden",
                }
            ),
            "advanced_options": json_super({}),
        },
    )
    upsert(
        "item_layout",
        "item_id",
        {
            "item_id": item_id,
            "section_id": section_id,
            "layout_id": layout_id,
            "x_offset": index,
            "y_offset": 0,
            "width": 1,
            "height": 1,
        },
    )

board_setting_key = None
board_setting_value = None
for key_column in ("name", "key"):
    if has_column("serverSetting", key_column):
        board_setting_key = key_column
        break
for value_column in ("value", "data", "config"):
    if has_column("serverSetting", value_column):
        board_setting_value = value_column
        break
if board_setting_key and board_setting_value:
    cur.execute(
        f"SELECT {board_setting_value} FROM serverSetting WHERE {board_setting_key} = ? LIMIT 1",
        ("board",),
    )
    row = cur.fetchone()
    if row is not None and row[0]:
        try:
            payload = json.loads(row[0])
        except json.JSONDecodeError:
            payload = {}
    else:
        payload = {}
    payload["homeBoardId"] = board_id
    payload["mobileHomeBoardId"] = board_id
    cur.execute(
        f"UPDATE serverSetting SET {board_setting_value} = ? WHERE {board_setting_key} = ?",
        (json.dumps(payload), "board"),
    )

if has_column("user", "home_board_id"):
    cur.execute(
        "UPDATE user SET home_board_id = ? WHERE provider = 'credentials'",
        (board_id,),
    )
if has_column("user", "mobile_home_board_id"):
    cur.execute(
        "UPDATE user SET mobile_home_board_id = ? WHERE provider = 'credentials'",
        (board_id,),
    )

if has_column("onboarding", "step"):
    cur.execute(
        "UPDATE onboarding SET previous_step = step, step = 'completed'",
    )

con.commit()
con.close()
PY
}

seed_homarr_dashboard

python3 - <<'PY'
import sqlite3

con = sqlite3.connect('/opt/media/config/homarr/db/db.sqlite')
cur = con.cursor()
cur.execute('SELECT id FROM onboarding LIMIT 1')
row = cur.fetchone()
if row is None:
    cur.execute("INSERT INTO onboarding (id, step, previous_step) VALUES ('vmctl-onboarding', 'completed', 'start')")
else:
    cur.execute("UPDATE onboarding SET previous_step = step, step = 'completed' WHERE id = ?", (row[0],))
con.commit()
PY
