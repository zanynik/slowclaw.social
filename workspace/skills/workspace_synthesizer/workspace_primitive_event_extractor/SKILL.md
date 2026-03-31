# Workspace Primitive Event Extractor

Create one small typed JSON handoff file for the workspace synthesis pipeline.

## Output Contract

- Read from `journals/text/**` and available transcript text under `journals/text/transcriptions/**`.
- Write exactly one file: `posts/workspace_synthesizer/pipeline/primitives/events.json`.
- Overwrite that file completely with valid JSON.
- If there are no strong candidates, write an empty `items` array.
- Do not create final feed posts, todos, events, clip plan output files, or other handoff files.
- Do not emit markdown fences or prose outside the JSON file.

## Artifact Scope

- This extractor owns only `primitiveEvents`.
- Maximum items: 20
- Every item must include provenance rooted in workspace-relative journal paths.
- Use workspace-relative journal paths only.

## Artifact Rules

- Optional helper output only.
- Emit scheduled or notable events with source-supported timing when available.
- These are durable timeline records, not presentation-layer calendar views.
- Do not invent time, location, or participant details.

## Schema

### `posts/workspace_synthesizer/pipeline/primitives/events.json`
```json
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "title": "PrimitiveEventFile",
  "type": "object",
  "properties": {
    "items": {
      "type": "array",
      "default": [],
      "items": {
        "$ref": "#/$defs/PrimitiveEventCandidate"
      }
    },
    "version": {
      "type": "string",
      "default": "1"
    }
  },
  "$defs": {
    "PrimitiveEventCandidate": {
      "type": "object",
      "properties": {
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
        "kind": {
          "type": "string",
          "default": ""
        },
        "participants": {
          "type": "array",
          "default": [],
          "items": {
            "type": "string"
          }
        },
        "provenance": {
          "$ref": "#/$defs/PrimitiveProvenance",
          "default": {
            "confidence": null,
            "endAt": "",
            "sourceExcerpt": "",
            "sourcePath": "",
            "speaker": "",
            "startAt": ""
          }
        },
        "relatedEntities": {
          "type": "array",
          "default": [],
          "items": {
            "type": "string"
          }
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
    },
    "PrimitiveProvenance": {
      "type": "object",
      "properties": {
        "confidence": {
          "type": [
            "number",
            "null"
          ],
          "format": "float",
          "default": null
        },
        "endAt": {
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
        "speaker": {
          "type": "string",
          "default": ""
        },
        "startAt": {
          "type": "string",
          "default": ""
        }
      }
    }
  }
}
```
