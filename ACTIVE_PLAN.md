# IFNH — Active Plan

> **Living document.** Updated whenever work lands or a finding changes. Sits beside `MASTER_TRACKER.md` (M0–M2 milestone ledger); this file tracks everything found in the 2026-09-18 review: defects, performance, missing features, and distribution.
> **Reads with:** PLAN.md (philosophy) · DECISIONS.md · DESIGN.md · MASTER_TRACKER.md · AGENTS.md
> **Baseline:** v0.1.7, ~11k lines of Zig, 61 commits. Review was a static read; findings tagged **[read]** are confirmed by reading the code, **[verify]** still needs a measurement or run.

---

## How this document works

**Who runs what.** The agent writes code and colocated tests and never runs `zig`. The owner runs every build/test locally (M3, 8 GB RAM: keep it cheap) and reports the result. A task only becomes `[x]` on the owner's confirmation.

**Status legend**

| Mark | Meaning |
|---|---|
| `[ ]` | todo |
| `[~]` | in progress |
| `[?]` | code landed, **awaiting owner's local verification** |
| `[x]` | verified by owner |
| `[!]` | failed verification or blocked (see notes) |
| `[-]` | cancelled |

**Update protocol**
1. Agent lands a change, sets the task `[?]`, fills the **Verify** column with exact commands, adds a Session log line.
2. Owner runs the commands, reports pass/fail (paste compiler output on failure).
3. Agent flips to `[x]` or `[!]` and records what was learned. Agent never sets `[x]` itself.
4. Decision changes: DECISIONS.md changelog. Interface/dependency/security changes: an ADR in `docs/adr/`.

**Standard verify commands** (owner side, cheapest first)

```bash
zig fmt --check src/                          # always
zig build check                               # type-check only, no codegen (after W-01 lands)
zig build test -Dtest-filter=<substr>         # only touched tests (after W-02 lands)
zig build test                                # full suite, once per phase before commit
```
Heavy checks (ReleaseSafe, size/startup budgets, kill-9, bench) run in CI: `gh run watch`.

---

## Current focus

