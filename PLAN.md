```markdown
# IFNH — Master Design & Architecture Ledger

> **Working Name:** IFNH — "Insert Flashy Name Here"  
> **Status:** Discovery / Architecture Design  
> **Implementation Language:** Zig  
> **License Target:** MIT  
> **Initial Platforms:** Linux and macOS  
> **Document Purpose:** Canonical source of truth for IFNH product philosophy, architecture, accepted design decisions, defaults, configuration philosophy, and unresolved questions.
>
> This document should be updated whenever an architectural or product decision changes. Engineers and coding agents should treat accepted decisions here as authoritative unless superseded by a later recorded decision.

---

# 1. Executive Summary

IFNH is a blazing-fast, lightweight, highly configurable, open-source agentic coding harness written in Zig.

It is intended primarily for:

- Senior developers.
- Experienced junior developers.
- Developers who understand their architecture and tooling.
- Developers who want AI assistance without surrendering control of their development environment.
- Developers who may occasionally want high-autonomy "vibe coding," but do not want autonomy forced upon them.
- Developers who use many different model providers, local models, tools, workflows, and development environments.

IFNH should provide the fundamental capabilities required for serious agentic software development without becoming a heavyweight terminal IDE.

The core philosophy is:

> **Small engine. Powerful composition. Developer-controlled intelligence.**

IFNH should be fast enough to start and stop almost immediately, small enough to understand and audit, and flexible enough that sophisticated behavior comes primarily from configuration, lifecycle definitions, skills, MCP servers, external tools, and developer instructions rather than an ever-growing core binary.

The goal is not to build another Claude Code, Codex, OpenCode, or heavyweight coding environment.

The goal is to build a minimal, extremely fast **agent orchestration and coding runtime** that advanced developers can shape into the harness they want.

---

# 2. Primary Inspiration

The strongest architectural/product inspiration is Vercel's `fx` project and its emphasis on a lightweight, fast coding-agent experience.

Other projects and ecosystems should be researched for specific ideas rather than blindly replicated.

Important references include:

- Vercel Labs `fx`
- OpenCode
- Claude Code and compatible/reimplemented ecosystems
- OpenAI Codex
- Grok-oriented coding harnesses / Grok Build
- PostHog's coding agent / coding wizard
- Ponytail
- Agent Skills / skills.sh ecosystem
- AGENTS.md
- CLAUDE.md
- MCP
- Honcho / Plastic Labs
- Existing lightweight sandboxing projects
- Existing multi-agent and swarm orchestration research

IFNH should borrow good ideas while maintaining its own architectural constraint:

> **A feature should not enter the Zig core simply because another coding harness has it.**

---

# 3. Product North Star

IFNH should be:

- Blazing fast.
- Lightweight.
- Local-first.
- Open source.
- MIT licensed.
- Provider agnostic.
- Model agnostic.
- Tool agnostic.
- Highly configurable.
- Developer-first.
- Auditable.
- Composable.
- Multi-agent capable.
- Safe by default without being restrictive by design.
- Suitable for both careful human-supervised development and high-autonomy workflows.

The developer should control:

- Providers.
- Models.
- Agent behavior.
- Agent count.
- Model routing.
- Permissions.
- Approval gates.
- Skills.
- Commands.
- Lifecycles.
- Hooks.
- MCP servers.
- Memory.
- Sandboxing.
- Git behavior.
- Testing requirements.
- Review requirements.
- Context management.
- Debugging.
- UI appearance.
- Autonomy.

---

# 4. Architectural Constraints

These are architectural constraints, not merely preferences.

## 4.1 Zig

The core IFNH application will be written in Zig.

Avoid introducing additional runtime languages into the core application.

External integrations may naturally use whatever technology they require, but the IFNH executable itself should remain a Zig application.

---

## 4.2 Single Native Binary

IFNH should compile to a single native executable wherever practical.

The desired installation experience is eventually similar to:

```bash
ifnh
```

without requiring a Node.js, Python, JVM, or similar runtime.

Distribution can eventually include:

- Direct binary downloads.
- Shell installer.
- Homebrew.
- Linux package managers where appropriate.

---

## 4.3 Startup Performance

Near-instant startup and shutdown are product requirements.

New features should be evaluated against:

- Startup latency.
- Binary size.
- Runtime memory.
- Architectural complexity.
- Dependency count.

A feature that can reasonably exist outside the core should generally exist outside the core.

---

## 4.4 Linux + macOS First

Version 1 targets:

- Linux.
- macOS.

Native Windows support is roadmap work.

Architecture should avoid unnecessarily preventing future Windows support.

---

# 5. Core vs. Integration Philosophy

IFNH should have a deliberately small core.

The core should own things such as:

- Configuration.
- Agent orchestration.
- Provider abstraction.
- Model interaction.
- Tool invocation.
- Permission enforcement.
- Approval gates.
- Lifecycle execution.
- Sessions.
- Checkpoints.
- Worktree coordination.
- Patching.
- Undo/journaling.
- MCP client functionality.
- Skills/instruction discovery.
- Lightweight CLI rendering.

Things that can live outside the core should generally remain outside it.

Examples:

- Web search.
- Web crawling.
- Specialized documentation retrieval.
- Vendor integrations.
- Specialized memory engines.
- Cloud-specific services.
- Specialized development tools.

The guiding principle is:

> **IFNH understands how to safely use tools. It does not need to understand every tool.**

---

# 6. Configuration Philosophy

Almost every meaningful behavior in IFNH should be configurable.

However:

> **Configurable must not mean complicated.**

A developer should be able to install IFNH and immediately use it with sensible defaults without writing configuration.

Advanced developers should then be able to progressively override those defaults.

---

# 7. Configuration Precedence

Configuration should follow deterministic layering.

From lowest to highest precedence:

1. Built-in defaults.
2. User-level configuration.
3. Project-level configuration.
4. Session-level overrides.

Conceptually:

```text
defaults
    ↓
user
    ↓
