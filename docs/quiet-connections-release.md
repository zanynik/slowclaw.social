# Quiet connections release

Proven: build on source-linked personal memory, the existing journal-ranked Reads feed, and signed Nostr publishing.
Better: follow questions over time, keep a stable short daily reading selection, and bring publications and conversations together without another tab.
New: explicitly followed question threads retain source IDs and an editable personal observation. Active, paused and resolved states are user choices, never AI truth judgements.

Question data is stored through the existing Zig-backed SQLite memory API in a separate category; journals and audio formats are unchanged. Connections recheck current source visibility, exclusion and excerpts. Threads with no available source are hidden, including from the daily selection. Related retrieval is bounded by the existing indexed-memory snapshot and cached Reads; no automatic public searches are introduced. A user can retain up to 100 questions and 30 journal links per question. Removing a question preserves its journals.

The daily shortlist retains up to three unread feed IDs with distinct hosts for the current local day. It inherits the existing feed ranking and provenance; it is not a claim that sources provide different viewpoints or verified answers. Dismissal persists for that day. Disliked or removed content is not shown. Paused and resolved questions are omitted. No extra AI generation runs for the shortlist.

Validation: runtime cases exercise thread serialization/lifecycle and daily selection bounds/diversity. The current Linux scratch environment has no Swift/Xcode; macOS runtime tests and full iOS compilation must pass in the existing TestFlight workflow before merge. Physical iPhone recording, navigation, sheet presentation and thermal behavior require device use.

Rollback: revert feature commits. Extra question-category records and local shortlist preferences can be ignored by older builds. Speech and inference engines are unchanged.

## Nostr conversations

Create and Settings both lead to My Nostr posts and replies, with new replies grouped by publication. Successful publish acknowledgements are archived independently of editable drafts. Legacy receipts are admitted only when they match the saved signed event. Read-only refresh discovers up to 50 authored notes/articles per configured relay and queries conversations for the newest 20 publications; opening an older post queries its own thread. These are bounded relay results, never global counts. No outgoing post, reply or reaction is sent automatically.

Incoming events require matching canonical SHA-256 IDs and valid Schnorr signatures. NIP-10 roots/replies are distinguished from mentions; NIP-22 article comments match event IDs or article coordinates; NIP-25 counts use the latest fetched reaction per author and do not count emoji as likes. Replaced article versions are collapsed. Queries use up to five existing configured secure relays, 10-second socket deadlines, 128KB frames, 320 frames per relay and bounded session results. UI reports incomplete relay coverage. Seen reply IDs and hidden authors persist locally; a control restores hidden authors. Identity names/profiles, in-app reply composition, deletion events, zaps, full-history pagination and background notifications are deferred.

Tests cover cryptographic tampering/future-event rejection, reply/mention classification, reaction semantics, article scopes/version collapse and unacknowledged-publish exclusion. Standards reviewed: https://github.com/nostr-protocol/nips/blob/master/10.md, 22.md and 25.md. Existing Speech, inference, ABI and signing workflow credentials are unchanged.
