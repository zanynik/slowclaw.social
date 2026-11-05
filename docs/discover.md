# Discover (v3)

The book's chapters are the reader's themes; results are kept only if they are close to what was written.

**News.** Each theme gets up to five searches: organisations tagged on the phone, products and acronyms
(DeepMind, GPU), and its most distinctive two-word phrases. Never people (plain capitalised words are
never used) and never places. Results from all searches are pooled, scored with MiniLM as
`0.5 · nearest passage + 0.5 · theme centre`, and kept if `≥ max(0.48, best − 0.12)`, at most four per
theme. On real journals: single-keyword searches surfaced mostly unrelated news (e.g. a train crash for
"recording"); the pooled, scored version kept 23 stories, about 18 clearly on-theme.

**Videos.** Recent uploads from YouTube's public channel feeds (a curated list the reader can change; no
scraping, no key), scored the same way against every theme, shown under the best one if `≥ 0.45`, at most
three per theme. Matching "open questions" in the journals was tried and dropped: in voice transcripts
"I don't know" is mostly filler, so the matches were weak.
