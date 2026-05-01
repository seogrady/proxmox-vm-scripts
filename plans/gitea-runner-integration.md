# Gitea Runner Integration Plan (vmctl + Gitea LXC)

## Executive Summary

Integrate **Gitea Actions runner** into the existing `vmctl`-provisioned Gitea environment by adding a dedicated **runner LXC** resource that is provisioned via `vmctl apply`, automatically registers itself to the Gitea instance, persists its configuration safely, and executes CI/CD workflows for repositories (starting with the `vmctl` repo).

Key properties:

- Fully automated: runner installation, registration, and service enablement are handled by `vmctl apply` (no manual steps).
- Idempotent + restart-safe: re-running `vmctl apply` does not create duplicate runners, and service restarts do not break registration.
- Secure-by-default execution model: jobs run in Docker containers; the runner does not need SSH access to the Proxmox host.
- Future-proof multi-instance: design supports multiple Gitea instances later without shims.

---

## Architecture Decision

### Chosen Hosting Model: **Dedicated Runner LXC (separate from Gitea)**

We will run the runner in its own LXC (e.g. `gitea-runner`) and register it to the Gitea instance (e.g. `gitea`). The runner will execute workflows using the **Docker job execution mode**.

**Why this is best in our stack**

- Isolation: runner executes untrusted repo code; separating it from Gitea reduces blast radius (filesystem, secrets, process space).
- Operational clarity: upgrades/restarts of runner do not affect Gitea uptime.
- Security: runner can be restricted to only the network access it needs; it avoids sharing the Gitea container’s data and tokens.
- Future-proof multi-instance: multiple `act_runner` daemons (per instance) can coexist on the runner host via systemd template units.

### Alternatives Considered

1. **Runner inside the Gitea LXC**
   - Pros: simplest token sharing and networking.
   - Cons: weakest isolation (runner compromise likely compromises Gitea).
   - Decision: reject.

2. **Runner directly on the Proxmox host**
   - Pros: easiest access to Proxmox tooling and host state.
   - Cons: too much privilege; job execution becomes host compromise risk.
   - Decision: reject (only consider later with stronger isolation / attestation).

3. **Dedicated VM**
   - Pros: strong isolation relative to LXC.
   - Cons: higher resource overhead and slower iteration in homelab context.
   - Decision: defer (could be an opt-in profile later).

---

## High-Level Architecture

### Components

- **`resources/gitea` (existing)**: Gitea LXC resource pack.
- **`resources/gitea-runner` (new)**: Runner LXC resource pack.
- **`services/gitea-runner` (new)**: Service pack describing runner dependencies and runtime characteristics.

### Provisioning Flow (vmctl apply)

1. `vmctl apply` provisions/repairs the `gitea` LXC and runs its `bootstrap-*` scripts.
2. `vmctl apply` provisions/repairs the `gitea-runner` LXC and runs its `bootstrap-*` scripts:
   - installs Docker engine (host-side)
   - installs `act_runner` binary
   - generates `/etc/act_runner/config.yaml`
   - requests a *scoped* registration token from Gitea via API (recommended: repo-level for `vmctl`)
   - registers the runner (creates `.runner` in runner state dir)
   - starts/enables systemd service
3. Validation hooks confirm:
   - runner is online and visible in Gitea UI
   - a workflow can be executed from push events

---

## Configuration & DRY Design

### Goals

- Avoid duplicating Gitea connection data (URL, admin credentials) across packs.
- Avoid hardcoding any secrets into repo files.
- Keep config extendable for multiple Gitea instances later.

### Proposed Global `[env]` Keys (workspace-level, referenced by packs)

Add these to `vmctl.toml` `[env]` (or equivalent workspace config):

