# Jev cloud memory experiment

## Topic persona and visible passage drafts

This revision replaces cloud Reads passage-to-item comparisons with a shared,
versioned 224-topic space. Jev scores topics independently in batches of 32.
Every bounded portion of a journal or incoming text contributes to its
length-weighted mean vector. Scores below 0.5 contribute no evidence; remaining
scores are rescaled to 0–1. Each included journal contributes once with a 90-day
half-life. Edits replace its contribution; deletion and exclusion remove it.
Existing journals are backfilled from their source text, not their selected
highlights. Original journal dates drive decay.

Reads and weekly source previews are classified in the same space. Their
cosine similarity (normalized dot product) to the summed persona determines
descending rank. An initial similarity floor of 0.15 suppresses weak overlap;
this is a tunable ranking heuristic, not a calibrated relevance probability.
The top contributing topics explain each match. Topic vectors are cached on
the device separately from persona-dependent scores. Cached source previews
are reranked immediately as journals change and reclassified weekly.
An initial full scan is more expensive than subsequent incremental updates.
The fixed catalog remains the discovery boundary.

Create now visibly lists Jev-selected passages with Source, Dismiss and Make
draft. The action assembles exact source sentences up to 280 characters into
an editable private draft; a short passage can be used directly. Oversized
passages without a complete short sentence explicitly abstain. Nothing posts
automatically. Passage importance is not a privacy or public-sharing guarantee.
Settings replaces Memory with Your interests and relative topic weights;
passage selection is retained solely to support Create.

Draft loading now lists the drafts session directly through an additive C ABI,
instead of searching for the words "draft post". This fixes saved original
sentences being invisible in Create. The SQLite session predicate precedes
the listing limit. A real in-memory SQLite/FFI regression covers a draft with
no search keywords behind 1001 newer journals, including result ownership.

Proven → Better: reuse the existing classifier, consent, device sessions,
source fetching and draft storage. Only the cloud classification/ranking
policy and its two user surfaces change. Optional local Kev remains available.
Rollback is to revert this app revision; old memory/reading service endpoints
remain compatible. Tests cover fixed topic coverage, score rejection, recency
decay, ranking, journal replacement/removal, and existing session restrictions.
Physical-device UI and real-journal quality still require TestFlight evaluation.

The following sections document earlier revisions and their validation.

Validation for this revision: all app Swift files parsed; the executable
persona tests passed; SQLite and C ABI tests passed (287 passed, one skipped).
The service TypeScript check, six tests and production build passed. A live
synthetic topic request returned all 224 valid scores and its temporary session
was revoked. This checks protocol compatibility, not personalized quality.

This branch improves the journal-first reading loop: exact useful journal passages become the authority for admitting incoming content. It is an opt-in cloud experiment. Capture stays on-device.

The owner configures OpenRouter in the separate SlowClaw Jev service. Its owner-only form verifies `jev-1.13` through `/api/v1/systemone` before encrypting the key at rest. No shared API key ships in the app. After first-use consent, each tester device automatically obtains a revocable session token and stores it in Keychain. The service does not persist journal or reading text. OpenRouter/provider policies still apply; the app explains this before enabling cloud processing. There are no per-user usage quotas. One request per device runs at a time.

Memory scans the journal archive, skips excluded/deleted records, and classifies bounded source passages as routine, useful context, or lasting insight. Promising long passages are split at natural boundaries and checked again, to two levels. If splitting loses the meaning, the original coherent passage remains. Exact source words, source key, content fingerprint and classifier version stay on-device. Unchanged journals, including those with no useful passages, are not reclassified. Forgotten passages remain dismissed. Edits invalidate prior memory. Failed requests remain retryable.

Reads compares incoming article content and short/long Nostr posts with every retained memory in batches of up to 16. Long incoming content is divided into bounded portions. A completed relevance score of at least 0.7 admits the item; items appear in descending score order with a matching source excerpt. Scores are model estimates, not a guarantee of usefulness. Incomplete or failed decisions do not admit items. Discovery/fetching still uses the existing feed sources; Jev makes admission decisions rather than fetching URLs itself.

Rollback: turn off Jev in Settings to stop new cloud requests and revoke this device connection, then explicitly activate the optional local Kev model. This experiment is not merged into main. Live latency, quality and provider compatibility need a configured OpenRouter key and on-device evaluation. Publishing continues through the existing TestFlight workflow only.

