# The book (v3)

Built from the journals with the bundled MiniLM; no language model is needed to build it.

1. Skip journals that repeat another (≥ 50% shared 3-word runs; duplicate imports measure ~0.77).
2. Split each journal into topic segments where neighbouring sentences turn away from each other
   (TextTiling on sentence vectors; cuts at the deepest point of each dip).
3. From each segment keep the 3–5 sentence window closest to its meaning that starts where a thought
   starts; keep the most substantial segments, about one per 1,500 characters (max 10).
4. Drop passages that repeat one in the book (cosine ≥ 0.85 or ≥ 35% shared 4-word runs).
5. Themes: spherical k-means, k ≈ √(n/2); groups of one or two join their closest theme. The loneliest
   5% of passages wait in "Loose ends" until related passages arrive.
6. Chapters: the theme that began earliest first, then the closest remaining theme; inside a chapter,
   date order.
7. When the phone is idle, Apple Intelligence titles the chapters and condenses each passage from its
   segment (kept only if ≥ 60% of its content words are the author's). Until then the cleaned words show.

Measured on 44 real journals (prototype): 186 passages in 10 chapters, neighbour similarity 0.289,
mean chapter cohesion 0.257, versus a 190-passage chapter with average-linkage clustering and versus
0.5's book (6 passages after ~12 minutes of language-model calls).
