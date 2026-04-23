# Proxmox Homelab SSO Security Plan (Authelia + Reverse Proxy + Jellyfin SSO Plugin)

Date: 2026-04-23

## Objective

Secure the entire Proxmox homelab (Proxmox node `mini`) so that **every HTTP access point** (Proxmox UI and all service web UIs across VMs/LXCs/containers) is reachable **only** through a centralized SSO layer using **Authelia**.

This plan is written to be **fully automated** and **reproducible** via `vmctl apply` using the repo’s existing architecture:

- `packs/services/*.toml` define docker services
- `packs/templates/*.hbs` render config/artifacts
- `packs/scripts/*.sh` bootstrap idempotently on guests
- Tailscale is already used for secure remote access (`tailscale-gateway` subnet router + per-node clients)

## Scope (Everything Must Be Protected)

Protected behind Authelia SSO (mandatory redirect when unauthenticated):

- Proxmox web UI/API (`https://mini:8006`)
- Jellyfin (plus Streamyfin/Jellysearch/Jellio paths served by Jellyfin or adjacent services)
- Jellyseerr
- Sonarr / Radarr / Prowlarr / Bazarr
- qBittorrent (VPN stack)
- Any exposed HTTP services (including “home/index” pages)
- Any VM/LXC/container web UIs (including future additions)

Access must work via:

- Tailscale
- Local network

## Non-Negotiable Requirements Mapping

- Centralized SSO: Authelia is the single auth layer for all routed services
- Mandatory redirect for unauthenticated requests: all unauthenticated requests redirect to Authelia portal
- Reverse proxy: single routing layer enforces SSO consistently and supports websockets
- Jellyfin: integrate via `jellyfin-plugin-sso` (OIDC to Authelia) so humans do not need local Jellyfin credentials
- Proxmox UI: reachable only behind the proxy + Authelia; direct `:8006` blocked from clients
- User management: Authelia has no native user management UI; we deploy **LLDAP** for directory + UI and wire Authelia to LDAP
- Zero-manual configuration: no clicking dashboards to “finish setup”; everything is configured by scripts/templates under `vmctl apply`
- Enabled by default but opt-out: SSO enabled unless explicitly disabled in `vmctl.toml`

## Architecture

### Components (Single Ingress Resource)

We standardize on **one ingress VM** which already exists and already runs Docker:

- `media-stack` VM: runs the entire proxy+auth stack in Docker Compose
  - `ingress` (NGINX reverse proxy)
  - `authelia` (SSO portal + authz endpoint + OIDC provider)
  - `redis` (Authelia session storage)
  - `lldap` (LDAP directory + user/group UI used by Authelia)
  - existing media services (Jellyfin, Sonarr, Radarr, Prowlarr, Bazarr, Jellyseerr, qBittorrent-vpn, etc)

This keeps “all web entrypoints” centralized and avoids cross-VM service discovery complexity.

### Container Version Pinning (Production Requirement)

To make `vmctl apply` reproducible and reduce “silent breaking upgrades”, pin the auth/proxy stack images:

- NGINX: `nginx:1.30.0-alpine` (stable release line)
- Authelia: `authelia/authelia:4.39.19`
- Redis: `redis:7.4-alpine` (official image)
- LLDAP: `lldap/lldap:2026-03-04-alpine`
- ACME client (lego): `goacme/lego:v4.34.0`

Media-service images can continue using the existing pack defaults initially, but the SSO/security-critical components above must be pinned.

### Canonical Hostnames (Required For OIDC + Consistent Redirects)

Authelia OIDC has a single issuer URL, and Jellyfin’s OIDC client must use a single consistent hostname for:

- the Authelia portal (`https://auth.lab.example.com`)
- the OIDC discovery/authorization/token endpoints
- the Jellyfin redirect URI (`https://jellyfin.lab.example.com/sso/OID/redirect/authelia`)

To make this work on both LAN and Tailnet **without split DNS** and without per-network hostnames, this plan requires a real DNS zone you control:

- `features.sso.base_domain` (example: `lab.example.com`)

DNS requirements:

1. Create a wildcard record which points to the `media-stack` LAN IP:
   - `*.lab.example.com` -> the static LAN IPv4 of `media-stack` (set a DHCP reservation so it does not change)
2. Do not expose that private RFC1918 address on the public internet; external (non-tailnet) clients can resolve it but cannot reach it.
3. Tailnet clients reach that LAN IP via the existing Tailscale subnet router (`tailscale-gateway`) which already advertises the LAN route.

Result:

- LAN devices access `https://jellyfin.lab.example.com`
- Tailnet devices also access `https://jellyfin.lab.example.com` (traffic routes over Tailscale into the LAN)
- Redirect behavior is identical across LAN and Tailnet because the hostnames are identical

Optional (LAN convenience, not used for OIDC):

