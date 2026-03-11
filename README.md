# slowclaw.social (minimal workspace-only fork)

A stripped-down fork of SlowClaw focused on one job:

- run in a single workspace
- execute/schedule workspace scripts
- persist app data locally in SQLite
- serve a simple bundled web UI

The binary name is `slowclaw`.

## What This Fork Keeps

- Workspace-only file access policy (hard-enforced in app config/policy)
- CLI + gateway (`/pair`, `/pair/new-code`, `/webhook`, `/health`, `/metrics`)
- Cron scheduling
- `workspace-script <relative/path>` scheduled command support
- PocketBase delivery for cron/heartbeat output
- Gateway-managed local SQLite store for chat/drafts/history metadata
- `memory/` folder structure (unchanged)
- Bundled web UI (local-first gateway API frontend)

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

## Quick Start

### Fastest developer path

If you are working on the app locally, the main entry point is:

```bash
cd web
npm install
npm run tauri dev
```

That starts the React frontend, launches the embedded Rust gateway, and opens the desktop app shell.

### 1. Prerequisites

Required for all local development:

- Rust stable toolchain (`rustc`, `cargo`)
- Node.js 18+ and npm

Required on macOS for the Tauri desktop app:

- Xcode Command Line Tools

  ```bash
  xcode-select --install
  ```

Recommended on macOS for packaging and native Apple builds:

- Full Xcode app from the App Store
- Homebrew

Required for iPhone/iOS development:

- Full Xcode app
- CocoaPods

  ```bash
  brew install cocoapods
  ```

- Rust iOS targets

  ```bash
  rustup target add aarch64-apple-ios x86_64-apple-ios aarch64-apple-ios-sim
  ```

### 2. Clone and install dependencies

```bash
git clone https://github.com/zanynik/slowclaw.social.git
cd slowclaw.social
cd web
npm install
cd ..
```

### 3. Run the macOS desktop app in dev mode

```bash
cd web
npm run tauri dev
```

What this does:

- runs the Vite frontend dev server
- builds the Rust Tauri host
- starts the embedded gateway automatically
- opens the desktop app window

The frontend dev server is configured at `http://localhost:1420`, but in normal use you just launch the Tauri app window.

### 4. Build distributable desktop artifacts

To build the production desktop app and bundle outputs such as `.app` and `.dmg` on macOS:

```bash
cd web
npm run tauri -- build
```

Bundle outputs are written under:

- `web/src-tauri/target/release/bundle/`

### 5. Run the iPhone app in dev mode

First-time setup:

```bash
cd web
npm run tauri:ios:init
```

Then run on simulator or device:

```bash
cd web
npm run tauri:ios:dev
```

Notes:

- You will likely need to choose a signing team in Xcode for device builds.
- The generated iOS project lives under `web/src-tauri/gen/apple/`.
- The iOS app uses the same Rust/Tauri codebase and web frontend as the desktop app.

### 6. CLI / gateway-only development

If you only want the Rust binary and gateway without the Tauri shell:

```bash
cargo build --release
./target/release/slowclaw gateway
```

Recommended for full scheduling + chat worker runtime:

```bash
./target/release/slowclaw daemon
```

The default gateway bind is:

- `http://127.0.0.1:42617/`

### 7. Pair and send a webhook prompt (optional)

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

### Workspace path recommendation (journals, media, artifacts)

Use a stable config/workspace root so files are easy to find:

```bash
export ZEROCLAW_CONFIG_DIR="$HOME/.zeroclaw"
```

Avoid pointing `ZEROCLAW_WORKSPACE` at temporary directories (`/tmp`, OS temp folders).  
By default, temp workspace overrides are ignored unless you explicitly opt in with:

```bash
export ZEROCLAW_ALLOW_TEMP_WORKSPACE=1
```

### 8. Generate a new pairing code without logging out existing clients

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

## Local Store Migration

On first gateway boot, SlowClaw initializes `state/local_data.db` and automatically checks for
legacy PocketBase data directories (including `Application Support/.../pocketbase/pb_data`).

If found, it imports legacy records (`chat_messages`, `drafts`, `post_history`,
`journal_entries`, `media_assets`, `artifacts`) before serving traffic.

Optional override for migration source:

```bash
ZEROCLAW_LEGACY_POCKETBASE_DATA_DIR=/absolute/path/to/pb_data ./target/release/slowclaw gateway
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

The bundled UI is now a local-first React app backed by gateway APIs (replacing the old dashboard).

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

## Tauri v2 Mobile App (Scaffolded)

This repo now includes a Tauri v2 scaffold at:

- `web/src-tauri/`

Included:

- secure credential bridge commands (`get_secret`, `set_secret`, `delete_secret`) backed by OS keyring
- `tauri.conf.json`
- default capability file
- npm scripts for iOS/Android init + dev

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
- `pb_data/` — legacy PocketBase runtime data (auto-import source)
- `pb_migrations/` — legacy PocketBase migrations
- `pocketbase/` — legacy PocketBase binary/schema assets
- `web/` — bundled web UI source/build
- `scripts/` — workspace scripts you schedule

## Validation Notes

Recommended local checks:

```bash
cargo check
git diff --check
```
