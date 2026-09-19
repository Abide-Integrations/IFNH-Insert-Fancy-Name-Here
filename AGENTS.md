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
- `ACTIVE_PLAN.md` — living plan from the 2026-09-18 review (defects, performance, features, distribution). Update it whenever work lands; it is the current work queue.

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

The owner runs the Zig toolchain on their own machine (8 GB RAM; builds are
kept cheap). Agents write code and colocated tests but do not run `zig`.

For every change, an agent must:

1. Mark the task `[?]` (landed, awaiting verification) in `ACTIVE_PLAN.md`,
   never `[x]`; only the owner's confirmation makes it `[x]`.
2. Hand over the exact commands to run and the expected result. Cheapest
   first: `zig fmt --check src/`, `zig build check`,
   `zig build test -Dtest-filter=<substr>`, then full `zig build test`
   (no leak reports) once per phase.
3. For user-facing changes, name the manual smoke step to run with the built
   binary (`./zig-out/bin/ifnh`). "Tests pass" is not a substitute for
   running the app.

Heavy checks (ReleaseSafe, size/startup budgets, kill-9, bench) run in CI.
Keep changes small (one task per verify cycle) and mirror existing patterns,
because agent-written Zig 0.16 `std.Io` code is not compiler-checked before
hand-off.

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
