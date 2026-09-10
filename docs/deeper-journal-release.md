# Deeper journal loop

Proven: preserve Apple Speech, the single-pass drafting path, source-linked memories, and verified Nostr publication.
Better: traverse the journal archive with keyset pages instead of a 60-result relevance query. Search compact indexed passages from all years before rechecking only selected original sources.

Archive reads use a separate actor-confined SQLite connection through an additive C ABI. Each page contains at most 20 records; drafts and app metadata are excluded in SQL. The row cursor checkpoints after a completed page and survives relaunch. Completed scans repeat after a day; recent visible journals remain immediate candidates. Fingerprints skip unchanged successes; failed extractions are suppressed for the current process and can retry on a later scan after relaunch. Cancellation does not commit a partial page. Recording, foreground state, battery and thermal conditions retain priority between requests. Older journals do not generate a flood of historical drafts.

The archive index stores small source-backed observations, not whole transcripts in model context. Searching older indexed passages does not mean every passage has been indexed already. AI extraction may reject a journal; original audio/text is never changed by indexing.

Validation: added C ABI coverage traversing 65 records across multiple pages while excluding drafts and question metadata. Swift/Xcode/Zig are unavailable in the local Linux scratch environment; run existing macOS CI, C ABI tests, iOS compile/archive and TestFlight upload before merge. Physical phone performance, recording and lock behavior remain device acceptance checks.

Rollback: revert release commits. The additive page API has no schema migration; existing memory formats remain readable. Extra archive cursor preferences can be ignored by older builds.

## Reviewed replies

The publication detail supports replying to a post or a specific incoming reply. Draft text survives closing the sheet; only an explicit Publish reply sends it to the configured relays. The existing publication path keeps signed retries idempotent and requires a relay acknowledgement. NIP-10 roots/parents and NIP-22 article scopes are built from verified source events; unrelated parents are rejected. There are no automatic replies, journal attachments or AI-written outgoing messages. Public profile metadata, avatars and discovery expansion are deferred.

## Source-grounded suggestions

Once in seven days, when two recent indexed passages from distinct days are available and optional work is allowed, the app can prepare a tentative reflection using the existing single-request grounded-reflection path. Exact citations are validated; interpretations are not treated as facts. It is saved locally, can be dismissed or turned into a followed question, and hides if its original sources change or become unavailable. This is explicitly a connection between two passages, not a comprehensive weekly assessment. Personal memory includes an off switch. Failed attempts are rate-limited to one per hour in the current process.

Automatic short-post extraction can include a small related active-question hint, never its proposed answer, while still requiring original-current-source quotations. New automatic drafts expose their supporting journal passage and warn when the source changes. Existing daily frequency and small backlog limits remain. Article generation is still one pass over original source passages; it is not changed into an automatic long-form pipeline in this release.

Runtime tests cover reply envelopes, preservation of existing thread roots, article scopes, unrelated-parent rejection, weekly-reflection serialization and draft source matching. The final workflow also runs the existing real MiniCPM5 smoke. CI cannot measure the usefulness of personal reflections or guarantee drafting quality.
