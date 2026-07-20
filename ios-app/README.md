# `ios-app/` — SlowClaw Social iOS app (Zig-backed)

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

## TestFlight (CI)

The `pub-testflight-zig.yml` workflow at `.github/workflows/` builds + signs +
uploads to TestFlight on every push to `zig-ios-pivot`. It reuses the same
App Store Connect + signing secrets as the legacy Tauri workflow:

- `APP_STORE_CONNECT_ISSUER_ID`
- `APP_STORE_CONNECT_KEY_ID`
- `APP_STORE_CONNECT_PRIVATE_KEY`
- `APPLE_DEVELOPMENT_TEAM` (variable or secret)

The cert + provisioning profile are issued fresh per run via App Store Connect
API (and stale CI profiles are cleaned up to avoid hitting Apple's limits).
**Trigger manually** via the Actions UI → "Publish iOS TestFlight (Zig)" →
Run workflow, or push to `zig-ios-pivot` with changes under `zig-src/`,
`ios-app/`, or the workflow file itself.

## Why no checked-in .xcodeproj

Xcode project files are verbose, machine-generated, and noisy in diffs. The
modern idiom (used by Firefox, Wireguard, many others) is XcodeGen: a single
human-readable `project.yml` that generates the project on demand. This makes
the project definition reviewable and merge-conflict-free.

## Architectural note (slice 8)

Per the pivot's "question the old architecture" guidance, the Zig TestFlight
path **drops the Tauri + Rust + npm pipeline entirely** for iOS. No Cargo, no
node, no web bundling — just Zig → staticlib → Xcode → TestFlight. The legacy
workflow `pub-testflight-ios.yml` still exists for the `main` branch; this new
workflow is for `zig-ios-pivot` only. When the pivot merges, the legacy one
gets deleted.
