# The book (v4)

Built from the journals with the bundled MiniLM; no language model is needed to build it.

1. Skip journals that repeat another (≥ 50% shared 3-word runs; duplicate imports measure ~0.77).
2. Split each journal into topic segments where neighbouring sentences turn away from each other
   (TextTiling on sentence vectors; cuts at the deepest point of each dip).
3. From each segment keep the 3–5 sentence window closest to its meaning that starts where a thought
   starts; keep the most substantial segments, about one per 1,500 characters (max 10).
4. Drop passages that repeat one in the book (cosine ≥ 0.85 or ≥ 35% shared 4-word runs).
5. Arrangement (v4): one reading path through every passage, then the best cuts.
   - The path minimises, summed over neighbouring passages, `1 − similarity`, with `0.15` taken off when
     the second passage was said right after the first in the same sitting. So neighbours are as alike as
     possible, and a thought stays next to the one that followed it unless something much closer exists.
   - The path is found by local search (greedy starts, reverse a stretch, move a run of 1–3 passages).
     Its length can be checked against the minimum spanning tree, which no path can beat.
   - Chapters are cuts of the path: about √(n/2) of them, 4 passages or more, never between a thought and
     its spoken continuation. For a given path the cuts are exactly optimal (dynamic programming),
     maximising how alike the passages inside each chapter are.
   - The loneliest 5% of passages wait in "Loose ends" until related passages arrive.
6. Gaps: a join far below the book's usual closeness (`< min(0.25, mean − 1.5 sd)`) that is not a spoken
   continuation is marked "The book jumps here", with a button that starts a recording. The marker is a
   `bridge` row, so the website shows it too. A new entry about the missing piece lands near the gap
   because the path is rebuilt.
7. Passages said in one sitting and kept together read as one stretch: the source is named once.
8. Chapters are named after their most distinctive phrases (the author's own words). When the phone is
   idle, Apple Intelligence condenses each passage from its segment (kept only if ≥ 60% of its content
   words are the author's). Until then the cleaned words show.

## What was measured for v4

On the 186 passages of 44 real journals (`tools/prototype/book_v4.py`):

| arrangement | neighbours alike | weak joins (< 0.2) | chapter cohesion | spoken continuations kept | path ÷ lower bound |
| --- | --- | --- | --- | --- | --- |
| shuffled inside v3's chapters | 0.262 | 34% | 0.257 | 4% | 1.43 |
| v3: themes, date order | 0.289 | 26% | 0.257 | 27% | 1.38 |
| v4: one path, best cuts | 0.419 | 6% | 0.251 | 34% | 1.13 |

Date order inside a theme was barely better than shuffling, and v3's themes sent 63% of thoughts spoken
back to back into different chapters. v4 marks 10 gaps in this book.

The spoken bonus is one dial between two things that pull against each other, because what is said next
is often not what is most alike (spoken pairs average 0.27 similarity; the path's joins average 0.42):

| bonus | neighbours alike | weak joins | spoken continuations kept |
| --- | --- | --- | --- |
| 0 | 0.435 | 3% | 7% |
| 0.15 (used) | 0.419 | 6% | 34% |
| 0.3 | 0.372 | 13% | 64% |
| 0.5 | 0.303 | 26% | 93% |

With known truth (`tools/prototype/reassemble.py`): 8 real essays cut into ~104 passages and shuffled
together, 10 trials. "Chapters right" is the adjusted Rand index against the essays; "neighbours" is the
share of truly consecutive passages that end up side by side.

| model | arrangement | chapters right | neighbours side by side |
| --- | --- | --- | --- |
| MiniLM (bundled, 45 MB) | v3 | 0.61 ± 0.05 | 0.14 ± 0.01 |
| MiniLM | v4 | 0.64 ± 0.05 | 0.24 ± 0.02 |
| EmbeddingGemma 2 (text, 4-bit ONNX, 174 MB) | v3 | 0.74 ± 0.03 | 0.15 ± 0.01 |
| EmbeddingGemma 2 | v4 | 0.75 ± 0.03 | 0.29 ± 0.01 |

The path solver matches brute force on every small case tried and lands within 8% of the lower bound on
200 random points.

What this says about the other ideas:

- **A better embedding model** is the next real gain: EmbeddingGemma 2 gets chapters right more often
  (0.75 vs 0.64) and finds the spoken-next passage more often on the journals (reciprocal rank 0.19 vs
  0.14). It costs ~6× the compute and 174 MB, and needs a runtime the app does not have (a second
  package, or a hand-written Gemma encoder like `MiniLM.swift`). gte-small and bge-small were no better
  than MiniLM. Discover's thresholds would need re-tuning with it (see below).
- **Order from meaning alone has a ceiling**: even the better model puts under a third of true neighbours
  side by side. The order in which things were said is the strongest signal there is, which is why it is
  part of the objective.
- **Building the book on a server** is not needed: the whole arrangement takes about a second in Python
  for this book, and journals would have to leave the phone.
- **Connecting sentences written by a language model** are not in v4: they could not be prototyped
  without the phone's model, and a server model would send journal text out. Gap markers say honestly
  where a connection is missing instead of writing one.

Also measured for v3: EmbeddingGemma-300m (4-bit ONNX, ~200 MB) ranked news about as well as MiniLM overall but
scored unrelated items as high as related ones (0.54–0.71 vs MiniLM's 0.2 for misses), so it filters
worse, and it is ~13× the compute. A "subjects you keep returning to" book (phrase counting, no model)
was fast but covered only 58 passages; filing the rest under subjects by similarity was noisy.

Earlier (v3), on the same journals: spherical k-means themes were chosen over average-linkage clustering
(one 190-passage chapter) and over 0.5's language-model book (6 passages after ~12 minutes).
