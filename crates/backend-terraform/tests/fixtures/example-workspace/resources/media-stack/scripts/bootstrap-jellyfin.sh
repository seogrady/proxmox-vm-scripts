#!/usr/bin/env bash
set -euo pipefail

STACK_DIR="/opt/media"
ENV_FILE="$STACK_DIR/.env"
COMPOSE_FILE="$STACK_DIR/docker-compose.yml"

if [[ -f "$ENV_FILE" ]]; then
  set -a
  . "$ENV_FILE"
  set +a
fi

COMPOSE_PROJECT_NAME="${COMPOSE_PROJECT_NAME:-media}"
docker_compose() {
  docker compose -p "$COMPOSE_PROJECT_NAME" --project-directory "$STACK_DIR" --env-file "$ENV_FILE" -f "$COMPOSE_FILE" "$@"
}

CONFIG_ROOT="${CONFIG_PATH:-/opt/media/config}"
BASE_URL_VALUE="${JELLYFIN_BASE_URL:-/jf}"
JELLYFIN_NETWORK_XML="$CONFIG_ROOT/jellyfin/network.xml"
JELLYFIN_ENCODING_XML="$CONFIG_ROOT/jellyfin/encoding.xml"
mkdir -p "$(dirname "$JELLYFIN_NETWORK_XML")"
export BASE_URL_VALUE
export JELLYFIN_NETWORK_XML
export JELLYFIN_ENCODING_XML
export JELLYFIN_ENV_FILE="$ENV_FILE"
export JELLYFIN_SOFTWARE_TRANSCODE_MARKER="$STACK_DIR/config/jellyfin/.vmctl-force-software-transcode"

jellyfin_base_updated="$(
python3 <<'PY'
import os
import xml.etree.ElementTree as ET

xml_path = os.environ["JELLYFIN_NETWORK_XML"]
base_url = (os.environ.get("BASE_URL_VALUE") or "").strip()
if not base_url.startswith("/"):
    base_url = f"/{base_url}"
if base_url == "/":
    base_url = ""

root = None
if os.path.exists(xml_path):
    root = ET.parse(xml_path).getroot()
else:
    root = ET.Element("NetworkConfiguration")

node = root.find("BaseUrl")
if node is None:
    node = ET.SubElement(root, "BaseUrl")

current = (node.text or "").strip()
if current == base_url:
    print("0")
else:
    node.text = base_url
    ET.ElementTree(root).write(xml_path, encoding="utf-8", xml_declaration=True)
    print("1")
PY
)"

jellyfin_encoding_updated="$(
python3 <<'PY'
import os
import xml.etree.ElementTree as ET

xml_path = os.environ["JELLYFIN_ENCODING_XML"]
transcoding_temp_path = (os.environ.get("JELLYFIN_TRANSCODING_TEMP_PATH") or "/config/transcodes").strip()
hwaccel_type = (os.environ.get("JELLYFIN_HWACCEL_TYPE") or "qsv").strip()
vaapi_device = (os.environ.get("JELLYFIN_HWACCEL_DEVICE") or "/dev/dri/renderD128").strip()
enable_hardware_encoding = (os.environ.get("JELLYFIN_HWACCEL_ENABLE_ENCODING") or "true").strip().lower() in {"1", "true", "yes", "on"}
enable_tonemapping_raw = (os.environ.get("JELLYFIN_HWACCEL_ENABLE_TONEMAPPING") or "auto").strip().lower()
enable_vpp_tonemapping = (os.environ.get("JELLYFIN_HWACCEL_ENABLE_VPP_TONEMAPPING") or "true").strip().lower() in {"1", "true", "yes", "on"}
enable_10bit_hevc = (os.environ.get("JELLYFIN_HWACCEL_ENABLE_10BIT_HEVC_DECODING") or "true").strip().lower() in {"1", "true", "yes", "on"}
enable_10bit_vp9 = (os.environ.get("JELLYFIN_HWACCEL_ENABLE_10BIT_VP9_DECODING") or "true").strip().lower() in {"1", "true", "yes", "on"}
enable_low_power_h264 = (os.environ.get("JELLYFIN_HWACCEL_ENABLE_INTEL_LOW_POWER_H264") or "true").strip().lower() in {"1", "true", "yes", "on"}
enable_low_power_hevc = (os.environ.get("JELLYFIN_HWACCEL_ENABLE_INTEL_LOW_POWER_HEVC") or "true").strip().lower() in {"1", "true", "yes", "on"}
prefer_native_decoder = (os.environ.get("JELLYFIN_HWACCEL_PREFER_NATIVE_DECODER") or "true").strip().lower() in {"1", "true", "yes", "on"}
decoding_codecs_raw = (os.environ.get("JELLYFIN_HWACCEL_DECODING_CODECS") or "h264,hevc,mpeg2video,vc1,vp8,vp9,av1").strip()

