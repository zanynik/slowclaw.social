#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
: "${SLOWCLAW_KEV_GGUF:?Set to the pinned Kev GGUF}"
ZIG_BIN="${ZIG_BIN:-zig}"
KEV_TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$KEV_TEST_ROOT"' EXIT
cd "$ROOT/zig-src"
"$ZIG_BIN" build -Doptimize=ReleaseFast -j2
"$ZIG_BIN" cc -w "$ROOT/ios-app/Tests/kev/native.c" \
  -I"$ROOT/ios-app/SlowClawFeed/Sources/SlowClawFeed/include" \
  zig-out/lib/libslowclaw_feed.a zig-out/lib/libsqlite3.a zig-out/lib/libllama.a \
  -lc++ -lpthread -lm -o "$KEV_TEST_ROOT/native"
python3 "$ROOT/ios-app/Tests/kev/native-smoke.py" --binary "$KEV_TEST_ROOT/native" \
  --model "$SLOWCLAW_KEV_GGUF" --output "${SLOWCLAW_KEV_REPORT:-/tmp/kev-native-report.json}"
