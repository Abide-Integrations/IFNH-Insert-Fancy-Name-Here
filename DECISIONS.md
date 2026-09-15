# IFNH — Decision Ledger: Discovery Backlog Resolved

> **Status:** Accepted (researched defaults, 2026-09-14)
> **Companion to:** PLAN.md (philosophy/decision ledger D001–D049), REMAINING_DECISIONS.md (the question backlog this document resolves), DESIGN.md (technical spec), MASTER_TRACKER.md (implementation plan).
> **How to read:** Answers are numbered to match REMAINING_DECISIONS.md exactly. Tags: `[core]` = fixed behavior, `[cfg]` = configurable default, `[M0]`/`[M1]`/`[M2]` = delivery milestone (see MASTER_TRACKER.md), `[post]` = post-MVP roadmap. `fx:` notes cite the Vercel Labs fx repository as architectural precedent (reference only — no code reuse; see Meta-decision M2).

---

## Meta-decisions (supplied by the project owner, 2026-09-14)

These four decisions resolve the tensions that blocked the rest of the backlog. They amend PLAN.md's Accepted Decision Ledger.

### M1 — Configuration format is JSON (amends D035)

Structured configuration uses **JSON**, not YAML. Zig's standard library has a complete JSON parser; it has no YAML parser, so YAML would require a third-party dependency. fx proves std-only JSON configuration works at 587-file scale. Markdown remains the format for instructions/skills (D035 half-retained). `ifnh config` commands accept and emit JSON.

### M2 — fx is an architecture reference only

Clean-room rule: study fx's architecture, patterns, and file layouts; write all IFNH code independently. No porting, no vendoring, no translation. License stays pure MIT with no Apache-2.0 attribution obligations. fx's AGENTS.md conventions may be adapted (they are not code).

### M3 — MVP is the vertical-slice core

M0 (the first milestone) is: single binary, config layering, `.ifnh/`, streaming inline CLI, generic provider interface (OpenAI-compatible + Anthropic native), core tool loop (read/grep/glob/patch-edit/bash), ask/auto permissions, JSONL sessions + resume, patch-first editing, undo journal, dirty-tree protection. Subagents, MCP, skills, worktrees, and lifecycle are M1+.

### M4 — Toolchain: Zig 0.16.0 stable now, 0.17.0 tracked

The owner asked for "the new 0.17.0". As of 2026-09-14, 0.17.0 is **unreleased** (master is `0.17.0-dev`; latest stable is 0.16.0, which is exactly what fx pins). Resolution: build against **0.16.0 stable** (`minimum_zig_version = 0.16.0`) so the scaffold compiles today and all fx-derived patterns apply verbatim; a standing tracker task validates compatibility with 0.17.0 when it ships.

---

# A. Persistence, sessions, and `.ifnh/`

1. **Hybrid: plain files + append-only JSONL event logs per session.** No SQLite. [core] fx: event-sourced `events.jsonl` + `session.json` manifest + recovery files; proven durable and resumable.
2. **Project `.ifnh/`** owns: `config.json`, `config.d/`, `instructions/`, `skills/`, `commands/`, `lifecycle/`, `plans/`, `reports/`, `tool-notes/`, `cache/`, `sessions/` (default). **User level** owns: config (`~/.config/ifnh/` on Linux, `~/Library/Application Support/ifnh/` on macOS), user skills/commands, logs/state (`~/.local/state/ifnh/` on Linux). [cfg]
3. **Committed:** `config.json`, `instructions/`, `skills/`, `commands/`, `lifecycle/`, `tool-notes/`. **Gitignored:** `sessions/`, `cache/`, `debug/`, `worktrees/`. Reports commit-optional (default ignored, flag to commit). IFNH writes/maintains `.ifnh/.gitignore` itself. [core]
4. **Session =** one parent conversation + its child-agent records + lifecycle state + config snapshot + undo journal, persisted under `.ifnh/sessions/<id>/`. [core]
5. **Multiple concurrent sessions: yes**, different sessions may target the same repo (isolation policy prevents mutation conflicts, L164-166); the *same* session is guarded by an advisory `flock` (`error.SessionBusy`, 2s deadline). fx: session locks. [M0]
6. **IDs:** `s_` + 12-char URL-safe random base64 (fx-proven shape); optional human alias + auto title stored in the session manifest; `ifnh resume` lists by recency/alias. [M0]
7. **Checkpoint =** event watermark (seq, event_id, log byte offset) + compaction handoff + config snapshot hash + lifecycle stage state + worktree refs + pending approvals, written as `checkpoint.json` plus `context_checkpoint` events. fx: checkpoint + recovery.json pattern. [M1]
8. **Retention defaults:** sessions 30, checkpoints 20 per session, debug logs 7 days, reports until explicit cleanup, journal lives with its session. All `[cfg]`.
9. **`/undo`** steps over journal groups (tool-call batches); default step = one agent turn, `--steps n` for finer granularity. Lifecycle stages are state transitions, not journal mutations — not undoable. Checkpoints are restore points, not undo entries. [M0]
10. **Yes** — the journal persists in the session dir; undo works across restarts while the journal exists. [M0]
11. **Fork = new session** dir with `fork_of` + fork-point watermark in its manifest; inherits history by lazy replay from the parent log. Git worktree binding optional at fork time (`--worktree`). Sessions are the primitive; branches/worktrees are bindings. [M2]
12. **Compare forks:** `ifnh fork diff <a> <b>` — side-by-side summary of diffs, reports, test results. No automatic scoring. [post]
13. **`ifnh cleanup` removes:** sessions past retention, orphaned IFNH-created worktrees (merged, or with confirmation), expired debug logs, old reports (explicit flag). **Never** touches developer files, `.ifnh/` config/instructions/skills, or anything not IFNH-created without explicit approval. [M2]
14. **Crash mid-mutation:** journal-first protocol — write intent record → apply → write commit record; next start replays or rolls back incomplete groups (fx: two-phase `commit.pending.json` + `recovery.json` pattern). [M0]