def probe_opencl_support() -> bool:
    # Jellyfin's Dolby Vision path needs OpenCL on this Intel stack. If the
    # runtime is missing or broken, leave tonemapping off so playback does not
    # hard-fail during FFmpeg device initialization.
    import subprocess

    try:
        subprocess.run(
            [
                "/usr/lib/jellyfin-ffmpeg/ffmpeg",
                "-v",
                "error",
                "-init_hw_device",
                f"vaapi=va:{vaapi_device}",
                "-init_hw_device",
                "opencl=ocl@va",
                "-f",
                "lavfi",
                "-i",
                "color=c=black:s=16x16:d=1",
                "-f",
                "null",
                "-",
            ],
            check=True,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        return True
    except Exception:
        return False

if enable_tonemapping_raw in {"", "auto"}:
    enable_tonemapping = probe_opencl_support()
else:
    enable_tonemapping = enable_tonemapping_raw in {"1", "true", "yes", "on"}

root = None
if os.path.exists(xml_path):
    root = ET.parse(xml_path).getroot()
else:
    root = ET.Element("EncodingOptions")

values = {
    "EncodingThreadCount": "-1",
    "TranscodingTempPath": transcoding_temp_path,
    "FallbackFontPath": "",
    "EnableFallbackFont": "false",
    "DownMixAudioBoost": "2",
    "DownMixStereoAlgorithm": "None",
    "MaxMuxingQueueSize": "2048",
    "EnableThrottling": "false",
    "ThrottleDelaySeconds": "180",
    "EnableSegmentDeletion": "false",
    "SegmentKeepSeconds": "720",
    "HardwareAccelerationType": hwaccel_type,
    "EncoderAppPathDisplay": "/usr/lib/jellyfin-ffmpeg/ffmpeg",
    "VaapiDevice": vaapi_device,
    "EnableTonemapping": str(enable_tonemapping).lower(),
    "EnableVppTonemapping": str(enable_vpp_tonemapping).lower(),
    "TonemappingAlgorithm": "bt2390",
    "TonemappingMode": "auto",
    "TonemappingRange": "auto",
    "TonemappingDesat": "0",
    "TonemappingPeak": "100",
    "TonemappingParam": "0",
    "VppTonemappingBrightness": "16",
    "VppTonemappingContrast": "1",
    "EnableHardwareEncoding": str(enable_hardware_encoding).lower(),
    "EnableDecodingColorDepth10Hevc": str(enable_10bit_hevc).lower(),
    "EnableDecodingColorDepth10Vp9": str(enable_10bit_vp9).lower(),
    "PreferSystemNativeHwDecoder": str(prefer_native_decoder).lower(),
    "EnableIntelLowPowerH264HwEncoder": str(enable_low_power_h264).lower(),
    "EnableIntelLowPowerHevcHwEncoder": str(enable_low_power_hevc).lower(),
    "AllowHevcEncoding": "true",
}
hardware_decoding_codecs = []
for codec in decoding_codecs_raw.split(","):
    codec = codec.strip().lower()
    if codec and codec not in hardware_decoding_codecs:
        hardware_decoding_codecs.append(codec)

current = {child.tag: (child.text or "") for child in list(root)}
codecs_node = root.find("HardwareDecodingCodecs")
current_codecs = []
if codecs_node is not None:
    current_codecs = [
        (child.text or "").strip()
        for child in list(codecs_node)
        if child.tag == "string" and (child.text or "").strip()
    ]
changed = any(current.get(tag) != value for tag, value in values.items())
changed = changed or current_codecs != hardware_decoding_codecs
if changed:
    for tag, value in values.items():
        node = root.find(tag)
        if node is None:
            node = ET.SubElement(root, tag)
        node.text = value
    if codecs_node is not None:
        root.remove(codecs_node)
    codecs_node = ET.SubElement(root, "HardwareDecodingCodecs")
    for codec in hardware_decoding_codecs:
        ET.SubElement(codecs_node, "string").text = codec
    ET.ElementTree(root).write(xml_path, encoding="utf-8", xml_declaration=True)
    print("1")
else:
    print("0")
PY
)"