```toml
[env]
# Existing
PROXMOX_TOKEN_ID = "${PROXMOX_TOKEN_ID}"
PROXMOX_TOKEN_SECRET = "${PROXMOX_TOKEN_SECRET}"
TAILSCALE_AUTH_KEY = "${TAILSCALE_AUTH_KEY}"
DEFAULT_SSH_KEY_FILE = "${DEFAULT_SSH_KEY_FILE}"
DEFAULT_SSH_PRIVATE_KEY_FILE = "${DEFAULT_SSH_PRIVATE_KEY_FILE}"

# New (shared between Gitea and Runner packs)
GITEA_BASE_URL = "${GITEA_BASE_URL}"                 # e.g. https://gitea.tailnet-xyz.ts.net/
GITEA_ADMIN_USER = "${GITEA_ADMIN_USER}"             # e.g. admin
GITEA_ADMIN_PASSWORD = "${GITEA_ADMIN_PASSWORD}"     # secret
GITEA_ACTIONS_RUNNER_SCOPE = "repo"                  # repo|org|instance (initially repo)
GITEA_ACTIONS_RUNNER_REPO = "admin/vmctl"            # only required for repo scope
GITEA_ACTIONS_RUNNER_NAME = "vmctl-runner-1"
GITEA_ACTIONS_RUNNER_LABELS = "vmctl:docker://rust:1.78-bookworm"
```

Then update `resources/gitea/resource.toml` and the new runner resource to reference these keys via `${env.*}` so the data is specified once.

### Runner Multi-Instance Future-Proofing

Design `features.gitea_runner.instances` as an *array* even if we only configure one entry initially:

```toml
[features.gitea_runner]
enabled = true

[[features.gitea_runner.instances]]
name = "gitea"
base_url = "${env.GITEA_BASE_URL}"
admin_user = "${env.GITEA_ADMIN_USER}"
admin_password = "${env.GITEA_ADMIN_PASSWORD}"
scope = "${env.GITEA_ACTIONS_RUNNER_SCOPE}"     # repo|org|instance
repo = "${env.GITEA_ACTIONS_RUNNER_REPO}"       # for repo scope
runner_name = "${env.GITEA_ACTIONS_RUNNER_NAME}"
runner_labels = "${env.GITEA_ACTIONS_RUNNER_LABELS}"
```

Implementation detail:

- One systemd unit per instance: `act_runner@gitea.service`
- One state dir per instance: `/var/lib/act_runner/gitea/`
- One config per instance: `/etc/act_runner/gitea.yaml`

---

## Secure Integration With Gitea

### Registration Token Strategy (No Manual Steps)

The runner **must** register using a registration token, but we will *obtain* the token automatically during provisioning.

Recommended approach (initial, single deployment):

- Runner bootstrap script calls the Gitea API to create a **short-lived registration token** for the chosen scope.
- Then `act_runner register --no-interactive ...` is executed.
- The resulting `.runner` file is persisted and locked down.

#### Token Scope Choice

- **Repo-level** token for `admin/vmctl` is the safest initial target: the runner only serves the `vmctl` repo.
- Keep **instance-level** as an option for later (shared runners for multiple repos).

#### API Endpoints (by scope)

- Repo scope: `POST /api/v1/repos/{owner}/{repo}/actions/runners/registration-token`
- Org scope: `POST /api/v1/orgs/{org}/actions/runners/registration-token`
- Instance scope: `POST /api/v1/admin/actions/runners/registration-token`

Authentication:

- Prefer a dedicated **admin API token** (or “automation” user token) if we add token bootstrap later.
- Accept **basic auth** (admin user/password) initially since that is already used by the existing `validate-gitea.sh`.

### Secret Storage Rules

- Never commit any runner tokens or admin passwords.
- Runner host:
  - store `.runner` and `config.yaml` under root-owned or `act_runner`-owned directories with `0600`/`0700`.
  - do not log registration tokens (ensure `set +x` around sensitive steps).
- Gitea Actions secrets:
  - store Proxmox tokens and SSH keys as repository secrets; only injected into trusted workflows (push to `main`).

---

## Runner Execution Model (Host Access & Safety)

### Core Design: **No SSH into Proxmox host**

