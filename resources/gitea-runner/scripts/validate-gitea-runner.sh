#!/usr/bin/env bash
set -euo pipefail

RESOURCE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="$RESOURCE_DIR/gitea-runner.env"

if [[ -f "$ENV_FILE" ]]; then
  set -a
  # shellcheck source=/dev/null
  . "$ENV_FILE"
  set +a
fi

GITEA_RUNNER_ENABLED="${GITEA_RUNNER_ENABLED:-true}"

is_truthy() {
  local value="${1:-}"
  case "${value,,}" in
    1|true|yes|on) return 0 ;;
    *) return 1 ;;
  esac
}

if ! is_truthy "$GITEA_RUNNER_ENABLED"; then
  echo "gitea runner feature disabled"
  exit 0
fi

instance_indexes() {
  local vars=() indices=() var idx
  while IFS= read -r var; do
    vars+=("$var")
  done < <(compgen -A variable GITEA_RUNNER_INSTANCE_NAME_ || true)
  for var in "${vars[@]}"; do
    idx="${var##*_}"
    [[ -n "$idx" ]] && indices+=("$idx")
  done
  if ((${#indices[@]} == 0)); then
    indices=(0)
  fi
  printf '%s\n' "${indices[@]}" | sort -n -u
}

list_runners_endpoint() {
  local base_url="$1"
  local scope="$2"
  local repo="$3"
  local org="$4"
  case "$scope" in
    repo)
      if [[ "$repo" != */* ]]; then
        echo "repo scope requires owner/repo, got: $repo" >&2
        return 1
      fi
      local owner="${repo%%/*}"
      local repo_name="${repo#*/}"
      printf '%s/api/v1/repos/%s/%s/actions/runners\n' "${base_url%/}" "$owner" "$repo_name"
      ;;
    org)
      [[ -n "$org" ]] || {
        echo "org scope requires org name" >&2
        return 1
      }
      printf '%s/api/v1/orgs/%s/actions/runners\n' "${base_url%/}" "$org"
      ;;
    instance)
      printf '%s/api/v1/admin/actions/runners\n' "${base_url%/}"
      ;;
    *)
      echo "unsupported runner scope: $scope" >&2
      return 1
      ;;
  esac
}

while IFS= read -r idx; do
  name_var="GITEA_RUNNER_INSTANCE_NAME_${idx}"
  base_url_var="GITEA_RUNNER_INSTANCE_BASE_URL_${idx}"
  scope_var="GITEA_RUNNER_INSTANCE_SCOPE_${idx}"
  repo_var="GITEA_RUNNER_INSTANCE_REPO_${idx}"
  org_var="GITEA_RUNNER_INSTANCE_ORG_${idx}"
  runner_name_var="GITEA_RUNNER_INSTANCE_RUNNER_NAME_${idx}"
  admin_user_var="GITEA_RUNNER_INSTANCE_ADMIN_USER_${idx}"
  admin_password_var="GITEA_RUNNER_INSTANCE_ADMIN_PASSWORD_${idx}"

  instance_name="${!name_var:-gitea-${idx}}"
  base_url="${!base_url_var:-http://gitea:3000/}"
  scope="${!scope_var:-repo}"
  repo="${!repo_var:-admin/vmctl}"
  org="${!org_var:-}"
  runner_name="${!runner_name_var:-${VMCTL_RESOURCE_NAME:-gitea-runner}-${idx}}"
  admin_user="${!admin_user_var:-admin}"
  admin_password="${!admin_password_var:-changeme}"

  instance_slug="$(printf '%s' "$instance_name" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9' '-')"
  instance_slug="${instance_slug#-}"
  instance_slug="${instance_slug%-}"
  if [[ -z "$instance_slug" ]]; then
    instance_slug="gitea-${idx}"
  fi

  if ! systemctl is-active --quiet "act_runner@${instance_slug}.service"; then
    echo "act_runner@${instance_slug}.service is not active"
    exit 1
  fi

  runner_file="/var/lib/act_runner/${instance_slug}/.runner"
  if [[ ! -s "$runner_file" ]]; then
    echo "runner registration file missing: $runner_file"
    exit 1
  fi
  if [[ "$(stat -c '%a' "$runner_file")" != "600" ]]; then
    echo "runner registration file has wrong permissions: $runner_file"
    exit 1
  fi

  endpoint="$(list_runners_endpoint "$base_url" "$scope" "$repo" "$org")"
  if ! curl -fsS -u "$admin_user:$admin_password" "$endpoint" >/tmp/vmctl-gitea-runners.json; then
    echo "failed to query gitea runners endpoint: $endpoint"
    exit 1
  fi

  if ! python3 - "$runner_name" /tmp/vmctl-gitea-runners.json <<'PY'
import json
import sys

runner_name = sys.argv[1].strip().lower()
with open(sys.argv[2], encoding="utf-8") as handle:
    payload = json.load(handle)

runners = payload.get("runners") if isinstance(payload, dict) else None
if runners is None:
    runners = payload if isinstance(payload, list) else []

for runner in runners:
    if str((runner or {}).get("name") or "").strip().lower() != runner_name:
        continue
    status = str((runner or {}).get("status") or "").strip().lower()
    disabled = bool((runner or {}).get("disabled"))
    if status == "online" and not disabled:
        raise SystemExit(0)

raise SystemExit(1)
PY
  then
    echo "runner '${runner_name}' is missing or not online"
    exit 1
  fi
done < <(instance_indexes)

echo "gitea runner validation passed"