# B. Configuration

15. **User locations:** Linux `~/.config/ifnh/` (XDG_CONFIG_HOME honored) for config; `~/.local/state/ifnh/` for logs/transient state. macOS: `~/Library/Application Support/ifnh/` for both. [core]
16. **Project config:** `.ifnh/config.json`. [core]
17. **Both:** `config.json` plus `config.d/*.json` merged in alphabetical filename order (later files override). [M0]
18. **No includes/imports** — `config.d/` covers composition. [M0]
19. **Schema versioning:** top-level `"schema_version": 1`. Unknown keys → warning; unknown version → error with guidance; breaking changes bump the major. [core]
20. **Invalid config:** hard fail at startup with file + JSON path + reason. `ifnh config validate` for offline checks. Security-relevant sections (permissions) **fail closed**: invalid → deny + warn, never default-open. [M0]
21. **Env overrides:** `IFNH_<PATH>__<KEY>` with `__` as nesting separator (e.g. `IFNH_MODEL`, `IFNH_PERMISSIONS__DEFAULT_MODE`). [M0]
22. **Session-settable:** model/alias, effort, budgets, autonomy level, compaction policy, verbosity, MCP enablement. **Never session-settable:** permission ceiling, sandbox policy, git ceiling (ceilings can only be lowered mid-session). [core]
23. **CLI flags are the top layer.** Full precedence: `built-in < user < project < session < env < CLI`. fx: per-key source tracking (ConfigSources). [core]
24. **Hot reload at policy boundaries only** (agent spawn, privileged exec, git ops, lifecycle stage entry, merge, hooks, destructive ops) — config files re-read at those points. [M0]
25. **Re-read at boundaries; no file-watching MVP** (inotify opt-in post-MVP). fx ships no watcher either. [core]
26. **Yes** — `ifnh config validate`. [M0]
27. **Yes** — `ifnh config explain <key>`: current value, default, winning layer, source file (fx ConfigSources pattern). [M0]
28. **`ifnh init` writes a commented starter config non-interactively**; interactive wizard is post-MVP. [M0]

# C. Instructions and context

29. **Precedence (low → high):** built-in defaults < user instructions < repo-root `AGENTS.md` < repo-root `CLAUDE.md` (loaded if present; AGENTS.md wins conflicts) < nested `AGENTS.md` (scope-limited) < `.ifnh/instructions/*.md` (alphabetical) < lifecycle stage instructions < session instructions. No instruction file may weaken security/permission policy. [M0]
30. **Yes** — recursive nested `AGENTS.md` discovery (depth cap 4). [M0]
31. **Applicability:** a nested instruction applies when the agent's current working file/command target path resolves inside that directory. [M0]
32. **Contradictions:** higher layer wins for behavior defaults; contradictions touching safety/permissions are surfaced in the context log; `ifnh context --explain` shows every source and outcome. [M0]
33. **Yes** — `/context` prints the assembled system/project prompt. [M1]
34. **Yes** — the context assembly log records each source: path, layer, why loaded (trace-level by default, on-demand display). [M1]
35. **Initial context:** assembled instructions + git status + bounded file tree (depth/entry caps) + recon artifact if present + skills catalog index. No bulk file reads — the agent pulls content via tools. [M0]
36. **Compaction preserves:** requirements, decisions, constraints, current plan, completed/outstanding work, key file map, open questions. fx: chunked-summary pipeline with validation. [M1]
37. **Yes** — `.ifnh/pinned.md` and `pinned: true` frontmatter are never compacted away; large artifacts stay path-referenced and re-readable. [M1]
38. **Yes** — per-agent compaction policy override; default inherits parent. [post]

# D. Provider / model architecture