project
    ↓
session
```

Higher layers override lower layers.

IFNH should eventually expose something conceptually similar to:

```bash
ifnh config explain
```

This should allow developers to determine:

- Current value.
- Default value.
- Which configuration layer changed it.
- Which file supplied it.
- Whether the current session overrides it.

Example question IFNH should be able to answer:

> Why is `agents.max_parallel` currently 4?

---

# 8. Configuration Formats

## YAML

YAML should be used for structured behavior and configuration.

Examples:

- Providers.
- Models.
- Agent policies.
- Lifecycles.
- Permissions.
- Hooks.
- Budgets.
- Sandboxing.
- MCP.
- Memory.
- UI behavior.
- Git policies.
- Model routing.

## Markdown

Markdown should be used for human-readable intelligence and instructions.

Examples:

- Skills.
- Commands.
- Coding standards.
- Review instructions.
- Reconnaissance instructions.
- Agent instructions.
- Project context.

## Environment

Environment variables and `.env` files should initially handle secrets.

Possible supported conventions include:

```text
.env
.env.local
.env.example
.env.template
```

Secret-store integrations can come later.

---

# 9. Project Directory

The conventional project-local IFNH directory is:

```text
.ifnh/
```

IFNH should **not require** this directory to operate.

Zero-config operation must remain possible.

The directory appears when the developer wants project-specific behavior/state.

A future structure may resemble:

```text
.ifnh/
├── config.yaml
├── lifecycle/
├── skills/
├── commands/
├── agents/
├── reports/
├── checkpoints/
├── sessions/
├── hooks/
└── debug/
```

This exact schema is **not yet finalized**.

Do not prematurely lock the implementation to this tree.

---

# 10. Hot Configuration Reloading

Configuration should not only be read once when IFNH starts.

IFNH should re-evaluate relevant configuration at defined policy/action checkpoints.

For example, before:

- Spawning an agent.
- Executing a privileged command.
- Performing Git operations.
- Entering a lifecycle stage.
- Merging work.
- Running a hook.
- Performing destructive operations.

This allows developers to change permissions or policies during an active session.

The goal is not literally parsing every configuration file before every token.

The goal is:

> **Configuration changes should become effective during a running session at predictable safety boundaries.**

---

# 11. Provider and Model Architecture

IFNH must be provider agnostic and model agnostic.

The core should operate against a generic model/provider interface.

Possible providers include:

- OpenRouter.
- OpenAI.
- Anthropic.
- Z.AI.
- Vercel AI Gateway.
- Ollama.
- llama.cpp.
- Custom OpenAI-compatible APIs.
- Company model proxies.
- Future providers.

Common providers may have convenient preconfigured adapters.

The architecture must not require a specific gateway.

---

# 12. Capability-Based Providers

Provider behavior should ideally be capability-driven.

The runtime may need to understand capabilities such as:

- Streaming.
- Tool calling.
- Reasoning.
- Structured output.
- Context window.
- Cost information.
- Image support.
- Prompt caching.
- Other provider-specific capabilities.

Agent logic should depend on capabilities where possible rather than provider names.

---

# 13. Model Routing

Parent and child agents do not need to use the same model.

A developer may configure:

```text
Parent:
Large reasoning model

Research agents:
Cheaper model

Simple implementation agents:
Small model

Reviewer:
Strong reasoning model
```

Model routing should be configurable.

IFNH should not force users to manually select a model every time an agent is spawned.

---

# 14. Multi-Agent Runtime

Multi-agent orchestration is a first-class IFNH capability.

A parent agent should be capable of recursively spawning child agents when policy allows.

Example:

```text
Developer
    ↓
Primary Agent
    ├── Research Agent A
    ├── Research Agent B
    ├── Architecture Agent
    └── Implementation Agent
             ↓
         Test Agent
```

Recursive spawning should be possible.

It should not be mandatory.

---

# 15. Autonomy Is Policy-Driven

IFNH should support developers who want:

- No proactive agents.
- Limited delegation.
- Explicit agent spawning.
- Automatic delegation.
- Recursive autonomous delegation.
- Nearly end-to-end autonomous implementation.

The harness must not impose one philosophy.

A developer should be able to move between:

```text
STRICT MANUAL
      ↓
ASSISTED
      ↓
DELEGATED
      ↓
HIGH AUTONOMY
```

without changing harnesses.

---

# 16. Sequential vs. Parallel Agents

Agent execution strategy must be configurable.

Supported concepts:

```text
sequential
parallel
auto
```

The developer may choose based on:

- Available compute.
- Network conditions.
- API rate limits.
- Cost.
- Local inference hardware.
- Nature of the task.

`auto` may eventually allow IFNH to determine sensible concurrency.

---

# 17. Agent Budgets

Budget controls should be first-class but optional.

Possible controls include:

- Maximum child agents.
- Maximum recursive depth.
- Maximum concurrent agents.
- Maximum estimated spend.
- Token budgets.
- Model-specific budgets.

If no limit is configured and IFNH predicts a substantial run, it may ask something conceptually similar to:

> This plan may spawn approximately 8 agents and is estimated to cost approximately $X using the currently configured models. Continue? Set a limit?

The developer remains in control.

---

# 18. Agent Isolation

The default isolation mechanism for code-editing child agents should be:

> **Git worktrees.**

Each agent can operate independently without several models simultaneously editing the same working tree.

Alternative execution environments should be configurable.

Examples:

- Current working directory.
- Git worktree.
- Docker container.
- Lightweight sandbox.
- Custom executor.

IFNH should investigate existing lightweight sandboxing projects rather than unnecessarily creating its own sandbox technology.

---

# 19. Child-Agent Results

Child agents should not simply dump their entire context into the parent's context.

Each child should produce a durable, structured Markdown report.

Reports should live in a predictable project location.

A report may include:

```markdown
# Agent Report

## Assignment

## Findings

## Decisions

## Changes Made

## Files Changed

## Tests Performed

