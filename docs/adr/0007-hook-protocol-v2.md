# ADR-0007: Hook protocol v2

- **Status:** Accepted (2026-11-02, task D-07)
- **Context:** Hooks ran a shell command around the agent and could only
  block. DECISIONS 212 names ten events and 215 limits hooks to informational
  or block-only behaviour in the MVP. Only a few events were wired, hooks had
  no way to see what was happening, and a hook could not say why it blocked.
- **Decision:**
  1. **Ten events** (P212): `session_start`, `session_end`, `before_agent`,
     `after_agent`, `before_stage`, `after_stage`, `before_tool`, `after_tool`,
     `before_merge`, `after_merge`. Each takes a command, a list of commands or
     a list of objects with `command`, `matcher` and `timeout_s` (1..300,
     default 30).
  2. **Payload.** A JSON object arrives on stdin and `IFNH_EVENT`,
     `IFNH_SESSION_ID`, `IFNH_TOOL_NAME` are set in a cloned environment. Output
     per stream is capped at 64 KiB.
  3. **Decisions.** A `before_*` hook may print a final JSON line
     `{"decision":"deny","reason":...}` or
     `{"decision":"rewrite","arguments":{...}}`. Rewrites chain through the
     remaining `before_tool` hooks. A non-zero exit or timeout still blocks
     `before_*`. `after_*` hooks never block. A hook cannot trigger hooks.
  4. **Hooks still cannot mutate runtime state (P215).** `rewrite` replaces the
     arguments of the one call in flight and goes through the same permission
     and approval checks as the original; a hook cannot change config,
     permissions, history, the model or the session.
  5. **Ordering.** Tool hooks fire before the tool runs, which is before the
     tool's own approval gate. A rewritten call is therefore what the user is
     asked to approve, and a denied call never reaches an approval prompt.
  6. **Merge.** There is no merge tool: merge = a `git merge` tool call.
     Concretely, a `bash` call whose arguments contain `git merge` also fires
     `before_merge` (after `before_tool`, using the original arguments) and
     `after_merge`; `before_merge` can block it like any `before_*` hook.
- **Consequences:**
  - Hooks are policy-as-data in `config.json`; nothing is compiled in.
  - Because hooks run before approvals, a hook that rewrites to something
    dangerous is still stopped by the permission engine.
  - Merge detection is a substring match on `bash` arguments. The `git` tool
    and a merge hidden inside a script do not fire the merge events, and a
    command that merely mentions `git merge` does.
  - Token figures in this area (`/context`, footer) are estimates,
    `(bytes + 3) / 4`, not provider counts; hooks must not treat them as exact.
- **Alternatives considered:**
  - Let hooks edit state (config, history): rejected by P215, and it would make
    a hook an unreviewed second control plane.
  - Run tool hooks after the approval gate: rejected, a rewrite must be visible
    to the human who approves.
  - A dedicated merge tool: rejected as scope.
- **Follow-ups:** state-mutating hooks need their own ADR; hook output in the
  REPL; per-hook environment allowlist.
