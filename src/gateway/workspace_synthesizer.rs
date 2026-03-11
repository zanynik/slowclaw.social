use crate::gateway::local_store;
use crate::util::truncate_with_ellipsis;
use anyhow::{Context, Result};
use schemars::{schema_for, JsonSchema};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::collections::{HashMap, HashSet};
use std::fs;
use std::path::{Path, PathBuf};

pub const WORKSPACE_SYNTHESIZER_THREAD_ID: &str = "workspace:synthesizer";
pub const WORKSPACE_SYNTHESIZER_OUTPUT_ROOT: &str = "posts/workspace_synthesizer";
pub const WORKSPACE_SYNTHESIZER_PIPELINE_DIR: &str = "posts/workspace_synthesizer/pipeline";
pub const WORKSPACE_INSIGHT_EXTRACTOR_WORKFLOW_KEY: &str = "workspace_insight_extractor";
pub const WORKSPACE_TODO_EXTRACTOR_WORKFLOW_KEY: &str = "workspace_todo_extractor";
pub const WORKSPACE_EVENT_EXTRACTOR_WORKFLOW_KEY: &str = "workspace_event_extractor";
pub const WORKSPACE_CLIP_EXTRACTOR_WORKFLOW_KEY: &str = "workspace_clip_extractor";
pub const WORKSPACE_JOURNAL_TITLE_EXTRACTOR_WORKFLOW_KEY: &str =
    "workspace_journal_title_extractor";
pub const WORKSPACE_SYNTHESIZER_INSIGHT_POSTS_PATH: &str =
    "posts/workspace_synthesizer/pipeline/insight_posts.json";
pub const WORKSPACE_SYNTHESIZER_TODOS_PATH: &str =
    "posts/workspace_synthesizer/pipeline/todos.json";
pub const WORKSPACE_SYNTHESIZER_EVENTS_PATH: &str =
    "posts/workspace_synthesizer/pipeline/events.json";
pub const WORKSPACE_SYNTHESIZER_CLIP_PLANS_PATH: &str =
    "posts/workspace_synthesizer/pipeline/clip_plans.json";
pub const WORKSPACE_SYNTHESIZER_JOURNAL_TITLES_PATH: &str =
    "posts/workspace_synthesizer/pipeline/journal_titles.json";
pub const WORKSPACE_SYNTHESIZER_MANIFEST_PATH: &str =
    "posts/workspace_synthesizer/pipeline/synthesis_manifest.json";
pub const WORKSPACE_SYNTHESIZER_CLIP_PLAN_DIR: &str = "posts/workspace_synthesizer/pipeline/clips";
const WORKSPACE_SYNTHESIZER_STATUS_PATH: &str = "state/workspace_synthesizer_status.json";
const MAX_INSIGHT_POSTS: usize = 18;
const MAX_TODOS: usize = 30;
const MAX_EVENTS: usize = 20;
const MAX_CLIP_PLANS: usize = 12;
const MAX_JOURNAL_TITLES: usize = 8;

#[derive(Debug, Clone, Copy)]
pub struct WorkspaceSynthExtractorSpec {
    pub workflow_key: &'static str,
    pub name: &'static str,
    pub goal: &'static str,
    pub handoff_path: &'static str,
    pub max_items: usize,
}

const WORKSPACE_SYNTH_EXTRACTOR_SPECS: [WorkspaceSynthExtractorSpec; 5] = [
    WorkspaceSynthExtractorSpec {
        workflow_key: WORKSPACE_INSIGHT_EXTRACTOR_WORKFLOW_KEY,
        name: "Workspace Insight Extractor",
        goal: "Extract concise workspace feed posts from recent journals and transcripts. Write only the insight_posts handoff JSON for Rust to materialize into feed posts.",
        handoff_path: WORKSPACE_SYNTHESIZER_INSIGHT_POSTS_PATH,
        max_items: MAX_INSIGHT_POSTS,
    },
    WorkspaceSynthExtractorSpec {
        workflow_key: WORKSPACE_TODO_EXTRACTOR_WORKFLOW_KEY,
        name: "Workspace Todo Extractor",
        goal: "Extract concrete action items and commitments from recent journals and transcripts. Write only the todos handoff JSON for Rust to store in the planner.",
        handoff_path: WORKSPACE_SYNTHESIZER_TODOS_PATH,
        max_items: MAX_TODOS,
    },
    WorkspaceSynthExtractorSpec {
        workflow_key: WORKSPACE_EVENT_EXTRACTOR_WORKFLOW_KEY,
        name: "Workspace Event Extractor",
        goal: "Extract scheduled events with clear timing from recent journals and transcripts. Write only the events handoff JSON for Rust to store in the planner.",
        handoff_path: WORKSPACE_SYNTHESIZER_EVENTS_PATH,
        max_items: MAX_EVENTS,
    },
    WorkspaceSynthExtractorSpec {
        workflow_key: WORKSPACE_CLIP_EXTRACTOR_WORKFLOW_KEY,
        name: "Workspace Clip Extractor",
        goal: "Extract clip plans only from audio/video transcript sidecars under journals/text/transcriptions. Write only the clip_plans handoff JSON for Rust to keep as pipeline artifacts.",
        handoff_path: WORKSPACE_SYNTHESIZER_CLIP_PLANS_PATH,
        max_items: MAX_CLIP_PLANS,
    },
    WorkspaceSynthExtractorSpec {
        workflow_key: WORKSPACE_JOURNAL_TITLE_EXTRACTOR_WORKFLOW_KEY,
        name: "Workspace Journal Title Extractor",
        goal: "Propose concise durable titles for the current journal note batch. Write only the journal_titles handoff JSON for Rust to rename journal note files.",
        handoff_path: WORKSPACE_SYNTHESIZER_JOURNAL_TITLES_PATH,
        max_items: MAX_JOURNAL_TITLES,
    },
];

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

#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema, Default)]
#[serde(rename_all = "camelCase")]
pub struct JournalTitleCandidate {
    #[serde(default)]
    pub source_path: String,
    #[serde(default)]
    pub title: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema, Default)]
#[serde(rename_all = "camelCase")]
pub struct InsightPostFile {
    #[serde(default = "manifest_version")]
    pub version: String,
    #[serde(default)]
    pub items: Vec<InsightPostCandidate>,
}

#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema, Default)]
#[serde(rename_all = "camelCase")]
pub struct TodoFile {
    #[serde(default = "manifest_version")]
    pub version: String,
    #[serde(default)]
    pub items: Vec<TodoCandidate>,
}

#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema, Default)]
#[serde(rename_all = "camelCase")]
pub struct EventFile {
    #[serde(default = "manifest_version")]
    pub version: String,
    #[serde(default)]
    pub items: Vec<EventCandidate>,
}

