use anyhow::{Context, Result};
use schemars::{schema_for, JsonSchema};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::collections::HashSet;
use std::fs;
use std::path::{Path, PathBuf};

use crate::util::truncate_with_ellipsis;

pub const ARTICLE_SYNTHESIZER_WORKFLOW_KEY: &str = "article_synthesizer";
pub const ARTICLE_OUTPUT_ROOT: &str = "posts/articles";
pub const ARTICLE_PIPELINE_DIR: &str = "posts/articles/pipeline";
pub const ARTICLE_HANDOFF_PATH: &str = "posts/articles/pipeline/article_updates.json";
pub const ARTICLE_METADATA_DIR: &str = "posts/articles/pipeline/metadata";

const MAX_ARTICLE_UPDATES: usize = 4;

#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema, Default)]
#[serde(rename_all = "camelCase")]
pub struct ArticleUpdateFile {
    #[serde(default = "file_version")]
    pub version: String,
    #[serde(default)]
    pub items: Vec<ArticleUpdateItem>,
    #[serde(default)]
    pub run_summary: ArticleRunSummary,
}

#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema, Default)]
#[serde(rename_all = "camelCase")]
pub struct ArticleRunSummary {
    #[serde(default)]
    pub notes: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema, PartialEq, Eq, Default)]
#[serde(rename_all = "camelCase")]
pub enum ArticleUpdateOperation {
    #[default]
    CreateArticle,
    RewriteArticle,
}

#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema, Default)]
#[serde(rename_all = "camelCase")]
pub struct ArticleUpdateItem {
    #[serde(default)]
    pub operation: ArticleUpdateOperation,
    #[serde(default)]
    pub target_path: String,
    #[serde(default)]
    pub expected_hash: String,
    #[serde(default)]
    pub title: String,
    #[serde(default)]
    pub summary: String,
    #[serde(default)]
    pub source_paths: Vec<String>,
    #[serde(default)]
    pub body_markdown: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
struct ArticleMetadataFile {
    #[serde(default = "file_version")]
    version: String,
    #[serde(default)]
    title: String,
    #[serde(default)]
    summary: String,
    #[serde(default)]
    source_paths: Vec<String>,
    #[serde(default)]
    updated_at: String,
    #[serde(default)]
    content_hash: String,
}

#[derive(Debug, Clone, Default)]
pub struct ArticleInventoryItem {
    pub path: String,
    pub title: String,
    pub content_hash: String,
    pub summary: String,
    pub source_paths: Vec<String>,
}

#[derive(Debug, Clone, Default)]
pub struct ArticleApplyResult {
    pub written_paths: Vec<String>,
    pub created_count: usize,
    pub updated_count: usize,
    pub applied_any: bool,
    pub had_errors: bool,
    pub summary: String,
}

fn file_version() -> String {
    "1".to_string()
}

pub fn handoff_path(workspace_dir: &Path) -> PathBuf {
    workspace_dir.join(ARTICLE_HANDOFF_PATH)
}

fn metadata_root(workspace_dir: &Path) -> PathBuf {
    workspace_dir.join(ARTICLE_METADATA_DIR)
}

fn article_hash(raw: &str) -> String {
    let digest = Sha256::digest(raw.as_bytes());
    hex::encode(&digest[..8])
}

fn title_from_path(path: &str) -> String {
    path.rsplit('/')
        .next()
        .unwrap_or("article")
        .trim_end_matches(".md")
        .replace(['_', '-'], " ")
}

fn detect_title_from_markdown(raw: &str, fallback_path: &str) -> String {
    for line in raw.lines() {
        let trimmed = line.trim();
        if let Some(rest) = trimmed.strip_prefix("# ") {
            let title = truncate_with_ellipsis(rest.trim(), 120);
            if !title.is_empty() {
                return title;
            }
        }
    }
    truncate_with_ellipsis(title_from_path(fallback_path).trim(), 120)
}

fn normalize_article_target_path(raw: &str) -> Result<String> {
    let normalized = raw.trim().trim_start_matches('/').replace('\\', "/");
    if normalized.is_empty() {
        anyhow::bail!("article items require targetPath");
    }
    if normalized.contains("..") {
        anyhow::bail!("targetPath must stay inside posts/articles/");
    }
    if !normalized.starts_with("posts/articles/") {
        anyhow::bail!("targetPath must point into posts/articles/");
    }
    if normalized.contains("/pipeline/") || normalized.ends_with("/pipeline") {
        anyhow::bail!("targetPath cannot point into the hidden pipeline directory");
    }
    if !normalized.ends_with(".md") {
        anyhow::bail!("targetPath must end with .md");
    }
    Ok(normalized)
}

fn normalize_source_path(raw: &str) -> Result<String> {
    let normalized = raw.trim().trim_start_matches('/').replace('\\', "/");
    if normalized.is_empty() {
        anyhow::bail!("sourcePaths entries must be non-empty");
    }
    if normalized.contains("..") {
        anyhow::bail!("sourcePaths must stay inside journals/");
    }
    if !normalized.starts_with("journals/") {
        anyhow::bail!("sourcePaths entries must point into journals/");
    }
    Ok(normalized)
}

fn strip_leading_h1(body_markdown: &str) -> String {
    let trimmed = body_markdown.trim();
    if !trimmed.starts_with("# ") {
        return trimmed.to_string();
    }
    let mut lines = trimmed.lines();
    let _ = lines.next();
    lines.collect::<Vec<_>>().join("\n").trim().to_string()
}

fn render_article_markdown(title: &str, body_markdown: &str) -> String {
    let title = truncate_with_ellipsis(title.trim(), 120);
    let body = strip_leading_h1(body_markdown);
    if body.is_empty() {
        format!("# {title}\n")
    } else {
        format!("# {title}\n\n{}\n", body.trim())
    }
}

fn metadata_path_for_article(workspace_dir: &Path, article_path: &str) -> Result<PathBuf> {
    let rel = article_path
        .trim()
        .trim_start_matches('/')
        .strip_prefix("posts/articles/")
        .context("article path must live under posts/articles/")?;
    Ok(metadata_root(workspace_dir).join(rel).with_extension("json"))
}

fn load_article_metadata(workspace_dir: &Path, article_path: &str) -> Option<ArticleMetadataFile> {
    let path = metadata_path_for_article(workspace_dir, article_path).ok()?;
    let raw = fs::read_to_string(path).ok()?;
    let mut metadata: ArticleMetadataFile = serde_json::from_str(&raw).ok()?;
    if metadata.version.trim().is_empty() {
        metadata.version = file_version();
    }
    Some(metadata)
}

fn write_article_metadata(
    workspace_dir: &Path,
    article_path: &str,
    metadata: &ArticleMetadataFile,
) -> Result<()> {
    let path = metadata_path_for_article(workspace_dir, article_path)?;
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)
            .with_context(|| format!("failed to create {}", parent.display()))?;
    }
    let raw = serde_json::to_string_pretty(metadata)?;
    fs::write(&path, raw).with_context(|| format!("failed to write {}", path.display()))?;
    Ok(())
}