39. **Minimal adapter interface:** `stream(ctx, request) → events {content_delta, reasoning_delta, tool_call, usage, done, failure}` + `capabilities()` + optional `list_models()`. Plain fn-pointer struct (fx Provider pattern), not a vtable. [M0]
40. **Yes — OpenAI-compatible Chat Completions is the generic fallback adapter** (covers OpenRouter, Ollama, llama.cpp server, Z.AI, vLLM, custom proxies). [M0]
41. **Provider-specific features** flow through an opaque `provider_options` bag + capability flags; the generic interface never grows provider fields; unknown options warn. [core]
42. **Capabilities:** static model config wins; optional dynamic `/models` probe, best-effort, cached. [M1]
43. **Both** — static config plus optional per-provider catalog fetch (fx model_catalog pattern). [M1]
44. **Aliases:** `models.aliases = { fast: {...}, reasoning: {...} }` mapping alias → provider/model/params. [M0]
45. **Routing table:** `routing: { parent, research, implement, review }` → alias; per-agent config overrides the role default. [M1]
46. **Missing required capability:** fail fast with a clear message and suggestion; no silent degradation, no automatic swap unless a fallback chain is configured. [M0]
47. **Retries:** exponential backoff + jitter, Retry-After honored; retryable = 429/5xx/network only; max 3 (cfg); never auto-retry after possible delivery without replay evidence (fx DeliveryCertainty concept). [M0]
48. **Rate limits:** honor Retry-After; per-provider retry budget; exhausted → clean failure to the developer. [M0]
49. **Fallback chains:** opt-in per alias, off by default. [M1]
50. **Provider offline mid-run:** the turn fails cleanly, session state stays consistent (recovery checkpoint), resume or manual retry; fallback if configured. [M1]
51. **Cost estimation:** config-supplied per-model pricing (per 1M input/output tokens); estimate = tokens × price, always labeled approximate; no live pricing feeds. [M1]
52. **Local endpoints:** explicit OpenAI-compatible `base_url` config MVP; `ifnh doctor` probes common localhost ports post-MVP. [M0]

# E. Agent orchestration

53. **Agent = session-scoped runtime instance:** assembled prompt, model binding, permission set, tool-registry view, own event stream, child registry, budget state. [M0]
54. **Spawn request:** task, role, model alias, permission request (≤ ceiling), isolation (worktree|cwd), tool subset, budget caps (tokens/cost/depth), timeout, report path. [M1]
55. **Result:** JSON envelope `{status, summary, files_changed, tests, report_path, metrics}` + the structured Markdown report of PLAN §19. [M1]
56. **Max recursive depth default: 1.** [cfg]
57. **Max concurrent agents default: 4.** [cfg]
58. **`auto` concurrency MVP = parallel read-only groups, sequential otherwise** (fx leadingParallelGroup pattern); smarter heuristics post-MVP. [M1]
59. **Yes** — per-child interrupt (thread handle + cancel flag; fx managed_owner pattern). [M1]
60. **Yes** — parent cancels a child via the runtime. [M1]
61. **Developer → child:** read-only inspection (`/agents show`) MVP; direct steering post-MVP. [M1]
62. **Child clarification routes through the parent** MVP. [M1]
63. **No lateral sibling communication MVP** — shared reports are the channel. [core]
64. **Agents spawn children only through runtime policy** (depth/budget/permission enforced); within budget = automatic, beyond budget = ask. [M1]
65. **Child crash:** parent notified, status failed, partial artifacts preserved. [M1]
66. **Parent crash:** children terminated (thread-scoped lifetime); journal/recovery on resume (fx pattern). [M1]
67. **Timeouts:** tool call 120s, agent turn 10min, task = budget-bounded; all `[cfg]`; timeout → cancel + partial report. [M0]
68. **No priorities MVP.** [post]
69. **No task queues MVP** — per-batch thread pool (fx pattern). [M1]
70. **Runaway prevention:** depth cap + concurrency cap + budget caps + delegation-cycle detection. [M1]

# F. Plans, artifacts, and lifecycle

71. **Plan artifact:** Markdown + JSON frontmatter `{id, title, status, created, parent_task}` at `.ifnh/plans/<id>.md`. [M0]
72. **`.ifnh/plans/`.** [M0]
73. **Non-trivial =** any of: multi-file edit, new dependency, destructive/privileged op, non-read-only shell beyond allowlist, > N tool-call estimate (`planning.auto_call_threshold`, default 12), or the developer asks. Otherwise act directly. [cfg]
74. **Yes** — plan displayed; editable via `$EDITOR` before approval; edits recorded. [M0]
75. **Yes** — the plan file is the source of truth; the agent re-reads it on execute (durable-artifacts principle). [M0]
76/77. **Lifecycle schema v1:** `stages: [{name, instructions (path|inline), agent {role, model_alias, permissions}, requires: [artifacts], tests: [commands], review: {reviewers[], policy: all|any|n_of_m}, approval: none|human, budget}]`. Linear pipeline MVP. [M2]
78–80. **Branching/loops/concurrent stages:** schema reserves the fields; implementation post-MVP. [post]
81. **Entry/exit conditions:** artifact existence + tests pass + review without blockers + approval satisfied. [M2]
82. **Reusable templates =** lifecycle files at user scope; project overrides. [M2]
83. **`extends` inheritance: post-MVP.** [post]
84. **Stage resolution order:** stage config > agent config > project config > user config > defaults (standard layering per stage). [M2]
85. **Resume:** lifecycle state is event-sourced in the session; resume continues at the current stage with entry conditions re-validated. [M2]
86. **Stage "done" =** exit conditions met ∧ no blocking findings ∧ required approvals satisfied. [M2]
87. **Manual tasks:** stage `manual: [items]`; `/lifecycle done <item>` marks complete, audited. [M2]

