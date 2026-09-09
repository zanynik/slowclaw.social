#!/bin/bash
set -euo pipefail
REPO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
MODEL_DIR="$(mktemp -d)"
trap 'rm -rf "$MODEL_DIR"' EXIT
MODEL_FILE="$MODEL_DIR/MiniCPM5-2B-Q4_K_M.gguf"
curl --fail --location --retry 3 --connect-timeout 30 --max-time 600 \
  'https://huggingface.co/openbmb/MiniCPM5-2B-GGUF/resolve/d00c954e5f9a0f2605468f24703ffa7e5cb0c492/MiniCPM5-2B-Q4_K_M.gguf' \
  --output "$MODEL_FILE"
printf '%s  %s\n' 'ec2d5801640099e97d8d7e8003ad4d81f336e757811f03a26173dddf386602fd' "$MODEL_FILE" | shasum -a 256 --check
cd "$REPO_ROOT/zig-src"
SLOWCLAW_TEST_GGUF="$MODEL_FILE" "${ZIG_BIN:?Set ZIG_BIN to Zig 0.16.0}" build test-local-llm -Doptimize=ReleaseFast -j2
