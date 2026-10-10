# SlowClaw Web: journals live with you

This plan replaces the earlier Vercel/Supabase migration. Neither service is needed for this architecture. No projects or databases were created in those accounts.

> Your journals live with you. The website is simply another window into them.

## Where things live

| Component | Home | Content retained |
| --- | --- | --- |
| Website/editor/model worker | GitHub Pages, `slowclaw.social` | Public static code/assets |
| Drafts, transcripts, meaningful units and import queue | IndexedDB in the browser | Encrypted temporary working copies, until explicitly cleared |
| Phone sync | WebRTC ordered data channel | Encrypted peer requests/responses; no cloud journal queue |
| QR signaling | Cloudflare Worker + in-memory Durable Object | Encrypted SDP, capability hashes and a five-minute room; no D1/R2/KV journal store |
| Canonical journals and media | iPhone | Authoritative originals and revisions |
| Network fallback | Optional TURN relay | Encrypted packets relayed in transit, without a journal database |

The browser must receive a durable phone receipt before saying **Saved on phone**. It keeps unsynced drafts when the phone is offline or disconnected. Old revisions still produce a conflict instead of silently overwriting phone edits. Existing excluded/deleted-entry checks and content-derived import keys are preserved.

## Implemented source

- `web/vite.pages.config.ts` builds a static client into `dist-static`; no API routes are shipped to Pages.
- `web/lib/local-store.ts` saves encrypted local drafts/queues. A non-extractable browser wrapping key protects the locally stored pairing key. This protects file contents at rest, not against a compromised/unlocked browser profile or same-origin malicious JavaScript.
- `peer-mailbox.ts` preserves the existing encrypted edit/receipt protocol as a serialized local queue. Phone requests remain NIP-98 signed and bound to exact URL, method and body. A reconnect must use the same phone identity or the old workspace must first be exported/cleared.
- `peer-connection.ts` authenticates SDP with the QR key and encrypts sequence-bound data-channel RPCs. Large messages are fragmented into bounded frames; imports are downloaded by the phone in 32 KiB ranges. Signaling never receives these RPCs or files.
- `web/signaling/worker.ts` has only pairing room/offer/answer endpoints, with origin checks, separate random role capabilities, immutable SDP, rate/size limits, and no content logging. Rooms expire after five minutes and are removed after successful pairing. Restart/eviction may end a pending room; show a new QR code. There is deliberately no persistent recovery of SDP.
- `WebPeerTransport.swift` provides native WebRTC data channels using pinned WebRTC 154.0.0. No camera/microphone streams or background audio entitlement are added. QR version 2 is accepted only from `https://slowclaw.social/`, with HTTPS signaling restricted to public `*.workers.dev` endpoints. The Worker is not trusted with journal plaintext or the QR key.
- `WebCompanion.swift` reuses the phone's revision checks, SQLite writes, import deduplication, unit validation and receipt handling. The legacy Sites HTTP pairing remains compatible during rollout.
- Browser draft export and phone journal-text export provide explicit local recovery files. Phone text export does not include audio/video originals or app settings; a device backup remains necessary for a complete backup.

## Operational limits

Keep SlowClaw open on the phone to sync. iOS can suspend background apps, and a browser may throttle a background tab. Offline edits wait locally; neither the Worker nor an inactive phone acts as an always-on mailbox.

IndexedDB is working storage, not a backup. Browsers, private browsing, clearing site data and storage pressure may remove it. Export unsynced drafts before clearing the workspace. Local storage remains until browser logout/explicit deletion; a 24-hour pairing expiry never silently deletes unsynced text. Moving between domains creates separate browser storage: export old browser drafts before moving to slowclaw.social.

One browser tab owns a workspace at a time to prevent local lost updates. Reconnect currently requires disconnecting the old phone session and scanning a fresh QR code. Stored drafts/receipts keep their operation identities so retries do not duplicate saved entries. Phone disconnect keeps browser drafts; browser logout explicitly clears them after confirmation.

