# `zig-src/` — SlowClaw Social Zig core pilot

This is **slice 1** of the iOS-only Zig pivot (branch `zig-ios-pivot`). It is a
**port-in-progress**, intentionally additive: the Rust source under `src/` stays
the authoritative spec until the port reaches feature parity and the iOS shell
wires up. No Rust code is deleted in this slice.

## Scope of slice 1

Port the **pure-logic core of `src/feed/ranker.rs`** (703 LOC) plus its two pure
dependencies (`cosine_similarity` from `src/memory/vector.rs`, and
`truncate_with_ellipsis` from `src/util.rs`) to Zig, behind an idiomatic Zig
public API, fully tested.

Explicitly **out of scope** for slice 1 (later slices):
- `src/feed/mod.rs` (5,601 LOC) — Bluesky / Nostr / RSS / gateway coupling.
- Tauri host, iOS shell, Swift bridge, Xcode integration.
- Removing Rust, dropping desktop, CI surgery.

## Toolchain

- **Zig 0.16.0** (stable, April 2026).
- Download from <https://ziglang.org/download/0.16.0/> and place on `PATH`, or
  locally under `tools/zig/` (the `tools/` directory is gitignored).

## Build / test

```bash
cd zig-src
zig build           # emits zig-out/libslowclaw_feed.a (staticlib)
zig build test      # runs every test{} block in the package
```

## Module layout (current)

```
zig-src/
  build.zig             # staticlib + test runner
  build.zig.zon         # package manifest, no external deps
  src/
    root.zig            # public re-exports + test discovery
    vector_math.zig     # cosine_similarity, vec<->bytes, hybrid_merge
    text_util.zig       # truncate_with_ellipsis (UTF-8 safe)
    porter_stemmer.zig  # Snowball English (Porter2) stemmer, from scratch
    tokenize.zig        # tokenize_terms, tokenize_and_stem, stopwords, stem_term
    feed_types.zig      # InterestVector, FeedProfile, FeedCandidate, …
    ranker.zig          # pure helpers, RFC3339 freshness, interleave,
                        #   rank_candidates (sync, embedder-injected),
                        #   rank_candidates_stage2
    memory_types.zig    # MemoryEntry, MemoryCategory, Memory backend vtable
    chunker.zig         # line-based markdown chunker (headings→paragraphs→lines)
    embeddings.zig      # EmbeddingProvider vtable, NoopEmbedding, HashEmbedding
                        #   (deterministic fallback; Builtin/OpenAi stay FFI-injected)
  README.md             # this file
```

## Methodology

TDD red-green-refactor per slice, using the Rust tests in
`src/memory/vector.rs`, `src/util.rs`, and `src/feed/ranker.rs` as the **spec**.
Zig tests are idiomatic (table-driven where it fits, `std.testing`) rather than
verbatim Rust copies.

## Cross-validation

For functions with floating-point output, the Rust originals are run first to
capture expected values (`cargo test --lib memory::vector`,
`cargo test --lib feed::ranker`), then Zig outputs are asserted to match within
`1e-6`.

## Known divergences from Rust

- **`item_sort_timestamp`**: the Rust impl reads `post.indexedAt` / `publishedAt`
  from the `feed_item` JSON value via serde. The Zig port stores `feed_item` as
  an opaque JSON blob (`feed_item_json: []const u8`) and currently only honors
  the `web_preview.discovered_at` path. Parsing the JSON for the fallback paths
  is tracked as TODO(slice-7) — surfaced in the code at the call site. The
  freshness bonus returns 0 for items that rely on the JSON path only.
- **Snowball stemmer**: the Zig `porter_stemmer.zig` is a from-scratch Snowball
  English (Porter2) implementation validated against 45 (word → stem) golden
  pairs captured from `rust_stemmers`. Edge cases beyond the captured set may
  diverge from `rust_stemmers`; file an issue with the failing word and the
  expected Snowball output if found.
- **`rank_candidates` is synchronous** with an injected embedder callback
  (Zig function pointer), replacing tokio + `Arc<dyn EmbeddingProvider>`. This
  is the idiomatic Zig shape; the iOS FFI slice will wrap the embedder call as a
  Swift callback through the C ABI.
