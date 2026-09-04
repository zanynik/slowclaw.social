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

### Model downloads keep running in the background

On-device model downloads run in a **background URLSession**
(`com.slowclaw.app.model-download`, see `ModelDownloadCoordinator` in
`SlowClawFeed.swift`). Background downloading IS possible on iOS via this
mechanism: `nsurlsessiond` owns the transfer, so a multi-GB GGUF download
**keeps running while the app is backgrounded/suspended or the phone is
locked**, pauses automatically on network loss and resumes, and — if the app
was relaunched mid-transfer — reattaches to the in-flight task instead of
restarting (the system relaunch callback is wired through
`ShareURLDelegate.application(_:handleEventsForBackgroundURLSession:)`).
No manual pause/resume bookkeeping is needed. SlowClaw persists the selected
preset while a transfer is active, so after an app relaunch it automatically
reattaches the progress bar to the system-owned task (or safely retries if a
force-quit cancelled it) instead of appearing stuck.

Nothing is installed into `Documents/Models/` until the transfer is proven
good: the delegate rejects any non-2xx HTTP response (error pages never
become — or overwrite — a model), then validates the downloaded body as a
plausible GGUF (magic bytes + a size floor derived from the expected
download size) before it touches the destination. The install is an atomic
swap (`replaceItemAt`) with no pre-delete, so an existing valid model
survives a failed or bogus download. By default transfers also stay off
metered/scarce networks — cellular, expensive links (hotspots), and Low Data
Mode are all disabled, and combined with `waitsForConnectivity` a multi-GB
GGUF waits for non-expensive Wi-Fi instead of failing fast or silently
consuming a data plan.

### Re-transcribing an audio journal

The journal detail view's transcript card has a **Re-transcribe** button
(shown for entries with a linked audio file). It re-runs on-device
transcription of the original audio from scratch and replaces the transcript
body in place, preserving the entry's title. This is the manual retry path
for truncated transcripts across new builds.

Routing goes through the shared on-device STT router (`AudioSTT`). When **Prefer
Gemma 4 Audio** is enabled, the Zig core's mtmd layer runs first in sequential
45-second segments; Apple Speech is fallback-only and the actual route appears
immediately under Profile → Audio Transcription → Recent Runs. With Gemma off,
Apple uses SpeechAnalyzer's `.offlineTranscription` preset over the whole file,
after installing the required locale model through `AssetInventory`; segmented
forced-on-device `SFSpeechRecognizer` is compatibility fallback only. Audio
never leaves the device on any path. If no complete
transcript is produced (empty/failed recognition, no
audio file, or a failed store write), the old transcript is left unchanged
and a "Re-transcription failed" alert is shown — a partial result never
overwrites the stored entry.

New recordings follow the system Voice Memos/Notes pattern: the microphone
buffer is written to the m4a and streamed into SpeechAnalyzer's
`.progressiveLiveTranscription` preset at the same time. Volatile text is
replaced as recognition improves, finals accumulate once, and Stop waits for
the analyzer to flush before the journal is saved. A completed live transcript
is not re-sliced afterward. If the live model is unavailable, the audio is
still saved immediately and the durable pending queue runs whole-file offline
transcription in the background. Imported audio enters that same persisted
queue, so its placeholder is usable/playable while transcription continues.

Audio detail screens expose a visible Delete action. Deletion moves the journal,
audio and transcript to Recently Deleted for 30 days; Empty Trash removes both
the database row and the app-owned audio file.

The Profile model rows distinguish the Q4 text model from its audio add-on.
The add-on reuses the exact same Q4 GGUF and downloads only the separate ~1 GB
mmproj when Q4 is already present; it is not a second text model.

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
