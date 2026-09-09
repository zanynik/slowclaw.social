# MiniCPM5 comparison release

Proven → Better: add an official MiniCPM5-2B Q4_K_M preset to the existing GGUF
download/activate path while retaining Gemma 4 E2B. No engine/vendor upgrade,
Speech change, new backend or expanded iPhone context window.

The preset is pinned to OpenBMB revision
`d00c954e5f9a0f2605468f24703ffa7e5cb0c492`, roughly 1.56 GB. The publisher uses
the standard Llama architecture. This app runs one model at a time and saves
the last successfully activated preset, so an app relaunch doesn't silently
switch a MiniCPM5 comparison back to Gemma. Both downloads remain user-controlled.

MiniCPM5 uses the publisher's text-only ChatML template with the closed thinking
prefix corresponding to `enable_thinking=false`. The llama.cpp C template API
cannot supply that Jinja option. This model-specific path avoids spending the
app's bounded output budget on a reasoning preamble; Gemma's prompt is unchanged.
BOS is added by the tokenizer. iPhone context remains 1,536 tokens, with the
existing two CPU inference threads. MiniCPM5's host smoke test also uses this
context limit, rather than its advertised long-context capacity.

Validation: prompt-format regression tests, existing Swift/Zig suites, real
GGUF loading and plain-text/JSON generation through the app's Zig inference
module, and full iOS compile/archive/upload in the existing publishing workflow.
The real-model smoke downloads the pinned file and checks SHA256
`ec2d5801640099e97d8d7e8003ad4d81f336e757811f03a26173dddf386602fd`.
Manual workflow runs can enable `test_minicpm` to repeat it. Model weights are
temporary test data, never committed or bundled in the app.

The Linux workspace has no installed Swift/Xcode or Zig toolchain; local diff,
shell syntax and workflow checks precede CI. Mac smoke inference and iOS compile
do not establish physical iPhone speed, memory pressure, battery use or output
quality on real journals. Benchmark superiority is not assumed.

Try: Settings → Advanced settings → On-Device AI → MiniCPM5 2B → Download,
then Activate. Switch back by activating Gemma; it remains installed.
Rollback by selecting Gemma or reverting this additive release.

Sources (checked 9 September 2026):
- https://huggingface.co/openbmb/MiniCPM5-2B
- https://huggingface.co/openbmb/MiniCPM5-2B-GGUF/blob/main/MiniCPM5-2B-Q4_K_M.gguf
- https://huggingface.co/openbmb/MiniCPM5-2B/blob/main/chat_template.jinja
