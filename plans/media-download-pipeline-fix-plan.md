# Media Request/Download/Import Pipeline Remediation Plan (Production-Ready)

Current date: 2026-04-25 (Australia/Melbourne)

## Objective

Make the end-to-end pipeline reliable and fully automated after `vmctl apply`:

`Seerr request -> Sonarr/Radarr search -> Prowlarr indexers -> Download clients (qBittorrent for torrents + SABnzbd for Usenet) -> Sonarr/Radarr import (atomic move/hardlinks) -> Jellyfin library refresh -> Jellystat “recently added” updates`

Constraints for this deliverable:

- Produce a deep investigation and remediation plan only.
- Do not implement code in this request.
- The plan is repo-specific to the current `vmctl` media stack implementation under `packs/`.

---

## What Exists Today (Repo Facts)

### Media stack composition (current)

The media VM role (`packs/roles/media_stack.toml`) renders and boots a Docker Compose stack at `/opt/media` using:

- Compose template: `packs/templates/docker-compose.media.hbs`
- Env template: `packs/templates/media.env.hbs` (synced to `/opt/media/.env` by `packs/scripts/bootstrap-media.sh`)
- Services enabled in `vmctl.toml` include: `seerr` (to be renamed to `seerr`), `sonarr`, `radarr`, `prowlarr`, `qbittorrent-vpn`, `jellyfin`, `jellystat` plus routing/aux services.

Provisioning scripts (executed as part of the role bootstrap) of direct relevance:

- qBittorrent provisioning: `packs/scripts/bootstrap-qbittorrent.sh`
- Sonarr/Radarr + Prowlarr provisioning: `packs/scripts/bootstrap-arr.sh`
- Seerr provisioning (currently named Seerr in-repo): `packs/scripts/bootstrap-seerr.sh` (to be renamed to `bootstrap-seerr.sh`)
- Jellyfin provisioning (libraries created at `/media/movies` and `/media/tv`): `packs/scripts/bootstrap-jellyfin.sh`
- Jellystat provisioning: `packs/scripts/bootstrap-jellystat.sh`
- Validation harness (currently config-only checks, not download/import): `packs/scripts/bootstrap-validate-streaming-stack.sh`
- Download-unpack helper (polls qB and attempts unpack + Arr rescan + Jellyfin refresh): `packs/scripts/bootstrap-download-unpack.sh`

### Current paths and categories (current)

From `packs/templates/media.env.hbs` and `bootstrap-media.sh`, current defaults are:

- Media mount inside containers: `${MEDIA_PATH}:/media` (default `${MEDIA_PATH}=/media`)
- Downloads:
  - Complete: `/media/downloads/complete`
  - Incomplete: `/media/downloads/incomplete`
- Libraries:
  - Movies: `/media/movies`
  - TV: `/media/tv`
- qBittorrent categories used by Arr:
  - Sonarr category: `tv`
  - Radarr category: `movies`

### Current Prowlarr defaults (current, problematic)

`packs/scripts/bootstrap-arr.sh` currently adds a small set of public torrent indexers if none exist:

- `Nyaa.si`, `1337x`, `EZTV`, `The Cowboy TV`, `YTS`

This does not align with the desired long-term strategy (avoid flaky/public trackers where possible) and it does not cover the requested Usenet-focused indexers list.

### Known misconfiguration risk already visible in current code

`bootstrap-arr.sh` uses the same Prowlarr `syncCategories` for both Sonarr and Radarr:

- `syncCategories: [5000, 5030, 5040]`

These are TV-oriented categories. Radarr should sync movie-oriented categories (2000-family). This can materially reduce Radarr search effectiveness and can contribute to “requests reach Radarr but nothing gets grabbed”.

---

## TRaSH Guides “Source of Truth” Targets

### File and folder structure (target)

Ref: https://trash-guides.info/File-and-Folder-Structure/

```
data
├── torrents
│   ├── movies
│   └── tv
├── usenet
│   ├── incomplete
│   └── complete
│       ├── movies
│       └── tv
└── media
    ├── movies
    └── tv
```

Key invariants:

- All apps must see identical paths (no container-specific remaps that require Remote Path Mapping).
- Downloads and libraries must be on the same filesystem to allow atomic moves and/or hardlinks.

### qBittorrent category/path behavior (target)

Per TRaSH qBittorrent categories guidance:

- Ref (Paths): https://trash-guides.info/Downloaders/qBittorrent/Paths/
- Ref (Categories): https://trash-guides.info/Downloaders/qBittorrent/How-to-add-categories/
- Use categories with “Save Path” as a subfolder under the configured Default Save Path.
- Ensure “Default Torrent Management Mode” is `Automatic` so downloads land in the category subfolder.

### Naming schemes (target)

Use TRaSH naming scheme recommendations for Sonarr and Radarr so imports are deterministic and upgrade-safe.

- Ref (Sonarr naming): https://trash-guides.info/Sonarr/Sonarr-recommended-naming-scheme/
- Ref (Radarr naming): https://trash-guides.info/Radarr/Radarr-recommended-naming-scheme/

### Quality profiles / scoring (target)

Do not hand-build TRaSH quality profiles and custom formats via bespoke scripting. Use a TRaSH-approved sync tool (Recyclarr is the simplest CLI-first fit) to keep naming, quality definitions, quality profiles, and custom formats aligned over time.

- Ref (Guide Sync): https://trash-guides.info/Guide-Sync/
- Ref (Recyclarr): https://trash-guides.info/Recyclarr/

### FlareSolverr (expectations)

TRaSH flags FlareSolverr as “non-functional” and not a reliable solution. Plan should not depend on FlareSolverr for core operation.

- Ref: https://trash-guides.info/Prowlarr/prowlarr-setup-flaresolverr/

---

## Investigation Plan (Deep, Hypothesis-Driven)

This section is the “do first” checklist. It is structured as:

- Hypothesis
- Evidence to gather
- Exact logs/endpoints to inspect
- Confirm/reject criteria

### 1) Seerr requests reach Sonarr/Radarr but do not reach qBittorrent

#### H1: Seerr requests are not being auto-approved or not being “Add + Search”

Evidence to gather:

- Seerr request status transitions (Pending -> Approved -> Processing -> Available).
- Whether Seerr is configured to “Prevent Search” for Sonarr/Radarr integrations.

Inspect:

- Seerr public settings (should show initialized):
  - `GET http://media-stack:5056/api/v1/settings/public`
- Seerr internal status:
  - `GET http://media-stack:5056/api/v1/status`
- Seerr config file used by bootstrap:
  - `/opt/media/config/seerr/settings.json` (after rename; update bootstrap to write here)
- Seerr container logs:
  - `docker compose -p media --project-directory /opt/media logs --tail=300 seerr`

Confirm/reject:

- Reject H1 if new requests show as Approved and Seerr integration entries have `"preventSearch": false` in `settings.json` (bootstrap sets this already).
- Confirm H1 if requests remain Pending, or if requests are Approved but “search” never runs (no Arr activity in logs, no Arr commands created).

#### H2: Sonarr/Radarr are receiving the media entry but are not monitored / not searching (profile/root mismatch)

Evidence to gather:

- For a requested show/movie, verify it exists in Sonarr/Radarr and is monitored.
- Verify Seerr selected root folder and quality profile IDs exist and match the intended defaults.

Inspect:

- Sonarr:
  - `GET http://media-stack:8989/api/v3/system/status`
  - `GET http://media-stack:8989/api/v3/rootfolder`
  - `GET http://media-stack:8989/api/v3/series?includeSeasonImages=false` (filter by title)
  - `GET http://media-stack:8989/api/v3/wanted/missing`
  - `GET http://media-stack:8989/api/v3/queue`
