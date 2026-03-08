# iOS TestFlight Handoff

This repo now includes a generated Tauri iOS project at:

- `web/src-tauri/gen/apple/slowclaw_mobile.xcodeproj`

## What Is Ready

- Standalone native mobile storage for journals, media, drafts, and post history.
- Embedded gateway startup for native runtimes.
- Secure OpenAI device-code login in-app.
- Bluesky credentials stored through OS keychain.
- Built-in operation registry with persisted content jobs.
- On-device Whisper transcription backend for native journal audio/video.

## What Must Be Added Before Archive

Place a Whisper ggml model file in:

- `web/src-tauri/resources/models/`

Recommended starter model:

- `ggml-base.en.bin`

The app will also look in `workspace/models/` during local development, but TestFlight builds should bundle the model in app resources.

## One-Time Machine Setup

On the Mac used for archive/upload:

1. Install Xcode and open it once.
2. Install CocoaPods and XcodeGen if they are missing.
3. From `web/`, run:

```bash
npm install
npm run build:tauri
npm run tauri -- ios init
```

## Local Device / Simulator Check

From `web/`:

```bash
npm run tauri -- ios dev
```

If you prefer Xcode:

1. Open `web/src-tauri/gen/apple/slowclaw_mobile.xcodeproj`.
2. Select the `slowclaw_mobile_iOS` target.
3. Set the signing team under `Signing & Capabilities`.
4. Run on an iPhone or simulator.

## Signing For TestFlight

In Xcode:

1. Open the generated project.
2. Set the Apple Developer team on the app target.
3. Confirm the bundle identifier is the one you want to ship.
4. Ensure the bundled Whisper model is present in app resources.
5. Archive using `Product` -> `Archive`.
6. Upload through Organizer to TestFlight.

## Recommended Smoke Test Before Upload

1. Launch the app with no desktop running.
2. Create a text journal entry.
3. Record or import audio/video.
4. Run transcription and confirm it completes locally.
5. Restart the app and confirm journals/transcripts still load.
6. Sign in to Bluesky with app password and confirm credentials survive restart.

## Current Known Limits

- Native media editing tools like trim/cleanup are not included yet.
- Mobile recording uses browser capture fallback unless a native recorder plugin is added later.
- Whisper transcription requires a bundled ggml model file; the repo ships the loader path, not the model binary.
- The built-in operation registry is ready for future native tools, but only `transcribe_media` is implemented today.
