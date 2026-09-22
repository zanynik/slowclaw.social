# Needle 3 local Pulse feasibility — 2026-09-22

Decision: **do not replace the existing Pulse ranker with this release yet**.
No app, backend, signing, workflow, or persona behavior changed. This is a
reproducible feasibility checkpoint, not a shipped integration.

Proven → Better: keep Jev's learned weighted interests as authority, but test
whether inexpensive local embeddings can replace cloud short-post relevance.
The proposed policy embeds each interest label, sums normalized embeddings
with its Jev weight, normalizes that centroid, and ranks post embeddings by
cosine similarity. Reads would remain unchanged. The vectors do not share
Jev's 224-dimensional topic space; both labels and posts must use Needle.

## Artifact and reproduction

Official sources: [model](https://huggingface.co/Cactus-Compute/needle3),
[Python/C API client](https://github.com/cactus-compute/needle),
[porting guide](https://cactuscompute.com/blog/porting-needle).
Needle exposes one global, non-thread-safe context. The public API returns
3072-dimensional embeddings for the tested release. This does not establish
that those embeddings were trained for semantic retrieval.

Pinned Hugging Face revision: `b274efcb211a9eef48c9a88da4b43bd569696a39`.
Download under `/Cactus-Compute/needle3/resolve/<revision>/`:

- `needle3.cact` (35,335,380 bytes), SHA256
  `c9d915eca282ed42d1a09b143b592adb4cc6744ffe2d294adf5cfc5548170c38`.
- `python/cactus_needle-3.0.1-py3-none-manylinux2014_x86_64.whl`, SHA256
  `05770ef9a85686583968ea15f62f9ad44217e078efdaa99559d3208bb8a369b0`.

Run on Linux x86_64 (Python standard library only):

```sh
python docs/experiments/needle-pulse-probe.py /path/to/needle3.cact /path/to/runtime.whl
```

The probe verifies hashes before loading executable code, retains model bytes,
serializes native calls, rejects invalid vectors, and prints full scores and
rankings. It reuses the 12 **synthetic** snippets in jev-batch-benchmark.json;
no private journals, credentials, or real Nostr events are used. All 12
snippets are relevant for a small first-screen ranking check, not proof of
performance over an unbounded relay stream.

## Observations

Two executions gave identical cosine scores. Warm snippet embeddings took
roughly 22–131 ms in this shared Linux environment; this is **not iPhone
performance**, excludes model loading, and is not a controlled speed study.

Technical profile: Local AI 40%, AI agents 30%, Data engineering 20%,
Data quality 10%. First seven results:

1. Keyword bait (a watch advert stuffed with AI keywords), cosine 0.940764
2. Specific technical correction, 0.933004
3. Meditation practice, 0.931733
4. Local AI on a phone, 0.930637
5. Agent evaluation, 0.929785
6. Incidental mention (celebrity fashion), 0.928925
7. Reliable data pipelines, 0.928311

Only two of the four first results were genuinely technical (precision@4
0.5 on this deliberately small fixture). Using a natural-language profile
instead of weighted topic vectors moved the watch advert to second, but
still produced precision@4 0.5 and placed data pipelines seventh.

Food and football profiles correctly placed their obvious best match first,
so the vectors contain some useful signal. However, the food cooperative
ranked sixth for the food profile, behind several unrelated items. Similarity
values were uniformly high; the existing Jev 0.55 gate cannot be reused.
These failures are sufficient to withhold a default replacement, not evidence
that every Needle configuration is unsuitable.

## Next gate / rollback

Keep current Pulse behavior. Do not add a dormant native dependency, download
UI, new threshold, or TestFlight build solely for this unsuccessful experiment.
Before adopting a revised embedding head or representation, extend the frozen
test set with held-out synthetic short posts, multilingual text, topic changes,
and keyword bait; compare ranking to existing Jev results. Then validate
bounded queues, caching, recording/thermal pauses, memory use and latency on
iOS 18 and newer devices. The current fetcher is bounded relay polling, not
an unbounded firehose. No continuous-stream throughput was tested here.
Rollback for this checkpoint is simply reverting these two experiment files.
