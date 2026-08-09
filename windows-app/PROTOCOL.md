# SlowClaw Sync Wire Protocol (v1)

LAN-only, QR-paired sync between the user's own iOS app and Windows
companion. Authorized as a bounded companion-surface exception in
[`../AGENTS.md`](../AGENTS.md) §1/§9.

**Scope reminder (hard rules):** same-LAN only; no relay, no cloud, no
public exposure; sync unit is journal `memories` rows + audio media files
referenced by `media_url` only. The desktop runs the listener; iOS scans
the QR and acts as client. The listener starts when the user opens the
Sync screen and stops on window close.

## Roles

| Role | Device | Process |
| --- | --- | --- |
| **Server** | Windows companion | `HttpListener` bound to the LAN interface. Renders the QR. |
| **Client** | iOS app | `URLSession` HTTP client. Scans the QR, drives the exchange. |

## Pairing payload (the QR code content)

A JSON object encoded as a QR. The iOS client parses it to learn where to
connect and how to authenticate:

```json
{
  "v": 1,
  "host": "192.168.1.42",
  "port": 8421,
  "token": "BASE32ENCODED32BYTES",
  "name": "DESKTOP-PC"
}
```

- `v` — protocol version (currently `1`).
- `host` — the server's LAN IPv4 address (the Windows shell picks a
  non-loopback interface).
- `port` — TCP port (default `8421`).
- `token` — 32 random bytes, base32-encoded (no padding). Required in the
  `Authorization` header of every request. Regenerated each time the Sync
  screen opens; not persisted.
- `name` — display name for the server (the machine name), shown in the
  iOS UI.

The token is the **only** auth. It is a pairing secret shared over a
visual channel (the QR), valid for the lifetime of the Sync session, and
never transmitted in cleartext over a medium other than the QR itself.
There is no TLS on the LAN transport (KISS); the token gates access. This
is acceptable because the threat model is "another device on the same LAN"
— the token raises the bar from "any LAN neighbor can read your journals"
to "any LAN neighbor who can also see your screen can read your journals".

## Transport

Plain HTTP/1.1 on the LAN. All requests carry:

```
Authorization: Bearer <token>
```

Requests with a missing or mismatched token get `401 Unauthorized`. The
server closes the listener on window close; no background daemon.

### Endpoints (all under `/v1/`)

#### `GET /v1/manifest` → 200

Returns the server's sync manifest (the JSON shape produced by
`slowclaw_feed_sync_build_manifest`):

```json
{
  "v": 1,
  "entries": [
    {
      "key": "slowclaw_user_key_1",
      "updated_at": "2026-08-09T14:39:15Z",
      "content_sha256": "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855",
      "has_media": true,
      "media_path": "Recordings/journal_1234.m4a",
      "media_len": 12345
    }
  ]
}
```

#### `POST /v1/manifest` → 200

Body: the client's manifest (same shape). Returns a diff (the JSON shape
produced by `slowclaw_feed_sync_diff`):

```json
{
  "to_pull": ["key_the_client_should_fetch"],
  "to_push": ["key_the_client_should_send"],
  "conflicts": [
    {
      "key": "...",
      "local_updated_at": "...",
      "remote_updated_at": "...",
      "winner": "local"
    }
  ]
}
```

`winner` is `"local"` (client has the newer copy; server should pull) or
`"remote"` (server has the newer copy; client should pull).

#### `GET /v1/entry?key=<key>` → 200

Returns one full journal entry as JSON (a `TransferEntry`):

```json
{
  "key": "slowclaw_user_key_1",
  "content": "journal text...",
  "category": "daily",
  "updated_at": "2026-08-09T14:39:15Z",
  "session_id": null,
  "source": "text",
  "media_url": "Recordings/journal_1234.m4a"
}
```

`404` if the key is absent on the server.

#### `GET /v1/media?path=<media_url>` → 200

Streams the audio file bytes for the given `media_url` (Documents-
relative path). `Content-Type: audio/m4a` for `.m4a` (the only format
the iOS recorder produces); other extensions use
`application/octet-stream`. Supports `Range` requests so the client can
resume a partial transfer of a large file. `404` if the file is absent.

#### `POST /v1/entry` → 200

Body: a single `TransferEntry` JSON object (same shape as
`GET /v1/entry`). The server applies it via
`slowclaw_feed_sync_apply_entries` (last-writer-wins). Returns `200`
with an empty body on success.

#### `POST /v1/media?path=<media_url>` → 200

Body: raw audio bytes. The server writes the file to its Documents tree
at the given relative path (creating parent dirs). Returns `200` empty
on success.

## Sync flow (client-driven)

```
  iOS client                                  Windows server
      │                                             │
      │  scan QR → {host, port, token}              │
      │                                             │
      │  GET  /v1/manifest                          │
      │ ─────────────────────────────────────────>  │
      │  <server manifest>                          │
      │ <─────────────────────────────────────────  │
      │                                             │
      │  POST /v1/manifest  (client manifest)       │
      │ ─────────────────────────────────────────>  │
      │  <diff: to_pull, to_push, conflicts>        │
      │ <─────────────────────────────────────────  │
      │                                             │
      │  for each key in to_pull (winner=remote):   │
      │    GET /v1/entry?key=...    → apply locally │
      │    GET /v1/media?path=...   → save file     │
      │ ─────────────────────────────────────────>  │
      │                                             │
      │  for each key in to_push (winner=local):    │
      │    POST /v1/entry   (full entry)            │
      │    POST /v1/media?path=... (file bytes)     │
      │ ─────────────────────────────────────────>  │
      │                                             │
      │  done — both sides now converge             │
```

The client re-runs the exchange until a diff returns empty `to_pull` and
`to_push`. Conflicts are resolved by `winner`; the losing side simply
fetches the winning copy (no merge).

## Deletion

**v1 does not propagate deletes.** A journal deleted on one device will
reappear on the next sync if the other device still has it. This is a
documented limitation; tombstones are a future non-breaking additive
migration. Out of scope for the MVP per AGENTS.md §3.2 (YAGNI).

## Security & privacy notes

- The token is regenerated per Sync session and never persisted.
- The listener binds to a specific LAN interface, not `0.0.0.0`, to avoid
  accidental exposure on other interfaces.
- Audio and journal content are the user's own data moving between the
  user's own two devices. No third-party ingestion, no cloud, no telemetry.
- Raw transcripts are never logged (AGENTS.md §3.6).
