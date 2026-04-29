#!/usr/bin/env bash
set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$SCRIPT_DIR/gitea-common.sh"
load_gitea_env

if [[ "$GITEA_ENABLED" != "true" ]]; then
  echo "gitea feature disabled"
  exit 0
fi

missing=()
for package in ca-certificates curl git jq openssh-client openssh-server python3 sqlite3; do
  dpkg-query -W -f='${Status}' "$package" 2>/dev/null | grep -q 'install ok installed' || missing+=("$package")
done
if ((${#missing[@]} > 0)); then
  apt-get update
  apt-get install -y "${missing[@]}"
fi

ensure_gitea_user() {
  if id gitea >/dev/null 2>&1; then
    return 0
  fi
  groupadd --system gitea
  useradd --system --home /var/lib/gitea --create-home --shell /usr/sbin/nologin --gid gitea gitea
}

install_gitea_binary_release() {
  local arch version url
  case "$(uname -m)" in
    x86_64) arch="amd64" ;;
    aarch64|arm64) arch="arm64" ;;
    *)
      echo "unsupported architecture for gitea binary install: $(uname -m)"
      exit 1
      ;;
  esac

  version="${GITEA_VERSION:-1.25.5}"
  url="https://dl.gitea.com/gitea/${version}/gitea-${version}-linux-${arch}"
  curl -fsSL "$url" -o /usr/local/bin/gitea
  chmod 0755 /usr/local/bin/gitea
}

ensure_gitea_systemd_unit() {
  cat > /etc/systemd/system/gitea.service <<'EOF_UNIT'
[Unit]
Description=Gitea
After=network.target

[Service]
Type=simple
User=gitea
Group=gitea
WorkingDirectory=/var/lib/gitea
ExecStart=/usr/local/bin/gitea web --config /etc/gitea/conf/app.ini
Restart=always
RestartSec=2s
Environment=USER=gitea HOME=/var/lib/gitea GITEA_WORK_DIR=/var/lib/gitea

[Install]
WantedBy=multi-user.target
EOF_UNIT
  systemctl daemon-reload
}

if ! command -v gitea >/dev/null 2>&1; then
  if apt-cache show gitea >/dev/null 2>&1; then
    apt-get install -y gitea
  else
    ensure_gitea_user
    install_gitea_binary_release
    ensure_gitea_systemd_unit
  fi
fi

if systemctl list-unit-files | grep -q '^gitea\.service'; then
  ensure_gitea_user
fi

if systemctl list-unit-files | grep -q '^ssh\.service'; then
  systemctl enable --now ssh
elif systemctl list-unit-files | grep -q '^sshd\.service'; then
  systemctl enable --now sshd
fi

gitea_user="gitea"
if ! id "$gitea_user" >/dev/null 2>&1; then
  echo "missing gitea system user after package install"
  exit 1
fi

install -d -m 0750 -o "$gitea_user" -g "$gitea_user" "$GITEA_DATA_ROOT"
install -d -m 0750 -o "$gitea_user" -g "$gitea_user" "$GITEA_DATA_ROOT/custom"
install -d -m 0750 -o "$gitea_user" -g "$gitea_user" "$GITEA_DATA_ROOT/data"
install -d -m 0750 -o "$gitea_user" -g "$gitea_user" "$GITEA_DATA_ROOT/log"
install -d -m 0750 -o "$gitea_user" -g "$gitea_user" "$GITEA_REPO_ROOT"
install -d -m 0750 -o "$gitea_user" -g "$gitea_user" /etc/gitea
install -d -m 0750 -o "$gitea_user" -g "$gitea_user" /etc/gitea/conf
install -d -m 0700 -o root -g root /var/lib/gitea/.vmctl

secret_file=/var/lib/gitea/.vmctl/secret_key
internal_token_file=/var/lib/gitea/.vmctl/internal_token
if [[ ! -s "$secret_file" ]]; then
  tr -dc 'a-f0-9' </dev/urandom | head -c 64 >"$secret_file"
