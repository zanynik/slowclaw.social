# Audio To Video Processor

Use this skill when the user asks to convert/process an audio journal into video outputs.

## Purpose

- Process a workspace audio file with the audio-to-video pipeline.
- Keep all processing inside the workspace.
- Return deterministic execution output and any produced artifact info.

## Required Tool

- `audio_to_video`

## When To Use

- User asks to convert an audio file into a video.
- User asks to run the `audio_to_video2.py` workflow on a workspace audio recording.
- User asks to reprocess an existing audio asset from `journals/media/audio/...`.

## Inputs

- `audio_path` (required): workspace-relative path to the audio file.
- `asset_id` (optional): `media_assets` id to patch status metadata.
- `gemini_model` (optional): model override for the wrapper script.
- `python_bin` (optional): interpreter, default `python3`.

## Execution Pattern

1. Validate the user-provided audio path is workspace-relative.
2. Call `audio_to_video` with `audio_path`.
3. If metadata linkage exists, include `asset_id`.
4. Report success/failure with concise summary and key output lines.

## Notes

- The wrapper script path is expected at:
  - `scripts/audio_to_video_skill/slowclaw_audio_to_video_job.py` (inside workspace)
- Storage policy:
  - Full pipeline/intermediate artifacts: `journals/pipeline/audio_to_video/...`
  - Feed-visible final outputs: `journals/processed/...`
  - Sidecar editable captions: `<media-file>.caption.txt` next to published media
- If the script is missing, tell the user to copy:
  - `/Users/nikhil/.gemini/antigravity/scratch/zeroclaw_modify/scripts/audio_to_video_skill`
  into:
  - `/Users/nikhil/.zeroclaw/workspace/scripts/audio_to_video_skill`
