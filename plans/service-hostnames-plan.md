# Service Hostnames Plan

## Architecture Overview

### Goal
Expose each media service via dedicated hostnames without ports, for both tailnet and local LAN access:

- `jellyfin.media-stack.<tailnet>.ts.net`
- `sonarr.media-stack.<tailnet>.ts.net`
- `radarr.media-stack.<tailnet>.ts.net`
- `prowlarr.media-stack.<tailnet>.ts.net`
- `qbittorrent.media-stack.<tailnet>.ts.net`

and locally:

- `jellyfin.media-stack`
- `sonarr.media-stack`
- `radarr.media-stack`
- `prowlarr.media-stack`
- `qbittorrent.media-stack`

### Routing Model
Use a single reverse proxy (Caddy) on `media-stack` with host-based routes:

- Caddy listens on `:80` (LAN ingress)
- Caddy maps `Host` header to upstream Docker service
- Tailscale Serve maps HTTPS `443` on the node to local Caddy `http://127.0.0.1:80`
- No path-prefix routing for app UIs
- Preserve Jellyfin client compatibility by forwarding `X-Forwarded-*` headers and supporting WebSockets via `reverse_proxy`

### Name Resolution

#### Tailscale
Use the node DNS name already assigned by Tailscale (`media-stack.<tailnet>.ts.net`) and add per-service host aliases through Tailscale HTTPS serve configuration:

- `https://jellyfin.media-stack.<tailnet>.ts.net` -> `http://127.0.0.1:80` with `Host: jellyfin.media-stack.<tailnet>.ts.net`
- Repeat for each service hostname

Implementation uses `tailscale serve` host-specific routing entries managed by bootstrap script.

#### Local Network
Use dnsmasq on `media-stack` to provide wildcard local resolution for `.media-stack` names to the media-stack LAN IP, and advertise that resolver via tailscale-gateway DHCP/DNS flow.

- `*.media-stack` -> `media-stack LAN IP`
- clients resolve `jellyfin.media-stack` etc. automatically

Fallback mode: if router DNS integration is unavailable, vmctl still updates `/etc/hosts` on managed nodes plus emits clear warning for unmanaged clients.

### Docker Exposure
Keep Docker services internal to compose network where possible; only Caddy binds host `80`. Service ports remain optional for diagnostics but no longer part of primary access path.

---

## Streamyfin (iOS) Compatibility

### Root Cause Analysis (Discovery + Connection Failures)
Current symptoms:
- Streamyfin “Search for Local Servers” does not discover Jellyfin.
- Manual connection to `http://media-stack:8097` fails.
- Login using `JELLYFIN_ADMIN_USER` / `JELLYFIN_ADMIN_PASSWORD` fails.

Likely root causes to confirm (in order of probability):
1. **Hostname resolution is wrong for iOS clients**
   - `media-stack` (bare hostname) typically won’t resolve on iOS unless local DNS/search domains are configured.
   - On Tailscale, the stable name is `media-stack.<tailnet>.ts.net` (or a service alias like `jellyfin.media-stack.<tailnet>.ts.net` via `tailscale serve`).
2. **Port mismatch / bypassing the intended ingress**
   - Jellyfin defaults: HTTP `8096`, HTTPS `8920`.
   - `8097` strongly suggests an ad-hoc host port mapping or an outdated compose override.
   - Even if a host port exists, using it bypasses the desired host-based reverse proxy and can cause mixed-scheme/host behavior.
3. **Auto-discovery is fundamentally limited across Tailscale (and sometimes even on LAN)**
   - Jellyfin’s client discovery relies on local broadcast/multicast style mechanisms (best-effort on the same Wi‑Fi broadcast domain).
   - Tailscale does not carry LAN broadcast/multicast between peers, so iOS discovery will not work over tailnet.
   - On LAN, discovery can still fail with AP isolation / “client isolation”, VLAN segmentation, or iOS network permission constraints.
4. **Reverse proxy headers / scheme correctness breaks some clients**
   - If Jellyfin is effectively reached via HTTPS (Tailscale Serve) but upstream sees HTTP, some clients can encounter redirects or mixed-content URL generation.
   - Fix by ensuring proxy forwards `X-Forwarded-Proto`, `X-Forwarded-Host`, `X-Forwarded-For`.
5. **Credentials expectation mismatch**
   - Streamyfin uses Jellyfin API login (same username/password as Jellyfin UI) and receives an auth token.
   - If `JELLYFIN_ADMIN_USER` / `JELLYFIN_ADMIN_PASSWORD` are vmctl secrets but Jellyfin was never provisioned with that user/password, the app login will fail even though the plan “expects” it to work.
6. **Firewall / network policy blocks the correct ingress**
   - LAN access requires TCP `80` to `media-stack` (and optionally TCP `443` if LAN HTTPS is added).
   - Tailnet access requires Tailscale to be up and Serve enabled; local host firewalls must allow `tailscaled` to bind Serve listeners.

