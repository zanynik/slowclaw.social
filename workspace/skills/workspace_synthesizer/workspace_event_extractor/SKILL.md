# Workspace Event Extractor

Create one small typed JSON handoff file for the workspace synthesis pipeline.

## Output Contract

- Read from `journals/text/**` and available transcript text under `journals/text/transcriptions/**`.
- Write exactly one file: `posts/workspace_synthesizer/pipeline/events.json`.
- Overwrite that file completely with valid JSON.
- If there are no strong candidates, write an empty `items` array.
- Do not create final feed posts, todos, events, clip plan output files, or other handoff files.
- Do not emit markdown fences or prose outside the JSON file.

## Artifact Scope

- This extractor owns only `events`.
- Maximum items: 20
- Every item must include provenance rooted in workspace-relative journal paths.
- Use workspace-relative journal paths only.

## Artifact Rules

- This is a primary durable artifact path.
- Emit only items with a clear date, time, or scheduled plan.
- Do not invent timing or location details.

## Schema

### `posts/workspace_synthesizer/pipeline/events.json`
```json
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "title": "EventFile",
  "type": "object",
  "properties": {
    "items": {
      "type": "array",
      "default": [],
      "items": {
        "$ref": "#/$defs/EventCandidate"
      }
    },
    "version": {
      "type": "string",
      "default": "1"
    }
  },
  "$defs": {
    "EventCandidate": {
      "type": "object",
      "properties": {
        "allDay": {
          "type": "boolean",
          "default": false
        },
        "details": {
          "type": "string",
          "default": ""
        },
        "endAt": {
          "type": "string",
          "default": ""
        },
        "id": {
          "type": "string",
          "default": ""
        },
        "location": {
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
        "status": {
          "type": "string",
          "default": ""
        },
        "title": {
          "type": "string",
          "default": ""
        }
      }
    }
  }
}
```
