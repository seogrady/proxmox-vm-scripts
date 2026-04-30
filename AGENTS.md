# AGENTS

Repository operating rules for contributors/agents:

- Do not preserve legacy compatibility paths unless explicitly requested.
- For service provisioning, `resources/*` and `services/*` are the only canonical source paths.
- If a change needs migration, update active codepaths directly rather than adding shims.
