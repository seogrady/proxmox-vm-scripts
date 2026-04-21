# UI Routing Implementation Plan (Chosen Approach)

## Architecture Overview

Implement a **single-entrypoint routing layer** on `media-stack`:

1. Add a reverse proxy (Caddy container) to `docker-compose.media`.
2. Route path prefixes to internal services:
   - `/` -> generated HTML service index page
   - `/jellyfin` -> Jellyfin
   - `/sonarr` -> Sonarr
   - `/radarr` -> Radarr
   - `/prowlarr` -> Prowlarr
   - `/qbittorrent` -> qBittorrent
3. Expose only proxy root via Tailscale Serve:
   - `https://media-stack.<tailnet>.ts.net/` -> `http://127.0.0.1:80`
4. Configure each app base URL in bootstrap so UI assets and API paths work under prefixes.

This keeps one Tailscale URL, scales by adding route entries, and stays fully `apply`-driven.

Compatibility policy:
- Default mode is path-prefix routing.
- Any service that cannot reliably serve static assets/API/websockets under prefix is automatically moved to exception mode (host-based route or dedicated tailnet endpoint), still provisioned by `apply`.

## Config Changes (`vmctl.toml`)

Add explicit routing config under media services:

```toml
[resources.features.media_services]
enabled = true
ui_routing_mode = "path_prefix"
ui_homepage_enabled = true
ui_homepage_title = "Media Stack"

[[resources.features.media_services.ui_routes]]
path = "/"
service = "ui-index"
title = "Home"
description = "Service directory"

[[resources.features.media_services.ui_routes]]
path = "/jellyfin"
service = "jellyfin"
title = "Jellyfin"
description = "Media server"

[[resources.features.media_services.ui_routes]]
path = "/sonarr"
service = "sonarr"
title = "Sonarr"
description = "TV automation"

[[resources.features.media_services.ui_routes]]
path = "/radarr"
service = "radarr"
title = "Radarr"
description = "Movie automation"

[[resources.features.media_services.ui_routes]]
path = "/prowlarr"
service = "prowlarr"
title = "Prowlarr"
description = "Indexer manager"

[[resources.features.media_services.ui_routes]]
path = "/qbittorrent"
service = "qbittorrent-vpn"
title = "qBittorrent"
description = "Torrent client"
```

Add exposure controls:

```toml
[resources.features.media_services.exposure]
tailscale_https_enabled = true
tailscale_https_target = "http://127.0.0.1:80"
```

## Pack/Service Updates

1. Add `caddy` service definition in `packs/services/caddy.toml`.
2. Update `packs/roles/media_stack.toml` default service set to include `caddy`.
3. Ensure generated compose publishes only proxy externally (or keep LAN ports configurable but disabled by default).
4. Add bootstrap ordering:
   - bootstrap-media (containers)
   - bootstrap-ui-routing (proxy + per-app base URLs)
   - bootstrap-jellyfin/bootstrap-arr/bootstrap-qbittorrent (idempotent API-level wiring)

## Template Updates (`.hbs`)

### `docker-compose.media.hbs`
- Include `caddy` service
- Mount generated `Caddyfile`
- Place upstream services on shared Docker network

Example snippet:

```hbs
caddy:
  image: caddy:2
  restart: unless-stopped
  ports:
    - "80:80"
  volumes:
    - "${CONFIG_PATH}/caddy/Caddyfile:/etc/caddy/Caddyfile:ro"
```

### New `caddyfile.media.hbs`

```hbs
:80 {
  encode gzip
  handle = / {
    root * /srv/ui-index
    file_server
  }
  {{#each features.media_services.ui_routes}}
  {{#unless (eq this.path "/")}}
  handle_path {{this.path}}* {
    reverse_proxy {{lookup ../features.media_services.upstreams this.service}}
  }
  {{/unless}}
  {{/each}}
}
```

### New `media-index.html.hbs`

Generated static homepage at `/` with service cards (name, description, link), sourced from `ui_routes` metadata:

```hbs
<!doctype html>
<html>
<head><meta charset="utf-8"><title>{{features.media_services.ui_homepage_title}}</title></head>
<body>
  <h1>{{features.media_services.ui_homepage_title}}</h1>
  <ul>
    {{#each features.media_services.ui_routes}}
    {{#unless (eq this.path "/")}}
    <li><a href="{{this.path}}">{{this.title}}</a> - {{this.description}}</li>
    {{/unless}}
    {{/each}}
  </ul>
</body>
</html>
```

### `media.env.hbs`
- Add routing/exposure vars:

