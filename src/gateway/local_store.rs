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
pub struct ContentJobInput {
    pub operation_key: String,
    pub target_id: String,
    pub target_path: String,
    pub input_json: String,
    pub status: String,
    pub progress_label: String,
    pub error: String,
    pub created_at_client: Option<String>,
}

#[derive(Debug, Clone)]
pub struct ArtifactInput {
    pub parent_asset_id: String,
    pub parent_entry_id: String,
    pub artifact_type: String,
    pub title: String,
    pub status: String,
    pub mime_type: String,
    pub workspace_path: String,
    pub preview_text: String,
    pub metadata_json: String,
    pub created_at_client: Option<String>,
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

pub fn list_chat_messages(workspace_dir: &Path, thread_id: &str, limit: usize) -> Result<Vec<serde_json::Value>> {
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

pub fn create_post_history(workspace_dir: &Path, item: &PostHistoryInput) -> Result<serde_json::Value> {
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
            tags_csv, created_at_client, created, updated
         ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?11)",
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
        "created": created,
        "updated": created,
    }))
}

pub fn list_journal_entries(
    workspace_dir: &Path,
    limit: usize,
    offset: usize,
) -> Result<Vec<serde_json::Value>> {
    let conn = open_conn(&db_path(workspace_dir))?;
    let lim = i64::try_from(limit.max(1)).unwrap_or(200);
    let off = i64::try_from(offset).unwrap_or(0);
    let mut stmt = conn.prepare(
        "SELECT id, title, entry_type, status, workspace_path, preview_text, text_body,
                created_at_client, created, updated
         FROM journal_entries
         ORDER BY COALESCE(NULLIF(created_at_client, ''), updated, created) DESC, id DESC
         LIMIT ?1 OFFSET ?2",
    )?;
    let rows = stmt.query_map(params![lim, off], |row| {
        Ok(serde_json::json!({
            "id": row.get::<_, String>(0)?,
            "title": row.get::<_, String>(1)?,
            "entryType": row.get::<_, String>(2)?,
            "status": row.get::<_, String>(3)?,
            "workspacePath": row.get::<_, String>(4)?,
            "previewText": row.get::<_, String>(5)?,
            "textBody": row.get::<_, String>(6)?,
            "createdAtClient": row.get::<_, String>(7)?,
            "created": row.get::<_, String>(8)?,
            "updated": row.get::<_, String>(9)?,
        }))
    })?;

    let mut out = Vec::new();
    for row in rows {
        out.push(row?);
    }
    Ok(out)
}

pub fn get_journal_entry(workspace_dir: &Path, id: &str) -> Result<Option<serde_json::Value>> {
    let conn = open_conn(&db_path(workspace_dir))?;
    conn.query_row(
        "SELECT id, title, entry_type, status, workspace_path, preview_text, text_body,
                created_at_client, created, updated
         FROM journal_entries
         WHERE id = ?1",
        params![id.trim()],
        |row| {
            Ok(serde_json::json!({
                "id": row.get::<_, String>(0)?,
                "title": row.get::<_, String>(1)?,
                "entryType": row.get::<_, String>(2)?,
                "status": row.get::<_, String>(3)?,
                "workspacePath": row.get::<_, String>(4)?,
                "previewText": row.get::<_, String>(5)?,
                "textBody": row.get::<_, String>(6)?,
                "createdAtClient": row.get::<_, String>(7)?,
                "created": row.get::<_, String>(8)?,
                "updated": row.get::<_, String>(9)?,
            }))
        },
    )
    .optional()
    .context("Failed to load journal entry")
}

pub fn update_journal_entry_text(
    workspace_dir: &Path,
    id: &str,
    text_body: &str,
    preview_text: &str,
) -> Result<Option<serde_json::Value>> {
    let conn = open_conn(&db_path(workspace_dir))?;
    let now = Utc::now().to_rfc3339();
    conn.execute(
        "UPDATE journal_entries
         SET text_body = ?2, preview_text = ?3, updated = ?4
         WHERE id = ?1",
        params![id.trim(), text_body, preview_text, now],
    )
    .with_context(|| format!("Failed to update journal entry {}", id.trim()))?;
    get_journal_entry(workspace_dir, id)
}