if [[ "$jellyfin_base_updated" == "1" || "$jellyfin_encoding_updated" == "1" ]]; then
  docker_compose up -d jellyfin
  docker_compose restart jellyfin
fi

python3 <<'PY'
import json
import os
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid
from pathlib import Path

base_candidates = []
for candidate in [
    "http://127.0.0.1:8096",
    (os.environ.get("JELLYFIN_INTERNAL_URL") or "http://127.0.0.1:8096").rstrip("/"),
]:
    if candidate not in base_candidates:
        base_candidates.append(candidate)
user = os.environ.get("JELLYFIN_ADMIN_USER") or "admin"
password = os.environ.get("JELLYFIN_ADMIN_PASSWORD") or ""
base_url = ""
auto_login_user = (os.environ.get("JELLYFIN_AUTOLOGIN_USER") or "media").strip() or "media"
stremio_user = (os.environ.get("JELLYFIN_STREMIO_USER") or "stremio").strip() or "stremio"
env_file = Path(os.environ.get("JELLYFIN_ENV_FILE") or "/opt/media/.env")
max_streaming_bitrate_raw = (os.environ.get("JELLYFIN_MAX_STREAMING_BITRATE") or "12000000").strip()


def call(method, path, payload=None, token=None, allow=(200, 204)):
    data = None
    headers = {
        "Content-Type": "application/json",
        "Authorization": 'MediaBrowser Client="vmctl", Device="bootstrap", DeviceId="vmctl", Version="1.0"',
    }
    if token:
        headers["X-Emby-Token"] = token
    if payload is not None:
        data = json.dumps(payload).encode()
    req = urllib.request.Request(base + path, data=data, headers=headers, method=method)
    try:
        with urllib.request.urlopen(req, timeout=20) as response:
            body = response.read().decode()
            if body:
                return json.loads(body)
            return None
    except urllib.error.HTTPError as err:
        if err.code in allow:
            return None
        raise


def call_text(method, path, payload=None, token=None, allow=(200, 204, 206)):
    data = None
    headers = {
        "Content-Type": "application/json",
        "Authorization": 'MediaBrowser Client="vmctl", Device="bootstrap", DeviceId="vmctl", Version="1.0"',
    }
    if token:
        headers["X-Emby-Token"] = token
    if payload is not None:
        data = json.dumps(payload).encode()
    req = urllib.request.Request(base + path, data=data, headers=headers, method=method)
    try:
        with opener.open(req, timeout=30) as response:
            return response.read().decode("utf-8", errors="replace")
    except urllib.error.HTTPError as err:
        if err.code in allow:
            return err.read().decode("utf-8", errors="replace")
        raise


def parse_positive_int(raw: str, default: int) -> int:
    try:
        value = int(str(raw or "").strip())
    except Exception:
        return default
    return value if value > 0 else default


def _item_locations(item):
    locations = []
    for location in item.get("Locations") or []:
        location = str(location).strip().rstrip("/")
        if location:
            locations.append(location)
    path = str(item.get("Path") or "").strip().rstrip("/")
    if path:
        locations.append(path)
    for path_info in (item.get("LibraryOptions") or {}).get("PathInfos") or []:
        location = str(path_info.get("Path") or "").strip().rstrip("/")
        if location:
            locations.append(location)
    seen = set()
    ordered = []
    for location in locations:
        if location not in seen:
            seen.add(location)
            ordered.append(location)
    return ordered


