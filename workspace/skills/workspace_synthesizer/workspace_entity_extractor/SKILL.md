# Workspace Entity Extractor

Create one small typed JSON handoff file for the workspace synthesis pipeline.

## Output Contract

- Read from `journals/text/**` and available transcript text under `journals/text/transcriptions/**`.
- Write exactly one file: `posts/workspace_synthesizer/pipeline/primitives/entities.json`.
- Overwrite that file completely with valid JSON.
- If there are no strong candidates, write an empty `items` array.
- Do not create final feed posts, todos, events, clip plan output files, or other handoff files.
- Do not emit markdown fences or prose outside the JSON file.

## Artifact Scope

- This extractor owns only `entities`.
- Maximum items: 80
- Every item must include provenance rooted in workspace-relative journal paths.
- Use workspace-relative journal paths only.

## Artifact Rules

- Optional helper output only.
- Emit canonical nouns that matter, including people, projects, orgs, dates, and amounts when useful.
- Use `canonicalName` for the stable label and `aliases` for surface forms.
- Include provenance for every emitted entity.

## Schema

### `posts/workspace_synthesizer/pipeline/primitives/entities.json`
```json
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "title": "EntityFile",
  "type": "object",
  "properties": {
    "items": {
      "type": "array",
      "default": [],
      "items": {
        "$ref": "#/$defs/EntityCandidate"
      }
    },
    "version": {
      "type": "string",
      "default": "1"
    }
  },
  "$defs": {
    "EntityCandidate": {
      "type": "object",
      "properties": {
        "aliases": {
          "type": "array",
          "default": [],
          "items": {
            "type": "string"
          }
        },
        "attributes": {
          "default": null
        },
        "canonicalName": {
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
