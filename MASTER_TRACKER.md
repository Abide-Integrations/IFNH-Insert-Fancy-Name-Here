# IFNH — Master Implementation Tracker

> **Status:** Living document — update task statuses as work lands.
> **Reads with:** PLAN.md (philosophy) · DECISIONS.md (accepted answers) · DESIGN.md (spec)
> **Conventions:** Task IDs `M<n>-T<nn>`. Status: `[ ]` todo · `[~]` in progress · `[x]` done · `[-]` cancelled. Every task lands with tests (`zig build test`) unless explicitly docs-only. Performance budgets from DESIGN §7 are release gates at M2.

---

## Milestone overview

> **2026-11-03:** current state lives in [ACTIVE_PLAN.md](ACTIVE_PLAN.md) (Phases A-D landed, Phase E in progress, almost every row `[?]` awaiting owner verification). Several `[x]` marks below predate the 2026-09-18 review and were audited on this date; rows corrected to `[~]`/`[?]` carry a dated reason. Nothing here was flipped to `[x]` by an agent.

| Milestone | Theme | Exit condition | Status |
|---|---|---|---|
| **M0** | Vertical-slice core | Tool loop works e2e against fake provider; sessions resume; undo restores files; permission gates hold; startup budget measured | **code complete** (2026-09-14) — 54 tests green, 1.3 MiB stripped; residual `[~]` items tracked above (raw-mode editor, retry policy, disk-backed commands → M1) |
| **M1** | Agents, extensions, observability | Subagents + worktrees + MCP + skills + hooks functional with tests; usage tracking; doctor | **code complete** (2026-09-14) — subagents/worktrees/MCP/skills/hooks/compaction/usage/doctor landed; deferred: background execs, read_tool_result, HTTP MCP |
| **M2** | Lifecycle, governance, budgets | Lifecycle engine + review gates + forks; CI budgets enforced; go-public checklist green | **code complete** (2026-09-14) — all M2 tasks landed except `fork diff` (post). Remaining open items are polish (`[~]`) and post-1.0 features |
| **Post** | Roadmap | DECISIONS `[post]` items, 0.17.0 compat | ongoing — tracked in [ACTIVE_PLAN.md](ACTIVE_PLAN.md) (review of 2026-09-18: correctness P0s, performance, UX, adaptability, distribution). Note: several M0–M2 `[x]` items there are overstated (see findings F-A01..F-A10) |

---

## M0 — Vertical-slice core (Meta-M3)

### M0.1 Foundation

| ID | Task | Depends | Status | Notes |
|---|---|---|---|---|
| M0-T01 | Scaffold: `build.zig`/`build.zig.zon` (zero deps, min 0.16.0), release flags, catch-all test wiring | — | `[x]` | done 2026-09-14 (scaffold commit) |
| M0-T02 | `core/fsutil.zig`: atomic durable replace (fsync file+dir), realpath helper, safe mkdirs, advisory flock | M0-T01 | `[x]` | with unit tests |
| M0-T03 | `cli/args.zig`: subcommand parsing, kebab-case flags, `--json` plumbing, FixedBufferAllocator help path | M0-T01 | `[x]` | |
| M0-T04 | `core/types.zig`: shared event/message/result types | M0-T01 | `[x]` | |
| M0-T05 | Version/metadata + `ifnh --version`, `ifnh --help` | M0-T03 | `[x]` | |

### M0.2 Configuration (highest-risk after providers)

| ID | Task | Depends | Status | Notes |
|---|---|---|---|---|
| M0-T06 | `core/config/`: defaults table + deep-merge with source tracking (per-key layer/path) | M0-T02 | `[x]` | done 2026-09-14; arena-aliasing bug found+fixed, 6 tests |
| M0-T07 | Loaders: user dir (XDG/macOS), `.ifnh/config.json`, `config.d/` merge, env `IFNH_*__*`, CLI overrides | M0-T06 | `[?]` | env layer via `IFNH_*__*` tested; CLI flags reserved (flags pass through to REPL) 2026-11-03: F-A10 (config path convention, A-10) and F-A07 (dead keys, A-07) are fixed and CLI per-key flags landed (D-06); all `[?]` in ACTIVE_PLAN, not owner-verified |
| M0-T08 | Validation: schema_version, unknown-key warnings, fail-closed security sections | M0-T06 | `[x]` | permissions/model.provider fail closed |
| M0-T09 | `ifnh config validate` + `ifnh config explain <key>` + `ifnh config path` | M0-T08 | `[?]` | validate + explain shipped; `config path` deferred 2026-11-03: `config path` exists (D-06, `[?]` in ACTIVE_PLAN); the "deferred" note was stale |
| M0-T10 | Policy-boundary re-read helper (hot reload at boundaries only) | M0-T07 | `[~]` | session-layer overrides (e.g. /model) apply per turn; full boundary re-read M1 2026-11-03: `SessionRuntime.reloadConfig` re-reads config at turn boundaries and re-applies session overrides; policy-file changes fail approvals closed. Still `[~]`: no general hot-reload of every layer |