## Risks

## Open Questions

## Recommended Next Action
```

The parent consumes the structured result.

This provides:

- Auditability.
- Better context efficiency.
- Debugging.
- Easier model experimentation.
- Human review.
- Durable project history.

An IFNH cleanup operation should eventually be able to remove old generated reports/state when requested.

---

# 20. Agent Communication Auditability

Agent-to-agent communication should produce durable artifacts where appropriate.

The developer should be able to inspect how:

- Parent instructions were interpreted.
- Child agents responded.
- Different prompts affect delegation.
- Different models affect results.

However, full transcripts are not persisted by default.

---

# 21. Debug Mode

Detailed logging should be optional.

Normal operation should remain clean.

Higher debug levels may persist:

- Full transcripts.
- Provider requests/responses where safe.
- Tool execution information.
- Errors.
- Agent communication.
- Lifecycle transitions.
- Configuration decisions.

Debug artifacts should live in a predictable directory.

The developer should eventually be able to configure whether debug information is:

- Project-local.
- User-level.
- Stored elsewhere.

Debug logging should redact recognized secrets by default.

---

# 22. Session Persistence

Sessions must be resumable.

IFNH should automatically persist enough state to resume meaningful work.

Normal session state should include things such as:

- Compacted context.
- Decisions.
- Plans.
- Agent reports.
- Pending approvals.
- Worktree references.
- Lifecycle state.
- Provider/model metadata.
- Relevant configuration references/snapshots.
- Checkpoints.

It should **not** persist gigantic full transcripts by default.

Full transcripts belong to elevated debug modes.

Conceptually:

```bash
ifnh resume
```

should allow a developer to continue previous work.

Multiple-session selection should eventually be supported.

---

# 23. Session Forking

Session branching/forking is a first-class capability.

A developer should be able to reach a checkpoint and explore multiple alternatives.

Conceptually:

```text
Session A
   |
Checkpoint
   |
   ├── Fork B → Architecture Option 1
   |
   └── Fork C → Architecture Option 2
```

A fork inherits relevant state up to the checkpoint and then diverges.

This should integrate naturally with Git worktrees.

---

# 24. Context Management

IFNH should support both manual and automatic context compaction.

A slash command should eventually allow manual compaction.

Automatic compaction should be configurable.

A hard safety threshold may require compaction to prevent provider/context-window failure.

Compaction should produce a structured durable checkpoint rather than simply throwing old context away.

The checkpoint should preserve important information such as:

- Requirements.
- Decisions.
- Constraints.
- Current plan.
- Completed work.
- Outstanding work.
- Relevant references.

---

# 25. Permissions

Permissions are first-class.

The user defines the ultimate permission ceiling.

A parent agent delegates only the permissions required for a child task.

Conceptually:

```text
USER POLICY
    ↓
PARENT CEILING
    ↓
TASK-SPECIFIC CHILD PERMISSIONS
```

A child can receive fewer permissions than the parent.

A child must not exceed the user-defined ceiling.

Default delegation should follow least privilege.

---

# 26. Permission Instructions

Permission behavior should be configurable using human-readable project/user instructions in addition to structured policy where appropriate.

Before spawning a child, the parent can determine:

1. What task is being delegated.
2. What capabilities are required.
3. What the current policy allows.
4. The smallest reasonable permission set.

The resulting permission set is attached to the child.

---

# 27. Approval Gates

Action/review behavior is central to IFNH.

Developers should be able to define actions requiring:

- No approval.
- Agent review.
- Specialized reviewer.
- Human approval.
- Multiple review stages.

Examples might include:

- Architectural changes.
- Database migrations.
- Dependency additions.
- Security-sensitive code.
- Destructive commands.
- Git pushes.
- Force pushes.
- Production operations.

---

# 28. Planning

Plans should be first-class artifacts.

For non-trivial tasks, the default behavior should generally be:

```text
Understand
    ↓
Plan
    ↓
Present Plan
    ↓
Developer Approval
    ↓
Execute
```

The plan should still exist in autonomous mode.

Autonomous mode changes the approval requirement; it should not necessarily eliminate planning.

---

# 29. Review Loop

A conceptual action/review cycle:

```text
PLAN
  ↓
ACTION
  ↓
REVIEW
  ↓
