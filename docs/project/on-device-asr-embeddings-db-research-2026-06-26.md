# On-Device ASR, Embeddings, and SurrealDB — Research Snapshot

- **Date:** 2026-06-26
- **Scope:** Local speech-to-text for the iOS app (post-recording transcription),
  local embedding models for chunking + RAG over journal entries, and feasibility
  of embedding SurrealDB into the iOS / Tauri mobile app.
- **Audience:** maintainers, contributors planning the iOS transcription feature,
  anyone evaluating the memory backend migration.
- **Vision gates applied:** `docs/vision-contract.md` — privacy-first,
  local-or-user-controlled vectorization, multimodal capture, cross-platform,
  open ecosystem, trait/contract-driven extension.

> **Evidence rule.** Every recommendation below is tied to code, dependencies,
> or plist keys that already exist in this repo, plus widely known model/runtime
> characteristics through early 2026. Verify any "latest 2026" claim against the
> upstream project before adoption (links included).

---

## 1. Where we are today (ground truth from this repo)

### 1.1 Transcription — placeholder, not wired

`web/src-tauri/src/transcription.rs` is an explicit stub:

> "On-device audio transcription is coming soon. For now, use the AI model to
> generate posts from your journal text."
> — `Err("On-device audio transcription is coming soon...")`

So today the iOS app has **no working on-device ASR**. Desktop has a Python
`scripts/transcribe_audio_journal.py` that shells out to `faster-whisper`
(CTranslate2 + int8). That works on desktop only and is not usable from the
Tauri iOS sandbox (no Python runtime shipped, no Whisper binary shipped).

iOS-side plumbing is already prepared:
- `web/src-tauri/Info.ios.plist` already declares `NSSpeechRecognitionUsageDescription`
  ("SlowClaw uses on-device speech recognition to transcribe your audio journal entries").
- `web/src/lib/audioRecorder.ts` and `web/src/App.tsx` both check for a native
  recorder plugin global `__SLOWCLAW_NATIVE_AUDIO_RECORDER__` — the recording
  side is the missing piece for a fully native flow.

So the ASR work is the **transcription half** of a recorder+transcribe pipeline
where the recorder half is already plumbed.

### 1.2 Embeddings — already on-device via ONNX Runtime

`src/memory/embeddings.rs`:
- Uses `tract-onnx` (pure Rust ONNX inference).
- Default local model: **all-MiniLM-L6-v2** (384 dims, 256 token max),
  pulled from `Xenova/all-MiniLM-L6-v2` (tokenizer + quantized ONNX).
- Hash-based fallback when local model init fails (degraded, not for RAG).
- This runs in the Rust core today (server/desktop side).

`web/src-tauri/Cargo.toml` exposes a `native-inference` feature that already
pulls in `llama-cpp-2` with `metal` for the iOS build, so the Tauri shell is
already prepared to ship native inference in the IPA. The same `tract-onnx`
stack used for embeddings on the server can be compiled into the iOS binary
with no new native bridge — it is pure Rust.

### 1.3 Storage / DBs — already substantial

Existing backends:
- `src/memory/sqlite.rs` (1900 lines) — SQLite + FTS5 + `embedding_cache`
  table; vector similarity computed in Rust via brute-force
  `vector::cosine_similarity` over stored `BLOB` embeddings.
- `src/memory/postgres.rs` — Postgres backend.
- `src/memory/qdrant.rs` — dedicated Qdrant vector DB backend.
- `src/memory/chunker.rs` — line-based markdown chunker (heading- and
  paragraph-aware).
- `src/memory/vector.rs` — vector utilities.
- `src/channels/pocketbase.rs` — PocketBase channel integration (also a
  bundled PocketBase in repo root).

iOS today does not use any of these directly — the iOS app talks to the Rust
gateway over HTTP for journal persistence and (currently failing) transcription.

---

## 2. Local transcription for iOS — ranked options

Evaluated against: on-device runtime, English quality floor, multilingual
support, model size suitable for an iPhone binary, licensing, and how cleanly
it fits the existing Rust + Tauri + iOS surface.

