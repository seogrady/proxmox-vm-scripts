#!/usr/bin/env bash
set -euo pipefail

STACK_DIR="/opt/media"
ENV_FILE="$STACK_DIR/.env"

if [[ ! -f "$ENV_FILE" ]]; then
  exit 0
fi

set -a
. "$ENV_FILE"
set +a

MEDIA_SERVICES_CSV="${MEDIA_SERVICES:-}"

service_enabled() {
  local name="$1"
  case ",${MEDIA_SERVICES_CSV}," in
    *,"$name",*) return 0 ;;
    *) return 1 ;;
  esac
}

if ! service_enabled "qbittorrent-vpn" && ! service_enabled "sabnzbd"; then
  exit 0
fi

if ! service_enabled "radarr" && ! service_enabled "sonarr"; then
  exit 0
fi

install -d /usr/local/lib/vmctl /var/lib/vmctl/download-unpack
cat >/usr/local/lib/vmctl/media_download_unpack.py <<'PY'
#!/usr/bin/env python3
import json
import os
import subprocess
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

STACK_DIR = Path("/opt/media")
ENV_FILE = STACK_DIR / ".env"
CONFIG_ROOT = Path(os.environ.get("CONFIG_PATH") or "/opt/media/config")
UI_INDEX_ROOT = CONFIG_ROOT / "caddy" / "ui-index"
TORRENT_DOWNLOAD_ROOT = Path(os.environ.get("QBITTORRENT_DOWNLOADS") or "/data/torrents")
USENET_COMPLETE_ROOT = Path(os.environ.get("SABNZBD_COMPLETE") or "/data/usenet/complete")
STATE_FILE = Path("/var/lib/vmctl/download-unpack/processed.json")
RECOVERY_STATE_FILE = Path("/var/lib/vmctl/download-unpack/recovery.json")
COMPATIBILITY_FILE = Path("/var/lib/vmctl/download-unpack/compatibility.json")
COMPATIBILITY_SUMMARY_JSON = Path("/var/lib/vmctl/download-unpack/compatibility-summary.json")
COMPATIBILITY_SUMMARY_TXT = Path("/var/lib/vmctl/download-unpack/compatibility-summary.txt")
STALE_STATE_FILE = Path("/var/lib/vmctl/download-unpack/stale-state.json")
STORAGE_HEALTH_FILE = Path("/opt/media/config/caddy/ui-index/storage-health.json")
PRENORMALIZE_SUMMARY_FILE = Path("/var/lib/vmctl/download-unpack/pre-normalize-summary.json")
VIDEO_SUFFIXES = {".mkv", ".mp4", ".m4v", ".avi", ".mov", ".wmv", ".ts", ".webm", ".iso"}
ARCHIVE_SUFFIXES = {".rar", ".r00", ".r01", ".r02", ".zip", ".7z"}
RADARR_CATEGORIES = {"radarr", "movies"}
SONARR_CATEGORIES = {"sonarr", "tv", "tv-sonarr"}
STREMIO_VIDEO_CODECS = {"h264", "hevc", "av1", "vp9"}
STREMIO_AUDIO_CODECS = {"aac", "ac3", "eac3", "mp3", "opus", "vorbis", "flac"}
STREMIO_SUBTITLE_CODECS = {"subrip", "srt", "ass", "ssa", "webvtt"}
ENGLISH_LANGUAGE_TOKENS = {"en", "eng", "english"}


def read_env() -> dict[str, str]:
    env: dict[str, str] = {}
    if not ENV_FILE.exists():
        return env
    for line in ENV_FILE.read_text(encoding="utf-8").splitlines():
        stripped = line.strip()
        if not stripped or stripped.startswith("#") or "=" not in stripped:
            continue
        key, value = stripped.split("=", 1)
        env[key] = value
    return env


ENV = read_env()


def env_bool(name: str, default: bool = False) -> bool:
    value = (ENV.get(name) or "").strip().lower()
    if not value:
        return default
    return value in {"1", "true", "yes", "on"}


def env_int(name: str, default: int) -> int:
    raw = (ENV.get(name) or "").strip()
    if not raw:
        return default
    try:
        return int(raw)
    except Exception:
        return default


def env_float(name: str, default: float) -> float:
    raw = (ENV.get(name) or "").strip()
    if not raw:
        return default
    try:
        return float(raw)
    except Exception:
        return default


def service_enabled(name: str) -> bool:
    services = {
        item.strip()
        for item in (ENV.get("MEDIA_SERVICES") or "").split(",")
        if item.strip()
    }
    return name in services