fi
if [[ ! -s "$internal_token_file" ]]; then
  tr -dc 'a-f0-9' </dev/urandom | head -c 64 >"$internal_token_file"
fi
chmod 0600 "$secret_file" "$internal_token_file"

gitea_host="$(resolve_gitea_http_host)"
gitea_ssh_host="$(resolve_gitea_ssh_host)"
gitea_root_url="$(resolve_gitea_root_url)"

secret_key="$(cat "$secret_file")"
internal_token="$(cat "$internal_token_file")"

cat > /tmp/vmctl-gitea-app.ini <<EOF_INI
APP_NAME = Gitea
RUN_MODE = prod
RUN_USER = ${gitea_user}
WORK_PATH = ${GITEA_DATA_ROOT}

[database]
DB_TYPE = sqlite3
PATH = ${GITEA_DATA_ROOT}/data/gitea.db

[repository]
ROOT = ${GITEA_REPO_ROOT}

[server]
DOMAIN = ${gitea_host}
HTTP_ADDR = 0.0.0.0
HTTP_PORT = ${GITEA_HTTP_PORT}
ROOT_URL = ${gitea_root_url}
DISABLE_SSH = false
SSH_DOMAIN = ${gitea_ssh_host}
SSH_PORT = ${GITEA_SSH_PORT}
START_SSH_SERVER = true
SSH_LISTEN_HOST = 0.0.0.0
SSH_LISTEN_PORT = ${GITEA_SSH_PORT}
OFFLINE_MODE = false

[service]
DISABLE_REGISTRATION = true
REQUIRE_SIGNIN_VIEW = false
ENABLE_CAPTCHA = false

[security]
INSTALL_LOCK = true
SECRET_KEY = ${secret_key}
INTERNAL_TOKEN = ${internal_token}
PASSWORD_HASH_ALGO = pbkdf2

[log]
ROOT_PATH = ${GITEA_DATA_ROOT}/log
MODE = console
LEVEL = Info
EOF_INI
install -m 0640 -o "$gitea_user" -g "$gitea_user" /tmp/vmctl-gitea-app.ini /etc/gitea/conf/app.ini
rm -f /tmp/vmctl-gitea-app.ini

systemctl enable gitea
systemctl restart gitea

if ! wait_for_gitea_version "$gitea_root_url"; then
  echo "gitea service not reachable after bootstrap"
  exit 1
fi

gitea_bin="$(command -v gitea || true)"
if [[ -z "$gitea_bin" ]]; then
  echo "gitea binary not found"
  exit 1
fi

run_gitea_admin_user_command() {
  runuser -u "$gitea_user" -- "$gitea_bin" --config /etc/gitea/conf/app.ini admin user "$@"
}

user_exists="$(python3 - "$GITEA_DATA_ROOT/data/gitea.db" "$GITEA_ADMIN_USER" <<'PY'
import sqlite3
import sys

db_path, user = sys.argv[1:3]
try:
    conn = sqlite3.connect(db_path)
    cur = conn.cursor()
    cur.execute("SELECT 1 FROM user WHERE lower_name = lower(?) LIMIT 1", (user,))
    row = cur.fetchone()
    print("1" if row else "0")
finally:
    try:
        conn.close()
    except Exception:
        pass
PY
)"

if [[ "$user_exists" == "1" ]]; then
  run_gitea_admin_user_command change-password \
    --username "$GITEA_ADMIN_USER" \
    --password "$GITEA_ADMIN_PASSWORD"
else
  run_gitea_admin_user_command create \
    --username "$GITEA_ADMIN_USER" \
    --password "$GITEA_ADMIN_PASSWORD" \
    --email "$GITEA_ADMIN_EMAIL" \
    --admin \
    --must-change-password=false
fi