Direct connectivity can fail through restrictive NAT/firewalls. The default STUN discovery is sufficient on some networks, not all. For reliable cellular/corporate-network use, configure TURN. TURN relays encrypted traffic; it does not decrypt journals. Worker and TURN usage may incur charges, even though there is no cloud journal database.

## Deploy the Cloudflare signaling Worker

No Cloudflare deployment credential was available in this workspace and no matching ChatGPT plugin was found. The implementation can be deployed without a plugin.

1. In Cloudflare, enable Workers for the intended account. Create an API token using the Workers deployment template, restricted to that account. Keep it outside source control.
2. In `zanynik/slowclaw.social` → Settings → Secrets and variables → Actions, add secrets `CLOUDFLARE_API_TOKEN` and `CLOUDFLARE_ACCOUNT_ID`.
3. Run the **Deploy peer signaling** GitHub Actions workflow manually. It tests the protocol and deploys `web/signaling/wrangler.jsonc`, then writes the resulting `https://slowclaw-signaling.<account>.workers.dev` URL to the run summary.
4. Optional: provision a coturn-compatible relay. Set Worker variable `TURN_URL` (for example a `turns:` URL) and secret `TURN_SECRET`. The Worker creates ten-minute HMAC credentials; the clients receive credentials, never the shared secret. Match the relay's REST shared-secret configuration and test forced-relay connections. Do not commit static TURN credentials into the website.

Local alternative:

```sh
cd web
pnpm install --frozen-lockfile
pnpm exec wrangler login
pnpm signal:deploy
```

The Worker permits browser origin `https://slowclaw.social`; configure explicit local/test origins only for separate development Workers. Do not add a wildcard production origin.

## Release and switch the existing Pages site

The public site must remain usable while the infrastructure is being configured.

1. Complete the iPhone CI archive/upload and install the compatible TestFlight build. Existing builds support only the legacy companion.
2. Set repository variable `SLOWCLAW_SIGNALING_ORIGIN` on **`zanynik/slowclaw_static`** to the deployed Worker origin. The updated Pages workflow builds `web/` from `zanynik/slowclaw.social` main and writes this public endpoint into `peer-config.json`.
3. Run the static repository's existing **Deploy static content to Pages** workflow. With the variable absent it still deploys the original landing page. With it present it runs web tests/build and deploys the static companion into the same Pages project. The existing custom domain/DNS can stay in place.
4. Pair an iPhone/browser on slowclaw.social. Test a new journal, transcript conflict, meaningful units, reload recovery, disconnect/reconnect, draft export, phone text export and a near-limit import. Verify the phone receipt and ciphertext deletion after importing. Test cellular/different-network pairing and forced TURN if configured.
5. Only after those checks should the new companion be treated as production-ready. Keep the legacy Sites host available for older builds and pending sessions.

Rollback: remove `SLOWCLAW_SIGNALING_ORIGIN` and rerun the same Pages workflow to restore the static landing page. This does not delete journals on the iPhone. Export unsynced browser text first. The legacy companion remains available throughout.

## Validation and remaining live checks

Automated checks cover the static build, existing encryption/conflict/unit tests, IndexedDB recovery, peer RPC replay/identity isolation, immutable receipts, chunked files, and real Worker/Durable Object origin/capability/size checks. iOS parser/crypto tests run in the existing release workflow; native framework linking is verified by its archive step.

Live phone/browser connectivity, Safari storage behavior, actual relay credentials and production signaling require the deployed Worker and a compatible phone build. Passing local tests is not a claim that this final end-to-end check has happened.

## Primary references

- [WebRTC data channels](https://webrtc.org/getting-started/data-channels)
- [WebRTC TURN connectivity](https://webrtc.org/getting-started/turn-server)
- [Browser storage quotas and eviction](https://developer.mozilla.org/en-US/docs/Web/API/Storage_API/Storage_quotas_and_eviction_criteria)
- [iOS background execution](https://developer.apple.com/documentation/uikit/extending-your-app-s-background-execution-time)
- [Pinned native WebRTC package](https://github.com/stasel/WebRTC/tree/154.0.0)
- [Cloudflare Durable Object lifecycle](https://developers.cloudflare.com/durable-objects/concepts/durable-object-lifecycle/)