def ensure_library(name, path, collection_type, token, admin_user_id):
    current = call("GET", "/Library/VirtualFolders", token=token, allow=(200, 204)) or []
    views = call("GET", f"/Users/{admin_user_id}/Views", token=token, allow=(200, 204)) or {}
    view_items = views.get("Items") or []
    desired_path = path.rstrip("/")
    canonical = None
    canonical_locations = []
    duplicates = []
    for item in current:
        item_name = (item.get("Name") or "").strip()
        locations = [str(location).rstrip("/") for location in (item.get("Locations") or []) if str(location).strip()]
        if item_name.lower() == name.lower():
            canonical = item
            canonical_locations = locations
            continue
        if desired_path in locations:
            duplicates.append(item_name)

    if canonical is None:
        for item in view_items:
            item_name = (item.get("Name") or "").strip()
            locations = _item_locations(item)
            if desired_path in locations or item_name.lower() == name.lower():
                canonical = item
                canonical_locations = locations
                break

    for duplicate in duplicates:
        call(
            "DELETE",
            f"/Library/VirtualFolders?name={urllib.parse.quote(duplicate)}",
            token=token,
            allow=(200, 204, 404),
        )

    if canonical is None:
        # If a stale non-canonical view already points at the desired path,
        # do not create a suffixed duplicate library. Refresh and let Jellyfin
        # converge the existing metadata in place.
        if any(desired_path in _item_locations(item) for item in view_items):
            call("POST", "/Library/Refresh", token=token, allow=(200, 204, 400))
            return
        query = urllib.parse.urlencode(
            {
                "name": name,
                "collectionType": collection_type,
                "paths": path,
                "refreshLibrary": "true",
            },
            doseq=True,
        )
        call(
            "POST",
            f"/Library/VirtualFolders?{query}",
            {"LibraryOptions": {"Enabled": True, "PathInfos": [{"Path": path}]}},
            token=token,
            allow=(200, 204, 400),
        )
        if duplicates:
            call("POST", "/Library/Refresh", token=token, allow=(200, 204, 400))
        return

    locations = canonical_locations
    if locations == [desired_path]:
        if duplicates:
            call("POST", "/Library/Refresh", token=token, allow=(200, 204, 400))
        return

    # Jellyfin's library path API mutates Locations through the add/remove
    # endpoints, not the media-path update endpoint. Remove stale paths first,
    # then add the TRaSH-aligned path so the library converges deterministically.
    for location in locations:
        if location == desired_path:
            continue
        call(
            "DELETE",
            f"/Library/VirtualFolders/Paths?name={urllib.parse.quote(name)}&path={urllib.parse.quote(location, safe='')}",
            token=token,
            allow=(200, 204, 404),
        )
    if desired_path not in locations:
        call(
            "POST",
            "/Library/VirtualFolders/Paths?refreshLibrary=true",
            {"Name": name, "Path": desired_path},
            token=token,
            allow=(200, 204, 400),
        )
    # Re-run a refresh so Jellyfin reindexes items against the updated path.
    call("POST", "/Library/Refresh", token=token, allow=(200, 204, 400))


def set_env_value(path: Path, key: str, value: str) -> None:
    lines = path.read_text(encoding="utf-8").splitlines() if path.exists() else []
    out = []
    seen = False
    for line in lines:
        if line.startswith(f"{key}="):
            out.append(f"{key}={value}")
            seen = True
        else:
            out.append(line)
    if not seen:
        out.append(f"{key}={value}")
    path.write_text("\n".join(out).rstrip() + "\n", encoding="utf-8")


def ensure_user(username: str, token: str) -> str:
    users = call("GET", "/Users", token=token, allow=(200, 204)) or []
    for item in users:
        if (item.get("Name") or "").lower() == username.lower():
            return item["Id"]
    created = call("POST", "/Users/New", {"Name": username}, token=token, allow=(200, 204, 400)) or {}
    if created.get("Id"):
        return created["Id"]
    users = call("GET", "/Users", token=token, allow=(200, 204)) or []
    for item in users:
        if (item.get("Name") or "").lower() == username.lower():
            return item["Id"]
    raise RuntimeError(f"failed to create Jellyfin user {username}")


def ensure_blank_password(user_id: str, token: str) -> None:
    call(
        "POST",
        f"/Users/{user_id}/Password",
        {"CurrentPw": "", "NewPw": "", "ResetPassword": False},
        token=token,
        allow=(200, 204, 400),
    )