1. **Owner: verify W-01, W-02, A-01** (all `[?]`; commands in their Verify cells).
2. **A-02** — Anthropic tool wire format (next to land once W-04's golden-test scaffold is agreed).
3. **W-04 / W-05** — golden-wire tests and config-key coverage.

---

## Phase W — Workflow prerequisites

| ID | Task | Status | Verify | Notes |
|---|---|---|---|---|
| W-01 | `zig build check` step: compile with no codegen | `[?]` | `zig build check` (expect: exits 0, no `zig-out/bin/ifnh` produced/updated); `zig build --help` lists `check` | `build.zig`: second `addExecutable` on the same module, never installed, so no bin is requested. If 0.16 rejects the API, paste the error |
| W-02 | `-Dtest-filter=<substr>` build option wired to test step `filters` | `[?]` | `zig build test -Dtest-filter=runTurn` (expect: only the engine `runTurn` tests run); `zig build test` still runs everything | `build.zig`: `b.option([]const []const u8, "test-filter", ...)` -> `.filters`. Repeatable flag. Tagging thread/subprocess tests `slow:` is still to do |
| W-03 | AGENTS.md verification rule (owner runs toolchain) + `[?]` legend + tracker pointer | `[?]` | read AGENTS.md | landed 2026-09-18 with this file |
| W-04 | Golden-wire test scaffold: `buildBody` snapshots + SSE byte fixtures, both adapters | `[ ]` | `zig build test -Dtest-filter=wire` | Prevents A-02-class regressions; pure functions, no network |
| W-05 | Config-key-coverage test: fails if a key in `default_config_json` is never read | `[ ]` | `zig build test -Dtest-filter=coverage` | Drives A-07 |

---

## Phase A — Correctness (P0: fix before any new feature)

| ID | Task | Status | Verify | Notes |
|---|---|---|---|---|
| A-01 | Stream assistant text: engine forwards `content_delta` to `on_text` | `[?]` | `zig fmt --check src/` · `zig build check` · `zig build test -Dtest-filter="runTurn executes scripted"` (new assertions: 2 text deltas, in order). **Manual smoke:** build, run `./zig-out/bin/ifnh`, send "hi": the reply must appear as it streams (before this fix it did not appear at all) | see F-A01. `engine.zig`: `Collector` now holds `Callbacks` and calls `on_text` per delta. Known limits: (1) a retry after a partially streamed reply will repeat the text on screen (fix in A-05); (2) `reasoning_delta` callback deferred: neither adapter emits reasoning events yet (E-01/D-05); (3) REPL writes each delta with its own syscall, fine now, revisit with C-07 |
| A-02 | Anthropic tools: neutral tool list, per-adapter wire render, merge tool_result blocks | `[ ]` | golden `buildBody` test (W-04); manual Anthropic tool round-trip | see F-A02 |
| A-03 | `bash`: always `sh -c` after classification; add `background` + `timeout_s`; honor `agents.timeout_tool_s` | `[ ]` | argv/quoting tests: `git commit -m "a b"`, `ls *.zig` | see F-A03 |
| A-04 | Persist tool-call assistant messages + tool results; paginate replay; warn on truncation | `[ ]` | session test: scripted tool turn, resume, history equal; `tests/integration-kill9.sh` | see F-A04 |
| A-05 | Transport errors become `.failure` events; parse `Retry-After`; connect/idle deadlines; roll back dangling user message | `[ ]` | adapter unit tests; manual: disconnect network mid-turn | see F-A05 |
| A-06 | SIGINT sets `cancel`; second Ctrl-C hard-exits; kill child process groups; Esc-to-stop | `[ ]` | manual: Ctrl-C mid-stream, mid-`bash sleep 60`; no orphan (`pgrep`) | see F-A06 |
| A-07 | Config keys: wire or delete each dead key; verify `git.push/force_push`, `read_dotenv` enforcement | `[ ]` | W-05 test; classifier test for `git push` with default config | see F-A07 |
| A-08 | `mcp_describe(server, tool)` returns input schema on demand | `[ ]` | mcp unit test; manual with a stdio server | see F-A08 |
| A-09 | Compaction cuts on turn boundaries only; threshold follows model window | `[ ]` | compaction test: tail never begins with orphan `tool` message | see F-A09 |
| A-10 | Resolve config-path inconsistency (USAGE vs code) | `[ ]` | decision in F-03 first | see F-A10 |

---

## Phase B — Performance ("blazing fast" where it counts)

Wall-clock in an agent harness is dominated by model round-trips and per-round overhead, not process startup (already ~5 ms per docs).

| ID | Task | Status | Verify | Notes |
|---|---|---|---|---|
| B-01 | Timing spans: `IFNH_TRACE_STARTUP=1`, per-round spans | `[ ]` | run with env var, read spans | Makes every later claim a number |
| B-02 | One long-lived HTTP client per session (keep-alive) | `[ ]` | before/after per-round latency via B-01 | Today: new `std.http.Client` per request (`anthropic.zig:31`, `openai.zig:36`); **[verify]** CA-bundle rescan cost |
| B-03 | Prompt caching + byte-stable system prompt | `[ ]` | usage shows cache hits on turn 2+ | System prompt rebuilt per turn with volatile focus dirs (`repl.zig:234-245`); no `cache_control` |
| B-04 | Cache per-turn overhead by mtime (config, instructions, git, skills, policy hash) | `[ ]` | B-01 spans per turn | |
| B-05 | Scratch arenas per tool call/turn; streaming grep | `[ ]` | peak RSS on a large repo (`/usr/bin/time -l`) | One process-lifetime arena today; `grepFile` reads up to 1 MB x 20k files |
| B-06 | Parallel read-only tool batches (`read`/`glob`/`grep`) | `[ ]` | engine test: ordered results; wall time | DESIGN §6 promises it |
| B-07 | Use `rg`/`fd` when present; better built-in fallback (.gitignore-aware, small regex subset) | `[ ]` | grep tests both paths | |
| B-08 | Early tool dispatch (emit `tool_call` as its block closes) | `[ ]` | adapter fixtures | |
| B-09 | Bench: interactive cold start, per-round overhead, peak RSS, TTFT; budgets in CI | `[ ]` | CI job | Today's gate measures `config validate`, not the interactive path |
| B-10 | Per-model `max_output_tokens` defaults | `[ ]` | golden body test | Anthropic hard-coded 4096 truncates edits |

---

## Phase C — Daily-driver UX

| ID | Task | Status | Verify | Notes |
|---|---|---|---|---|
| C-01 | Extract `core/agent/session_runtime.zig` from `repl.zig` (1,545 lines); remove module globals | `[ ]` | full `zig build test`; manual REPL smoke | Prerequisite for C-02 and E-06 |
| C-02 | Headless: `ifnh ask`/`-p`, `--json` NDJSON events, `--yes`/`--deny-all`/`--policy`, stdin, exit codes | `[ ]` | scripted `ifnh ask` in shell | fx parity |
| C-03 | Line editor: history, arrows, Ctrl-R, multiline, paste, Tab-complete, `@file`, `!cmd` | `[ ]` | manual | |
| C-04 | Live footer: model, context %, tokens, cost, elapsed | `[ ]` | manual | |
| C-05 | Approval previews (unified diff for edit/write) + "always for this project" grants in gitignored `.ifnh/permissions.local.json` | `[ ]` | manual; policy-hash test | Docs promise diffs; prompt shows only path (`repl.zig:538`) |
| C-06 | Cost tracking: price table as data file, `/usage` in dollars, `agents.budget_usd` circuit breaker | `[ ]` | unit test on budget stop | |
| C-07 | Streaming-safe markdown renderer, TTY-width wrap, light syntax highlight | `[ ]` | fixture tests + manual | |

---

## Phase D — Adaptability (differentiator vs fx)

| ID | Task | Status | Verify | Notes |
|---|---|---|---|---|
| D-01 | Tool registry replacing string-compare chain in `tool.zig:execute`; split per DESIGN | `[ ]` | full test | Enables D-02, per-role allowlists, MCP-as-tools |
| D-02 | Custom tools as data: `.ifnh/tools/*.json` (name, schema, command template, permission class) | `[ ]` | tool test + ADR | Biggest "ultra-adaptable" lever |
| D-03 | Named profiles (`--profile`) bundling model + permissions + tools + prompt fragments | `[ ]` | config tests | |
| D-04 | Wire `models.aliases/fallbacks` and `routing` | `[ ]` | routing tests | Keys exist, unread |
| D-05 | Per-model `provider_options` (thinking budget, reasoning effort) | `[ ]` | golden body test | Field exists, nothing fills it |
| D-06 | `ifnh config path|get|set|edit|schema`; publish JSON Schema; `--flag` per config key | `[ ]` | CLI tests | CLI layer "reserved" today |
| D-07 | Hooks: all 10 events, JSON payload on stdin, per-tool matchers, `before_tool` deny/rewrite, arrays | `[ ]` | hooks tests | Only before/after_agent dispatched, payload `{}` |
| D-08 | `/context` X-ray: tokens per source | `[ ]` | manual | |
| D-09 | `--trace` redacted wire log; `ifnh debug-bundle`; session export/replay | `[ ]` | redaction tests | DECISIONS S261 |
| D-10 | `edit` upgrades: atomic multi-edit, `replace_all`, whitespace-tolerant match | `[ ]` | edit tests | |

---

## Phase E — Breadth and hardening

| ID | Task | Status | Verify | Notes |
|---|---|---|---|---|
| E-01 | OpenAI Responses API adapter; Anthropic extended thinking; vision | `[ ]` | golden tests | |
| E-02 | Native Gemini adapter (Bedrock/Vertex later); subscription/OAuth login | `[ ]` | golden tests | |
| E-03 | MCP Streamable HTTP + per-agent allowlists | `[ ]` | mcp tests | |
| E-04 | OS sandbox for `bash`: macOS Seatbelt, Linux Landlock/bwrap | `[ ]` | adversarial tests | DECISIONS N192 |
| E-05 | Memory adapter; `/skills install` + lockfile | `[ ]` | | DECISIONS Q223-232 |
| E-06 | ACP/LSP-style server mode; `libifnh` embedding | `[ ]` | | needs C-01 |
| E-07 | Zig 0.17 compatibility (ST-1) | `[ ]` | | |
| E-08 | Docs reconciliation (README "pre-alpha", `<org>` placeholders, tracker overstated `[x]`) | `[ ]` | | |
| E-09 | Nightly / `workflow_dispatch` macOS arm64 CI job | `[ ]` | `gh run watch` | CI is ubuntu-only; owner runs macOS |

Non-goal kept: Windows.

---

## Phase F — Distribution (curl today; Homebrew, apt, snap, others next)

Starting point: `install.sh` fetches GitHub release artifacts (5 cross-compiled targets, static musl on Linux, sha256sums); `ifnh-uninstall.sh` sits beside the binary. Static, dependency-free binaries make every format below cheap. **Do not publish to package managers until Phase A lands** (F-01 to F-03 may proceed in parallel).

| ID | Task | Status | Verify | Notes |
|---|---|---|---|---|
| F-01 | Release hardening: stable artifact names (`ifnh-<ver>-<os>-<arch>.tar.gz`), sha256, signatures (minisign or cosign), SBOM, CI check that `version.zig` = `build.zig.zon` = git tag | `[ ]` | CI release dry run | All packages consume these artifacts |
| F-02 | Packaging surface: `ifnh completions bash|zsh|fish`, man page `ifnh.1`, `ifnh version --verbose` (commit, target, mode) | `[ ]` | run commands | |
| F-03 | **Decide config/state paths** (XDG vs macOS Library); migration note if changing | `[ ]` | decision recorded in DECISIONS.md | Must precede any publish; resolves A-10 |
| F-04 | Self-update policy: any `ifnh update` disabled for package-managed installs | `[ ]` | | Package manager owns upgrades/removal |
| F-05 | **Homebrew tap** `homebrew-ifnh`: binary formula per arch, completions, `test do`, auto-bump on release. homebrew-core later | `[ ]` | `brew install`/`brew test` on clean user | Owner is on macOS: first |
| F-06 | **`.deb` / `.rpm`** via nfpm from static musl tarballs (amd64+arm64) + GPG-signed apt repo (GitHub Pages or Cloudsmith/packagecloud) | `[ ]` | `apt install` in ubuntu + debian containers | PPA/Debian mainline need source builds; not worth it now |
| F-07 | **Snap**: `snapcraft.yaml`, **classic confinement** (strict breaks an agent that runs arbitrary commands), Snap Store review request | `[ ]` | `snap install --classic` | Last; review is outside our control |
| F-08 | Cheap extras: AUR `ifnh-bin`, Nix flake, asdf/mise via GitHub-release backend, OCI image (`FROM scratch`) | `[ ]` | | Need stable F-01 naming |
| F-09 | `install.sh`: detect package-managed install and refuse to overwrite; document that packages never touch project `.ifnh/` or `~/.config/ifnh` | `[ ]` | run installer on brew/apt host | |

Order: F-01/F-02/F-03 → F-05 (Homebrew) → F-06 (.deb/.rpm) → F-08 → F-07 (snap).

---

## Findings register (evidence)

**F-A01. Assistant text is never displayed. [read]**
`runTurn` never calls `callbacks.on_text`; `Collector.emit` (`src/core/agent/engine.zig:54`) only buffers deltas. The REPL passes `TurnUi.onText` (`src/cli/repl.zig:414`) but uses `outcome.reply` (line 432) only for the session store, never to print. `git log -S 'callbacks.on_text('` finds no call anywhere in history. Effect: no token streaming; prose appears not to render.
Fix: `Collector` holds `Callbacks`, forwards `content_delta` immediately, adds a `reasoning_delta` callback.

**F-A02. Anthropic tools sent in OpenAI shape. [read]**
`renderToolsJson` (`engine.zig:93`) always emits `{"type":"function","function":{...}}`; `anthropic.zig:255` writes it verbatim; Anthropic needs `{name, description, input_schema}` (`input_schema` appears only in MCP code). Expect HTTP 400 on every Anthropic request with tools. The capability probe (`probe.zig`) uses the same OpenAI shape.
Fix: engine hands providers a neutral tool list (DESIGN: "providers translate"); merge consecutive `tool_result` messages; never emit an empty content array.

**F-A03. `bash` mis-tokenizes quotes. [read]**
`toolBash` (`src/tools/tool.zig` ~L634) uses a shell only when the string contains `| ; & < > ( )` or a backtick; otherwise `tokenizeAny(" \t")`. `git commit -m "fix bug"` becomes argv `["git","commit","-m","\"fix","bug\""]`; `ls *.zig` and `grep "a b" f` also break. Schema omits `background`. Timeout hard-coded at 120 s (`tool.zig:569`) although `agents.timeout_tool_s` exists.

**F-A04. Session persistence drops tool traffic. [read]**
REPL appends only `user`, final `assistant` text, `note`, `interrupted` (`repl.zig:273/397/432/439/443`). Tool calls/results never stored though `rebuildHistory` (`repl.zig:562`) can read them: resume and fork lose tool context. `readEvents(..., 10_000)` silently truncates. `usage.jsonl` hand-appended (bypasses `fsutil`).

**F-A05. Transport errors abort with no retry. [read]**
Engine does `try provider.stream(...)`; a thrown error (`ConnectionRefused`, TLS, timeout) skips backoff, prints `turn failed: <ErrorName>`, leaves a dangling user message. No adapter parses `Retry-After` (`retry_after_s` is defined but never set by adapters). No connect/idle deadlines.

**F-A06. No interrupt. [read]**
`cancel` atomic exists but nothing sets it; no `sigaction`/SIGINT anywhere. Ctrl-C kills the process, possibly orphaning children/worktrees.

**F-A07. Config keys that do nothing. [read; enforcement of git keys: verify]**
Defined, not read by any `cfg.get*` in code traced: `agents.timeout_turn_s`, `agents.budget_*`, `git.commits/push/force_push`, `permissions.read_dotenv`, `planning.auto_call_threshold`, `sessions.dir`, `ui.symbols/verbosity`, `debug.*`, `routing.*`, `models.aliases/fallbacks`. Hooks: only `before_agent`/`after_agent` dispatched, payload `{}`. A safety key that silently does nothing is a security bug until proven wired (the command classifier may hard-code the same behaviour).

**F-A08. MCP tools undiscoverable. [read]**
`mcpListHook` (`repl.zig:611`) prints only `server.tool: description`; schema captured (`mcp.zig:18`) but never shown, so the model guesses arguments. Only stdio transport exists.

**F-A09. Compaction can orphan tool results. [verify]**
Last 2 messages always kept; if the tail starts with a `tool` message whose parent assistant tool_calls was summarized, both APIs reject the request. Threshold default 96k tokens regardless of model window.

**F-A10. Docs vs code disagree on config location. [read]**
`docs/USAGE.md` says macOS config lives in `~/Library/Application Support/ifnh/`; code reads skills/keys from `~/.config/ifnh` (`repl.zig:149`, `main.zig` doctor).

**Other observations (no task yet)**
- Fake HTTP server (M0-T21) never landed: adapters have zero wire-level tests, which is how F-A01/F-A02 escaped.
- DESIGN names modules that do not exist: `providers/transport.zig`, `ui/render.zig`, `ui/input.zig`, `core/lifecycle/`, `core/context/`.
- Approval prompt creates a fresh stdin reader per prompt (`repl.zig:543`); pasted multi-line input can be swallowed.
- Redaction is given only the active API key (`redactionsFor`); `redact.zig` has pattern rules (sk-, ghp_, AKIA, JWT) — extend to `env_allow` values and `.env` reads.
- No OS sandbox; classifier is heuristic. Test newline, `$(...)`, here-doc, `env`/`sh -c` wrappers.
- Confirm `~/.config/ifnh/env` is 0600 and never logged.
- Startup budget in CI measures `config validate`, not the interactive path.

---

## Decisions

**Resolved**
- Owner runs all Zig builds/tests; agent never runs `zig` (2026-09-18).
- Distribution targets: keep curl; add Homebrew, apt (.deb), snap, others (2026-09-18).

**Defaults in force unless changed**
1. `sh -c` for every bash command (over a quote-aware tokenizer).
2. Headless (C-02) before the line editor (C-03).
3. Custom tools as JSON data (D-02) ahead of MCP HTTP (E-03).
4. Use system `rg`/`fd` when present; built-in fallback stays.
5. Packaging order: Homebrew, then `.deb`/`.rpm`, then extras, then snap (classic).

**Open**
- F-03 config/state path convention (blocks A-10 and any publish).
- Signing tool for releases: minisign vs cosign (F-01).
- apt repo host: GitHub Pages vs Cloudsmith/packagecloud (F-06).

---

## Recommended sequence

W-01, W-02, W-04, W-05 → A-01 → A-02 → A-03 → A-04 → A-05 → A-06 → A-07/A-08/A-09/A-10 → F-01/F-02/F-03 (parallel) → B-01..B-10 → C-01, C-02, then rest of C → D → F-05/F-06 publish → E → F-08, F-07.

Why: W first so each owner verify cycle takes seconds; A removes defects that make everything else unmeasurable; B is the product promise; C-01/C-02 unlock scripting and ACP; D differentiates from fx for this audience; F is publish-gated on A.

---

## Session log

| Date | Entry |
|---|---|
| 2026-09-18 | Full static review of v0.1.7. Created this document. W-03 landed (AGENTS.md verification rule, MASTER_TRACKER pointer). No code changed; nothing built or run by the agent. |
| 2026-09-18 | Landed (awaiting owner verification, not compiled by agent): W-01 `check` step and W-02 `-Dtest-filter` in `build.zig`; A-01 live text streaming in `src/core/agent/engine.zig` (+ new assertions in the existing `runTurn executes scripted tool call...` test). Only two `runTurn` callers exist (REPL prints, subagent no-ops), so no other output changes. |
