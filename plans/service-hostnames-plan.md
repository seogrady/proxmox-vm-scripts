# Service Hostnames Plan

## Architecture Overview

### Goal
Expose each media service via dedicated hostnames without ports, for both tailnet and local LAN access:

- `jellyfin.media-stack.ts.net`
- `sonarr.media-stack.ts.net`
- `radarr.media-stack.ts.net`
- `prowlarr.media-stack.ts.net`
- `qbittorrent.media-stack.ts.net`

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

### Name Resolution

#### Tailscale
Use the node DNS name already assigned by Tailscale (`media-stack.<tailnet>.ts.net`) and add per-service host aliases through Tailscale HTTPS serve configuration:

- `https://jellyfin.media-stack.ts.net` -> `http://127.0.0.1:80` with `Host: jellyfin.media-stack.ts.net`
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
tail_host = "jellyfin.media-stack.ts.net"
service = "jellyfin"
upstream = "jellyfin:8096"
health_path = "/web/"

[[resources.features.media_services.host_routes]]
host = "sonarr.media-stack"
tail_host = "sonarr.media-stack.ts.net"
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

---

## TDD Approach

## Reproduce Failures
- Broken DNS: `getent hosts jellyfin.media-stack` fails
- Broken proxy: `curl -H "Host: sonarr.media-stack" http://media-stack` fails
- Broken tailnet host: `curl https://sonarr.media-stack.ts.net` fails

## Tests to Add/Update
1. Template fixture test: Caddy has one host matcher per service.
2. Template fixture test: index links use hostname URLs.
3. Provision script fixture test: tailscale serve includes each host route.
4. Provision script fixture test: dnsmasq config generated with wildcard.
5. Integration script smoke:
   - resolve local hostnames
   - fetch each service root and static asset

## Example Test Cases
- `renders_host_based_caddy_routes_for_all_media_services`
- `media_index_uses_service_hostnames_not_ports`
- `bootstrap_ui_routing_programs_tailscale_host_routes`
- `bootstrap_local_dns_configures_media_stack_wildcard`

---

## Definition of Done

1. Each service UI loads correctly at:
   - `https://<service>.media-stack.ts.net`
   - `http://<service>.media-stack`
2. No port required for normal use.
3. JS/CSS assets load with no broken relative-path behavior.
4. `cargo run -q -p vmctl -- apply` from clean state provisions everything automatically.
5. Re-running apply is idempotent (no duplicate tailscale serve entries, no duplicate DNS config blocks, no resource churn).

---

## DRY Strategy

- Single `host_routes` table drives:
  - Caddy host routing
  - index page links
  - tailscale serve host mappings
  - health verification loops
- Reusable template partial/helper for host route loop.
- Bootstrap scripts consume same rendered route data file (`/opt/media/config/routes.json`) to avoid duplicating host/service definitions in bash.
