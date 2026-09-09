# Grounded context and single-pass articles

Proven → Better: extend the existing editable journal memory, Apple sentence
embeddings, Zig scoring, serial inference executor and Reads. One Explore
drill-down, accessible from Personal memory in Journals or Settings; no new tab.

## Tools and boundaries

- Personal context search combines literal words with same-language sentence
  embeddings over at most 128 indexed source passages. Zig owns relevance
  scoring. Old experiences do not lose relevance solely because of age. Missing
  embedding assets retain literal-word matching. Retrieval is not agreement.
- Original-source retrieval rechecks exclusion, deletion and the exact passage.
  Search/reflect results are discarded when memory revisions change. Correcting
  a memory can also change its kind: experience, interpretation, explicit belief
  or value, alongside interest/project/question. Existing records remain valid.
  New extraction preserves one quoted current-source observation and can use
  one retrieved previous passage for context. It may not import prior facts.
- Evidence discovery first ranks cached Reads excerpts (RSS/Nostr), with source
  diversity and existing dislikes respected. An optional, explicitly entered
  public query searches English Wikipedia introductions. No journal or inferred
  query is automatically sent to that service. Fixed HTTPS API host, ephemeral
  session, timeout, 100 KB response cap, five results. Network failure leaves
  local suggestions usable. This is background reading, not general web search
  or automated fact-checking. Results are labeled as excerpts, not full articles.
- A bounded reflection uses up to two journal passages and one user-selected
  external excerpt in one local request. JSON citations must refer to supplied
  IDs and reproduce exact passages, including a journal citation. Fabricated or
  unavailable sources reject the result. These checks establish provenance,
  not correctness of the model's interpretation. No truth score, spiritual
  assessment, autonomous publishing or arbitrary model-selected URLs/actions.
- Reading an evidence link uses the in-app browser and existing reading-time
  signals. Raw journal passages and vectors remain local. Reflections are
  temporary exploration results; original memories stay editable and persistent.

The toolbox is orchestrated by bounded app workflows, not a recursive model
agent. Optional work respects capture, transcription, heat, low power and app
activity; a native generation already running completes before cancellation.
The durable index still starts from the existing 60-entry journal snapshot;
this is not a complete search over every historical recording on the device.

## Single-pass drafting

Removed journal-summary passes, the title request and three separately generated
article sections. Both models now produce a draft in exactly one inference
request from original passages. Up to three sources share the input budget;
long sources are sampled at the beginning, middle and end, visibly marked.

MiniCPM5 article requests use a 4,096-token ceiling and 1,024 output tokens;
short tasks remain at 1,536. Gemma retains 1,536 and requests a shorter article.
MiniCPM5 supports 131,072 positions in its publisher configuration; that is not
an iPhone memory/performance promise. Long-form overflow returns an explicit
error instead of silently truncating source tokens. Completed drafts are saved
only if their source journals still match. No changes to Speech or signing.

## Validation and rollback

Local diff, shell, YAML, single-call and ABI checks precede push. This Linux
workspace has no Swift/Xcode or Zig toolchain. CI runs Swift tests for source
grounding, query boundaries, UTF-8 sampling and migration; a live Wikipedia
provider check; Zig retrieval/ABI tests; pinned actual-GGUF inference including
a single-pass article exceeding the old combined context, duplicate-paragraph
checks and overflow rejection; then iOS compile/archive/export/upload/cleanup.

Physical iPhone memory pressure, latency, heat, output quality, Dynamic Type,
transcription and lock behavior require device use; CI cannot establish them.
Rollback by reverting this release; no database or original-journal migration.

Sources checked 9 September 2026:
- https://huggingface.co/openbmb/MiniCPM5-2B/blob/main/config.json
- https://www.mediawiki.org/wiki/API:Search
- https://www.mediawiki.org/wiki/Extension:TextExtracts#API
