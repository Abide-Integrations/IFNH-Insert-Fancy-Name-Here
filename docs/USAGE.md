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
export ANTHROPIC_API_KEY=sk-ant-...   # or OPENAI_API_KEY / GEMINI_API_KEY
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
| `/context` | context x-ray: bytes and estimated tokens per source (`--json` for machines) |
| `/undo` / `/redo` | step the file-mutation journal (works across restarts) |
| `/diff` | git diff of the working tree |
| `/plan <title>` | create a plan artifact in `.ifnh/plans/` |
| `/sessions` | list sessions |
| `/agents` | subagent reports |
| `/skills` | installed skills |
| `/mcp` | MCP servers/tools |
| `/memory` | memory scope, entry count and the newest notes (`/memory purge` deletes them, after approval) |
| `/exec` | background executions |
| `/usage` | session token and dollar totals, with the budget and a per-model line when several models were used |
| `/compact` | force context compaction |
| `/image <path>` | attach an image to the next message (`/image` = queued count, `/image clear`) |
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

`--image <path>` attaches an image to the prompt (see "Images" in section 5;
repeatable, up to 8). An unsupported type, a file over 5 MiB or an unreadable
path is reported on stderr before anything runs, with exit 2.

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
ifnh config explain model.model   # value, layer and source file
ifnh config get model.model       # value only (script-friendly)
ifnh config get ui.footer --json  # {"key","value","layer","source"}
ifnh config path                  # user + project config paths
ifnh config schema                # the published JSON Schema
ifnh config validate
```

Edit without hand-editing JSON:

```bash
ifnh config set model.model gpt-5                 # project: .ifnh/config.json
ifnh config set ui.footer false --global          # user config
ifnh config set model.temperature 0.3 --json
ifnh config edit                                  # $VISUAL / $EDITOR / vi
```

Values parse as JSON when they can (`false`, `0.3`, `["a"]`) and are stored as
strings otherwise, so bare words work. `set` validates the whole file against
the schema before writing and refuses on any error (`not written`), so a typo
cannot break the next startup. `--global`/`--project` pick the file; the
default is the project config. The schema itself lives in
`docs/config.schema.json` and is embedded in the binary, so
`ifnh config schema` always matches the defaults.

Per-key flags are CLI-layer overrides, applied after `--profile`, so they win
over everything:

```bash
ifnh --model qwen3-coder --temperature 0.2
ifnh --provider anthropic --base-url https://example.test/v1
ifnh --max-output-tokens 4096 --context-tokens 200000
ifnh --permission-mode auto --no-footer
ifnh --model m config get model.model   # shows layer: cli, source: --model
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
    "provider": "openai",          // "openai" = any OpenAI-compatible API (Chat Completions)
                                   // "openai-responses" = OpenAI Responses API; "anthropic" = Messages;
                                   // "gemini" = Google Gemini (generateContent)
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

### Profiles, aliases and routing

`--profile <name>` (a global flag, so it goes before the subcommand) merges
`profiles.<name>` over the loaded config as the highest layer below session
overrides, and appends its `prompt` text to the system prompt:

```bash
ifnh --profile offline            # REPL with the profile applied
ifnh --profile offline ask -p "hi"
```

```jsonc
{
  "profiles": {
    "offline": {
      "model": { "provider": "openai", "base_url": "http://127.0.0.1:11434/v1" },
      "permissions": { "default_mode": "auto" },
      "prompt": "This machine has no network access."
    }
  }
}
```

An unknown name is a startup error (`unknown profile 'x'; known profiles: a, b`)
with exit code 2; `/model` still wins over a profile. A profile may set any
config key, including `models` and `routing` — the merged result is validated
the same way a hand-written config is.

Model aliases name a provider/model pair once and reuse it:

```jsonc
{
  "models": {
    "aliases": {
      "fast": { "provider": "openai", "model": "gpt-5-mini",
                "provider_options": { "reasoning_effort": "low" } },
      "deep": { "provider": "anthropic", "model": "claude-opus-4-1",
                "provider_options": { "thinking": { "type": "enabled", "budget_tokens": 8192 } } }
    },
    "fallbacks": { "fast": ["deep"] },
    "provider_options": { "claude-opus-4-1": { "top_k": 40 } }
  },
  "routing": { "parent": "deep", "research": "fast",
               "implement": "default", "review": "fast" }
}
```

- `routing` picks the model per role: `parent` for the main turn, `research`,
  `implement` and `review` for the child agents that role can spawn.
  `"default"` means the plain `model` block. A role with no entry uses the
  parent's provider, model, endpoint and key together (never a mix).
