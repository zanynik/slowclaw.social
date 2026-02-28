# slowclaw.social (minimal workspace-only fork)

A stripped-down fork of SlowClaw focused on one job:

- run in a single workspace
- execute/schedule workspace scripts
- write results to PocketBase
- serve a simple bundled web UI

The binary name is `slowclaw`.

## What This Fork Keeps

- Workspace-only file access policy (hard-enforced in app config/policy)
- CLI + gateway (`/pair`, `/pair/new-code`, `/webhook`, `/health`, `/metrics`)
- Cron scheduling
- `workspace-script <relative/path>` scheduled command support
- PocketBase delivery for cron/heartbeat output
- PocketBase sidecar auto-start (if `pocketbase` binary is available)
- `memory/` folder structure (unchanged)
- Bundled web UI (replaced with the MySky/PocketBase-based frontend)

## What This Fork Removes

- Full-system access / configurable extra roots (`allowed_roots`)
- External channel integrations (Telegram, WhatsApp, Discord, Slack, etc.)
- Gateway dashboard REST API (`/api/*`), SSE, and WebSocket chat endpoints
- Old dashboard frontend pages and integration UI

## Before You Install (Security)

Scheduled scripts are still real process execution. App-level workspace checks are useful, but not a kernel sandbox.

Read `SECURITY.md` and follow the **Workspace-Only Fork Hardening (Before Install)** section.

Minimum recommendation:

- dedicated OS user
- dedicated workspace directory
- container/VM (preferred) or Linux sandbox backend (`bwrap` / firejail / Landlock)
- restrict network egress unless needed

## Quick Start (Recommended)

Use the unified Tauri desktop app. It starts frontend + PocketBase + SlowClaw daemon together.

### 1. Prerequisites

- Rust toolchain (`rustc`, `cargo`)
- Node.js 18+
- PocketBase binary available as Tauri sidecar:
  - `web/src-tauri/binaries/pocketbase-aarch64-apple-darwin`
- SlowClaw binary sidecar:
  - `web/src-tauri/binaries/slowclaw-aarch64-apple-darwin`

### 2. Run desktop app

```bash
cd web
npm install
npm run tauri dev
```

Desktop startup now:

1. resolves Tauri `app_data_dir`,
2. creates `app_data_dir/workspace`,
3. runs non-interactive onboarding scaffold for new users,
4. starts PocketBase sidecar (`127.0.0.1:8090`),
5. starts SlowClaw daemon (`127.0.0.1:42617`) using app-local config/workspace.

This means new users do not need pre-existing `~/.zeroclaw/workspace`.

### 3. Desktop auth flow

- In app `Settings`, sign in to Bluesky using:
  - handle
  - app password
- Credentials are stored in OS keyring via Tauri commands (`get_secret`, `set_secret`).

### 4. Mobile pairing flow (thin client)

- On desktop `Settings`, click **Generate QR**.
- Mobile app opens to QR scanner login.
- Scan QR to import:
  - local gateway URL (`http://<desktop-lan-ip>:42617`)
  - gateway bearer token
- Mobile then uses these for all gateway requests on local Wi-Fi.

## CLI / Gateway Quick Start (Manual)

### 1. Prerequisites

Required:

