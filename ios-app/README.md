# `ios-app/` — SlowClaw Social iOS app (Zig-backed)

> **Architecture source of truth:** the root [`README.md`](../README.md) holds the
> system-wide diagrams (two-layer architecture, C ABI contract, capture/feed/AI
> loops, CI pipeline). This file covers **XcodeGen, signing, and the pre-build
> `zig build` script specific to the iOS shell**. If anything here disagrees with
> the root README, the root README wins.

The iOS shell of the iOS-only Zig pivot. Contains the SwiftUI app + XcodeGen
project definition + the C ABI contract header. **The `.xcodeproj` is not in
git** — it's regenerated from `project.yml` via XcodeGen. This keeps the
project definition reviewable and diff-able.

## Layout

```
ios-app/
  project.yml                   XcodeGen spec → generates SlowClaw.xcodeproj
  README.md                     This file
  .gitignore                    Excludes .xcodeproj, build/, DerivedData/

  SlowClawApp/                  The app target
    SlowClawApp.swift           Minimal SwiftUI demo (open DB → store → recall)
    Info.plist                  iOS app metadata
    Assets.xcassets/            App icon asset catalog (AppIcon.appiconset).
                                The SlowClaw mark; TestFlight's CFBundleIconName
                                check passes against this set.

  SlowClawFeed/                 Swift package wrapping the C ABI
    Package.swift               SwiftPM manifest (for SPM consumers)
    Sources/SlowClawFeed/
      SlowClawFeed.swift        Idiomatic Swift overlay (String, throws, etc.)
      include/
        slowclaw_feed.h         The C ABI contract (mirrors zig-src/src/ffi.zig)
```

## Build (local macOS)

```bash
# 1. Install prerequisites
brew install xcodegen
# Install Zig 0.16.0 from https://ziglang.org/download/ (or use tools/zig/)

# 2. Generate the Xcode project
cd ios-app
xcodegen generate

# 3. Open in Xcode and run on the iOS simulator
open SlowClaw.xcodeproj
```

The Xcode project's pre-build script phase runs `zig build` automatically, so
editing Zig source and re-running in Xcode picks up the changes. The script
detects sim vs device builds and picks the right Zig target:
- `iphonesimulator` → `zig build -Dtarget=aarch64-ios-sim`
- `iphoneos` → `zig build -Dtarget=aarch64-ios`

The app links THREE static archives out of `zig-src/zig-out/lib`:
`libslowclaw_feed.a` (Zig core), `libsqlite3.a` (vendored SQLite), and
`libllama.a` (vendored llama.cpp b10201, CPU backend — powers the On-Device AI
card: model download from Hugging Face into Documents/Models/, activate/load,
then journal synthesis, interest extraction, and post drafting all run
on-device). The app also links Apple's libc++ (`-lc++`) for the llama.cpp
objects — zig doesn't emit its bundled libc++ for iOS targets. Models are
mmap'd (pages stay file-backed) and the context is capped at 1536 tokens to
stay inside the default per-app memory budget — matching the Tauri app,
which shipped GGUF inference without a memory entitlement. (The
`increased-memory-limit` entitlement only survives signing with
Xcode-managed profiles, which this CI pipeline doesn't use.)

## TestFlight (CI)

The `pub-testflight-zig.yml` workflow at `.github/workflows/` builds + signs +
uploads to TestFlight on every push to `main` (when `zig-src/`, `ios-app/`,
or the workflow file change). It uses these repo-wide App Store Connect +
signing secrets:

- `APP_STORE_CONNECT_ISSUER_ID`
- `APP_STORE_CONNECT_KEY_ID`
- `APP_STORE_CONNECT_PRIVATE_KEY`
- `APPLE_DEVELOPMENT_TEAM` (variable or secret)

The cert + provisioning profile are issued fresh per run via App Store Connect
API (and stale CI profiles are cleaned up to avoid hitting Apple's limits).
**Trigger manually** via the Actions UI → "Publish iOS TestFlight (Zig)" →
Run workflow, or push to `main` with changes under `zig-src/`, `ios-app/`,
or the workflow file itself.

## Why no checked-in .xcodeproj

Xcode project files are verbose, machine-generated, and noisy in diffs. The
modern idiom (used by Firefox, Wireguard, many others) is XcodeGen: a single
human-readable `project.yml` that generates the project on demand. This makes
the project definition reviewable and merge-conflict-free.

## Architectural note

This app **dropped the Tauri + Rust + npm pipeline entirely** for iOS. No
Cargo, no node, no web bundling — just Zig → staticlib → Xcode → TestFlight.
The old `pub-testflight-ios.yml` workflow and the entire `src/`, `web/`, and
`crates/` trees from the Rust-era fork were removed during the pivot
consolidation; `pub-testflight-zig.yml` is the only publish path.
