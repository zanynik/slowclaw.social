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

## C ABI surface (Swift consumers)

The staticlib `libslowclaw_feed.a` exposes a small C ABI in `src/ffi.zig`. Swift
imports it via a bridging header (TBD in the iOS shell slice). Current surface:

| Function | Purpose |
| --- | --- |
| `slowclaw_feed_free(ptr)` | Free any pointer returned by the library. |
| `slowclaw_feed_hash_embedder_new(model, dims)` | Create a `HashEmbedding` handle. |
| `slowclaw_feed_hash_embedder_free(handle)` | Destroy a HashEmbedding handle. |
| `slowclaw_feed_hash_embed(handle, text, out_dims)` | Embed one text → f32 buffer. |
| `slowclaw_feed_rank_stage2(interests, negatives, candidates, limit, now, out_err)` | Run the keyword-path ranker over C-struct inputs; returns a JSON array of ranked items. |
| `slowclaw_feed_rank_result_free(result)` | Free a rank result and its JSON string. |
| `slowclaw_feed_sqlite_open(path, embedder)` | Open (or create) a SQLite memory DB. |
| `slowclaw_feed_sqlite_close(handle)` | Close and free the DB. |
| `slowclaw_feed_sqlite_health(handle)` | Returns true if `SELECT 1` succeeds. |
| `slowclaw_feed_sqlite_store(handle, key, content, category, session_id)` | Insert or upsert a memory. |
| `slowclaw_feed_sqlite_get(handle, key, out_entry)` | Fetch a memory by key → entry struct. |
| `slowclaw_feed_sqlite_forget(handle, key)` | Delete by key. Returns 1 if removed, 0 if not found. |
| `slowclaw_feed_sqlite_count(handle)` | Count stored memories. |
| `slowclaw_feed_sqlite_recall(handle, query, limit, session_id, out_result)` | Hybrid FTS5+vector search → JSON array. |
| `slowclaw_feed_sqlite_result_free(result)` | Free a recall JSON result. |
| `slowclaw_feed_sqlite_entry_free(entry)` | Free an entry obtained from `sqlite_get`. |

**Memory ownership**: strings passed in are caller-owned (Zig does not free).
Strings/buffers passed out are Zig-allocated via `c_allocator`; the caller frees
via `slowclaw_feed_free`. Errors are returned as a negative status code; an
optional `*SlowclawString` out-param receives the error message (also
caller-freed).

**Embedder callback** (TODO): the next slice adds `slowclaw_feed_rank(...)` that
takes a Swift-provided C function pointer for the embedder (matching
`SlowclawEmbedFunction`), enabling the full stage-1 embedding path from Swift
without going through HashEmbedding.



- **Zig 0.16.0** (stable, April 2026).
- Download from <https://ziglang.org/download/0.16.0/> and place on `PATH`, or
  locally under `tools/zig/` (the `tools/` directory is gitignored).

## Build / test

```bash
cd zig-src
zig build                  # emits zig-out/libslowclaw_feed.a + zig-out/libsqlite3.a (staticlibs)
zig build test             # libc-free unit tests (ranker, vector_math, chunker, embeddings, …)
zig build test-ffi         # C ABI round-trip tests (libc + sqlite linked)
zig build test-sqlite      # SQLite-backed memory store tests (libc + vendored SQLite)
zig build test-markdown    # Markdown memory backend tests (libc for file I/O)
zig build test-response-cache # LLM response cache tests (libc + sqlite)
```

## Known iOS link issues (Zig 0.16.0)

Three separate Zig 0.16.0 regressions surface only when linking the staticlib
into an iOS app (the unit tests never exercise the Xcode link). All three are
fixed in the 0.17-dev branch and **not** backported to any 0.16.x release; the
workarounds below are wired into `build.zig` / `ios-app/project.yml` / CI.

### 1. Apple `ld` rejects Zig's staticlib archive (member alignment)

Zig 0.16's archive writer hardcodes the 4-byte (`.p32`) format even for 64-bit
Mach-O members, so Apple's `ld` (Xcode 26.4+) fails with:

```
ld: 64-bit mach-o member 'libslowclaw_feed_zcu.o' not 8-byte aligned in '.../libslowclaw_feed.a'
```

[Codeberg ziglang/zig#35280](https://codeberg.org/ziglang/zig/issues/35280).

**Workaround (in `build.zig`):** on a macOS host, the build graph installs
`libslowclaw_feed.a` normally (the static `.a` is only materialized by the
install step), then extracts its members with `xcrun ar -x` and reassembles them
with `xcrun libtool -static` + `xcrun ranlib` (which write 8-byte-aligned
members), and install-copies the aligned archive over `zig-out/lib/`. Non-macOS
hosts skip the repack — Apple `ld` is never the consumer there. CI additionally
runs `nm -a` on the installed archive so a regression surfaces at the Zig build
step, not 5 min later at the Xcode link.

> Local macOS incremental-build note: the repack step's input (the installed
> archive) is a plain path arg, so Zig's per-step cache doesn't content-track
> it. If the link error reappears after editing Zig sources, `rm -rf
> zig-src/.zig-cache` and rebuild. (CI runs fresh, so it is unaffected.)

