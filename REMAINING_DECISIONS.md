We've actually resolved a lot of the product philosophy. What's left is mostly the layer that turns IFNH from a strong concept into something engineers can implement without making architectural decisions for us.

I would **not** answer all of these at once. This is the remaining interview backlog, and we can continue walking through it one question at a time.

## Remaining IFNH Discovery Questions

### A. Persistence, sessions, and `.ifnh/`
1. What persistence technology should IFNH use internally: plain files, SQLite, or a hybrid?
2. What belongs in `.ifnh/` versus a user-level IFNH directory?
3. Which `.ifnh/` artifacts should normally be committed to Git versus `.gitignore`d?
4. What exactly constitutes a session?
5. Can multiple IFNH sessions operate against the same repository simultaneously?
6. How should session IDs/names work?
7. What exactly gets captured in a checkpoint?
8. How long should old sessions/checkpoints be retained?
9. How should `/undo` behave across agent actions, lifecycle stages, and checkpoints?
10. Should undo survive closing and reopening IFNH?
11. How should session forks relate to Git branches/worktrees?
12. How do we compare two forked sessions and choose one?
13. What should `cleanup` remove, and what should it never remove automatically?
14. What happens if IFNH crashes halfway through a mutating action?

### B. Configuration
15. What are the exact user-level config locations on Linux/macOS?
16. What is the canonical project config filename?
17. One large YAML file, multiple focused YAML files, or support both?
18. Do we support YAML includes/imports?
19. How are configuration schemas versioned?
20. What happens when configuration is invalid?
21. How do environment variables override YAML?
22. Which settings can be overridden for only the current session?
23. Should CLI flags be another configuration layer above session configuration?
24. Exactly when does hot reload occur?
25. Should IFNH watch config files or re-read them only at policy boundaries?
26. Do we want `ifnh config validate`?
27. Do we want `ifnh config explain <key>`?
28. Do we want IFNH to generate documented starter configurations interactively?

### C. Instructions and context
29. What is the exact precedence between `AGENTS.md`, `CLAUDE.md`, `SKILL.md`, `.ifnh` instructions, lifecycle instructions, and session instructions?
30. Should IFNH recursively discover nested `AGENTS.md`/instruction files?
31. When does a nested instruction become applicable?
32. What happens when two instruction sources contradict each other?
33. Should developers be able to inspect the final assembled system/project prompt?
34. Should IFNH explain *why* a particular instruction was loaded?
35. How much repository content should initially enter context?
36. What gets preserved during automatic compaction?
37. Can developers mark information as "never compact this"?
38. Can individual agents have different context-compaction policies?

### D. Provider/model architecture
39. What is the minimum interface every provider adapter must implement?
40. Do we natively support OpenAI-compatible APIs as the generic fallback?
41. How are provider-specific features exposed without contaminating the generic interface?
42. How does IFNH discover model capabilities?
43. Does IFNH maintain a model catalog or query providers dynamically?
44. How do users configure aliases like `fast`, `cheap`, `reviewer`, `reasoning`?
45. How does automatic model routing work?
46. What happens if the selected model doesn't support required tool calling/structured output?
47. How are retries handled?
48. How are provider rate limits handled?
49. Should fallback models/providers be configurable?
50. What happens mid-run if a provider goes offline?
51. How precise must cost estimation be before we expose estimated spend?
52. How are local Ollama/llama.cpp endpoints discovered/configured?

### E. Agent orchestration
53. What exactly is an "agent" internally?
54. What information is contained in a child-agent spawn request?
55. What is the exact structured child-agent result format?
56. What maximum recursive depth ships as the default?
57. What maximum concurrent-agent count ships as the default?
58. How does `auto` concurrency decide how many agents to run?
59. Can developers interrupt one child without stopping its siblings?
60. Can a parent cancel a child?
61. Can a developer directly talk to a child agent?
62. Can a child request clarification directly from the developer, or must it route through its parent?
63. Can agents communicate laterally with siblings?
64. Can agents spawn children without asking the parent?
65. What happens if a child crashes?
66. What happens if the parent crashes while children are running?
67. How do timeouts work?
68. Should agents have priorities?
69. Do we need task queues?
70. How do we prevent runaway recursive delegation?

