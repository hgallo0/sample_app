---
name: adr
description: Generate an Architecture Decision Record for a feature or component decision. Use when a backend architecture, data store, caching, or scaling choice needs to be made and documented, not just implemented silently.
---

Produce a short Architecture Decision Record (ADR) for the decision at hand. If the decision isn't stated explicitly, ask one clarifying question before proceeding rather than guessing.

Structure the ADR as:

1. **Context** — one or two sentences: what problem/requirement forced this decision.
2. **Decision** — the specific choice made, stated as a concrete action ("use X"), not a hedge.
3. **Rejected alternatives** — at least one other option that was considered, with the concrete reason it lost (cost, latency, complexity, team familiarity, time constraint). Never skip this section — a decision without a named alternative is incomplete.
4. **Tradeoffs / consequences** — what this decision costs later (operational burden, scaling ceiling, security surface, migration cost if reversed).

Rules:
- Cover data store, caching, and scaling implications explicitly if the decision touches any of them — don't let those go unaddressed even if the question was narrower.
- Keep it to one page. This is a decision record, not a design doc.
- Write it as a numbered markdown file under `docs/adr/NNNN-title.md` (zero-padded, incrementing from the highest existing number in that directory, starting at 0001).
- State the decision in first person, as something decided, not as a menu of options being presented back to the user.
