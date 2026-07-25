# Zig iOS Pivot — Status & Lessons Learned

> **Branch:** `zig-ios-pivot` (off `gemini-refactor`)
> **Date:** 2026-07-25
> **Commits:** 30 since branch point
> **Goal:** Full rewrite of the Rust core in Zig, iOS-only app, TestFlight-deployable

---

## What's been accomplished

### Ported modules (~7,600 LOC of Zig)

| Module | Rust source | Zig LOC | Tests | Status |
|--------|------------|---------|-------|--------|
| `vector_math.zig` | `memory/vector.rs` | 443 | 30 | ✅ Green |
| `text_util.zig` | `util.rs` | 146 | 9 | ✅ Green |
| `porter_stemmer.zig` | `rust_stemmers` crate | 551 | 45 golden pairs | ✅ Green |
| `tokenize.zig` | `feed/ranker.rs:426-578` | 274 | 8 | ✅ Green |
| `feed_types.zig` | `feed/types.rs` | 185 | 6 | ✅ Green |
| `ranker.zig` | `feed/ranker.rs` (703 LOC) | 1247 | 18 | ✅ Green |
| `memory_types.zig` | `memory/traits.rs` | 207 | 4 | ✅ Green |
| `chunker.zig` | `memory/chunker.rs` | 558 | 19 | ✅ Green |
| `embeddings.zig` | `memory/embeddings.rs` | 466 | 9 | ✅ Green |
| `sqlite.zig` | `memory/sqlite.rs` (1900 LOC) | 950+ | 70 | ✅ Green |
| `markdown.zig` | `memory/markdown.rs` | 600+ | 14 | ✅ Green |
| `response_cache.zig` | `memory/response_cache.rs` | 438 | 10 | ✅ Green |
| `ffi.zig` | (new — C ABI) | 450+ | 7 | ✅ Green |

**Total: 334 tests across 5 test suites, 0 failures, 0 leaks (on Windows host).**

### iOS shell (~650 LOC of Swift + config)

- `ios-app/project.yml` — XcodeGen project spec
- `ios-app/SlowClawApp/SlowClawApp.swift` — SwiftUI demo (store/recall memories)
- `ios-app/SlowClawFeed/Sources/SlowClawFeed/SlowClawFeed.swift` — idiomatic Swift overlay
- `ios-app/SlowClawFeed/Sources/SlowClawFeed/include/slowclaw_feed.h` — C ABI header

### CI pipeline

- `.github/workflows/pub-testflight-zig.yml` — Zig-only TestFlight build (no Tauri/Rust/npm)
- `.github/workflows/scripts/asc-issue-cert-profile.js` — shared App Store Connect signing script

### Vendored dependencies

- `zig-src/vendor/sqlite/` — SQLite 3.46 amalgamation (sqlite3.c + .h + sqlite3ext.h)

---

## Current blocker: TestFlight CI run

**Status:** Workflow runs but fails at "Build Zig staticlib (iOS device)" step.

**Latest error:** The repack-to-8-byte-align step (added to fix a prior Apple ld alignment error) can't find the `.a` file at the expected cache path.

**Progression of CI failures and fixes (13 runs total):**

| Run # | Failure point | Root cause | Fix applied |
|-------|-------------|-----------|-------------|
| 1 | Zig download (curl 404) | Wrong URL: `zig-macos-0.16.0` → should be `zig-aarch64-macos-0.16.0` | Fixed URL in workflow |
| 2-3 | Build Zig staticlib: `unable to find dynamic system library 'sqlite3'` | Zig cross-compiler can't find iOS system libsqlite3 | Switched to always compiling vendored SQLite amalgamation |
| 4-6 | Build Zig staticlib: `'stdio.h' file not found` | sqlite3.c needs iOS SDK headers; Zig doesn't ship them | Added `-Dios-sysroot` build option + `addSystemIncludePath` |
| 7 | Build Zig staticlib: `std.process.Child.run` not found | Zig 0.16 removed this API | Dropped xcrun auto-discovery; use `-Dios-sysroot` option only |
| 8 | Build Zig staticlib: `'time.h' file not found` in @cImport | lib_mod also needs iOS SDK headers for @cImport | Applied `addIosSysroot` to lib_mod too |
| 9-10 | Build Zig staticlib: `requires aligned address` / `@ptrCast increases pointer alignment` | `SQLITE_TRANSIENT` = `((sqlite3_destructor_type)-1)` — arm64 Zig rejects -1 as a function pointer | Declared `sqlite3_bind_text`/`sqlite3_bind_blob` as local `extern fn` with `?*const anyopaque` destructor param |
| 11 | Archive: `unable to resolve module dependency: 'SlowClawFeed'` | `import SlowClawFeed` but module compiled in same target | Removed import (same-target sources) |
| 12 | Archive: `extension outside of file prevents CaseIterable synthesis` | Swift CaseIterable conformance in separate file from enum | Moved `CaseIterable` to enum declaration |
| 13 | Archive: `ld: member not 8-byte aligned in libslowclaw_feed.a` | Zig's `.a` archive members aren't 8-byte padded (Apple ld requires it) | **Attempted repack step — itself failing (current blocker)** |