### M0.3 Sessions & journal

| ID | Task | Depends | Status | Notes |
|---|---|---|---|---|
| M0-T11 | `core/session/`: dir layout, manifest, id generation (`s_` + 12-char), flock/SessionBusy | M0-T02 | `[x]` | tryLock non-blocking; SessionBusy tested |
| M0-T12 | JSONL event writer with watermark + bounded replay reader + torn-tail handling | M0-T11 | `[?]` | torn tail ignored; assistant tool_calls embedded 2026-11-03: F-A04 (tool traffic was not persisted) fixed in A-04 (`[?]`); not owner-verified |
| M0-T13 | `ifnh sessions list` / `ifnh resume` (picker + last) with UI replay projection | M0-T12 | `[~]` | list + resume by id; interactive picker M1 2026-11-03: the interactive picker is not built; resume is by id or last |
| M0-T14 | `core/journal.zig`: intent/commit groups, inverse patches, undo/redo walker | M0-T02 | `[x]` | DESIGN §3.6 |
| M0-T15 | Crash-recovery pass: replay/rollback incomplete journal groups at startup | M0-T14 | `[x]` | rollback-on-open tested |

### M0.4 Providers (prototype-first per W309)

| ID | Task | Depends | Status | Notes |
|---|---|---|---|---|
| M0-T16 | `providers/provider.zig` contract + `EventSink` + capability descriptor | M0-T04 | `[x]` | fn-pointer struct per DESIGN |
| M0-T17 | `providers/sse.zig`: bounded SSE parser (UTF-8 safe, max event/total bytes, cancel checks) | M0-T16 | `[x]` | 5 tests; std fixed-reader quirk worked around (takeByte state machine) |
| M0-T18 | `providers/transport.zig`: std.http wrapper, deadlines, cancel flag, retry/backoff/Retry-After, delivery certainty | M0-T16 | `[?]` | A-05 landed (awaiting owner verification): connect/idle limits, adapter `.failure` conversion, Retry-After parsing, engine backoff; delivery certainty still open 2026-11-03: A-05 (connect/idle limits, `.failure` conversion, Retry-After) landed; awaiting owner verification (F-A05) |
| M0-T19 | `providers/openai.zig`: chat-completions adapter (streaming + tool calls + usage), config-driven base_url | M0-T18 | `[?]` | tool-call accumulation by index; [DONE] handling 2026-11-03: F-A05 retry/Retry-After handling landed in A-05 (`[?]`) |
| M0-T20 | `providers/anthropic.zig`: messages adapter (streaming + tool use + usage) | M0-T18 | `[?]` | tool_result user blocks; input_json_delta accumulation 2026-11-03: F-A02 (tools sent in OpenAI shape) fixed in A-02 and thinking blocks added in E-01 (both `[?]`); not owner-verified |
| M0-T21 | `tests/fake_provider.zig` + `tests/fake_server.zig` (in-process, canned responses) | M0-T16 | `[?]` | fake provider (`core/agent/testing.zig`) done + drives engine tests; fake HTTP server for adapter e2e deferred (M1-T15) 2026-11-03: the fake HTTP server landed as `providers/testing.zig` (`FakeServer`, W-04/A-05, `[?]` in ACTIVE_PLAN) and backs the adapter, `serve` and `libifnh` tests; the `tests/fake_*.zig` file names were not used. The old "deferred (M1-T15)" note was stale |
| M0-T22 | Credential leases: env-var keys, zeroize after use, redaction filter for model-bound output | M0-T16 | `[~]` | env-var keys wired (api_key_env); zeroize+redaction filter M1 2026-11-03: redaction exists (`core/redact.zig`, `debug.redact`) but is fed the active API key only (F-A observation); credential zeroizing is not implemented |

### M0.5 Tool kernel

