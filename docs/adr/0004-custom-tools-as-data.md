# ADR-0004: Custom tools as data (`.ifnh/tools/*.json`)

- **Status:** Accepted (2026-10-23, ACTIVE_PLAN D-02)
- **Context:** D-01 turned the tool layer into a registry (one row per tool). Adaptability ("ultra-adaptable", ACTIVE_PLAN Phase D) needs users to add tools without recompiling the binary: a repository should be able to describe its own `deploy`, `lint`, or `query` tool as data. The alternative (a Zig plugin ABI) would add an unstable interface, a load path into the binary, and a supply-chain surface that ADR-0001 exists to avoid.
- **Decision:** Data-defined tools are JSON files in `.ifnh/tools/*.json` (project level) and `~/.config/ifnh/tools/*.json` (user level). Each file is one tool:
  ```json
  {
    "name": "greet",
    "description": "Say hello.",
    "input_schema": {"type": "object", "properties": {"who": {"type": "string"}}, "required": ["who"]},
    "command": "echo hello {{who}}",
    "permission": "ask"
  }
  ```
  Rules:
  - `name` (required) is `[A-Za-z0-9_.-]{1,64}` and must not collide with a built-in tool; collisions are rejected (a project file must never shadow `bash`).
  - `command` (required) is a shell template. Each `{{param}}` is replaced by the argument value **as one single-quoted shell word**; a template must not add its own quotes around a placeholder. Missing or non-scalar arguments fail the call.
  - `permission` (required) is `"auto"`, `"ask"` or `"deny"`. It is combined with the existing permission engine and **the stricter decision wins**: `auto` adds no restriction, `ask` always prompts, `deny` always refuses. A file can tighten policy, never relax it.
  - `description` and `input_schema` are optional (`""` and an empty object schema by default). `input_schema` must be a JSON object; it is advertised to providers verbatim.
  - Project entries override user entries with the same name. Invalid files are reported as a warning line and skipped; loading never fails the session.
  - Execution reuses the `bash` path: engine classification, approval flow, and `sh -c` invocation, with the same output capping/artifact behaviour. Custom commands, like `bash`, are not journaled (bash side effects are opaque; they are gated by approvals instead).
  - Subagents do not receive custom tools in this iteration (they also do not receive MCP or skills hooks).
- **Consequences:**
  - No new dependency, no plugin ABI, no binary changes: the tool set is data on disk, loaded once per session before the first provider request.
  - `execute` and provider tool specs now read from a registry that is built-in rows plus loaded rows; adding a built-in tool is still one row, adding a user tool is one file.
  - `.ifnh/tools/` is added to the permission engine's protected paths, alongside `.ifnh/config.json` and `.ifnh/skills/`: an agent can never author a tool definition that would run with its declared permission in a later session.
  - Shell-quoting placeholders removes the obvious template-injection path, but a `permission: "auto"` file is still a pre-approved command for its author: repository review must treat `.ifnh/tools/` as executable policy, like `.ifnh/config.json`.
  - Malformed definitions are non-fatal and visible (warning with file path), which matches skills discovery behaviour.
