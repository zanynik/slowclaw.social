#!/bin/bash
# Real-model native smoke test. Model path must be the pinned Q4_K_M artifact.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
: "${SLOWCLAW_READS_GGUF:?Set to Qwen3-Reranker-0.6B.Q4_K_M.gguf}"
ZIG_BIN="${ZIG_BIN:-zig}"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT
cd "$ROOT/zig-src"
"$ZIG_BIN" build -Doptimize=ReleaseFast -j2
"$ZIG_BIN" cc -w "$ROOT/ios-app/Tests/reads-decision-smoke.c" \
    -I"$ROOT/ios-app/SlowClawFeed/Sources/SlowClawFeed/include" \
    zig-out/lib/libslowclaw_feed.a zig-out/lib/libsqlite3.a zig-out/lib/libllama.a \
    -lc++ -lpthread -lm -o "$TEST_ROOT/reads-smoke"
"$TEST_ROOT/reads-smoke" "$SLOWCLAW_READS_GGUF"