- Radarr:
  - `GET http://media-stack:7878/api/v3/system/status`
  - `GET http://media-stack:7878/api/v3/rootfolder`
  - `GET http://media-stack:7878/api/v3/movie` (filter by title)
  - `GET http://media-stack:7878/api/v3/wanted/missing`
  - `GET http://media-stack:7878/api/v3/queue`
- Seerr integration config (bootstrap writes these):
  - `/opt/media/config/seerr/settings.json` (`sonarr[0].activeProfileId`, `sonarr[0].activeDirectory`, same for radarr)

Confirm/reject:

- Confirm H2 if requested items exist but are unmonitored, or if `rootFolderPath` is invalid/inaccessible, or if default profiles are “Any” and effectively reject all releases after TRaSH scoring is applied.
- Reject H2 if items are monitored and “Search” commands appear in Arr history/logs.

#### H3: Indexers are failing (search returns 0 results) so nothing is grabbed (most likely given Sonarr indexer warning)

Evidence to gather:

- Sonarr health warnings and indexer statuses.
- Prowlarr indexer health and test results.

Inspect:

- Sonarr health:
  - `GET http://media-stack:8989/api/v3/health`
  - UI warning: “Indexers unavailable due to failures…”
- Sonarr logs (provided):
  - `http://media-stack:8989/logfile/sonarr.debug.txt`
  - `http://media-stack:8989/logfile/sonarr.txt`
- Radarr logs (for symmetry; check via UI if filenames differ):
  - `http://media-stack:7878/logfile/radarr.debug.txt`
  - `http://media-stack:7878/logfile/radarr.txt`
- Prowlarr:
  - `GET http://media-stack:9696/api/v1/system/status`
  - `GET http://media-stack:9696/api/v1/indexer`
  - `GET http://media-stack:9696/api/v1/indexerstatus` (if available in your Prowlarr version)
  - Prowlarr logfile endpoints (check via UI if filenames differ):
    - `http://media-stack:9696/logfile/prowlarr.txt`
    - `http://media-stack:9696/logfile/prowlarr.debug.txt`
  - Prowlarr UI “System -> Logs” and “Indexers -> Test”
  - Container logs: `docker compose -p media --project-directory /opt/media logs --tail=500 prowlarr`

Confirm/reject:

- Confirm H3 if Sonarr/Radarr interactive search returns “no results” and/or indexer test failures are present for all indexers or for the only ones enabled.
- Reject H3 only if at least one indexer is healthy and searching returns releases.

#### H4: Sonarr/Radarr download client is misconfigured (auth/network/category mismatch)

Evidence to gather:

- Arr download client configuration and test results.
- qBittorrent API reachability from Arr containers (not just from the LAN).

Inspect:

- Download clients:
  - Sonarr: `GET http://media-stack:8989/api/v3/downloadclient`
  - Radarr: `GET http://media-stack:7878/api/v3/downloadclient`
- qBittorrent API:
  - `GET http://media-stack:8080/api/v2/app/version`
  - qBittorrent logs:
    - `/opt/media/config/qbittorrent/qBittorrent/logs/`
    - `docker compose -p media --project-directory /opt/media logs --tail=300 qbittorrent-vpn`

Confirm/reject:

- Confirm H4 if Arr shows download client test failures, or if qBittorrent logs show repeated auth failures from Sonarr/Radarr IPs, or if the category fields don’t match the intended categories.
- Reject H4 if Arr download client tests succeed and qB receives torrents from manual grabs, but automated grabs don’t happen (points back to H3/H2).

#### H5: Prowlarr -> Arr sync categories are wrong for Radarr (movie searches constrained incorrectly)

Evidence to gather:

- Prowlarr Applications configuration for Radarr and Sonarr.
- Categories used when Prowlarr creates Torznab indexers in Radarr.

Inspect:

- Prowlarr apps:
  - `GET http://media-stack:9696/api/v1/applications`
- Radarr indexers created by Prowlarr:
  - `GET http://media-stack:7878/api/v3/indexer`

Confirm/reject:

- Confirm H5 if Radarr indexers are created with TV categories (5000-family) and searches return nothing while Sonarr works.
- Reject H5 if Radarr indexers have correct movie categories and still fail (then it’s health/auth/indexer-specific).

---

### 2) Sonarr “Indexers unavailable due to failures: The Pirate Bay (Prowlarr)”

#### H1: The Pirate Bay indexer is blocked/Cloudflare/DDoS-Guarded and fails consistently

Evidence to gather:

- Sonarr debug log entries for that indexer.
- Prowlarr indexer test output and HTTP failure codes.

Inspect:

- Sonarr logs:
  - `http://media-stack:8989/logfile/sonarr.debug.txt`
  - Search within debug log for:
    - `Torznab`, `The Pirate Bay`, `HttpRequest`, `proxy`, `Cloudflare`, `captcha`, `TLS`, `timeout`
- Prowlarr indexer:
  - UI: Indexers -> The Pirate Bay -> Test
  - API: `GET http://media-stack:9696/api/v1/indexer` (locate TPB, check `enabled`, tags, and settings)

Confirm/reject:

- Confirm if indexer tests fail repeatedly and error type is consistent (403/522/timeout/handshake).

Remediation decision:

- Remove TPB. It is a known flaky/public tracker and conflicts with the desired indexer strategy.

#### H2: Prowlarr is syncing an unwanted indexer into Sonarr (stale config drift)

Evidence to gather:

- Whether TPB exists in Prowlarr and is enabled.
- Whether Sonarr indexers list contains only Prowlarr-managed entries.

Inspect:

- Prowlarr indexers list and tags.
- Sonarr indexers:
  - `GET http://media-stack:8989/api/v3/indexer`

Confirm/reject:

- Confirm if TPB exists in Prowlarr and sync is enabled, and Sonarr’s TPB entry is labelled “(Prowlarr)”.

Remediation:

- Delete/disable indexer in Prowlarr, then run “Indexer Sync” to push changes to Sonarr/Radarr.

#### H3: Network/proxy/VPN routing breaks outbound requests for indexers

Evidence to gather:

- Whether Prowlarr is routed through VPN (it is not configured as `vpn_route_through_gluetun` in this repo).
- DNS resolution, IPv6 vs IPv4 issues, or blocked egress.

Inspect:

- Prowlarr container logs.
- Host egress from the VM:
  - `curl -fsSL https://api.ipify.org` (from host and from inside container)
- If you use a VPN/proxy for indexers, follow TRaSH Prowlarr proxy guidance (do not route the whole app blindly).

Confirm/reject:

- Confirm if failures are timeouts/DNS across multiple indexers, not just TPB.

Remediation:

- Keep Prowlarr on normal egress; only route the torrent client through VPN (current design), unless you explicitly need Prowlarr via VPN/proxy for specific tracker access.

#### H4: FlareSolverr is assumed as a fix (it should not be)

TRaSH explicitly warns FlareSolverr is currently non-functional and should not be relied on.

Remediation stance:

- Do not build a “production success” plan that depends on FlareSolverr.
- Prefer indexers that do not require Cloudflare circumvention: private trackers with stable APIs or paid Usenet indexers.

#### H5: Long-term indexer strategy is mismatched to the current stack (Usenet indexers listed but no Usenet downloader exists)

The target indexers list in the prompt contains primarily Usenet indexers (e.g., NZBGeek, DrunkenSlug, NZBFinder). Prowlarr can manage these, but Sonarr/Radarr must also be provisioned with a Usenet download client (SABnzbd or NZBGet) to actually download NZBs.

Confirm:

- If you add Usenet indexers but only have qBittorrent configured, Sonarr/Radarr can find releases but cannot download them.

Remediation:

- Add SABnzbd (recommended) as a first-class service in the media pack, and provision it with TRaSH category/path layout.

