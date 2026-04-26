#!/usr/bin/env bash
set -euo pipefail

STACK_DIR="${STACK_DIR:-/opt/media}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

resolve_env_file() {
  local candidate
  if [[ -n "${ENV_FILE:-}" && -f "${ENV_FILE:-}" ]]; then
    printf '%s\n' "$ENV_FILE"
    return 0
  fi

  for candidate in \
    "$STACK_DIR/.env" \
    "$REPO_ROOT/backend/generated/workspace/resources/media-stack/media.env" \
    "$REPO_ROOT/crates/backend-terraform/tests/fixtures/example-workspace/resources/media-stack/media.env"
  do
    if [[ -f "$candidate" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done

  return 1
}

ENV_FILE="$(resolve_env_file || true)"
if [[ -z "$ENV_FILE" ]]; then
  cat >&2 <<EOF
missing media env file
checked:
  - ${ENV_FILE:-<unset>}
  - $STACK_DIR/.env
  - $REPO_ROOT/backend/generated/workspace/resources/media-stack/media.env
  - $REPO_ROOT/crates/backend-terraform/tests/fixtures/example-workspace/resources/media-stack/media.env
EOF
  exit 1
fi

export VMCTL_MEDIA_ENV_FILE="$ENV_FILE"

set -a
. "$ENV_FILE"
set +a

python3 <<'PY'
import json
import os
import time
import urllib.error
import urllib.request
from pathlib import Path

ENV_FILE = Path(os.environ["VMCTL_MEDIA_ENV_FILE"])
CONFIG_ROOT = Path(os.environ.get("CONFIG_PATH") or "/opt/media/config")
JELLYFIN_URL = (os.environ.get("JELLYFIN_INTERNAL_URL") or "http://127.0.0.1:8096").rstrip("/")
JELLYFIN_ADMIN_USER = os.environ.get("JELLYFIN_ADMIN_USER", "admin")
JELLYFIN_ADMIN_PASSWORD = os.environ.get("JELLYFIN_ADMIN_PASSWORD", "")
STATE_FILE = Path("/var/lib/vmctl/download-unpack/processed.json")
COMPATIBILITY_FILE = Path("/var/lib/vmctl/download-unpack/compatibility.json")
COMPATIBILITY_SUMMARY_JSON = Path("/var/lib/vmctl/download-unpack/compatibility-summary.json")
COMPATIBILITY_SUMMARY_TXT = Path("/var/lib/vmctl/download-unpack/compatibility-summary.txt")
STALE_STATE_FILE = Path("/var/lib/vmctl/download-unpack/stale-state.json")
VIDEO_SUFFIXES = {".mkv", ".mp4", ".m4v", ".avi", ".mov", ".wmv", ".ts", ".webm", ".iso"}


def request_json(method: str, url: str, payload=None, headers=None, allow=(200, 204)):
    data = None
    req_headers = dict(headers or {})
    if payload is not None:
        data = json.dumps(payload).encode("utf-8")
        req_headers.setdefault("Content-Type", "application/json")
    req = urllib.request.Request(url, data=data, headers=req_headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=30) as response:
            raw = response.read().decode("utf-8")
            return json.loads(raw) if raw else None
    except urllib.error.HTTPError as err:
        if err.code in allow:
            return None
        detail = err.read().decode("utf-8", errors="replace")
        raise RuntimeError(f"{method} {url} failed with HTTP {err.code}: {detail}") from err


def load_json_file(path: Path):
    if not path.exists():
        return {}
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except Exception:
        return {}


def save_json_file(path: Path, payload) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def path_has_media(path: Path) -> bool:
    if path.is_file():
        return path.suffix.lower() in VIDEO_SUFFIXES
    if not path.is_dir():
        return False
    for child in path.rglob("*"):
        if child.is_file() and child.suffix.lower() in VIDEO_SUFFIXES:
            return True
    return False


def read_api_key(app: str) -> str:
    path = CONFIG_ROOT / app / "config.xml"
    started = time.time()
    while time.time() - started < 180:
        if path.exists():
            try:
                import xml.etree.ElementTree as ET

                root = ET.parse(path).getroot()
            except Exception:
                time.sleep(2)
                continue
            key = (root.findtext("ApiKey") or "").strip()
            if key:
                return key
        time.sleep(2)
    raise RuntimeError(f"missing API key for {app} at {path}")


def jellyfin_refresh() -> None:
    headers = {
        "Content-Type": "application/json",
        "Authorization": 'MediaBrowser Client="vmctl", Device="cleanup", DeviceId="vmctl-cleanup", Version="1.0"',
    }
    auth = request_json(
        "POST",
        f"{JELLYFIN_URL}/Users/AuthenticateByName",
        {"Username": JELLYFIN_ADMIN_USER, "Pw": JELLYFIN_ADMIN_PASSWORD},
        headers=headers,
        allow=(),
    )
    token = auth.get("AccessToken")
    if not token:
        return
    request_json(
        "POST",
        f"{JELLYFIN_URL}/Library/Refresh",
        headers={
            "X-Emby-Token": token,
            "Authorization": 'MediaBrowser Client="vmctl", Device="cleanup", DeviceId="vmctl-cleanup", Version="1.0"',
        },
        allow=(200, 204, 400),
    )


def rebuild_compatibility_summary() -> None:
    reports = load_json_file(COMPATIBILITY_FILE)
    incompatible = []
    for item_id, report in sorted(reports.items(), key=lambda item: item[0]):
        if not isinstance(report, dict):
            continue
        if report.get("compatible", False):
            continue
        incompatible.append(
            {
                "id": item_id,
                "path": report.get("path") or "",
                "container": report.get("container") or "",
                "videoCodecs": report.get("videoCodecs") or [],
                "audioCodecs": report.get("audioCodecs") or [],
                "audioLanguages": report.get("audioLanguages") or [],
                "subtitleCodecs": report.get("subtitleCodecs") or [],
                "reason": report.get("reason") or "unknown",
            }
        )

    payload = {
        "updatedAt": int(time.time()),
        "incompatibleCount": len(incompatible),
        "items": incompatible,
    }
    save_json_file(COMPATIBILITY_SUMMARY_JSON, payload)
    lines = [
        f"incompatible_count={len(incompatible)}",
        f"updated_at={payload['updatedAt']}",
    ]
    for item in incompatible:
        lines.append(
            " | ".join(
                [
                    str(item["id"]),
                    f"path={item['path'] or 'unknown'}",
                    f"container={item['container'] or 'unknown'}",
                    f"video={','.join(item['videoCodecs']) or '-'}",
                    f"audio={','.join(item['audioCodecs']) or '-'}",
                    f"subtitles={','.join(item['subtitleCodecs']) or '-'}",
                    f"reason={item['reason']}",
                ]
            )
        )
    COMPATIBILITY_SUMMARY_TXT.parent.mkdir(parents=True, exist_ok=True)
    COMPATIBILITY_SUMMARY_TXT.write_text("\n".join(lines).rstrip() + "\n", encoding="utf-8")


def cleanup_stale_state(dry_run: bool = False) -> dict:
    state = load_json_file(STATE_FILE)
    compatibility = load_json_file(COMPATIBILITY_FILE)
    cleanup = {
        "updatedAt": int(time.time()),
        "removed": [],
        "refreshedJellyfin": False,
    }

    for item_id, entry in list(state.items()):
        path_text = str((entry or {}).get("path") or "").strip()
        path = Path(path_text) if path_text else None
        if path is None or not path_has_media(path):
            cleanup["removed"].append(
                {
                    "id": item_id,
                    "app": (entry or {}).get("app") or "",
                    "path": path_text,
                    "reason": "imported path missing or no longer contains media",
                }
            )
            if not dry_run:
                state.pop(item_id, None)

    for item_id, report in list(compatibility.items()):
        if not isinstance(report, dict):
            continue
        path_text = str(report.get("path") or "").strip()
        path = Path(path_text) if path_text else None
        if path is None or not path_has_media(path):
            cleanup["removed"].append(
                {
                    "id": item_id,
                    "app": "compatibility",
                    "path": path_text,
                    "reason": "compatibility report path missing or no longer contains media",
                }
            )
            if not dry_run:
                compatibility.pop(item_id, None)

    if dry_run:
        return cleanup

    if cleanup["removed"]:
        save_json_file(STATE_FILE, state)
        save_json_file(COMPATIBILITY_FILE, compatibility)
        rebuild_compatibility_summary()
        try:
            jellyfin_refresh()
            cleanup["refreshedJellyfin"] = True
        except Exception as exc:
            print(f"warning: Jellyfin refresh skipped: {exc}")
    save_json_file(STALE_STATE_FILE, cleanup)
    return cleanup


def main() -> int:
    import argparse

    parser = argparse.ArgumentParser(description="Prune stale media-stack state and refresh Jellyfin")
    parser.add_argument("--dry-run", action="store_true", help="Report stale entries without modifying state")
    args = parser.parse_args()

    cleanup = cleanup_stale_state(dry_run=args.dry_run)
    print(json.dumps(cleanup, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
PY