- Rust toolchain (`rustc`, `cargo`)
- PocketBase binary (optional but strongly recommended for this fork's default flow)

Optional (for rebuilding the web UI):

- Node.js 18+

### 2. Place PocketBase binary

The gateway can auto-start PocketBase if it finds a binary in one of these locations:

- `./pocketbase/pocketbase`
- `./pocketbase/pocketbase.exe` (Windows)
- `PATH`
- `ZEROCLAW_POCKETBASE_BIN=/absolute/path/to/pocketbase`

The sidecar will store data in:

- `./pb_data/`

### 3. Build

```bash
cargo build --release
```

Binary path:

```bash
./target/release/slowclaw
```

### 4. Run the gateway (serves UI + starts PocketBase sidecar if available)

```bash
./target/release/slowclaw gateway
```

Open:

- `http://127.0.0.1:42617/` (or your configured gateway port)

The gateway startup log prints the actual UI URL and whether PocketBase sidecar started.

Recommended for full scheduling + chat worker runtime:

```bash
./target/release/slowclaw daemon
```

### 5. Pair and send a webhook prompt (optional)

If pairing is enabled, use the startup pairing code:

```bash
curl -X POST http://127.0.0.1:42617/pair -H 'X-Pairing-Code: <code>'
```

Then send prompts:

```bash
curl -X POST http://127.0.0.1:42617/webhook \
  -H 'Authorization: Bearer <token>' \
  -H 'Content-Type: application/json' \
  -d '{"message":"hello"}'
```

### 6. Generate a new pairing code without logging out existing clients

Use this when Mac is already paired and you want to pair phone too.

```bash
./target/release/slowclaw pair new-code --token '<existing_bearer_token>'
```

You can also set:

```bash
export ZEROCLAW_GATEWAY_TOKEN='<existing_bearer_token>'
./target/release/slowclaw pair new-code
```

Notes:

- Existing paired sessions remain valid.
- `config.toml` stores hashed tokens, not plaintext bearer tokens.
- You can copy the current token from the web UI: Profile -> Gateway & App Settings -> Show Token / Copy Token.

## PocketBase Setup

This fork now includes PocketBase project assets copied from the merged UI project:

- `pb_migrations/`
- `pocketbase/collections.example.json`
- `scripts/pb-bootstrap.mjs`

Environment variables:

- `ZEROCLAW_POCKETBASE_DISABLE=1` disable sidecar auto-start
- `ZEROCLAW_POCKETBASE_BIN=/path/to/pocketbase` choose binary
- `ZEROCLAW_POCKETBASE_HOST=127.0.0.1` override host
- `ZEROCLAW_POCKETBASE_PORT=8090` override port
- `ZEROCLAW_POCKETBASE_URL=http://127.0.0.1:8090` cron delivery target
- `ZEROCLAW_POCKETBASE_TOKEN=...` optional auth token for writes
- `ZEROCLAW_POCKETBASE_COLLECTION=cron_runs` optional collection name

Bootstrap/create collections (including `chat_messages`) after PocketBase is running:

```bash
cd web
PB_URL=http://127.0.0.1:8090 PB_EMAIL=admin@example.com PB_PASSWORD='your-admin-password' npm run pb:bootstrap
```

## Scheduling Workspace Scripts

Use the cron CLI and the `workspace-script` command form.

Example script (must live inside the workspace):

```bash
mkdir -p scripts
cat > scripts/ping.sh <<'SH'
#!/usr/bin/env bash
set -euo pipefail
date > ./last-run.txt
SH
chmod +x scripts/ping.sh
```

Schedule it every 15 minutes:

```bash
./target/release/slowclaw cron add '*/15 * * * *' 'workspace-script scripts/ping.sh'
```

Notes:

- Path must be workspace-relative.
- Keep scripts small and reviewed.
- Prefer `workspace-script` over long shell chains.
- App policy is not a substitute for OS sandboxing.

## Web UI (Merged From `phone_app_mysky`)

The bundled UI is now a PocketBase-backed React app (replacing the old dashboard).

To rebuild the UI bundle:

```bash
cd web
npm install
npm run build
```

The gateway serves static assets under `/_app/` and uses SPA fallback for `/`.

Important:

- The web bundle is embedded in the Rust binary at compile time.
- After `web` changes, rebuild both UI and binary:

```bash
cd web && npm run build
cd .. && cargo build --release
```

## Tauri v2 Unified Desktop App

This repo now includes a Tauri v2 desktop scaffold at:

- `web/src-tauri/`

Included:

- secure credential bridge commands (`get_secret`, `set_secret`, `delete_secret`) backed by OS keyring
- `tauri.conf.json`
- capability files
- sidecar bootstrap for:
  - PocketBase
  - SlowClaw daemon backend
- single desktop dev loop via:
  - `npm run tauri dev`

### Desktop dev loop (frontend + backend + sidecars)

```bash
cd web
npm install
npm run tauri dev
```

At app startup, Tauri now:

1. launches PocketBase sidecar (127.0.0.1:8090),
2. ensures app-local workspace/config scaffold exists (auto-onboard for new users),
3. launches `slowclaw daemon` backend (127.0.0.1:42617),
4. terminates both when the app exits.

Sidecar orchestration is compiled only for desktop targets (`not(iOS/Android)`), so mobile builds stay thin-client only.

For packaging, place sidecar binaries in:

- `web/src-tauri/binaries/`

### Prerequisites (macOS/iOS)

Install before running mobile commands:

- Xcode (full app)
- Rust iOS targets:
  - `rustup target add aarch64-apple-ios x86_64-apple-ios aarch64-apple-ios-sim`
- CocoaPods:
  - `brew install cocoapods`

### First-time iOS setup

```bash
cd web
npm install
npm run tauri:ios:init
```

### Run on iOS simulator/device

```bash
cd web
npm run tauri:ios:dev
```

### Notes

- Gateway build still uses `npm run build` (`/_app/` asset base) for embedded Rust gateway UI.
- Tauri build uses `npm run build:tauri` (`./` asset base) and is wired in `src-tauri/tauri.conf.json`.
- Desktop bundle sidecars are configured in `src-tauri/tauri.conf.json` `bundle.externalBin`.
- After `tauri ios init`, open the generated Xcode project and set:
  - camera + microphone usage descriptions
  - local network usage description
  - ATS exceptions for local HTTP testing if you keep laptop gateway on plain `http://`.

### Mobile Safari note (LAN HTTP)

iPhone Safari on `http://<LAN-IP>:<port>` may not expose live `getUserMedia` recording APIs.
In this fork, Audio/Video buttons fall back to file/capture picker automatically when live recording is unavailable.

## Minimal Route Surface (Gateway)

Exposed routes now:

- `GET /health`
- `GET /metrics`
- `POST /pair`
- `POST /pair/new-code`
- `POST /webhook`
- `GET /api/chat/messages`
- `POST /api/chat/messages`
- `POST /api/media/upload`
- `POST /api/journal/text`
- `GET /api/library/items`
- `GET /api/library/text`
- `POST /api/library/save-text`
- `GET /api/media/{path}`
- `GET /` and `GET /_app/*` (static UI)

Removed from the gateway surface in this fork:

- `/api/events`
- `/ws/chat`
- external channel webhook endpoints (`/whatsapp`, `/linq`, `/wati`, `/nextcloud-talk`, etc.)

## Project Layout (Important Directories)

- `memory/` — agent memory structure (kept intact for future use)
- `pb_data/` — PocketBase runtime data
- `pb_migrations/` — PocketBase migrations
- `pocketbase/` — PocketBase binary/schema assets
- `web/` — bundled web UI source/build
- `scripts/` — workspace scripts you schedule

## Validation Notes

Recommended local checks:

```bash
cargo check
git diff --check
```