### 2. SQLite is a separate archive — the app must link both

`build.zig` emits **two** static archives: `libslowclaw_feed.a` (the Zig code)
and `libsqlite3.a` (the vendored SQLite amalgamation). They are NOT merged —
`lib_mod.linkLibrary(sqlite_c)` records a dependency, it does not bundle the
sqlite objects into the feed archive. So the iOS app must link both:

```yaml
OTHER_LDFLAGS: "-lslowclaw_feed -lsqlite3"
```

This is set in `ios-app/project.yml` (base + target settings), and the XcodeGen
pre-build script copies both archives from the sim prefix too. (Earlier comments
in `project.yml` wrongly claimed SQLite was compiled "INTO" `libslowclaw_feed.a`
— corrected.)

### 3. `_dyld_get_image_header_containing_address` is unavailable on iOS

Zig 0.16's `std.debug` unconditionally calls `_dyld_get_image_header_containing_address`,
which is `__API_UNAVAILABLE(ios, tvos, watchos)` in Apple's `mach-o/dyld.h`. It
exists on macOS (and the iOS Simulator, which links the host libdyld), so the
failure only shows on a real iOS-device build:

```
Undefined symbols for architecture arm64:
  "__dyld_get_image_header_containing_address", referenced from:
      _debug.writeCurrentStackTrace in libslowclaw_feed.a(libslowclaw_feed_zcu.o)
```

Fixed upstream by [Codeberg ziglang/zig#32138](https://codeberg.org/ziglang/zig/pulls/32138)
(falls back to `dladdr` on non-macOS). On 0.16.0, build with
`-Doptimize=ReleaseFast` (not `ReleaseSafe`): the lib has no reachable
`@panic`/`unreachable`, so `ReleaseFast` drops the safety-panic stack-walk path
that references the unavailable symbol. This is set in CI and in the `project.yml`
pre-build script (sim + device).

> If a future change makes a panic path reachable in `ReleaseFast`, the residual
> fallback is a weak C stub of the symbol returning `NULL` (see PR #32138).

### Cleanup when bumping Zig past 0.16

When moving to a 0.17 release that contains both upstream fixes, delete the
`repackInstalledArchiveStep` branch in `build.zig` (revert to
`b.installArtifact(lib)`), and the `-Doptimize=ReleaseFast` choice can be
revisited (the SQLite dual-archive link in `project.yml` stays — that is the
intended build.zig structure, not a bug).

## Module layout (current)

```
zig-src/
  build.zig             # 3 test steps + 2 staticlibs (libslowclaw_feed, libsqlite3)
  build.zig.zon         # package manifest, no external deps
  src/
    root.zig            # library public re-exports (includes ffi + sqlite)
    test_root.zig       # libc-free test entry point (excludes ffi/sqlite)
    ffi.zig             # C ABI surface — Swift-callable export fns
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
    sqlite.zig          # SqliteMemory — production persistence via vendored SQLite
                        #   (FTS5 search, embedding cache, Memory trait ops)
    markdown.zig        # MarkdownMemory — file-backed append-only memory backend
                        #   (MEMORY.md + memory/YYYY-MM-DD.md, alternative to sqlite)
    response_cache.zig  # ResponseCache — LLM response cache (SHA-256 keyed,
                        #   TTL + LRU eviction, separate SQLite DB)
  vendor/sqlite/        # vendored SQLite 3.46 amalgamation (sqlite3.c + .h)
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
- [x] ffi.zig — C ABI surface (rank_stage2, hash embedder, JSON serialization);
      build separates libc-free tests from libc-linked library artifact
- [x] sqlite.zig — SQLite memory backend via vendored SQLite amalgamation
      (compiled by Zig; FTS5 keyword search; upsert, get, list, forget, count,
      session_id + custom-category round-trip, file persistence)

**Total: 117 libc-free + 123 FFI + 70 SQLite + 14 Markdown + 10 ResponseCache = 334 tests, 0 leaks.** The
production persistence backend works end-to-end and is fully reachable from
Swift through the C ABI: open a database, store memories, recall via hybrid
FTS5+vector search, get/forget by key, and inspect health/count. The markdown
backend offers a plain-text audit-trail alternative; the response cache saves
LLM tokens on repeated prompts.

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
