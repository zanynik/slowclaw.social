# Bluesky Insight Posts

Use this content agent to fulfill the following goal:

> Create interesting Bluesky post drafts from my recent journal notes. Extract standout insights and save each post as a separate file in posts/ so it appears in the workspace feed.

## Sources

- `journals/text/**`
- transcript files under `journals/text/transcriptions/**` when present

- `journals/media/audio/**` and `journals/media/video/**` when the goal depends on journal media

## Output

- `posts/bluesky_insight_posts`

## Output Rules

- Write feed-visible artifacts only under `posts/bluesky_insight_posts`.
- Hidden intermediates may go under `posts/bluesky_insight_posts/pipeline/` or `posts/bluesky_insight_posts/artifacts/`.
- If generating multiple distinct post candidates, save each as a separate file.
- Prefer built-in runtime tools for media and transcription tasks; do not hardcode scripts or shell pipelines when a built-in tool exists.
- Keep unrelated workspace files untouched.
