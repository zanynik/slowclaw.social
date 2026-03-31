# Weekly Highlights

Use this content agent to fulfill the following goal:

> Turn my recent journal notes into polished weekly highlight posts for the workspace feed. Save each highlight as a separate file in posts/.

## Sources

- `journals/text/**`
- transcript files under `journals/text/transcriptions/**` when present

- `journals/media/audio/**` and `journals/media/video/**` when the goal depends on journal media

## Output

- `posts/weekly_highlights`

## Output Rules

- Write feed-visible artifacts only under `posts/weekly_highlights`.
- Hidden intermediates may go under `posts/weekly_highlights/pipeline/` or `posts/weekly_highlights/artifacts/`.
- If generating multiple distinct post candidates, save each as a separate file.
- Prefer built-in runtime tools for media and transcription tasks; do not hardcode scripts or shell pipelines when a built-in tool exists.
- Keep unrelated workspace files untouched.
