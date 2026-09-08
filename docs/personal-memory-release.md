# Personal memory release

Proven: extend the existing durable journal index, serialized local inference,
Reads ranking and private draft review. Better: source-linked, editable memory
and semantic relevance supplement topic matching. New on top: selective short
post candidates from recent journals, without manual journal selection.

## Behavior

- Local-only extraction creates one interest, project or question observation
  per journal, with an exact source quotation. No personality, diagnosis, values
  or philosophical assessment. Structured output with invented quotes is rejected.
- Long journals are sampled at the beginning, middle and end (1,800 characters
  plus separators); this is an observation from passages, not a full summary.
  The existing bounded 60-entry journal snapshot is the indexing work list.
- Memories live in the existing local journal-index metadata. The Settings
  Personal memory sheet supports corrections and source navigation. Forget &
  exclude persists across relaunch and source edits. Exclusion is also available
  before processing from a journal's detail screen. Inclusion is explicit.
- Source edits invalidate observations before another model pass. Completion
  checks deletion, exclusion, source content and memory revision. Corrections
  replace both semantic text and inferred topic labels.
- Apple Natural Language sentence embeddings match up to 48 memories against
  120 candidate articles, on an off-main actor. Only same-language vectors are
  compared. Unavailable language models retain the existing topic ranking;
  no hashing is presented as semantic understanding. Vectors are ephemeral.
  The existing Zig ranker owns the bounded semantic scoring policy through a
  scalar-only additive C ABI. Source diversity, filtering and freshness remain.
- Explanations name the connected observation and open the source journal.
  Semantic similarity is not a truth or agreement assessment. No new external
  research service is added. Existing feed retrieval still uses topic labels.
- One model request extracts memory and optionally proposes a short post.
  Most entries should return no candidate. Candidates must be 30–300 characters;
  URLs/contact handles are rejected. The model is told to omit identifying or
  third-party private details, but review is essential: this isn't a PII guarantee.
  Save at most one per 24 hours from journals under seven days old, with at most
  three automatic drafts in the current draft list. Discarded/edited candidates
  aren't regenerated merely on refresh. Source links remain private metadata.
- The automatic drafting toggle is in Personal memory. No automatic long posts,
  philosophical nudges, new tabs, new model download or automatic publishing.
- Heavy extraction uses the existing optional-work queue and serialized native
  executor. Recording/transcription, manual writing, low power, heat and suspension
  defer new requests. A native inference request already running completes first.
  Embedding passes check priority between vectors and discard interrupted results.
  An already-downloaded model can activate after a five-second settling delay
  only when there is pending memory work and priority checks permit it. Explicit
  Unload prevents automatic reactivation for that session. Cached Reads retains
  its source-match metadata across relaunch; unchanged indexing doesn't erase it.

## Validation and rollback

New runtime tests cover fabricated-source rejection, unsupported memory kinds,
long-journal sampling, draft bounds/contact exclusion, and corrected-memory
persistence. New Zig tests cover semantic thresholds, nonfinite values, score
caps and decay; a scalar C ABI round trip covers the exported policy.

Linux workspace has no Swift/Xcode or Zig toolchain. Local diff/contract checks
precede push; macOS CI runs runtime tests, Zig unit/FFI tests, full iOS compile,
archive, export, TestFlight upload and signing cleanup before merge. Actual local
model JSON/output quality, language asset availability, relevance calibration,
Dynamic Type and physical iPhone speech/lock behavior still need device testing.

Rollback: revert this release. No SQLite, original-journal or Speech engine
migration. Older versions ignore the optional insight field. The exclusion and
auto-draft preferences remain local metadata; drafts use existing SQLite rows.

Native embedding API reference:
https://developer.apple.com/documentation/naturallanguage/nlembedding
