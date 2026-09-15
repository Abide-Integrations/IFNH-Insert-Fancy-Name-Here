# IFNH — Technical Design

> **Status:** Authoritative implementation spec (v1, 2026-09-14)
> **Derives from:** PLAN.md (philosophy, D001–D049), DECISIONS.md (backlog resolution, meta-decisions M1–M4)
> **Reference:** Vercel Labs `fx` (architecture reference only — clean-room implementation, Meta-M2)
> **Language:** Zig 0.16.0 stable (M4); zero third-party dependencies

---

## 1. System shape

Single native binary. Composition root `src/main.zig` stays thin: it parses the subcommand, installs global I/O, wires concrete implementations into the core runtimes, and dispatches. All feature logic lives below it.

```text
                    ┌──────────────────────────┐
                    │  Developer (stdin/stdout)│
                    └────────────┬─────────────┘
                    ┌────────────▼─────────────┐
                    │  src/ui   streaming CLI  │  inline render, footer, input
                    │  src/cli  arg parsing    │  subcommands, --json output
                    └────────────┬─────────────┘
                    ┌────────────▼─────────────┐
                    │  src/core (no I/O policy)│
                    │  agent loop (turn engine)│
                    │  session store + journal │
                    │  permission engine       │
                    │  config (layered)        │
                    │  instructions assembler  │
                    └───────┬──────────┬───────┘
                  ┌─────────▼──┐   ┌───▼──────────────┐
                  │ src/tools  │   │ src/providers    │
                  │ tool kernel│   │ wire protocols   │
                  │ read/grep/ │   │ openai-compatible│
                  │ glob/edit/ │   │ anthropic        │
                  │ bash/git   │   │ std.http + SSE   │
                  └────────────┘   └──────────────────┘
           Extension boundary (M1+): skills, commands, MCP, hooks, memory
```

Layering rules (enforced by review, stated in AGENTS.md):

1. `core` never imports `ui` or `cli`.
2. `ui` never owns product state; it renders snapshots and feeds input events.
3. `providers` never absorb product logic; they translate the generic request/event model to wire formats.
4. `tools` implementations depend only on `core` contracts.
5. Anything expressible as Markdown/JSON on disk loads at runtime, not compile time (D063-style principle).

## 2. Repository layout

```text
ifnh/
├── build.zig                # single exe + test step; release size flags
├── build.zig.zon            # name ifnh, min zig 0.16.0, dependencies = .{}
├── src/
│   ├── main.zig             # composition root: argv, io install, DI wiring
│   ├── version.zig          # pub const version = "0.0.1";
│   ├── core/
│   │   ├── config/          # layered config load/merge/validate/explain
│   │   ├── session/         # session dirs, JSONL event log, resume, locks
│   │   ├── journal.zig      # undo journal (intent/apply/commit records)
│   │   ├── agent/           # turn engine, tool-call batching, budgets
│   │   ├── permissions/     # permission engine, path/command rules
│   │   ├── instructions/    # AGENTS.md/CLAUDE.md/.ifnh discovery + assembly
│   │   ├── lifecycle/       # lifecycle schema + stage runner (M2)
│   │   ├── context/         # assembly log, compaction pipeline (M1)
│   │   ├── fsutil.zig       # atomic durable write, realpath, safe ops
│   │   └── types.zig        # shared event/message/result types
│   ├── providers/
│   │   ├── provider.zig     # Provider contract (fn-pointer struct)
│   │   ├── transport.zig    # std.http wrapper, retries, deadlines
│   │   ├── sse.zig          # bounded SSE parser
│   │   ├── openai.zig       # OpenAI-compatible chat-completions adapter
│   │   └── anthropic.zig    # Anthropic messages adapter
│   ├── tools/
│   │   ├── tool.zig         # Tool contract + registry
│   │   ├── read.zig  glob.zig  grep.zig
│   │   ├── edit.zig  write.zig  bash.zig  git.zig
│   │   └── read_result.zig  # artifact retrieval (M1)
│   ├── ui/
│   │   ├── render.zig       # inline streaming renderer, ANSI subset
│   │   ├── input.zig        # raw mode, line editor, escape parsing
│   │   └── approval.zig     # approval prompt rendering
│   └── cli/
│       ├── args.zig         # subcommand/flag parsing
│       ├── commands.zig     # init, config, sessions, doctor, resume...
│       └── output.zig       # human + --json output contracts
├── tests/                   # integration tests (fake provider harness)
├── docs/
│   ├── adr/                 # architecture decision records
│   └── design.md → link
├── PLAN.md REMAINING_DECISIONS.md DECISIONS.md DESIGN.md MASTER_TRACKER.md
├── AGENTS.md LICENSE .gitignore
└── .github/workflows/ci.yml
```

