# slowclaw.social

SlowClaw Social is a local-first, **journal-first brain-feeder** — a personal capture and curation app. Your journals are the **lens** that decides what flows back to you.

It is an **iOS app** built from two layers:

- A **Zig core** (`zig-src/`) compiled to a static library, exposed through a C ABI.
- A **thin native Swift shell** (`ios-app/`) that links the Zig staticlib + vendored SQLite + vendored llama.cpp (CPU) and renders the SwiftUI app.

There is no Rust, no Tauri, no React, no npm, no web bundle, no embedded HTTP gateway, and no desktop/CLI/daemon surface. Those were removed in the `zig-ios-pivot` consolidation.

It is built around **one workspace** and three loops:

1. **Capture** — write journals and notes, or **record audio (the default) or video**. Capture stays on-device: transcription via iOS `SFSpeechRecognizer` (`SpeechTranscriber.swift`), AI via on-device inference (llama.cpp/GGUF in `zig-src/src/local_inference.zig`).
2. **Feed (journal-driven curation)** — articles, news, and video (incl. YouTube) are ranked by **relevance to your own journals**, not generic popularity. What you've written shapes what you read and watch back. This is the core idea: the journal feeds your mind.
3. **Share / Connect** — distill your thinking into drafts, review them, and publish out to open protocols (Nostr short-form and long-form). Discovery of people whose insights resonate flows back into the feed.

## How it works

SlowClaw is built around one idea: **what you write is the lens for what you read back.**

- The **Zig core** owns ranking (`ranker.zig`, `feeds_ranking.zig`), memory + persistence (`sqlite.zig`, `markdown.zig`, `response_cache.zig`), embeddings (`embeddings.zig`), RSS parsing (`rss_parser.zig`), the feed catalog (`feed_catalog.zig`), the journal agent (`journal_agent.zig`), the interest profile (`interest_profile.zig`), and on-device LLM inference (`local_inference.zig`). It is compiled to three static archives — `libslowclaw_feed.a`, `libsqlite3.a`, `libllama.a` — that the app links.
- The **Swift shell** (`ios-app/`) talks to the core only through the C ABI declared in `ios-app/SlowClawFeed/include/slowclaw_feed.h` (mirroring `zig-src/src/ffi.zig`). It owns audio capture, on-device speech, voice-memo import, Nostr fetching, and the SwiftUI surfaces (Journal, Reads, On-Device AI / TweetClaw, Profile).

For the full module map, the C ABI surface, the build graph, and the known iOS-specific link workarounds, see [`zig-src/README.md`](zig-src/README.md). For the Xcode project, signing, and the pre-build `zig build` script, see [`ios-app/README.md`](ios-app/README.md).

## Quick start (iOS, macOS only)

Prerequisites:

- **Xcode** (full app) + Command Line Tools
- **XcodeGen** — `brew install xcodegen`
- **Zig 0.16.0** — from <https://ziglang.org/download/0.16.0/>, placed on `PATH` or under `tools/zig/` (gitignored)

Build and run:

```bash
cd ios-app
xcodegen generate         # regenerates SlowClaw.xcodeproj from project.yml
open SlowClaw.xcodeproj   # pick a sim/device target and run
```

The Xcode pre-build script runs `zig build` automatically for the right target (`aarch64-ios-sim` for simulator, `aarch64-ios` for device), so editing Zig source and re-running in Xcode picks up the changes.

## Zig core (tests)

```bash
cd zig-src
zig build                  # emits zig-out/lib{slowclaw_feed,sqlite3,llama}.a
zig build test             # libc-free unit tests
zig build test-ffi         # C ABI round-trip tests
zig build test-sqlite      # SQLite memory backend tests
zig build test-markdown    # Markdown memory backend tests
zig build test-response-cache
SLOWCLAW_TEST_GGUF=/path/to/model.gguf zig build test-local-llm   # on-device LLM smoke
```

## TestFlight (CI)

`.github/workflows/pub-testflight-zig.yml` builds the Zig core for iOS, generates the Xcode project, signs it via App Store Connect API, and uploads to TestFlight. It triggers on push to `main` (when `zig-src/`, `ios-app/`, or the workflow file change) or manually via `workflow_dispatch`. It is the **only** publish path — there is no Docker, Homebrew, or generic release workflow anymore.

Required repo secrets / variables (App Store Connect + signing):

- `APP_STORE_CONNECT_ISSUER_ID`
- `APP_STORE_CONNECT_KEY_ID`
- `APP_STORE_CONNECT_PRIVATE_KEY`
- `APPLE_DEVELOPMENT_TEAM` (variable or secret)

The cert + provisioning profile are issued fresh per run via the App Store Connect API (and stale CI profiles are cleaned up to avoid hitting Apple's limits).

## Project layout

```
slowclaw.social/
  zig-src/                # Zig core (the engine)
    build.zig             # 3 static archives + multiple test steps
    build.zig.zon         # package manifest (no external deps)
    src/                  # ffi, ranker, sqlite, markdown, embeddings,
                          #   chunker, local_inference, rss_parser,
                          #   feed_catalog, journal_agent, ...
    vendor/sqlite/        # vendored SQLite 3.46 amalgamation
    vendor/llama.cpp/     # vendored llama.cpp (b10201, CPU backend)
  ios-app/                # native Swift shell
    project.yml           # XcodeGen spec (SlowClaw.xcodeproj is gitignored)
    SlowClawApp/          # SwiftUI app + audio + speech + Nostr fetch
    SlowClawFeed/         # Swift package wrapping the C ABI
  docs/README.md          # docs entry point
  README.md
  AGENTS.md               # agent engineering protocol
  LICENSE-APACHE
  LICENSE-MIT
```

Local-only (gitignored): `tools/zig/` (the locally downloaded Zig toolchain, ~177MB), `zig-src/.zig-cache/`, `zig-src/zig-out/`.

## Vision

The authoritative, enforceable vision is [`docs/vision-contract.md`](docs/vision-contract.md) (where present). The product pipeline is the **three loops**: **multimodal capture (audio-first, on-device) → journal-driven curation (the journal is the lens; articles + news + video incl. YouTube) → draft review → open publishing/ingestion (Nostr / RSS / Atom).**

Video/YouTube is a first-class *ingestion* source (read-only) while the user's own content and publishing stay open-protocol-bound.
