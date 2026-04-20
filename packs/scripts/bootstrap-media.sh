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
chown -R 1000:1000 "$STACK_DIR/config" "$MEDIA_PATH"

docker compose --env-file "$STACK_DIR/.env" -f "$STACK_DIR/docker-compose.yml" pull
docker compose --env-file "$STACK_DIR/.env" -f "$STACK_DIR/docker-compose.yml" up -d --remove-orphans
