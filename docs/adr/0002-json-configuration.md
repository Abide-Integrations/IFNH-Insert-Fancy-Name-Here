# ADR-0002: JSON for structured configuration (amends D035)

- **Status:** Accepted (2026-09-14, meta-decision M1)
- **Context:** PLAN.md D035 specified YAML for structured configuration. Zig 0.16's standard library has no YAML parser; honoring D035 literally would force either a third-party dependency (violating ADR-0001) or a hand-rolled YAML-subset parser (a correctness liability with real security implications, since configuration drives permissions).
- **Decision:** Structured configuration uses **JSON**: user `~/.config/ifnh/config.json`, project `.ifnh/config.json` + `.ifnh/config.d/*.json`, env overrides `IFNH_*__*`, CLI flags. Markdown remains the format for instructions, skills, commands, plans, and reports (the human-intelligence half of D035 is unchanged). Frontmatter inside Markdown (e.g. `SKILL.md`, command files) may use YAML-style frontmatter parsed minimally for `name`/`description`/`pinned` keys only, never as a general YAML parser.
- **Consequences:**
  - `std.json` provides parsing/validation; no new audit surface.
  - Configuration precedence implementation (DESIGN §3.5) merges `std.json.Value` trees with per-key source tracking.
  - PLAN.md records this amendment in its Amendments section.