- **`Memory` and `EmbeddingProvider` traits are vtables**, not language traits.
  Zig 0.16 traits can't express the multi-method + ctx contracts the way Rust
  traits do; the struct-of-function-pointers + `*anyopaque` pattern is the
  idiomatic equivalent and the same shape Swift will see through the C ABI.
- **`HashEmbedding` Unicode handling**: text normalization lowercases ASCII
  codepoints and passes non-ASCII letters through. Rust's `char::is_alphanumeric`
  is fully Unicode; our ASCII fast path matches English text and treats
  non-ASCII letters as separators (loose divergence). Extending to the Unicode
  alpha table is a tracked follow-up if real journal input needs it.
- **`BuiltinEmbedding` (tract-onnx + tokenizers) and `OpenAiEmbedding` (HTTP)**
  are not ported — they have no Zig equivalents. They'll be implemented on the
  Swift/iOS side (CoreML/Metal for on-device, URLSession for OpenAI-compatible)
  and surfaced to the ranker via the same `EmbeddingProvider` vtable through the
  C ABI in a later slice.

## Cross-validation against Rust

Shared spec tests run on both sides and agree within `1e-6`:
- `cargo test --lib memory::vector` → **30/30 pass** (Rust)
- `cargo test --lib feed::ranker` → **3/3 pass** (the `negative_keyword_penalty`
  trio — ported verbatim to Zig with identical assertions and tolerances)
- `zig build test` → **85/85 pass, 0 leaks** (Zig; includes the verbatim ports)

The golden stemmer pairs were captured from `rust_stemmers` via a standalone
Rust probe binary (see the test block `stem: golden pairs from rust_stemmers`
in `src/porter_stemmer.zig`).

## Status

- [x] Scaffold + build/test runner
- [x] vector_math.zig — cosine_similarity, vec↔bytes, hybrid_merge (30 tests)
- [x] text_util.zig — truncate_with_ellipsis, UTF-8 safe (9 tests)
- [x] porter_stemmer.zig — Snowball English (Porter2), 45 golden pairs + exceptions
- [x] tokenize.zig — tokenize_terms, tokenize_and_stem, stopwords, stem_term
- [x] feed_types.zig — InterestVector, FeedProfile, FeedCandidate, …
- [x] ranker.zig — pure helpers, RFC3339 freshness, interleave, rank_candidates
      (embedder-injected, sync), rank_candidates_stage2
- [x] memory_types.zig — MemoryEntry, MemoryCategory, Memory backend vtable
- [x] chunker.zig — line-based markdown chunker (18 Rust edge-case tests)
- [x] embeddings.zig — EmbeddingProvider vtable, NoopEmbedding, HashEmbedding
      (deterministic fallback, FNV-1a hashed features, L2-normalized)
- [x] ranker.Embedder unified with embeddings.EmbeddingProvider (single contract)

**Total: 117 tests, 0 leaks.** Ported so far: all of `src/feed/ranker.rs`
(703 LOC) plus its pure deps, the `Memory` trait + types, the markdown chunker,
and the embeddings trait + Noop + Hash implementations.

## Next slices (not in this branch's current scope)

- **Slice 3 (config):** port `src/config/` (7,737 LOC) — schema + loading +
  env-var merging. Pure data + parsing; biggest unblocking win for everything
  downstream (providers, gateway, tools all read config).
- **Slice 4 (security core):** port `src/security/{policy,pairing,secrets,traits}.rs`
  — the iOS-relevant subset (skip landlock/firejail/bubblewrap/docker which are
  desktop-Linux sandboxing only).
- **Slice 5 (memory backends):** port `src/memory/sqlite.rs` (66K — the
  production backend) + `markdown.rs`. These are the real persistence path.
- **Slice 6 (feed/mod.rs):** port the network-heavy 5,601-line Bluesky/Nostr/RSS
  layer. Largest single chunk.
- **Slice 7 (FFI):** expose rank_candidates, Memory, EmbeddingProvider behind a
  C ABI; wire Swift callbacks for the embedder; parse `feed_item_json`.
- **Later:** iOS native shell (SwiftUI + Zig staticlib), drop Tauri, remove
  desktop/CLI/gateway surfaces, CI surgery.