pub fn delete_journal_entry(workspace_dir: &Path, id: &str) -> Result<bool> {
    let conn = open_conn(&db_path(workspace_dir))?;
    let changed = conn
        .execute(
            "DELETE FROM journal_entries WHERE id = ?1",
            params![id.trim()],
        )
        .with_context(|| format!("Failed to delete journal entry {}", id.trim()))?;
    Ok(changed > 0)
}

pub fn delete_draft(workspace_dir: &Path, id: &str) -> Result<bool> {
    let conn = open_conn(&db_path(workspace_dir))?;
    let changed = conn
        .execute("DELETE FROM drafts WHERE id = ?1", params![id.trim()])
        .with_context(|| format!("Failed to delete draft {}", id.trim()))?;
    Ok(changed > 0)
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

pub fn create_content_job(workspace_dir: &Path, job: &ContentJobInput) -> Result<serde_json::Value> {
    let conn = open_conn(&db_path(workspace_dir))?;
    let id = format!("lc_{}", Uuid::new_v4().simple());
    let now = Utc::now().to_rfc3339();
    let created_at_client = job
        .created_at_client
        .as_deref()
        .map(str::trim)
        .filter(|v| !v.is_empty())
        .map(ToOwned::to_owned)
        .unwrap_or_else(|| now.clone());
    conn.execute(
        "INSERT INTO content_jobs (
            id, operation_key, target_id, target_path, input_json, output_json, status,
            progress_label, error, created_at_client, created, updated
         ) VALUES (?1, ?2, ?3, ?4, ?5, '', ?6, ?7, ?8, ?9, ?10, ?10)",
        params![
            id,
            job.operation_key.trim(),
            job.target_id.trim(),
            job.target_path.trim(),
            job.input_json,
            job.status.trim(),
            job.progress_label,
            job.error,
            created_at_client,
            now,
        ],
    )
    .context("Failed to create content job")?;
    get_content_job(workspace_dir, &id)?
        .ok_or_else(|| anyhow::anyhow!("content job disappeared after insert"))
}

pub fn get_content_job(workspace_dir: &Path, id: &str) -> Result<Option<serde_json::Value>> {
    let conn = open_conn(&db_path(workspace_dir))?;
    conn.query_row(
        "SELECT id, operation_key, target_id, target_path, input_json, output_json, status,
                progress_label, error, created_at_client, created, updated
         FROM content_jobs
         WHERE id = ?1",
        params![id.trim()],
        |row| {
            Ok(serde_json::json!({
                "id": row.get::<_, String>(0)?,
                "operationKey": row.get::<_, String>(1)?,
                "targetId": row.get::<_, String>(2)?,
                "targetPath": row.get::<_, String>(3)?,
                "inputJson": row.get::<_, String>(4)?,
                "outputJson": row.get::<_, String>(5)?,
                "status": row.get::<_, String>(6)?,
                "progressLabel": row.get::<_, String>(7)?,
                "error": row.get::<_, String>(8)?,
                "createdAtClient": row.get::<_, String>(9)?,
                "created": row.get::<_, String>(10)?,
                "updated": row.get::<_, String>(11)?,
            }))
        },
    )
    .optional()
    .context("Failed to load content job")
}

