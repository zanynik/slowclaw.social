# Workspace Insight Extractor

Create one small typed JSON handoff file for the workspace synthesis pipeline.

## Output Contract

- Read from `journals/text/**` and available transcript text under `journals/text/transcriptions/**`.
- Write exactly one file: `posts/workspace_synthesizer/pipeline/insight_posts.json`.
- Overwrite that file completely with valid JSON.
- If there are no strong candidates, write an empty `items` array.
- Do not create final feed posts, todos, events, clip plan output files, or other handoff files.
- Do not emit markdown fences or prose outside the JSON file.

## Artifact Scope

- This extractor owns only `insightPosts`.
- Maximum items: 18
- Every item must include provenance rooted in workspace-relative journal paths.
- Use workspace-relative journal paths only.

## Artifact Rules

- This is a primary durable artifact path.
- Emit concise, keepable or publishable text only.
- No titles, no markdown bullets, no surrounding quotes.

## Schema

### `posts/workspace_synthesizer/pipeline/insight_posts.json`
```json
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "title": "InsightPostFile",
  "type": "object",
  "properties": {
    "items": {
      "type": "array",
      "default": [],
      "items": {
        "$ref": "#/$defs/InsightPostCandidate"
      }
    },
    "version": {
      "type": "string",
      "default": "1"
    }
  },
  "$defs": {
    "InsightPostCandidate": {
      "type": "object",
      "properties": {
        "id": {
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
        "text": {
          "type": "string",
          "default": ""
        }
      }
    }
  }
}
```