QBIT_URL = (ENV.get("QBITTORRENT_URL") or "http://localhost:8080").rstrip("/")
QBIT_USERNAME = ENV.get("QBITTORRENT_USERNAME", "admin")
QBIT_PASSWORD = ENV.get("QBITTORRENT_PASSWORD", "adminadmin")
JELLYFIN_URL = (ENV.get("JELLYFIN_INTERNAL_URL") or "http://127.0.0.1:8096").rstrip("/")
JELLYFIN_ADMIN_USER = ENV.get("JELLYFIN_ADMIN_USER", "admin")
JELLYFIN_ADMIN_PASSWORD = ENV.get("JELLYFIN_ADMIN_PASSWORD", "")
PLAYBACK_PRENORMALIZE_ENABLED = env_bool("VMCTL_PLAYBACK_PRENORMALIZE_ENABLED", False)
PLAYBACK_REMOVE_ORIGINAL_AFTER_NORMALIZATION = env_bool(
    "VMCTL_PLAYBACK_REMOVE_ORIGINAL_AFTER_NORMALIZATION", False
)
PLAYBACK_NORMALIZE_VIDEO_CODEC = (ENV.get("VMCTL_PLAYBACK_NORMALIZE_VIDEO_CODEC") or "libx265").strip() or "libx265"
PLAYBACK_NORMALIZE_PRESET = (ENV.get("VMCTL_PLAYBACK_NORMALIZE_PRESET") or "slow").strip() or "slow"
PLAYBACK_NORMALIZE_CRF = env_int("VMCTL_PLAYBACK_NORMALIZE_CRF", 19)
PLAYBACK_NORMALIZE_AUDIO_CODEC = (ENV.get("VMCTL_PLAYBACK_NORMALIZE_AUDIO_CODEC") or "aac").strip() or "aac"
PLAYBACK_NORMALIZE_AUDIO_BITRATE = (ENV.get("VMCTL_PLAYBACK_NORMALIZE_AUDIO_BITRATE") or "384k").strip() or "384k"
PLAYBACK_NORMALIZE_MAX_WIDTH = env_int("VMCTL_PLAYBACK_NORMALIZE_MAX_WIDTH", 0)
PLAYBACK_TONE_MAP_ENABLED = env_bool("VMCTL_PLAYBACK_TONE_MAP_ENABLED", True)
PLAYBACK_TONE_MAP_ALGORITHM = (ENV.get("VMCTL_PLAYBACK_TONE_MAP_ALGORITHM") or "hable").strip() or "hable"
PLAYBACK_TONE_MAP_DESAT = env_float("VMCTL_PLAYBACK_TONE_MAP_DESAT", 0.0)
NORMALIZED_FILE_SUFFIX = " - vmctl-sdr.mkv"
LEGACY_NORMALIZED_FILE_SUFFIX = " - vmctl-1080p-sdr.mkv"


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


def wait_for(url: str, timeout_seconds: int = 180):
    started = time.time()
    while time.time() - started < timeout_seconds:
        try:
            with urllib.request.urlopen(url, timeout=10):
                return
        except Exception:
            time.sleep(2)
    raise RuntimeError(f"timed out waiting for {url}")


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


def qbit_login() -> str:
    data = urllib.parse.urlencode({"username": QBIT_USERNAME, "password": QBIT_PASSWORD}).encode("utf-8")
    req = urllib.request.Request(f"{QBIT_URL}/api/v2/auth/login", data=data, method="POST")
    with urllib.request.urlopen(req, timeout=20) as response:
        cookie = response.headers.get("Set-Cookie", "")
    return cookie.split(";", 1)[0]


def qbit_get(path: str, cookie: str):
    req = urllib.request.Request(f"{QBIT_URL}{path}", headers={"Cookie": cookie}, method="GET")
    with urllib.request.urlopen(req, timeout=30) as response:
        return json.loads(response.read().decode("utf-8"))


def arr_get(app: str, path: str):
    api_key = read_api_key(app)
    if app == "radarr":
        base_url = "http://127.0.0.1:7878"
    elif app == "sonarr":
        base_url = "http://127.0.0.1:8989"
    else:
        raise RuntimeError(f"unsupported app {app}")
    return request_json("GET", f"{base_url}{path}", headers={"X-Api-Key": api_key})


def arr_scan(app: str, folder: str, download_client_id: str):
    api_key = read_api_key(app)
    if app == "radarr":
        base_url = "http://127.0.0.1:7878"
        command = "DownloadedMoviesScan"
    elif app == "sonarr":
        base_url = "http://127.0.0.1:8989"
        command = "DownloadedEpisodesScan"
    else:
        raise RuntimeError(f"unsupported app {app}")
    payload = {
        "name": command,
        "path": folder,
        "downloadClientId": download_client_id,
        "importMode": "Move",
    }
    request_json("POST", f"{base_url}/api/v3/command", payload, headers={"X-Api-Key": api_key}, allow=(200, 201, 202, 204))