# G. Reviews and approval gates

88. **Reviewer inspects:** diff, plan, child reports, test output, named files — with a read-only tool subset. [M2]
89. **Reviewer = agent role** on the same runtime primitive (restricted tools + report format), not a separate primitive. [core]
90. **Multiple reviewers:** yes, config list. [M2]
91. **Different models per reviewer:** yes (each reviewer has a model_alias). [M2]
92. **Approval policy:** `all | any | n_of_m` per gate. [M2]
93. **Findings:** structured `{severity, file, line, description, suggestion}` (JSON + Markdown report). [M2]
94. **Severities:** blocker | major | minor | info. [M2]
95. **Blocking:** blocker always; major by default (`[cfg]` per gate); minor/info never. [M2]
96. **Override:** `/review override <finding-id> --reason "..."` — developer-only command. [M2]
97. **Yes** — overrides are durable audit artifacts (session journal + review report). [M2]
98. **Default human-approval operations** (PLAN §59): merge, push, force-push, destructive shell, dependency changes, migrations, `.ifnh/` policy edits, permission-ceiling changes, all non-reversible ops. [core]
99. **Policy self-modification protection:** `.ifnh/` config/policy/lifecycle paths are agent-write-**denied** by default; changes require human approval; a policy hash snapshot is verified at each approval boundary (tamper detection). [M0]

# H. Permissions / security

100. **Primitives:** tool grants (`tool → allow|ask|deny`), path grants (`read|write` + glob), command grants (parsed pattern → allow|ask|deny), MCP grants (`server.tool`), env-var access grants. [M0]
101. **Combination:** tool + path + command-based; delegation passes bounded capability sets (structured subsets, never freeform strings). [core]
102. **Yes** — `read: ["**"], write: ["src/**"]` is expressible; matching resolves realpaths. [M0]
103. **Yes** — command allow/deny via lexer classification + prefix patterns (fx command_lex/command_effect approach). [M0]
104. **Composition:** a pipeline's required permission = intersection of all components; redirects/pipes/subshells each classified; any unknown component → ask. [M0]
105. **Destructive classification:** static lexicon (`rm -rf`, `git push --force`, `dd`, `mkfs`, `chmod 777`, `curl … | sh`, …) + write-effect heuristics; unmatched write-ish commands → ask. [M0]
106/107. **MCP permissions:** per-server enable + per-tool grants, default ask; per-agent server allowlists. [M1]
108. **Env vars:** agents see only explicitly granted vars (allowlist); tool commands run with a filtered environment. [M0]
109. **No** — `.env` values are not directly readable by default (deny, `[cfg]`); they are injected only into approved command environments. [core]
110. **Credentials:** redaction filter on all model-bound output and logs (configured secret var names + common token patterns); secrets never enter prompts/reports. [M0]
111. **Approval request shows:** tool, command/patch preview (diff), affected paths, triggering rule, provenance (agent/instruction/skill), grant options. [M0]
112. **Grant scopes:** once | session | pattern-scoped-permanent (user-scope permanence requires an explicit flag); no silent permanence. [M0]
113. **Child permissions ∩ sandbox capabilities** — a sandbox can only narrow. [M1]
114. **Threat model:** repo content (AGENTS.md, skills, docs, tool output) is **untrusted input**; permission prompts display provenance; approval gates are the enforcement mechanism, never model judgment. [core]
115. **Prompt-injection defense:** tool outputs framed as data, never instructions; injection-suspicious patterns flagged; dangerous actions gated regardless of instruction source. [core]
116. **Skills cannot grant permissions** — metadata is advisory; the runtime ignores permission requests in skill files. [core]
117. **Yes** — downloaded skills/scripts are untrusted until approved; per-source trust store; first execution requires approval. [M1]
118. **Symlinks/paths:** realpath resolution on all grant matching; escapes deny unless the target is covered; worktree paths pinned. [M0]
119. **`.ifnh/` policy files:** agent-write-denied by default; human approval required for changes (pairs with G99). [M0]

# I. Shell and tool execution

120. **Direct argv exec** for simple commands (no shell); the user's `$SHELL -c` only for compound commands (pipes/redirects/`&&`), classified by the lexer first. [M0]
121. **bash/zsh/fish:** handled uniformly via `$SHELL -c` for compound commands; no deeper shell-specific behavior; POSIX-lean. [core]
122. **No PTY MVP** — captured mode only; interactive TTY programs fail with a clear error; tmux-backed TTY sessions post-MVP (fx pattern). [core]
123/124/125. **Long-running/background:** managed-executions registry (spawn → execution_id → poll/stop/output); tracked in the session; killed on session end; process-group isolation prevents orphans. [M1]
126. **Output:** UTF-8-safe truncation at cap (default 64 KiB) with an explicit marker; stdout/stderr kept separate. [M0]
127. **Full output** stored as an artifact; `read_tool_result` retrieves by handle id + optional byte range/search (fx pattern). [M1]
128. **Discovery order:** loaded skills/instructions → `--help` → `man` → local README/docs → repo docs → configured research MCP → ask the developer (PLAN §38). [M0]
129. **CLI-doc cache** `.ifnh/cache/cli-notes/` with TTL: post-MVP. [post]
130. **Yes** — `.ifnh/tool-notes/<tool>.md` auto-injected on first use of that tool (project + user scopes). [M1]
131. **Slash parameters:** command Markdown frontmatter `{name, description, args: [{name, required, default}]}`; `$NAME` substitution in the body. [M0]
132. **Command composition:** single-level include of other commands MVP; no recursion. [M1]
133. **Yes** — commands may invoke lifecycle stages (`/lifecycle run <stage>`). [M2]
134. **`/reload`** reloads skills, commands, MCP config, tool-notes, instructions. Policies re-read only at boundaries (D029). [M1]

