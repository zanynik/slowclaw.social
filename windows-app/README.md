# SlowClaw Sync (Windows companion)

LAN-only, QR-paired sync companion for the SlowClaw Social iOS app. This is a
**non-product** companion surface: its sole role is syncing the user's own
journals + audio between the user's own two devices. It does **no** capture,
curation, or publishing. See [`../AGENTS.md`](../AGENTS.md) §1/§9 for the
bounded exception that authorizes this surface, and
[`PROTOCOL.md`](./PROTOCOL.md) for the wire contract.

## What it does

1. Opens a window showing a **QR code** containing its LAN host + port + a
   one-time pairing token.
2. Runs a **token-gated HTTP listener** on the LAN (desktop = server).
3. When the iOS app scans the QR, the iOS client drives the sync exchange
   (manifest → diff → pull/push entries + audio). The desktop delegates all
   manifest/diff/apply logic to the **Zig core** via P/Invoke — the same C ABI
   the iOS shell uses.
4. Stops the listener when the window closes. Never a background daemon.

## Architecture (mirrors the iOS shell, one C ABI)

```
Windows shell (C# WinUI 3)  →  C ABI (slowclaw_feed.h)  →  Zig core  →  vendored sqlite
       owns: LAN transport              owns: sync logic + persistence
```

The Zig core stays transport-agnostic (AGENTS.md §6.3). On-device LLM
(llama.cpp) is **disabled** on Windows (`-Dwith-llama=false`) — the sync shell
needs no inference, and this avoids shipping the 102 MB llama binary.

## Build

Prerequisites: Windows 10 1809+ (17763+), .NET 8 SDK, the Zig toolchain at
`../tools/zig/zig.exe` (or on PATH).

```bash
# The csproj pre-build target runs this for you, but you can do it manually:
cd ../zig-src && ../tools/zig/zig.exe build -Dtarget=x86_64-windows-msvc -Doptimize=ReleaseFast -Dwith-llama=false

# Then build + run the shell:
cd ../windows-app && dotnet build -c Release
dotnet run --project SlowClawSync/SlowClawSync.csproj -c Release
```

The csproj `BuildZigCore` MSBuild target runs `zig build` before the C# compile
and copies `slowclaw_feed.lib` next to the `.exe` so the
`DllImport("slowclaw_feed")` resolves at runtime.

## Layout

```
windows-app/
  SlowClawSync.sln
  PROTOCOL.md                         # the wire contract
  README.md                           # this file
  SlowClawSync/
    App.xaml(.cs)                     # entry: open the Sync window
    MainWindow.xaml(.cs)              # QR display + listener lifecycle
    app.manifest                      # unpackaged, asInvoker
    SlowClawSync.csproj               # net8.0-windows, WinUI 3, QRCoder dep
    Native/SlowClawNative.cs          # P/Invoke bindings to libslowclaw_feed
    Sync/SyncServer.cs                # HttpListener + token auth + endpoints
    Sync/QrPayload.cs                 # QR JSON payload + base32 token
    Sync/LanInterface.cs              # picks the LAN IPv4 for the QR
    Storage/DatabasePath.cs           # %LOCALAPPDATA%\SlowClaw\ layout
```

## Security & privacy

- The pairing token is 32 random bytes, regenerated each time the window opens,
  never persisted. It's the only auth — see PROTOCOL.md for the threat model.
- The listener binds to a **specific** LAN interface, not `0.0.0.0`, to avoid
  accidental exposure on virtual/loopback adapters.
- Path-traversal is guarded on every `/v1/media` handler.
- Raw journal content and transcripts are never logged.

## Validation status

- **Zig core + FFI:** fully validated (all test steps pass; the sync C-ABI
  round-trip converges two stores deterministically).
- **Windows shell:** compile-validated against standard WinUI 3 / .NET 8 +
  QRCoder APIs. Runtime smoke (QR renders, listener binds the LAN port, token
  auth rejects unauthenticated requests) is the documented next step — it
  requires the .NET SDK installed on the dev machine. End-to-end device sync
  needs an iOS device + the iOS client (Phase 4).