### 2.1 Recommended: Apple `SFSpeechRecognizer` (best quality-per-byte on iOS)

- **What:** Apple's on-device speech recognition (`SFSpeechRecognizer` with
  `requiresOnDeviceRecognition = true`).
- **Quality:** High for the user's chosen dictation language; Apple tunes these
  models per locale and runs them on the Apple Neural Engine. For English
  journal dictation this is generally the best quality-per-megabyte option
  available on iOS.
- **Privacy:** Fully on-device when `requiresOnDeviceRecognition` is set; no
  audio leaves the device.
- **License:** Apple SDK (ships with iOS).
- **iOS viability:** Native, supported since iOS 13; ANE-accelerated.
- **Integration path:** This is the TODO already noted in
  `web/src-tauri/src/transcription.rs` ("a future version will add a proper
  Swift plugin for high-quality on-device transcription via SFSpeechRecognizer").
  The plist key is already there.
- **Limitations:**
  - Per-app language pack must be installed by the user (Settings →
    General → Keyboard → Dictation → Continuous Dictation / Languages) — UX
    caveat, not a blocker.
  - Returns partial results / final results as a callback — must be wired
    through a Swift → ObjC block → Rust FFI bridge (the original reason the
    stub exists).
  - Quality drops on long-form continuous dictation vs Whisper-class models
    (segmentation issues), but for 30 s–5 min journal entries this is fine.

**Verdict: ship this first.** It is the cheapest, highest-quality local ASR
on iOS and matches the existing TODO exactly. A Tauri Swift plugin bridging
`SFSpeechRecognizer` is the smallest possible code change.

### 2.2 Strong fallback: `sherpa-onnx` (k2-fsa) for portable on-device ASR

- **What:** `sherpa-onnx` — pure C++ ONNX-based ASR runtime from k2-fsa, with
  Rust bindings and a curated model zoo including Whisper, Paraformer, Moonshine,
  Zipformer, and NeMo Parakeet/TDT.
- **Why it matters here:** It runs the same ONNX models already used elsewhere
  in the repo via `tract-onnx`, and it supports streaming, which the journal
  capture UX wants (start transcribing as the user records).
- **Quality:** Depends on model. Top picks for English journal use:
  - **Whisper tiny.en / base.en** — recognizable quality floor, small.
  - **Moonshine tiny/base** — designed for on-device, lower memory than
    Whisper at similar English quality (open weights, Apache-2.0).
  - **sherpa-onnx Zipformer / Parakeet TDT** — strong streaming accuracy, but
    the model files are larger and more complex.
- **iOS viability:** Has iOS builds (sherpa-onnx ships iOS frameworks via XCFramework
  on its releases). Cross-compile or vendor the XCFramework into the Tauri iOS
  project and call via the same Swift plugin pattern.
- **License:** Apache-2.0 for the runtime; model licenses vary (Whisper MIT,
  Moonshine Apache-2.0, Zipformer/Parakeet CC-BY / Apache-2.0 — verify each).
- **Integration path:** Bigger than SFSpeech — needs XCFramework, model asset
  download/first-run install, and a Rust/Swift bridge. But it gives you a
  **cross-platform** ASR story (the same code path works on Android via the
  same Tauri shell, and on the desktop gateway).
- **Limitations:**
  - Binary size: Whisper tiny (~75 MB) or Moonshine tiny (~60 MB) on top of
    the existing `llama-cpp-2` + embeddings ONNX. May push the IPA over the
    cellular download size cap unless assets are downloaded on demand.
  - Must ship model files or download them first-run.

**Verdict: second wave.** Worth doing for cross-platform parity and as a
fallback for languages where Apple's on-device pack isn't installed. Don't
ship it as the default over SFSpeech on iOS.

### 2.3 Last resort: server-side Whisper over the gateway

The existing `scripts/transcribe_audio_journal.py` runs `faster-whisper`
(CTranslate2, int8). The mobile app already uploads audio to the gateway
(see `web/src/App.tsx` upload flow + `setRecordingHint`). So server-side
Whisper is **already reachable** — but it is not local and violates the
vision-contract's "local or user-controlled vectorization" spirit. Keep
this as a fallback only for users who disabled on-device ASR.

---

## 3. Concrete recommendation for shipping ASR in the iOS app

Two-stage plan, smallest blast radius:

**Stage A — ship `SFSpeechRecognizer` first (fills the existing TODO).**
- Add a Tauri Swift plugin in `web/src-tauri/ios/Sources/SpeechPlugin/`
  (matches the existing `__SLOWCLAW_NATIVE_AUDIO_RECORDER__` plugin pattern).
- Expose `plugin:speech|transcribe` commands: `start`, `stop`, `cancel`,
  streaming `transcription_event`.
- Set `requiresOnDeviceRecognition = true`.
- Wire `transcribe_audio_file` in `web/src-tauri/src/transcription.rs` to
  delegate to the plugin; remove the placeholder error.
- This alone fixes the user's complaint ("audio recorder button" is now
  paired with a working transcript).

