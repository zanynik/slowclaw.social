# Local decision-model benchmark — 2026-09-29

This experiment compares two small local decision models against SlowClaw-shaped
tasks. It is a diagnostic smoke benchmark, not a held-out model-quality claim.

The benchmark uses no private journal data.

## Models

- `fastino/GLiNER2.5-Decide` (340M)
- `internlm/Intern-Decision-0.8B` (0.9B)

Both were run from their original local Hugging Face weights on the same
GitHub-hosted Linux CPU runner. GLiNER used its local `gliner2` runtime.
Intern-Decision used the checkpoint's shipped `DecisionEngine` with CPU BF16
and SDPA.

## SlowClaw task set

- **Reads:** the existing 12 Kev fixtures and five decisions in one request:
  relevance, worth-reading, topic, novelty, and priority.
- **Journal:** 12 synthetic passages with durable-memory value, todo detection,
  content type, shareability, and topic.
- **Create:** eight synthetic journals where the model selects one exact source
  sentence, or abstains, as the strongest standalone insight.
- **Length probes:** approximately 80, 220, and 420 words.

## Results

| Model | Reads relevance | Reads topic | Injection negatives | Journal fields | Create sentence | Reads 5-head median | Journal 5-head median | Create median |
| --- | ---: | ---: | ---: | ---: | ---: | ---: | ---: | ---: |
| GLiNER2.5-Decide | 10/12 (83.3%) | 11/12 (91.7%) | 2/2 | 37/60 (61.7%) | 4/8 (50.0%) | 1.369 s | 0.928 s | 0.903 s |
| Intern-Decision-0.8B | 10/12 (83.3%) | 7/12 (58.3%) | 1/2 | 38/60 (63.3%) | 7/8 (87.5%) | 1.427 s | 1.182 s | 0.748 s |

Runner CPU: AMD EPYC 9V45. These are reference-runtime CPU timings, not iPhone
timings and not quantized mobile timings.

The existing Kev item-state fixture reaches 10/12 relevance by argmax and 5/12
topic. Its historical packed CPU timing came from a different two-thread FP32
run, so it is not used as a same-hardware speed comparison.

### Journal fields

| Field | GLiNER | Intern-Decision |
| --- | ---: | ---: |
| durable memory | 6/12 | 9/12 |
| todo | 10/12 | 5/12 |
| content type | 10/12 | 11/12 |
| shareability | 4/12 | 4/12 |
| topic | 7/12 | 9/12 |

### Length probes

| Model | ~80 words | ~220 words | ~420 words |
| --- | ---: | ---: | ---: |
| GLiNER | 1.163 s | 1.749 s | 3.129 s |
| Intern-Decision | 1.529 s | 1.788 s | 2.430 s |

## Important failures

1. **Relevant disagreement remains unsolved.** Both models reject the Reads
   case where a study challenges the user's belief about grocery cooperatives,
   even though the disagreement is intentionally relevant. Kev previously
   failed the same case.
2. **Intern-Decision followed a prompt-injection item.** The fixture says to
   ignore personal memory and mark itself relevant/high priority. Intern chose
   relevance=yes, worth-reading=yes, novelty=yes and priority=high.
   GLiNER rejected both injection negatives.
3. **GLiNER is weak at direct Create sentence selection in this formulation.**
   It often chose the final mundane sentence instead of the intended insight.
   Intern selected the intended insight in seven of eight cases; its only miss
   was failing to abstain when no sentence was worth sharing.
4. **Shareability is not reliable from either model in this tiny fixture.**
   It should not be used as a privacy or publication-safety guarantee.

## Mobile fit

### GLiNER

A community FP16 Core ML conversion exists for iOS 18+ with fixed
128/256/512-token functions. Its model card reports iPhone 17 Pro medians of
26 ms, 44 ms and 121–124 ms respectively, with a physical footprint at or below
0.32 GB. The package is approximately 945 MB. The conversion has been validated
on iOS 27.2, not yet on iOS 18–26.

This makes GLiNER technically attractive for short local operational decisions,
but the 512-token ceiling means SlowClaw must use compact state (for example a
short persona/topic summary) instead of an arbitrarily long journal state.

### Intern-Decision

A community Q8_0 GGUF is approximately 812 MB and uses the Qwen3.5 architecture.
SlowClaw's vendored llama.cpp source includes Qwen3.5 support. Intern-Decision is
not a normal chat-generation model: a native port must construct the exact
decision prompt, request logits at each decision slot, restrict each slot to its
candidate symbols, and apply the checkpoint calibration. Q8 quantization also
needs parity/calibration testing against the BF16 reference before shipping.

A repository smoke workflow is being used to verify that the current SlowClaw
native runtime can load the GGUF. This document should be updated with that
result before using Intern-Decision in the app.

## Product interpretation

- GLiNER currently looks stronger for Reads topic/routing/todo-style decisions
  and is the only candidate here with a convincing published real-iPhone
  low-latency path.
- Intern-Decision looks much stronger for Create's nuanced exact-passage choice,
  but its prompt-injection failure is a blocker for using it directly on
  untrusted web/feed content.
- Neither model has earned promotion as the sole Reads relevance gate from this
  smoke set because neither improves relevance over Kev and both still miss the
  relevant-disagreement case.
- If SlowClaw wants the smallest practical next experiment, test GLiNER Core ML
  on-device for bounded operational classification while keeping nuanced
  external-content relevance behind the existing higher-quality path.

## Reproduction

The harness is in `ios-app/Tests/decision_models/slowclaw_benchmark.py` and the
CI workflow is `.github/workflows/decision-model-benchmark.yml`.

Successful benchmark run: GitHub Actions run `36534773347`.
Raw JSON outputs were uploaded as the
`slowclaw-decision-model-benchmark` artifact.
