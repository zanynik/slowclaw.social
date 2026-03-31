use crate::gateway::article_synthesizer;
use crate::gateway::local_store;
use crate::util::truncate_with_ellipsis;
use anyhow::{Context, Result};
use chrono::{DateTime, Datelike, Utc};
use schemars::{schema_for, JsonSchema};
use serde::de::DeserializeOwned;
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
pub const WORKSPACE_SYNTHESIZER_PRIMITIVES_DIR: &str =
    "posts/workspace_synthesizer/pipeline/primitives";
pub const WORKSPACE_SYNTHESIZER_PRIMITIVE_ENTITIES_PATH: &str =
    "posts/workspace_synthesizer/pipeline/primitives/entities.json";
pub const WORKSPACE_SYNTHESIZER_PRIMITIVE_EVENTS_PATH: &str =
    "posts/workspace_synthesizer/pipeline/primitives/events.json";
pub const WORKSPACE_SYNTHESIZER_PRIMITIVE_ASSERTIONS_PATH: &str =
    "posts/workspace_synthesizer/pipeline/primitives/assertions.json";
pub const WORKSPACE_SYNTHESIZER_PRIMITIVE_ACTIONS_PATH: &str =
    "posts/workspace_synthesizer/pipeline/primitives/actions.json";
pub const WORKSPACE_SYNTHESIZER_PRIMITIVE_SEGMENTS_PATH: &str =
    "posts/workspace_synthesizer/pipeline/primitives/segments.json";
pub const WORKSPACE_SYNTHESIZER_PRIMITIVE_STRUCTURES_PATH: &str =
    "posts/workspace_synthesizer/pipeline/primitives/structures.json";
pub const WORKSPACE_SYNTHESIZER_MANIFEST_PATH: &str =
    "posts/workspace_synthesizer/pipeline/synthesis_manifest.json";
pub const WORKSPACE_SYNTHESIZER_CLIP_PLAN_DIR: &str = "posts/workspace_synthesizer/pipeline/clips";
const WORKSPACE_SYNTHESIZER_STATUS_PATH: &str = "state/workspace_synthesizer_status.json";
const WORKSPACE_SYNTH_SKILLS_PATH: &str = "state/workspace_synth_skills.json";
pub const WORKSPACE_ENTITY_EXTRACTOR_WORKFLOW_KEY: &str = "workspace_entity_extractor";
pub const WORKSPACE_ACTION_EXTRACTOR_WORKFLOW_KEY: &str = "workspace_action_extractor";
pub const WORKSPACE_PRIMITIVE_EVENT_EXTRACTOR_WORKFLOW_KEY: &str =
    "workspace_primitive_event_extractor";
pub const WORKSPACE_ASSERTION_EXTRACTOR_WORKFLOW_KEY: &str = "workspace_assertion_extractor";
pub const WORKSPACE_SEGMENT_EXTRACTOR_WORKFLOW_KEY: &str = "workspace_segment_extractor";
const MAX_INSIGHT_POSTS: usize = 18;
const MAX_TODOS: usize = 30;
const MAX_EVENTS: usize = 20;
const MAX_CLIP_PLANS: usize = 12;
const MAX_JOURNAL_TITLES: usize = 8;
const MAX_ENTITIES: usize = 80;
const MAX_ASSERTIONS: usize = 60;
const MAX_ACTIONS: usize = 30;
const MAX_SEGMENTS: usize = 40;
const MAX_STRUCTURES: usize = 24;

/// Timeout for the triage classification call (seconds).
pub const WORKSPACE_SYNTH_TRIAGE_TIMEOUT_SECS: u64 = 60;

/// Result of the triage classification step.
/// The triage call inspects a batch of journal notes and returns which
/// extraction skills are relevant, plus topical keywords extracted from the
/// content. This avoids running every enabled skill on every batch.
#[derive(Debug, Clone, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub struct TriageResult {
    /// Skill keys that should run for this batch.
    #[serde(default, alias = "relevant_skills")]
    pub relevant_skills: Vec<String>,
    /// Topical keywords extracted from the batch for interest profile feeding.
    #[serde(default)]
    pub keywords: Vec<String>,
}

/// Parse a triage JSON response from the LLM.
///
/// Accepts both raw JSON and markdown-fenced JSON. Returns `None` on any
/// parse failure so the caller can fall through to the default (run all
/// enabled skills).
pub fn parse_triage_response(raw: &str) -> Option<TriageResult> {
    let trimmed = raw.trim();
    // Strip optional markdown code fences.
    let json_str = if trimmed.starts_with("```") {
        let inner = trimmed
            .trim_start_matches("```json")
            .trim_start_matches("```")
            .trim_end_matches("```")
            .trim();
        inner
    } else {
        trimmed
    };
    // Try to find a JSON object in the text.
    let start = json_str.find('{')?;
    let end = json_str.rfind('}')?;
    if end <= start {
        return None;
    }
    let candidate = &json_str[start..=end];
    let result: TriageResult = serde_json::from_str(candidate).ok()?;
    // Normalize skill keys to lowercase.
    let relevant_skills = result
        .relevant_skills
        .into_iter()
        .map(|k| k.trim().to_ascii_lowercase())
        .filter(|k| !k.is_empty())
        .collect();
    let keywords = result
        .keywords
        .into_iter()
        .map(|k| k.trim().to_string())
        .filter(|k| !k.is_empty())
        .take(12)
        .collect();
    Some(TriageResult {
        relevant_skills,
        keywords,
    })
}

#[derive(Debug, Clone, Copy)]
pub struct WorkspaceSynthExtractorSpec {
    pub workflow_key: &'static str,
    pub name: &'static str,
    pub goal: &'static str,
    pub handoff_path: &'static str,
    pub max_items: usize,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "snake_case")]
pub enum WorkspaceSynthSkillHandlerKind {
    SplitHandoff,
    ArticleHandoff,
    DirectPostOutput,
    DirectMediaOutput,
}

impl Default for WorkspaceSynthSkillHandlerKind {
    fn default() -> Self {
        Self::SplitHandoff
    }
}