# J. MCP

135. **v1 transports: stdio + Streamable HTTP** (+ legacy SSE read support). fx: same three. [M1]
136. **Config:** `mcp_servers` map in user/project `config.json` — `{command, args, env}` for stdio; `{url, headers}` for HTTP; plus timeouts, `enabled`, `required`. [M1]
137. **Both scopes; project-scope servers are untrusted** → approval on first use per workspace (fx workspace-admission pattern). [M1]
138. **Lifecycle:** lazy spawn on first use (optional eager); graceful shutdown on session end; restart with a limit (fx server_lifecycle pattern). [M1]
139. **Yes** — remote HTTP servers v1. [M1]
140. **Credentials:** env vars only MVP (`bearer_token_env`, `header_env`); OAuth post-MVP. [M1]
141. **MCP tools enter the same permission engine** (grant key `mcp.<server>.<tool>`); default ask. [M1]
142. **Yes** — per-agent MCP allowlists (captured per child, fx mcp_view pattern). [M1]
143. **Unavailable server:** warn + degraded status; calls fail clearly; `required: true` fails lifecycle gates that depend on it. [M1]
144. **Output budget:** same tool-result cap (64 KiB) + artifact storage. [M1]
145/146. **Ship an example config for a recommended research MCP; do not build one MVP.** [M1]

# K. Skills and commands

147. **Target format: Agent Skills `SKILL.md`** — YAML frontmatter (`name`, `description`) + Markdown body; missing frontmatter tolerated (name falls back to directory basename; fx skill_contract semantics). [M1]
148. **Discovery:** user `~/.config/ifnh/skills/` + project `.ifnh/skills/` + read-only compat roots `.claude/skills`, `.agents/skills`. [M1]
149. **Merge:** project overrides user on name collision; catalog deduped by canonical path. [M1]
150. **Dependencies:** advisory metadata only MVP. [M1]
151/152. **Required executables / MCP:** advisory; checked at invocation with clear errors. [M1]
153. **Skills cannot request or grant permissions** — the runtime ignores such fields. [core]
154. **Skill scripts** execute via the normal permission-gated shell path; no special runner; first execution of downloaded scripts requires approval. [M1]
155. **Incompatible environment:** skill skipped with a catalog notice. [M1]
156. **skills.sh install:** manual clone MVP; `/skills install` post-MVP. [post]
157/158. **Pinning/updates:** record source + commit in `.ifnh/skills.lock.json` post-MVP; updates manual. [post]
159. **`/reload skills`** rescans the catalog. [M1]
160. **Yes** — IFNH generates skills via the first-party skill flow (PLAN §43). [M2]
161. **Generated skills require human review before activation**; written to `.ifnh/skills/`; never auto-enabled. [M2]

# L. Git / worktrees

162. **Git optional** — its presence unlocks worktrees/branches; everything else works without it. [core]
163. **Non-git directory:** worktree isolation unavailable → cwd isolation with an explicit warning + stricter default permissions (write scopes required). [M0]
164. **Worktree naming:** `ifnh-<session-short>-<agent>-<n>`. [M1]
165. **Location:** `~/.local/state/ifnh/worktrees/<repo-hash>/` default (avoids nested-repo confusion inside the main tree); project-local `.ifnh/worktrees/` is a `[cfg]` option. [M1]
166. **Yes** — branch `ifnh/<session>/<agent>` auto-created per worktree. [M1]
167. **Deletion:** after merge approval (`[cfg]`: immediate | retain-until-cleanup); failed tasks retained until cleanup. [M1]
168. **Failed task:** worktree preserved + marked; cleanup asks. [M1]
169. **Dirty protection:** detect at startup and before mutations; never stash/commit/overwrite (D047); propose a worktree path instead. [M0]
170. **Patch-first:** apply with exact-context verification (fx `edit_file` old_string semantics); expected context hash recorded at read time. [M0]
171. **Stale patch** = context mismatch at apply time → error + agent re-reads the file; blind application is impossible. [M0]
172. **Merge gate shows:** full diff, stats, test results, report links, plan reference. [M0]
173. **Hunk-level approval: post-MVP** (MVP: whole-diff approve/reject). [post]
174. **Edit-before-apply:** reject-with-instructions MVP; `$EDITOR` edit post-MVP. [post]
175. **Reconciliation agent:** PLAN §33 flow — dedicated agent receives requirements + reports + both diffs; its proposal goes through normal review. [M2]
176. **Child commits** land on worktree branches; merge gate; developer-approved merge/cherry-pick to target. [M1]
177. **Submodules: unmanaged MVP** (documented limitation). [core]
178. **Monorepos: supported** — path-scoped grants + nested AGENTS.md discovery cover them. [core]

