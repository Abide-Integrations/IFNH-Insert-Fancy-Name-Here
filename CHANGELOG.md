# Changelog

All notable changes to IFNH are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/). IFNH is pre-1.0:
interfaces and config keys may still change between 0.1.x releases.

The source of truth for what landed and what is still awaiting verification on
the owner's host is [ACTIVE_PLAN.md](ACTIVE_PLAN.md); this entry summarizes its
phases A-F and session log.

## [0.1.7] - unreleased

No tag has been pushed and nothing is published yet.

### Added

- **Headless and scripting.** `ifnh ask` runs one turn from an argument, `-p`
  or stdin. `--json` writes NDJSON events (`start`, `text`, `tool`, `approval`,
  `error`, `end`). `--yes`, `--deny-all` and `--policy ask|allow|deny` decide
  approvals, never read from stdin. Exit codes: 0 ok, 1 failed, 2 usage, 3
  denied, 4 budget spent, 130 interrupted.
- **Terminal UX.** A line editor (history, Ctrl-R, multiline, bracketed paste,
  Tab completion, `@file` attachments, `!cmd`), a status footer on stderr,
  unified-diff previews on `write`/`edit` approvals, and project-local
  "always" grants in a gitignored `.ifnh/permissions.local.json`. `/context`
  shows bytes and estimated tokens per prompt source.
- **Custom tools as data.** `.ifnh/tools/*.json` command templates with
  shell-quoted `{placeholder}` arguments, gated like `bash`; builtins now come
  from one registry table (ADR-0004).
- **Configuration.** `ifnh config path|get|explain|set|edit|schema|validate`,
  a published JSON Schema (`docs/config.schema.json`), and per-key flags
  (`--model`, `--provider`, `--base-url`, `--temperature`,
  `--max-output-tokens`, `--context-tokens`, `--permission-mode`,
  `--no-footer`). Named profiles (`--profile`), `models.aliases`,
  `models.fallbacks`, per-role `routing`, and per-model `provider_options`
  (ADR-0005, ADR-0006).
- **Providers.** OpenAI Responses API, native Google Gemini (API key or OAuth
  access token), Anthropic extended thinking, image input (`--image`,
  `/image`), per-model default output-token limits, and Anthropic prompt
  caching with cache token counts in the footer and `usage.jsonl`.
- **Hooks v2.** All ten events, JSON payload on stdin, `IFNH_*` environment,
  per-tool matchers, timeouts, command lists, and `deny`/`rewrite` decisions on
  `before_tool` (ADR-0007).
- **MCP.** Streamable HTTP servers (`url`, `headers`) beside stdio, per-agent
  allowlists (`agents`), subagent inheritance, and `mcp_describe` returning a
  tool's input schema.
- **Skills and memory.** `/skills install` from git with a pinned
  `.ifnh/skills.lock.json`; opt-in advisory memory (`file` or `mcp` adapter,
  `ifnh memory list|purge`, `/memory`).
- **Cost tracking.** Embedded price table, dollars per turn, `/usage` in
  dollars, per-turn `cost_usd` in `usage.jsonl`, and the `agents.budget_usd`
  circuit breaker.
- **Observability.** `--trace` / `IFNH_TRACE_LOG` redacted NDJSON wire log,
  `ifnh debug-bundle`, `ifnh session export`, `ifnh replay`.
- **Edit upgrades.** `replace_all`, atomic `edits[]`, and a whitespace-tolerant
  fallback.
- **Sandbox.** Optional OS sandbox for model-issued shell commands:
  bubblewrap and Landlock on Linux, Seatbelt on macOS (`sandbox.mode`,
  `sandbox.network`, `sandbox.write_extra`).
- **Server mode and embedding.** `ifnh serve` (JSON-RPC 2.0 / ACP over stdio,
  newline-delimited or `Content-Length` framing) and `libifnh.a` with
  `include/ifnh.h`.
- **Packaging surface.** `ifnh completions bash|zsh|fish`, a man page,
  `ifnh version --verbose`, a hardened `install.sh` with a companion
  uninstaller, and packaging files for Homebrew, apt/dnf (nfpm), snap, AUR,
  Nix, mise and a container image.
