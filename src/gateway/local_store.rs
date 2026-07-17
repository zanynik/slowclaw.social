use anyhow::{Context, Result};
use chrono::Utc;
use rusqlite::{params, Connection, OptionalExtension};
use std::path::{Path, PathBuf};
use std::time::Duration;
use uuid::Uuid;

#[derive(Debug, Clone, Default)]
pub struct BootstrapReport {
    pub db_path: PathBuf,
    pub migrated_from_legacy: bool,
    pub legacy_source: Option<PathBuf>,
    pub migrated_chat_messages: usize,
    pub migrated_drafts: usize,
    pub migrated_post_history: usize,
    pub migrated_journal_entries: usize,
    pub migrated_media_assets: usize,
    pub migrated_artifacts: usize,
}

#[derive(Debug, Clone)]
pub struct DraftUpsert {
    pub id: Option<String>,
    pub text: String,
    pub video_name: String,
    pub created_at_client: Option<String>,
    pub updated_at_client: Option<String>,
}

#[derive(Debug, Clone)]
pub struct PostHistoryInput {
    pub provider: String,
    pub text: String,
    pub video_name: String,
    pub source_path: String,
    pub uri: String,
    pub cid: String,
    pub status: String,
    pub error: String,
    pub created_at_client: Option<String>,
}

#[derive(Debug, Clone)]
pub struct JournalEntryInput {
    pub title: String,
    pub entry_type: String,
    pub source: String,
    pub status: String,
    pub workspace_path: String,
    pub preview_text: String,
    pub text_body: String,
    pub tags_csv: String,
    pub created_at_client: Option<String>,
}

#[derive(Debug, Clone)]
pub struct MediaAssetInput {
    pub title: String,
    pub entry_id: String,
    pub asset_type: String,
    pub mime_type: String,
    pub source: String,
    pub status: String,
    pub workspace_path: String,
    pub size_bytes: i64,
    pub created_at_client: Option<String>,
}

#[derive(Debug, Clone)]
pub struct WorkspaceTodoUpsert {
    pub id: String,
    pub title: String,
    pub details: String,
    pub priority: String,
    pub model_status: String,
    pub due_at: String,
    pub source_path: String,
    pub source_excerpt: String,
    pub metadata_json: String,
}

#[derive(Debug, Clone)]
pub struct WorkspaceTodoStatusUpdate {
    pub id: String,
    pub status_override: String,
}

#[derive(Debug, Clone)]
pub struct WorkspaceEventUpsert {
    pub id: String,
    pub title: String,
    pub details: String,
    pub location: String,
    pub status: String,
    pub start_at: String,
    pub end_at: String,
    pub all_day: bool,
    pub source_path: String,
    pub source_excerpt: String,
    pub metadata_json: String,
}

#[derive(Debug, Clone)]
pub struct WorkspaceSynthSourceRecord {
    pub source_path: String,
    pub content_hash: String,
    pub word_count: i64,
    pub last_processed_hash: String,
    pub last_processed_at: String,
    pub last_batch_id: String,
    pub updated_at: String,
}

#[derive(Debug, Clone)]
pub struct WorkspaceSynthSourceUpsert {
    pub source_path: String,
    pub content_hash: String,
    pub word_count: i64,
    pub last_processed_hash: String,
    pub last_processed_at: String,
    pub last_batch_id: String,
}

/// One row of the `journal_enrichment` task-status map.
///
/// A journal's enrichment pipeline is modelled as four independent tasks
/// (`transcription`, `title`, `interests`, `tweet`). Each task has its own
/// status in this table; the on-device loop (see
/// `web/src/hooks/useJournalEnrichmentLoop.ts`) drives each one from `pending`
/// to a terminal state (`done` / `error` / `skipped`). Once all of a journal's
/// tasks are terminal, the loop stops touching it — that is the convergence
/// guarantee.
#[derive(Debug, Clone)]
pub struct JournalEnrichmentRecord {
    pub source_path: String,
    /// One of `transcription` | `title` | `interests` | `tweet`.
    pub task: String,
    /// One of `pending` | `done` | `error` | `skipped`.
    pub status: String,
    /// Number of times the loop has attempted this task (capped in TS).
    pub attempts: i64,
    pub last_error: String,
    pub last_run_at: String,
    pub updated_at: String,
}

#[derive(Debug, Clone)]
pub struct FeedInterestRecord {
    pub id: String,
    pub label: String,
    pub source_path: String,
    pub embedding: Vec<u8>,
    pub health_score: f64,
    pub last_seen_at: String,
    pub created_at: String,
    pub updated_at: String,
    pub keywords_override: String,
}

#[derive(Debug, Clone)]
pub struct FeedInterestUpsert {
    pub id: Option<String>,
    pub label: String,
    pub source_path: String,
    pub embedding: Vec<u8>,
    pub health_score: f64,
    pub last_seen_at: String,
}

#[derive(Debug, Clone)]
pub struct FeedInterestSourceRecord {
    pub source_path: String,
    pub content_hash: String,
    pub profile_input_hash: String,
    pub interest_id: Option<String>,
    pub title: String,
    pub triage_keywords_json: String,
    pub updated_at: String,
}

#[derive(Debug, Clone)]
pub struct FeedKeywordRecord {
    pub id: String,
    pub term: String,
    pub weight: f64,
    pub first_seen_at: String,
    pub last_seen_at: String,
    pub source_count: i64,
    pub updated_at: String,
    /// 0 = positive (journal / liked-card), 1 = negative (disliked-card).
    /// Negative keywords persist (no decay) and down-rank, never hide.
    pub polarity: i64,
}

#[derive(Debug, Clone)]
pub struct FeedKeywordUpsert {
    pub id: Option<String>,
    pub term: String,
    pub weight: f64,
    pub first_seen_at: String,
    pub last_seen_at: String,
    pub source_count: i64,
    /// 0 = positive, 1 = negative. See `FeedKeywordRecord::polarity`.
    pub polarity: i64,
}

#[derive(Debug, Clone)]
pub struct FeedWebSourceRecord {
    pub domain: String,
    pub title: String,
    pub html_url: String,
    pub xml_url: String,
    pub description: String,
    pub topics_csv: String,
    pub metadata_embedding: Vec<u8>,
    pub enabled: bool,
    pub source_kind: String,
    pub created_at: String,
    pub updated_at: String,
}

#[derive(Debug, Clone)]
pub struct FeedWebSourceUpsert {
    pub domain: String,
    pub title: String,
    pub html_url: String,
    pub xml_url: String,
    pub description: String,
    pub topics_csv: String,
    pub metadata_embedding: Vec<u8>,
    pub enabled: bool,
    pub source_kind: String,
}

#[derive(Debug, Clone)]
pub struct FeedWebCacheRecord {
    pub url: String,
    pub domain: String,
    pub title: String,
    pub description: String,
    pub image_url: String,
    pub provider: String,
    pub snippet: String,
    pub search_query: String,
    pub fetched_at: String,
    pub updated_at: String,
}

#[derive(Debug, Clone)]
pub struct FeedWebCacheUpsert {
    pub url: String,
    pub domain: String,
    pub title: String,
    pub description: String,
    pub image_url: String,
    pub provider: String,
    pub snippet: String,
    pub search_query: String,
    pub fetched_at: String,
}

#[derive(Debug, Clone)]
pub struct PersonalizedFeedCacheRecord {
    pub feed_key: String,
    pub cache_key: String,
    pub payload_json: String,
    pub score: f64,
    pub sort_order: i64,
    pub refreshed_at: String,
    pub updated_at: String,
}

#[derive(Debug, Clone)]
pub struct PersonalizedFeedCacheUpsert {
    pub feed_key: String,
    pub cache_key: String,
    pub payload_json: String,
    pub score: f64,
    pub sort_order: i64,
    pub refreshed_at: String,
}

#[derive(Debug, Clone)]
pub struct PersonalizedFeedStateRecord {
    pub feed_key: String,
    pub dirty: bool,
    pub refresh_status: String,
    pub refreshed_at: String,
    pub refresh_started_at: String,
    pub refresh_finished_at: String,
    pub last_error: String,
    pub profile_status: String,
    pub profile_stats_json: String,
    pub details_json: String,
    pub updated_at: String,
    pub generation: i64,
}

#[derive(Debug, Clone)]
pub struct PersonalizedFeedStateUpsert {
    pub feed_key: String,
    pub dirty: bool,
    pub refresh_status: String,
    pub refreshed_at: String,
    pub refresh_started_at: String,
    pub refresh_finished_at: String,
    pub last_error: String,
    pub profile_status: String,
    pub profile_stats_json: String,
    pub details_json: String,
}

#[derive(Debug, Clone)]
pub struct ContentSourceRecord {
    pub source_key: String,
    pub domain: String,
    pub title: String,
    pub html_url: String,
    pub xml_url: String,
    pub source_kind: String,
    pub enabled: bool,
    pub etag: String,
    pub last_modified: String,
    pub last_fetch_at: String,
    pub last_success_at: String,
    pub last_error: String,
    pub created_at: String,
    pub updated_at: String,
}

#[derive(Debug, Clone)]
pub struct ContentSourceUpsert {
    pub source_key: String,
    pub domain: String,
    pub title: String,
    pub html_url: String,
    pub xml_url: String,
    pub source_kind: String,
    pub enabled: bool,
}

#[derive(Debug, Clone)]
pub struct ContentItemRecord {
    pub id: String,
    pub source_key: String,
    pub source_title: String,
    pub source_kind: String,
    pub domain: String,
    pub canonical_url: String,
    pub external_id: String,
    pub title: String,
    pub author: String,
    pub summary: String,
    pub content_text: String,
    pub content_hash: String,
    pub embedding: Vec<u8>,
    pub published_at: String,
    pub discovered_at: String,
    pub created_at: String,
    pub updated_at: String,
}

#[derive(Debug, Clone)]
pub struct ContentItemUpsert {
    pub id: String,
    pub source_key: String,
    pub source_title: String,
    pub source_kind: String,
    pub domain: String,
    pub canonical_url: String,
    pub external_id: String,
    pub title: String,
    pub author: String,
    pub summary: String,
    pub content_text: String,
    pub content_hash: String,
    pub embedding: Vec<u8>,
    pub published_at: String,
    pub discovered_at: String,
}

pub fn initialize(workspace_dir: &Path) -> Result<BootstrapReport> {
    let db_path = db_path(workspace_dir);
    if let Some(parent) = db_path.parent() {
        std::fs::create_dir_all(parent)
            .with_context(|| format!("Failed to create state directory {}", parent.display()))?;
    }

    let conn = open_conn(&db_path)?;
    init_schema(&conn)?;

    let report = BootstrapReport {
        db_path,
        ..BootstrapReport::default()
    };
    Ok(report)
}

pub fn db_path(workspace_dir: &Path) -> PathBuf {
    workspace_dir.join("state").join("local_data.db")
}

pub fn list_chat_messages(
    workspace_dir: &Path,
    thread_id: &str,
    limit: usize,
) -> Result<Vec<serde_json::Value>> {
    let conn = open_conn(&db_path(workspace_dir))?;
    let lim = i64::try_from(limit.max(1)).unwrap_or(200);
    let mut stmt = conn.prepare(
        "SELECT id, thread_id, role, content, status, source, reply_to_id, error, created_at_client, created, updated
         FROM chat_messages
         WHERE thread_id = ?1
         ORDER BY COALESCE(NULLIF(created_at_client, ''), created) ASC, id ASC
         LIMIT ?2",
    )?;
    let rows = stmt.query_map(params![thread_id, lim], |row| {
        Ok(serde_json::json!({
            "id": row.get::<_, String>(0)?,
            "threadId": row.get::<_, String>(1)?,
            "role": row.get::<_, String>(2)?,
            "content": row.get::<_, String>(3)?,
            "status": row.get::<_, String>(4)?,
            "source": non_empty_opt(row.get::<_, String>(5)?),
            "replyToId": non_empty_opt(row.get::<_, String>(6)?),
            "error": non_empty_opt(row.get::<_, String>(7)?),
            "createdAtClient": row.get::<_, String>(8)?,
            "created": row.get::<_, String>(9)?,
            "updated": row.get::<_, String>(10)?,
        }))
    })?;

    let mut out = Vec::new();
    for row in rows {
        out.push(row?);
    }
    Ok(out)
}

pub fn create_chat_message(
    workspace_dir: &Path,
    thread_id: &str,
    role: &str,
    content: &str,
    status: &str,
    source: &str,
    reply_to_id: Option<&str>,
    error: Option<&str>,
) -> Result<serde_json::Value> {
    let conn = open_conn(&db_path(workspace_dir))?;
    let now = Utc::now().to_rfc3339();
    let id = format!("lc_{}", Uuid::new_v4().simple());
    let reply_to = reply_to_id.unwrap_or("").trim();
    let err = error.unwrap_or("").trim();
    conn.execute(
        "INSERT INTO chat_messages (
            id, thread_id, role, content, status, source, reply_to_id, error,
            created_at_client, processed_at, created, updated
         ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, '', ?10, ?10)",
        params![
            id,
            thread_id.trim(),
            normalize_role(role),
            content,
            status.trim(),
            source.trim(),
            reply_to,
            err,
            now,
            now
        ],
    )
    .context("Failed to insert chat message")?;
    Ok(serde_json::json!({
        "id": id,
        "threadId": thread_id.trim(),
        "role": normalize_role(role),
        "content": content,
        "status": status.trim(),
        "source": non_empty_opt(source.trim().to_string()),
        "replyToId": non_empty_opt(reply_to.to_string()),
        "error": non_empty_opt(err.to_string()),
        "createdAtClient": now,
    }))
}

pub fn patch_chat_status(
    workspace_dir: &Path,
    record_id: &str,
    status: &str,
    error: Option<&str>,
) -> Result<()> {
    let conn = open_conn(&db_path(workspace_dir))?;
    let now = Utc::now().to_rfc3339();
    conn.execute(
        "UPDATE chat_messages
         SET status = ?2, error = ?3, processed_at = ?4, updated = ?4
         WHERE id = ?1",
        params![record_id, status.trim(), error.unwrap_or("").trim(), now],
    )
    .with_context(|| format!("Failed to patch chat message status for {}", record_id))?;
    Ok(())
}

pub fn upsert_draft(workspace_dir: &Path, draft: &DraftUpsert) -> Result<serde_json::Value> {
    let conn = open_conn(&db_path(workspace_dir))?;
    let now = Utc::now().to_rfc3339();
    let id = draft
        .id
        .as_deref()
        .map(str::trim)
        .filter(|v| !v.is_empty())
        .map(ToOwned::to_owned)
        .unwrap_or_else(|| format!("lc_{}", Uuid::new_v4().simple()));
    let created = draft
        .created_at_client
        .as_deref()
        .map(str::trim)
        .filter(|v| !v.is_empty())
        .unwrap_or(&now)
        .to_string();
    let updated = draft
        .updated_at_client
        .as_deref()
        .map(str::trim)
        .filter(|v| !v.is_empty())
        .unwrap_or(&now)
        .to_string();

    conn.execute(
        "INSERT INTO drafts (id, text, video_name, created_at_client, updated_at_client, created, updated)
         VALUES (?1, ?2, ?3, ?4, ?5, ?4, ?5)
         ON CONFLICT(id) DO UPDATE SET
            text = excluded.text,
            video_name = excluded.video_name,
            updated_at_client = excluded.updated_at_client,
            updated = excluded.updated",
        params![id, draft.text, draft.video_name, created, updated],
    )
    .context("Failed to upsert draft")?;

    Ok(serde_json::json!({
        "id": id,
        "text": draft.text,
        "videoName": draft.video_name,
        "createdAtClient": created,
        "updatedAtClient": updated,
    }))
}

pub fn list_drafts(workspace_dir: &Path, limit: usize) -> Result<Vec<serde_json::Value>> {
    let conn = open_conn(&db_path(workspace_dir))?;
    let lim = i64::try_from(limit.max(1)).unwrap_or(20);
    let mut stmt = conn.prepare(
        "SELECT id, text, video_name, created_at_client, updated_at_client, created, updated
         FROM drafts
         ORDER BY COALESCE(NULLIF(created_at_client, ''), created) DESC, id DESC
         LIMIT ?1",
    )?;
    let rows = stmt.query_map(params![lim], |row| {
        Ok(serde_json::json!({
            "id": row.get::<_, String>(0)?,
            "text": row.get::<_, String>(1)?,
            "videoName": row.get::<_, String>(2)?,
            "createdAtClient": row.get::<_, String>(3)?,
            "updatedAtClient": row.get::<_, String>(4)?,
            "created": row.get::<_, String>(5)?,
            "updated": row.get::<_, String>(6)?,
        }))
    })?;

    let mut out = Vec::new();
    for row in rows {
        out.push(row?);
    }
    Ok(out)
}

pub fn create_post_history(
    workspace_dir: &Path,
    item: &PostHistoryInput,
) -> Result<serde_json::Value> {
    let conn = open_conn(&db_path(workspace_dir))?;
    let id = format!("lc_{}", Uuid::new_v4().simple());
    let now = Utc::now().to_rfc3339();
    let created_at_client = item
        .created_at_client
        .as_deref()
        .map(str::trim)
        .filter(|v| !v.is_empty())
        .map(ToOwned::to_owned)
        .unwrap_or_else(|| now.clone());
    let created = now;
    conn.execute(
        "INSERT INTO post_history (
            id, provider, text, video_name, source_path, uri, cid, status, error, created_at_client, created
         ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11)",
        params![
            id,
            item.provider.trim(),
            item.text,
            item.video_name,
            item.source_path,
            item.uri,
            item.cid,
            item.status.trim(),
            item.error,
            created_at_client,
            created,
        ],
    )
    .context("Failed to create post history entry")?;
    Ok(serde_json::json!({
        "id": id,
        "provider": item.provider.trim(),
        "text": item.text,
        "videoName": item.video_name,
        "sourcePath": non_empty_opt(item.source_path.clone()),
        "uri": item.uri,
        "cid": item.cid,
        "status": item.status.trim(),
        "error": item.error,
        "createdAtClient": created_at_client,
    }))
}