### F. Plans, artifacts, and lifecycle
71. What exact format should a plan artifact use?
72. Where are plans stored?
73. When does a task become "non-trivial" enough to require a plan by default?
74. Can a developer edit the generated plan before approving it?
75. Does editing the plan automatically become new agent context?
76. What is the exact lifecycle YAML schema?
77. What constitutes a lifecycle stage?
78. Can stages branch?
79. Can stages execute concurrently?
80. Can stages loop?
81. How are entry/exit conditions expressed?
82. Can developers create reusable lifecycle templates?
83. Can one lifecycle import/extend another?
84. How do lifecycle stages choose models, skills, permissions, sandboxes, and reviewers?
85. How does a developer resume a partially completed lifecycle?
86. What does "done" technically mean for a lifecycle stage?
87. How do manually performed developer tasks get marked complete?

### G. Reviews and approval gates
88. What exactly can a reviewer inspect?
89. Is a reviewer simply another agent role or a distinct runtime primitive?
90. Can multiple reviewers be required?
91. Can different models review the same work independently?
92. Can reviews require unanimous approval or N-of-M approval?
93. How are review findings structured?
94. What severity levels exist?
95. What findings block progression?
96. How does a developer override a failed review?
97. Is an override recorded as an auditable decision?
98. Which operations require human approval by default?
99. How do we prevent an agent from modifying the thing that defines its own approval policy?

### H. Permissions/security
100. What are the actual permission primitives?
101. Are permissions path-based, tool-based, command-based, capability-based, or a combination?
102. Can we express "read anywhere, write only under `src/`"?
103. Can shell commands be allowlisted/denylisted?
104. How do pipes, redirects, and shell composition affect command permissions?
105. How do we classify destructive commands?
106. How do MCP permissions work?
107. Can permissions differ per MCP server/tool?
108. How do environment-variable permissions work?
109. Should agents ever be allowed to read `.env` values directly?
110. How are credentials prevented from entering prompts/reports/logs?
111. What does an approval request actually show the developer?
112. Can approvals be "once", "for this session", "for this command pattern", or permanent?
113. How do child permissions interact with sandbox permissions?
114. What is the threat model for malicious repository instructions?
115. How do we defend against prompt injection in README/docs/tool output?
116. How do we prevent a malicious skill from escalating permissions?
117. Do downloaded skills/scripts require trust/approval before execution?
118. How should IFNH handle symlinks and paths escaping a repository?
119. How should IFNH protect its own `.ifnh` policy/configuration files from agents?

### I. Shell and tool execution
120. Does IFNH invoke a user's shell or execute programs directly where possible?
121. Bash/zsh/fish differences—how much should IFNH care?
122. Do we need PTY support?
123. How are long-running processes handled?
124. Can an agent start background services?
125. How are background processes tracked and cleaned up?
126. How is command output truncated/summarized before entering model context?
127. How does the agent retrieve more output if needed?
128. What exact discovery order do we use for unfamiliar commands?
129. Should IFNH cache learned CLI documentation?
130. Can developers define tool-specific policies/instructions?
131. How are custom slash commands parameterized?
132. Can slash commands call other slash commands?
133. Can slash commands invoke lifecycle stages?
134. What does `/reload` reload?

### J. MCP
135. Which MCP transports do we support in v1?
136. How are MCP servers configured?
137. User-level and project-level MCP servers?
138. How are MCP server processes started/stopped?
139. Do we support remote MCP servers initially?
140. How are MCP credentials supplied?
141. How do MCP tools enter the permission system?
142. Can only certain agents access certain MCP servers?
143. How do we handle an unavailable MCP server?
144. How much MCP tool output enters context?
145. Should IFNH ship an optional recommended research MCP configuration?
146. Do we actually build an IFNH research MCP server, or simply recommend existing ones initially?

