# AGENTS: crates/modules

Purpose:
- Own module-source resolution and indexing primitives for vmctl.
- Provide deterministic mapping from source declarations to module manifests.

Scope:
- Source parsing (`local://`, `git::...`, `inline`).
- Git fetch/cache/dedup by `(repo_url, ref)`.
- Recursive manifest discovery (`resource.toml`, `service.toml`).
- Module precedence registry assembly (remote < local < inline).

Non-goals:
- Planner/business-level composition decisions.
- Resource/service runtime rendering logic.
- Backward-compatibility shims for legacy config formats.

Invariants:
- Reject unsafe git subdirs (`..`, absolute paths).
- Keep behavior deterministic (sorted outputs, stable dedup).
- Preserve clear origin metadata for diagnostics and lock pinning.

When editing:
- Prefer adding tests for parser/indexer/registry behavior changes.
- Keep APIs small and crate-local responsibilities explicit.
