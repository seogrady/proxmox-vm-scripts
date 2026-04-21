#!/usr/bin/env bash
set -euo pipefail

missing=()
for package in ca-certificates curl python3; do
  dpkg-query -W -f='${Status}' "$package" 2>/dev/null | grep -q 'install ok installed' || missing+=("$package")
done
if ((${#missing[@]} > 0)); then
  apt-get update
  apt-get install -y "${missing[@]}"
fi

. /etc/os-release
if ! command -v docker >/dev/null 2>&1 || ! docker compose version >/dev/null 2>&1; then
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL "https://download.docker.com/linux/${ID}/gpg" -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc
  cat > /etc/apt/sources.list.d/docker.list <<EOF
deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/${ID} ${VERSION_CODENAME} stable
EOF

  apt-get update
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
fi
systemctl enable --now docker

RESOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STACK_DIR="/opt/media"

. "$RESOURCE_DIR/media.env"
MEDIA_PATH="${MEDIA_PATH:-/media}"

install -d "$STACK_DIR" "$STACK_DIR/config" \
  "$MEDIA_PATH/downloads/complete" "$MEDIA_PATH/downloads/incomplete" \
  "$MEDIA_PATH/movies" "$MEDIA_PATH/tv"
install -m 0644 "$RESOURCE_DIR/docker-compose.media" "$STACK_DIR/docker-compose.yml"
install -m 0644 "$RESOURCE_DIR/media.env" "$STACK_DIR/.env"

random_hex() {
  local bytes="$1"
  python3 - "$bytes" <<'PY'
import secrets
import sys
print(secrets.token_hex(int(sys.argv[1])))
PY
}

ensure_env_value() {
  local file="$1"
  local key="$2"
  local value="$3"
  if grep -q "^${key}=" "$file"; then
    local current
    current="$(grep -E "^${key}=" "$file" | tail -n1 | cut -d= -f2-)"
    if [[ -z "$current" ]]; then
      sed -i "s|^${key}=.*|${key}=${value}|" "$file"
    fi
  else
    printf '%s=%s\n' "$key" "$value" >>"$file"
  fi
}

ensure_env_value "$STACK_DIR/.env" "SECRET_ENCRYPTION_KEY" "$(random_hex 32)"
ensure_env_value "$STACK_DIR/.env" "POSTGRES_USER" "jellystat"
ensure_env_value "$STACK_DIR/.env" "POSTGRES_DB" "jellystat"
ensure_env_value "$STACK_DIR/.env" "POSTGRES_PASSWORD" "$(random_hex 24)"
ensure_env_value "$STACK_DIR/.env" "POSTGRES_IP" "jellystat-db"
ensure_env_value "$STACK_DIR/.env" "POSTGRES_PORT" "5432"
ensure_env_value "$STACK_DIR/.env" "JWT_SECRET" "$(random_hex 32)"

if grep -q '^MEDIA_VPN_CONFIGURED=true$' "$STACK_DIR/.env" && grep -q '^MEDIA_VPN_ENABLED=false$' "$STACK_DIR/.env"; then
  echo "media VPN is configured but incomplete; running qBittorrent without VPN until WireGuard values are set"
fi

if [[ -f "$RESOURCE_DIR/caddyfile.media" ]]; then
  install -d "$STACK_DIR/config/caddy" "$STACK_DIR/config/caddy/ui-index"
  install -m 0644 "$RESOURCE_DIR/caddyfile.media" "$STACK_DIR/config/caddy/Caddyfile"
fi
if [[ -f "$RESOURCE_DIR/media-index.html" ]]; then
  install -d "$STACK_DIR/config/caddy/ui-index"
  install -m 0644 "$RESOURCE_DIR/media-index.html" "$STACK_DIR/config/caddy/ui-index/index.html"
fi
chown -R 1000:1000 "$STACK_DIR/config" "$MEDIA_PATH"

docker compose --env-file "$STACK_DIR/.env" -f "$STACK_DIR/docker-compose.yml" pull
docker compose --env-file "$STACK_DIR/.env" -f "$STACK_DIR/docker-compose.yml" up -d --remove-orphans