### K. Skills and commands
147. Exactly which Agent Skills specification/version are we targeting?
148. How does skill discovery work?
149. How are user/project skills merged?
150. Can skills declare dependencies?
151. Can skills declare required executables?
152. Can skills declare MCP dependencies?
153. Can skills request permissions?
154. How are scripts packaged with skills executed safely?
155. What happens when a skill is incompatible with the current environment?
156. How does skills.sh installation work from IFNH?
157. Do we pin downloaded skill versions?
158. How are skill updates handled?
159. How does `/reload skills` work?
160. Can IFNH generate skills itself?
161. What approval is required before a generated skill becomes active?

### L. Git/worktrees
162. Do we require Git for all projects, or merely unlock additional functionality when Git exists?
163. What happens in a non-Git directory?
164. How are agent worktrees named?
165. Where physically are worktrees stored?
166. Do child agents receive branches automatically?
167. When are worktrees deleted?
168. What happens to a worktree after a failed task?
169. How do we protect dirty developer files?
170. How does patch-first editing interact with files changed after an agent started?
171. How do we detect stale patches?
172. What exactly does the developer see at the merge gate?
173. Can they approve individual hunks?
174. Can they edit a proposed patch before applying it?
175. How does the reconciliation-agent workflow work?
176. How do commits made inside child worktrees reach the main branch?
177. How do we handle repositories with submodules?
178. Monorepos?

### M. Undo/journaling
179. What constitutes one undoable "action"?
180. Patch, tool call, agent turn, or lifecycle step?
181. Do we support `/redo`?
182. How much undo history is retained?
183. Where is the journal stored?
184. How do we journal filesystem operations without copying huge files?
185. What operations are explicitly non-reversible?
186. How do we warn before a non-reversible operation?
187. How does undo interact with Git commits?
188. How does undo interact with external side effects such as database changes or MCP actions?

### N. Sandboxing
189. Which existing sandbox project were you remembering as "breadcrumbs," if we can identify it?
190. What isolation properties do we actually require?
191. Is Docker sufficient as the first optional sandbox backend?
192. Do we need a lighter Linux sandbox?
193. What's our macOS sandbox story?
194. How does networking work inside sandboxes?
195. Can policy disable network access?
196. How are project files mounted?
197. How are secrets injected?
198. How are sandbox resources limited—CPU/RAM/time?
199. Can developers define custom sandbox executors?
200. How does IFNH determine whether a test should run locally versus sandboxed?

### O. Testing
201. How does IFNH discover existing test commands?
202. Can lifecycle config explicitly define test suites?
203. How does IFNH determine which tests are relevant to a patch?
204. Should generated tests themselves always be reviewed?
205. Can an implementation agent write its own tests, or should another agent do so by default?
206. What constitutes sufficient test coverage?
207. Do we integrate coverage tools or merely consume their output?
208. How are flaky tests treated?
209. How are expensive test suites handled?
210. What happens when the repository has no tests at all?
211. Should reconnaissance propose a test strategy automatically?

### P. Hooks
212. Exact hook events?
213. Synchronous or asynchronous?
214. Can hooks block progression?
215. Can hooks modify state?
216. Can hooks invoke agents?
217. Can hooks invoke MCP?
218. Can hooks themselves require approval?
219. What happens when a hook fails?
220. How are recursive hook loops prevented?
221. Project versus user hooks?
222. What security restrictions apply to repository-provided hooks?

### Q. Memory
223. What should the minimal memory adapter interface look like?
224. Is local memory part of MVP?
225. If so, what is "local memory": files, SQLite, vectors?
226. What information may agents write to memory?
227. Is memory per-user, per-project, per-agent, or selectable?
228. Does memory retrieval happen automatically or only when requested?
229. How does the developer inspect memory?
230. How does the developer delete memory?
231. How do we prevent stale memory from overriding repository truth?
232. How do Honcho/MCP/custom memory adapters expose capabilities consistently?

