# Grouped thoughts and the local decision model

This extends the existing journal and paired-browser flows (Proven → Better). It adds a simple **Your thoughts** surface on the web and **Profile → Grouped thoughts** on iPhone. Groups consist of exact journal excerpts; their titles are short source excerpts, never generated claims about the person. They stay private and do not publish anything.

## Journal understanding

EmbeddingGemma 2 runs locally in a browser worker so longer journal archives can process while the laptop remains open. The paired server holds only ciphertext. Older journals are requested one at a time using the existing encrypted journal read queue. Each completed journal's vectors and excerpts are sent as a durable encrypted operation and saved atomically on the phone. Lost receipts retry the same operation ID. Browser pending state is encrypted with the session key; logout removes it.

Use Google's clustering task prefix. Retain and re-normalize the first 256 dimensions, rounding each value to six decimal places for smaller transfers. Merge adjacent sentences at cosine ≥0.93 and re-embed the resulting exact excerpt. Group excerpts at ≥0.94 against a fixed representative, preventing weak similarity chains. These conservative thresholds were selected after real synthetic runtime checks; clustering is organizational, not a claim of factual equivalence.

The phone verifies the pinned model, current canonical revision, inclusion status, exact readable source substring, finite 256d vector and unit norm before accepting results. Updated/deleted/excluded journals disappear from groups immediately. Source checking uses the same cleaned transcript projection as the web editor. Forgetting an excerpt persists by a source-key/text digest. Full records live in `journal-units.json`, protected with complete file protection. Grouping runs off the main actor, and obsolete grouping tasks are discarded.

The eligible MediaPipe runtime `1.1.0-rc.20260929` requires a vision encoder at initialization. Therefore the pinned EmbeddingGemma 2 text-and-vision bundle is used with **text-only input**. It was exercised with real WASM inference; no alternate embedding model is substituted. The web snapshot displays up to 100 groups with 30 excerpts each; the full collection stays on the phone. The browser processes journals up to the editor's 1 MB limit and bounded sentence/result counts, reporting failures explicitly.

## Strands Decider v21

Reads, exact journal selection, context relevance, and Pulse use the pinned Strands Decider 2B v21 classifier. It replaces Kev as the app's local judge and removes Needle from the iOS link/build and Pulse runtime. The old Needle ABI remains as an explicit unavailable result for source compatibility; it never loads a substitute. Cloud Jev remains an existing separately controlled option.

The model uses the existing llama.cpp Qwen3.5 implementation, with the merged rank-16 adapter, FP32 LayerNorm/pointer projections and fitted choice temperature. XML prompts and option-token endpoints match the reference implementation. State and each full question are tokenized separately. Hybrid recurrent state requires a fresh full context per question; branch-prefix caching is intentionally absent. Inputs exceeding 4096 tokens are rejected, with no truncation. The Qwen3.5 embedding-only graph skips its unused vocabulary projection; generation contexts retain the original path. Pulse caches scores and yields the serial executor between posts so recording can take priority. Pulse, Reads and journal/context selection exclude each other while a Decider handle is open, avoiding two copies in memory. No C ABI ownership rules change: additive Decider exports use caller-owned buffers and serial executor ownership.

The GGUF is Q6_K, about 1.56 GB; the model's SHA-256 is verified before loading. Installation/activation remains explicit in Advanced settings, using a new preference key so an old Kev installation cannot be mistaken for Decider. The existing TestFlight workflow packages a pinned model release once, verifies its digest, runs native reference comparisons, then compiles/signs/uploads the app. No additional app publishing workflow is introduced.

## Validation and rollback

- Web: source-excerpt and vector tests, autosave/receipt tests, paired-session security tests, TypeScript, production build, real EmbeddingGemma 2 WASM inference.
- Native: Zig unit/FFI tests, full host archive build, actual Q6 model/reference comparison, independent-question isolation, repeatability and malformed/context-limit rejection.
- Real Q6 comparison: maximum score drift 0.0474, 59/60 reference winners, packed/separate questions and repeats identical. Q4 was rejected at 0.1229 maximum drift.
- Swift/iOS: source tests and full device build in the existing TestFlight workflow; Linux cannot execute Apple's SwiftUI/AVFoundation UI.

Synthetic model fixtures contain no real journals. Native runtime latency on an actual iPhone remains to be measured. Grouping may leave genuinely related passages separate; it does not change their text. Rolling back the two scoped commits restores the previous model/UI while original journals remain intact. Removing the grouped-thoughts feature leaves its cache available for a later compatible release; no source journals depend on it.