---

### 3) Jellystat “Recently Added” is empty

Treat this as a downstream symptom until proven otherwise.

#### H1: No successful imports -> Jellyfin has no new items -> Jellystat shows nothing

Evidence to gather:

- Jellyfin libraries have content.
- Sonarr/Radarr history shows imports.

Inspect:

- Jellyfin:
  - `GET http://media-stack:8096/System/Info/Public`
  - With token:
    - `GET http://media-stack:8096/Items/Latest?Limit=20&IncludeItemTypes=Movie,Episode`
  - Libraries are created by bootstrap at:
    - Movies: `/media/movies`
    - TV: `/media/tv`
- Sonarr/Radarr:
  - `GET /api/v3/history` (filter for “Imported”)
  - Container logs for import errors.

Confirm/reject:

- Confirm if Jellyfin latest items is empty and Arr has no import events.

#### H2: Jellyfin libraries point at paths that do not match where Arr is importing to

Evidence to gather:

- Jellyfin virtual folder paths vs Arr root folders vs download client paths.

Inspect:

- Jellyfin virtual folders:
  - `GET /Library/VirtualFolders` (requires token)
- Arr root folder paths:
  - `GET /api/v3/rootfolder`

Confirm/reject:

- Confirm if Jellyfin libraries are not pointing to the Arr root folders.

#### H3: Jellystat is not fully configured or is configured against the wrong Jellyfin base URL/token

Evidence to gather:

- Jellystat configured state and stored Jellyfin host.
- Jellystat container logs for auth errors.

Inspect:

- Jellystat configured state:
  - `GET http://media-stack:3000/auth/isConfigured` (bootstrap uses this)
- Jellystat logs:
  - `docker compose -p media --project-directory /opt/media logs --tail=400 jellystat`
- Jellystat database (if needed):
  - `docker compose -p media --project-directory /opt/media exec -T jellystat-db psql -U jellystat -d jellystat -c '\\dt'`
  - Verify `app_config` points at `JF_HOST` and has a working API key.

Confirm/reject:

- Confirm if Jellystat logs show 401/403 or connection errors to Jellyfin.

#### H4: Jellyfin library refresh is not being triggered (or scheduled) after imports

Evidence to gather:

- Jellyfin scheduled tasks configuration.
- Whether Arr notifies Jellyfin or whether a post-import hook exists.

Inspect:

- Jellyfin scheduled tasks in UI.
- Arr “Connect” settings for Jellyfin (if configured).
- Current repo behavior: `bootstrap-jellyfin.sh` runs `POST /Library/Refresh` once at bootstrap; `bootstrap-download-unpack.sh` may run refresh after processing qB entries.

Confirm/reject:

- Confirm if content exists on disk but Jellyfin doesn’t show it until a manual scan.

Remediation:

- Add explicit post-import refresh triggers (webhook or scheduled job) and validate in tests.

---

### 4) Fully provision Sonarr/Radarr automation (works immediately after `vmctl apply`)

This is not “a single fix”; it’s closing several configuration gaps:

- TRaSH paths + hardlinks/atomic moves.
- qBittorrent categories/paths.
- Usenet downloader addition (if using Usenet indexers).
- TRaSH naming, quality definitions, quality profiles, custom formats (Recyclarr).
- Indexer strategy and health monitoring.
- Seerr defaults aligned to those profiles and roots.

The rest of this plan is the remediation design.

---

## Remediation Design (Implementation Strategy)

Execute this in phases, each with TDD gates and rollback points.

### Planned Repo Changes (Explicit File List)

These are the concrete repo locations that will be modified/added during implementation (not in this request):

- Templates
  - `packs/templates/media.env.hbs` (centralize new `/data` roots, categories, downloader URLs, indexer credential env vars)
  - `packs/templates/media-index.html.hbs` (rename UI label/link from Seerr to Seerr)
  - `packs/templates/docker-compose.media.hbs` (only if new services need compose-specific overrides)
- Services
  - `packs/services/qbittorrent-vpn.toml` (mount path `/data`, if adopting `/data`)
  - `packs/services/sonarr.toml`, `packs/services/radarr.toml`, `packs/services/jellyfin.toml` (mount path `/data`)
  - `packs/services/seerr.toml` (to be renamed to `packs/services/seerr.toml`)
  - `packs/services/caddy.toml` (rename env var injection from `SEERR_API_KEY` to `SEERR_API_KEY`, if still needed)
  - `packs/services/prowlarr.toml` (mount path changes not required, but may be needed for shared helpers/config)
  - Add: `packs/services/sabnzbd.toml`
  - Add: `packs/services/recyclarr.toml` (recommended)
- Bootstrap/provisioning scripts
  - `packs/scripts/bootstrap-media.sh` (create TRaSH directory layout under the data root; stop creating legacy `/media/movies` and `/media/tv`)
  - `packs/scripts/bootstrap-qbittorrent.sh` (set TRaSH paths, AutoTMM, and categories)
  - `packs/scripts/bootstrap-arr.sh` (root folders to `/data/media/tv` and `/data/media/movies`, correct Prowlarr sync categories per app, add SABnzbd download client, stop auto-adding public indexers by default)
  - `packs/scripts/bootstrap-jellyfin.sh` (libraries to `/data/media/tv` and `/data/media/movies`)
  - `packs/scripts/bootstrap-seerr.sh` (to be renamed to `packs/scripts/bootstrap-seerr.sh`; choose default quality profile by name; update root paths)
  - `packs/scripts/bootstrap-jellystat.sh` (ensure `JF_HOST` is internal and stable; add validation)
  - `packs/scripts/bootstrap-download-unpack.sh` (update paths; confirm Arr command semantics; make optional)
  - `packs/scripts/bootstrap-validate-streaming-stack.sh` (add indexer health + import + Jellystat checks)
- Roles/config
  - `packs/roles/media_stack.toml` (add `sabnzbd` and `recyclarr` services; add `bootstrap-sabnzbd.sh` and `bootstrap-recyclarr.sh` in bootstrap order)
  - `vmctl.toml` (`resources.features.media_services.services` add `sabnzbd`/`recyclarr`; rename service `seerr` -> `seerr`; add `[env]` keys for indexer credentials and SABnzbd credentials)
  - `packs/templates/caddyfile.media.hbs` (update `reverse_proxy seerr:5055` to `reverse_proxy seerr:5055` after service rename)

---

### Workstream: Rename Seerr/seerr -> Seerr/seerr (Repo-Wide)

We are using the Seerr v3.2.0 image (`ghcr.io/seerr-team/seerr:v3.2.0`), so the repo should stop using the “Seerr” name to reduce cognitive overhead and to match the upstream product name.

Implementation steps (must be exhaustive and mechanical):

1. Rename service and pack files
   - `packs/services/seerr.toml` -> `packs/services/seerr.toml`
   - Update the service `name =` field from `seerr` to `seerr`
2. Rename bootstrap scripts
   - `packs/scripts/bootstrap-seerr.sh` -> `packs/scripts/bootstrap-seerr.sh`
   - Update all internal references to config paths and env vars as described below
3. Update templates and routing
   - `packs/templates/caddyfile.media.hbs`: `reverse_proxy seerr:5055` -> `reverse_proxy seerr:5055`
   - Keep the external listener at `:5056` unless there is a strong reason to change it (port stability matters)
4. Update Docker Compose generation inputs
   - Ensure the generated compose has a `seerr:` service key (not `seerr:`)
5. Update `.env` contract
   - Rename variables:
     - `SEERR_URL` -> `SEERR_URL`
     - `SEERR_INTERNAL_URL` -> `SEERR_INTERNAL_URL`
     - `SEERR_API_KEY` -> `SEERR_API_KEY`
   - Keep a short transition window where old keys are read (read both, write new) to avoid bricking existing deployments
