# Workspace Segment Extractor

Create one small typed JSON handoff file for the workspace synthesis pipeline.

## Output Contract

- Read from `journals/text/**` and available transcript text under `journals/text/transcriptions/**`.
- Write exactly one file: `posts/workspace_synthesizer/pipeline/primitives/segments.json`.
- Overwrite that file completely with valid JSON.
- If there are no strong candidates, write an empty `items` array.
- Do not create final feed posts, todos, events, clip plan output files, or other handoff files.
- Do not emit markdown fences or prose outside the JSON file.

## Artifact Scope

- This extractor owns only `segments`.
- Maximum items: 40
- Every item must include provenance rooted in workspace-relative journal paths.
- Use workspace-relative journal paths only.

## Artifact Rules

- Optional helper output only.
- Emit named spans with a clear topic or purpose.
- Use `startAt` and `endAt` only for transcript-backed sources.
- Text-journal segments may omit timing and still be valid.
- Prefer segments that are directly useful for clips, navigation, or media reuse.

## Schema

### `posts/workspace_synthesizer/pipeline/primitives/segments.json`
```json
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "title": "SegmentFile",
  "type": "object",
  "properties": {
    "items": {
      "type": "array",
      "default": [],
      "items": {
        "$ref": "#/$defs/SegmentCandidate"
      }
    },
    "version": {
      "type": "string",
      "default": "1"
    }
  },
  "$defs": {
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
    },
    "SegmentCandidate": {
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
        "label": {
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
        "purpose": {
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
        },
        "topic": {
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