### R. CLI/UX
233. What happens when you run bare `ifnh`?
234. What is the minimum first-run setup?
235. How does provider setup work?
236. Do we provide an interactive initialization wizard?
237. What does `ifnh init` do?
238. What slash commands ship by default?
239. How are slash commands discovered/listed?
240. How do users inspect running child agents?
241. How do users interrupt/cancel agents?
242. How are approval prompts displayed?
243. How do diffs render without becoming a full TUI?
244. Do we integrate with `$PAGER`?
245. How are extremely large diffs handled?
246. What accessibility/no-color modes are required?
247. How does ASCII/theme customization work?
248. What does non-interactive stdout look like so future headless support isn't painful?

### S. Observability/debugging
249. What debug levels exist?
250. What does each level record?
251. Where are logs stored by default?
252. How do developers redirect logs?
253. How does redaction work?
254. Can users inspect token usage per agent?
255. Cost per agent?
256. Time per agent?
257. Tool calls per agent?
258. Context/compaction events?
259. Do we need an `ifnh doctor` command?
260. Should crash reports be local-only unless explicitly shared?
261. How do contributors get enough diagnostics to reproduce bugs without exposing source code/secrets?

### T. Performance constraints
262. What startup-time target do we actually set?
263. What binary-size target?
264. What idle-memory target?
265. How much overhead per child agent is acceptable?
266. How do we benchmark IFNH against FX/OpenCode/Claude Code/etc.?
267. Do we establish performance regression tests in CI?
268. Which dependencies are acceptable?
269. Do dependencies need an explicit "why this belongs in core" review?
270. Where do we deliberately trade performance for correctness/security?

### U. Repository and Zig architecture
271. Monorepo or single IFNH repository?
272. Exact Zig version policy?
273. How do we structure core modules?
274. Which pieces need stable internal interfaces from day one?
275. Do providers compile into the binary or use generic protocol implementations/configuration?
276. Which third-party Zig libraries are mature enough?
277. YAML parser choice?
278. HTTP/SSE implementation?
279. JSON-RPC/MCP implementation?
280. Git: shell out to `git` or use a library?
281. Patch implementation?
282. Persistence implementation?
283. Concurrency model?
284. Process-management architecture?
285. File-watching strategy?
286. How do we unit-test provider adapters without hitting APIs?
287. How do we integration-test multi-agent behavior deterministically?

### V. Open-source governance
288. When does the internal project become public?
289. What must be cleaned/separated before publishing?
290. Contribution model?
291. `CONTRIBUTING.md` standards?
292. Architecture decision record process?
293. What requires maintainer approval?
294. How do we prevent community PRs from bloating core?
295. Should integrations live in separate repos?
296. How do we label experimental versus stable interfaces?
297. Semantic versioning?
298. Backward-compatibility guarantees for `.ifnh` configuration?
299. Backward-compatibility guarantees for skills/lifecycles?
300. Security vulnerability reporting process?

### W. Final scope questions
301. What **must** exist for you personally to replace your current coding harness with IFNH?
302. What can absolutely wait until v0.2?
303. What can wait until v1?
304. What features sound cool but violate the lightweight philosophy?
305. What are our measurable acceptance criteria for MVP?
306. Which reference projects should we benchmark directly?
307. What are IFNH's 3–5 explicit competitive differentiators?
308. What are its 3–5 explicit non-goals?
309. What parts should we prototype before committing to the architecture?
310. Finally: **what is the smallest IFNH we can build that proves the architecture is right?**

---

I'd tackle them in roughly this order: **persistence/config → instructions/context → providers → agent protocol → permissions/security → lifecycle/reviews → tools/MCP/skills → Git/sandbox/testing → CLI/performance → Zig architecture → open-source/MVP boundary.**
