# Config DRY + Stremio (Samsung Tizen) Compatibility Remediation Plan

Current date: 2026-04-23 (Australia/Melbourne)

This plan addresses two related problem areas:

1. Configuration duplication / lack of centralized interpolation (DRY).
2. Stremio works on macOS but fails on Samsung Tizen OS, despite the addon being reachable (manifest/catalog definitions load) because catalog results appear empty on Tizen (so playback is not yet testable).

The plan is implementation-ready and designed to be executed with TDD and regression prevention.

---

## 1) Investigation (Do This First)

### 1.1 Current Architecture / Request Flow (Config → Generated Artifacts)

**Config parse + interpolation**
- `vmctl.toml` is parsed and interpolated by `crates/config/src/lib.rs` (the `Interpolator` supports `${...}` references across:
  - `const.*`, `env.*`, process environment variables, and full-path scalar lookups).
- Interpolation happens before deserialization to typed config (`Config::from_toml`).

**Desired state build**
- Desired state is built by `crates/planner/src/lib.rs`:
  - Applies `[defaults]` into each resource’s flattened `settings`.
  - Normalizes resources into `NormalizedResource` and derives `provision.host` from `hostname`/`searchdomain`.

**Packs expansion + rendering**
- Packs are loaded from `packs/` and expanded/rendered via `crates/packs/src/lib.rs`.
- Templates (`packs/templates/*.hbs`) are rendered with Handlebars using a context containing:
  - `resource` (includes flattened `settings`), `features`, `services`, `service_packs`, `tailscale`, etc.
- Bootstrap scripts (`packs/scripts/*.sh`) are copied verbatim (not templated) into generated resource directories.

**Terraform backend rendering**
- Terraform workspace and generated resource artifacts are produced by `crates/backend-terraform`.
- Golden fixtures exist under `crates/backend-terraform/tests/fixtures/example-workspace/...` and are asserted in `crates/backend-terraform/src/lib.rs`.

### 1.2 Current Architecture / Request Flow (Stremio → Addon → Jellyfin)

**Ingress**
- Caddy runs on `media-stack` and serves:
  - `/jellio/*` reverse-proxied to Jellyfin (Jellio plugin serves Stremio addon endpoints).
  - `/jf/*` reverse-proxied to Jellyfin with `X-MediaBrowser-Token` injected (Stremio-safe public proxy to Jellyfin APIs).
  - `/Items/*` and `/Videos/*` reverse-proxied to Jellyfin with the same injected token (used for artwork and playback URLs).
- Caddy config template: `packs/templates/caddyfile.media.hbs`.

**Jellio/Jellyfin plugin configuration**
- `packs/scripts/bootstrap-jellio.sh`:
  - Creates/ensures a dedicated Jellyfin user for Stremio and retrieves its `AccessToken`.
  - Writes Stremio manifest URLs into:
    - `/opt/media/config/caddy/ui-index/jellio-manifest.*.url`
    - `.env` keys: `JELLIO_STREMIO_MANIFEST_URL_*`
  - Encodes a payload containing `PublicBaseUrl = <addon_base>/jf` and `AuthToken` and selected library GUIDs.

### 1.3 Where Duplication Exists Today (Representative, Not Exhaustive)

These are concrete “single values repeated in many places” examples that must become centrally-derived:

- `media-stack` and `media-stack.home.arpa`
  - `packs/templates/media.env.hbs` hardcodes `MEDIA_PUBLIC_BASE_URL_LAN=http://media-stack`.
  - `packs/templates/caddyfile.media.hbs` hardcodes the site addresses `media-stack:80, media-stack.home.arpa:80, :80`.
  - `packs/scripts/bootstrap-jellio.sh` hardcodes `host_server_name = "media-stack"` and defaults to `http://media-stack`.
  - `packs/scripts/bootstrap-media.sh` hardcodes hostnames inside `/etc/hosts` management and Jellyfin URL fallback checks.
  - `packs/scripts/bootstrap-kodi-jellyfin.sh` and `packs/roles/kodi_htpc.toml` include hardcoded Jellyfin URLs.
- Port numbers and upstream URLs
  - Caddyfile contains `:5056`, `:8097`, and internal service addresses that may also appear elsewhere.
- Service identifiers and feature flags
  - The same service names appear in `vmctl.toml`, `packs/roles/*.toml`, `.env` templates, bootstrap scripts, and tests/fixtures.

