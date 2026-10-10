# SlowClaw Web

The standalone browser companion for SlowClaw: encrypted phone pairing, a journal notepad, transcript edits, grouped thoughts, moments, and encrypted file imports. The iPhone keeps the original journals and runs its existing local processing.

Exported from SlowClaw Web version 6, commit `89cdf784f6c37297c97a66747964995e59c96395`. The unpaired opening page adds a short introduction inspired by `zanynik/slowclaw_static` commit `19b86df2cb386b928a1f10afa03380ad14f20ff2`; the existing companion interface is preserved.

## Run and verify

Requires Node 22.13+ and pnpm 11.25.0.

```sh
pnpm install --frozen-lockfile
pnpm typecheck
pnpm test
pnpm build
pnpm dev
```

The current runtime is Vinext/Vite on a Cloudflare Worker, with D1 (`DB`) and private R2 (`BUCKET`) bindings. Local Worker tests provision isolated D1/R2 through Miniflare. Production bindings and their migrations must be provisioned before deploying this export outside Sites; `.openai/hosting.json` records the original managed project, not credentials.

**This source export is not yet a Vercel/Supabase runtime port.** Importing this directory into Vercel alone will not produce a working companion. See [the migration and domain cutover plan](../docs/web-migration.md) for the required backend, file transfer, and iOS changes. The Supabase SQL and environment template are preparation only and are not used by the current runtime.

The original deployed companion remains at https://slowclaw-web.zanynik.chatgpt.site until a replacement passes the acceptance checks.

## Security boundaries

Session keys remain in the QR URL fragment and browser/phone. The server handles encrypted payloads, hashed browser capabilities, pairing proofs, and temporary queues. Supabase Auth must not replace the existing phone signature protocol. Never commit environment secrets, private journals, pairing links, or tokens.

`tests/session.test.mjs` covers signed pairing, replay rejection, encrypted snapshots, journal edit receipts/conflicts, transfers, and cleanup. Journal and unit tests cover encryption and exact source passages. Browser embeddings remain in a Web Worker.
