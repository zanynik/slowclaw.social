# Deeper journal loop

Proven: preserve Apple Speech, the single-pass drafting path, source-linked memories, and verified Nostr publication.
Better: traverse the journal archive with keyset pages instead of a 60-result relevance query. Search compact indexed passages from all years before rechecking only selected original sources.

Archive reads use a separate actor-confined SQLite connection through an additive C ABI. Each page contains at most 20 records; drafts and app metadata are excluded in SQL. The row cursor checkpoints after a completed page and survives relaunch. Completed scans repeat after a day; recent visible journals remain immediate candidates. Fingerprints skip unchanged successes; failed extractions are suppressed for the current process and retry after relaunch. Cancellation does not commit a partial page. Recording, foreground state, battery and thermal conditions retain priority between requests. Older journals do not generate a flood of historical drafts.

The archive index stores small source-backed observations, not whole transcripts in model context. Searching older indexed passages does not mean every passage has been indexed already. AI extraction may reject a journal; original audio/text is never changed by indexing.

Validation: added C ABI coverage traversing 65 records across multiple pages while excluding drafts and question metadata. Swift/Xcode/Zig are unavailable in the local Linux scratch environment; run existing macOS CI, C ABI tests, iOS compile/archive and TestFlight upload before merge. Physical phone performance, recording and lock behavior remain device acceptance checks.

Rollback: revert release commits. The additive page API has no schema migration; existing memory formats remain readable. Extra archive cursor preferences can be ignored by older builds.
