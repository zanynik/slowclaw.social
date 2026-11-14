# AGENTS.md — working on SlowClaw

SlowClaw is a daily journaling app: record → on-device transcription → on-device cleanup →
organized into spaces with to-dos, ideas, questions and notes → text synced to a small website.
Read `README.md` first.

## Product rules

1. **Capture first.** Opening the app and recording must stay one tap. Never block saving on
   AI, network or sign-in; save first, process after.
2. **Keep it small.** Prefer removing features to adding settings. A new screen needs a clear
   daily use.
3. **On-device AI only.** Use Apple Foundation Models (`OnDeviceAI.swift`) with a rule-based
   fallback. Do not add server-side model calls or API keys.
4. **Audio stays on the phone.** Only text rows sync. Book vectors stay on the phone too.
5. **Journal text never leaves for third parties.** News sends only topic words; Videos and Reads
   send nothing about the user (public feeds, and a list of writers' public keys). Anything sent
   to a service other than the user's own Supabase rows must be shown to the user first.
   Nothing is published to Nostr.
6. **One package.** `libsecp256k1` (pinned) is the only dependency; prefer Apple frameworks
   (relays are read with `URLSessionWebSocketTask`). The
   bundled MiniLM (`Model/`, Apache-2.0) runs on Accelerate, not a package.
7. **Prototype on real data first.** Book and Discover changes are tried with `tools/prototype` on the
   owner's journals (never committed) and ported only when the output reads better.

## Code map

- `ios-app/SlowClawApp/` (folders are groups only; XcodeGen picks up every file)
  - `App/` — `SlowClawApp.swift` (entry, tabs), `Models.swift`, `Store.swift` (the JSON store in
    Application Support), `SettingsView.swift`, `Shortcuts.swift` ("Record a journal" App Intent),
    `LegacyImport.swift` (one-time read-only import from the old `slowclaw.sqlite`).
  - `Capture/` — `RecordView.swift`, `Processor.swift` (transcribe → clean → organize),
    `OnDeviceAI.swift` (Foundation Models prompts and fallbacks), and the proven capture code:
    `AudioRecorder.swift`, `SpeechTranscriber.swift`, `TimedTranscript.swift`,
    `RecordingSilence.swift` — change with care.
  - `Journal/` — `JournalViews.swift`, `TodosView.swift`, `SpacesViews.swift`.
  - `Book/` — `MiniLM.swift` (sentence embeddings, same model as the prototype),
    `BookOrganizer.swift` (pure rules: segments, passages, repeats, themes, order, keyphrases),
    `BookEngine.swift` (vectors, words), `Book.swift` (store, layout, background polish, sync
    rows), `BookViews.swift`. See `docs/book.md`.
  - `Discover/` — `Discover.swift` (theme searches, relevance), `News.swift` (Google News RSS,
    reading history), `Videos.swift` (channel feeds), `Reads.swift` (Nostr long-form essays from
    chosen writers, Markdown blocks) and their views. See `docs/discover.md`.
  - `Sync/` — `CloudSync.swift` (Supabase auth + PostgREST pull/push, dirty flags, server cursor),
    `LocalServer.swift` (Wi-Fi web server + JSON API for the local view), `QRScanner.swift`
    (browser codes), `Nostr.swift` (Keychain key, BIP-340 signing, NIP-19/NIP-98),
    `NostrRelay.swift` (read-only relay client, event verification, `naddr` links).
- `ios-app/Tests/` — unit tests; the PR check runs them on the simulator.
- `web/` — static site, plain JS. Set text with `textContent` only (the `h()` helper does this).
  Cloud and local mode share `app.js`; keep `LocalServer.swift`'s `/api/data` rows in the same
  shape as the Supabase tables, and `tools/web-dev/server.mjs` (sample data) in the same shape as
  `LocalServer.swift`.
- `supabase/functions/` — redeploy after editing (`cloud-login`, `cloud-qr`).
- `supabase/migrations/` — never edit an applied migration; add a new one.

## Workflow

- A nightly agent turns the owner's journal ideas into small changes: see `docs/nightly-agent.md`.
  It pushes `nightly/*` branches; `nightly-release.yml` promotes them to `main` only after the
  build and unit tests pass.

- Work on a branch, open a PR. The PR runs an unsigned iOS compile check and the unit tests on
  macOS, and for website changes a browser smoke test (`node tools/web-dev/smoke.mjs`; run it
  locally too, against `node tools/web-dev/server.mjs`).
- Merging to `main` publishes: `ios-app/**` → TestFlight, `web/**` → Pages.
- Keep `CloudSync.swift` row mapping and `web/app.js` in step with the table columns.
- Never commit secrets. The Supabase URL and publishable key are public; service keys are not.
- Use neutral placeholders in examples and tests (`user_a`, `example.com`).
