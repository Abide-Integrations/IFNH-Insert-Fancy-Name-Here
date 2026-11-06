# IFNH

**IFNH** ("Insert Flashy Name Here") is a terminal AI coding agent: an agentic
coding harness written in Zig. It is one native binary with zero third-party
dependencies, for developers who want to control their models, tools, agents,
permissions and workflow rather than adopt a heavyweight AI coding environment.

It speaks natively to Anthropic (Messages), OpenAI (Responses and Chat
Completions) and Google Gemini, and to any OpenAI-compatible endpoint (Ollama,
llama.cpp, vLLM, OpenRouter) through `model.base_url`.

## Status: 0.1.x, pre-1.0

Version 0.1.7 is feature-complete for the planned scope (phases A-F of
[ACTIVE_PLAN.md](ACTIVE_PLAN.md)), but it is not a stable 1.0:

- Interfaces, config keys and on-disk formats may still move before 1.0.
- No package-manager channel is published yet; the packaging files exist and
  were rehearsed locally, nothing has been pushed to a tap, repository, store
  or registry.
- Several acceptance rows are still awaiting verification by the owner on a
  real host (macOS execution, live provider runs, signing, package installs).
  [ACTIVE_PLAN.md](ACTIVE_PLAN.md) lists each row with its status and residuals.

What changed in this release is in [CHANGELOG.md](CHANGELOG.md).

## Features

- **Streaming REPL** with a line editor (history, reverse search, multiline,
  `@file`, `!cmd`) and a status footer showing model, context use, tokens, cost
  and turn time.
- **Tool kernel:** `read`, `glob`, `grep`, `edit`, `write`, `bash` (with
  background execution), `git`, `agent`, and `read_tool_result` for oversized
  output. `edit` supports `replace_all`, atomic multi-edits and a
  whitespace-tolerant fallback.
- **Subagents** with `research`, `implement` and `review` roles, optionally in
  their own git worktree.
- **Permission engine** with per-tool rules, `ask`/`auto` modes, unified-diff
  previews on writes, project-local grants, and ceilings on commits, pushes and
  force-pushes. Policy is enforced by the engine, not by the model.
