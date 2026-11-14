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

**Reads.** Long essays published on Nostr (NIP-23, kind 30023) by a list of writers the reader can
change, fetched from three public relays and scored like videos: shown under the best chapter if
`≥ 0.45`, at most three per chapter, from the last 180 days. Every event's id and signature are checked
on the phone; the relays see only the list of writers' public keys. Essays open in an in-app reader
(headings, paragraphs, quotes, lists, code; images and HTML are left out).

What was tried (`tools/prototype/reads_v3.py`):

- *The open firehose* (all recent kind 30023 from two relays): of 574 posts in a few hours, most were
  adult-content and SEO spam, machine-written news and non-English filler. Relevance scoring alone does
  not make that safe to show, so it was dropped.
- *Writers trusted by the network* (followed by at least two of seven long-standing accounts): 1,035
  writers, 263 essays in 150 days. Scored against a real book's themes, 8 cleared `0.45` and 15 cleared
  `0.40`; the ones kept were clearly on-theme. The 25 default writers are the ones from this set who publish real essays.
- A feed of short notes (kind 1) was not built: it is a timeline to scroll, not something that follows
  from what was written, and it would need follows the reader does not have.

Reads is slow by design: a handful of essays, refreshed at most twice a day.