fn collect_article_paths(dir: &Path, workspace_dir: &Path, out: &mut Vec<String>) -> Result<()> {
    let entries =
        fs::read_dir(dir).with_context(|| format!("failed to read {}", dir.display()))?;
    for entry in entries {
        let entry = entry?;
        let path = entry.path();
        let file_type = entry.file_type()?;
        if file_type.is_dir() {
            let rel = path
                .strip_prefix(workspace_dir)
                .unwrap_or(&path)
                .to_string_lossy()
                .replace('\\', "/");
            if rel == ARTICLE_PIPELINE_DIR || rel.contains("/pipeline/") {
                continue;
            }
            collect_article_paths(&path, workspace_dir, out)?;
            continue;
        }
        if !file_type.is_file() {
            continue;
        }
        if path.extension().and_then(|value| value.to_str()) != Some("md") {
            continue;
        }
        let rel = path
            .strip_prefix(workspace_dir)
            .unwrap_or(&path)
            .to_string_lossy()
            .replace('\\', "/");
        out.push(rel);
    }
    Ok(())
}

pub fn article_inventory(workspace_dir: &Path) -> Result<Vec<ArticleInventoryItem>> {
    let output_root = workspace_dir.join(ARTICLE_OUTPUT_ROOT);
    if !output_root.exists() {
        return Ok(Vec::new());
    }
    let mut paths = Vec::new();
    collect_article_paths(&output_root, workspace_dir, &mut paths)?;
    paths.sort();

    let mut out = Vec::with_capacity(paths.len());
    for rel_path in paths {
        let abs_path = workspace_dir.join(&rel_path);
        let raw = fs::read_to_string(&abs_path)
            .with_context(|| format!("failed to read {}", abs_path.display()))?;
        let metadata = load_article_metadata(workspace_dir, &rel_path);
        out.push(ArticleInventoryItem {
            path: rel_path.clone(),
            title: metadata
                .as_ref()
                .map(|item| item.title.clone())
                .filter(|value| !value.trim().is_empty())
                .unwrap_or_else(|| detect_title_from_markdown(&raw, &rel_path)),
            content_hash: article_hash(&raw),
            summary: metadata
                .as_ref()
                .map(|item| truncate_with_ellipsis(item.summary.trim(), 240))
                .unwrap_or_default(),
            source_paths: metadata
                .map(|item| item.source_paths)
                .unwrap_or_default(),
        });
    }
    Ok(out)
}