### Discovery Strategy (What We Support)
Policy:
- **Tailnet (Tailscale): auto-discovery is not supported** (technical constraint: no broadcast/multicast over tailnet).
- **Local LAN: auto-discovery is best-effort only** (works only when the phone and server are on the same broadcast domain and discovery is enabled/unblocked).

Recommended client connection methods (document and optimize for these):
1. **Primary (tailnet, no port, HTTPS):** `https://jellyfin.media-stack.<tailnet>.ts.net`
2. **Secondary (LAN, no port, HTTP):** `http://jellyfin.media-stack`
3. **Fallback (LAN, explicit IP; only for emergency debug):** `http://<media-stack-lan-ip>:8096`

### Reliable Connection Setup (Streamyfin-Friendly)
Requirements:
- No port needed for normal use.
- HTTPS works via Tailscale Serve.
- LAN hostname works via local DNS wildcard.

Implementation details:
- Standardize Jellyfin upstream as `jellyfin:8096` (container port); avoid/retire host port `8097`.
- Ensure Caddy reverse proxy sets:
  - `header_up X-Forwarded-Proto {scheme}`
  - `header_up X-Forwarded-Host {host}`
  - `header_up X-Forwarded-For {remote_host}`
- Ensure host firewall allows LAN ingress to Caddy on TCP `80` (and TCP `443` if LAN HTTPS is introduced).
- Ensure Jellyfin admin settings:
  - “Allow remote connections” enabled (if required in current config)
  - Base URL empty (no path prefix)
  - Optional: configure “Known proxies” / “Trusted proxies” to include `127.0.0.1` / docker bridge as needed to accept forwarded headers safely

### Authentication Fix (Make App Login Predictable)
Target: Streamyfin can authenticate using a known-good Jellyfin user.

Plan options (pick one and implement consistently):
1. **Credentials-based (preferred for simplicity):**
   - Ensure `JELLYFIN_ADMIN_USER` / `JELLYFIN_ADMIN_PASSWORD` are actually applied to Jellyfin on first boot (create user if missing; rotate password only when explicitly requested).
   - Document that Streamyfin must use those exact credentials (same as Jellyfin UI).
2. **Token-based fallback (for diagnostics and automation):**
   - Provision a Jellyfin API key (or user access token) and store it as a vmctl secret.
   - Use it for curl-based health/auth tests and as an emergency client auth method if Streamyfin supports API keys.

---

## vmctl Integration

## `vmctl.toml` Changes
Add explicit hostname route table under media services.

```toml
[resources.features.media_services]
enabled = true
ui_homepage_enabled = true
ui_homepage_title = "Media Stack"

[[resources.features.media_services.host_routes]]
host = "jellyfin.media-stack"
tail_host = "jellyfin.media-stack.<tailnet>.ts.net"
service = "jellyfin"
upstream = "jellyfin:8096"
health_path = "/System/Info/Public"

[[resources.features.media_services.host_routes]]
host = "sonarr.media-stack"
tail_host = "sonarr.media-stack.<tailnet>.ts.net"
service = "sonarr"
upstream = "sonarr:8989"
health_path = "/"
```

## Packs / Services
- Keep service definitions in `packs/services/*.toml`
- Add/standardize `internal_port` metadata for host routing generation
- Remove dependence on base URL/path prefix settings for ARR/Jellyfin

## Template Changes
- `packs/templates/caddyfile.media.hbs`
  - generate one `host` block per route
- `packs/templates/media-index.html.hbs`
  - render links to hostname URLs instead of ports
- `packs/templates/media.env.hbs`
  - remove legacy base path vars if no longer required
- add `packs/templates/dnsmasq.media-stack.conf.hbs`
  - wildcard local DNS for `.media-stack`

## Provisioning Changes
- `bootstrap-media.sh`
  - ensure Caddy conf generated from host routes
- `bootstrap-ui-routing.sh`
  - program tailscale serve host-based HTTPS mappings
  - verify each host route
- extend bootstrap flow to ensure a known-good Jellyfin user exists (for Streamyfin login), without destructive resets
- new `bootstrap-local-dns.sh`
  - install/configure dnsmasq
  - configure wildcard `.media-stack` -> local IP
  - restart dnsmasq safely and idempotently

---

## Config / Template / Rust Examples

## Caddy Template Snippet (`caddyfile.media.hbs`)
```hbs
:80 {
  encode gzip

  handle_path /healthz {
    respond "ok" 200
  }

  {{#each features.media_services.host_routes}}
  @{{this.service}} host {{this.host}} {{this.tail_host}}
  handle @{{this.service}} {
    reverse_proxy {{this.upstream}} {
      header_up Host {host}
      header_up X-Forwarded-Proto {scheme}
      header_up X-Forwarded-Host {host}
      header_up X-Forwarded-For {remote_host}
    }
  }
  {{/each}}

  handle / {
    root * /srv/ui-index
    file_server
  }
}
```

## Index Template Snippet (`media-index.html.hbs`)
```hbs
{{#each features.media_services.host_routes}}
<li>
  <a href="https://{{this.tail_host}}">{{this.service}}</a>
  <p>LAN: http://{{this.host}}</p>
</li>
{{/each}}
```