def ensure_user_policy(user_id: str, token: str, max_streaming_bitrate: int) -> None:
    user = call("GET", f"/Users/{user_id}", token=token, allow=(200, 204)) or {}
    policy = user.get("Policy") or {}
    desired = dict(policy)
    desired["EnablePlaybackRemuxing"] = True
    desired["EnableVideoPlaybackTranscoding"] = True
    desired["EnableAudioPlaybackTranscoding"] = True
    desired["RemoteClientBitrateLimit"] = max_streaming_bitrate
    if desired != policy:
        call("POST", f"/Users/{user_id}/Policy", desired, token=token, allow=(200, 204, 400))


def try_call(method, path, payload=None, token=None):
    try:
        return call(method, path, payload, token, allow=(200, 204))
    except urllib.error.HTTPError:
        return None


def _first_playlist_line(payload: str) -> str:
    for line in (payload or "").splitlines():
        line = line.strip()
        if line and not line.startswith("#"):
            return line
    return ""


def probe_transcode_candidate(token: str, item_id: str, media_source_id: str) -> bool:
    probe_session_id = str(uuid.uuid4())
    probe_params = urllib.parse.urlencode(
        {
            "DeviceId": probe_session_id,
            "MediaSourceId": media_source_id,
            "VideoCodec": "av1,h264,vp9",
            "AudioCodec": "aac",
            "VideoBitrate": "2147099647",
            "AudioBitrate": "384000",
            "SegmentContainer": "mp4",
            "PlaySessionId": probe_session_id,
            "ApiKey": token,
            "TranscodingMaxAudioChannels": "2",
            "EnableAudioVbrEncoding": "true",
            "TranscodeReasons": "VideoCodecNotSupported,AudioCodecNotSupported",
            "allowVideoStreamCopy": "false",
            "allowAudioStreamCopy": "false",
        }
    )
    master = call_text("GET", f"/Videos/{item_id}/master.m3u8?{probe_params}", allow=(200,))
    if "#EXTM3U" not in (master or ""):
        return False
    media_playlist = _first_playlist_line(master)
    if not media_playlist:
        return False
    nested = call_text("GET", f"/Videos/{item_id}/{media_playlist}", allow=(200,))
    segment = _first_playlist_line(nested)
    if not segment:
        return False

    for _ in range(20):
        try:
            call_text("GET", f"/Videos/{item_id}/{segment}", allow=(200, 206))
            # The browser path that currently fails in production is the
            # dynamic HLS fMP4 segment endpoint, not playlist generation.
            call_text(
                "GET",
                f"/Videos/{item_id}/hls1/main/-1.mp4?{probe_params}&runtimeTicks=0&actualSegmentLengthTicks=0",
                allow=(200, 206),
            )
            return True
        except urllib.error.HTTPError:
            time.sleep(1)
    return False


def set_encoding_mode(
    token: str,
    hwaccel_type: str,
    enable_hardware_encoding: bool,
    prefer_native_decoder: bool,
    enable_tonemapping: bool,
    enable_vpp_tonemapping: bool,
    decoding_codecs,
) -> None:
    encoding = try_call("GET", "/System/Configuration/encoding", token=token) or {}
    if not encoding:
        return
    encoding["HardwareAccelerationType"] = hwaccel_type
    encoding["EnableHardwareEncoding"] = bool(enable_hardware_encoding)
    encoding["EnableTonemapping"] = bool(enable_tonemapping)
    encoding["EnableVppTonemapping"] = bool(enable_vpp_tonemapping)
    encoding["PreferSystemNativeHwDecoder"] = bool(prefer_native_decoder)
    encoding["HardwareDecodingCodecs"] = list(decoding_codecs)
    call("POST", "/System/Configuration/encoding", encoding, token=token, allow=(200, 204, 400))