pub fn list_post_history(workspace_dir: &Path, limit: usize) -> Result<Vec<serde_json::Value>> {
    let conn = open_conn(&db_path(workspace_dir))?;
    let lim = i64::try_from(limit.max(1)).unwrap_or(50);
    let mut stmt = conn.prepare(
        "SELECT id, provider, text, video_name, source_path, uri, cid, status, error, created_at_client, created
         FROM post_history
         ORDER BY COALESCE(NULLIF(created_at_client, ''), created) DESC, id DESC
         LIMIT ?1",
    )?;
    let rows = stmt.query_map(params![lim], |row| {
        Ok(serde_json::json!({
            "id": row.get::<_, String>(0)?,
            "provider": row.get::<_, String>(1)?,
            "text": row.get::<_, String>(2)?,
            "videoName": row.get::<_, String>(3)?,
            "sourcePath": non_empty_opt(row.get::<_, String>(4)?),
            "uri": row.get::<_, String>(5)?,
            "cid": row.get::<_, String>(6)?,
            "status": row.get::<_, String>(7)?,
            "error": non_empty_opt(row.get::<_, String>(8)?),
            "createdAtClient": row.get::<_, String>(9)?,
            "created": row.get::<_, String>(10)?,
        }))
    })?;

    let mut out = Vec::new();
    for row in rows {
        out.push(row?);
    }
    Ok(out)
}

pub fn replace_workspace_todos(
    workspace_dir: &Path,
    items: &[WorkspaceTodoUpsert],
    manifest_id: &str,
    processed_source_paths: &[String],
) -> Result<usize> {
    let mut conn = open_conn(&db_path(workspace_dir))?;
    let tx = conn.transaction()?;
    let now = Utc::now().to_rfc3339();
    let mut written = 0usize;

    // Collect IDs from the current manifest so we know what's still active
    let current_ids: std::collections::HashSet<&str> =
        items.iter().map(|i| i.id.as_str()).collect();

    for item in items {
        tx.execute(
            "INSERT INTO workspace_todos (
                id, title, details, priority, model_status, status_override, due_at,
                source_path, source_excerpt, metadata_json, created_at, updated_at,
                last_manifest_id, archived
             ) VALUES (?1, ?2, ?3, ?4, ?5, '', ?6, ?7, ?8, ?9, ?10, ?10, ?11, 0)
             ON CONFLICT(id) DO UPDATE SET
                title = excluded.title,
                details = excluded.details,
                priority = excluded.priority,
                model_status = excluded.model_status,
                due_at = excluded.due_at,
                source_path = excluded.source_path,
                source_excerpt = excluded.source_excerpt,
                metadata_json = excluded.metadata_json,
                updated_at = excluded.updated_at,
                last_manifest_id = excluded.last_manifest_id
             WHERE workspace_todos.title != excluded.title
                OR workspace_todos.details != excluded.details
                OR workspace_todos.priority != excluded.priority
                OR workspace_todos.model_status != excluded.model_status
                OR workspace_todos.due_at != excluded.due_at
                OR workspace_todos.source_path != excluded.source_path",
            params![
                item.id,
                item.title,
                item.details,
                item.priority,
                item.model_status,
                item.due_at,
                item.source_path,
                item.source_excerpt,
                item.metadata_json,
                now,
                manifest_id,
            ],
        )
        .with_context(|| format!("Failed to upsert workspace todo {}", item.id))?;
        written += 1;
    }

    // Archive stale todos: items whose source was re-processed but were not
    // re-extracted by the model (i.e. the model no longer considers them relevant).
    // Only archive from sources we actually processed — don't touch items from
    // other sources that weren't part of this run.
    for src in processed_source_paths {
        let mut stmt =
            tx.prepare("SELECT id FROM workspace_todos WHERE source_path = ?1 AND archived = 0")?;
        let stale_ids: Vec<String> = stmt
            .query_map(params![src.trim()], |row| row.get::<_, String>(0))?
            .filter_map(|r| r.ok())
            .filter(|id| !current_ids.contains(id.as_str()))
            .collect();
        for stale_id in &stale_ids {
            tx.execute(
                "UPDATE workspace_todos SET archived = 1, updated_at = ?2 WHERE id = ?1",
                params![stale_id, now],
            )?;
        }
    }

    tx.commit()?;
    Ok(written)
}

pub fn list_workspace_todos(workspace_dir: &Path, limit: usize) -> Result<Vec<serde_json::Value>> {
    let conn = open_conn(&db_path(workspace_dir))?;
    let lim = i64::try_from(limit.max(1)).unwrap_or(50);
    let mut stmt = conn.prepare(
        "SELECT
            id, title, details, priority, model_status, status_override, due_at,
            source_path, source_excerpt, metadata_json, created_at, updated_at
         FROM workspace_todos
         WHERE archived = 0
         ORDER BY
            CASE
                WHEN COALESCE(NULLIF(status_override, ''), model_status) = 'done' THEN 1
                ELSE 0
            END ASC,
            CASE priority
                WHEN 'high' THEN 0
                WHEN 'medium' THEN 1
                WHEN 'low' THEN 2
                ELSE 3
            END ASC,
            updated_at DESC,
            id DESC
         LIMIT ?1",
    )?;
    let rows = stmt.query_map(params![lim], |row| {
        let model_status: String = row.get(4)?;
        let status_override: String = row.get(5)?;
        let effective_status =
            non_empty_opt(status_override.clone()).unwrap_or(model_status.clone());
        Ok(serde_json::json!({
            "id": row.get::<_, String>(0)?,
            "title": row.get::<_, String>(1)?,
            "details": non_empty_opt(row.get::<_, String>(2)?),
            "priority": row.get::<_, String>(3)?,
            "modelStatus": model_status,
            "statusOverride": non_empty_opt(status_override),
            "status": effective_status,
            "dueAt": non_empty_opt(row.get::<_, String>(6)?),
            "sourcePath": non_empty_opt(row.get::<_, String>(7)?),
            "sourceExcerpt": non_empty_opt(row.get::<_, String>(8)?),
            "metadataJson": non_empty_opt(row.get::<_, String>(9)?),
            "created": row.get::<_, String>(10)?,
            "updated": row.get::<_, String>(11)?,
        }))
    })?;

    let mut out = Vec::new();
    for row in rows {
        out.push(row?);
    }
    Ok(out)
}

pub fn update_workspace_todo_status(
    workspace_dir: &Path,
    update: &WorkspaceTodoStatusUpdate,
) -> Result<serde_json::Value> {
    let conn = open_conn(&db_path(workspace_dir))?;
    let now = Utc::now().to_rfc3339();
    conn.execute(
        "UPDATE workspace_todos
         SET status_override = ?2, updated_at = ?3
         WHERE id = ?1",
        params![update.id.trim(), update.status_override.trim(), now],
    )
    .with_context(|| format!("Failed to update workspace todo {}", update.id))?;

    let mut stmt = conn.prepare(
        "SELECT
            id, title, details, priority, model_status, status_override, due_at,
            source_path, source_excerpt, metadata_json, created_at, updated_at
         FROM workspace_todos
         WHERE id = ?1
         LIMIT 1",
    )?;
    let record = stmt
        .query_row(params![update.id.trim()], |row| {
            let model_status: String = row.get(4)?;
            let status_override: String = row.get(5)?;
            let effective_status =
                non_empty_opt(status_override.clone()).unwrap_or(model_status.clone());
            Ok(serde_json::json!({
                "id": row.get::<_, String>(0)?,
                "title": row.get::<_, String>(1)?,
                "details": non_empty_opt(row.get::<_, String>(2)?),
                "priority": row.get::<_, String>(3)?,
                "modelStatus": model_status,
                "statusOverride": non_empty_opt(status_override),
                "status": effective_status,
                "dueAt": non_empty_opt(row.get::<_, String>(6)?),
                "sourcePath": non_empty_opt(row.get::<_, String>(7)?),
                "sourceExcerpt": non_empty_opt(row.get::<_, String>(8)?),
                "metadataJson": non_empty_opt(row.get::<_, String>(9)?),
                "created": row.get::<_, String>(10)?,
                "updated": row.get::<_, String>(11)?,
            }))
        })
        .optional()?
        .ok_or_else(|| anyhow::anyhow!("Workspace todo not found"))?;

    Ok(record)
}

pub fn replace_workspace_events(
    workspace_dir: &Path,
    items: &[WorkspaceEventUpsert],
    manifest_id: &str,
    processed_source_paths: &[String],
) -> Result<usize> {
    let mut conn = open_conn(&db_path(workspace_dir))?;
    let tx = conn.transaction()?;
    let now = Utc::now().to_rfc3339();
    let mut written = 0usize;

    let current_ids: std::collections::HashSet<&str> =
        items.iter().map(|i| i.id.as_str()).collect();

    for item in items {
        tx.execute(
            "INSERT INTO workspace_events (
                id, title, details, location, status, start_at, end_at, all_day,
                source_path, source_excerpt, metadata_json, created_at, updated_at,
                last_manifest_id, archived
             ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?12, ?13, 0)
             ON CONFLICT(id) DO UPDATE SET
                title = excluded.title,
                details = excluded.details,
                location = excluded.location,
                status = excluded.status,
                start_at = excluded.start_at,
                end_at = excluded.end_at,
                all_day = excluded.all_day,
                source_path = excluded.source_path,
                source_excerpt = excluded.source_excerpt,
                metadata_json = excluded.metadata_json,
                updated_at = excluded.updated_at,
                last_manifest_id = excluded.last_manifest_id
             WHERE workspace_events.title != excluded.title
                OR workspace_events.details != excluded.details
                OR workspace_events.location != excluded.location
                OR workspace_events.status != excluded.status
                OR workspace_events.start_at != excluded.start_at
                OR workspace_events.end_at != excluded.end_at
                OR workspace_events.all_day != excluded.all_day
                OR workspace_events.source_path != excluded.source_path",
            params![
                item.id,
                item.title,
                item.details,
                item.location,
                item.status,
                item.start_at,
                item.end_at,
                if item.all_day { 1 } else { 0 },
                item.source_path,
                item.source_excerpt,
                item.metadata_json,
                now,
                manifest_id,
            ],
        )
        .with_context(|| format!("Failed to upsert workspace event {}", item.id))?;
        written += 1;
    }

    // Archive stale events from processed sources not re-extracted
    for src in processed_source_paths {
        let mut stmt =
            tx.prepare("SELECT id FROM workspace_events WHERE source_path = ?1 AND archived = 0")?;
        let stale_ids: Vec<String> = stmt
            .query_map(params![src.trim()], |row| row.get::<_, String>(0))?
            .filter_map(|r| r.ok())
            .filter(|id| !current_ids.contains(id.as_str()))
            .collect();
        for stale_id in &stale_ids {
            tx.execute(
                "UPDATE workspace_events SET archived = 1, updated_at = ?2 WHERE id = ?1",
                params![stale_id, now],
            )?;
        }
    }

    tx.commit()?;
    Ok(written)
}

pub fn list_workspace_events(workspace_dir: &Path, limit: usize) -> Result<Vec<serde_json::Value>> {
    let conn = open_conn(&db_path(workspace_dir))?;
    let lim = i64::try_from(limit.max(1)).unwrap_or(50);
    let mut stmt = conn.prepare(
        "SELECT
            id, title, details, location, status, start_at, end_at, all_day,
            source_path, source_excerpt, metadata_json, created_at, updated_at
         FROM workspace_events
         WHERE archived = 0
         ORDER BY
            CASE status
                WHEN 'cancelled' THEN 1
                ELSE 0
            END ASC,
            start_at ASC,
            updated_at DESC,
            id DESC
         LIMIT ?1",
    )?;
    let rows = stmt.query_map(params![lim], |row| {
        Ok(serde_json::json!({
            "id": row.get::<_, String>(0)?,
            "title": row.get::<_, String>(1)?,
            "details": non_empty_opt(row.get::<_, String>(2)?),
            "location": non_empty_opt(row.get::<_, String>(3)?),
            "status": row.get::<_, String>(4)?,
            "startAt": row.get::<_, String>(5)?,
            "endAt": non_empty_opt(row.get::<_, String>(6)?),
            "allDay": row.get::<_, i64>(7)? != 0,
            "sourcePath": non_empty_opt(row.get::<_, String>(8)?),
            "sourceExcerpt": non_empty_opt(row.get::<_, String>(9)?),
            "metadataJson": non_empty_opt(row.get::<_, String>(10)?),
            "created": row.get::<_, String>(11)?,
            "updated": row.get::<_, String>(12)?,
        }))
    })?;

    let mut out = Vec::new();
    for row in rows {
        out.push(row?);
    }
    Ok(out)
}

pub fn list_workspace_synth_sources(
    workspace_dir: &Path,
) -> Result<Vec<WorkspaceSynthSourceRecord>> {
    let conn = open_conn(&db_path(workspace_dir))?;
    let mut stmt = conn.prepare(
        "SELECT
            source_path, content_hash, word_count, last_processed_hash,
            last_processed_at, last_batch_id, updated_at
         FROM workspace_synth_sources
         ORDER BY updated_at DESC, source_path ASC",
    )?;
    let rows = stmt.query_map([], |row| {
        Ok(WorkspaceSynthSourceRecord {
            source_path: row.get(0)?,
            content_hash: row.get(1)?,
            word_count: row.get(2)?,
            last_processed_hash: row.get(3)?,
            last_processed_at: row.get(4)?,
            last_batch_id: row.get(5)?,
            updated_at: row.get(6)?,
        })
    })?;

    let mut out = Vec::new();
    for row in rows {
        out.push(row?);
    }
    Ok(out)
}

pub fn upsert_workspace_synth_sources(
    workspace_dir: &Path,
    items: &[WorkspaceSynthSourceUpsert],
) -> Result<()> {
    if items.is_empty() {
        return Ok(());
    }

    let mut conn = open_conn(&db_path(workspace_dir))?;
    let tx = conn.transaction()?;
    let now = Utc::now().to_rfc3339();

    for item in items {
        tx.execute(
            "INSERT INTO workspace_synth_sources (
                source_path, content_hash, word_count, last_processed_hash,
                last_processed_at, last_batch_id, updated_at
             ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)
             ON CONFLICT(source_path) DO UPDATE SET
                content_hash = excluded.content_hash,
                word_count = excluded.word_count,
                last_processed_hash = excluded.last_processed_hash,
                last_processed_at = excluded.last_processed_at,
                last_batch_id = excluded.last_batch_id,
                updated_at = excluded.updated_at",
            params![
                item.source_path,
                item.content_hash,
                item.word_count,
                item.last_processed_hash,
                item.last_processed_at,
                item.last_batch_id,
                now,
            ],
        )
        .with_context(|| {
            format!(
                "Failed to upsert workspace synth source {}",
                item.source_path
            )
        })?;
    }

    tx.commit()?;
    Ok(())
}

pub fn rename_workspace_synth_source_path(
    workspace_dir: &Path,
    old_path: &str,
    new_path: &str,
) -> Result<()> {
    let conn = open_conn(&db_path(workspace_dir))?;
    let now = Utc::now().to_rfc3339();
    conn.execute(
        "UPDATE workspace_synth_sources
         SET source_path = ?2, updated_at = ?3
         WHERE source_path = ?1",
        params![old_path.trim(), new_path.trim(), now],
    )
    .with_context(|| {
        format!(
            "Failed to rename workspace synth source path {} -> {}",
            old_path, new_path
        )
    })?;
    Ok(())
}

pub fn rename_media_asset_path(
    workspace_dir: &Path,
    old_path: &str,
    new_path: &str,
) -> Result<usize> {
    let conn = open_conn(&db_path(workspace_dir))?;
    let rows = conn
        .execute(
            "UPDATE media_assets
             SET workspace_path = ?2
             WHERE workspace_path = ?1",
            params![old_path.trim(), new_path.trim()],
        )
        .with_context(|| {
            format!(
                "Failed to rename media asset path {} -> {}",
                old_path, new_path
            )
        })?;
    Ok(rows)
}

pub fn rename_source_path_references(
    workspace_dir: &Path,
    old_path: &str,
    new_path: &str,
) -> Result<()> {
    let conn = open_conn(&db_path(workspace_dir))?;
    let now = Utc::now().to_rfc3339();
    let old_trimmed = old_path.trim();
    let new_trimmed = new_path.trim();

    let _ = conn.execute(
        "UPDATE workspace_todos SET source_path = ?2, updated_at = ?3 WHERE source_path = ?1",
        params![old_trimmed, new_trimmed, now],
    );
    let _ = conn.execute(
        "UPDATE workspace_events SET source_path = ?2, updated_at = ?3 WHERE source_path = ?1",
        params![old_trimmed, new_trimmed, now],
    );
    let _ = conn.execute(
        "UPDATE feed_interest_sources SET source_path = ?2, updated_at = ?3 WHERE source_path = ?1",
        params![old_trimmed, new_trimmed, now],
    );

    Ok(())
}

pub fn rename_journal_entry_path(
    workspace_dir: &Path,
    old_path: &str,
    new_path: &str,
    title: &str,
) -> Result<usize> {
    let conn = open_conn(&db_path(workspace_dir))?;
    let mut conn = conn;
    let tx = conn.transaction()?;
    let old_trimmed = old_path.trim();
    let new_trimmed = new_path.trim();
    let title_trimmed = title.trim();
    let now = Utc::now().to_rfc3339();

    let rows = tx
        .execute(
            "UPDATE journal_entries
             SET workspace_path = ?2, title = ?3
             WHERE workspace_path = ?1",
            params![old_trimmed, new_trimmed, title_trimmed],
        )
        .with_context(|| {
            format!(
                "Failed to rename journal entry {} -> {}",
                old_trimmed, new_trimmed
            )
        })?;

    let repaired_rows = if rows == 0 {
        if let Some((preview_text, text_body)) =
            journal_preview_and_body_from_workspace(workspace_dir, new_trimmed)
        {
            let created = now.clone();
            tx.execute(
                "INSERT INTO journal_entries (
                    id, title, entry_type, source, status, workspace_path, preview_text, text_body,
                    tags_csv, created_at_client, created
                 ) VALUES (?1, ?2, 'text', 'workspace-synth', 'raw', ?3, ?4, ?5, '', ?6, ?6)",
                params![
                    format!("lc_{}", Uuid::new_v4().simple()),
                    title_trimmed,
                    new_trimmed,
                    preview_text,
                    text_body,
                    created
                ],
            )
            .unwrap_or(0)
        } else {
            tracing::warn!(
                old_path = old_trimmed,
                new_path = new_trimmed,
                "rename_journal_entry_path: no rows matched old_path and no journal file was available for repair"
            );
            0
        }
    } else {
        0
    };

    // Cascade rename to todos and events that reference this source
    let _ = tx.execute(
        "UPDATE workspace_todos SET source_path = ?2, updated_at = ?3 WHERE source_path = ?1",
        params![old_trimmed, new_trimmed, now],
    );
    let _ = tx.execute(
        "UPDATE workspace_events SET source_path = ?2, updated_at = ?3 WHERE source_path = ?1",
        params![old_trimmed, new_trimmed, now],
    );
    let _ = tx.execute(
        "UPDATE feed_interest_sources SET source_path = ?2, updated_at = ?3 WHERE source_path = ?1",
        params![old_trimmed, new_trimmed, now],
    );

    tx.commit()?;

    Ok(rows + repaired_rows)
}

