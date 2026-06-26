# iOS SFSpeechRecognizer integration

This document covers the one-time Mac setup and the ongoing build flow for the
on-device audio transcription feature in the SlowClaw iOS app.

## What this adds

- **Rust:** `web/src-tauri/src/transcription.rs` (rewrite) — replaces the
  long-standing `"On-device audio transcription is coming soon..."` stub with
  a real implementation that delegates to Apple `SFSpeechRecognizer` on iOS.
  Gated on `#[cfg(all(target_os = "ios", feature = "native-inference"))]`, so
  desktop and iOS-without-`native-inference` builds keep returning the clear
  fallback error and the frontend's gateway-transcription path stays
  authoritative on those targets.
- **Swift:** `web/src-tauri/ios/SpeechTranscriber/SpeechTranscriber.swift`
  (new) — `@_cdecl("slowclaw_transcribe_audio")` C-ABI bridge. Uses
  `SFSpeechRecognizer` with `requiresOnDeviceRecognition = true`, so audio
  never leaves the device. Blocks the calling thread via `DispatchSemaphore`
  to match the `tauri::async_runtime::spawn_blocking` pattern in
  `web/src-tauri/src/lib.rs`.
- **Ruby:** `scripts/ios-add-speech-plugin.rb` (new) — idempotent helper that copies the Swift file into `web/src-tauri/gen/apple/SpeechTranscriber/` and adds it to the iOS app target's "Compile Sources" build phase using a `SOURCE_ROOT`-relative reference. Run automatically by CI; optional for local Mac builds.
- **Plist:** the required `NSSpeechRecognitionUsageDescription` is already
  present in `web/src-tauri/Info.ios.plist` — no change needed.
- **Frameworks:** `Speech.framework` and `AVFoundation.framework` are already
  linked under the `native-inference` feature in `web/src-tauri/build.rs` — no
  change to framework linking.
- **Link resolution:** `build.rs` now emits
  `cargo:rustc-link-arg-cdylib=-Wl,-undefined,dynamic_lookup` for iOS under
  `native-inference`. The Swift `@_cdecl("slowclaw_transcribe_audio")` symbol
  is compiled into the iOS app target by Xcode at the FINAL app link, not
  during the Rust build. The Rust crate is built as both a `staticlib` (linked
  into the app by Xcode, where the symbol resolves against the Swift object)
  and a `cdylib` (built by cargo as a side effect, but not shipped for iOS).
  The `staticlib` link uses `ar` and never resolves symbols; the `cdylib` link
  uses `cc` and would otherwise fail on the undefined symbol. The flag lets
  that vestigial iOS cdylib link with the symbol resolved lazily; the shipped
  app resolves it normally from the Swift object at the final Xcode link, so
  the flag never reaches an App Store binary.
- **Frontend:** no change. `invoke("transcribe_audio", { audioPath })` in
  `web/src/lib/tauriApi.ts` is the public API and is unchanged.
- **Capabilities:** no change. `transcribe_audio` is a Rust `#[tauri::command]`
  already registered in `tauri::generate_handler!`, so it is invokable under
  the existing `core:default` capability without additional permissions.

## One-time Mac setup (local builds only)

TestFlight builds do NOT require any manual Mac step: the
`pub-testflight-ios.yml` workflow runs `tauri ios init` then
`ruby scripts/ios-add-speech-plugin.rb` automatically on every build (see
the "CI flow" section below). These steps are only needed if you want to
build the iOS app locally on your own Mac.

1. **Generate the iOS Xcode project** (if `web/src-tauri/gen/apple/` does not
   already exist):

   ```bash
   cd web
   npm run tauri -- ios init --ci --skip-targets-install
   ```

2. **Install the `xcodeproj` Ruby gem** (needed by the integration script):

   ```bash
   sudo gem install xcodeproj --no-document
   ```