Module import style: plain relative imports (no root re-export), one shared kernel `core/types.zig` + `core/fsutil.zig`. Tests are colocated `test` blocks plus a catch-all `test { _ = @import(...) }` set in `main.zig` (fx pattern) so `zig build test` needs no test-list maintenance.

## 3. Stable interfaces (day 1)

Six interfaces are frozen at M0; everything else is internal. All are plain structs of function pointers or data — no vtables.

### 3.1 Provider (`src/providers/provider.zig`)

```zig
pub const StreamEvent = union(enum) {
    content_delta: []const u8,
    reasoning_delta: []const u8,
    tool_call: ToolCall,          // id, name, arguments_json
    usage: Usage,                 // input_tokens, output_tokens
    done,
    failure: ProviderFailure,     // kind taxonomy + retry_after_s + message
};

pub const Provider = struct {
    ctx: ?*anyopaque = null,
    stream_fn: *const fn (ctx: ?*anyopaque, alloc: Allocator, io: std.Io,
        req: ModelRequest, sink: EventSink, cancel: *std.atomic.Value(bool)) anyerror!void,
    capabilities_fn: *const fn () Capabilities,
    list_models_fn: ?*const fn (alloc: Allocator, io: std.Io) anyerror![]ModelInfo = null,
};
```

`ModelRequest` carries: model id, assembled system prompt, bounded message history, tool schemas (JSON Schema subset), provider_options bag, deadline, credential lease (secret bytes zeroized after use). Providers serialize to their wire format, open the HTTP stream, parse SSE, and emit events through `EventSink` (context + emit fn). Retry/delivery-certainty accounting lives in `transport.zig`, not in adapters.

Two adapters at M0: `openai.zig` (generic `/chat/completions`, config-driven `base_url` — covers OpenRouter/Ollama/llama.cpp/Z.AI/custom) and `anthropic.zig` (`/v1/messages`).

### 3.2 Tool (`src/tools/tool.zig`)

```zig
pub const Tool = struct {
    name: []const u8,
    description: []const u8,
    input_schema: JsonSchema,               // subset: object/string/number/bool/array/enum
    executor_kind: enum { read, write, exec, git },
    call_fn: *const fn (ctx: *ToolContext, alloc: Allocator, io: std.Io,
        input: []const u8) anyerror!ToolResult,
};

pub const ToolResult = struct {
    output: []const u8,       // model-facing text (redacted, truncated)
    status: enum { ok, denied, failed, timeout },
    mutation: ?JournalGroup,  // populated by write/exec tools; drives undo
};
```

M0 tool kernel (D037): `read`, `glob`, `grep`, `edit` (exact old/new replacement with context hash check), `write` (create/replace), `bash`, `git`. `edit`/`write`/`bash` produce `JournalGroup` entries. Tools decode their JSON input with `std.json`, validate, execute under the caller's checked paths, and return bounded output (64 KiB cap, UTF-8-safe, marker).

### 3.3 PermissionEngine (`src/core/permissions/engine.zig`)

```zig
pub const Decision = enum { allow, ask, deny };

pub const Request = union(enum) {
    tool: struct { tool: []const u8 },
    path: struct { access: enum { read, write }, path: []const u8 },
    command: struct { argv: [][]const u8, compound: ?ShellPipeline },
    mcp: struct { server: []const u8, tool: []const u8 },   // M1
    env: struct { name: []const u8 },
};

pub fn decide(self: *Engine, req: Request, scope: Scope) Decision;
```

Rules evaluate deny → ask → allow (deny wins), path rules match realpath-resolved globs, command rules run the lexer classifier first (destructive lexicon + write-effect heuristics) then prefix/pattern grants. `decide` is pure and table-driven for testability. Approval results (`once | session | pattern`) feed back as session grants. `.ifnh/` policy paths carry an implicit agent-write-deny rule. Fail-closed on malformed rules (DECISIONS H20).

### 3.4 SessionStore (`src/core/session/`)