python3 - "$GITEA_DATA_ROOT/data/gitea.db" "$GITEA_ADMIN_USER" "$GITEA_ADMIN_EMAIL" <<'PY'
import sqlite3
import sys

db_path, user, email = sys.argv[1:4]
conn = sqlite3.connect(db_path)
try:
    cur = conn.cursor()
    cur.execute(
        "UPDATE user SET is_admin = 1, email = ?, must_change_password = 0 WHERE lower_name = lower(?)",
        (email, user),
    )
    if cur.rowcount == 0:
        raise SystemExit("admin user does not exist after provisioning")
    conn.commit()
finally:
    conn.close()
PY

api_base="${gitea_root_url%/}/api/v1"
if ! curl -fsS -u "$GITEA_ADMIN_USER:$GITEA_ADMIN_PASSWORD" "$api_base/user" >/tmp/vmctl-gitea-user.json; then
  echo "gitea login failed for admin user"
  exit 1
fi

key_file="$(mktemp)"
if [[ -f "$GITEA_SSH_KEY_SOURCE" ]]; then
  awk '/^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp256|ecdsa-sha2-nistp384|ecdsa-sha2-nistp521|sk-ssh-ed25519@openssh.com|sk-ecdsa-sha2-nistp256@openssh.com) / {print $0}' "$GITEA_SSH_KEY_SOURCE" >>"$key_file"
fi
if [[ -n "$GITEA_ADMIN_SSH_PUBLIC_KEYS" ]]; then
  printf '%s\n' "$GITEA_ADMIN_SSH_PUBLIC_KEYS" | tr ',' '\n' | awk '/^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp256|ecdsa-sha2-nistp384|ecdsa-sha2-nistp521|sk-ssh-ed25519@openssh.com|sk-ecdsa-sha2-nistp256@openssh.com) / {print $0}' >>"$key_file"
fi
sort -u -o "$key_file" "$key_file"

if [[ -s "$key_file" ]]; then
  python3 - "$api_base" "$GITEA_ADMIN_USER" "$GITEA_ADMIN_PASSWORD" "$key_file" <<'PY'
import base64
import hashlib
import json
import sys
import urllib.error
import urllib.request

api_base, user, password, key_path = sys.argv[1:5]
auth = base64.b64encode(f"{user}:{password}".encode("utf-8")).decode("utf-8")


def request(method, path, payload=None):
    data = None
    headers = {
        "Authorization": f"Basic {auth}",
        "Accept": "application/json",
    }
    if payload is not None:
        data = json.dumps(payload).encode("utf-8")
        headers["Content-Type"] = "application/json"
    req = urllib.request.Request(api_base + path, data=data, method=method, headers=headers)
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            body = resp.read().decode("utf-8", errors="replace")
            return resp.status, body
    except urllib.error.HTTPError as exc:
        return exc.code, exc.read().decode("utf-8", errors="replace")

status, body = request("GET", "/user/keys")
if status != 200:
    raise SystemExit(f"failed to list admin SSH keys via API: {status} {body}")

existing = set()
for item in json.loads(body):
    key = (item or {}).get("key")
    if key:
        existing.add(key.strip())

with open(key_path, encoding="utf-8") as handle:
    keys = [line.strip() for line in handle if line.strip()]

for key in keys:
    if key in existing:
        continue
    title = "vmctl-" + hashlib.sha256(key.encode("utf-8")).hexdigest()[:16]
    status, body = request("POST", "/user/keys", {"title": title, "key": key})
    if status not in (200, 201, 202, 409, 422):
        raise SystemExit(f"failed to add admin SSH key: {status} {body}")
PY
fi
rm -f "$key_file"

echo "gitea bootstrap complete"
echo "web: ${gitea_root_url}"
echo "ssh: ssh://gitea@${gitea_ssh_host}:${GITEA_SSH_PORT}/${GITEA_ADMIN_USER}/<repo>.git"
