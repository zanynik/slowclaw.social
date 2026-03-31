# Workspace Assertion Extractor

Create one small typed JSON handoff file for the workspace synthesis pipeline.

## Output Contract

- Read from `journals/text/**` and available transcript text under `journals/text/transcriptions/**`.
- Write exactly one file: `posts/workspace_synthesizer/pipeline/primitives/assertions.json`.
- Overwrite that file completely with valid JSON.
- If there are no strong candidates, write an empty `items` array.
- Do not create final feed posts, todos, events, clip plan output files, or other handoff files.
- Do not emit markdown fences or prose outside the JSON file.

## Artifact Scope

- This extractor owns only `assertions`.
- Maximum items: 60
- Every item must include provenance rooted in workspace-relative journal paths.
- Use workspace-relative journal paths only.

## Artifact Rules

- Optional helper output only.
- Emit explicit claims, opinions, beliefs, questions, or decisions.
- Prefer precise text over paraphrased abstractions when possible.
- Include related entity and event ids when the linkage is clear from the source.

## Schema

### `posts/workspace_synthesizer/pipeline/primitives/assertions.json`
```json
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "title": "AssertionFile",
  "type": "object",
  "properties": {
    "items": {
      "type": "array",
      "default": [],
      "items": {
        "$ref": "#/$defs/AssertionCandidate"
      }
    },
    "version": {
      "type": "string",
      "default": "1"
    }
  },
  "$defs": {
    "AssertionCandidate": {
      "type": "object",
      "properties": {
        "id": {
          "type": "string",
          "default": ""
        },
        "kind": {
          "type": "string",
          "default": ""
        },
        "polarity": {
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
        "relatedEntities": {
          "type": "array",
          "default": [],
          "items": {
            "type": "string"
          }
        },
        "relatedEventIds": {
          "type": "array",
          "default": [],
          "items": {
            "type": "string"
          }
        },
        "speaker": {
          "type": "string",
          "default": ""
        },
        "status": {
          "type": "string",
          "default": ""
        },
        "text": {
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
