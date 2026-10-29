# Optional Supabase cloud workspace

The local phone workspace and direct encrypted phone/browser pairing remain available. This optional mode adds private server storage and scheduled cloud processing so experiments can run while the app is closed. Cloud processing requires separate, explicit sync, AI, and daily switches. All start disabled.

This work extends proven capture, journal extraction, and review surfaces with optional server persistence. It preserves local-first use and makes cloud dependencies replaceable. It does not automatically publish anything.

## Implemented

- Email/password accounts; owner-scoped database permissions; private original audio; short-lived playback URLs; immutable uploads verified by SHA-256 and byte count.
- Browser Journals, Spaces, Actions, Reads, Moments, and Settings tabs. Encrypted local drafts/outbox survive offline work. Revision conflicts preserve local text for review, copying, or export.
- Native Profile → Cloud workspace: Keychain sessions, account binding, foreground journal/audio synchronization, source review, and cloud suggestions in Reads/Create. Divergent edits and open editors are protected from automatic replacement.
- Versioned journals and historical source lookup. Summary/action/moment extraction retains exact quotations and source revisions; edits mark derived output stale. Acceptance remains a review action.
- Durable leased jobs, retries, visible error codes, budget reservations, missing-key preflight, and one worker invocation per minute. User processing can run with the app closed.
- Optional transcription of untranscribed recordings; text analysis; embeddings and related journal groups; daily space/booklet proposals; personalized links from five fixed public RSS sources.
- Per-user OpenAI or OpenRouter keys stored in encrypted server Vault. The browser never receives stored provider keys or server credentials. OpenRouter requests require providers supporting no data collection and zero data retention; unavailable routes fail visibly.
- Paginated account export, original audio downloads, and a standalone backup utility. Source deletion removes cloud journal text/history/derived artifacts and queues original audio removal. Public reading links/read status remain; journal-derived reasons are redacted.

## Architecture

GitHub Pages still serves the static browser app. Supabase supplies Auth, Postgres, private Storage, Edge Functions, Vault, Cron, and HTTP scheduling. `cloud-api` authenticates each user; `cloud-worker` accepts either an authenticated user or a server-only scheduler capability. Both perform their own authentication, so gateway JWT verification is disabled intentionally. No unauthenticated execution path is allowed.

All user tables have owner RLS. Write/lease/commit RPCs are service-only. Analysis and transcription commits recheck the lease, current source revision, and processing consent inside the transaction. Jobs whose source changes cannot silently replace newer work.

Server storage is private, but cloud mode is not end-to-end encrypted: server functions need journal text/audio for processing. Selected content goes to the chosen AI provider. Supabase administrators and provider policies remain part of the trust boundary. RSS fetches do not contain private journal text; ranking happens afterward.

## Deployment and connection

A dedicated free pilot backend has been provisioned. The project reference and publishable key are obtained from its Supabase dashboard; credentials and project identifiers are intentionally absent from repository source.

