# SlowClaw Web migration and domain cutover

Prepared 10 October 2026. Source is merged into `web/`; hosting and DNS have not changed. The existing Sites companion and static domain remain available. The opening page keeps the companion design and adds a journal-first introduction inspired by the static site.

## Architecture

GitHub Pages serves static files. This companion also needs signed pairing, temporary encrypted snapshots/edit queues, and encrypted file transfers. GitHub stores code; a runtime and database supply those services.

| Component | Current | Proposed |
| --- | --- | --- |
| UI and API | Sites-managed Vinext/Vite Cloudflare Worker | Standard Next.js App Router on Vercel |
| Sessions, proofs, edits, transfer metadata | D1 SQLite | Supabase Postgres, server access only |
| Temporary encrypted files | Private R2 | Private Supabase Storage |
| Pairing identity | Browser capability + phone NIP-98 signatures | Preserve; Supabase Auth is unnecessary |
| Journal originals and keys | iPhone and paired browser | Preserve existing ownership |
| Text embeddings | Browser Web Worker | Keep client-side |

Vercel/Supabase is reasonable but not required simply to leave GitHub Pages. Keeping the Cloudflare architecture or using the existing Sites host with a custom domain entails less backend work. Both paths still need the iOS domain update below.

## 1. Accounts and infrastructure

**Vercel and Supabase are both connected in ChatGPT.** Account inspection found no SlowClaw Supabase project. The existing projects belong to other applications and are inactive; use a dedicated new project rather than repurposing them. The account has one organization, `zanynik's Org`. Plugins are optional; their exposed permissions determine which setup operations can be automated.

Create a Supabase project in a region near the intended Vercel function region (Frankfurt is an option for European users). Create a private `slowclaw-transfers` bucket. Anonymous/browser users must have no general table access, bucket listing, or upload permission.

After the runtime port, connect a Vercel project to `zanynik/slowclaw.social`, root directory `web`. **Importing this export into Vercel alone will not work:** it still requires Cloudflare D1/R2. No SlowClaw project was found in the connected Vercel account during this export. Configure server-only values from `web/.env.migration.example` in Vercel settings. Never commit secrets or expose them through `NEXT_PUBLIC_*`. Use separate staging/production resources.

## 2. Runtime port

`web/migrations/supabase/0001_sessions.sql` is an unapplied starting schema. Review/apply it with an administrator, then provision a least-privilege server role with schema/table/sequence grants and RLS policies. Anonymous/authenticated client access is deliberately absent. Private Storage is provisioned separately.

Replace D1/R2 in `web/lib/session-server.ts` with a Postgres/private Storage adapter. Parameterize queries; replace SQLite placeholders and `rowid` ordering with Postgres parameters and `queue_order`. Preserve Unix-second timestamps, error codes, quotas, receipt status and conflicts. Make replay-proof insertion, quota admission, and queue transitions transactional under concurrent requests. Do not translate D1 batch operations into independent queries.

Use Supabase's transaction pooler for serverless connections, TLS and a small per-function pool. Avoid named prepared statements and session-local settings; check driver-specific pooling/pipelining limitations in the connection guide.

Convert framework scripts/configuration from Vinext/Vite/Cloudflare to standard Next.js. Adapt browser worker/model assets to its bundler and verify the production build. Use a validated server-only `APP_ORIGIN` for canonical phone signature validation; never derive trust from caller-controlled forwarded hosts.

Preserve `/api/session` routes, browser authorization, same-origin checks, pairing/session expiry, timestamp/replay checks, signed body digests, exact revision conflicts, and logout deletion. Never log private payloads, tokens, QR fragments or signed URLs.

### Large files require direct Storage transfers

Vercel Functions have a **4.5 MB request/response limit**. The current API proxies roughly 50 MiB encrypted files and cannot be moved unchanged.