- An explicit `model` argument in an `agent` tool call names an alias (or `default`) and beats `routing`; an unknown alias fails the call.
- `fallbacks` is a chain, off by default. It is tried only after the failures
  that are worth retrying (HTTP 429/5xx, network, timeout) are exhausted, never
  after an error that a retry cannot fix and never after text has already been
  streamed. The switch prints `fallback: fast -> deep` on stderr.
- `provider_options` is per adapter and only implemented keys survive:
  `openai` accepts `reasoning_effort` (`minimal|low|medium|high`) and
  `reasoning` (object); `anthropic` accepts `thinking` (object) and `top_k`
  (integer); `gemini` accepts `thinking` (object). Anything else is dropped with a config warning. Precedence is
  alias > `models.provider_options.<model id>` > `model.provider_options`,
  merged key by key.

### OpenAI Responses API

`"provider": "openai-responses"` talks to `{base_url}/responses` (default
`https://api.openai.com/v1`, key from `OPENAI_API_KEY`) instead of Chat
Completions. Requests are streamed with `store: false`; it accepts the same
`provider_options` keys as `openai`, and reasoning summaries stream as
reasoning events.

```jsonc
{ "model": { "provider": "openai-responses", "model": "gpt-5.1",
             "provider_options": { "reasoning": { "effort": "medium", "summary": "auto" } } } }
```

### Google Gemini

`"provider": "gemini"` streams from
`{base_url}/models/<model>:streamGenerateContent?alt=sse` (default `base_url`
`https://generativelanguage.googleapis.com/v1beta`, key from
`GEMINI_API_KEY`, sent as `x-goog-api-key`). Model ids may not contain `/` or
`?`.

```jsonc
{ "model": { "provider": "gemini", "model": "gemini-2.5-pro",
             "provider_options": { "thinking": { "budget_tokens": 2048, "include_thoughts": true } } } }
```

- `thinking` maps to `generationConfig.thinkingConfig` (`budget_tokens` is a
  non-negative integer, `include_thoughts` a boolean); thought parts stream
  as reasoning events. It is the only option the adapter implements.
- `"auth": "oauth"` (on `model` or on an alias; default `"api_key"`) sends the
  value of `api_key_env` as `Authorization: Bearer <token>` instead of
  `x-goog-api-key`, for a Google OAuth access token. There is no login flow:
  export the token (for example `GEMINI_API_KEY=$(gcloud auth print-access-token)`)
  or store it with `/provider key`. Access tokens expire after about an hour.
  Any other `auth` value is a startup error naming the key.
- A reply cut off by `MAX_TOKENS` ends normally; a refusal (`SAFETY`,
  `RECITATION`, ...) or a blocked prompt is reported as a failure.
- No Gemini context caching: the system prompt is always sent as one block.

### Anthropic extended thinking

Set `thinking` in `provider_options` of an `anthropic` model:

```jsonc
{ "model": { "provider": "anthropic", "model": "claude-sonnet-4-6",
             "provider_options": { "thinking": { "type": "enabled", "budget_tokens": 4096 } } } }
```

With thinking on, `temperature` is not sent (the API requires the default),
and `max_tokens` is raised to at least `budget_tokens + 1024`. The signed
thinking block is sent back with the assistant turn it belongs to, as the API
requires during a tool loop; it is kept in memory for the running session, not
written to the session log, so a resumed session starts without it.

### Images

Attach PNG, JPEG, GIF or WebP files (at most 5 MiB each, 8 per message) to a
message. Images are sent inline as base64; there is no URL form. The image is
re-sent with every later request in the session, so it counts against the
context window and cost each turn.

```bash
ifnh ask --image shot.png --image diagram.webp "what differs between these?"
```

In the REPL, `/image <path>` queues a file for the next message, `/image` shows
how many are queued and `/image clear` empties the queue. Images are not
recorded in the session log.

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
- **`memory_recall` / `memory_remember` / `memory_forget`** — only when
  `memory.adapter` is not `none` (see Memory).
- **`mcp_list` / `mcp_describe` / `mcp_call`** — MCP servers (see below).
- **`read_tool_result`** — page through oversized outputs stored as
  artifacts.

`edit` replaces one occurrence of `old_string` by default and refuses zero
or several matches. Three upgrades:

- `replace_all: true` replaces every exact occurrence and reports the count
  (zero matches still fails).
- `edits: [{"old_string","new_string","replace_all"}, ...]` applies several
  edits in order against one in-memory copy and writes the file once, through
  one approval (whose diff is the final result) and one journal entry. If any
  edit fails the file is untouched and the error names the index
  (`[edits[1]]`). `edits` cannot be combined with `old_string`/`new_string`.
