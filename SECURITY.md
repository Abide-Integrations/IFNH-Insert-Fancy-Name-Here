# Security Policy

## Reporting a vulnerability

Report privately: open a GitHub security advisory (Security -> Advisories
-> New draft advisory) or contact the maintainers directly. Do not open
public issues for vulnerabilities.

We aim to acknowledge reports within 72 hours and will coordinate
disclosure timing with you.

## Security model summary

IFNH's permission model is the enforcement boundary, never model judgment:

- Permission ceilings cannot be raised by repo content, skills, or agents.
- `.ifnh/` policy/config files are agent-write-denied by default.
- Tool outputs are treated as untrusted data (prompt-injection framing).
- Secrets are redacted from model-bound output; `.env` values are not
  directly readable by agents by default.
- Shell commands are classified by a conservative lexer; destructive and
  unknown write-ish commands require approval.

Scope notes: IFNH executes developer-configured hooks and MCP servers as
separate processes by design; treat their configuration as part of your
trust boundary.
