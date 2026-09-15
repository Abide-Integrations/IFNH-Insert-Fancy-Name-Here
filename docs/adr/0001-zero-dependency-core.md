# ADR-0001: Zero third-party dependencies

- **Status:** Accepted (2026-09-14)
- **Context:** PLAN.md D002 (lightweight core), D039 (single binary), REMAINING_DECISIONS Q268/269. The primary reference implementation (Vercel Labs `fx`) ships a 6.17 MiB binary with `.dependencies = .{}` and hand-rolls HTTP/SSE, JSON framing, terminal rendering, and diffing on the Zig standard library — proof that dependency-free is viable at production scale.
- **Decision:** IFNH declares zero third-party Zig dependencies permanently. `build.zig.zon` carries an empty `dependencies` table. Capabilities are built on `std` (std.http.Client, std.json, std.Thread, std.process, std.crypto) or implemented in-tree.
- **Consequences:**
  - Every capability (SSE parsing, diff/patch, fuzzy matching, MCP JSON-RPC) is auditable in-repo, satisfying the "small enough to understand and audit" north star.
  - A dependency proposal requires: an ADR, a "why does this belong in core" justification, license review, binary-size impact measurement, and maintainer approval (MASTER_TRACKER ST-3, PLAN §78).
  - We accept higher initial implementation cost for parsers/formats in exchange for auditability and zero supply-chain surface.