- **CI.** Performance budgets (`scripts/bench.sh`: size, startup, cold start,
  TTFT, per-round overhead, peak RSS) and a nightly / on-demand macOS arm64
  workflow.

### Changed

- **Performance.** Per-turn config, instructions, skills, git state and policy
  hash are cached by file fingerprint; one long-lived HTTP client per session;
  scratch arenas per tool call; streaming `grep`; parallel read-only tool
  batches; `rg`/`fd` used when present and `tools.external` is on; tool calls
  dispatch as soon as their block closes.
- **Layout.** The agent loop moved into `core/agent/session_runtime.zig`,
  shared by the REPL, `ifnh ask` and `ifnh serve`, with no module globals.
- **Paths.** The user config directory is `$XDG_CONFIG_HOME/ifnh`, else
  `~/.config/ifnh`, on Linux and macOS alike; state lives under
  `~/.local/state/ifnh`.
- **Release artifacts.** Stable names `ifnh-<version>-<os>-<arch>.tar.gz`
  (Linux adds `-musl` or `-gnu`), each with a `.sha256`, an SPDX SBOM and a
  keyless cosign bundle. `scripts/check-version.sh` ties `src/version.zig`,
  `build.zig.zon` and the tag together.
- **Self-update.** `ifnh update` always refuses with instructions; IFNH never
  updates itself.
- **Toolchain.** Pinned to Zig 0.16.0 with zero third-party dependencies.
- **Subagent models.** An explicit `model` on an `agent` call now names an
  alias (or `default`), not a raw model id; an unknown alias fails the call.
- **Docs.** README rewritten, `docs/USAGE.md` reconciled with the code, and the
  tracker's overstated completion marks downgraded.

### Fixed

- Anthropic requests: tools use the Anthropic schema, consecutive tool results
  merge into one user message, `is_error` is set, and malformed tool arguments
  no longer produce invalid requests. OpenAI assistant messages now keep their
  `tool_calls`.
- Config keys: dead keys were wired up or removed, and `git.push`,
  `git.force_push` and `read_dotenv` enforcement was verified.
- Compaction cuts only on turn boundaries, and its threshold follows the model
  window.
- `bash` always runs through `/bin/sh -c` after classification, so quoted
  arguments and globs are no longer split; `background` and `timeout_s` are
  advertised.
- Ctrl-C aborts the stream and kills the whole child process group; a second
  press exits with status 130.
- Transport errors become provider failures, `Retry-After` is honoured, and a
  turn that fails mid-way is rolled back instead of leaving a dangling message.
- Session resume replays tool calls and results, reads the newest events, and
  warns when older ones were dropped.
- The workspace git repository is found without spawning `git`, which also
  makes subagent worktree isolation work from the REPL.
- `write` and `edit` journal paths resolve under the workspace, not the
  session directory.
- Config warnings were printed twice with `--profile` or per-key flags.
- A redaction bug dropped text after the first match.

### Security

- Secrets are redacted when trace lines, debug bundles and session exports are
  written; the trace log and debug bundle are created with mode 0600.
- `.ifnh/tools/` and `.ifnh/permissions.local.json` are protected paths: agents
  cannot write them, even with approval.
- Custom tool arguments are single-quoted, so an argument cannot inject shell
  syntax.
- `install.sh` aborts on a checksum mismatch or a missing checksum, and refuses
  to overwrite a package-managed install. Release signatures are keyless
  (Sigstore), so there is no signing key to hold.
- Skills install only from `https://`, `ssh://` and `git@` sources, pin the
  commit, and gain no permissions from being installed.

### Known residuals

- No package-manager channel (Homebrew, apt, dnf, snap, AUR, Nix, mise, container
  image) is published; each needs one-time owner setup. `install.sh` is the only
  working install path once a release exists.
- Several acceptance rows are still awaiting owner verification on a real host:
  macOS execution, live provider runs, keyless signing, package installs and a
  GitHub Actions dry run. See [ACTIVE_PLAN.md](ACTIVE_PLAN.md).
- The Landlock backend cannot deny UDP or unix sockets, and denying TCP needs
  kernel 6.7 or newer.
- Esc-to-stop is not built: interrupting a turn is Ctrl-C (A-06). The C-07 markdown renderer is implemented in `src/ui/render.zig` and used by the REPL, but its ACTIVE_PLAN row is still marked unverified.
