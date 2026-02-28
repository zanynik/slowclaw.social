# Sidecar Binaries

Place sidecar binaries here for Tauri v2 `externalBin` packaging.

Configured sidecars in `tauri.conf.json`:

- `binaries/pocketbase`
- `binaries/slowclaw`

For packaging, Tauri expects target-suffixed files at build time, for example on Apple Silicon macOS:

- `pocketbase-aarch64-apple-darwin`
- `slowclaw-aarch64-apple-darwin`

For local desktop dev in this repo, these fallbacks are also used:

- PocketBase:
  - `src-tauri/binaries/pocketbase`
  - `../../pocketbase/pocketbase`
  - or `ZEROCLAW_POCKETBASE_BIN`
- SlowClaw daemon:
  - `src-tauri/binaries/slowclaw`
  - `../../target/release/slowclaw`
  - or `SLOWCLAW_DAEMON_BIN`