| ID | Task | Depends | Status | Notes |
|---|---|---|---|---|
| M0-T23 | `tools/tool.zig`: Tool contract + registry + JSON-schema subset + parallel read-only batches | M0-T04 | `[?]` | 7 specs + dispatch; parallel batches land with M1 subagents. 2026-11-01 (D-01/D-02, awaiting owner verification): one static `registry` table now backs `find`/`specs`/`isReadOnly`; data-defined `.ifnh/tools/*.json` tools load at session start (`tools/custom.zig`, ADR 0004) 2026-11-03: D-01/D-02 are `[?]` in ACTIVE_PLAN; parallel read-only batches exist in the engine |
| M0-T24 | `read`, `glob`, `grep` tools (bounded output, 64 KiB cap, UTF-8-safe truncation marker) | M0-T23 | `[x]` | literal-substring grep (no regex, per fx) |
| M0-T25 | `edit` (exact old/new, context-hash staleness check) + `write` tools, journal-integrated | M0-T14, M0-T23 | `[x]` | ambiguity + staleness refused; journal groups |
| M0-T26 | `bash` tool: argv vs `$SHELL -c` classification, lexer, destructive lexicon, process groups, output caps, managed timeout | M0-T23 | `[?]` | 120s timeout; classifier tests; background registry M1 2026-11-03: F-A03 (quote mis-tokenizing) fixed in A-03 (`[?]`): every command now runs under `sh -c`; E-04 adds the optional OS sandbox (`[?]`) |
| M0-T27 | `git` tool: porcelain-only (status/diff/add/commit/branch/worktree), output parsing | M0-T26 | `[x]` | subcommand classification via command_class |

### M0.6 Permissions & approvals

| ID | Task | Depends | Status | Notes |
|---|---|---|---|---|
| M0-T28 | `core/permissions/engine.zig`: rules (tool/path/command), deny>ask>allow, realpath glob matching, fail-closed parse | M0-T06 | `[x]` | glob + command classifier + engine, 9 tests |
| M0-T29 | Session grants: once/session/pattern scopes; grant feedback into context | M0-T28, M0-T11 | `[x]` | once-grants consumed; approval prompt grants prefixes |
| M0-T30 | `.ifnh/` agent-write-deny + policy snapshot hash at approval boundaries | M0-T28 | `[x]` | fail-closed tamper detection at every approval |
| M0-T31 | Approval UI (inline diff/command preview, grant options) + dirty-tree detection banner | M0-T29 | `[~]` | [y]once/[s]session/[n]o prompt; dirty-tree banner M1 2026-11-03: the dirty-tree banner was never built |

### M0.7 Agent loop & UI

| ID | Task | Depends | Status | Notes |
|---|---|---|---|---|
| M0-T32 | `core/agent/` turn engine: stream → tool batch → permission → execute → tool_result loop; budgets/timeouts/interrupt (Esc) | M0-T16, M0-T23, M0-T28 | `[~]` | loop + usage + round limit done; cancel flag present, Esc wiring M1 |
| M0-T33 | `core/instructions/`: AGENTS.md/CLAUDE.md/nested discovery, assembly log, precedence | M0-T06 | `[~]` | root AGENTS/CLAUDE + .ifnh/instructions assembled w/ source log; nested-dir scoping M1 |
| M0-T34 | `ui/render.zig` + `ui/input.zig`: inline streaming renderer, footer, raw-mode line editor, ANSI subset, NO_COLOR/ascii modes | M0-T03 | `[~]` | line-oriented inline streaming REPL (TTY/SSH/pipe safe); raw-mode editor + footer M1 |
| M0-T35 | Plan artifacts + non-trivial detection + approve/edit flow | M0-T32 | `[~]` | `/plan` artifacts + system-prompt planning rules; auto-threshold detection M1 |
| M0-T36 | Merge gate: whole-diff view, approve/reject (no auto-merge) | M0-T27 | `[x]` | /diff + approval-gated git commit (write-class → ask) |
| M0-T37 | Slash command framework + defaults (`/help /model /config /undo /redo /sessions /resume /quit` + disk-backed `commands/`) | M0-T32 | `[~]` | built-ins live (incl /context /diff /plan); disk-backed commands M1 with skills |
| M0-T38 | `ifnh init` (`.ifnh/` skeleton + starter config, never overwrites) | M0-T09 | `[x]` | done + REPL lazily creates state dirs (zero-config) |

### M0.8 Hardening & acceptance

