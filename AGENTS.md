# AGENTS.md

Instructions for AI coding agents working in this repository.

## What this project is

IFNH is a lightweight agentic coding harness written in Zig. Philosophy,
accepted decisions, and scope live in three authoritative documents — read
them before making architectural choices:

- `PLAN.md` — product philosophy and decision ledger D001–D049 (plus amendments).
- `DECISIONS.md` — resolved discovery backlog; every answer references its question number.
- `DESIGN.md` — technical spec: module layout, interfaces, schemas, budgets.
- `MASTER_TRACKER.md` — implementation tasks and status. Update task statuses as you land work.

## Toolchain

- Zig 0.16.0 (`minimum_zig_version = 0.16.0`). No Node, no Python, no
  JavaScript build step for the binary.
- Zero third-party Zig dependencies, permanently (`build.zig.zon` has an
  empty `dependencies` table). A dependency proposal requires an ADR and a
  written "why does this belong in core" justification.

```bash
zig build              # build the binary -> zig-out/bin/ifnh
zig build test         # run all unit tests
zig fmt src/           # format; the canonical check is `zig fmt --check src/`
```

## Verification rules

Do not report work as done until:

1. `zig build` succeeds.
2. `zig build test` passes with no leak reports.
3. `zig fmt src/` produces no diff.
4. You ran the built binary (`./zig-out/bin/ifnh`) on the changed path if it
   is user-facing. "Tests pass" is not a substitute for running the app.

## Code style

- Run `zig fmt` on everything before committing.
- No emojis in code, output, or documentation. Unicode symbols are acceptable.
- CLI flags are kebab-case (`--no-color`, `--log-level`).
- `snake_case` identifiers, `PascalCase` types, per Zig convention.
- Keep `pub` surface minimal; only mark declarations `pub` when used outside the file.
- Bounded error sets and `errdefer` for partial state; never panic on bad
  runtime input; test allocation-failure paths where practical.
- Allocators: explicit `io`-style parameter passing (Zig 0.16 `std.Io`);
  arena for request-scoped scratch, caller-owned results documented in doc
  comments.

## Architecture rules (non-negotiable)

- `src/main.zig` is the composition root. No leaf feature logic there.
- `src/core/` owns contracts and runtimes. It must not import `src/ui/` or `src/cli/`.
- `src/ui/` renders snapshots and feeds input events; it never owns product state.
- `src/providers/` translate the generic request/event model to wire
  formats; they never absorb product logic.
- `src/tools/` implementations depend only on `core` contracts.
- Behavior expressible as JSON/Markdown on disk loads at runtime; do not
  compile policy into the binary.
- Tests are colocated `test` blocks; register new modules in the catch-all
  `test` block at the bottom of `src/main.zig`.
- Every write to user state goes through `core/fsutil.zig` atomic primitives.

## Adding a feature

1. Find the task in `MASTER_TRACKER.md` (or add one with owner agreement).
2. Decide the module owner using the rules above; if unclear, define the
   contract (types + pure functions) first and test it before the runtime.
3. Land contract + tests + implementation together.
4. Update the tracker status and, if a documented decision changed,
   `DECISIONS.md` changelog (and an ADR for interfaces/dependencies/security).
