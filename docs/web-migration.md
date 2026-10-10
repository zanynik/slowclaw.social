# SlowClaw Web: journals live with you

This plan replaces the earlier Vercel/Supabase migration. Neither service is needed for this architecture. No projects or databases were created in those accounts.

> Your journals live with you. The website is simply another window into them.

## Where things live

| Component | Home | Content retained |
| --- | --- | --- |
| Website/editor/model worker | GitHub Pages, `slowclaw.social` | Public static code/assets |
| Drafts, transcripts, Idea Paths, meaningful units and import queue | IndexedDB in the browser | Encrypted temporary working copies, until explicitly cleared |
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

## Idea Paths

After pairing, open **Your thoughts → Build idea paths**. The browser locally embeds five-line passages from the three latest journals with EmbeddingGemma 2, groups related excerpts and orders them using the Idea Path prototype. Exact excerpts and vectors are encrypted in browser working storage; cards do not change phone journals. Existing phone thought groups remain visible. See [model, processing bounds and verification](idea-paths.md). The public sample uses invented journals only.

## Operational limits

Keep SlowClaw open on the phone to sync. Allow its Local Network permission when pairing on Wi-Fi; if access was denied, enable it in iPhone Settings before retrying. The permission is used for direct encrypted laptop sync, not journal upload to the cloud. iOS can suspend background apps, and a browser may throttle a background tab. Offline edits wait locally; neither the Worker nor an inactive phone acts as an always-on mailbox.

IndexedDB is working storage, not a backup. Browsers, private browsing, clearing site data and storage pressure may remove it. Export unsynced drafts before clearing the workspace. Local storage remains until browser logout/explicit deletion; a 24-hour pairing expiry never silently deletes unsynced text. Moving between domains creates separate browser storage: export old browser drafts before moving to slowclaw.social.

One browser tab owns a workspace at a time to prevent local lost updates. Reconnect currently requires disconnecting the old phone session and scanning a fresh QR code. Stored drafts/receipts keep their operation identities so retries do not duplicate saved entries. Phone disconnect keeps browser drafts; browser logout explicitly clears them after confirmation.

Direct connectivity can fail through restrictive NAT/firewalls. The default STUN discovery is sufficient on some networks, not all. For reliable cellular/corporate-network use, configure TURN. TURN relays encrypted traffic; it does not decrypt journals. Worker and TURN usage may incur charges, even though there is no cloud journal database.

## Deploy the Cloudflare signaling Worker

The initial Worker was deployed through the connected Cloudflare plugin on 10 October 2026 at **https://slowclaw-signaling.zanynik.workers.dev**. It uses the `PairingRooms` Durable Object binding, migration `v1`, and disables observability/logpush. No deployment token was created or stored in the repository. The GitHub workflow below is an optional way to deploy future updates; the connected plugin can also update the Worker directly.

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

Deployment health can be checked with `node web/tests/signaling-live.mjs https://slowclaw-signaling.zanynik.workers.dev`. This opt-in check uses synthetic offer/answer payloads and deletes its temporary pairing room.

The Worker permits browser origin `https://slowclaw.social`; configure explicit local/test origins only for separate development Workers. Do not add a wildcard production origin.

## Release and deploy the existing Pages site

The actual Pages owner is **`zanynik/slowclaw.social`**, which already has the custom domain `slowclaw.social` and HTTPS enabled. `zanynik/slowclaw_static` preserves the original landing page as a backup; its separate project Pages URL does not own the domain.

1. Install compatible TestFlight **build 201** after Apple processing. Its simulator/runtime/model/device build, archive, export and upload completed successfully: [release run](https://github.com/zanynik/slowclaw.social/actions/runs/38087593444).
2. The **Deploy SlowClaw Web to Pages** workflow in this repository builds and checks `web/`, tests the live signaling API, and publishes `dist-static` into the existing Pages project. It runs on companion changes to main or can be run manually. No DNS or custom-domain reassignment is needed.
3. The default signaling origin is `https://slowclaw-signaling.zanynik.workers.dev`. An optional repository variable `SLOWCLAW_SIGNALING_ORIGIN` on **this repository** overrides that public endpoint. No deployment credential belongs in it.
4. On your laptop open slowclaw.social. On the updated iPhone open **Profile → SlowClaw Web**, disconnect an older session if needed, scan the QR code and approve it. Keep the app open and allow Local Network access for same-Wi-Fi pairing.
5. Test a new journal, transcript conflict, Idea Paths, meaningful units, reload recovery, disconnect/reconnect, draft export, phone text export and a near-limit import. Verify the phone receipt and ciphertext deletion after importing. Test cellular/different-network pairing and forced TURN if configured. These checks need a real iPhone and are not implied by CI success.

Rollback: manually run **Deploy SlowClaw Web to Pages** with **legacy_landing** checked. It checks out the backup landing repository and deploys that content to the same domain. Export unsynced browser text before switching. This does not delete phone journals. A normal run restores the companion. The legacy Sites companion remains available for older builds and pending sessions.

## Validation and remaining live checks

The deployed Cloudflare Worker passed the opt-in live signaling check on 10 October 2026: forbidden origin, unauthenticated access, role separation, immutable offer/answer, no journal endpoint, and deletion.

Automated checks cover the static build, existing encryption/conflict/unit tests, IndexedDB recovery, peer RPC replay/identity isolation, immutable receipts, chunked files, and real Worker/Durable Object origin/capability/size checks. iOS parser/crypto tests run in the existing release workflow; native framework linking is verified by its archive step.

The deployed Pages site was checked in Chrome: QR creation and **New pairing code** retries worked; local sample inference and cached refresh produced Idea Path cards. The browser now proceeds with gathered ICE candidates after bounded discovery, instead of rejecting usable candidates when STUN discovery stalls. These checks used synthetic data and did not expose private journals.

Live phone/browser connectivity, Safari storage behavior and actual TURN relay credentials still require a compatible phone build and real-device checks. TURN is not configured. Passing CI and browser-only checks is not a claim that the real phone-to-browser test has happened.

## Primary references

- [WebRTC data channels](https://webrtc.org/getting-started/data-channels)
- [WebRTC TURN connectivity](https://webrtc.org/getting-started/turn-server)
- [Browser storage quotas and eviction](https://developer.mozilla.org/en-US/docs/Web/API/Storage_API/Storage_quotas_and_eviction_criteria)
- [iOS background execution](https://developer.apple.com/documentation/uikit/extending-your-app-s-background-execution-time)
- [Pinned native WebRTC package](https://github.com/stasel/WebRTC/tree/154.0.0)
- [Cloudflare Durable Object lifecycle](https://developers.cloudflare.com/durable-objects/concepts/durable-object-lifecycle/)
