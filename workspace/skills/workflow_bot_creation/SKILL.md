# Content Agent Creation Skill

Use this skill to create or modify a content agent for the workspace feed.

## Product Model

- The user describes a goal, not tools or implementation details.
- The runtime executes the content agent from its `SKILL.md` using the tools available in the workspace runtime.
- The generated `SKILL.md` is the canonical agent definition.

## Fixed Inputs And Outputs

- Source scope is fixed:
  - `journals/text/**`
  - transcript files under `journals/text/transcriptions/**` when present
  - `journals/media/audio/**` and `journals/media/video/**` when the goal requires media-derived output
- Output scope is fixed:
  - `posts/<agent_key>/**`
- Do not read outside the workspace journal tree.
- Do not write outside `posts/`.

## What To Generate

You must generate and maintain the agent `SKILL.md`.

The `SKILL.md` should describe:

- the user goal in plain language
- the fixed source locations
- the fixed output destination under `posts/`
- whether hidden intermediates should live under `posts/<agent_key>/pipeline/`
- quality rules for outputs
- one-file-per-post behavior when multiple items are produced
- safety constraints such as avoiding unrelated file edits

Do not turn the `SKILL.md` into generic documentation. Keep it specific to the agent.

## Runtime Contract

- The content agent runs inside the workspace runtime with its normal tool access.
- Do not assume shell-script execution.
- Keep instructions dependency-light and reversible.
- The skill must be concrete enough that the runtime agent can execute it directly.

## Tooling Guidance

- Prefer the runtime's existing workspace-local tools for reading, searching, and writing files.
- Do not hardcode a separate tool catalog into generated agent files; rely on the runtime's actual available tools.
- If the goal can be satisfied with file reads, file writes, search, and existing journal content, keep it that simple.
- If the goal requires media-derived output, prefer built-in runtime media tools such as `transcribe_media`, `clean_audio`, `extract_audio_segment`, `render_text_card_video`, `stitch_images_with_audio`, and `compose_simple_clip`.
- Do not hardcode `python3`, `ffmpeg`, `ffprobe`, or `scripts/...` into generated content-agent skills.

## Output Types

A content agent may publish one or more of:

- Markdown/text
- Audio
- Video

If multiple distinct post candidates are generated, save each as a separate file.

## Scheduling

Scheduling is managed by the application, not by the generated files.
Do not hardcode schedule timing in script logic.
