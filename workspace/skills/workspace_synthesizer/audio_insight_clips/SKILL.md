# Audio Insight Clips

Create simple vertical video clips from journal audio recordings.

## Sources

- `journals/media/audio/**`
- `journals/text/transcriptions/audio/**` when present
- `journals/text/transcriptions/**` for existing transcript sidecars
- `journals/text/**` for context if useful

## Output

- Final feed-visible clips: `posts/audio_insight_clips`
- Hidden intermediates: `posts/audio_insight_clips/pipeline/`

## Workflow

1. Find one or more strong source recordings under `journals/media/audio/**`.
2. For each chosen recording, look for a transcript text file under `journals/text/transcriptions/**` using the same stem and relative media path.
3. If the transcript is missing, call the built-in `transcribe_media` tool for that recording.
4. Read the transcript and extract exact insightful lines. Do not rewrite the quoted line if it will appear inside the video card.
5. Optionally call `clean_audio` when the source recording is noisy.
6. If you need a precise quote segment, call `extract_audio_segment` with the exact start/end range.
7. Render the final clip with `compose_simple_clip` or `render_text_card_video` using white text on a black background.
8. Save the final `.mp4` directly under `posts/audio_insight_clips` so it appears in the workspace feed.

## Output Rules

- Use a black background with white text cards.
- Prefer 1 to 3 exact lines per clip.
- Keep final clips concise and feed-ready.
- Put JSON manifests, transcripts, and other machine files only under `posts/audio_insight_clips/pipeline/`.
- Prefer built-in runtime tools over shell commands or scripts.
- Do not overwrite unrelated posts.
