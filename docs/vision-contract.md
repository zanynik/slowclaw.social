# SlowClaw Social Vision Contract

This document converts the product vision into repository-level change gates.

> **Canonical product thesis (read this first):** SlowClaw Social is a
> **journal-first brain-feeder.** You capture your own thoughts — mostly by
> voice — into one local workspace. What you have already written then becomes
> the **lens** that curates everything you read and watch back: articles,
> news, and video. The feed feeds *your* mind, not a generic crowd's. From
> there you can distill the best of your own thinking into posts, publish out
> to open networks, and connect with the people whose insights resonate.

## 0. Summary

- **Purpose:** make the product vision enforceable during planning, implementation, and review.
- **Audience:** contributors, maintainers, reviewers, and coding agents.
- **Scope:** feature planning, architecture decisions, PR readiness, and review outcomes.
- **Non-goals:** replacing subsystem-specific contracts in `AGENTS.md`, `CONTRIBUTING.md`, or runtime reference docs.

---

## 1. Core Product Vision

SlowClaw Social is a local-first, **iOS-primary** personal app organized around three loops:

1. **Capture loop** — a single journal workspace for text, **audio (the default)**, and video. Capture stays on-device: transcription via the native iOS speech bridge, AI via on-device inference (`llama.cpp`/GGUF). The journal is the **source of truth about the user** and therefore the foundation of everything else.

2. **Feed loop (journal-driven curation)** — articles, news, and video flow *into* the user through **one** curated surface, ranked by **relevance to the user's own journals**, not by generic popularity. This replaces third-party readers / aggregators (Perplexity, feed readers, etc.) and is the project's core differentiator: **the journal is the lens.** Both fresh content and high-quality evergreen content are in scope.

3. **Share/Connect loop** — the user distills their own thinking into drafts, reviews them, and publishes out to open protocols (Bluesky short-form, Nostr long-form). They discover the people whose thinking resonates, follow them, and those authors flow back into the Feed loop.

When tradeoffs appear, prefer this order by default:

1. Privacy and user control (local-first, on-device)
2. Journal-driven relevance over generic popularity
3. Simplicity and low cognitive load
4. Open protocols and portability
5. Extensibility through skills/tools/contracts
6. Convenience optimizations

---

## 2. Non-Negotiable Product Invariants

| Vision area | Repository contract |
|---|---|
| **Journal is the lens** | Curation/ranking surfaces MUST be influenced by the user's own captured material (journal-derived topics/interests, with a path to embeddings). Ranking that is generic-popularity-only or ignores the journal is a regression and must be justified. |
| **Audio-first capture** | Audio journaling is a first-class, one-tap, auto-transcribed path — never a fallback or second-class surface. Capture must work fully on-device on iOS. |
| **Local-first / on-device AI** | New AI features default to the on-device path (`inference.rs`, `transcription.rs`). Do not make remote LLM/processing the default for capture or synthesis. Remote is opt-in with user-owned credentials. |
| **One curated feed surface** | Articles, news, and video should converge into a small number of reading/watching surfaces, all ranked through the same journal-derived relevance signal. Avoid proliferating disconnected content tabs. |
| **Video is a first-class source** | Video (including YouTube and equivalent) is an ingestion source of equal standing to articles and social posts, supporting both fresh and evergreen content. See the ingestion note below. |
| **Open publishing, open ingestion** | Publishing output stays on open protocols (Bluesky, Nostr). Ingestion prefers open protocols (RSS, Atom, Nostr, AT Protocol) but MAY include proprietary read-only sources (e.g. YouTube) when they serve the feed — provided the user's **own** captured material and **published** output are never locked into a closed platform. |
| **Draft review before publish** | Publishing flows MUST preserve a dedicated review/draft stage rather than forcing immediate publication. |
| **Publishing boundaries** | Bluesky remains the short-form publishing path; Nostr remains the long-form/open publishing path unless an intentional contract change is documented. |
| **Clean, minimal UX** | Reject changes that add unnecessary workflow steps, fragmented surfaces, or avoidable configuration burden without a documented user-value reason. |
| **AI-centric, inspectable architecture** | New behavior must be decomposed into explicit contracts, typed interfaces, and inspectable flows so agents can extend and verify it safely. No hidden prompt-only magic that cannot be reviewed. |
| **Extensible design** | Prefer trait implementations, tools, skills, and plugin-style extension points over hardcoded special cases. |
| **Cross-platform target** | iOS is primary. Do not design new behavior so it only works on desktop unless the limitation is temporary, explicit, and documented. |
| **Local or user-controlled vectorization** | Do not make remote vector processing the default. If remote execution is necessary, require explicit user intent and user-owned credentials. |
| **Multimodal capture** | Preserve the direction toward text, audio, and video input ingestion rather than narrowing the system around text-only assumptions. |

