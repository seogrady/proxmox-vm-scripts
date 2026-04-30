# vmctl Remote Modules Architecture
## Fully Composable Module System (Local + Git + Inline) for Resources and Services

This document is a design and implementation plan only. It intentionally does not implement code.

It evolves `vmctl` into a **fully composable module system** spanning:
- Local filesystem module collections
- Remote Git module collections (HTTPS + SSH)
- Inline module definitions and overrides in `vmctl.toml`

Key properties:
- Discovery is file-based (`resource.toml`, `service.toml`).
- `vmctl.toml` does not need to encode “what is a resource vs service” for **discovery**; the filesystem tells us.
- Composition hierarchy is `vmctl → resources → services`.
- All layers support `local`, `git`, and `inline`, with deterministic overrides.
- Remote Git repositories are treated as **module collections**: fetched once per `(repo, ref)` and indexed once; multiple modules are then addressable without refetching.

Repository rule alignment (`AGENTS.md`):
- For service provisioning, `resources/*` and `services/*` remain the default local module collections.
- This plan does **not** add legacy compatibility paths; it updates the active loading pipeline to go through the new module system.

---

## 1. Glossary

- **Module**: A directory that contains either `resource.toml` or `service.toml` (or both, though this plan recommends “one kind per module”).
- **Module collection**: A root directory (local path or git checkout root) containing many modules in subdirectories.
- **Module source**: Where a module collection or module comes from (`local://…`, `git::…`, `inline`).
- **Module index**: `(module_kind, module_name) -> ModuleLocation` plus metadata needed for loading and merging.
- **Resolved repo**: `(repo_url, ref) -> checkout_path + resolved_commit`.

---

## 2. Goals and Non-Goals

### Goals
1. Load modules from:
   - Local filesystem paths
   - Remote Git repositories over HTTPS + SSH
   - Inline definitions in `vmctl.toml`
2. Support hybrid composition:
   - Local modules extend/override remote modules
   - Inline overrides remote and local deterministically
3. Allow resources to include and configure services (and reusable service stacks).
4. Efficiently handle remote repositories containing multiple modules:
   - Fetch once per `(repo, ref)`
   - Index once per checkout
   - Reference multiple modules without duplicate downloads
5. Integrate cleanly with:
   - Current planner/orchestrator/service DAG approach
   - Existing lockfile concept for reproducibility and offline reuse

### Non-Goals (explicit)
- A general-purpose package manager (no semantic “install” outside git checkouts + indexing).
- Untrusted sandbox execution. Remote modules are code and must be treated as trusted inputs unless allowlisted.

---

## 3. Target User Experience

### 3.1 Module Collection Paths (Local)
```toml
[paths]
modules = [
  "./resources",
  "./services",
  "./modules",
]
```

Interpretation:
- Each entry is a local module collection root.
- Discovery is recursive: any subdirectory containing `resource.toml` and/or `service.toml` becomes a module.
- Default `paths.modules` (if omitted) is `["./resources", "./services"]`.

### 3.2 Resource Includes Services (Mixed Sources)
```toml
[resources.media_stack]
source = "local://resources/media-stack" # optional; if omitted it can be discovered by name

[resources.media_stack.services.jellyfin]
source = "local://services/jellyfin"

[resources.media_stack.services.radarr]
source = "git::https://github.com/example/vmctl-modules//radarr?ref=v1"
```

### 3.3 vmctl Overrides Resource Services
```toml
[resources.media_stack.services.jellyfin.config]
http_port = 8097

[resources.media_stack.services.radarr]
enabled = false
```

### 3.4 Remote Repo with Multiple Modules (Module Collection)
Repository:
```text
vmctl-modules/
  jellyfin/
    service.toml
  radarr/
    service.toml
  media-stack/
    resource.toml
```

Must support:
- single fetch for `vmctl-modules@ref`
- all modules discoverable after indexing
- multiple modules referenced without refetching
- multiple repositories simultaneously

### 3.5 Reuse Same Repo Checkout for Multiple Modules
```toml
[resources.media_stack]
source = "git::https://github.com/example/vmctl-modules//media-stack?ref=main"

[resources.media_stack.services.jellyfin]
source = "git::https://github.com/example/vmctl-modules//jellyfin?ref=main"
```

Repo must be fetched once, module index shared.

---