**Stage B — add `sherpa-onnx` Moonshine or Whisper-tiny as the offline /
  cross-platform fallback** (optional, after Stage A). Worth it only if
  cross-platform parity (Android, desktop without gateway) is a near-term
  goal. If it is, prefer **Moonshine** over Whisper-tiny: better
  quality-per-MB for English, Apache-2.0.

Don't ship a Whisper model bundled inside the IPA. If a Whisper-class model
is added later, download on first use (`mlmodel` style download flow), or
require a user opt-in ("Download offline transcription model, 60 MB").

---

## 4. Local embedding models for RAG over journal entries

You already have a working local embedding path. The question is whether to
keep `all-MiniLM-L6-v2` or swap to a better small model.

### 4.1 The current model: `all-MiniLM-L6-v2`

- 384 dims, 256 token max, ~22 MB quantized ONNX.
- Trained on English; multilingual retrieval is weak.
- Quality floor for English retrieval is decent, not great.
- Already loaded via `tract-onnx` and cached on first use.

### 4.2 Better options to evaluate (all run on the same `tract-onnx` stack)

| Model | Dims | Multilingual | Quality (MTEB English avg) | License | Notes |
|---|---|---|---|---|---|
| `Xenova/all-MiniLM-L6-v2` (current) | 384 | EN only | ~56 | Apache-2.0 | Tiny. Good enough for English-only. |
| `Xenova/bge-small-en-v1.5` | 384 | EN only | higher than MiniLM | MIT | Drop-in replacement; same dims. |
| `Xenova/gte-small` | 384 | EN | competitive with BGE-small | MIT | Strong at short queries. |
| `Xenova/bge-m3` | 1024 | 100+ langs | strong multilingual | MIT | ~570 MB; too big to ship on iOS. Skip for mobile. |
| `onnx-community/embeddinggemma-300m` / smaller Gemma embedders | varies | multilingual | newer generation | Gemma license | Verify availability of a quantized ONNX suitable for `tract-onnx` before adopting. |
| `Xenova/multilingual-e5-small` | 384 | multilingual | good for multilingual | MIT | If the journal is bilingual, this is the right swap. |

> **Caveat.** Exact MTEB numbers and "latest 2026" model availability drift
> quickly. Verify against the `Xenova` (now `@huggingface/transformers.js`
> curated ONNX) catalog and the MTEB leaderboard before locking in. The
> table above is qualitative, not a benchmark.

### 4.3 Chunking — already good for this app

`src/memory/chunker.rs` is heading/paragraph-aware and respects a max-token
limit. For RAG over journal entries (which are short, markdown notes, often
audio transcripts), this is the right granularity. No change needed.

Considerations if RAG becomes a feature:
- Increase the embedding's max input length when you swap models (MiniLM is
  256 tokens; BGE-small and GTE-small are 512). Journal entries rarely need
  > 512 tokens per chunk.
- Keep an embedding cache (`embedding_cache` table already exists) so repeat
  queries don't re-embed.

### 4.4 Recommendation