6. Update role config
   - `packs/roles/media_stack.toml`: replace `seerr` with `seerr` in `features.media_services.services` and `scripts.bootstrap`
   - `vmctl.toml`: replace service name `seerr` with `seerr` in `resources.features.media_services.services`
   - `vmctl.toml [env]`: rename `SEERR_API_KEY` to `SEERR_API_KEY`
7. Update all text references and docs
   - Replace `Seerr/seerr` wording in docs/plans with `Seerr/seerr`
8. Validation gates
   - After renaming, the existing endpoint `http://media-stack:5056` must still serve Seerr UI and API (`/api/v1/status`, `/api/v1/settings/public`)
   - `bootstrap-validate-streaming-stack.sh` must be updated to check `seerr` container/service instead of `seerr`

### Bootstrap Sequencing (Make It Deterministic)

During implementation, update the `packs/roles/media_stack.toml` `scripts.bootstrap` order so dependencies are satisfied and defaults are chosen after TRaSH profiles exist:

1. `bootstrap-media.sh` (creates directories, renders env, starts compose)
2. `bootstrap-jellyfin.sh` (ensures Jellyfin is initialized and libraries point at `/data/media/movies` and `/data/media/tv`)
3. `bootstrap-qbittorrent.sh` (ensures qB is reachable, paths set, categories exist)
4. `bootstrap-sabnzbd.sh` (required if you implement the target Usenet indexers list; ensures Usenet paths + categories exist)
5. `bootstrap-arr.sh` (root folders, download clients, Prowlarr app sync with correct categories)
6. `bootstrap-recyclarr.sh` (sync TRaSH naming/qualities/profiles/custom formats)
7. `bootstrap-seerr.sh` (configure integrations using profile IDs by name, matching TRaSH profiles)
8. `bootstrap-jellystat.sh` (configure analytics connection to Jellyfin)
9. `bootstrap-validate-streaming-stack.sh` (expanded to validate the full pipeline readiness)

This ordering prevents Seerr from locking in “first profile” defaults before Recyclarr creates the intended profiles.

### Phase 0: Baseline “Observability + TDD Harness” (before changing behavior)

Goal: Make failures reproducible and diagnosable, and add failing checks that capture the current broken state.

#### 0.1 Add a dedicated pipeline validator (extend the existing one)

Existing validator: `packs/scripts/bootstrap-validate-streaming-stack.sh` currently validates:

- services reachable
- Seerr initialized and integrations exist
- Sonarr/Radarr have qB download client configured
- basic Jellyfin plugin checks

Enhance it (plan changes only) to add *failing checks* for:

- Prowlarr app sync category correctness (Radarr must not use TV-only categories).
- Indexer health:
  - In Prowlarr: all enabled indexers must have last status OK (or pass a test call).
  - In Sonarr/Radarr: `GET /api/v3/health` must not contain “Indexer” failures.
- Download client reachability:
  - Sonarr/Radarr “test download client” using their API endpoint (or validate by issuing a qB auth and simple API call from inside the Sonarr/Radarr containers).
- Import pipeline readiness:
  - Hardlink/atomic move capability check: downloads and library roots resolve to same filesystem (stat device ID check).
- Jellyfin and Jellystat data path alignment:
  - Jellyfin virtual folder paths must match the configured library roots.
  - Jellystat configured state must be `>=2` and must point at the internal Jellyfin URL.

Concrete validation script approach:

- Add a new optional validator shell script under `/opt/media/validators.d/` (supported by the existing validator runner near the end of `bootstrap-validate-streaming-stack.sh`).
- Keep it idempotent and fast (no real downloads).

Example validator (bash + python + curl) skeleton:

```bash
#!/usr/bin/env bash
set -euo pipefail

ENV_FILE=/opt/media/.env
set -a
. "$ENV_FILE"
set +a

cfg_root="${CONFIG_PATH:-/opt/media/config}"
sonarr_key="$(python3 - <<'PY'
import xml.etree.ElementTree as ET
print(ET.parse("/opt/media/config/sonarr/config.xml").getroot().findtext("ApiKey") or "")
PY
)"

curl -fsS -H "X-Api-Key: $sonarr_key" "http://127.0.0.1:8989/api/v3/health" \
  | python3 - <<'PY'
import json,sys
issues=json.load(sys.stdin)
bad=[i for i in issues if "Indexer" in (i.get("source") or "") or "indexer" in (i.get("message") or "").lower()]
if bad:
  raise SystemExit("sonarr has indexer health failures: " + json.dumps(bad[:3]))
PY
```

This validator should fail in the current broken state and become green as fixes land.

#### 0.2 Capture a “golden failure” packet

For the “Seerr request doesn’t download” issue, capture the state before any fix:

- Seerr request JSON (via UI export or DB entry).
- Sonarr/Radarr series/movie object and queue state.
- Sonarr/Radarr health output.
- Prowlarr indexer statuses and last error.
- qBittorrent logs around the request time window.

Store these artifacts under a predictable location on the VM for forensics:

- Directory naming convention: `/var/lib/vmctl/diagnostics/media-pipeline/YYYYmmddTHHMMSSZ/` (example: `/var/lib/vmctl/diagnostics/media-pipeline/20260425T120102Z/`)

Add a script later (implementation) to generate this packet on demand; for now the plan defines the artifact list.

#### 0.3 UI Smoke Verification (Playwright MCP + Screenshots)

In addition to curl/API/CLI checks, use the Playwright MCP to verify UIs render expected content after each phase and after the full end-to-end pipeline test.

Why:

- Many regressions are “UI loads but is broken” (JS errors, auth redirects, empty tables) and won’t be caught by a 200-only health check.
- Playwright can capture screenshots as objective evidence for the diagnostics packet.

UI checklist (URLs and expectations):

- Portal (Caddy):
  - `http://media-stack/` loads and contains links/tiles for: Seerr, Sonarr, Radarr, Prowlarr, qBittorrent, Jellyfin, Jellystat
- Seerr:
  - `http://media-stack:5056/` loads and the UI is interactive (not a blank page)
  - After the pipeline test request is created, Seerr shows it in Requests
- Sonarr:
  - `http://media-stack:8989/` loads and the Queue/Wanted pages show data (even if empty, page should render without errors)
  - Download client test shows qBittorrent (and SABnzbd if enabled) as healthy
- Radarr:
  - `http://media-stack:7878/` loads and the Queue/Wanted pages render
  - Indexers list is populated with Prowlarr-managed indexers
- Prowlarr:
  - `http://media-stack:9696/` loads and Indexers page shows enabled indexers as healthy
- qBittorrent:
  - `http://media-stack:8080/` loads and Categories includes `tv` and `movies`
- Jellyfin:
  - `http://media-stack:8097/` loads (no-login proxy) and the Movies/TV libraries render
- Jellystat:
  - `http://media-stack:3000/` loads and “Recently Added” shows the test import after the end-to-end run

Artifacts to capture with Playwright MCP:

- One screenshot per UI root page after provisioning completes
- One screenshot per UI after the end-to-end test import (showing the new media in Jellyfin and Jellystat “Recently Added”)
- Store under the diagnostics packet directory: `/var/lib/vmctl/diagnostics/media-pipeline/YYYYmmddTHHMMSSZ/ui/`

---

### Phase 1: Adopt TRaSH File/Folder Structure with a Single Consistent Container Path

Goal: eliminate path mismatches permanently and enable atomic moves/hardlinks.

#### 1.1 Choose the canonical in-container root path

Recommendation:

- Use `/data` inside containers (matches TRaSH examples).
- Keep the host mountpoint configurable via `vmctl.toml` (`resources.features.storage.media_path`).