## Tester-first interface

The first-use screen explains cloud text processing once and offers Start
journaling or Use offline. The first option automatically obtains a device
session from the existing service; testers need no account, OpenRouter key,
or model download. The provider key remains server-side. Anonymous beta
enrollment is intentionally open while TESTFLIGHT_ACCESS_ENABLED is true;
it is not a guarantee that a caller installed via TestFlight. The owner can
disable enrollment and existing beta sessions with that server setting.

Journal saves and completed transcripts resume memory extraction automatically.
Retained passages supply exact-sentence private draft suggestions and Reads.
Deleted suggestions are not recreated for an unchanged source. Nothing is
published automatically. The app retries an interrupted connection and can
renew expired device sessions. Cloud processing off remains respected.

Journal, Reads, Create, Settings each have one primary purpose. Source controls
and recommendation explanations sit behind menus/disclosures. Settings has
Memory, Privacy & connection, Appearance and Advanced; models, storage and
diagnostics are in Advanced. Create shows drafts rather than journal-by-journal
classification controls. The backend is isolated behind JevCloud so a future
local judge need not change these screens.

Validation: Swift syntax parsing; backend TypeScript check and production build;
five backend tests including real SQLite-backed enrollment, key-admin denial,
server-side disable and session revocation. The existing TestFlight pipeline
provides full Swift/iOS compilation. Physical-device layout, recording and
classification quality remain device acceptance checks. A live synthetic journal
request verified anonymous enrollment and a valid Jev response; its session was
revoked afterward. This does not establish latency or real-journal quality.

## Source and draft follow-up

Proven → Better: reuse the existing catalog, Jev memory/relevance endpoints and exact-sentence draft assembly. The Sources sheet separates selected and unselected feeds. Jev compares five recent stories from each reachable RSS/YouTube feed against retained memory; a score of 0.7 selects the source for fetching. Successful decisions persist for seven days, then refresh while the app is in use. Removed memory invalidates its source choices immediately. New passages influence the next weekly scan or an explicit recheck. This selects from the catalog, not arbitrary web discovery, and does not promise scheduled iOS background execution. Network batches are bounded to eight feeds; classification is serial and resumable, with a pause control.

Selected sources rotate through the daily fetch budget; selected YouTube channels are always included. The Atom parser now retains media:description, which YouTube uses instead of summary/content. The candidate pool reserves space for web stories, videos and both Nostr kinds before the unchanged per-item Jev admission rule. Nostr handshake/send/receive share an eight-second deadline; UTF-8 binary relay frames are also accepted. Sources shows fetched counts so an empty transport can be distinguished from relevance rejection.

When Jev is enabled, Create selects complete original journal sentences through cloud memory classification and assembles up to two into a private draft of at most 280 characters. No local model download is required. Importance is not a public-sharing safety decision: the UI asks for review of personal details and editing before publishing. The optional local path remains available when Jev is off.

The minimum OS returns to iOS 18 in both Xcode and the Apple-clang llama archive. iOS 26 keeps SpeechAnalyzer live transcription; iOS 18 records normally and uses the existing forced-on-device SFSpeechRecognizer after saving. An iOS 18 device must still be tested for launch, capture and transcription. Signing and publication safeguards are unchanged. The compatibility change can be reverted separately from source/draft selection.

Validation: Swift syntax parsing and two executable regression tests passed (weekly expiry/removed-memory invalidation and platform candidate budgets/deduplication). Zig tests passed: 208 passed, one skipped, including a YouTube Atom description regression. Full macOS runtime tests and iOS SDK compilation run in the existing TestFlight workflow. Live relay probes timed out from the development environment; on-device relay delivery and live Jev quality/latency are not claimed as verified by these checks.

Validation before push: all app Swift files parsed; the pure memory module type-checked; executable checks covered exact source reconstruction, bounded Unicode payloads (including a long combining sequence), and fail-closed admission. Backend decision tests, TypeScript checking and production build passed. The setup page rendered in the supervised browser preview. Owner sign-in/WebMCP and real Jev requests require the owner connection and were not exercised. macOS runtime tests, iOS SDK compilation, signing and upload run in the existing TestFlight workflow.