fn journal_preview_and_body_from_workspace(
    workspace_dir: &Path,
    rel_path: &str,
) -> Option<(String, String)> {
    let path = workspace_dir.join(rel_path.trim().trim_start_matches('/'));
    let body = std::fs::read_to_string(path).ok()?;
    let trimmed = body.trim().to_string();
    if trimmed.is_empty() {
        return None;
    }
    let preview = trimmed.chars().take(240).collect::<String>();
    Some((preview, trimmed))
}

pub fn create_journal_entry_metadata(
    workspace_dir: &Path,
    item: &JournalEntryInput,
) -> Result<serde_json::Value> {
    let conn = open_conn(&db_path(workspace_dir))?;
    let id = format!("lc_{}", Uuid::new_v4().simple());
    let created = Utc::now().to_rfc3339();
    let created_at_client = item
        .created_at_client
        .as_deref()
        .map(str::trim)
        .filter(|v| !v.is_empty())
        .map(ToOwned::to_owned)
        .unwrap_or_else(|| created.clone());
    conn.execute(
        "INSERT INTO journal_entries (
            id, title, entry_type, source, status, workspace_path, preview_text, text_body,
            tags_csv, created_at_client, created
         ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11)",
        params![
            id,
            item.title,
            item.entry_type,
            item.source,
            item.status,
            item.workspace_path,
            item.preview_text,
            item.text_body,
            item.tags_csv,
            created_at_client,
            created
        ],
    )
    .context("Failed to insert journal metadata")?;
    Ok(serde_json::json!({
        "id": id,
        "title": item.title,
        "entryType": item.entry_type,
        "source": item.source,
        "status": item.status,
        "workspacePath": item.workspace_path,
        "previewText": item.preview_text,
        "textBody": item.text_body,
        "tagsCsv": item.tags_csv,
        "createdAtClient": created_at_client,
    }))
}

pub fn create_media_asset_metadata(
    workspace_dir: &Path,
    item: &MediaAssetInput,
) -> Result<serde_json::Value> {
    let conn = open_conn(&db_path(workspace_dir))?;
    let id = format!("lc_{}", Uuid::new_v4().simple());
    let created = Utc::now().to_rfc3339();
    let created_at_client = item
        .created_at_client
        .as_deref()
        .map(str::trim)
        .filter(|v| !v.is_empty())
        .map(ToOwned::to_owned)
        .unwrap_or_else(|| created.clone());
    conn.execute(
        "INSERT INTO media_assets (
            id, title, entry_id, asset_type, mime_type, source, status, workspace_path,
            size_bytes, created_at_client, created
         ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11)",
        params![
            id,
            item.title,
            item.entry_id,
            item.asset_type,
            item.mime_type,
            item.source,
            item.status,
            item.workspace_path,
            item.size_bytes,
            created_at_client,
            created
        ],
    )
    .context("Failed to insert media metadata")?;
    Ok(serde_json::json!({
        "id": id,
        "title": item.title,
        "entryId": item.entry_id,
        "assetType": item.asset_type,
        "mimeType": item.mime_type,
        "source": item.source,
        "status": item.status,
        "workspacePath": item.workspace_path,
        "sizeBytes": item.size_bytes,  // integer
        "createdAtClient": created_at_client,
    }))
}

pub fn list_feed_interests(workspace_dir: &Path) -> Result<Vec<FeedInterestRecord>> {
    let conn = open_conn(&db_path(workspace_dir))?;
    let mut stmt = conn.prepare(
        "SELECT id, label, source_path, embedding, health_score, last_seen_at, created_at, updated_at,
                COALESCE(keywords_override, '')
         FROM feed_interests
         ORDER BY updated_at DESC, id DESC",
    )?;
    let rows = stmt.query_map([], |row| {
        Ok(FeedInterestRecord {
            id: row.get(0)?,
            label: row.get(1)?,
            source_path: row.get(2)?,
            embedding: row.get(3)?,
            health_score: row.get(4)?,
            last_seen_at: row.get(5)?,
            created_at: row.get(6)?,
            updated_at: row.get(7)?,
            keywords_override: row.get(8)?,
        })
    })?;

    let mut out = Vec::new();
    for row in rows {
        out.push(row?);
    }
    Ok(out)
}

pub fn list_feed_keywords(workspace_dir: &Path) -> Result<Vec<FeedKeywordRecord>> {
    let conn = open_conn(&db_path(workspace_dir))?;
    let mut stmt = conn.prepare(
        "SELECT id, term, weight, first_seen_at, last_seen_at, source_count, updated_at, polarity
         FROM feed_profile_keywords
         ORDER BY weight DESC, last_seen_at DESC, term ASC",
    )?;
    let rows = stmt.query_map([], |row| {
        Ok(FeedKeywordRecord {
            id: row.get(0)?,
            term: row.get(1)?,
            weight: row.get(2)?,
            first_seen_at: row.get(3)?,
            last_seen_at: row.get(4)?,
            source_count: row.get(5)?,
            updated_at: row.get(6)?,
            polarity: row.get(7)?,
        })
    })?;

    let mut out = Vec::new();
    for row in rows {
        out.push(row?);
    }
    Ok(out)
}

/// List feed keywords filtered by polarity (0 = positive, 1 = negative).
/// Same ordering as `list_feed_keywords`.
pub fn list_feed_keywords_by_polarity(
    workspace_dir: &Path,
    polarity: i64,
) -> Result<Vec<FeedKeywordRecord>> {
    let conn = open_conn(&db_path(workspace_dir))?;
    let mut stmt = conn.prepare(
        "SELECT id, term, weight, first_seen_at, last_seen_at, source_count, updated_at, polarity
         FROM feed_profile_keywords
         WHERE polarity = ?1
         ORDER BY weight DESC, last_seen_at DESC, term ASC",
    )?;
    let rows = stmt.query_map(params![polarity], |row| {
        Ok(FeedKeywordRecord {
            id: row.get(0)?,
            term: row.get(1)?,
            weight: row.get(2)?,
            first_seen_at: row.get(3)?,
            last_seen_at: row.get(4)?,
            source_count: row.get(5)?,
            updated_at: row.get(6)?,
            polarity: row.get(7)?,
        })
    })?;

    let mut out = Vec::new();
    for row in rows {
        out.push(row?);
    }
    Ok(out)
}

pub fn upsert_feed_keyword(
    workspace_dir: &Path,
    keyword: &FeedKeywordUpsert,
) -> Result<FeedKeywordRecord> {
    let conn = open_conn(&db_path(workspace_dir))?;
    let now = Utc::now().to_rfc3339();
    let id = keyword
        .id
        .as_deref()
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(ToOwned::to_owned)
        .unwrap_or_else(|| format!("lc_{}", Uuid::new_v4().simple()));
    let polarity = keyword.polarity.clamp(0, 1);
    conn.execute(
        "INSERT INTO feed_profile_keywords (
            id, term, weight, first_seen_at, last_seen_at, source_count, updated_at, polarity
         ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)
         ON CONFLICT(term) DO UPDATE SET
            weight = excluded.weight,
            first_seen_at = excluded.first_seen_at,
            last_seen_at = excluded.last_seen_at,
            source_count = excluded.source_count,
            updated_at = excluded.updated_at,
            polarity = excluded.polarity",
        params![
            id,
            keyword.term.trim(),
            keyword.weight,
            keyword.first_seen_at.trim(),
            keyword.last_seen_at.trim(),
            keyword.source_count,
            now,
            polarity,
        ],
    )
    .context("Failed to upsert feed profile keyword")?;

    let mut stmt = conn.prepare(
        "SELECT id, term, weight, first_seen_at, last_seen_at, source_count, updated_at, polarity
         FROM feed_profile_keywords
         WHERE term = ?1
         LIMIT 1",
    )?;
    let record = stmt.query_row(params![keyword.term.trim()], |row| {
        Ok(FeedKeywordRecord {
            id: row.get(0)?,
            term: row.get(1)?,
            weight: row.get(2)?,
            first_seen_at: row.get(3)?,
            last_seen_at: row.get(4)?,
            source_count: row.get(5)?,
            updated_at: row.get(6)?,
            polarity: row.get(7)?,
        })
    })?;
    Ok(record)
}

pub fn decay_feed_keywords(workspace_dir: &Path, decay_rate: f64) -> Result<usize> {
    let conn = open_conn(&db_path(workspace_dir))?;
    let now = Utc::now().to_rfc3339();
    // Decay positives only (polarity = 0). Disliked keywords (polarity = 1) are
    // explicit negative signals and must persist until the user removes them.
    let updated = conn.execute(
        "UPDATE feed_profile_keywords
         SET weight = MAX(0.0, weight * ?1),
             updated_at = ?2
         WHERE polarity = 0",
        params![decay_rate, now],
    )?;
    Ok(updated)
}

pub fn prune_feed_keywords(
    workspace_dir: &Path,
    min_weight: f64,
    keep_limit: usize,
) -> Result<usize> {
    let conn = open_conn(&db_path(workspace_dir))?;
    // Weight-floor pruning applies to positives only: an un-reinforced interest
    // that has decayed below the floor is forgotten. Disliked keywords carry no
    // decay, so they never hit this floor; they are bounded by `keep_limit`.
    let mut removed = conn.execute(
        "DELETE FROM feed_profile_keywords WHERE weight < ?1 AND polarity = 0",
        params![min_weight],
    )?;
    let keep_limit = i64::try_from(keep_limit.max(1)).unwrap_or(300);
    removed += conn.execute(
        "DELETE FROM feed_profile_keywords
         WHERE id IN (
             SELECT id
             FROM feed_profile_keywords
             ORDER BY weight DESC, last_seen_at DESC, term ASC
             LIMIT -1 OFFSET ?1
         )",
        params![keep_limit],
    )?;
    Ok(removed)
}

pub fn delete_feed_keyword(workspace_dir: &Path, keyword_id: &str) -> Result<bool> {
    let conn = open_conn(&db_path(workspace_dir))?;
    let deleted = conn.execute(
        "DELETE FROM feed_profile_keywords WHERE id = ?1",
        params![keyword_id.trim()],
    )?;
    Ok(deleted > 0)
}

pub fn update_feed_keyword_term(
    workspace_dir: &Path,
    keyword_id: &str,
    term: &str,
) -> Result<bool> {
    let conn = open_conn(&db_path(workspace_dir))?;
    let now = Utc::now().to_rfc3339();
    let updated = conn.execute(
        "UPDATE feed_profile_keywords SET term = ?1, updated_at = ?2 WHERE id = ?3",
        params![term.trim(), now, keyword_id.trim()],
    )?;
    Ok(updated > 0)
}

/* ── Lens overrides (mute / boost multipliers) ────────────────────────────
 * Persisted in SQLite so both the TS ranker and the Rust world-feed ranker
 * honor the same editable lens, and so it survives an iOS app reinstall
 * (localStorage does not). Mirrors the old `interestProfile.ts` overrides.
 */

#[derive(Debug, Clone)]
pub struct FeedLensOverrideRecord {
    pub term: String,
    pub multiplier: f64,
    pub updated_at: String,
}

pub fn list_feed_lens_overrides(workspace_dir: &Path) -> Result<Vec<FeedLensOverrideRecord>> {
    let conn = open_conn(&db_path(workspace_dir))?;
    let mut stmt = conn.prepare(
        "SELECT term, multiplier, updated_at
         FROM feed_lens_overrides
         ORDER BY term ASC",
    )?;
    let rows = stmt.query_map([], |row| {
        Ok(FeedLensOverrideRecord {
            term: row.get(0)?,
            multiplier: row.get(1)?,
            updated_at: row.get(2)?,
        })
    })?;
    let mut out = Vec::new();
    for row in rows {
        out.push(row?);
    }
    Ok(out)
}

/// Upsert a lens override for a term. `multiplier` is clamped to a sane range
/// (0 = mute, 1 = normal, 2 = boost) to mirror the discrete UI states.
pub fn set_feed_lens_override(workspace_dir: &Path, term: &str, multiplier: f64) -> Result<()> {
    let key = term.trim().to_lowercase();
    if key.is_empty() {
        return Ok(());
    }
    let conn = open_conn(&db_path(workspace_dir))?;
    let now = Utc::now().to_rfc3339();
    // Clamp to [0, 4]: the UI emits 0/1/2 but a small headroom avoids silently
    // dropping an extreme value while still rejecting garbage.
    let mult = multiplier.clamp(0.0, 4.0);
    conn.execute(
        "INSERT INTO feed_lens_overrides (term, multiplier, updated_at)
         VALUES (?1, ?2, ?3)
         ON CONFLICT(term) DO UPDATE SET
            multiplier = excluded.multiplier,
            updated_at = excluded.updated_at",
        params![key, mult, now],
    )
    .context("Failed to upsert feed lens override")?;
    Ok(())
}

pub fn remove_feed_lens_override(workspace_dir: &Path, term: &str) -> Result<bool> {
    let key = term.trim().to_lowercase();
    let conn = open_conn(&db_path(workspace_dir))?;
    let deleted = conn.execute(
        "DELETE FROM feed_lens_overrides WHERE term = ?1",
        params![key],
    )?;
    Ok(deleted > 0)
}

/* ── Manual interests (user-added, not yet in journals) ────────────────── */

#[derive(Debug, Clone)]
pub struct FeedManualInterestRecord {
    pub term: String,
    pub added_at: String,
}

pub fn list_feed_manual_interests(workspace_dir: &Path) -> Result<Vec<FeedManualInterestRecord>> {
    let conn = open_conn(&db_path(workspace_dir))?;
    let mut stmt = conn.prepare(
        "SELECT term, added_at
         FROM feed_manual_interests
         ORDER BY added_at DESC, term ASC",
    )?;
    let rows = stmt.query_map([], |row| {
        Ok(FeedManualInterestRecord {
            term: row.get(0)?,
            added_at: row.get(1)?,
        })
    })?;
    let mut out = Vec::new();
    for row in rows {
        out.push(row?);
    }
    Ok(out)
}

pub fn add_feed_manual_interest(workspace_dir: &Path, term: &str) -> Result<bool> {
    let key = term.trim().to_lowercase();
    if key.is_empty() {
        return Ok(false);
    }
    let conn = open_conn(&db_path(workspace_dir))?;
    let now = Utc::now().to_rfc3339();
    // INSERT OR IGNORE so re-adding is a no-op; returns whether a row was added.
    let inserted = conn.execute(
        "INSERT OR IGNORE INTO feed_manual_interests (term, added_at) VALUES (?1, ?2)",
        params![key, now],
    )?;
    Ok(inserted > 0)
}

pub fn remove_feed_manual_interest(workspace_dir: &Path, term: &str) -> Result<bool> {
    let key = term.trim().to_lowercase();
    let conn = open_conn(&db_path(workspace_dir))?;
    let deleted = conn.execute(
        "DELETE FROM feed_manual_interests WHERE term = ?1",
        params![key],
    )?;
    Ok(deleted > 0)
}

pub fn upsert_feed_interest(
    workspace_dir: &Path,
    interest: &FeedInterestUpsert,
) -> Result<FeedInterestRecord> {
    let conn = open_conn(&db_path(workspace_dir))?;
    let now = Utc::now().to_rfc3339();
    let id = interest
        .id
        .as_deref()
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(ToOwned::to_owned)
        .unwrap_or_else(|| format!("lc_{}", Uuid::new_v4().simple()));
    conn.execute(
        "INSERT INTO feed_interests (
            id, label, source_path, embedding, health_score, last_seen_at, created_at, updated_at
         ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?7)
         ON CONFLICT(id) DO UPDATE SET
            label = excluded.label,
            source_path = excluded.source_path,
            embedding = excluded.embedding,
            health_score = excluded.health_score,
            last_seen_at = excluded.last_seen_at,
            updated_at = excluded.updated_at",
        params![
            id,
            interest.label,
            interest.source_path,
            interest.embedding,
            interest.health_score,
            interest.last_seen_at,
            now
        ],
    )
    .context("Failed to upsert feed interest")?;

    Ok(FeedInterestRecord {
        id,
        label: interest.label.clone(),
        source_path: interest.source_path.clone(),
        embedding: interest.embedding.clone(),
        health_score: interest.health_score,
        last_seen_at: interest.last_seen_at.clone(),
        created_at: now.clone(),
        updated_at: now,
        keywords_override: String::new(),
    })
}

pub fn decay_feed_interests(workspace_dir: &Path, decay_rate: f64) -> Result<usize> {
    let conn = open_conn(&db_path(workspace_dir))?;
    let now = Utc::now().to_rfc3339();
    let updated = conn.execute(
        "UPDATE feed_interests
         SET health_score = MAX(0.0, MIN(1.0, health_score * ?1)),
             updated_at = ?2",
        params![decay_rate, now],
    )?;
    Ok(updated)
}

pub fn update_feed_interest_keywords_override(
    workspace_dir: &Path,
    interest_id: &str,
    keywords_override: &str,
) -> Result<bool> {
    let conn = open_conn(&db_path(workspace_dir))?;
    let now = Utc::now().to_rfc3339();
    let updated = conn.execute(
        "UPDATE feed_interests SET keywords_override = ?1, updated_at = ?2 WHERE id = ?3",
        params![keywords_override, now, interest_id],
    )?;
    Ok(updated > 0)
}

