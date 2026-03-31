# Long-Form Article Synthesizer

Create or refine clean long-form articles that accumulate over time from journal notes.

## Output Contract

- Read from `journals/text/**`, available transcript text under `journals/text/transcriptions/**`, and existing article drafts under `posts/articles/**`.
- Write exactly one JSON handoff file: `posts/articles/pipeline/article_updates.json`.
- Rust will validate the handoff and materialize visible markdown files under `posts/articles/`.
- Do not write visible article markdown files directly.
- Hidden metadata lives under `posts/articles/pipeline`.

## Decision Rules

- Decide whether an existing article should be refined or whether a new article should be created.
- For `rewriteArticle`, use the exact `expectedHash` supplied in the run prompt inventory for the target file.
- For `createArticle`, choose a new `targetPath` under `posts/articles/`.
- Keep articles focused, durable, and readable as standalone long-form pieces.
- `bodyMarkdown` must exclude the top-level `# Title` heading because Rust writes that heading.
- Every item must include at least one `sourcePath` rooted under `journals/`.
- If nothing is worth updating, write an empty `items` array.

## Schema

### `posts/articles/pipeline/article_updates.json`
```json
{
  "$schema": "https://json-schema.org/draft/2020-12/schema",
  "title": "ArticleUpdateFile",
  "type": "object",
  "properties": {
    "items": {
      "type": "array",
      "default": [],
      "items": {
        "$ref": "#/$defs/ArticleUpdateItem"
      }
    },
    "runSummary": {
      "$ref": "#/$defs/ArticleRunSummary",
      "default": {
        "notes": ""
      }
    },
    "version": {
      "type": "string",
      "default": "1"
    }
  },
  "$defs": {
    "ArticleRunSummary": {
      "type": "object",
      "properties": {
        "notes": {
          "type": "string",
          "default": ""
        }
      }
    },
    "ArticleUpdateItem": {
      "type": "object",
      "properties": {
        "bodyMarkdown": {
          "type": "string",
          "default": ""
        },
        "expectedHash": {
          "type": "string",
          "default": ""
        },
        "operation": {
          "$ref": "#/$defs/ArticleUpdateOperation",
          "default": "createArticle"
        },
        "sourcePaths": {
          "type": "array",
          "default": [],
          "items": {
            "type": "string"
          }
        },
        "summary": {
          "type": "string",
          "default": ""
        },
        "targetPath": {
          "type": "string",
          "default": ""
        },
        "title": {
          "type": "string",
          "default": ""
        }
      }
    },
    "ArticleUpdateOperation": {
      "type": "string",
      "enum": [
        "createArticle",
        "rewriteArticle"
      ]
    }
  }
}
```