PASS / FAIL
```

If review fails, **default behavior is to return control to the developer**.

IFNH should not automatically enter an infinite repair loop.

The developer can choose to:

- Fix manually.
- Ask the original agent to fix it.
- Spawn another agent.
- Enable an automatic fix/review loop.

Automatic remediation is opt-in.

Ponytail should be studied for accountable coding/review patterns.

---

# 30. Git Behavior

Git behavior must be configurable.

Depending on policy, IFNH may be allowed to:

- Read repository state.
- Create branches.
- Create worktrees.
- Stage files.
- Commit.
- Push.
- Create new branches remotely.
- Force push.

Or IFNH may be prohibited from doing any of those things.

The developer controls the ceiling.

---

# 31. Dirty Working Trees

IFNH must protect developer-owned uncommitted work.

Default behavior:

> **Never automatically stash, discard, commit, overwrite, or otherwise manipulate pre-existing developer changes.**

When IFNH starts in a dirty repository, it should detect and identify the existing changes.

Those changes should be considered developer-owned.

IFNH may propose safe ways to work around them, including creating isolated worktrees from the current Git state where appropriate.

Any operation that could affect the developer's existing changes requires explicit approval.

---

# 32. Merge Behavior

Default behavior after an implementation passes review:

> **Show the developer the diff. Do not automatically merge it.**

The developer approves or rejects the merge.

Trusted/autonomous configurations may eventually allow automatic merging.

The default remains human review.

---

# 33. Concurrent Edit Conflicts

If multiple isolated agents produce conflicting changes:

> **Stop and surface the conflict to the developer.**

Do not silently ask another model to decide which code wins.

IFNH should then offer an optional action:

> Spawn an integration/reconciliation agent?

If selected, the reconciliation agent receives relevant:

- Original requirements.
- Plans.
- Agent reports.
- Diffs.
- Tests.
- Conflicting implementations.

It proposes a combined solution.

That proposed solution still goes through normal review/diff approval.

---

# 34. Patch-First Editing

IFNH should use patch-based edits by default.

Advantages:

- Smaller model output.
- Easier review.
- Better auditability.
- Easier undo.
- Clearer diffs.
- Lower chance of accidental unrelated changes.

Full-file operations remain available when appropriate, especially:

- Creating files.
- Replacing very small files.
- Explicit developer requests.
- Situations where patching is impractical.

---

# 35. Undo / Reversible Actions

Reversible actions are a core requirement.

IFNH should journal mutating actions sufficiently to support something conceptually similar to:

```text
/undo
```

This should be distinct from:

```bash
git reset
```

The goal is to undo an IFNH/agent action without destroying unrelated developer work.

Actions that should be considered include:

- File patches.
- File creation.
- File deletion.
- Other reversible workspace mutations.

Git remains the larger source-of-truth boundary.

---

# 36. Tool Philosophy

IFNH should **not** contain built-in integrations for every development tool.

The native tool kernel should remain small.

Likely primitives include:

- File read.
- File search.
- Patch/write.
- Shell execution.
- Git/worktree operations.
- Agent spawn.
- Agent communication.
- Permission request.
- Lifecycle/control operations.

Everything else can generally be reached through the shell or MCP.

---

# 37. Arbitrary Developer Tools

Developers use enormous numbers of tools, including custom internal CLIs.

Examples:

```text
zig
npm
pnpm
cargo
go
docker
kubectl
terraform
gh
aws
gcloud
vercel
custom-company-cli
```

IFNH should not require native knowledge of them.

Instead, it should be capable of discovering how to use them.

---

# 38. Tool Discovery

When an agent encounters an unfamiliar command, default behavior is:

> **Discover before interrupting the developer.**

The discovery sequence can conceptually inspect:

1. Existing loaded skill/instruction information.
2. `command --help`.
3. `command -h`.
4. Man pages.
5. Local README/documentation.
6. Relevant repository documentation.
7. Configured MCP documentation/research tools.
8. Ask the developer if ambiguity remains.

All command execution remains subject to permissions.

---

# 39. Slash Commands

Developers should be able to define custom slash commands without recompiling IFNH.

Commands can primarily be disk-backed Markdown/instruction definitions.

Examples:

```text
/deploy-staging
/run-mobile-tests
/review-auth
/recon
/compact
```

Runtime loading keeps the Zig binary small.

A reload mechanism should eventually allow newly installed/created commands and skills to become available during an active environment.

No marketplace is required for MVP.

---

# 40. Skills

IFNH should favor compatibility with existing skills standards rather than inventing an incompatible proprietary format.

Support should include the established Agent Skills / `SKILL.md` ecosystem where practical.

Skills may include:

- Markdown instructions.
- References.
- Supporting files.
- Scripts where the standard permits them.

Compatibility with skills.sh is desirable.

---

# 41. Skill Scope

Skills may exist at multiple scopes:

```text
USER
PROJECT
```

There is no IFNH cloud "account" requirement.

Project skills can override or supplement user skills according to deterministic precedence rules.

---

# 42. Instruction Compatibility

IFNH should interoperate with common project instruction conventions.

Important examples:

```text
AGENTS.md
CLAUDE.md
SKILL.md
```

IFNH should normalize relevant instructions internally rather than forcing developers to rewrite existing repositories around IFNH.

Exact discovery and precedence behavior still needs specification.

---

# 43. First-Party / Self-Improvement Skills

IFNH may ship with a small optional set of first-party skills.

These should provide useful capabilities without bloating the core executable.

Examples:

- Create a skill.
- Improve an existing skill.
- Create a lifecycle.
- Generate tests.
- Analyze an unfamiliar repository.
- Create project instructions.
- Improve project instructions.
- Review configuration.

This allows IFNH to help developers configure IFNH itself.

These behaviors should remain explicit and auditable.

IFNH should not silently rewrite its own instructions.

---

# 44. MCP

MCP support is mandatory.

MCP should be a first-class extension mechanism.

Agents may use configured MCP servers for:

- Research.
- Documentation.
- External systems.
- Databases.
- Developer tools.
- Memory.
- Company systems.
- Other integrations.

MCP access remains governed by IFNH permissions.

---

# 45. Web Research

Native web crawling/search does **not** need to live in the Zig core.

Web research should primarily be provided through MCP.

IFNH may eventually provide an easy path to configure a recommended research MCP server.

However:

> The MCP implementation must remain generic.

Developers should be able to replace the recommended server with:

- Their own MCP.
- A commercial search MCP.
- Documentation MCPs.
- Company infrastructure.
- Future providers.

IFNH should not depend on an IFNH-operated web service.

---

# 46. Memory

Memory should be optional and provider/backend agnostic.

Potential memory configurations include:

```text
none
local
Honcho
MCP-backed
custom vector storage
provider-backed
custom adapter
```

Honcho by Plastic Labs should be researched as one reference implementation.

IFNH must function perfectly well without persistent external memory.

Memory should therefore be an extension interface rather than a hard dependency.

---

# 47. Secrets

MVP secrets support:

- Environment variables.
- `.env` conventions.

External secret stores are roadmap work.

The architecture should not prevent later integrations such as:

- OS keychains.
- Vault.
- Cloud secret managers.

Secrets must be redacted from logs/debug output where recognizable.

---

# 48. Project Lifecycle Engine

A configurable project lifecycle is an important differentiator.

IFNH should not only be capable of responding to prompts.

It should optionally help developers move through structured software-development processes.

Possible lifecycle:

```text
RECONNAISSANCE
      ↓
RESEARCH
      ↓
REQUIREMENTS
      ↓
ARCHITECTURE
      ↓
PLAN
      ↓
SCAFFOLD
      ↓