def transcode_probe(token: str, user_id: str) -> bool:
    # Probe several high-risk items through Jellyfin's HLS transcode path.
    # Any failed probe means clients can hit fatal playback errors.
    candidates = []
    for _ in range(24):
        items = call(
            "GET",
            f"/Users/{user_id}/Items?Recursive=true&IncludeItemTypes=Movie,Episode&Limit=2000&Fields=Path,MediaSources,MediaStreams",
            token=token,
            allow=(200, 204),
        ) or {}
        candidates = []
        for item in items.get("Items") or []:
            sources = item.get("MediaSources") or []
            if not sources:
                continue
            item_id = (item.get("Id") or "").strip()
            if not item_id:
                continue
            for source in sources:
                media_source_id = (source.get("Id") or "").strip()
                if not media_source_id:
                    continue
                streams = source.get("MediaStreams") or item.get("MediaStreams") or []
                has_hevc = any(
                    (str(stream.get("Codec") or "").strip().lower() == "hevc")
                    and (str(stream.get("Type") or "").strip().lower() == "video")
                    for stream in streams
                )
                has_dovi_or_hdr = False
                for stream in streams:
                    stream_tokens = " ".join(
                        [
                            str(stream.get("VideoRangeType") or ""),
                            str(stream.get("VideoRange") or ""),
                            str(stream.get("CodecTag") or ""),
                            str(stream.get("Title") or ""),
                            str(stream.get("Profile") or ""),
                            str(stream.get("VideoDoViTitle") or ""),
                            str(stream.get("ColorPrimaries") or ""),
                            str(stream.get("ColorTransfer") or ""),
                        ]
                    ).strip().lower()
                    if any(
                        marker in stream_tokens
                        for marker in (
                            "dovi",
                            "dolby",
                            "vision",
                            "hdr",
                            "hdr10",
                            "hlg",
                            "bt2020",
                            "smpte2084",
                            "pq",
                        )
                    ):
                        has_dovi_or_hdr = True
                        break
                    if int(stream.get("DvProfile") or 0) > 0 or int(stream.get("DvVersionMajor") or 0) > 0:
                        has_dovi_or_hdr = True
                        break
                max_width = max(
                    [
                        int(stream.get("Width") or 0)
                        for stream in streams
                        if str(stream.get("Type") or "").strip().lower() == "video"
                    ]
                    or [0]
                )
                score = 0
                if has_hevc:
                    score += 4
                if has_dovi_or_hdr:
                    score += 4
                if max_width >= 3840:
                    score += 2
                source_hints = " ".join(
                    [
                        str(source.get("Path") or ""),
                        str(source.get("Name") or ""),
                        str(source.get("Container") or ""),
                        str(item.get("Name") or ""),
                        str(item.get("Path") or ""),
                    ]
                ).lower()
                if any(
                    token in source_hints
                    for token in (
                        "2160",
                        "4k",
                        "uhd",
                        "dovi",
                        "dolby",
                        "vision",
                        "hdr",
                        "dv.",
                        ".dv",
                        "h265",
                        "hevc",
                    )
                ):
                    score += 3
                candidates.append(
                    {
                        "score": score,
                        "item_id": item_id,
                        "media_source_id": media_source_id,
                        "has_hevc": has_hevc,
                        "has_dovi_or_hdr": has_dovi_or_hdr,
                        "max_width": max_width,
                    }
                )
        if candidates:
            break
        time.sleep(5)
    candidates.sort(
        key=lambda row: (
            -int(bool(row["has_dovi_or_hdr"] and row["has_hevc"])),
            -int(bool(row["has_dovi_or_hdr"])),
            -int(bool(row["has_hevc"])),
            -int(row["max_width"] >= 3840),
            -row["score"],
            row["item_id"],
            row["media_source_id"],
        )
    )
    if not candidates:
        # Fail closed when we cannot validate any media item. This keeps
        # playback reliable on fresh stacks where indexing is still converging.
        return False

    probes = []
    prioritized = [row for row in candidates if row["has_dovi_or_hdr"] and row["has_hevc"]]
    for row in prioritized + candidates:
        score = row["score"]
        item_id = row["item_id"]
        media_source_id = row["media_source_id"]
        if score <= 0:
            continue
        pair = (item_id, media_source_id)
        if pair in probes:
            continue
        probes.append(pair)
        if len(probes) >= 8:
            break
    if not probes:
        probe_item_id = candidates[0]["item_id"]
        probe_media_source_id = candidates[0]["media_source_id"]
        probes.append((probe_item_id, probe_media_source_id))

    for probe_item_id, probe_media_source_id in probes:
        if not probe_transcode_candidate(token, probe_item_id, probe_media_source_id):
            return False
    return True


