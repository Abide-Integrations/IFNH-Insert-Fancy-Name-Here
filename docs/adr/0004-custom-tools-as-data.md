# ADR-0004: Tools as data — a builtin registry and `.ifnh/tools/*.json`

- **Status:** Accepted (2026-11-01, tasks D-01/D-02)
- **Context:** `tools/tool.zig:execute` dispatched tools through an `if/else-if`
  chain of `std.mem.eql` calls, and `specs` (the model-facing list) was a second
  hand-maintained literal. Adding a tool meant editing three places, and users
  could not extend the tool set at all without rebuilding the binary. PLAN.md's
  adaptability goal ("ultra-adaptable", D-02 in ACTIVE_PLAN.md) named custom
  tools as the biggest lever; per-role allowlists and MCP-as-tools both need a
  single dispatch table.
- **Decision:**
  1. `src/tools/tool.zig` owns one static table, `pub const registry = [_]Tool{...}`,
     holding name, description, parameter schema, `executor_kind` and `call_fn`
     for all fourteen builtins. `find`, `specs` (computed at comptime from the
     table) and `isReadOnly` (from `executor_kind`) all read it, so dispatch,
     advertisement and read-only batching cannot drift. `specs` keeps the
     historical advertisement order.
  2. Data-defined tools live in `<workspace>/.ifnh/tools/*.json` and are loaded
     by the new module `src/tools/custom.zig`: `{name, description, parameters,
     command, permission}` (a file may hold an object or an array). `{name}`
     placeholders in `command` are replaced with the matching argument, shell
     single-quoted (`'` becomes `'\''`), so an argument is always one word.
     `{{`/`}}` escape literal braces.
  3. Custom calls run through the same captured-shell path as `bash`
     (`runShell`): same timeouts, output cap, cancel flag, journal and background
     behaviour, and the command is classified by the permission engine as if the
     model had asked for it via `bash`. `.ask` prompts name the tool and render
     the full command; `.deny` and a declined prompt return `permission denied`.
  4. Collisions with builtins (and `mcp_*`, `agent`) are rejected, names must
     match `^[a-z][a-z0-9_-]{0,63}$`, at most 64 tools and 64 KiB per file.
     Load errors are warnings on the caller's stderr/stdout channel, never
     fatal; a missing `.ifnh/tools` directory is normal. `tools.external: false`
     disables loading entirely (one warning).
  5. The set is loaded once per run in `SessionRuntime.init` and shared by the
     REPL, `ifnh ask` and child agents (`subagents inherit their parent's set`).
  6. `custom.zig` never imports `tool.zig` (no cycle). Its `reserved_names`
     table is checked against `registry` by a `comptime` assertion, so a new
     builtin that is not reserved fails the build instead of shadowing.
- **Consequences:**
  - `permission` in a definition is advisory metadata for the model (and a hook
    for future allowlists); it does not bypass the engine. Every custom tool is
    gated, sequential, and never `read` for batching purposes.
  - A custom tool is a shell command template, so it cannot express logic that
    needs more than arguments; that keeps the loader tiny and auditable.
  - The set is loaded at startup, so a new definition needs a new run.
  - Deviations from the DESIGN sketch, all recorded in code comments:
    `call_fn(ctx, args)` instead of `call_fn(ctx, alloc, io, input)`
    (`ToolContext` already carries all three), `Set.load(arena, io, workspace,
    enabled)` because Zig 0.16 `std.Io.Dir` reads need an explicit `std.Io`,
    and `Request.command` is the engine's existing single-string form rather
    than argv.
  - Tests: 7 in `custom.zig` (loading, warn-and-skip, collisions, kill switch,
    quoting, bad placeholders) and 5 in `tool.zig` (registry/spec agreement,
    read-only derivation, end-to-end execution, injection attempt, gate
    failures), because an end-to-end test must go through `execute`.