Use small authenticated API calls to reserve an upload and obtain a restricted signed Storage upload URL. Send ciphertext directly from browser to Storage, with resumable uploads for larger files. An authenticated completion endpoint must verify object existence/size and active session before marking it ready. Use unique paths, no overwrites, transaction-safe quotas and idempotent completion.

The phone obtains a restricted download URL through a signed API request, downloads ciphertext directly, decrypts locally, then sends its signed receipt. Do not forward API Authorization headers to the Storage host. Handle abandoned/resumed uploads, signed URL lifetime and concurrent session closure. Expired sessions must never be revived. Scheduled cleanup must delete orphan objects and expired session data; SQL cascading does not remove Storage objects.

Account for encryption overhead: the current limit is 50 MiB plaintext plus 28 bytes. If the plan/bucket cap is exactly 50 MiB, lower the plaintext allowance or raise that cap. Verify current plan limits before choosing a plan.

## 3. iPhone domain support and release

`ios-app/SlowClawApp/WebSessionProtocol.swift` accepts only `https://slowclaw-web.zanynik.chatgpt.site`. `WebCompanion.swift` sends all requests to that fixed origin. DNS changes alone therefore break pairing.

Add an explicit production allowlist for `https://slowclaw.social` and the legacy host. Carry the validated origin in pairing and persisted sessions; sign/send each request to that same origin. Default existing persisted sessions to the legacy origin. Update links and confirmation text. Preserve exact HTTPS/host/path validation and rejection of arbitrary QR domains, credentials, ports and signature-breaking redirects.

Use a specifically pinned staging hostname in development builds. Release the new production domain support through TestFlight before domain cutover. Keep the legacy service available for older app versions and in-flight sessions.

## 4. Acceptance checks

Run typecheck, journal/unit tests and the production build. Port the Worker integration tests to real Postgres/Storage: the existing Miniflare tests do not verify a new adapter.

- New/legacy pairing succeeds; foreign hosts, expired/replayed proofs and altered signed bodies fail.
- Snapshots, journal edits, receipts and conflicts preserve revisions and unsaved typing.
- Grouped thoughts retain exact excerpts; browser embedding workers load correctly.
- Small text and near-limit encrypted audio transfer directly, save on the phone, and delete after receipt.
- Duplicate requests, interrupted uploads, quota concurrency, logout, expiry and orphan cleanup behave correctly.
- Anonymous table/bucket access fails, sensitive responses are not publicly cached, and logs contain no secrets.

Canonical journals do not need migration into Supabase. Finish old transfer/edit queues, save unsaved browser drafts, and end old sessions. Fresh pairing recreates temporary state. Keep the original deployment until the replacement passes checks.

## 5. Domain cutover

Add `slowclaw.social` and optionally `www.slowclaw.social` to the verified Vercel project. Use apex as canonical origin and redirect www for landing navigation. Signed phone API calls must go directly to canonical HTTPS.

Save the current GitHub Pages domain/DNS settings for rollback. Use the exact DNS records supplied by Vercel, replacing conflicting Pages records. Wait for verification/TLS, then test landing, pairing, edits and large file transfers again. Keep `slowclaw_static` as historical source. If acceptance fails, restore saved DNS; retain the legacy companion throughout.

## Primary references

- [GitHub Pages static hosting](https://docs.github.com/en/pages/getting-started-with-github-pages/what-is-github-pages)
- [Vercel frameworks](https://vercel.com/docs/frameworks)
- [Vercel Function limits](https://vercel.com/docs/functions/limitations)
- [Supabase connections/pooling](https://supabase.com/docs/guides/database/connecting-to-postgres)
- [Signed Storage uploads](https://supabase.com/docs/reference/javascript/storage-from-createsigneduploadurl)
- [Storage upload guidance](https://supabase.com/docs/guides/storage/uploads/standard-uploads)
- [Bucket configuration](https://supabase.com/docs/guides/storage/buckets/creating-buckets)
