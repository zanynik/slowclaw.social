#!/bin/bash
set -euo pipefail
APP_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT
mkdir -p "$TEST_ROOT/Sources/Runtime" "$TEST_ROOT/Tests/RuntimeTests"
cp "$APP_ROOT/SlowClawApp/OnDeviceAIExecutor.swift" "$APP_ROOT/SlowClawApp/Nip19.swift" "$APP_ROOT/SlowClawApp/NostrPublisher.swift" "$TEST_ROOT/Sources/Runtime/"
cp "$APP_ROOT/SlowClawApp/DraftBudget.swift" "$TEST_ROOT/Sources/Runtime/"
cp "$APP_ROOT/SlowClawApp/ReadingHistory.swift" "$TEST_ROOT/Sources/Runtime/"
swiftc -frontend -parse "$APP_ROOT"/SlowClawApp/*.swift
cp "$APP_ROOT/Tests/RuntimeTests.swift" "$TEST_ROOT/Tests/RuntimeTests/"
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