### 1.4 Tizen-Specific Failure Surface (What’s Different vs macOS)

Current observed behavior on Tizen:
- The Stremio TV app can reach the addon and shows catalog *definitions* (Movies/TV sections exist).
- The catalog contents appear **empty** (no items visible), so playback is **not yet testable** on Tizen.

Given “manifest loads but Tizen catalog results are empty”, likely differences/failure points are in:

- Catalog request differences:
  - Tizen may request different `extra` parameters (pagination/search/genre) or different catalog IDs/types than macOS.
  - Tizen may be stricter about response JSON shape, required fields, or even compression/content-encoding.
- Stream URL content and playback protocol:
  - macOS Stremio is generally tolerant (software decode / broader container support).
  - Tizen Stremio is constrained by Tizen playback stack (container/codec support often narrower, and HLS is typically the safest).
- Stream response behavior:
  - Redirect handling, Range request requirements, response headers.
- URL reachability:
  - The TV may reach the addon origin but not the *returned* playback URL origin/path (or the returned URL resolves to a different hostname).

---

## 2) Root Cause Analysis (Hypotheses, Evidence, Exact Checks)

### 2.1 Config Duplication / DRY Violations

**Hypothesis A: Packs templates rely on literals because render context lacks a canonical “naming/endpoints” layer**
- Evidence to gather:
  - `grep -RIn "http://media-stack|media-stack\\.home\\.arpa|:8096|:80"` across `packs/templates`, `packs/scripts`, `packs/services`, `packs/roles`.
- Exact checks:
  1. Confirm Handlebars context cannot reference global “consts” directly (only `resource`, `features`, etc).
  2. Identify the minimum data needed to produce canonical hostnames/URLs in templates (`resource.name`, `resource.searchdomain`, feature config).
- Prove/disprove:
  - If replacing literals in templates with `{{resource.name}}` / `{{resource.searchdomain}}` is sufficient for most cases, the missing piece is mainly “scripts are not templated” and “scripts need standardized env inputs”.

**Hypothesis B: Role bootstrap scripts are copied verbatim, forcing embedded literals**
- Evidence:
  - `packs/scripts/bootstrap-*.sh` contain role-specific hostnames (`media-stack`, `.home.arpa`) and URLs.
- Exact checks:
  1. List scripts copied as-is for `media_stack` role in `packs/roles/media_stack.toml`.
  2. Identify which literals must be parameterized (hostnames, ports, base URLs).
- Prove/disprove:
  - If scripts can be made generic by consuming env variables that are generated from `vmctl.toml`, the duplication can be removed without templating scripts.

**Hypothesis C: Tests/fixtures encode duplicated literals, locking in non-DRY design**
- Evidence:
  - `crates/backend-terraform/tests/fixtures/...` include hardcoded `media-stack.*` and values repeated from templates/scripts.
- Exact checks:
  - Identify fixture assertions in `crates/backend-terraform/src/lib.rs` that validate string literals rather than validating derived behavior.
- Prove/disprove:
  - If fixture tests must be rewritten to validate “derived values match the desired naming strategy” rather than “this exact literal exists”, they currently prevent DRY refactors.

### 2.2 Stremio on Samsung Tizen OS (Manifest OK, Catalog Empty; Playback Not Yet Testable)

Treat this as a two-stage compatibility problem:
1. **Stage 1 (Discovery):** manifest loads but **catalog items are empty** on Tizen.
2. **Stage 2 (Playback):** once items are visible, ensure streams play reliably (likely via HLS for Tizen).

#### Stage 1: Catalog Items Are Empty on Tizen

**Hypothesis 0A: Tizen requests different `catalog` URLs/params than macOS, triggering an empty result**
- Evidence to gather:
  - Caddy access logs for `/jellio/.../catalog/...json` on macOS vs Tizen, including full path + query.
- Exact checks:
  1. Enable access logs (include request URI and `User-Agent`) and capture the exact catalog requests made by:
     - macOS Stremio (working)
     - Samsung Tizen Stremio (empty)
  2. Replay the Tizen catalog request from a shell with the same query params and a Tizen-like `User-Agent` and compare the JSON response to macOS.
  3. Compare `extra` fields (commonly `skip`, `limit`, `search`, `genre`) and confirm the plugin/addon actually supports them as requested.
