# Sources Syntax Refactor (Fine-Grained Module Filtering)

## Objective
Enhance `[sources]` so `vmctl` can load modules from local paths and git repos while selecting a final module set via `include` (whitelist) + `exclude` (blacklist) glob filters applied at load time.

## Architecture

### Schema (`vmctl.toml`)
Target:

```toml
[sources]
local = [
  { path = "./resources", include = ["devbox-*", "node"], exclude = ["legacy-*"] },
  "./services",
]
git = [
  { repo = "https://github.com/example/vmctl-modules", include = ["devbox-*"] },
]
```

Dual syntax support:

- Short form (per entry): `"./resources"` / `"./services"` / `"https://github.com/..."`
- Expanded form:
  - local: `{ path = "...", include = ["*"], exclude = [] }`
  - git: `{ repo = "...", include = ["*"], exclude = [] }`

Defaults:

- `include = ["*"]`
- `exclude = []`

Back-compat (no breaking changes):

- Keep accepting existing forms:
  - `local = "./modules"` and `local = ["./resources", "./services"]`
  - `git = ["git::https://host/repo?ref=main", "git::https://host/repo//subdir?ref=main"]`

### Normalized Representation
Normalize all entries into a single struct used by module loading:

```rust
// CLI layer (or exported helper in vmctl-modules)
pub struct NormalizedSource {
    pub spec: vmctl_modules::SourceSpec, // LocalPath{path} or Git{repo_url, ref_, subdir}
    pub include: Vec<String>,            // defaults applied
    pub exclude: Vec<String>,            // defaults applied
}
```

Normalization rules:

- local short `"./resources"` => `LocalPath{path}` + default filters
- local expanded `{ path = ... }` => `LocalPath{path}` + provided/default filters
- git expanded `{ repo = "https://..." }` => `Git{repo_url=repo, ref_="main", subdir=None}` + filters
- git short string:
  - parse via existing `DefaultSourceResolver` so legacy `git::...?...ref=...` (and optional `//subdir`) keep working

### Parsing Flow (Short → Expanded → Normalized)
1. `vmctl-config` deserializes `[sources]` allowing single-string and list forms, with list items being string or object.
2. Defaults applied (`include=["*"]`, `exclude=[]`).
3. CLI builds `Vec<NormalizedSource>` and proceeds with indexing/filtering through a single pipeline.

### Filtering Pipeline
For each source entry:

1. Index all modules under the collection root (existing `FsModuleIndexer`).
2. Apply include: keep modules where `module.name` matches any include glob.
3. Apply exclude: drop modules where `module.name` matches any exclude glob.
4. Pass the remaining `IndexedModule`s into `ModuleRegistryBuilder::add_indexed`.

Implementation details:

- Match globs against module names (not paths).
- Compile globs once per source entry (use `globset`).
- Precedence is strict: include first, then exclude.

### Git Source Behavior (Clone/Cache/Dedupe)
- Continue using `GitRepoManager` (already clones once and reuses the checkout cache).
- Add explicit dedupe in the CLI build path:
  - group git specs by `(repo_url, ref_)` (`RepoRef`)
  - call `ensure_repo` once per `RepoRef`, reuse `ResolvedRepo` across multiple filtered sources

## Code Examples

### `vmctl.toml`
Short form:

```toml
[sources]
local = ["./resources"]
git = []
```

Back-compat git strings:

```toml
[sources]
git = [
  "git::https://github.com/example/vmctl-modules?ref=main",
]
```

### Rust Structs
Config schema (`crates/config/src/lib.rs`):