- **Keep `tract-onnx` + the existing `embedding_cache` pipeline.**
- **Default: stay on `all-MiniLM-L6-v2` for the iOS build** (small, fast,
  fits in the IPA, proven). Provide a config knob
  (`memory.embedding.model = "bge-small-en-v1.5" | "gte-small" | "all-MiniLM-L6-v2"`)
  to swap without code changes, matching the existing `whisper_model` /
  `whisper_path` config pattern in `crates/robot-kit`.
- **If the journal becomes multilingual:** swap default to
  `multilingual-e5-small` (same 384 dims, same `tract-onnx` path, MIT).
- **Do not** adopt BGE-M3 or Gemma-class embedders for the iOS binary —
  they are too large. Keep them as a desktop/server option.

---

## 5. Can SurrealDB be used in this app?

### 5.1 What SurrealDB offers that overlaps with the current stack

SurrealDB is a multi-model DB (document + graph + relational + vector) with:
- Embedded mode via RocksDB or in-memory.
- A native Rust SDK (`surrealdb` crate).
- Vector search (`vec::distance::knn`) over HNSW.
- Live queries and graph traversal.

The current stack has: SQLite + FTS5 + brute-force cosine + Qdrant backend +
Postgres backend + PocketBase. SurrealDB could **collapse** the SQLite +
vector + (optionally) Qdrant story into one engine.

### 5.2 iOS feasibility — honest assessment

- **Pure Rust SDK exists**, so it can theoretically compile into the Tauri
  iOS binary (which already compiles `tract-onnx`, `llama-cpp-2`, `rusqlite`,
  `reqwest`, etc.).
- **Embedded mode requires RocksDB** by default, which links the Rust
  `rocksdb` crate. That crate historically has not been a happy
  cross-compilation target for iOS — it depends on platform `libc++`/compression
  shims that frequently need patching for `aarch64-apple-ios`. Possible, but
  not free. Plan a spike before committing.
- **In-memory mode (`Surreal::new::<Mem>`)** avoids RocksDB and would work
  on iOS, but data is lost on relaunch — fine as a query/vector cache, not
  as the system of record for journals.
- **Binary size:** SurrealDB embedded + RocksDB adds noticeable weight. The
  TestFlight build already ships `llama-cpp-2` + ONNX models; adding
  SurrealDB+RocksDB pushes the IPA size further toward the cellular download
  cap. Again, verify with a spike build.

### 5.3 Does it fit the existing trait architecture?

It would replace (or sit alongside) `Memory` implementations in
`src/memory/`. The existing `Memory` trait (`src/memory/backend.rs`) and the
factory wiring give a clean insertion point: implement a new
`SurrealMemory` backend, register it in the factory, gate it behind a
`memory.backend = "sqlite" | "postgres" | "qdrant" | "surreal"` config key.
No trait rewrite needed.

### 5.4 Recommendation — keep SurrealDB out of the iOS binary for now

Reasons:
1. **No user-visible gap.** SQLite + `embedding_cache` already cover the
   on-device persistence story; Qdrant is the dedicated vector store where it
   matters (server side).
2. **iOS cross-compile risk.** RocksDB on `aarch64-apple-ios` is the kind of
   build-system pain that bites late and is hard to roll back from inside an
   IPA release cycle. AGENTS.md explicitly values reversibility.
3. **Size budget.** Each new native crate in the Tauri iOS shell is a binary
   size tax; the priority right now is shipping working transcription, not
   swapping the embedded DB.
4. **Architecture fit is good but not necessary.** SurrealDB is a
   *consolidation* play (SQLite + FTS + vector store → one engine). The
   current modular memory backend is already consolidation-friendly via the
   trait + factory pattern.

**Where SurrealDB *is* worth exploring** (separate spike, not part of the
iOS build):
- As a **desktop / self-hosted** memory backend — replaces SQLite+Qdrant
  with one engine, gives you live queries, graph relations between journal
  entries (e.g., "entries that referenced this Bluesky post"), and HNSW
  vector search. This is a real architectural win on the server side and
  doesn't carry iOS build risk.