# M. Undo / journaling

179. **Undoable action = one tool-call execution batch** — all file mutations from a single tool call or a parallel batch, journaled as one group. [M0]
180. **Journal entries are tool-call-level; default `/undo` step = one agent turn**; `--steps n` for tool-level granularity. [M0]
181. **`/redo`: yes** — two-way while the session is open. [M0]
182. **History:** full journal per session; pruned with session retention. [cfg]
183. **Location:** `.ifnh/sessions/<id>/journal.jsonl`. [M0]
184. **No file copies** — inverse patches + content hashes; bounded before-images only when an inverse is impossible. [M0]
185. **Non-reversible:** shell side effects, MCP calls, network pushes, deletions outside tracked scope. [M0]
186. **Warning:** the approval gate fires before classified destructive/non-reversible operations. [M0]
187. **Undo of IFNH-created commits = inverse (revert) commit** via git; never rebases developer branches; commits carry journal markers. [M1]
188. **External side effects** (databases, MCP actions) are marked irreversible; undo refuses with an explanation; compensations possible later via hooks. [core]

# N. Sandboxing

189. **The "breadcrumbs" are lightweight OS-sandbox projects:** Codex CLI-style sandboxing (Landlock on Linux, Seatbelt/sandbox-exec on macOS), bubblewrap, nsjail — research targets, not dependencies. [research]
190. **Required isolation properties:** filesystem write-scoping, process isolation, optional network policy, fast spawn. [core]
191. **Yes — Docker is the first optional executor backend** (tests/agents), never required. [M1]
192. **Lighter Linux sandbox (Landlock/bwrap): post-MVP.** [post]
193. **macOS sandbox (Seatbelt): post-MVP**; MVP = host exec + IFNH permissions only. [core]
194. **Network in sandbox:** Docker default open; `network: none` supported; light sandboxes default restricted when they arrive. [M1]
195. **Yes — policy disables network** per executor/agent config. [M1]
196. **Mounts:** project rw by default; ro for read-only roles. [M1]
197. **Secrets:** env-allowlist injection only. [M1]
198. **Resource limits:** IFNH-enforced timeouts always; Docker cpu/mem flags passthrough via config. [M1]
199. **Custom executors:** command-template interface post-MVP. [post]
200. **Local vs sandboxed tests:** `tests.sandbox: local|docker|auto`; `auto` = local MVP. [M1]

# O. Testing

201. **Discovery:** config `test.commands` + convention detection (package.json scripts, Makefile, `zig build test`, …) during reconnaissance; stored in the recon artifact. [M1]
202. **Yes** — lifecycle stages declare explicit `tests: []` suites. [M2]
203. **Relevance:** path-mapping heuristics + agent judgment MVP; no coverage-tool integration MVP. [M1]
204. **Yes** — generated tests are reviewed in the review stage (D026). [M2]
205. **Implementation agent writes its own tests by default**; a dedicated test-agent + reviewer checks are configurable. [M2]
206. **Sufficiency = exit criteria config** (new paths tested + suite green); no percentage mandate MVP. [cfg]
207. **Coverage tools:** consumed if configured, never required. [post]
208. **Flaky tests:** re-run-on-fail (`[cfg]`, off default); reported, never auto-ignored. [M2]
209. **Expensive suites:** `test.fast` vs `test.full` subsets; full suite before the merge gate. [M2]
210. **No tests at all:** recon flags it; the test stage may propose a minimal harness (approval-gated). [M2]
211. **Yes** — reconnaissance proposes a test strategy in its artifact. [M2]

# P. Hooks

212. **Events v1:** `session_start`, `session_end`, `before_tool`, `after_tool`, `before_agent`, `after_agent`, `before_stage`, `after_stage`, `before_merge`, `after_merge`. [M1]
213. **Synchronous MVP** (`before_*` may block); async post-MVP. [M1]
214. **Yes — hooks block progression:** non-zero exit + stderr message blocks with the reason surfaced. [M1]
215. **No state mutation from hooks MVP** — informational or block only. [M1]
216/217. **Hooks invoke agents/MCP indirectly via shell**; no direct runtime API. [M1]
218. **Hooks need no approval themselves, but repo-provided hooks are untrusted** → workspace trust approval (fx admission pattern). [M1]
219. **Failure:** surfaced; blocking hooks block; non-blocking hooks log. [M1]
220. **Recursion prevention:** hooks cannot trigger hooks; depth-1 events only. [M1]
221. **User + project hooks; project hooks trust-gated.** [M1]
222. **Repo-provided hooks:** explicit approval + allowlist; never auto-run. [M1]

# Q. Memory

