# SlowClaw

Open the app, tap the red button, talk. SlowClaw transcribes on the iPhone, cleans the
transcript up, and files the entry into a **space** (Work, Health, Ideas…) together with the
**to-dos, ideas, questions and notes** it contains. The passages worth keeping grow into a
**living book**, and a **news** tab follows the topics you write about. Everything syncs as text
to [slowclaw.social](https://slowclaw.social), or stays on your Wi-Fi with the local view.

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
| To-dos | Every open to-do from every space in one list. Check things off, or add one and pick its space. |
| Book | A living book grown from your journal, in your own words: chapters by theme, a map of passages (the table of contents) and a reader. See below. |
| Discover | **News** and **Videos** for the chapters of your book: results are scored on the phone against what you wrote and only close ones are shown. News searches are shown in Topics; videos come from public channel feeds you choose. Reading history included. See `docs/discover.md`. |
| Spaces | Your areas of life. Each space has an on-device overview, to-dos (with checkboxes), ideas, questions, notes and its journal entries. "Organize unsorted" files older entries in one go. |
| Settings (gear on Journal) | Sync (with this iPhone's key or email), sign a browser in by QR, the local view, Nostr identity backup, capture options, export. |

Say "Record a journal in SlowClaw" to Siri, or put the **Record journal** shortcut on the Action
Button or Lock Screen, to start recording without tapping through the app. Leaving a recording
takes a confirmation once it is longer than a few seconds.

The website opens on **Today**: your journal streak, this week against last, a calendar of the
last 30 weeks (click a day to see what you wrote and finished), what is next, the to-do waiting
longest, and an older idea or question worth another look. **Ideas**, **Questions** and **Notes**
collect every item from every entry, grouped by space or month. **To-dos → Done** is the log of
what you finished, with a weekly chart (a done to-do's last update counts as when it was done).
The editor uses the full width; select words in an entry to keep them as a to-do, idea, question
or note. Click any item to edit it. Keys: `N` new entry, `/` search, `Ctrl/⌘ + Enter` done.
Journal edits save automatically.

### The living book

Your journals become a book of themes. A small sentence-embedding model bundled in the app
(MiniLM, the same one used to tune this on real journals) splits each entry into topics, keeps the
most substantial passage of each in your own words, drops repeats, groups passages into chapters by
theme and orders each chapter by date. It appears right away; when the phone is idle Apple
Intelligence titles the chapters and tidies each passage (keeping your words). Details in
`docs/book.md`.

Continue any entry with **Continue recording**: the new words are added to the same entry.

### Signing in a browser

- **slowclaw.social:** the page shows a QR code. Scan it in Settings. The phone proves it holds
  its Nostr key, the server issues a session for your account, and the phone encrypts it with
  a key that only exists in the QR code; the relay in between only sees ciphertext.
- **Local view (no cloud):** turn on "View on a computer, without the cloud", open the address
  it shows on a computer on the same Wi-Fi, and scan that page's code. The phone serves the
  website and your data directly; keep SlowClaw open while you use it.

The Nostr key is created on the phone (or carried over from older builds), kept in iCloud
Keychain, and can be backed up as an `nsec` from Settings.

Journals from earlier SlowClaw builds are imported automatically on first launch (read-only;
the old database and recordings are left in place).

## Repository

| Path | Contents |
| --- | --- |
| `ios-app/` | SwiftUI app. `project.yml` is the XcodeGen spec. One package: `libsecp256k1` for Nostr signatures. `Tests/` runs on the simulator in the PR check. |
| `web/` | Static website (`index.html`, `app.js`, `style.css`). No build step. `mode.js` picks cloud or local; the app bundles this folder and serves it for the local view. |
| `supabase/migrations/` | Database history. `20261103094822_simple_journal_sync.sql` and `20261104090000_book_and_nostr_links.sql` define the current tables. |
| `supabase/functions/` | `cloud-login` (Nostr-proof sign-in and key linking) and `cloud-qr` (two-minute relay for sealed browser sessions). |
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

- Tables: `journals`, `spaces`, `space_items`, `book_nodes`, all keyed by `(user_id, id)` with
  owner-only RLS. `cloud_private.nostr_links` maps Nostr keys to accounts (service role only).
- The client URL and publishable key are in `CloudSync.swift` and `web/app.js`; they are public
  by design. Never put a secret/service key in client code.
- The `cloud-api` and `cloud-worker` functions, older `cloud_*` tables and the private audio bucket
  belong to the previous version and are unused. `cloud-login`, `cloud-qr` and the
  `cloud_phone_*` / `cloud_qr` database functions are in use.

## License

MIT or Apache-2.0, at your option.
