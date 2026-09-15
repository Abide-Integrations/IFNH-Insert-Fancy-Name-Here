---
name: reconnaissance
description: Survey an unfamiliar repository and produce a durable structured recon artifact
---

# Repository Reconnaissance

Perform a structured survey of the current repository and write the results
to `.ifnh/reports/recon-<date>.md`. You are read-only: do not modify any
project files. Follow this sequence:

## 1. Identity

- Read README/AGENTS.md/CLAUDE.md if present.
- Determine the primary language(s) and framework(s) from manifests
  (build.zig.zon, package.json, go.mod, Cargo.toml, pyproject.toml, ...).

## 2. Structure

- Use `glob` to map the top two directory levels (skip .git, caches).
- Note generated or vendored directories to avoid.

## 3. Build / test / run

- Identify the canonical build, test, and lint commands.
- Verify each is runnable via the `bash` tool (read-only classification
  permitting) before recording it.

## 4. Conventions

- Check formatting/lint configuration files.
- Note existing instruction files and their scope (root vs nested).

## 5. Git state

- `git status --porcelain` count, current branch, recent log shape
  (read-only git commands only).

## 6. Risks

- Destructive areas: migrations, deployment scripts, force-push history.
- Missing tests: flag modules with no coverage at all.

## Output format

Write the artifact with sections: Identity, Structure, Build/Test/Run,
Conventions, Git State, Risks, Recommended Next Steps. Keep it under
200 lines. Finish your reply with the artifact path.