pub fn article_inventory_markdown(workspace_dir: &Path) -> String {
    match article_inventory(workspace_dir) {
        Ok(items) if items.is_empty() => "- No existing long-form articles yet.".to_string(),
        Ok(items) => items
            .into_iter()
            .map(|item| {
                let sources = if item.source_paths.is_empty() {
                    "none".to_string()
                } else {
                    item.source_paths.join(", ")
                };
                let summary = if item.summary.trim().is_empty() {
                    String::new()
                } else {
                    format!(" | summary=\"{}\"", item.summary.replace('"', "'"))
                };
                format!(
                    "- `{}` | title=\"{}\" | hash=`{}` | sources={}{}",
                    item.path,
                    item.title.replace('"', "'"),
                    item.content_hash,
                    sources,
                    summary
                )
            })
            .collect::<Vec<_>>()
            .join("\n"),
        Err(err) => format!(
            "- Article inventory unavailable: {}",
            truncate_with_ellipsis(&format!("{err:#}"), 240)
        ),
    }
}

pub fn reset_handoff_file(workspace_dir: &Path) -> Result<()> {
    match fs::remove_file(handoff_path(workspace_dir)) {
        Ok(()) => Ok(()),
        Err(err) if err.kind() == std::io::ErrorKind::NotFound => Ok(()),
        Err(err) => Err(err).with_context(|| format!("failed to clear {}", ARTICLE_HANDOFF_PATH)),
    }
}

fn normalize_update_file(mut file: ArticleUpdateFile) -> Result<ArticleUpdateFile> {
    if file.version.trim().is_empty() {
        file.version = file_version();
    }
    if file.version != "1" {
        anyhow::bail!("unsupported article update version `{}`", file.version);
    }
    file.run_summary.notes = truncate_with_ellipsis(file.run_summary.notes.trim(), 800);
    if file.items.len() > MAX_ARTICLE_UPDATES {
        file.items.truncate(MAX_ARTICLE_UPDATES);
    }
    let mut seen_paths = HashSet::new();
    for item in &mut file.items {
        item.target_path = normalize_article_target_path(&item.target_path)?;
        item.title = truncate_with_ellipsis(item.title.trim(), 120);
        item.summary = truncate_with_ellipsis(item.summary.trim(), 400);
        item.body_markdown = truncate_with_ellipsis(item.body_markdown.trim(), 32_000);
        if item.title.is_empty() {
            anyhow::bail!("article items require non-empty title");
        }
        if item.body_markdown.is_empty() {
            anyhow::bail!("article items require non-empty bodyMarkdown");
        }
        if !seen_paths.insert(item.target_path.clone()) {
            anyhow::bail!("article handoff cannot contain duplicate targetPath entries");
        }
        let mut normalized_sources = Vec::new();
        let mut seen_sources = HashSet::new();
        for source_path in &item.source_paths {
            let normalized = normalize_source_path(source_path)?;
            if seen_sources.insert(normalized.clone()) {
                normalized_sources.push(normalized);
            }
        }
        if normalized_sources.is_empty() {
            anyhow::bail!("article items require at least one journal source path");
        }
        item.source_paths = normalized_sources;
        item.expected_hash = item.expected_hash.trim().to_ascii_lowercase();
        match item.operation {
            ArticleUpdateOperation::CreateArticle => {
                item.expected_hash.clear();
            }
            ArticleUpdateOperation::RewriteArticle => {
                if item.expected_hash.is_empty() {
                    anyhow::bail!("rewriteArticle items require expectedHash");
                }
            }
        }
    }
    Ok(file)
}

fn load_update_file(workspace_dir: &Path) -> Result<ArticleUpdateFile> {
    let path = handoff_path(workspace_dir);
    let raw =
        fs::read_to_string(&path).with_context(|| format!("failed to read {}", path.display()))?;
    let file: ArticleUpdateFile =
        serde_json::from_str(&raw).with_context(|| format!("invalid JSON in {}", path.display()))?;
    normalize_update_file(file)
}

