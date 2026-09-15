---
name: create-skill
description: Create a new IFNH skill from a described task pattern
---

# Create a Skill

When asked to create a skill, produce a `SKILL.md` in the Agent Skills
format and install it to the project scope:

1. Interview: what task pattern, what steps, what artifacts?
2. Write `.ifnh/skills/<name>/SKILL.md` with YAML frontmatter
   (`name`, `description`) and a Markdown body with numbered steps and
   the expected output format.
3. Present the file for human review — skills never activate themselves
   (K161). Never grant permissions in a skill (K153).
