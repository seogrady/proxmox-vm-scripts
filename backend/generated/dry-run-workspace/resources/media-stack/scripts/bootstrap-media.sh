#!/usr/bin/env bash
set -euo pipefail

apt-get update
apt-get install -y docker.io docker-compose-plugin
systemctl enable --now docker

RESOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STACK_DIR="/opt/media"

install -d "$STACK_DIR" "$STACK_DIR/config" /media
install -m 0644 "$RESOURCE_DIR/docker-compose.media" "$STACK_DIR/docker-compose.yml"
install -m 0644 "$RESOURCE_DIR/media.env" "$STACK_DIR/.env"

docker compose --env-file "$STACK_DIR/.env" -f "$STACK_DIR/docker-compose.yml" pull
docker compose --env-file "$STACK_DIR/.env" -f "$STACK_DIR/docker-compose.yml" up -d