IMPLEMENT
      ↓
TEST
      ↓
REVIEW
      ↓
HUMAN APPROVAL
      ↓
MERGE
```

This is an example, not a hard-coded workflow.

---

# 49. Lifecycle Configuration

Lifecycles should be human-readable and configurable, likely using YAML.

Conceptually:

```yaml
lifecycle:
  stages:
    - reconnaissance
    - research
    - architecture
    - implementation
    - testing
    - review
```

A lifecycle stage may eventually define:

- Instructions.
- Agent role.
- Model routing.
- Skills.
- Permissions.
- Required artifacts.
- Entry conditions.
- Exit conditions.
- Tests.
- Hooks.
- Reviewers.
- Human approval.
- Budget.

The exact schema remains to be designed.

---

# 50. Assisted Lifecycle Creation

IFNH should be able to help the developer create or modify lifecycle stages.

Examples:

> Create the testing stage for this project.

> Design a lifecycle for this existing React Native repository.

> Add a security review between implementation and merge.

> Generate the unit-test requirements for this feature.

This can be implemented through optional first-party skills rather than large hard-coded core behavior.

---

# 51. Reconnaissance

Repository reconnaissance should be available as a reusable lifecycle capability/skill.

It should not automatically run in every repository unless configured.

When invoked, it should be able to investigate things such as:

- Repository structure.
- Languages.
- Frameworks.
- Build commands.
- Tests.
- Existing instructions.
- CI/CD.
- Dependencies.
- Architecture.
- Dangerous areas.
- Generated files.
- Code-quality rules.
- Git state.
- Development conventions.
- Documentation.

It should produce a durable structured artifact.

---

# 52. Testing

Testing should be treated as part of the lifecycle rather than an afterthought.

IFNH should encourage agents to understand:

- Existing tests.
- Required new tests.
- Appropriate unit tests.
- Integration tests.
- Project-specific test commands.
- Whether generated tests actually test meaningful behavior.

A possible sequence:

```text
IMPLEMENT
   ↓
VERIFY TEST EXISTS
   ↓
REVIEW TEST QUALITY
   ↓
RUN TEST IN APPROPRIATE ENVIRONMENT
   ↓
REVIEW RESULT
```

Exact behavior remains configurable.

---

# 53. Sandboxed Testing

Developers should be able to configure tests to execute in:

- Current environment.
- Worktree.
- Docker.
- Lightweight sandbox.
- Custom executor.

IFNH should avoid forcing Docker when it is unnecessary.

---

# 54. Hooks

A lightweight hook engine is desirable.

Hooks should be configuration-driven.

Potential events include:

```text
before_action
after_action
before_tool
after_tool
before_agent
after_agent
before_test
after_test
before_merge
after_merge
```

Exact hook names are not finalized.

Example use:

```text
Feature completed
      ↓
Hook checks test existence
      ↓
Reviewer examines test
      ↓
Test runs in sandbox
      ↓