| ID | Task | Depends | Status | Notes |
|---|---|---|---|---|
| M0-T39 | Integration tests: e2e tool loop (fake provider), kill -9 resume, undo-after-crash, permission denials | M0-T32 | `[x]` | 85 tests + tests/integration-kill9.sh harness |
| M0-T40 | Benchmark script: startup + subcommand timing vs budget (50ms/5ms), record baseline | M0-T34 | `[x]` | scripts/bench.sh (size + startup gates); 5ms measured |
| M0-T41 | Binary size check vs 5 MiB budget; strip verification | M0-T01 | `[x]` | 1.3 MiB stripped ReleaseSafe (was 9.3 MiB unstripped) |
| M0-T42 | AGENTS.md conventions finalized; `zig fmt` clean; error-path audit (no panics on bad input) | all | `[~]` | fmt clean, all paths error-return; audit continues |

**M0 exit checklist:** all `[x]` + W305 criteria demonstrated in tests + budgets measured.

---

## M1 — Agents, extensions, observability

| ID | Task | Depends | Status | Notes |
|---|---|---|---|---|
| M1-T01 | Subagent runtime: spawn request schema, thread-per-child, captured authority snapshot, per-child cancel, structured reports to `reports/` | M0-T32 | `[x]` | role-scoped engines; authority snapshot; durable reports |
| M1-T02 | Parallel subagent groups + auto concurrency (read-only parallel rule) + runaway caps | M1-T01 | `[x]` | consecutive agent calls run on threads, ordered fan-in; depth/concurrency caps |
| M1-T03 | `/agents` status pane + child inspection | M1-T01 | `[~]` | /agents lists reports; live pane deferred (children run inline) |
| M1-T04 | Worktrees: naming, location, branches, merge gate integration, failed-task retention, cleanup-with-approval | M1-T01 | `[x]` | isolation:"worktree"; branch ifnh/<session>/<agent>; diff preview in envelope; cleanup M2 |
| M1-T05 | MCP client: stdio dispatcher (NDJSON reader thread) + Streamable HTTP, config, admission/trust, permission integration, per-agent allowlists | M0-T28 | `[?]` | stdio done (lazy spawn, tools/call, permission-gated, /mcp); HTTP transport + per-agent allowlists M2 2026-11-03: Streamable HTTP and per-agent allowlists landed in E-03; F-A08 schema discovery in A-08 (all `[?]`) |
| M1-T06 | Skills: SKILL.md catalog (user/project/compat roots), budgeted `<available_skills>` index, `skill` loader tool, `/skills`, `/reload skills` | M0-T37 | `[x]` | per-turn catalog; /reload M2 |
| M1-T07 | Hooks: 10 events, sync, block semantics, trust-gated project hooks | M0-T32 | `[~]` | 8 events wired (before/after agent); tool/merge-level dispatch M2 |
| M1-T08 | Context compaction: trigger thresholds, chunked summary pipeline, structured handoff checkpoint, `/compact` | M0-T12 | `[?]` | auto at turn boundaries + manual; chunked pipeline C36 note 2026-11-03: F-A09 (compaction could orphan tool results) fixed in A-09 (`[?]`) |
| M1-T09 | Usage tracking: per-agent tokens/cost/time/tool-calls (`usage.jsonl`), surfaced in `/agents` | M0-T32 | `[x]` | session usage.jsonl + /usage totals |
| M1-T10 | Background/managed executions: execution handles, poll/stop, session-end cleanup | M0-T26 | `[x]` | registry + bash background:true + exec tool + /exec |
| M1-T11 | Model catalog probing + aliases/fallbacks + routing table + cost estimation | M0-T19 | `[~]` | /model session override + role routing (lifecycle); aliases/fallbacks/cost M2 |
| M1-T12 | `read_tool_result` artifact retrieval + output artifact store | M0-T24 | `[x]` | oversized outputs to .ifnh/cache/artifacts with paging |
| M1-T13 | Checkpoints (watermark + handoff + config hash + refs) | M0-T12 | `[~]` | watermark + manifest + compaction notes; full checkpoint.json M2 |
| M1-T14 | `ifnh doctor`: config, provider reachability, git, MCP health | M1-T05 | `[x]` | config/provider-key/git/MCP/state checks |
| M1-T15 | Deterministic multi-agent integration tests (fake provider driving children) | M1-T01 | `[x]` | subagent + lifecycle e2e on scripted providers |

**M1 exit:** W302 feature set works with tests; per-child overhead measured (T265).

---

## M2 — Lifecycle, governance, budgets