pub fn render_skill_markdown(output_dir: &str) -> String {
    let schema = schema_for!(ArticleUpdateFile);
    let schema_json = serde_json::to_string_pretty(&schema).unwrap_or_else(|_| "{}".to_string());
    format!(
        "# Long-Form Article Synthesizer\n\n\
Create or refine clean long-form articles that accumulate over time from journal notes.\n\n\
## Output Contract\n\n\
- Read from `journals/text/**`, available transcript text under `journals/text/transcriptions/**`, and existing article drafts under `{output_dir}/**`.\n\
- Write exactly one JSON handoff file: `{handoff_path}`.\n\
- Rust will validate the handoff and materialize visible markdown files under `{output_dir}/`.\n\
- Do not write visible article markdown files directly.\n\
- Hidden metadata lives under `{pipeline_dir}`.\n\
\n\
## Decision Rules\n\n\
- Decide whether an existing article should be refined or whether a new article should be created.\n\
- For `rewriteArticle`, use the exact `expectedHash` supplied in the run prompt inventory for the target file.\n\
- For `createArticle`, choose a new `targetPath` under `posts/articles/`.\n\
- Keep articles focused, durable, and readable as standalone long-form pieces.\n\
- `bodyMarkdown` must exclude the top-level `# Title` heading because Rust writes that heading.\n\
- Every item must include at least one `sourcePath` rooted under `journals/`.\n\
- If nothing is worth updating, write an empty `items` array.\n\
\n\
## Schema\n\n\
### `{handoff_path}`\n\
```json\n\
{schema_json}\n\
```\n",
        output_dir = output_dir.trim_end_matches('/'),
        handoff_path = ARTICLE_HANDOFF_PATH,
        pipeline_dir = ARTICLE_PIPELINE_DIR,
        schema_json = schema_json.trim(),
    )
}

fn build_apply_summary(
    created_count: usize,
    updated_count: usize,
    had_errors: bool,
    applied_any: bool,
    error_messages: &[String],
) -> String {
    let base = format!(
        "Applied article synthesis: {} created, {} updated.",
        created_count, updated_count
    );
    if !had_errors {
        return base;
    }
    let issues = error_messages.join(" | ");
    if applied_any {
        format!("{base} Partial issues: {issues}")
    } else {
        format!("Article synthesis did not apply any updates. Issues: {issues}")
    }
}

