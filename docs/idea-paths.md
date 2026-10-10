# Idea Paths in SlowClaw Web

After pairing, open **Your thoughts → Build idea paths**. The three latest phone journals (including transcripts) supply the source text. If their full text is not in the recent snapshot, the browser requests it over the existing encrypted peer queue. The phone remains authoritative; Idea Path cards are derived browser data and do not edit journals.

The web organizer now uses the working Idea Path Laboratory embedding approach instead of its earlier MediaPipe organizer. Previously saved phone thought groups remain visible below the new cards. This rollout does not change their model identifier, convert their vectors, or imply that new chain cards are saved on the phone.

## Proven → Better → New

- Proven: reuse the measured prototype's Transformers.js 4.3.1, `onnx-community/embeddinggemma-2-ONNX`, q4/WebGPU, 768 dimensions, `title: none | text: ` prefix and cosine/step-alignment scoring.
- Better: use a dedicated embedding worker, visible model-download/inference progress, pause/retry, encrypted local caches and exact source references. A saved journal revision reuses its embeddings. WebGPU uses the prototype's q4 model; browsers without an adapter use q8/WASM because q4's GatherBlockQuantized operator is unsupported by the CPU backend. Backend-specific caches prevent mixing quantizations in one chain. Pin model revision `daa72c51243991dfcaf9f9137d2c573d8f7790c0` rather than mutable main.
- New: create complete-link semantic groups, then score ordered chains inside each group. Earliest/latest passages anchor each chain; score averages adjacent idea similarity and step-vector alignment with equal weights, as in the prototype. These are suggested connections, not evidence of cause or a generated summary.

## Processing bounds

Each passage uses five nonempty source lines. A single-paragraph transcript uses five sentences. Oversized passages split at 1,600 UTF-16 characters without splitting surrogate pairs. Each journal contributes its first 20 passages, at most 60 total; the UI explicitly reports truncation. Excerpts retain their journal identifier, revision and character offsets. Nothing is paraphrased.

Complete-link clustering uses cosine threshold 0.86 and at most eight passages per group. An isolated passage remains visible rather than being forced into an unrelated group. Each group exhaustively scores its interior permutations (at most 720 routes), keeping earliest/latest anchors. High similarity does not guarantee human-perceived coherence; the user reviews the excerpts.

Models/runtime are fetched from Hugging Face/jsDelivr. Journal text is passed only to the local model. It is never sent to these providers or the Cloudflare signaling Worker. Derived text/vectors and the latest loaded sources are encrypted with the browser session key in IndexedDB; logout removes them through the existing workspace deletion barrier. Browser storage is working storage, not backup. Model weights may remain in the browser's public model-download cache after logout; they contain no journal text.

A sample at `https://slowclaw.social/?sample=idea-path` uses three invented journals and the same production component/worker. It never opens the real workspace, reads phone data, or bypasses pairing. It provides a reproducible model/download check without exposing private journals.

## Pairing timeout

The previous browser waited for complete ICE discovery and rejected after 20 seconds, even when usable host candidates had already arrived. It now waits up to 12 seconds and can publish the gathered candidates when an unresponsive STUN server holds discovery open. Zero candidates still produce an explicit network-route error, and closing the connection cancels discovery. This does not guarantee connectivity through restrictive NAT or a VPN; use the same Wi-Fi first, or configure the documented optional TURN relay. The Cloudflare plugin confirmed the existing Worker configuration; journal storage remains absent.

## Verification

`pnpm typecheck`, `pnpm test`, and `pnpm build` passed. The initial live q4/WASM check caught an unsupported GatherBlockQuantized operator; this prompted the q4/WebGPU and q8/WASM split rather than treating a successful build as inference verification. Tests exercise exact five-line/prose chunks, Unicode/oversized passages, full 768-dimensional validation, the prototype's geometric step score, bounded complete-link grouping, stalled ICE with candidates, no candidates and connection cancellation. A real iPhone/browser sync still requires the user's compatible TestFlight build 201 and an open phone app.

Rollback: revert the Idea Paths web commit to restore the previous web surface. The existing Pages workflow's `legacy_landing` input can restore the original static landing page. Neither action deletes phone journals.