- **Custom tools as data:** `.ifnh/tools/*.json` command templates with
  shell-quoted arguments ([usage](docs/USAGE.md#custom-tools-ifnhtoolsjson),
  [ADR-0004](docs/adr/0004-custom-tools-as-data.md)).
- **Profiles, aliases, fallbacks and routing:** `--profile`, `models.aliases`,
  `models.fallbacks`, per-role `routing.*`, and `provider_options` per model.
- **Hooks:** ten events, JSON payload, `deny` and `rewrite` decisions on
  `before_tool`.
- **MCP:** stdio and Streamable HTTP servers, with per-agent allowlists.
- **Skills** installed from git and pinned in a lockfile, opt-in advisory
  **memory**, and JSON **lifecycles** with review gates.
- **OS sandbox** for model-issued shell commands: bubblewrap, Landlock or
  Seatbelt (`sandbox.mode`, off by default).
- **Cost tracking:** dollars per turn, `/usage`, and an `agents.budget_usd`
  circuit breaker.
- **Observability:** `--trace` NDJSON wire log with write-time redaction,
  `ifnh debug-bundle`, `ifnh session export` and `ifnh replay`.
- **Headless mode:** `ifnh ask` with `--json` NDJSON events, `--policy`,
  `--yes`, `--deny-all` and documented exit codes.
- **Server mode:** `ifnh serve` speaks JSON-RPC 2.0 (ACP) over stdio.
- **Embedding:** `libifnh.a` with a C ABI in [include/ifnh.h](include/ifnh.h).
- **Packaging surface:** `install.sh`, shell completions (bash, zsh, fish), a
  man page, and Homebrew, apt, dnf, snap, AUR, Nix, mise and container files.

Details for every item are in the [usage guide](docs/USAGE.md).

## Quick start

Install (Linux and macOS; installs to `~/.local/bin`):

```bash
curl -fsSL https://raw.githubusercontent.com/Abide-Integrations/IFNH-Insert-Fancy-Name-Here/main/install.sh | sh
```

Releases are `ifnh-<version>-<os>-<arch>.tar.gz` (Linux adds `-musl` or `-gnu`,
for example `ifnh-0.1.7-linux-x86_64-musl.tar.gz`), each with a `.sha256`
checksum, a `.spdx.json` SBOM and a keyless cosign `.cosign.bundle` signature.
The installer verifies the checksum;
[docs/USAGE.md](docs/USAGE.md#release-artifacts) shows how to verify the
signature. It refuses to overwrite a package-managed `ifnh`, and `ifnh update`
deliberately does nothing: IFNH never updates itself. The package-manager
commands in the guide ([status](docs/USAGE.md#package-managers)) will not work
until a release has published them. To build from source:

```bash
zig build -Doptimize=ReleaseSafe && scripts/install.sh
```

Then, in your project:

```bash
export ANTHROPIC_API_KEY=sk-ant-...   # or OPENAI_API_KEY / GEMINI_API_KEY
ifnh init                             # optional .ifnh/ skeleton
ifnh doctor                           # checks config, key, git, MCP, state dirs
ifnh                                  # interactive session
ifnh ask "summarise src/main.zig"     # or one headless turn
```

Choose a model and a named profile in `.ifnh/config.json`:

```json
{
  "schema_version": 1,
  "model": { "provider": "anthropic", "model": "claude-sonnet-4-6" },
  "profiles": {
    "local": {
      "model": { "provider": "openai", "model": "qwen3-coder",
                 "base_url": "http://localhost:11434/v1" }
    }
  }
}
```

`ifnh --profile local` starts a session against the local server. Any key can
also be set with `ifnh config set <key> <value>` or a per-key flag such as
`--model`.

## Measured, not promised

`scripts/bench.sh` measures a ReleaseSafe build against fixed budgets (binary under 5 MiB, `config validate` under 50 ms, interactive
cold start under 50 ms, time to first token under 250 ms against a local fake
provider, per-round overhead under 50 ms, peak RSS under 30 MiB) and CI runs it.
One recorded run in the development VM (see the 2026-10-29 entry in the
ACTIVE_PLAN.md session log) measured a 1,880,208-byte binary and a 5.63 ms cold
start; CI and your machine will differ. There are no comparisons with other
tools here because none were run.

## Documentation

| Document | Contents |
|---|---|
| [docs/USAGE.md](docs/USAGE.md) | Usage guide: REPL, `ifnh ask`, configuration, tools, MCP, skills, hooks, sandbox, server mode, embedding, distribution |
| [docs/config.schema.json](docs/config.schema.json) | JSON Schema for configuration (also `ifnh config schema`) |
| [docs/adr/](docs/adr/) | Architecture decision records |
| [CHANGELOG.md](CHANGELOG.md) | What the 0.1.7 release contains |
| [ACTIVE_PLAN.md](ACTIVE_PLAN.md) | Work queue, verification status, known residuals |
| [PLAN.md](PLAN.md) | Product philosophy, constraints, decision ledger |
| [DECISIONS.md](DECISIONS.md) | Resolved discovery backlog (Q1-Q310) and meta-decisions |
| [DESIGN.md](DESIGN.md) | Technical spec: modules, interfaces, schemas, budgets |
| [MASTER_TRACKER.md](MASTER_TRACKER.md) | Implementation milestones and task status |
| [AGENTS.md](AGENTS.md), [CONTRIBUTING.md](CONTRIBUTING.md) | Conventions for people and coding agents working here |
| [SECURITY.md](SECURITY.md) | Reporting vulnerabilities |

## Build

Requires [Zig 0.16.0](https://ziglang.org/download/) and nothing else:

```bash
zig build -Doptimize=ReleaseSafe
./zig-out/bin/ifnh --help
zig build test
```

Linux and macOS. Cross-compiles to any target (`-Dtarget=aarch64-linux-gnu`
etc.); tagging a release builds all five platform artifacts in CI.

## License

[MIT](LICENSE)
