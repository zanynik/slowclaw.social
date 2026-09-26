# Create and Reads regressions after build 167

This is a **Better** change to the existing journal → curation → reviewed
publishing flow, with direct media publishing completing the requested Create
workflow. Work remains on `feat/kev-reads-judge`.

## Findings and fixes

- `rememberArticle` called `rebuildInterestLens`, incrementing the shared memory
  revision and deleting every article's relevance decision after a 30-second
  visit. Reading feedback does not modify either classifier's journal input.
  Preserve its decisions; hide completed visits by URL in Reads only. Clearing
  history restores them; dislikes remain per-item. Pulse stays independent.
- `refreshCreateIdeas` rejected the action whenever background memory/source/
  relevance work was busy. Reserve Create priority, let in-flight work release
  its server lease and yield at its next checkpoint, then run the requested
  scan. Reconnect missing device sessions through the existing tester path.
- Do not put retranscription of an old recording ahead of every quote. Existing
  native timings still produce audio/video candidates; recordings without
  timings can prepare captions in Edit.
- Evaluate exact sentences and adjacent sentence pairs, retaining original
  whitespace. The new candidate version invalidates old window decisions.
  Scan up to 96 pending candidates, stopping once six cards are available;
  preserve accepted/rejected decisions between pulls. Keep privacy and quality
  gates, source-fingerprint validation and exact native audio boundaries.
- Each card now has Publish. Render locally, review the actual exported image
  or clip, upload only that export to the selected Blossom server, and publish
  its HTTPS URL with the selected words through the existing Nostr signer and
  relay-acknowledgement path. Nothing uploads on generation or opening review.
  Scoped expiring BUD-11 authorization, matching BUD-02 receipts and no upload
  redirects protect the upload path. Failure remains visible and retryable.

## JEV documentation review

Canonical references checked: https://docs.typesafe.ai/api,
https://docs.typesafe.ai/patterns/fan-out,
https://docs.typesafe.ai/models, and
https://docs.typesafe.ai/primitives/advanced.

Question IDs are routing labels, not model instructions. Independent decisions
can share state in one call, within 64k combined tokens and 32k for state plus
its longest question. The current service already asks six explicit questions
for each of up to twelve passages together (72 decisions), including separate
privacy and standalone gates. Reads similarly batches up to 32 items against
fifteen weighted interests. Preserve those efficient contracts; the app-side
scheduling and candidate preparation were the concrete failures. No service or
stored API key changes were needed. Seven service contract tests passed locally.

## Verification and limits

The reading regression harness extracts the actual AppState admission/history
methods and tests a two-minute read, duplicate URL, short visit, dislike, like
and clearing history. Candidate tests verify exact isolated sentences become
cards and overlapping/private candidates remain excluded. Media tests verify
Schnorr authorization scope and reject mismatching upload receipts. The real
studio and publish-review sheet run in the iOS simulator host; CI also runs
existing media exports, Swift tests, Zig/FFI, native model checks and device
archive/upload. Linux local validation covers shell syntax, generated test
project/source, service contract tests and diff integrity; Swift/iOS execution
requires the macOS release workflow.

Live provider quality on the user's journals and a real public Nostr media post
are left to device testing. No user content was published during verification.
Media server policy/availability can reject an upload and is reported in-app.

Rollback: revert the app commit. No FFI, signing, journal schema or hosted service
changes. Existing local journals and recordings are untouched.
