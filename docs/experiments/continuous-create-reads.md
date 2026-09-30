# Continuous Create and retained Reads

A **Better** change to the journal → curation → reviewed creation loop.

Create scans belong to AppState rather than SwiftUI's refresh gesture. Concurrent
pulls join one task; releasing a gesture or leaving the tab does not cancel it.
Recording, backgrounding, privacy opt-out and thermal/power pauses still yield at
existing checkpoints. Each pull seeks six **new** accepted moments within the
existing 96-candidate budget. The former three-per-journal and 24-total display
caps are removed. The durable feed keeps previously selected moments ahead of
new ones, excludes overlapping windows and remains bounded by the existing
600-candidate cache. Opening an empty Create starts a scan; reaching its footer
reveals more saved cards or requests another page. The same footer can be tapped
when a sparse scan needs another page. Completed decisions survive interruptions.

Reads restores cached Jev decisions for the exact content and current weighted
profile before waiting for network or scheduling slots. Every transport refresh,
including a forced pull, merges candidates and reserves space for up to 40
approved unread reads. Unchanged content retains its prior object/ID even when
RSS batch indices shift. Edited content and recycled IDs need a fresh decision;
URLs and IDs are deduplicated and the candidate cache stays bounded at 120.
AppState owns network refreshes; simultaneous calls join instead of cancelling.
The existing foreground scheduler retries deferred ranking with cached candidates,
so another pull is not required after memory or Create finishes.

This preserves exact-input admission, exclusions, dislikes, read history, and
journal-driven relevance. A genuinely cold feed with no successful decisions,
changed journal profile, disabled processing, or all approved items already read
can still show an honest empty state. No invented or unranked articles are added.

Regression tests exercise the actual extracted AppState wrappers, cache hydration
and merge methods; they cover cancellation, overlapping refreshes, content changes,
cache/profile identity and retention at the candidate bound. Candidate tests cover
additional pages beyond 24 cards and preservation of existing selection order.
Local checks: extraction, shell syntax and diff integrity. Swift execution,
synthetic simulator checks, Zig/FFI and device archive/upload run in release CI;
this Linux workspace does not have Xcode or Swift. Live journal/model quality
still requires device testing. No FFI, journal schema, signing or service changes.

Rollback: revert the feed fix commit. The optional selection order is backward
compatible; existing candidate decisions and journals remain readable.