- **Whitespace-tolerant fallback.** When `old_string` has no exact match, whole
  lines are compared ignoring leading/trailing blanks and the length of
  space/tab runs. A unique match is replaced, line for line, with
  `new_string` exactly as given (its indentation is not adjusted) and the
  result says `matched ignoring whitespace differences`. Several candidates
  fail with the multiple-matches error plus a whitespace-insensitive hint.
  An exact match always wins, and `replace_all` never uses the fallback.

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

A server is either a local process (`command`, as above) or a remote
Streamable HTTP endpoint (`url`); setting both, or neither, is a config error
naming `mcp_servers.<name>`:

```jsonc
{
  "mcp_servers": {
    "tracker": {
      "url": "https://mcp.example.com/mcp",
      "headers": { "Authorization": "Bearer <token>" }   // optional
    }
  }
}
```

Each request is a `POST` with `Accept: application/json, text/event-stream`;
the reply may be plain JSON or an event stream (read until the response to
that request). The `Mcp-Session-Id` from `initialize` is sent on every later
request, with `MCP-Protocol-Version: 2024-11-05`, and a `DELETE` with it ends
the session at shutdown (best effort). `headers` values are plain config:
keep tokens out of a committed `.ifnh/config.json`.

`agents` limits a server to some agent identities: `parent` is the
top-level agent, and a subagent is its role (`research`, `implement`,
`review`). Absent or empty means every agent. A server that is not enabled
for an agent is never started for it and behaves as if it did not exist
(`mcp_list` says `no MCP servers for agent '<name>'` when none is left; a
call gets `error: mcp server '<name>' is not enabled for agent '<agent>'`).
An unknown identity only produces a config warning, so a role list stays
forward-compatible.

```jsonc
{ "mcp_servers": { "docs": { "command": "docs-mcp", "agents": ["parent", "research"] } } }
```

Subagents inherit MCP through the same allowlist; each child starts its own
connections, which end when the child finishes.

