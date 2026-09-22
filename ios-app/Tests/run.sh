#!/bin/bash
set -euo pipefail
APP_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT
mkdir -p "$TEST_ROOT/Sources/Runtime" "$TEST_ROOT/Tests/RuntimeTests"
cp "$APP_ROOT/SlowClawApp/NostrFetcher.swift" "$APP_ROOT/SlowClawApp/ReadsContentFilter.swift" "$TEST_ROOT/Sources/Runtime/"
python3 - "$APP_ROOT" "$TEST_ROOT" <<'PYDTO'
import pathlib, sys
source = (pathlib.Path(sys.argv[1]) / "SlowClawFeed/Sources/SlowClawFeed/SlowClawFeed.swift").read_text()
start = source.index("public struct RankedFeedItem:")
end = source.index("private struct RankedFeedItemDTO:", start)
(pathlib.Path(sys.argv[2]) / "Sources/Runtime/RankedFeedItem.swift").write_text("import Foundation\n" + source[start:end])
PYDTO
cp "$APP_ROOT/SlowClawApp/JevMemory.swift" "$TEST_ROOT/Sources/Runtime/"
cp "$APP_ROOT/SlowClawApp/JevPersona.swift" "$APP_ROOT/SlowClawApp/JevIdeas.swift" "$APP_ROOT/SlowClawApp/JournalPolish.swift" "$TEST_ROOT/Sources/Runtime/"
cp "$APP_ROOT/SlowClawApp/JevFeeds.swift" "$TEST_ROOT/Sources/Runtime/"
cp "$APP_ROOT/SlowClawApp/KevLite.swift" "$TEST_ROOT/Sources/Runtime/"
cp "$APP_ROOT/SlowClawApp/ReadsRelevance.swift" "$TEST_ROOT/Sources/Runtime/"
cp "$APP_ROOT/SlowClawApp/OnDeviceAIExecutor.swift" "$APP_ROOT/SlowClawApp/Nip19.swift" "$APP_ROOT/SlowClawApp/NostrPublisher.swift" "$TEST_ROOT/Sources/Runtime/"
cp "$APP_ROOT/SlowClawApp/DraftBudget.swift" "$TEST_ROOT/Sources/Runtime/"
cp "$APP_ROOT/SlowClawApp/ReadingHistory.swift" "$TEST_ROOT/Sources/Runtime/"
cp "$APP_ROOT/SlowClawApp/TranscriptSafety.swift" "$TEST_ROOT/Sources/Runtime/"
cp "$APP_ROOT/SlowClawApp/ArticleReflection.swift" "$TEST_ROOT/Sources/Runtime/"
cp "$APP_ROOT/SlowClawApp/ContextTools.swift" "$TEST_ROOT/Sources/Runtime/"
cp "$APP_ROOT/SlowClawApp/PersonalMemory.swift" "$TEST_ROOT/Sources/Runtime/"
cp "$APP_ROOT/SlowClawApp/QuestionThread.swift" "$TEST_ROOT/Sources/Runtime/"
cp "$APP_ROOT/SlowClawApp/NostrConversations.swift" "$TEST_ROOT/Sources/Runtime/"
cp "$APP_ROOT/SlowClawApp/NostrReply.swift" "$TEST_ROOT/Sources/Runtime/"
cp "$APP_ROOT/SlowClawApp/WeeklyReflection.swift" "$TEST_ROOT/Sources/Runtime/"
swiftc -frontend -parse "$APP_ROOT"/SlowClawApp/*.swift
cp "$APP_ROOT/Tests/RuntimeTests.swift" "$TEST_ROOT/Tests/RuntimeTests/"
cp "$APP_ROOT/Tests/JournalPolishTests.swift" "$TEST_ROOT/Tests/RuntimeTests/"
cat > "$TEST_ROOT/Package.swift" <<'SWIFT'
// swift-tools-version: 6.1
import PackageDescription
let package = Package(name: "Runtime", platforms: [.macOS(.v14)],
    products: [.library(name: "Runtime", targets: ["Runtime"])],
    dependencies: [.package(url: "https://github.com/21-DOT-DEV/swift-secp256k1", exact: "0.23.2")],
    targets: [
        .target(name: "Runtime", dependencies: [.product(name: "libsecp256k1", package: "swift-secp256k1")]),
        .testTarget(name: "RuntimeTests", dependencies: ["Runtime"])
    ], swiftLanguageModes: [.v5])
SWIFT
swift test --package-path "$TEST_ROOT"
