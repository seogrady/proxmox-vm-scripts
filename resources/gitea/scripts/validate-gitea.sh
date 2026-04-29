#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
. "$SCRIPT_DIR/gitea-common.sh"
load_gitea_env

if [[ "$GITEA_ENABLED" != "true" ]]; then
  echo "gitea feature disabled"
  exit 0
fi

gitea_root_url="$(resolve_gitea_root_url)"
gitea_ssh_host="$(resolve_gitea_ssh_host)"
api_base="${gitea_root_url%/}/api/v1"

if ! wait_for_gitea_version "$gitea_root_url"; then
  echo "gitea service not reachable"
  exit 1
fi

if ! curl -fsS -u "$GITEA_ADMIN_USER:$GITEA_ADMIN_PASSWORD" "$api_base/user" >/tmp/vmctl-gitea-user.json; then
  echo "gitea login failed for admin user"
  exit 1
fi
if ! python3 - "$GITEA_ADMIN_USER" /tmp/vmctl-gitea-user.json <<'PY'
import json
import sys

expected = sys.argv[1].strip().lower()
with open(sys.argv[2], encoding="utf-8") as handle:
    payload = json.load(handle)
actual = str(payload.get("login") or "").strip().lower()
if actual != expected:
    raise SystemExit(1)
PY
then
  echo "gitea login failed for admin user"
  exit 1
fi

work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT

ssh_key="$work_dir/vmctl-gitea-smoke"
ssh-keygen -q -t ed25519 -N '' -f "$ssh_key" >/dev/null

smoke_key_payload="$(python3 - "$ssh_key.pub" <<'PY'
import hashlib
import json
import sys
from pathlib import Path

key = Path(sys.argv[1]).read_text(encoding="utf-8").strip()
title = "vmctl-validate-" + hashlib.sha256(key.encode("utf-8")).hexdigest()[:16]
print(json.dumps({"title": title, "key": key}))
PY
)"

add_key_status="$(curl -sS -o "$work_dir/add-key.json" -w '%{http_code}' \
  -u "$GITEA_ADMIN_USER:$GITEA_ADMIN_PASSWORD" \
  -H 'Content-Type: application/json' \
  -X POST \
  -d "$smoke_key_payload" \
  "$api_base/user/keys")"
if [[ "$add_key_status" != "201" && "$add_key_status" != "200" && "$add_key_status" != "422" && "$add_key_status" != "409" ]]; then
  echo "gitea ssh key injection failed"
  cat "$work_dir/add-key.json" >&2 || true
  exit 1
fi

repo_name="vmctl-ssh-smoke"
repo_status="$(curl -sS -o "$work_dir/repo-get.json" -w '%{http_code}' \
  -u "$GITEA_ADMIN_USER:$GITEA_ADMIN_PASSWORD" \
  "$api_base/repos/${GITEA_ADMIN_USER}/${repo_name}")"
if [[ "$repo_status" == "404" ]]; then
  create_payload="$(python3 - "$repo_name" <<'PY'
import json
import sys
print(json.dumps({"name": sys.argv[1], "private": False, "auto_init": False}))
PY
)"
  create_status="$(curl -sS -o "$work_dir/repo-create.json" -w '%{http_code}' \
    -u "$GITEA_ADMIN_USER:$GITEA_ADMIN_PASSWORD" \
    -H 'Content-Type: application/json' \
    -X POST \
    -d "$create_payload" \
    "$api_base/user/repos")"
  if [[ "$create_status" != "201" && "$create_status" != "200" && "$create_status" != "409" && "$create_status" != "422" ]]; then
    echo "gitea repository creation failed"
    cat "$work_dir/repo-create.json" >&2 || true
    exit 1
  fi
elif [[ "$repo_status" != "200" ]]; then
  echo "gitea api responded with unexpected status while checking repo"
  cat "$work_dir/repo-get.json" >&2 || true
  exit 1
fi

smoke_repo_dir="$work_dir/repo"
mkdir -p "$smoke_repo_dir"
(
  cd "$smoke_repo_dir"
  git init -q
  git config user.name "vmctl"
  git config user.email "vmctl@local"
  echo "vmctl gitea ssh smoke $(date -u +%Y-%m-%dT%H:%M:%SZ)" > README.md
  git add README.md
  git commit -q -m "vmctl ssh smoke"

  remote_url="ssh://gitea@${gitea_ssh_host}:${GITEA_SSH_PORT}/${GITEA_ADMIN_USER}/${repo_name}.git"
  smoke_branch="vmctl-smoke-$(date -u +%Y%m%d%H%M%S)-$RANDOM"
  export GIT_SSH_COMMAND="ssh -i $ssh_key -o BatchMode=yes -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=$work_dir/known_hosts -p ${GITEA_SSH_PORT}"
  git remote add origin "$remote_url"
  git push -q -u origin "HEAD:${smoke_branch}"
) || {
  echo "gitea ssh push smoke test failed"
  exit 1
}

if ! curl -fsS "$api_base/version" >/tmp/vmctl-gitea-version.json; then
  echo "gitea api did not return version"
  exit 1
fi

echo "gitea validation passed"
