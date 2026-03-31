# Workspace Journal Title Extractor

Create one small typed JSON handoff file for the workspace synthesis pipeline.

## Output Contract

- Read from `journals/text/**` and available transcript text under `journals/text/transcriptions/**`.
- Write exactly one file: `posts/workspace_synthesizer/pipeline/journal_titles.json`.
- Overwrite that file completely with valid JSON.
- If there are no strong candidates, write an empty `items` array.
- Do not create final feed posts, todos, events, clip plan output files, or other handoff files.
- Do not emit markdown fences or prose outside the JSON file.

## Artifact Scope

- This extractor owns only `journalTitles`.
- Maximum items: 8
- Every item must include provenance rooted in workspace-relative journal paths.
- Use workspace-relative journal paths only.

## Artifact Rules

- Emit titles only for real journal note files under `journals/text/`.
- Do not retitle transcript sidecars under `journals/text/transcriptions/**`.
- Titles should be concise, durable, and free of dates, numbering, markdown markers, or file extensions.

## Schema

### `posts/workspace_synthesizer/pipeline/journal_titles.json`
```json
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "title": "JournalTitleFile",
  "type": "object",
  "properties": {
    "items": {
      "type": "array",
      "default": [],
      "items": {
        "$ref": "#/$defs/JournalTitleCandidate"
      }
    },
    "version": {
      "type": "string",
      "default": "1"
    }
  },
  "$defs": {
    "JournalTitleCandidate": {
      "type": "object",
      "properties": {
        "sourcePath": {
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