```hbs
UI_ROUTING_MODE={{features.media_services.ui_routing_mode}}
TAILSCALE_HTTPS_ENABLED={{features.media_services.exposure.tailscale_https_enabled}}
TAILSCALE_HTTPS_TARGET={{features.media_services.exposure.tailscale_https_target}}
```

## Provisioning Changes

Create `packs/scripts/bootstrap-ui-routing.sh`:

1. Validate route config (unique paths, known services).
2. Render/install Caddyfile under `/opt/media/config/caddy/Caddyfile`.
3. Render/install `index.html` under `/opt/media/config/caddy/ui-index/index.html`.
3. Restart caddy container (`docker compose up -d caddy`).
4. Configure per-app base paths:
   - Sonarr/Radarr/Prowlarr: set URL base via API.
   - qBittorrent: set `WebUI\RootFolder`.
   - Jellyfin: set Base URL to `/jellyfin` via API (or `/` if chosen root mode).
5. Health-check homepage and each routed endpoint via local curl before success.
   - Validate index + referenced static assets (JS/CSS) are 200.
   - Validate websocket/API endpoint availability when applicable.
   - Mark service prefix-compatible or prefix-incompatible.
6. Apply exception routing for prefix-incompatible services:
   - host-based route if available, else dedicated tailnet endpoint mapping.
6. Configure Tailscale Serve:
   - `tailscale serve --yes --bg "$TAILSCALE_HTTPS_TARGET"`
   - if disabled, `tailscale serve reset`.

All steps must be idempotent and rerunnable.

## Tailscale Exposure Strategy

- Single tailnet HTTPS URL on `media-stack`.
- Tailscale Serve points to local reverse proxy only.
- No per-service port exposure required.
- Drift repair is part of every `apply` provisioning pass:
  - re-assert serve config
  - re-assert Caddy routes
  - re-assert app base paths

## CLI Behavior (`apply`)

`vmctl apply` behavior:

1. Render desired state and templates.
2. Reconcile backend state.
3. Apply Terraform/OpenTofu.
4. Provision media-stack scripts including `bootstrap-ui-routing.sh`.
5. Validate routed endpoints.
6. Write lockfile as cache.

No manual post-steps.

Rust integration sketch:

```rust
// crates/cli/src/main.rs
progress.run("provisioning resources", || run_provision(&workspace, &desired, &progress))?;
progress.run("verifying media ui routes", || verify_media_ui_routes(&desired))?;
```

## Task Breakdown (Step-by-Step)

1. Extend media feature schema with `ui_routing_mode`, `ui_routes`, `exposure`.
2. Add Caddy service pack entry.
3. Update media role defaults and bootstrap list.
4. Add `caddyfile.media.hbs` and update compose/env templates.
5. Implement `bootstrap-ui-routing.sh` with API-based base-path setters.
6. Add CLI verification helper for routed endpoints.
7. Add fixture updates for backend-render tests.
8. Run full test suite and live `apply --ignore-lock` verification.

## TDD Approach

### Failure Reproduction

1. Route missing:
   - `curl http://media-stack/sonarr` -> 404.
2. Base URL mismatch:
   - UI static assets 404 under prefix.
3. Serve drift:
   - `tailscale serve reset` then re-run apply.
4. Root-bound asset failure:
   - app returns `/static/...` from domain root and fails under `/service`.

### Tests to Add

1. **Template render tests**
   - Caddy service appears in compose.
   - Caddyfile contains configured route handles.
   - index template renders all configured services with links/descriptions.
2. **Provision script fixture tests**
   - `bootstrap-ui-routing.sh` includes base-path and serve commands.
3. **CLI tests**
   - verification step detects missing route.
4. **Integration test**
   - simulate serve reset; apply restores working root URL + prefixes.
5. **Compatibility-gate test**
   - simulate prefix-incompatible service metadata; apply emits exception route and verification passes.

## DRY Considerations

- Define one canonical `ui_routes` table in config.
- Reuse same route map for:
  - Caddyfile generation
  - index.html generation
  - endpoint verification
  - bootstrap base-path configuration mapping
- Keep per-service metadata in one reusable map:
  - service name -> upstream address + base-path API adapter + compatibility mode.

## Definition of Done

1. `vmctl apply` provisions and verifies:
   - `https://media-stack.<tailnet>.ts.net/` -> generated services index page
   - `https://media-stack.<tailnet>.ts.net/jellyfin` -> Jellyfin
   - `.../sonarr`, `.../radarr`, `.../prowlarr`, `.../qbittorrent` reachable
2. Re-running `apply` is idempotent.
3. Resetting Tailscale Serve is auto-healed by next `apply`.
4. All tests pass (`cargo test -q`).
5. No manual UI routing or tailscale commands required.