```zig
// One session = one directory: .ifnh/sessions/<id>/
//   manifest.json    {schema_version, id, alias, created, cwd, parent_id?, config_snapshot_hash}
//   events.jsonl     append-only event log (watermarked)
//   journal.jsonl    undo journal (tool-call groups)
//   checkpoint.json  latest checkpoint (M1)
//   usage.jsonl      per-agent usage records (M1)
//   session.lock     advisory flock
```

Event record: `{"seq": u64, "ts": iso8601, "event": <union>}` where event ∈ `user | assistant | tool_call | tool_result | context_checkpoint | lifecycle_state | fork_point | interrupted`. Resume = read manifest → verify watermark → replay bounded events → rebuild UI projection. Writes: append (O_APPEND) + periodic watermark into manifest via atomic replace; crash recovery replays or rolls back incomplete journal groups (A14).

### 3.5 Config (`src/core/config/`)

Layered JSON. Load order low → high: built-in defaults → user (`~/.config/ifnh/config.json`) → project (`.ifnh/config.json` + `.ifnh/config.d/*.json`) → session → env (`IFNH_*__*`) → CLI flags. Every key records its winning source (path + layer) for `ifnh config explain`. Precedence helper is a generic deep-merge over `std.json.Value` with source tracking. Security sections fail closed on invalid input.

Schema v1 (see §4 for the full tree) — `schema_version: 1` required; unknown keys warn.

### 3.6 Journal (`src/core/journal.zig`)

```zig
pub const Entry = union(enum) {
    intent:  { group_id: u64, ops: []FileOp, ts },   // written before apply
    commit:  { group_id: u64 },                       // written after apply
};
pub const FileOp = union(enum) {
    write:   { path, inverse_patch: Patch, content_hash_before, content_hash_after },
    create:  { path },                                // undo = delete
    delete:  { path, bounded_before_image },          // bounded size
};
```

`/undo` walks committed groups newest-first, applies inverse ops, marks them undone (append `undo` record); `/redo` replays. Non-reversible ops never enter the journal — they are refused at the approval gate instead (M185-188).

## 4. Config schema v1

```jsonc
{
  "schema_version": 1,
  "model": {                       // default provider/model
    "provider": "openai",          // openai | anthropic
    "model": "claude-sonnet-4-6",
    "base_url": null,              // OpenAI-compatible override (Ollama etc.)
    "api_key_env": "OPENAI_API_KEY",
    "temperature": null,
    "max_output_tokens": null
  },
  "models": {
    "aliases": {                   // DECISIONS D44
      "fast":     { "provider": "openai", "model": "..." },
      "reasoning":{ "provider": "anthropic", "model": "..." }
    },
    "fallbacks": {}                // alias -> [alias], off by default (D49)
  },
  "routing": { "parent": "default", "research": "fast",
               "implement": "default", "review": "default" },
  "permissions": {
    "default_mode": "ask",         // ask | auto   (auto = read allow, write ask)
    "read":  ["**"],
    "write": [],
    "command_allow": [],           // prefix patterns after classification
    "command_deny": [],
    "env_allow": [],               // env vars agents may see
    "read_dotenv": false
  },
  "git": { "commits": "ask", "push": "never", "force_push": "never" },
  "agents": {
    "max_depth": 1, "max_concurrent": 4,
    "timeout_tool_s": 120, "timeout_turn_s": 600,
    "budget_usd": null, "budget_tokens": null
  },
  "context": {
    "auto_compact": true, "compact_at_fraction": 0.8,
    "max_file_read_bytes": 262144
  },
  "planning": { "auto_call_threshold": 12 },
  "tests": { "sandbox": "local", "fast": [], "full": [] },
  "sessions": { "dir": "project", "keep": 30, "checkpoints_keep": 20 },
  "mcp_servers": {},               // M1
  "hooks": {},                     // M1
  "lifecycle": null,               // M2: path to lifecycle file
  "ui": { "colors": true, "symbols": "unicode", "verbosity": "normal" },
  "debug": { "level": "info", "dir": null, "redact": true }
}
```

All of it optional — zero-config runs on env credentials + defaults (D048). `IFNH_MODEL=anthropic/claude-...` style env and `IFNH_PERMISSIONS__DEFAULT_MODE=auto` nesting both work.

## 5. `.ifnh/` layout v1

