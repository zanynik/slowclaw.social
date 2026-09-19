# Local decisions for Reads

Reads now admits articles and Nostr short posts only after the dedicated local
Qwen3-Reranker 0.6B model scores them at least 0.80. Missing, failed, non-finite,
stale, or unevaluated scores do not admit content. There is no keyword, embedding,
or generative-model admission fallback. A short or empty feed is intentional.

This is a Jev-like decision interface, not TypeSafe's Jev weights. The reranker
computes a normalized yes/no score in one prompt evaluation without generating
an answer. The score is not a calibrated probability of personal usefulness.
The initial threshold needs real-device and personal-relevance evaluation.

## Product behavior

- Download and activate the separate 484 MB Reads model from Reads or Settings.
  It does not
  replace the active writing model. Its model-list row includes Download,
  Activate for Reads, Active for Reads, Deactivate, and Remove controls.
  Activation is persisted but weights are loaded only while selecting content.
- Recent journal excerpts provide context when no generated memory exists;
  corrected memory summaries take precedence. Excluded/deleted journals cannot
  contribute. Up to 12 journal samples (180 characters each) are used per pass.
- RSS, Nostr long-form articles, and signed kind-1 Nostr notes enter the existing
  bounded, diversified candidate pool (at most 80 items). The model evaluates
  titles and feed excerpts, not the full linked web pages. A relevant Nostr
  note opens its event in a Nostr reader; outbound links are not independently
  imported as approved articles.
- Short notes are deduplicated by event ID, limited per author, and checked for
  content warnings/spam before scoring. Requests contain no journal text.
- Cached feed entries are candidates only. Approvals are session-local and tied
  to full candidate content/URL and the current journal revision. Edits,
  exclusions, deletion, and changed feed content invalidate prior approvals.
- Evaluation runs off-main, one candidate at a time. Recording, model activation,
  journal writing, backgrounding, low power, and thermal pressure pause
  work between candidates. The small model is released after each pass. An
  already executing prompt is bounded to 2,048 tokens and is not preempted.
- Optional large-model journal indexing yields between entries to active Reads
  selection. The small model can run from original journals with no writer active.
- Accepted items sort by the small model's score; prior ranking breaks ties.
- Daily selections and normal Reads cards both use the same admission gate.
  The instruction allows relevant challenges to beliefs, not just agreement.

## Model provenance

- [Upstream model and scoring format](https://huggingface.co/Qwen/Qwen3-Reranker-0.6B)
- [QuantFactory Q4_K_M artifact](https://huggingface.co/QuantFactory/Qwen3-Reranker-0.6B-GGUF/blob/9bdee8f1ad01d7896a20823d5affd66c494eee8b/Qwen3-Reranker-0.6B.Q4_K_M.gguf)
- License: Apache 2.0. Model weights are downloaded, not committed.
- Pinned revision: `9bdee8f1ad01d7896a20823d5affd66c494eee8b`.
- SHA256: `783d816e7541ba78a5105f949a010217fecf31795c267d69ffa5a96403dff4a7`.

The Swift loader streams checksum verification before opening the model. The
quant's `general.name` is `Models`, so that field cannot identify its training.
The native engine checks `general.architecture=qwen3`. User text is tokenized
with special-token parsing disabled; only the fixed model template can insert
chat delimiters. Model/handle operations share the existing inference mutex.

## Validation and remaining gate

- `zig build test test-ffi -j2`: 414 tests pass, 2 existing tests skip.
- Native ReleaseFast build succeeds with vendored llama.cpp.
- Real pinned-model smoke through the production C ABI: related gardening
  passage scores 0.988725, unrelated sports passage 0.000002. Missing handles,
  empty queries, and oversized documents abstain. Reproduce with:
  `SLOWCLAW_READS_GGUF=/path/to/model.gguf bash ios-app/Tests/reads-decision-smoke.sh`.
- Swift frontend parsing passes for all app sources. Standalone Swift admission
  checks pass for missing/invalid scores, rejection, approval, and stale inputs.
  The Nostr fetcher also typechecks on Linux with platform types shimmed.
- Added macOS runtime tests for signed Nostr notes, tampering, content warnings,
  deduplication, and strict admission. Run `bash ios-app/Tests/run.sh` on macOS.
- Full Xcode build, the macOS runtime suite, and device UI/latency/memory testing
  remain necessary before release; this Linux environment cannot run them.
  In particular measure memory while a journal model is also loaded, and test
  download/relaunch, recording interruption, and editing/excluding a journal
  during selection. The synthetic smoke is not a relevance benchmark.

## Scope and rollback

Proven: existing GGUF download, CPU inference, serial executor, candidate
ranking and Nostr ingestion. Better: a trained relevance decision replaces
heuristic admission. New: ordinary Nostr notes join Reads through that same gate.
This preserves the journal-first capture → curation → open publishing direction.
Journal generation, transcription, publishing and signing workflows are unchanged.

Rollback: revert the feature commit. No journal/database schema changes are
introduced. Cache version 5 contains candidates only and can be discarded;
the model can be removed in Settings. The existing TestFlight workflow explicitly accepts pushes to
`feat/local-reads-relevance` for pre-merge release validation.