pub fn apply_handoff_file(workspace_dir: &Path) -> Result<ArticleApplyResult> {
    let file = load_update_file(workspace_dir)?;
    let output_root = workspace_dir.join(ARTICLE_OUTPUT_ROOT);
    fs::create_dir_all(&output_root)
        .with_context(|| format!("failed to create {}", output_root.display()))?;
    fs::create_dir_all(metadata_root(workspace_dir))
        .with_context(|| format!("failed to create {}", metadata_root(workspace_dir).display()))?;

    let mut result = ArticleApplyResult::default();
    let mut error_messages = Vec::new();

    for item in file.items {
        let abs_path = workspace_dir.join(&item.target_path);
        if let Some(parent) = abs_path.parent() {
            if let Err(err) = fs::create_dir_all(parent) {
                result.had_errors = true;
                error_messages.push(format!("{}: {}", item.target_path, err));
                continue;
            }
        }

        let existing = fs::read_to_string(&abs_path);
        let existing_hash = existing.as_ref().ok().map(|raw| article_hash(raw));
        match item.operation {
            ArticleUpdateOperation::CreateArticle => {
                if existing.is_ok() {
                    result.had_errors = true;
                    error_messages.push(format!(
                        "{}: createArticle target already exists",
                        item.target_path
                    ));
                    continue;
                }
            }
            ArticleUpdateOperation::RewriteArticle => {
                let Some(current_hash) = existing_hash.clone() else {
                    result.had_errors = true;
                    error_messages.push(format!(
                        "{}: rewriteArticle target does not exist",
                        item.target_path
                    ));
                    continue;
                };
                if current_hash != item.expected_hash {
                    result.had_errors = true;
                    error_messages.push(format!(
                        "{}: expectedHash mismatch (expected {}, found {})",
                        item.target_path, item.expected_hash, current_hash
                    ));
                    continue;
                }
            }
        }

        let markdown = render_article_markdown(&item.title, &item.body_markdown);
        if let Err(err) = fs::write(&abs_path, &markdown) {
            result.had_errors = true;
            error_messages.push(format!("{}: {}", item.target_path, err));
            continue;
        }

        let metadata = ArticleMetadataFile {
            version: file_version(),
            title: item.title.clone(),
            summary: item.summary.clone(),
            source_paths: item.source_paths.clone(),
            updated_at: chrono::Utc::now().to_rfc3339(),
            content_hash: article_hash(&markdown),
        };
        result.written_paths.push(item.target_path.clone());
        result.applied_any = true;
        match item.operation {
            ArticleUpdateOperation::CreateArticle => result.created_count += 1,
            ArticleUpdateOperation::RewriteArticle => result.updated_count += 1,
        }
        if let Err(err) = write_article_metadata(workspace_dir, &item.target_path, &metadata) {
            result.had_errors = true;
            error_messages.push(format!("{} metadata: {}", item.target_path, err));
        }
    }

    result.summary = build_apply_summary(
        result.created_count,
        result.updated_count,
        result.had_errors,
        result.applied_any,
        &error_messages,
    );
    Ok(result)
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::tempdir;

    fn write_json_file<T: Serialize>(path: &Path, value: &T) {
        if let Some(parent) = path.parent() {
            fs::create_dir_all(parent).unwrap();
        }
        fs::write(path, serde_json::to_string_pretty(value).unwrap()).unwrap();
    }

    #[test]
    fn apply_handoff_file_creates_article_and_metadata() {
        let tmp = tempdir().unwrap();
        let handoff = ArticleUpdateFile {
            version: "1".to_string(),
            items: vec![ArticleUpdateItem {
                operation: ArticleUpdateOperation::CreateArticle,
                target_path: "posts/articles/ai/native-notes.md".to_string(),
                title: "Native Notes".to_string(),
                summary: "Grows from repeated journal observations.".to_string(),
                source_paths: vec!["journals/text/2026-03-13.md".to_string()],
                body_markdown: "This article body starts here.".to_string(),
                ..ArticleUpdateItem::default()
            }],
            ..ArticleUpdateFile::default()
        };
        write_json_file(&handoff_path(tmp.path()), &handoff);

        let applied = apply_handoff_file(tmp.path()).unwrap();

        assert!(applied.applied_any);
        assert_eq!(applied.created_count, 1);
        assert_eq!(applied.updated_count, 0);
        assert!(tmp
            .path()
            .join("posts/articles/ai/native-notes.md")
            .exists());
        assert!(tmp
            .path()
            .join("posts/articles/pipeline/metadata/ai/native-notes.json")
            .exists());
    }

    #[test]
    fn apply_handoff_file_rejects_stale_hash() {
        let tmp = tempdir().unwrap();
        let article_path = tmp.path().join("posts/articles/ai/native-notes.md");
        fs::create_dir_all(article_path.parent().unwrap()).unwrap();
        fs::write(&article_path, "# Native Notes\n\nOriginal\n").unwrap();

        let handoff = ArticleUpdateFile {
            version: "1".to_string(),
            items: vec![ArticleUpdateItem {
                operation: ArticleUpdateOperation::RewriteArticle,
                target_path: "posts/articles/ai/native-notes.md".to_string(),
                expected_hash: "deadbeefdeadbeef".to_string(),
                title: "Native Notes".to_string(),
                summary: "Update".to_string(),
                source_paths: vec!["journals/text/2026-03-13.md".to_string()],
                body_markdown: "Updated body.".to_string(),
            }],
            ..ArticleUpdateFile::default()
        };
        write_json_file(&handoff_path(tmp.path()), &handoff);

        let applied = apply_handoff_file(tmp.path()).unwrap();

        assert!(!applied.applied_any);
        assert!(applied.had_errors);
        let raw = fs::read_to_string(&article_path).unwrap();
        assert!(raw.contains("Original"));
    }

    #[test]
    fn article_inventory_reads_metadata_sidecar() {
        let tmp = tempdir().unwrap();
        let article_rel = "posts/articles/rust/notes.md";
        let article_abs = tmp.path().join(article_rel);
        fs::create_dir_all(article_abs.parent().unwrap()).unwrap();
        fs::write(&article_abs, "# Notes\n\nBody\n").unwrap();
        write_article_metadata(
            tmp.path(),
            article_rel,
            &ArticleMetadataFile {
                version: file_version(),
                title: "Rust Notes".to_string(),
                summary: "Summary".to_string(),
                source_paths: vec!["journals/text/2026-03-12.md".to_string()],
                updated_at: "2026-03-13T00:00:00Z".to_string(),
                content_hash: "abcd".to_string(),
            },
        )
        .unwrap();

        let items = article_inventory(tmp.path()).unwrap();

        assert_eq!(items.len(), 1);
        assert_eq!(items[0].title, "Rust Notes");
        assert_eq!(items[0].source_paths, vec!["journals/text/2026-03-12.md"]);
    }
}
