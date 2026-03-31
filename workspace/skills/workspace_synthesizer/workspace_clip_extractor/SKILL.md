# Workspace Clip Extractor

Create one small typed JSON handoff file for the workspace synthesis pipeline.

## Output Contract

- Read from `journals/text/**` and available transcript text under `journals/text/transcriptions/**`.
- Write exactly one file: `posts/workspace_synthesizer/pipeline/clip_plans.json`.
- Overwrite that file completely with valid JSON.
- If there are no strong candidates, write an empty `items` array.
- Do not create final feed posts, todos, events, clip plan output files, or other handoff files.
- Do not emit markdown fences or prose outside the JSON file.

## Artifact Scope

- This extractor owns only `clipPlans`.
- Maximum items: 12
- Every item must include provenance rooted in workspace-relative journal paths.
- Use workspace-relative journal paths only.

## Artifact Rules

- This is a primary durable artifact path.
- Emit only transcript-backed segments from audio/video transcript sidecars under journals/text/transcriptions/** or journals/text/transcript/**.
- Prefer precise `startAt` and `endAt` values from transcript context when available.

## Schema

### `posts/workspace_synthesizer/pipeline/clip_plans.json`
```json
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "title": "ClipPlanFile",
  "type": "object",
  "properties": {
    "items": {
      "type": "array",
      "default": [],
      "items": {
        "$ref": "#/$defs/ClipPlanCandidate"
      }
    },
    "version": {
      "type": "string",
      "default": "1"
    }
  },
  "$defs": {
    "ClipPlanCandidate": {
      "type": "object",
      "properties": {
        "endAt": {
          "type": "string",
          "default": ""
        },
        "id": {
          "type": "string",
          "default": ""
        },
        "notes": {
          "type": "string",
          "default": ""
        },
        "sourceExcerpt": {
          "type": "string",
          "default": ""
        },
        "sourcePath": {
          "type": "string",
          "default": ""
        },
        "startAt": {
          "type": "string",
          "default": ""
        },
        "title": {
          "type": "string",
          "default": ""
        },
        "transcriptQuote": {
          "type": "string",
          "default": ""
        }
      }
    }
  }
}
```