## 4. Architecture Overview (Production-Ready)

The new system introduces a first-class **module layer** that sits between `vmctl.toml` parsing and the existing planner/orchestrator:

1. **SourceResolver** parses module source strings (`local://…`, `git::…`, `inline`) and produces an internal `SourceSpec`.
2. **RepoManager** fetches and caches git repositories, deduplicating by `(repo_url, ref)` and producing a stable checkout directory and resolved commit hash.
3. **ModuleIndexer** scans module collections (local dirs + git checkouts) for `resource.toml` and `service.toml` and produces per-collection `ModuleIndex`.
4. **ModuleRegistry** merges indexes across collections and applies the override precedence rules to yield:
   - A resolved `ResourceModule` set
   - A resolved `ServiceModule` set
5. **ModuleLoader** loads TOML manifests into typed structs with strong validation and stable diagnostics.
6. **MergeEngine** deterministically merges:
   - remote base module
   - local module override
   - resource-level overrides
   - vmctl-level overrides
7. **Composition Engine** expands `vmctl → resources → services` into the orchestrator’s dependency graph inputs.
8. **Dependency Graph Integration** reuses the existing service DAG logic, but uses module-origin-aware keys so services can be resolved from any source location.

### 4.1 Core Components
- ModuleDiscovery engine
- SourceResolver
- RepoManager (NEW)
- ModuleIndexer (NEW)
- ModuleLoader
- MergeEngine
- Resource–Service composition engine
- Dependency graph integration

---

## 5. Data Model

### 5.1 Source Syntax and Parsing

Supported forms:
- `local://<path>`: local filesystem module directory or module collection root
- `git::https://<host>/<org>/<repo>//<subdir>?ref=<ref>`: git repository module (checkout + subdir)
- `git::ssh://git@<host>/<org>/<repo>//<subdir>?ref=<ref>`: same, using SSH transport
- `inline`: module definition is provided in `vmctl.toml` at the referencing node

Notes:
- `//<subdir>` is optional. If absent, the module is the repo root (module collection root).
- `ref=` is required for reproducibility. `ref` may be a branch, tag, or commit SHA.
- The **resolved commit SHA** is what is recorded into `vmctl.lock` (or a new sources lock section).

### 5.2 Module Identity

Two identities are needed:
1. **Logical identity**: stable in config and overrides
   - `ModuleName` (example: `jellyfin`, `media-stack`)
   - `ModuleKind` (`resource` | `service`) discovered by file presence
2. **Physical identity**: where it came from
   - `ModuleOrigin`:
     - local collection path + module-relative path
     - git repo URL + ref + module-relative path + resolved commit
     - inline node path in config

Resolution rule:
- Overrides are decided by **logical identity** + precedence layer, not by physical path alone.

### 5.3 Module Registry Shape

```rust
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum ModuleKind { Resource, Service }

#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct ModuleKey {
    pub kind: ModuleKind,
    pub name: String,
}

#[derive(Debug, Clone)]
pub enum ModuleOrigin {
    Local { collection_root: std::path::PathBuf, module_dir: std::path::PathBuf },
    Git   { repo_url: String, ref_: String, commit: String, checkout_root: std::path::PathBuf, module_dir: std::path::PathBuf },
    Inline { config_path: String }, // "resources.media_stack.services.jellyfin"
}

#[derive(Debug, Clone)]
pub struct ModuleLocation {
    pub key: ModuleKey,
    pub origin: ModuleOrigin,
    pub manifest_path: std::path::PathBuf, // resource.toml or service.toml
}

#[derive(Debug, Clone, Default)]
pub struct ModuleRegistry {
    pub resources: std::collections::BTreeMap<String, ModuleLocation>,
    pub services: std::collections::BTreeMap<String, ModuleLocation>,
}
```

---

## 6. Override and Merge Strategy

### 6.1 Precedence (Deterministic)

Applies to both resources and services:
1. **Remote base module** (git module)
2. **Local module override** (local filesystem module with same logical name/kind)
3. **Resource-level definition** (a resource module includes/configures a service stack in `resource.toml`)
4. **vmctl-level override** (top-level inline overrides in `vmctl.toml`)

Important: “inline” here means “config overrides”, not necessarily a full inline module manifest.

### 6.2 Merge Semantics