> **Ingestion vs. lock-in note (important nuance):** pulling a YouTube video
> *into* the user's curated feed is **ingestion** and is allowed — the user is
> not locked in, because their journals and their published output remain on
> open protocols. This is consistent with treating RSS/HN as ingestion today.
> The forbidden thing is making a closed platform the home for the user's
> *own* content or a hard dependency for *core* capture/synthesis.

---

## 3. Planning Gate

Every feature proposal, plan, or issue that changes user-facing behavior should answer these questions explicitly:

1. Which loop does this advance — **Capture**, **Feed (curation)**, or **Share/Connect**?
2. Does it strengthen or weaken the **journal-as-lens** signal? (If it adds a content/ranking surface that ignores the journal, justify it.)
3. Does it keep **capture** local-first and **audio-first** first-class on iOS?
4. Which vision requirement could it accidentally weaken?
5. Which existing extension point should carry the behavior?
6. What is the rollback path if the change harms simplicity, privacy, openness, or journal-driven relevance?

If a proposal cannot answer these clearly, it is not ready for implementation.

---

## 4. Design Rules for Future Changes

- Prefer extension through traits, tools, and skills before adding cross-cutting branching.
- Prefer open protocol integrations before proprietary platform dependencies.
- Keep vectorization local-first and credential scope narrow.
- Keep AI behavior explicit, typed, and inspectable; avoid hidden prompt-only magic that cannot be reviewed.
- Preserve the iOS-primary path when introducing UI/runtime assumptions; gate platform-specific code with `cfg` (Rust) or runtime capability checks (TS).
- Keep built-in transformation workflows small and testable; community expansion should remain possible without core rewrites.
- Treat drafts, publishing, and ingestion as distinct surfaces with explicit contracts.
- Funnel every new content source through the existing `UnifiedItem` normalization layer (`web/src/lib/socialFeed.ts`, blueprint in [Social-media-app-open-web.md](Social-media-app-open-web.md)) so ranking and rendering stay source-agnostic.

---

## 5. PR Gate

Every PR that changes behavior, architecture, planning docs, or user-facing flows must include a `Vision Alignment` section in the PR template.

That section must state:

- the vision loop(s) and requirement(s) affected
- the **journal-as-lens** impact (does any ranking/curation surface get less journal-driven?)
- the simplicity/cognitive-load impact
- whether open-protocol alignment is preserved (publishing open; ingestion may be proprietary-read-only)
- whether extensibility is preserved through traits/tools/skills
- whether cross-platform / iOS-primary implications are understood
- whether privacy/local-vectorization constraints are preserved
- whether publishing or ingestion contracts changed

If any answer is negative, the PR must justify the exception and describe rollback.

---

## 6. Review Gate

Reviewers should block or request redesign when a change:

- adds a content or ranking surface that is **not** journal-driven without a strong user-value reason
- demotes audio capture or moves capture/synthesis off-device by default
- adds product complexity without a strong user-facing reason
- hardcodes behavior that should live behind an extension point
- makes a closed platform the home for the user's *own* content or a hard dependency for *core* capture/synthesis
- narrows iOS-primary support without explicit scoping
- weakens the draft/review, publishing, or RSS/Atom/ingestion contracts
- claims alignment with the vision but does not provide evidence in the PR

---

## 7. Implementation Defaults

When the right direction is unclear, use these defaults:

- default to smaller, reversible changes
- default to **journal-derived relevance** over generic popularity for any new ranking
- default to **on-device** processing for capture/synthesis over remote convenience
- default to **audio-first** capture flows
- default to open protocols for publishing; treat proprietary sources as read-only ingestion
- default to extension points over embedded one-off logic
- default to explicit product constraints over silent fallback

---

## 8. Related Governance Docs

- [../AGENTS.md](../AGENTS.md)
- [../CONTRIBUTING.md](../CONTRIBUTING.md)
- [pr-workflow.md](pr-workflow.md)
- [reviewer-playbook.md](reviewer-playbook.md)
- [Social-media-app-open-web.md](Social-media-app-open-web.md) — the unified-feed normalization blueprint

---

## 9. Maintenance Notes

- **Owner:** maintainers responsible for product direction and repository governance.
- **Update trigger:** vision changes, new product pillars, or repeated review conflicts about product direction.
- **Reconciliation:** when this vision changes in substance, mirror the product framing in `AGENTS.md` §1 (Project Snapshot / Product direction) and the `README.md` product description, per the repo documentation contract.
- **Last reviewed:** 2026-07-09 — sharpened around the **journal-first brain-feeder** thesis (three loops: Capture → journal-driven Feed → Share/Connect), made audio-first capture and journal-driven curation non-negotiable, and opened video (incl. YouTube) as a first-class ingestion source while keeping the user's own content open-protocol-bound.
