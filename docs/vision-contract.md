# ZeroClaw Vision Contract

This document converts the product vision into repository-level change gates.

## 0. Summary

- **Purpose:** make the product vision enforceable during planning, implementation, and review.
- **Audience:** contributors, maintainers, reviewers, and coding agents.
- **Scope:** feature planning, architecture decisions, PR readiness, and review outcomes.
- **Non-goals:** replacing subsystem-specific contracts in `AGENTS.md`, `CONTRIBUTING.md`, or runtime reference docs.

---

## 1. Core Product Vision

ZeroClaw should evolve into a clean, minimal, cross-platform personal content and curation engine that captures personal digital inputs, transforms them automatically, curates personalized feeds, and connects users through open social protocols.

When tradeoffs appear, prefer this order by default:

1. Privacy and user control
2. Simplicity and low cognitive load
3. Open protocols and portability
4. Extensibility through skills/tools/contracts
5. Convenience optimizations

---

## 2. Non-Negotiable Product Invariants

| Vision area | Repository contract |
|---|---|
| Clean, minimal UX | Reject changes that add unnecessary workflow steps, fragmented surfaces, or avoidable configuration burden without a documented user-value reason. |
| AI-centric architecture | New behavior must be decomposed into explicit contracts, typed interfaces, and inspectable flows so agents can extend and verify it safely. |
| Open ecosystem first | Prefer BlueSky, Nostr, RSS, and Atom aligned behavior over closed-platform lock-in. Closed integrations must stay optional, not foundational. |
| Extensible design | Prefer trait implementations, tools, skills, and plugin-style extension points over hardcoded special cases. |
| Cross-platform target | Do not design new behavior so it only works on one desktop OS unless the limitation is temporary, explicit, and documented. |
| Local or user-controlled vectorization | Do not make remote vector processing the default. If remote execution is necessary, require explicit user intent and user-owned credentials. |
| Multimodal capture | Preserve the direction toward text, audio, and video input ingestion rather than narrowing the system around text-only assumptions. |
| Content transformation engine | Add initial built-in workflows in a way that can later be expanded by community-developed skills/tools without subsystem rewrites. |
| Personalized curation | Feed/curation changes should strengthen relevance based on user inputs, embeddings, similarity, or deliberate contrast rather than generic popularity alone. |
| Connection and discovery | Social/discovery features should favor meaningful alignment across open ecosystems instead of closed social graph dependence. |
| Draft review before publish | Publishing flows should preserve a dedicated review/draft stage rather than forcing immediate publication. |
| Publishing boundaries | BlueSky remains the short-form publishing path; Nostr remains the long-form/open publishing path unless an intentional contract change is documented. |
| Open feed ingestion | Do not regress RSS/Atom ingestion support or treat it as an afterthought. |

---

## 3. Planning Gate

Every feature proposal, plan, or issue that changes user-facing behavior should answer these questions explicitly:

1. Which vision requirement does this work advance?
2. Which vision requirement could it accidentally weaken?
3. Why is the simplest acceptable shape sufficient for this iteration?
4. Which existing extension point should carry the behavior?
5. What is the rollback path if the change harms simplicity, privacy, or openness?

If a proposal cannot answer these clearly, it is not ready for implementation.

---

## 4. Design Rules for Future Changes

- Prefer extension through traits, tools, and skills before adding cross-cutting branching.
- Prefer open protocol integrations before proprietary platform dependencies.
- Keep vectorization local-first and credential scope narrow.
- Keep AI behavior explicit, typed, and inspectable; avoid hidden prompt-only magic that cannot be reviewed.
- Preserve a clear path to macOS, iOS, Windows, and Android support when introducing UI/runtime assumptions.
- Keep built-in transformation workflows small and testable; community expansion should remain possible without core rewrites.
- Treat drafts, publishing, and ingestion as distinct surfaces with explicit contracts.

---

## 5. PR Gate

Every PR that changes behavior, architecture, planning docs, or user-facing flows must include a `Vision Alignment` section in the PR template.

That section must state:

- the vision requirement(s) affected
- the simplicity/cognitive-load impact
- whether open-protocol alignment is preserved
- whether extensibility is preserved through traits/tools/skills
- whether cross-platform implications are understood
- whether privacy/local-vectorization constraints are preserved
- whether publishing or ingestion contracts changed

If any answer is negative, the PR must justify the exception and describe rollback.

---

## 6. Review Gate

Reviewers should block or request redesign when a change:

- adds product complexity without a strong user-facing reason
- hardcodes behavior that should live behind an extension point
- makes a closed platform or remote vector service mandatory by default
- narrows future cross-platform support without explicit scoping
- weakens the draft/review, publishing, or RSS/Atom ingestion contracts
- claims alignment with the vision but does not provide evidence in the PR

---

## 7. Implementation Defaults

When the right direction is unclear, use these defaults:

- default to smaller, reversible changes
- default to open protocols over closed APIs
- default to local/private processing over remote convenience
- default to extension points over embedded one-off logic
- default to explicit product constraints over silent fallback

---

## 8. Related Governance Docs

- [../AGENTS.md](../AGENTS.md)
- [../CONTRIBUTING.md](../CONTRIBUTING.md)
- [pr-workflow.md](pr-workflow.md)
- [reviewer-playbook.md](reviewer-playbook.md)

---

## 9. Maintenance Notes

- **Owner:** maintainers responsible for product direction and repository governance.
- **Update trigger:** vision changes, new product pillars, or repeated review conflicts about product direction.
- **Last reviewed:** 2026-03-10.