def jellyfin_refresh():
    headers = {
        "Content-Type": "application/json",
        "Authorization": 'MediaBrowser Client="vmctl", Device="unpack", DeviceId="vmctl-unpack", Version="1.0"',
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
            "Authorization": 'MediaBrowser Client="vmctl", Device="unpack", DeviceId="vmctl-unpack", Version="1.0"',
        },
        allow=(200, 204, 400),
    )


def jellyfin_is_ready() -> bool:
    try:
        req = urllib.request.Request(f"{JELLYFIN_URL}/System/Info/Public", method="GET")
        with urllib.request.urlopen(req, timeout=10) as response:
            return int(response.status) == 200
    except Exception:
        return False


def refresh_jellyfin_if_ready() -> bool:
    if not jellyfin_is_ready():
        return False
    try:
        jellyfin_refresh()
        return True
    except Exception:
        return False


def ffprobe(path: Path):
    try:
        completed = subprocess.run(
            [
                "ffprobe",
                "-v",
                "error",
                "-show_format",
                "-show_streams",
                "-print_format",
                "json",
                str(path),
            ],
            check=True,
            capture_output=True,
            text=True,
        )
    except FileNotFoundError:
        return None
    except subprocess.CalledProcessError:
        return None
    try:
        return json.loads(completed.stdout or "{}")
    except Exception:
        return None


def normalize_language_token(value) -> str:
    return "".join(ch for ch in str(value).lower() if ch.isalpha())


def stream_language_tokens(stream):
    tags = stream.get("tags") or {}
    values = [
        tags.get("language"),
        tags.get("LANGUAGE"),
        tags.get("title"),
        tags.get("TITLE"),
    ]
    return {
        token
        for token in (normalize_language_token(value) for value in values if value)
        if token
    }


def stream_is_english(stream) -> bool:
    return any(token in ENGLISH_LANGUAGE_TOKENS for token in stream_language_tokens(stream))


def video_stream_has_hdr_or_dv_metadata(stream) -> bool:
    tokens = " ".join(
        [
            str(stream.get("profile") or ""),
            str(stream.get("codec_tag_string") or ""),
            str(stream.get("color_primaries") or ""),
            str(stream.get("color_transfer") or ""),
            str(stream.get("color_space") or ""),
            str(stream.get("side_data_list") or ""),
        ]
    ).lower()
    dv_markers = ("dovi", "dolby", "vision", "dv_profile")
    hdr_markers = ("hdr", "hdr10", "hlg", "bt2020", "smpte2084", "bt2100")
    return any(marker in tokens for marker in dv_markers) or any(marker in tokens for marker in hdr_markers)


def compatibility_report(path: Path):
    report = {
        "path": str(path),
        "compatible": False,
        "reason": "no media file found",
        "container": "",
        "videoCodecs": [],
        "audioCodecs": [],
        "subtitleCodecs": [],
    }
    if path.is_file():
        media_files = [path] if path.suffix.lower() in VIDEO_SUFFIXES else []
    elif path.is_dir():
        media_files = sorted(
            [child for child in path.rglob("*") if child.is_file() and child.suffix.lower() in VIDEO_SUFFIXES],
            key=lambda item: item.name.lower(),
        )
    else:
        media_files = []
    if not media_files:
        return report

    probe = ffprobe(media_files[0])
    if not probe:
        report["reason"] = "ffprobe unavailable or file could not be probed"
        return report

    streams = probe.get("streams") or []
    format_info = probe.get("format") or {}
    container = (format_info.get("format_name") or media_files[0].suffix.lstrip(".")).lower()
    report["container"] = container

    video_codecs = [str(stream.get("codec_name") or "").lower() for stream in streams if stream.get("codec_type") == "video"]
    audio_codecs = [str(stream.get("codec_name") or "").lower() for stream in streams if stream.get("codec_type") == "audio"]
    subtitle_codecs = [str(stream.get("codec_name") or "").lower() for stream in streams if stream.get("codec_type") == "subtitle"]
    audio_languages = sorted(
        {
            token
            for stream in streams
            if stream.get("codec_type") == "audio"
            for token in stream_language_tokens(stream)
            if token
        }
    )
    report["videoCodecs"] = sorted({codec for codec in video_codecs if codec})
    report["audioCodecs"] = sorted({codec for codec in audio_codecs if codec})
    report["subtitleCodecs"] = sorted({codec for codec in subtitle_codecs if codec})
    report["audioLanguages"] = audio_languages

    if not video_codecs:
        report["reason"] = "no video stream found"
        return report
    if any(codec not in STREMIO_VIDEO_CODECS for codec in video_codecs if codec):
        report["reason"] = "unsupported video codec"
        return report
    if any(
        video_stream_has_hdr_or_dv_metadata(stream)
        for stream in streams
        if stream.get("codec_type") == "video"
    ):
        report["reason"] = "unsupported video range metadata"
        return report
    if any(codec and codec not in STREMIO_AUDIO_CODECS for codec in audio_codecs):
        report["reason"] = "unsupported audio codec"
        return report
    if audio_codecs and audio_languages and not any(
        stream_is_english(stream) for stream in streams if stream.get("codec_type") == "audio"
    ):
        report["reason"] = "missing english audio track"
        return report
    if any(codec and codec not in STREMIO_SUBTITLE_CODECS for codec in subtitle_codecs):
        report["reason"] = "unsupported subtitle codec"
        return report
    if not any(token in container for token in ("mp4", "mkv", "webm", "mov", "matroska")):
        report["reason"] = "unsupported container"
        return report

    report["compatible"] = True
    report["reason"] = ""
    return report


