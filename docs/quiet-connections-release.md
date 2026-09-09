# Quiet connections release

Proven: build on source-linked personal memory, the existing journal-ranked Reads feed, and signed Nostr publishing.
Better: follow questions over time, keep a stable short daily reading selection, and bring publications and conversations together without another tab.
New: explicitly followed question threads retain source IDs and an editable personal observation. Active, paused and resolved states are user choices, never AI truth judgements.

Question data is stored through the existing Zig-backed SQLite memory API in a separate category; journals and audio formats are unchanged. Connections recheck current source visibility, exclusion and excerpts. Threads with no available source are hidden, including from the daily selection. Related retrieval is bounded by the existing indexed-memory snapshot and cached Reads; no automatic public searches are introduced. A user can retain up to 100 questions and 30 journal links per question. Removing a question preserves its journals.

The daily shortlist retains up to three unread feed IDs with distinct hosts for the current local day. It inherits the existing feed ranking and provenance; it is not a claim that sources provide different viewpoints or verified answers. Dismissal persists for that day. Disliked or removed content is not shown. Paused and resolved questions are omitted. No extra AI generation runs for the shortlist.

Validation: runtime cases exercise thread serialization/lifecycle and daily selection bounds/diversity. The current Linux scratch environment has no Swift/Xcode; macOS runtime tests and full iOS compilation must pass in the existing TestFlight workflow before merge. Physical iPhone recording, navigation, sheet presentation and thermal behavior require device use.

Rollback: revert feature commits. Extra question-category records and local shortlist preferences can be ignored by older builds. Speech and inference engines are unchanged.
