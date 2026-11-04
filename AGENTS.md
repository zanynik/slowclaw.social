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
5. **Journal text never leaves for third parties.** News sends only topic words. Anything sent
   to a service other than the user's own Supabase rows must be shown to the user first.
6. **One package.** `libsecp256k1` (pinned) is the only dependency; prefer Apple frameworks.

## Code map

- `ios-app/SlowClawApp/`
  - `SlowClawApp.swift` — app entry and tabs.
  - `Models.swift`, `Store.swift` — data model and the JSON store (Application Support).
  - `Processor.swift` — transcribe → clean → organize pipeline.
  - `OnDeviceAI.swift` — Foundation Models prompts and fallbacks.
  - `CloudSync.swift` — Supabase auth + PostgREST pull/push (dirty flags, server cursor).
  - `LegacyImport.swift` — one-time read-only import from the old `slowclaw.sqlite`.
  - `AudioRecorder.swift`, `SpeechTranscriber.swift`, `TimedTranscript.swift`,
    `RecordingSilence.swift` — proven capture/transcription code; change with care.
  - `Shortcuts.swift` — "Record a journal" App Intent (Siri, Action Button, Shortcuts).
  - `BookEngine.swift` (pure rules: gate, insertion, chapters, PCA map), `Book.swift` (store,
    embeddings, passages, sync rows), `BookViews.swift`.
  - `News.swift` (topics, RSS, clustering, summaries), `NewsViews.swift`.
  - `Nostr.swift` (Keychain key, BIP-340 signing, NIP-19/NIP-98), `QRScanner.swift`
    (browser codes), `LocalServer.swift` (Wi-Fi web server + JSON API for the local view).
  - Views: `JournalViews.swift`, `RecordView.swift`, `TodosView.swift`, `SpacesViews.swift`,
    `SettingsView.swift`.
- `ios-app/Tests/` — unit tests; the PR check runs them on the simulator.
- `web/` — static site, plain JS. Set text with `textContent` only (the `h()` helper does this).
  Cloud and local mode share `app.js`; keep `LocalServer.swift`'s `/api/data` rows in the same
  shape as the Supabase tables.
- `supabase/functions/` — redeploy after editing (`cloud-login`, `cloud-qr`).
- `supabase/migrations/` — never edit an applied migration; add a new one.

## Workflow

- Work on a branch, open a PR. The PR runs an unsigned iOS compile check on macOS.
- Merging to `main` publishes: `ios-app/**` → TestFlight, `web/**` → Pages.
- Keep `CloudSync.swift` row mapping and `web/app.js` in step with the table columns.
- Never commit secrets. The Supabase URL and publishable key are public; service keys are not.
- Use neutral placeholders in examples and tests (`user_a`, `example.com`).
