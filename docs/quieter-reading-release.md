# A quieter reading and writing surface

Proven: keep A little for today, source-linked recommendations, reviewed publishing and Apple Speech.
Better: admit articles to the default Reads surface only with a strong semantic journal match (cosine >= 0.65) or two distinct whole-topic matches from the same included journal. Reading history and freshness may still rank candidates but cannot admit unrelated catalog discoveries. This is a conservative heuristic, not a calibrated probability or a guarantee of personal relevance. No additional model calls or network requests are introduced.

Both the daily card and the list use this gate, including cached items. Deleted/excluded journal records and disliked articles are excluded. An empty selection is allowed. The original catalog cache remains available for existing question/evidence exploration. A daily selection can refill if all its former choices no longer qualify; dismissal is respected.

Create keeps editing and review/publish visible, moves copy/export/delete/regenerate to a labelled menu, and collapses long draft previews. Settings groups writing tools, reading preferences and storage information, with remote provider and custom instructions separately collapsed. Nostr posts remain accessible from Create. No tabs, dependencies, database migrations, transcription changes or new generation passes.

Validation: added runtime cases for unrelated headlines, weak similarity, same-journal topic matches, cross-journal coincidences, duplicate topics and substring false matches. Swift/Xcode are unavailable in the local Linux environment; the existing macOS workflow must pass runtime tests, Zig tests, iOS compile, archive/export/upload and signing cleanup before merge. Device layout, VoiceOver and personal relevance still need physical iPhone acceptance.

Rollback: revert this release; cached articles and journal data are preserved.
