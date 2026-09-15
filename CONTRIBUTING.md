# Contributing to IFNH

Thank you for your interest in contributing. IFNH has a deliberately small
core — read [PLAN.md](PLAN.md) (philosophy), [DECISIONS.md](DECISIONS.md)
(accepted decisions), and [DESIGN.md](DESIGN.md) (architecture) before
proposing changes.

## Setup

- Zig 0.16.0 (see `build.zig.zon`). No other toolchain, no third-party
  Zig dependencies — ever (see `docs/adr/0001`).

```bash
zig build test      # all unit tests
zig build           # binary -> zig-out/bin/ifnh
zig fmt --check src/
```

## Ground rules

1. **Architecture boundaries are non-negotiable** (AGENTS.md): core never
   imports ui/cli; tools depend only on core contracts; providers never
   absorb product logic.
2. **Zero dependencies.** A dependency proposal requires an ADR, a written
   "why does this belong in core" justification, license review, and a
   binary-size impact measurement.
3. **Tests land with code.** Colocated `test` blocks; register new modules
   in the catch-all test block in `src/main.zig`.
4. **`zig fmt --check src/` must be clean.**
5. **Performance budgets are release gates** (DESIGN §7): binary < 5 MiB,
   startup < 50 ms. CI enforces both.
6. **Never panic on bad runtime input**; bounded error sets; test
   allocation-failure paths where practical.
7. Every write to user state goes through `core/fsutil.zig` atomic
   primitives.

## PR checklist

- [ ] `zig build test` passes locally with no leak reports
- [ ] `zig fmt --check src/` clean
- [ ] Ran the built binary on the changed path if user-facing
- [ ] New behavior expressible as JSON/Markdown on disk is NOT compiled in
- [ ] Dependency changes: ADR + why-core justification attached
- [ ] Interface changes: ADR attached
- [ ] Tracker updated (`MASTER_TRACKER.md`) and decision changes recorded
      in `DECISIONS.md`

## Security

See [SECURITY.md](SECURITY.md) for reporting vulnerabilities. Please do
not open public issues for security reports.

## License

By contributing, you agree your contributions are licensed under the
MIT License.