Concrete repo changes later (not implementing now):

- Update media service mounts in:
  - `packs/services/*.toml` where mounts currently use `"${MEDIA_PATH}:/media"` to instead use `"${MEDIA_PATH}:/data"`.
- Update all provisioning scripts that reference `/media/` paths to use `/data/` paths.
- Update `.env` template defaults accordingly.

#### 1.2 Target directories (inside containers)

Create and manage:

- Downloads (torrents):
  - `/data/torrents/movies`
  - `/data/torrents/tv`
  - `/data/torrents/.incomplete`
- Downloads (usenet, if enabled):
  - `/data/usenet/incomplete`
  - `/data/usenet/complete/movies`
  - `/data/usenet/complete/tv`
- Libraries:
  - `/data/media/movies`
  - `/data/media/tv`

This matches TRaSH’s recommended layout.

#### 1.3 Migration strategy from current layout (safe, production)

If you already have content under `/media/movies`, `/media/tv`, `/media/downloads/complete`, `/media/downloads/incomplete`:

- Stop Arr + Jellyfin to avoid concurrent writes.
- Move/merge:
  - `/media/movies -> /media/data/media/movies`
  - `/media/tv -> /media/data/media/tv`
  - `/media/downloads/complete -> /media/data/torrents` (split by category if needed)
  - `/media/downloads/incomplete -> /media/data/torrents/.incomplete`
- Create symlinks temporarily for backward compatibility during rollout:
  - `/media/movies -> /media/data/media/movies`
  - `/media/tv -> /media/data/media/tv`
  - `/media/downloads/complete -> /media/data/torrents`
  - `/media/downloads/incomplete -> /media/data/torrents/.incomplete`
- Switch containers to mount `/data` and update Arr/Jellyfin paths.
- Remove symlinks only after validation passes and no legacy paths are referenced.

Rollback:

- If needed, revert mounts and revert Arr/Jellyfin root folders, using the symlinks to keep content visible.

---

### Phase 2: qBittorrent Provisioning (TRaSH-Aligned Paths + Categories)

Goal: ensure Arr can reliably route downloads into category folders, and that completed downloads are importable without path mapping.

#### 2.1 qBittorrent settings to enforce

Apply these via qB API (preferred) or `qBittorrent.conf` + setPreferences:

- Default Save Path: `/data/torrents`
- Keep incomplete torrents in: `/data/torrents/.incomplete` and enable it
- Default Torrent Management Mode: `Automatic` (AutoTMM enabled)
- Disable problematic WebUI protections in a controlled LAN environment (repo already disables CSRF/clickjacking in `bootstrap-qbittorrent.sh`)

#### 2.2 Categories to create

Create categories that match Arr download client categories and map to subfolders:

- `tv` -> save path `tv`
- `movies` -> save path `movies`

Optionally support additional explicit categories used in some setups:

- `sonarr` (alias to `tv`)
- `radarr` (alias to `movies`)

Keep categories minimal to reduce drift. The important thing is that the category used by Arr matches a defined qB category.

#### 2.3 qBittorrent API provisioning examples

Login and create categories (example):

```bash
set -euo pipefail

ENV_FILE=/opt/media/.env
set -a
. "$ENV_FILE"
set +a

QBIT_BASE="${QBITTORRENT_URL:-http://127.0.0.1:8080}"
QBIT_USER="${QBITTORRENT_USERNAME:-admin}"
QBIT_PASS="${QBITTORRENT_PASSWORD:-adminadmin}"

cookie="$(curl -fsS -i --data-urlencode "username=$QBIT_USER" --data-urlencode "password=$QBIT_PASS" \
  "$QBIT_BASE/api/v2/auth/login" | awk -F': ' 'tolower($1)=="set-cookie"{print $2}' | head -n1 | cut -d';' -f1)"

# Set global preferences (paths + automatic category management)
prefs_json='{
  "save_path": "/data/torrents",
  "temp_path_enabled": true,
  "temp_path": "/data/torrents/.incomplete",
  "auto_tmm_enabled": true
}'
curl -fsS -H "Cookie: $cookie" --data-urlencode "json=$prefs_json" "$QBIT_BASE/api/v2/app/setPreferences" >/dev/null

# Create categories
curl -fsS -H "Cookie: $cookie" --data-urlencode "category=tv" --data-urlencode "savePath=tv" \
  "$QBIT_BASE/api/v2/torrents/createCategory" || true
curl -fsS -H "Cookie: $cookie" --data-urlencode "category=movies" --data-urlencode "savePath=movies" \
  "$QBIT_BASE/api/v2/torrents/createCategory" || true
```

Validation checks:

- `GET /api/v2/torrents/categories` includes `tv` and `movies`.
- A torrent added with category `tv` stores under `/data/torrents/tv` (not the root).

---

### Phase 3: Add a Usenet Downloader (Required to Use the Requested Indexer Set)

Goal: support the target indexers list (mostly Usenet) and provide fallback when torrent trackers are unavailable.

#### 3.1 Add SABnzbd as a first-class service

Concrete repo changes later (not implementing now):

- Add `packs/services/sabnzbd.toml` (LinuxServer or official image).
- Mount `/data` consistently.
- Expose UI port (e.g., 8085:8080).
- Add `sabnzbd` to the enabled services lists:
  - `vmctl.toml` -> `resources.features.media_services.services`
  - `packs/roles/media_stack.toml` -> `features.media_services.services`
- Add bootstrap script `packs/scripts/bootstrap-sabnzbd.sh` that configures:
  - Temporary + final folders:
    - Incomplete: `/data/usenet/incomplete`
    - Complete: `/data/usenet/complete`
  - Categories:
    - `tv` -> `/data/usenet/complete/tv`
    - `movies` -> `/data/usenet/complete/movies`
  - API key extraction for DRY config (write back to `/opt/media/.env` if needed).

#### 3.2 Sonarr/Radarr provisioning changes

Provision both download clients:

- qBittorrent (torrent)
- SABnzbd (usenet)

Ensure categories match across:

- Prowlarr indexer -> indexer categories
- Arr download client categories
- Downloader categories

#### 3.3 Fallback strategy (required)

Define a clear priority order:

1. Usenet (primary, stable): Paid/paid-tier indexers + reliable providers.
2. Private torrent trackers (secondary): BTN if available, plus any other private tracker you have access to.
3. Public trackers (last resort, optional and off by default): only if explicitly enabled.

Operationalize fallback:

- Keep public indexers disabled by default.
- Enable “Automatic Search” only for stable indexers; keep limited/free indexers in an “Interactive Search” profile to avoid API bans.

---

### Phase 4: Prowlarr Provisioning (Indexer Strategy + Health + Correct App Sync)

Goal: remove flaky defaults, add the desired indexers, and ensure correct sync into Sonarr/Radarr.

#### 4.1 Correct the Sonarr vs Radarr syncCategories split

Concrete remediation:

- Sonarr app sync categories: TV categories (5000-family).
- Radarr app sync categories: Movie categories (2000-family).

Implementation detail (later): adjust `ensure_prowlarr_app_sync()` in `packs/scripts/bootstrap-arr.sh` to accept app-specific category lists.

Validation:

- `GET /api/v1/applications` shows Radarr has movie categories and Sonarr has TV categories.
- `GET Radarr /api/v3/indexer` shows indexers created with correct categories.

#### 4.2 Replace/remove unreliable indexers

Immediate fix for current reported warning:

- Remove “The Pirate Bay” in Prowlarr, sync, and verify Sonarr health clears.

Long-term:

- Avoid public trackers as the baseline.
- Keep a small number of high-signal indexers enabled rather than many noisy ones.

#### 4.3 Add the target indexers set (where available)

Target list provided (mostly Usenet):