- You may also run dnsmasq for shortnames like `jellyfin.media-stack` on the LAN if you want, but the canonical `*.lab.example.com` hostnames remain the source of truth for SSO/OIDC and must be the ones users bookmark.

### Service Coverage Notes (What “Secured” Means Per Item)

- Proxmox UI: accessed only via `pve.*` hostname through NGINX + Authelia; direct `mini:8006` blocked.
- Jellyfin (browser): always behind Authelia; inside Jellyfin, login uses `jellyfin-plugin-sso` (OIDC to Authelia) so users do not need local Jellyfin passwords.
- Jellyseerr/*arr/Bazarr/qBittorrent: the services remain untrusted internally and are protected exclusively by the proxy; their direct ports must not be reachable from clients.
- Streamyfin/Jellio/Jellysearch/Jellysearch/Jellio:
  - server-side components are accessed via the Jellyfin hostname and therefore inherit SSO protection
  - any standalone HTTP UIs (e.g. Jellysearch if exposed) must be routed as their own hostnames in `features.sso.routes`
- Kodi:
  - Kodi itself is not a web UI that needs SSO, but its Jellyfin addon requires Jellyfin API access
  - by default, this plan keeps Kodi compatibility by allowing Jellyfin token-based access for non-browser clients via a dedicated “API hostname” route that requires a Jellyfin API token (not Authelia), and is not exposed publicly
  - human-facing Jellyfin access remains SSO-only

This avoids breaking existing playback clients while still meeting the core security goal: no interactive web UI is reachable without authentication.

### Request Flow (Unauthenticated)

```
Client (LAN or Tailnet)
  -> ingress NGINX :443 (LAN directly; Tailnet routes to the same LAN IP via the Tailscale subnet router)
    -> auth_request to Authelia authz endpoint
      -> 401 + redirect to Authelia portal
        -> user logs in (and completes 2FA if required)
          -> Authelia redirects back to original URL
            -> NGINX retries auth_request, gets 200
              -> request proxied to backend service
```

### Request Flow (Authenticated)

```
Client
  -> NGINX (sends auth_request metadata to Authelia)
    -> Authelia returns 200 + Remote-* headers
      -> NGINX forwards to service (injects Remote-* headers)
        -> Service responds (web UI + websockets supported)
```

### Session and Token Lifecycle (Authelia)

- Browser session:
  - Authelia sets a session cookie scoped to the relevant cookie domain.
  - Sessions stored in Redis (supports HA later; no state on NGINX).
  - Expiration/inactivity enforced by Authelia config.
- OIDC (Jellyfin plugin):
  - Authelia is the OIDC issuer; Jellyfin is an OIDC client.
  - Jellyfin plugin performs Authorization Code + PKCE flow (`S256`).
  - Authelia issues ID token and (optionally) refresh/access tokens per configuration.

## Reverse Proxy Design (NGINX + Authelia)

We use Authelia’s recommended NGINX pattern (`auth_request`) and redirect-on-401 behavior.

### Tailscale Routing (No Special DNS Required)

Tailnet devices access the same `*.lab.example.com` hostnames as LAN devices.

Connectivity is provided by the existing `tailscale-gateway` subnet router advertising the LAN route, so remote tailnet devices can reach the ingress private IP (the wildcard DNS target) without exposing anything publicly.

### Core Auth Enforcement Snippet (NGINX)

The Authelia docs’ pattern is:

- `auth_request /internal/authelia/authz;`
- capture redirect URL from Authelia response header (modern method)
- redirect unauthenticated users to the portal automatically

We implement this as a single reusable include, applied to every service `location /`.

### NGINX Config (Rendered)

The NGINX config is rendered as a single file (mounted read-only) and is fully route-table-driven.

Key points:

- every service vhost includes the same Authelia `auth_request` include
- the Authelia portal vhost is the only one without auth enforcement
- Proxmox upstream uses `proxy_ssl_verify off`

```nginx
# /etc/nginx/nginx.conf
events {}

http {
  # Websocket upgrade helper.
  map $http_upgrade $connection_upgrade {
    default upgrade;
    '' close;
  }

  # Trust X-Forwarded-Proto when present (if running behind an L7 proxy), else use $scheme.
  map $http_x_forwarded_proto $effective_proto {
    default $http_x_forwarded_proto;
    ''      $scheme;
  }

  # Authelia NGINX integration uses two reusable snippet files:
  # - authelia-location.conf: defines /internal/authelia/authz used by auth_request
  # - authelia-authrequest.conf: enforces auth and performs redirect on 401
  # This mirrors Authelia's documented pattern.

  # /etc/nginx/snippets/authelia-location.conf (rendered)
  # Creates an internal endpoint that forwards authz checks to Authelia.
  #
  # NOTE: This snippet must be included in every protected server block because
  # auth_request targets a URI on the same virtual host.
  #
  # (Shown inline here for completeness; vmctl renders it as a separate file.)
  #
  # set $upstream_authelia http://authelia:9091/api/authz/auth-request;
  # location = /internal/authelia/authz {
  #   internal;
  #   proxy_pass $upstream_authelia;
  #   proxy_set_header X-Original-Method $request_method;
  #   proxy_set_header X-Original-URL    $effective_proto://$http_host$request_uri;
  #   proxy_set_header X-Forwarded-Method $request_method;
  #   proxy_set_header X-Forwarded-Proto  $effective_proto;
  #   proxy_set_header X-Forwarded-Host   $http_host;
  #   proxy_set_header X-Forwarded-URI    $request_uri;
  #   proxy_pass_request_body off;
  #   proxy_set_header Content-Length "";
  # }
  #
  # /etc/nginx/snippets/authelia-authrequest.conf (rendered)
  #
  # auth_request /internal/authelia/authz;
  # auth_request_set $redirection_url $upstream_http_location;
  # error_page 401 =302 $redirection_url;
  # auth_request_set $user   $upstream_http_remote_user;
  # auth_request_set $groups $upstream_http_remote_groups;
  # auth_request_set $name   $upstream_http_remote_name;
  # auth_request_set $email  $upstream_http_remote_email;
  # proxy_set_header Remote-User   $user;
  # proxy_set_header Remote-Groups $groups;
  # proxy_set_header Remote-Name   $name;
  # proxy_set_header Remote-Email  $email;

  # Redirect plain HTTP to HTTPS for the whole zone.
  server {
    listen 80;
    server_name lab.example.com *.lab.example.com;
    return 301 https://$host$request_uri;
  }

  server {
    listen 443 ssl;
    server_name auth.lab.example.com;
    ssl_certificate     /etc/nginx/certs/wildcard/fullchain.pem;
    ssl_certificate_key /etc/nginx/certs/wildcard/privkey.pem;

    location / {
      proxy_pass http://authelia:9091;
      proxy_set_header Host $host;
      proxy_set_header X-Forwarded-Proto $effective_proto;
      proxy_set_header X-Forwarded-Host  $host;
      proxy_set_header X-Forwarded-URI   $request_uri;
    }
  }

  server {
    listen 443 ssl;
    server_name jellyfin.lab.example.com;
    ssl_certificate     /etc/nginx/certs/wildcard/fullchain.pem;
    ssl_certificate_key /etc/nginx/certs/wildcard/privkey.pem;
    include /etc/nginx/snippets/authelia-location.conf;
    location / {
      include /etc/nginx/snippets/authelia-authrequest.conf;

      proxy_http_version 1.1;
      proxy_set_header Upgrade $http_upgrade;
      proxy_set_header Connection $connection_upgrade;

      proxy_set_header Host $host;
      proxy_set_header X-Forwarded-Proto $effective_proto;
      proxy_set_header X-Forwarded-Host  $host;
      proxy_set_header X-Forwarded-URI   $request_uri;

      proxy_pass http://jellyfin:8096;
    }
  }

  server {
    listen 443 ssl;
    server_name pve.lab.example.com;
    ssl_certificate     /etc/nginx/certs/wildcard/fullchain.pem;
    ssl_certificate_key /etc/nginx/certs/wildcard/privkey.pem;
    include /etc/nginx/snippets/authelia-location.conf;
    location / {
      include /etc/nginx/snippets/authelia-authrequest.conf;

      proxy_http_version 1.1;
      proxy_set_header Upgrade $http_upgrade;
      proxy_set_header Connection $connection_upgrade;

      proxy_set_header Host $host;
      proxy_set_header X-Forwarded-Proto $effective_proto;
      proxy_set_header X-Forwarded-Host  $host;
      proxy_set_header X-Forwarded-URI   $request_uri;

      proxy_ssl_verify off;
      proxy_pass https://mini:8006;
    }
  }
}
```

### Websocket Compatibility

For services that use websockets (Proxmox console, Jellyfin, *arr UIs, etc), enforce:

- `proxy_http_version 1.1`
- `proxy_set_header Upgrade $http_upgrade`
- `proxy_set_header Connection $connection_upgrade` (via a `map`)

### Proxmox Upstream Specifics

Proxmox UI is HTTPS on `mini:8006` with a self-signed certificate by default.

NGINX upstream settings for Proxmox:

- `proxy_pass https://mini:8006;`
- `proxy_ssl_verify off;`
- forward headers: `Host`, `X-Forwarded-*`
- websockets enabled

Additionally, we **block direct client access** to `mini:8006` so the only reachable path is via SSO.

## Authelia Design (Users, Access Control, OIDC)

### User Directory and “User Management UI”

Authelia does not include a general-purpose user management UI. Instead, it authenticates against a backend (file, LDAP, etc).

This plan deploys **LLDAP**:

- provides user/group management UI
- provides LDAP service for Authelia’s authentication backend

LLDAP is then exposed as `https://lldap.lab.example.com` (LAN and Tailnet), protected behind Authelia like everything else (admin-only).

### Authelia Authentication Backend (LLDAP)

Authelia’s LLDAP integration uses:

```yaml
    authentication_backend:
      ldap:
        implementation: 'lldap'
        address: 'ldap://lldap:3890'
        base_dn: 'DC=home,DC=arpa'
        user: 'UID=authelia,OU=people,DC=home,DC=arpa'
        password: '{{ secret "/config/secrets/lldap.authelia.bind_password" }}'
```

This matches Authelia’s documented LLDAP defaults and pattern.

### Authelia Session Cookies and HTTPS Constraints

Authelia session cookie domains require `authelia_url` which must be `https://` and must share cookie scope with the domain.

To satisfy this for **both LAN and Tailnet** without split DNS:

1. We terminate TLS on the ingress with an ACME certificate for `*.lab.example.com` using DNS-01 (Cloudflare recommended).
2. LAN and tailnet clients both use the same `https://*.lab.example.com` hostnames (tailnet routes to the private ingress IP via the subnet router).

We configure a single cookie domain entry:

- domain: `lab.example.com` (covers all `*.lab.example.com` services)
  - `authelia_url: https://auth.lab.example.com`

### Access Control (Default Deny)

Authelia access control rules:

- default policy: `deny`
- explicit allow rules per service hostname, scoped by group membership

Example group model in LLDAP:

- `homelab-admins`: Proxmox + everything
- `media-users`: Jellyfin + Jellyseerr
- `arr-admins`: Sonarr/Radarr/Prowlarr/Bazarr
- `downloads-users`: qBittorrent UI

This provides least-privilege while still being DRY (rules generated from a single route table).

### OIDC Provider (Jellyfin)

Authelia provides an official Jellyfin OIDC client example which uses:

- redirect URI: `https://jellyfin.example.com/sso/OID/redirect/authelia`
- PKCE (S256)
- scopes: `openid`, `profile`, `groups`
- authorization policy commonly `two_factor`

We follow that model and generate a Jellyfin client whose redirect URIs include the canonical hostname:

- `https://jellyfin.lab.example.com/sso/OID/redirect/authelia`

### Authelia OIDC Provider Key Material (Generated, No Manual Steps)

Authelia’s OIDC provider requires an HMAC secret and at least one RSA JWK configured with `RS256`.

Bootstrap generates and persists these as files under `/opt/media/config/authelia/secrets`:

```bash
# Generate random secrets (session, storage encryption, OIDC HMAC).
docker run --rm -v /opt/media/config/authelia/secrets:/secrets authelia/authelia:4.39.19 \
  sh -lc 'authelia crypto rand --length 64 > /secrets/session.secret && authelia crypto rand --length 64 > /secrets/storage.encryption_key && authelia crypto rand --length 64 > /secrets/oidc.hmac_secret'

# Generate an RSA keypair for OIDC JWKS (writes private.pem/public.pem).
docker run --rm -v /opt/media/config/authelia/secrets/oidc/jwks:/keys authelia/authelia:4.39.19 \
  authelia crypto pair rsa generate --directory /keys

# Normalize to the exact file path referenced in configuration.yml:
cp /opt/media/config/authelia/secrets/oidc/jwks/private.pem /opt/media/config/authelia/secrets/oidc/jwks/rsa.2048.key
```

The Authelia `configuration.yml` uses the built-in secret templating to load these files at runtime (no secrets hard-coded into the YAML).

```yaml
server:
  address: tcp://0.0.0.0:9091

log:
  level: info

authentication_backend:
  ldap:
    implementation: lldap
    address: ldap://lldap:3890
    base_dn: DC=lab,DC=example,DC=com
    user: UID=authelia,OU=people,DC=lab,DC=example,DC=com
    password: '{{ secret \"/config/secrets/lldap.authelia.bind_password\" }}'

session:
  name: authelia_session
  secret: '{{ secret \"/config/secrets/session.secret\" }}'
  cookies:
    - domain: lab.example.com
      authelia_url: https://auth.lab.example.com
      default_redirection_url: https://jellyfin.lab.example.com
  redis:
    host: redis
    port: 6379

storage:
  encryption_key: '{{ secret \"/config/secrets/storage.encryption_key\" }}'
  local:
    path: /config/db.sqlite3

notifier:
  filesystem:
    filename: /config/notification.txt

identity_providers:
  oidc:
    issuer: https://auth.lab.example.com
    hmac_secret: '{{ secret \"/config/secrets/oidc.hmac_secret\" }}'
    jwks:
      - algorithm: RS256
        use: sig
        key: {{ secret "/config/secrets/oidc/jwks/rsa.2048.key" | mindent 10 "|" | msquote }}
    clients:
      - client_id: jellyfin
        client_name: Jellyfin
        client_secret: '{{ secret \"/config/secrets/oidc.clients.jellyfin.pbkdf2\" }}'
        require_pkce: true
        pkce_challenge_method: S256
        redirect_uris:
          - https://jellyfin.lab.example.com/sso/OID/redirect/authelia
        scopes:
          - openid
          - profile
          - groups
        response_types:
          - code
        grant_types:
          - authorization_code

access_control:
  default_policy: deny
  rules:
    - domain: auth.lab.example.com
      policy: bypass
    - domain: jellyfin.lab.example.com
      policy: one_factor
      subject: ['group:media-users', 'group:homelab-admins']
    - domain: pve.lab.example.com
      policy: two_factor
      subject: ['group:homelab-admins']
```

## Jellyfin SSO Integration (jellyfin-plugin-sso)

### Plugin Version Pinning and Installation

We install Jellyfin’s SSO Authentication plugin via direct zip download pinned from the plugin manifest (so `vmctl apply` is deterministic):

- Manifest: `https://raw.githubusercontent.com/9p4/jellyfin-plugin-sso/manifest-release/manifest.json`
- Latest listed version in manifest (as of 2026-03-20): `4.0.0.4`
- Zip URL: `https://github.com/9p4/jellyfin-plugin-sso/releases/download/v4.0.0.4/sso-authentication_4.0.0.4.zip`

Installation mechanism matches the repo’s existing “drop zip into plugins directory + restart” approach used by Streamyfin/Jellio plugins.

### Zero-Manual Plugin Configuration (API-driven)

The plugin provides an HTTP API to create the OIDC provider config by POSTing JSON to:

- `POST https://jellyfin.lab.example.com/sso/OID/Add/authelia?api_key=${JELLYFIN_ADMIN_API_KEY}`

We use `PROVIDER_NAME=authelia`.

The payload includes:

- `oidEndpoint`: Authelia issuer base URL (use `https://auth.lab.example.com`)
- `oidClientId` / `oidSecret`: values matching Authelia OIDC client config
- `roleClaim`: `groups` (Authelia provides groups claim when requested)
- `oidScopes`: includes `openid`, `profile`, `groups` (groups required for role mapping)
- `roles` and `adminRoles`: map to LLDAP group names

This avoids any dashboard clicking.

### “No Local Jellyfin Credentials” Policy

Practical constraints:

- Jellyfin still requires a local admin for server bootstrap and API operations.
- Many non-browser Jellyfin clients do not support OIDC flows reliably.

Policy implemented by this plan:

- Human users:
  - authenticate via Authelia + Jellyfin SSO plugin (OIDC)
  - no per-user Jellyfin passwords are required
- Service accounts (optional):
  - remain allowed for Kodi or other non-OIDC clients, but are not exposed outside the reverse proxy

If you want to enforce “browser-only SSO”, we also configure NGINX to protect `/web/` and `/` strictly, while allowing a narrow set of API endpoints for trusted clients if explicitly enabled (opt-in).

## Proxmox UI Protection

### Proxy-Only Access

We expose Proxmox UI only at:

- `https://pve.lab.example.com` (LAN and Tailnet, via the same canonical hostname)

Both are behind Authelia SSO.

### Block Direct Unauthenticated Access to `mini:8006`

We implement a Proxmox-host firewall rule set:

- allow `:8006` only from:
  - `media-stack` LAN IP (reverse proxy)
  - `127.0.0.1`
- deny from the rest of the LAN and from the tailnet subnet route

This ensures no bypass is possible.

Implementation options:

- Proxmox firewall at datacenter/node level (preferred if already used)
- `nftables` rules on the Proxmox host (managed by a `vmctl`-provisioned “host bootstrap” step via SSH to `mini`)

Because `vmctl` currently provisions guests (not the Proxmox host), this plan adds a dedicated `proxmox_host` feature to run a small idempotent firewall script against the Proxmox API endpoint host.

## vmctl Integration (Config, Packs, Templates, Scripts)

### 1) `vmctl.toml` Feature Flag (Enabled by Default)

`vmctl` currently does not have a top-level `[features]` table; features are under `[defaults.features.*]` and `[resources.features.*]`.

We implement the requested UX:

```toml
[features]
sso = true
```

by extending the config loader to merge root `[features]` into `[defaults.features]` (and allow per-resource overrides), without breaking existing configs.

Effective resolution rules:

- default: `features.sso = true`
- per resource: `[resources.features.sso] enabled = false` disables SSO routing/bootstraps for that resource only

### 2) New SSO Feature Schema

Add a new feature object:

```toml
[defaults.features.sso]
enabled = true

# The resource that runs the ingress/auth stack.
ingress_resource = "media-stack"

# Canonical DNS zone used for every service hostname (LAN and Tailnet).
# This must be a DNS zone you control (example: lab.example.com) with a wildcard record to the ingress LAN IP.
base_domain = "lab.example.com"

[defaults.features.sso.tls]
# ACME DNS-01 is required so certificates work even when hostnames resolve to private RFC1918 addresses.
mode = "acme_dns01_cloudflare"
acme_email = "admin@lab.example.com"
cloudflare_dns_api_token = "${CLOUDFLARE_DNS_API_TOKEN}"

# Service route table (single source of truth).
[[defaults.features.sso.routes]]
name = "jellyfin"
host = "jellyfin.lab.example.com"
upstream = "http://jellyfin:8096"
policy = "one_factor"
websockets = true

[[defaults.features.sso.routes]]
name = "pve"
host = "pve.lab.example.com"
upstream = "https://mini:8006"
policy = "two_factor"
websockets = true
insecure_upstream_tls = true
```

Notes:

- `host` is the canonical hostname used on both LAN and tailnet.
- `policy` maps to Authelia access control policy and required factor.
- `tls.mode = "acme_dns01_cloudflare"` requires `CLOUDFLARE_DNS_API_TOKEN` to be set in the `vmctl.toml` `[env]` section.

### 3) Pack Changes (New Services)

Add service packs:

- `packs/services/ingress-nginx.toml`
- `packs/services/authelia.toml`
- `packs/services/redis.toml`
- `packs/services/lldap.toml`
- `packs/services/lego.toml` (ACME DNS-01 client used to obtain wildcard certificates)

Update `packs/roles/media_stack.toml` default services:

- include the new auth/proxy stack when `features.sso.enabled` is true
- keep existing media services list unchanged

### 4) Template Changes

Add templates:

- `packs/templates/nginx.conf.sso.hbs`
  - generates server blocks for every `features.sso.routes` item
  - enforces auth_request to Authelia on every service by default
  - handles websockets and upstream TLS exceptions (Proxmox)
- `packs/templates/authelia.configuration.yml.hbs`
  - Authelia config with:
    - LDAP backend pointing to LLDAP
    - Redis sessions
    - OIDC provider and Jellyfin client
    - access_control rules derived from `features.sso.routes`
- `packs/templates/lldap.env.hbs` / `packs/templates/authelia.env.hbs`
  - secrets are generated once and preserved (see scripts)
- `packs/templates/lego.env.hbs`
  - ACME DNS-01 settings (Cloudflare token) for wildcard certificates
- `packs/templates/sso-routes.json.hbs`
  - machine-readable copy of `features.sso.routes` consumed by bootstrap scripts (no duplicated logic in bash)

Update existing templates:

- `packs/templates/docker-compose.media.hbs`:
  - add the new containers
  - mount generated configs under `/opt/media/config/*`
  - when SSO is enabled:
    - do not publish UI ports for backend services (only publish the ingress ports 80/443)
    - keep non-UI ports required for functionality (e.g. torrent ports) published as needed

### 5) Provisioning Scripts (Idempotent)

Add scripts (executed on `media-stack` during apply):

- `packs/scripts/bootstrap-sso.sh`
  - render/install configs
  - generate and persist secrets in `/opt/media/.env` (using the existing `ensure_env_value` pattern)
  - obtain/renew a wildcard TLS certificate for `*.lab.example.com` via ACME DNS-01 (Cloudflare) and install into the NGINX mount
  - start/restart containers as needed
  - run an internal HTTP test suite (curl-based) to enforce redirect behavior

ACME implementation detail (deterministic, apply-driven):

```bash
# Runs on media-stack during apply. Certificates are written to a persistent host directory mounted into NGINX.
docker run --rm \
  -e CLOUDFLARE_DNS_API_TOKEN="${CLOUDFLARE_DNS_API_TOKEN}" \
  -v /opt/media/config/sso/lego:/lego \
  goacme/lego:v4.34.0 \
  --accept-tos \
  --email "admin@lab.example.com" \
  --dns cloudflare \
  --domains "lab.example.com" \
  --domains "*.lab.example.com" \
  --path /lego \
  run

# After successful issuance/renewal:
# - copy /opt/media/config/sso/lego/certificates/*.key/*.crt into /opt/media/config/sso/certs/wildcard/{privkey.pem,fullchain.pem}
# - reload nginx (SIGHUP) or restart container if first install
```
- `packs/scripts/bootstrap-sso-jellyfin.sh`
  - install `jellyfin-plugin-sso` zip pinned from manifest
  - configure provider via plugin API (`/sso/OID/Add/authelia`)
  - verify that `/sso/OID/start/authelia` responds and completes auth in browser flows
No local DNS service is required in canonical-domain mode: normal DNS resolution (public resolvers) works on both LAN and tailnet, and connectivity from tailnet to the private ingress IP is provided by the subnet router.

Add scripts (executed against Proxmox host `mini`):

- `packs/scripts/bootstrap-proxmox-firewall-sso.sh`
  - apply idempotent firewall rules to restrict `:8006` to ingress IP

### 6) DRY: One Route Table Drives Everything

The single table `features.sso.routes` must drive:

- NGINX vhosts (routing + auth enforcement)
- Authelia access control (rules and per-service policy)
- test suite (redirect + authenticated success)
- index/home UI if you keep it

No hard-coded hostnames inside scripts.

## Concrete Configuration Examples

### `vmctl.toml` Example (Minimal)

```toml
[features]
sso = true

[resources.features.media_services]
enabled = true
services = ["jellyfin", "sonarr", "radarr", "prowlarr", "bazarr", "qbittorrent-vpn", "jellyseerr", "jellysearch"]

[resources.features.sso]
enabled = true
ingress_resource = "media-stack"

# Canonical DNS zone for all service hostnames (LAN and Tailnet).
base_domain = "lab.example.com"

[resources.features.sso.tls]
mode = "acme_dns01_cloudflare"
acme_email = "admin@lab.example.com"
cloudflare_dns_api_token = "${CLOUDFLARE_DNS_API_TOKEN}"

[[resources.features.sso.routes]]
name = "auth"
host = "auth.lab.example.com"
upstream = "http://authelia:9091"
policy = "bypass"

[[resources.features.sso.routes]]
name = "jellyfin"
host = "jellyfin.lab.example.com"
upstream = "http://jellyfin:8096"
policy = "one_factor"
websockets = true

[[resources.features.sso.routes]]
name = "sonarr"
host = "sonarr.lab.example.com"
upstream = "http://sonarr:8989"
policy = "one_factor"

[[resources.features.sso.routes]]
name = "radarr"
host = "radarr.lab.example.com"
upstream = "http://radarr:7878"
policy = "one_factor"

[[resources.features.sso.routes]]
name = "prowlarr"
host = "prowlarr.lab.example.com"
upstream = "http://prowlarr:9696"
policy = "one_factor"

[[resources.features.sso.routes]]
name = "bazarr"
host = "bazarr.lab.example.com"
upstream = "http://bazarr:6767"
policy = "one_factor"

[[resources.features.sso.routes]]
name = "qbittorrent"
host = "qbittorrent.lab.example.com"
upstream = "http://qbittorrent-vpn:8080"
policy = "one_factor"
websockets = true

[[resources.features.sso.routes]]
name = "jellyseerr"
host = "jellyseerr.lab.example.com"
upstream = "http://jellyseerr:5055"
policy = "one_factor"

[[resources.features.sso.routes]]
name = "jellysearch"
host = "jellysearch.lab.example.com"
upstream = "http://jellysearch:5000"
policy = "one_factor"

[[resources.features.sso.routes]]
name = "lldap"
host = "lldap.lab.example.com"
upstream = "http://lldap:17170"
policy = "two_factor"

[[resources.features.sso.routes]]
name = "pve"
host = "pve.lab.example.com"
upstream = "https://mini:8006"
policy = "two_factor"
websockets = true
insecure_upstream_tls = true
```

### Authelia OIDC Client for Jellyfin (Generated)

Based on Authelia’s Jellyfin integration guide.

The client secret is generated once as plaintext (stored in `/opt/media/.env`) and hashed into a PBKDF2 digest for Authelia.

Concrete hashing step during bootstrap:

```bash
# Run Authelia's builtin crypto helper inside the container image to produce the digest Authelia expects.
JELLYFIN_OIDC_SECRET="$(python3 -c 'import secrets; print(secrets.token_urlsafe(48))')"
JELLYFIN_OIDC_DIGEST="$(docker run --rm authelia/authelia:4.39.19 authelia crypto hash generate pbkdf2 --variant sha512 --iterations 310000 --password "${JELLYFIN_OIDC_SECRET}" | awk -F': ' '/Digest:/{print $2}')"
```

```yaml
identity_providers:
  oidc:
    clients:
      - client_id: 'jellyfin'
        client_name: 'Jellyfin'
        client_secret: '{{ secret "/config/secrets/oidc.clients.jellyfin.pbkdf2" }}'
        public: false
        authorization_policy: 'two_factor'
        require_pkce: true
        pkce_challenge_method: 'S256'
        redirect_uris:
          - 'https://jellyfin.lab.example.com/sso/OID/redirect/authelia'
        scopes:
          - 'openid'
          - 'profile'
          - 'groups'
        response_types:
          - 'code'
        grant_types:
          - 'authorization_code'
        access_token_signed_response_alg: 'none'
```

### Jellyfin Plugin Provider Config (API Payload)

Based on the plugin’s documented `Add` endpoint.

```json
{
  "oidEndpoint": "https://auth.lab.example.com",
  "oidClientId": "jellyfin",
  "oidSecret": "${JELLYFIN_OIDC_SECRET}",
  "enabled": true,
  "enableAuthorization": true,
  "enableAllFolders": true,
  "enabledFolders": [],
  "adminRoles": ["homelab-admins"],
  "roles": ["media-users", "homelab-admins"],
  "enableFolderRoles": false,
  "folderRoleMapping": [],
  "roleClaim": "groups",
  "oidScopes": ["openid", "profile", "groups"]
}
```

## Task Breakdown (Implementation Steps)

### Phase 1: vmctl Schema + Pack Plumbing

1. Extend `crates/config` to support root `[features]` table merged into `[defaults.features]` (preserve existing behavior).
2. Extend `crates/packs` to parse/validate `features.sso` and expose it to templates/scripts.
3. Add the new service packs and templates listed above.
4. Update `packs/roles/media_stack.toml` to include new bootstrap scripts:
   - `bootstrap-sso.sh`
   - `bootstrap-sso-jellyfin.sh`
   - `bootstrap-local-dns.sh`
5. Update `vmctl.example.toml` to show SSO enabled by default and the route table.

### Phase 2: Ingress Stack Implementation (media-stack)

1. Add `ingress-nginx`, `authelia`, `redis`, `lldap` services to the media compose.
2. Generate configs to `/opt/media/config/sso/*` via templates.
3. Generate/persist secrets in `/opt/media/.env`:
   - Authelia: session secret, storage encryption key, JWT secret (if used)
   - LLDAP: admin password, JWT secret
   - OIDC: Jellyfin client secret (plaintext stored in env), and PBKDF2 digest rendered into Authelia config
4. LAN TLS:
   - obtain/renew an ACME wildcard cert for `*.lab.example.com` via DNS-01 (Cloudflare)
   - mount into NGINX and enable 443 listener
5. Disable per-node HTTP exposure features that could bypass ingress:
   - if any guest currently runs `tailscale serve` for its own UI, reset it during provisioning so the only supported ingress is `https://*.lab.example.com` via the centralized proxy
   - program per-host mappings on `media-stack` for every route

### Phase 3: Secure Proxmox UI

1. Add route `pve.lab.example.com` -> `https://mini:8006` behind Authelia.
2. Add a new provisioning step to apply firewall rules on `mini`:
   - restrict inbound to `:8006` from the ingress IP only.

### Phase 4: Jellyfin SSO (OIDC)

1. Install the SSO Authentication plugin zip pinned from the upstream manifest.
2. Configure provider `authelia` via plugin API.
3. Ensure the login URL works:
   - `https://jellyfin.lab.example.com/sso/OID/start/authelia`
4. Ensure Authelia OIDC client redirect URIs include the Jellyfin callback path `/sso/OID/redirect/authelia`.

### Phase 5: Secure Every Other Service

For each routed service:

1. Remove direct LAN port exposure (compose publish) unless required for non-UI functionality.
2. Ensure the only ingress is the centralized reverse proxy on `media-stack` (NGINX :80/:443).
3. Enforce Authelia in NGINX `location /` using `auth_request`.
4. Apply least-privilege Authelia rule:
   - `one_factor` for most
   - `two_factor` for `pve` and `lldap`

## TDD / Verification (Automated)

We add a `vmctl`-run test harness executed at the end of `bootstrap-sso.sh` (and separately runnable) that validates for every route:

1. Unauthenticated request redirects to Authelia portal:
   - `curl -sS -I https://sonarr.lab.example.com | grep -E 'HTTP/.* 302|Location:.*auth'`
2. Authenticated request succeeds:
   - use Authelia login once (headless Playwright) to obtain session cookie
   - re-run curls with cookie jar and assert `200`/`30x` to app (not to portal)
3. Session persistence:
   - wait N seconds, repeat request, still authorized
4. Logout invalidates:
   - call Authelia logout endpoint (browser-driven)
   - subsequent request returns redirect again

NGINX-specific redirect behavior must match Authelia’s auth_request integration semantics.

## Definition of Done

The system is complete when:

- Every service hostname in `features.sso.routes` returns:
  - unauthenticated: redirect to Authelia portal
  - authenticated: service content loads (including websockets where applicable)
- No direct unauthenticated access exists:
  - Docker UI ports not exposed on LAN
  - Proxmox `:8006` reachable only from the ingress VM
- Jellyfin:
  - users can sign in via Authelia OIDC using `jellyfin-plugin-sso`
  - no per-user local Jellyfin credentials are required for human users
- Authelia portal is reachable on both LAN and tailnet hostnames
- LLDAP UI is reachable and protected
- Works from:
  - tailnet devices
  - LAN devices
- `vmctl apply` is idempotent:
  - reruns do not create duplicate DNS/serve rules
  - secrets are preserved once generated
  - config drift is repaired automatically