---

## How to fix the current blocker

The repack step added in the last commit (`0d806c0`) tries to use `ar` to extract and repack the `.a`, but the path to the archive in the Zig cache is wrong. Two approaches:

### Option A: Fix the repack step (quick)

The Zig build's install step puts the `.a` at `zig-out/lib/libslowclaw_feed.a` (on Linux/macOS — no `.lib` suffix). The repack script should operate on THAT path, not the cache path. Update the repack `Run` step in `build.zig` to point at `b.path("zig-out/lib/libslowclaw_feed.a")` or just do the repack in the CI workflow step after `zig build` completes:

```bash
# In the workflow, AFTER zig build:
cd zig-src/zig-out/lib
ar x libslowclaw_feed.a
ar rcs libslowclaw_feed.a *.o
rm *.o
```

### Option B: Use Zig's `ar` with `__ar_parse__` workaround

Zig 0.16's `zig ar` may support alignment flags. Or use macOS's system `ar` (which produces correctly-aligned archives natively) by setting the archiver in build.zig.

### Option C: Link object files directly (skip .a entirely)

Instead of producing a `.a`, have Zig emit the object files and link them directly into the Xcode target. This avoids the archive format entirely. Add the `.o` files to the Xcode project as source files.

---

## Key Zig 0.16 API changes encountered (reference for future work)

These are the Zig 0.16 stdlib changes that broke our code during the port. Future Zig work should expect to hit these again:

| Old API | New API (0.16) | Where it hit |
|---------|---------------|--------------|
| `std.crypto.random.bytes()` | `std.Random.DefaultPrng.init(seed).random().bytes()` | sqlite.zig (UUID generation) |
| `std.time.timestamp()` / `nanoTimestamp()` | Removed — use libc `time()` via `@cImport` | sqlite.zig, markdown.zig, response_cache.zig |
| `std.fs.cwd().deleteFile()` / `std.fs.deleteFile()` | Removed — use libc `remove()` | markdown.zig |
| `std.process.getEnvVarOwned()` | Moved into Io subsystem — use libc `getenv()` | markdown.zig, build.zig |
| `std.process.Child.run()` | Moved into Io subsystem | build.zig |
| `std.math.negInf(f32)` | `-std.math.inf(f32)` | vector_math.zig, ranker.zig, sqlite.zig |
| `std.mem.trimRight()` | `std.mem.trimEnd()` | text_util.zig |
| `std.fmt.fmtSliceHexLower()` | `std.fmt.bytesToHex(bytes, .lower)` | response_cache.zig |
| `ArrayList.writer()` | Removed — use `std.fmt.allocPrint` in a loop | chunker.zig, embeddings.zig |
| `ArrayList.append(item)` | `ArrayList.append(allocator, item)` | Everywhere (allocator per-call) |
| `ArrayList.deinit()` | `ArrayList.deinit(allocator)` | Everywhere |
| `ArrayList.init(allocator)` | `ArrayList.empty` | Everywhere |
| `addStaticLibrary(...)` | `addLibrary(.{ .root_module = ..., .linkage = .static })` | build.zig |
| `step.linkLibrary(other)` | `module.linkLibrary(other)` | build.zig |
| `@import("builtin").os.tag == .macos` for host detection | Still works | build.zig |
| Export fns in imported modules are NOT retained | Must `pub export fn` + `comptime { _ = &ffi.fn; }` in root.zig | **Critical** — root.zig |
| `SQLITE_TRANSIENT` via `@cImport` on arm64 | Fails alignment check — declare `extern fn` with `?*const anyopaque` | sqlite.zig, response_cache.zig |
| Zig `.a` archive on Apple platforms | Members not 8-byte aligned — Apple `ld` rejects. Need repack with system `ar` | **Current blocker** |

---

## Architecture decisions (clean-slate)

### What was dropped (per "question the old architecture")

- **Tauri** — entirely dropped for iOS. No web UI, no React, no npm.
- **Rust** — not a single line of Rust is compiled for the iOS path.
- **Desktop gateway/daemon/CLI** — not ported, not needed for iOS.
- **`security/` module** — confirmed NOT imported by any iOS-relevant code (only the desktop gateway uses it). iOS sandboxing + Keychain enforce security.
- **Chat channels** (Telegram, Discord, Slack, Lark, etc.) — intentionally removed per AGENTS.md.
- **`config/schema.rs`** (7,631 LOC) — mostly chat-channel noise; deferred, not ported.

### What was kept / ported

- Feed ranker (the "journal-is-the-lens" curation engine)
- Memory subsystem (SQLite + markdown + response cache + chunker + embeddings)
- All as Zig, behind a C ABI, consumed by SwiftUI

### What's still in Rust (untouched on this branch)

