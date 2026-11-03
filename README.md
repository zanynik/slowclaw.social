# SlowClaw

Open the app, tap the red button, talk. SlowClaw transcribes on the iPhone, cleans the
transcript up, and files the entry into a **space** (Work, Health, Ideas…) together with the
**to-dos, ideas, questions and notes** it contains. Everything syncs as text to
[slowclaw.social](https://slowclaw.social), where you can read and tend the same lists.

## How it fits together

```
iPhone app (ios-app/)                         Supabase (supabase/)            Website (web/)
──────────────────────                        ────────────────────            ──────────────
record ─► Apple Speech (on device)            journals                        sign in
        ─► Apple Intelligence cleanup ──text──► spaces        ◄──── text ────► spaces + lists
        ─► Apple Intelligence organizer        space_items                     read / edit
audio stays on the phone                      owner-only RLS                  static files on Pages
```

- **No server-side AI.** Cleanup, organizing and space overviews use Apple's on-device
  Foundation Models (iOS 26, Apple Intelligence). Without it the app falls back to simple
  rules and still works.
- **Audio is never uploaded.** Only journal text, spaces and items sync, which keeps the
  Supabase project comfortably on the free tier.
- **Last edit wins.** Each row carries `updated_at`; the database ignores older writes.

## The app

| Tab | What it does |
| --- | --- |
| Journal | All entries by day, search, big record button, write button. Tap an entry to edit it, move it to another space, replay its audio or see the original transcript. |
| Spaces | Your areas of life. Each space has an on-device overview, to-dos (with checkboxes), ideas, questions, notes and its journal entries. "Organize unsorted" files older entries in one go. |
| Settings | Email sign-in for sync, "open straight into recording", automatic organizing, export. |

Journals from earlier SlowClaw builds are imported automatically on first launch (read-only;
the old database and recordings are left in place).

## Repository

| Path | Contents |
| --- | --- |
| `ios-app/` | SwiftUI app. `project.yml` is the XcodeGen spec. No third-party packages. |
| `web/` | Static website (`index.html`, `app.js`, `style.css`). No build step. |
| `supabase/migrations/` | Database history. `20261103094822_simple_journal_sync.sql` defines the current tables. |
| `.github/workflows/` | `pub-testflight.yml` (PR compile check; TestFlight upload on `main`), `pages.yml` (website deploy). |

## Building

```sh
brew install xcodegen
cd ios-app && xcodegen generate && open SlowClaw.xcodeproj
```

Run the website locally with any static server, e.g. `cd web && python3 -m http.server`.

## Releasing

- **iPhone:** merge to `main` with changes under `ios-app/` → the TestFlight workflow signs and
  uploads (needs the App Store Connect secrets and `APPLE_DEVELOPMENT_TEAM`). It can also be run
  manually from the Actions tab.
- **Website:** merge to `main` with changes under `web/` → Pages deploys `web/` as-is.
- **Database:** add a new file in `supabase/migrations/` and apply it to the project.

## Supabase notes

- Tables: `journals`, `spaces`, `space_items`, all keyed by `(user_id, id)` with owner-only RLS.
- The client URL and publishable key are in `CloudSync.swift` and `web/app.js`; they are public
  by design. Never put a secret/service key in client code.
- Older `cloud_*` tables, Edge Functions and the private audio bucket belong to the previous
  version. They are no longer used and can be removed once you no longer need that data.

## License

MIT or Apache-2.0, at your option.