223. **Adapter interface:** `recall(query, scope) → snippets`, `remember(entry, scope)`, `forget(scope)`, `capabilities()` — behind either MCP or a built-in file adapter. [post]
224. **Local memory: not MVP** — sessions/reports are the durable memory. [core]
225. (resolved by 224) A future local adapter would be file/JSONL-backed. [post]
226. **Writes:** only via an explicit memory tool when configured. [post]
227. **Scope:** per-project, selectable. [post]
228. **Retrieval: on-request MVP** (tool call); auto-inject post-MVP. [post]
229/230. **Inspect/delete:** `ifnh memory list|purge` when local memory exists; MCP-backed memory is the server's job. [post]
231. **Stale memory:** always advisory; repository truth wins (instruction + memory never auto-loaded MVP). [core]
232. **Honcho via the MCP adapter pattern** — no native Honcho client in core. [post]

# R. CLI / UX

233. **Bare `ifnh` = interactive streaming session in cwd** — inline UI + footer (fx-style), normal scrollback preserved. [M0]
234. **First-run:** zero-config if a provider env var/config exists; otherwise a guided hint (which env var to set). No forced wizard. [M0]
235. **Provider setup:** env var or `providers` entry in config.json; `ifnh doctor` verifies reachability. [M0]
236. **No wizard MVP.** [core]
237. **`ifnh init`:** writes the `.ifnh/` skeleton (config.json, instructions/, skills/, commands/, plans/, .gitignore) + prints next steps; never overwrites existing files. [M0]
238. **Default slash commands:** `/help /model /config /context /plan /compact /undo /redo /sessions /resume /fork /review /approve /deny /agents /reload /lifecycle /doctor /quit`. [M0 subset, rest by milestone]
239. **Listing:** `/help` shows built-ins + discovered commands. [M0]
240. **Child inspection:** `/agents` status pane (PLAN §56, one line per agent). [M1]
241. **Interrupt:** Esc interrupts the current turn; `/agents stop <id>`. [M0/M1]
242. **Approval prompt:** inline diff/command preview + `[y]es [n]o [s]ession [a]lways(pattern)` (`[e]dit` post-MVP). [M0]
243. **Diffs:** inline +/- colored blocks; near-monochrome with green/red deltas only (fx diff palette pattern). [M0]
244. **`$PAGER`: yes** above a size threshold. [M0]
245. **Large diffs:** preview cap + full artifact path + pager hint. [M0]
246. **Accessibility:** `NO_COLOR`, `--no-color`, and an ASCII symbol-set option. [M0]
247. **Theme:** config-driven colors/symbols (data-driven, PLAN §57). [M1]
248. **Non-interactive stdout:** stable human lines + `--json` on every command (fx output_contracts pattern) — the seam for future headless mode. [M0]

# S. Observability / debugging

249. **Levels: error | info | debug | trace** (trace = full transcripts + provider payloads). [M0]
250. **debug** records tool I/O summaries, decisions, config resolutions; **trace** adds transcripts/provider bodies. [M0]
251. **Storage:** `~/.local/state/ifnh/logs/` (Linux) / `~/Library/Application Support/ifnh/logs/` (macOS); project `.ifnh/debug/` opt-in. [M0]
252. **Redirection:** `--log-file` flag; `IFNH_LOG_LEVEL` env. [M0]
253. **Redaction at write time:** configured secret names + token patterns; always on for debug/trace. [M0]
254–258. **Usage tracking per agent:** tokens, cost, time, tool calls, compaction events in session `usage.jsonl`; `/agents` displays them. [M1]
259. **Yes — `ifnh doctor`:** config validity, provider reachability, git state, MCP health, versions. [M1]
260. **Crash reports: local-only, always.** [core]
261. **`ifnh debug-bundle`** (redacted logs + sanitized config) post-MVP. [post]

# T. Performance constraints

262. **Startup target: < 50 ms interactive cold start** (to prompt-ready); < 5 ms for non-interactive subcommands. fx budgets 2 ms for subcommands — our stretch goal. [core]
263. **Binary size target: < 5 MiB stripped** (fx: 6.17 MiB with more surface). [core]
264. **Idle memory target: < 30 MB.** [core]
265. **Per-child-agent overhead: < 10 MB + 1 thread.** [M1]
266. **Benchmarks:** hyperfine scripts in-repo; compared against fx/OpenCode/Claude Code where installed. [M1]
267. **Yes — CI performance budgets** (startup + size fail the build; fx check_budgets pattern) once CI exists. [M2]
268/269. **Dependencies: zero MVP;** any proposed dep requires a written "why core" review + ADR (fx rule adopted). [core]
270. **Deliberate perf tradeoffs:** durability beats speed on session writes; redaction beats speed; O(n) permission scans acceptable ≤ 1024 rules; never trade correctness of undo/durability for performance. [core]

# U. Repository and Zig architecture

