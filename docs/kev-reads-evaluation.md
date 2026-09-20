# Kev-first Reads judge: initial evaluation

**Later experiment:** the user explicitly requested a Kev Lite TestFlight despite
these diagnostic failures. See [Kev Lite](kev-lite.md) for the native port, relaxed
experimental feed ranking and release behavior. The historical results below
remain unchanged.

The target is a small on-device decision model that uses journals/personal
memory to judge RSS stories, links and Nostr posts. Qwen3-Reranker is a legacy
comparison baseline, no longer the primary Jev substitute. Kev-0.5B is the first
candidate tested for the replacement.

## Result: do not promote this checkpoint yet

The actual public adapter and pointer head were loaded on top of the pinned
Qwen2.5-0.5B base, using upstream inference in float32 on a Linux CPU with two
threads. No personal journals, remote inference, generated answers, or mock
scores were used. Tests ran on 2026-09-19.

Twelve authored synthetic cases contain six clearly relevant and six unrelated
items. They include a changed-memory pair, a relevant challenge to a belief,
and instruction/delimiter attacks. This is a diagnostic smoke set, not a held-out
benchmark or a calibrated estimate of recommendation quality.

| Input layout | Relevant admitted at 0.80 | Unrelated admitted | Topic correct | Packed/separate max difference | Median packed CPU time |
| --- | --- | --- | --- | --- | --- |
| Memory and incoming item in shared state | 2/6 | 0/6 | 6/12 | 0.00000554 | 0.80 s |
| Incoming item in state; memory in four personal questions | 3/6 | 0/6 | 5/12 | 0.00000268 | 1.51 s |

The second layout was tried after inspecting failures in the first. It is an
exploratory adjustment on the same cases, not an independent validation set.
Times include one packed forward evaluation, exclude downloading/loading and
separate-question checks, include the first cold request, and are single samples
on a shared CPU. They do not predict iPhone speed or compare speed against the
legacy reranker. The longer second layout repeats memory in four branches.

The most important failure: the relevant challenge case scored 0.158 with the
item-only state, whereas an unrelated delimiter-attack item scored 0.608. Simply
lowering the admission threshold cannot separate those cases. In the shared
state layout, an unrelated football item scored 0.462, above a relevant local-AI
item's 0.332. Topic outputs also confused memory content with incoming content;
removing memory from the shared state did not fix overall topic accuracy.

Packed and independent questions agree within 0.000006: the upstream branch
isolation mechanism works in this test. Neither layout admitted the two attack
examples at 0.80; two examples do not establish prompt-injection resistance.
Worth-reading, novelty and priority distributions were collected, but those
outputs have no independently labelled accuracy/calibration measurement here.

**Release decision:** retain these results and improve/evaluate the candidate
before native integration. This branch changes evaluation and documentation
only. The previous TestFlight build still runs the existing reranker when
activated; Kev is not yet downloadable or activatable in that build. No new
TestFlight upload or production-model switch was performed for this experiment.

## Intended app contract

- Local context uses included journals and corrected personal-memory records.
  Deleted/excluded material must invalidate approvals as in the existing gate.
- Ask five typed questions: relevant (yes/no), worth reading (yes/no), topic
  (AI/philosophy/food systems/data/family/other), new relative to supplied memory
  (yes/no), and priority (low/medium/high). Novelty must not be described as
  knowledge of everything the person already knows.
- Strong relevance is mandatory for admission. Topic and priority cannot bypass
  it. Thresholds and any additional worth-reading gate need labelled validation.
- Use full distributions internally. Failed, missing, stale, or invalid outputs
  abstain. Keep the writing model out of incoming-item decisions.
- Match the trained architecture: base + LoRA + pointer head, reserved-token
  sanitization, reset branch positions and isolated question attention. Reuse
  context and evaluate the branches without generating an answer.

## Native deployment gate

The published checkpoint is an adapter plus a PyTorch pointer head, not a
ready-made GGUF. The existing reranker's yes/no vocabulary logits are not Kev's
readout. A native port needs the trained adapter and both 896-to-256 projections
(including biases), final hidden states at option-end/decision tokens, and the
same scaled dot product/softmax. Any quantization must be checked against this
float32 reference, including packed versus separate branch parity.

Before promoting a default: fix the observed relevance/topic failures, evaluate
on fresh labelled examples (including useful disagreement and English/German
journals), verify native numerical parity, then measure real-device latency,
peak memory and interruption behavior with the writing model loaded. Only then
publish checksum-pinned downloadable assets and an independent Activate for
Reads control. Do not advertise an available Kev download until those assets
and runtime actually exist.

Proven → Better → New: retain local downloads, memory exclusions, background
scheduling, signed Nostr ingestion and strict admission. Improve the decision
engine with a typed judge. Add topic/novelty/priority only after validation.
Rollback for this evaluation branch is a documentation/test revert; there are
no app, ABI, model-download, storage or signing changes.

## Reproduce

From the repository root, with Python 3.12:

```bash
python -m venv /tmp/slowclaw-kev-env
source /tmp/slowclaw-kev-env/bin/activate
python -m pip install torch==2.14.0 --index-url https://download.pytorch.org/whl/cpu
python -m pip install -r ios-app/Tests/kev/requirements.txt
git clone https://github.com/jaredpalmer/kev.git /tmp/slowclaw-kev
git -C /tmp/slowclaw-kev checkout 29d71c78368657b3a522729a01c748ea15272abc
# Inspect kev/model.py before running; the evaluator imports that pinned code.
HF_HUB_DISABLE_XET=1 python ios-app/Tests/kev/evaluate.py \
  --upstream /tmp/slowclaw-kev --layout shared-memory --output /tmp/kev-shared.json
HF_HUB_DISABLE_XET=1 python ios-app/Tests/kev/evaluate.py \
  --upstream /tmp/slowclaw-kev --layout item-state --output /tmp/kev-item.json
```

The runner finishes when measurement succeeds; exit code zero is not a quality
pass. Inspect the summary and case distributions. Model downloads require about
1 GB, and unquantized CPU evaluation needs several GB of RAM. Outputs contain
only the synthetic fixture identifiers and scores.

Fixtures and full results: `ios-app/Tests/kev/`. The results record the fixture
SHA256 and all model/code revisions. The Python checkpoint is opened with
`weights_only=True`. Both models are pinned and no remote model code is enabled.

Sources: [upstream architecture](https://github.com/jaredpalmer/kev/blob/29d71c78368657b3a522729a01c748ea15272abc/kev/model.py),
[checkpoint/model card](https://huggingface.co/jaredpalmer/kev-0.5b/tree/edf1dc6d7f8d983c0adfd251e80a686e5539fc61),
[base](https://huggingface.co/Qwen/Qwen2.5-0.5B/tree/060db6499f32faf8b98477b0a26969ef7d8b9987).
