# Tester feedback: interest overview and Reads batching

## What worked

The personal-interest view felt immediately useful: journal-driven categories updated quickly, and a single-page overview with percentage bars made the analysis easy to understand. Preserve this short feedback loop and compact visual presentation. This is qualitative tester feedback, not a measured latency benchmark; displayed weights are relative interests, not calibrated probabilities.

## Blocking issue

A tester reported repeated crashes when opening Reads after the recent releases. Initial source inspection covered the Reads filter/ranking, card rendering, entity decoding and thumbnail path. No root cause has been confirmed and no crash has been reproduced in the development environment. Obtain the affected build number and a device/TestFlight crash report before claiming a fix. Recent thumbnails use AsyncImage without explicit image downsampling; image-memory pressure is a hypothesis to investigate, not an established diagnosis.

## Proposed experiment, not yet implemented

Keep journal-to-topic scoring and the rolling persona. Serialize topic names alongside weights as shared context and independently judge each incoming article summary or post for relevance. Start with bounded batches (for example 16 or 32 candidates); benchmark before considering 200–250 candidates. Do not make the candidates compete in a single-choice distribution: multiple items or none may be relevant. Use stable IDs, validate all returned decisions and cache against both content and persona revision.

The current app classifies 224 topics in seven requests of 32, not a single 224-topic request. Candidate summaries are longer than topic labels. Fewer requests could reduce overhead, but token limits, provider limits, measured latency and relevance quality determine useful batch size. Existing cached article vectors can be re-ranked locally when the persona changes; direct persona-conditioned judgments require invalidation or re-scoring. Compare both approaches before replacing the current ranking path.
