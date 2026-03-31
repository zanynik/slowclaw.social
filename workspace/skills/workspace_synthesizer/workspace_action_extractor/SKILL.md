# Workspace Action Extractor

Create one small typed JSON handoff file for the workspace synthesis pipeline.

## Output Contract

- Read from `journals/text/**` and available transcript text under `journals/text/transcriptions/**`.
- Write exactly one file: `posts/workspace_synthesizer/pipeline/primitives/actions.json`.
- Overwrite that file completely with valid JSON.
- If there are no strong candidates, write an empty `items` array.
- Do not create final feed posts, todos, events, clip plan output files, or other handoff files.
- Do not emit markdown fences or prose outside the JSON file.

## Artifact Scope

- This extractor owns only `actions`.
- Maximum items: 30
- Every item must include provenance rooted in workspace-relative journal paths.
- Use workspace-relative journal paths only.

## Artifact Rules

- Optional helper output only.
- Emit explicit actions, commitments, follow-ups, or requests.
- Avoid vague aspirations unless the source makes the next step clear.
- These are durable planner inputs, not presentation-layer todos.

## Schema

### `posts/workspace_synthesizer/pipeline/primitives/actions.json`
```json
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "title": "ActionFile",
  "type": "object",
  "properties": {
    "items": {
      "type": "array",
      "default": [],
      "items": {
        "$ref": "#/$defs/ActionCandidate"
      }
    },
    "version": {
      "type": "string",
      "default": "1"
    }
  },
  "$defs": {
    "ActionCandidate": {
      "type": "object",
      "properties": {
        "details": {
          "type": "string",
          "default": ""
        },
        "dueAt": {
          "type": "string",
          "default": ""
        },
        "id": {
          "type": "string",
          "default": ""
        },
        "owner": {
          "type": "string",
          "default": ""
        },
        "priority": {
          "type": "string",
          "default": ""
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
        "relatedAssertionIds": {
          "type": "array",
          "default": [],
          "items": {
            "type": "string"
          }
        },
        "relatedEntities": {
          "type": "array",
          "default": [],
          "items": {
            "type": "string"
          }
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