base = None
for candidate_base in base_candidates:
    base = candidate_base
    for _ in range(90):
        try:
            call("GET", "/System/Info/Public", allow=(200, 204, 302))
            break
        except Exception:
            time.sleep(2)
    else:
        continue
    break
else:
    raise RuntimeError(f"Jellyfin did not become ready at any of: {', '.join(base_candidates)}")

try:
    call("POST", "/Startup/Configuration", {
        "UICulture": "en-US",
        "MetadataCountryCode": "US",
        "PreferredMetadataLanguage": "en",
    }, allow=(200, 204, 400))
    if password:
        call("POST", "/Startup/User", {"Name": user, "Password": password}, allow=(200, 204, 400))
    call("POST", "/Startup/RemoteAccess", {
        "EnableRemoteAccess": True,
        "EnableAutomaticPortMapping": False,
    }, allow=(200, 204, 400))
    call("POST", "/Startup/Complete", allow=(200, 204, 400))
except urllib.error.HTTPError:
    pass

token = None
auth = None
if password:
    auth = try_call("POST", "/Users/AuthenticateByName", {"Username": user, "Pw": password})
if not auth:
    startup_user = try_call("GET", "/Startup/User")
    existing_user = startup_user.get("Name") if startup_user else None
    if existing_user:
        auth = try_call("POST", "/Users/AuthenticateByName", {"Username": existing_user, "Pw": ""})
if not auth:
    for candidate_user in [auto_login_user, stremio_user, "media", "stremio"]:
        auth = try_call("POST", "/Users/AuthenticateByName", {"Username": candidate_user, "Pw": ""})
        if auth:
            break
token = auth.get("AccessToken") if auth else None