pub fn update_feed_interest_label(
    workspace_dir: &Path,
    interest_id: &str,
    label: &str,
    embedding: &[u8],
) -> Result<bool> {
    let conn = open_conn(&db_path(workspace_dir))?;
    let now = Utc::now().to_rfc3339();
    let updated = conn.execute(
        "UPDATE feed_interests SET label = ?1, embedding = ?2, updated_at = ?3 WHERE id = ?4",
        params![label, embedding, now, interest_id],
    )?;
    Ok(updated > 0)
}

pub fn delete_feed_interest(workspace_dir: &Path, interest_id: &str) -> Result<bool> {
    let conn = open_conn(&db_path(workspace_dir))?;
    let deleted = conn.execute(
        "DELETE FROM feed_interests WHERE id = ?1",
        params![interest_id],
    )?;
    Ok(deleted > 0)
}

pub fn get_feed_interest_source(
    workspace_dir: &Path,
    source_path: &str,
) -> Result<Option<FeedInterestSourceRecord>> {
    let conn = open_conn(&db_path(workspace_dir))?;
    let mut stmt = conn.prepare(
        "SELECT source_path, content_hash, COALESCE(profile_input_hash, ''), interest_id, title,
                COALESCE(triage_keywords_json, ''), updated_at
         FROM feed_interest_sources
         WHERE source_path = ?1
         LIMIT 1",
    )?;
    let row = stmt
        .query_row(params![source_path], |row| {
            let interest_id: String = row.get(3)?;
            Ok(FeedInterestSourceRecord {
                source_path: row.get(0)?,
                content_hash: row.get(1)?,
                profile_input_hash: row.get(2)?,
                interest_id: non_empty_opt(interest_id),
                title: row.get(4)?,
                triage_keywords_json: row.get(5)?,
                updated_at: row.get(6)?,
            })
        })
        .optional()?;
    Ok(row)
}

pub fn upsert_feed_interest_source(
    workspace_dir: &Path,
    source: &FeedInterestSourceRecord,
) -> Result<()> {
    let conn = open_conn(&db_path(workspace_dir))?;
    conn.execute(
        "INSERT INTO feed_interest_sources (
            source_path, content_hash, profile_input_hash, interest_id, title, triage_keywords_json, updated_at
         ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)
         ON CONFLICT(source_path) DO UPDATE SET
            content_hash = excluded.content_hash,
            profile_input_hash = excluded.profile_input_hash,
            interest_id = excluded.interest_id,
            title = excluded.title,
            triage_keywords_json = excluded.triage_keywords_json,
            updated_at = excluded.updated_at",
        params![
            source.source_path,
            source.content_hash,
            source.profile_input_hash,
            source.interest_id.clone().unwrap_or_default(),
            source.title,
            source.triage_keywords_json,
            source.updated_at
        ],
    )
    .context("Failed to upsert feed interest source")?;
    Ok(())
}

// ── journal_enrichment: per-journal task-status map ─────────────────────────
// The on-device enrichment loop is the primary writer; `ensure_journal_enrichment`
// seeds pending rows (idempotent), `set_journal_enrichment` records outcomes,
// `list_pending_journal_enrichment` / `list_all_journal_enrichment` feed the loop
// and the AI Activity panel, and `delete_journal_enrichment` clears stale rows
// when a journal is deleted.

/// Insert a `pending` row for each task in `tasks` that does not already have a
/// row for `source_path`. Existing rows are left untouched (idempotent — safe to
/// call on every capture / every loop tick). Returns nothing; callers re-query.
pub fn ensure_journal_enrichment(
    workspace_dir: &Path,
    source_path: &str,
    tasks: &[&str],
) -> Result<()> {
    if tasks.is_empty() {
        return Ok(());
    }
    let conn = open_conn(&db_path(workspace_dir))?;
    let now = Utc::now().to_rfc3339();
    for task in tasks {
        // INSERT ... ON CONFLICT DO NOTHING keeps any existing row (done/error
        // from a prior pass) intact — we never clobber progress by re-seeding.
        conn.execute(
            "INSERT INTO journal_enrichment
                (source_path, task, status, attempts, last_error, last_run_at, updated_at)
             VALUES (?1, ?2, 'pending', 0, '', '', ?3)
             ON CONFLICT(source_path, task) DO NOTHING",
            params![source_path, task, now],
        )
        .context("Failed to ensure journal_enrichment row")?;
    }
    Ok(())
}

/// Set the status of a single (source_path, task) row, bumping `attempts` on
/// every non-`done` write and stamping `last_run_at` / `updated_at`. Creates
/// the row if it does not exist (defensive — matches how the loop calls it).
pub fn set_journal_enrichment(
    workspace_dir: &Path,
    source_path: &str,
    task: &str,
    status: &str,
    last_error: Option<&str>,
) -> Result<()> {
    let conn = open_conn(&db_path(workspace_dir))?;
    let now = Utc::now().to_rfc3339();
    let err = last_error.unwrap_or("").trim();
    // attempts increments on every write that is not a clean `done`, so a
    // flaky task's retry count is visible in the panel and the TS cap applies.
    let attempt_bump = if status == "done" { 0 } else { 1 };
    conn.execute(
        "INSERT INTO journal_enrichment
            (source_path, task, status, attempts, last_error, last_run_at, updated_at)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?6)
         ON CONFLICT(source_path, task) DO UPDATE SET
            status = excluded.status,
            attempts = journal_enrichment.attempts + excluded.attempts,
            last_error = excluded.last_error,
            last_run_at = excluded.last_run_at,
            updated_at = excluded.updated_at",
        params![source_path, task, status, attempt_bump, err, now],
    )
    .context("Failed to set journal_enrichment status")?;
    Ok(())
}

/// All enrichment rows for one journal (used by the loop's per-journal checks).
pub fn get_journal_enrichment(
    workspace_dir: &Path,
    source_path: &str,
) -> Result<Vec<JournalEnrichmentRecord>> {
    let conn = open_conn(&db_path(workspace_dir))?;
    let mut stmt = conn.prepare(
        "SELECT source_path, task, status, attempts, last_error, last_run_at, updated_at
         FROM journal_enrichment
         WHERE source_path = ?1
         ORDER BY task ASC",
    )?;
    let rows = stmt.query_map(params![source_path], |row| {
        Ok(JournalEnrichmentRecord {
            source_path: row.get(0)?,
            task: row.get(1)?,
            status: row.get(2)?,
            attempts: row.get(3)?,
            last_error: row.get(4)?,
            last_run_at: row.get(5)?,
            updated_at: row.get(6)?,
        })
    })?;

    let mut out = Vec::new();
    for row in rows {
        out.push(row?);
    }
    Ok(out)
}

/// Up to `limit` rows still in `pending` status, oldest-updated first — the
/// loop's work queue. `limit` keeps a single pass bounded on a phone.
pub fn list_pending_journal_enrichment(
    workspace_dir: &Path,
    limit: usize,
) -> Result<Vec<JournalEnrichmentRecord>> {
    let conn = open_conn(&db_path(workspace_dir))?;
    let lim = i64::try_from(limit.max(1)).unwrap_or(64);
    let mut stmt = conn.prepare(
        "SELECT source_path, task, status, attempts, last_error, last_run_at, updated_at
         FROM journal_enrichment
         WHERE status = 'pending'
         ORDER BY updated_at ASC, source_path ASC, task ASC
         LIMIT ?1",
    )?;
    let rows = stmt.query_map(params![lim], |row| {
        Ok(JournalEnrichmentRecord {
            source_path: row.get(0)?,
            task: row.get(1)?,
            status: row.get(2)?,
            attempts: row.get(3)?,
            last_error: row.get(4)?,
            last_run_at: row.get(5)?,
            updated_at: row.get(6)?,
        })
    })?;

    let mut out = Vec::new();
    for row in rows {
        out.push(row?);
    }
    Ok(out)
}

/// Every row — drives the AI Activity "Enrichment progress" summary.
pub fn list_all_journal_enrichment(workspace_dir: &Path) -> Result<Vec<JournalEnrichmentRecord>> {
    let conn = open_conn(&db_path(workspace_dir))?;
    let mut stmt = conn.prepare(
        "SELECT source_path, task, status, attempts, last_error, last_run_at, updated_at
         FROM journal_enrichment
         ORDER BY source_path ASC, task ASC",
    )?;
    let rows = stmt.query_map([], |row| {
        Ok(JournalEnrichmentRecord {
            source_path: row.get(0)?,
            task: row.get(1)?,
            status: row.get(2)?,
            attempts: row.get(3)?,
            last_error: row.get(4)?,
            last_run_at: row.get(5)?,
            updated_at: row.get(6)?,
        })
    })?;

    let mut out = Vec::new();
    for row in rows {
        out.push(row?);
    }
    Ok(out)
}

/// Delete every row for a journal — called when the journal itself is deleted,
/// so the status map never references a removed file.
pub fn delete_journal_enrichment(workspace_dir: &Path, source_path: &str) -> Result<()> {
    let conn = open_conn(&db_path(workspace_dir))?;
    conn.execute(
        "DELETE FROM journal_enrichment WHERE source_path = ?1",
        params![source_path],
    )
    .context("Failed to delete journal_enrichment rows")?;
    Ok(())
}

pub fn list_feed_web_sources(workspace_dir: &Path) -> Result<Vec<FeedWebSourceRecord>> {
    let conn = open_conn(&db_path(workspace_dir))?;
    let mut stmt = conn.prepare(
        "SELECT domain, title, html_url, xml_url, description, topics_csv, metadata_embedding,
                enabled, source_kind, created_at, updated_at
         FROM feed_web_sources
         WHERE enabled = 1
         ORDER BY title ASC, domain ASC",
    )?;
    let rows = stmt.query_map([], |row| {
        Ok(FeedWebSourceRecord {
            domain: row.get(0)?,
            title: row.get(1)?,
            html_url: row.get(2)?,
            xml_url: row.get(3)?,
            description: row.get(4)?,
            topics_csv: row.get(5)?,
            metadata_embedding: row.get(6)?,
            enabled: row.get::<_, i64>(7)? != 0,
            source_kind: row.get(8)?,
            created_at: row.get(9)?,
            updated_at: row.get(10)?,
        })
    })?;

    let mut out = Vec::new();
    for row in rows {
        out.push(row?);
    }
    Ok(out)
}

pub fn upsert_feed_web_source(
    workspace_dir: &Path,
    source: &FeedWebSourceUpsert,
) -> Result<FeedWebSourceRecord> {
    let conn = open_conn(&db_path(workspace_dir))?;
    let now = Utc::now().to_rfc3339();
    conn.execute(
        "INSERT INTO feed_web_sources (
            domain, title, html_url, xml_url, description, topics_csv, metadata_embedding,
            enabled, source_kind, created_at, updated_at
         ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?10)
         ON CONFLICT(domain) DO UPDATE SET
            title = excluded.title,
            html_url = excluded.html_url,
            xml_url = excluded.xml_url,
            description = excluded.description,
            topics_csv = excluded.topics_csv,
            metadata_embedding = excluded.metadata_embedding,
            enabled = excluded.enabled,
            source_kind = excluded.source_kind,
            updated_at = excluded.updated_at",
        params![
            source.domain.trim().to_ascii_lowercase(),
            source.title,
            source.html_url,
            source.xml_url,
            source.description,
            source.topics_csv,
            source.metadata_embedding,
            if source.enabled { 1 } else { 0 },
            source.source_kind,
            now
        ],
    )
    .context("Failed to upsert feed web source")?;

    Ok(FeedWebSourceRecord {
        domain: source.domain.trim().to_ascii_lowercase(),
        title: source.title.clone(),
        html_url: source.html_url.clone(),
        xml_url: source.xml_url.clone(),
        description: source.description.clone(),
        topics_csv: source.topics_csv.clone(),
        metadata_embedding: source.metadata_embedding.clone(),
        enabled: source.enabled,
        source_kind: source.source_kind.clone(),
        created_at: now.clone(),
        updated_at: now,
    })
}

pub fn get_feed_web_cache(workspace_dir: &Path, url: &str) -> Result<Option<FeedWebCacheRecord>> {
    let conn = open_conn(&db_path(workspace_dir))?;
    let mut stmt = conn.prepare(
        "SELECT url, domain, title, description, image_url, provider, snippet, search_query, fetched_at, updated_at
         FROM feed_web_cache
         WHERE url = ?1
         LIMIT 1",
    )?;
    let row = stmt
        .query_row(params![url], |row| {
            Ok(FeedWebCacheRecord {
                url: row.get(0)?,
                domain: row.get(1)?,
                title: row.get(2)?,
                description: row.get(3)?,
                image_url: row.get(4)?,
                provider: row.get(5)?,
                snippet: row.get(6)?,
                search_query: row.get(7)?,
                fetched_at: row.get(8)?,
                updated_at: row.get(9)?,
            })
        })
        .optional()?;
    Ok(row)
}

pub fn upsert_feed_web_cache(
    workspace_dir: &Path,
    item: &FeedWebCacheUpsert,
) -> Result<FeedWebCacheRecord> {
    let conn = open_conn(&db_path(workspace_dir))?;
    let now = Utc::now().to_rfc3339();
    conn.execute(
        "INSERT INTO feed_web_cache (
            url, domain, title, description, image_url, provider, snippet, search_query, fetched_at, updated_at
         ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10)
         ON CONFLICT(url) DO UPDATE SET
            domain = excluded.domain,
            title = excluded.title,
            description = excluded.description,
            image_url = excluded.image_url,
            provider = excluded.provider,
            snippet = excluded.snippet,
            search_query = excluded.search_query,
            fetched_at = excluded.fetched_at,
            updated_at = excluded.updated_at",
        params![
            item.url,
            item.domain,
            item.title,
            item.description,
            item.image_url,
            item.provider,
            item.snippet,
            item.search_query,
            item.fetched_at,
            now
        ],
    )
    .context("Failed to upsert feed web cache")?;

    Ok(FeedWebCacheRecord {
        url: item.url.clone(),
        domain: item.domain.clone(),
        title: item.title.clone(),
        description: item.description.clone(),
        image_url: item.image_url.clone(),
        provider: item.provider.clone(),
        snippet: item.snippet.clone(),
        search_query: item.search_query.clone(),
        fetched_at: item.fetched_at.clone(),
        updated_at: now,
    })
}

pub fn list_personalized_feed_cache(
    workspace_dir: &Path,
    feed_key: &str,
    limit: usize,
) -> Result<Vec<PersonalizedFeedCacheRecord>> {
    let conn = open_conn(&db_path(workspace_dir))?;
    let lim = i64::try_from(limit.max(1)).unwrap_or(100);
    let mut stmt = conn.prepare(
        "SELECT feed_key, cache_key, payload_json, score, sort_order, refreshed_at, updated_at
         FROM personalized_feed_cache
         WHERE feed_key = ?1
         ORDER BY sort_order ASC, score DESC, cache_key ASC
         LIMIT ?2",
    )?;
    let rows = stmt.query_map(params![feed_key.trim(), lim], |row| {
        Ok(PersonalizedFeedCacheRecord {
            feed_key: row.get(0)?,
            cache_key: row.get(1)?,
            payload_json: row.get(2)?,
            score: row.get(3)?,
            sort_order: row.get(4)?,
            refreshed_at: row.get(5)?,
            updated_at: row.get(6)?,
        })
    })?;

    let mut out = Vec::new();
    for row in rows {
        out.push(row?);
    }
    Ok(out)
}

pub fn replace_personalized_feed_cache(
    workspace_dir: &Path,
    feed_key: &str,
    items: &[PersonalizedFeedCacheUpsert],
) -> Result<()> {
    let mut conn = open_conn(&db_path(workspace_dir))?;
    let tx = conn.transaction()?;
    tx.execute(
        "DELETE FROM personalized_feed_cache WHERE feed_key = ?1",
        params![feed_key.trim()],
    )
    .with_context(|| {
        format!(
            "Failed to clear personalized feed cache for {}",
            feed_key.trim()
        )
    })?;

    for item in items {
        let now = Utc::now().to_rfc3339();
        tx.execute(
            "INSERT INTO personalized_feed_cache (
                feed_key, cache_key, payload_json, score, sort_order, refreshed_at, updated_at
             ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7)",
            params![
                item.feed_key.trim(),
                item.cache_key.trim(),
                item.payload_json,
                item.score,
                item.sort_order,
                item.refreshed_at,
                now,
            ],
        )
        .with_context(|| {
            format!(
                "Failed to insert personalized feed cache row {} for {}",
                item.cache_key, item.feed_key
            )
        })?;
    }

    tx.commit()?;
    Ok(())
}

pub fn get_personalized_feed_state(
    workspace_dir: &Path,
    feed_key: &str,
) -> Result<Option<PersonalizedFeedStateRecord>> {
    let conn = open_conn(&db_path(workspace_dir))?;
    let mut stmt = conn.prepare(
        "SELECT feed_key, dirty, refresh_status, refreshed_at, refresh_started_at,
                refresh_finished_at, last_error, profile_status, profile_stats_json,
                details_json, updated_at, COALESCE(generation, 0)
         FROM personalized_feed_state
         WHERE feed_key = ?1
         LIMIT 1",
    )?;
    let row = stmt
        .query_row(params![feed_key.trim()], |row| {
            Ok(PersonalizedFeedStateRecord {
                feed_key: row.get(0)?,
                dirty: row.get::<_, i64>(1)? != 0,
                refresh_status: row.get(2)?,
                refreshed_at: row.get(3)?,
                refresh_started_at: row.get(4)?,
                refresh_finished_at: row.get(5)?,
                last_error: row.get(6)?,
                profile_status: row.get(7)?,
                profile_stats_json: row.get(8)?,
                details_json: row.get(9)?,
                updated_at: row.get(10)?,
                generation: row.get(11)?,
            })
        })
        .optional()?;
    Ok(row)
}