- Prove/disprove:
  - If the catalog response for Tizen requests contains `metas: []` while the macOS equivalent returns items, the issue is request-shape handling (params/catalog ID/type).

**Hypothesis 0B: Catalog response contains items but Tizen UI filters them out due to missing/invalid fields**
- Evidence to gather:
  - Compare a macOS catalog response vs Tizen catalog response (same endpoint) focusing on required Stremio fields:
    - `id`, `type`, `name`, `poster` (or `posterShape` expectations), `releaseInfo`/`year` (optional but commonly used).
- Exact checks:
  1. Inspect the raw JSON returned to Tizen for `metas` length and presence of required fields.
  2. Force a minimal “known-good” meta object (via a local test stub or response fixture) and confirm Tizen renders it.
- Prove/disprove:
  - If `metas` is non-empty but nothing renders on the TV, the issue is missing/invalid meta fields (or URL formatting) rather than data retrieval.

**Hypothesis 0C: Tizen has stricter requirements around HTTP response headers/encoding for JSON**
- Evidence to gather:
  - For manifest and catalog responses: `Content-Type`, `Content-Encoding`, status codes, and response sizes.
- Exact checks:
  1. Confirm catalog responses to Tizen are `200` with `Content-Type: application/json` and do not rely on unsupported compression.
  2. If Tizen sends `Accept-Encoding: gzip`, validate it can successfully decode by comparing:
     - `curl -H 'User-Agent: <tizen UA>' --compressed <catalog_url>`
     - `curl -H 'User-Agent: <tizen UA>' -H 'Accept-Encoding: identity' <catalog_url>`
- Prove/disprove:
  - If forcing `Accept-Encoding: identity` yields content that Tizen renders, the issue is content-encoding handling and the proxy should avoid compressing addon JSON for Tizen.

#### Stage 2: Playback (Once Catalog Items Are Visible)

**Hypothesis 1: Tizen cannot play the direct stream container/codec returned by Jellyfin/Jellio (e.g., MKV/Matroska)**
- Evidence to gather:
  - From logs/validation: `Content-Type` for the stream URL (commonly `video/x-matroska` when direct streaming MKV).
  - Jellyfin playback decision for the same item: direct play vs transcoding.
- Exact checks:
  1. Capture one failing item’s stream URL from Stremio (Tizen) and from macOS.
  2. `curl -I` the stream URL and record:
     - status (`200` / `206`), `Content-Type`, `Accept-Ranges`, `Content-Length`/`Transfer-Encoding`, redirects.
  3. Query Jellyfin playback info for that item (via proxied `/jf` or internal Jellyfin) to inspect codecs/containers and available transcode profiles.
- Prove/disprove:
  - If Tizen fails consistently on Matroska streams but succeeds when the same content is forced through HLS (m3u8) or MP4 (H.264/AAC), the root cause is codec/container/protocol compatibility.

**Hypothesis 2: The returned playback URL host/path differs from what the TV can resolve/reach**
- Evidence:
  - Compare the origin used for addon requests (catalogs) to the origin embedded in `PublicBaseUrl` (decoded from the manifest URL payload) and the resulting stream URL.
- Exact checks:
  1. Decode the manifest payload written by `bootstrap-jellio.sh`:
     - Ensure `PublicBaseUrl` matches the origin the client is actually using (short host vs FQDN vs IP).
  2. Confirm the TV can reach the returned stream URL origin with a simple HTTP GET/HEAD from the same network (or by replaying via a phone on the same Wi-Fi).
- Prove/disprove:
  - If catalogs are fetched from `http://media-stack/...` but playback URLs point at `http://media-stack.home.arpa/...` (or vice versa) and only one is resolvable from the TV, the issue is URL base mismatch.

**Hypothesis 3: Tizen player is stricter about redirects and Range semantics**
- Evidence:
  - Tizen may not follow redirects for media URLs, and may require Range support for seeking/buffering.
- Exact checks:
  1. Ensure no `301/302` occurs on the stream URL path.
  2. Ensure Range requests return `206` with correct headers.
  3. Confirm Caddy is not compressing/altering video responses (should not, but verify).
- Prove/disprove:
  - If the first request from Tizen returns a redirect or ignores Range responses, adjust proxy behavior and retest.

---

## 3) Remediation Strategy (High-Level Decisions)