For TOML tables:
- Scalar values: later layers overwrite earlier layers.
- Tables: deep-merge recursively.
- Arrays: default overwrite (not merge) unless the key is explicitly declared “mergeable” in schema (optional future enhancement).

Schema ownership:
- Services own their input schema (`service.toml [inputs] schema`).
- `MergeEngine` must reject unknown override keys for service inputs (same behavior as current `ServiceRegistry::resolve_inputs`).

### 6.3 Handling Name Collisions

Collisions can happen across module collections:
- Two service modules named `jellyfin` in different repos.

Rule:
- If multiple modules of the same logical key exist at the same precedence layer, error with a clear message listing origins.
- If they exist across layers, the higher-precedence layer wins.

Optional (future) namespace support:
- `name = "example/jellyfin"` or `namespace = "example"` fields in manifests.
- Not required for v1; collisions are handled as explicit errors.

---

## 7. Module Discovery Engine

### 7.1 Discovery Inputs
- Local module collection roots:
  - defaults: `./resources`, `./services`
  - plus `vmctl.toml [paths].modules` entries
- Git module collection roots:
  - checkouts managed by `RepoManager` based on referenced `git::…` sources
- Inline definitions:
  - captured during config parse when `source = "inline"` or inline blocks exist

### 7.2 Discovery Rules

For each collection root, scan recursively:
- If a directory contains `resource.toml`: register a resource module with module name from TOML `name` and validate it matches directory name (existing behavior).
- If a directory contains `service.toml`: register a service module with module name from TOML `name` and validate it matches directory name (existing behavior).

Indexing output includes:
- ModuleKey (kind+name)
- ModuleLocation (origin + manifest path + module directory)
- Optional module metadata extracted cheaply (kind, name, version)

### 7.3 Efficiency

Repo indexing is done once per checkout.
- Cache the module index alongside the checkout:
  - `index.json` containing discovered module keys and manifest relative paths
  - Invalidate when checkout commit changes

---

## 8. Remote Repository Manager (RepoManager) (NEW)

Responsibilities:
- Fetch repositories over HTTPS or SSH.
- Cache checkouts locally.
- Deduplicate fetches:
  - Same `(repo_url, ref)` = single checkout directory.
  - Different refs of same repo = different checkouts.
- Expose a module lookup API (via `ModuleIndexer` + `ModuleRegistry`) but RepoManager itself remains focused on git I/O + caching.

### 8.1 Cache Layout

Workspace-local cache (recommended default for determinism and easy inspection):
```text
backend/cache/git/
  <hash(repo_url)>/
    refs/
      <sanitized-ref>/
        repo/               # bare or normal checkout (implementation choice)
        worktree/           # materialized working tree for scanning/loading
        RESOLVED_COMMIT
        index.json
```

Alternative: user cache (e.g. `~/.cache/vmctl/git`). This plan recommends workspace-local initially because:
- `vmctl fetch` / `vmctl sources` becomes trivial to implement and reason about.
- Offline reuse is per workspace by default.

### 8.2 Implementation Approach

Prefer shelling out to `git` via `vmctl_util::command_runner` because it:
- Reuses existing SSH agent/config and HTTPS credential helpers.
- Minimizes libgit2 edge cases and feature gaps.

Minimum command set:
- `git clone --filter=blob:none` (optional optimization) or normal clone
- `git fetch --tags --force` for updates
- `git checkout <resolved>` (or `git worktree add` pinned to commit)
- `git rev-parse` to get commit SHA for lockfile

### 8.3 Authentication

SSH (default):
- Use system SSH config (`~/.ssh/config`, agent, known_hosts).
- Optional env overrides:
  - `GIT_SSH_COMMAND` to force identity file / strict host key checking mode.

HTTPS:
- Rely on credential helpers by default.
- Optional env token support:
  - `GIT_ASKPASS` flow is possible but avoid building custom credential management into vmctl initially.

---

## 9. Module Indexing (ModuleIndexer) (NEW)

After fetching a repo checkout, recursively scan for module manifests and register modules as:

Display form:
- `<repo_display_name>::<module-path>`
  - Example: `vmctl-modules::jellyfin`
  - Example: `vmctl-modules::media-stack`

Internal keying:
- By ModuleKey `(kind, name)` plus origin metadata so override errors can list exact repo/ref/commit.

