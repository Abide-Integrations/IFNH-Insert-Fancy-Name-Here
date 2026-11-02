# ADR-0006: Config CLI, published JSON Schema, per-key flags

- **Status:** Accepted (2026-11-02, task D-06)
- **Context:** Configuration could be read only by opening files, and the
  `.cli` layer was reserved but unused. Users edited JSON by hand with no
  editor help, a typo surfaced only at the next startup, and changing one model
  setting for a run meant an environment variable with `__` nesting. DECISIONS
  already fixed the layers (builtin, user, project, session, env, cli); nothing
  exposed them.
- **Decision:**
  1. **`ifnh config path|get|set|edit|schema`.** `get` reads the merged tree
     (`--json`, `--origin` for layer and file). `set <key> <value>` parses the
     value as JSON when it can and as a string otherwise, edits exactly one file
     (`--project` by default, `--global` for the user config), validates the
     candidate text with `validateFileText` and refuses to write when it has
     errors; the write is `fsutil.atomicWriteFile`. `edit` opens the file in
     `$VISUAL`/`$EDITOR` and validates what came back. `schema` prints the
     published schema.
  2. **JSON Schema is `docs/config.schema.json`**, embedded into the binary as a
     build-time anonymous import (`config_schema`) so the document users point
     their editors at and the one `ifnh config schema` prints cannot drift.
     Drift tests walk the builtin defaults against the schema's `properties` in
     both directions.
  3. **Per-key flags** (`--model`, `--provider`, `--base-url`, `--temperature`,
     `--max-output-tokens`, `--context-tokens`, `--permission-mode`,
     `--no-footer`) come from one table in `args.zig` and become the `.cli`
     layer after `--profile`, so a flag beats a profile, which beats files.
- **Consequences:**
  - Adding a flag is one table row plus a schema property.
  - `set` validates with the same code as startup, so what it accepts is
    exactly what the loader accepts. The validator does not type-check every
    key (for example `ui.footer`), so `set` inherits that gap.
  - `@embedFile` cannot reach outside the module root; the build-level import
    is the smallest fix that keeps the schema in `docs/`.
  - Free-form sections stay free-form in the schema.
- **Alternatives considered:**
  - Generate the schema from Zig types: rejected, config is data and the
    schema is a published contract reviewed as a document.
  - Move `main.zig` to the repository root so `@embedFile` reaches `docs/`:
    rejected as a layout change for one file.
  - A flag per config key generated automatically: rejected, most keys make
    poor flags and each flag is public surface.
- **Follow-ups:** type-check more keys in `validate` so `set` can reject
  `ui.footer notabool`; `config unset`; schema `$id` hosting.