`vmctl apply` does not need to run “on the Proxmox host” if:

- the workflow job can reach the Proxmox API endpoint configured in `vmctl.toml`
- it has `PROXMOX_TOKEN_ID` and `PROXMOX_TOKEN_SECRET`
- it has the SSH private key used to provision guests

Therefore:

- runner LXC provides compute + Docker isolation
- job container runs `cargo run -q -p vmctl -- apply` and drives Proxmox remotely via API and SSH

This avoids:

- mounting host paths into the runner container
- giving the runner SSH access to the Proxmox host
- turning CI into “remote root shell on hypervisor”

### Credentials Passing (Workflow -> vmctl)

Workflow will assemble required files/vars at runtime:

- `PROXMOX_TOKEN_ID`, `PROXMOX_TOKEN_SECRET` (secrets)
- `TF_VAR_proxmox_api_token="${PROXMOX_TOKEN_ID}=${PROXMOX_TOKEN_SECRET}"` (derived)
- `DEFAULT_SSH_PRIVATE_KEY_FILE`, `DEFAULT_SSH_KEY_FILE` as **paths**
- the key material itself from secrets written to those paths

### Mitigations & Guardrails

- Restrict the apply workflow to `push` to `main` only (no PR secrets).
- Add `concurrency` to prevent parallel applies.
- Run job containers without Docker socket access:
  - set `container.docker_host: "-"` in runner config (runner still uses Docker, but job containers do not get the Docker host mounted).
- Keep `container.privileged: false` (no DinD).
- Consider adding a Proxmox role/token with minimal permissions for `vmctl`.

---

## Networking & Tailscale

### Required Connectivity

Runner host and job containers must be able to:

- reach `GITEA_BASE_URL` (Gitea API + git HTTP/SSH endpoints as needed)
- reach the Proxmox API endpoint configured in `vmctl.toml`
- reach provisioned guests via SSH (as vmctl executes guest bootstrap scripts)

### Recommended Network Setup

- Put the runner LXC on the same L2/L3 network as Proxmox + guests (bridge `vmbr0`) and also join Tailscale (optional but recommended).
- Use a stable `GITEA_BASE_URL` that is reachable from runner job containers:
  - If Gitea is served via Tailscale HTTPS, use that URL consistently.
  - Ensure DNS resolution works inside Docker job containers; if MagicDNS is in use and Docker DNS causes issues, set runner `container.options` to include an explicit DNS server.

---

## Provisioning Design (vmctl Packs)

### 1. New Service Pack: `services/gitea-runner`

Create `services/gitea-runner/service.toml` with:

- `scope = "resource"`
- `targets = ["lxc", "vm"]`
- runtime requirements:
  - `container-engine`
  - `git`
  - `curl`
  - `systemd`

This keeps the runner logic in resources/scripts but lets vmctl dependency checking understand what’s needed.

### 2. New Resource Pack: `resources/gitea-runner`

Create `resources/gitea-runner/resource.toml` modelled after `resources/gitea`:

- `kind = "lxc"`
- `image = "debian_12_lxc"`
- `features.lxc.nesting = true` (Docker in LXC needs nesting)
- optional `features.tailscale` similar to `resources/gitea`
- `features.gitea_runner.enabled = true`
- `features.gitea_runner.instances = [...]`
- `features.gitea_runner_bundle.services = ["gitea-runner"]`
- `render.templates`:
  - `gitea-runner.env.hbs`
  - `act-runner.config.yaml.hbs` (or a script-generated config)
- `hooks.bootstrap`:
  - `scripts/bootstrap-node.sh` (if required by your base convention)
  - `scripts/bootstrap-tailscale.sh` (optional)
  - `scripts/bootstrap-gitea-runner.sh`
- `hooks.validate`:
  - `scripts/validate-gitea-runner.sh`

### 3. Runner Bootstrap Script (Outline)

File: `resources/gitea-runner/scripts/bootstrap-gitea-runner.sh`

Responsibilities:

1. Install OS deps: `ca-certificates curl git jq openssh-client python3`
2. Install Docker CE + enable service (reuse `resources/media-stack` install approach).
3. Create `act_runner` user:
   - home: `/var/lib/act_runner`
   - add to `docker` group
4. Install `act_runner` binary:
   - fetch from release URL (pin version; checksum verify)
5. Write config(s):
   - `/etc/act_runner/<instance>.yaml`
   - key settings:
     - `runner.file: /var/lib/act_runner/<instance>/.runner`
     - `runner.capacity: 1` (initially; revisit if you want parallel builds)
     - `runner.labels: ["vmctl:docker://rust:1.78-bookworm"]`
     - `container.privileged: false`
     - `container.valid_volumes: []`
     - `container.docker_host: "-"` (prevent docker host/socket exposure to job containers)
6. Registration:
   - If `.runner` exists and looks valid: skip register (idempotent).
   - Else:
     - wait for `GET ${GITEA_BASE_URL}/api/v1/version`
     - request scope token (repo-level recommended)
     - `act_runner register --no-interactive --config /etc/act_runner/<instance>.yaml --instance "$GITEA_BASE_URL" --token "$REG_TOKEN" --name "$RUNNER_NAME" --labels "$LABELS"`
7. Systemd:
   - Install a templated service unit `act_runner@.service` or per-instance unit file.
   - Enable and start.

### 4. Runner Validation Script (Outline)

File: `resources/gitea-runner/scripts/validate-gitea-runner.sh`

Checks:

- systemd: `systemctl is-active act_runner@<instance>`
- local state: `.runner` exists, owned by `act_runner`, permissions `0600`
- Gitea API:
  - list runners for repo (or instance) and assert this runner name is present and `online`

---

## Gitea Side Changes (Minimal + Required)

### Enable Actions in Gitea Config

Ensure `app.ini` includes an `[actions]` section enabling Actions (and any required defaults for your version). This should be managed by `resources/gitea/scripts/bootstrap-gitea.sh` so it is idempotent.

### Ensure `vmctl` Repository Exists (Recommended)

For repo-scoped runner registration, the repo must exist.

Add an **optional** bootstrap step on the Gitea resource:

- Create repo `admin/vmctl` if missing (empty repo is fine).
- Alternatively, document that the repo must exist before runner bootstrap completes.

Prefer the “create if missing” path to achieve truly zero manual steps.

---

## CI/CD: vmctl GitOps Workflow

### Design Principles

- Deployment workflow runs only on trusted branch events.
- No secrets available to PR workflows.
- Concurrency prevents overlapping applies.

### Zero-Manual Repo Bootstrapping (Recommended)

To meet the “no manual configuration” requirement end-to-end (runner + repo + secrets), add a **vmctl-driven bootstrap step** that ensures the `admin/vmctl` repository exists and its Actions secrets are in place.

Reasoning:

- The runner can be provisioned automatically by vmctl.
- The workflow files live in the Git repo, but the **required secrets** typically require UI/API configuration.
- vmctl already runs with the required sensitive values in its environment (Proxmox token, Tailscale key, SSH key paths), so it is the natural automation point.

Proposed implementation approach:

- Add a small “local hook” execution capability to `vmctl apply` (or a dedicated `vmctl bootstrap gitea-actions` command).
- The hook runs on the same machine that invoked `vmctl apply` and:
  - calls the Gitea API (authenticated as admin) to:
    - create `admin/vmctl` repo if missing
    - set required Actions secrets for the repo idempotently

API write operations needed:

- Create repo (if missing): `POST /api/v1/admin/users/{username}/repos` or `POST /api/v1/user/repos` (depending on auth mode)
- Upsert secret: `PUT /api/v1/repos/{owner}/{repo}/actions/secrets/{secretname}` (base64-encoded payload)

If adding a local hook system is considered too large for the first iteration:

- Accept a one-time manual action to set repo secrets via UI, but keep the hook design in-scope for the next hardening pass.