Everything — the Rust source is intact and additive. This branch adds Zig; it doesn't remove Rust. The Rust→Zig replacement is a merge-time decision.

---

## Module dependency graph

```
root.zig (library entry — force-retains all export fns)
├── ffi.zig (C ABI — Swift-callable)
│   ├── ranker.zig
│   ├── embeddings.zig
│   ├── sqlite.zig
│   └── feed_types.zig
├── ranker.zig (feed ranking pipeline)
│   ├── vector_math.zig
│   ├── tokenize.zig
│   ├── feed_types.zig
│   └── embeddings.zig
├── sqlite.zig (production persistence)
│   ├── vector_math.zig
│   ├── embeddings.zig
│   └── memory_types.zig
├── markdown.zig (file-backed alternative backend)
│   └── memory_types.zig
├── response_cache.zig (LLM response cache)
├── embeddings.zig (EmbeddingProvider vtable + HashEmbedding)
├── chunker.zig (markdown text chunking)
├── memory_types.zig (Memory trait vtable + types)
├── feed_types.zig (feed data structs)
├── tokenize.zig (tokenizer + Porter stemmer)
│   └── porter_stemmer.zig
├── porter_stemmer.zig (Snowball English from scratch)
├── text_util.zig (UTF-8 truncation)
└── vector_math.zig (cosine similarity, hybrid merge)
```

---

## Test suite structure

```bash
cd zig-src
zig build test              # 117 tests (libc-free, ranker/vector/chunker/embeddings)
zig build test-ffi          # 123 tests (libc + sqlite, C ABI round-trip)
zig build test-sqlite       # 70 tests (libc + sqlite, SqliteMemory ops)
zig build test-markdown     # 14 tests (libc, file I/O)
zig build test-response-cache # 10 tests (libc + sqlite, LLM cache)
```

Test separation is deliberate: linking libc changes the debug allocator's behavior and broke ranker tests (latent use-after-free in the `neg()` test helper that only manifested under libc). The split keeps the libc-free test binary clean.

---

## Next steps (priority order)

1. **Fix the `.a` archive 8-byte alignment issue** — the current CI blocker. Quickest: repack with system `ar` in the CI workflow step after `zig build`. Once fixed, the workflow should reach the Archive → Export → TestFlight upload steps.

2. **Validate TestFlight upload** — the signing script is shared with the proven legacy workflow, so it should work. First successful upload = the milestone.

3. **On-device test** — install the TestFlight build on an iPhone, verify the store/recall round-trip works.

4. **HTTP + feed ingestion** — the biggest product gap. `std.http.Client.fetch` is available in Zig 0.16. This unlocks the "Feed loop" (journal-driven Bluesky/Nostr/RSS curation).

5. **On-device LLM** — mirror `web/src-tauri/src/inference.rs` in Zig calling llama.cpp's C API directly, exposed through the same C ABI. This is the "Capture loop" (audio-first journal transcription + on-device synthesis).

6. **Open-protocol publishing** — Bluesky/Nostr publishing for the "Share/Connect loop."

7. **Drop the Rust code** — once the Zig core reaches feature parity, remove `src/`, `web/src-tauri/`, `Cargo.toml`, and the legacy TestFlight workflow.

---

## Lessons for future Zig iOS work

1. **Zig 0.16 is bleeding-edge** — many stdlib APIs were renamed or removed between 0.14/0.15 and 0.16. Expect 2-3 API migrations per module ported.

2. **Cross-compiling C code for iOS from Zig requires the iOS SDK sysroot** — pass it via `-Dios-sysroot=$(xcrun --sdk iphoneos --show-sdk-path)`. Zig doesn't auto-discover it.

3. **`@cImport` on arm64 is fragile with function pointer macros** — `SQLITE_TRANSIENT = ((fn*)-1)` fails three different ways on arm64 Zig. Workaround: declare the functions yourself with `?*const anyopaque` for the problematic parameter.

4. **Export functions in static libraries must be force-retained** — `pub export fn` + `comptime { _ = &ffi.fn_name; }` in the root source file. Without this, Zig 0.16's lazy compilation silently omits them and the `.a` is empty.

5. **Zig `.a` archives need repacking for Apple `ld`** — Zig's archiver doesn't 8-byte-align members, which Apple's linker requires. Repack with system `ar` after building.

6. **Test allocator behavior changes when libc is linked** — latent use-after-free bugs that are invisible under Zig's debug allocator surface immediately under libc's malloc. This is a feature, not a bug — it finds real bugs. But it means you need separate test binaries for libc-free vs libc-linked tests.

7. **XcodeGen is the right tool for Zig+Xcode projects** — the `.xcodeproj` format is too complex to hand-write. XcodeGen's `project.yml` is diff-able and reviewable.

8. **The `defer` order in Zig is LIFO** — `defer a.free(x); defer do_thing(x);` will free `x` FIRST, then `do_thing` reads freed memory. This bit us in markdown tests. Always put cleanup BEFORE the data-using defer, or combine them into a single helper.
