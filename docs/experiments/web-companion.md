# Phone-paired companion (2026-09-27)

User-requested exception to the iOS-only surface: a temporary browser companion at
https://slowclaw-web.zanynik.chatgpt.site. The separate Sites source repository owns
the web implementation. iOS remains the canonical journal store and all transcription
remains on device. No C ABI or signing infrastructure changes.

## Proven → Better → New

- Proven: existing SQLite journal upserts, durable transcription queue, Nostr Keychain
  identity, Needle + BM25 ranking and selected Create passages.
- Better: popular discovery tapers gradually as **following** grows, from 28 of 40
  candidate slots at zero follows (36 if no network candidates) to 12 at 100 follows.
  Personal-network target grows from 8 to 24. Four slots allow wider discovery.
  Followers are not a relevance signal. Missing provider pools backfill without
  duplicate events or more than two notes per author. These are candidate quotas;
  subsequent local relevance ranking can change the visible proportions.
- New: phone-approved temporary access to recent journal text, moment/story excerpts
  and current Pulse; laptop text/audio imports. No arbitrary remote signing, publishing, original-audio export or video playback.
  The text notepad extends this flow with new journals, existing-entry edits and
  on-demand older transcript reads; the phone is still the canonical store.

## Session contract

The browser creates a random capability, a one-use pairing challenge (five minutes),
and a 256-bit AES key. Only hashes of the capability and challenge reach D1. The AES
key crosses to the phone in the QR fragment, never in an HTTP request or server log.
The QR parser pins HTTPS origin and path and rejects duplicate/unknown fields.
The phone shows explicit consent and signs NIP-98 kind 27235 HTTP authorization:
exact URL, method, body SHA-256, timestamp ±60 seconds and unique nonce. The server
verifies Schnorr, matches the paired pubkey and rejects replayed event IDs.
This is scoped HTTP authorization, not a NIP-46 remote signing service.

AES-GCM envelopes are nonce(12) + ciphertext + tag(16), authenticated with session ID
and purpose (snapshot, transfer metadata or file ID). The server cannot decrypt.
The browser keeps session credentials only in sessionStorage, plaintext only in
memory; the phone uses ThisDeviceOnly Keychain. Sessions last at most 24 hours.
API expiry is enforced on every request. Logout marks the session closed, deletes
R2 bytes and database records, and clears local credentials after confirmation.
Expired storage is swept in bounded batches on API activity, **not by a guaranteed
wall-clock background deletion job**. No claim of timed physical erasure is made.

Recent sharing is limited to seven days, at most 200 journals and a bounded text
budget, 100 selected moments and 40 current Pulse notes. Excluded entries stay out.
Large weeks may be partial. Audio originals never leave the phone in this flow.

Uploads: UTF-8 .txt/.md up to 1 MB; supported audio up to 50 MiB per file; 250 MiB
unreceived at a time, 500 transfer records per session. Browser originals are never
deleted. Phone imports on foreground/open and every 15 seconds while active; iOS
background delivery is not promised. Text uses the existing content fingerprint;
audio uses SHA-256 bytes, making retries and duplicate file selection idempotent.
Audio must decode before acknowledgment. SQLite row, audio copy and persisted
transcription intent must exist before the phone acknowledges. R2 bytes are then
deleted; a small encrypted transfer receipt remains until logout/expiry cleanup.

Logout explicitly warns about pending uploads; those copies are deleted even if
the phone has not received them. The user must keep originals or wait for “Saved
on phone”. Received files remain on the phone after logout. Import dates use the
phone's existing journal import behavior, not the laptop filesystem modification date.

## Verification and rollback

Swift tests cover origin/fragment validation, encryption context/tamper rejection,
NIP-98 request binding and a WebCrypto/CryptoKit interoperability fixture. Existing
social tests cover gradual thresholds and preserved provider fallbacks. Web tests
exercise real Worker/D1/R2 pairing, replay, ownership, upload receipt and deletion.
The existing TestFlight workflow remains the only release gate. No user content or
real Nostr publication is used in tests. Real camera scanning and laptop-to-phone
transfer still require an installed-device check.

Rollback: remove the Profile link and foreground sync task; revoke live sessions
before removing the companion. Existing imported journals are normal local records
and must never be deleted as part of rollback.

Protocol reference: https://github.com/nostr-protocol/nips/blob/master/98.md

## Browser notepad (2026-10)

The Journals tab has a white text editor, optional title, New entry button and
searchable history index. Recent text is sent with the snapshot; older text and
transcripts are requested individually. Audio originals are never requested.
Notes are capped at 1 MB; the snapshot/history index retains the existing bounded
payload budget for unusually large archives. Excluded and deleted entries cannot
be opened or edited. QR consent explicitly grants reading and editing journals.

Each AES-GCM operation is bound to session/note/operation ID; receipts use a
separate /result context. Browser drafts and exact pending operations are encrypted
in sessionStorage for reload recovery. A stable browser journal key makes new
entry retries idempotent. Only the paired phone can acknowledge an operation,
after the canonical SQLite write succeeds. Transcript writes preserve category,
session, source and media URL. No new C ABI or audio transfer path is introduced.

Autosave queues the latest draft about once per second, with one unacknowledged
operation per note. The phone polls while foregrounded every 15 seconds. The UI
distinguishes unsaved changes, waiting for phone and saved on phone. Editing can
continue during an in-flight save; a receipt advances the revision without
overwriting newer browser text. Writes compare the exact full-content SHA-256
revision synchronously with the upsert. Concurrent phone changes return the phone
version and keep browser text; the user can use the phone version or save browser
text as a new entry. Missing/excluded entries are rejected without resurrection.

Sessions still expire after 24 hours. Logout removes encrypted drafts and pending
operations and warns that unsynced edits will be lost. Closing a page with pending
changes prompts the browser's unsaved-work warning. Browser tests cover receipt
reconciliation and encrypted reload recovery; Worker/D1 tests cover ownership,
idempotent queueing, immutable receipts and deletion. Swift tests cover revision
conflicts, retry behavior, missing/excluded entry protection and payload validation.

Vision alignment: proven SQLite journal persistence plus the encrypted companion;
a simpler laptop capture surface that feeds the same journal-driven understanding
and curation. Rollback the notepad component and phone edit receiver together;
existing saved journals remain ordinary local records.
