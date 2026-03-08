# SlowClaw

Slow down. Reclaim the internet.

SlowClaw is a local-first journaling, content creation, and social posting app for people who want a quieter workflow around writing, recording, refining, and publishing. It combines private on-device storage, built-in content operations, and AI-assisted editing so you can capture ideas, turn them into usable drafts, and publish intentionally instead of bouncing between disconnected tools.

The product direction is aligned with [slowclaw.social](https://www.slowclaw.social): thoughtful content over algorithmic noise, local control over cloud sprawl, and workflows that are curated instead of chaotic.

## What SlowClaw Is

SlowClaw is built around a simple loop:

- capture journals, notes, audio, and video locally
- transcribe and organize that material into reusable content
- use AI services deliberately for cleanup, rewriting, and summarization
- publish selected output to social platforms, starting with Bluesky

Today, the repo includes:

- a desktop Tauri app
- a standalone mobile-first Tauri app path
- local storage for journals, media, drafts, transcripts, and posting history
- secure credential storage through native OS facilities
- on-device Whisper transcription support for native mobile content
- a built-in operation registry designed for future native tool updates

## Product Direction

SlowClaw is not trying to be an everything-agent.

It is a focused content workspace:

- journaling app
- idea capture system
- transcript workspace
- AI-assisted writing editor
- social media draft manager
- publishing surface

The goal is not endless generation. The goal is better source material, better edits, and more intentional posting.

## Current Feature Set

### Local-first content workspace

- journal entries stored locally
- local media asset tracking for audio and video
- local drafts and post history
- local persistence across restarts
- standalone mobile usage without requiring a paired desktop session for core workflows

### AI-assisted content workflows

- remote AI services can be used for rewrite, cleanup, summarization, and orchestration
- current auth flow supports secure in-app OpenAI device-code login
- AI is intended to operate on explicit content selections, not silently scan or export your entire library

### On-device transcription

- native transcription is implemented through Whisper-compatible ggml models
- this is intended for local audio and video journal material
- the app code supports bundled models, but the repository does not ship model binaries

### Social posting

- Bluesky is the first supported posting target
- credentials and sessions are stored in the OS keychain / secure storage
- edited text and linked content history can be kept inside the app before posting

### Extensible native tool architecture

Built-in operations are the long-term extension model for SlowClaw mobile and desktop-native workflows.

Current direction:

- operations are typed and explicit
- jobs are persisted locally
- unsupported desktop-style shell automation is intentionally not the mobile default
- future native media tools can be added without redesigning the whole app

This makes it easier to ship future updates such as:

- media trim
- silence removal
- transcript cleanup
- clip extraction
- draft templating
- richer social publishing actions

## What SlowClaw Is Not

SlowClaw is not a generic unrestricted automation runtime on mobile.

On iOS in particular, the app is intentionally moving toward:

- built-in native content tools
- resumable local jobs
- secure storage
- explicit posting flows

and away from:

- arbitrary shell execution
- user-authored scripts inside the app
- always-on daemon assumptions
- desktop-only runtime semantics

Desktop retains broader runtime capabilities, but the product itself is now centered on content workflows rather than generic automation.

## Platform Status

### Desktop

The desktop app remains supported through Tauri and is still the easiest place to iterate during development.

Use it for:

- day-to-day development
- UI iteration
- validating native credential and local storage flows
- desktop publishing and content testing

### iOS / mobile

The mobile app path is now oriented around standalone local use:

- local journals and drafts
- native secure storage
- local transcription
- no desktop required for core content access

The iOS packaging and TestFlight handoff flow is documented in [web/src-tauri/IOS_TESTFLIGHT.md](web/src-tauri/IOS_TESTFLIGHT.md).

Important current limitation:

- you must bundle a Whisper ggml model file for transcription to work in packaged mobile builds

## Privacy and Security Model

SlowClaw is meant to be local-first and deliberate by default.

- journals, media, transcripts, drafts, and post history are stored locally
- credentials are stored in the native secure store / keychain where supported
- remote AI should be used only for the content you explicitly choose to send
- Bluesky authentication uses app-password-based secure storage in the app

This does not mean zero trust work is finished. Review the code and deployment choices before treating the app as production-grade for sensitive material.

## Development

### Prerequisites

Required:

- Rust toolchain
- Node.js 18+

For iOS work on macOS:

- Xcode
- CocoaPods
- the required Rust Apple targets

### Install dependencies

```bash
cd web
npm install
```

### Run the web UI in browser

```bash
cd web
npm run dev
```

This is the fastest way to iterate on layout and interaction, especially with mobile device emulation in the browser.

### Run the desktop Tauri app

```bash
cd web
npm run tauri dev
```

### Build the desktop app

```bash
cd web
npm run tauri build
```

### Build the Tauri web bundle

```bash
cd web
npm run build:tauri
```

This bundle is used by the Tauri app path.

## iOS Development and TestFlight

From `web/`:

```bash
npm run tauri:ios:init
npm run tauri:ios:dev
```

For TestFlight handoff, signing, archive, and required bundled transcription assets, see:

- [web/src-tauri/IOS_TESTFLIGHT.md](web/src-tauri/IOS_TESTFLIGHT.md)

## Repository Structure

- `src/` - Rust core runtime, gateway, storage, providers, and shared application logic
- `web/` - React frontend and Tauri app shell
- `web/src-tauri/` - native Tauri commands, iOS/Android scaffolding, packaging resources
- `docs/` - project and runtime documentation

## Current Built-in Content Direction

SlowClaw is being shaped around a native operation registry rather than free-form scripting on mobile.

That means future content features should preferably arrive as built-in operations such as:

- `transcribe_media`
- `trim_media`
- `clean_transcript`
- `rewrite_text`
- `retitle_entry`
- `summarize_entry`
- `post_bluesky`

The current codebase already includes the registry and job model needed to grow this surface gradually.

## Known Gaps

The product direction is ahead of the fully implemented feature set.

Not everything described above is complete yet. In particular:

- on-device transcription support exists, but model files must be supplied separately
- native media editing tools are planned but not yet implemented
- Bluesky is the first posting target; broader platform coverage is future work
- browser-based UI preview is useful for layout work, but only native runs validate the full mobile path

## Vision

The web is full of slop, urgency, and generic output. SlowClaw aims for the opposite:

- slower capture
- better source material
- local ownership
- careful AI assistance
- intentional publishing

If you want a journaling app that grows into a content studio and social posting tool without becoming a noisy “everything agent,” that is the direction of this repository.
