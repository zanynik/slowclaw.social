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
4. **Audio stays on the phone.** Only text rows sync.

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
  - Views: `JournalViews.swift`, `RecordView.swift`, `TodosView.swift`, `SpacesViews.swift`,
    `SettingsView.swift`.
- `web/` — static site, plain JS. Set text with `textContent` only (the `h()` helper does this).
- `supabase/migrations/` — never edit an applied migration; add a new one.

## Workflow

- Work on a branch, open a PR. The PR runs an unsigned iOS compile check on macOS.
- Merging to `main` publishes: `ios-app/**` → TestFlight, `web/**` → Pages.
- Keep `CloudSync.swift` row mapping and `web/app.js` in step with the table columns.
- Never commit secrets. The Supabase URL and publishable key are public; service keys are not.
- Use neutral placeholders in examples and tests (`user_a`, `example.com`).
