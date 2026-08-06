---
name: threat-model
description: Run a structured security review of an endpoint, feature, or service boundary. Use when new API surface, auth flow, or data path is added and needs a security pass, not just a correctness check.
---

Run a structured threat-model pass over the target (an endpoint, feature, or boundary named by the user, or the most recently added API surface if unspecified). This is a security review, not a general code review — stay focused on the categories below and skip generic style/quality feedback entirely.

For each category, give a concrete finding grounded in the actual code/config (cite file:line), not generic advice. If a category is genuinely not applicable, say so in one line and move on — don't pad.

1. **Authentication** — how is identity established on this path? Is token verification actually enforced (not just present in code but unreachable), and against what issuer/audience?
2. **Authorization** — once identity is known, what can it do? Check for missing ownership checks (e.g. user A acting on user B's resource via an ID in the request).
3. **Input validation / trust boundary** — what crosses from untrusted to trusted here? Flag anything taken from client input and used unvalidated (DB query params, file paths, prompts to an LLM, redirect targets).
4. **Injection surface** — SQL/command injection, and if an LLM is in the path, prompt injection (untrusted text reaching the model without delimiter/instruction separation).
5. **Abuse / rate limiting** — can this endpoint be scripted for abuse (leaderboard gaming, credential stuffing, quota exhaustion)? Is there a WAF/quota layer actually in front of it, or just assumed?
6. **Data exposure** — what does this path log, return, or cache that shouldn't be — PII, tokens, internal error detail leaking to the client?

End with a short prioritized list: Critical / Should-fix / Note — ranked by actual exploitability, not theoretical severity.