Indexing must:
- Avoid duplicate loads: parse TOML only enough to read `name` and (for services) `version` during indexing; full parse happens in `ModuleLoader`.
- Record module directory so `ServiceRegistry`-style template/hook resolution can be rooted correctly per module origin.

---

## 10. Integration With Existing Planner/Orchestrator

Today (current codebase reality):
- `ResourceRegistry::load_with_config(resources_root, services_root, config_value, process_env)`
  - loads local `resources/*/resource.toml`
  - loads service definitions from `services/*/service.toml` (stripping manifest keys)
- `ServiceRegistry::load(services_root)`
  - loads service manifests from `services/*/service.toml`
- `planner` combines:
  - discovered resources + inline resources
  - expansions from `ResourceRegistry`
  - service execution plan from `ServiceRegistry`

Target state:
- Replace the assumption of single `services_root` and `resources_root` with `ModuleRegistry` outputs.
- Both “service definition” (for templating/render context) and “service manifest” (for service DAG and hooks) are derived from the same loaded module.

### 10.1 Proposed New Crate Boundaries

Add a new crate:
- `crates/modules` (package name `vmctl-modules`)

Move/adjust responsibilities:
- `vmctl-modules`:
  - SourceResolver
  - RepoManager
  - ModuleIndexer
  - ModuleRegistry
  - ModuleLoader
  - MergeEngine
  - Resource–Service composition expansion (module-centric)
- `vmctl-resources` and `vmctl-services`:
  - Evolve to operate on “loaded modules with explicit roots”, not “single root directory”.
  - Avoid adding shims; update the active codepaths to consume module-layer outputs.

### 10.2 Orchestrator / Dependency Graph

Service dependencies already exist via `service.toml [dependencies]`.
New requirements add:
- Dependencies spanning multiple repos: handled naturally because registry is global and keyed by logical service name.
- Dedup: dedup by `(service-name, scope, target)` as today, independent of origin.

Where origin matters:
- Rendering/copying templates + scripts must be done relative to the service module’s actual root directory (local or git checkout).

---

## 11. vmctl.toml Schema Updates

This plan adds the minimal schema needed to express:
- module collection roots
- module sources per resource/service
- inline overrides (resource-level and vmctl-level)

### 11.1 New Top-Level Keys

```toml
[paths]
# Local module collection roots (scanned recursively).
# Default: ["./resources", "./services"]
modules = ["./resources", "./services", "./modules"]

[sources]
# Optional named git sources to prefetch/index (useful for `vmctl fetch` and `vmctl sources` UX).
# Referencing a git module source directly should also auto-fetch.
git = [
  "git::https://github.com/example/vmctl-modules?ref=v1",
]
```

### 11.2 Resource Instance Schema (Proposed)

Move from `[[resources]]` (array) to `[resources.<name>]` (table keyed by name) to support clean overrides and stable addressing:

```toml
[resources.media_stack]
kind = "vm"
source = "git::https://github.com/example/vmctl-modules//media-stack?ref=main"

# Resource instance config (settings/features) overrides module defaults
[resources.media_stack.config]
vmid = 210

[resources.media_stack.services.jellyfin]
source = "git::https://github.com/example/vmctl-modules//jellyfin?ref=main"

[resources.media_stack.services.jellyfin.config]
http_port = 8097
```

Migration note:
- This is a breaking config shape change. The plan calls for migrating the active `Config` model and its deserializer rather than adding a compatibility shim.

---

## 11.3 Resource Modules Define Service Stacks (resource.toml)

To support “resources able to include services” and “compose reusable service stacks” without pushing service wiring into `vmctl.toml`, extend `resource.toml` with an optional `[services]` block.

Conceptually:
- `resource.toml` remains the resource module’s manifest and defaults.
- `resource.toml [services.<name>]` defines the resource’s **default service stack**, including where each service comes from and default inputs.
- `vmctl.toml` can override:
  - which services are enabled
  - per-service sources (swap local vs git)
  - per-service config inputs

Example `resource.toml` (new section):
```toml
name = "media-stack"
kind = "vm"

# ... existing fields: defaults/features/render/hooks ...

[services.jellyfin]
source = "local://services/jellyfin"

[services.jellyfin.config]
base_url = "/jf"
http_port = 8096

[services.radarr]
source = "git::https://github.com/example/vmctl-modules//radarr?ref=v1"

[services.radarr.config]
base_url = "/radarr"
```