### Gitea Actions Secrets Required (Repository: `admin/vmctl`)

- `PROXMOX_TOKEN_ID`
- `PROXMOX_TOKEN_SECRET`
- `TAILSCALE_AUTH_KEY` (if required by your resource packs)
- `DEFAULT_SSH_PRIVATE_KEY` (private key material, not a path)
- `DEFAULT_SSH_PUBLIC_KEY` (public key material)

Optional:

- `VMCTL_CONFIG_PATH` (if you choose to use a dedicated CI config file)

### Workflow 1: PR Checks (No Secrets)

Path: `.gitea/workflows/ci.yaml`

```yaml
name: CI

on:
  pull_request:
    branches: [ main ]

jobs:
  test:
    runs-on: vmctl
    steps:
      - name: Checkout
        uses: actions/checkout@v4

      - name: Rust tests
        run: |
          cargo test --locked
```

### Workflow 2: Apply on Main Push (GitOps-style)

Path: `.gitea/workflows/apply.yaml`

```yaml
name: Apply (vmctl)

on:
  push:
    branches: [ main ]

concurrency:
  group: vmctl-apply-main
  cancel-in-progress: false

jobs:
  apply:
    runs-on: vmctl
    steps:
      - name: Checkout
        uses: actions/checkout@v4

      - name: Install tooling deps
        run: |
          apt-get update
          apt-get install -y --no-install-recommends \
            ca-certificates curl git jq openssh-client unzip

      - name: Install OpenTofu
        run: |
          # Example: pin a specific version and verify checksums in the real implementation.
          TOFU_VERSION="1.7.3"
          curl -fsSL "https://github.com/opentofu/opentofu/releases/download/v${TOFU_VERSION}/tofu_${TOFU_VERSION}_linux_amd64.tar.gz" -o /tmp/tofu.tgz
          tar -C /usr/local/bin -xzf /tmp/tofu.tgz tofu
          tofu version

      - name: Prepare SSH key files
        env:
          DEFAULT_SSH_PRIVATE_KEY: ${{ secrets.DEFAULT_SSH_PRIVATE_KEY }}
          DEFAULT_SSH_PUBLIC_KEY: ${{ secrets.DEFAULT_SSH_PUBLIC_KEY }}
        run: |
          install -d -m 0700 /root/.ssh
          printf '%s\n' "$DEFAULT_SSH_PRIVATE_KEY" > /root/.ssh/id_ed25519
          printf '%s\n' "$DEFAULT_SSH_PUBLIC_KEY" > /root/.ssh/id_ed25519.pub
          chmod 0600 /root/.ssh/id_ed25519

      - name: Apply
        env:
          PROXMOX_TOKEN_ID: ${{ secrets.PROXMOX_TOKEN_ID }}
          PROXMOX_TOKEN_SECRET: ${{ secrets.PROXMOX_TOKEN_SECRET }}
          TAILSCALE_AUTH_KEY: ${{ secrets.TAILSCALE_AUTH_KEY }}
          DEFAULT_SSH_KEY_FILE: /root/.ssh/id_ed25519.pub
          DEFAULT_SSH_PRIVATE_KEY_FILE: /root/.ssh/id_ed25519
          TF_VAR_proxmox_api_token: ${{ secrets.PROXMOX_TOKEN_ID }}=${{ secrets.PROXMOX_TOKEN_SECRET }}
        run: |
          cargo run -q -p vmctl -- apply

      - name: Upload debug artifacts (on failure)
        if: failure()
        uses: actions/upload-artifact@v4
        with:
          name: vmctl-debug
          path: |
            vmctl.lock
            backend/generated/workspace
```

### Failure Handling

- If `vmctl apply` fails:
  - workflow fails (red)
  - artifacts are uploaded for debugging (workspace + lockfile)
- Follow-up hardening (optional):
  - automatically create an issue or send a notification (email/webhook) on failures.

---

## TDD / Validation Strategy

### 1. Unit / Pack-Level Checks

