Kev-0.5B for the experimental SlowClaw Lite branch.

Merged Qwen2.5-0.5B backbone and Kev v0.1 LoRA, quantized to Q8_0. The trained pointer head remains FP32 in GGUF metadata. The model does not generate text. Requires SlowClaw's Kev native runtime; this is not a chat GGUF.

Base: https://huggingface.co/Qwen/Qwen2.5-0.5B/tree/060db6499f32faf8b98477b0a26969ef7d8b9987
Adapter/head: https://huggingface.co/jaredpalmer/kev-0.5b/tree/edf1dc6d7f8d983c0adfd251e80a686e5539fc61
Upstream: https://github.com/jaredpalmer/kev
Converter: https://github.com/ggml-org/llama.cpp/tree/8f4646a63ee29f2e0ab971b0290b141938769762

Base, adapter and head are Apache-2.0. License and checksum manifest attached. See the upstream model card for research limitations. Personal relevance quality remains experimental; scores are not calibrated probabilities of personal usefulness.