- BroadcastTheNet (torrent, private)
- OMGWTFNZBS, NZBFinder, NZBGeek, NinjaCentral, DrunkenSlug, Usenet Crawler, abNZB, altHUB, SceneNZB, PlanetNZB (usenet)

Provisioning approach (robust):

- Use Prowlarr API to add indexers from `/api/v1/indexer/schema` entries.
- Centralize credentials in `vmctl.toml` `[env]` and render into `/opt/media/.env` (do not hardcode in scripts).
- For limited API indexers:
  - Configure Prowlarr Sync Profiles and apply query/grab limits to avoid bans.

Recommended baseline (practical, “high signal”):

- Usenet primary (Automatic Search enabled, RSS enabled if your API limits support it):
  - NZBGeek
  - DrunkenSlug
  - NinjaCentral
  - NZBFinder
- Usenet secondary backups (Automatic Search enabled, RSS disabled, strict API limits):
  - OMGWTFNZBS
  - SceneNZB
  - PlanetNZB
  - altHUB
  - abNZB
  - Usenet Crawler
- Torrent (only if you have access; keep count small):
  - BroadcastTheNet

Policy decisions to enforce in provisioning:

- Remove/disable all public torrent indexers that the current bootstrap can add (`Nyaa.si`, `1337x`, `EZTV`, `The Cowboy TV`, `YTS`) unless explicitly enabled via config.
- Remove/disable “The Pirate Bay” to clear the current Sonarr warning and to align with the “avoid flaky/public trackers” requirement.

Sync profile configuration (Prowlarr) to implement:

- Create three Sync Profiles:
  - `RSS + Automatic` (Enable RSS, Enable Automatic Search, Disable Interactive Search)
  - `Automatic Only` (Disable RSS, Enable Automatic Search, Enable Interactive Search)
  - `Interactive Only` (Disable RSS, Disable Automatic Search, Enable Interactive Search)
- Apply:
  - Primary paid indexers -> `RSS + Automatic` (or `Automatic Only` if RSS burns API hits too quickly)
  - Limited/free indexers -> `Automatic Only` or `Interactive Only` with conservative query/grab limits

This is directly aligned with TRaSH’s limited-API guidance (use Sync Profiles + limits to avoid bans).

#### 4.4 Health monitoring expectations

Add an explicit “indexer health gate” in bootstrap validation:

- All enabled indexers pass a test request at bootstrap completion.
- Any failing indexer causes `bootstrap-validate-streaming-stack.sh` to fail the apply (or at minimum print actionable diagnostics and mark the system degraded).

Also add periodic monitoring:

- A cron/systemd timer on the VM that runs:
  - Prowlarr indexer test sweep (or status check)
  - Sonarr/Radarr health checks
- Emit logs to journald and/or a file under `/var/log/vmctl/`.

---

### Phase 5: Sonarr/Radarr Provisioning (TRaSH-Aligned PVR Automation)

Goal: Sonarr/Radarr behave like “automated PVRs” immediately after `vmctl apply`.

This is best achieved by combining:

- Minimal “plumbing” via our bootstrap scripts:
  - root folders
  - download clients
  - Prowlarr sync correctness
- TRaSH settings sync via Recyclarr:
  - naming scheme
  - quality definitions
  - quality profiles
- custom formats + scoring (via Recyclarr/TRaSH)

#### 5.1 Recyclarr integration (recommended)

Concrete repo changes later (not implementing now):

- Add a `recyclarr` service (as a scheduled container) or run it as a one-shot bootstrap step:
  - Run as a scheduled container (clean, ongoing alignment with TRaSH updates).
- Store the Recyclarr YAML config as a template-rendered file under `/opt/media/config/recyclarr/recyclarr.yml` sourced from repo templates.
- Use Arr API keys extracted from config.xml (already done in existing scripts) to avoid manual secrets for Arr.

Why this is required:

- TRaSH’s recommended naming scheme and profiles are detailed and evolve over time; implementing and maintaining them as custom API patch code is fragile.

#### 5.2 Naming scheme settings (if not using Recyclarr for naming)

Minimum viable enforcement:

- Sonarr: set Episode Format / Series Folder Format to TRaSH recommendations.
- Radarr: set Movie Format / Movie Folder Format to TRaSH recommendations.

#### 5.3 Download clients

Torrent:

- qBittorrent client:
  - host should be `qbittorrent-vpn` when VPN disabled
  - host should be `gluetun` when VPN enabled (because qB shares gluetun network namespace)
  - category fields:
    - Sonarr: `tvCategory=tv`
    - Radarr: `movieCategory=movies`

Usenet (if enabled):

- SABnzbd client:
  - categories:
    - Sonarr: `tv`
    - Radarr: `movies`
  - completed folder: `/data/usenet/complete`

Ensure Arr “Completed Download Handling” is enabled and hardlink settings are correct for torrents.

#### 5.4 Root folders (TRaSH)

- Sonarr root: `/data/media/tv`
- Radarr root: `/data/media/movies`

#### 5.5 New releases workflow

Operational settings to enforce (via Recyclarr/TRaSH profiles):

- Upgrades enabled with clear cutoffs
- Proper/repack handling
- Multi-quality releases handled by profile ordering and custom formats

Add a regression check:

- Validate “upgrade allowed” settings and cutoff settings match the chosen TRaSH profile.

---

### Phase 6: Seerr Provisioning (Seerr -> Arr flow that always triggers)

Goal: Requesting in Seerr causes immediate Arr search and download.

#### 6.1 Verify and enforce Seerr integrations post-TRaSH changes

After changing:

- root folders
- quality profiles
- (optionally) language profiles

Seerr defaults must be updated so it:

- Points at the correct root folder paths (new `/data/media/tv` and `/data/media/movies`)
- Uses the intended TRaSH quality profile IDs (not the first profile returned by Arr)

Concrete change later:

- Update `packs/scripts/bootstrap-seerr.sh` to explicitly select the desired profile by name, not “first profile”.
  - Example: choose “HD-1080p” for TV and Movies, or “UHD-2160p” if that’s your standard.

#### 6.2 Approval/search behavior

Explicitly enforce:

- Requests are auto-approved (if desired for your environment).
- “Add + Search” is used (no silent add-only).

Because Seerr settings schema can drift by version, prefer using Seerr’s API endpoints where possible, and only fall back to editing `settings.json` where stable.

Validation:

- Create a request and verify:
  - Arr history shows a search command
  - Arr queue shows a grabbed release
  - qB or SAB shows a new download

---

### Phase 7: Import + Library Update + Jellystat Update (the last-mile)

Goal: downloads import cleanly and downstream UIs reflect new media quickly.

#### 7.1 Remove accidental “import crutches” that hide real problems

The current `bootstrap-download-unpack.sh` deploys a polling script that:

- reads qB torrents
- tries to unpack archives
- triggers Arr scans
- triggers Jellyfin refresh

This is useful for edge cases (RAR releases), but it should not be required for the baseline pipeline.

Plan:

- Keep the unpack tool as an optional enhancement, but ensure:
  - standard Completed Download Handling works without it
  - the unpack tool does not pass invalid `downloadClientId` values to Arr commands (verify against Arr API expectations during implementation)

#### 7.2 Jellyfin configuration

Ensure Jellyfin libraries point at:

- `/data/media/movies`
- `/data/media/tv`

And ensure:

- library refresh is triggered periodically or via post-import hook
- a test import results in `GET /Items/Latest` returning the new item

#### 7.3 Jellystat integration

Bootstrap currently configures Jellystat by passing `JF_HOST` and `JF_API_KEY` derived from Jellyfin auth.

Enhance robustness:

- Ensure Jellystat uses Jellyfin internal URL (container-to-host consistent).
- Add a validator that confirms:
  - Jellystat is configured (`/auth/isConfigured` state `>=2`)
  - Jellystat can query Jellyfin without 401/403
