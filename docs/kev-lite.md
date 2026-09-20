# SlowClaw Lite: Kev experiment

This branch is an explicitly requested TestFlight experiment, not the production
default. It uses the same app identity and local database; do not merge it into
main until the user has tried it. Capture, Apple Speech transcription, journal
editing/export/deletion, Nostr signing and reviewed publishing are preserved.

## One local judge

| Previously | Lite behavior |
| --- | --- |
| Keyword topic weights, semantic boost, reranker gate and daily promotion | One Kev relevance score; checked items descend by relevance with ID ties |
| Automatic large-model journal analysis and generated short posts | On-demand exact-sentence highlight, open question and private short draft |
| Semantic/keyword personal-memory retrieval | Kev ranks up to 24 recent original journal passages |
| Separate question/evidence matching | The same Kev judge ranks journal connections and cached reading |
| Generated contextual reflections | Revisit original passages, select a highlight/question, follow it |
| Broad writing-model configuration | Kev download/activate, personal memory, Nostr, storage and speech diagnostics |

RSS and signed Nostr remain ordinary bounded network ingestion. Source transport,
signatures, URL deduplication, content warnings and storage are not model tasks.
The RSS catalog rotates a bounded slice daily without sending private topics to
servers. Content excerpts enter a bounded 80-item pool. The existing parser and
source caps still bound discovery, but do not determine visible relevance order.
A user can add an http(s) link; up to 256 KiB of text is read and its excerpt is
judged. Javascript-only pages and truncated excerpts may be uninformative.

Reads uses up to twelve recent included journals (short, spread-out original
passages), with explicitly corrected memory notes taking precedence. No automatic
large-model index is required. Legacy generated summaries no longer drive Reads.
All successfully checked items are shown by default, because the previous
12-case experiment demonstrated that a 0.80 gate misses relevant material.
"Strong matches only" restores that optional cutoff. Unchecked/failed/stale
items remain hidden. Scores are model estimates, not calibrated probabilities.

Create's "Find highlights" checks six recent journals; individual selection is
available for twelve. Seven complete source sentences are sampled across each
journal, plus an explicit abstention option. Kev chooses an important passage,
an open question and sentences suitable for a short post. Up to two high-scoring
public-post candidates are joined in original source order, capped at 280
characters without truncating sentences. No new sentences are generated.
Every saved draft is validated against the current original source and linked
back to it. A repeated save does not overwrite an edited draft. The model's
privacy judgment is fallible: a user must review the actual wording before
publishing. Nothing is sent or published automatically.

## Model and native runtime

Pinned Kev v0.1 LoRA is merged into Qwen2.5-0.5B and quantized to Q8_0. The two
896-to-256 pointer projections and biases stay FP32 in GGUF metadata. The one
533 MB download has a pinned SHA256; weights remain on device. It uses the
existing vendored llama.cpp CPU runtime, not Python or a server on the phone.

The C ABI accepts typed question options and returns probability arrays. It
uses upstream delimiter sanitization, shared-state sequence IDs and independent
question branches with restarted positions. Context is bounded to 4,096 packed
tokens, 1,536 state tokens and 2,048 positions per branch. Up to eight questions
with eight choices each are accepted. Invalid inputs abstain. State, options and
answers are not written to logs. Model operations share the existing inference
mutex and run off the main actor. Models close after a pass; recording,
backgrounding, low power and thermal pressure pause between evaluations.

Read approvals are session-local and tied to exact item content and journal
revision. Edits, corrected notes, exclusion, deletion and deactivation invalidate
results. Keep originals and existing full-app settings so rollback does not need
a database migration. The Kev activation preference has a separate key from the
legacy reranker; installing Lite does not silently activate another model.

## Evidence

- `zig build test test-ffi`: native ABI/unit suite passed (existing skips retained).
- Exact-source Swift selection, bounded assembly, invalid distributions and stale
  reads checked locally; macOS runtime tests include those paths in TestFlight CI.
- F32 port versus upstream probabilities: maximum difference 0.00000398 across
  12 cases; packed/separate maximum difference 0.000001051.
- The shipped Q8 model: reference maximum difference 0.04183, packed/separate
  difference 0.02485. These are quantized backend numerical differences; the
  F32 comparison above verifies attention isolation independently. Repeated
  identical Q8 requests produce identical recorded probabilities on this host.
- Real model smoke tests exercise all five reading questions, normalization,
  repeatability, absent handles, empty/oversized input and packed/separate calls.
  See `ios-app/Tests/kev/native-q8-results.json` and `native-smoke.sh`.
- No claim of improved semantic accuracy: the original weak relevance/topic
  results remain in `kev-reads-evaluation.md`. This release permits user testing
  of the proposed Lite behavior despite that known limitation. Device latency,
  peak memory and non-English quality need hands-on evaluation.

## Release and rollback

Only `pub-testflight-zig.yml` publishes the app. On this explicit branch a Linux
job builds/verifies the pinned model asset and makes an immutable prerelease
asset available. Its contents-write permission is limited to that job; iOS
signing uses the existing job and secrets. A checksum mismatch stops publishing.
The macOS job downloads that asset, reruns the production ABI smoke, then runs
the normal device build, validation, signing and TestFlight upload.

Use Settings → Kev-0.5B → Download → Activate Kev. The app labels this build Lite.
To roll back, install the previous full-app TestFlight build. Journals, drafts,
Nostr keys and full-app model files are retained. Deactivate/remove Kev in Lite
Settings if desired. This branch must remain unmerged for the experiment.

Proven → Better → New: reuse capture, local inference and reviewed publishing;
simplify relevance to one judge; add exact-sentence selection and journal recall
through that same judge. Kev is fallible, even though its inference has no random
sampling. It is not used for transcription, URL fetching, signatures or access
control.