- As a **sidecar** for the iOS app, talking to a SurrealDB instance over
  HTTP — same pattern as the existing gateway. Don't embed, talk.

If a future PR wants to add SurrealDB support, the right scope is:
1. Add `src/memory/surreal.rs` implementing the existing `Memory` trait.
2. Wire it through `src/memory/mod.rs` factory.
3. Default it off; opt-in via config.
4. Document the iOS-embedded status as "not supported — use HTTP gateway
   mode" so nobody expects it in the IPA.

---

## 6. Summary — what to ship, in what order

| Order | Change | Why | Risk |
|---|---|---|---|
| 1 | `SFSpeechRecognizer` Tauri Swift plugin (fills existing TODO in `web/src-tauri/src/transcription.rs`) | Highest on-device quality-per-MB on iOS; plist key already present; matches the existing TODO and the existing native-plugin pattern (`__SLOWCLAW_NATIVE_AUDIO_RECORDER__`) | Low. The whole point is that the surrounding contract is already there. |
| 2 | Configurable embedding model (`memory.embedding.model`) with `bge-small-en-v1.5` / `gte-small` / `multilingual-e5-small` options on top of the existing `tract-onnx` path | Drop-in improvement for English and multilingual RAG; reuses the existing ONNX + cache + chunker stack | Low. Same runtime, same trait. |
| 3 | Server-side `sherpa-onnx` (Moonshine or Whisper-tiny) for desktop/Android parity | Cross-platform ASR without per-OS plugins | Medium. Adds a model asset + first-run download UX. |
| 4 | `src/memory/surreal.rs` as a self-hosted memory backend (desktop / self-host users) | Consolidation of SQLite + Qdrant; graph + live queries; still trait-driven | Medium. New dependency, new test surface. |
| — | SurrealDB **embedded in the iOS app** | — | **Do not ship.** Cross-compile risk + binary-size budget + no user-visible gap. Revisit only if the on-device storage needs change (e.g., live queries become a product requirement). |

---

## 7. Open questions to resolve before any PR

1. **Is per-user language support a product requirement?** If yes, SFSpeech
   alone is not enough; sherpa-onnx with a Whisper multilingual model or
   Apple's `SpeechAnalyzer` (newer API on recent iOS) should be evaluated.
2. **Will RAG be exposed to the user in v1, or is it internal scaffolding?**
   This decides whether the embedding model bump (Step 2) is v1 or v2.
3. **Cellular-download cap for the IPA.** Apple throttles downloads over
   ~200 MB on cellular. Any on-device ASR/embedding model shipped inside
   the IPA should be either (a) tiny enough to ignore, or (b) downloaded
   on first use with explicit consent.
4. **License audit.** Whisper = MIT, Moonshine = Apache-2.0, BGE = MIT,
   GTE = MIT, multilingual-E5 = MIT, Apple frameworks = Apple TOS, but
   SFSpeech transcripts may be subject to Apple attribution rules — verify
   before claiming full local-data sovereignty in privacy copy.

---

## 8. References (verify before adoption)

- Apple Speech framework: `SFSpeechRecognizer`,
  `requiresOnDeviceRecognition`.
- `sherpa-onnx` (k2-fsa): https://github.com/k2-fsa/sherpa-onnx
- Moonshine (Useful Sensors): https://github.com/usefulsensors/moonshine
- Whisper / faster-whisper: https://github.com/SYSTRAN/faster-whisper
- Whisper.cpp / whisper-rs: https://github.com/tazz4843/whisper-rs
- `tract-onnx`: https://github.com/sonos/tract
- `Xenova` curated ONNX models: https://huggingface.co/Xenova
- MTEB leaderboard: https://huggingface.co/spaces/mteb/leaderboard
- SurrealDB Rust SDK: https://github.com/surrealdb/surrealdb
- SurrealDB embedded mode + RocksDB notes: SurrealDB docs, "Embedded"
  section.

---

## 9. Changelog of this doc

- 2026-06-26 — Initial research snapshot. Coexists with
  `docs/project-triage-snapshot-2026-02-18.md`.