Stdio servers spawn lazily on first use and are killed at session end. Tool
calls pass the permission engine (`mcp.<server>.<tool>`, default ask).
Inspect with `/mcp`; the agent uses `mcp_list`/`mcp_describe`/`mcp_call`.
`mcp_describe(server, tool)` returns that tool's description and its input
JSON schema (from the server's `tools/list`), so the model need not guess
arguments.

Manual check against a stdio server: configure the `docs` server above, run
`ifnh`, and ask "use mcp_describe on docs read_file and tell me its required
arguments". The `[tool] mcp_describe` line must be followed by
`docs.read_file: <description>` and an `input schema: {...}` line whose
`required` list the model then repeats. An unknown tool gives
`error: unknown tool docs.<name>`; an unknown server gives
`error: server '<name>' unavailable`.

## 9. Skills

Agent Skills format (`SKILL.md` with `name`/`description` frontmatter):

- Project: `.ifnh/skills/<name>/SKILL.md` (highest precedence)
- User: `~/.config/ifnh/skills/` (or `$XDG_CONFIG_HOME/ifnh/skills/`)
- Compat (read-only): `.claude/skills/`, `.agents/skills/`

The agent sees a budgeted catalog each turn and loads bodies with the
`skill` tool. First-party examples ship in this repo under `skills/`
(reconnaissance, create-skill) — copy them into a skills directory to use.

### Installing skills from git

```
/skills                                         # [scope] name commit: description
/skills install <git-url> [name] [--ref <ref>] [--force]
/skills remove <name>                           # asks first
```

`install` accepts `https://…`, `ssh://…` and `git@host:path` sources only
(`file://`, `git://`, plain paths and anything starting with `-` are
refused). It runs `git clone --depth 1 [--branch <ref>]` into
`.ifnh/skills/.tmp-<name>`, then moves the result to `.ifnh/skills/<name>`;
the name defaults to the repository name and must match `[A-Za-z0-9._-]+`.
An existing `<name>` is refused unless you pass `--force`, which swaps the
whole directory (it is never half-replaced). The clone's `.git` directory is
dropped; the commit is pinned in `.ifnh/skills.lock.json`:

```json
{
  "version": 1,
  "skills": {
    "pdf-review": {
      "source": "https://github.com/o/pdf-review.git",
      "ref": "",
      "commit": "0123456789abcdef0123456789abcdef01234567",
      "installed_at": "2026-11-03T12:00:00Z"
    }
  }
}
```

The file is written deterministically (names sorted) so it diffs cleanly;
commit it to share exact versions. If it is not valid JSON, `install` and
`remove` stop with `skills lockfile is not valid JSON: .ifnh/skills.lock.json`
and leave it alone; `/skills` lists without commits. `--ref` takes a branch
or tag (not a bare commit id). An installed repository must keep its
`SKILL.md` at the top level for the catalog to pick it up; when none is found
within two directory levels, `install` still keeps the files but prints
`warning: no SKILL.md found in <name>`. The catalog is rescanned right
away. Skills never gain permissions from being installed (K153), but their
text goes to the model, so install only sources you trust.

## 10. Memory

Optional, advisory notes that survive between sessions. **Off by default**
(`memory.adapter: "none"`): nothing is stored, no tool is advertised.

```jsonc
{ "memory": { "adapter": "file",      // "none" | "file" | "mcp"
              "scope": "project" } }  // "project" | "user"
```

- **What gets stored:** only what the model saves with an explicit
  `memory_remember` call (a text of at most 4096 bytes, approved like any
  other write; `permissions` MCP rules apply as `memory.remember` and
  `memory.forget`). Entries are never added to the prompt automatically; the
  model reads them by calling `memory_recall`, and treats them as hints, not
  instructions (DECISIONS Q231). `memory_forget` deletes one note by id, or
  the whole scope without an id.
- **`file` adapter:** JSONL, one `{"id","ts","scope","text","source"}` object
  per line, in `.ifnh/memory/project.jsonl` (project scope; commit it or add
  it to `.ifnh/.gitignore`, as you prefer) or `<config dir>/memory/user.jsonl`
  (user scope). Recall is a case-insensitive substring match, newest first,
  at most 8 notes and 4 KiB per call; malformed lines are skipped and
  reported.
- **`mcp` adapter:** `{"adapter": "mcp", "server": "honcho"}` forwards to an
  entry of `mcp_servers`, calling the server's `memory_recall`,
  `memory_remember` and `memory_forget` tools with `{query, scope, limit}`,
  `{text, scope}` and `{scope, id}`. Rename them with
  `"tools": {"recall": "...", "remember": "...", "forget": "..."}`. A missing
  server or tool is reported as an error; the server's text reply is passed
  through. `adapter: "mcp"` without a `server` that exists in `mcp_servers`
  is a startup error.
- **Inspect and clear:** `ifnh memory list [--scope project|user] [--json]`
  prints one line per note; `ifnh memory purge [--scope ...] [--yes]` deletes
  them (without `--yes` it asks on a terminal and refuses when stdin is not
  one). In the REPL, `/memory` and `/memory purge`. With memory off, all of
  them print `memory is off (memory.adapter)`.
- Subagents share the parent's adapter; `research` and `review` children get
  `memory_recall` only.

## 11. Hooks

```jsonc
{ "hooks": {
    "before_agent": "echo starting | tee -a .ifnh/hook.log",
    "after_agent":  "zig build test",           // non-zero exit BLOCKS before_* only
    "before_tool": [
      "echo audit >> .ifnh/hook.log",
      { "command": "scripts/fmt-check.sh", "matcher": "edit|write", "timeout_s": 10 }
    ]
} }
```

Events (all ten of P212): `session_start/end`, `before/after_agent`,
`before/after_stage`, `before/after_tool`, `before/after_merge`. Each event
takes a command, a list of commands, or a list of objects with `command`,
`matcher` (`|`-separated exact tool names, `*` or omitted = every tool) and
`timeout_s` (1..300, default 30). Every hook runs under `/bin/sh` in the
workspace.

The event payload arrives as JSON on stdin and as `IFNH_EVENT`,
`IFNH_SESSION_ID` and `IFNH_TOOL_NAME` in the environment. A `before_*`
hook can steer the call from its stdout, using the last non-empty line:

```jsonc
{"decision": "deny", "reason": "no pushes on Fridays"}   // blocks the call
{"decision": "rewrite", "arguments": {"path": "b.txt"}} // replaces tool input
```

Rewrites chain through the remaining `before_tool` hooks; `after_*` hooks
never block, whatever they print. A non-zero exit or a timeout still blocks
`before_*` and is advisory everywhere else. Hooks never trigger hooks.

## 12. Lifecycles

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

## 13. Observability

- `ifnh doctor` — environment health.
- `/usage` — session token totals; per-turn records in the session dir.
- Logs: `--log-level err|info|debug|trace` (debug/trace redact secrets at
  write time).
- `ifnh --trace <path> ask ...` (or `IFNH_TRACE_LOG=<path>`) — NDJSON wire log
  of every provider request, response and failure, mode 0600, appended across
  runs. Line shape: `{"ts_ms","kind":"request"|"response"|"error","provider",
  "model","round","url","headers","body"}`. Requests carry the body actually
  sent; responses carry the accumulated text, tool calls and final usage (not
  raw SSE frames). Redaction is applied when each line is written: the
  stored provider keys and credential-named environment values are scrubbed
  exactly, `authorization`/`x-api-key`/`api-key`/`proxy-authorization` values
  become `[REDACTED]`, and the usual token patterns (`sk-`, `ghp_`, JWTs,
  `Bearer ...`) are masked in every body. A write failure prints one warning
  and turns tracing off; it never fails the turn. Child agents and context
  compaction requests are not traced yet.
- `ifnh debug-bundle [--out <path>] [--json]` — one redacted JSON file for bug
  reports (default `ifnh-debug-<utc>.json`, mode 0600): versions, platform,
  the merged config without keys named `*api_key*`, `*token*`, `*secret*` or
  `*password*` (model aliases keep only provider/model/base_url), where each
  key came from, config errors and warnings, the doctor report, the last 200
  lines of the trace log and `~/.local/state/ifnh/logs/*`, the last 20
  sessions (id, times, turn count, no message text) and `IFNH_*`/`TERM`/`SHELL`
  environment (secret-looking names redacted). `~/.config/ifnh/env` is never
  read into it. Prints the path, or `{"path","bytes"}` with `--json`.
- `ifnh session export <id> [--out <path>|-]` — a session's stored records as
  NDJSON (one per line, original order), secrets redacted; stdout by default.
  `<id>` may be a unique prefix; an unknown or ambiguous id exits 1.
- `ifnh replay <file> [--json]` — print an exported session offline (no
  provider, no config): `user:`, `assistant:`, `tool <name>: <status>` blocks,
  tool output cut to 20 lines with `... (n more lines)`. `--json` re-emits the
  records unchanged. Malformed input exits 2 with the line number on stderr
  and nothing on stdout.

## 14. Distribution

One-liner (needs a tagged release; the repository is planned to be renamed, and GitHub redirects the old path):

```bash
curl -fsSL https://raw.githubusercontent.com/Abide-Integrations/IFNH-Insert-Fancy-Name-Here/main/install.sh | sh
```

The root `install.sh` resolves the latest release tag (set `IFNH_VERSION=v0.1.7`
to pin one, or when the GitHub API is unreachable), detects the platform,
prefers the static musl build on Linux, verifies the sha256 (a mismatch or a
missing checksum aborts), installs to `~/.local/bin`, and warns if that
directory is not on your PATH. Set `IFNH_PREFIX` to install elsewhere. The man
page and shell completions in the tarball go to `<prefix>/../share/` (for
example `~/.local/share/man/man1/ifnh.1`) when that directory is writable, and
are skipped quietly when it is not. Signature checking is optional and manual,
see "Release artifacts" below; cosign is never required to install.

Uninstall (k3s-style — the installer drops a companion script next to the
binary):

```bash
ifnh-uninstall.sh           # remove binary, man page, completions + runtime state (keeps config + API keys)
ifnh-uninstall.sh --purge   # also delete ~/.config/ifnh (config + keys)
```

Project-local `.ifnh/` directories are never touched by the uninstaller.

A hosted copy works too:

```bash
curl -fsSL https://raw.githubusercontent.com/Abide-Integrations/IFNH-Insert-Fancy-Name-Here/main/uninstall.sh | sh
```

### Package-managed installs

If a package manager already provides `ifnh` (Homebrew, apt/dpkg, rpm, pacman or
AUR, snap, Nix), `install.sh` refuses before downloading anything and prints
the upgrade command, for example:

```
ifnh: refusing to overwrite a package-managed install (Homebrew); upgrade with brew upgrade ifnh
```

It checks the `ifnh` on your PATH and `$IFNH_PREFIX/ifnh` (paths under
`/Cellar/`, `/homebrew/`, `/snap/`, `/nix/store/`, or owned according to
`dpkg-query -S`, `rpm -qf`, `pacman -Qo`) and asks `brew` and `snap` whether
they have the package. There is no `--force`, and `IFNH_PREFIX` does not
bypass the check.

Package-managed installs (Homebrew, apt/rpm, snap, AUR, Nix) own the binary,
man page and completions only. They never create, modify or remove a project's
`.ifnh/`, `~/.config/ifnh` (config and API keys) or `~/.local/state/ifnh`
unless you, or the package's own uninstaller, do. The generated
`ifnh-uninstall.sh` behaves the same: it leaves every `.ifnh/` alone and, without
`--purge`, `~/.config/ifnh` too.

### Self-update

IFNH never updates itself: the package manager (or `install.sh`) owns upgrades
and removal. `ifnh update` is a deliberate refusal, not a missing feature. It
reads only its own path, makes no network call and writes nothing, prints to
stderr why it is disabled and how to upgrade (`brew upgrade ifnh` for a
Homebrew binary, `sudo snap refresh ifnh` for snap, your system package manager
for `/usr/bin`, otherwise re-running `install.sh` or downloading the release),
and exits 1.

### Release artifacts

Every `v<version>` tag publishes, per platform, a tarball and three sidecars
named `ifnh-<version>-<os>-<arch>` (Linux adds `-musl` or `-gnu`):

| Platform | Tarball |
|---|---|
| Linux x86_64, static | `ifnh-0.1.7-linux-x86_64-musl.tar.gz` |
| Linux x86_64, glibc | `ifnh-0.1.7-linux-x86_64-gnu.tar.gz` |
| Linux aarch64, static | `ifnh-0.1.7-linux-aarch64-musl.tar.gz` |
| macOS Apple silicon | `ifnh-0.1.7-macos-aarch64.tar.gz` |
| macOS Intel | `ifnh-0.1.7-macos-x86_64.tar.gz` |

For each tarball `<t>`:

| File | Content |
|---|---|
| `<t>.sha256` | `sha256sum` format checksum of the tarball |
| `<name>.spdx.json` | SPDX JSON SBOM of the `ifnh` binary, generated by [syft](https://github.com/anchore/syft) (`<name>` is the tarball name without `.tar.gz`) |
| `<t>.cosign.bundle` | cosign keyless signature bundle (Sigstore) |

Inside the tarball, `ifnh-<version>-<platform>/` holds `ifnh`,
`share/man/man1/ifnh.1` and the three completion scripts under
`share/bash-completion/completions/`, `share/zsh/site-functions/` and
`share/fish/vendor_completions.d/`.

Verify the checksum, then the signature. Signing is keyless: the bundle ties the
tarball to the release workflow's GitHub identity, there is no key to trust or
rotate.

```bash
sha256sum -c ifnh-0.1.7-linux-x86_64-musl.tar.gz.sha256

cosign verify-blob \
  --bundle ifnh-0.1.7-linux-x86_64-musl.tar.gz.cosign.bundle \
  --certificate-identity-regexp '^https://github.com/Abide-Integrations/IFNH-Insert-Fancy-Name-Here/\.github/workflows/release\.yml@refs/tags/v.+$' \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  ifnh-0.1.7-linux-x86_64-musl.tar.gz
```

The identity contains the repository path; if the repository has been renamed,
use its current `owner/name`. A bundle made by a manual dry run of the workflow
carries a `refs/heads/...` identity and is rejected by this pattern on purpose.

Releasing: `src/version.zig` is the only place the version is edited; set the
same value as `.version` in `build.zig.zon`, then check and tag:

```bash
scripts/check-version.sh --tag v0.1.7   # version.zig == build.zig.zon == tag
scripts/release-dry-run.sh              # local rehearsal: builds, packages, checksums, SBOMs
git tag v0.1.7 && git push origin v0.1.7
```

`release.yml` also runs on `workflow_dispatch` as a dry run (builds, packages,
signs and uploads workflow artifacts, never creates or touches a GitHub
release); only a tag push publishes. `scripts/release-dry-run.sh` skips the
keyless signature (it needs GitHub's OIDC token) unless given `--sign-key`.

### Completions, man page and `version --verbose`

```bash
ifnh completions bash > ~/.local/share/bash-completion/completions/ifnh
ifnh completions zsh  > ~/.local/share/zsh/site-functions/_ifnh      # directory must be in $fpath
ifnh completions fish > ~/.config/fish/completions/ifnh.fish
man ifnh                                                              # installed by install.sh and packages
ifnh version --verbose   # version, commit, target, build mode (4 lines); `ifnh version` / -V print one
```

The scripts are generated by the binary, so they always match the installed
version. `ifnh completions` with no or an unknown shell is a usage error (exit 2).
A source build records `git rev-parse --short HEAD` as its commit (or `unknown`
without a checkout); override it with `zig build -Dcommit=<sha>`.

CI is deliberately lean: `ci.yml` runs on ubuntu only (auto-cancel,
docs-only changes skipped) — version consistency, fmt, tests, ReleaseSafe
build, `scripts/bench.sh` budgets (size, startup, interactive cold start, TTFT,
per-round overhead, peak RSS), integration harnesses, and the offline install and
CLI smoke scripts (`tests/smoke-install.sh`, `tests/smoke-cli.sh`). For a single
machine:

```bash
zig build -Doptimize=ReleaseSafe && scripts/install.sh
```

## 15. Project layout inside `.ifnh/`

```
.ifnh/
├── config.json          # committed — project policy
├── config.d/            # committed — split config
├── instructions/        # committed — extra project instructions
├── commands/            # committed — custom slash commands
├── skills/              # committed — project skills (`/skills install` clones here)
├── skills.lock.json     # committed — pinned source/commit of installed skills
├── memory/              # advisory notes of the file memory adapter (opt-in)
├── lifecycle/           # committed — lifecycle definitions
├── tool-notes/          # committed — per-CLI guidance for agents
├── plans/               # plan artifacts
├── reports/             # agent reports (gitignored by default)
├── permissions.local.json  # your "always for this project" grants (gitignored)
├── sessions/            # session state (gitignored)
├── cache/               # artifacts, background-execution logs (gitignored)
└── .gitignore           # written by IFNH
```

## 16. Sandbox

An OS sandbox for the commands the **model** issues: the `bash` tool
(including `background: true`), data-defined custom tools and anything a
child agent runs. It never wraps the REPL's `!cmd` (you typed it) or the
`git` tool. It is best effort and off by default; the permission engine
still decides what may run, the sandbox limits what a permitted command can
touch.

```json
{ "sandbox": { "mode": "auto", "network": false, "write_extra": ["../shared-cache"] } }
```

- `sandbox.mode`: `"off"` (default; behaviour is byte-identical to no
  sandbox), `"auto"` (use the first available backend; if there is none, run
  unsandboxed and print `sandbox backend unavailable; running unsandboxed`
  once per session), `"required"` (no backend means the tool call fails with
  `sandbox unavailable: <reason>`; nothing runs unsandboxed).
- `sandbox.network`: default `false`. Allow network access inside the
  sandbox.
- `sandbox.write_extra`: paths (absolute, or relative to the workspace)
  that may be written in addition to the workspace, the temp dir (`$TMPDIR`,
  else `/tmp`) and `/dev/null`. They must exist for bwrap and Landlock.

Everything is readable; writes outside those places fail with a permission
error. Backends, in order of preference:

| Platform | Backend | Notes |
|---|---|---|
| Linux | `bwrap` (bubblewrap) | Read-only bind of `/`, fresh `/dev`, `/proc`, `/tmp`, PID/IPC/UTS namespaces, `--unshare-net` unless `network`. It is used only if it actually starts (it is test-run once per session). The user namespace is not unshared: that breaks hosts where bwrap is setuid or the namespace is already owned. |
| Linux | Landlock | Kernel 5.13+. The command runs under `ifnh __sandbox-exec`, a hidden helper that restricts itself (write access only below the allowed paths) and then `exec`s the shell; it refuses to start unless the parent set `IFNH_SANDBOX_EXEC=1`, and any failure exits 126 with `sandbox: <errno>` instead of running open. Denying the network needs ABI 4 (kernel 6.7+), and only covers TCP bind/connect: on an older kernel the filesystem is still scoped but `network: false` cannot be enforced; UDP and unix sockets are not covered. |
| macOS | Seatbelt | `/usr/bin/sandbox-exec` with a generated profile (`deny default`, reads allowed, writes to the paths above plus `/private/tmp` and `/private/var/tmp`). Paths containing a newline or `)` are refused. |

`ifnh doctor` prints the result: `sandbox: landlock (mode=auto, network=off)`.
The backend is resolved once when a session starts; child agents inherit it.
A command's working directory is still the directory `ifnh` was started in.
Landlock needs the `ifnh` executable itself, so it is not offered when
`libifnh` is embedded in another program.

## 17. Server mode (ACP)

`ifnh serve` speaks JSON-RPC 2.0 on stdin/stdout so an editor or another
program can drive the agent. The method set is the core of the
[Agent Client Protocol](https://agentclientprotocol.com) plus one extension.
Each session is the same runtime `ifnh ask` uses (same config, permissions,
sandbox, tools); there is no second agent loop. Stdout carries protocol
messages only: no ANSI, no banners. Diagnostics go to stderr. The server
exits 0 when stdin closes.

```bash
ifnh serve                            # newline-delimited JSON (ACP default)
ifnh serve --framing content-length   # LSP style: Content-Length: N\r\n\r\n<json>
ifnh --profile quick --model m serve  # global flags apply to every session
```

Framing: in the default mode a message is one line (CRLF and blank lines are
tolerated, a message may arrive split across reads). A message over 1 MiB is
answered with `-32600` (`id: null`) and skipped; the stream continues. With
`content-length`, both directions use the header form.

| Method | Params | Result |
|---|---|---|
| `initialize` | `{protocolVersion: 1, clientCapabilities?}` | `{protocolVersion: 1, agentCapabilities: {loadSession: true, promptCapabilities: {image: true}}, agentInfo: {name: "ifnh", version}, authMethods: []}` |
| `session/new` | `{cwd?, mcpServers?}` | `{sessionId}` |
| `session/load` | `{sessionId, cwd?}` | `{sessionId}` (resumes a persisted session; history is rebuilt, not replayed as updates) |
| `session/prompt` | `{sessionId, prompt: [content blocks]}` | `{stopReason}`: `end_turn`, `cancelled`, `max_turn_requests`, `refusal` (budget spent) |
| `session/cancel` | notification `{sessionId}` | none; the running prompt ends with `cancelled` |
| `session/close` | `{sessionId}` | `{}` |

- `cwd` is the project directory of the session (default: the server's
  working directory); config and `.ifnh/` state are read from it. A bad
  directory is `-32602`. The server moves the process into it while a prompt
  runs, so shell commands run there. Prompts run one at a time.
- Content blocks: `text` (several are joined with `"\n"` in order),
  `image` (`mimeType` png/jpeg/gif/webp, base64 `data`) and `resource_link`
  (passed to the model as `[link] <uri>`). `mcpServers` from the client are
  ignored (an `ifnh/notice` says so); configure `mcp_servers` instead.
- Errors: `-32700` parse error, `-32600` invalid request, `-32601` unknown
  method, `-32602` invalid params (including an unknown session), `-32603`
  a handler failure with a one-line message (for example `no model
  configured`).

Server to client:

- `session/update` notifications: `agent_message_chunk` for assistant text,
  `tool_call` (`status: "in_progress"`, `rawInput`) when a tool starts and
  `tool_call_update` (`completed` or `failed`, text `content`) when it ends.
  No `agent_thought_chunk` is sent: the runtime does not surface reasoning.
- `ifnh/notice` notifications (extension): `{sessionId, level, text}` with
  `level` one of `info`, `warn`, `error`, `notice`. Status and notice lines
  of the runtime (compaction, denials, the sandbox notice) arrive here.
- `session/request_permission` requests, whenever a tool needs approval:
  `{sessionId, toolCall, options}` (the approval comes before the tool starts, so
  `toolCall.toolCallId` is the placeholder `approval`) with the options `allow_once`,
  `allow_always` (this session) and `reject_once`. Answer with
  `{outcome: {outcome: "selected", optionId}}`. Anything else (another
  option, `cancelled`, an error, no answer within 30 s, a `session/cancel`,
  or closed stdin) is a rejection. Other messages that arrive while waiting
  are kept and handled afterwards. A cancel takes effect at the next point
  the turn checks it (between streamed events), so while the provider has not
  yet sent its first byte the prompt ends when that wait does.

## 18. Embedding libifnh

`zig build` (or `zig build lib`) also produces `zig-out/lib/libifnh.a` and
`zig-out/include/ifnh.h`: the runtime as a static library with a small C ABI
(`include/ifnh.h` documents it). The library reads no config files; the
host passes the whole configuration as JSON over the builtin defaults, and
API keys come from the process environment.

```c
#include "ifnh.h"

static void on_event(void *user, int kind, const char *text, int status) {
    if (kind == IFNH_EVENT_TEXT) fputs(text, stdout);
}

char *err = NULL;
ifnh_runtime *rt = ifnh_runtime_new("/path/to/project",
    "{\"model\":{\"provider\":\"openai\",\"model\":\"gpt-5\"}}", &err);
if (!rt) { fprintf(stderr, "%s\n", err); ifnh_string_free(err); return 1; }
int code = ifnh_runtime_prompt(rt, "summarize this repo", on_event, NULL, &err);
ifnh_runtime_free(rt);
```

`ifnh_runtime_prompt` returns 0 (completed), 1 (failed or never ran, for
example no model), 2 (cancelled), 3 (a tool was refused) or 4 (budget spent),
with the same precedence as `ifnh ask`. Strings passed to the callback are
copies valid for the call. There is no approval channel: tools that would ask
are refused, so allow them in the config you pass (`permissions`). A runtime
is single-threaded and not reentrant; shell commands run in the process
working directory, so `chdir` to the project first. The Landlock sandbox
backend is not available when embedded (it re-executes `ifnh`); bwrap and
Seatbelt are. From Zig, `src/lib.zig` exposes the same thing as `Runtime`.

```bash
./tests/smoke-lib.sh    # builds, compiles a C program with `zig cc`, runs it
```