### 3.1 Single-Source-of-Truth Strategy (Config DRY)

Adopt this policy:

- **Canonical identity** for a resource is its `[[resources]].name` in `vmctl.toml` (example: `media-stack`).
- **Canonical FQDN** is derived from `resource.name + "." + resource.searchdomain` when `searchdomain` exists.
- **All generated artifacts** (templates + scripts + proxy config) must consume derived values, not embed the same literals.
- **Bootstrap scripts** must be parameterized via a standardized env contract (generated from templates), so scripts never need to hardcode hostnames.

Concrete implementation approach:

1. Add a small set of standardized “vmctl-derived” env vars to `packs/templates/media.env.hbs` (and other role env templates) using Handlebars and resource fields.
2. Update role scripts to use those env vars (instead of literals).
3. Update proxy templates to derive hostnames from the same resource fields.
4. Update tests to enforce “no hardcoded naming literals in packs/scripts/templates” and to assert correctness via derived outputs.

### 3.2 Tizen Compatibility Strategy (Minimize Scope, Keep Current Jellio)

Recommended approach: **Keep Jellio/Jellyfin plugin for catalogs/metadata, fix Tizen catalog emptiness first, then add a Tizen-safe playback path at the reverse proxy layer**.

- Rationale:
  - The plugin is external; we want to avoid maintaining a fork.
- The returned stream URLs already point back to `media-stack`, so Caddy can detect Tizen clients and rewrite the playback path/protocol without changing the addon responses.
- HLS is the safest cross-device playback format; it reduces codec/container risk on Tizen.

Concretely:

- Add a Caddy conditional that detects Tizen (User-Agent match) and rewrites `/videos/<id>/stream` to a Jellyfin HLS entrypoint (or MP4 transcode) while keeping auth header injection.
- Ensure both `/Videos/*` and `/videos/*` are proxied with injected token (and same for `/Items/*` and `/items/*`) to avoid case-sensitive path pitfalls.

---

## 4) Implementation Plan (Concrete Changes)

### 4.1 Config DRY: Centralize Hostnames/URLs and Remove Duplicated Literals

#### 4.1.1 Extend Generated `.env` Contract (Single Place to Derive Naming)

Update `packs/templates/media.env.hbs` to add vmctl-derived naming fields (examples):

```env
VMCTL_RESOURCE_NAME={{resource.name}}
VMCTL_SEARCHDOMAIN={{resource.searchdomain}}
VMCTL_HOST_SHORT={{resource.name}}
VMCTL_HOST_FQDN={{resource.name}}.{{resource.searchdomain}}
VMCTL_HTTP_BASE_URL_SHORT=http://{{resource.name}}
VMCTL_HTTP_BASE_URL_FQDN=http://{{resource.name}}.{{resource.searchdomain}}
MEDIA_PUBLIC_BASE_URL_LAN=http://{{resource.name}}
```

Notes:
- Enforce `defaults.searchdomain` as required (non-empty) when `resources.features.media_services.enabled = true`, so FQDN derivations are always well-formed for the media stack role.
- This keeps the “define once” requirement: `resource.name` and `searchdomain` are already defined in `vmctl.toml` (`[[resources]].name` and `[defaults].searchdomain`), and all downstream artifacts derive from those fields.

#### 4.1.2 Remove Literals From Templates (Caddy and UI)

Update `packs/templates/caddyfile.media.hbs` to derive site addresses:

```caddyfile
{{resource.name}}:80, {{resource.name}}.{{resource.searchdomain}}:80, :80 {
  ...
}
```

If searchdomain can be empty, use conditional rendering so the Caddyfile does not contain malformed hostnames.

#### 4.1.3 Remove Literals From Scripts by Consuming Env Vars

Update scripts that currently embed `media-stack` (examples below must be executed across all affected scripts):

- `packs/scripts/bootstrap-jellio.sh`
  - Replace `host_server_name = "media-stack"` with `host_server_name = os.environ.get("VMCTL_RESOURCE_NAME") or "media-stack"`.
  - Replace default `lan_public_base` fallback and other naming assumptions with `VMCTL_HTTP_BASE_URL_SHORT` / `MEDIA_PUBLIC_BASE_URL_LAN`.