```text
.ifnh/
├── config.json          # committed
├── config.d/            # committed (merge order)
├── .gitignore           # written/maintained by IFNH
├── instructions/        # committed, *.md, loaded in precedence
├── skills/              # committed, SKILL.md dirs (M1)
├── commands/            # committed, *.md slash commands (M1)
├── lifecycle/           # committed, *.json lifecycles (M2)
├── tool-notes/          # committed, per-CLI instruction notes (M1)
├── plans/               # committed-optional, plan artifacts
├── reports/             # gitignored by default, agent reports (M1)
├── sessions/            # gitignored — session state (this repo's runtime data)
├── cache/               # gitignored
└── debug/               # gitignored, opt-in logs
```

## 6. Agent turn engine (M0 core loop)

```text
user prompt
  → instructions assembler (§C rules) + bounded repo context
  → provider.stream(request)
  → accumulate deltas; on tool_call batch:
      → permission engine decide() each call (batch: parallel if all read-only)
      → ask → approval UI → grant/deny recorded
      → execute via tool registry (JournalGroup capture)
      → append tool_result events (bounded output)
  → loop until no tool calls or budget/timeout/interrupt
  → session event log + journal updated throughout
```

Concurrency: one UI thread + one agent loop thread (M0); tool batches parallelize read-only groups on `std.Thread` with per-call arenas (M1 for subagents; the batch machinery lands in M0).

## 7. Performance budgets

| Metric | Budget | Enforcement |
|---|---|---|
| Interactive cold start (to prompt-ready) | < 50 ms | benchmark script + CI (M2) |
| Non-interactive subcommand | < 5 ms | benchmark script + CI (M2) |
| Binary size (stripped, ReleaseSafe) | < 5 MiB | CI size check (M2) |
| Idle memory | < 30 MB | manual/bench |
| Per child agent | < 10 MB + 1 thread | M1 |

Build flags (fx-proven): `link_libc`, strip in all non-Debug modes, `omit_frame_pointer`, no unwind tables, no stack protector in ReleaseFast. FixedBufferAllocator for help/CLI fast paths; lazy creation of threaded I/O.

## 8. Testing strategy

1. **Colocated unit tests** (zig `test` blocks) for every contract: config merge/precedence, permission decisions (table-driven), diff apply/staleness, SSE parser (byte-stream fixtures), journal undo/redo, session watermark/replay.
2. **Fake provider** (`tests/fake_provider.zig`): in-process scripted `Provider` emitting deterministic content/tool-call/usage events — the deterministic harness for agent-loop tests, no network.
3. **Fake HTTP server** (`tests/fake_server.zig`): `std.net` listener speaking canned OpenAI/Anthropic responses for adapter tests (fx fake-gateway pattern).
4. **Integration tests** (`tests/`): e2e tool loop with fake provider (prompt → edit → test → report); kill -9 mid-turn → resume; undo after crash; permission denial paths; `ifnh init` in a temp dir.
5. **No live-API tests in CI.** Provider smoke tests are manual, opt-in via env.

## 9. Threat model summary (enforcement points)

| Threat | Enforcement |
|---|---|
| Malicious repo instructions (AGENTS.md/skills/docs) | Untrusted-input framing; provenance in approvals; permission gates are the real boundary |
| Prompt injection via tool output | Outputs framed as data; injection patterns flagged; dangerous ops always gated |
| Agent writes outside scope | Path grants + realpath resolution + journal-verified mutations; `.ifnh/` write-denied |
| Destructive shell | Lexicon + heuristics → ask; unknown write-ish → ask; pipeline intersection |
| Secret leakage | Env allowlist; redaction at write time; `.env` unreadable by default; zeroized credentials |
| Policy tampering | `.ifnh/` agent-write-deny + config snapshot hash checked at approval boundaries |
| Runaway delegation | Depth/concurrency/budget caps + cycle detection (M1) |

## 10. Milestone mapping

- **M0** — §3 interfaces, config layering, session store, journal/undo, tool kernel, permission engine, turn engine, inline UI, `init`/`config`/`sessions`/`resume` CLI, dirty-tree protection, merge gate (whole-diff).
- **M1** — subagents (threads + captured authority), worktrees, MCP client, skills, hooks, compaction, usage tracking, background executions, doctor.
- **M2** — lifecycle engine, review gates (multi-reviewer), forks, cleanup, CI budgets, go-public checklist.
- **Post** — per DECISIONS `[post]` tags.