Schema shape:
- `[services.<service_name>]` is a table containing:
  - `source` (optional; if omitted, resolve by service name via ModuleRegistry)
  - `enabled` (optional; defaults to `true`)
  - `config` (optional table; validated against the service module’s `[inputs] schema`)

Merge rule for resource composition:
- Resource module service stack provides defaults (precedence level 3).
- `vmctl.toml [resources.<name>.services.<svc>]` overrides it (precedence level 4).

---

## 11.4 Inline Module Definitions (inline)

Inline modules support the “no repo needed” case and allow operators to prototype or maintain small one-off modules.

Design constraints:
- Inline definitions must be representable as TOML tables.
- They must be validated the same way as file-based modules.
- They must participate in the same precedence rules.
- They must be visible in `vmctl sources` / resolution explain output.

### Inline Service Module

```toml
[services.custom_service]
source = "inline"

[services.custom_service.manifest]
name = "custom-service"
version = "0.1.0"
scope = "resource"
targets = ["vm"]

[services.custom_service.manifest.inputs]
schema = [
  { key = "http_port", type = "u16", default = 8080 },
]

[services.custom_service.manifest.dependencies]
requires = ["container-runtime"]

[services.custom_service.manifest.runtime]
requirements = ["compose-service"]
services = ["custom-service"]
templates = [
  { src = "templates/docker-compose.yml", dst = "docker-compose.custom.yml" },
]

[services.custom_service.files."templates/docker-compose.yml"]
contents = """
services:
  custom-service:
    image: nginx:alpine
    ports: ["${HTTP_PORT}:80"]
"""
```

Inline file payloads:
- Inline service modules may include a `[services.<name>.files]` map:
  - key: relative path (must be inside module, no `..`)
  - value: `{ contents = "..." }`
- At load time, `ModuleLoader` materializes an ephemeral module directory under:
  - `backend/generated/module-inline/<stable-hash>/…`
- The rest of the system treats it as a normal module root.

### Inline Resource Module

Same pattern:
```toml
[resources.media_stack]
source = "inline"
kind = "vm"

[resources.media_stack.manifest]
name = "media-stack"
kind = "vm"

# Optional default service stack owned by the resource module:
[resources.media_stack.manifest.services.jellyfin]
source = "local://services/jellyfin"
```

Locking:
- Inline modules do not have a git commit to pin.
- For reproducibility, lockfile should record a content digest for each inline module definition:
  - `sha256` over the normalized inline manifest + inline file contents.

---

## 12. Rust Interfaces (Traits / Core Types)

The intent is to keep git I/O, indexing, loading, and merging testable and independently mockable.

### 12.1 SourceResolver
```rust
use std::path::PathBuf;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum SourceSpec {
    LocalPath { path: PathBuf },
    Git { repo_url: String, ref_: String, subdir: Option<String> },
    Inline,
}

pub trait SourceResolver {
    fn parse(&self, source: &str) -> anyhow::Result<SourceSpec>;
}
```

### 12.2 RepoManager (NEW)
```rust
use std::path::PathBuf;

#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct RepoRef {
    pub repo_url: String,
    pub ref_: String, // tag/branch/sha
}

#[derive(Debug, Clone)]
pub struct ResolvedRepo {
    pub repo: RepoRef,
    pub commit: String,      // resolved SHA
    pub checkout_root: PathBuf,
}

pub trait RepoManager {
    fn ensure_repo(&self, repo: &RepoRef, offline: bool) -> anyhow::Result<ResolvedRepo>;
    fn list_repos(&self) -> anyhow::Result<Vec<ResolvedRepo>>;
}
```

### 12.3 ModuleIndexer (NEW)
```rust
use std::path::PathBuf;

#[derive(Debug, Clone)]
pub struct IndexedModule {
    pub kind: ModuleKind,
    pub name: String,
    pub module_dir: PathBuf,
    pub manifest_path: PathBuf,
    pub origin: ModuleOrigin,
    pub version: Option<String>, // service version or optional resource version
}

pub trait ModuleIndexer {
    fn index_collection(&self, collection_root: &PathBuf, origin: ModuleOrigin)
        -> anyhow::Result<Vec<IndexedModule>>;
}
```