Result evaluated
```

Hooks should remain thin orchestration primitives rather than becoming a giant plugin framework.

---

# 55. UI Philosophy

IFNH should **not** become a full-screen TUI.

The interface should remain a lightweight streaming CLI.

Desired characteristics:

- Immediate startup.
- Streaming output.
- Normal terminal history remains useful.
- Works well over SSH.
- Low rendering overhead.
- Easy piping/composition where practical.

---

# 56. Multi-Agent Status UI

By default, active agents should have a small status representation.

Example concept:

```text
● parent         running
● research-1     running
✓ research-2     complete
○ reviewer       waiting
```

This is not a full TUI.

Status rendering should be configurable.

Possible options:

- Colors.
- Symbols.
- ASCII art.
- Spinner/loading art.
- Verbosity.
- Completely disabled.

---

# 57. Appearance

Visual customization should be possible without bloating the core.

Potential customization:

- Colors.
- Symbols.
- ASCII branding.
- Loading animations.
- Status styles.

Appearance configuration should be data-driven where practical.

---

# 58. Headless Mode

Fully headless/non-interactive execution is desirable but **not an MVP requirement**.

Roadmap examples:

```bash
ifnh run ...
```

inside:

- CI/CD.
- Scripts.
- Other agents.
- Automation systems.

The architecture should avoid making future headless support unnecessarily difficult.

---

# 59. Human Approval Defaults

IFNH is designed for capable developers.

Its defaults should favor accountability.

Default examples:

- Show non-trivial plan before execution.
- Show diff before merge.
- Stop after failed review.
- Stop on conflicting concurrent edits.
- Protect pre-existing dirty worktrees.
- Ask before dangerous actions.
- Least-privilege child permissions.

Developers may deliberately loosen those controls.

---

# 60. Configurable Autonomy

The system should make it possible to configure anything from:

```text
"Do exactly what I explicitly tell you."
```

to:

```text
"Research, plan, delegate, implement, test, review and prepare the final changes."
```

and potentially eventually:

```text
"Handle the lifecycle autonomously within these policies and budgets."
```

The architecture should not treat one of these as the universally correct workflow.

---

# 61. Philosophy of Defaults

IFNH should follow:

> **Strong defaults, weak assumptions.**

Defaults should provide a safe, useful experience.

They must be easy to replace.

---

# 62. Architecture Principle: Policy vs. Mechanism

Where possible, separate mechanism from policy.

Example:

**Mechanism**

> IFNH can create Git commits.

**Policy**

> This project does not allow agents to create commits.

---

**Mechanism**

> IFNH can recursively spawn agents.

**Policy**

> Maximum agent depth is 1.

---

**Mechanism**

> IFNH can automatically repair failed reviews.

**Policy**

> Stop and ask the developer instead.

This separation is fundamental to IFNH's configurability.

---

# 63. Architecture Principle: Runtime Extensibility Over Compilation

Capabilities expressed as:

- Markdown.
- YAML.
- Skills.
- Commands.
- MCP configuration.
- Lifecycle definitions.

should generally load at runtime.

Adding a Markdown slash command should not require recompiling IFNH.

Recompilation should generally only be necessary for actual native/core functionality.

---

# 64. Architecture Principle: Durable Artifacts Over Hidden Context

Important decisions should not exist solely inside an LLM context window.

Prefer durable artifacts for:

- Plans.
- Agent reports.
- Architecture decisions.
- Lifecycle state.
- Checkpoints.
- Reviews.
- Important findings.

This improves:

- Auditability.
- Resume behavior.
- Context efficiency.
- Debugging.
- Collaboration.
- Reproducibility.

---

# 65. Architecture Principle: Developer-Owned Work Is Sacred

IFNH must distinguish between:

- Work created by IFNH.
- Work created by agents.
- Work already present when IFNH arrived.
- Work created manually by the developer during the session.

Developer work should never be casually overwritten because an agent believes another state is preferable.

---

# 66. Architecture Principle: No Forced Ecosystem

IFNH should not require:

- A hosted IFNH account.
- An IFNH cloud.
- An IFNH model gateway.
- An IFNH memory provider.
- An IFNH web search provider.
- A proprietary skills marketplace.

An ecosystem may eventually exist around IFNH.

The core harness should remain independently useful.

---

# 67. Architecture Principle: Open Source Friendly

IFNH begins as an internal tool but is intended to become publicly announced open-source software and accept community contributions.

Therefore:

- Core boundaries need to be explicit.
- Extension points need to be clear.
- Configuration needs documentation.
- Contributor changes should not casually expand the binary.
- Provider-specific code should remain isolated.
- Integrations should generally live outside core when possible.
- Architecture decisions should be documented.

---

# 68. License

Target license:

**MIT**

Any borrowed or incorporated implementation must be license-compatible.

Existing projects should be used as architectural references unless their licenses explicitly permit code reuse under IFNH's intended licensing model.

License review must occur before directly porting code.

---

# 69. Current MVP Direction

The exact MVP is not finalized, but current likely foundational requirements include:

- Zig implementation.
- Single native binary.
- Linux.
- macOS.
- Streaming CLI.
- Provider abstraction.
- Multiple provider support.
- Custom endpoints.
- Basic configuration system.
- User/project/session config layering.
- `.ifnh/`.
- File operations.
- Patch-based editing.
- Shell execution.
- Git awareness.
- Worktree support.
- Basic permissions.
- Approval gates.
- Sessions.
- Resume.
- Context compaction.
- Agent spawning.
- Structured child reports.
- Sequential/parallel execution.
- Model routing.
- Skills/instruction loading.
- AGENTS.md compatibility.
- CLAUDE.md compatibility.
- MCP client support.
- Basic lifecycle engine.
- Diff review before merge.
- Dirty-working-tree protection.
- Lightweight agent status rendering.

This list must be refined before implementation begins.

---

# 70. Likely Post-MVP / Roadmap

Current likely roadmap candidates:

- Native Windows.
- Fully headless mode.
- CI/CD-first execution.
- Broader secret-store integrations.
- More sophisticated memory adapters.
- Package-manager distribution expansion.
- Richer lifecycle tooling.
- More advanced cost estimation.
- Advanced sandbox integrations.
- Community extension ecosystem.
- Optional recommended IFNH MCP services.
- More sophisticated session comparison.
- More sophisticated autonomous reconciliation.
- Additional first-party skills.

Roadmap placement is not permanent.

---

# 71. Explicit Non-Goals — Current Direction

Unless future discovery changes this, IFNH is **not** trying to become:

- A full IDE.
- A full-screen TUI.
- A model provider.
- A model gateway.
- A hosted SaaS requirement.
- A web search engine.
- A container runtime.
- A Git replacement.
- A proprietary skills ecosystem.
- An integration for every developer CLI.
- An opinionated autonomous coding methodology that everyone must follow.

---

# 72. Repositories / Projects Requiring Deeper Research

Before the engineering architecture is finalized, conduct structured research into:

## Core inspiration

- Vercel Labs `fx`

Questions:

- Architecture.
- Zig conventions.
- Dependency strategy.
- Terminal rendering.
- Provider implementation.
- Streaming.
- Tool calling.
- Session handling.
- Binary size.
- Build system.
- License.

## OpenCode

Research:

- Provider configuration.
- Model abstraction.
- Skills.
- Commands.
- Configuration layering.
- MCP.
- Session handling.
- Plugin/extension behavior.

## Claude Code ecosystem

Research:

- CLAUDE.md behavior.
- Commands.
- Skills.
- Hooks.
- Permission models.
- Agent delegation.

## OpenAI Codex

Research:

- Sandboxing.
- Tool architecture.
- Git interaction.
- Approval model.
- Agent behavior.

## Grok Build / relevant Grok coding harness

Research:

- Multi-agent UX.
- Delegation.
- Parallelism.
- Review mechanisms.

## PostHog coding wizard/agent

Research specifically:

- Project lifecycle architecture.
- Planning.
- Testing.
- Workflow stages.
- Developer interaction model.

## Ponytail

Research specifically:

- Accountable code-quality patterns.
- Action/review loops.
- Approval philosophy.
- Agent instructions.
- Review behavior.

## skills.sh / Agent Skills

Research:

- Canonical format.
- Skill discovery.
- Installation.
- Scope.
- Dependencies.
- Scripts.
- Security considerations.

## Honcho / Plastic Labs

Research:

- Memory interface.
- Self-hosting.
- APIs.
- Agent integration patterns.
- Whether an adapter or MCP implementation is preferable.

## Lightweight sandbox projects

Research existing systems before designing anything custom.

Desired properties:

- Fast startup.
- Strong enough isolation for coding-agent execution.
- Low resource usage.
- Linux/macOS viability where possible.
- Easy external integration.

---

# 73. Zig Research Required

Before implementation, research current Zig conventions and ecosystem options for:

- HTTP clients.
- SSE/streaming.
- JSON.
- YAML.
- TOML if needed.
- Process execution.
- PTYs.
- Terminal rendering.
- File watching.
- Async/concurrency.
- Git integration.
- Patch parsing/application.
- MCP protocol implementation.
- JSON-RPC.
- WebSockets if needed.
- SQLite or alternative lightweight persistence if needed.
- Cross-platform filesystem handling.
- Process isolation.
- Signal handling.
- Secure secret handling.
- Configuration parsing.
- Testing.
- Packaging.

Priority should be given to:

- Zig standard library.
- Small audited dependencies.
- Compile-time simplicity.
- Binary size.
- Startup speed.

---

# 74. Major Architecture Questions Still Open

These remain unresolved and should be addressed one at a time.

## Persistence

- Files only?
- SQLite?
- Hybrid?
- What belongs in `.ifnh/` versus user state?

## Exact Configuration Schema

- Exact filenames.
- Exact YAML schema.
- User configuration location.
- Project configuration location.

## Instruction Precedence

Need exact rules for conflicts between:

- AGENTS.md.
- CLAUDE.md.
- Skills.
- User instructions.
- Project instructions.
- Lifecycle instructions.
- Session instructions.

## Provider API

Need exact internal Zig interface.

## Tool API

Need exact native tool contract.

## Agent Protocol

Need exact parent/child task and response schema.

## Lifecycle Schema

Need exact stage schema.

## Permission Schema

Need exact capabilities and inheritance/delegation rules.

## Hooks

Need exact event model.

## Sandboxing

Need external systems research.

## Cost Estimation

Need determine how reliable provider/model pricing information can be.

## MCP

Need transport/security/configuration design.

## Memory

Need adapter contract.

## Undo

Need determine journaling strategy.

## Session Forking

Need exact relationship between sessions, checkpoints, Git branches, and worktrees.

## Debugging

Need debug levels and redaction design.

## Cleanup

Need lifecycle for:

- Worktrees.
- Agent reports.
- Debug transcripts.
- Sessions.
- Checkpoints.
- Temporary sandboxes.

---

# 75. Accepted Decision Ledger

The following decisions have been explicitly accepted during discovery.

### D001 — Zig Core

IFNH will be written in Zig.

### D002 — Lightweight Core

Startup speed, shutdown speed, binary size, and architectural simplicity are core requirements.

### D003 — Provider Agnostic

IFNH will support arbitrary providers/models through an abstraction layer.

### D004 — Recursive Multi-Agent

Parent agents may recursively spawn child agents when policy permits.

### D005 — Configurable Agent Execution

Sequential, parallel, and eventually automatic execution strategies should be supported.

### D006 — Policy-Driven Autonomy

Developers control how proactive/autonomous IFNH is.

### D007 — Action/Review Architecture

Planning, action, and review are first-class concepts.

### D008 — Failed Review Stops by Default

A failed review returns control to the developer unless automatic remediation is explicitly enabled.

### D009 — Worktrees Default

Isolated Git worktrees are the preferred default for concurrent coding agents.

### D010 — Pluggable Execution/Sandboxing

Alternative execution environments may be configured.

### D011 — Structured Child Reports

Child agents return structured Markdown artifacts.

### D012 — Resume

Sessions must be resumable.

### D013 — Full Transcripts Debug Only

Full transcripts are persisted only when debug configuration requests them.

### D014 — Session Forking

Sessions can branch from checkpoints.

### D015 — Least-Privilege Delegation

Children receive only permissions necessary for their task within the user's permission ceiling.

### D016 — Existing Skills Compatibility

Prefer compatibility with existing Agent Skills conventions.

### D017 — AGENTS.md / CLAUDE.md Compatibility

Existing project instruction conventions should be supported.

### D018 — User + Project Skill Scope

Skills may be user-global or project-local.

### D019 — MCP Mandatory

MCP is a required first-class capability.

### D020 — Web via MCP

Web search/research does not need to live in the Zig core.

### D021 — Memory Is Pluggable

IFNH should support optional memory backends without depending on one.

### D022 — Environment-Based Secrets Initially

Environment variables and `.env` files are sufficient for initial secret handling.

### D023 — Configurable Project Lifecycle

Software-development lifecycle workflows should be configurable.

### D024 — Assisted Lifecycle Authoring

IFNH should optionally help developers create/refine lifecycle configuration.

### D025 — Reconnaissance Capability

Existing-repository reconnaissance should be available as an optional lifecycle capability.

### D026 — Testing Is Lifecycle-Aware

Tests and test quality should be treated as workflow requirements rather than agent afterthoughts.

### D027 — Diff Before Merge

Default behavior is to show the developer the diff before merging.

### D028 — Git Permissions Configurable

Agent Git capabilities may range from read-only to force-push-capable depending on explicit policy.

### D029 — Hot Configuration

Relevant configuration should be re-evaluated during sessions at policy/action boundaries.

### D030 — Runtime Slash Commands

Markdown/config-defined slash commands should not require recompilation.

### D031 — Thin Hooks

A lightweight configurable hook mechanism is desirable.

### D032 — Lightweight Agent Status

Each running agent receives a small configurable status representation by default.

### D033 — Debug Logging Optional

Deep audit/debug output is opt-in.

### D034 — Configuration Precedence

Configuration precedence is:

```text
built-in → user → project → session
```

### D035 — YAML + Markdown

YAML handles structured configuration.

Markdown handles instructions/intelligence.

### D036 — `.ifnh/`

Project-local IFNH state/configuration uses `.ifnh/`.

### D037 — Tiny Native Tool Kernel

IFNH provides a small set of execution primitives rather than native integrations for every CLI.

### D038 — Tool Discovery Before Developer Interruption

Agents inspect local help, man pages, documentation, skills, etc. before asking how an unfamiliar CLI works.

### D039 — Single Binary

IFNH targets a single native Zig executable with minimal/no runtime dependencies.

### D040 — Linux + macOS v1

Linux and macOS are initial supported platforms.

### D041 — No Full TUI

IFNH uses a lightweight streaming terminal interface.

### D042 — Headless Is Roadmap

Full non-interactive automation is desirable but not required for initial MVP.

### D043 — Reversible Actions

Workspace mutations should be journaled sufficiently for IFNH-level undo.

### D044 — Patch-First Editing

Agents edit existing code primarily through patches.

### D045 — Concurrent Conflict Stops

Conflicting concurrent agent edits stop for developer intervention by default.

### D046 — Optional Reconciliation Agent

The developer may explicitly request an agent to reconcile concurrent conflicts.

### D047 — Dirty Developer Work Is Protected

Existing uncommitted changes are never automatically stashed, discarded, committed, or overwritten.

### D048 — Everything Configurable, Zero Configuration Required

Advanced behavior should be deeply configurable while a useful default experience requires no configuration.

---

# 76. Current Conceptual Architecture

The architecture currently appears to be moving toward:

```text
                    ┌─────────────────────────┐
                    │       Developer         │
                    └────────────┬────────────┘
                                 │
                    ┌────────────▼────────────┐
                    │     Streaming CLI       │
                    │    Lightweight View     │
                    └────────────┬────────────┘
                                 │
                    ┌────────────▼────────────┐
                    │      IFNH Runtime       │
                    │                         │
                    │  Session / Lifecycle    │
                    │  Policy / Permissions   │
                    │  Agent Orchestration    │
                    │  Review / Approval      │
                    └───────┬────────┬────────┘
                            │        │
                 ┌──────────▼──┐  ┌──▼────────────┐
                 │ Agent      │  │ Tool Kernel    │
                 │ Runtime    │  │                │
                 └──────┬─────┘  │ Files/Patches │
                        │        │ Shell          │
              ┌─────────┼──────┐ │ Git/Worktrees │
              │         │      │ │ Control        │
         ┌────▼───┐ ┌──▼────┐ │ └───────┬───────┘
         │Agent A │ │Agent B │ │         │
         └────────┘ └───────┘ │         │
                              │         │
                    ┌─────────▼─────────▼──┐
                    │ External Developer   │
                    │ Tools / Sandboxes    │
                    └──────────────────────┘

         ┌────────────────────────────────────────┐
         │           Extension Boundary           │
         │                                        │
         │ Skills      MCP       Memory           │
         │ Commands    Docs      Web Research     │
         │ Hooks       Custom Integrations        │
         └────────────────────────────────────────┘

         ┌────────────────────────────────────────┐
         │          Provider Abstraction          │
         ├────────────────────────────────────────┤
         │ OpenRouter │ OpenAI │ Anthropic │ ... │
         │ Ollama │ llama.cpp │ Custom APIs      │
         └────────────────────────────────────────┘
