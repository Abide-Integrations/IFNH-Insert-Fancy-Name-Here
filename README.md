# IFNH

**IFNH** ("Insert Flashy Name Here") is a blazing-fast, lightweight,
open-source agentic coding harness written in Zig — for developers who want
to control their models, tools, agents, workflows, permissions, and
development lifecycle without adopting a heavyweight AI coding environment.

Status: pre-alpha, active architecture/scaffolding phase.

## Documentation

| Document | Contents |
|---|---|
| [PLAN.md](PLAN.md) | Product philosophy, architectural constraints, decision ledger |
| [DECISIONS.md](DECISIONS.md) | Resolved discovery backlog (Q1–Q310) + meta-decisions |
| [DESIGN.md](DESIGN.md) | Technical spec: modules, interfaces, schemas, budgets |
| [MASTER_TRACKER.md](MASTER_TRACKER.md) | Implementation milestones and task status |
| [AGENTS.md](AGENTS.md) | Conventions for humans and coding agents working here |
| [docs/adr/](docs/adr/) | Architecture decision records |

## Build

Requires [Zig 0.16.0](https://ziglang.org/download/):

```bash
zig build
./zig-out/bin/ifnh --help
zig build test
```

Zero third-party dependencies. Linux and macOS.

## License

[MIT](LICENSE)