def iter_media_files(path: Path):
    if path.is_file():
        if path.suffix.lower() in VIDEO_SUFFIXES:
            yield path
        return
    if not path.is_dir():
        return
    files = sorted(
        [child for child in path.rglob("*") if child.is_file() and child.suffix.lower() in VIDEO_SUFFIXES],
        key=lambda item: item.as_posix().lower(),
    )
    for media_file in files:
        yield media_file


def high_risk_playback_reason(probe: dict):
    """
    Returns: (is_high_risk, priority, reason)
    """
    streams = probe.get("streams") or []
    for stream in streams:
        if stream.get("codec_type") != "video":
            continue
        codec = str(stream.get("codec_name") or "").strip().lower()
        if codec != "hevc":
            continue
        width = int(stream.get("width") or 0)
        tokens = " ".join(
            [
                str(stream.get("profile") or ""),
                str(stream.get("codec_tag_string") or ""),
                str(stream.get("color_primaries") or ""),
                str(stream.get("color_transfer") or ""),
                str(stream.get("color_space") or ""),
                str(stream.get("side_data_list") or ""),
            ]
        ).lower()
        dv_markers = ("dovi", "dolby", "vision", "dv_profile")
        hdr_markers = ("hdr", "hdr10", "hlg", "bt2020", "smpte2084")
        has_dv = any(marker in tokens for marker in dv_markers)
        has_hdr = any(marker in tokens for marker in hdr_markers)
        if has_dv:
            return (True, 140, "high-risk HEVC Dolby Vision source")
        if has_hdr:
            return (True, 120, "high-risk HEVC HDR source")
        if width >= 3840:
            return (True, 100, "high-risk 4K HEVC source")
    return (False, 0, "")


def normalize_output_path(media_file: Path) -> Path:
    parent = media_file.parent
    base_name = parent.name if parent.name else media_file.stem
    return parent / f"{base_name}{NORMALIZED_FILE_SUFFIX}"


def normalization_target_path(media_file: Path) -> tuple[Path, bool]:
    # When remove-original is enabled, normalize in-place to keep Jellyfin item paths stable.
    if PLAYBACK_REMOVE_ORIGINAL_AFTER_NORMALIZATION:
        return (media_file, True)
    return (normalize_output_path(media_file), False)


def pre_normalize_decision(media_file: Path):
    """
    Returns: (should_convert, priority, reason)
    """
    if media_file.name.endswith(NORMALIZED_FILE_SUFFIX) or media_file.name.endswith(LEGACY_NORMALIZED_FILE_SUFFIX):
        return (False, 0, "already normalized output")
    probe = ffprobe(media_file)
    if not probe:
        return (False, 0, "ffprobe unavailable or failed")
    report = compatibility_report(media_file)
    is_high_risk, high_risk_priority, high_risk_reason = high_risk_playback_reason(probe)
    if is_high_risk:
        return (True, high_risk_priority, high_risk_reason)

    if report.get("compatible"):
        return (False, 0, "already compatible")

    reason = str(report.get("reason") or "incompatible")
    if reason in {"unsupported video codec", "unsupported audio codec", "unsupported container"}:
        return (True, 60, reason)
    if reason == "unsupported video range metadata":
        return (True, 80, reason)
    if reason == "unsupported subtitle codec":
        # Subtitle incompatibility alone is not a reason to fully re-encode video.
        return (False, 0, reason)
    if reason == "missing english audio track":
        return (False, 0, reason)

    return (True, 20, reason)


def first_stream(probe: dict, stream_type: str):
    for stream in (probe.get("streams") or []):
        if stream.get("codec_type") == stream_type:
            return stream
    return None