```

This diagram is conceptual and should not yet be treated as an implementation specification.

---

# 77. Example Desired Developer Experience

A new developer should eventually be able to install IFNH and simply run:

```bash
ifnh
```

No configuration should be necessary beyond obtaining/configuring a usable model.

An advanced developer could create:

```text
.ifnh/
├── config.yaml
├── lifecycle/
│   └── default.yaml
├── skills/
│   ├── architecture/
│   │   └── SKILL.md
│   └── testing/
│       └── SKILL.md
├── commands/
│   ├── recon.md
│   └── ship.md
├── reports/
├── checkpoints/
└── debug/
```

and control nearly every aspect of the harness.

The two users are using the **same binary**.

That is important.

---

# 78. The IFNH Test

Whenever a feature is proposed, ask:

### Does this belong in the core?

Could it instead be:

- YAML?
- Markdown?
- A skill?
- A slash command?
- A lifecycle stage?
- A hook?
- An MCP server?
- An external CLI?
- A memory adapter?

### Does it preserve speed?

What does it do to:

- Startup time?
- Binary size?
- Runtime memory?
- Dependency count?

### Does it preserve developer control?

Can the developer:

- Disable it?
- Replace it?
- Configure it?
- Inspect it?

### Is it auditable?

Can the developer understand:

- What happened?
- Why?
- Which agent did it?
- Which policy allowed it?
- Which model performed it?
- What changed?

### Are we reinventing something?

Does an established:

- Protocol,
- standard,
- CLI,
- library,
- MCP,
- Git capability,
- skill format,
- or sandbox

already solve the problem?

If so, integrate rather than recreate where practical.

---

# 79. Working Product Statement

> **IFNH is a blazing-fast, lightweight, open-source agentic coding harness written in Zig for developers who want to control their models, tools, agents, workflows, permissions, and development lifecycle without adopting a heavyweight AI coding environment.**

A shorter eventual positioning might become:

> **The agent harness for developers who want to stay in control.**

Neither statement is final marketing copy.

---

# 80. Current Guiding Principle

If there is tension between adding another impressive feature and preserving IFNH's core identity, prefer:

> **A tiny, fast, understandable core with powerful extension points.**

The intelligence belongs in models, skills, instructions, lifecycles, tools, and developer configuration.

IFNH's job is to orchestrate those pieces exceptionally well.

---

# 81. Discovery Status

Architecture discovery is **not complete**.

Do not begin implementing the entire system from this document yet.

The next phase of discovery should continue one question at a time.

Once discovery is sufficiently complete, this ledger should be used to produce:

1. Formal product requirements.
2. Technical architecture.
3. Zig module architecture.
4. Configuration specification.
5. Agent protocol specification.
6. Permission model.
7. Lifecycle specification.
8. Session/persistence specification.
9. MCP architecture.
10. Provider adapter specification.
11. Security/threat model.
12. MVP scope.
13. Milestone plan.
14. Testing strategy.
15. Repository structure.
16. Contributor architecture guide.
17. Implementation tasks suitable for parallel coding agents and human engineers.

Only then should implementation be divided among coding agents.

---

**END OF CURRENT IFNH MASTER DESIGN & ARCHITECTURE LEDGER**
```