#[derive(Debug, Clone, Copy)]
pub struct WorkspaceSynthSkillSpec {
    pub key: &'static str,
    pub name: &'static str,
    pub goal: &'static str,
    pub output_prefix: &'static str,
    pub handler_kind: WorkspaceSynthSkillHandlerKind,
    pub enabled_by_default: bool,
    pub visible_in_ui: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub struct WorkspaceSynthSkillRecord {
    #[serde(default)]
    pub skill_key: String,
    #[serde(default)]
    pub name: String,
    #[serde(default)]
    pub skill_path: String,
    #[serde(default)]
    pub output_prefix: String,
    #[serde(default = "default_skill_enabled")]
    pub enabled: bool,
    #[serde(default)]
    pub goal: String,
    #[serde(default)]
    pub built_in_skill_fingerprint: Option<String>,
    #[serde(default = "default_skill_visible_in_ui")]
    pub visible_in_ui: bool,
    #[serde(default)]
    pub handler_kind: WorkspaceSynthSkillHandlerKind,
    #[serde(default)]
    pub artifact_rules_override: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub struct WorkspaceSynthSkillStore {
    #[serde(default)]
    pub skills: HashMap<String, WorkspaceSynthSkillRecord>,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub struct WorkspaceSynthSkillResponseItem {
    #[serde(default)]
    pub skill_key: String,
    #[serde(default)]
    pub name: String,
    #[serde(default)]
    pub skill_path: String,
    #[serde(default)]
    pub output_prefix: String,
    #[serde(default)]
    pub enabled: bool,
    #[serde(default)]
    pub supported: bool,
    #[serde(default)]
    pub unsupported_reason: Option<String>,
    #[serde(default)]
    pub goal: String,
    #[serde(default)]
    pub handler_kind: WorkspaceSynthSkillHandlerKind,
    #[serde(default)]
    pub artifact_rules: String,
    #[serde(default)]
    pub artifact_rules_override: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub struct WorkspaceSynthSkillRunState {
    #[serde(default)]
    pub skill_key: String,
    #[serde(default)]
    pub name: String,
    #[serde(default)]
    pub output_prefix: String,
    #[serde(default)]
    pub handler_kind: WorkspaceSynthSkillHandlerKind,
    #[serde(default)]
    pub status: String,
    #[serde(default)]
    pub summary: String,
    #[serde(default)]
    pub error: String,
    #[serde(default)]
    pub item_count: usize,
    #[serde(default)]
    pub started_at: String,
    #[serde(default)]
    pub finished_at: String,
    #[serde(default)]
    pub duration_ms: u64,
}

#[derive(Debug, Clone)]
pub struct WorkspaceSynthSkillDefinition {
    pub key: String,
    pub name: String,
    pub skill_path: String,
    pub output_prefix: String,
    pub goal: String,
    pub handler_kind: WorkspaceSynthSkillHandlerKind,
    pub visible_in_ui: bool,
    pub artifact_rules_override: String,
}

const WORKSPACE_SYNTH_EXTRACTOR_SPECS: [WorkspaceSynthExtractorSpec; 10] = [
    WorkspaceSynthExtractorSpec {
        workflow_key: WORKSPACE_ENTITY_EXTRACTOR_WORKFLOW_KEY,
        name: "Workspace Entity Extractor",
        goal: "Extract canonical entities from recent journals and transcripts. Write only the primitive entities handoff JSON for Rust to compile into downstream outputs.",
        handoff_path: WORKSPACE_SYNTHESIZER_PRIMITIVE_ENTITIES_PATH,
        max_items: MAX_ENTITIES,
    },
    WorkspaceSynthExtractorSpec {
        workflow_key: WORKSPACE_ACTION_EXTRACTOR_WORKFLOW_KEY,
        name: "Workspace Action Extractor",
        goal: "Extract explicit actions, commitments, and follow-ups from recent journals and transcripts. Write only the primitive actions handoff JSON for Rust to compile into planner outputs.",
        handoff_path: WORKSPACE_SYNTHESIZER_PRIMITIVE_ACTIONS_PATH,
        max_items: MAX_ACTIONS,
    },
    WorkspaceSynthExtractorSpec {
        workflow_key: WORKSPACE_PRIMITIVE_EVENT_EXTRACTOR_WORKFLOW_KEY,
        name: "Workspace Primitive Event Extractor",
        goal: "Extract scheduled or notable events from recent journals and transcripts. Write only the primitive events handoff JSON for Rust to compile into planner outputs and timelines.",
        handoff_path: WORKSPACE_SYNTHESIZER_PRIMITIVE_EVENTS_PATH,
        max_items: MAX_EVENTS,
    },
    WorkspaceSynthExtractorSpec {
        workflow_key: WORKSPACE_ASSERTION_EXTRACTOR_WORKFLOW_KEY,
        name: "Workspace Assertion Extractor",
        goal: "Extract explicit claims, beliefs, questions, and decisions from recent journals and transcripts. Write only the primitive assertions handoff JSON for Rust to compile into downstream outputs.",
        handoff_path: WORKSPACE_SYNTHESIZER_PRIMITIVE_ASSERTIONS_PATH,
        max_items: MAX_ASSERTIONS,
    },
    WorkspaceSynthExtractorSpec {
        workflow_key: WORKSPACE_SEGMENT_EXTRACTOR_WORKFLOW_KEY,
        name: "Workspace Segment Extractor",
        goal: "Extract named spans from recent journals and transcripts. Use timestamps when transcript timing is available and write only the primitive segments handoff JSON for Rust to compile into clip plans and navigation structures.",
        handoff_path: WORKSPACE_SYNTHESIZER_PRIMITIVE_SEGMENTS_PATH,
        max_items: MAX_SEGMENTS,
    },
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

const WORKSPACE_SYNTH_SKILL_SPECS: [WorkspaceSynthSkillSpec; 14] = [
    WorkspaceSynthSkillSpec {
        key: WORKSPACE_ENTITY_EXTRACTOR_WORKFLOW_KEY,
        name: "Workspace Entity Extractor",
        goal: "Extract canonical entities from recent journals and transcripts. Write only the primitive entities handoff JSON for Rust to compile into downstream outputs.",
        output_prefix: "posts/workspace_synthesizer/",
        handler_kind: WorkspaceSynthSkillHandlerKind::SplitHandoff,
        enabled_by_default: false,
        visible_in_ui: false,
    },
    WorkspaceSynthSkillSpec {
        key: WORKSPACE_ACTION_EXTRACTOR_WORKFLOW_KEY,
        name: "Workspace Action Extractor",
        goal: "Extract explicit actions, commitments, and follow-ups from recent journals and transcripts. Write only the primitive actions handoff JSON for Rust to compile into planner outputs.",
        output_prefix: "posts/workspace_synthesizer/",
        handler_kind: WorkspaceSynthSkillHandlerKind::SplitHandoff,
        enabled_by_default: false,
        visible_in_ui: false,
    },
    WorkspaceSynthSkillSpec {
        key: WORKSPACE_PRIMITIVE_EVENT_EXTRACTOR_WORKFLOW_KEY,
        name: "Workspace Primitive Event Extractor",
        goal: "Extract scheduled or notable events from recent journals and transcripts. Write only the primitive events handoff JSON for Rust to compile into planner outputs and timelines.",
        output_prefix: "posts/workspace_synthesizer/",
        handler_kind: WorkspaceSynthSkillHandlerKind::SplitHandoff,
        enabled_by_default: false,
        visible_in_ui: false,
    },
    WorkspaceSynthSkillSpec {
        key: WORKSPACE_ASSERTION_EXTRACTOR_WORKFLOW_KEY,
        name: "Workspace Assertion Extractor",
        goal: "Extract explicit claims, beliefs, questions, and decisions from recent journals and transcripts. Write only the primitive assertions handoff JSON for Rust to compile into downstream outputs.",
        output_prefix: "posts/workspace_synthesizer/",
        handler_kind: WorkspaceSynthSkillHandlerKind::SplitHandoff,
        enabled_by_default: false,
        visible_in_ui: false,
    },
    WorkspaceSynthSkillSpec {
        key: WORKSPACE_SEGMENT_EXTRACTOR_WORKFLOW_KEY,
        name: "Workspace Segment Extractor",
        goal: "Extract named spans from recent journals and transcripts. Use timestamps when transcript timing is available and write only the primitive segments handoff JSON for Rust to compile into clip plans and navigation structures.",
        output_prefix: "posts/workspace_synthesizer/",
        handler_kind: WorkspaceSynthSkillHandlerKind::SplitHandoff,
        enabled_by_default: false,
        visible_in_ui: false,
    },
    WorkspaceSynthSkillSpec {
        key: WORKSPACE_INSIGHT_EXTRACTOR_WORKFLOW_KEY,
        name: "Workspace Insight Extractor",
        goal: "Extract concise workspace feed posts from recent journals and transcripts. Write only the insight_posts handoff JSON for Rust to materialize into feed posts.",
        output_prefix: "posts/workspace_synthesizer/",
        handler_kind: WorkspaceSynthSkillHandlerKind::SplitHandoff,
        enabled_by_default: true,
        visible_in_ui: true,
    },
    WorkspaceSynthSkillSpec {
        key: WORKSPACE_TODO_EXTRACTOR_WORKFLOW_KEY,
        name: "Workspace Todo Extractor",
        goal: "Extract concrete action items and commitments from recent journals and transcripts. Write only the todos handoff JSON for Rust to store in the planner.",
        output_prefix: "posts/workspace_synthesizer/",
        handler_kind: WorkspaceSynthSkillHandlerKind::SplitHandoff,
        enabled_by_default: true,
        visible_in_ui: true,
    },
    WorkspaceSynthSkillSpec {
        key: WORKSPACE_EVENT_EXTRACTOR_WORKFLOW_KEY,
        name: "Workspace Event Extractor",
        goal: "Extract scheduled events with clear timing from recent journals and transcripts. Write only the events handoff JSON for Rust to store in the planner.",
        output_prefix: "posts/workspace_synthesizer/",
        handler_kind: WorkspaceSynthSkillHandlerKind::SplitHandoff,
        enabled_by_default: true,
        visible_in_ui: true,
    },
    WorkspaceSynthSkillSpec {
        key: WORKSPACE_CLIP_EXTRACTOR_WORKFLOW_KEY,
        name: "Workspace Clip Extractor",
        goal: "Extract transcript-backed clip plans from recent journals and transcript text. Write only the clip_plans handoff JSON for Rust to keep as pipeline artifacts.",
        output_prefix: "posts/workspace_synthesizer/",
        handler_kind: WorkspaceSynthSkillHandlerKind::SplitHandoff,
        enabled_by_default: true,
        visible_in_ui: true,
    },
    WorkspaceSynthSkillSpec {
        key: WORKSPACE_JOURNAL_TITLE_EXTRACTOR_WORKFLOW_KEY,
        name: "Workspace Journal Title Extractor",
        goal: "Propose concise durable titles for the current journal note batch. Write only the journal_titles handoff JSON for Rust to rename journal note files.",
        output_prefix: "posts/workspace_synthesizer/",
        handler_kind: WorkspaceSynthSkillHandlerKind::SplitHandoff,
        enabled_by_default: true,
        visible_in_ui: true,
    },
    WorkspaceSynthSkillSpec {
        key: "bluesky_insight_posts",
        name: "Bluesky Insight Posts",
        goal: "Create interesting Bluesky post drafts from my recent journal notes. Extract standout insights and save each post as a separate file in posts/ so it appears in the workspace feed.",
        output_prefix: "posts/bluesky_insight_posts/",
        handler_kind: WorkspaceSynthSkillHandlerKind::DirectPostOutput,
        enabled_by_default: false,
        visible_in_ui: false,
    },
    WorkspaceSynthSkillSpec {
        key: "weekly_highlights",
        name: "Weekly Highlights",
        goal: "Turn my recent journal notes into polished weekly highlight posts for the workspace feed. Save each highlight as a separate file in posts/.",
        output_prefix: "posts/weekly_highlights/",
        handler_kind: WorkspaceSynthSkillHandlerKind::DirectPostOutput,
        enabled_by_default: false,
        visible_in_ui: false,
    },
    WorkspaceSynthSkillSpec {
        key: article_synthesizer::ARTICLE_SYNTHESIZER_WORKFLOW_KEY,
        name: "Long-Form Articles",
        goal: "Build clean long-form articles from journal notes over time. Decide whether to refine an existing article or create a new one, then hand off JSON for Rust to materialize markdown under posts/articles/.",
        output_prefix: "posts/articles/",
        handler_kind: WorkspaceSynthSkillHandlerKind::ArticleHandoff,
        enabled_by_default: false,
        visible_in_ui: false,
    },
    WorkspaceSynthSkillSpec {
        key: "audio_insight_clips",
        name: "Audio Insight Clips",
        goal: "Create simple vertical video clips from my journal audio recordings. If a transcript is missing, generate it first, extract exact insightful lines, build black-background text cards, and render a feed-ready mp4 into posts/.",
        output_prefix: "posts/audio_insight_clips/",
        handler_kind: WorkspaceSynthSkillHandlerKind::DirectMediaOutput,
        enabled_by_default: false,
        visible_in_ui: false,
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
pub struct PrimitiveProvenance {
    #[serde(default)]
    pub source_path: String,
    #[serde(default)]
    pub source_excerpt: String,
    #[serde(default)]
    pub start_at: String,
    #[serde(default)]
    pub end_at: String,
    #[serde(default)]
    pub speaker: String,
    #[serde(default)]
    pub confidence: Option<f32>,
}

#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema, Default)]
#[serde(rename_all = "camelCase")]
pub struct EntityCandidate {
    #[serde(default)]
    pub id: String,
    #[serde(default)]
    pub kind: String,
    #[serde(default)]
    pub canonical_name: String,
    #[serde(default)]
    pub aliases: Vec<String>,
    #[serde(default)]
    pub attributes: serde_json::Value,
    #[serde(default)]
    pub provenance: PrimitiveProvenance,
}

#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema, Default)]
#[serde(rename_all = "camelCase")]
pub struct PrimitiveEventCandidate {
    #[serde(default)]
    pub id: String,
    #[serde(default)]
    pub title: String,
    #[serde(default)]
    pub kind: String,
    #[serde(default)]
    pub status: String,
    #[serde(default)]
    pub start_at: String,
    #[serde(default)]
    pub end_at: String,
    #[serde(default)]
    pub participants: Vec<String>,
    #[serde(default)]
    pub related_entities: Vec<String>,
    #[serde(default)]
    pub details: String,
    #[serde(default)]
    pub provenance: PrimitiveProvenance,
}

#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema, Default)]
#[serde(rename_all = "camelCase")]
pub struct AssertionCandidate {
    #[serde(default)]
    pub id: String,
    #[serde(default)]
    pub text: String,
    #[serde(default)]
    pub kind: String,
    #[serde(default)]
    pub polarity: String,
    #[serde(default)]
    pub status: String,
    #[serde(default)]
    pub speaker: String,
    #[serde(default)]
    pub related_entities: Vec<String>,
    #[serde(default)]
    pub related_event_ids: Vec<String>,
    #[serde(default)]
    pub provenance: PrimitiveProvenance,
}

#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema, Default)]
#[serde(rename_all = "camelCase")]
pub struct ActionCandidate {
    #[serde(default)]
    pub id: String,
    #[serde(default)]
    pub title: String,
    #[serde(default)]
    pub details: String,
    #[serde(default)]
    pub status: String,
    #[serde(default)]
    pub priority: String,
    #[serde(default)]
    pub due_at: String,
    #[serde(default)]
    pub owner: String,
    #[serde(default)]
    pub related_entities: Vec<String>,
    #[serde(default)]
    pub related_assertion_ids: Vec<String>,
    #[serde(default)]
    pub provenance: PrimitiveProvenance,
}

#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema, Default)]
#[serde(rename_all = "camelCase")]
pub struct SegmentCandidate {
    #[serde(default)]
    pub id: String,
    #[serde(default)]
    pub label: String,
    #[serde(default)]
    pub topic: String,
    #[serde(default)]
    pub source_path: String,
    #[serde(default)]
    pub start_at: String,
    #[serde(default)]
    pub end_at: String,
    #[serde(default)]
    pub speaker: String,
    #[serde(default)]
    pub transcript_quote: String,
    #[serde(default)]
    pub purpose: String,
    #[serde(default)]
    pub provenance: PrimitiveProvenance,
}

#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema, Default)]
#[serde(rename_all = "camelCase")]
pub struct StructureCandidate {
    #[serde(default)]
    pub id: String,
    #[serde(default)]
    pub kind: String,
    #[serde(default)]
    pub title: String,
    #[serde(default)]
    pub body: String,
    #[serde(default)]
    pub source_primitive_ids: Vec<String>,
    #[serde(default)]
    pub format_hint: String,
    #[serde(default)]
    pub provenance: PrimitiveProvenance,
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

#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema, Default)]
#[serde(rename_all = "camelCase")]
pub struct EntityFile {
    #[serde(default = "manifest_version")]
    pub version: String,
    #[serde(default)]
    pub items: Vec<EntityCandidate>,
}

#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema, Default)]
#[serde(rename_all = "camelCase")]
pub struct PrimitiveEventFile {
    #[serde(default = "manifest_version")]
    pub version: String,
    #[serde(default)]
    pub items: Vec<PrimitiveEventCandidate>,
}

#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema, Default)]
#[serde(rename_all = "camelCase")]
pub struct AssertionFile {
    #[serde(default = "manifest_version")]
    pub version: String,
    #[serde(default)]
    pub items: Vec<AssertionCandidate>,
}

#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema, Default)]
#[serde(rename_all = "camelCase")]
pub struct ActionFile {
    #[serde(default = "manifest_version")]
    pub version: String,
    #[serde(default)]
    pub items: Vec<ActionCandidate>,
}

#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema, Default)]
#[serde(rename_all = "camelCase")]
pub struct SegmentFile {
    #[serde(default = "manifest_version")]
    pub version: String,
    #[serde(default)]
    pub items: Vec<SegmentCandidate>,
}

#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema, Default)]
#[serde(rename_all = "camelCase")]
pub struct StructureFile {
    #[serde(default = "manifest_version")]
    pub version: String,
    #[serde(default)]
    pub items: Vec<StructureCandidate>,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub struct WorkspaceSynthesizerStatus {
    #[serde(default = "default_idle_status")]
    pub status: String,
    #[serde(default = "default_true")]
    pub provider_ready: bool,
    #[serde(default)]
    pub provider_blocked_reason: String,
    #[serde(default)]
    pub trigger_reason: String,
    #[serde(default)]
    pub journal_save_cooldown_until: String,
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
    #[serde(default)]
    pub renamed_sources: Vec<WorkspaceSynthRenamedSource>,
    #[serde(default)]
    pub skill_runs: Vec<WorkspaceSynthSkillRunState>,
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
    #[serde(default)]
    pub primitive_entities: usize,
    #[serde(default)]
    pub primitive_events: usize,
    #[serde(default)]
    pub primitive_assertions: usize,
    #[serde(default)]
    pub primitive_actions: usize,
    #[serde(default)]
    pub primitive_segments: usize,
    #[serde(default)]
    pub primitive_structures: usize,
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
    #[serde(default)]
    pub journal_titles: WorkspaceSynthArtifactState,
    #[serde(default)]
    pub primitive_entities: WorkspaceSynthArtifactState,
    #[serde(default)]
    pub primitive_events: WorkspaceSynthArtifactState,
    #[serde(default)]
    pub primitive_assertions: WorkspaceSynthArtifactState,
    #[serde(default)]
    pub primitive_actions: WorkspaceSynthArtifactState,
    #[serde(default)]
    pub primitive_segments: WorkspaceSynthArtifactState,
    #[serde(default)]
    pub primitive_structures: WorkspaceSynthArtifactState,
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
    #[serde(default)]
    pub skill_runs: Vec<WorkspaceSynthSkillRunState>,
    /// Keywords extracted by the triage step (if triage ran).
    #[serde(default)]
    pub triage_keywords: Vec<String>,
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

fn default_true() -> bool {
    true
}

fn default_skill_enabled() -> bool {
    true
}

fn default_skill_visible_in_ui() -> bool {
    true
}

fn is_retired_workspace_synth_skill_key(skill_key: &str) -> bool {
    matches!(
        skill_key.trim(),
        "bluesky_insight_posts"
            | "weekly_highlights"
            | "audio_insight_clips"
            | article_synthesizer::ARTICLE_SYNTHESIZER_WORKFLOW_KEY
    )
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

fn entities_schema_json() -> Result<String> {
    let schema = schema_for!(EntityFile);
    serde_json::to_string_pretty(&schema).context("failed to serialize entities schema")
}

fn primitive_events_schema_json() -> Result<String> {
    let schema = schema_for!(PrimitiveEventFile);
    serde_json::to_string_pretty(&schema).context("failed to serialize primitive events schema")
}

fn assertions_schema_json() -> Result<String> {
    let schema = schema_for!(AssertionFile);
    serde_json::to_string_pretty(&schema).context("failed to serialize assertions schema")
}

fn actions_schema_json() -> Result<String> {
    let schema = schema_for!(ActionFile);
    serde_json::to_string_pretty(&schema).context("failed to serialize actions schema")
}

fn segments_schema_json() -> Result<String> {
    let schema = schema_for!(SegmentFile);
    serde_json::to_string_pretty(&schema).context("failed to serialize segments schema")
}

fn structures_schema_json() -> Result<String> {
    let schema = schema_for!(StructureFile);
    serde_json::to_string_pretty(&schema).context("failed to serialize structures schema")
}

pub fn extractor_specs() -> &'static [WorkspaceSynthExtractorSpec] {
    &WORKSPACE_SYNTH_EXTRACTOR_SPECS
}

pub fn skill_specs() -> &'static [WorkspaceSynthSkillSpec] {
    &WORKSPACE_SYNTH_SKILL_SPECS
}

pub fn is_managed_skill_key(skill_key: &str) -> bool {
    let normalized = skill_key.trim().to_ascii_lowercase();
    skill_specs()
        .iter()
        .any(|spec| spec.key.eq_ignore_ascii_case(&normalized))
}

pub fn skill_spec_by_key(skill_key: &str) -> Option<WorkspaceSynthSkillSpec> {
    skill_specs()
        .iter()
        .copied()
        .find(|spec| spec.key.eq_ignore_ascii_case(skill_key.trim()))
}

pub fn skill_store_path(workspace_dir: &Path) -> PathBuf {
    workspace_dir.join(WORKSPACE_SYNTH_SKILLS_PATH)
}

fn normalize_skill_path(skill_key: &str) -> String {
    format!(
        "skills/workspace_synthesizer/{}/SKILL.md",
        skill_key.trim().to_ascii_lowercase()
    )
}

fn normalize_skill_output_prefix(prefix: &str, skill_key: &str) -> String {
    let trimmed = prefix.trim().trim_start_matches('/').replace('\\', "/");
    let mut normalized = if trimmed.is_empty() {
        format!("posts/{}/", skill_key.trim().to_ascii_lowercase())
    } else {
        trimmed
    };
    if !normalized.starts_with("posts/") {
        normalized = format!("posts/{}/", skill_key.trim().to_ascii_lowercase());
    }
    if !normalized.ends_with('/') {
        normalized.push('/');
    }
    normalized
}

fn normalize_skill_record(skill_key: &str, mut record: WorkspaceSynthSkillRecord) -> WorkspaceSynthSkillRecord {
    record.skill_key = skill_key.trim().to_ascii_lowercase();
    if record.name.trim().is_empty() {
        record.name = skill_spec_by_key(skill_key)
            .map(|spec| spec.name.to_string())
            .unwrap_or_else(|| skill_key.trim().to_string());
    }
    record.skill_path = {
        let trimmed = record
            .skill_path
            .trim()
            .trim_start_matches('/')
            .replace('\\', "/");
        if trimmed.is_empty() || trimmed.contains("..") || !trimmed.starts_with("skills/") {
            normalize_skill_path(skill_key)
        } else {
            trimmed
        }
    };
    record.output_prefix = normalize_skill_output_prefix(&record.output_prefix, skill_key);
    record.goal = record.goal.trim().to_string();
    record.artifact_rules_override = record.artifact_rules_override.trim().to_string();
    if let Some(spec) = skill_spec_by_key(skill_key) {
        record.handler_kind = spec.handler_kind;
        record.visible_in_ui = spec.visible_in_ui;
        if record.goal.is_empty() {
            record.goal = spec.goal.to_string();
        }
    } else {
        record.visible_in_ui = record.visible_in_ui || default_skill_visible_in_ui();
    }
    if is_retired_workspace_synth_skill_key(skill_key) {
        record.visible_in_ui = false;
        record.enabled = false;
    }
    record
}

fn render_template_skill_markdown(skill_name: &str, goal: &str, output_dir: &str) -> String {
    format!(
        "# {skill_name}\n\n\
Use this content agent to fulfill the following goal:\n\n\
> {goal}\n\n\
## Sources\n\n\
- `journals/text/**`\n\
- transcript files under `journals/text/transcriptions/**` when present\n\n\
 - `journals/media/audio/**` and `journals/media/video/**` when the goal depends on journal media\n\n\
## Output\n\n\
- `{output_dir}`\n\n\
## Output Rules\n\n\
- Write feed-visible artifacts only under `{output_dir}`.\n\
- Hidden intermediates may go under `{output_dir}/pipeline/` or `{output_dir}/artifacts/`.\n\
- If generating multiple distinct post candidates, save each as a separate file.\n\
- Prefer built-in runtime tools for media and transcription tasks; do not hardcode scripts or shell pipelines when a built-in tool exists.\n\
- Keep unrelated workspace files untouched.\n"
    )
}

fn render_audio_insight_clip_skill_markdown(output_dir: &str) -> String {
    format!(
        "# Audio Insight Clips\n\n\
Create simple vertical video clips from journal audio recordings.\n\n\
## Sources\n\n\
- `journals/media/audio/**`\n\
- `journals/text/transcriptions/audio/**` when present\n\
- `journals/text/transcriptions/**` for existing transcript sidecars\n\
- `journals/text/**` for context if useful\n\n\
## Output\n\n\
- Final feed-visible clips: `{output_dir}`\n\
- Hidden intermediates: `{output_dir}/pipeline/`\n\n\
## Workflow\n\n\
1. Find one or more strong source recordings under `journals/media/audio/**`.\n\
2. For each chosen recording, look for a transcript text file under `journals/text/transcriptions/**` using the same stem and relative media path.\n\
3. If the transcript is missing, call the built-in `transcribe_media` tool for that recording.\n\
4. Read the transcript and extract exact insightful lines. Do not rewrite the quoted line if it will appear inside the video card.\n\
5. Optionally call `clean_audio` when the source recording is noisy.\n\
6. If you need a precise quote segment, call `extract_audio_segment` with the exact start/end range.\n\
7. Render the final clip with `compose_simple_clip` or `render_text_card_video` using white text on a black background.\n\
8. Save the final `.mp4` directly under `{output_dir}` so it appears in the workspace feed.\n\n\
## Output Rules\n\n\
- Use a black background with white text cards.\n\
- Prefer 1 to 3 exact lines per clip.\n\
- Keep final clips concise and feed-ready.\n\
- Put JSON manifests, transcripts, and other machine files only under `{output_dir}/pipeline/`.\n\
- Prefer built-in runtime tools over shell commands or scripts.\n\
- Do not overwrite unrelated posts.\n"
    )
}

fn built_in_skill_markdown(record: &WorkspaceSynthSkillRecord) -> Result<String> {
    let output_dir = record.output_prefix.trim_end_matches('/');
    let body = if is_extractor_workflow_key(&record.skill_key) {
        render_extractor_skill_markdown(&record.skill_key)?
    } else {
        match record.skill_key.as_str() {
        article_synthesizer::ARTICLE_SYNTHESIZER_WORKFLOW_KEY => {
            article_synthesizer::render_skill_markdown(output_dir)
        }
        "audio_insight_clips" => render_audio_insight_clip_skill_markdown(output_dir),
        _ => render_template_skill_markdown(&record.name, &record.goal, output_dir),
    }};
    Ok(body)
}

fn skill_definition_from_record(record: &WorkspaceSynthSkillRecord) -> WorkspaceSynthSkillDefinition {
    WorkspaceSynthSkillDefinition {
        key: record.skill_key.clone(),
        name: record.name.clone(),
        skill_path: record.skill_path.clone(),
        output_prefix: record.output_prefix.clone(),
        goal: record.goal.clone(),
        handler_kind: record.handler_kind,
        visible_in_ui: record.visible_in_ui,
        artifact_rules_override: record.artifact_rules_override.clone(),
    }
}

pub fn extract_markdown_section(markdown: &str, section_heading: &str) -> Option<String> {
    let heading = section_heading.trim();
    if heading.is_empty() {
        return None;
    }
    let mut capture = false;
    let mut lines = Vec::new();
    let needle = format!("## {heading}");
    for line in markdown.lines() {
        let trimmed = line.trim_end();
        if trimmed.trim() == needle {
            capture = true;
            continue;
        }
        if capture && trimmed.starts_with("## ") {
            break;
        }
        if capture {
            lines.push(trimmed);
        }
    }
    let section = lines.join("\n").trim().to_string();
    if section.is_empty() {
        None
    } else {
        Some(section)
    }
}

pub fn artifact_rules_from_markdown(markdown: &str) -> String {
    extract_markdown_section(markdown, "Artifact Rules").unwrap_or_default()
}

pub fn effective_artifact_rules(markdown: &str, override_text: &str) -> String {
    let trimmed_override = override_text.trim();
    if !trimmed_override.is_empty() {
        trimmed_override.to_string()
    } else {
        artifact_rules_from_markdown(markdown)
    }
}

pub fn all_skill_definitions(
    store: &WorkspaceSynthSkillStore,
) -> Vec<WorkspaceSynthSkillDefinition> {
    let mut defs = store
        .skills
        .values()
        .map(skill_definition_from_record)
        .collect::<Vec<_>>();
    defs.sort_by(|a, b| a.key.cmp(&b.key));
    defs
}

pub fn skill_definitions(store: &WorkspaceSynthSkillStore) -> Vec<WorkspaceSynthSkillDefinition> {
    all_skill_definitions(store)
        .into_iter()
        .filter(|skill| skill.visible_in_ui)
        .collect()
}

pub fn skill_definition_by_key(
    store: &WorkspaceSynthSkillStore,
    key: &str,
) -> Option<WorkspaceSynthSkillDefinition> {
    let normalized = key.trim().to_ascii_lowercase();
    store.skills.get(&normalized).map(skill_definition_from_record)
}

pub fn skill_for_feed_path(
    store: &WorkspaceSynthSkillStore,
    path: &str,
) -> Option<WorkspaceSynthSkillDefinition> {
    let normalized_path = path.trim_start_matches('/').to_ascii_lowercase();
    skill_definitions(store).into_iter().find(|skill| {
        normalized_path.starts_with(&skill.output_prefix.to_ascii_lowercase())
    })
}

fn built_in_skill_record(spec: WorkspaceSynthSkillSpec) -> WorkspaceSynthSkillRecord {
    let key = spec.key.to_ascii_lowercase();
    let mut record = WorkspaceSynthSkillRecord {
        skill_key: key.clone(),
        name: spec.name.to_string(),
        skill_path: normalize_skill_path(&key),
        output_prefix: spec.output_prefix.to_string(),
        enabled: spec.enabled_by_default,
        goal: spec.goal.to_string(),
        built_in_skill_fingerprint: None,
        visible_in_ui: spec.visible_in_ui,
        handler_kind: spec.handler_kind,
        artifact_rules_override: String::new(),
    };
    record = normalize_skill_record(&key, record);
    if let Ok(body) = built_in_skill_markdown(&record) {
        record.built_in_skill_fingerprint = Some(content_agent_skill_fingerprint(&body));
    }
    record
}

pub fn load_skill_store(workspace_dir: &Path) -> Result<WorkspaceSynthSkillStore> {
    let path = skill_store_path(workspace_dir);
    if !path.exists() {
        return Ok(WorkspaceSynthSkillStore::default());
    }
    let raw = fs::read_to_string(&path)
        .with_context(|| format!("failed to read {}", path.display()))?;
    let mut parsed: WorkspaceSynthSkillStore =
        serde_json::from_str(&raw).with_context(|| format!("invalid JSON in {}", path.display()))?;
    parsed.skills = parsed
        .skills
        .into_iter()
        .map(|(key, record)| {
            let normalized = key.trim().to_ascii_lowercase();
            (normalized.clone(), normalize_skill_record(&normalized, record))
        })
        .collect();
    Ok(parsed)
}

pub fn save_skill_store(workspace_dir: &Path, store: &WorkspaceSynthSkillStore) -> Result<()> {
    let path = skill_store_path(workspace_dir);
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)
            .with_context(|| format!("failed to create {}", parent.display()))?;
    }
    let raw = serde_json::to_string_pretty(store)?;
    fs::write(&path, raw).with_context(|| format!("failed to write {}", path.display()))?;
    Ok(())
}

pub fn ensure_built_in_skills(
    workspace_dir: &Path,
    store: &mut WorkspaceSynthSkillStore,
) -> Result<bool> {
    let mut changed = false;
    for spec in skill_specs() {
        let key = spec.key.to_ascii_lowercase();
        if !store.skills.contains_key(&key) {
            store.skills.insert(key.clone(), built_in_skill_record(*spec));
            changed = true;
        }
        if let Some(record) = store.skills.get_mut(&key) {
            *record = normalize_skill_record(&key, record.clone());
            let canonical_body = built_in_skill_markdown(record)?;
            let canonical_fingerprint = content_agent_skill_fingerprint(&canonical_body);
            let skill_abs = workspace_dir.join(&record.skill_path);
            let should_refresh = record
                .built_in_skill_fingerprint
                .as_deref()
                != Some(canonical_fingerprint.as_str())
                || !skill_abs.exists();
            if should_refresh {
                if let Some(parent) = skill_abs.parent() {
                    fs::create_dir_all(parent)
                        .with_context(|| format!("failed to create {}", parent.display()))?;
                }
                fs::write(&skill_abs, canonical_body)
                    .with_context(|| format!("failed to refresh {}", skill_abs.display()))?;
                record.built_in_skill_fingerprint = Some(canonical_fingerprint);
                changed = true;
            }
        }
    }
    Ok(changed)
}

pub fn load_or_seed_skill_store(workspace_dir: &Path) -> Result<WorkspaceSynthSkillStore> {
    let mut store = load_skill_store(workspace_dir)?;
    if ensure_built_in_skills(workspace_dir, &mut store)? {
        save_skill_store(workspace_dir, &store)?;
    }
    Ok(store)
}

fn content_agent_skill_fingerprint(body: &str) -> String {
    let digest = Sha256::digest(body.as_bytes());
    hex::encode(digest)
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
The runtime uses this skill as the shared guidance layer, then runs specialized extractor skills that primarily produce durable app artifacts:\n\
- Primary artifact files: `{insight_posts_path}`, `{todos_path}`, `{events_path}`, `{clip_plans_path}`, `{journal_titles_path}`\n\
\n\
- Optional helper primitive files when explicitly enabled:\n\
- `{entity_key}` -> `{entities_path}`\n\
- `{action_key}` -> `{actions_path}`\n\
- `{primitive_event_key}` -> `{primitive_events_path}`\n\
- `{assertion_key}` -> `{assertions_path}`\n\
- `{segment_key}` -> `{segments_path}`\n\
\n\
Primary workflow keys:\n\
- `{insight_key}`\n\
- `{todo_key}`\n\
- `{event_key}`\n\
- `{clip_key}`\n\
- `{title_key}`\n\n\
## Role\n\n\
- Read from `journals/text/**` and available transcript text under `journals/text/transcriptions/**`.\n\
- Act as the global policy layer for all workspace extraction.\n\
- Durable app artifacts are the primary product output.\n\
- Primitive handoffs are optional helper artifacts, not the default product memory layer.\n\
- The Rust runtime decides which extractor skills to run, validates each handoff file independently, and can compile missing app outputs from primitive files when those helper files are present.\n\
- Extractor skills, not this index skill alone, own the small typed JSON outputs.\n\n\
## Shared Guardrails\n\n\
- Prefer fewer, higher-signal artifacts over exhaustive extraction.\n\
- Every emitted item must include source provenance.\n\
- Use workspace-relative journal paths only.\n\
- Do not create final feed posts, todos, events, or clip plan output files directly.\n\
- Desktop and mobile must both be supported. Clip rendering may be unavailable, but clip planning is still allowed.\n\n\
## Primary Artifact Policy\n\n\
- `insightPosts`: concise, keepable or publishable text artifacts under `posts/`.\n\
- `todos`: planner tasks that persist in the workspace database.\n\
- `events`: planner events that persist in the workspace database.\n\
- `clipPlans`: transcript-backed editing plans and clip artifacts.\n\
- `journalTitles`: operational file-improvement output.\n\
\n\
## Optional Helper Policy\n\n\
- `segments`: useful when timestamps unlock deterministic media editing.\n\
- `actions` and `primitiveEvents`: useful when primary planner outputs are not emitted directly.\n\
- `assertions`, `entities`, and `structures`: optional helper context only; do not treat them as the default persisted product layer.\n\
\n\
## Runtime Notes\n\n\
- App-shaped handoffs remain the primary path.\n\
- Primitive helper handoffs are optional and disabled by default to keep runs cheaper.\n\
- Rust materializes final outputs and keeps planner data out of the feed.\n\
- Partial success is allowed: one extractor can fail without discarding the others.\n",
        entity_key = WORKSPACE_ENTITY_EXTRACTOR_WORKFLOW_KEY,
        action_key = WORKSPACE_ACTION_EXTRACTOR_WORKFLOW_KEY,
        primitive_event_key = WORKSPACE_PRIMITIVE_EVENT_EXTRACTOR_WORKFLOW_KEY,
        assertion_key = WORKSPACE_ASSERTION_EXTRACTOR_WORKFLOW_KEY,
        segment_key = WORKSPACE_SEGMENT_EXTRACTOR_WORKFLOW_KEY,
        insight_key = WORKSPACE_INSIGHT_EXTRACTOR_WORKFLOW_KEY,
        todo_key = WORKSPACE_TODO_EXTRACTOR_WORKFLOW_KEY,
        event_key = WORKSPACE_EVENT_EXTRACTOR_WORKFLOW_KEY,
        clip_key = WORKSPACE_CLIP_EXTRACTOR_WORKFLOW_KEY,
        title_key = WORKSPACE_JOURNAL_TITLE_EXTRACTOR_WORKFLOW_KEY,
        entities_path = WORKSPACE_SYNTHESIZER_PRIMITIVE_ENTITIES_PATH,
        actions_path = WORKSPACE_SYNTHESIZER_PRIMITIVE_ACTIONS_PATH,
        primitive_events_path = WORKSPACE_SYNTHESIZER_PRIMITIVE_EVENTS_PATH,
        assertions_path = WORKSPACE_SYNTHESIZER_PRIMITIVE_ASSERTIONS_PATH,
        segments_path = WORKSPACE_SYNTHESIZER_PRIMITIVE_SEGMENTS_PATH,
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
        WORKSPACE_ENTITY_EXTRACTOR_WORKFLOW_KEY => (
            "entities",
            entities_schema_json()?,
            "- Optional helper output only.\n\
- Emit canonical nouns that matter, including people, projects, orgs, dates, and amounts when useful.\n\
- Use `canonicalName` for the stable label and `aliases` for surface forms.\n\
- Include provenance for every emitted entity.\n",
        ),
        WORKSPACE_ACTION_EXTRACTOR_WORKFLOW_KEY => (
            "actions",
            actions_schema_json()?,
            "- Optional helper output only.\n\
- Emit explicit actions, commitments, follow-ups, or requests.\n\
- Avoid vague aspirations unless the source makes the next step clear.\n\
- These are durable planner inputs, not presentation-layer todos.\n",
        ),
        WORKSPACE_PRIMITIVE_EVENT_EXTRACTOR_WORKFLOW_KEY => (
            "primitiveEvents",
            primitive_events_schema_json()?,
            "- Optional helper output only.\n\
- Emit scheduled or notable events with source-supported timing when available.\n\
- These are durable timeline records, not presentation-layer calendar views.\n\
- Do not invent time, location, or participant details.\n",
        ),
        WORKSPACE_ASSERTION_EXTRACTOR_WORKFLOW_KEY => (
            "assertions",
            assertions_schema_json()?,
            "- Optional helper output only.\n\
- Emit explicit claims, opinions, beliefs, questions, or decisions.\n\
- Prefer precise text over paraphrased abstractions when possible.\n\
- Include related entity and event ids when the linkage is clear from the source.\n",
        ),
        WORKSPACE_SEGMENT_EXTRACTOR_WORKFLOW_KEY => (
            "segments",
            segments_schema_json()?,
            "- Optional helper output only.\n\
- Emit named spans with a clear topic or purpose.\n\
- Use `startAt` and `endAt` only for transcript-backed sources.\n\
- Text-journal segments may omit timing and still be valid.\n\
- Prefer segments that are directly useful for clips, navigation, or media reuse.\n",
        ),
        WORKSPACE_INSIGHT_EXTRACTOR_WORKFLOW_KEY => (
            "insightPosts",
            insight_posts_schema_json()?,
            "- This is a primary durable artifact path.\n\
- Emit concise, keepable or publishable text only.\n\
- No titles, no markdown bullets, no surrounding quotes.\n",
        ),
        WORKSPACE_TODO_EXTRACTOR_WORKFLOW_KEY => (
            "todos",
            todos_schema_json()?,
            "- This is a primary durable artifact path.\n\
- Emit only explicit next actions, tasks, or commitments.\n\
- Prefer stable titles and put nuance in `details`.\n",
        ),
        WORKSPACE_EVENT_EXTRACTOR_WORKFLOW_KEY => (
            "events",
            events_schema_json()?,
            "- This is a primary durable artifact path.\n\
- Emit only items with a clear date, time, or scheduled plan.\n\
- Do not invent timing or location details.\n",
        ),
        WORKSPACE_CLIP_EXTRACTOR_WORKFLOW_KEY => (
            "clipPlans",
            clip_plans_schema_json()?,
            "- This is a primary durable artifact path.\n\
- Emit only transcript-backed segments from audio/video transcript sidecars under journals/text/transcriptions/** or journals/text/transcript/**.\n\
- Prefer precise `startAt` and `endAt` values from transcript context when available.\n",
        ),
        WORKSPACE_JOURNAL_TITLE_EXTRACTOR_WORKFLOW_KEY => (
            "journalTitles",
            journal_titles_schema_json()?,
            "- Emit titles for real journal note files under `journals/text/` and for transcript-backed media families using the transcript `.txt` path under `journals/text/transcriptions/**` or `journals/text/transcript/**`.\n\
- When titling transcript-backed media, point `sourcePath` at the transcript `.txt` file; Rust will rename the linked media file and transcript sidecars together.\n\
- Do not point `journalTitles` at transcript `.json` or `.srt` sidecars.\n\
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
- Every item must include provenance rooted in workspace-relative journal paths.\n\
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
- Primary artifact files: `{insight_posts_path}`, `{todos_path}`, `{events_path}`, `{clip_plans_path}`, `{journal_titles_path}`.\n\
- Optional helper files when explicitly needed: `{entities_path}`, `{primitive_events_path}`, `{assertions_path}`, `{actions_path}`, `{segments_path}`, `{structures_path}`.\n\
- Overwrite each emitted file completely with valid JSON.\n\
- Omit files for artifact types with no strong candidates, or write empty `items` arrays.\n\
- Do not write final feed posts, todos, events, or any other files yourself.\n\
- The Rust runtime will validate each handoff file independently and may compile missing app outputs from helper primitive files when those are present.\n\n\
## Extraction Scope\n\n\
- `insightPosts`: concise, keepable or publishable text artifacts under `posts/`.\n\
- `actions`: concrete action items only when the journal makes a clear commitment or next step explicit.\n\
- `todos`: durable planner tasks.\n\
- `events`: durable planner events.\n\
- `clipPlans`: transcript-backed editing plans or clip artifacts.\n\
- `entities`: optional helper context when useful.\n\
- `primitiveEvents`: optional helper event timeline data when useful.\n\
- `assertions`: explicit claims, beliefs, questions, or decisions.\n\
- `segments`: named spans, with timestamps for transcripts and untimed sections for plain text journals.\n\
- `structures`: optional draft outputs such as feed-ready posts, outlines, or summaries. Use only when clearly useful.\n\
- `journalTitles`: only for journal note files that deserve clearer durable titles.\n\n\
## Quality Rules\n\n\
- Prefer fewer, high-signal artifacts over exhaustive extraction.\n\
- Write app-shaped artifacts directly when the checked skills ask for them.\n\
- Use assertions, entities, or structures only as helper reasoning when needed.\n\
- Segments are especially valuable when transcript timing unlocks downstream media tooling.\n\
- Every item must include source provenance.\n\
- Use stable lowercase ids with letters, numbers, and dashes when possible.\n\
- Use workspace-relative journal paths only.\n\
- If an artifact type has nothing worth emitting, return an empty array for that type.\n\
- Never include comments, markdown fences, or trailing prose in the JSON file.\n\n\
## Output Limits\n\n\
- Maximum {max_posts} `insightPosts`\n\
- Maximum {max_entities} `entities`\n\
- Maximum {max_assertions} `assertions`\n\
- Maximum {max_actions} `actions`\n\
- Maximum {max_segments} `segments`\n\
- Maximum {max_structures} `structures`\n\
- Maximum {max_todos} `todos`\n\
- Maximum {max_events} `events`\n\
- Maximum {max_clips} `clipPlans`\n\
- Maximum {max_titles} `journalTitles`\n\n\
## Runtime Notes\n\n\
- {media_summary}\n\
- This workflow must work on desktop and mobile runtimes. Clip plans are allowed even when rendering is unavailable.\n\n\
## JSON Schemas\n\n\
### `{entities_path}`\n\
```json\n\
{entities_schema}\n\
```\n\
\n\
### `{primitive_events_path}`\n\
```json\n\
{primitive_events_schema}\n\
```\n\
\n\
### `{assertions_path}`\n\
```json\n\
{assertions_schema}\n\
```\n\
\n\
### `{actions_path}`\n\
```json\n\
{actions_schema}\n\
```\n\
\n\
### `{segments_path}`\n\
```json\n\
{segments_schema}\n\
```\n\
\n\
### `{structures_path}`\n\
```json\n\
{structures_schema}\n\
```\n\
\n\
### `{insight_posts_path}`\n\
```json\n\
{insight_posts_schema}\n\
```\n",
        pipeline_dir = WORKSPACE_SYNTHESIZER_PIPELINE_DIR,
        entities_path = WORKSPACE_SYNTHESIZER_PRIMITIVE_ENTITIES_PATH,
        primitive_events_path = WORKSPACE_SYNTHESIZER_PRIMITIVE_EVENTS_PATH,
        assertions_path = WORKSPACE_SYNTHESIZER_PRIMITIVE_ASSERTIONS_PATH,
        actions_path = WORKSPACE_SYNTHESIZER_PRIMITIVE_ACTIONS_PATH,
        segments_path = WORKSPACE_SYNTHESIZER_PRIMITIVE_SEGMENTS_PATH,
        structures_path = WORKSPACE_SYNTHESIZER_PRIMITIVE_STRUCTURES_PATH,
        insight_posts_path = WORKSPACE_SYNTHESIZER_INSIGHT_POSTS_PATH,
        todos_path = WORKSPACE_SYNTHESIZER_TODOS_PATH,
        events_path = WORKSPACE_SYNTHESIZER_EVENTS_PATH,
        clip_plans_path = WORKSPACE_SYNTHESIZER_CLIP_PLANS_PATH,
        journal_titles_path = WORKSPACE_SYNTHESIZER_JOURNAL_TITLES_PATH,
        max_posts = MAX_INSIGHT_POSTS,
        max_entities = MAX_ENTITIES,
        max_assertions = MAX_ASSERTIONS,
        max_actions = MAX_ACTIONS,
        max_segments = MAX_SEGMENTS,
        max_structures = MAX_STRUCTURES,
        max_todos = MAX_TODOS,
        max_events = MAX_EVENTS,
        max_clips = MAX_CLIP_PLANS,
        max_titles = MAX_JOURNAL_TITLES,
        media_summary = media_summary.trim(),
        entities_schema = entities_schema_json()?.trim(),
        primitive_events_schema = primitive_events_schema_json()?.trim(),
        assertions_schema = assertions_schema_json()?.trim(),
        actions_schema = actions_schema_json()?.trim(),
        segments_schema = segments_schema_json()?.trim(),
        structures_schema = structures_schema_json()?.trim(),
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

pub fn primitive_entities_path(workspace_dir: &Path) -> PathBuf {
    workspace_dir.join(WORKSPACE_SYNTHESIZER_PRIMITIVE_ENTITIES_PATH)
}

pub fn primitive_events_path(workspace_dir: &Path) -> PathBuf {
    workspace_dir.join(WORKSPACE_SYNTHESIZER_PRIMITIVE_EVENTS_PATH)
}

pub fn primitive_assertions_path(workspace_dir: &Path) -> PathBuf {
    workspace_dir.join(WORKSPACE_SYNTHESIZER_PRIMITIVE_ASSERTIONS_PATH)
}

pub fn primitive_actions_path(workspace_dir: &Path) -> PathBuf {
    workspace_dir.join(WORKSPACE_SYNTHESIZER_PRIMITIVE_ACTIONS_PATH)
}

pub fn primitive_segments_path(workspace_dir: &Path) -> PathBuf {
    workspace_dir.join(WORKSPACE_SYNTHESIZER_PRIMITIVE_SEGMENTS_PATH)
}

pub fn primitive_structures_path(workspace_dir: &Path) -> PathBuf {
    workspace_dir.join(WORKSPACE_SYNTHESIZER_PRIMITIVE_STRUCTURES_PATH)
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
        primitive_entities_path(workspace_dir),
        primitive_events_path(workspace_dir),
        primitive_assertions_path(workspace_dir),
        primitive_actions_path(workspace_dir),
        primitive_segments_path(workspace_dir),
        primitive_structures_path(workspace_dir),
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

fn strip_json_markdown_fence(raw: &str) -> Option<String> {
    let trimmed = raw.trim();
    if !trimmed.starts_with("```") {
        return None;
    }

    let first_newline = trimmed.find('\n')?;
    let body = &trimmed[first_newline + 1..];
    let closing = body.rfind("```")?;
    Some(body[..closing].trim().to_string())
}

fn extract_json_values(raw: &str) -> Vec<serde_json::Value> {
    let mut values = Vec::new();
    let trimmed = raw.trim();
    if trimmed.is_empty() {
        return values;
    }

    if let Ok(value) = serde_json::from_str::<serde_json::Value>(trimmed) {
        values.push(value);
        return values;
    }

    let char_positions: Vec<(usize, char)> = trimmed.char_indices().collect();
    let mut idx = 0;
    while idx < char_positions.len() {
        let (byte_idx, ch) = char_positions[idx];
        if ch == '{' || ch == '[' {
            let slice = &trimmed[byte_idx..];
            let mut stream =
                serde_json::Deserializer::from_str(slice).into_iter::<serde_json::Value>();
            if let Some(Ok(value)) = stream.next() {
                let consumed = stream.byte_offset();
                if consumed > 0 {
                    values.push(value);
                    let next_byte = byte_idx + consumed;
                    while idx < char_positions.len() && char_positions[idx].0 < next_byte {
                        idx += 1;
                    }
                    continue;
                }
            }
        }
        idx += 1;
    }

    values
}

fn parse_extractor_response_json(response_text: &str) -> Result<serde_json::Value> {
    let trimmed = response_text.trim();
    if trimmed.is_empty() {
        anyhow::bail!("extractor response was empty");
    }

    if let Ok(value) = serde_json::from_str::<serde_json::Value>(trimmed) {
        return Ok(value);
    }

    if let Some(unfenced) = strip_json_markdown_fence(trimmed) {
        if let Ok(value) = serde_json::from_str::<serde_json::Value>(&unfenced) {
            return Ok(value);
        }
        if let Some(value) = extract_json_values(&unfenced).into_iter().next() {
            return Ok(value);
        }
    }

    if let Some(value) = extract_json_values(trimmed).into_iter().next() {
        return Ok(value);
    }

    anyhow::bail!("extractor response did not contain valid JSON")
}

fn parse_handoff_version(value: &serde_json::Value, artifact_label: &str) -> Result<String> {
    let mut version = value
        .get("version")
        .and_then(serde_json::Value::as_str)
        .unwrap_or("1")
        .trim()
        .to_string();
    normalize_file_version(&mut version, artifact_label)?;
    Ok(version)
}

fn parse_handoff_items<T>(value: &serde_json::Value, artifact_label: &str) -> Result<Vec<T>>
where
    T: DeserializeOwned,
{
    if value.is_array() {
        return serde_json::from_value(value.clone())
            .with_context(|| format!("invalid {artifact_label} item array"));
    }

    if let Some(items) = value.get("items") {
        return serde_json::from_value(items.clone())
            .with_context(|| format!("invalid {artifact_label} items payload"));
    }

    anyhow::bail!(
        "extractor response for {artifact_label} must be a JSON object with `items` or a top-level array"
    )
}

fn write_pretty_json_file<T: Serialize>(path: &Path, value: &T) -> Result<()> {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)
            .with_context(|| format!("failed to create {}", parent.display()))?;
    }
    let raw = serde_json::to_string_pretty(value)?;
    fs::write(path, raw).with_context(|| format!("failed to write {}", path.display()))?;
    Ok(())
}

pub fn materialize_extractor_response(
    workspace_dir: &Path,
    workflow_key: &str,
    response_text: &str,
) -> Result<usize> {
    let payload = parse_extractor_response_json(response_text)?;

    match workflow_key.trim() {
        WORKSPACE_INSIGHT_EXTRACTOR_WORKFLOW_KEY => {
            let version = parse_handoff_version(&payload, "insight posts")?;
            let items =
                normalize_insight_post_items(parse_handoff_items(&payload, "insight posts")?)?;
            let file = InsightPostFile {
                version,
                items: items.clone(),
            };
            write_pretty_json_file(&insight_posts_path(workspace_dir), &file)?;
            Ok(items.len())
        }
        WORKSPACE_TODO_EXTRACTOR_WORKFLOW_KEY => {
            let version = parse_handoff_version(&payload, "todos")?;
            let items = normalize_todo_items(parse_handoff_items(&payload, "todos")?)?;
            let file = TodoFile {
                version,
                items: items.clone(),
            };
            write_pretty_json_file(&todos_path(workspace_dir), &file)?;
            Ok(items.len())
        }
        WORKSPACE_EVENT_EXTRACTOR_WORKFLOW_KEY => {
            let version = parse_handoff_version(&payload, "events")?;
            let items = normalize_event_items(parse_handoff_items(&payload, "events")?)?;
            let file = EventFile {
                version,
                items: items.clone(),
            };
            write_pretty_json_file(&events_path(workspace_dir), &file)?;
            Ok(items.len())
        }
        WORKSPACE_CLIP_EXTRACTOR_WORKFLOW_KEY => {
            let version = parse_handoff_version(&payload, "clip plans")?;
            let items = normalize_clip_plan_items(parse_handoff_items(&payload, "clip plans")?)?;
            let file = ClipPlanFile {
                version,
                items: items.clone(),
            };
            write_pretty_json_file(&clip_plans_path(workspace_dir), &file)?;
            Ok(items.len())
        }
        WORKSPACE_JOURNAL_TITLE_EXTRACTOR_WORKFLOW_KEY => {
            let version = parse_handoff_version(&payload, "journal titles")?;
            let items =
                normalize_journal_title_items(parse_handoff_items(&payload, "journal titles")?)?;
            let file = JournalTitleFile {
                version,
                items: items.clone(),
            };
            write_pretty_json_file(&journal_titles_path(workspace_dir), &file)?;
            Ok(items.len())
        }
        WORKSPACE_ENTITY_EXTRACTOR_WORKFLOW_KEY => {
            let version = parse_handoff_version(&payload, "entities")?;
            let items = normalize_entity_items(parse_handoff_items(&payload, "entities")?)?;
            let file = EntityFile {
                version,
                items: items.clone(),
            };
            write_pretty_json_file(&primitive_entities_path(workspace_dir), &file)?;
            Ok(items.len())
        }
        WORKSPACE_PRIMITIVE_EVENT_EXTRACTOR_WORKFLOW_KEY => {
            let version = parse_handoff_version(&payload, "primitive events")?;
            let items =
                normalize_primitive_event_items(parse_handoff_items(&payload, "primitive events")?)?;
            let file = PrimitiveEventFile {
                version,
                items: items.clone(),
            };
            write_pretty_json_file(&primitive_events_path(workspace_dir), &file)?;
            Ok(items.len())
        }
        WORKSPACE_ASSERTION_EXTRACTOR_WORKFLOW_KEY => {
            let version = parse_handoff_version(&payload, "assertions")?;
            let items = normalize_assertion_items(parse_handoff_items(&payload, "assertions")?)?;
            let file = AssertionFile {
                version,
                items: items.clone(),
            };
            write_pretty_json_file(&primitive_assertions_path(workspace_dir), &file)?;
            Ok(items.len())
        }
        WORKSPACE_ACTION_EXTRACTOR_WORKFLOW_KEY => {
            let version = parse_handoff_version(&payload, "actions")?;
            let items = normalize_action_items(parse_handoff_items(&payload, "actions")?)?;
            let file = ActionFile {
                version,
                items: items.clone(),
            };
            write_pretty_json_file(&primitive_actions_path(workspace_dir), &file)?;
            Ok(items.len())
        }
        WORKSPACE_SEGMENT_EXTRACTOR_WORKFLOW_KEY => {
            let version = parse_handoff_version(&payload, "segments")?;
            let items = normalize_segment_items(parse_handoff_items(&payload, "segments")?)?;
            let file = SegmentFile {
                version,
                items: items.clone(),
            };
            write_pretty_json_file(&primitive_segments_path(workspace_dir), &file)?;
            Ok(items.len())
        }
        other => anyhow::bail!("unsupported workspace synth extractor `{other}`"),
    }
}

pub fn extractor_schema_json(workflow_key: &str) -> Result<String> {
    match workflow_key.trim() {
        WORKSPACE_ENTITY_EXTRACTOR_WORKFLOW_KEY => entities_schema_json(),
        WORKSPACE_ACTION_EXTRACTOR_WORKFLOW_KEY => actions_schema_json(),
        WORKSPACE_PRIMITIVE_EVENT_EXTRACTOR_WORKFLOW_KEY => primitive_events_schema_json(),
        WORKSPACE_ASSERTION_EXTRACTOR_WORKFLOW_KEY => assertions_schema_json(),
        WORKSPACE_SEGMENT_EXTRACTOR_WORKFLOW_KEY => segments_schema_json(),
        WORKSPACE_INSIGHT_EXTRACTOR_WORKFLOW_KEY => insight_posts_schema_json(),
        WORKSPACE_TODO_EXTRACTOR_WORKFLOW_KEY => todos_schema_json(),
        WORKSPACE_EVENT_EXTRACTOR_WORKFLOW_KEY => events_schema_json(),
        WORKSPACE_CLIP_EXTRACTOR_WORKFLOW_KEY => clip_plans_schema_json(),
        WORKSPACE_JOURNAL_TITLE_EXTRACTOR_WORKFLOW_KEY => journal_titles_schema_json(),
        other => anyhow::bail!("unknown workspace synthesizer extractor `{other}`"),
    }
}

pub fn extractor_response_template_json(workflow_key: &str) -> Result<&'static str> {
    match workflow_key.trim() {
        WORKSPACE_ENTITY_EXTRACTOR_WORKFLOW_KEY => Ok(
            r#"{"version":"1","items":[{"id":"optional-entity-id","kind":"person|project|org|date|amount","canonicalName":"...","aliases":["..."],"attributes":{},"provenance":{"sourcePath":"journals/text/...","sourceExcerpt":"..."}}]}"#,
        ),
        WORKSPACE_ACTION_EXTRACTOR_WORKFLOW_KEY => Ok(
            r#"{"version":"1","items":[{"id":"optional-action-id","title":"...","details":"...","status":"open","priority":"medium","dueAt":"","owner":"","relatedEntities":[],"relatedAssertionIds":[],"provenance":{"sourcePath":"journals/text/...","sourceExcerpt":"..."}}]}"#,
        ),
        WORKSPACE_PRIMITIVE_EVENT_EXTRACTOR_WORKFLOW_KEY => Ok(
            r#"{"version":"1","items":[{"id":"optional-primitive-event-id","title":"...","kind":"meeting|deadline|milestone|other","status":"confirmed","startAt":"","endAt":"","participants":[],"relatedEntities":[],"details":"...","provenance":{"sourcePath":"journals/text/...","sourceExcerpt":"..."}}]}"#,
        ),
        WORKSPACE_ASSERTION_EXTRACTOR_WORKFLOW_KEY => Ok(
            r#"{"version":"1","items":[{"id":"optional-assertion-id","text":"...","kind":"belief|question|decision|claim","polarity":"positive|negative|neutral","status":"open","speaker":"","relatedEntities":[],"relatedEventIds":[],"provenance":{"sourcePath":"journals/text/...","sourceExcerpt":"..."}}]}"#,
        ),
        WORKSPACE_SEGMENT_EXTRACTOR_WORKFLOW_KEY => Ok(
            r#"{"version":"1","items":[{"id":"optional-segment-id","label":"...","topic":"...","sourcePath":"journals/text/transcriptions/...","startAt":"","endAt":"","speaker":"","transcriptQuote":"...","purpose":"...","provenance":{"sourcePath":"journals/text/transcriptions/...","sourceExcerpt":"..."}}]}"#,
        ),
        WORKSPACE_INSIGHT_EXTRACTOR_WORKFLOW_KEY => Ok(
            r#"{"version":"1","items":[{"id":"optional-insight-id","text":"...","sourcePath":"journals/text/...","sourceExcerpt":"..."}]}"#,
        ),
        WORKSPACE_TODO_EXTRACTOR_WORKFLOW_KEY => Ok(
            r#"{"version":"1","items":[{"id":"optional-todo-id","title":"...","details":"...","priority":"low|medium|high","status":"open","dueAt":"","sourcePath":"journals/text/...","sourceExcerpt":"..."}]}"#,
        ),
        WORKSPACE_EVENT_EXTRACTOR_WORKFLOW_KEY => Ok(
            r#"{"version":"1","items":[{"id":"optional-event-id","title":"...","details":"...","location":"","status":"confirmed","startAt":"2026-03-22T09:00:00Z","endAt":"","allDay":false,"sourcePath":"journals/text/...","sourceExcerpt":"..."}]}"#,
        ),
        WORKSPACE_CLIP_EXTRACTOR_WORKFLOW_KEY => Ok(
            r#"{"version":"1","items":[{"id":"optional-clip-id","title":"...","sourcePath":"journals/text/transcriptions/...","sourceExcerpt":"...","transcriptQuote":"...","startAt":"00:00:01.000","endAt":"00:00:08.000","notes":"..."}]}"#,
        ),
        WORKSPACE_JOURNAL_TITLE_EXTRACTOR_WORKFLOW_KEY => Ok(
            r#"{"version":"1","items":[{"sourcePath":"journals/text/...","title":"..."}]}"#,
        ),
        other => anyhow::bail!("unknown workspace synthesizer extractor `{other}`"),
    }
}

pub fn reset_skill_outputs(
    workspace_dir: &Path,
    skill: &WorkspaceSynthSkillDefinition,
) -> Result<()> {
    match skill.handler_kind {
        WorkspaceSynthSkillHandlerKind::SplitHandoff => {
            if let Some(handoff_rel) = extractor_handoff_path(&skill.key) {
                let path = workspace_dir.join(handoff_rel);
                match fs::remove_file(&path) {
                    Ok(()) => {}
                    Err(err) if err.kind() == std::io::ErrorKind::NotFound => {}
                    Err(err) => {
                        return Err(err)
                            .with_context(|| format!("failed to clear {}", path.display()));
                    }
                }
            }
        }
        WorkspaceSynthSkillHandlerKind::ArticleHandoff => {
            article_synthesizer::reset_handoff_file(workspace_dir)?;
        }
        WorkspaceSynthSkillHandlerKind::DirectPostOutput
        | WorkspaceSynthSkillHandlerKind::DirectMediaOutput => {}
    }
    Ok(())
}

pub fn direct_output_file_count(workspace_dir: &Path, output_prefix: &str) -> Result<usize> {
    let rel = output_prefix.trim().trim_start_matches('/').trim_end_matches('/');
    if rel.is_empty() {
        return Ok(0);
    }
    let root = workspace_dir.join(rel);
    if !root.exists() {
        return Ok(0);
    }
    count_visible_outputs_recursive(&root, workspace_dir)
}

pub fn direct_output_paths(workspace_dir: &Path, output_prefix: &str) -> Result<Vec<String>> {
    let rel = output_prefix.trim().trim_start_matches('/').trim_end_matches('/');
    if rel.is_empty() {
        return Ok(Vec::new());
    }
    let root = workspace_dir.join(rel);
    if !root.exists() {
        return Ok(Vec::new());
    }
    let mut out = Vec::new();
    collect_visible_outputs_recursive(&root, workspace_dir, &mut out)?;
    out.sort();
    Ok(out)
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

fn load_optional_entities_file(workspace_dir: &Path) -> Result<Option<Vec<EntityCandidate>>> {
    let path = primitive_entities_path(workspace_dir);
    let raw = match fs::read_to_string(&path) {
        Ok(raw) => raw,
        Err(err) if err.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(err) => return Err(err).with_context(|| format!("failed to read {}", path.display())),
    };
    let mut file: EntityFile =
        serde_json::from_str(&raw).with_context(|| format!("invalid JSON in {}", path.display()))?;
    normalize_file_version(&mut file.version, "entities")?;
    Ok(Some(normalize_entity_items(file.items)?))
}

fn load_optional_primitive_events_file(
    workspace_dir: &Path,
) -> Result<Option<Vec<PrimitiveEventCandidate>>> {
    let path = primitive_events_path(workspace_dir);
    let raw = match fs::read_to_string(&path) {
        Ok(raw) => raw,
        Err(err) if err.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(err) => return Err(err).with_context(|| format!("failed to read {}", path.display())),
    };
    let mut file: PrimitiveEventFile =
        serde_json::from_str(&raw).with_context(|| format!("invalid JSON in {}", path.display()))?;
    normalize_file_version(&mut file.version, "primitive events")?;
    Ok(Some(normalize_primitive_event_items(file.items)?))
}

fn load_optional_assertions_file(workspace_dir: &Path) -> Result<Option<Vec<AssertionCandidate>>> {
    let path = primitive_assertions_path(workspace_dir);
    let raw = match fs::read_to_string(&path) {
        Ok(raw) => raw,
        Err(err) if err.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(err) => return Err(err).with_context(|| format!("failed to read {}", path.display())),
    };
    let mut file: AssertionFile =
        serde_json::from_str(&raw).with_context(|| format!("invalid JSON in {}", path.display()))?;
    normalize_file_version(&mut file.version, "assertions")?;
    Ok(Some(normalize_assertion_items(file.items)?))
}

fn load_optional_actions_file(workspace_dir: &Path) -> Result<Option<Vec<ActionCandidate>>> {
    let path = primitive_actions_path(workspace_dir);
    let raw = match fs::read_to_string(&path) {
        Ok(raw) => raw,
        Err(err) if err.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(err) => return Err(err).with_context(|| format!("failed to read {}", path.display())),
    };
    let mut file: ActionFile =
        serde_json::from_str(&raw).with_context(|| format!("invalid JSON in {}", path.display()))?;
    normalize_file_version(&mut file.version, "actions")?;
    Ok(Some(normalize_action_items(file.items)?))
}

fn load_optional_segments_file(workspace_dir: &Path) -> Result<Option<Vec<SegmentCandidate>>> {
    let path = primitive_segments_path(workspace_dir);
    let raw = match fs::read_to_string(&path) {
        Ok(raw) => raw,
        Err(err) if err.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(err) => return Err(err).with_context(|| format!("failed to read {}", path.display())),
    };
    let mut file: SegmentFile =
        serde_json::from_str(&raw).with_context(|| format!("invalid JSON in {}", path.display()))?;
    normalize_file_version(&mut file.version, "segments")?;
    Ok(Some(normalize_segment_items(file.items)?))
}

fn load_optional_structures_file(workspace_dir: &Path) -> Result<Option<Vec<StructureCandidate>>> {
    let path = primitive_structures_path(workspace_dir);
    let raw = match fs::read_to_string(&path) {
        Ok(raw) => raw,
        Err(err) if err.kind() == std::io::ErrorKind::NotFound => return Ok(None),
        Err(err) => return Err(err).with_context(|| format!("failed to read {}", path.display())),
    };
    let mut file: StructureFile =
        serde_json::from_str(&raw).with_context(|| format!("invalid JSON in {}", path.display()))?;
    normalize_file_version(&mut file.version, "structures")?;
    Ok(Some(normalize_structure_items(file.items)?))
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
        let preferred_id = if item.id.trim().is_empty() || item.id.starts_with("post-") {
            preferred_insight_post_id(&item.text)
        } else {
            item.id.clone()
        };
        item.id = unique_id(&used_ids, &preferred_id, &seed, "post");
        used_ids.insert(item.id.clone());
    }
    Ok(items)
}

fn preferred_insight_post_id(text: &str) -> String {
    let first_line = text.lines().next().unwrap_or("").trim();
    let sentence = first_line
        .split(['.', '!', '?', ':'])
        .next()
        .unwrap_or(first_line)
        .trim();
    let mut stem = normalize_title_stem(&truncate_with_ellipsis(sentence, 72));
    if stem.is_empty() {
        stem = format!("post-{}", short_hash(text));
    }
    stem
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
        let seed = format!(
            "{}|{}|{}|{}",
            item.title, item.details, item.due_at, item.source_path
        );
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
        if is_transcript_source_path(&item.source_path) {
            let extension = Path::new(&item.source_path)
                .extension()
                .and_then(|value| value.to_str())
                .unwrap_or("")
                .to_ascii_lowercase();
            if extension != "txt" {
                anyhow::bail!(
                    "journalTitles transcript-backed media items must point to transcript text files, not sidecars"
                );
            }
        } else if !item.source_path.starts_with("journals/text/") {
            anyhow::bail!(
                "journalTitles items must point to journal note files or transcript-backed media transcript text files"
            );
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

fn is_transcript_source_path(path: &str) -> bool {
    path.starts_with("journals/text/transcriptions/") || path.starts_with("journals/text/transcript/")
}

fn workspace_relative_path_from_metadata_value(
    workspace_dir: &Path,
    raw: &str,
) -> Option<String> {
    let trimmed = raw.trim();
    if trimmed.is_empty() {
        return None;
    }

    let candidate = Path::new(trimmed);
    let rel = if candidate.is_absolute() {
        candidate.strip_prefix(workspace_dir).ok()?.to_path_buf()
    } else {
        PathBuf::from(trimmed.trim_start_matches('/'))
    };
    let normalized = rel.to_string_lossy().replace('\\', "/");
    (!normalized.is_empty()).then_some(normalized)
}

fn linked_media_rel_path_from_transcript_metadata(
    workspace_dir: &Path,
    transcript_rel: &str,
) -> Option<String> {
    let json_rel = super::transcript_json_rel_path(transcript_rel);
    let json_abs = workspace_dir.join(&json_rel);
    let raw = fs::read_to_string(json_abs).ok()?;
    let payload: serde_json::Value = serde_json::from_str(&raw).ok()?;
    let source = payload.get("source")?.as_str()?;
    let media_rel = workspace_relative_path_from_metadata_value(workspace_dir, source)?;
    media_rel
        .starts_with(&format!("{}/", super::JOURNAL_MEDIA_DIR))
        .then_some(media_rel)
}

fn linked_media_rel_path_from_transcript_path(
    workspace_dir: &Path,
    transcript_rel: &str,
) -> Option<String> {
    let normalized = transcript_rel.trim().trim_start_matches('/').replace('\\', "/");
    if let Some(relative) = normalized.strip_prefix("journals/text/transcriptions/") {
        let relative_path = Path::new(relative);
        let stem = relative_path.file_stem()?.to_str()?.trim();
        if stem.is_empty() {
            return None;
        }
        let mut media_dir = workspace_dir.join(super::JOURNAL_MEDIA_DIR);
        if let Some(parent) = relative_path.parent() {
            if !parent.as_os_str().is_empty() {
                media_dir.push(parent);
            }
        }
        let entries = fs::read_dir(media_dir).ok()?;
        let mut matches = entries
            .flatten()
            .filter_map(|entry| {
                let path = entry.path();
                let file_type = entry.file_type().ok()?;
                if !file_type.is_file() {
                    return None;
                }
                let entry_stem = path.file_stem()?.to_str()?.trim();
                if entry_stem != stem {
                    return None;
                }
                path.strip_prefix(workspace_dir)
                    .ok()
                    .map(|rel| rel.to_string_lossy().replace('\\', "/"))
            })
            .collect::<Vec<_>>();
        matches.sort();
        return (matches.len() == 1).then(|| matches.remove(0));
    }

    if let Some(stem) = Path::new(&normalized)
        .file_stem()
        .and_then(|value| value.to_str())
        .map(str::trim)
        .filter(|value| !value.is_empty())
    {
        let root = workspace_dir.join(super::JOURNAL_MEDIA_DIR);
        let mut stack = vec![root];
        let mut matches = Vec::new();
        while let Some(dir) = stack.pop() {
            let entries = match fs::read_dir(&dir) {
                Ok(entries) => entries,
                Err(_) => continue,
            };
            for entry in entries.flatten() {
                let path = entry.path();
                let Ok(file_type) = entry.file_type() else {
                    continue;
                };
                if file_type.is_dir() {
                    stack.push(path);
                    continue;
                }
                if !file_type.is_file() {
                    continue;
                }
                let Some(entry_stem) = path.file_stem().and_then(|value| value.to_str()) else {
                    continue;
                };
                if entry_stem.trim() != stem {
                    continue;
                }
                if let Ok(rel) = path.strip_prefix(workspace_dir) {
                    matches.push(rel.to_string_lossy().replace('\\', "/"));
                }
            }
        }
        matches.sort();
        return (matches.len() == 1).then(|| matches.remove(0));
    }

    None
}

fn linked_media_rel_path_for_transcript(
    workspace_dir: &Path,
    transcript_rel: &str,
) -> Option<String> {
    linked_media_rel_path_from_transcript_metadata(workspace_dir, transcript_rel)
        .or_else(|| linked_media_rel_path_from_transcript_path(workspace_dir, transcript_rel))
}

fn rename_workspace_file_if_exists(
    workspace_dir: &Path,
    old_rel: &str,
    new_rel: &str,
) -> Result<()> {
    if old_rel == new_rel {
        return Ok(());
    }
    let old_abs = workspace_dir.join(old_rel);
    if !old_abs.exists() {
        return Ok(());
    }
    let new_abs = workspace_dir.join(new_rel);
    if let Some(parent) = new_abs.parent() {
        fs::create_dir_all(parent)
            .with_context(|| format!("failed to create {}", parent.display()))?;
    }
    fs::rename(&old_abs, &new_abs)
        .with_context(|| format!("failed to rename {} -> {}", old_abs.display(), new_abs.display()))
}

fn path_rename_conflicts(
    workspace_dir: &Path,
    reserved_targets: &HashSet<String>,
    candidate_rel: &str,
    old_rel: &str,
) -> bool {
    if candidate_rel == old_rel {
        return false;
    }
    if reserved_targets.contains(candidate_rel) {
        return true;
    }
    workspace_dir.join(candidate_rel).exists()
}

fn rewrite_transcript_json_sidecar_after_family_rename(
    workspace_dir: &Path,
    transcript_json_rel: &str,
    media_rel: Option<&str>,
    transcript_rel: &str,
) -> Result<()> {
    let json_abs = workspace_dir.join(transcript_json_rel);
    if !json_abs.is_file() {
        return Ok(());
    }

    let raw = fs::read_to_string(&json_abs)
        .with_context(|| format!("failed to read {}", json_abs.display()))?;
    let mut payload: serde_json::Value = serde_json::from_str(&raw)
        .with_context(|| format!("invalid JSON in {}", json_abs.display()))?;
    let Some(object) = payload.as_object_mut() else {
        anyhow::bail!(
            "transcript json sidecar must be a JSON object: {}",
            json_abs.display()
        );
    };
    object.insert(
        "transcriptPath".to_string(),
        serde_json::Value::String(
            workspace_dir
                .join(transcript_rel)
                .to_string_lossy()
                .into_owned(),
        ),
    );
    if let Some(media_rel) = media_rel {
        object.insert(
            "source".to_string(),
            serde_json::Value::String(
                workspace_dir.join(media_rel).to_string_lossy().into_owned(),
            ),
        );
    }

    let serialized = serde_json::to_string_pretty(&payload)
        .with_context(|| format!("failed to serialize {}", json_abs.display()))?;
    fs::write(&json_abs, format!("{serialized}\n"))
        .with_context(|| format!("failed to write {}", json_abs.display()))
}

fn rename_transcript_backed_media_family(
    workspace_dir: &Path,
    transcript_rel: &str,
    stem: &str,
    reserved_targets: &mut HashSet<String>,
    rename_map: &mut HashMap<String, String>,
) -> Result<()> {
    let old_transcript_abs = workspace_dir.join(transcript_rel);
    if !old_transcript_abs.is_file() {
        return Ok(());
    }

    let transcript_parent_rel = old_transcript_abs
        .parent()
        .and_then(|parent| parent.strip_prefix(workspace_dir).ok())
        .map(|rel| rel.to_string_lossy().replace('\\', "/"))
        .with_context(|| format!("missing transcript parent for {}", old_transcript_abs.display()))?;
    let transcript_ext = old_transcript_abs
        .extension()
        .and_then(|value| value.to_str())
        .unwrap_or("txt");
    let old_transcript_json_rel = super::transcript_json_rel_path(transcript_rel);
    let old_transcript_srt_rel = super::transcript_srt_rel_path(transcript_rel);

    let media_rel = linked_media_rel_path_for_transcript(workspace_dir, transcript_rel);
    let media_spec = media_rel.as_ref().and_then(|rel| {
        let media_abs = workspace_dir.join(rel);
        let parent_rel = media_abs
            .parent()?
            .strip_prefix(workspace_dir)
            .ok()?
            .to_string_lossy()
            .replace('\\', "/");
        let extension = media_abs
            .extension()
            .and_then(|value| value.to_str())
            .unwrap_or("")
            .to_string();
        Some((rel.clone(), parent_rel, extension))
    });

    let mut selected = None;
    for attempt in 0..=32usize {
        let candidate_seed = if attempt == 0 {
            stem.to_string()
        } else {
            format!(
                "{}-{}",
                stem,
                short_hash(&format!("{transcript_rel}|{stem}|{attempt}"))
            )
        };
        let candidate_transcript_rel =
            format!("{}/{}.{}", transcript_parent_rel, candidate_seed, transcript_ext);
        let candidate_transcript_json_rel =
            super::transcript_json_rel_path(&candidate_transcript_rel);
        let candidate_transcript_srt_rel =
            super::transcript_srt_rel_path(&candidate_transcript_rel);
        let candidate_media_rel = media_spec.as_ref().map(|(_, parent_rel, extension)| {
            format!("{}/{}.{}", parent_rel, candidate_seed, extension)
        });

        let transcript_conflict = path_rename_conflicts(
            workspace_dir,
            reserved_targets,
            &candidate_transcript_rel,
            transcript_rel,
        ) || path_rename_conflicts(
            workspace_dir,
            reserved_targets,
            &candidate_transcript_json_rel,
            &old_transcript_json_rel,
        ) || path_rename_conflicts(
            workspace_dir,
            reserved_targets,
            &candidate_transcript_srt_rel,
            &old_transcript_srt_rel,
        );
        let media_conflict = match (media_spec.as_ref(), candidate_media_rel.as_ref()) {
            (Some((old_media_rel, _, _)), Some(candidate_media_rel)) => path_rename_conflicts(
                workspace_dir,
                reserved_targets,
                candidate_media_rel,
                old_media_rel,
            ),
            _ => false,
        };

        if transcript_conflict || media_conflict {
            continue;
        }

        selected = Some((
            candidate_transcript_rel,
            candidate_transcript_json_rel,
            candidate_transcript_srt_rel,
            candidate_media_rel,
        ));
        break;
    }

    let Some((
        new_transcript_rel,
        new_transcript_json_rel,
        new_transcript_srt_rel,
        new_media_rel,
    )) = selected
    else {
        anyhow::bail!(
            "failed to choose a non-conflicting target name for transcript-backed media family {}",
            transcript_rel
        );
    };

    if let (Some((old_media_rel, _, _)), Some(new_media_rel)) = (media_spec.as_ref(), new_media_rel.as_ref()) {
        rename_workspace_file_if_exists(workspace_dir, old_media_rel, new_media_rel)?;
        if let Err(err) = local_store::rename_media_asset_path(workspace_dir, old_media_rel, new_media_rel) {
            tracing::warn!(
                old = old_media_rel,
                new = %new_media_rel,
                err = %err,
                "media asset path rename failed"
            );
        }
    }

    rename_workspace_file_if_exists(workspace_dir, transcript_rel, &new_transcript_rel)?;
    rename_workspace_file_if_exists(
        workspace_dir,
        &old_transcript_json_rel,
        &new_transcript_json_rel,
    )?;
    rename_workspace_file_if_exists(
        workspace_dir,
        &old_transcript_srt_rel,
        &new_transcript_srt_rel,
    )?;

    for (old_rel, new_rel) in [
        (transcript_rel, new_transcript_rel.as_str()),
        (old_transcript_json_rel.as_str(), new_transcript_json_rel.as_str()),
        (old_transcript_srt_rel.as_str(), new_transcript_srt_rel.as_str()),
    ] {
        if old_rel == new_rel {
            continue;
        }
        if let Err(err) = local_store::rename_workspace_synth_source_path(workspace_dir, old_rel, new_rel) {
            tracing::warn!(
                old = old_rel,
                new = %new_rel,
                err = %err,
                "transcript family source path rename failed"
            );
        }
    }
    if let Err(err) = local_store::rename_source_path_references(
        workspace_dir,
        transcript_rel,
        &new_transcript_rel,
    ) {
        tracing::warn!(
            old = transcript_rel,
            new = %new_transcript_rel,
            err = %err,
            "transcript family reference rename failed"
        );
    }
    if let Err(err) = rewrite_transcript_json_sidecar_after_family_rename(
        workspace_dir,
        &new_transcript_json_rel,
        new_media_rel.as_deref(),
        &new_transcript_rel,
    ) {
        tracing::warn!(
            path = %new_transcript_json_rel,
            err = %err,
            "failed to rewrite transcript json metadata after family rename"
        );
    }

    reserved_targets.insert(new_transcript_rel.clone());
    reserved_targets.insert(new_transcript_json_rel);
    reserved_targets.insert(new_transcript_srt_rel);
    if let Some(new_media_rel) = new_media_rel {
        reserved_targets.insert(new_media_rel);
    }
    rename_map.insert(transcript_rel.to_string(), new_transcript_rel);
    Ok(())
}

fn normalize_optional_id_list(values: &mut Vec<String>) {
    let mut seen = HashSet::new();
    let mut out = Vec::new();
    for value in values.iter() {
        let normalized = normalize_id(value);
        if !normalized.is_empty() && seen.insert(normalized.clone()) {
            out.push(normalized);
        }
    }
    *values = out;
}

fn normalize_provenance(
    provenance: &mut PrimitiveProvenance,
    fallback_source_path: Option<&str>,
    require_timed_transcript: bool,
) -> Result<()> {
    let raw_source_path = if provenance.source_path.trim().is_empty() {
        fallback_source_path.unwrap_or_default()
    } else {
        provenance.source_path.as_str()
    };
    provenance.source_path = normalize_source_path(raw_source_path)?;
    provenance.source_excerpt = truncate_with_ellipsis(provenance.source_excerpt.trim(), 280);
    provenance.start_at = provenance.start_at.trim().to_string();
    provenance.end_at = provenance.end_at.trim().to_string();
    provenance.speaker = truncate_with_ellipsis(provenance.speaker.trim(), 120);
    if let Some(confidence) = provenance.confidence.as_mut() {
        *confidence = confidence.clamp(0.0, 1.0);
    }
    let has_timing = !provenance.start_at.is_empty() || !provenance.end_at.is_empty();
    if has_timing && !is_transcript_source_path(&provenance.source_path) {
        anyhow::bail!("timed primitive provenance must point to transcript sidecars");
    }
    if require_timed_transcript && (!has_timing || !is_transcript_source_path(&provenance.source_path)) {
        anyhow::bail!("timed primitive items must point to transcript sidecars with startAt/endAt");
    }
    Ok(())
}

fn normalize_entity_items(mut items: Vec<EntityCandidate>) -> Result<Vec<EntityCandidate>> {
    if items.len() > MAX_ENTITIES {
        items.truncate(MAX_ENTITIES);
    }
    let mut used_ids = HashSet::new();
    for item in &mut items {
        item.kind = truncate_with_ellipsis(item.kind.trim(), 60);
        item.canonical_name = truncate_with_ellipsis(item.canonical_name.trim(), 160);
        item.aliases = item
            .aliases
            .iter()
            .map(|alias| truncate_with_ellipsis(alias.trim(), 160))
            .filter(|alias| !alias.is_empty())
            .collect();
        normalize_provenance(&mut item.provenance, None, false)?;
        if item.canonical_name.is_empty() {
            anyhow::bail!("entities items require non-empty canonicalName");
        }
        let seed = format!("{}|{}|{}", item.canonical_name, item.kind, item.provenance.source_path);
        item.id = unique_id(&used_ids, &item.id, &seed, "entity");
        used_ids.insert(item.id.clone());
    }
    Ok(items)
}

fn normalize_primitive_event_items(mut items: Vec<PrimitiveEventCandidate>) -> Result<Vec<PrimitiveEventCandidate>> {
    if items.len() > MAX_EVENTS {
        items.truncate(MAX_EVENTS);
    }
    let mut used_ids = HashSet::new();
    for item in &mut items {
        item.title = truncate_with_ellipsis(item.title.trim(), 120);
        item.kind = truncate_with_ellipsis(item.kind.trim(), 60);
        item.status = normalize_event_status(&item.status);
        item.details = truncate_with_ellipsis(item.details.trim(), 600);
        normalize_optional_id_list(&mut item.participants);
        normalize_optional_id_list(&mut item.related_entities);
        normalize_provenance(&mut item.provenance, None, false)?;
        item.start_at = if item.start_at.trim().is_empty() {
            item.provenance.start_at.clone()
        } else {
            item.start_at.trim().to_string()
        };
        item.end_at = if item.end_at.trim().is_empty() {
            item.provenance.end_at.clone()
        } else {
            item.end_at.trim().to_string()
        };
        if item.title.is_empty() {
            anyhow::bail!("primitive events items require non-empty title");
        }
        let seed = format!("{}|{}|{}", item.title, item.start_at, item.provenance.source_path);
        item.id = unique_id(&used_ids, &item.id, &seed, "pevent");
        used_ids.insert(item.id.clone());
    }
    Ok(items)
}

fn normalize_assertion_items(mut items: Vec<AssertionCandidate>) -> Result<Vec<AssertionCandidate>> {
    if items.len() > MAX_ASSERTIONS {
        items.truncate(MAX_ASSERTIONS);
    }
    let mut used_ids = HashSet::new();
    for item in &mut items {
        item.text = truncate_with_ellipsis(item.text.trim(), 400);
        item.kind = truncate_with_ellipsis(item.kind.trim(), 60);
        item.polarity = truncate_with_ellipsis(item.polarity.trim(), 30);
        item.status = truncate_with_ellipsis(item.status.trim(), 30);
        item.speaker = truncate_with_ellipsis(item.speaker.trim(), 120);
        normalize_optional_id_list(&mut item.related_entities);
        normalize_optional_id_list(&mut item.related_event_ids);
        normalize_provenance(&mut item.provenance, None, false)?;
        if item.speaker.is_empty() && !item.provenance.speaker.is_empty() {
            item.speaker = item.provenance.speaker.clone();
        }
        if item.text.is_empty() {
            anyhow::bail!("assertions items require non-empty text");
        }
        let seed = format!("{}|{}|{}", item.text, item.kind, item.provenance.source_path);
        item.id = unique_id(&used_ids, &item.id, &seed, "assertion");
        used_ids.insert(item.id.clone());
    }
    Ok(items)
}

fn normalize_action_items(mut items: Vec<ActionCandidate>) -> Result<Vec<ActionCandidate>> {
    if items.len() > MAX_ACTIONS {
        items.truncate(MAX_ACTIONS);
    }
    let mut used_ids = HashSet::new();
    for item in &mut items {
        item.title = truncate_with_ellipsis(item.title.trim(), 120);
        item.details = truncate_with_ellipsis(item.details.trim(), 600);
        item.status = normalize_todo_status(&item.status);
        item.priority = normalize_priority(&item.priority);
        item.owner = truncate_with_ellipsis(item.owner.trim(), 120);
        normalize_optional_id_list(&mut item.related_entities);
        normalize_optional_id_list(&mut item.related_assertion_ids);
        normalize_provenance(&mut item.provenance, None, false)?;
        if item.title.is_empty() {
            anyhow::bail!("actions items require non-empty title");
        }
        let seed = format!("{}|{}|{}", item.title, item.due_at, item.provenance.source_path);
        item.id = unique_id(&used_ids, &item.id, &seed, "action");
        used_ids.insert(item.id.clone());
    }
    Ok(items)
}

fn normalize_segment_items(mut items: Vec<SegmentCandidate>) -> Result<Vec<SegmentCandidate>> {
    if items.len() > MAX_SEGMENTS {
        items.truncate(MAX_SEGMENTS);
    }
    let mut used_ids = HashSet::new();
    for item in &mut items {
        item.label = truncate_with_ellipsis(item.label.trim(), 120);
        item.topic = truncate_with_ellipsis(item.topic.trim(), 160);
        item.source_path = normalize_source_path(&item.source_path)?;
        item.start_at = item.start_at.trim().to_string();
        item.end_at = item.end_at.trim().to_string();
        item.speaker = truncate_with_ellipsis(item.speaker.trim(), 120);
        item.transcript_quote = truncate_with_ellipsis(item.transcript_quote.trim(), 400);
        item.purpose = truncate_with_ellipsis(item.purpose.trim(), 160);
        normalize_provenance(&mut item.provenance, Some(&item.source_path), false)?;
        let has_timing = !item.start_at.is_empty() || !item.end_at.is_empty();
        if has_timing && !is_transcript_source_path(&item.source_path) {
            anyhow::bail!("segments with timing must point to transcript sidecars");
        }
        if item.label.is_empty() && item.topic.is_empty() {
            anyhow::bail!("segments items require non-empty label or topic");
        }
        let seed = format!(
            "{}|{}|{}|{}",
            item.label, item.topic, item.start_at, item.source_path
        );
        item.id = unique_id(&used_ids, &item.id, &seed, "segment");
        used_ids.insert(item.id.clone());
    }
    Ok(items)
}

fn normalize_structure_items(mut items: Vec<StructureCandidate>) -> Result<Vec<StructureCandidate>> {
    if items.len() > MAX_STRUCTURES {
        items.truncate(MAX_STRUCTURES);
    }
    let mut used_ids = HashSet::new();
    for item in &mut items {
        item.kind = truncate_with_ellipsis(item.kind.trim(), 60);
        item.title = truncate_with_ellipsis(item.title.trim(), 120);
        item.body = truncate_with_ellipsis(item.body.trim(), 1200);
        item.format_hint = truncate_with_ellipsis(item.format_hint.trim(), 60);
        normalize_optional_id_list(&mut item.source_primitive_ids);
        normalize_provenance(&mut item.provenance, None, false)?;
        if item.kind.is_empty() {
            anyhow::bail!("structures items require non-empty kind");
        }
        if item.body.is_empty() {
            anyhow::bail!("structures items require non-empty body");
        }
        let seed = format!("{}|{}|{}", item.kind, item.body, item.provenance.source_path);
        item.id = unique_id(&used_ids, &item.id, &seed, "structure");
        used_ids.insert(item.id.clone());
    }
    Ok(items)
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

fn is_inbox_text_journal_source_path(path: &str) -> bool {
    let normalized = path.trim().trim_start_matches('/').replace('\\', "/");
    normalized == super::JOURNAL_TEXT_INBOX_DIR
        || normalized.starts_with(&format!("{}/", super::JOURNAL_TEXT_INBOX_DIR))
}

fn journal_source_observed_at(path: &Path) -> Option<DateTime<Utc>> {
    let metadata = fs::metadata(path).ok()?;
    let timestamp = metadata.created().or_else(|_| metadata.modified()).ok()?;
    Some(timestamp.into())
}

fn canonical_journal_target_rel_path(
    workspace_dir: &Path,
    old_abs: &Path,
    old_rel: &str,
    stem: &str,
    extension: &str,
) -> Result<String> {
    if is_inbox_text_journal_source_path(old_rel) {
        let observed_at = journal_source_observed_at(old_abs).unwrap_or_else(Utc::now);
        return Ok(format!(
            "{}/{:04}/{:02}/{:02}/{}.{}",
            super::JOURNAL_TEXT_DIR,
            observed_at.year(),
            observed_at.month(),
            observed_at.day(),
            stem,
            extension
        ));
    }

    let parent = old_abs
        .parent()
        .with_context(|| format!("missing parent for {}", old_abs.display()))?;
    Ok(format!(
        "{}/{}.{}",
        parent
            .strip_prefix(workspace_dir)
            .unwrap_or(parent)
            .to_string_lossy()
            .replace('\\', "/"),
        stem,
        extension
    ))
}

fn apply_source_path_renames(
    processed_source_paths: &[String],
    journal_titles: &[JournalTitleCandidate],
    workspace_dir: &Path,
) -> Result<HashMap<String, String>> {
    let mut title_map = HashMap::new();
    for item in journal_titles {
        let old_rel = item.source_path.trim().trim_start_matches('/').replace('\\', "/");
        if old_rel.is_empty() {
            continue;
        }
        title_map.insert(old_rel, item.title.trim().to_string());
    }

    let mut target_paths = Vec::new();
    let mut seen_paths = HashSet::new();
    for path in processed_source_paths {
        let normalized = path.trim().trim_start_matches('/').replace('\\', "/");
        if normalized.is_empty() || !seen_paths.insert(normalized.clone()) {
            continue;
        }
        target_paths.push(normalized);
    }
    for path in title_map.keys() {
        if seen_paths.insert(path.clone()) {
            target_paths.push(path.clone());
        }
    }

    let mut rename_map = HashMap::new();
    let mut reserved_targets = HashSet::new();
    for old_rel in target_paths {
        if old_rel.is_empty() {
            continue;
        }
        if is_transcript_source_path(&old_rel) {
            let Some(title) = title_map.get(&old_rel) else {
                continue;
            };
            let mut stem = normalize_title_stem(title);
            if stem.is_empty() {
                stem = format!("recording-{}", short_hash(&format!("{}|{}", old_rel, title)));
            }
            rename_transcript_backed_media_family(
                workspace_dir,
                &old_rel,
                &stem,
                &mut reserved_targets,
                &mut rename_map,
            )?;
            continue;
        }
        let old_abs = workspace_dir.join(&old_rel);
        if !old_abs.is_file() {
            continue;
        }
        let extension = old_abs
            .extension()
            .and_then(|value| value.to_str())
            .unwrap_or("md")
            .to_string();
        let current_stem = old_abs
            .file_stem()
            .and_then(|value| value.to_str())
            .unwrap_or("");
        let mut stem = title_map
            .get(&old_rel)
            .map(|title| normalize_title_stem(title))
            .filter(|value| !value.is_empty())
            .unwrap_or_else(|| normalize_title_stem(current_stem));
        if stem.is_empty() {
            stem = format!("journal-{}", short_hash(&old_rel));
        }
        let mut candidate_rel =
            canonical_journal_target_rel_path(workspace_dir, &old_abs, &old_rel, &stem, &extension)?;
        let mut candidate_abs = workspace_dir.join(&candidate_rel);
        if reserved_targets.contains(&candidate_rel)
            || (candidate_abs.exists() && candidate_abs != old_abs)
        {
            let suffix = short_hash(&format!(
                "{}|{}",
                old_rel,
                title_map.get(&old_rel).cloned().unwrap_or_else(|| stem.clone())
            ));
            let candidate_seed = format!("{stem}-{suffix}");
            candidate_rel = canonical_journal_target_rel_path(
                workspace_dir,
                &old_abs,
                &old_rel,
                &candidate_seed,
                &extension,
            )?;
            candidate_abs = workspace_dir.join(&candidate_rel);
        }

        if candidate_abs == old_abs {
            continue;
        }

        if let Some(parent) = candidate_abs.parent() {
            fs::create_dir_all(parent)
                .with_context(|| format!("failed to create {}", parent.display()))?;
        }
        fs::rename(&old_abs, &candidate_abs).with_context(|| {
            format!("failed to rename {} -> {}", old_abs.display(), candidate_abs.display())
        })?;
        if let Err(e) = local_store::rename_workspace_synth_source_path(
            workspace_dir,
            &old_rel,
            &candidate_rel,
        ) {
            tracing::warn!(old = old_rel, new = %candidate_rel, err = %e, "synth source path rename failed");
        }
        let title_for_record = title_map
            .get(&old_rel)
            .cloned()
            .unwrap_or_else(|| current_stem.replace(['_', '-'], " "));
        match local_store::rename_journal_entry_path(
            workspace_dir,
            &old_rel,
            &candidate_rel,
            &title_for_record,
        ) {
            Ok(0) => tracing::warn!(old = old_rel, new = %candidate_rel, "journal rename: no DB rows matched"),
            Err(e) => tracing::warn!(old = old_rel, new = %candidate_rel, err = %e, "journal rename failed"),
            _ => {}
        }
        reserved_targets.insert(candidate_rel.clone());
        rename_map.insert(old_rel.to_string(), candidate_rel);
    }
    Ok(rename_map)
}

fn rewrite_source_path(path: &mut String, rename_map: &HashMap<String, String>) {
    if let Some(next) = rename_map.get(path.trim()) {
        *path = next.clone();
    }
}

#[derive(Debug, Clone, Default)]
struct LoadedPrimitiveHandoffs {
    entities: Option<Vec<EntityCandidate>>,
    events: Option<Vec<PrimitiveEventCandidate>>,
    assertions: Option<Vec<AssertionCandidate>>,
    actions: Option<Vec<ActionCandidate>>,
    segments: Option<Vec<SegmentCandidate>>,
    structures: Option<Vec<StructureCandidate>>,
}

fn primitive_artifact_states_default() -> WorkspaceSynthArtifactStates {
    WorkspaceSynthArtifactStates {
        insight_posts: skipped_artifact_state(WORKSPACE_SYNTHESIZER_INSIGHT_POSTS_PATH),
        todos: skipped_artifact_state(WORKSPACE_SYNTHESIZER_TODOS_PATH),
        events: skipped_artifact_state(WORKSPACE_SYNTHESIZER_EVENTS_PATH),
        clip_plans: skipped_artifact_state(WORKSPACE_SYNTHESIZER_CLIP_PLANS_PATH),
        journal_titles: skipped_artifact_state(WORKSPACE_SYNTHESIZER_JOURNAL_TITLES_PATH),
        primitive_entities: skipped_artifact_state(WORKSPACE_SYNTHESIZER_PRIMITIVE_ENTITIES_PATH),
        primitive_events: skipped_artifact_state(WORKSPACE_SYNTHESIZER_PRIMITIVE_EVENTS_PATH),
        primitive_assertions: skipped_artifact_state(WORKSPACE_SYNTHESIZER_PRIMITIVE_ASSERTIONS_PATH),
        primitive_actions: skipped_artifact_state(WORKSPACE_SYNTHESIZER_PRIMITIVE_ACTIONS_PATH),
        primitive_segments: skipped_artifact_state(WORKSPACE_SYNTHESIZER_PRIMITIVE_SEGMENTS_PATH),
        primitive_structures: skipped_artifact_state(WORKSPACE_SYNTHESIZER_PRIMITIVE_STRUCTURES_PATH),
    }
}

fn compile_todos_from_actions(items: &[ActionCandidate]) -> Vec<TodoCandidate> {
    items.iter()
        .map(|item| TodoCandidate {
            id: item.id.clone(),
            title: item.title.clone(),
            details: item.details.clone(),
            priority: item.priority.clone(),
            status: item.status.clone(),
            due_at: item.due_at.clone(),
            source_path: item.provenance.source_path.clone(),
            source_excerpt: item.provenance.source_excerpt.clone(),
        })
        .collect()
}

fn compile_events_from_primitive_events(items: &[PrimitiveEventCandidate]) -> Vec<EventCandidate> {
    items.iter()
        .map(|item| EventCandidate {
            id: item.id.clone(),
            title: item.title.clone(),
            details: item.details.clone(),
            location: String::new(),
            status: item.status.clone(),
            start_at: item.start_at.clone(),
            end_at: item.end_at.clone(),
            all_day: item.start_at.len() == 10 && item.end_at.is_empty(),
            source_path: item.provenance.source_path.clone(),
            source_excerpt: item.provenance.source_excerpt.clone(),
        })
        .collect()
}

fn compile_clip_plans_from_segments(
    segments: &[SegmentCandidate],
    assertions: &[AssertionCandidate],
    structures: &[StructureCandidate],
) -> Vec<ClipPlanCandidate> {
    segments
        .iter()
        .filter(|item| !item.start_at.is_empty() && !item.end_at.is_empty() && is_transcript_source_path(&item.source_path))
        .take(MAX_CLIP_PLANS)
        .map(|item| {
            let mut notes_parts = Vec::new();
            if !item.purpose.is_empty() {
                notes_parts.push(item.purpose.clone());
            }
            if let Some(assertion) = assertions
                .iter()
                .find(|assertion| assertion.provenance.source_path == item.source_path)
            {
                notes_parts.push(format!("Assertion: {}", assertion.text));
            }
            if let Some(structure) = structures
                .iter()
                .find(|structure| structure.provenance.source_path == item.source_path)
            {
                notes_parts.push(format!("Structure: {}", structure.kind));
            }
            ClipPlanCandidate {
                id: item.id.clone(),
                title: if item.label.is_empty() {
                    truncate_with_ellipsis(&item.topic, 120)
                } else {
                    item.label.clone()
                },
                source_path: item.source_path.clone(),
                source_excerpt: item.provenance.source_excerpt.clone(),
                transcript_quote: if item.transcript_quote.is_empty() {
                    item.provenance.source_excerpt.clone()
                } else {
                    item.transcript_quote.clone()
                },
                start_at: item.start_at.clone(),
                end_at: item.end_at.clone(),
                notes: truncate_with_ellipsis(&notes_parts.join(" | "), 600),
            }
        })
        .collect()
}

fn compile_insight_posts_from_primitives(
    assertions: &[AssertionCandidate],
    segments: &[SegmentCandidate],
    structures: &[StructureCandidate],
) -> Vec<InsightPostCandidate> {
    let mut items = assertions
        .iter()
        .filter(|item| {
            matches!(
                item.kind.to_ascii_lowercase().as_str(),
                "claim" | "belief" | "decision" | "question"
            )
        })
        .take(MAX_INSIGHT_POSTS)
        .map(|item| {
            let supporting_segment = segments
                .iter()
                .find(|segment| segment.provenance.source_path == item.provenance.source_path);
            let text = supporting_segment
                .and_then(|segment| {
                    if segment.transcript_quote.trim().is_empty() {
                        None
                    } else {
                        Some(segment.transcript_quote.as_str())
                    }
                })
                .unwrap_or(item.text.as_str());
            InsightPostCandidate {
                id: item.id.clone(),
                text: truncate_with_ellipsis(text, 480),
                source_path: item.provenance.source_path.clone(),
                source_excerpt: item.provenance.source_excerpt.clone(),
            }
        })
        .collect::<Vec<_>>();
    if !items.is_empty() {
        return items;
    }
    items = structures
        .iter()
        .filter(|item| item.kind.eq_ignore_ascii_case("post"))
        .take(MAX_INSIGHT_POSTS)
        .map(|item| InsightPostCandidate {
            id: item.id.clone(),
            text: truncate_with_ellipsis(&item.body, 480),
            source_path: item.provenance.source_path.clone(),
            source_excerpt: item.provenance.source_excerpt.clone(),
        })
        .collect();
    items
}

fn apply_primitive_handoff_files(
    workspace_dir: &Path,
    manifest_id: &str,
    processed_source_paths: &[String],
    handoffs: LoadedPrimitiveHandoffs,
    legacy_insight_items: Option<Vec<InsightPostCandidate>>,
    legacy_todo_items: Option<Vec<TodoCandidate>>,
    legacy_event_items: Option<Vec<EventCandidate>>,
    legacy_clip_plan_items: Option<Vec<ClipPlanCandidate>>,
    journal_title_items: Option<Vec<JournalTitleCandidate>>,
    result: &mut WorkspaceSynthesisApplyResult,
    error_messages: &mut Vec<String>,
) -> Result<()> {
    let rename_map = match apply_source_path_renames(
        processed_source_paths,
        journal_title_items.as_deref().unwrap_or(&[]),
        workspace_dir,
    ) {
        Ok(map) => map,
        Err(err) => {
            result.had_errors = true;
            error_messages.push(format!("journal titles: {err}"));
            HashMap::new()
        }
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
    }

    let used_entities = handoffs.entities.is_some();
    let used_primitive_events = handoffs.events.is_some();
    let used_assertions = handoffs.assertions.is_some();
    let used_actions = handoffs.actions.is_some();
    let used_segments = handoffs.segments.is_some();
    let used_structures = handoffs.structures.is_some();

    let entities = handoffs.entities.unwrap_or_default();
    let primitive_events = handoffs.events.unwrap_or_default();
    let assertions = handoffs.assertions.unwrap_or_default();
    let actions = handoffs.actions.unwrap_or_default();
    let mut segments = handoffs.segments.unwrap_or_default();
    let mut structures = handoffs.structures.unwrap_or_default();

    for item in &mut segments {
        rewrite_source_path(&mut item.source_path, &rename_map);
        rewrite_source_path(&mut item.provenance.source_path, &rename_map);
    }
    for item in &mut structures {
        rewrite_source_path(&mut item.provenance.source_path, &rename_map);
    }

    result.counts.primitive_entities = entities.len();
    result.counts.primitive_events = primitive_events.len();
    result.counts.primitive_assertions = assertions.len();
    result.counts.primitive_actions = actions.len();
    result.counts.primitive_segments = segments.len();
    result.counts.primitive_structures = structures.len();
    result.artifact_states.primitive_entities = if used_entities {
        applied_artifact_state(WORKSPACE_SYNTHESIZER_PRIMITIVE_ENTITIES_PATH, entities.len())
    } else {
        skipped_artifact_state(WORKSPACE_SYNTHESIZER_PRIMITIVE_ENTITIES_PATH)
    };
    result.artifact_states.primitive_events = if used_primitive_events {
        applied_artifact_state(WORKSPACE_SYNTHESIZER_PRIMITIVE_EVENTS_PATH, primitive_events.len())
    } else {
        skipped_artifact_state(WORKSPACE_SYNTHESIZER_PRIMITIVE_EVENTS_PATH)
    };
    result.artifact_states.primitive_assertions = if used_assertions {
        applied_artifact_state(WORKSPACE_SYNTHESIZER_PRIMITIVE_ASSERTIONS_PATH, assertions.len())
    } else {
        skipped_artifact_state(WORKSPACE_SYNTHESIZER_PRIMITIVE_ASSERTIONS_PATH)
    };
    result.artifact_states.primitive_actions = if used_actions {
        applied_artifact_state(WORKSPACE_SYNTHESIZER_PRIMITIVE_ACTIONS_PATH, actions.len())
    } else {
        skipped_artifact_state(WORKSPACE_SYNTHESIZER_PRIMITIVE_ACTIONS_PATH)
    };
    result.artifact_states.primitive_segments = if used_segments {
        applied_artifact_state(WORKSPACE_SYNTHESIZER_PRIMITIVE_SEGMENTS_PATH, segments.len())
    } else {
        skipped_artifact_state(WORKSPACE_SYNTHESIZER_PRIMITIVE_SEGMENTS_PATH)
    };
    result.artifact_states.primitive_structures = if used_structures {
        applied_artifact_state(WORKSPACE_SYNTHESIZER_PRIMITIVE_STRUCTURES_PATH, structures.len())
    } else {
        skipped_artifact_state(WORKSPACE_SYNTHESIZER_PRIMITIVE_STRUCTURES_PATH)
    };

    let compiled_insight_posts = if used_structures || used_assertions {
        compile_insight_posts_from_primitives(&assertions, &segments, &structures)
    } else {
        legacy_insight_items.unwrap_or_default()
    };
    let compiled_todos = if used_actions {
        compile_todos_from_actions(&actions)
    } else {
        legacy_todo_items.unwrap_or_default()
    };
    let compiled_events = if used_primitive_events {
        compile_events_from_primitive_events(&primitive_events)
    } else {
        legacy_event_items.unwrap_or_default()
    };
    let compiled_clip_plans = if used_segments {
        compile_clip_plans_from_segments(&segments, &assertions, &structures)
    } else {
        legacy_clip_plan_items.unwrap_or_default()
    };

    let manifest = WorkspaceSynthesisManifest {
        version: manifest_version(),
        insight_posts: compiled_insight_posts,
        todos: compiled_todos,
        events: compiled_events,
        clip_plans: compiled_clip_plans,
        run_summary: ManifestRunSummary {
            notes: format!(
                "Compiled app outputs from primitive handoffs: entities={}, events={}, assertions={}, actions={}, segments={}, optional_draft_structures={}.",
                entities.len(),
                primitive_events.len(),
                assertions.len(),
                actions.len(),
                segments.len(),
                structures.len()
            ),
        },
    };

    let mut applied = apply_manifest(workspace_dir, &manifest, manifest_id)?;
    if !rename_map.is_empty() {
        applied.renamed_sources = result.renamed_sources.clone();
    }
    applied.artifact_states = result.artifact_states.clone();
    applied.counts.primitive_entities = entities.len();
    applied.counts.primitive_events = primitive_events.len();
    applied.counts.primitive_assertions = assertions.len();
    applied.counts.primitive_actions = actions.len();
    applied.counts.primitive_segments = segments.len();
    applied.counts.primitive_structures = structures.len();
    applied.summary = format!(
        "{} Primitive compilation active.",
        build_apply_summary(
            &applied.counts,
            applied.renamed_sources.len(),
            applied.had_errors,
            applied.applied_any,
            error_messages
        )
    );
    *result = applied;
    if result.counts.todos == 0 && !processed_source_paths.is_empty() {
        result.counts.todos = 0;
    }
    Ok(())
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
        ..WorkspaceSynthArtifactCounts::default()
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
        skill_runs: Vec::new(),
        triage_keywords: Vec::new(),
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
        artifact_states: primitive_artifact_states_default(),
        ..WorkspaceSynthesisApplyResult::default()
    };
    let mut saw_split_file = false;
    let mut saw_primitive_file = false;
    let mut error_messages = Vec::new();
    let mut primitive_handoffs = LoadedPrimitiveHandoffs::default();
    let mut insight_items: Option<Vec<InsightPostCandidate>> = None;
    let mut todo_items_raw: Option<Vec<TodoCandidate>> = None;
    let mut event_items_raw: Option<Vec<EventCandidate>> = None;
    let mut clip_plan_items: Option<Vec<ClipPlanCandidate>> = None;
    let mut journal_title_items: Option<Vec<JournalTitleCandidate>> = None;

    if primitive_entities_path(workspace_dir).is_file() {
        saw_primitive_file = true;
        match load_optional_entities_file(workspace_dir) {
            Ok(Some(items)) => primitive_handoffs.entities = Some(items),
            Ok(None) => {}
            Err(err) => {
                result.had_errors = true;
                result.artifact_states.primitive_entities =
                    error_artifact_state(WORKSPACE_SYNTHESIZER_PRIMITIVE_ENTITIES_PATH, &err);
                error_messages.push(format!("entities: {err}"));
            }
        }
    }

    if primitive_events_path(workspace_dir).is_file() {
        saw_primitive_file = true;
        match load_optional_primitive_events_file(workspace_dir) {
            Ok(Some(items)) => primitive_handoffs.events = Some(items),
            Ok(None) => {}
            Err(err) => {
                result.had_errors = true;
                result.artifact_states.primitive_events =
                    error_artifact_state(WORKSPACE_SYNTHESIZER_PRIMITIVE_EVENTS_PATH, &err);
                error_messages.push(format!("primitive events: {err}"));
            }
        }
    }

    if primitive_assertions_path(workspace_dir).is_file() {
        saw_primitive_file = true;
        match load_optional_assertions_file(workspace_dir) {
            Ok(Some(items)) => primitive_handoffs.assertions = Some(items),
            Ok(None) => {}
            Err(err) => {
                result.had_errors = true;
                result.artifact_states.primitive_assertions =
                    error_artifact_state(WORKSPACE_SYNTHESIZER_PRIMITIVE_ASSERTIONS_PATH, &err);
                error_messages.push(format!("assertions: {err}"));
            }
        }
    }

    if primitive_actions_path(workspace_dir).is_file() {
        saw_primitive_file = true;
        match load_optional_actions_file(workspace_dir) {
            Ok(Some(items)) => primitive_handoffs.actions = Some(items),
            Ok(None) => {}
            Err(err) => {
                result.had_errors = true;
                result.artifact_states.primitive_actions =
                    error_artifact_state(WORKSPACE_SYNTHESIZER_PRIMITIVE_ACTIONS_PATH, &err);
                error_messages.push(format!("actions: {err}"));
            }
        }
    }

    if primitive_segments_path(workspace_dir).is_file() {
        saw_primitive_file = true;
        match load_optional_segments_file(workspace_dir) {
            Ok(Some(items)) => primitive_handoffs.segments = Some(items),
            Ok(None) => {}
            Err(err) => {
                result.had_errors = true;
                result.artifact_states.primitive_segments =
                    error_artifact_state(WORKSPACE_SYNTHESIZER_PRIMITIVE_SEGMENTS_PATH, &err);
                error_messages.push(format!("segments: {err}"));
            }
        }
    }

    if primitive_structures_path(workspace_dir).is_file() {
        saw_primitive_file = true;
        match load_optional_structures_file(workspace_dir) {
            Ok(Some(items)) => primitive_handoffs.structures = Some(items),
            Ok(None) => {}
            Err(err) => {
                result.had_errors = true;
                result.artifact_states.primitive_structures =
                    error_artifact_state(WORKSPACE_SYNTHESIZER_PRIMITIVE_STRUCTURES_PATH, &err);
                error_messages.push(format!("structures: {err}"));
            }
        }
    }

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
                result.artifact_states.journal_titles =
                    error_artifact_state(WORKSPACE_SYNTHESIZER_JOURNAL_TITLES_PATH, &err);
                error_messages.push(format!("journal titles: {err}"));
            }
        }
    }

    if saw_primitive_file && !saw_split_file {
        apply_primitive_handoff_files(
            workspace_dir,
            manifest_id,
            processed_source_paths,
            primitive_handoffs,
            insight_items,
            todo_items_raw,
            event_items_raw,
            clip_plan_items,
            journal_title_items,
            &mut result,
            &mut error_messages,
        )?;
        return Ok(result);
    }

    let rename_map = match apply_source_path_renames(
        processed_source_paths,
        journal_title_items.as_deref().unwrap_or(&[]),
        workspace_dir,
    ) {
        Ok(map) => map,
        Err(err) => {
            result.had_errors = true;
            error_messages.push(format!("journal titles: {err}"));
            HashMap::new()
        }
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
    result.artifact_states.journal_titles = if !result.renamed_sources.is_empty() {
        applied_artifact_state(
            WORKSPACE_SYNTHESIZER_JOURNAL_TITLES_PATH,
            result.renamed_sources.len(),
        )
    } else if result.artifact_states.journal_titles.error.trim().is_empty() {
        skipped_artifact_state(WORKSPACE_SYNTHESIZER_JOURNAL_TITLES_PATH)
    } else {
        result.artifact_states.journal_titles.clone()
    };

    let primitive_entities = primitive_handoffs.entities.unwrap_or_default();
    let primitive_events = primitive_handoffs.events.unwrap_or_default();
    let primitive_assertions = primitive_handoffs.assertions.unwrap_or_default();
    let primitive_actions = primitive_handoffs.actions.unwrap_or_default();
    let mut primitive_segments = primitive_handoffs.segments.unwrap_or_default();
    let mut primitive_structures = primitive_handoffs.structures.unwrap_or_default();

    for item in &mut primitive_segments {
        rewrite_source_path(&mut item.source_path, &rename_map);
        rewrite_source_path(&mut item.provenance.source_path, &rename_map);
    }
    for item in &mut primitive_structures {
        rewrite_source_path(&mut item.provenance.source_path, &rename_map);
    }

    result.counts.primitive_entities = primitive_entities.len();
    result.counts.primitive_events = primitive_events.len();
    result.counts.primitive_assertions = primitive_assertions.len();
    result.counts.primitive_actions = primitive_actions.len();
    result.counts.primitive_segments = primitive_segments.len();
    result.counts.primitive_structures = primitive_structures.len();
    if saw_primitive_file {
        if result.artifact_states.primitive_entities.status != "error" {
            result.artifact_states.primitive_entities = applied_artifact_state(
                WORKSPACE_SYNTHESIZER_PRIMITIVE_ENTITIES_PATH,
                primitive_entities.len(),
            );
        }
        if result.artifact_states.primitive_events.status != "error" {
            result.artifact_states.primitive_events = applied_artifact_state(
                WORKSPACE_SYNTHESIZER_PRIMITIVE_EVENTS_PATH,
                primitive_events.len(),
            );
        }
        if result.artifact_states.primitive_assertions.status != "error" {
            result.artifact_states.primitive_assertions = applied_artifact_state(
                WORKSPACE_SYNTHESIZER_PRIMITIVE_ASSERTIONS_PATH,
                primitive_assertions.len(),
            );
        }
        if result.artifact_states.primitive_actions.status != "error" {
            result.artifact_states.primitive_actions = applied_artifact_state(
                WORKSPACE_SYNTHESIZER_PRIMITIVE_ACTIONS_PATH,
                primitive_actions.len(),
            );
        }
        if result.artifact_states.primitive_segments.status != "error" {
            result.artifact_states.primitive_segments = applied_artifact_state(
                WORKSPACE_SYNTHESIZER_PRIMITIVE_SEGMENTS_PATH,
                primitive_segments.len(),
            );
        }
        if result.artifact_states.primitive_structures.status != "error" {
            result.artifact_states.primitive_structures = applied_artifact_state(
                WORKSPACE_SYNTHESIZER_PRIMITIVE_STRUCTURES_PATH,
                primitive_structures.len(),
            );
        }
    }

    if insight_items.is_none() && (!primitive_assertions.is_empty() || !primitive_structures.is_empty()) {
        let compiled = compile_insight_posts_from_primitives(
            &primitive_assertions,
            &primitive_segments,
            &primitive_structures,
        );
        if !compiled.is_empty() {
            insight_items = Some(compiled);
        }
    }
    if todo_items_raw.is_none() && !primitive_actions.is_empty() {
        todo_items_raw = Some(compile_todos_from_actions(&primitive_actions));
    }
    if event_items_raw.is_none() && !primitive_events.is_empty() {
        event_items_raw = Some(compile_events_from_primitive_events(&primitive_events));
    }
    if clip_plan_items.is_none() && !primitive_segments.is_empty() {
        let compiled = compile_clip_plans_from_segments(
            &primitive_segments,
            &primitive_assertions,
            &primitive_structures,
        );
        if !compiled.is_empty() {
            clip_plan_items = Some(compiled);
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
        ..WorkspaceSynthArtifactStates::default()
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

fn collect_visible_outputs_recursive(
    dir: &Path,
    workspace_dir: &Path,
    out: &mut Vec<String>,
) -> Result<()> {
    let entries = match fs::read_dir(dir) {
        Ok(entries) => entries,
        Err(err) if err.kind() == std::io::ErrorKind::NotFound => return Ok(()),
        Err(err) => return Err(err).with_context(|| format!("failed to read {}", dir.display())),
    };
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
            if rel.ends_with("/pipeline")
                || rel.contains("/pipeline/")
                || rel.ends_with("/artifacts")
                || rel.contains("/artifacts/")
            {
                continue;
            }
            collect_visible_outputs_recursive(&path, workspace_dir, out)?;
            continue;
        }
        if !file_type.is_file() {
            continue;
        }
        let rel = path
            .strip_prefix(workspace_dir)
            .unwrap_or(&path)
            .to_string_lossy()
            .replace('\\', "/");
        if rel.ends_with(".json") || rel.ends_with(".srt") || rel.ends_with(".caption.txt") {
            continue;
        }
        out.push(rel);
    }
    Ok(())
}

fn count_visible_outputs_recursive(dir: &Path, workspace_dir: &Path) -> Result<usize> {
    let mut out = Vec::new();
    collect_visible_outputs_recursive(dir, workspace_dir, &mut out)?;
    Ok(out.len())
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
    fn todo_ids_stay_stable_when_only_source_excerpt_changes() {
        let base = TodoCandidate {
            title: "Email the team".to_string(),
            details: "Share the launch checklist".to_string(),
            due_at: "2026-03-12".to_string(),
            source_path: "journals/text/2026-03-11.md".to_string(),
            source_excerpt: "Need to send the checklist tomorrow.".to_string(),
            ..TodoCandidate::default()
        };

        let first = normalize_todo_items(vec![base.clone()]).unwrap();
        let second = normalize_todo_items(vec![TodoCandidate {
            source_excerpt: "Need to send the checklist first thing tomorrow.".to_string(),
            ..base
        }])
        .unwrap();

        assert_eq!(first[0].id, second[0].id);
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
    fn normalize_segment_items_allows_untimed_text_journal_segments() {
        let items = normalize_segment_items(vec![SegmentCandidate {
            label: "Product demo".to_string(),
            topic: "demo".to_string(),
            source_path: "journals/text/2026-03-11.md".to_string(),
            provenance: PrimitiveProvenance {
                source_path: "journals/text/2026-03-11.md".to_string(),
                source_excerpt: "Talked through the demo section.".to_string(),
                ..PrimitiveProvenance::default()
            },
            ..SegmentCandidate::default()
        }])
        .unwrap();

        assert_eq!(items.len(), 1);
        assert!(items[0].start_at.is_empty());
        assert!(items[0].end_at.is_empty());
    }

    #[test]
    fn normalize_segment_items_rejects_timing_outside_transcripts() {
        let err = normalize_segment_items(vec![SegmentCandidate {
            label: "Timed segment".to_string(),
            source_path: "journals/text/2026-03-11.md".to_string(),
            start_at: "00:00:01.000".to_string(),
            end_at: "00:00:05.000".to_string(),
            provenance: PrimitiveProvenance {
                source_path: "journals/text/2026-03-11.md".to_string(),
                source_excerpt: "Timed excerpt".to_string(),
                ..PrimitiveProvenance::default()
            },
            ..SegmentCandidate::default()
        }])
        .unwrap_err();

        assert!(format!("{err:#}").contains("segments with timing must point to transcript sidecars"));
    }

    #[test]
    fn normalize_action_items_generates_stable_ids() {
        let base = ActionCandidate {
            title: "Email the team".to_string(),
            due_at: "2026-03-12".to_string(),
            provenance: PrimitiveProvenance {
                source_path: "journals/text/2026-03-11.md".to_string(),
                source_excerpt: "Need to email the team tomorrow.".to_string(),
                ..PrimitiveProvenance::default()
            },
            ..ActionCandidate::default()
        };

        let first = normalize_action_items(vec![base.clone()]).unwrap();
        let second = normalize_action_items(vec![ActionCandidate {
            details: "Share the latest synthesis update.".to_string(),
            ..base
        }])
        .unwrap();

        assert_eq!(first[0].id, second[0].id);
    }

    #[test]
    fn artifact_rules_from_markdown_extracts_section_body() {
        let markdown = "\
# Skill

## Artifact Rules

- Emit concise, feed-ready text only.
- No titles.

## Output Schema

Use JSON.
";

        assert_eq!(
            artifact_rules_from_markdown(markdown),
            "- Emit concise, feed-ready text only.\n- No titles."
        );
    }

    #[test]
    fn effective_artifact_rules_prefers_override_text() {
        let markdown = "\
## Artifact Rules

- Built-in rule.
";

        assert_eq!(
            effective_artifact_rules(markdown, "  - Custom rule.\n- Another rule.  "),
            "- Custom rule.\n- Another rule."
        );
    }

    #[test]
    fn artifact_rules_from_markdown_returns_empty_when_missing() {
        let markdown = "\
## Goal

Do something useful.
";

        assert!(artifact_rules_from_markdown(markdown).is_empty());
    }

    #[test]
    fn materialize_extractor_response_accepts_fenced_json_object() {
        let tmp = tempdir().unwrap();
        let response = r#"```json
{
  "version": "1",
  "items": [
    {
      "text": "Capture the strongest lesson while the note is still fresh.",
      "sourcePath": "journals/text/2026-03-21.md",
      "sourceExcerpt": "Capture the strongest lesson while the note is still fresh."
    }
  ]
}
```"#;

        let written = materialize_extractor_response(
            tmp.path(),
            WORKSPACE_INSIGHT_EXTRACTOR_WORKFLOW_KEY,
            response,
        )
        .unwrap();

        assert_eq!(written, 1);
        let file = load_optional_insight_posts_file(tmp.path()).unwrap().unwrap();
        assert_eq!(file.len(), 1);
        assert_eq!(
            file[0].source_path,
            "journals/text/2026-03-21.md"
        );
    }

    #[test]
    fn materialize_extractor_response_accepts_array_payload() {
        let tmp = tempdir().unwrap();
        let response = r#"[
  {
    "title": "Send the follow-up note",
    "details": "Share the synthesis test result with the team.",
    "priority": "high",
    "status": "open",
    "dueAt": "2026-03-22",
    "sourcePath": "journals/text/2026-03-21.md",
    "sourceExcerpt": "Need to send the follow-up note tomorrow."
  }
]"#;

        let written = materialize_extractor_response(
            tmp.path(),
            WORKSPACE_TODO_EXTRACTOR_WORKFLOW_KEY,
            response,
        )
        .unwrap();

        assert_eq!(written, 1);
        let file = load_optional_todos_file(tmp.path()).unwrap().unwrap();
        assert_eq!(file.len(), 1);
        assert_eq!(file[0].title, "Send the follow-up note");
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
    fn apply_handoff_files_marks_journal_titles_applied_when_rename_succeeds() {
        let tmp = tempdir().unwrap();
        let journal_rel = "journals/text/2026/03/15/103944_Journal_entry.md";
        let journal_abs = tmp.path().join(journal_rel);
        fs::create_dir_all(journal_abs.parent().unwrap()).unwrap();
        fs::write(&journal_abs, "A note about work and life.").unwrap();

        let titles = JournalTitleFile {
            version: "1".to_string(),
            items: vec![JournalTitleCandidate {
                source_path: journal_rel.to_string(),
                title: "Work and Life Reflections".to_string(),
            }],
        };
        write_json_file(&journal_titles_path(tmp.path()), &titles);

        let processed_source_paths = vec![journal_rel.to_string()];
        let applied = apply_handoff_files(tmp.path(), "run-title", &processed_source_paths).unwrap();

        assert_eq!(applied.artifact_states.journal_titles.status, "applied");
        assert_eq!(applied.artifact_states.journal_titles.item_count, 1);
        assert_eq!(applied.renamed_sources.len(), 1);
        assert_eq!(
            applied.renamed_sources[0].to_path,
            "journals/text/2026/03/15/work-and-life-reflections.md"
        );
        assert!(
            tmp.path()
                .join("journals/text/2026/03/15/work-and-life-reflections.md")
                .exists()
        );
    }

    #[test]
    fn apply_handoff_files_moves_processed_inbox_note_into_dated_folder_without_title_handoff() {
        let tmp = tempdir().unwrap();
        let journal_rel = "journals/text/inbox/raw-note.md";
        let journal_abs = tmp.path().join(journal_rel);
        fs::create_dir_all(journal_abs.parent().unwrap()).unwrap();
        fs::write(&journal_abs, "Inbox note waiting for synthesis.").unwrap();
        let observed_at = journal_source_observed_at(&journal_abs).unwrap();

        let processed_source_paths = vec![journal_rel.to_string()];
        let applied = apply_handoff_files(tmp.path(), "run-inbox", &processed_source_paths).unwrap();

        assert_eq!(applied.renamed_sources.len(), 1);
        let expected_rel = format!(
            "journals/text/{:04}/{:02}/{:02}/raw-note.md",
            observed_at.year(),
            observed_at.month(),
            observed_at.day()
        );
        assert_eq!(applied.renamed_sources[0].to_path, expected_rel);
        assert!(tmp.path().join(&applied.renamed_sources[0].to_path).exists());
        assert!(!tmp.path().join(journal_rel).exists());
    }

    #[test]
    fn apply_handoff_files_renames_transcript_backed_media_family_from_title_handoff() {
        let tmp = tempdir().unwrap();
        local_store::initialize(tmp.path()).unwrap();

        let media_rel = "journals/media/audio/2026/03/30/190553_Audio_20260208_123857.mp3";
        let transcript_rel =
            "journals/text/transcriptions/audio/2026/03/30/190553_Audio_20260208_123857.txt";
        let media_abs = tmp.path().join(media_rel);
        let transcript_abs = tmp.path().join(transcript_rel);
        fs::create_dir_all(media_abs.parent().unwrap()).unwrap();
        fs::create_dir_all(transcript_abs.parent().unwrap()).unwrap();
        fs::write(&media_abs, b"audio").unwrap();
        fs::write(&transcript_abs, "mindful observation").unwrap();
        fs::write(
            tmp.path().join(super::super::transcript_json_rel_path(transcript_rel)),
            format!(
                "{}\n",
                serde_json::to_string_pretty(&serde_json::json!({
                    "ok": true,
                    "source": media_abs.to_string_lossy(),
                    "transcriptPath": transcript_abs.to_string_lossy(),
                }))
                .unwrap()
            ),
        )
        .unwrap();
        fs::write(
            tmp.path().join(super::super::transcript_srt_rel_path(transcript_rel)),
            "1\n00:00:00,000 --> 00:00:01,000\nmindful observation\n",
        )
        .unwrap();

        local_store::create_media_asset_metadata(
            tmp.path(),
            &local_store::MediaAssetInput {
                title: "Audio 20260208 123857".to_string(),
                entry_id: String::new(),
                asset_type: "audio".to_string(),
                mime_type: "audio/mpeg".to_string(),
                source: "workspace".to_string(),
                status: "ready".to_string(),
                workspace_path: media_rel.to_string(),
                size_bytes: 5,
                created_at_client: None,
            },
        )
        .unwrap();
        local_store::upsert_workspace_synth_sources(
            tmp.path(),
            &[local_store::WorkspaceSynthSourceUpsert {
                source_path: transcript_rel.to_string(),
                content_hash: "hash-1".to_string(),
                word_count: 12,
                last_processed_hash: String::new(),
                last_processed_at: String::new(),
                last_batch_id: String::new(),
            }],
        )
        .unwrap();
        local_store::upsert_feed_interest_source(
            tmp.path(),
            &local_store::FeedInterestSourceRecord {
                source_path: transcript_rel.to_string(),
                content_hash: "hash-1".to_string(),
                profile_input_hash: String::new(),
                interest_id: None,
                title: "Audio 20260208 123857".to_string(),
                triage_keywords_json: "[\"mindfulness\"]".to_string(),
                updated_at: Utc::now().to_rfc3339(),
            },
        )
        .unwrap();

        write_json_file(
            &journal_titles_path(tmp.path()),
            &JournalTitleFile {
                version: "1".to_string(),
                items: vec![JournalTitleCandidate {
                    source_path: transcript_rel.to_string(),
                    title: "Mindful Observation Beyond Judgment".to_string(),
                }],
            },
        );

        let processed_source_paths = vec![transcript_rel.to_string()];
        let applied = apply_handoff_files(tmp.path(), "run-audio-title", &processed_source_paths)
            .unwrap();

        let expected_media_rel =
            "journals/media/audio/2026/03/30/mindful-observation-beyond-judgment.mp3";
        let expected_transcript_rel =
            "journals/text/transcriptions/audio/2026/03/30/mindful-observation-beyond-judgment.txt";

        assert_eq!(applied.artifact_states.journal_titles.status, "applied");
        assert_eq!(applied.artifact_states.journal_titles.item_count, 1);
        assert_eq!(applied.renamed_sources.len(), 1);
        assert_eq!(applied.renamed_sources[0].from_path, transcript_rel);
        assert_eq!(applied.renamed_sources[0].to_path, expected_transcript_rel);
        assert!(tmp.path().join(expected_media_rel).exists());
        assert!(tmp.path().join(expected_transcript_rel).exists());
        assert!(tmp
            .path()
            .join(super::super::transcript_json_rel_path(expected_transcript_rel))
            .exists());
        assert!(tmp
            .path()
            .join(super::super::transcript_srt_rel_path(expected_transcript_rel))
            .exists());
        assert!(!tmp.path().join(media_rel).exists());
        assert!(!tmp.path().join(transcript_rel).exists());

        let relocated_json: serde_json::Value = serde_json::from_str(
            &fs::read_to_string(
                tmp.path()
                    .join(super::super::transcript_json_rel_path(expected_transcript_rel)),
            )
            .unwrap(),
        )
        .unwrap();
        assert_eq!(
            relocated_json["source"].as_str(),
            Some(tmp.path().join(expected_media_rel).to_string_lossy().as_ref())
        );
        assert_eq!(
            relocated_json["transcriptPath"].as_str(),
            Some(
                tmp.path()
                    .join(expected_transcript_rel)
                    .to_string_lossy()
                    .as_ref()
            )
        );

        let synth_sources = local_store::list_workspace_synth_sources(tmp.path()).unwrap();
        assert_eq!(synth_sources.len(), 1);
        assert_eq!(synth_sources[0].source_path, expected_transcript_rel);
        assert!(local_store::get_feed_interest_source(tmp.path(), expected_transcript_rel)
            .unwrap()
            .is_some());
        assert_eq!(
            local_store::rename_media_asset_path(
                tmp.path(),
                expected_media_rel,
                "journals/media/audio/2026/03/30/final-check.mp3",
            )
            .unwrap(),
            1
        );
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

    #[test]
    fn apply_handoff_files_compiles_app_outputs_from_primitives() {
        let tmp = tempdir().unwrap();
        write_json_file(
            &primitive_actions_path(tmp.path()),
            &ActionFile {
                version: "1".to_string(),
                items: vec![ActionCandidate {
                    id: "email-team".to_string(),
                    title: "Email the team".to_string(),
                    details: "Share the primitive-first update.".to_string(),
                    status: "open".to_string(),
                    priority: "high".to_string(),
                    due_at: "2026-03-12T09:00:00Z".to_string(),
                    provenance: PrimitiveProvenance {
                        source_path: "journals/text/2026-03-11.md".to_string(),
                        source_excerpt: "Need to email the team tomorrow morning.".to_string(),
                        ..PrimitiveProvenance::default()
                    },
                    ..ActionCandidate::default()
                }],
            },
        );
        write_json_file(
            &primitive_segments_path(tmp.path()),
            &SegmentFile {
                version: "1".to_string(),
                items: vec![SegmentCandidate {
                    id: "product-demo".to_string(),
                    label: "Product demo".to_string(),
                    topic: "demo".to_string(),
                    source_path: "journals/text/transcriptions/demo.txt".to_string(),
                    start_at: "00:00:01.000".to_string(),
                    end_at: "00:00:05.000".to_string(),
                    transcript_quote: "Here is the strongest part of the demo.".to_string(),
                    provenance: PrimitiveProvenance {
                        source_path: "journals/text/transcriptions/demo.txt".to_string(),
                        source_excerpt: "Here is the strongest part of the demo.".to_string(),
                        start_at: "00:00:01.000".to_string(),
                        end_at: "00:00:05.000".to_string(),
                        ..PrimitiveProvenance::default()
                    },
                    ..SegmentCandidate::default()
                }],
            },
        );
        write_json_file(
            &primitive_assertions_path(tmp.path()),
            &AssertionFile {
                version: "1".to_string(),
                items: vec![AssertionCandidate {
                    id: "product-belief".to_string(),
                    text: "The sharper workflow makes the product demo easier to follow.".to_string(),
                    kind: "belief".to_string(),
                    provenance: PrimitiveProvenance {
                        source_path: "journals/text/2026-03-11.md".to_string(),
                        source_excerpt: "The sharper workflow makes the demo easier to follow.".to_string(),
                        ..PrimitiveProvenance::default()
                    },
                    ..AssertionCandidate::default()
                }],
            },
        );
        write_json_file(
            &primitive_structures_path(tmp.path()),
            &StructureFile {
                version: "1".to_string(),
                items: vec![StructureCandidate {
                    id: "draft-post".to_string(),
                    kind: "post".to_string(),
                    body: "This is only a draft structure and should not win over assertions."
                        .to_string(),
                    provenance: PrimitiveProvenance {
                        source_path: "journals/text/2026-03-11.md".to_string(),
                        source_excerpt: "Draft structure excerpt.".to_string(),
                        ..PrimitiveProvenance::default()
                    },
                    ..StructureCandidate::default()
                }],
            },
        );

        let processed_source_paths = vec!["journals/text/2026-03-11.md".to_string()];
        let applied = apply_handoff_files(tmp.path(), "run-primitive", &processed_source_paths).unwrap();

        assert!(applied.applied_any);
        assert_eq!(applied.counts.todos, 1);
        assert_eq!(applied.counts.clip_plans, 1);
        assert_eq!(applied.counts.insight_posts, 1);
        assert_eq!(applied.counts.primitive_actions, 1);
        assert_eq!(applied.counts.primitive_segments, 1);
        assert_eq!(applied.counts.primitive_assertions, 1);
        assert_eq!(applied.counts.primitive_structures, 1);
        assert_eq!(applied.artifact_states.primitive_actions.status, "applied");
        assert_eq!(applied.artifact_states.primitive_segments.status, "applied");
        assert!(tmp
            .path()
            .join("posts/workspace_synthesizer/product-belief.md")
            .exists());
        assert!(!tmp
            .path()
            .join("posts/workspace_synthesizer/draft-post.md")
            .exists());
        assert!(tmp
            .path()
            .join("posts/workspace_synthesizer/pipeline/clips/product-demo.json")
            .exists());
    }

    #[test]
    fn all_skill_definitions_include_hidden_audio_clip_skill() {
        let tmp = tempdir().unwrap();
        let store = load_or_seed_skill_store(tmp.path()).unwrap();

        let visible_keys: Vec<String> = skill_definitions(&store)
            .into_iter()
            .map(|item| item.key)
            .collect();
        let all_keys: Vec<String> = all_skill_definitions(&store)
            .into_iter()
            .map(|item| item.key)
            .collect();

        assert!(!visible_keys.iter().any(|key| key == "audio_insight_clips"));
        assert!(all_keys.iter().any(|key| key == "audio_insight_clips"));
    }
}
