# IFNH

**IFNH** ("Insert Flashy Name Here") is a blazing-fast, lightweight,
open-source agentic coding harness written in Zig — for developers who want
to control their models, tools, agents, workflows, permissions, and
development lifecycle without adopting a heavyweight AI coding environment.

Status: pre-1.0. Phases A-D (correctness, performance, headless and
scripting, extensibility) have landed and Phase E hardening is in progress;
interfaces and config keys may still move. Current work: [ACTIVE_PLAN.md](ACTIVE_PLAN.md).

## Documentation

| Document | Contents |
|---|---|
| [PLAN.md](PLAN.md) | Product philosophy, architectural constraints, decision ledger |
| [DECISIONS.md](DECISIONS.md) | Resolved discovery backlog (Q1–Q310) + meta-decisions |
| [DESIGN.md](DESIGN.md) | Technical spec: modules, interfaces, schemas, budgets |
| [MASTER_TRACKER.md](MASTER_TRACKER.md) | Implementation milestones and task status |
| [AGENTS.md](AGENTS.md) | Conventions for humans and coding agents working here |
| [docs/adr/](docs/adr/) | Architecture decision records |

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/Abide-Integrations/IFNH-Insert-Fancy-Name-Here/main/install.sh | sh
```
The repository is planned to be renamed; the old path will redirect.
Or from source:

```bash
zig build -Doptimize=ReleaseSafe && scripts/install.sh
```

## Quickstart

```bash
cd your/project
export ANTHROPIC_API_KEY=sk-ant-...
ifnh init                          # optional .ifnh/ skeleton
ifnh doctor                        # verify environment
ifnh                               # start an agentic session
```

Works with any OpenAI-compatible endpoint (Ollama, llama.cpp, vLLM,
OpenRouter) via `model.base_url`, and natively with Anthropic, the OpenAI
Responses API and Google Gemini (`model.provider`). See the [usage guide](docs/USAGE.md)
for configuration, permissions, subagents, MCP, skills (`/skills install`
from git, pinned in a lockfile), opt-in advisory memory, hooks, and
lifecycles.

Also: an optional OS sandbox for model-issued shell commands (`sandbox.mode`,
bubblewrap/Landlock/Seatbelt), `ifnh serve` (JSON-RPC/ACP over stdio) and
`libifnh.a` with a C ABI (`include/ifnh.h`) for embedding.

## Build

Requires [Zig 0.16.0](https://ziglang.org/download/):

```bash
zig build -Doptimize=ReleaseSafe
./zig-out/bin/ifnh --help
zig build test
```

Zero third-party dependencies. Linux and macOS. Cross-compiles to any
target (`-Dtarget=aarch64-linux-gnu` etc.); tagging a release builds all
five platform artifacts in CI.

## License

[MIT](LICENSE)