3. **Copy the Swift bridge into the project and wire it into the target**:

   ```bash
   ruby scripts/ios-add-speech-plugin.rb
   ```

   The script copies `web/src-tauri/ios/SpeechTranscriber/SpeechTranscriber.swift`
   into `web/src-tauri/gen/apple/SpeechTranscriber/SpeechTranscriber.swift`,
   then adds it to the iOS app target's "Compile Sources" build phase using a
   `SOURCE_ROOT`-relative reference (deterministic; does not depend on the
   project's group path configuration). It is idempotent and refreshes the
   copy on every run, so edits to the canonical Swift source propagate the
   next time you run it.

4. **(Optional) Verify in Xcode** that the file appears under the app target:

   ```bash
   open web/src-tauri/gen/apple/SlowClaw.xcodeproj
   ```

   Confirm `SpeechTranscriber.swift` is listed under the app target's
   "Compile Sources" build phase.

`web/src-tauri/gen/` is gitignored, so none of these generated artifacts are
committed; CI regenerates them on every run.

## CI flow (TestFlight)

The `Publish iOS TestFlight` workflow (`pub-testflight-ios.yml`) already:

1. Runs `tauri ios init` to (re)generate `web/src-tauri/gen/apple/`.
2. Runs `sudo gem install xcodeproj` then `ruby scripts/ios-add-speech-plugin.rb`
   to copy the Swift bridge in and wire it into the app target.
3. Builds the signed IPA with `--features native-inference`.

The workflow's `xcodebuild` wrapper already injects `-framework Speech
-framework AVFoundation` and the Swift runtime linker flags via
`OTHER_LDFLAGS`, so the Swift bridge links cleanly into the final IPA.

## How the bridge works at runtime

```
JS                       Rust core                                  Swift (iOS)
─────────────────────────────────────────────────────────────────────────────
invoke("transcribe_audio",   transcribe_audio_file(audio_path)
  { audioPath })             │
                             │  #[cfg(all(target_os = "ios",
                             │            feature = "native-inference"))]
                             ▼
                             call_ios_transcriber(path)
                             │   CString path
                             │   2 MiB text buffer
                             │   1 KiB error buffer
                             ▼
                             extern "C" slowclaw_transcribe_audio(...)
                                                              │
                                                              ▼
                                                              SFSpeechRecognizer
                                                                (on-device)
                                                              │
                                                              ▼
                                                              UTF-8 transcript
                                                              written to buffer
                             ◀────── returns bytes written (or -1) ────────
                             │
                             ▼
                             TranscriptionResult { text, duration_seconds }
◀──── returns to JS ─────
```

Key properties:

- **On-device only.** `SFSpeechURLRecognitionRequest.requiresOnDeviceRecognition = true`
  is set unconditionally. If the user's locale doesn't have a downloadable
  on-device speech model (Settings → General → Keyboard → Dictation →
  Languages), the function fails with a clear error message instead of
  silently falling back to a server-side path.
- **Synchronous.** The Swift function blocks via `DispatchSemaphore.wait`
  with a 600-second safety timeout. This matches the `spawn_blocking`
  wrapping in `lib.rs`.
- **No audio leaves the device.** The function never makes network calls and
  never serialises audio off-device.
- **Language follows the device.** `Locale.preferredLanguages.first` is used
  as the recognizer locale. Override this if you ever want to pin a specific
  locale.
- **Surface contract matches the existing JS API.** `TranscriptionResult`
  shape is unchanged, so no frontend code needs to change.

## Permissions the user will see

On first transcription attempt iOS shows the standard
"Speech Recognition" permission prompt (driven by
`NSSpeechRecognitionUsageDescription` in `Info.ios.plist`). If the user
denies it, the function returns a clear error: *"Speech recognition
permission was denied. Enable it in Settings."*

A second prerequisite — the dictation language pack — is downloaded via
Settings → General → Keyboard → Dictation → Languages. If the user's chosen
locale lacks an on-device pack, the function returns: *"On-device speech
recognition is not supported for locale \<id\>. Install the dictation
language pack in Settings → General → Keyboard → Dictation."*

## How to verify a local iOS build

After the one-time Mac setup above:

```bash
cd web
npm run tauri -- ios build --ci \
  --features native-inference \
  --export-method app-store-connect
```

Confirm that the build prints `Compiling SpeechTranscriber.swift` (or
equivalent) and that the final IPA is produced.

A faster smoke test is the Xcode-based dev build:

```bash
cd web
npm run tauri -- ios dev --open --host
```

Then record an audio journal entry in the app, tap **Transcribe**, and
confirm the transcript appears without a network round-trip.

## Rollback

This change is fully reversible:

1. `git revert` the merge commit (or the feature branch).
2. No data migration is needed — no new persisted files or schema fields.

The transcription feature returning to its previous "coming soon" state is
safe; the frontend's gateway-transcription fallback already covers desktop
and iOS-without-Swift-bridge.

## Known limitations

- **iOS only.** The Rust stub still returns the fallback error on macOS,
  Windows, Linux, and Android. Cross-platform local ASR is a separate piece
  of work tracked in `docs/project/on-device-asr-embeddings-db-research-2026-06-26.md`.
- **No partial / streaming transcripts.** The function waits for the final
  result. A future iteration could surface partials via a streaming Tauri
  event if the UX calls for it.
- **Single locale per call.** The recognizer is created for the device's
  preferred language on each call. Pinning a locale would be a small
  extension.
- **No on-device call-home or telemetry.** Consistent with the vision
  contract.