pub fn list_content_jobs(workspace_dir: &Path, limit: usize) -> Result<Vec<serde_json::Value>> {
    let conn = open_conn(&db_path(workspace_dir))?;
    let lim = i64::try_from(limit.max(1)).unwrap_or(100);
    let mut stmt = conn.prepare(
        "SELECT id, operation_key, target_id, target_path, input_json, output_json, status,
                progress_label, error, created_at_client, created, updated
         FROM content_jobs
         ORDER BY COALESCE(NULLIF(created_at_client, ''), updated, created) DESC, id DESC
         LIMIT ?1",
    )?;
    let rows = stmt.query_map(params![lim], |row| {
        Ok(serde_json::json!({
            "id": row.get::<_, String>(0)?,
            "operationKey": row.get::<_, String>(1)?,
            "targetId": row.get::<_, String>(2)?,
            "targetPath": row.get::<_, String>(3)?,
            "inputJson": row.get::<_, String>(4)?,
            "outputJson": row.get::<_, String>(5)?,
            "status": row.get::<_, String>(6)?,
            "progressLabel": row.get::<_, String>(7)?,
            "error": row.get::<_, String>(8)?,
            "createdAtClient": row.get::<_, String>(9)?,
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

pub fn find_latest_content_job_for_target(
    workspace_dir: &Path,
    operation_key: &str,
    target_id: &str,
) -> Result<Option<serde_json::Value>> {
    let conn = open_conn(&db_path(workspace_dir))?;
    conn.query_row(
        "SELECT id, operation_key, target_id, target_path, input_json, output_json, status,
                progress_label, error, created_at_client, created, updated
         FROM content_jobs
         WHERE operation_key = ?1 AND target_id = ?2
         ORDER BY COALESCE(NULLIF(created_at_client, ''), updated, created) DESC, id DESC
         LIMIT 1",
        params![operation_key.trim(), target_id.trim()],
        |row| {
            Ok(serde_json::json!({
                "id": row.get::<_, String>(0)?,
                "operationKey": row.get::<_, String>(1)?,
                "targetId": row.get::<_, String>(2)?,
                "targetPath": row.get::<_, String>(3)?,
                "inputJson": row.get::<_, String>(4)?,
                "outputJson": row.get::<_, String>(5)?,
                "status": row.get::<_, String>(6)?,
                "progressLabel": row.get::<_, String>(7)?,
                "error": row.get::<_, String>(8)?,
                "createdAtClient": row.get::<_, String>(9)?,
                "created": row.get::<_, String>(10)?,
                "updated": row.get::<_, String>(11)?,
            }))
        },
    )
    .optional()
    .context("Failed to load latest content job")
}

pub fn update_content_job(
    workspace_dir: &Path,
    id: &str,
    status: &str,
    progress_label: &str,
    error: Option<&str>,
    output_json: Option<&str>,
) -> Result<Option<serde_json::Value>> {
    let conn = open_conn(&db_path(workspace_dir))?;
    let now = Utc::now().to_rfc3339();
    conn.execute(
        "UPDATE content_jobs
         SET status = ?2,
             progress_label = ?3,
             error = ?4,
             output_json = COALESCE(?5, output_json),
             updated = ?6
         WHERE id = ?1",
        params![
            id.trim(),
            status.trim(),
            progress_label,
            error.unwrap_or("").trim(),
            output_json,
            now
        ],
    )
    .with_context(|| format!("Failed to update content job {}", id.trim()))?;
    get_content_job(workspace_dir, id)
}

pub fn create_artifact_metadata(
    workspace_dir: &Path,
    item: &ArtifactInput,
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

    conn.execute(
        "INSERT INTO artifacts (
            id, parent_asset_id, parent_entry_id, artifact_type, title, status, mime_type,
            workspace_path, preview_text, metadata_json, created_at_client, created
         ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12)",
        params![
            id,
            item.parent_asset_id,
            item.parent_entry_id,
            item.artifact_type,
            item.title,
            item.status,
            item.mime_type,
            item.workspace_path,
            item.preview_text,
            item.metadata_json,
            created_at_client,
            now,
        ],
    )
    .context("Failed to insert artifact metadata")?;

    Ok(serde_json::json!({
        "id": id,
        "parentAssetId": item.parent_asset_id,
        "parentEntryId": item.parent_entry_id,
        "artifactType": item.artifact_type,
        "title": item.title,
        "status": item.status,
        "mimeType": item.mime_type,
        "workspacePath": item.workspace_path,
        "previewText": item.preview_text,
        "metadataJson": item.metadata_json,
        "createdAtClient": created_at_client,
        "created": now,
    }))
}

pub fn list_artifacts_for_entry(
    workspace_dir: &Path,
    parent_entry_id: &str,
    limit: usize,
) -> Result<Vec<serde_json::Value>> {
    let conn = open_conn(&db_path(workspace_dir))?;
    let lim = i64::try_from(limit.max(1)).unwrap_or(100);
    let mut stmt = conn.prepare(
        "SELECT id, parent_asset_id, parent_entry_id, artifact_type, title, status, mime_type,
                workspace_path, preview_text, metadata_json, created_at_client, created
         FROM artifacts
         WHERE parent_entry_id = ?1
         ORDER BY COALESCE(NULLIF(created_at_client, ''), created) DESC, id DESC
         LIMIT ?2",
    )?;
    let rows = stmt.query_map(params![parent_entry_id.trim(), lim], |row| {
        Ok(serde_json::json!({
            "id": row.get::<_, String>(0)?,
            "parentAssetId": row.get::<_, String>(1)?,
            "parentEntryId": row.get::<_, String>(2)?,
            "artifactType": row.get::<_, String>(3)?,
            "title": row.get::<_, String>(4)?,
            "status": row.get::<_, String>(5)?,
            "mimeType": row.get::<_, String>(6)?,
            "workspacePath": row.get::<_, String>(7)?,
            "previewText": row.get::<_, String>(8)?,
            "metadataJson": row.get::<_, String>(9)?,
            "createdAtClient": row.get::<_, String>(10)?,
            "created": row.get::<_, String>(11)?,
        }))
    })?;

    let mut out = Vec::new();
    for row in rows {
        out.push(row?);
    }
    Ok(out)
}

pub fn find_latest_artifact_for_entry_and_type(
    workspace_dir: &Path,
    parent_entry_id: &str,
    artifact_type: &str,
) -> Result<Option<serde_json::Value>> {
    let conn = open_conn(&db_path(workspace_dir))?;
    conn.query_row(
        "SELECT id, parent_asset_id, parent_entry_id, artifact_type, title, status, mime_type,
                workspace_path, preview_text, metadata_json, created_at_client, created
         FROM artifacts
         WHERE parent_entry_id = ?1 AND artifact_type = ?2
         ORDER BY COALESCE(NULLIF(created_at_client, ''), created) DESC, id DESC
         LIMIT 1",
        params![parent_entry_id.trim(), artifact_type.trim()],
        |row| {
            Ok(serde_json::json!({
                "id": row.get::<_, String>(0)?,
                "parentAssetId": row.get::<_, String>(1)?,
                "parentEntryId": row.get::<_, String>(2)?,
                "artifactType": row.get::<_, String>(3)?,
                "title": row.get::<_, String>(4)?,
                "status": row.get::<_, String>(5)?,
                "mimeType": row.get::<_, String>(6)?,
                "workspacePath": row.get::<_, String>(7)?,
                "previewText": row.get::<_, String>(8)?,
                "metadataJson": row.get::<_, String>(9)?,
                "createdAtClient": row.get::<_, String>(10)?,
                "created": row.get::<_, String>(11)?,
            }))
        },
    )
    .optional()
    .context("Failed to load latest artifact")
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
            created TEXT NOT NULL,
            updated TEXT NOT NULL DEFAULT ''
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

        CREATE TABLE IF NOT EXISTS content_jobs (
            id TEXT PRIMARY KEY,
            operation_key TEXT NOT NULL DEFAULT '',
            target_id TEXT NOT NULL DEFAULT '',
            target_path TEXT NOT NULL DEFAULT '',
            input_json TEXT NOT NULL DEFAULT '',
            output_json TEXT NOT NULL DEFAULT '',
            status TEXT NOT NULL DEFAULT '',
            progress_label TEXT NOT NULL DEFAULT '',
            error TEXT NOT NULL DEFAULT '',
            created_at_client TEXT NOT NULL DEFAULT '',
            created TEXT NOT NULL,
            updated TEXT NOT NULL
        );
        CREATE INDEX IF NOT EXISTS idx_content_jobs_target
            ON content_jobs(operation_key, target_id, updated);
        CREATE INDEX IF NOT EXISTS idx_content_jobs_created
            ON content_jobs(created_at_client, created);

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
            ON artifacts(workspace_path);",
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

    let has_journal_updated: bool = conn
        .prepare("SELECT updated FROM journal_entries LIMIT 0")
        .is_ok();
    if !has_journal_updated {
        let _ = conn.execute_batch(
            "ALTER TABLE journal_entries ADD COLUMN updated TEXT NOT NULL DEFAULT ''",
        );
        let _ = conn.execute_batch(
            "UPDATE journal_entries SET updated = created WHERE updated = ''",
        );
    }

    Ok(())
}

fn table_exists(conn: &Connection, table: &str) -> Result<bool> {
    let mut stmt = conn.prepare(
        "SELECT 1 FROM sqlite_master WHERE type='table' AND name=?1 LIMIT 1",
    )?;
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
        assert!(table_exists(&conn, "content_jobs").unwrap());
        assert!(table_exists(&conn, "artifacts").unwrap());
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

        assert!(delete_draft(tmp.path(), &id).unwrap());
        assert!(list_drafts(tmp.path(), 100).unwrap().is_empty());
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

        let listed = list_journal_entries(tmp.path(), 10, 0).unwrap();
        assert_eq!(listed.len(), 1);
        assert_eq!(listed[0]["id"], entry["id"]);

        let fetched = get_journal_entry(tmp.path(), entry["id"].as_str().unwrap())
            .unwrap()
            .unwrap();
        assert_eq!(fetched["workspacePath"], "journals/2026-03-03/entry.md");

        let updated = update_journal_entry_text(
            tmp.path(),
            entry["id"].as_str().unwrap(),
            "updated body",
            "updated preview",
        )
        .unwrap()
        .unwrap();
        assert_eq!(updated["textBody"], "updated body");
        assert_eq!(updated["previewText"], "updated preview");

        assert!(delete_journal_entry(tmp.path(), entry["id"].as_str().unwrap()).unwrap());
        assert!(
            get_journal_entry(tmp.path(), entry["id"].as_str().unwrap())
                .unwrap()
                .is_none()
        );
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
    fn content_job_roundtrip() {
        let tmp = test_workspace();
        initialize(tmp.path()).unwrap();

        let job = create_content_job(
            tmp.path(),
            &ContentJobInput {
                operation_key: "transcribe_media".into(),
                target_id: "journal-1".into(),
                target_path: "journals/media/audio/sample.m4a".into(),
                input_json: "{\"model\":\"ggml-base.en.bin\"}".into(),
                status: "queued".into(),
                progress_label: "Queued".into(),
                error: String::new(),
                created_at_client: None,
            },
        )
        .unwrap();

        let fetched = get_content_job(tmp.path(), job["id"].as_str().unwrap())
            .unwrap()
            .unwrap();
        assert_eq!(fetched["operationKey"], "transcribe_media");
        assert_eq!(fetched["status"], "queued");

        let latest = find_latest_content_job_for_target(tmp.path(), "transcribe_media", "journal-1")
            .unwrap()
            .unwrap();
        assert_eq!(latest["id"], job["id"]);

        let updated = update_content_job(
            tmp.path(),
            job["id"].as_str().unwrap(),
            "completed",
            "Transcript ready",
            None,
            Some("{\"transcriptPath\":\"journals/text/transcriptions/sample.txt\"}"),
        )
        .unwrap()
        .unwrap();
        assert_eq!(updated["status"], "completed");
        assert_eq!(updated["progressLabel"], "Transcript ready");

        let listed = list_content_jobs(tmp.path(), 10).unwrap();
        assert_eq!(listed.len(), 1);
        assert_eq!(listed[0]["id"], job["id"]);
    }

    #[test]
    fn artifact_metadata_roundtrip() {
        let tmp = test_workspace();
        initialize(tmp.path()).unwrap();

        let artifact = create_artifact_metadata(
            tmp.path(),
            &ArtifactInput {
                parent_asset_id: String::new(),
                parent_entry_id: "journal-1".into(),
                artifact_type: "canonical_transcript".into(),
                title: "Timed transcript".into(),
                status: "ready".into(),
                mime_type: "application/json".into(),
                workspace_path: "artifacts/transcripts/audio/example.timed_transcript.json".into(),
                preview_text: "hello world".into(),
                metadata_json: "{\"cueCount\":2}".into(),
                created_at_client: None,
            },
        )
        .unwrap();

        let listed = list_artifacts_for_entry(tmp.path(), "journal-1", 10).unwrap();
        assert_eq!(listed.len(), 1);
        assert_eq!(listed[0]["id"], artifact["id"]);

        let latest = find_latest_artifact_for_entry_and_type(
            tmp.path(),
            "journal-1",
            "canonical_transcript",
        )
        .unwrap()
        .unwrap();
        assert_eq!(latest["workspacePath"], "artifacts/transcripts/audio/example.timed_transcript.json");
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
        assert_eq!(non_empty_opt("".into()), None);
        assert_eq!(non_empty_opt("   ".into()), None);
    }

}