271. **Single repository.** [core]
272. **Zig 0.16.0 stable baseline** (`minimum_zig_version = 0.16.0`). Owner requested 0.17.0; it is unreleased (master = 0.17.0-dev as of 2026-09-14) — 0.16.0 is the current stable generation and fx's exact target. 0.17.0 compatibility check is a standing tracker task. [core]
273. **Module layout:** `src/main.zig` composition root; `src/core/{config,session,agent,permissions,tooling,instructions,lifecycle,journal,context,util}`; `src/providers/{transport,sse,openai,anthropic}`; `src/tools/`; `src/ui/`; `src/cli/`. Layering rules live in AGENTS.md (core never imports ui; ui never owns product state; providers never absorb product logic). [core]
274. **Stable day-1 interfaces:** Provider, Tool, PermissionEngine, SessionStore/Event, Config schema, Journal. Everything else internal until it earns stability. [core]
275. **Providers compile in as generic wire protocols** (OpenAI-compatible + Anthropic native); endpoints config-driven; no per-vendor hardcoding. [M0]
276. **Zero third-party Zig libraries.** [core]
277. **No YAML parser** (JSON decision, Meta-M1). [core]
278. **HTTP/SSE:** `std.http.Client` + hand-rolled bounded SSE parser (fx-proven approach). [M0]
279. **JSON-RPC/MCP:** hand-rolled NDJSON JSON-RPC (fx pattern). [M1]
280. **Git: shell out to the `git` binary** — porcelain commands only. [M0]
281. **Patches:** hand-rolled unified-diff parse/apply with context verification; LCS diff generation for undo inverses. [M0]
282. **Persistence:** JSONL + atomic durable file replace (fsync file + dir; fx `durableReplaceVerified` semantics re-implemented). [M0]
283. **Concurrency:** `std.Thread` (agent workers, parallel tool batches, MCP readers); single UI thread; no async runtime. [core]
284. **Process management:** `std.process.spawn` + process groups; managed-executions registry. [M0]
285. **File watching: none MVP.** [core]
286. **Provider tests:** in-process fake HTTP server (`std.net` listener) + canned fixtures (fx fake-gateway pattern). [M0]
287. **Deterministic multi-agent tests:** scripted fake provider driving tool calls, fully in-process, no network. [M1]

# V. Open-source governance

288. **Public after M2** (go-public checklist lives in MASTER_TRACKER.md; owner sets timing). [process]
289. **Pre-publish cleanup:** secrets scan, LICENSE/headers, README/CONTRIBUTING, docs pass. [process]
290. **Contribution model:** PR-based; no CLA; conventional-commit-friendly but unenforced MVP. [process]
291. **CONTRIBUTING.md:** setup, conventions (`zig fmt`, test rules), PR checklist (tests, budgets, why-core rationale, ADR if interfaces change). [process]
292. **ADR process:** `docs/adr/NNNN-*.md`, required for interfaces, dependencies, security behavior, core additions. [process]
293. **Maintainer approval required for:** core interfaces, dependencies, permission/security behavior, license matters. [process]
294. **Anti-bloat:** PR checklist + CI budgets + the PLAN §78 test as review gates. [process]
295. **Integrations** (skill packs, MCP servers, lifecycle templates): separate repos recommended. [process]
296. **`@unstable` doc-comment marker** for pre-1.0 interfaces; semver for releases. [process]
297. **Semver 0.x pre-1.0**; config `schema_version` evolves independently. [process]
298. **`.ifnh/` compat:** best-effort pre-1.0 with migration warnings; stable at 1.0. [process]
299. **Skills/lifecycle formats:** versioned and forward-compatible (unknown keys tolerated). [process]
300. **Security reporting:** SECURITY.md with a private disclosure channel at publish; internal until then. [process]

# W. Final scope

301. **Must-haves to replace the current harness:** provider-agnostic tool loop, sessions + resume, patch-first editing + undo, unsurprising permission gates, < 50 ms startup.
302. **v0.2:** subagents, MCP, skills, worktrees.
303. **v1:** lifecycle engine, review gates, session forks, background executions, doctor, headless JSON mode.
304. **Sounds cool but violates the philosophy:** full TUI, cloud services of any kind, built-in web search, embedding memory in core, in-core scripting/plugin VM.
305. **MVP acceptance criteria** (measurable, tracked in MASTER_TRACKER.md): e2e tool loop against a fake provider; resume after `kill -9`; `/undo` restores file states; permission gate denies out-of-scope writes; startup budget enforced.
306. **Benchmark targets:** fx, OpenCode, Claude Code.
307. **Differentiators:** (1) CI-enforced speed/size budgets, (2) auditable policy-ceiling delegation, (3) lifecycle-as-config, (4) zero-dependency auditable core, (5) durable artifacts over hidden context.
308. **Non-goals:** PLAN §71 (unchanged).
309. **Prototype before committing:** the provider streaming loop + session journal are the highest-risk pieces — they are the first M0 tasks.
310. **Smallest proof of the architecture = the M0 vertical slice** (owner-selected).

---

## Default-answer disclaimer

Answers above marked `[cfg]` are shipped defaults, not laws: every one is meant to be overridable through the configuration system per PLAN D048 ("everything configurable, zero configuration required"). Any answer may be superseded by a later recorded decision in this file's changelog below.

## Changelog

| Date | Change |
|---|---|
| 2026-09-14 | Initial resolution of the full discovery backlog (Q1–Q310) + meta-decisions M1–M4. |
