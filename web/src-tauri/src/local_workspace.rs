use base64::engine::general_purpose::STANDARD as BASE64_STANDARD;
use base64::Engine;
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::path::{Path, PathBuf};
use std::time::{SystemTime, UNIX_EPOCH};
use zeroclaw::gateway::local_store;

const APP_CONFIG_FILENAME: &str = "mobile_app_config.json";

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct JournalEntry {
    pub id: String,
    pub title: String,
    pub content: String,
    pub kind: String,
    pub file_path: Option<String>,
    pub created_at: String,
    pub updated_at: String,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Draft {
    pub id: String,
    pub text: String,
    pub video_name: Option<String>,
    pub created_at: String,
    pub updated_at: String,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct PostRecord {
    pub id: String,
    pub provider: String,
    pub text: String,
    pub source_journal_id: Option<String>,
    pub uri: Option<String>,
    pub cid: Option<String>,
    pub status: String,
    pub error: Option<String>,
    pub created_at: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AppConfig {
    pub ollama_base_url: String,
    pub ollama_model: String,
    pub bluesky_handle: String,
    pub bluesky_service_url: String,
    pub transcription_enabled: bool,
    pub transcription_model: String,
    pub available_transcription_models: Vec<String>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct DraftInput {
    pub id: Option<String>,
    pub text: String,
    pub video_name: Option<String>,
}

#[derive(Debug, Clone, Deserialize)]
pub struct PostRecordInput {
    pub provider: String,
    pub text: String,
    pub source_journal_id: Option<String>,
    pub uri: Option<String>,
    pub cid: Option<String>,
    pub status: String,
    pub error: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct PersistedAppConfig {
    ollama_base_url: String,
    ollama_model: String,
    bluesky_handle: String,
    bluesky_service_url: String,
    transcription_enabled: bool,
    transcription_model: String,
}

impl Default for PersistedAppConfig {
    fn default() -> Self {
        Self {
            ollama_base_url: String::new(),
            ollama_model: String::new(),
            bluesky_handle: String::new(),
            bluesky_service_url: "https://bsky.social".to_string(),
            transcription_enabled: false,
            transcription_model: "ggml-base.en.bin".to_string(),
        }
    }
}

fn built_in_transcription_models() -> Vec<String> {
    vec![
        "ggml-tiny.en.bin".to_string(),
        "ggml-base.en.bin".to_string(),
        "ggml-small.en.bin".to_string(),
        "ggml-base.bin".to_string(),
    ]
}

fn now_rfc3339ish() -> String {
    let secs = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|duration| duration.as_secs())
        .unwrap_or(0);
    format!("{secs}")
}

fn timestamp_prefix() -> String {
    let millis = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|duration| duration.as_millis())
        .unwrap_or(0);
    millis.to_string()
}

fn slugify(value: &str) -> String {
    let mut out = String::with_capacity(value.len());
    let mut last_dash = false;
    for ch in value.trim().chars() {
        let normalized = if ch.is_ascii_alphanumeric() {
            Some(ch.to_ascii_lowercase())
        } else if ch == '-' || ch == '_' || ch.is_ascii_whitespace() {
            Some('-')
        } else {
            None
        };
        let Some(next) = normalized else {
            continue;
        };
        if next == '-' {
            if last_dash || out.is_empty() {
                continue;
            }
            last_dash = true;
        } else {
            last_dash = false;
        }
        out.push(next);
    }
    let trimmed = out.trim_matches('-');
    if trimmed.is_empty() {
        "entry".to_string()
    } else {
        trimmed.to_string()
    }
}

fn sanitize_filename(value: &str) -> String {
    let mut out = String::with_capacity(value.len());
    for ch in value.trim().chars() {
        if ch.is_ascii_alphanumeric() || matches!(ch, '.' | '-' | '_') {
            out.push(ch);
        } else if ch.is_ascii_whitespace() {
            out.push('_');
        }
    }
    if out.is_empty() {
        "media.bin".to_string()
    } else {
        out
    }
}

fn preview_text(content: &str) -> String {
    content.trim().chars().take(280).collect()
}

async fn load_runtime_config() -> Result<zeroclaw::Config, String> {
    zeroclaw::Config::load_or_init()
        .await
        .map_err(|e| format!("failed to load config: {e}"))
}

fn ensure_local_store(workspace_dir: &Path) -> Result<(), String> {
    local_store::initialize(workspace_dir)
        .map(|_| ())
        .map_err(|e| format!("failed to initialize local store: {e}"))
}

fn app_config_path(config: &zeroclaw::Config) -> PathBuf {
    config
        .config_path
        .parent()
        .map_or_else(|| PathBuf::from("."), PathBuf::from)
        .join(APP_CONFIG_FILENAME)
}

fn read_persisted_app_config(config: &zeroclaw::Config) -> PersistedAppConfig {
    let path = app_config_path(config);
    let Ok(raw) = std::fs::read_to_string(path) else {
        return PersistedAppConfig::default();
    };
    serde_json::from_str(&raw).unwrap_or_default()
}

fn write_persisted_app_config(config: &zeroclaw::Config, app_config: &PersistedAppConfig) -> Result<(), String> {
    let path = app_config_path(config);
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)
            .map_err(|e| format!("failed to create app config directory: {e}"))?;
    }
    let serialized = serde_json::to_vec_pretty(app_config)
        .map_err(|e| format!("failed to serialize app config: {e}"))?;
    std::fs::write(path, serialized).map_err(|e| format!("failed to write app config: {e}"))
}

fn journal_transcript_rel_path(workspace_path: &str) -> Option<String> {
    let normalized = workspace_path.trim().trim_start_matches('/');
    if !normalized.starts_with("journals/media/") {
        return None;
    }
    let rel = normalized.trim_start_matches("journals/media/");
    let stem = match rel.rsplit_once('.') {
        Some((before, _)) => before,
        None => rel,
    };
    Some(format!("journals/text/transcriptions/{stem}.txt"))
}

fn write_text_entry_file(abs_path: &Path, title: &str, content: &str) -> Result<(), String> {
    if let Some(parent) = abs_path.parent() {
        std::fs::create_dir_all(parent)
            .map_err(|e| format!("failed to create journal directory: {e}"))?;
    }
    let body = format!("# {}\n\n{}\n", title.trim(), content.trim());
    std::fs::write(abs_path, body).map_err(|e| format!("failed to write journal file: {e}"))
}

fn write_transcript_sidecar(workspace_dir: &Path, media_workspace_path: &str, content: &str) -> Result<(), String> {
    let Some(rel_path) = journal_transcript_rel_path(media_workspace_path) else {
        return Ok(());
    };
    let abs_path = workspace_dir.join(rel_path);
    if let Some(parent) = abs_path.parent() {
        std::fs::create_dir_all(parent)
            .map_err(|e| format!("failed to create transcript directory: {e}"))?;
    }
    std::fs::write(abs_path, content).map_err(|e| format!("failed to write transcript: {e}"))
}

fn remove_file_if_exists(path: &Path) -> Result<(), String> {
    if !path.exists() {
        return Ok(());
    }
    std::fs::remove_file(path).map_err(|e| format!("failed to remove {}: {e}", path.display()))
}

fn string_field(value: &Value, key: &str) -> String {
    value.get(key)
        .and_then(Value::as_str)
        .unwrap_or_default()
        .to_string()
}

fn optional_string_field(value: &Value, key: &str) -> Option<String> {
    let raw = string_field(value, key);
    let trimmed = raw.trim();
    if trimmed.is_empty() {
        None
    } else {
        Some(trimmed.to_string())
    }
}

fn journal_entry_from_value(workspace_dir: &Path, value: Value) -> JournalEntry {
    let kind = string_field(&value, "entryType");
    let workspace_path = string_field(&value, "workspacePath");
    let file_path = if matches!(kind.as_str(), "audio" | "video" | "image") && !workspace_path.is_empty() {
        Some(workspace_dir.join(workspace_path).display().to_string())
    } else {
        None
    };

    JournalEntry {
        id: string_field(&value, "id"),
        title: string_field(&value, "title"),
        content: string_field(&value, "textBody"),
        kind,
        file_path,
        created_at: optional_string_field(&value, "createdAtClient")
            .or_else(|| optional_string_field(&value, "created"))
            .unwrap_or_else(now_rfc3339ish),
        updated_at: optional_string_field(&value, "updated")
            .or_else(|| optional_string_field(&value, "created"))
            .unwrap_or_else(now_rfc3339ish),
    }
}

#[tauri::command]
pub async fn save_journal_text(title: String, content: String) -> Result<JournalEntry, String> {
    let config = load_runtime_config().await?;
    ensure_local_store(&config.workspace_dir)?;

    let normalized_title = if title.trim().is_empty() {
        "Journal entry".to_string()
    } else {
        title.trim().to_string()
    };
    let rel_path = format!(
        "journals/text/{}_{}.md",
        timestamp_prefix(),
        slugify(&normalized_title)
    );
    let abs_path = config.workspace_dir.join(&rel_path);
    write_text_entry_file(&abs_path, &normalized_title, &content)?;

    let entry = local_store::create_journal_entry_metadata(
        &config.workspace_dir,
        &local_store::JournalEntryInput {
            title: normalized_title.clone(),
            entry_type: "text".to_string(),
            source: "native-local".to_string(),
            status: "ready".to_string(),
            workspace_path: rel_path,
            preview_text: preview_text(&content),
            text_body: content,
            tags_csv: String::new(),
            created_at_client: None,
        },
    )
    .map_err(|e| format!("failed to save journal metadata: {e}"))?;

    Ok(journal_entry_from_value(&config.workspace_dir, entry))
}

#[tauri::command]
pub async fn save_journal_media(
    kind: String,
    filename: String,
    data_b64: String,
    title: Option<String>,
) -> Result<JournalEntry, String> {
    let config = load_runtime_config().await?;
    ensure_local_store(&config.workspace_dir)?;

    let normalized_kind = match kind.trim() {
        "audio" | "video" | "image" => kind.trim().to_string(),
        other => return Err(format!("unsupported media kind: {other}")),
    };
    let safe_filename = sanitize_filename(&filename);
    let rel_path = format!(
        "journals/media/{}/{}_{}",
        normalized_kind,
        timestamp_prefix(),
        safe_filename
    );
    let abs_path = config.workspace_dir.join(&rel_path);
    if let Some(parent) = abs_path.parent() {
        std::fs::create_dir_all(parent)
            .map_err(|e| format!("failed to create media directory: {e}"))?;
    }
    let bytes = BASE64_STANDARD
        .decode(data_b64.trim())
        .map_err(|e| format!("failed to decode media payload: {e}"))?;
    std::fs::write(&abs_path, &bytes).map_err(|e| format!("failed to write media file: {e}"))?;

    let normalized_title = title
        .as_deref()
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(ToOwned::to_owned)
        .unwrap_or_else(|| safe_filename.clone());

    let entry = local_store::create_journal_entry_metadata(
        &config.workspace_dir,
        &local_store::JournalEntryInput {
            title: normalized_title.clone(),
            entry_type: normalized_kind.clone(),
            source: "native-local".to_string(),
            status: "ready".to_string(),
            workspace_path: rel_path.clone(),
            preview_text: String::new(),
            text_body: String::new(),
            tags_csv: String::new(),
            created_at_client: None,
        },
    )
    .map_err(|e| format!("failed to save media journal metadata: {e}"))?;

    let entry_id = string_field(&entry, "id");
    let _ = local_store::create_media_asset_metadata(
        &config.workspace_dir,
        &local_store::MediaAssetInput {
            title: normalized_title,
            entry_id,
            asset_type: normalized_kind.clone(),
            mime_type: String::new(),
            source: "native-local".to_string(),
            status: "ready".to_string(),
            workspace_path: rel_path,
            size_bytes: i64::try_from(bytes.len()).unwrap_or(i64::MAX),
            created_at_client: None,
        },
    );

    Ok(journal_entry_from_value(&config.workspace_dir, entry))
}

#[tauri::command]
pub async fn list_journals(limit: Option<usize>, offset: Option<usize>) -> Result<Vec<JournalEntry>, String> {
    let config = load_runtime_config().await?;
    ensure_local_store(&config.workspace_dir)?;
    let entries = local_store::list_journal_entries(
        &config.workspace_dir,
        limit.unwrap_or(200),
        offset.unwrap_or(0),
    )
    .map_err(|e| format!("failed to list journals: {e}"))?;
    Ok(entries
        .into_iter()
        .map(|value| journal_entry_from_value(&config.workspace_dir, value))
        .collect())
}

#[tauri::command]
pub async fn get_journal(id: String) -> Result<JournalEntry, String> {
    let config = load_runtime_config().await?;
    ensure_local_store(&config.workspace_dir)?;
    let Some(entry) = local_store::get_journal_entry(&config.workspace_dir, &id)
        .map_err(|e| format!("failed to load journal: {e}"))?
    else {
        return Err("journal not found".to_string());
    };
    Ok(journal_entry_from_value(&config.workspace_dir, entry))
}

#[tauri::command]
pub async fn update_journal_text(id: String, content: String) -> Result<JournalEntry, String> {
    let config = load_runtime_config().await?;
    ensure_local_store(&config.workspace_dir)?;
    let Some(existing) = local_store::get_journal_entry(&config.workspace_dir, &id)
        .map_err(|e| format!("failed to load journal: {e}"))?
    else {
        return Err("journal not found".to_string());
    };

    let title = string_field(&existing, "title");
    let kind = string_field(&existing, "entryType");
    let workspace_path = string_field(&existing, "workspacePath");
    if workspace_path.is_empty() {
        return Err("journal workspace path missing".to_string());
    }

    if kind == "text" {
        let abs_path = config.workspace_dir.join(&workspace_path);
        write_text_entry_file(&abs_path, &title, &content)?;
    } else {
        write_transcript_sidecar(&config.workspace_dir, &workspace_path, &content)?;
    }

    let Some(updated) = local_store::update_journal_entry_text(
        &config.workspace_dir,
        &id,
        &content,
        &preview_text(&content),
    )
    .map_err(|e| format!("failed to update journal metadata: {e}"))?
    else {
        return Err("journal not found".to_string());
    };

    Ok(journal_entry_from_value(&config.workspace_dir, updated))
}

#[tauri::command]
pub async fn delete_journal(id: String) -> Result<(), String> {
    let config = load_runtime_config().await?;
    ensure_local_store(&config.workspace_dir)?;
    let Some(existing) = local_store::get_journal_entry(&config.workspace_dir, &id)
        .map_err(|e| format!("failed to load journal: {e}"))?
    else {
        return Ok(());
    };

    let workspace_path = string_field(&existing, "workspacePath");
    let kind = string_field(&existing, "entryType");
    if !workspace_path.is_empty() {
        remove_file_if_exists(&config.workspace_dir.join(&workspace_path))?;
        if kind != "text" {
            if let Some(transcript_rel) = journal_transcript_rel_path(&workspace_path) {
                remove_file_if_exists(&config.workspace_dir.join(transcript_rel))?;
            }
        }
    }

    let _ = local_store::delete_journal_entry(&config.workspace_dir, &id)
        .map_err(|e| format!("failed to delete journal metadata: {e}"))?;
    Ok(())
}

#[tauri::command]
pub async fn save_draft(draft: DraftInput) -> Result<Draft, String> {
    let config = load_runtime_config().await?;
    ensure_local_store(&config.workspace_dir)?;
    let saved = local_store::upsert_draft(
        &config.workspace_dir,
        &local_store::DraftUpsert {
            id: draft.id,
            text: draft.text,
            video_name: draft.video_name.unwrap_or_default(),
            created_at_client: None,
            updated_at_client: None,
        },
    )
    .map_err(|e| format!("failed to save draft: {e}"))?;
    Ok(Draft {
        id: string_field(&saved, "id"),
        text: string_field(&saved, "text"),
        video_name: optional_string_field(&saved, "videoName"),
        created_at: optional_string_field(&saved, "createdAtClient").unwrap_or_else(now_rfc3339ish),
        updated_at: optional_string_field(&saved, "updatedAtClient").unwrap_or_else(now_rfc3339ish),
    })
}

#[tauri::command]
pub async fn list_drafts() -> Result<Vec<Draft>, String> {
    let config = load_runtime_config().await?;
    ensure_local_store(&config.workspace_dir)?;
    let drafts = local_store::list_drafts(&config.workspace_dir, 100)
        .map_err(|e| format!("failed to list drafts: {e}"))?;
    Ok(drafts
        .into_iter()
        .map(|saved| Draft {
            id: string_field(&saved, "id"),
            text: string_field(&saved, "text"),
            video_name: optional_string_field(&saved, "videoName"),
            created_at: optional_string_field(&saved, "createdAtClient").unwrap_or_else(now_rfc3339ish),
            updated_at: optional_string_field(&saved, "updatedAtClient")
                .or_else(|| optional_string_field(&saved, "created"))
                .unwrap_or_else(now_rfc3339ish),
        })
        .collect())
}

#[tauri::command]
pub async fn delete_draft(id: String) -> Result<(), String> {
    let config = load_runtime_config().await?;
    ensure_local_store(&config.workspace_dir)?;
    let _ = local_store::delete_draft(&config.workspace_dir, &id)
        .map_err(|e| format!("failed to delete draft: {e}"))?;
    Ok(())
}

#[tauri::command]
pub async fn save_post_record(record: PostRecordInput) -> Result<PostRecord, String> {
    let config = load_runtime_config().await?;
    ensure_local_store(&config.workspace_dir)?;
    let saved = local_store::create_post_history(
        &config.workspace_dir,
        &local_store::PostHistoryInput {
            provider: record.provider,
            text: record.text,
            video_name: String::new(),
            source_path: record.source_journal_id.unwrap_or_default(),
            uri: record.uri.unwrap_or_default(),
            cid: record.cid.unwrap_or_default(),
            status: record.status,
            error: record.error.unwrap_or_default(),
            created_at_client: None,
        },
    )
    .map_err(|e| format!("failed to save post record: {e}"))?;
    Ok(PostRecord {
        id: string_field(&saved, "id"),
        provider: string_field(&saved, "provider"),
        text: string_field(&saved, "text"),
        source_journal_id: optional_string_field(&saved, "sourcePath"),
        uri: optional_string_field(&saved, "uri"),
        cid: optional_string_field(&saved, "cid"),
        status: string_field(&saved, "status"),
        error: optional_string_field(&saved, "error"),
        created_at: optional_string_field(&saved, "createdAtClient").unwrap_or_else(now_rfc3339ish),
    })
}

#[tauri::command]
pub async fn list_post_history() -> Result<Vec<PostRecord>, String> {
    let config = load_runtime_config().await?;
    ensure_local_store(&config.workspace_dir)?;
    let items = local_store::list_post_history(&config.workspace_dir, 100)
        .map_err(|e| format!("failed to list post history: {e}"))?;
    Ok(items
        .into_iter()
        .map(|saved| PostRecord {
            id: string_field(&saved, "id"),
            provider: string_field(&saved, "provider"),
            text: string_field(&saved, "text"),
            source_journal_id: optional_string_field(&saved, "sourcePath"),
            uri: optional_string_field(&saved, "uri"),
            cid: optional_string_field(&saved, "cid"),
            status: string_field(&saved, "status"),
            error: optional_string_field(&saved, "error"),
            created_at: optional_string_field(&saved, "createdAtClient")
                .or_else(|| optional_string_field(&saved, "created"))
                .unwrap_or_else(now_rfc3339ish),
        })
        .collect())
}

#[tauri::command]
pub async fn get_config() -> Result<AppConfig, String> {
    let config = load_runtime_config().await?;
    let persisted = read_persisted_app_config(&config);
    Ok(AppConfig {
        ollama_base_url: persisted.ollama_base_url,
        ollama_model: if persisted.ollama_model.trim().is_empty() {
            config
                .default_model
                .clone()
                .unwrap_or_else(|| config.transcription.model.clone())
        } else {
            persisted.ollama_model
        },
        bluesky_handle: persisted.bluesky_handle,
        bluesky_service_url: persisted.bluesky_service_url,
        transcription_enabled: config.transcription.enabled,
        transcription_model: if persisted.transcription_model.trim().is_empty() {
            config.transcription.model.clone()
        } else {
            persisted.transcription_model
        },
        available_transcription_models: built_in_transcription_models(),
    })
}

#[tauri::command]
pub async fn save_config(config_update: AppConfig) -> Result<(), String> {
    let mut config = load_runtime_config().await?;
    let mut persisted = read_persisted_app_config(&config);

    persisted.ollama_base_url = config_update.ollama_base_url;
    persisted.ollama_model = config_update.ollama_model.clone();
    persisted.bluesky_handle = config_update.bluesky_handle;
    persisted.bluesky_service_url = if config_update.bluesky_service_url.trim().is_empty() {
        "https://bsky.social".to_string()
    } else {
        config_update.bluesky_service_url
    };
    persisted.transcription_enabled = config_update.transcription_enabled;
    persisted.transcription_model = if config_update.transcription_model.trim().is_empty() {
        "ggml-base.en.bin".to_string()
    } else {
        config_update.transcription_model.clone()
    };
    write_persisted_app_config(&config, &persisted)?;

    if !config_update.ollama_model.trim().is_empty() {
        config.default_model = Some(config_update.ollama_model.clone());
    }
    config.transcription.enabled = config_update.transcription_enabled;
    config.transcription.model = persisted.transcription_model;
    config
        .save()
        .await
        .map_err(|e| format!("failed to save runtime config: {e}"))?;
    Ok(())
}
