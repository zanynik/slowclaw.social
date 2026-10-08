#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
: "${SLOWCLAW_DECIDER_GGUF:?Set to the pinned Decider GGUF}"
ZIG_BIN="${ZIG_BIN:-zig}"
DECIDER_TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$DECIDER_TEST_ROOT"' EXIT
cd "$ROOT/zig-src"
echo 'Compiling native Decider test archives (cold build)'
"$ZIG_BIN" build -Doptimize=ReleaseFast -j2 --prefix "$DECIDER_TEST_ROOT/libs"
"$ZIG_BIN" cc -w "$ROOT/ios-app/Tests/decider/native.c" \
  -I"$ROOT/ios-app/SlowClawFeed/Sources/SlowClawFeed/include" \
  "$DECIDER_TEST_ROOT/libs/lib/libslowclaw_feed.a" "$DECIDER_TEST_ROOT/libs/lib/libsqlite3.a" \
  "$DECIDER_TEST_ROOT/libs/lib/libllama.a" -lc++ -lpthread -lm -o "$DECIDER_TEST_ROOT/native"
echo 'Native runner compiled; starting full model validation'
python3 -u "$ROOT/ios-app/Tests/decider/native-smoke.py" --binary "$DECIDER_TEST_ROOT/native" \
  --model "$SLOWCLAW_DECIDER_GGUF" --output "${SLOWCLAW_DECIDER_REPORT:-/tmp/decider-native-report.json}"
