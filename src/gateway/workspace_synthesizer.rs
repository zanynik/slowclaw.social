use crate::gateway::local_store;
use crate::util::truncate_with_ellipsis;
use anyhow::{Context, Result};
use schemars::{schema_for, JsonSchema};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::collections::HashSet;
use std::fs;
use std::path::{Path, PathBuf};

pub const WORKSPACE_SYNTHESIZER_THREAD_ID: &str = "workspace:synthesizer";
pub const WORKSPACE_SYNTHESIZER_OUTPUT_ROOT: &str = "posts/workspace_synthesizer";
pub const WORKSPACE_SYNTHESIZER_MANIFEST_PATH: &str =
    "posts/workspace_synthesizer/pipeline/synthesis_manifest.json";
pub const WORKSPACE_SYNTHESIZER_CLIP_PLAN_DIR: &str = "posts/workspace_synthesizer/pipeline/clips";
const WORKSPACE_SYNTHESIZER_STATUS_PATH: &str = "state/workspace_synthesizer_status.json";
const MAX_INSIGHT_POSTS: usize = 18;
const MAX_TODOS: usize = 30;
const MAX_EVENTS: usize = 20;
const MAX_CLIP_PLANS: usize = 12;

#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema, Default)]
#[serde(rename_all = "camelCase")]
pub struct WorkspaceSynthesisManifest {
    #[serde(default = "manifest_version")]
    pub version: String,
    #[serde(default)]
    pub insight_posts: Vec<InsightPostCandidate>,
    #[serde(default)]
    pub todos: Vec<TodoCandidate>,
    #[serde(default)]
    pub events: Vec<EventCandidate>,
    #[serde(default)]
    pub clip_plans: Vec<ClipPlanCandidate>,
    #[serde(default)]
    pub run_summary: ManifestRunSummary,
}

#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema, Default)]
#[serde(rename_all = "camelCase")]
pub struct ManifestRunSummary {
    #[serde(default)]
    pub notes: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema, Default)]
#[serde(rename_all = "camelCase")]
pub struct InsightPostCandidate {
    #[serde(default)]
    pub id: String,
    #[serde(default)]
    pub text: String,
    #[serde(default)]
    pub source_path: String,
    #[serde(default)]
    pub source_excerpt: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema, Default)]
#[serde(rename_all = "camelCase")]
pub struct TodoCandidate {
    #[serde(default)]
    pub id: String,
    #[serde(default)]
    pub title: String,
    #[serde(default)]
    pub details: String,
    #[serde(default)]
    pub priority: String,
    #[serde(default)]
    pub status: String,
    #[serde(default)]
    pub due_at: String,
    #[serde(default)]
    pub source_path: String,
    #[serde(default)]
    pub source_excerpt: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema, Default)]
#[serde(rename_all = "camelCase")]
pub struct EventCandidate {
    #[serde(default)]
    pub id: String,
    #[serde(default)]
    pub title: String,
    #[serde(default)]
    pub details: String,
    #[serde(default)]
    pub location: String,
    #[serde(default)]
    pub status: String,
    #[serde(default)]
    pub start_at: String,
    #[serde(default)]
    pub end_at: String,
    #[serde(default)]
    pub all_day: bool,
    #[serde(default)]
    pub source_path: String,
    #[serde(default)]
    pub source_excerpt: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema, Default)]
