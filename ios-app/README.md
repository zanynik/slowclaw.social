# `ios-app/` — SlowClaw Social iOS app (Zig-backed)

This is the iOS shell slice (slice 7) of the iOS-only Zig pivot. It contains
everything needed to run the Zig core from a SwiftUI app end-to-end, proving
the full Swift → C ABI → Zig → SQLite path works on iOS.

**This is a skeleton**, not a polished app. The intent is to validate the
integration story; the product surfaces (journal capture, feed UI, publishing)
land in later slices on top of this foundation.

## Layout

```
ios-app/
  SlowClawFeed/                 Swift package wrapping the C ABI
    Package.swift               SwiftPM manifest
    Sources/SlowClawFeed/
      SlowClawFeed.swift        Idiomatic Swift overlay (String, throws, etc.)
      include/
        slowclaw_feed.h         The C ABI contract (mirrors zig-src/src/ffi.zig)

  SlowClawApp/                  Minimal SwiftUI demo app
    SlowClawApp.swift           Open DB → store → recall round-trip UI

  README.md                     This file
```

## Build

### 1. Build the Zig staticlib

```bash
cd zig-src
zig build
# → zig-out/lib/libslowclaw_feed.a (the staticlib Swift links)
# → zig-out/lib/libsqlite3.a      (vendored SQLite, included transitively)
```

### 2. Create the Xcode project

The repo deliberately does not ship a checked-in `.xcodeproj` (they're noisy
and machine-generated). To create one:

1. Open Xcode → File → New → Project → iOS → App.
2. Name it `SlowClawApp`, Swift interface, SwiftUI lifecycle.
3. Replace the generated `ContentView.swift` / `SlowClawApp.swift` with the
   file under `ios-app/SlowClawApp/SlowClawApp.swift`.
4. Add the SlowClawFeed Swift package:
   - File → Add Package Dependencies → Add Local → select `ios-app/SlowClawFeed`.
5. Add the Zig staticlib:
   - Target → General → Frameworks, Libraries, and Embedded Content → Add →
     Add Other → Add Files → select `zig-src/zig-out/lib/libslowclaw_feed.a`.
   - Target → Build Settings → Other Linker Flags → add `-lsqlite3` (iOS
     ships libsqlite3 as a system framework).
6. Add a build phase that runs `zig build` before each compile:
   - Target → Build Phases → + → New Run Script Phase → drag to top.
   - Script body:
     ```bash
     cd "$SRCROOT/../zig-src"
     "$SRCROOT/../tools/zig/zig" build || exit 1
     ```
   - Output files: `$(SRCROOT)/../zig-src/zig-out/lib/libslowclaw_feed.a`

### 3. Run

Select an iOS simulator target, ⌘R. The app opens a SQLite DB at
`<Documents>/slowclaw.sqlite`, lets you type a memory + store it, and runs a
hybrid keyword+vector recall across the store.

## Why this slice matters

Before this slice the Zig package was a library: well-tested, fully featured,
but **completely uncallable from iOS**. After this slice:

- The C ABI is captured in a single contract header (`slowclaw_feed.h`) that
  Swift imports directly.
- An idiomatic Swift overlay (`SlowClawFeed.swift`) hides the (pointer, length)
  ergonomics behind `String`/`throws`/`Data`.
- A working SwiftUI demo proves the integration end-to-end.

Every subsequent Zig module ported automatically becomes Swift-callable just
by adding new `export fn`s to `ffi.zig` and declarations to the header.

## Known limitations

- The Zig staticlib currently links the vendored SQLite amalgamation. On iOS
  the cleaner option is to switch `build.zig` to link the system `-lsqlite3`
  framework instead (smaller binary, no version drift). TODO.
- The Swift overlay exposes only the SQLite memory surface. The HashEmbedder
  and ranker are available via the C ABI but not yet wrapped — add as needed.
- The demo app's "list everything" uses a synthetic recall query; a real
  list-all API would be added to the C ABI when needed.