def build_video_filter_chain(has_hdr_or_dv: bool) -> str:
    filters = []
    if PLAYBACK_NORMALIZE_MAX_WIDTH > 0:
        filters.append(f"scale='min({PLAYBACK_NORMALIZE_MAX_WIDTH},iw)':-2:flags=lanczos")
    if has_hdr_or_dv and PLAYBACK_TONE_MAP_ENABLED:
        filters.extend(
            [
                "zscale=transfer=linear:npl=100",
                f"tonemap=tonemap={PLAYBACK_TONE_MAP_ALGORITHM}:desat={PLAYBACK_TONE_MAP_DESAT}",
                "zscale=transfer=bt709:primaries=bt709:matrix=bt709",
            ]
        )
    return ",".join(filters)


def pre_normalize_file(media_file: Path, decision_reason: str) -> tuple[bool, str]:
    normalized_file, replace_source_in_place = normalization_target_path(media_file)
    if not replace_source_in_place and normalized_file.exists():
        source_probe = ffprobe(media_file) or {}
        existing_probe = ffprobe(normalized_file)
        existing_streams = (existing_probe or {}).get("streams") or []
        source_duration = float(((source_probe.get("format") or {}).get("duration") or 0) or 0)
        existing_duration = float((((existing_probe or {}).get("format") or {}).get("duration") or 0) or 0)
        has_video = any(stream.get("codec_type") == "video" for stream in existing_streams)
        duration_is_valid = False
        if source_duration > 0 and existing_duration > 0:
            duration_is_valid = existing_duration >= (source_duration * 0.90)
        elif source_duration <= 0 and existing_duration > 0:
            duration_is_valid = True
        if has_video and duration_is_valid:
            return (False, f"skip (normalized exists): {normalized_file}")
        try:
            normalized_file.unlink()
        except Exception:
            return (False, f"skip (invalid normalized output exists): {normalized_file}")

    if decision_reason == "already normalized output":
        return (False, "skip (already normalized output)")
    if decision_reason in {"ffprobe unavailable or failed", "already compatible", "unsupported subtitle codec", "missing english audio track"}:
        return (False, f"skip ({decision_reason})")

    if not media_file.exists():
        return (False, "skip (source file missing)")

    normalized_file.parent.mkdir(parents=True, exist_ok=True)
    temp_output = normalized_file.with_name(f"{normalized_file.stem}.tmp{normalized_file.suffix}")
    try:
        if temp_output.exists():
            temp_output.unlink()
    except Exception:
        return (False, f"failed (could not remove stale temp output: {temp_output})")

    print(f"pre-normalize: converting {media_file} -> {normalized_file} ({decision_reason})")
    source_probe = ffprobe(media_file) or {}
    source_video = first_stream(source_probe, "video") or {}
    source_audio = first_stream(source_probe, "audio") or {}
    source_video_codec = str(source_video.get("codec_name") or "").strip().lower()
    source_audio_codec = str(source_audio.get("codec_name") or "").strip().lower()
    has_hdr_or_dv = video_stream_has_hdr_or_dv_metadata(source_video)

    needs_video_reencode = decision_reason not in {"unsupported audio codec", "unsupported container"}
    needs_audio_reencode = decision_reason == "unsupported audio codec"
    if source_audio_codec and source_audio_codec not in STREMIO_AUDIO_CODECS:
        needs_audio_reencode = True

    video_filter = build_video_filter_chain(has_hdr_or_dv) if needs_video_reencode else ""

    cmd = [
        "ffmpeg",
        "-y",
        "-hide_banner",
        "-loglevel",
        "error",
        "-i",
        str(media_file),
        "-map",
        "0:v:0",
        "-map",
        "0:a:0?",
        "-map",
        "-0:s",
    ]
    if needs_video_reencode:
        cmd.extend(
            [
                "-c:v",
                PLAYBACK_NORMALIZE_VIDEO_CODEC,
                "-preset",
                PLAYBACK_NORMALIZE_PRESET,
                "-crf",
                str(PLAYBACK_NORMALIZE_CRF),
                "-pix_fmt",
                "yuv420p",
            ]
        )
        if not has_hdr_or_dv or PLAYBACK_TONE_MAP_ENABLED:
            cmd.extend(
                [
                    "-color_primaries",
                    "bt709",
                    "-color_trc",
                    "bt709",
                    "-colorspace",
                    "bt709",
                ]
            )
        if video_filter:
            cmd.extend(["-vf", video_filter])
    else:
        cmd.extend(["-c:v", "copy"])

    if needs_audio_reencode:
        cmd.extend(
            [
                "-c:a",
                PLAYBACK_NORMALIZE_AUDIO_CODEC,
                "-b:a",
                PLAYBACK_NORMALIZE_AUDIO_BITRATE,
            ]
        )
    else:
        cmd.extend(["-c:a", "copy"])

    cmd.append(str(temp_output))
    try:
        subprocess.run(cmd, check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    except Exception as exc:
        try:
            if temp_output.exists():
                temp_output.unlink()
        except Exception:
            pass
        return (False, f"failed ({exc})")
    try:
        temp_output.replace(normalized_file)
    except Exception as exc:
        return (False, f"failed (could not finalize output: {exc})")

    if replace_source_in_place:
        return (True, "converted (in-place)")
    return (True, "converted")


def pre_normalize_media(path: Path, summary: dict | None = None) -> bool:
    if not PLAYBACK_PRENORMALIZE_ENABLED:
        return False

    candidates = []
    for media_file in iter_media_files(path):
        should_convert, priority, reason = pre_normalize_decision(media_file)
        candidates.append((priority, str(media_file).lower(), media_file, should_convert, reason))
    candidates.sort(key=lambda row: (-row[0], row[1]))

    changed = False
    for _priority, _key, media_file, should_convert, reason in candidates:
        converted, status = pre_normalize_file(media_file, reason if should_convert else reason)
        changed = converted or changed
        if summary is not None:
            summary["scanned"] += 1
            if converted:
                summary["converted"] += 1
            else:
                summary["skipped"] += 1
            summary["items"].append(
                {
                    "path": str(media_file),
                    "convert": bool(should_convert),
                    "decision": reason,
                    "status": status,
                }
            )
    return changed


def load_state():
    if not STATE_FILE.exists():
        return {}
    try:
        return json.loads(STATE_FILE.read_text(encoding="utf-8"))
    except Exception:
        return {}


def save_state(state):
    STATE_FILE.parent.mkdir(parents=True, exist_ok=True)
    STATE_FILE.write_text(json.dumps(state, indent=2, sort_keys=True) + "\n", encoding="utf-8")


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


def mirror_ui_file(name: str, content: str) -> None:
    UI_INDEX_ROOT.mkdir(parents=True, exist_ok=True)
    (UI_INDEX_ROOT / name).write_text(content, encoding="utf-8")


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
    mirror_ui_file("compatibility-summary.txt", COMPATIBILITY_SUMMARY_TXT.read_text(encoding="utf-8"))
    mirror_ui_file("compatibility-summary.json", COMPATIBILITY_SUMMARY_JSON.read_text(encoding="utf-8"))


def write_storage_health() -> None:
    storage_path = Path(ENV.get("STORAGE_PATH") or "/data")
    try:
        stat = os.statvfs(storage_path)
    except FileNotFoundError:
        return

    total_bytes = stat.f_frsize * stat.f_blocks
    free_bytes = stat.f_frsize * stat.f_bavail
    used_bytes = max(total_bytes - free_bytes, 0)
    gb = 1024 ** 3
    payload = {
        "storagePath": str(storage_path),
        "totalBytes": total_bytes,
        "usedBytes": used_bytes,
        "freeBytes": free_bytes,
        "totalGb": round(total_bytes / gb, 2),
        "usedGb": round(used_bytes / gb, 2),
        "freeGb": round(free_bytes / gb, 2),
        "usedPercent": round((used_bytes * 100.0 / total_bytes) if total_bytes else 0.0, 2),
        "freePercent": round((free_bytes * 100.0 / total_bytes) if total_bytes else 0.0, 2),
        "updatedAt": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
    }
    STORAGE_HEALTH_FILE.parent.mkdir(parents=True, exist_ok=True)
    STORAGE_HEALTH_FILE.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def path_has_media(path: Path) -> bool:
    if path.is_file():
        return path.suffix.lower() in VIDEO_SUFFIXES
    if not path.is_dir():
        return False
    for child in path.rglob("*"):
        if child.is_file() and child.suffix.lower() in VIDEO_SUFFIXES:
            return True
    return False


def archive_candidates(path: Path):
    files = [child for child in path.iterdir() if child.is_file() and child.suffix.lower() in ARCHIVE_SUFFIXES]
    if not files:
        return []
    priority = {".rar": 0, ".zip": 1, ".7z": 2, ".r00": 3, ".r01": 4, ".r02": 5}
    return sorted(files, key=lambda item: (priority.get(item.suffix.lower(), 99), item.name.lower()))


def extract_archive(path: Path) -> bool:
    archives = archive_candidates(path)
    if not archives:
        return False
    if path_has_media(path):
        return False
    archive = next((candidate for candidate in archives if candidate.suffix.lower() in {".rar", ".zip", ".7z"}), archives[0])
    subprocess.run(["7z", "x", "-y", f"-o{path}", str(archive)], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    return True


def item_id_for_path(path: Path, prefix: str) -> str:
    return f"{prefix}:{path.as_posix()}"


def process_torrent_downloads(state):
    cookie = qbit_login()
    torrents = qbit_get("/api/v2/torrents/info", cookie)
    changed = False

    for torrent in torrents:
        category = (torrent.get("category") or "").strip().lower()
        if category in RADARR_CATEGORIES:
            app = "radarr"
        elif category in SONARR_CATEGORIES:
            app = "sonarr"
        else:
            continue

        if float(torrent.get("progress") or 0.0) < 1.0 and int(torrent.get("amount_left") or 1) != 0:
            continue

        raw_path = Path(torrent.get("content_path") or torrent.get("save_path") or "")
        content_path = raw_path if raw_path.is_dir() else raw_path.parent
        if not content_path.exists() or not content_path.is_dir():
            continue

        torrent_id = str(torrent.get("hash") or "").upper()
        if not torrent_id:
            continue
        existing = state.get(torrent_id, {})
        if existing.get("imported") and existing.get("path") == str(content_path):
            continue

        extract_archive(content_path)
        pre_normalize_media(content_path)
        report = compatibility_report(content_path)
        reports = load_json_file(COMPATIBILITY_FILE)
        reports[torrent_id] = report
        save_json_file(COMPATIBILITY_FILE, reports)
        if not path_has_media(content_path):
            continue

        arr_scan(app, str(content_path), torrent_id)
        state[torrent_id] = {
            "app": app,
            "path": str(content_path),
            "imported": True,
            "updatedAt": int(time.time()),
        }
        changed = True

    if changed:
        save_state(state)
    return changed


def process_usenet_downloads(state):
    changed = False
    if not USENET_COMPLETE_ROOT.exists():
        return changed

    for category_root in [USENET_COMPLETE_ROOT / "movies", USENET_COMPLETE_ROOT / "tv"]:
        if not category_root.exists():
            continue
        app = "radarr" if category_root.name == "movies" else "sonarr"
        entries = sorted(
            [child for child in category_root.iterdir() if child.is_dir() or child.is_file()],
            key=lambda item: item.name.lower(),
        )
        for item_path in entries:
            if not item_path.exists():
                continue
            content_path = item_path if item_path.is_dir() else item_path.parent
            item_key = item_id_for_path(content_path, "SAB")
            if state.get(item_key, {}).get("imported"):
                continue

            extract_archive(content_path)
            pre_normalize_media(content_path)
            report = compatibility_report(content_path)
            reports = load_json_file(COMPATIBILITY_FILE)
            reports[item_key] = report
            save_json_file(COMPATIBILITY_FILE, reports)
            if not path_has_media(content_path):
                continue

            arr_scan(app, str(content_path), item_key)
            state[item_key] = {
                "app": app,
                "path": str(content_path),
                "imported": True,
                "updatedAt": int(time.time()),
            }
            changed = True

    return changed


def trigger_recovery():
    recovery_state = load_json_file(RECOVERY_STATE_FILE)
    now = int(time.time())
    last_run = int(recovery_state.get("lastRunAt") or 0)
    if now - last_run < 3600:
        return

    recovered = recovery_state.get("recovered", {})
    allowed_protocols = [item for item in (os.environ.get("VMCTL_DOWNLOAD_PROTOCOLS") or "").split(",") if item.strip()]
    if not allowed_protocols:
        return

    for app, command, id_field in [
        ("radarr", "MoviesSearch", "movieIds"),
        ("sonarr", "SeriesSearch", "seriesIds"),
    ]:
        try:
            items = arr_get(app, "/api/v3/movie" if app == "radarr" else "/api/v3/series")
        except Exception:
            continue
        candidates = items or []

        for item in candidates:
            if not isinstance(item, dict):
                continue
            if not item.get("monitored", True):
                continue
            if app == "radarr" and item.get("hasFile") is True:
                continue
            if app == "sonarr":
                stats = item.get("statistics") or {}
                episode_count = int(stats.get("episodeCount") or 0)
                file_count = int(stats.get("episodeFileCount") or 0)
                if episode_count and file_count >= episode_count:
                    continue
            item_id = item.get("id")
            if item_id is None:
                continue
            key = f"{app}:{item_id}"
            last_triggered = int(recovered.get(key) or 0)
            if now - last_triggered < 21600:
                continue
            payload = {"name": command, id_field: [item_id]}
            try:
                request_json(
                    "POST",
                    f"http://127.0.0.1:{7878 if app == 'radarr' else 8989}/api/v3/command",
                    payload,
                    headers={"X-Api-Key": read_api_key(app)},
                    allow=(200, 201, 202, 204),
                )
                recovered[key] = now
            except Exception:
                continue

    recovery_state["lastRunAt"] = now
    recovery_state["recovered"] = recovered
    save_json_file(RECOVERY_STATE_FILE, recovery_state)


def cleanup_stale_state(state):
    cleanup = {
        "updatedAt": int(time.time()),
        "removed": [],
        "refreshedJellyfin": False,
    }
    compatibility = load_json_file(COMPATIBILITY_FILE)
    changed = False

    for item_id, entry in list(state.items()):
        entry_path_text = str((entry or {}).get("path") or "").strip()
        entry_path = Path(entry_path_text) if entry_path_text else None
        if entry_path is None or not path_has_media(entry_path):
            cleanup["removed"].append(
                {
                    "id": item_id,
                    "app": entry.get("app") or "",
                    "path": entry_path_text,
                    "reason": "imported path missing or no longer contains media",
                }
            )
            state.pop(item_id, None)
            changed = True

    for item_id, report in list(compatibility.items()):
        if not isinstance(report, dict):
            continue
        report_path_text = str(report.get("path") or "").strip()
        report_path = Path(report_path_text) if report_path_text else None
        if report_path is None or not path_has_media(report_path):
            cleanup["removed"].append(
                {
                    "id": item_id,
                    "app": "compatibility",
                    "path": report_path_text,
                    "reason": "compatibility report path missing or no longer contains media",
                }
            )
            compatibility.pop(item_id, None)
            changed = True

    if changed:
        save_state(state)
        save_json_file(COMPATIBILITY_FILE, compatibility)
        rebuild_compatibility_summary()
        cleanup["refreshedJellyfin"] = refresh_jellyfin_if_ready()
    save_json_file(STALE_STATE_FILE, cleanup)

    return changed


def process():
    state = load_state()
    changed = False
    cleanup_stale_state(state)
    if service_enabled("qbittorrent-vpn"):
        changed = process_torrent_downloads(state) or changed
    if service_enabled("sabnzbd"):
        changed = process_usenet_downloads(state) or changed
    if changed:
        save_state(state)
        refresh_jellyfin_if_ready()
    trigger_recovery()
    rebuild_compatibility_summary()
    write_storage_health()


def scan_existing_media() -> None:
    if not PLAYBACK_PRENORMALIZE_ENABLED:
        print("pre-normalization is disabled; skipping existing media scan")
        return
    roots = []
    for candidate in (
        os.environ.get("RADARR_ROOT_FOLDER") or "/data/media/movies",
        os.environ.get("SONARR_ROOT_FOLDER") or "/data/media/tv",
    ):
        path = Path(candidate).expanduser()
        if path.exists() and path not in roots:
            roots.append(path)
    summary = {
        "startedAt": int(time.time()),
        "scanned": 0,
        "converted": 0,
        "skipped": 0,
        "roots": [str(root) for root in roots],
        "items": [],
    }
    changed = False
    for root in roots:
        changed = pre_normalize_media(root, summary) or changed
    summary["completedAt"] = int(time.time())
    PRENORMALIZE_SUMMARY_FILE.parent.mkdir(parents=True, exist_ok=True)
    PRENORMALIZE_SUMMARY_FILE.write_text(json.dumps(summary, indent=2) + "\n", encoding="utf-8")
    print(
        f"pre-normalization summary: scanned={summary['scanned']} "
        f"converted={summary['converted']} skipped={summary['skipped']} "
        f"report={PRENORMALIZE_SUMMARY_FILE}"
    )
    rebuild_compatibility_summary()
    write_storage_health()
    if changed:
        refresh_jellyfin_if_ready()


if "--scan-existing" in os.sys.argv:
    try:
        scan_existing_media()
    except Exception as exc:
        print(f"warning: pre-normalization scan failed: {exc}")
else:
    wait_for("http://127.0.0.1:8080/api/v2/app/version", 240)
    wait_for("http://127.0.0.1:7878/ping", 240)
    wait_for("http://127.0.0.1:8989/ping", 240)
    try:
        process()
    except Exception as exc:
        print(f"warning: media unpack/import pass failed: {exc}")
PY
chmod +x /usr/local/lib/vmctl/media_download_unpack.py

cat >/etc/systemd/system/vmctl-media-unpack.service <<EOF
[Unit]
Description=vmctl archive download unpack and import
After=network-online.target docker.service
Wants=network-online.target docker.service

[Service]
Type=oneshot
EnvironmentFile=/opt/media/.env
ExecStart=/usr/local/lib/vmctl/media_download_unpack.py
User=root

[Install]
WantedBy=multi-user.target
EOF

cat >/etc/systemd/system/vmctl-media-unpack.timer <<EOF
[Unit]
Description=Run vmctl media unpack and import periodically

[Timer]
OnBootSec=2m
OnUnitActiveSec=5m
AccuracySec=1m
Persistent=true
Unit=vmctl-media-unpack.service

[Install]
WantedBy=timers.target
EOF

systemctl daemon-reload
systemctl enable --now vmctl-media-unpack.timer
systemctl start vmctl-media-unpack.service || true
