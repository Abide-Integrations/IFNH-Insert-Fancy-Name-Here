# IFNH Usage Guide

Everything you need to run, configure, and live in IFNH. Philosophy and
decisions live in PLAN.md/DECISIONS.md; architecture in DESIGN.md.

---

## 1. Build

Requires [Zig 0.16.0](https://ziglang.org/download/). No other toolchain.

```bash
zig build -Doptimize=ReleaseSafe     # -> zig-out/bin/ifnh (~1.7 MiB)
zig build test                       # unit tests
./scripts/bench.sh                   # verify size + startup budgets
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
| `/usage` | session token totals |
| `/compact` | force context compaction |
| `/lifecycle run <file.json> [--from <n>]` | run a lifecycle |
| `/review override <reason>` | developer-only override of a blocked review (audited) |
| `/reconcile <path>` | reconciliation agent for conflicting edits |
| `/quit` | exit |

Custom commands: drop a Markdown file into `.ifnh/commands/<name>.md`
(optional `---` frontmatter); `$ARGS` in the body is replaced by what you
type after the command.

## 4. Configuration

Precedence (low to high): **built-in defaults < user < project < session <
env < CLI**. Inspect any key:

```bash
ifnh config explain model.model
ifnh config validate
```

- **User config:** `~/.config/ifnh/config.json` (Linux) or
  `~/Library/Application Support/ifnh/` (macOS)
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
  "agents": { "max_depth": 1, "max_concurrent": 4 },
  "ui": { "colors": true }
}
```

`NO_COLOR` / `--no-color` disable styling.

## 5. What the agent can do (tool kernel)

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

## 6. Sessions, undo, forks

- Everything is event-sourced under `.ifnh/sessions/<id>/`
  (`events.jsonl`, `journal.jsonl`, `usage.jsonl`).
- `/undo` reverts agent file mutations (before-images live in the
  journal; crash recovery rolls back incomplete groups on next start).
- `ifnh resume <id>` continues a session; `ifnh sessions list --json`;
  `ifnh fork <id>` branches from the current state; `ifnh fork diff <a> <b>`
  compares; `ifnh cleanup [--yes]` enforces `sessions.keep` retention.

## 7. MCP

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

## 8. Skills

Agent Skills format (`SKILL.md` with `name`/`description` frontmatter):

- Project: `.ifnh/skills/<name>/SKILL.md` (highest precedence)
- User: `~/.config/ifnh/skills/`
- Compat (read-only): `.claude/skills/`, `.agents/skills/`

The agent sees a budgeted catalog each turn and loads bodies with the
`skill` tool. First-party examples ship in this repo under `skills/`
(reconnaissance, create-skill) — copy them into a skills directory to use.

## 9. Hooks

```jsonc
{ "hooks": {
    "before_agent": "echo starting | tee -a .ifnh/hook.log",
    "after_agent":  "zig build test"     // non-zero exit BLOCKS before_* only
} }
```

Events: `session_start/end`, `before/after_tool`, `before/after_agent`,
`before/after_merge`. `before_*` hooks block on non-zero exit; everything
runs under `/bin/sh` with a 30s timeout.

## 10. Lifecycles

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

## 11. Observability

- `ifnh doctor` — environment health.
- `/usage` — session token totals; per-turn records in the session dir.
- Logs: `--log-level err|info|debug|trace` (debug/trace redact secrets at
  write time).

## 12. Distribution

One-liner (after the repo is on GitHub and a tag is released):

```bash
curl -fsSL https://raw.githubusercontent.com/<org>/ifnh/main/install.sh | sh
```

The root `install.sh` detects platform, prefers static musl builds on
Linux, verifies sha256 when available, installs to `~/.local/bin`, and
warns if that directory is not on your PATH. Set `IFNH_PREFIX` to install
elsewhere, `IFNH_VERSION=v0.1.0` to pin a version.

CI is deliberately lean: `ci.yml` runs on ubuntu only (auto-cancel,
docs-only changes skipped) — fmt, tests, ReleaseSafe build, size +
startup budgets, integration harnesses. `release.yml` builds all five
release targets cross-compiled on one ubuntu runner and attaches them to
the GitHub release with sha256sums. For a single machine:

```bash
zig build -Doptimize=ReleaseSafe && scripts/install.sh
```

## 13. Project layout inside `.ifnh/`

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
├── sessions/            # session state (gitignored)
├── cache/               # artifacts, background-execution logs (gitignored)
└── .gitignore           # written by IFNH
```