### 12.4 ModuleLoader
```rust
#[derive(Debug, Clone)]
pub struct LoadedServiceModule {
    pub manifest: vmctl_services::ServiceManifest,
    pub definition: vmctl_resources::ServiceDefinition, // same file, stripped view
    pub root: std::path::PathBuf, // module dir
    pub origin: ModuleOrigin,
}

#[derive(Debug, Clone)]
pub struct LoadedResourceModule {
    pub manifest: vmctl_resources::ResourceManifest,
    pub resource: vmctl_domain::Resource, // same file, domain view
    pub root: std::path::PathBuf, // module dir
    pub origin: ModuleOrigin,
}

pub trait ModuleLoader {
    fn load_service(&self, loc: &ModuleLocation) -> anyhow::Result<LoadedServiceModule>;
    fn load_resource(&self, loc: &ModuleLocation) -> anyhow::Result<LoadedResourceModule>;
}
```

### 12.5 MergeEngine
```rust
use toml::Value;

#[derive(Debug, Clone, Copy)]
pub enum MergePrecedence { Remote, Local, ResourceLevel, Vmctl }

pub trait MergeEngine {
    fn merge_toml(&self, base: Value, overlay: Value) -> anyhow::Result<Value>;

    fn merge_with_precedence(
        &self,
        layers: Vec<(MergePrecedence, Value)>,
    ) -> anyhow::Result<Value>;
}
```

### 12.6 Composition Engine
```rust
#[derive(Debug, Clone)]
pub struct ResourceSpec {
    pub name: String,
    pub source: Option<SourceSpec>,
    pub config: toml::Value,
    pub services: std::collections::BTreeMap<String, ServiceSpec>,
}

#[derive(Debug, Clone)]
pub struct ServiceSpec {
    pub source: Option<SourceSpec>,
    pub enabled: Option<bool>,
    pub config: toml::Value, // service inputs overrides
}

pub trait CompositionEngine {
    fn resolve_resources_and_services(
        &self,
        registry: &ModuleRegistry,
        resources: std::collections::BTreeMap<String, ResourceSpec>,
    ) -> anyhow::Result<vmctl_domain::DesiredState>;
}
```

---

## 13. CLI Behavior (New/Updated Commands)

### `vmctl fetch`
- Ensures all referenced git sources are fetched and indexed.
- Writes resolved commits into lockfile sources section.
- Supports `--offline` to fail if something is not already cached.

### `vmctl update`
- Refreshes git sources (fetch latest for branch/tag refs), re-resolves commits, updates lock.
- Supports `--source <name|url>` to update one repo only.

### `vmctl sources`
Debugging/inspection:
- List cached repos (url, ref, commit, path, last fetch time if tracked).
- List modules per repo checkout (resources/services discovered).
- Explain resolution for a given module name (which origin won and why).

### Existing commands (`apply`, `plan`, `inspect`)
- Must invoke module resolution before desired state build.
- Must reuse cached repos; avoid refetching unless commanded.

---

## 14. Locking, Reproducibility, and Offline Mode

### 14.1 Lockfile Extension

Extend `vmctl.lock` from version `1` to `2` and add:
- `[[sources.git]]` records:
  - `repo_url`
  - `ref`
  - `commit`
  - optional `checkout_path` (debug only; not required for determinism)
- `[[sources.inline]]` records:
  - `config_path` (stable address like `services.custom_service`)
  - `digest` (sha256 of normalized inline manifest + inline files)

Example:
```toml
version = 2

[[sources.git]]
repo_url = "https://github.com/example/vmctl-modules"
ref = "main"
commit = "a1b2c3d4..."

[[sources.inline]]
config_path = "services.custom_service"
digest = "sha256:...."
```

Rules:
- `vmctl apply/plan` in `--offline` mode must refuse to resolve any git source not present in cache and lockfile.
- `vmctl fetch` populates cache and lockfile.

### 14.2 Dedup Guarantee

Dedup is by exact `(repo_url, ref)` for checkout and by `(kind, name)` for module resolution.

---

## 15. Security and Trust Boundaries

Remote modules may contain scripts that `vmctl` will execute during provisioning. Treat this as executing remote code.

Minimum production safeguards:
- Optional allowlist:
  - `vmctl.toml [security].git_allowlist = ["github.com/example/*", "git.example.internal/*"]`