- `packs/scripts/bootstrap-media.sh`
  - Replace `/etc/hosts` replacement string `"{primary_ip} media-stack.home.arpa media-stack"` with values derived from env vars:
    - `VMCTL_HOST_FQDN` and `VMCTL_HOST_SHORT`.
  - Replace Jellyfin URL fallback list to include derived host(s) rather than hardcoding.

- `packs/scripts/bootstrap-kodi-jellyfin.sh` and role configs referencing Jellyfin URL
  - Replace defaults like `http://media-stack.home.arpa:8096` with a value passed via env (`JELLYFIN_URL` already exists) and make the default come from `vmctl.toml` -> generated env.

#### 4.1.4 Optional (If Needed): Centralize Ports/Service Names

If port duplication causes drift:
- Add `const.ports.*` in `vmctl.toml` and interpolate into resource features, then reference in templates as `{{features...}}`.
- Avoid making pack TOML files themselves templated; instead, flow values via rendered templates (`.env`, `Caddyfile`, compose overrides).

### 4.2 Tizen Compatibility: Provide a Playback-Safe Path (Proxy-Layer)

#### 4.2.1 Add a Tizen-Specific Matcher and Rewrite in Caddy

Update `packs/templates/caddyfile.media.hbs` to:

1. Proxy both lowercase and uppercase paths with token injection:

```caddyfile
handle /items/* { ...token... }
handle /videos/* { ...token... }
handle /Items/* { ...token... }
handle /Videos/* { ...token... }
```

2. Detect Tizen clients and rewrite the playback URL to HLS (recommended) or MP4 transcode:

Example (concrete Caddy matcher + capture + rewrite):

```caddyfile
@tizen_stream {
  header_regexp User-Agent (?i).*tizen.*
  path_regexp tizen_stream ^/videos/([^/]+)/stream$
}

handle @tizen_stream {
  # Force HLS for Tizen by mapping the direct stream URL to Jellyfin's HLS master playlist.
  rewrite * /Videos/{re.tizen_stream.1}/master.m3u8
  reverse_proxy {$JELLYFIN_INTERNAL_URL} {
    header_up X-MediaBrowser-Token {$JELLYFIN_STREMIO_AUTH_TOKEN}
  }
}
```

Implementation detail requirement:
- Verify Jellyfin’s exact HLS entrypoint for your version by fetching one known item’s master playlist via the proxy:
  - `curl -i "http://<media-host>/Videos/<item_id>/master.m3u8"`
- Ensure any subsequent segment URLs are also covered by the `/Videos/*` proxy handlers (with injected token).

#### 4.2.2 Ensure No Redirects for LAN HTTP (Tizen Can Be Strict)

Explicitly validate for Tizen paths:
- `http://<host>/videos/<id>/stream` returns `200`/`206` and does not redirect.
- `http://<host>/Videos/<id>/master.m3u8` returns `200` and appropriate HLS content type.

#### 4.2.3 Add Diagnostics for Client Differentiation

Add/enable Caddy access logging (scoped to media-stack) to capture:
- `Host`, `URI`, status code, `User-Agent`, Range headers.

This is required to prove which requests are coming from Tizen and what fails (catalog vs stream).

---

## 5) Verification Steps (Before and After Fixes)

### 5.1 Config DRY Verification

**Static checks**
1. Run a repo-wide grep to ensure `media-stack` literal no longer appears in templates/scripts except:
   - documentation/examples, tests specifically asserting the example workspace, or values that are genuinely constant identifiers.
2. Generate backend artifacts (`vmctl backend render` or equivalent) and confirm:
   - `backend/generated/workspace/resources/media-stack/media.env` contains derived env vars and does not embed unexpected literals.
   - `backend/generated/workspace/resources/media-stack/caddyfile.media` uses derived hosts.

**Behavioral checks**
- Change `[[resources]].name` (in a temporary branch) and confirm hostnames/URLs propagate to:
  - generated `.env`
  - generated Caddyfile
  - generated UI index links
  - Jellio manifest URLs written by bootstrap

### 5.2 Tizen Playback Verification

**Network-level checks**
1. From a LAN client, fetch the manifest URL installed on the TV and decode the payload:
   - Confirm `PublicBaseUrl` points to the same reachable origin as the manifest host.
2. With a Tizen-like `User-Agent`, request and validate catalog endpoints first:
   - confirm `metas` is non-empty for Movies and TV catalogs on the TV’s configured addon base URL