1. In Supabase **Authentication → URL Configuration**, set the Site URL to `https://slowclaw.social` and allow the browser confirmation/recovery redirect paths under that origin. Local testing needs its own explicitly allowed localhost callback. These Auth dashboard settings are not applied by Edge Function deployment.
2. Enable email confirmation and use a strong account password. Review mail delivery/rate limits before inviting testers. The free pilot currently reports the advisory that leaked-password protection is disabled; see [Supabase password security](https://supabase.com/docs/guides/auth/password-security#password-strength-and-leaked-password-protection).
3. Set GitHub repository Actions variables `SLOWCLAW_SUPABASE_URL` and `SLOWCLAW_SUPABASE_PUBLISHABLE_KEY`. Both are public configuration, never service secrets. The Pages workflow validates and writes `cloud-config.json` during deployment. The app also supports manually entering these public values. Never place a service-role/secret key in these fields.
4. Release the web branch through the normal Pages workflow. Open `https://slowclaw.social/?cloud`, create/confirm an account, and sign in. Configure the native app through Profile → Cloud workspace using the same public project values and account. A new native build is required for these features.
5. Enable sync first and verify one disposable journal/audio recording on both clients. Then add a provider API key through Cloud Settings, select OpenAI or OpenRouter, enable AI, and optionally enable daily processing. Provider API billing is separate from consumer ChatGPT subscriptions.
6. Run one journal and daily pass; inspect job statuses and provider billing before importing larger collections. Missing keys visibly block jobs without reserving model spend. Use retry after fixing a key or configuration error.

For another Supabase installation, link the CLI project, apply `supabase/migrations/` in order, deploy both functions with their own authentication enabled, and configure Auth URLs. Set the server-only scheduler runtime URL and Vault capability using the same pattern as the scheduler migration. Do not expose that capability to clients. The deployed migration versions and committed filenames match.

## Pilot limits and costs

The provisioned backend uses the free plan; no paid plan was selected. Actual AI spend depends on usage and the chosen provider. Default application reservations are 20 attempts/day, $1/day, and $10/month. They are conservative admission estimates, not measured invoices or provider-enforced hard caps. Retries and uncertain failures retain reservations. Set a spending cap at the provider too.

- Audio: 50 MB/file, 900 MB/account soft application quota; server transcription up to 25 MB/file. Concurrent uploads can exceed the soft quota; infrastructure plan quotas still apply.
- Analyze up to 60,000 characters per journal. Oversize journals need splitting for full analysis.
- Daily context uses the latest 30 journals; embedding groups use at most 120 units from the same embedding model. A daily job runs at most once per UTC date, with no configurable timezone yet.
- Read discovery currently uses MIT Technology Review, Quanta, Our World in Data, Hacker News, and Aeon feeds. It is bounded feed curation, not unrestricted web research or full article ingestion.
- Browser dashboard shows bounded recent artifacts/jobs/media. Account export is separately paginated.
- Native sync runs in the foreground, with bounded work per cycle. The server continues processing already synced data when the phone app closes; new phone recordings upload when the app is active again. There is no background URLSession upload implementation.
- Excluding a local journal prevents further sync; it does not erase an already uploaded cloud copy. Delete that cloud journal explicitly if removal is intended. Disabling sync/AI also does not delete existing stored content or retract provider requests already in flight.
- No automatic full-device restore, full account deletion UI, video workflow, publishing automation, or rendered video/story generation is included.

## Backup and removal

The browser exports account records as JSON and offers original audio downloads. For a portable records-and-originals backup outside the repository:

```sh
python3 supabase/scripts/backup.py --url https://PROJECT.supabase.co --directory /path/to/private-backup
```

Enter the publishable key, email, and password at the prompts. The tool refreshes the session, paginates every export entity, downloads originals using short-lived URLs, verifies each checksum and byte count, and writes `manifest.json` only when complete. On interruption, `manifest.partial.json` marks incomplete work; verified existing audio is reused on the next run. Provider keys are never exported. Backups contain plaintext private data and must be stored accordingly. Exports are not a transactional snapshot: pause edits during backup if a consistent revision set is required. Restore is manual, not an implemented import workflow.

Deleting a cloud journal clears its private source and derived content and schedules audio deletion independently of AI budgets. Storage deletion happens asynchronously; verify the purge job completes. Existing provider requests, downloads, external backups, and provider retention are outside this deletion path. Signing out or disabling cloud mode does not delete cloud data.

## Validation and release status

- Web TypeScript, backend TypeScript, existing browser tests plus cloud tests, and the static production build pass.
- Rollback-only synthetic database tests cover account isolation, revision receipts/conflicts/history, stale AI completion, scoped deletion, Vault/RPC permissions, and budgets.
- Live disposable-account checks exercised sign-in, configuration, version conflicts, private original upload/checksum verification/playback, paginated export, missing-key behavior, and deletion. Additional live transaction checks covered transcription consent and atomic commit. No real journals or paid model calls were used.
- Swift files passed syntax parsing. This Linux environment cannot compile or run the iOS target; Xcode simulator/device build and a two-device foreground sync check remain release gates. Browser visual interaction was not verified here.
- Real-provider quality, feed availability, and model/route availability need a small paid smoke test after configuring a key. Unsupported provider routes fail visibly.

The backend is deployed; the website/native implementation is on the feature branch pending release. Keep cloud switches disabled until setup and smoke tests are complete. Roll back clients by reverting the feature commits. To stop server AI work, disable the per-account AI/daily switches and, if necessary, unschedule the cloud Cron task. Retain/export private storage before destructive project changes.