## Rust Integration Points
- `crates/packs/src/lib.rs`
  - validate `host_routes` schema (`host`, `tail_host`, `service`, `upstream`, `health_path`)
  - ensure unique hostnames/services
- `crates/planner/src/lib.rs`
  - normalize defaults for host routes
- `crates/backend-terraform/src/lib.rs` tests
  - fixture assertions for generated Caddy, env, index, scripts

---

## Task Breakdown

## 0. Streamyfin/Jellyfin RCA (Before Changes)
1. Confirm Jellyfin is actually reachable on the node:
   - `curl -fsS http://127.0.0.1:8096/System/Info/Public`
2. Confirm current ingress behavior (LAN + tailnet):
   - `curl -fsS -H "Host: jellyfin.media-stack" http://127.0.0.1/System/Info/Public`
   - `curl -fsS https://jellyfin.media-stack.<tailnet>.ts.net/System/Info/Public`
3. Confirm which port is currently being used/advertised (`8096` vs `8097`) and remove stale client instructions accordingly.
4. Confirm the intended Jellyfin user can authenticate via API:
   - `POST /Users/AuthenticateByName` returns an access token for the provisioned user.

## 1. Config
1. Add `host_routes` schema support.
2. Add defaults in media role.
3. Update `vmctl.example.toml`.

## 2. Templates
1. Replace route generation in Caddy template with host routing.
2. Update media index links to hostname URLs.
3. Add local DNS template (`dnsmasq`).

## 3. Provisioning
1. Add `bootstrap-local-dns.sh`.
2. Extend `bootstrap-ui-routing.sh` for tailscale host mappings.
3. Remove path/base-url compatibility logic from bootstrap scripts.

## 4. DNS / Hostname Setup
1. Configure dnsmasq wildcard for `.media-stack`.
2. Ensure resolver propagation from gateway (or explicit fallback behavior).
3. Validate host resolution from media-stack and gateway.

## 5. Validation
1. Curl each hostname locally and tailnet.
2. Browser checks for asset loads per service.
3. Re-run apply and confirm idempotency.
4. Streamyfin validation:
   - manual connect to tailnet HTTPS URL succeeds
   - manual connect to LAN hostname succeeds
   - login succeeds and library loads

---

## TDD Approach

## Reproduce Failures
- Broken discovery (expected on tailnet): Streamyfin “Search for Local Servers” finds nothing over Tailscale
- Broken DNS (LAN): `getent hosts jellyfin.media-stack` fails
- Broken proxy: `curl -H "Host: sonarr.media-stack" http://media-stack` fails
- Broken tailnet host: `curl https://sonarr.media-stack.<tailnet>.ts.net` fails
- Broken Jellyfin API: `curl -fsS https://jellyfin.media-stack.<tailnet>.ts.net/System/Info/Public` fails

## Tests to Add/Update
1. Template fixture test: Caddy has one host matcher per service.
2. Template fixture test: index links use hostname URLs.
3. Provision script fixture test: tailscale serve includes each host route.
4. Provision script fixture test: dnsmasq config generated with wildcard.
5. Integration script smoke:
   - resolve local hostnames
   - fetch each service root and static asset
   - Jellyfin API responds at `/System/Info/Public`
   - Jellyfin auth endpoint (`/Users/AuthenticateByName`) accepts known-good credentials

## Example Test Cases
- `renders_host_based_caddy_routes_for_all_media_services`
- `media_index_uses_service_hostnames_not_ports`
- `bootstrap_ui_routing_programs_tailscale_host_routes`
- `bootstrap_local_dns_configures_media_stack_wildcard`
- `jellyfin_system_info_public_is_reachable_via_tailnet_https`
- `jellyfin_system_info_public_is_reachable_via_lan_hostname_http`
- `jellyfin_authenticate_by_name_succeeds_for_provisioned_user`

---

## Definition of Done

1. Each service UI loads correctly at:
   - `https://<service>.media-stack.<tailnet>.ts.net`
   - `http://<service>.media-stack`
2. No port required for normal use.
3. JS/CSS assets load with no broken relative-path behavior.
4. Streamyfin can connect and authenticate:
   - Manual connect succeeds via `https://jellyfin.media-stack.<tailnet>.ts.net`
   - Manual connect succeeds via `http://jellyfin.media-stack`
   - Login succeeds using the provisioned Jellyfin user (same credentials as Jellyfin UI)
5. Discovery expectations are clear and require no debugging:
   - Tailnet: discovery is documented as unsupported (manual URL required)
   - LAN: discovery may work best-effort; manual URL is always supported
6. `cargo run -q -p vmctl -- apply` from clean state provisions everything automatically.
7. Re-running apply is idempotent (no duplicate tailscale serve entries, no duplicate DNS config blocks, no resource churn).

---

## DRY Strategy

- Single `host_routes` table drives:
  - Caddy host routing
  - index page links
  - tailscale serve host mappings
  - health verification loops
- Reusable template partial/helper for host route loop.
- Bootstrap scripts consume same rendered route data file (`/opt/media/config/routes.json`) to avoid duplicating host/service definitions in bash.