#[serde(rename_all = "camelCase")]
pub struct ClipPlanCandidate {
    #[serde(default)]
    pub id: String,
    #[serde(default)]
    pub title: String,
    #[serde(default)]
    pub source_path: String,
    #[serde(default)]
    pub source_excerpt: String,
    #[serde(default)]
    pub transcript_quote: String,
    #[serde(default)]
    pub start_at: String,
    #[serde(default)]
    pub end_at: String,
    #[serde(default)]
    pub notes: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub struct WorkspaceSynthesizerStatus {
    #[serde(default = "default_idle_status")]
    pub status: String,
    #[serde(default)]
    pub trigger_reason: String,
    #[serde(default)]
    pub thread_id: String,
    #[serde(default)]
    pub last_run_at: String,
    #[serde(default)]
    pub last_source_updated_at: i64,
    #[serde(default)]
    pub last_summary: String,
    #[serde(default)]
    pub last_error: String,
    #[serde(default)]
    pub last_manifest_path: String,
    #[serde(default)]
    pub artifact_counts: WorkspaceSynthArtifactCounts,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub struct WorkspaceSynthArtifactCounts {
    #[serde(default)]
    pub insight_posts: usize,
    #[serde(default)]
    pub todos: usize,
    #[serde(default)]
    pub events: usize,
    #[serde(default)]
    pub clip_plans: usize,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub struct WorkspaceSynthesisApplyResult {
    #[serde(default)]
    pub insight_post_paths: Vec<String>,
    #[serde(default)]
    pub clip_plan_paths: Vec<String>,
    #[serde(default)]
    pub counts: WorkspaceSynthArtifactCounts,
    #[serde(default)]
    pub summary: String,
}

fn manifest_version() -> String {
    "1".to_string()
}

fn default_idle_status() -> String {
    "idle".to_string()
}

pub fn manifest_schema_json() -> Result<String> {
    let schema = schema_for!(WorkspaceSynthesisManifest);
    serde_json::to_string_pretty(&schema).context("failed to serialize workspace synthesis schema")
}

pub fn render_prompt(media_summary: &str) -> Result<String> {
    let schema_json = manifest_schema_json()?;
    Ok(format!(
        "You are the workspace synthesizer.\n\n\
Read the workspace journal corpus and extract structured artifacts into a single JSON manifest.\n\n\
## Sources\n\n\
- `journals/text/**`\n\
- `journals/text/transcriptions/**`\n\n\
## Required Output\n\n\
- Write exactly one JSON file to `{manifest_path}`.\n\
- Overwrite that file completely with valid JSON.\n\
- Do not write final feed posts, todos, events, or any other files yourself.\n\
- The Rust runtime will validate the manifest and route artifacts by type.\n\n\
## Extraction Scope\n\n\
- `insightPosts`: concise feed-ready post text only. No headings, no markdown bullets, no surrounding quotes.\n\
- `todos`: concrete action items only when the journal makes a clear commitment or next step explicit.\n\
- `events`: only when the source includes a clear date/time or scheduled plan.\n\
- `clipPlans`: only when transcripts contain a quotable segment with enough context to plan a clip.\n\n\
## Quality Rules\n\n\
- Prefer fewer, high-signal artifacts over exhaustive extraction.\n\
- Keep `insightPosts` short enough to be feed-friendly.\n\
- Every item must include `sourcePath` and `sourceExcerpt`.\n\
- Use stable lowercase ids with letters, numbers, and dashes when possible.\n\
- Use workspace-relative journal paths only.\n\
- If an artifact type has nothing worth emitting, return an empty array for that type.\n\
- Never include comments, markdown fences, or trailing prose in the JSON file.\n\n\
## Output Limits\n\n\
- Maximum {max_posts} `insightPosts`\n\
- Maximum {max_todos} `todos`\n\
- Maximum {max_events} `events`\n\
- Maximum {max_clips} `clipPlans`\n\n\
## Runtime Notes\n\n\
- {media_summary}\n\
- This workflow must work on desktop and mobile runtimes. Clip plans are allowed even when rendering is unavailable.\n\n\
## JSON Schema\n\n\
```json\n\
{schema_json}\n\
```\n",
        manifest_path = WORKSPACE_SYNTHESIZER_MANIFEST_PATH,
        max_posts = MAX_INSIGHT_POSTS,
        max_todos = MAX_TODOS,
        max_events = MAX_EVENTS,
        max_clips = MAX_CLIP_PLANS,
        media_summary = media_summary.trim(),
        schema_json = schema_json.trim(),
    ))
}

pub fn manifest_path(workspace_dir: &Path) -> PathBuf {
    workspace_dir.join(WORKSPACE_SYNTHESIZER_MANIFEST_PATH)
}

pub fn status_path(workspace_dir: &Path) -> PathBuf {
    workspace_dir.join(WORKSPACE_SYNTHESIZER_STATUS_PATH)
}

pub fn load_status(workspace_dir: &Path) -> WorkspaceSynthesizerStatus {
    let path = status_path(workspace_dir);
    let raw = match fs::read_to_string(path) {
        Ok(raw) => raw,
        Err(_) => return WorkspaceSynthesizerStatus::default(),
    };
    serde_json::from_str(&raw).unwrap_or_default()
}

pub fn save_status(workspace_dir: &Path, status: &WorkspaceSynthesizerStatus) -> Result<()> {
    let path = status_path(workspace_dir);
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)
            .with_context(|| format!("failed to create {}", parent.display()))?;
    }
    let raw = serde_json::to_string_pretty(status)?;
    fs::write(&path, raw).with_context(|| format!("failed to write {}", path.display()))?;
    Ok(())
}

pub fn load_manifest(workspace_dir: &Path) -> Result<WorkspaceSynthesisManifest> {
    let path = manifest_path(workspace_dir);
    let raw =
        fs::read_to_string(&path).with_context(|| format!("failed to read {}", path.display()))?;
    let manifest: WorkspaceSynthesisManifest =
        serde_json::from_str(&raw).with_context(|| format!("invalid JSON in {}", path.display()))?;
    normalize_manifest(manifest)
}

fn normalize_manifest(mut manifest: WorkspaceSynthesisManifest) -> Result<WorkspaceSynthesisManifest> {
    if manifest.version.trim().is_empty() {
        manifest.version = manifest_version();
    }
    if manifest.version != "1" {
        anyhow::bail!("unsupported workspace synthesis manifest version `{}`", manifest.version);
    }

    if manifest.insight_posts.len() > MAX_INSIGHT_POSTS {
        manifest.insight_posts.truncate(MAX_INSIGHT_POSTS);
    }
    if manifest.todos.len() > MAX_TODOS {
        manifest.todos.truncate(MAX_TODOS);
    }
    if manifest.events.len() > MAX_EVENTS {
        manifest.events.truncate(MAX_EVENTS);
    }
    if manifest.clip_plans.len() > MAX_CLIP_PLANS {
        manifest.clip_plans.truncate(MAX_CLIP_PLANS);
    }

    let mut used_post_ids = HashSet::new();
    for item in &mut manifest.insight_posts {
        item.text = truncate_with_ellipsis(item.text.trim(), 480);
        item.source_path = normalize_source_path(&item.source_path)?;
        item.source_excerpt = truncate_with_ellipsis(item.source_excerpt.trim(), 280);
        if item.text.trim().is_empty() {
            anyhow::bail!("insightPosts items require non-empty text");
        }
        let seed = format!("{}|{}|{}", item.text, item.source_path, item.source_excerpt);
        item.id = unique_id(&used_post_ids, &item.id, &seed, "post");
        used_post_ids.insert(item.id.clone());
    }

    let mut used_todo_ids = HashSet::new();
    for item in &mut manifest.todos {
        item.title = truncate_with_ellipsis(item.title.trim(), 120);
        item.details = truncate_with_ellipsis(item.details.trim(), 600);
        item.priority = normalize_priority(&item.priority);
        item.status = normalize_todo_status(&item.status);
        item.source_path = normalize_source_path(&item.source_path)?;
        item.source_excerpt = truncate_with_ellipsis(item.source_excerpt.trim(), 280);
        if item.title.trim().is_empty() {
            anyhow::bail!("todos items require non-empty title");
        }
        let seed = format!("{}|{}|{}", item.title, item.source_path, item.source_excerpt);
        item.id = unique_id(&used_todo_ids, &item.id, &seed, "todo");
        used_todo_ids.insert(item.id.clone());
    }

    let mut used_event_ids = HashSet::new();
    for item in &mut manifest.events {
        item.title = truncate_with_ellipsis(item.title.trim(), 120);
        item.details = truncate_with_ellipsis(item.details.trim(), 600);
        item.location = truncate_with_ellipsis(item.location.trim(), 200);
        item.status = normalize_event_status(&item.status);
        item.start_at = item.start_at.trim().to_string();
        item.end_at = item.end_at.trim().to_string();
        item.source_path = normalize_source_path(&item.source_path)?;
        item.source_excerpt = truncate_with_ellipsis(item.source_excerpt.trim(), 280);
        if item.title.trim().is_empty() {
            anyhow::bail!("events items require non-empty title");
        }
        if item.start_at.is_empty() {
            anyhow::bail!("events items require non-empty startAt");
        }
        let seed = format!("{}|{}|{}", item.title, item.start_at, item.source_path);
        item.id = unique_id(&used_event_ids, &item.id, &seed, "event");
        used_event_ids.insert(item.id.clone());
    }

    let mut used_clip_ids = HashSet::new();
    for item in &mut manifest.clip_plans {
        item.title = truncate_with_ellipsis(item.title.trim(), 120);
        item.transcript_quote = truncate_with_ellipsis(item.transcript_quote.trim(), 400);
        item.notes = truncate_with_ellipsis(item.notes.trim(), 600);
        item.start_at = item.start_at.trim().to_string();
        item.end_at = item.end_at.trim().to_string();
        item.source_path = normalize_source_path(&item.source_path)?;
        item.source_excerpt = truncate_with_ellipsis(item.source_excerpt.trim(), 280);
        if item.title.trim().is_empty() {
            anyhow::bail!("clipPlans items require non-empty title");
        }
        if item.transcript_quote.trim().is_empty() {
            anyhow::bail!("clipPlans items require non-empty transcriptQuote");
        }
        if item.start_at.is_empty() || item.end_at.is_empty() {
            anyhow::bail!("clipPlans items require startAt and endAt");
        }
        let seed = format!("{}|{}|{}|{}", item.title, item.start_at, item.end_at, item.source_path);
        item.id = unique_id(&used_clip_ids, &item.id, &seed, "clip");
        used_clip_ids.insert(item.id.clone());
    }

    manifest.run_summary.notes = truncate_with_ellipsis(manifest.run_summary.notes.trim(), 800);
    Ok(manifest)
}

fn normalize_source_path(raw: &str) -> Result<String> {
    let normalized = raw.trim().trim_start_matches('/').replace('\\', "/");
    if normalized.is_empty() {
        anyhow::bail!("manifest items require sourcePath");
    }
    if normalized.contains("..") {
        anyhow::bail!("sourcePath must stay inside the workspace journal tree");
    }
    if !normalized.starts_with("journals/") {
        anyhow::bail!("sourcePath must point into journals/");
    }
    Ok(normalized)
}

fn normalize_priority(raw: &str) -> String {
    match raw.trim().to_ascii_lowercase().as_str() {
        "low" => "low".to_string(),
        "high" => "high".to_string(),
        _ => "medium".to_string(),
    }
}

fn normalize_todo_status(raw: &str) -> String {
    match raw.trim().to_ascii_lowercase().as_str() {
        "done" => "done".to_string(),
        _ => "open".to_string(),
    }
}

fn normalize_event_status(raw: &str) -> String {
    match raw.trim().to_ascii_lowercase().as_str() {
        "tentative" => "tentative".to_string(),
        "cancelled" => "cancelled".to_string(),
        _ => "confirmed".to_string(),
    }
}

fn unique_id(
    used_ids: &HashSet<String>,
    preferred: &str,
    seed: &str,
    prefix: &str,
) -> String {
    let base = normalize_id(preferred);
    let seeded = if base.is_empty() {
        format!("{prefix}-{}", short_hash(seed))
    } else {
        base
    };
    if !used_ids.contains(&seeded) {
        return seeded;
    }
    format!("{seeded}-{}", short_hash(seed))
}

fn normalize_id(raw: &str) -> String {
    let mut out = String::new();
    let mut prev_dash = false;
    for ch in raw.chars() {
        let lower = ch.to_ascii_lowercase();
        if lower.is_ascii_alphanumeric() {
            out.push(lower);
            prev_dash = false;
        } else if !prev_dash {
            out.push('-');
            prev_dash = true;
        }
    }
    out.trim_matches('-').to_string()
}

fn short_hash(seed: &str) -> String {
    let digest = Sha256::digest(seed.as_bytes());
    hex::encode(&digest[..4])
}

pub fn apply_manifest(
    workspace_dir: &Path,
    manifest: &WorkspaceSynthesisManifest,
    manifest_id: &str,
) -> Result<WorkspaceSynthesisApplyResult> {
    let output_root = workspace_dir.join(WORKSPACE_SYNTHESIZER_OUTPUT_ROOT);
    let clip_dir = workspace_dir.join(WORKSPACE_SYNTHESIZER_CLIP_PLAN_DIR);
    let pipeline_dir = workspace_dir.join("posts/workspace_synthesizer/pipeline");
    fs::create_dir_all(&output_root)
        .with_context(|| format!("failed to create {}", output_root.display()))?;
    fs::create_dir_all(&clip_dir)
        .with_context(|| format!("failed to create {}", clip_dir.display()))?;
    fs::create_dir_all(&pipeline_dir)
        .with_context(|| format!("failed to create {}", pipeline_dir.display()))?;

    let insight_post_paths = write_insight_posts(&output_root, &manifest.insight_posts)?;
    let clip_plan_paths = write_clip_plans(&clip_dir, &manifest.clip_plans)?;

    let todo_items: Vec<local_store::WorkspaceTodoUpsert> = manifest
        .todos
        .iter()
        .map(|item| {
            let metadata_json = serde_json::to_string(item).unwrap_or_else(|_| "{}".to_string());
            local_store::WorkspaceTodoUpsert {
                id: item.id.clone(),
                title: item.title.clone(),
                details: item.details.clone(),
                priority: item.priority.clone(),
                model_status: item.status.clone(),
                due_at: item.due_at.clone(),
                source_path: item.source_path.clone(),
                source_excerpt: item.source_excerpt.clone(),
                metadata_json,
            }
        })
        .collect();
    let event_items: Vec<local_store::WorkspaceEventUpsert> = manifest
        .events
        .iter()
        .map(|item| {
            let metadata_json = serde_json::to_string(item).unwrap_or_else(|_| "{}".to_string());
            local_store::WorkspaceEventUpsert {
                id: item.id.clone(),
                title: item.title.clone(),
                details: item.details.clone(),
                location: item.location.clone(),
                status: item.status.clone(),
                start_at: item.start_at.clone(),
                end_at: item.end_at.clone(),
                all_day: item.all_day,
                source_path: item.source_path.clone(),
                source_excerpt: item.source_excerpt.clone(),
                metadata_json,
            }
        })
        .collect();

    let todo_count = local_store::replace_workspace_todos(workspace_dir, &todo_items, manifest_id)?;
    let event_count =
        local_store::replace_workspace_events(workspace_dir, &event_items, manifest_id)?;
    let counts = WorkspaceSynthArtifactCounts {
        insight_posts: insight_post_paths.len(),
        todos: todo_count,
        events: event_count,
        clip_plans: clip_plan_paths.len(),
    };
    let summary = format!(
        "Applied workspace synthesis: {} feed posts, {} todos, {} events, {} clip plans.",
        counts.insight_posts, counts.todos, counts.events, counts.clip_plans
    );
    Ok(WorkspaceSynthesisApplyResult {
        insight_post_paths,
        clip_plan_paths,
        counts,
        summary,
    })
}

fn write_insight_posts(
    output_root: &Path,
    items: &[InsightPostCandidate],
) -> Result<Vec<String>> {
    let mut keep_files = HashSet::new();
    let mut written_paths = Vec::new();
    for item in items {
        let filename = format!("{}.md", item.id);
        let path = output_root.join(&filename);
        let content = format!("{}\n", item.text.trim());
        fs::write(&path, content).with_context(|| format!("failed to write {}", path.display()))?;
        keep_files.insert(filename);
        written_paths.push(format!("posts/workspace_synthesizer/{}.md", item.id));
    }
    remove_stale_files(output_root, &keep_files, &["pipeline"])?;
    Ok(written_paths)
}

fn write_clip_plans(clip_dir: &Path, items: &[ClipPlanCandidate]) -> Result<Vec<String>> {
    let mut keep_files = HashSet::new();
    let mut written_paths = Vec::new();
    for item in items {
        let filename = format!("{}.json", item.id);
        let path = clip_dir.join(&filename);
        let raw = serde_json::to_string_pretty(item)?;
        fs::write(&path, raw).with_context(|| format!("failed to write {}", path.display()))?;
        keep_files.insert(filename);
        written_paths.push(format!("posts/workspace_synthesizer/pipeline/clips/{}.json", item.id));
    }
    remove_stale_files(clip_dir, &keep_files, &[])?;
    Ok(written_paths)
}

fn remove_stale_files(dir: &Path, keep_files: &HashSet<String>, preserve_dirs: &[&str]) -> Result<()> {
    for entry in fs::read_dir(dir).with_context(|| format!("failed to read {}", dir.display()))? {
        let entry = entry?;
        let path = entry.path();
        let file_name = entry.file_name().to_string_lossy().to_string();
        let file_type = entry.file_type()?;
        if file_type.is_dir() {
            if preserve_dirs.iter().any(|name| *name == file_name) {
                continue;
            }
            continue;
        }
        if keep_files.contains(&file_name) {
            continue;
        }
        fs::remove_file(&path).with_context(|| format!("failed to remove {}", path.display()))?;
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn manifest_normalization_generates_ids_and_applies_defaults() {
        let manifest = WorkspaceSynthesisManifest {
            version: "1".to_string(),
            insight_posts: vec![InsightPostCandidate {
                text: "Ship the thing".to_string(),
                source_path: "journals/text/2026-03-11.md".to_string(),
                source_excerpt: "Ship the thing.".to_string(),
                ..InsightPostCandidate::default()
            }],
            todos: vec![TodoCandidate {
                title: "Email the team".to_string(),
                source_path: "journals/text/2026-03-11.md".to_string(),
                source_excerpt: "Need to email the team.".to_string(),
                ..TodoCandidate::default()
            }],
            events: vec![EventCandidate {
                title: "Launch review".to_string(),
                start_at: "2026-03-12T09:00:00Z".to_string(),
                source_path: "journals/text/2026-03-11.md".to_string(),
                source_excerpt: "Launch review tomorrow at 9.".to_string(),
                ..EventCandidate::default()
            }],
            ..WorkspaceSynthesisManifest::default()
        };

        let normalized = normalize_manifest(manifest).unwrap();
        assert_eq!(normalized.insight_posts.len(), 1);
        assert!(!normalized.insight_posts[0].id.is_empty());
        assert_eq!(normalized.todos[0].priority, "medium");
        assert_eq!(normalized.todos[0].status, "open");
        assert_eq!(normalized.events[0].status, "confirmed");
    }
}
