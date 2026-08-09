# SlowClaw Social — Docs

This directory will hold documentation for the current SlowClaw Social
architecture: a **Zig core** (`zig-src/`) exposed via a C FFI, wrapped by a
thin **native Swift shell** (`ios-app/`).

The previous Rust/Tauri/React documentation was removed during the
`zig-ios-pivot` consolidation — it described a stack that no longer ships.

## Entry points

- [`../README.md`](../README.md) — project overview, build, and architecture.
- [`../AGENTS.md`](../AGENTS.md) — agent engineering protocol.
- [`../zig-src/README.md`](../zig-src/README.md) — Zig core: build targets, FFI, modules.
- [`../ios-app/README.md`](../ios-app/README.md) — iOS app: Xcode project, signing, build flow.
- [`../windows-app/README.md`](../windows-app/README.md) — Windows companion shell (LAN sync, non-product).
- [`../windows-app/PROTOCOL.md`](../windows-app/PROTOCOL.md) — the LAN QR-paired sync wire protocol.
- [`../.github/workflows/pub-testflight-zig.yml`](../.github/workflows/pub-testflight-zig.yml) — TestFlight publish pipeline.