pub fn upsert_personalized_feed_state(
    workspace_dir: &Path,
    state: &PersonalizedFeedStateUpsert,
) -> Result<PersonalizedFeedStateRecord> {
    let conn = open_conn(&db_path(workspace_dir))?;
    let now = Utc::now().to_rfc3339();
    conn.execute(
        "INSERT INTO personalized_feed_state (
            feed_key, dirty, refresh_status, refreshed_at, refresh_started_at,
            refresh_finished_at, last_error, profile_status, profile_stats_json,
            details_json, updated_at
         ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11)
         ON CONFLICT(feed_key) DO UPDATE SET
            dirty = excluded.dirty,
            refresh_status = excluded.refresh_status,
            refreshed_at = excluded.refreshed_at,
            refresh_started_at = excluded.refresh_started_at,
            refresh_finished_at = excluded.refresh_finished_at,
            last_error = excluded.last_error,
            profile_status = excluded.profile_status,
            profile_stats_json = excluded.profile_stats_json,
            details_json = excluded.details_json,
            updated_at = excluded.updated_at",
        params![
            state.feed_key.trim(),
            if state.dirty { 1 } else { 0 },
            state.refresh_status.trim(),
            state.refreshed_at.trim(),
            state.refresh_started_at.trim(),
            state.refresh_finished_at.trim(),
            state.last_error.trim(),
            state.profile_status.trim(),
            state.profile_stats_json.trim(),
            state.details_json.trim(),
            now,
        ],
    )
    .with_context(|| {
        format!(
            "Failed to upsert personalized feed state {}",
            state.feed_key
        )
    })?;

    Ok(PersonalizedFeedStateRecord {
        feed_key: state.feed_key.trim().to_string(),
        dirty: state.dirty,
        refresh_status: state.refresh_status.trim().to_string(),
        refreshed_at: state.refreshed_at.trim().to_string(),
        refresh_started_at: state.refresh_started_at.trim().to_string(),
        refresh_finished_at: state.refresh_finished_at.trim().to_string(),
        last_error: state.last_error.trim().to_string(),
        profile_status: state.profile_status.trim().to_string(),
        profile_stats_json: state.profile_stats_json.trim().to_string(),
        details_json: state.details_json.trim().to_string(),
        updated_at: now,
        generation: 0,
    })
}

pub fn bump_feed_generation(workspace_dir: &Path, feed_key: &str) -> Result<i64> {
    let conn = open_conn(&db_path(workspace_dir))?;
    let current: i64 = conn
        .query_row(
            "SELECT COALESCE(generation, 0) FROM personalized_feed_state WHERE feed_key = ?1",
            params![feed_key.trim()],
            |row| row.get(0),
        )
        .unwrap_or(0);
    let next = current + 1;
    conn.execute(
        "UPDATE personalized_feed_state SET generation = ?1 WHERE feed_key = ?2",
        params![next, feed_key.trim()],
    )?;
    Ok(next)
}

pub fn mark_personalized_feed_dirty(workspace_dir: &Path, feed_key: &str) -> Result<()> {
    let current = get_personalized_feed_state(workspace_dir, feed_key)?;
    let current = current.unwrap_or(PersonalizedFeedStateRecord {
        feed_key: feed_key.trim().to_string(),
        dirty: true,
        refresh_status: "idle".to_string(),
        refreshed_at: String::new(),
        refresh_started_at: String::new(),
        refresh_finished_at: String::new(),
        last_error: String::new(),
        profile_status: String::new(),
        profile_stats_json: "{}".to_string(),
        generation: 0,
        details_json: "{}".to_string(),
        updated_at: String::new(),
    });
    let _ = upsert_personalized_feed_state(
        workspace_dir,
        &PersonalizedFeedStateUpsert {
            feed_key: current.feed_key,
            dirty: true,
            refresh_status: current.refresh_status,
            refreshed_at: current.refreshed_at,
            refresh_started_at: current.refresh_started_at,
            refresh_finished_at: current.refresh_finished_at,
            last_error: current.last_error,
            profile_status: current.profile_status,
            profile_stats_json: if current.profile_stats_json.trim().is_empty() {
                "{}".to_string()
            } else {
                current.profile_stats_json
            },
            details_json: if current.details_json.trim().is_empty() {
                "{}".to_string()
            } else {
                current.details_json
            },
        },
    )?;
    Ok(())
}

pub fn list_content_sources(
    workspace_dir: &Path,
    limit: usize,
) -> Result<Vec<ContentSourceRecord>> {
    let conn = open_conn(&db_path(workspace_dir))?;
    let lim = i64::try_from(limit.max(1)).unwrap_or(100);
    let mut stmt = conn.prepare(
        "SELECT source_key, domain, title, html_url, xml_url, source_kind, enabled,
                etag, last_modified, last_fetch_at, last_success_at, last_error, created_at, updated_at
         FROM content_sources
         WHERE enabled = 1
         ORDER BY
            CASE WHEN NULLIF(last_fetch_at, '') IS NULL THEN 0 ELSE 1 END ASC,
            NULLIF(last_fetch_at, '') ASC,
            title ASC,
            domain ASC
         LIMIT ?1",
    )?;
    let rows = stmt.query_map(params![lim], |row| {
        Ok(ContentSourceRecord {
            source_key: row.get(0)?,
            domain: row.get(1)?,
            title: row.get(2)?,
            html_url: row.get(3)?,
            xml_url: row.get(4)?,
            source_kind: row.get(5)?,
            enabled: row.get::<_, i64>(6)? != 0,
            etag: row.get(7)?,
            last_modified: row.get(8)?,
            last_fetch_at: row.get(9)?,
            last_success_at: row.get(10)?,
            last_error: row.get(11)?,
            created_at: row.get(12)?,
            updated_at: row.get(13)?,
        })
    })?;

    let mut out = Vec::new();
    for row in rows {
        out.push(row?);
    }
    Ok(out)
}

pub fn upsert_content_source(
    workspace_dir: &Path,
    source: &ContentSourceUpsert,
) -> Result<ContentSourceRecord> {
    let conn = open_conn(&db_path(workspace_dir))?;
    let now = Utc::now().to_rfc3339();
    let source_key = source.source_key.trim().to_string();
    conn.execute(
        "INSERT INTO content_sources (
            source_key, domain, title, html_url, xml_url, source_kind, enabled,
            etag, last_modified, last_fetch_at, last_success_at, last_error, created_at, updated_at
         ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, '', '', '', '', '', ?8, ?8)
         ON CONFLICT(source_key) DO UPDATE SET
            domain = excluded.domain,
            title = excluded.title,
            html_url = excluded.html_url,
            xml_url = excluded.xml_url,
            source_kind = excluded.source_kind,
            enabled = excluded.enabled,
            updated_at = excluded.updated_at",
        params![
            source_key,
            source.domain.trim().to_ascii_lowercase(),
            source.title,
            source.html_url,
            source.xml_url,
            source.source_kind,
            if source.enabled { 1 } else { 0 },
            now
        ],
    )
    .context("Failed to upsert content source")?;

    let existing = get_content_source(workspace_dir, &source.source_key)?;
    existing.context("Content source missing after upsert")
}

pub fn get_content_source(
    workspace_dir: &Path,
    source_key: &str,
) -> Result<Option<ContentSourceRecord>> {
    let conn = open_conn(&db_path(workspace_dir))?;
    let mut stmt = conn.prepare(
        "SELECT source_key, domain, title, html_url, xml_url, source_kind, enabled,
                etag, last_modified, last_fetch_at, last_success_at, last_error, created_at, updated_at
         FROM content_sources
         WHERE source_key = ?1
         LIMIT 1",
    )?;
    let row = stmt
        .query_row(params![source_key.trim()], |row| {
            Ok(ContentSourceRecord {
                source_key: row.get(0)?,
                domain: row.get(1)?,
                title: row.get(2)?,
                html_url: row.get(3)?,
                xml_url: row.get(4)?,
                source_kind: row.get(5)?,
                enabled: row.get::<_, i64>(6)? != 0,
                etag: row.get(7)?,
                last_modified: row.get(8)?,
                last_fetch_at: row.get(9)?,
                last_success_at: row.get(10)?,
                last_error: row.get(11)?,
                created_at: row.get(12)?,
                updated_at: row.get(13)?,
            })
        })
        .optional()?;
    Ok(row)
}

pub fn update_content_source_fetch(
    workspace_dir: &Path,
    source_key: &str,
    fetched_at: &str,
    etag: Option<&str>,
    last_modified: Option<&str>,
    last_error: Option<&str>,
    success: bool,
) -> Result<()> {
    let conn = open_conn(&db_path(workspace_dir))?;
    let normalized_error = last_error.unwrap_or("").trim().to_string();
    conn.execute(
        "UPDATE content_sources
         SET etag = COALESCE(NULLIF(?2, ''), etag),
             last_modified = COALESCE(NULLIF(?3, ''), last_modified),
             last_fetch_at = ?4,
             last_success_at = CASE WHEN ?6 = 1 THEN ?4 ELSE last_success_at END,
             last_error = ?5,
             updated_at = ?4
         WHERE source_key = ?1",
        params![
            source_key.trim(),
            etag.unwrap_or("").trim(),
            last_modified.unwrap_or("").trim(),
            fetched_at.trim(),
            if success {
                ""
            } else {
                normalized_error.as_str()
            },
            if success { 1 } else { 0 },
        ],
    )
    .with_context(|| {
        format!(
            "Failed to update content source fetch state for {}",
            source_key
        )
    })?;
    Ok(())
}

pub fn upsert_content_item(
    workspace_dir: &Path,
    item: &ContentItemUpsert,
) -> Result<ContentItemRecord> {
    let conn = open_conn(&db_path(workspace_dir))?;
    let now = Utc::now().to_rfc3339();
    conn.execute(
        "INSERT INTO content_items (
            id, source_key, source_title, source_kind, domain, canonical_url, external_id,
            title, author, summary, content_text, content_hash, embedding, published_at,
            discovered_at, created_at, updated_at
         ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15, ?16, ?16)
         ON CONFLICT(canonical_url) DO UPDATE SET
            source_key = excluded.source_key,
            source_title = excluded.source_title,
            source_kind = excluded.source_kind,
            domain = excluded.domain,
            external_id = excluded.external_id,
            title = excluded.title,
            author = excluded.author,
            summary = excluded.summary,
            content_text = excluded.content_text,
            content_hash = excluded.content_hash,
            embedding = excluded.embedding,
            published_at = excluded.published_at,
            discovered_at = excluded.discovered_at,
            updated_at = excluded.updated_at",
        params![
            item.id,
            item.source_key,
            item.source_title,
            item.source_kind,
            item.domain,
            item.canonical_url,
            item.external_id,
            item.title,
            item.author,
            item.summary,
            item.content_text,
            item.content_hash,
            item.embedding,
            item.published_at,
            item.discovered_at,
            now
        ],
    )
    .context("Failed to upsert content item")?;

    Ok(ContentItemRecord {
        id: item.id.clone(),
        source_key: item.source_key.clone(),
        source_title: item.source_title.clone(),
        source_kind: item.source_kind.clone(),
        domain: item.domain.clone(),
        canonical_url: item.canonical_url.clone(),
        external_id: item.external_id.clone(),
        title: item.title.clone(),
        author: item.author.clone(),
        summary: item.summary.clone(),
        content_text: item.content_text.clone(),
        content_hash: item.content_hash.clone(),
        embedding: item.embedding.clone(),
        published_at: item.published_at.clone(),
        discovered_at: item.discovered_at.clone(),
        created_at: now.clone(),
        updated_at: now,
    })
}

pub fn list_recent_content_items(
    workspace_dir: &Path,
    limit: usize,
) -> Result<Vec<ContentItemRecord>> {
    let conn = open_conn(&db_path(workspace_dir))?;
    let lim = i64::try_from(limit.max(1)).unwrap_or(100);
    let mut stmt = conn.prepare(
        "SELECT id, source_key, source_title, source_kind, domain, canonical_url, external_id,
                title, author, summary, content_text, content_hash, embedding, published_at,
                discovered_at, created_at, updated_at
         FROM content_items
         ORDER BY
            COALESCE(NULLIF(published_at, ''), NULLIF(discovered_at, ''), updated_at) DESC,
            id DESC
         LIMIT ?1",
    )?;
    let rows = stmt.query_map(params![lim], |row| {
        Ok(ContentItemRecord {
            id: row.get(0)?,
            source_key: row.get(1)?,
            source_title: row.get(2)?,
            source_kind: row.get(3)?,
            domain: row.get(4)?,
            canonical_url: row.get(5)?,
            external_id: row.get(6)?,
            title: row.get(7)?,
            author: row.get(8)?,
            summary: row.get(9)?,
            content_text: row.get(10)?,
            content_hash: row.get(11)?,
            embedding: row.get(12)?,
            published_at: row.get(13)?,
            discovered_at: row.get(14)?,
            created_at: row.get(15)?,
            updated_at: row.get(16)?,
        })
    })?;

    let mut out = Vec::new();
    for row in rows {
        out.push(row?);
    }
    Ok(out)
}

pub fn list_content_items_missing_embeddings(
    workspace_dir: &Path,
    limit: usize,
) -> Result<Vec<ContentItemRecord>> {
    let conn = open_conn(&db_path(workspace_dir))?;
    let lim = i64::try_from(limit.max(1)).unwrap_or(100);
    let mut stmt = conn.prepare(
        "SELECT id, source_key, source_title, source_kind, domain, canonical_url, external_id,
                title, author, summary, content_text, content_hash, embedding, published_at,
                discovered_at, created_at, updated_at
         FROM content_items
         WHERE length(embedding) = 0
           AND length(trim(content_text)) > 0
         ORDER BY
            COALESCE(NULLIF(published_at, ''), NULLIF(discovered_at, ''), updated_at) DESC,
            id DESC
         LIMIT ?1",
    )?;
    let rows = stmt.query_map(params![lim], |row| {
        Ok(ContentItemRecord {
            id: row.get(0)?,
            source_key: row.get(1)?,
            source_title: row.get(2)?,
            source_kind: row.get(3)?,
            domain: row.get(4)?,
            canonical_url: row.get(5)?,
            external_id: row.get(6)?,
            title: row.get(7)?,
            author: row.get(8)?,
            summary: row.get(9)?,
            content_text: row.get(10)?,
            content_hash: row.get(11)?,
            embedding: row.get(12)?,
            published_at: row.get(13)?,
            discovered_at: row.get(14)?,
            created_at: row.get(15)?,
            updated_at: row.get(16)?,
        })
    })?;

    let mut out = Vec::new();
    for row in rows {
        out.push(row?);
    }
    Ok(out)
}

pub fn update_content_item_embedding(
    workspace_dir: &Path,
    item_id: &str,
    embedding: &[u8],
) -> Result<()> {
    let conn = open_conn(&db_path(workspace_dir))?;
    let now = Utc::now().to_rfc3339();
    conn.execute(
        "UPDATE content_items
         SET embedding = ?2,
             updated_at = ?3
         WHERE id = ?1",
        params![item_id.trim(), embedding, now],
    )
    .with_context(|| format!("Failed to update content item embedding for {}", item_id))?;
    Ok(())
}

fn open_conn(path: &Path) -> Result<Connection> {
    let conn = Connection::open(path)
        .with_context(|| format!("Failed to open local store {}", path.display()))?;
    conn.busy_timeout(Duration::from_secs(5))
        .context("Failed to set local store busy timeout")?;
    conn.execute_batch(
        "PRAGMA journal_mode=WAL;
         PRAGMA synchronous=NORMAL;
         PRAGMA foreign_keys=ON;",
    )
    .context("Failed to configure local store pragmas")?;
    Ok(conn)
}

