# Workspace Todo Extractor

Create one small typed JSON handoff file for the workspace synthesis pipeline.

## Output Contract

- Read from `journals/text/**` and available transcript text under `journals/text/transcriptions/**`.
- Write exactly one file: `posts/workspace_synthesizer/pipeline/todos.json`.
- Overwrite that file completely with valid JSON.
- If there are no strong candidates, write an empty `items` array.
- Do not create final feed posts, todos, events, clip plan output files, or other handoff files.
- Do not emit markdown fences or prose outside the JSON file.

## Artifact Scope

- This extractor owns only `todos`.
- Maximum items: 30
- Every item must include provenance rooted in workspace-relative journal paths.
- Use workspace-relative journal paths only.

## Artifact Rules

- This is a primary durable artifact path.
- Emit only explicit next actions, tasks, or commitments.
- Prefer stable titles and put nuance in `details`.

## Schema

### `posts/workspace_synthesizer/pipeline/todos.json`
```json
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "title": "TodoFile",
  "type": "object",
  "properties": {
    "items": {
      "type": "array",
      "default": [],
      "items": {
        "$ref": "#/$defs/TodoCandidate"
      }
    },
    "version": {
      "type": "string",
      "default": "1"
    }
  },
  "$defs": {
    "TodoCandidate": {
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
        "priority": {
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