- Add an expected-lag SLA:
  - “Recently added” reflects a new import within 10 minutes (validate and adjust only if your Jellystat polling interval differs).

---

## Concrete Provisioning Examples (API Calls and Scripts)

These are intended to be used in later implementation inside bootstrap scripts or validators.

### DRY env var schema (indexers, downloaders, paths)

Extend `packs/templates/media.env.hbs` to export a minimal, explicit contract that bootstrap scripts consume:

- Paths (single source of truth)
  - `DATA_ROOT=/data`
  - `TORRENTS_ROOT=/data/torrents`
  - `TORRENTS_INCOMPLETE=/data/torrents/.incomplete`
  - `USENET_INCOMPLETE=/data/usenet/incomplete`
  - `USENET_COMPLETE=/data/usenet/complete`
  - `MOVIES_ROOT=/data/media/movies`
  - `TV_ROOT=/data/media/tv`
- Categories
  - `QBIT_CATEGORY_TV=tv`
  - `QBIT_CATEGORY_MOVIES=movies`
  - `SAB_CATEGORY_TV=tv`
  - `SAB_CATEGORY_MOVIES=movies`
- Downloader URLs (internal)
  - `QBITTORRENT_INTERNAL_URL=http://qbittorrent-vpn:8080` (or `http://gluetun:8080` when VPN enabled; derive in scripts)
  - `SABNZBD_INTERNAL_URL=http://sabnzbd:8080`
- Indexer credentials (examples; add only what you actually use)
  - `PROWLARR_INDEXER_NZBGEEK_API_KEY` (set in `vmctl.toml [env]`)
  - `PROWLARR_INDEXER_DRUNKENSLUG_API_KEY`
  - `PROWLARR_INDEXER_NZBFINDER_API_KEY`
  - `PROWLARR_INDEXER_OMGWTFNZBS_API_KEY`
  - `PROWLARR_INDEXER_SCENENZB_API_KEY`
  - `PROWLARR_INDEXER_PLANETNZB_API_KEY`
  - `PROWLARR_INDEXER_ALTHUB_API_KEY`
  - `PROWLARR_INDEXER_USENETCRAWLER_API_KEY`
  - `PROWLARR_INDEXER_ABNZB_API_KEY`
  - Private tracker creds should follow the same pattern (passkey, uid, username/password), but only if you are implementing them.

Notes:

- Secrets must come from `vmctl.toml [env]` and/or process env. They must never be committed into the repo.
- Avoid “JSON-in-env” for indexer definitions unless you also implement strong validation; prefer a template-rendered config file under `/opt/media/config/prowlarr/indexers.json` with secrets interpolated from env at render-time.

### Extract Arr API keys (from existing config.xml)

```bash
sonarr_key="$(python3 - <<'PY'
import xml.etree.ElementTree as ET
print(ET.parse("/opt/media/config/sonarr/config.xml").getroot().findtext("ApiKey") or "")
PY
)"
radarr_key="$(python3 - <<'PY'
import xml.etree.ElementTree as ET
print(ET.parse("/opt/media/config/radarr/config.xml").getroot().findtext("ApiKey") or "")
PY
)"
```

### Sonarr/Radarr: verify download client wiring

```bash
curl -fsS -H "X-Api-Key: $sonarr_key" http://127.0.0.1:8989/api/v3/downloadclient | jq '.[] | {name, enable, protocol, implementation}'
curl -fsS -H "X-Api-Key: $radarr_key" http://127.0.0.1:7878/api/v3/downloadclient | jq '.[] | {name, enable, protocol, implementation}'
```

### Prowlarr: verify app sync correctness

```bash
prowlarr_key="$(python3 - <<'PY'
import xml.etree.ElementTree as ET
print(ET.parse("/opt/media/config/prowlarr/config.xml").getroot().findtext("ApiKey") or "")
PY
)"

curl -fsS -H "X-Api-Key: $prowlarr_key" http://127.0.0.1:9696/api/v1/applications | jq
curl -fsS -H "X-Api-Key: $prowlarr_key" http://127.0.0.1:9696/api/v1/indexer | jq '.[] | {name, enable, priority}'
```

### qBittorrent: confirm categories exist

```bash
QBIT_BASE="http://127.0.0.1:8080"
cookie="$(curl -fsS -i --data-urlencode "username=$QBITTORRENT_USERNAME" --data-urlencode "password=$QBITTORRENT_PASSWORD" \
  "$QBIT_BASE/api/v2/auth/login" | awk -F': ' 'tolower($1)=="set-cookie"{print $2}' | head -n1 | cut -d';' -f1)"
curl -fsS -H "Cookie: $cookie" "$QBIT_BASE/api/v2/torrents/categories" | jq
```

### Jellyfin: check latest items after an import

```bash
jf_token="$(curl -fsS -X POST http://127.0.0.1:8096/Users/AuthenticateByName \
  -H 'Content-Type: application/json' \
  -H 'Authorization: MediaBrowser Client=\"vmctl\", Device=\"validate\", DeviceId=\"vmctl-validate\", Version=\"1.0\"' \
  -d "{\"Username\":\"$JELLYFIN_ADMIN_USER\",\"Pw\":\"$JELLYFIN_ADMIN_PASSWORD\"}" | jq -r .AccessToken)"

curl -fsS "http://127.0.0.1:8096/Items/Latest?Limit=20&IncludeItemTypes=Movie,Episode" \
  -H "X-Emby-Token: $jf_token" | jq '.[0:5]'
```

### Sonarr/Radarr: provisioning download clients (qBittorrent example payload)

Sonarr/Radarr store download client settings as a “downloadclient” object with “fields”. The exact field names differ slightly between Sonarr and Radarr, but the pattern is stable:

```bash
set -euo pipefail

sonarr_key="$(python3 - <<'PY'
import xml.etree.ElementTree as ET
print(ET.parse("/opt/media/config/sonarr/config.xml").getroot().findtext("ApiKey") or "")
PY
)"

payload='{
  "enable": true,
  "protocol": "torrent",
  "priority": 1,
  "removeCompletedDownloads": true,
  "removeFailedDownloads": true,
  "name": "qBittorrent",
  "implementation": "QBittorrent",
  "configContract": "QBittorrentSettings",
  "fields": [
    {"name": "host", "value": "qbittorrent-vpn"},
    {"name": "port", "value": 8080},
    {"name": "urlBase", "value": ""},
    {"name": "username", "value": "'"$QBITTORRENT_USERNAME"'"},
    {"name": "password", "value": "'"$QBITTORRENT_PASSWORD"'"},
    {"name": "tvCategory", "value": "tv"},
    {"name": "recentTvPriority", "value": 0},
    {"name": "olderTvPriority", "value": 0},
    {"name": "initialState", "value": 0}
  ]
}'

curl -fsS -H "X-Api-Key: $sonarr_key" -H "Content-Type: application/json" \
  -d "$payload" http://127.0.0.1:8989/api/v3/downloadclient
```

Implementation note:

- This repo already provisions qBittorrent download clients in `packs/scripts/bootstrap-arr.sh`. The implementation work is to update it for `/data` paths and ensure it stays correct when VPN is enabled (host `gluetun`).

### Prowlarr: provisioning app sync (Sonarr/Radarr) with correct categories

The Prowlarr Applications API supports creating/updating app entries with fields. Example payloads:

```bash
set -euo pipefail

prowlarr_key="$(python3 - <<'PY'
import xml.etree.ElementTree as ET
print(ET.parse("/opt/media/config/prowlarr/config.xml").getroot().findtext("ApiKey") or "")
PY
)"
sonarr_key="$(python3 - <<'PY'
import xml.etree.ElementTree as ET
print(ET.parse("/opt/media/config/sonarr/config.xml").getroot().findtext("ApiKey") or "")
PY
)"
radarr_key="$(python3 - <<'PY'
import xml.etree.ElementTree as ET
print(ET.parse("/opt/media/config/radarr/config.xml").getroot().findtext("ApiKey") or "")
PY
)"

# Sonarr (TV categories)
curl -fsS -H "X-Api-Key: $prowlarr_key" -H "Content-Type: application/json" \
  -d '{
    "name": "Sonarr",
    "syncLevel": "fullSync",
    "implementation": "Sonarr",
    "configContract": "SonarrSettings",
    "enable": true,
    "fields": [
      {"name":"prowlarrUrl","value":"http://prowlarr:9696"},
      {"name":"baseUrl","value":"http://sonarr:8989"},
      {"name":"apiKey","value":"'"$sonarr_key"'"},
      {"name":"syncCategories","value":[5000,5030,5040]}
    ]
  }' http://127.0.0.1:9696/api/v1/applications || true

# Radarr (Movie categories)
curl -fsS -H "X-Api-Key: $prowlarr_key" -H "Content-Type: application/json" \
  -d '{
    "name": "Radarr",
    "syncLevel": "fullSync",
    "implementation": "Radarr",
    "configContract": "RadarrSettings",
    "enable": true,
    "fields": [
      {"name":"prowlarrUrl","value":"http://prowlarr:9696"},
      {"name":"baseUrl","value":"http://radarr:7878"},
      {"name":"apiKey","value":"'"$radarr_key"'"},
      {"name":"syncCategories","value":[2000,2010,2020,2030,2040,2045,2050,2060]}
    ]
  }' http://127.0.0.1:9696/api/v1/applications || true
```

Implementation note:

- During implementation, do not blindly POST duplicates. Query existing applications, then PUT updates when needed (the existing `bootstrap-arr.sh` already implements this pattern; it just needs app-specific category lists).

### Prowlarr: indexer provisioning pattern (schema-driven, supports many indexers)

Use a schema-driven approach so adding/replacing indexers is data-driven and DRY:

1. Fetch schemas: `GET /api/v1/indexer/schema`
2. Select schema by `name`
3. Fill `fields` by name using env-derived secrets
4. POST the indexer
5. Test and enable

This avoids hardcoding per-indexer JSON layouts in shell scripts and reduces drift when Prowlarr updates presets.

--- 

## TDD Execution Plan (Required)

The order here matters: the tests should fail first, then become green.

### Test 1: Seerr -> Sonarr/Radarr connectivity

Failing check to add:

- `GET seerr settings.json` integrations exist and `preventSearch=false`.
- Sonarr/Radarr `/ping` is reachable from Seerr container network namespace.

Pass criteria:

- Seerr API returns initialized=true and integrations are present.

### Test 2: Sonarr/Radarr -> qBittorrent connectivity (and SABnzbd if enabled)

Failing check to add:

- From inside Sonarr/Radarr containers, verify qB API `/api/v2/app/version` is reachable using the configured host.
- Verify Arr download client field values match expected host/port/category.

Pass criteria:

- Connectivity and config converge.

### Test 3: Indexer health (Prowlarr and Arr)

Failing check to add:

- Prowlarr has at least 1 enabled indexer that passes test.
- Sonarr/Radarr health has no indexer failures.

Pass criteria:

- No “Indexers unavailable” warnings and tests pass.

### Test 4: Completed download import (synthetic, no piracy)

Create an automated, legal, deterministic import test:

- Add a known public-domain sample video file (or generate a 1-second MP4 with ffmpeg) into staged directories:
  - `/data/torrents/tv/_vmctl_pipeline_test_tv/`
  - `/data/torrents/movies/_vmctl_pipeline_test_movies/`
- Add a real series/movie to Sonarr/Radarr via API (metadata fetch is legal).
- Trigger Manual Import / Downloaded*Scan API endpoints pointing at the staged directory.
- Validate the file ends up renamed and moved into `/data/media/tv` or `/data/media/movies`.

Pass criteria:

- File is imported, renamed per naming rules, and appears under the expected library root.

### Test 5: Jellyfin library update

Failing check to add:

- After import, call `POST /Library/Refresh` and then poll `GET /Items/Latest` until the imported title appears.

Pass criteria:

- Imported media appears in Jellyfin latest list.

### Test 6: Jellystat update

Failing check to add:

- Poll Jellystat API/UI-backed endpoint(s) for “recently added” (or validate its internal state indicates new items processed).

Pass criteria:

- Jellystat reflects the new item within the SLA window.

### Regression coverage

Add these checks to the standard `bootstrap-validate-streaming-stack.sh` run so a broken pipeline fails fast during provisioning.

### UI Regression Coverage (Playwright MCP)

Add a UI smoke pass as part of the verification workflow (and optionally as an automated test step) using Playwright MCP:

1. Open each UI URL listed in Phase 0.3 and assert the page renders expected content (no blank page, no endless redirects).
2. Capture screenshots before and after the pipeline test import.
3. Treat UI failures as blocking (they commonly indicate auth/path/routing breakage that API checks won’t surface).

This is explicitly additive to curl/API checks, not a replacement.

---

## DRY / Single Source of Truth (Required)

Goal: eliminate duplicated values across `.env`, templates, and scripts so changes are safe.

### Centralize the following

In `vmctl.toml` (or derived `features.media_services` fields) + template rendering:

- Service URLs (internal and external)
- Ports (qB, Sonarr, Radarr, Prowlarr, Seerr, Jellyfin, Jellystat, SABnzbd)
- Canonical data root used inside containers (`/data`)
- All derived paths:
  - torrents root
  - usenet root
  - media root
- Categories:
  - `tv`, `movies`
- Indexer configuration inputs (names enabled, priorities, sync profiles)

### Recommended structure for config in vmctl.toml

Add to `[const]` and/or `[resources.features.media_services]`:

- `media_data_root = "/data"`
- `media_paths.*` derived from that root:
  - `torrents_root`, `usenet_complete_root`, `usenet_incomplete_root`, `movies_root`, `tv_root`
- `arr_categories.*`

Render these into:

- `packs/templates/media.env.hbs` (as exported env vars)
- Use env vars in bootstrap scripts instead of hard-coded `/media/` paths.

### Shared provisioning helpers

Later implementation should reduce duplicated “API request / wait_for / read key” code by:

- introducing a small shared Python module under `packs/scripts/lib/` (or a single `vmctl_media_api.py`) used by:
  - `bootstrap-arr.sh`
  - `bootstrap-seerr.sh`
  - `bootstrap-jellystat.sh`
  - validators

Keep it dependency-free (stdlib only), matching existing script style.

---

## Definition of Done

This plan is complete when the implemented changes achieve the following measurable outcomes:

- Seerr requests (on `http://media-stack:5056`) result in immediate Sonarr/Radarr search activity.
- Sonarr/Radarr consistently grab releases from healthy indexers and enqueue downloads to the correct downloader:
  - torrents -> qBittorrent
  - usenet -> SABnzbd (required when Usenet indexers are configured)
- qBittorrent receives downloads under TRaSH-aligned paths and categories.
- Completed downloads are imported by Sonarr/Radarr into TRaSH-aligned library roots with correct naming.
- Jellyfin libraries point at the same library roots and show newly imported items without manual intervention.
- Jellystat “recently added” reflects new items within the defined SLA window.
- Sonarr has no ongoing failing indexers; Prowlarr indexers are healthy and authenticated.
- The above holds after a clean `vmctl apply` with no manual UI steps.
- Playwright MCP UI smoke verification passes for all UIs, and post-import screenshots are captured in the diagnostics packet.
