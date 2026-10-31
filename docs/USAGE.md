# IFNH Usage Guide

Everything you need to run, configure, and live in IFNH. Philosophy and
decisions live in PLAN.md/DECISIONS.md; architecture in DESIGN.md.

---

## 1. Build

Requires [Zig 0.16.0](https://ziglang.org/download/). No other toolchain.

```bash
zig build -Doptimize=ReleaseSafe     # -> zig-out/bin/ifnh (~1.7 MiB)
zig build test                       # unit tests
./scripts/bench.sh                   # verify size, startup, TTFT, per-round overhead, RSS budgets
```

Cross-compiling for distribution (any target, from any host):

```bash
zig build -Doptimize=ReleaseSafe -Dtarget=x86_64-linux-gnu
zig build -Doptimize=ReleaseSafe -Dtarget=aarch64-linux-gnu
zig build -Doptimize=ReleaseSafe -Dtarget=x86_64-linux-musl   # static
```

## 2. First run

```bash
cd your/project
ifnh init                 # optional: creates .ifnh/ skeleton (never overwrites)
export ANTHROPIC_API_KEY=sk-ant-...   # or OPENAI_API_KEY
ifnh doctor               # verifies config, key, git, MCP, state dirs
```

`ifnh doctor` tells you exactly what is missing. The two things it needs:

1. **A model** — `.ifnh/config.json`:
   ```json
   { "schema_version": 1,
     "model": { "provider": "anthropic", "model": "claude-sonnet-4-6" } }
   ```
   or the environment: `export IFNH_MODEL__MODEL="claude-sonnet-4-6"`
2. **A key** — `ANTHROPIC_API_KEY` / `OPENAI_API_KEY`, or any env var you
   name in `model.api_key_env`.

Then:

```bash
ifnh                      # interactive session in the current directory
```

## 3. Using the REPL

Type naturally; the agent reads, edits, runs, and delegates — asking you
when policy says so.

```
> explain what src/core/journal.zig does
> fix the failing test in tests/foo.zig and run the suite
> delegate: have a research agent map the auth flow
```

Approvals look like:

```
approval needed: run command
  mkdir -p build
[y] once  [s] session  [n] no:
```

File writes and edits show a unified diff of the change first (new files show
all lines as additions; output is cut at 40 lines / 4 KiB) and add a fourth
answer:

```
approval needed: write file
  src/a.zig
    --- a/src/a.zig
    +++ b/src/a.zig
    @@ -1,2 +1,2 @@
     const x = 1;
    -const y = 2;
    +const y = 3;
  (p saves this grant to .ifnh/permissions.local.json)
[y] once  [s] session  [p] always for this project  [n] no:
```

`p` allows writes to exactly that path from now on, in this and later
sessions of this project. It is stored in `.ifnh/permissions.local.json`
(`{"version":1,"command_prefix":[...],"path_write":[...]}`), which IFNH adds to
`.ifnh/.gitignore`: grants belong to you, not to the repository. A grant only
turns a prompt into a yes. Protected paths (`.ifnh/config.json`, instructions,
`AGENTS.md`, and the grants file itself), deny rules and the `git.*` ceilings
still win, and agents cannot write the file. Delete a line, or the file, to
revoke. An unreadable file is reported at startup, ignored, and never
overwritten (answering `p` then only lasts for the session). `p` is offered for
file writes only, not for commands or MCP calls.

### Line editor

On a terminal (stdin and stderr are TTYs and `TERM` is not `dumb`) the prompt is
a line editor. Piped input, `TERM=dumb` and `ifnh ask` use plain line reading
and none of this applies.

| Keys | Effect |
|---|---|
| Left / Right, Ctrl-B / Ctrl-F | move by character |
| Home / End, Ctrl-A / Ctrl-E | start / end of the current line |
| Backspace, Delete | delete before / under the cursor |
| Ctrl-K / Ctrl-U / Ctrl-W | kill to end of line / to start of line / previous word |
| Ctrl-L | clear the screen and redraw |
| Up / Down | history; the line you were typing comes back after the newest entry |
| Ctrl-R | incremental reverse search; Ctrl-R again goes further back, Enter accepts the match into the line, Ctrl-C or ESC restores what you had |
| Alt+Enter, or a trailing `\` then Enter | new line in the same message (the backslash is removed); a plain Enter sends everything |
| Tab | `/command` names (first word) and `@path` files; one match completes, several list and complete the common prefix |
| Ctrl-D | on an empty line, end the session |
| Ctrl-C | on a non-empty line, clear it; on an empty line, exit with status 130 |

Pasting is safe: terminals that support bracketed paste insert the text
verbatim (nothing in it is treated as a key; control bytes are dropped). Without
it, text arriving in one burst with a newline inside is inserted as lines
instead of being sent. A lone ESC is recognised after a 50 ms pause.

History lives in `~/.local/state/ifnh/history` (mode 0600), 500 entries, with
consecutive duplicates collapsed. Blank lines and `/provider key ...` (which
carries a secret) are not recorded.

`@path` attaches a file: `explain @src/main.zig` sends the text with the file
appended as `<file path="src/main.zig">...</file>`. A word is a file mention
only if it starts with `@` and contains `/` or `.` or names an existing file
(`@alice` and a bare `@` are left alone). Files are cut at
`context.max_file_read_bytes` with `... (truncated)`. A missing, binary or
directory mention prints `cannot attach <path>: <reason>` and nothing is sent.
The file contents go to the model provider like the rest of your message, and
the read is yours, not the agent's: `permissions.read` and `read_dotenv` do not
apply, so do not `@` a secrets file. Completion skips `.git`, build output and
dot-files, never leaves the project and reads one directory at a time.

`!cmd` runs a shell command yourself: `!git status`, `!zig build 2>&1 | tail`.
It runs under `/bin/sh -c` in the project directory with the bash tool's
timeout (`agents.timeout_tool_s`) and Ctrl-C handling, prints the output and an
exit line, asks no approval, and is never sent to the model or recorded as a
message. A multi-line buffer starting with `!` runs as one script.

### Status footer

After each turn (and between tool calls) a dim line is drawn on **stderr**:

```
claude-sonnet-4-6 | ctx 25% (24000/96000) | ↑1200 ↓345 | $0.0123 | 4.5s
```

`ctx` is the last request's prompt plus output tokens over
`context.max_context_tokens` (`ctx ?%` when that is not set). `↑`/`↓` and the
cost are session totals; cost is `n/a` for a model without a price (see
`/usage`), and `$0.00` under a tenth of a cent. The time is the wall time of
the turn. The footer is erased before any other output, so it never mixes
into streamed text. It is off with `ui.footer: false`, and absent when stderr
is not a terminal or `TERM` is `dumb`: then nothing at all is written.

### Slash commands

| Command | Effect |
|---|---|
| `/help` | command list |
| `/model <name>` | switch model for this session |
| `/config` | show resolved configuration |
| `/context` | show assembled instructions + sources |
| `/undo` / `/redo` | step the file-mutation journal (works across restarts) |
| `/diff` | git diff of the working tree |
| `/plan <title>` | create a plan artifact in `.ifnh/plans/` |
| `/sessions` | list sessions |
| `/agents` | subagent reports |
| `/skills` | installed skills |
| `/mcp` | MCP servers/tools |
| `/exec` | background executions |
| `/usage` | session token and dollar totals, with the budget and a per-model line when several models were used |
| `/compact` | force context compaction |
| `/lifecycle run <file.json> [--from <n>]` | run a lifecycle |
| `/review override <reason>` | developer-only override of a blocked review (audited) |
| `/reconcile <path>` | reconciliation agent for conflicting edits |
| `/quit` | exit |

Custom commands: drop a Markdown file into `.ifnh/commands/<name>.md`
(optional `---` frontmatter); `$ARGS` in the body is replaced by what you
type after the command.

## 4. Headless: `ifnh ask`

`ask` runs exactly one turn, prints the assistant text, and exits. It never
starts the REPL.

```bash
ifnh ask "summarise src/core/journal.zig"
ifnh ask -p "same prompt"          # -p also works before: ifnh -p "same prompt"
printf 'summarise this' | ifnh ask
ifnh ask -                         # explicit stdin
```

The positional prompt and `-p` are equivalent; give at most one. With no
prompt (or `-`), the whole of stdin is read until EOF. Trailing newlines are
trimmed. An empty or whitespace-only prompt is a usage error (exit 2).

Plain mode writes only assistant text to stdout; diagnostics go to stderr.
`--json` (global or after `ask`) writes NDJSON to stdout and nothing else, with
no styling or ANSI escapes.

### Approvals

| Flag | Effect |
|---|---|
| `--yes` | approve every permission ask as `approved_once` |
| `--deny-all` | deny every permission ask |
| `--policy ask` | prompt on `/dev/tty` when stdin is a TTY; otherwise deny (default) |
| `--policy allow` | approve every permission ask (same as `--yes`) |
| `--policy deny` | deny every permission ask (same as `--deny-all`) |

`--yes`, `--deny-all` and `--policy` are mutually exclusive; more than one is
a usage error. Approvals are never read from stdin, because stdin may carry the
prompt. A piped prompt with the default `--policy ask` therefore fails closed.

### NDJSON events (`--json`)

One object per line, no pretty printing, no carriage returns, no trailing
commas. Every run emits exactly one `start` and one final `end`:

```json
{"type":"start","session":"s_abc123","model":"claude-sonnet-4-6"}
{"type":"text","text":"Let me read that file."}
{"type":"tool","name":"read","phase":"start"}
{"type":"tool","name":"read","phase":"end","ok":true}
{"type":"approval","tool":"bash","detail":"touch .ifnh/out.txt","decision":"approved_once"}
{"type":"error","message":"provider error: boom"}
{"type":"end","status":"failed"}
```

- `text` appears once per streamed assistant delta.
- `tool` emits a `start` and `end` pair; `ok` is false for denied or failed calls.
- `approval` records `approved_once`, `approved_session` or `denied`.
- `error` appears only on failure, before `end`.
- `end.status` is `ok`, `failed`, `denied` or `interrupted`.

### Exit codes

| Code | Meaning |
|---|---|
| 0 | success: the turn completed with no denial |
| 1 | failure: provider error, tool error that ended the turn, or other turn failure |
| 2 | usage error: unknown flag, bad/missing flag value, missing/empty prompt, bad `--policy`, conflicting approval flags |
| 3 | denied: at least one tool call was denied during the turn (includes `--deny-all`) |
| 4 | budget: `agents.budget_usd` was already spent, so the turn was refused before any request (nothing was spent) |
| 130 | interrupted: SIGINT during the turn (the interrupted outcome is emitted first) |

When several apply, precedence is `130 > 4 > 1 > 3 > 0`. `ask` always starts a
new session, so the budget check can only trip there when the budget is `0`
(spend nothing); in the REPL it trips once the session's spend reaches the
budget.

## 5. Configuration

Precedence (low to high): **built-in defaults < user < project < session <
env < CLI**. Inspect any key:

```bash
ifnh config explain model.model
ifnh config validate
```

- **User config:** `$XDG_CONFIG_HOME/ifnh/config.json` when `XDG_CONFIG_HOME`
  is set, otherwise `~/.config/ifnh/config.json` — the same on Linux and
  macOS (there is no `~/Library/Application Support` variant). User skills
  and the stored API keys (`env`) live in that same directory. Logs and
  transient state live under `~/.local/state/ifnh/`.
- **Project config:** `.ifnh/config.json` (+ `.ifnh/config.d/*.json` merged
  alphabetically)
- **Env:** `IFNH_<SECTION>__<KEY>` — `IFNH_PERMISSIONS__DEFAULT_MODE=auto`

The full annotated default lives in `src/core/config/config.zig`
(`default_config_json`). Common overrides:

```jsonc
{
  "schema_version": 1,
  "model": {
    "provider": "openai",          // "openai" = any OpenAI-compatible API
    "model": "qwen3-coder",
    "base_url": "http://localhost:11434/v1",   // Ollama, llama.cpp, vLLM...
    "api_key_env": "OLLAMA_KEY"    // optional for local servers
  },
  "permissions": {
    "default_mode": "ask",         // "auto" = reads run free, writes still ask
    "read": ["**"],
    "write": ["src/**", "tests/**"],   // matching writes skip the prompt
    "command_allow": ["zig build", "zig test", "npm test"],
    "command_deny": ["cargo"],
    "env_allow": ["GITHUB_TOKEN"]  // env vars agents may see
  },
  "git": { "commits": "ask", "push": "never", "force_push": "never" },
  "agents": { "max_depth": 1, "max_concurrent": 4, "budget_usd": 5.0 },
  "ui": { "colors": true, "footer": true }
}
```

`agents.budget_usd` (default `null`, no limit) is a circuit breaker on the
dollar cost of a session. Costs come from the price table embedded in the
binary (`src/providers/pricing.json`: list prices per million tokens for
Anthropic Claude and OpenAI GPT/o-series, matched by model id prefix); models
without an entry are unpriced, count as $0 and show `n/a`, so the budget cannot
protect you with them. Before each turn the REPL checks the spend so far; once
it has reached the budget it prints `[budget] $X of $B spent; raise
agents.budget_usd or /usage to inspect` and stays at the prompt (slash commands
still work). The check is per turn: the turn that crosses the line completes,
and subagent spend is not counted yet. `ui.footer` switches the status footer.

`NO_COLOR` / `--no-color` disable styling.

## 6. What the agent can do (tool kernel)

`read` `glob` `grep` `edit` `write` `bash` `git` — plus:

- **`agent`** — delegate to a child agent:
  roles `research` (read-only), `implement` (edits), `review` (findings);
  `isolation: "worktree"` puts the child in its own git worktree on branch
  `ifnh/<session>/<agent>` (main workspace untouched). Depth and
  concurrency are budgeted (`agents.*`). Full reports land in
  `.ifnh/reports/`.
- **`bash` with `background: true`** — long commands return an execution
  handle; poll with the `exec` tool or `/exec` (status/output/stop).
- **`skill`** — load installed skills (see below).
- **`mcp_list` / `mcp_call`** — MCP servers (see below).
- **`read_tool_result`** — page through oversized outputs stored as
  artifacts.

Policies in this section are enforced by the permission engine, never by
the model's judgment. `.ifnh/` policy files are agent-write-denied; a
mid-session policy change fails approvals closed.

## 7. Sessions, undo, forks

- Everything is event-sourced under `.ifnh/sessions/<id>/`
  (`events.jsonl`, `journal.jsonl`, `usage.jsonl`).
- `/undo` reverts agent file mutations (before-images live in the
  journal; crash recovery rolls back incomplete groups on next start).
- `ifnh resume <id>` continues a session; `ifnh sessions list --json`;
  `ifnh fork <id>` branches from the current state; `ifnh fork diff <a> <b>`
  compares; `ifnh cleanup [--yes]` enforces `sessions.keep` retention.

## 8. MCP

```jsonc
{
  "mcp_servers": {
    "docs": {
      "command": "npx", "args": ["-y", "@modelcontextprotocol/server-filesystem", "."],
      "env": { "API_KEY_ENV_NAME": "..." }
    }
  }
}
```

Servers spawn lazily on first use and are killed at session end. Tool
calls pass the permission engine (`mcp.<server>.<tool>`, default ask).
Inspect with `/mcp`; the agent uses `mcp_list`/`mcp_call`.

## 9. Skills

Agent Skills format (`SKILL.md` with `name`/`description` frontmatter):

- Project: `.ifnh/skills/<name>/SKILL.md` (highest precedence)
- User: `~/.config/ifnh/skills/` (or `$XDG_CONFIG_HOME/ifnh/skills/`)
- Compat (read-only): `.claude/skills/`, `.agents/skills/`

The agent sees a budgeted catalog each turn and loads bodies with the
`skill` tool. First-party examples ship in this repo under `skills/`
(reconnaissance, create-skill) — copy them into a skills directory to use.

## 10. Hooks

```jsonc
{ "hooks": {
    "before_agent": "echo starting | tee -a .ifnh/hook.log",
    "after_agent":  "zig build test"     // non-zero exit BLOCKS before_* only
} }
```

Events: `session_start/end`, `before/after_tool`, `before/after_agent`,
`before/after_merge`. `before_*` hooks block on non-zero exit; everything
runs under `/bin/sh` with a 30s timeout.

## 11. Lifecycles

```jsonc
// .ifnh/lifecycle/ship.json
{ "name": "ship",
  "stages": [
    { "name": "research",  "role": "research",  "instructions": "survey the repo" },
    { "name": "implement", "role": "implement", "instructions": "build the feature",
      "review": true, "reviewers": 2, "review_policy": "n_of_m", "review_threshold": 2 },
    { "name": "ship",      "role": "implement", "instructions": "finalize",
      "approval": "human" }
  ] }
```

Run with `/lifecycle run .ifnh/lifecycle/ship.json` (resume with
`--from <stage-index>`). Failed reviews stop the pipeline (D008); only
`/review override <reason>` — recorded as an audit artifact — bypasses.

## 12. Observability

- `ifnh doctor` — environment health.
- `/usage` — session token totals; per-turn records in the session dir.
- Logs: `--log-level err|info|debug|trace` (debug/trace redact secrets at
  write time).

## 13. Distribution

One-liner (after the repo is on GitHub and a tag is released):

```bash
curl -fsSL https://raw.githubusercontent.com/<org>/ifnh/main/install.sh | sh
```

The root `install.sh` detects platform, prefers static musl builds on
Linux, verifies sha256 when available, installs to `~/.local/bin`, and
warns if that directory is not on your PATH. Set `IFNH_PREFIX` to install
elsewhere, `IFNH_VERSION=v0.1.0` to pin a version.

Uninstall (k3s-style — the installer drops a companion script next to the
binary):

```bash
ifnh-uninstall.sh           # remove binary + runtime state (keeps config + API keys)
ifnh-uninstall.sh --purge   # also delete ~/.config/ifnh (config + keys)
```

Project-local `.ifnh/` directories are never touched by the uninstaller.

A hosted copy works too:

```bash
curl -fsSL https://raw.githubusercontent.com/<org>/ifnh/main/uninstall.sh | sh
```

CI is deliberately lean: `ci.yml` runs on ubuntu only (auto-cancel,
docs-only changes skipped) — fmt, tests, ReleaseSafe build,
`scripts/bench.sh` budgets (size, startup, interactive cold start, TTFT,
per-round overhead, peak RSS), integration harnesses. `release.yml` builds all five
release targets cross-compiled on one ubuntu runner and attaches them to
the GitHub release with sha256sums. For a single machine:

```bash
zig build -Doptimize=ReleaseSafe && scripts/install.sh
```

## 14. Project layout inside `.ifnh/`

```
.ifnh/
├── config.json          # committed — project policy
├── config.d/            # committed — split config
├── instructions/        # committed — extra project instructions
├── commands/            # committed — custom slash commands
├── skills/              # committed — project skills
├── lifecycle/           # committed — lifecycle definitions
├── tool-notes/          # committed — per-CLI guidance for agents
├── plans/               # plan artifacts
├── reports/             # agent reports (gitignored by default)
├── permissions.local.json  # your "always for this project" grants (gitignored)
├── sessions/            # session state (gitignored)
├── cache/               # artifacts, background-execution logs (gitignored)
└── .gitignore           # written by IFNH
```