3. With a Tizen-like `User-Agent`, request:
   - the episode stream URL returned by Stremio
   - confirm it serves HLS (m3u8) after the rewrite and that segment requests succeed.

**Device-level checks**
1. On Samsung Tizen Stremio:
   - open Movies/TV catalogs and confirm items are visible (not empty)
   - open an episode/movie and press play, verify playback starts and continues (seek works).
2. On macOS Stremio:
   - verify behavior remains working (no regression; direct stream can remain enabled for macOS if desired).

---

## 6) TDD Plan (Tests First, Then Fix)

### 6.1 Config DRY (TDD)

**Step 1: Reproduce current duplication**
- Write a test that fails if known literals exist in rendered artifacts for the example workspace.

**Step 2: Add failing tests**

Add tests in `crates/backend-terraform` (preferred, because it already validates generated artifacts) that:
- Render the example workspace and assert:
  - `media.env` contains `MEDIA_PUBLIC_BASE_URL_LAN=http://{{derived}}` rather than the literal.
  - `caddyfile.media` host list is derived from resource name + searchdomain.
- Add a “no hardcoded hostnames” assertion that scans rendered files for forbidden literals (scoped to specific artifact directories, with an allowlist for docs/tests).

Example test shape (Rust pseudocode):

```rust
let env = read_rendered("resources/media-stack/media.env");
assert!(env.contains("VMCTL_RESOURCE_NAME=media-stack"));
assert!(env.contains("MEDIA_PUBLIC_BASE_URL_LAN=http://media-stack"));
assert!(!env.contains("MEDIA_PUBLIC_BASE_URL_LAN=http://media-stack.home.arpa")); // unless derived config says so
```

**Step 3: Implement refactor**
- Update templates/scripts as described in section 4.1.

**Step 4: Verify**
- Tests pass.
- `cargo test -p vmctl-backend-terraform` passes (plus any directly affected crate tests).

**Step 5: Regression coverage**
- Add a focused test that:
  - Modifies the resource name/searchdomain in a minimal config fixture.
  - Asserts the generated artifacts reflect the change everywhere without further edits.

### 6.2 Tizen Compatibility (TDD)

**Step 1: Reproduce (capture current behavior)**
- Add an automated validation that simulates a Tizen client using a Tizen-like `User-Agent` and asserts:
  - catalog endpoints return non-empty `metas` (Stage 1)
  - stream endpoints are playable (Stage 2, only after Stage 1 is solved)

**Step 2: Add failing tests**

1. **Caddyfile contract test**
   - Assert that generated `caddyfile.media` includes:
     - `/videos/*` and `/items/*` token-injecting proxy routes
     - a Tizen UA matcher and an HLS rewrite block.

2. **Bootstrap validation enhancement**
   - Update `packs/scripts/bootstrap-validate-streaming-stack.sh` to:
     - call Movies and TV catalog endpoints with a Tizen-like `User-Agent` and assert `metas.length > 0` for at least one library-backed catalog
     - call a stream URL with a Tizen-like User-Agent
     - verify it returns HLS playlist content-type and `200`, and the body begins with `#EXTM3U`
     - follow up by fetching at least one referenced segment URL and verifying `200/206`

**Step 3: Implement fix**
- Implement the Caddy rewrite/matcher and route coverage in the Caddy template.

**Step 4: Verify**
- Provision `media-stack` and ensure validation passes.
- Validate on actual Samsung Tizen device.

**Step 5: Regression coverage**
- Keep the validation script checks permanently.
- Keep a fixture-based test in `crates/backend-terraform` that ensures the required Caddy handlers remain present.

---

## 7) DRY Considerations (Avoid New Duplication While Fixing Duplication)

### 7.1 Centralize Derived Naming in One Place

Policy: **derive names once in the generated env template**, then reuse them everywhere.

- Templates (Caddyfile, UI index) should reference `resource.*` directly for static derivations.
- Scripts should reference only env vars (`VMCTL_*`, `MEDIA_PUBLIC_BASE_URL_LAN`, etc), never hardcode hostnames.

### 7.2 Create a Small Shared Helper for Tests

Add a test helper module (in the crate where tests live) that:
- Reads rendered files from a known fixture directory.
- Provides:
  - `assert_no_forbidden_literals(paths, forbidden, allowlist)`
  - `decode_jellio_manifest_payload(url) -> struct { PublicBaseUrl, ... }`

