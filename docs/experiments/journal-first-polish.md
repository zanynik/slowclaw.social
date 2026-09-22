# Journal-first interaction pass

The five surfaces have distinct jobs: Journal is raw life; Profile is what
SlowClaw tentatively understands; Reads is outside material worth attention;
Create is original thought worth offering; Pulse is lightweight connection.
The live interest bars were the successful reference experience: fast feedback,
recognizable topics, and an intelligible single-page view. Keep that quality.

## Proven → Better

- One shared trailing Copy control gives transient, accessible “Copied” feedback
  on journal text, passages, drafts, Pulse notes and weekly reflections.
- Clean text is a deterministic **display projection** of the original. It removes
  narrow English hesitation/false-start patterns, normalizes spaces, adds a final
  period where obvious, and groups already-punctuated sentences. It does not
  invent missing sentence boundaries or paraphrase. Original/edit remains one
  tap away; audio and original stored text are never replaced by cleanup.
- Profile leads with interest bars. Trend arrows compare topic shares from the
  last seven days against the preceding seven. A change over one percentage
  point is rising/falling; no comparable observations means a dash. Relative
  topic share is not model confidence or a personality diagnosis.
- History records articles after 30 active foreground seconds, including time
  across background/resume segments and later visits. Background time is excluded;
  foreground dwell is an estimate, not proof of reading. Local protected metadata
  stores URL/title/source/date/duration, never browser contents. The latest 200
  remain, with a confirmed Clear action. There is no reconstructed old history.
- Drafts are inline editors with immediate local saving. Swipe right keeps;
  swipe left discards into a recoverable archive. Full-swipe discard is disabled.
  Context actions copy, share, or open explicit Nostr short/long-form review.
  Confirmed relay receipts, not the act of tapping Publish, drive Published.
- Short Nostr notes appear only in Pulse; RSS/video and Nostr articles stay in
  Reads. Both reuse the existing journal-driven classifier and transport budgets.
- Journal → menu → Import text files accepts up to 100 UTF-8 files per selection,
  at most 1 MB each, with bounded serial reads, deterministic content keys and
  per-batch success/duplicate/failure counts. Source files are never modified.
  Imported notes enter the same consent-controlled persona/ideas processing as
  written journals. Archive enumeration replaces keyword search so journals in
  other languages and notes without common English words remain visible.

## New, on the existing foundation

The service's additive `/api/ideas` endpoint accepts at most 12 source passages
per request. Independent Jev questions score usefulness to another person and
potential sensitive/identifying detail. App-side decisions are versioned and
cached by exact source passage ID; source edits, deletion and exclusion prevent
stale ideas from being displayed. Score >= 0.7 and privacy score < 0.3 permit a
suggestion. Neither score guarantees privacy or quality. Up to five original
passages appear in Create. Make draft is explicit; the automatic passage-to-draft
loop is removed. Prior drafts remain. No generation model or automatic publishing
is added. The existing key storage, consent, session authorization, device lease,
provider error handling and old service endpoints are unchanged.

## Web/QR import: proposed, not enabled

A web companion is feasible with [NIP-46](https://github.com/nostr-protocol/nips/blob/master/46.md)
remote signing and [NIP-17](https://github.com/nostr-protocol/nips/blob/master/17.md)
encrypted messages (NIP-44/59 encryption/wrapping). Pair an ephemeral browser
session by QR, confirm it on the phone, and restrict its permissions to importing
notes to that same identity. Never export nsec to the browser or use public posts
as journal transport. Require expiry/revocation, replay protection, sender checks,
bounded file batches, deduplication and a private import-review inbox before
journal ingestion. Relay delivery is not guaranteed; the UI must show receipts
and retry state. iOS foreground signing constraints must be tested. The current
service does not implement this pairing/DM bridge and has not acquired journal
storage. Multi-file Files/iCloud import is the available first step.

## Validation, risk and rollback

New regression tests cover conservative cleanup/source preservation, trend
windows and missing baselines, inbox state/receipt rules, UTF-8 import bounds,
sharing-score rejection and reading-duration labels. Existing SQLite/FFI tests
cover the archive cursor used by the journal list. The service's seven tests and
TypeScript check passed; its production bundle was built and published as v5.
A live synthetic two-passage request validated the new response shape; its
temporary tester session was revoked. This is not real-journal quality validation.
This Linux environment has no Swift/iOS SDK: app type checking and the new Swift
tests run in the existing TestFlight workflow. Physical iOS 18/newer UI, clipboard,
keyboard, swipe, background dwell timing, file-provider import and real-journal
sharing quality still require on-device acceptance. No signing, build settings,
C ABI, or main-branch changes are part of this pass.

Local `zig build test-sqlite test-ffi` could not execute: the available Zig
binary exited 139 before producing test output. This is not a passing test result;
the existing macOS CI suite is required before release.

Rollback: revert the app UX commit; original journals, audio, drafts, persona
vectors and old service endpoints remain compatible. New history/inbox/idea caches
are independent additions. The API endpoint can remain without affecting old apps.
