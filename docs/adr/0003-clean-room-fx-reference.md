# ADR-0003: fx is an architecture reference only (clean-room rule)

- **Status:** Accepted (2026-09-14, meta-decision M2)
- **Context:** PLAN.md names Vercel Labs `fx` as the strongest architectural inspiration and mandates license review before porting code (§68). fx is Apache-2.0; IFNH targets pure MIT. Apache-2.0 material can be incorporated into MIT projects with notice retention, but attribution obligations and upstream divergence tracking conflict with the goal of a minimal, fully-owned core.
- **Decision:** The fx repository (`/opt/fx` checkout) is used exclusively as an architecture reference: module layering, interface shapes (fn-pointer Provider/Tool contracts), session layout (JSONL event log + manifest), durability patterns (atomic replace + fsync + advisory locks), build flags, and CI budget enforcement are studied and re-implemented independently. **No code is ported, vendored, or translated.** `THIRD_PARTY_NOTICES.md` stays empty unless this policy changes by ADR.
- **Consequences:**
  - Pure MIT license with no third-party attribution obligations.
  - Slightly slower initial development than direct porting; full ownership of every line.
  - fx conventions that are documentation rather than code (AGENTS.md rules, verification discipline) may be adapted freely.