This prevents duplicating regexes and manifest decoding logic across multiple tests.

### 7.3 One Compatibility Switch (Not Multiple One-Off Conditions)

If introducing Tizen-only behavior:
- Implement a single “client classification” rule (e.g., `User-Agent` regex for Tizen).
- Keep rewrite logic localized in the proxy (Caddy), not scattered across scripts and templates.

---

## 8) Task Breakdown (Actionable, Grouped)

### 8.1 Investigation
1. Run `grep -RIn` across `packs/` and `crates/` for duplicated literals: `media-stack`, `.home.arpa`, `:8096`, and base URLs.
2. Enumerate which duplicates are:
   - safe to derive from `resource.name`/`resource.searchdomain`
   - require explicit config keys (ports, external domains, feature identifiers)
3. Capture Tizen traffic:
   - enable Caddy access logs including `User-Agent` and `Range`
   - record the exact Tizen `catalog` request URLs (path + query) and whether they return `metas: []`
   - only after catalogs are non-empty, record stream URL(s) and corresponding response headers/status

### 8.2 Reproduction
1. Create a reproducible “failing discovery” set:
   - pick at least 1 movie and 1 TV series that appear on macOS Stremio via this addon
   - record their Stremio meta IDs and the macOS catalog request URL(s) that return them
   - record the corresponding Tizen catalog request URL(s) that do not show them (or return `metas: []`)
2. Add/extend automated validation to detect the current failure mode (before fixes):
   - Stage 1: catalog endpoints are empty on Tizen
   - Stage 2: only after Stage 1 is fixed, capture playback failures (if any)

### 8.3 Remediation
1. Update `packs/templates/media.env.hbs` to derive naming env vars and remove `MEDIA_PUBLIC_BASE_URL_LAN` literal.
2. Update `packs/templates/caddyfile.media.hbs` to derive hostnames and add:
   - lowercase/uppercase proxy coverage
   - Tizen UA matcher + HLS rewrite path
3. Update affected scripts to remove embedded literals and use env vars:
   - `packs/scripts/bootstrap-jellio.sh`
   - `packs/scripts/bootstrap-media.sh`
   - `packs/scripts/bootstrap-kodi-jellyfin.sh` (and any other scripts found in investigation)
4. Update docs that describe endpoints if they reference literals (keep examples but mark them as examples).

### 8.4 Validation
1. Run unit/golden tests:
   - `cargo test -p vmctl-backend-terraform`
   - any additional crate tests touched
2. Provision `media-stack` and ensure:
   - Tizen UA catalog endpoints return non-empty `metas` for both Movies and TV
   - only after catalogs are non-empty: Tizen UA playback endpoint serves HLS
   - only after catalogs are non-empty: actual Tizen Stremio playback works for the recorded test media

### 8.5 Regression Prevention
1. Add a “forbidden literal” test for rendered artifacts (scoped, with allowlist).
2. Keep the enhanced `bootstrap-validate-streaming-stack.sh` checks permanently.
3. Add a small “contract test” asserting required Caddy handlers exist in the generated Caddyfile.

---

## 9) Definition of Done

### 9.1 Config DRY
Complete when:
- `media-stack` (and similar key hostnames) are defined once in `vmctl.toml` (via `[[resources]].name` and defaults like `searchdomain`).
- Rendered templates and scripts derive hostnames/URLs from:
  - `resource` fields in templates, and
  - standardized env vars in scripts.
- Repo-wide scan of generated artifacts shows no unintended duplicated literals for hostnames/URLs.
- Changing `[[resources]].name` and/or `[defaults].searchdomain` updates all dependent outputs correctly after a render/apply (no manual edits required).

### 9.2 Stremio on Samsung Tizen OS
Complete when:
- Catalog definitions load and **catalog items are visible** on Samsung Tizen Stremio (non-empty Movies/TV lists).
- Playback works on Tizen for at least:
  - 1 TV episode
  - 1 movie
  with “supported” codecs (as defined by the chosen compatibility strategy).
- Stream URLs returned to Tizen are reachable and do not redirect unexpectedly.
- Tizen playback uses a Tizen-safe path/protocol (HLS recommended), validated by automated checks plus device verification.
- macOS Stremio remains working (no regression).