if token:
    max_streaming_bitrate = parse_positive_int(max_streaming_bitrate_raw, 12_000_000)
    info = try_call("GET", "/System/Info/Public", token=token) or {}
    server_id = (info.get("Id") or "").strip()
    admin_user_id = ensure_user(user, token)
    network = try_call("GET", "/System/Configuration/network", token=token) or {}
    if not network.get("EnablePublishedServerUriByRequest"):
        network["EnablePublishedServerUriByRequest"] = True
        call("POST", "/System/Configuration/network", network, token=token, allow=(200, 204, 400))

    config = try_call("GET", "/System/Configuration", token=token) or {}
    auto_user_id = ensure_user(auto_login_user, token)
    ensure_blank_password(auto_user_id, token)
    auto_auth = try_call("POST", "/Users/AuthenticateByName", {"Username": auto_login_user, "Pw": ""})
    auto_token = (auto_auth or {}).get("AccessToken") or token
    stremio_user_id = ensure_user(stremio_user, token)
    ensure_user_policy(admin_user_id, token, max_streaming_bitrate)
    ensure_user_policy(auto_user_id, token, max_streaming_bitrate)
    ensure_user_policy(stremio_user_id, token, max_streaming_bitrate)

    if config.get("AutoLoginUserId") != auto_user_id:
        config["AutoLoginUserId"] = auto_user_id
        call("POST", "/System/Configuration", config, token=token, allow=(200, 204, 400))

    if config.get("BaseUrl") != base_url:
        config["BaseUrl"] = base_url
        call("POST", "/System/Configuration", config, token=token, allow=(200, 204, 400))
    for name, path, collection_type in [
        ("Movies", "/data/media/movies", "movies"),
        ("TV", "/data/media/tv", "tvshows"),
    ]:
        os.makedirs(path, exist_ok=True)
        ensure_library(name, path, collection_type, token, admin_user_id)
    call("POST", "/Library/Refresh", token=token, allow=(200, 204, 400))

    current_hwaccel = (os.environ.get("JELLYFIN_HWACCEL_TYPE") or "").strip().lower()
    safe_qsv_codecs = ["h264", "mpeg2video", "vc1", "vp8", "vp9", "av1"]

    def apply_safe_hardware_mode(mode: str) -> bool:
        set_encoding_mode(
            token,
            mode,
            True,
            False,
            False,
            False,
            safe_qsv_codecs,
        )
        set_env_value(env_file, "JELLYFIN_HWACCEL_TYPE", mode)
        set_env_value(env_file, "JELLYFIN_HWACCEL_ENABLE_ENCODING", "true")
        set_env_value(env_file, "JELLYFIN_HWACCEL_ENABLE_TONEMAPPING", "false")
        set_env_value(env_file, "JELLYFIN_HWACCEL_ENABLE_VPP_TONEMAPPING", "false")
        set_env_value(env_file, "JELLYFIN_HWACCEL_PREFER_NATIVE_DECODER", "false")
        set_env_value(env_file, "JELLYFIN_HWACCEL_DECODING_CODECS", ",".join(safe_qsv_codecs))
        return transcode_probe(token, admin_user_id)

    probe_ok = transcode_probe(token, admin_user_id)
    safe_hw_applied = False

    # Recover from prior software fallback by actively re-probing hardware modes.
    if current_hwaccel == "none":
        for mode in ("qsv", "vaapi"):
            if apply_safe_hardware_mode(mode):
                safe_hw_applied = True
                probe_ok = True
                break

    if not probe_ok and current_hwaccel in {"qsv", "vaapi"} and not safe_hw_applied:
        safe_hw_applied = apply_safe_hardware_mode(current_hwaccel)
        probe_ok = safe_hw_applied

    if not probe_ok and not safe_hw_applied:
        for mode in ("qsv", "vaapi"):
            if mode == current_hwaccel:
                continue
            if apply_safe_hardware_mode(mode):
                safe_hw_applied = True
                probe_ok = True
                break

    if not probe_ok and not safe_hw_applied:
        set_encoding_mode(
            token,
            "none",
            False,
            False,
            False,
            False,
            [],
        )
        set_env_value(env_file, "JELLYFIN_HWACCEL_TYPE", "none")
        set_env_value(env_file, "JELLYFIN_HWACCEL_ENABLE_ENCODING", "false")
        set_env_value(env_file, "JELLYFIN_HWACCEL_ENABLE_TONEMAPPING", "false")
        set_env_value(env_file, "JELLYFIN_HWACCEL_ENABLE_VPP_TONEMAPPING", "false")
        set_env_value(env_file, "JELLYFIN_HWACCEL_PREFER_NATIVE_DECODER", "false")
        set_env_value(env_file, "JELLYFIN_HWACCEL_DECODING_CODECS", "")

    marker = (os.environ.get("JELLYFIN_SOFTWARE_TRANSCODE_MARKER") or "").strip()
    if marker:
        Path(marker).parent.mkdir(parents=True, exist_ok=True)
        marker_value = "fallback=safe-hw\n" if safe_hw_applied else "fallback=software\n"
        Path(marker).write_text(marker_value, encoding="utf-8")

    set_env_value(env_file, "JELLYFIN_AUTOLOGIN_USER", auto_login_user)
    set_env_value(env_file, "JELLYFIN_AUTO_AUTH_TOKEN", auto_token)
    autologin_params = urllib.parse.urlencode(
        {
            "serverid": server_id,
            "serverId": server_id,
            "userid": auto_user_id,
            "userId": auto_user_id,
            "api_key": auto_token,
            "accessToken": auto_token,
        }
    )
    default_public_base = f"http://{os.environ.get('VMCTL_RESOURCE_NAME', 'media-stack')}"
    autologin_base = (os.environ.get("VMCTL_HTTP_BASE_URL_SHORT") or default_public_base).rstrip("/")
    autologin_url = f"{autologin_base}:8097/web/#/home.html?{autologin_params}"
    set_env_value(env_file, "JELLYFIN_AUTOLOGIN_URL", autologin_url)
    ui_index = Path("/opt/media/config/caddy/ui-index")
    ui_index.mkdir(parents=True, exist_ok=True)
    (ui_index / "jellyfin-autologin.url").write_text(autologin_url + "\n", encoding="utf-8")
PY

if [[ -f "$JELLYFIN_SOFTWARE_TRANSCODE_MARKER" ]]; then
  rm -f "$JELLYFIN_SOFTWARE_TRANSCODE_MARKER"
  docker_compose up -d jellyfin
  docker_compose restart jellyfin
fi

if docker_compose config --services | grep -qx "caddy"; then
  set -a
  . "$ENV_FILE"
  set +a
  docker_compose up -d --force-recreate caddy
fi