- Optional “deny by default” mode:
  - `vmctl` errors if a git source is used and not allowlisted
- Strict path handling:
  - No `..` escapes in `//subdir`
  - Reject absolute subdir paths
- Print origin in all execution logs:
  - which repo/ref/commit provided each module’s scripts/templates

Future enhancements (not required for v1):
- commit signature verification
- hash pinning (content digest) in lockfile

---

## 16. Detailed Implementation Plan (Task Breakdown)

This is ordered to keep the system shippable at each step while avoiding long-lived compatibility shims.

### Phase 0: Groundwork and Refactor Boundaries
1. Create `crates/modules` (`vmctl-modules`) with empty scaffolding and unit test harness.
2. Add minimal shared types:
   - `ModuleKind`, `ModuleKey`, `SourceSpec`, `RepoRef`

### Phase 1: SourceResolver + Git Source Parsing
1. Implement `SourceResolver::parse` for:
   - `local://…`
   - `git::https://…//…?ref=…`
   - `git::ssh://…//…?ref=…`
   - `inline`
2. Unit tests:
   - parse success for each scheme
   - invalid ref missing => error
   - `//subdir` normalization and rejection of `..` segments

### Phase 2: RepoManager (Fetch + Cache + Dedup)
1. Define cache root:
   - default: `backend/cache/git` under workspace root
2. Implement `RepoManager::ensure_repo(repo, offline)`:
   - derive deterministic cache dir from `hash(repo_url)` + sanitized ref
   - if cached and commit matches lock (when present), reuse
   - if offline and missing, error
   - else fetch/update and record resolved commit
3. Tests (integration-style with temp dirs):
   - same `(repo, ref)` called twice => single clone/fetch (dedup)
   - different refs => distinct checkouts
   - offline mode => uses cache only

### Phase 3: ModuleIndexer (Multi-Module Repo Support)
1. Implement `ModuleIndexer::index_collection`:
   - recursive scan
   - detect `resource.toml` and `service.toml`
   - parse minimal `name` (and service `version`) to create `IndexedModule`
2. Tests:
   - a repo tree containing multiple modules registers all correctly
   - index is stable across filesystem traversal order (sort)
   - name mismatch between dir and manifest => error

### Phase 4: ModuleRegistry (Global Registry + Precedence)
1. Merge multiple indexes into a single registry:
   - remote git indexes
   - local path indexes
2. Apply precedence policy:
   - remote base < local override
3. Tests:
   - same module in remote + local => local wins
   - duplicates at same precedence => clear error listing origins

### Phase 5: ModuleLoader (Typed Load)
1. Load service modules:
   - parse `service.toml` into `ServiceManifest` (existing struct)
   - derive `ServiceDefinition` view by stripping manifest keys (reuse existing `service_definition_value` logic, moved into shared code)
2. Load resource modules:
   - parse `resource.toml` into `ResourceManifest`
   - parse same into `vmctl_domain::Resource` (existing behavior)
3. Tests:
   - service module load yields both views consistently
   - resource module load validates kind/name expectations

### Phase 6: Config Schema Migration (`vmctl.toml`)
1. Update `vmctl-config`:
   - introduce `[paths].modules`
   - migrate `resources` shape to table form `[resources.<name>]` with:
     - `source`, `kind`, `enabled`, `config`, `services`
   - add optional top-level `[services.<name>]` entries for workspace/host services (mirrors current `services` selections, but now module-addressable)
2. Update CLI config loading and validation accordingly.
3. Tests:
   - new schema parse success
   - validation errors are actionable

### Phase 7: MergeEngine + Composition Engine
1. Implement TOML deep-merge with array overwrite.
2. Resource resolution:
   - resolve resource module by `source` or by name via registry lookup
   - merge module defaults with `resources.<name>.config`
3. Service resolution within a resource:
   - services can come from:
     - resource module defaults (declared service stack)
     - resource-level additions/overrides
     - vmctl-level overrides
   - resolve each service’s module origin and merge service input overrides using service input schema validation
4. Tests:
   - inline overrides win over local and git
   - disabling a service removes it from the plan deterministically

### Phase 7.1: Inline Module Materialization
1. Implement inline module support in `ModuleLoader`:
   - materialize inline module roots under `backend/generated/module-inline/<hash>/`
   - enforce path safety (no absolute paths, no `..`)
