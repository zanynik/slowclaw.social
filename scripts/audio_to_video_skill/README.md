# Audio To Video Skill (Workspace Processor)

This folder vendors the minimum files from your `audio_to_video` project needed to run `audio_to_video2.py`:

- `audio_to_video.py`
- `audio_to_video2.py`
- `slowclaw_audio_to_video_job.py` (SlowClaw wrapper that updates PocketBase metadata)

## Important

- `audio_to_video2.py` depends on external tools (`ffmpeg`, `ffprobe`, `gemini`, `pocket-tts`) and Python packages (plus optional local `.vendor*` wheels).
- For `workspace-script` execution, copy this folder into your active SlowClaw workspace (because `workspace-script` only runs inside the workspace).

## Suggested workspace location

Copy to:

- `~/ .zeroclaw/workspace/scripts/audio_to_video_skill` (without the space; shown split here only to avoid auto-link confusion)

Example:

```bash
mkdir -p ~/.zeroclaw/workspace/scripts
cp -R /Users/nikhil/.gemini/antigravity/scratch/zeroclaw_modify/scripts/audio_to_video_skill \
  ~/.zeroclaw/workspace/scripts/
chmod +x ~/.zeroclaw/workspace/scripts/audio_to_video_skill/slowclaw_audio_to_video_job.py
```

## Run manually (from workspace)

```bash
cd ~/.zeroclaw/workspace
python3 scripts/audio_to_video_skill/slowclaw_audio_to_video_job.py \
  journals/media/audio/2026/02/26/123000_my_note.m4a
```

## Example cron usage (one-shot)

```bash
slowclaw cron once 1m "workspace-script scripts/audio_to_video_skill/slowclaw_audio_to_video_job.py journals/media/audio/2026/02/26/123000_my_note.m4a"
```

The wrapper:

- runs `audio_to_video2.py`
- stores full processing artifacts under `journals/pipeline/audio_to_video/...`
- publishes final media for app feed under `journals/processed/...`
- writes `artifacts` records to PocketBase (including published outputs)
- patches `media_assets` status (if `--asset-id` is provided)