#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema, Default)]
#[serde(rename_all = "camelCase")]
pub struct ClipPlanFile {
    #[serde(default = "manifest_version")]
    pub version: String,
    #[serde(default)]
    pub items: Vec<ClipPlanCandidate>,
}

#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema, Default)]
#[serde(rename_all = "camelCase")]
pub struct JournalTitleFile {
    #[serde(default = "manifest_version")]
    pub version: String,
    #[serde(default)]
    pub items: Vec<JournalTitleCandidate>,
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
    pub pending_source_count: usize,
    #[serde(default)]
    pub pending_word_count: usize,
    #[serde(default)]
    pub selected_source_paths: Vec<String>,
    #[serde(default)]
    pub artifact_counts: WorkspaceSynthArtifactCounts,
    #[serde(default)]
    pub artifact_states: WorkspaceSynthArtifactStates,
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
pub struct WorkspaceSynthArtifactState {
    #[serde(default)]
    pub status: String,
    #[serde(default)]
    pub path: String,
    #[serde(default)]
    pub item_count: usize,
    #[serde(default)]
    pub error: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub struct WorkspaceSynthArtifactStates {
    #[serde(default)]
    pub insight_posts: WorkspaceSynthArtifactState,
    #[serde(default)]
    pub todos: WorkspaceSynthArtifactState,
    #[serde(default)]
    pub events: WorkspaceSynthArtifactState,
    #[serde(default)]
    pub clip_plans: WorkspaceSynthArtifactState,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub struct WorkspaceSynthesisApplyResult {
    #[serde(default)]
    pub insight_post_paths: Vec<String>,
    #[serde(default)]
    pub clip_plan_paths: Vec<String>,
    #[serde(default)]
    pub renamed_sources: Vec<WorkspaceSynthRenamedSource>,
    #[serde(default)]
    pub counts: WorkspaceSynthArtifactCounts,
    #[serde(default)]
    pub summary: String,
    #[serde(default)]
    pub artifact_states: WorkspaceSynthArtifactStates,
    #[serde(default)]
    pub applied_any: bool,
    #[serde(default)]
    pub had_errors: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub struct WorkspaceSynthRenamedSource {
    #[serde(default)]
    pub from_path: String,
    #[serde(default)]
    pub to_path: String,
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

fn insight_posts_schema_json() -> Result<String> {
    let schema = schema_for!(InsightPostFile);
    serde_json::to_string_pretty(&schema)
        .context("failed to serialize insight posts schema")
}

fn todos_schema_json() -> Result<String> {
    let schema = schema_for!(TodoFile);
    serde_json::to_string_pretty(&schema).context("failed to serialize todos schema")
}

fn events_schema_json() -> Result<String> {
    let schema = schema_for!(EventFile);
    serde_json::to_string_pretty(&schema).context("failed to serialize events schema")
}

fn clip_plans_schema_json() -> Result<String> {
    let schema = schema_for!(ClipPlanFile);
    serde_json::to_string_pretty(&schema).context("failed to serialize clip plans schema")
}

fn journal_titles_schema_json() -> Result<String> {
    let schema = schema_for!(JournalTitleFile);
    serde_json::to_string_pretty(&schema).context("failed to serialize journal titles schema")
}

pub fn extractor_specs() -> &'static [WorkspaceSynthExtractorSpec] {
    &WORKSPACE_SYNTH_EXTRACTOR_SPECS
}

pub fn is_extractor_workflow_key(workflow_key: &str) -> bool {
    extractor_spec_by_key(workflow_key).is_some()
}

pub fn extractor_handoff_path(workflow_key: &str) -> Option<&'static str> {
    extractor_spec_by_key(workflow_key).map(|spec| spec.handoff_path)
}

pub fn extractor_spec_by_key(workflow_key: &str) -> Option<WorkspaceSynthExtractorSpec> {
    extractor_specs()
        .iter()
        .copied()
        .find(|spec| spec.workflow_key == workflow_key.trim())
}

pub fn render_skill_markdown() -> Result<String> {
    Ok(format!(
        "# Workspace Synthesizer\n\n\
This is the index skill for workspace synthesis.\n\n\
The runtime uses this skill as the shared guidance layer, then runs specialized extractor skills for each artifact family:\n\
- `{insight_key}` -> `{insight_posts_path}`\n\
- `{todo_key}` -> `{todos_path}`\n\
- `{event_key}` -> `{events_path}`\n\
- `{clip_key}` -> `{clip_plans_path}`\n\
- `{title_key}` -> `{journal_titles_path}`\n\n\
## Role\n\n\
- Read from `journals/text/**` and available transcript text under `journals/text/transcriptions/**`.\n\
- Act as the global policy layer for all workspace extraction.\n\
- The Rust runtime decides which extractor skills to run and validates each handoff file independently.\n\
- Extractor skills, not this index skill alone, own the small typed JSON outputs.\n\n\
## Shared Guardrails\n\n\
- Prefer fewer, higher-signal artifacts over exhaustive extraction.\n\
- Every emitted item must include `sourcePath` and `sourceExcerpt`.\n\
- Use workspace-relative journal paths only.\n\
- Do not create final feed posts, todos, events, or clip plan output files directly.\n\
- Desktop and mobile must both be supported. Clip rendering may be unavailable, but clip planning is still allowed.\n\n\
## Artifact Policy\n\n\
- `insightPosts`: concise feed-ready text only.\n\
- `todos`: only explicit actions or commitments.\n\
- `events`: only when timing or scheduling is actually supported by the source.\n\
- `clipPlans`: only from transcript sidecars under `journals/text/transcriptions/**`, and only when transcript text contains a quotable segment with clear start/end timing context.\n\
- `journalTitles`: only for journal note files that deserve clearer durable titles.\n\
\n\
## Runtime Notes\n\n\
- Each extractor writes one small typed JSON handoff file.\n\
- Rust materializes final outputs and keeps planner data out of the feed.\n\
- Partial success is allowed: one extractor can fail without discarding the others.\n",
        insight_key = WORKSPACE_INSIGHT_EXTRACTOR_WORKFLOW_KEY,
        todo_key = WORKSPACE_TODO_EXTRACTOR_WORKFLOW_KEY,
        event_key = WORKSPACE_EVENT_EXTRACTOR_WORKFLOW_KEY,
        clip_key = WORKSPACE_CLIP_EXTRACTOR_WORKFLOW_KEY,
        title_key = WORKSPACE_JOURNAL_TITLE_EXTRACTOR_WORKFLOW_KEY,
        insight_posts_path = WORKSPACE_SYNTHESIZER_INSIGHT_POSTS_PATH,
        todos_path = WORKSPACE_SYNTHESIZER_TODOS_PATH,
        events_path = WORKSPACE_SYNTHESIZER_EVENTS_PATH,
        clip_plans_path = WORKSPACE_SYNTHESIZER_CLIP_PLANS_PATH,
        journal_titles_path = WORKSPACE_SYNTHESIZER_JOURNAL_TITLES_PATH,
    ))
}

pub fn render_extractor_skill_markdown(workflow_key: &str) -> Result<String> {
    let Some(spec) = extractor_spec_by_key(workflow_key) else {
        anyhow::bail!("unknown workspace synthesizer extractor `{workflow_key}`");
    };
    let (artifact_name, schema_json, artifact_rules) = match spec.workflow_key {
        WORKSPACE_INSIGHT_EXTRACTOR_WORKFLOW_KEY => (
            "insightPosts",
            insight_posts_schema_json()?,
            "- Emit concise, feed-ready text only.\n\
- No titles, no markdown bullets, no surrounding quotes.\n\
- Only include items strong enough to stand alone in the workspace feed.\n",
        ),
        WORKSPACE_TODO_EXTRACTOR_WORKFLOW_KEY => (
            "todos",
            todos_schema_json()?,
            "- Emit only explicit next actions, tasks, or commitments.\n\
- Avoid vague aspirations unless the source clearly implies an actionable todo.\n\
- Prefer stable titles and put nuance in `details`.\n",
        ),
        WORKSPACE_EVENT_EXTRACTOR_WORKFLOW_KEY => (
            "events",
            events_schema_json()?,
            "- Emit only items with a clear date, time, or scheduled plan.\n\
- Use `allDay` only when timing is date-level rather than time-specific.\n\
- Do not invent timing or location details.\n",
        ),
        WORKSPACE_CLIP_EXTRACTOR_WORKFLOW_KEY => (
            "clipPlans",
            clip_plans_schema_json()?,
            "- Emit only transcript-backed segments from audio/video transcript sidecars under journals/text/transcriptions/** or journals/text/transcript/**.\n\
- `transcriptQuote` must be a real quote from the source excerpt.\n\
- Use precise `startAt` and `endAt` values from the transcript context when available.\n",
        ),
        WORKSPACE_JOURNAL_TITLE_EXTRACTOR_WORKFLOW_KEY => (
            "journalTitles",
            journal_titles_schema_json()?,
            "- Emit titles only for real journal note files under `journals/text/`.\n\
- Do not retitle transcript sidecars under `journals/text/transcriptions/**`.\n\
- Titles should be concise, durable, and free of dates, numbering, markdown markers, or file extensions.\n",
        ),
        _ => unreachable!(),
    };
    Ok(format!(
        "# {name}\n\n\
Create one small typed JSON handoff file for the workspace synthesis pipeline.\n\n\
## Output Contract\n\n\
- Read from `journals/text/**` and available transcript text under `journals/text/transcriptions/**`.\n\
- Write exactly one file: `{handoff_path}`.\n\
- Overwrite that file completely with valid JSON.\n\
- If there are no strong candidates, write an empty `items` array.\n\
- Do not create final feed posts, todos, events, clip plan output files, or other handoff files.\n\
- Do not emit markdown fences or prose outside the JSON file.\n\n\
## Artifact Scope\n\n\
- This extractor owns only `{artifact_name}`.\n\
- Maximum items: {max_items}\n\
- Every item must include `sourcePath` and `sourceExcerpt`.\n\
- Use workspace-relative journal paths only.\n\n\
## Artifact Rules\n\n\
{artifact_rules}\n\
## Schema\n\n\
### `{handoff_path}`\n\
```json\n\
{schema_json}\n\
```\n",
        name = spec.name,
        handoff_path = spec.handoff_path,
        artifact_name = artifact_name,
        max_items = spec.max_items,
        artifact_rules = artifact_rules,
        schema_json = schema_json.trim(),
    ))
}

pub fn render_prompt(media_summary: &str) -> Result<String> {
    let insight_posts_schema = insight_posts_schema_json()?;
    let todos_schema = todos_schema_json()?;
    let events_schema = events_schema_json()?;
    let clip_plans_schema = clip_plans_schema_json()?;
    let journal_titles_schema = journal_titles_schema_json()?;
    Ok(format!(
        "You are the workspace synthesizer.\n\n\
Read the workspace journal corpus and extract structured artifacts into small typed JSON handoff files.\n\n\
## Sources\n\n\
- `journals/text/**`\n\
- `journals/text/transcriptions/**`\n\n\
## Required Output\n\n\
- Write zero or more JSON files under `{pipeline_dir}`.\n\
- Allowed files: `{insight_posts_path}`, `{todos_path}`, `{events_path}`, `{clip_plans_path}`, `{journal_titles_path}`.\n\
- Overwrite each emitted file completely with valid JSON.\n\
- Omit files for artifact types with no strong candidates, or write empty `items` arrays.\n\
- Do not write final feed posts, todos, events, or any other files yourself.\n\
- The Rust runtime will validate each handoff file independently and route artifacts by type.\n\n\
## Extraction Scope\n\n\
- `insightPosts`: concise feed-ready post text only. No headings, no markdown bullets, no surrounding quotes.\n\
- `todos`: concrete action items only when the journal makes a clear commitment or next step explicit.\n\
- `events`: only when the source includes a clear date/time or scheduled plan.\n\
- `clipPlans`: only when transcripts contain a quotable segment with enough context to plan a clip.\n\
- `journalTitles`: only for journal note files that deserve clearer durable titles.\n\n\
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
- Maximum {max_clips} `clipPlans`\n\
- Maximum {max_titles} `journalTitles`\n\n\
## Runtime Notes\n\n\
- {media_summary}\n\
- This workflow must work on desktop and mobile runtimes. Clip plans are allowed even when rendering is unavailable.\n\n\
## JSON Schemas\n\n\
### `{insight_posts_path}`\n\
```json\n\
{insight_posts_schema}\n\
```\n",
        pipeline_dir = WORKSPACE_SYNTHESIZER_PIPELINE_DIR,
        insight_posts_path = WORKSPACE_SYNTHESIZER_INSIGHT_POSTS_PATH,
        todos_path = WORKSPACE_SYNTHESIZER_TODOS_PATH,
        events_path = WORKSPACE_SYNTHESIZER_EVENTS_PATH,
        clip_plans_path = WORKSPACE_SYNTHESIZER_CLIP_PLANS_PATH,
        journal_titles_path = WORKSPACE_SYNTHESIZER_JOURNAL_TITLES_PATH,
        max_posts = MAX_INSIGHT_POSTS,
        max_todos = MAX_TODOS,
        max_events = MAX_EVENTS,
        max_clips = MAX_CLIP_PLANS,
        max_titles = MAX_JOURNAL_TITLES,
        media_summary = media_summary.trim(),
        insight_posts_schema = insight_posts_schema.trim(),
    ) + &format!(
        "\n\n### `{todos_path}`\n\
```json\n\
{todos_schema}\n\
```\n\
\n\
### `{events_path}`\n\
```json\n\
{events_schema}\n\
```\n\
\n\
### `{clip_plans_path}`\n\
```json\n\
{clip_plans_schema}\n\
```\n\
\n\
### `{journal_titles_path}`\n\
```json\n\
{journal_titles_schema}\n\
```\n",
        todos_path = WORKSPACE_SYNTHESIZER_TODOS_PATH,
        events_path = WORKSPACE_SYNTHESIZER_EVENTS_PATH,
        clip_plans_path = WORKSPACE_SYNTHESIZER_CLIP_PLANS_PATH,
        journal_titles_path = WORKSPACE_SYNTHESIZER_JOURNAL_TITLES_PATH,
        todos_schema = todos_schema.trim(),
        events_schema = events_schema.trim(),
        clip_plans_schema = clip_plans_schema.trim(),
        journal_titles_schema = journal_titles_schema.trim(),
    ))
}

pub fn manifest_path(workspace_dir: &Path) -> PathBuf {
    workspace_dir.join(WORKSPACE_SYNTHESIZER_MANIFEST_PATH)
}

pub fn pipeline_dir(workspace_dir: &Path) -> PathBuf {
    workspace_dir.join(WORKSPACE_SYNTHESIZER_PIPELINE_DIR)
}

pub fn insight_posts_path(workspace_dir: &Path) -> PathBuf {
    workspace_dir.join(WORKSPACE_SYNTHESIZER_INSIGHT_POSTS_PATH)
}

pub fn todos_path(workspace_dir: &Path) -> PathBuf {
    workspace_dir.join(WORKSPACE_SYNTHESIZER_TODOS_PATH)
}

pub fn events_path(workspace_dir: &Path) -> PathBuf {
    workspace_dir.join(WORKSPACE_SYNTHESIZER_EVENTS_PATH)
}

pub fn clip_plans_path(workspace_dir: &Path) -> PathBuf {
    workspace_dir.join(WORKSPACE_SYNTHESIZER_CLIP_PLANS_PATH)
}

pub fn journal_titles_path(workspace_dir: &Path) -> PathBuf {
    workspace_dir.join(WORKSPACE_SYNTHESIZER_JOURNAL_TITLES_PATH)
}

pub fn status_path(workspace_dir: &Path) -> PathBuf {
    workspace_dir.join(WORKSPACE_SYNTHESIZER_STATUS_PATH)
}

pub fn reset_handoff_files(workspace_dir: &Path) -> Result<()> {
    let handoff_paths = [
        manifest_path(workspace_dir),
        insight_posts_path(workspace_dir),
        todos_path(workspace_dir),
        events_path(workspace_dir),
        clip_plans_path(workspace_dir),
        journal_titles_path(workspace_dir),
    ];
    for path in handoff_paths {
        match fs::remove_file(&path) {
            Ok(()) => {}
            Err(err) if err.kind() == std::io::ErrorKind::NotFound => {}
            Err(err) => {
                return Err(err)
                    .with_context(|| format!("failed to clear {}", path.display()));
            }
        }
    }
    Ok(())
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

fn normalize_file_version(version: &mut String, artifact_label: &str) -> Result<()> {
    if version.trim().is_empty() {
        *version = manifest_version();
    }
    if version != "1" {
        anyhow::bail!(
            "unsupported {artifact_label} handoff version `{}`",
            version
        );
    }
    Ok(())
}

fn load_optional_insight_posts_file(workspace_dir: &Path) -> Result<Option<Vec<InsightPostCandidate>>> {
    let path = insight_posts_path(workspace_dir);
    let raw = match fs::read_to_string(&path) {
        Ok(raw) => raw,
        Err(err) if err.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(err) => {
            return Err(err).with_context(|| format!("failed to read {}", path.display()));
        }
    };
    let mut file: InsightPostFile =
        serde_json::from_str(&raw).with_context(|| format!("invalid JSON in {}", path.display()))?;
    normalize_file_version(&mut file.version, "insight posts")?;
    Ok(Some(normalize_insight_post_items(file.items)?))
}

fn load_optional_todos_file(workspace_dir: &Path) -> Result<Option<Vec<TodoCandidate>>> {
    let path = todos_path(workspace_dir);
    let raw = match fs::read_to_string(&path) {
        Ok(raw) => raw,
        Err(err) if err.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(err) => {
            return Err(err).with_context(|| format!("failed to read {}", path.display()));
        }
    };
    let mut file: TodoFile =
        serde_json::from_str(&raw).with_context(|| format!("invalid JSON in {}", path.display()))?;
    normalize_file_version(&mut file.version, "todos")?;
    Ok(Some(normalize_todo_items(file.items)?))
}

fn load_optional_events_file(workspace_dir: &Path) -> Result<Option<Vec<EventCandidate>>> {
    let path = events_path(workspace_dir);
    let raw = match fs::read_to_string(&path) {
        Ok(raw) => raw,
        Err(err) if err.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(err) => {
            return Err(err).with_context(|| format!("failed to read {}", path.display()));
        }
    };
    let mut file: EventFile =
        serde_json::from_str(&raw).with_context(|| format!("invalid JSON in {}", path.display()))?;
    normalize_file_version(&mut file.version, "events")?;
    Ok(Some(normalize_event_items(file.items)?))
}

fn load_optional_clip_plans_file(workspace_dir: &Path) -> Result<Option<Vec<ClipPlanCandidate>>> {
    let path = clip_plans_path(workspace_dir);
    let raw = match fs::read_to_string(&path) {
        Ok(raw) => raw,
        Err(err) if err.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(err) => {
            return Err(err).with_context(|| format!("failed to read {}", path.display()));
        }
    };
    let mut file: ClipPlanFile =
        serde_json::from_str(&raw).with_context(|| format!("invalid JSON in {}", path.display()))?;
    normalize_file_version(&mut file.version, "clip plans")?;
    Ok(Some(normalize_clip_plan_items(file.items)?))
}

fn load_optional_journal_titles_file(workspace_dir: &Path) -> Result<Option<Vec<JournalTitleCandidate>>> {
    let path = journal_titles_path(workspace_dir);
    let raw = match fs::read_to_string(&path) {
        Ok(raw) => raw,
        Err(err) if err.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(err) => {
            return Err(err).with_context(|| format!("failed to read {}", path.display()));
        }
    };
    let mut file: JournalTitleFile =
        serde_json::from_str(&raw).with_context(|| format!("invalid JSON in {}", path.display()))?;
    normalize_file_version(&mut file.version, "journal titles")?;
    Ok(Some(normalize_journal_title_items(file.items)?))
}

fn normalize_manifest(mut manifest: WorkspaceSynthesisManifest) -> Result<WorkspaceSynthesisManifest> {
    if manifest.version.trim().is_empty() {
        manifest.version = manifest_version();
    }
    if manifest.version != "1" {
        anyhow::bail!("unsupported workspace synthesis manifest version `{}`", manifest.version);
    }

    manifest.insight_posts = normalize_insight_post_items(manifest.insight_posts)?;
    manifest.todos = normalize_todo_items(manifest.todos)?;
    manifest.events = normalize_event_items(manifest.events)?;
    manifest.clip_plans = normalize_clip_plan_items(manifest.clip_plans)?;

    manifest.run_summary.notes = truncate_with_ellipsis(manifest.run_summary.notes.trim(), 800);
    Ok(manifest)
}

fn normalize_insight_post_items(
    mut items: Vec<InsightPostCandidate>,
) -> Result<Vec<InsightPostCandidate>> {
    if items.len() > MAX_INSIGHT_POSTS {
        items.truncate(MAX_INSIGHT_POSTS);
    }
    let mut used_ids = HashSet::new();
    for item in &mut items {
        item.text = truncate_with_ellipsis(item.text.trim(), 480);
        item.source_path = normalize_source_path(&item.source_path)?;
        item.source_excerpt = truncate_with_ellipsis(item.source_excerpt.trim(), 280);
        if item.text.trim().is_empty() {
            anyhow::bail!("insightPosts items require non-empty text");
        }
        let seed = format!("{}|{}|{}", item.text, item.source_path, item.source_excerpt);
        item.id = unique_id(&used_ids, &item.id, &seed, "post");
        used_ids.insert(item.id.clone());
    }
    Ok(items)
}

fn normalize_todo_items(mut items: Vec<TodoCandidate>) -> Result<Vec<TodoCandidate>> {
    if items.len() > MAX_TODOS {
        items.truncate(MAX_TODOS);
    }
    let mut used_ids = HashSet::new();
    for item in &mut items {
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
        item.id = unique_id(&used_ids, &item.id, &seed, "todo");
        used_ids.insert(item.id.clone());
    }
    Ok(items)
}

fn normalize_event_items(mut items: Vec<EventCandidate>) -> Result<Vec<EventCandidate>> {
    if items.len() > MAX_EVENTS {
        items.truncate(MAX_EVENTS);
    }
    let mut used_ids = HashSet::new();
    for item in &mut items {
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
        item.id = unique_id(&used_ids, &item.id, &seed, "event");
        used_ids.insert(item.id.clone());
    }
    Ok(items)
}

fn normalize_clip_plan_items(mut items: Vec<ClipPlanCandidate>) -> Result<Vec<ClipPlanCandidate>> {
    if items.len() > MAX_CLIP_PLANS {
        items.truncate(MAX_CLIP_PLANS);
    }
    let mut used_ids = HashSet::new();
    for item in &mut items {
        item.title = truncate_with_ellipsis(item.title.trim(), 120);
        item.transcript_quote = truncate_with_ellipsis(item.transcript_quote.trim(), 400);
        item.notes = truncate_with_ellipsis(item.notes.trim(), 600);
        item.start_at = item.start_at.trim().to_string();
        item.end_at = item.end_at.trim().to_string();
        item.source_path = normalize_source_path(&item.source_path)?;
        item.source_excerpt = truncate_with_ellipsis(item.source_excerpt.trim(), 280);
        if !item.source_path.starts_with("journals/text/transcriptions/")
            && !item.source_path.starts_with("journals/text/transcript/")
        {
            anyhow::bail!(
                "clipPlans items must point to transcript sidecars under journals/text/transcriptions"
            );
        }
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
        item.id = unique_id(&used_ids, &item.id, &seed, "clip");
        used_ids.insert(item.id.clone());
    }
    Ok(items)
}

fn normalize_journal_title_items(
    mut items: Vec<JournalTitleCandidate>,
) -> Result<Vec<JournalTitleCandidate>> {
    if items.len() > MAX_JOURNAL_TITLES {
        items.truncate(MAX_JOURNAL_TITLES);
    }
    let mut used_paths = HashSet::new();
    let mut out = Vec::new();
    for mut item in items {
        item.source_path = normalize_source_path(&item.source_path)?;
        if item.source_path.starts_with("journals/text/transcriptions/")
            || item.source_path.starts_with("journals/text/transcript/")
        {
            anyhow::bail!("journalTitles items must point to journal note files, not transcript sidecars");
        }
        item.title = truncate_with_ellipsis(item.title.trim(), 120);
        if item.title.is_empty() {
            anyhow::bail!("journalTitles items require non-empty title");
        }
        if used_paths.insert(item.source_path.clone()) {
            out.push(item);
        }
    }
    Ok(out)
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

fn normalize_title_stem(raw: &str) -> String {
    let mut out = String::new();
    let mut prev_sep = false;
    for ch in raw.trim().chars() {
        let lower = ch.to_ascii_lowercase();
        if lower.is_ascii_alphanumeric() {
            out.push(lower);
            prev_sep = false;
        } else if !prev_sep {
            out.push('-');
            prev_sep = true;
        }
    }
    out.trim_matches('-').to_string()
}

fn apply_source_path_renames(
    journal_titles: &[JournalTitleCandidate],
    workspace_dir: &Path,
) -> Result<HashMap<String, String>> {
    let mut rename_map = HashMap::new();
    let mut reserved_targets = HashSet::new();
    for item in journal_titles {
        let old_rel = item.source_path.trim();
        if old_rel.is_empty() {
            continue;
        }
        let old_abs = workspace_dir.join(old_rel);
        if !old_abs.is_file() {
            continue;
        }
        let extension = old_abs
            .extension()
            .and_then(|value| value.to_str())
            .unwrap_or("md")
            .to_string();
        let parent = old_abs
            .parent()
            .with_context(|| format!("missing parent for {}", old_abs.display()))?;
        let mut stem = normalize_title_stem(&item.title);
        if stem.is_empty() {
            stem = format!("journal-{}", short_hash(old_rel));
        }
        let old_stem = old_abs
            .file_stem()
            .and_then(|value| value.to_str())
            .unwrap_or("")
            .to_ascii_lowercase();
        if stem == old_stem {
            continue;
        }

        let mut candidate_rel = format!(
            "{}/{}.{}",
            parent
                .strip_prefix(workspace_dir)
                .unwrap_or(parent)
                .to_string_lossy()
                .replace('\\', "/"),
            stem,
            extension
        );
        let mut candidate_abs = workspace_dir.join(&candidate_rel);
        if reserved_targets.contains(&candidate_rel)
            || (candidate_abs.exists() && candidate_abs != old_abs)
        {
            let suffix = short_hash(&format!("{}|{}", old_rel, item.title));
            candidate_rel = format!(
                "{}/{}-{}.{}",
                parent
                    .strip_prefix(workspace_dir)
                    .unwrap_or(parent)
                    .to_string_lossy()
                    .replace('\\', "/"),
                stem,
                suffix,
                extension
            );
            candidate_abs = workspace_dir.join(&candidate_rel);
        }

        if candidate_abs != old_abs {
            fs::rename(&old_abs, &candidate_abs).with_context(|| {
                format!("failed to rename {} -> {}", old_abs.display(), candidate_abs.display())
            })?;
            let _ = local_store::rename_workspace_synth_source_path(
                workspace_dir,
                old_rel,
                &candidate_rel,
            );
            let _ =
                local_store::rename_journal_entry_path(workspace_dir, old_rel, &candidate_rel, &item.title);
            reserved_targets.insert(candidate_rel.clone());
            rename_map.insert(old_rel.to_string(), candidate_rel);
        }
    }
    Ok(rename_map)
}

fn rewrite_source_path(path: &mut String, rename_map: &HashMap<String, String>) {
    if let Some(next) = rename_map.get(path.trim()) {
        *path = next.clone();
    }
}

pub fn apply_manifest(
    workspace_dir: &Path,
    manifest: &WorkspaceSynthesisManifest,
    manifest_id: &str,
) -> Result<WorkspaceSynthesisApplyResult> {
    local_store::initialize(workspace_dir)?;
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

    let processed_source_paths = collect_processed_source_paths(
        &manifest.insight_posts,
        &manifest.todos,
        &manifest.events,
        &manifest.clip_plans,
    );
    let todo_count = local_store::replace_workspace_todos(
        workspace_dir,
        &todo_items,
        manifest_id,
        &processed_source_paths,
    )?;
    let event_count = local_store::replace_workspace_events(
        workspace_dir,
        &event_items,
        manifest_id,
        &processed_source_paths,
    )?;
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
        renamed_sources: Vec::new(),
        counts,
        summary,
        artifact_states: WorkspaceSynthArtifactStates::default(),
        applied_any: true,
        had_errors: false,
    })
}

fn skipped_artifact_state(path: &str) -> WorkspaceSynthArtifactState {
    WorkspaceSynthArtifactState {
        status: "skipped".to_string(),
        path: path.to_string(),
        item_count: 0,
        error: String::new(),
    }
}

fn applied_artifact_state(path: &str, item_count: usize) -> WorkspaceSynthArtifactState {
    WorkspaceSynthArtifactState {
        status: "applied".to_string(),
        path: path.to_string(),
        item_count,
        error: String::new(),
    }
}

fn error_artifact_state(path: &str, err: &anyhow::Error) -> WorkspaceSynthArtifactState {
    WorkspaceSynthArtifactState {
        status: "error".to_string(),
        path: path.to_string(),
        item_count: 0,
        error: truncate_with_ellipsis(&format!("{err:#}"), 800),
    }
}

fn build_apply_summary(
    counts: &WorkspaceSynthArtifactCounts,
    renamed_count: usize,
    had_errors: bool,
    applied_any: bool,
    error_messages: &[String],
) -> String {
    let mut base = format!(
        "Applied workspace synthesis: {} feed posts, {} todos, {} events, {} clip plans.",
        counts.insight_posts, counts.todos, counts.events, counts.clip_plans
    );
    if renamed_count > 0 {
        base.push_str(&format!(" Retitled {} journal note{}.", renamed_count, if renamed_count == 1 { "" } else { "s" }));
    }
    if !had_errors {
        return base;
    }
    let issues = error_messages.join(" | ");
    if applied_any {
        format!("{base} Partial issues: {issues}")
    } else {
        format!("Workspace synthesis did not apply any handoff files. Issues: {issues}")
    }
}

pub fn apply_handoff_files(
    workspace_dir: &Path,
    manifest_id: &str,
    processed_source_paths: &[String],
) -> Result<WorkspaceSynthesisApplyResult> {
    local_store::initialize(workspace_dir)?;
    let output_root = workspace_dir.join(WORKSPACE_SYNTHESIZER_OUTPUT_ROOT);
    let clip_dir = workspace_dir.join(WORKSPACE_SYNTHESIZER_CLIP_PLAN_DIR);
    let pipeline_root = pipeline_dir(workspace_dir);
    fs::create_dir_all(&output_root)
        .with_context(|| format!("failed to create {}", output_root.display()))?;
    fs::create_dir_all(&clip_dir)
        .with_context(|| format!("failed to create {}", clip_dir.display()))?;
    fs::create_dir_all(&pipeline_root)
        .with_context(|| format!("failed to create {}", pipeline_root.display()))?;

    let insight_posts_file_path = insight_posts_path(workspace_dir);
    let todos_file_path = todos_path(workspace_dir);
    let events_file_path = events_path(workspace_dir);
    let clip_plans_file_path = clip_plans_path(workspace_dir);
    let journal_titles_file_path = journal_titles_path(workspace_dir);

    let mut result = WorkspaceSynthesisApplyResult {
        artifact_states: WorkspaceSynthArtifactStates {
            insight_posts: skipped_artifact_state(WORKSPACE_SYNTHESIZER_INSIGHT_POSTS_PATH),
            todos: skipped_artifact_state(WORKSPACE_SYNTHESIZER_TODOS_PATH),
            events: skipped_artifact_state(WORKSPACE_SYNTHESIZER_EVENTS_PATH),
            clip_plans: skipped_artifact_state(WORKSPACE_SYNTHESIZER_CLIP_PLANS_PATH),
        },
        ..WorkspaceSynthesisApplyResult::default()
    };
    let mut saw_split_file = false;
    let mut error_messages = Vec::new();
    let mut insight_items: Option<Vec<InsightPostCandidate>> = None;
    let mut todo_items_raw: Option<Vec<TodoCandidate>> = None;
    let mut event_items_raw: Option<Vec<EventCandidate>> = None;
    let mut clip_plan_items: Option<Vec<ClipPlanCandidate>> = None;
    let mut journal_title_items: Option<Vec<JournalTitleCandidate>> = None;

    if insight_posts_file_path.is_file() {
        saw_split_file = true;
        match load_optional_insight_posts_file(workspace_dir) {
            Ok(Some(items)) => insight_items = Some(items),
            Ok(None) => {}
            Err(err) => {
                result.had_errors = true;
                result.artifact_states.insight_posts =
                    error_artifact_state(WORKSPACE_SYNTHESIZER_INSIGHT_POSTS_PATH, &err);
                error_messages.push(format!("insight posts: {err}"));
            }
        }
    }

    if todos_file_path.is_file() {
        saw_split_file = true;
        match load_optional_todos_file(workspace_dir) {
            Ok(Some(items)) => todo_items_raw = Some(items),
            Ok(None) => {}
            Err(err) => {
                result.had_errors = true;
                result.artifact_states.todos =
                    error_artifact_state(WORKSPACE_SYNTHESIZER_TODOS_PATH, &err);
                error_messages.push(format!("todos: {err}"));
            }
        }
    }

    if events_file_path.is_file() {
        saw_split_file = true;
        match load_optional_events_file(workspace_dir) {
            Ok(Some(items)) => event_items_raw = Some(items),
            Ok(None) => {}
            Err(err) => {
                result.had_errors = true;
                result.artifact_states.events =
                    error_artifact_state(WORKSPACE_SYNTHESIZER_EVENTS_PATH, &err);
                error_messages.push(format!("events: {err}"));
            }
        }
    }

    if clip_plans_file_path.is_file() {
        saw_split_file = true;
        match load_optional_clip_plans_file(workspace_dir) {
            Ok(Some(items)) => clip_plan_items = Some(items),
            Ok(None) => {}
            Err(err) => {
                result.had_errors = true;
                result.artifact_states.clip_plans =
                    error_artifact_state(WORKSPACE_SYNTHESIZER_CLIP_PLANS_PATH, &err);
                error_messages.push(format!("clip plans: {err}"));
            }
        }
    }

    if journal_titles_file_path.is_file() {
        saw_split_file = true;
        match load_optional_journal_titles_file(workspace_dir) {
            Ok(Some(items)) => journal_title_items = Some(items),
            Ok(None) => {}
            Err(err) => {
                result.had_errors = true;
                error_messages.push(format!("journal titles: {err}"));
            }
        }
    }

    let rename_map = match journal_title_items.as_deref() {
        Some(items) if !items.is_empty() => match apply_source_path_renames(items, workspace_dir) {
            Ok(map) => map,
            Err(err) => {
                result.had_errors = true;
                error_messages.push(format!("journal titles: {err}"));
                HashMap::new()
            }
        },
        _ => HashMap::new(),
    };
    if !rename_map.is_empty() {
        result.renamed_sources = rename_map
            .iter()
            .map(|(from_path, to_path)| WorkspaceSynthRenamedSource {
                from_path: from_path.clone(),
                to_path: to_path.clone(),
            })
            .collect();
        result.applied_any = true;
        if let Some(items) = insight_items.as_mut() {
            for item in items {
                rewrite_source_path(&mut item.source_path, &rename_map);
            }
        }
        if let Some(items) = todo_items_raw.as_mut() {
            for item in items {
                rewrite_source_path(&mut item.source_path, &rename_map);
            }
        }
        if let Some(items) = event_items_raw.as_mut() {
            for item in items {
                rewrite_source_path(&mut item.source_path, &rename_map);
            }
        }
        if let Some(items) = clip_plan_items.as_mut() {
            for item in items {
                rewrite_source_path(&mut item.source_path, &rename_map);
            }
        }
    }

    if let Some(items) = insight_items {
        match write_insight_posts(&output_root, &items) {
            Ok(paths) => {
                result.counts.insight_posts = paths.len();
                result.insight_post_paths = paths;
                result.artifact_states.insight_posts =
                    applied_artifact_state(WORKSPACE_SYNTHESIZER_INSIGHT_POSTS_PATH, items.len());
                result.applied_any = true;
            }
            Err(err) => {
                result.had_errors = true;
                result.artifact_states.insight_posts =
                    error_artifact_state(WORKSPACE_SYNTHESIZER_INSIGHT_POSTS_PATH, &err);
                error_messages.push(format!("insight posts: {err}"));
            }
        }
    }

    if let Some(items) = todo_items_raw {
        let todo_items: Vec<local_store::WorkspaceTodoUpsert> = items
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
        match local_store::replace_workspace_todos(
            workspace_dir,
            &todo_items,
            manifest_id,
            processed_source_paths,
        ) {
            Ok(written) => {
                result.counts.todos = written;
                result.artifact_states.todos =
                    applied_artifact_state(WORKSPACE_SYNTHESIZER_TODOS_PATH, items.len());
                result.applied_any = true;
            }
            Err(err) => {
                result.had_errors = true;
                result.artifact_states.todos =
                    error_artifact_state(WORKSPACE_SYNTHESIZER_TODOS_PATH, &err);
                error_messages.push(format!("todos: {err}"));
            }
        }
    }

    if let Some(items) = event_items_raw {
        let event_items: Vec<local_store::WorkspaceEventUpsert> = items
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
        match local_store::replace_workspace_events(
            workspace_dir,
            &event_items,
            manifest_id,
            processed_source_paths,
        ) {
            Ok(written) => {
                result.counts.events = written;
                result.artifact_states.events =
                    applied_artifact_state(WORKSPACE_SYNTHESIZER_EVENTS_PATH, items.len());
                result.applied_any = true;
            }
            Err(err) => {
                result.had_errors = true;
                result.artifact_states.events =
                    error_artifact_state(WORKSPACE_SYNTHESIZER_EVENTS_PATH, &err);
                error_messages.push(format!("events: {err}"));
            }
        }
    }

    if let Some(items) = clip_plan_items {
        match write_clip_plans(&clip_dir, &items) {
            Ok(paths) => {
                result.counts.clip_plans = paths.len();
                result.clip_plan_paths = paths;
                result.artifact_states.clip_plans =
                    applied_artifact_state(WORKSPACE_SYNTHESIZER_CLIP_PLANS_PATH, items.len());
                result.applied_any = true;
            }
            Err(err) => {
                result.had_errors = true;
                result.artifact_states.clip_plans =
                    error_artifact_state(WORKSPACE_SYNTHESIZER_CLIP_PLANS_PATH, &err);
                error_messages.push(format!("clip plans: {err}"));
            }
        }
    }

    if saw_split_file {
        result.summary = build_apply_summary(
            &result.counts,
            result.renamed_sources.len(),
            result.had_errors,
            result.applied_any,
            &error_messages,
        );
        return Ok(result);
    }

    let legacy_manifest = load_manifest(workspace_dir)?;
    let mut legacy_result = apply_manifest(workspace_dir, &legacy_manifest, manifest_id)?;
    legacy_result.artifact_states = WorkspaceSynthArtifactStates {
        insight_posts: applied_artifact_state(
            WORKSPACE_SYNTHESIZER_MANIFEST_PATH,
            legacy_manifest.insight_posts.len(),
        ),
        todos: applied_artifact_state(
            WORKSPACE_SYNTHESIZER_MANIFEST_PATH,
            legacy_manifest.todos.len(),
        ),
        events: applied_artifact_state(
            WORKSPACE_SYNTHESIZER_MANIFEST_PATH,
            legacy_manifest.events.len(),
        ),
        clip_plans: applied_artifact_state(
            WORKSPACE_SYNTHESIZER_MANIFEST_PATH,
            legacy_manifest.clip_plans.len(),
        ),
    };
    Ok(legacy_result)
}

fn collect_processed_source_paths(
    insight_posts: &[InsightPostCandidate],
    todos: &[TodoCandidate],
    events: &[EventCandidate],
    clip_plans: &[ClipPlanCandidate],
) -> Vec<String> {
    let mut seen = HashSet::new();
    let mut out = Vec::new();
    for source_path in insight_posts
        .iter()
        .map(|item| item.source_path.as_str())
        .chain(todos.iter().map(|item| item.source_path.as_str()))
        .chain(events.iter().map(|item| item.source_path.as_str()))
        .chain(clip_plans.iter().map(|item| item.source_path.as_str()))
    {
        let trimmed = source_path.trim();
        if !trimmed.is_empty() && seen.insert(trimmed.to_string()) {
            out.push(trimmed.to_string());
        }
    }
    out
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
    use tempfile::tempdir;

    fn write_json_file<T: Serialize>(path: &Path, value: &T) {
        if let Some(parent) = path.parent() {
            fs::create_dir_all(parent).unwrap();
        }
        fs::write(path, serde_json::to_string_pretty(value).unwrap()).unwrap();
    }

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

    #[test]
    fn normalize_clip_plan_items_rejects_non_transcript_sources() {
        let err = normalize_clip_plan_items(vec![ClipPlanCandidate {
            title: "Moment".to_string(),
            transcript_quote: "Quote".to_string(),
            start_at: "00:00:01.000".to_string(),
            end_at: "00:00:05.000".to_string(),
            source_path: "journals/text/2026-03-11.md".to_string(),
            source_excerpt: "Quote".to_string(),
            ..ClipPlanCandidate::default()
        }])
        .unwrap_err();

        assert!(format!("{err:#}").contains("clipPlans items must point to transcript sidecars"));
    }

    #[test]
    fn apply_handoff_files_applies_present_files_and_skips_missing_ones() {
        let tmp = tempdir().unwrap();
        let insight_posts = InsightPostFile {
            version: "1".to_string(),
            items: vec![InsightPostCandidate {
                id: "ship-note".to_string(),
                text: "Ship the sharper workflow.".to_string(),
                source_path: "journals/text/2026-03-11.md".to_string(),
                source_excerpt: "Ship the sharper workflow.".to_string(),
            }],
        };
        let todos = TodoFile {
            version: "1".to_string(),
            items: vec![TodoCandidate {
                id: "email-team".to_string(),
                title: "Email the team".to_string(),
                details: "Share the workspace synthesis update.".to_string(),
                priority: "high".to_string(),
                status: "open".to_string(),
                due_at: "2026-03-12T09:00:00Z".to_string(),
                source_path: "journals/text/2026-03-11.md".to_string(),
                source_excerpt: "Need to email the team tomorrow morning.".to_string(),
            }],
        };
        write_json_file(&insight_posts_path(tmp.path()), &insight_posts);
        write_json_file(&todos_path(tmp.path()), &todos);

        let processed_source_paths = vec!["journals/text/2026-03-11.md".to_string()];
        let applied = apply_handoff_files(tmp.path(), "run-1", &processed_source_paths).unwrap();

        assert!(applied.applied_any);
        assert!(!applied.had_errors);
        assert_eq!(applied.counts.insight_posts, 1);
        assert_eq!(applied.counts.todos, 1);
        assert_eq!(applied.counts.events, 0);
        assert_eq!(applied.counts.clip_plans, 0);
        assert_eq!(applied.artifact_states.insight_posts.status, "applied");
        assert_eq!(applied.artifact_states.todos.status, "applied");
        assert_eq!(applied.artifact_states.events.status, "skipped");
        assert_eq!(applied.artifact_states.clip_plans.status, "skipped");
        assert!(tmp
            .path()
            .join("posts/workspace_synthesizer/ship-note.md")
            .exists());

        let todo_rows = local_store::list_workspace_todos(tmp.path(), 20).unwrap();
        assert_eq!(todo_rows.len(), 1);
    }

    #[test]
    fn apply_handoff_files_keeps_valid_outputs_when_one_type_fails() {
        let tmp = tempdir().unwrap();
        let insight_posts = InsightPostFile {
            version: "1".to_string(),
            items: vec![InsightPostCandidate {
                id: "good-post".to_string(),
                text: "Capture the clean takeaway.".to_string(),
                source_path: "journals/text/2026-03-11.md".to_string(),
                source_excerpt: "Capture the clean takeaway.".to_string(),
            }],
        };
        write_json_file(&insight_posts_path(tmp.path()), &insight_posts);

        let events_raw = r#"{
          "version": "1",
          "items": [
            {
              "id": "broken-event",
              "title": "Launch review",
              "sourcePath": "journals/text/2026-03-11.md",
              "sourceExcerpt": "Launch review tomorrow."
            }
          ]
        }"#;
        let events_path = events_path(tmp.path());
        if let Some(parent) = events_path.parent() {
            fs::create_dir_all(parent).unwrap();
        }
        fs::write(&events_path, events_raw).unwrap();

        let processed_source_paths = vec!["journals/text/2026-03-11.md".to_string()];
        let applied = apply_handoff_files(tmp.path(), "run-2", &processed_source_paths).unwrap();

        assert!(applied.applied_any);
        assert!(applied.had_errors);
        assert_eq!(applied.artifact_states.insight_posts.status, "applied");
        assert_eq!(applied.artifact_states.events.status, "error");
        assert!(applied.summary.contains("Partial issues"));
        assert!(tmp
            .path()
            .join("posts/workspace_synthesizer/good-post.md")
            .exists());
    }

    #[test]
    fn apply_handoff_files_falls_back_to_legacy_manifest() {
        let tmp = tempdir().unwrap();
        let manifest = WorkspaceSynthesisManifest {
            version: "1".to_string(),
            events: vec![EventCandidate {
                id: "launch-review".to_string(),
                title: "Launch review".to_string(),
                start_at: "2026-03-12T09:00:00Z".to_string(),
                source_path: "journals/text/2026-03-11.md".to_string(),
                source_excerpt: "Launch review tomorrow at 9.".to_string(),
                ..EventCandidate::default()
            }],
            ..WorkspaceSynthesisManifest::default()
        };
        write_json_file(&manifest_path(tmp.path()), &manifest);

        let processed_source_paths = vec!["journals/text/2026-03-11.md".to_string()];
        let applied = apply_handoff_files(tmp.path(), "run-legacy", &processed_source_paths).unwrap();

        assert!(applied.applied_any);
        assert!(!applied.had_errors);
        assert_eq!(applied.counts.events, 1);
        assert_eq!(
            applied.artifact_states.events.path,
            WORKSPACE_SYNTHESIZER_MANIFEST_PATH
        );
        let event_rows = local_store::list_workspace_events(tmp.path(), 20).unwrap();
        assert_eq!(event_rows.len(), 1);
    }
}