2. Extend lockfile writing to record `[[sources.inline]]` digests.
3. Tests:
   - inline service module loads, renders templates, and runs hooks from the materialized root
   - changing inline contents changes digest deterministically

### Phase 8: Orchestrator/Planner Integration
1. Replace `ResourceRegistry::load_with_config(resources_root, services_root, …)` with:
   - `ModuleRegistry` + loaded module roots
2. Update service plan building:
   - `ServiceRegistry` must accept per-service module roots, not a single root directory:
     - store `manifest + root path` per service
3. Update resource rendering:
   - resource templates/scripts must be rooted to the resolved resource module directory, not assumed `./resources/<name>`
4. Tests:
   - cross-repo service dependencies resolve
   - service artifact rendering uses correct roots

### Phase 9: CLI Additions (`fetch`, `update`, `sources`)
1. Add `vmctl fetch|update|sources` commands.
2. Implement:
   - repo listing
   - module listing per repo
   - explain module resolution
3. Tests:
   - `fetch` in offline mode errors if missing
   - `sources` prints stable output for fixtures

---

## 17. TDD Plan (By Component)

For each component: define behavior → failing test → implement → validate → regression tests.

### SourceResolver
- Behavior:
  - parse valid local/git/inline
  - normalize subdir
  - reject missing ref
- Tests:
  - table-driven parsing cases

### RepoManager
- Behavior:
  - dedup by `(repo_url, ref)`
  - supports multiple refs of same repo
  - offline reuse
- Tests:
  - tempdir-based cache assertions
  - mocked command runner (optional) or real git fixtures using local `file://` repos

### ModuleIndexer
- Behavior:
  - indexes all `resource.toml` and `service.toml` recursively
  - stable ordering
  - name/dir mismatch errors
- Tests:
  - multi-module tree fixture

### ModuleRegistry
- Behavior:
  - merges indexes and applies precedence
  - collision errors are actionable
- Tests:
  - remote+local same module => local wins
  - two locals same name => error

### ModuleLoader
- Behavior:
  - loads typed manifests with correct root paths
  - provides both service manifest + service definition view
- Tests:
  - loads sample `service.toml` and verifies both views match expectations

### MergeEngine
- Behavior:
  - deep merge tables
  - overwrite scalars and arrays
- Tests:
  - nested table merge
  - array overwrite semantics

### Composition/Planner Integration
- Behavior:
  - multi-module repo reuse (single fetch, shared index)
  - cross-repo dependencies
  - deterministic plan ordering
- Tests:
  - fixture with two git repos and a resource that composes services from both
  - dedup ensures one repo checkout per ref

---

## 18. DRY Principles (How Duplication Is Avoided)

1. **Repo fetch dedup**:
   - Centralize in RepoManager; all `git::…` resolution routes through it.
2. **Single module index per checkout**:
   - ModuleIndexer runs once; index persisted to `index.json`.
3. **Single source of truth for service parsing**:
   - ModuleLoader parses `service.toml` once and derives both:
     - Service manifest (DAG + hooks)
     - Service definition (templating/render context)
4. **Single merge engine**:
   - All override merges use the same MergeEngine with explicit precedence ordering.

---

## 19. Definition of Done

- A single git repo can contain multiple modules (resources and services).
- Repo is fetched only once per `(repo_url, ref)`.
- All modules in repo are discoverable via indexing.
- Multiple repos supported simultaneously.
- Resources and services resolve across repos and local paths.
- Deterministic merge behavior:
  - remote base < local module < resource-level < vmctl-level
- Dependency graph resolves correctly across module origins.
- Reproducible runs via lockfile pinning of resolved commits.
- Offline mode supported via cache + lockfile.

---

## 20. Risks and Tradeoffs

- Repo size and scan performance:
  - Mitigation: index.json caching; optional `--filter=blob:none`; avoid reading large files during indexing.
- Caching complexity:
  - Mitigation: workspace-local cache first; deterministic directory naming; strict invariants.
- Version conflicts across repos:
  - If two repos define the same service name:
    - higher precedence layer wins, else error
  - Future mitigation: namespace support.
- Naming collisions:
  - Clear error messages with module origins and suggested fixes (rename or allowlist a preferred source).
- Security:
  - Remote scripts are code execution.
  - Mitigation: allowlist, strict path normalization, provenance printed in logs.
