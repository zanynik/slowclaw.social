# Batched persona relevance and Pulse

## Decision and evidence

Proven → Better: retain journal classification into the 224-topic rolling persona,
transport filtering, consent/device leases, exact-source identity checks and the
existing Nostr signer. Replace per-candidate 224-topic vectors with independent
Jev relevance questions sharing the top 15 weighted interests as state.

A live, **synthetic** experiment on 2026-09-22 compared 12 candidate excerpts:

| Path | Provider requests | Measured service wall time |
| --- | ---: | ---: |
| Existing 224-topic candidate classification, sequential | 84 | 92.994 s |
| Shared persona, one question per candidate | 1 | 1.334 s |
| Same candidates plus 20 unrelated fillers | 1 | 1.120 s |

Both first two paths admitted the four intended technical candidates at their
respective thresholds (old cosine 0.15, new heuristic 0.55). The new scores were
0.58–0.90 for those candidates and 0.01–0.10 for the others. A second food/meditation
persona admitted only its three intended items. Keyword bait, incidental AI
mentions and an embedded instruction to return 1.0 were rejected in these cases.
This small adversarial sample is not a prompt-injection security guarantee.

Adding 20 short fillers changed original scores by at most 0.02; four single-item
comparisons differed by at most 0.02; reversing order differed by at most 0.01.
A 15-interest / 32-item case with longer fillers took 1.501 s and retained the
same admitted items, though scores shifted by up to 0.21 with the changed persona
and context. A broader, diverse 15-interest persona took 1.283 s and selected its
seven relevant items while rejecting unrelated/spam candidates. These are measured
service timings, not iPhone latency, repeated statistical benchmarks, real-journal
quality, or provider-token cost measurements. The old method can reuse cached
vectors and compare the full topic space; the new method deliberately loses
minor interests outside the top 15 and content beyond the bounded excerpt.

`jev-batch-benchmark.json` contains the synthetic fixture/results. To repeat:
`node ios-app/Tests/jev-batch-benchmark.mjs --live`. This explicitly uses the public
tester enrollment, makes paid provider requests, and revokes its temporary session
in finally. It never retrieves an owner/provider key or sends real journals.

## Request, cache and admission contract

- State: up to 15 positive topics, normalized and rounded to 0.001, stable tie order.
- Questions: up to 32 independent title + first 100 description-word excerpts.
  Titles are bounded to 200 UTF-8 bytes; the entire excerpt to 1,200 bytes.
- Escaped-content-aware packing reserves question/state overhead. Requests with
  long/escape-heavy text split earlier. The service additionally bounds the full
  provider request to 60,000 UTF-8 bytes. We do not assume the claimed 64k context
  window is all available to content or that filling it is necessary for speed.
- Versioned `/api/relevance` rejects invalid/duplicate IDs, unknown topics,
  non-finite/out-of-range weights and malformed/missing provider scores. Existing
  endpoints and auth remain unchanged; the fixed request does not enable a generic
  arbitrary-prompt proxy. The service stores no input content.
- Local cache: at most 300 score/hash/date entries, seven-day lifetime, protected
  atomic storage. Persona/version changes invalidate it. Full original URL/title/
  description hash invalidates even edits beyond the excerpt. After each await,
  recheck consent, persona, memory revision and current candidate content.
- Scores >= 0.55 are admitted and sorted descending. This is an experimental
  ranking threshold, not a calibrated probability. Failures remain retryable;
  incomplete batches never grant admission. Prior complete batches are retained.
- Journal topic scoring and weekly RSS source-preview selection are unchanged.
  Therefore total refresh cost includes source discovery and other work; the
  table only compares candidate scoring. Optional local Kev remains unchanged.

## Pulse experience

Pulse is a compact note timeline with For you / Latest ordering, verified-event
public-key identity, timestamps, expandable text, native replies/conversations,
share/copy/mute, and a persistent unsent composer. Review first saves to the
existing private drafts session; publishing still requires the existing explicit
review/signer. No new automatic posting, fake engagement counts or fake follow
buttons. Profile names/avatar network fetching are not added; abbreviated public
keys identify authors honestly. Old cached posts without signed event data can
still open their web conversation; refresh enables native replies.

Transport now reserves up to 40 RSS, 20 video, 20 long-form Nostr and 40 short
Nostr candidates (120 total). Existing per-author short-note and content gates
remain. All candidates still require relevance approval. Latest only reorders
approved notes; it does not bypass the gate. The optional signed-event field is
Swift-only and backward-compatible with old feed caches; no C ABI changes.

## Validation and rollback

Backend eight unit/auth tests, TypeScript and production build passed. Additive
service v6 is deployed, and live synthetic requests above succeeded with sessions
revoked. Swift regressions cover profile bounds, Unicode/escaping, response
integrity, cache invalidation, pool fairness, and preservation of signed events.
This environment has no Swift/iOS SDK; actual Swift tests and iOS compilation run
in the existing TestFlight workflow. Physical-device scrolling, keyboard/reply
flows, real relay availability and real-feed relevance remain acceptance checks.
Signing, main, journal storage and persona extraction are unchanged.

Rollback: revert the app batch-ranking commit to restore cosine candidate scoring;
the additive service route can remain for compatibility. Revert the separate Pulse
UI commit to restore its previous presentation. No journal/draft data migration.