```rust
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SourceCatalogConfig {
    #[serde(default = "default_local_sources_list")]
    pub local: SourceList<LocalSourceConfig>,
    #[serde(default)]
    pub git: SourceList<GitSourceConfig>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(untagged)]
pub enum SourceList<T> {
    One(SourceItem<T>),        // legacy: local = "./resources"
    Many(Vec<SourceItem<T>>),  // local = ["./resources", { path = ... }]
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(untagged)]
pub enum SourceItem<T> {
    Short(String),
    Expanded(T),
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct LocalSourceConfig {
    pub path: String,
    #[serde(default = "default_include")]
    pub include: Vec<String>,
    #[serde(default)]
    pub exclude: Vec<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct GitSourceConfig {
    pub repo: String,
    #[serde(default = "default_include")]
    pub include: Vec<String>,
    #[serde(default)]
    pub exclude: Vec<String>,
}
```

Normalized + filtering (shared for local + git):

```rust
fn filter_modules(
    modules: Vec<vmctl_modules::IndexedModule>,
    include: &globset::GlobSet,
    exclude: &globset::GlobSet,
) -> Vec<vmctl_modules::IndexedModule> {
    modules
        .into_iter()
        .filter(|m| include.is_match(&m.name))
        .filter(|m| !exclude.is_match(&m.name))
        .collect()
}
```

## Task Breakdown
1. Parser refactor (`vmctl-config`)
- Replace current `SourceCatalogConfig { local: Vec<PathBuf>, git: Vec<String> }` with untagged short/expanded lists (keeping legacy forms).
- Keep default local sources as `./resources` + `./services` when `sources.local` is absent.

2. Schema validation
- Validate:
  - non-empty `path`/`repo`
  - `include`/`exclude` are non-empty strings
  - glob patterns compile (fail fast with a source-entry-specific error)

3. Normalization logic
- Single function producing `Vec<NormalizedSource>` with defaults applied.
- Use `DefaultSourceResolver` for legacy git strings; map expanded `{ repo }` to `ref_="main"`.

4. Include/exclude filtering implementation
- Add a reusable filtering utility (prefer `vmctl-modules` so CLI and other commands can share it).
- Integrate into `build_module_registry` right after indexing, before `add_indexed`.

5. Git clone/cache/dedupe
- Deduplicate `ensure_repo` calls by `(repo_url, ref_)`.
- Keep lockfile pinning behavior unchanged (pins repo/ref to commit; filtering does not affect pins).

## TDD Approach

### Config tests (`crates/config`)
- short vs expanded:
  - `local = ["./resources"]`
  - `local = [{ path = "./resources" }]`
  - mixed list: `local = [{...}, "./services"]`
  - legacy: `local = "./modules"`
- defaults:
  - missing include/exclude => `include=["*"]`, `exclude=[]`
- git:
  - expanded `{ repo = "https://..." }`
  - legacy `"git::...?...ref=..."`

### Filter tests (modules crate)
- include-only
- exclude-only
- include+exclude precedence
- glob matching (`"*"` / `"devbox-*"` / `"*-service"`)
- invalid glob patterns -> error surfaced at validation/normalization

### Git + local consistency
- same filter produces the same selected module-name set regardless of origin (index output fed into filter).

## DRY Principles
- One normalization pipeline for local + git (no duplicated parsing paths).
- One filtering utility shared by all callers.
- Reuse existing `DefaultSourceResolver` + `GitRepoManager` (no new shims/parallel implementations).

## Definition Of Done
- `[sources]` supports short + expanded forms (including mixed lists).
- Defaults apply (`include=["*"]`, `exclude=[]`).
- Filtering matches glob patterns with include-then-exclude precedence.
- Local + git behave the same with respect to filtering.
- Git sources are cached and `ensure_repo` is deduped per repo/ref.
- Existing configs continue to work unchanged.

## Risks & Edge Cases
- include/exclude conflicts: exclude wins after include; test + document.
- empty result set: allow; downstream will error if referenced modules are missing (consider warning output in `vmctl sources`).
- invalid glob patterns: fail fast with a clear message pointing to the offending pattern.
- duplicate module names across sources: existing same-layer duplicates still error; filtering may change when this triggers.
