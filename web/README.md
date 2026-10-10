# SlowClaw Web

> Your journals live with you. The website is simply another window into them.

A static browser companion: a journal notepad, transcript edits, grouped thoughts, moments, Pulse and encrypted imports. GitHub Pages hosts the code. IndexedDB keeps temporary encrypted working copies. WebRTC syncs directly with the iPhone, which remains authoritative. A minimal Cloudflare Worker exchanges encrypted connection setup messages without storing journals.

## Run

Node 22.13+ and pnpm 11.25.0:

```sh
pnpm install --frozen-lockfile
pnpm typecheck
pnpm test
pnpm build
pnpm dev
```

The static output is `dist-static/`. Set `public/peer-config.json` to the deployed Worker origin for pairing; its empty default deliberately prevents pairing before infrastructure is configured. The production phone only accepts the real slowclaw.social origin. Local browser tests can use the local queue/Worker integration tests; real development phone pairing needs an explicitly reviewed development origin.

See [deployment, privacy, recovery and rollout](../docs/web-migration.md). Vercel and Supabase are not used. The old D1/R2 server source remains for legacy regression tests and compatibility reference, and is excluded from the static bundle. `pnpm build:legacy` builds that reference runtime; do not mistake it for the new static architecture.

## Recovery

Keep the phone app open to sync. **Saved on phone** follows its durable receipt. Offline drafts wait in IndexedDB and can be exported. Phone disconnect keeps them; browser logout explicitly removes the workspace. Browser data eviction or clearing can lose unsynced drafts, so export before clearing. Local key wrapping does not protect against an unlocked or compromised browser profile.

Source originally exported from SlowClaw Web version 6, commit `89cdf784f6c37297c97a66747964995e59c96395`. The opening page is lightly inspired by `slowclaw_static` commit `19b86df2cb386b928a1f10afa03380ad14f20ff2`. The original companion remains available during rollout at https://slowclaw-web.zanynik.chatgpt.site.
