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

wait_for_homarr() {
  local retries=60
  while ((retries > 0)); do
    if compose exec -T homarr sh -lc 'node /app/apps/cli/cli.cjs users list >/tmp/homarr-users.txt 2>/dev/null'; then
      return 0
    fi
    retries=$((retries - 1))
    sleep 2
  done
  return 1
}

first_user_name() {
  compose exec -T homarr sh -lc 'node /app/apps/cli/cli.cjs users list 2>/dev/null' \
    | awk 'NR > 1 && NF >= 2 { print $2; exit }'
}

user_exists() {
  local username="$1"
  compose exec -T homarr sh -lc 'node /app/apps/cli/cli.cjs users list 2>/dev/null' \
    | awk 'NR > 1 && NF >= 2 { print $2 }' \
    | grep -Fxq "$username"
}

compose up -d homarr
wait_for_homarr

if ! user_exists "$HOMARR_USER"; then
  compose exec -T homarr node /app/apps/cli/cli.cjs recreate-admin --username "$HOMARR_USER" >/dev/null 2>&1 || true
fi

TARGET_USER="$HOMARR_USER"
if ! user_exists "$TARGET_USER"; then
  TARGET_USER="$(first_user_name || true)"
fi

if [[ -n "$TARGET_USER" ]]; then
  compose exec -T homarr node /app/apps/cli/cli.cjs users update-password --username "$TARGET_USER" --password "$HOMARR_PASSWORD" >/dev/null
fi
