# Workflow Bot Creation Skill

Use this skill to create or modify a workflow bot implemented as a cron-run script.

## Goal

- Build a script that reads context from the journal tree (`journals/...`).
- Produce feed outputs under the posts tree (`posts/...`).
- Keep selection behavior deterministic and configurable.

## Required Script Arguments

The script must accept:

- `--mode` with values `date_range` or `random`
- `--days` (used when `--mode date_range`)
- `--random-count` (used when `--mode random`)

Optional arguments can be added, but these core arguments must remain supported.

## Runtime Contract

- Script must run from the workspace root.
- Script should emit structured output (JSON or concise text) for observability.
- Script should avoid network-only assumptions unless explicitly requested.

## Safety Rules

- Keep all reads under the workspace journal paths.
- Keep all writes under `posts/` for feed-visible artifacts.
- Avoid command chaining and avoid introducing heavy dependencies.
- Keep changes focused and reversible.

## Output Types

A workflow bot may publish one or more of:

- Markdown/text
- Audio
- Video

## Structured Output Schema

Scripts must emit a single JSON object to stdout on completion:

```json
{
  "status": "ok",
  "files_written": ["posts/my_bot/2026-03-03-digest.md"],
  "message": "Generated 1 post from 5 journal entries"
}
```

Fields:

- `status` (required): `"ok"` on success, `"error"` on failure.
- `files_written` (required): Array of workspace-relative paths produced by this run. May be empty on error.
- `message` (required): Human-readable summary for observability logs.
- `error` (optional): Error detail string when `status` is `"error"`.

## Scheduling

Bot scheduling is managed by cron settings in the gateway/UI.
Do not hardcode schedule timing in script logic.