fn init_schema(conn: &Connection) -> Result<()> {
    conn.execute_batch(
        "CREATE TABLE IF NOT EXISTS chat_messages (
            id TEXT PRIMARY KEY,
            thread_id TEXT NOT NULL,
            role TEXT NOT NULL,
            content TEXT NOT NULL DEFAULT '',
            status TEXT NOT NULL,
            source TEXT NOT NULL DEFAULT '',
            reply_to_id TEXT NOT NULL DEFAULT '',
            error TEXT NOT NULL DEFAULT '',
            created_at_client TEXT NOT NULL DEFAULT '',
            processed_at TEXT NOT NULL DEFAULT '',
            created TEXT NOT NULL,
            updated TEXT NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_chat_messages_thread_created
            ON chat_messages(thread_id, created_at_client, created);

        CREATE TABLE IF NOT EXISTS drafts (
            id TEXT PRIMARY KEY,
            text TEXT NOT NULL DEFAULT '',
            video_name TEXT NOT NULL DEFAULT '',
            created_at_client TEXT NOT NULL DEFAULT '',
            updated_at_client TEXT NOT NULL DEFAULT '',
            created TEXT NOT NULL,
            updated TEXT NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_drafts_created
            ON drafts(created_at_client, created);

        CREATE TABLE IF NOT EXISTS post_history (
            id TEXT PRIMARY KEY,
            provider TEXT NOT NULL DEFAULT 'bluesky',
            text TEXT NOT NULL DEFAULT '',
            video_name TEXT NOT NULL DEFAULT '',
            source_path TEXT NOT NULL DEFAULT '',
            uri TEXT NOT NULL DEFAULT '',
            cid TEXT NOT NULL DEFAULT '',
            status TEXT NOT NULL DEFAULT 'success',
            error TEXT NOT NULL DEFAULT '',
            created_at_client TEXT NOT NULL DEFAULT '',
            created TEXT NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_post_history_created
            ON post_history(created_at_client, created);

        CREATE TABLE IF NOT EXISTS journal_entries (
            id TEXT PRIMARY KEY,
            title TEXT NOT NULL DEFAULT '',
            entry_type TEXT NOT NULL DEFAULT '',
            source TEXT NOT NULL DEFAULT '',
            status TEXT NOT NULL DEFAULT '',
            workspace_path TEXT NOT NULL DEFAULT '',
            preview_text TEXT NOT NULL DEFAULT '',
            text_body TEXT NOT NULL DEFAULT '',
            tags_csv TEXT NOT NULL DEFAULT '',
            created_at_client TEXT NOT NULL DEFAULT '',
            created TEXT NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_journal_entries_path
            ON journal_entries(workspace_path);

        CREATE TABLE IF NOT EXISTS media_assets (
            id TEXT PRIMARY KEY,
            title TEXT NOT NULL DEFAULT '',
            entry_id TEXT NOT NULL DEFAULT '',
            asset_type TEXT NOT NULL DEFAULT '',
            mime_type TEXT NOT NULL DEFAULT '',
            source TEXT NOT NULL DEFAULT '',
            status TEXT NOT NULL DEFAULT '',
            workspace_path TEXT NOT NULL DEFAULT '',
            size_bytes INTEGER NOT NULL DEFAULT 0,
            created_at_client TEXT NOT NULL DEFAULT '',
            created TEXT NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_media_assets_path
            ON media_assets(workspace_path);

        CREATE TABLE IF NOT EXISTS artifacts (
            id TEXT PRIMARY KEY,
            parent_asset_id TEXT NOT NULL DEFAULT '',
            parent_entry_id TEXT NOT NULL DEFAULT '',
            artifact_type TEXT NOT NULL DEFAULT '',
            title TEXT NOT NULL DEFAULT '',
            status TEXT NOT NULL DEFAULT '',
            mime_type TEXT NOT NULL DEFAULT '',
            workspace_path TEXT NOT NULL DEFAULT '',
            preview_text TEXT NOT NULL DEFAULT '',
            metadata_json TEXT NOT NULL DEFAULT '',
            created_at_client TEXT NOT NULL DEFAULT '',
            created TEXT NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_artifacts_path
            ON artifacts(workspace_path);

        CREATE TABLE IF NOT EXISTS workspace_todos (
            id TEXT PRIMARY KEY,
            title TEXT NOT NULL DEFAULT '',
            details TEXT NOT NULL DEFAULT '',
            priority TEXT NOT NULL DEFAULT 'medium',
            model_status TEXT NOT NULL DEFAULT 'open',
            status_override TEXT NOT NULL DEFAULT '',
            due_at TEXT NOT NULL DEFAULT '',
            source_path TEXT NOT NULL DEFAULT '',
            source_excerpt TEXT NOT NULL DEFAULT '',
            metadata_json TEXT NOT NULL DEFAULT '',
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL,
            last_manifest_id TEXT NOT NULL DEFAULT '',
            archived INTEGER NOT NULL DEFAULT 0
        );
        CREATE INDEX IF NOT EXISTS idx_workspace_todos_active
            ON workspace_todos(archived, updated_at);

        CREATE TABLE IF NOT EXISTS workspace_events (
            id TEXT PRIMARY KEY,
            title TEXT NOT NULL DEFAULT '',
            details TEXT NOT NULL DEFAULT '',
            location TEXT NOT NULL DEFAULT '',
            status TEXT NOT NULL DEFAULT 'confirmed',
            start_at TEXT NOT NULL DEFAULT '',
            end_at TEXT NOT NULL DEFAULT '',
            all_day INTEGER NOT NULL DEFAULT 0,
            source_path TEXT NOT NULL DEFAULT '',
            source_excerpt TEXT NOT NULL DEFAULT '',
            metadata_json TEXT NOT NULL DEFAULT '',
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL,
            last_manifest_id TEXT NOT NULL DEFAULT '',
            archived INTEGER NOT NULL DEFAULT 0
        );
        CREATE INDEX IF NOT EXISTS idx_workspace_events_active
            ON workspace_events(archived, start_at);

        CREATE TABLE IF NOT EXISTS workspace_synth_sources (
            source_path TEXT PRIMARY KEY,
            content_hash TEXT NOT NULL DEFAULT '',
            word_count INTEGER NOT NULL DEFAULT 0,
            last_processed_hash TEXT NOT NULL DEFAULT '',
            last_processed_at TEXT NOT NULL DEFAULT '',
            last_batch_id TEXT NOT NULL DEFAULT '',
            updated_at TEXT NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_workspace_synth_sources_updated
            ON workspace_synth_sources(updated_at);

        -- Per-journal AI/transcription task status. One row per (journal path,
        -- task). Seeded `pending` on capture; moved to `done`/`error`/`skipped`
        -- by the on-device enrichment loop as each task's precondition is met.
        -- The loop converges: once all of a journal's tasks are terminal it is
        -- never revisited. See web/src/hooks/useJournalEnrichmentLoop.ts.
        CREATE TABLE IF NOT EXISTS journal_enrichment (
            source_path TEXT NOT NULL,
            task TEXT NOT NULL,
            status TEXT NOT NULL DEFAULT 'pending',
            attempts INTEGER NOT NULL DEFAULT 0,
            last_error TEXT NOT NULL DEFAULT '',
            last_run_at TEXT NOT NULL DEFAULT '',
            updated_at TEXT NOT NULL,
            PRIMARY KEY (source_path, task)
        );
        CREATE INDEX IF NOT EXISTS idx_journal_enrichment_status
            ON journal_enrichment(status, updated_at);

        CREATE TABLE IF NOT EXISTS feed_interests (
            id TEXT PRIMARY KEY,
            label TEXT NOT NULL DEFAULT '',
            source_path TEXT NOT NULL DEFAULT '',
            embedding BLOB NOT NULL,
            health_score REAL NOT NULL DEFAULT 1.0,
            last_seen_at TEXT NOT NULL DEFAULT '',
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_feed_interests_updated
            ON feed_interests(updated_at);

        CREATE TABLE IF NOT EXISTS feed_interest_sources (
            source_path TEXT PRIMARY KEY,
            content_hash TEXT NOT NULL DEFAULT '',
            profile_input_hash TEXT NOT NULL DEFAULT '',
            interest_id TEXT NOT NULL DEFAULT '',
            title TEXT NOT NULL DEFAULT '',
            triage_keywords_json TEXT NOT NULL DEFAULT '',
            updated_at TEXT NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_feed_interest_sources_interest_id
            ON feed_interest_sources(interest_id);

        CREATE TABLE IF NOT EXISTS feed_profile_keywords (
            id TEXT PRIMARY KEY,
            term TEXT NOT NULL UNIQUE,
            weight REAL NOT NULL DEFAULT 0.0,
            first_seen_at TEXT NOT NULL DEFAULT '',
            last_seen_at TEXT NOT NULL DEFAULT '',
            source_count INTEGER NOT NULL DEFAULT 0,
            updated_at TEXT NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_feed_profile_keywords_weight
            ON feed_profile_keywords(weight DESC, last_seen_at DESC, updated_at DESC);

        CREATE TABLE IF NOT EXISTS feed_lens_overrides (
            term TEXT PRIMARY KEY,
            multiplier REAL NOT NULL DEFAULT 1.0,
            updated_at TEXT NOT NULL
        );

        CREATE TABLE IF NOT EXISTS feed_manual_interests (
            term TEXT PRIMARY KEY,
            added_at TEXT NOT NULL
        );

        CREATE TABLE IF NOT EXISTS feed_web_sources (
            domain TEXT PRIMARY KEY,
            title TEXT NOT NULL DEFAULT '',
            html_url TEXT NOT NULL DEFAULT '',
            xml_url TEXT NOT NULL DEFAULT '',
            description TEXT NOT NULL DEFAULT '',
            topics_csv TEXT NOT NULL DEFAULT '',
            metadata_embedding BLOB NOT NULL DEFAULT X'',
            enabled INTEGER NOT NULL DEFAULT 1,
            source_kind TEXT NOT NULL DEFAULT '',
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_feed_web_sources_enabled
            ON feed_web_sources(enabled, title);

        CREATE TABLE IF NOT EXISTS feed_web_cache (
            url TEXT PRIMARY KEY,
            domain TEXT NOT NULL DEFAULT '',
            title TEXT NOT NULL DEFAULT '',
            description TEXT NOT NULL DEFAULT '',
            image_url TEXT NOT NULL DEFAULT '',
            provider TEXT NOT NULL DEFAULT '',
            snippet TEXT NOT NULL DEFAULT '',
            search_query TEXT NOT NULL DEFAULT '',
            fetched_at TEXT NOT NULL DEFAULT '',
            updated_at TEXT NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_feed_web_cache_updated
            ON feed_web_cache(updated_at);

        CREATE TABLE IF NOT EXISTS personalized_feed_cache (
            feed_key TEXT NOT NULL DEFAULT '',
            cache_key TEXT NOT NULL DEFAULT '',
            payload_json TEXT NOT NULL DEFAULT '',
            score REAL NOT NULL DEFAULT 0.0,
            sort_order INTEGER NOT NULL DEFAULT 0,
            refreshed_at TEXT NOT NULL DEFAULT '',
            updated_at TEXT NOT NULL,
            PRIMARY KEY(feed_key, cache_key)
        );
        CREATE INDEX IF NOT EXISTS idx_personalized_feed_cache_order
            ON personalized_feed_cache(feed_key, sort_order, score);

        CREATE TABLE IF NOT EXISTS personalized_feed_state (
            feed_key TEXT PRIMARY KEY,
            dirty INTEGER NOT NULL DEFAULT 1,
            refresh_status TEXT NOT NULL DEFAULT 'idle',
            refreshed_at TEXT NOT NULL DEFAULT '',
            refresh_started_at TEXT NOT NULL DEFAULT '',
            refresh_finished_at TEXT NOT NULL DEFAULT '',
            last_error TEXT NOT NULL DEFAULT '',
            profile_status TEXT NOT NULL DEFAULT '',
            profile_stats_json TEXT NOT NULL DEFAULT '{}',
            details_json TEXT NOT NULL DEFAULT '{}',
            updated_at TEXT NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_personalized_feed_state_updated
            ON personalized_feed_state(updated_at);

        CREATE TABLE IF NOT EXISTS content_sources (
            source_key TEXT PRIMARY KEY,
            domain TEXT NOT NULL DEFAULT '',
            title TEXT NOT NULL DEFAULT '',
            html_url TEXT NOT NULL DEFAULT '',
            xml_url TEXT NOT NULL DEFAULT '',
            source_kind TEXT NOT NULL DEFAULT '',
            enabled INTEGER NOT NULL DEFAULT 1,
            etag TEXT NOT NULL DEFAULT '',
            last_modified TEXT NOT NULL DEFAULT '',
            last_fetch_at TEXT NOT NULL DEFAULT '',
            last_success_at TEXT NOT NULL DEFAULT '',
            last_error TEXT NOT NULL DEFAULT '',
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_content_sources_fetch
            ON content_sources(enabled, last_fetch_at, updated_at);

        CREATE TABLE IF NOT EXISTS content_items (
            id TEXT PRIMARY KEY,
            source_key TEXT NOT NULL DEFAULT '',
            source_title TEXT NOT NULL DEFAULT '',
            source_kind TEXT NOT NULL DEFAULT '',
            domain TEXT NOT NULL DEFAULT '',
            canonical_url TEXT NOT NULL DEFAULT '',
            external_id TEXT NOT NULL DEFAULT '',
            title TEXT NOT NULL DEFAULT '',
            author TEXT NOT NULL DEFAULT '',
            summary TEXT NOT NULL DEFAULT '',
            content_text TEXT NOT NULL DEFAULT '',
            content_hash TEXT NOT NULL DEFAULT '',
            embedding BLOB NOT NULL,
            published_at TEXT NOT NULL DEFAULT '',
            discovered_at TEXT NOT NULL DEFAULT '',
            created_at TEXT NOT NULL,
            updated_at TEXT NOT NULL
        );
        CREATE UNIQUE INDEX IF NOT EXISTS idx_content_items_canonical_url
            ON content_items(canonical_url);
        CREATE INDEX IF NOT EXISTS idx_content_items_published
            ON content_items(published_at, discovered_at, updated_at);",
    )
    .context("Failed to initialize local store schema")?;

    // Migration: add source_path column to post_history if missing (pre-existing DBs).
    let has_source_path: bool = conn
        .prepare("SELECT source_path FROM post_history LIMIT 0")
        .is_ok();
    if !has_source_path {
        let _ = conn.execute_batch(
            "ALTER TABLE post_history ADD COLUMN source_path TEXT NOT NULL DEFAULT ''",
        );
    }

    ensure_column(
        conn,
        "feed_web_sources",
        "description",
        "TEXT NOT NULL DEFAULT ''",
    )?;
    ensure_column(
        conn,
        "feed_web_sources",
        "topics_csv",
        "TEXT NOT NULL DEFAULT ''",
    )?;
    ensure_column(
        conn,
        "feed_web_sources",
        "metadata_embedding",
        "BLOB NOT NULL DEFAULT X''",
    )?;
    ensure_column(
        conn,
        "personalized_feed_state",
        "generation",
        "INTEGER NOT NULL DEFAULT 0",
    )?;
    ensure_column(
        conn,
        "feed_interests",
        "keywords_override",
        "TEXT NOT NULL DEFAULT ''",
    )?;
    ensure_column(
        conn,
        "feed_interest_sources",
        "profile_input_hash",
        "TEXT NOT NULL DEFAULT ''",
    )?;
    ensure_column(
        conn,
        "feed_interest_sources",
        "triage_keywords_json",
        "TEXT NOT NULL DEFAULT ''",
    )?;
    // Polarity on feed keywords: 0 = positive (journal / liked-card), 1 =
    // negative (disliked-card). Additive migration; existing rows default to 0
    // (their pre-polarity positive-only behavior). See `FeedKeywordRecord`.
    ensure_column(
        conn,
        "feed_profile_keywords",
        "polarity",
        "INTEGER NOT NULL DEFAULT 0",
    )?;

    Ok(())
}

fn ensure_column(conn: &Connection, table: &str, column: &str, sql_type: &str) -> Result<()> {
    if column_exists(conn, table, column)? {
        return Ok(());
    }

    conn.execute_batch(&format!(
        "ALTER TABLE {table} ADD COLUMN {column} {sql_type}"
    ))
    .with_context(|| format!("Failed to add column {table}.{column}"))?;
    Ok(())
}

fn column_exists(conn: &Connection, table: &str, column: &str) -> Result<bool> {
    let mut stmt = conn
        .prepare(&format!("PRAGMA table_info({table})"))
        .with_context(|| format!("Failed to inspect schema for {}", table))?;
    let rows = stmt.query_map([], |row| row.get::<_, String>(1))?;
    for row in rows {
        if row?.eq_ignore_ascii_case(column) {
            return Ok(true);
        }
    }
    Ok(false)
}

fn table_exists(conn: &Connection, table: &str) -> Result<bool> {
    let mut stmt =
        conn.prepare("SELECT 1 FROM sqlite_master WHERE type='table' AND name=?1 LIMIT 1")?;
    let found = stmt
        .query_row(params![table], |_row| Ok(()))
        .optional()?
        .is_some();
    Ok(found)
}

fn non_empty_opt(value: String) -> Option<String> {
    let trimmed = value.trim();
    if trimmed.is_empty() {
        None
    } else {
        Some(trimmed.to_string())
    }
}

fn normalize_role(value: &str) -> &'static str {
    if value.eq_ignore_ascii_case("assistant") {
        "assistant"
    } else if value.eq_ignore_ascii_case("system") {
        "system"
    } else {
        "user"
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashMap;

    fn test_workspace() -> tempfile::TempDir {
        tempfile::tempdir().unwrap()
    }

    #[test]
    fn initialize_creates_schema() {
        let tmp = test_workspace();
        let report = initialize(tmp.path()).unwrap();
        assert!(report.db_path.exists());
        assert!(!report.migrated_from_legacy);

        let conn = open_conn(&report.db_path).unwrap();
        assert!(table_exists(&conn, "chat_messages").unwrap());
        assert!(table_exists(&conn, "drafts").unwrap());
        assert!(table_exists(&conn, "post_history").unwrap());
        assert!(table_exists(&conn, "journal_entries").unwrap());
        assert!(table_exists(&conn, "media_assets").unwrap());
        assert!(table_exists(&conn, "artifacts").unwrap());
        assert!(table_exists(&conn, "feed_interests").unwrap());
        assert!(table_exists(&conn, "feed_interest_sources").unwrap());
        assert!(table_exists(&conn, "feed_profile_keywords").unwrap());
        assert!(table_exists(&conn, "feed_lens_overrides").unwrap());
        assert!(table_exists(&conn, "feed_manual_interests").unwrap());
        assert!(table_exists(&conn, "feed_web_sources").unwrap());
        assert!(table_exists(&conn, "feed_web_cache").unwrap());
        assert!(table_exists(&conn, "personalized_feed_cache").unwrap());
        assert!(table_exists(&conn, "personalized_feed_state").unwrap());
        assert!(table_exists(&conn, "content_sources").unwrap());
        assert!(table_exists(&conn, "content_items").unwrap());
        assert!(table_exists(&conn, "journal_enrichment").unwrap());
    }

    #[test]
    fn initialize_is_idempotent() {
        let tmp = test_workspace();
        let r1 = initialize(tmp.path()).unwrap();
        let r2 = initialize(tmp.path()).unwrap();
        assert_eq!(r1.db_path, r2.db_path);
        assert!(!r2.migrated_from_legacy);
    }

    #[test]
    fn chat_message_roundtrip() {
        let tmp = test_workspace();
        initialize(tmp.path()).unwrap();

        let msg = create_chat_message(
            tmp.path(),
            "thread-1",
            "user",
            "hello world",
            "done",
            "mobile-ui",
            None,
            None,
        )
        .unwrap();
        assert_eq!(msg["role"], "user");
        assert_eq!(msg["content"], "hello world");
        assert_eq!(msg["threadId"], "thread-1");

        let msgs = list_chat_messages(tmp.path(), "thread-1", 100).unwrap();
        assert_eq!(msgs.len(), 1);
        assert_eq!(msgs[0]["content"], "hello world");

        let empty = list_chat_messages(tmp.path(), "other-thread", 100).unwrap();
        assert!(empty.is_empty());
    }

    #[test]
    fn patch_chat_status_updates_fields() {
        let tmp = test_workspace();
        initialize(tmp.path()).unwrap();

        let msg = create_chat_message(
            tmp.path(),
            "thread-1",
            "user",
            "test",
            "pending",
            "",
            None,
            None,
        )
        .unwrap();
        let id = msg["id"].as_str().unwrap();

        patch_chat_status(tmp.path(), id, "done", None).unwrap();

        let msgs = list_chat_messages(tmp.path(), "thread-1", 100).unwrap();
        assert_eq!(msgs[0]["status"], "done");
    }

    #[test]
    fn draft_upsert_and_list() {
        let tmp = test_workspace();
        initialize(tmp.path()).unwrap();

        let d1 = upsert_draft(
            tmp.path(),
            &DraftUpsert {
                id: None,
                text: "draft one".into(),
                video_name: String::new(),
                created_at_client: None,
                updated_at_client: None,
            },
        )
        .unwrap();
        assert!(!d1["id"].as_str().unwrap().is_empty());
        assert_eq!(d1["text"], "draft one");

        let drafts = list_drafts(tmp.path(), 100).unwrap();
        assert_eq!(drafts.len(), 1);

        // Update existing draft
        let id = d1["id"].as_str().unwrap().to_string();
        upsert_draft(
            tmp.path(),
            &DraftUpsert {
                id: Some(id.clone()),
                text: "updated draft".into(),
                video_name: String::new(),
                created_at_client: None,
                updated_at_client: None,
            },
        )
        .unwrap();

        let drafts = list_drafts(tmp.path(), 100).unwrap();
        assert_eq!(drafts.len(), 1);
        assert_eq!(drafts[0]["text"], "updated draft");
    }

    #[test]
    fn post_history_roundtrip() {
        let tmp = test_workspace();
        initialize(tmp.path()).unwrap();

        create_post_history(
            tmp.path(),
            &PostHistoryInput {
                provider: "bluesky".into(),
                text: "posted text".into(),
                video_name: String::new(),
                source_path: "posts/digest/2026-03-03.md".into(),
                uri: "at://did:example/post/1".into(),
                cid: "bafyabc".into(),
                status: "success".into(),
                error: String::new(),
                created_at_client: None,
            },
        )
        .unwrap();

        let history = list_post_history(tmp.path(), 100).unwrap();
        assert_eq!(history.len(), 1);
        assert_eq!(history[0]["text"], "posted text");
        assert_eq!(history[0]["provider"], "bluesky");
        assert_eq!(history[0]["status"], "success");
        assert_eq!(history[0]["sourcePath"], "posts/digest/2026-03-03.md");
    }

    #[test]
    fn workspace_todos_roundtrip_and_override() {
        let tmp = test_workspace();
        initialize(tmp.path()).unwrap();

        let written = replace_workspace_todos(
            tmp.path(),
            &[WorkspaceTodoUpsert {
                id: "todo-follow-up".into(),
                title: "Send follow-up".into(),
                details: "Email the partner after the review".into(),
                priority: "high".into(),
                model_status: "open".into(),
                due_at: "2026-03-12".into(),
                source_path: "journals/text/2026-03-11.md".into(),
                source_excerpt: "Need to send a follow-up tomorrow.".into(),
                metadata_json: "{\"kind\":\"todo\"}".into(),
            }],
            "manifest-1",
            &["journals/text/2026-03-11.md".into()],
        )
        .unwrap();
        assert_eq!(written, 1);

        let todos = list_workspace_todos(tmp.path(), 20).unwrap();
        assert_eq!(todos.len(), 1);
        assert_eq!(todos[0]["status"], "open");
        assert_eq!(todos[0]["priority"], "high");

        let updated = update_workspace_todo_status(
            tmp.path(),
            &WorkspaceTodoStatusUpdate {
                id: "todo-follow-up".into(),
                status_override: "done".into(),
            },
        )
        .unwrap();
        assert_eq!(updated["status"], "done");

        let todos = list_workspace_todos(tmp.path(), 20).unwrap();
        assert_eq!(todos[0]["status"], "done");

        replace_workspace_todos(
            tmp.path(),
            &[],
            "manifest-2",
            &["journals/text/2026-03-11.md".into()],
        )
        .unwrap();
        let todos = list_workspace_todos(tmp.path(), 20).unwrap();
        assert_eq!(todos.len(), 1);
        assert_eq!(todos[0]["id"].as_str(), Some("todo-follow-up"));
        assert_eq!(todos[0]["status"].as_str(), Some("done"));
    }

    #[test]
    fn workspace_todos_preserve_other_sources_when_replacing_subset() {
        let tmp = test_workspace();
        initialize(tmp.path()).unwrap();

        replace_workspace_todos(
            tmp.path(),
            &[
                WorkspaceTodoUpsert {
                    id: "todo-a".into(),
                    title: "Todo A".into(),
                    details: String::new(),
                    priority: "medium".into(),
                    model_status: "open".into(),
                    due_at: String::new(),
                    source_path: "journals/text/a.md".into(),
                    source_excerpt: "A".into(),
                    metadata_json: "{}".into(),
                },
                WorkspaceTodoUpsert {
                    id: "todo-b".into(),
                    title: "Todo B".into(),
                    details: String::new(),
                    priority: "medium".into(),
                    model_status: "open".into(),
                    due_at: String::new(),
                    source_path: "journals/text/b.md".into(),
                    source_excerpt: "B".into(),
                    metadata_json: "{}".into(),
                },
            ],
            "manifest-1",
            &["journals/text/a.md".into(), "journals/text/b.md".into()],
        )
        .unwrap();

        replace_workspace_todos(
            tmp.path(),
            &[WorkspaceTodoUpsert {
                id: "todo-a-2".into(),
                title: "Todo A2".into(),
                details: String::new(),
                priority: "medium".into(),
                model_status: "open".into(),
                due_at: String::new(),
                source_path: "journals/text/a.md".into(),
                source_excerpt: "A2".into(),
                metadata_json: "{}".into(),
            }],
            "manifest-2",
            &["journals/text/a.md".into()],
        )
        .unwrap();

        let todos = list_workspace_todos(tmp.path(), 20).unwrap();
        assert_eq!(todos.len(), 3);
        assert!(todos.iter().any(|item| item["id"] == "todo-a-2"));
        assert!(todos.iter().any(|item| item["id"] == "todo-b"));
        assert!(todos.iter().any(|item| item["id"] == "todo-a"));
    }

    #[test]
    fn workspace_todos_do_not_unarchive_on_reextract() {
        let tmp = test_workspace();
        initialize(tmp.path()).unwrap();

        replace_workspace_todos(
            tmp.path(),
            &[WorkspaceTodoUpsert {
                id: "todo-archive".into(),
                title: "Archive me".into(),
                details: String::new(),
                priority: "medium".into(),
                model_status: "open".into(),
                due_at: String::new(),
                source_path: "journals/text/archive.md".into(),
                source_excerpt: "Archive me".into(),
                metadata_json: "{}".into(),
            }],
            "manifest-1",
            &["journals/text/archive.md".into()],
        )
        .unwrap();

        let conn = open_conn(&db_path(tmp.path())).unwrap();
        conn.execute(
            "UPDATE workspace_todos SET archived = 1 WHERE id = ?1",
            params!["todo-archive"],
        )
        .unwrap();

        replace_workspace_todos(
            tmp.path(),
            &[WorkspaceTodoUpsert {
                id: "todo-archive".into(),
                title: "Archive me".into(),
                details: "Still archived".into(),
                priority: "high".into(),
                model_status: "open".into(),
                due_at: String::new(),
                source_path: "journals/text/archive.md".into(),
                source_excerpt: "Archive me again".into(),
                metadata_json: "{\"kind\":\"todo\"}".into(),
            }],
            "manifest-2",
            &["journals/text/archive.md".into()],
        )
        .unwrap();

        assert!(list_workspace_todos(tmp.path(), 20).unwrap().is_empty());
    }

    #[test]
    fn workspace_todos_skip_updated_at_churn_when_meaningful_fields_match() {
        let tmp = test_workspace();
        initialize(tmp.path()).unwrap();

        replace_workspace_todos(
            tmp.path(),
            &[WorkspaceTodoUpsert {
                id: "todo-stable".into(),
                title: "Stable todo".into(),
                details: "Keep it steady".into(),
                priority: "medium".into(),
                model_status: "open".into(),
                due_at: "2026-03-12".into(),
                source_path: "journals/text/stable.md".into(),
                source_excerpt: "First excerpt".into(),
                metadata_json: "{\"version\":1}".into(),
            }],
            "manifest-1",
            &["journals/text/stable.md".into()],
        )
        .unwrap();

        let initial = list_workspace_todos(tmp.path(), 20).unwrap();
        let initial_updated = initial[0]["updated"].as_str().unwrap().to_string();

        std::thread::sleep(std::time::Duration::from_millis(5));

        replace_workspace_todos(
            tmp.path(),
            &[WorkspaceTodoUpsert {
                id: "todo-stable".into(),
                title: "Stable todo".into(),
                details: "Keep it steady".into(),
                priority: "medium".into(),
                model_status: "open".into(),
                due_at: "2026-03-12".into(),
                source_path: "journals/text/stable.md".into(),
                source_excerpt: "Edited excerpt should not churn".into(),
                metadata_json: "{\"version\":2}".into(),
            }],
            "manifest-2",
            &["journals/text/stable.md".into()],
        )
        .unwrap();

        let after = list_workspace_todos(tmp.path(), 20).unwrap();
        assert_eq!(after[0]["updated"].as_str(), Some(initial_updated.as_str()));
    }

    #[test]
    fn workspace_events_roundtrip() {
        let tmp = test_workspace();
        initialize(tmp.path()).unwrap();

        let written = replace_workspace_events(
            tmp.path(),
            &[WorkspaceEventUpsert {
                id: "event-launch-review".into(),
                title: "Launch review".into(),
                details: "Review the launch checklist".into(),
                location: "Berlin".into(),
                status: "confirmed".into(),
                start_at: "2026-03-12T09:00:00Z".into(),
                end_at: "2026-03-12T10:00:00Z".into(),
                all_day: false,
                source_path: "journals/text/2026-03-11.md".into(),
                source_excerpt: "Launch review tomorrow at 9.".into(),
                metadata_json: "{\"kind\":\"event\"}".into(),
            }],
            "manifest-1",
            &["journals/text/2026-03-11.md".into()],
        )
        .unwrap();
        assert_eq!(written, 1);

        let events = list_workspace_events(tmp.path(), 20).unwrap();
        assert_eq!(events.len(), 1);
        assert_eq!(events[0]["title"], "Launch review");
        assert_eq!(events[0]["status"], "confirmed");

        replace_workspace_events(
            tmp.path(),
            &[],
            "manifest-2",
            &["journals/text/2026-03-11.md".into()],
        )
        .unwrap();
        let events = list_workspace_events(tmp.path(), 20).unwrap();
        assert_eq!(events.len(), 1);
        assert_eq!(events[0]["id"].as_str(), Some("event-launch-review"));
    }

    #[test]
    fn workspace_events_preserve_other_sources_when_replacing_subset() {
        let tmp = test_workspace();
        initialize(tmp.path()).unwrap();

        replace_workspace_events(
            tmp.path(),
            &[
                WorkspaceEventUpsert {
                    id: "event-a".into(),
                    title: "Event A".into(),
                    details: String::new(),
                    location: String::new(),
                    status: "confirmed".into(),
                    start_at: "2026-03-12T09:00:00Z".into(),
                    end_at: String::new(),
                    all_day: false,
                    source_path: "journals/text/a.md".into(),
                    source_excerpt: "A".into(),
                    metadata_json: "{}".into(),
                },
                WorkspaceEventUpsert {
                    id: "event-b".into(),
                    title: "Event B".into(),
                    details: String::new(),
                    location: String::new(),
                    status: "confirmed".into(),
                    start_at: "2026-03-13T09:00:00Z".into(),
                    end_at: String::new(),
                    all_day: false,
                    source_path: "journals/text/b.md".into(),
                    source_excerpt: "B".into(),
                    metadata_json: "{}".into(),
                },
            ],
            "manifest-1",
            &["journals/text/a.md".into(), "journals/text/b.md".into()],
        )
        .unwrap();

        replace_workspace_events(
            tmp.path(),
            &[WorkspaceEventUpsert {
                id: "event-a-2".into(),
                title: "Event A2".into(),
                details: String::new(),
                location: String::new(),
                status: "confirmed".into(),
                start_at: "2026-03-14T09:00:00Z".into(),
                end_at: String::new(),
                all_day: false,
                source_path: "journals/text/a.md".into(),
                source_excerpt: "A2".into(),
                metadata_json: "{}".into(),
            }],
            "manifest-2",
            &["journals/text/a.md".into()],
        )
        .unwrap();

        let events = list_workspace_events(tmp.path(), 20).unwrap();
        assert_eq!(events.len(), 3);
        assert!(events.iter().any(|item| item["id"] == "event-a-2"));
        assert!(events.iter().any(|item| item["id"] == "event-b"));
        assert!(events.iter().any(|item| item["id"] == "event-a"));
    }

    #[test]
    fn workspace_events_do_not_unarchive_on_reextract() {
        let tmp = test_workspace();
        initialize(tmp.path()).unwrap();

        replace_workspace_events(
            tmp.path(),
            &[WorkspaceEventUpsert {
                id: "event-archive".into(),
                title: "Archive event".into(),
                details: String::new(),
                location: String::new(),
                status: "confirmed".into(),
                start_at: "2026-03-12T09:00:00Z".into(),
                end_at: String::new(),
                all_day: false,
                source_path: "journals/text/archive-event.md".into(),
                source_excerpt: "Archive this event".into(),
                metadata_json: "{}".into(),
            }],
            "manifest-1",
            &["journals/text/archive-event.md".into()],
        )
        .unwrap();

        let conn = open_conn(&db_path(tmp.path())).unwrap();
        conn.execute(
            "UPDATE workspace_events SET archived = 1 WHERE id = ?1",
            params!["event-archive"],
        )
        .unwrap();

        replace_workspace_events(
            tmp.path(),
            &[WorkspaceEventUpsert {
                id: "event-archive".into(),
                title: "Archive event".into(),
                details: "Still archived".into(),
                location: "Berlin".into(),
                status: "confirmed".into(),
                start_at: "2026-03-12T09:00:00Z".into(),
                end_at: String::new(),
                all_day: false,
                source_path: "journals/text/archive-event.md".into(),
                source_excerpt: "Archive this event again".into(),
                metadata_json: "{\"kind\":\"event\"}".into(),
            }],
            "manifest-2",
            &["journals/text/archive-event.md".into()],
        )
        .unwrap();

        assert!(list_workspace_events(tmp.path(), 20).unwrap().is_empty());
    }

    #[test]
    fn workspace_events_skip_updated_at_churn_when_meaningful_fields_match() {
        let tmp = test_workspace();
        initialize(tmp.path()).unwrap();

        replace_workspace_events(
            tmp.path(),
            &[WorkspaceEventUpsert {
                id: "event-stable".into(),
                title: "Stable event".into(),
                details: "Agenda".into(),
                location: "Berlin".into(),
                status: "confirmed".into(),
                start_at: "2026-03-12T09:00:00Z".into(),
                end_at: "2026-03-12T10:00:00Z".into(),
                all_day: false,
                source_path: "journals/text/stable-event.md".into(),
                source_excerpt: "First event excerpt".into(),
                metadata_json: "{\"version\":1}".into(),
            }],
            "manifest-1",
            &["journals/text/stable-event.md".into()],
        )
        .unwrap();

        let initial = list_workspace_events(tmp.path(), 20).unwrap();
        let initial_updated = initial[0]["updated"].as_str().unwrap().to_string();

        std::thread::sleep(std::time::Duration::from_millis(5));

        replace_workspace_events(
            tmp.path(),
            &[WorkspaceEventUpsert {
                id: "event-stable".into(),
                title: "Stable event".into(),
                details: "Agenda".into(),
                location: "Berlin".into(),
                status: "confirmed".into(),
                start_at: "2026-03-12T09:00:00Z".into(),
                end_at: "2026-03-12T10:00:00Z".into(),
                all_day: false,
                source_path: "journals/text/stable-event.md".into(),
                source_excerpt: "Edited event excerpt should not churn".into(),
                metadata_json: "{\"version\":2}".into(),
            }],
            "manifest-2",
            &["journals/text/stable-event.md".into()],
        )
        .unwrap();

        let after = list_workspace_events(tmp.path(), 20).unwrap();
        assert_eq!(after[0]["updated"].as_str(), Some(initial_updated.as_str()));
    }

    #[test]
    fn journal_entry_metadata_roundtrip() {
        let tmp = test_workspace();
        initialize(tmp.path()).unwrap();

        let entry = create_journal_entry_metadata(
            tmp.path(),
            &JournalEntryInput {
                title: "test entry".into(),
                entry_type: "text".into(),
                source: "mobile-ui".into(),
                status: "ready".into(),
                workspace_path: "journals/2026-03-03/entry.md".into(),
                preview_text: "preview".into(),
                text_body: "full body".into(),
                tags_csv: "tag1,tag2".into(),
                created_at_client: None,
            },
        )
        .unwrap();
        assert_eq!(entry["title"], "test entry");
        assert_eq!(entry["entryType"], "text");
    }

    #[test]
    fn media_asset_metadata_stores_size_as_integer() {
        let tmp = test_workspace();
        initialize(tmp.path()).unwrap();

        let asset = create_media_asset_metadata(
            tmp.path(),
            &MediaAssetInput {
                title: "recording.mp4".into(),
                entry_id: String::new(),
                asset_type: "video".into(),
                mime_type: "video/mp4".into(),
                source: "mobile-ui".into(),
                status: "uploaded".into(),
                workspace_path: "journals/media/recording.mp4".into(),
                size_bytes: 1_048_576,
                created_at_client: None,
            },
        )
        .unwrap();
        assert_eq!(asset["sizeBytes"], 1_048_576);
        assert!(asset["sizeBytes"].is_i64());
    }

    #[test]
    fn normalize_role_maps_correctly() {
        assert_eq!(normalize_role("user"), "user");
        assert_eq!(normalize_role("assistant"), "assistant");
        assert_eq!(normalize_role("ASSISTANT"), "assistant");
        assert_eq!(normalize_role("system"), "system");
        assert_eq!(normalize_role("SYSTEM"), "system");
        assert_eq!(normalize_role("unknown"), "user");
        assert_eq!(normalize_role(""), "user");
    }

    #[test]
    fn non_empty_opt_trims_and_filters() {
        assert_eq!(non_empty_opt("hello".into()), Some("hello".into()));
        assert_eq!(non_empty_opt("  spaced  ".into()), Some("spaced".into()));
        assert_eq!(non_empty_opt(String::new()), None);
        assert_eq!(non_empty_opt("   ".into()), None);
    }

    #[test]
    fn feed_interest_roundtrip() {
        let tmp = test_workspace();
        initialize(tmp.path()).unwrap();

        let interest = upsert_feed_interest(
            tmp.path(),
            &FeedInterestUpsert {
                id: None,
                label: "Machine Learning".into(),
                source_path: "posts/ml/one.md".into(),
                embedding: vec![1, 2, 3, 4],
                health_score: 0.8,
                last_seen_at: "2026-03-09T12:00:00Z".into(),
            },
        )
        .unwrap();
        assert_eq!(interest.label, "Machine Learning");

        let interests = list_feed_interests(tmp.path()).unwrap();
        assert_eq!(interests.len(), 1);
        assert_eq!(interests[0].source_path, "posts/ml/one.md");

        let decayed = decay_feed_interests(tmp.path(), 0.95).unwrap();
        assert_eq!(decayed, 1);
        let interests = list_feed_interests(tmp.path()).unwrap();
        assert!(interests[0].health_score < 0.8);
    }

    #[test]
    fn delete_feed_interest_removes_row() {
        let tmp = test_workspace();
        initialize(tmp.path()).unwrap();

        let interest = upsert_feed_interest(
            tmp.path(),
            &FeedInterestUpsert {
                id: None,
                label: "Test Interest".into(),
                source_path: "state/world_feed_diagnostics/dummy/test.md".into(),
                embedding: vec![1, 2, 3, 4],
                health_score: 0.7,
                last_seen_at: "2026-03-09T12:00:00Z".into(),
            },
        )
        .unwrap();

        assert!(delete_feed_interest(tmp.path(), &interest.id).unwrap());
        assert!(list_feed_interests(tmp.path()).unwrap().is_empty());
    }

    #[test]
    fn feed_interest_source_roundtrip() {
        let tmp = test_workspace();
        initialize(tmp.path()).unwrap();

        upsert_feed_interest_source(
            tmp.path(),
            &FeedInterestSourceRecord {
                source_path: "posts/ml/one.md".into(),
                content_hash: "abc123".into(),
                profile_input_hash: "profile123".into(),
                interest_id: Some("interest-1".into()),
                title: "Machine Learning".into(),
                triage_keywords_json: "[\"machine learning\",\"ranking\"]".into(),
                updated_at: "2026-03-09T12:00:00Z".into(),
            },
        )
        .unwrap();

        let source = get_feed_interest_source(tmp.path(), "posts/ml/one.md").unwrap();
        let source = source.expect("source record should exist");
        assert_eq!(source.content_hash, "abc123");
        assert_eq!(source.profile_input_hash, "profile123");
        assert_eq!(source.interest_id.as_deref(), Some("interest-1"));
        assert_eq!(
            source.triage_keywords_json,
            "[\"machine learning\",\"ranking\"]"
        );
    }

    #[test]
    fn feed_web_source_roundtrip() {
        let tmp = test_workspace();
        initialize(tmp.path()).unwrap();

        upsert_feed_web_source(
            tmp.path(),
            &FeedWebSourceUpsert {
                domain: "example.com".into(),
                title: "Example".into(),
                html_url: "https://example.com".into(),
                xml_url: "https://example.com/feed.xml".into(),
                description: "Example source".into(),
                topics_csv: "testing,feeds".into(),
                metadata_embedding: vec![1, 2, 3, 4],
                enabled: true,
                source_kind: "seed".into(),
            },
        )
        .unwrap();

        let sources = list_feed_web_sources(tmp.path()).unwrap();
        assert_eq!(sources.len(), 1);
        assert_eq!(sources[0].domain, "example.com");
        assert_eq!(sources[0].topics_csv, "testing,feeds");
        assert_eq!(sources[0].metadata_embedding, vec![1, 2, 3, 4]);
    }

    #[test]
    fn feed_web_cache_roundtrip() {
        let tmp = test_workspace();
        initialize(tmp.path()).unwrap();

        upsert_feed_web_cache(
            tmp.path(),
            &FeedWebCacheUpsert {
                url: "https://example.com/post".into(),
                domain: "example.com".into(),
                title: "Example".into(),
                description: "Desc".into(),
                image_url: "https://example.com/image.png".into(),
                provider: "duckduckgo".into(),
                snippet: "Snippet".into(),
                search_query: "test query".into(),
                fetched_at: "2026-03-10T10:00:00Z".into(),
            },
        )
        .unwrap();

        let cached = get_feed_web_cache(tmp.path(), "https://example.com/post").unwrap();
        let cached = cached.expect("cache should exist");
        assert_eq!(cached.domain, "example.com");
        assert_eq!(cached.title, "Example");
    }

    #[test]
    fn content_source_roundtrip() {
        let tmp = test_workspace();
        initialize(tmp.path()).unwrap();

        upsert_content_source(
            tmp.path(),
            &ContentSourceUpsert {
                source_key: "https://example.com/feed.xml".into(),
                domain: "example.com".into(),
                title: "Example Feed".into(),
                html_url: "https://example.com".into(),
                xml_url: "https://example.com/feed.xml".into(),
                source_kind: "rss".into(),
                enabled: true,
            },
        )
        .unwrap();

        update_content_source_fetch(
            tmp.path(),
            "https://example.com/feed.xml",
            "2026-03-10T10:00:00Z",
            Some("etag-1"),
            Some("Wed, 10 Mar 2026 10:00:00 GMT"),
            None,
            true,
        )
        .unwrap();

        let sources = list_content_sources(tmp.path(), 10).unwrap();
        assert_eq!(sources.len(), 1);
        assert_eq!(sources[0].source_key, "https://example.com/feed.xml");
        assert_eq!(sources[0].etag, "etag-1");
    }

    #[test]
    fn content_item_roundtrip() {
        let tmp = test_workspace();
        initialize(tmp.path()).unwrap();

        upsert_content_item(
            tmp.path(),
            &ContentItemUpsert {
                id: "item-1".into(),
                source_key: "https://example.com/feed.xml".into(),
                source_title: "Example Feed".into(),
                source_kind: "rss".into(),
                domain: "example.com".into(),
                canonical_url: "https://example.com/posts/1".into(),
                external_id: "guid-1".into(),
                title: "First post".into(),
                author: "Example Author".into(),
                summary: "Summary".into(),
                content_text: "Body".into(),
                content_hash: "hash-1".into(),
                embedding: vec![1, 2, 3, 4],
                published_at: "2026-03-10T10:00:00Z".into(),
                discovered_at: "2026-03-10T10:05:00Z".into(),
            },
        )
        .unwrap();

        let items = list_recent_content_items(tmp.path(), 10).unwrap();
        assert_eq!(items.len(), 1);
        assert_eq!(items[0].canonical_url, "https://example.com/posts/1");
        assert_eq!(items[0].source_title, "Example Feed");
    }

    #[test]
    fn content_item_embedding_backfill_queries_only_missing_rows() {
        let tmp = test_workspace();
        initialize(tmp.path()).unwrap();

        upsert_content_item(
            tmp.path(),
            &ContentItemUpsert {
                id: "item-missing".into(),
                source_key: "https://example.com/feed.xml".into(),
                source_title: "Example Feed".into(),
                source_kind: "rss".into(),
                domain: "example.com".into(),
                canonical_url: "https://example.com/posts/missing".into(),
                external_id: "guid-missing".into(),
                title: "Missing vector".into(),
                author: "Example Author".into(),
                summary: "Summary".into(),
                content_text: "Needs embedding".into(),
                content_hash: "hash-missing".into(),
                embedding: Vec::new(),
                published_at: "2026-03-10T10:00:00Z".into(),
                discovered_at: "2026-03-10T10:05:00Z".into(),
            },
        )
        .unwrap();
        upsert_content_item(
            tmp.path(),
            &ContentItemUpsert {
                id: "item-complete".into(),
                source_key: "https://example.com/feed.xml".into(),
                source_title: "Example Feed".into(),
                source_kind: "rss".into(),
                domain: "example.com".into(),
                canonical_url: "https://example.com/posts/complete".into(),
                external_id: "guid-complete".into(),
                title: "Has vector".into(),
                author: "Example Author".into(),
                summary: "Summary".into(),
                content_text: "Already embedded".into(),
                content_hash: "hash-complete".into(),
                embedding: vec![1, 2, 3, 4],
                published_at: "2026-03-09T10:00:00Z".into(),
                discovered_at: "2026-03-09T10:05:00Z".into(),
            },
        )
        .unwrap();

        let missing = list_content_items_missing_embeddings(tmp.path(), 10).unwrap();
        assert_eq!(missing.len(), 1);
        assert_eq!(missing[0].id, "item-missing");

        update_content_item_embedding(tmp.path(), "item-missing", &[9, 8, 7, 6]).unwrap();
        let missing_after = list_content_items_missing_embeddings(tmp.path(), 10).unwrap();
        assert!(missing_after.is_empty());
    }

    #[test]
    fn personalized_feed_cache_and_state_roundtrip() {
        let tmp = test_workspace();
        initialize(tmp.path()).unwrap();

        replace_personalized_feed_cache(
            tmp.path(),
            "world",
            &[PersonalizedFeedCacheUpsert {
                feed_key: "world".into(),
                cache_key: "item-1".into(),
                payload_json: "{\"sourceType\":\"web\"}".into(),
                score: 0.87,
                sort_order: 0,
                refreshed_at: "2026-03-13T10:00:00Z".into(),
            }],
        )
        .unwrap();
        upsert_personalized_feed_state(
            tmp.path(),
            &PersonalizedFeedStateUpsert {
                feed_key: "world".into(),
                dirty: false,
                refresh_status: "idle".into(),
                refreshed_at: "2026-03-13T10:00:00Z".into(),
                refresh_started_at: "2026-03-13T09:59:00Z".into(),
                refresh_finished_at: "2026-03-13T10:00:00Z".into(),
                last_error: String::new(),
                profile_status: "ready".into(),
                profile_stats_json: "{\"interestCount\":2}".into(),
                details_json: "{\"selectedSources\":[]}".into(),
            },
        )
        .unwrap();

        let cache = list_personalized_feed_cache(tmp.path(), "world", 10).unwrap();
        assert_eq!(cache.len(), 1);
        assert_eq!(cache[0].cache_key, "item-1");

        let state = get_personalized_feed_state(tmp.path(), "world")
            .unwrap()
            .expect("feed state should exist");
        assert_eq!(state.refresh_status, "idle");
        assert_eq!(state.profile_status, "ready");

        mark_personalized_feed_dirty(tmp.path(), "world").unwrap();
        let dirty_state = get_personalized_feed_state(tmp.path(), "world")
            .unwrap()
            .expect("dirty state should exist");
        assert!(dirty_state.dirty);
    }

    fn upsert_test_keyword(workspace: &Path, term: &str, weight: f64, polarity: i64) {
        let now = "2026-03-12T12:00:00Z";
        upsert_feed_keyword(
            workspace,
            &FeedKeywordUpsert {
                id: None,
                term: term.into(),
                weight,
                first_seen_at: now.into(),
                last_seen_at: now.into(),
                source_count: 1,
                polarity,
            },
        )
        .unwrap();
    }

    #[test]
    fn feed_keyword_polarity_roundtrip() {
        let tmp = test_workspace();
        initialize(tmp.path()).unwrap();

        upsert_test_keyword(tmp.path(), "ranking", 2.0, 0);
        upsert_test_keyword(tmp.path(), "celebrity gossip", 1.0, 1);

        let all = list_feed_keywords(tmp.path()).unwrap();
        assert_eq!(all.len(), 2);

        let pos = list_feed_keywords_by_polarity(tmp.path(), 0).unwrap();
        let neg = list_feed_keywords_by_polarity(tmp.path(), 1).unwrap();
        assert_eq!(pos.len(), 1);
        assert_eq!(pos[0].term, "ranking");
        assert_eq!(pos[0].polarity, 0);
        assert_eq!(neg.len(), 1);
        assert_eq!(neg[0].term, "celebrity gossip");
        assert_eq!(neg[0].polarity, 1);
    }

    #[test]
    fn decay_skips_disliked_keywords() {
        let tmp = test_workspace();
        initialize(tmp.path()).unwrap();

        upsert_test_keyword(tmp.path(), "ranking", 2.0, 0);
        upsert_test_keyword(tmp.path(), "celebrity gossip", 2.0, 1);

        let decayed = decay_feed_keywords(tmp.path(), 0.5).unwrap();
        // Only the positive row should have been touched.
        assert_eq!(decayed, 1);

        let all: HashMap<String, FeedKeywordRecord> = list_feed_keywords(tmp.path())
            .unwrap()
            .into_iter()
            .map(|r| (r.term.clone(), r))
            .collect();
        assert!((all["ranking"].weight - 1.0).abs() < 1e-9); // decayed
        assert!((all["celebrity gossip"].weight - 2.0).abs() < 1e-9); // untouched
    }

    #[test]
    fn prune_keeps_disliked_below_floor() {
        let tmp = test_workspace();
        initialize(tmp.path()).unwrap();

        // Positive keyword that has decayed below the prune floor → pruned.
        upsert_test_keyword(tmp.path(), "ranking", 0.05, 0);
        // Disliked keyword below the floor → must survive (no decay means the
        // floor is meaningless for it; bounded only by keep_limit).
        upsert_test_keyword(tmp.path(), "celebrity gossip", 0.02, 1);

        let removed = prune_feed_keywords(tmp.path(), 0.1, 300).unwrap();
        assert_eq!(removed, 1);

        let remaining: Vec<String> = list_feed_keywords(tmp.path())
            .unwrap()
            .into_iter()
            .map(|r| r.term)
            .collect();
        assert!(remaining.contains(&"celebrity gossip".to_string()));
        assert!(!remaining.contains(&"ranking".to_string()));
    }

    #[test]
    fn feed_lens_override_roundtrip() {
        let tmp = test_workspace();
        initialize(tmp.path()).unwrap();

        set_feed_lens_override(tmp.path(), "Philosophy", 2.0).unwrap();
        set_feed_lens_override(tmp.path(), "  Spam  ", 0.0).unwrap();

        let overrides = list_feed_lens_overrides(tmp.path()).unwrap();
        assert_eq!(overrides.len(), 2);
        // Terms are normalized to lowercase on write.
        let by_term: HashMap<String, f64> = overrides
            .into_iter()
            .map(|o| (o.term, o.multiplier))
            .collect();
        assert!((by_term["philosophy"] - 2.0).abs() < 1e-9);
        assert!((by_term["spam"] - 0.0).abs() < 1e-9);

        // Upsert replaces, not appends.
        set_feed_lens_override(tmp.path(), "philosophy", 1.0).unwrap();
        assert_eq!(list_feed_lens_overrides(tmp.path()).unwrap().len(), 2);

        assert!(remove_feed_lens_override(tmp.path(), "SPAM").unwrap());
        assert_eq!(list_feed_lens_overrides(tmp.path()).unwrap().len(), 1);
    }

    #[test]
    fn feed_manual_interest_roundtrip() {
        let tmp = test_workspace();
        initialize(tmp.path()).unwrap();

        assert!(add_feed_manual_interest(tmp.path(), "Existentialism").unwrap());
        // Re-adding the same term (even different case) is a no-op.
        assert!(!add_feed_manual_interest(tmp.path(), "  existentialism  ").unwrap());
        assert!(add_feed_manual_interest(tmp.path(), "Stoicism").unwrap());

        let interests = list_feed_manual_interests(tmp.path()).unwrap();
        assert_eq!(interests.len(), 2);
        let terms: Vec<String> = interests.into_iter().map(|i| i.term).collect();
        assert!(terms.contains(&"existentialism".to_string()));
        assert!(terms.contains(&"stoicism".to_string()));

        assert!(remove_feed_manual_interest(tmp.path(), "stoicism").unwrap());
        assert_eq!(list_feed_manual_interests(tmp.path()).unwrap().len(), 1);
    }

    #[test]
    fn journal_enrichment_converges() {
        // The convergence contract: ensure seeds pending rows; set moves them
        // terminal; list_pending stops returning them; get shows the full map.
        let tmp = test_workspace();
        initialize(tmp.path()).unwrap();
        let path = "journals/2026-07-13/converges.md";

        let tasks = ["transcription", "title", "interests", "tweet"];
        // Seed — idempotent: re-seeding must NOT reset progress.
        ensure_journal_enrichment(tmp.path(), path, &tasks).unwrap();
        ensure_journal_enrichment(tmp.path(), path, &tasks).unwrap();
        let all = get_journal_enrichment(tmp.path(), path).unwrap();
        assert_eq!(all.len(), 4);
        assert!(all.iter().all(|r| r.status == "pending" && r.attempts == 0));

        // All four are pending work.
        let pending = list_pending_journal_enrichment(tmp.path(), 64).unwrap();
        assert_eq!(pending.len(), 4);

        // Drive three to done, one to error — simulating a loop pass each.
        set_journal_enrichment(tmp.path(), path, "transcription", "done", None).unwrap();
        set_journal_enrichment(tmp.path(), path, "title", "done", None).unwrap();
        set_journal_enrichment(tmp.path(), path, "interests", "done", None).unwrap();
        set_journal_enrichment(tmp.path(), path, "tweet", "error", Some("no output")).unwrap();

        // The errored task is terminal `error`, so the work queue is now EMPTY.
        // That is convergence: terminal rows leave the queue regardless of
        // success/error/skip.
        let pending_after = list_pending_journal_enrichment(tmp.path(), 64).unwrap();
        assert!(
            pending_after.is_empty(),
            "terminal tasks must leave the queue"
        );

        // attempts only bumps on non-done writes (the error task, once).
        let tweet_row = get_journal_enrichment(tmp.path(), path)
            .unwrap()
            .into_iter()
            .find(|r| r.task == "tweet")
            .unwrap();
        assert_eq!(tweet_row.status, "error");
        assert_eq!(tweet_row.attempts, 1);
        assert_eq!(tweet_row.last_error, "no output");

        // A retry bumps attempts again and clears the error.
        set_journal_enrichment(tmp.path(), path, "tweet", "done", None).unwrap();
        let tweet_after = get_journal_enrichment(tmp.path(), path)
            .unwrap()
            .into_iter()
            .find(|r| r.task == "tweet")
            .unwrap();
        assert_eq!(tweet_after.status, "done");
        assert_eq!(tweet_after.attempts, 1); // done does not bump
        assert_eq!(tweet_after.last_error, ""); // cleared on success

        // list_all returns every row for the panel.
        assert_eq!(list_all_journal_enrichment(tmp.path()).unwrap().len(), 4);

        // Deleting the journal cleans up its rows.
        delete_journal_enrichment(tmp.path(), path).unwrap();
        assert!(get_journal_enrichment(tmp.path(), path).unwrap().is_empty());
        assert!(list_all_journal_enrichment(tmp.path()).unwrap().is_empty());
    }
}