Add tests that validate rendered artifacts contain expected runner content.

Targets:

- `crates/backend-terraform/src/lib.rs` tests that currently assert expected script/template content:
  - ensure `resources/gitea-runner/resource.toml` is included and defaults are sane
  - ensure runner scripts include:
    - Docker install
    - `act_runner register --no-interactive`
    - systemd enable/start
    - `.runner` existence checks (idempotency)
  - ensure secrets are not embedded into rendered artifacts:
    - no `${env.GITEA_ADMIN_PASSWORD}` literal in outputs
    - no Proxmox secrets in generated TF JSON (already a goal of vmctl)

### 2. Provision Validation Hooks

Add `validate-gitea-runner.sh` that fails fast on:

- runner offline or systemd inactive
- `.runner` missing
- Gitea API cannot see runner as `online`

### 3. End-to-End (Live) Acceptance

Manual once, then automate:

1. `vmctl apply` provisions Gitea and runner.
2. In Gitea UI: runner is visible as online.
3. Push commit to `main` for `admin/vmctl`:
   - workflow triggers
   - job checks out repo and runs `cargo run -q -p vmctl -- apply`
4. Confirm infra changes (or “no changes”) and successful run.

### 4. Negative / Failing Scenarios (Must be Covered)

- Gitea unreachable:
  - runner bootstrap should retry and then fail clearly.
- Wrong Gitea admin credentials:
  - runner bootstrap fails when requesting registration token.
- Repo missing (repo scope):
  - runner bootstrap either creates repo or fails with a clear error.
- Runner already registered but config changed:
  - runner restarts and applies new labels/capacity without re-registering.
- Docker unavailable:
  - runner bootstrap fails; validate hook catches it.
- Proxmox endpoint DNS fails inside job containers:
  - adjust runner `container.options` to set DNS; add regression test documenting the requirement.

---

## Security Considerations (Explicit)

- The runner host is a high-trust system. Treat it as “automation control plane,” not a generic shared build machine.
- Repo `apply` workflow must be restricted to trusted events (push to `main`).
- Use repo-scoped runner + labels to prevent accidental use by other repos.
- Keep job containers away from Docker socket:
  - `container.docker_host: "-"` in runner config
  - do not allow workflow-defined volume mounts (`container.valid_volumes: []`)
- Prefer least-privilege Proxmox tokens.
- Consider rotating runner registration token regularly (API-driven) if instance-scoped.

---

## Task Breakdown (Implementation Order)

1. Packs and config wiring
   1. Create `services/gitea-runner/service.toml`
   2. Create `resources/gitea-runner/resource.toml` + templates + scripts
   3. Add runner resource to workspace (`vmctl.toml`) in the target deployment
2. Runner provisioning scripts
   1. Docker install (reuse proven approach from media stack)
   2. `act_runner` install + checksum pinning
   3. config generation + permission hardening
   4. token request + `register` + systemd service
3. Gitea updates
   1. Ensure Actions enabled in `app.ini`
   2. Ensure `admin/vmctl` repo exists (or document prerequisite)
4. Workflows
   1. Add `.gitea/workflows/ci.yaml`
   2. Add `.gitea/workflows/apply.yaml`
   3. Document required secrets in repo settings
5. Tests and validation
   1. Add/extend backend render tests for runner assets
   2. Add validate hook for runner
   3. Run live acceptance sequence

---

## Definition of Done

After `vmctl apply`:

- Runner is installed and running (`systemd active`).
- Runner is registered and visible in Gitea UI as `online`.
- Runner configuration persists and survives restarts / re-applies.

After pushing to `main` in the `vmctl` repo:

- Workflow triggers automatically.
- Workflow runs `cargo run -q -p vmctl -- apply` successfully.
- Runner can reach Proxmox API and provision/update infra as defined.

No manual configuration is required beyond:

- setting required secrets in Gitea repository settings (Proxmox token + SSH keys)
- setting shared env keys for `vmctl apply` execution context (same as today)
