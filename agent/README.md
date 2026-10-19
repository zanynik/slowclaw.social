# Slowclaw Local Agent — first working slice

A **local-only, long-running** harness that turns mirrored passages into **reviewable proposals**. It does not modify iPhone data. It uses Node's built-in SQLite, HTTP, crypto and filesystem modules with no npm dependencies. Pi is optional and disabled by default.

## Requirements

- Node.js **22.13+** (`node:sqlite` in Node 22 is experimental and may print a warning).
- Optional: an installed, authenticated [Pi](https://github.com/earendil-works/pi) command-line tool with a model you trust. Pi may call a **remote** provider.

## Run with invented data

```sh
cd agent
npm test
npm run demo
npm start
```

In another terminal in `agent/`, run `npm run token`. Open **http://127.0.0.1:4317** and paste the token. You should see the demo's journal passages and a sourced connection proposal; accept or reject it. The local worker processes queued jobs even if you close the dashboard. Scheduled discovery is **off by default**; enable it in the dashboard. Everything remains local on this computer.

Set `SLOWCLAW_AGENT_HOME` to choose a different private data directory (default `~/.slowclaw/agent`). Set `SLOWCLAW_AGENT_PORT` to change the localhost port. The access-token file is created with owner-only permissions where the OS supports them. Never expose the port externally or share the token.

## Passage import (manual)

You can paste a passage into the dashboard, or import a local UTF-8 JSON file:

```sh
node src/main.mjs import path/to/my-passages.json
```

Expected shape:

```json
{
  "passages": [{
    "id": "journal:abc:passage:1",
    "source": "journal:abc",
    "revision": 1,
    "occurred_at": "2026-10-19T07:00:00Z",
    "body": "A paragraph of journal text"
  }]
}
```

Import up to 100 passages at once. IDs must be stable, revisions monotonic, and conflicts are rejected atomically. This is **not yet a parser for the phone's own export**; use manually prepared passages until a phone–daemon bridge exists. Imported text is a **local mirror**, not a phone edit or cloud sync.

## Pi text reflection (explicit consent)

Install and authenticate Pi separately. Verify your version supports flags documented in [Pi's CLI guide](https://github.com/earendil-works/pi/blob/main/packages/coding-agent/docs/cli.md). Then start the daemon with Pi enabled:

```powershell
# Windows PowerShell
$env:SLOWCLAW_ENABLE_PI = '1'
npm start
```

In the dashboard, enter 1–12 exact source IDs and tick the consent box for that individual model request. Pi receives the selected text over stdin, with no built-in tools, discovered extensions, skills, context files, prompts, or persisted sessions. **Pi may send your journal text to the configured model provider**. Choose a local provider if you do not wish to share it remotely. Pi failures mark the job failed without changing the mirror.

## API (version 1)

All `/v1/*` endpoints require `Authorization: Bearer <local token>`. The server binds **127.0.0.1 only**. It does not enable CORS and rejects cross-origin requests.

| Method | Endpoint | Purpose |
| --- | --- | --- |
| GET | `/v1/status` | Runtime and scheduler state |
| POST | `/v1/passages` | Revision-safe import: `{ "passages": [...] }` |
| GET | `/v1/passages` | Mirrored source passages |
| POST | `/v1/jobs` | Queue `discover-connections`; or `reflect` with `payload.source_ids` and `payload.allow_model_provider=true` |
| GET | `/v1/jobs` | Durable job status and errors |
| GET | `/v1/proposals` | Suggested connections/reflections and source IDs |
| POST | `/v1/proposals/{uuid}/decision` | `{ "status": "accepted" }` or `"rejected"` |
| PUT | `/v1/schedule` | `{ "enabled": true, "interval_minutes": 1440 }` (minimum 60) |
| GET | `/v1/events` | Bounded metadata-only audit history |

## Current limits and rollback

- The iPhone owns canonical journals; this daemon never writes phone data. Accepting a proposal records a **local** decision, not a synced phone decision.
- Repeated deterministic suggestions are deduplicated by source IDs and revisions; Pi model responses remain reviewable proposals.
- Incomplete read-only jobs recover once after restart. No externally consequential autonomous actions exist.
- Connection discovery currently uses **lexical similarity**, not EmbeddingGemma. It can miss paraphrases.
- Raw mirrored passages are stored unencrypted on local disk in SQLite; protect your OS account and use disk encryption. Do not put the database in a shared/synced folder.
- The localhost dashboard is **not yet integrated** into the existing `web/` GitHub Pages companion.
- This version does not include phone↔daemon WebRTC, automatic iOS export import, background scheduling on iPhone, remote access, or OS auto-start service. These remain future milestones.
- Stop the daemon to roll back. Existing Zig, Swift, and static browser code is unchanged. Preserve any valuable local-only decisions before deleting `~/.slowclaw/agent`.

Engineering principle: **Proven → Better → New**. Preserve iPhone and web capture; add reliable local job execution and approval; incrementally extend with opt-in reasoning.
