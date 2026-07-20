// swift-tools-version: 5.9
//
// SlowClawFeed — Swift package wrapping the Zig `libslowclaw_feed.a` staticlib.
//
// The library is NOT built by Swift Package Manager; it's expected to be
// built separately via `zig build` (see the Xcode app target's build phases
// or the iOS app's README). This package only provides the Swift overlay.
//
// To consume the staticlib from an app:
//   1. Run `zig build` in zig-src/ → produces zig-src/zig-out/lib/libslowclaw_feed.a
//   2. Add libslowclaw_feed.a to your Xcode target's "Link Binary With Libraries"
//   3. Add zig-src/ as a header search path so Swift can find slowclaw_feed.h
//      (or copy the header into your project).

import PackageDescription

let package = Package(
    name: "SlowClawFeed",
    products: [
        .library(name: "SlowClawFeed", targets: ["SlowClawFeed"]),
    ],
    targets: [
        .target(
            name: "SlowClawFeed",
            path: "Sources/SlowClawFeed",
            publicHeadersPath: "include",
            cSettings: [
                // The slowclaw_feed.h header is self-contained (only stddef.h/stdint.h/stdbool.h).
            ]
        ),
    ]
)
