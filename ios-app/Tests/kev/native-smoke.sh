#!/bin/bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
: "${SLOWCLAW_KEV_GGUF:?Set to the pinned Kev GGUF}"
ZIG_BIN="${ZIG_BIN:-zig}"
KEV_TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$KEV_TEST_ROOT"' EXIT
cd "$ROOT/zig-src"
# The macOS archive repack cache keys include the install path. Never share
# that path with the later iOS build, or it can reuse a host-only archive.
"$ZIG_BIN" build -Doptimize=ReleaseFast -j2 --prefix "$KEV_TEST_ROOT/libs"
"$ZIG_BIN" cc -w "$ROOT/ios-app/Tests/kev/native.c" \
  -I"$ROOT/ios-app/SlowClawFeed/Sources/SlowClawFeed/include" \
  "$KEV_TEST_ROOT/libs/lib/libslowclaw_feed.a" \
  "$KEV_TEST_ROOT/libs/lib/libsqlite3.a" "$KEV_TEST_ROOT/libs/lib/libllama.a" \
  -lc++ -lpthread -lm -o "$KEV_TEST_ROOT/native"
python3 "$ROOT/ios-app/Tests/kev/native-smoke.py" --binary "$KEV_TEST_ROOT/native" \
  --model "$SLOWCLAW_KEV_GGUF" --output "${SLOWCLAW_KEV_REPORT:-/tmp/kev-native-report.json}"
