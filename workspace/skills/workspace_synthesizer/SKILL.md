# Workspace Synthesizer

This is the index skill for workspace synthesis.

The runtime uses this skill as the shared guidance layer, then runs specialized extractor skills that primarily produce durable app artifacts:
- Primary artifact files: `posts/workspace_synthesizer/pipeline/insight_posts.json`, `posts/workspace_synthesizer/pipeline/todos.json`, `posts/workspace_synthesizer/pipeline/events.json`, `posts/workspace_synthesizer/pipeline/clip_plans.json`, `posts/workspace_synthesizer/pipeline/journal_titles.json`

- Optional helper primitive files when explicitly enabled:
- `workspace_entity_extractor` -> `posts/workspace_synthesizer/pipeline/primitives/entities.json`
- `workspace_action_extractor` -> `posts/workspace_synthesizer/pipeline/primitives/actions.json`
- `workspace_primitive_event_extractor` -> `posts/workspace_synthesizer/pipeline/primitives/events.json`
- `workspace_assertion_extractor` -> `posts/workspace_synthesizer/pipeline/primitives/assertions.json`
- `workspace_segment_extractor` -> `posts/workspace_synthesizer/pipeline/primitives/segments.json`

Primary workflow keys:
- `workspace_insight_extractor`
- `workspace_todo_extractor`
- `workspace_event_extractor`
- `workspace_clip_extractor`
- `workspace_journal_title_extractor`

## Role

- Read from `journals/text/**` and available transcript text under `journals/text/transcriptions/**`.
- Act as the global policy layer for all workspace extraction.
- Durable app artifacts are the primary product output.
- Primitive handoffs are optional helper artifacts, not the default product memory layer.
- The Rust runtime decides which extractor skills to run, validates each handoff file independently, and can compile missing app outputs from primitive files when those helper files are present.
- Extractor skills, not this index skill alone, own the small typed JSON outputs.

## Shared Guardrails

- Prefer fewer, higher-signal artifacts over exhaustive extraction.
- Every emitted item must include source provenance.
- Use workspace-relative journal paths only.
- Do not create final feed posts, todos, events, or clip plan output files directly.
- Desktop and mobile must both be supported. Clip rendering may be unavailable, but clip planning is still allowed.

## Primary Artifact Policy

- `insightPosts`: concise, keepable or publishable text artifacts under `posts/`.
- `todos`: planner tasks that persist in the workspace database.
- `events`: planner events that persist in the workspace database.
- `clipPlans`: transcript-backed editing plans and clip artifacts.
- `journalTitles`: operational file-improvement output.

## Optional Helper Policy

- `segments`: useful when timestamps unlock deterministic media editing.
- `actions` and `primitiveEvents`: useful when primary planner outputs are not emitted directly.
- `assertions`, `entities`, and `structures`: optional helper context only; do not treat them as the default persisted product layer.

## Runtime Notes

- App-shaped handoffs remain the primary path.
- Primitive helper handoffs are optional and disabled by default to keep runs cheaper.
- Rust materializes final outputs and keeps planner data out of the feed.
- Partial success is allowed: one extractor can fail without discarding the others.