| ID | Task | Depends | Status | Notes |
|---|---|---|---|---|
| M2-T01 | Lifecycle schema v1 + stage runner (linear, entry/exit conditions, per-stage agent/model/permissions) | M1-T01 | `[x]` | linear runner + entry conditions + role routing |
| M2-T02 | Review gates: reviewer role, multi-reviewer, all/any/n_of_m, severity model, blocking rules | M2-T01 | `[x]` | N reviewers + all/any/n_of_m + threshold; failed reviewers fail closed |
| M2-T03 | Review overrides (developer-only, audited) + `/review` command | M2-T02 | `[x]` | audit artifacts + --from resume |
| M2-T04 | Reconciliation-agent flow for concurrent conflicts | M2-T01 | `[x]` | /reconcile via journal version history (D045/046) |
| M2-T05 | Session forks (+ optional worktree binding) + `fork diff` | M0-T13 | `[x]` | fork + `ifnh fork diff` with divergence point |
| M2-T06 | `ifnh cleanup` (retention, orphan worktrees w/ approval, debug logs) | M1-T04 | `[x]` | dry-run default, --yes executes |
| M2-T07 | CI: build + test matrix (Linux/macOS), size + startup budget gates, `zig fmt` check | M0-T40/41 | `[~]` | size + startup gates in ci.yml 2026-11-03: CI is ubuntu-only; the macOS nightly (E-09, `[?]`) is not a required check |
| M2-T08 | `--json` output on all subcommands (output contracts) | M0-T03 | `[~]` | sessions list --json; remaining subcommands post-1.0 |
| M2-T09 | Reconnaissance skill (repo survey → durable artifact) | M1-T06 | `[x]` | skills/reconnaissance (first-party, disk-shipped) |
| M2-T09b | First-party skills (create skill) with human-review activation | M1-T06 | `[x]` | skills/create-skill; never self-activate (K161) |
| M2-T11 | Go-public checklist: secrets scan, README, CONTRIBUTING, SECURITY.md, LICENSE headers, ADR audit | — | `[x]` | CONTRIBUTING + SECURITY + budgets + ADRs landed |

**M2 exit:** CI budgets green; lifecycle demo e2e; go-public checklist green (owner decides publish timing).

---

## Standing tasks (every milestone)

| ID | Task | Status |
|---|---|---|
| ST-1 | Validate 0.17.0 compatibility when released (M4); adapt or pin | `[?]` 2026-11-04 (E-07): PINNED to Zig 0.16.0 (`minimum_zig_version` 0.16.0). The 0.17.1 port of 2026-11-03 was reverted because CI and the test host run 0.16.0 and it could not be verified green. Full suite on 0.16.0: 466 pass / 471 total (5 skips), exit 0, no leaks. Breakages a future port must handle: `builtin.OptimizeMode.debug` -> `.Debug`, `std.Build.addPassthruArgs` -> `addArgs`, `@backingInt` -> `@intFromEnum`, `Enum.field_names` -> `.fields`, `std.Io.net.HostName.fromUri` (transport), module-level `.link_libc`, test string repetition `"x" ** n` -> `@splat`. A nightly, non-blocking `zig-0.17` workflow (`.github/workflows/zig-0.17.yml`) tracks the port |
| ST-2 | Update DECISIONS.md changelog for any decision change | `[ ]` |
| ST-3 | ADR for any interface/dependency/security change | `[ ]` |
| ST-4 | Keep `zig build test` green; `zig fmt src/` clean | `[ ]` |

---

## Decision-change log

| Date | Decision | Changed from → to | Reason |
|---|---|---|---|
| 2026-09-14 | M1 config format | YAML → JSON | stdlib-only, fx-proven (owner) |
| 2026-09-14 | M4 toolchain | 0.17.0 requested → 0.16.0 stable baseline | 0.17.0 unreleased; compat tracked (ST-1) |
| 2026-11-03 | Toolchain | 0.16.0 → 0.17.1 (min 0.17.0) | 0.17 released; the port is source-incompatible with 0.16 (E-07, ST-1) |
| 2026-11-04 | Toolchain | 0.17.1 -> 0.16.0 (min 0.16.0) | The 0.17 port was reverted: CI and the test host run 0.16.0 and it could not be verified green; ST-1 allows pinning. A non-blocking 0.17.1 nightly workflow tracks the future port |

---

## Repository management

- Init git history: first commit = scaffold + docs (`git init` in /opt/ifnh — currently a bare .git exists from repo creation; verify remotes before pushing anywhere).
- Branch model: `main` protected post-publish; short-lived feature branches; no force-push policy in repo settings once public.
