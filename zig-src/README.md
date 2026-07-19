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

## Module layout (target)

```
zig-src/
  build.zig             # staticlib + test runner
  build.zig.zon         # package manifest, no external deps
  src/
    root.zig            # public re-exports
    vector_math.zig     # cosine_similarity, vec<->bytes, hybrid_merge   (slice 2)
    text_util.zig       # truncate_with_ellipsis (UTF-8 safe)            (slice 3)
    tokenize.zig        # tokenize_terms, tokenize_and_stem, stopwords,  (slice 4)
                        #   Porter stemmer
    feed_types.zig      # InterestVector, FeedProfile, FeedCandidate, …  (slice 5)
    ranker.zig          # the ported ranker functions                    (slice 6)
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

(none yet — will be listed here as they are discovered)

## Status

- [x] Scaffold + build/test runner
- [ ] vector_math.zig
- [ ] text_util.zig
- [ ] tokenize.zig
- [ ] feed_types.zig
- [ ] ranker.zig
