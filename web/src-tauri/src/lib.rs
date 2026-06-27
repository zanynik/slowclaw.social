use base64::Engine;
use serde::{Deserialize, Serialize};
use std::io::{BufRead, BufReader, Read};
use std::net::{IpAddr, UdpSocket};
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::mpsc;
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::{Duration, SystemTime, UNIX_EPOCH};
use tauri::async_runtime::JoinHandle;
use tauri::Manager;

mod inference;
mod transcription;

const EMBEDDED_GATEWAY_URL: &str = "http://127.0.0.1:42617";
const PROVIDER_SECRET_SERVICE: &str = "social.slowclaw.gateway";
const PROVIDER_API_KEY_SECRET_ACCOUNT: &str = "provider.api_key";
const OPENROUTER_API_KEY_SECRET_ACCOUNT: &str = "openrouter.api_key";
const DESKTOP_GATEWAY_TOKEN_SECRET_ACCOUNT: &str = "desktop.gateway.token";
const OPENAI_DEVICE_LOGIN_PROVIDER: &str = "openai-codex";
const OPENAI_DEVICE_LOGIN_PROFILE: &str = "default";
const NATIVE_LOCAL_AI_PROVIDER: &str = "slowclaw-local";
const NATIVE_LOCAL_AI_URL: &str = "slowclaw-native://local";
const NATIVE_JOURNAL_INDEX_DIR: &str = "native_journals";

#[derive(Debug, Deserialize)]
struct SecretGetRequest {
    service: String,
    account: String,
}

#[derive(Debug, Deserialize)]
struct SecretSetRequest {
    service: String,
    account: String,
    value: String,
}

#[derive(Debug, Serialize)]
struct SecretGetResponse {
    value: Option<String>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
struct JournalEntry {
    id: String,
    title: String,
    content: String,
    kind: String,
    file_path: Option<String>,
    created_at: String,
    updated_at: String,
}

#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
struct NativeJournalRecord {
    id: String,
    title: String,
    content: String,
    kind: String,
    file_path: Option<String>,
    created_at: String,
    updated_at: String,
}

impl From<NativeJournalRecord> for JournalEntry {
    fn from(record: NativeJournalRecord) -> Self {
        Self {
            id: record.id,
            title: record.title,
            content: record.content,
            kind: record.kind,
            file_path: record.file_path,
            created_at: record.created_at,
            updated_at: record.updated_at,
        }
    }
}

#[derive(Debug, Clone, Serialize)]
struct EmbeddedGatewayInfo {
    gateway_url: String,
    running: bool,
    last_error: Option<String>,
    provider_api_key_set: bool,
}

#[derive(Debug, Serialize)]
struct GatewayQrPayload {
    gateway_url: String,
    token: String,
    qr_value: String,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct DesktopGatewayBootstrap {
    gateway_url: String,
    token: String,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
struct OpenAiDeviceCodeStatus {
    state: String,
    running: bool,
    completed: bool,
    message: String,
    verification_url: Option<String>,
    user_code: Option<String>,
    fast_link: Option<String>,
    error: Option<String>,
}

impl Default for OpenAiDeviceCodeStatus {
    fn default() -> Self {
        Self {
            state: "idle".to_string(),
            running: false,
            completed: false,
            message: "Not started.".to_string(),
            verification_url: None,
            user_code: None,
            fast_link: None,
            error: None,
        }
    }
}

#[derive(Debug)]
struct GatewayRuntimeState {
    gateway_url: String,
    running: bool,
    last_error: Option<String>,
    provider_api_key_set: bool,
    gateway_handle: Option<JoinHandle<()>>,
}

impl Default for GatewayRuntimeState {
    fn default() -> Self {
        Self {
            gateway_url: EMBEDDED_GATEWAY_URL.to_string(),
            running: false,
            last_error: None,
            provider_api_key_set: false,
            gateway_handle: None,
        }
    }
}

#[derive(Clone, Default)]
struct GatewayState {
    inner: Arc<Mutex<GatewayRuntimeState>>,
}

#[derive(Debug, Default)]
struct OpenAiDeviceCodeRuntimeState {
    status: OpenAiDeviceCodeStatus,
}

#[derive(Clone, Default)]
struct OpenAiDeviceCodeState {
    inner: Arc<Mutex<OpenAiDeviceCodeRuntimeState>>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
struct AnthropicTokenStatus {
    is_set: bool,
    message: String,
    error: Option<String>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
struct NativeLocalAiStatus {
    provider: String,
    configured: bool,
    available: bool,
    running: bool,
    state: String,
    model_id: Option<String>,
    model_path: Option<String>,
    api_url: String,
    message: String,
    error: Option<String>,
}

#[derive(Debug)]
struct NativeLocalAiRuntimeState {
    status: NativeLocalAiStatus,
}

impl Default for NativeLocalAiRuntimeState {
    fn default() -> Self {
        Self {
            status: default_native_local_ai_status(),
        }
    }
}

#[derive(Clone, Default)]
struct NativeLocalAiState {
    inner: Arc<Mutex<NativeLocalAiRuntimeState>>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct NativeLocalAiConfigureRequest {
    model_id: String,
    model_path: String,
}

#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
struct NativeLocalAiPersistedState {
    model_id: String,
    model_path: String,
}

fn default_native_local_ai_status() -> NativeLocalAiStatus {
    let engine_compiled = cfg!(feature = "native-inference");
    NativeLocalAiStatus {
        provider: NATIVE_LOCAL_AI_PROVIDER.to_string(),
        configured: false,
        available: engine_compiled,
        running: false,
        state: if engine_compiled {
            "ready".to_string()
        } else {
            "engine_missing".to_string()
        },
        model_id: None,
        model_path: None,
        api_url: NATIVE_LOCAL_AI_URL.to_string(),
        message: if engine_compiled {
            "Native local AI engine is available. Download and select a model to get started."
                .to_string()
        } else if cfg!(mobile) {
            "SlowClaw is wired for a native iOS local AI engine, but the llama.cpp engine is not compiled into this build."
                .to_string()
        } else {
            "SlowClaw native local AI is intended for iOS. Desktop can use the llama.cpp server runtime."
                .to_string()
        },
        error: if engine_compiled {
            None
        } else {
            Some("Native local inference engine is not compiled into this build.".to_string())
        },
    }
}

fn sync_native_local_ai_env(model_id: &str, model_path: &str) {
    std::env::set_var(
        zeroclaw::providers::local_native::ENV_NATIVE_MODEL_ID,
        model_id,
    );
    std::env::set_var(
        zeroclaw::providers::local_native::ENV_NATIVE_MODEL_PATH,
        model_path,
    );
}

fn native_local_ai_state_path(config: &zeroclaw::Config) -> PathBuf {
    config
        .workspace_dir
        .join("state")
        .join("native_local_ai.json")
}

async fn save_native_local_ai_state(
    config: &zeroclaw::Config,
    state: &NativeLocalAiPersistedState,
) -> Result<(), String> {
    let path = native_local_ai_state_path(config);
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)
            .map_err(|e| format!("failed to create native local AI state dir: {e}"))?;
    }
    let json = serde_json::to_string_pretty(state)
        .map_err(|e| format!("failed to encode native local AI state: {e}"))?;
    std::fs::write(&path, json).map_err(|e| format!("failed to write native local AI state: {e}"))
}

async fn load_native_local_ai_state(
    config: &zeroclaw::Config,
) -> Result<Option<NativeLocalAiPersistedState>, String> {
    let path = native_local_ai_state_path(config);
    if !path.is_file() {
        return Ok(None);
    }
    let raw = std::fs::read_to_string(&path)
        .map_err(|e| format!("failed to read native local AI state: {e}"))?;
    let state = serde_json::from_str(&raw)
        .map_err(|e| format!("failed to parse native local AI state: {e}"))?;
    Ok(Some(state))
}

/// On iOS, the app container UUID changes on update/reinstall, making
/// previously saved absolute model paths stale. This function tries to
/// reconstruct the path under the current workspace directory.
///
/// It also scans the models directory for any `.gguf` file matching the
/// model_id pattern as a last resort.
fn try_repair_model_path(model_id: &str, old_path: &str) -> Option<String> {
    // Extract the relative suffix after workspace marker
    // e.g. ".zeroclaw/workspace/local-models/llamacpp/<dir>/<file>.gguf"
    let workspace_marker = ".zeroclaw/workspace/";
    let relative_suffix = old_path
        .find(workspace_marker)
        .map(|i| &old_path[i + workspace_marker.len()..]);

    // Get the current home directory (works on iOS + macOS + Linux)
    let home = std::env::var("HOME")
        .map(std::path::PathBuf::from)
        .unwrap_or_else(|_| std::path::PathBuf::from("."));
    let workspace_dir = home.join(".zeroclaw").join("workspace");

    // Strategy 1: reconstruct from the relative suffix
    if let Some(suffix) = relative_suffix {
        let candidate = workspace_dir.join(suffix);
        if candidate.is_file() {
            return Some(candidate.display().to_string());
        }
    }

    // Strategy 2: look for the GGUF by model_id in the models directory
    let model_dir_name: String = model_id
        .chars()
        .map(|ch| {
            if ch.is_ascii_alphanumeric() || matches!(ch, '.' | '-' | '_') {
                ch
            } else {
                '_'
            }
        })
        .collect();
    let search_dir = workspace_dir
        .join("local-models")
        .join("llamacpp")
        .join(&model_dir_name);
    if search_dir.is_dir() {
        if let Ok(entries) = std::fs::read_dir(&search_dir) {
            for entry in entries.flatten() {
                let p = entry.path();
                if p.extension().is_some_and(|ext| ext == "gguf") && p.is_file() {
                    return Some(p.display().to_string());
                }
            }
        }
    }

    // Strategy 3: scan ALL model directories for any .gguf file
    let models_root = workspace_dir.join("local-models").join("llamacpp");
    if models_root.is_dir() {
        if let Ok(dirs) = std::fs::read_dir(&models_root) {
            for dir_entry in dirs.flatten() {
                if !dir_entry.path().is_dir() {
                    continue;
                }
                if let Ok(files) = std::fs::read_dir(dir_entry.path()) {
                    for file_entry in files.flatten() {
                        let p = file_entry.path();
                        if p.extension().is_some_and(|ext| ext == "gguf") && p.is_file() {
                            return Some(p.display().to_string());
                        }
                    }
                }
            }
        }
    }

    None
}

fn status_from_native_local_ai_state(saved: NativeLocalAiPersistedState) -> NativeLocalAiStatus {
    let mut model_path = saved.model_path.clone();
    let mut model_exists = std::path::Path::new(&model_path).is_file();

    // iOS app containers change UUID on update/reinstall.
    // If the saved absolute path is stale, try to reconstruct it
    // from the current workspace directory.
    if !model_exists {
        if let Some(repaired) = try_repair_model_path(&saved.model_id, &saved.model_path) {
            eprintln!(
                "[native-ai] repaired stale model path: {} -> {}",
                saved.model_path, repaired
            );
            model_path = repaired;
            model_exists = true;
        }
    }

    let engine_compiled = cfg!(feature = "native-inference");
    NativeLocalAiStatus {
        provider: NATIVE_LOCAL_AI_PROVIDER.to_string(),
        configured: true,
        available: engine_compiled && model_exists,
        running: false,
        state: if !model_exists {
            "model_missing".to_string()
        } else if engine_compiled {
            "configured".to_string()
        } else {
            "configured_engine_missing".to_string()
        },
        model_id: Some(saved.model_id),
        model_path: Some(model_path),
        api_url: NATIVE_LOCAL_AI_URL.to_string(),
        message: if !model_exists {
            "SlowClaw found a saved native local AI model selection, but the GGUF file is missing. Re-download the model."
                .to_string()
        } else if engine_compiled {
            "Model is ready for on-device inference. Tap 'Generate' on a journal entry to use local AI."
                .to_string()
        } else {
            "SlowClaw restored the selected native local AI model. The inference engine must be compiled with the native-inference feature."
                .to_string()
        },
        error: if model_exists && engine_compiled {
            None
        } else if !model_exists {
            Some("Downloaded model file was not found on this device.".to_string())
        } else {
            Some("Native local inference engine is not compiled into this build.".to_string())
        },
    }
}

#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
struct AppConfig {
    ollama_base_url: String,
    ollama_model: String,
    bluesky_handle: String,
    bluesky_service_url: String,
    transcription_enabled: bool,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
struct OllamaStatus {
    available: bool,
    base_url: String,
    model: String,
    models: Vec<String>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
struct LocalModelDownloadStatus {
    model: String,
    available: bool,
    message: String,
}

fn validate_secret_locator(service: &str, account: &str) -> Result<(), String> {
    if service.trim().is_empty() {
        return Err("service is required".to_string());
    }
    if account.trim().is_empty() {
        return Err("account is required".to_string());
    }
    Ok(())
}

fn ui_command_error(context: &str, user_message: &str, err: impl std::fmt::Display) -> String {
    eprintln!("{context}: {err}");
    user_message.to_string()
}

fn now_unix_millis_string() -> Result<String, String> {
    Ok(SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_err(|e| format!("system clock is before UNIX epoch: {e}"))?
        .as_millis()
        .to_string())
}

fn sanitize_journal_component(value: &str, fallback: &str) -> String {
    let mut out = String::new();
    for ch in value.chars() {
        if ch.is_ascii_alphanumeric() {
            out.push(ch.to_ascii_lowercase());
        } else if matches!(ch, '-' | '_' | '.') {
            out.push(ch);
        } else if ch.is_whitespace() {
            out.push('-');
        }
        if out.len() >= 80 {
            break;
        }
    }
    let trimmed = out.trim_matches(['-', '_', '.']);
    if trimmed.is_empty() {
        fallback.to_string()
    } else {
        trimmed.to_string()
    }
}

fn native_journal_index_dir(config: &zeroclaw::Config) -> PathBuf {
    config
        .workspace_dir
        .join("state")
        .join(NATIVE_JOURNAL_INDEX_DIR)
}

fn native_journal_record_path(config: &zeroclaw::Config, id: &str) -> PathBuf {
    native_journal_index_dir(config).join(format!("{id}.json"))
}

fn native_journal_text_path(config: &zeroclaw::Config, id: &str) -> PathBuf {
    config
        .workspace_dir
        .join("journals")
        .join("text")
        .join("mobile")
        .join(format!("{id}.md"))
}

fn native_journal_media_path(
    config: &zeroclaw::Config,
    kind: &str,
    id: &str,
    filename: &str,
) -> PathBuf {
    let extension = Path::new(filename)
        .extension()
        .and_then(|value| value.to_str())
        .map(|value| sanitize_journal_component(value, "bin"))
        .unwrap_or_else(|| "bin".to_string());
    config
        .workspace_dir
        .join("journals")
        .join("media")
        .join(kind)
        .join("mobile")
        .join(format!("{id}.{extension}"))
}

fn persist_native_journal_record(
    config: &zeroclaw::Config,
    record: &NativeJournalRecord,
) -> Result<(), String> {
    let path = native_journal_record_path(config, &record.id);
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent).map_err(|e| {
            ui_command_error(
                "native journal index create failed",
                "Failed to prepare local journal storage.",
                e,
            )
        })?;
    }
    let body = serde_json::to_vec_pretty(record).map_err(|e| {
        ui_command_error(
            "native journal record encode failed",
            "Failed to save the journal entry metadata.",
            e,
        )
    })?;
    std::fs::write(path, body).map_err(|e| {
        ui_command_error(
            "native journal record write failed",
            "Failed to save the journal entry metadata.",
            e,
        )
    })
}

fn load_native_journal_record(
    config: &zeroclaw::Config,
    id: &str,
) -> Result<NativeJournalRecord, String> {
    let safe_id = sanitize_journal_component(id, "");
    if safe_id.is_empty() || safe_id != id {
        return Err("Invalid journal entry id.".to_string());
    }
    let path = native_journal_record_path(config, id);
    let body = std::fs::read_to_string(path).map_err(|e| {
        ui_command_error(
            "native journal record read failed",
            "Failed to load the journal entry.",
            e,
        )
    })?;
    let mut record: NativeJournalRecord = serde_json::from_str(&body).map_err(|e| {
        ui_command_error(
            "native journal record decode failed",
            "Failed to load the journal entry.",
            e,
        )
    })?;
    if record.kind == "text" {
        if let Some(file_path) = record.file_path.as_deref() {
            if let Ok(content) = std::fs::read_to_string(file_path) {
                record.content = content;
            }
        }
    }
    Ok(record)
}

fn list_native_journal_records(
    config: &zeroclaw::Config,
) -> Result<Vec<NativeJournalRecord>, String> {
    let index_dir = native_journal_index_dir(config);
    if !index_dir.exists() {
        return Ok(Vec::new());
    }
    let mut records = Vec::new();
    let entries = std::fs::read_dir(index_dir).map_err(|e| {
        ui_command_error(
            "native journal index read failed",
            "Failed to load local journal entries.",
            e,
        )
    })?;
    for entry in entries.flatten() {
        let path = entry.path();
        if path.extension().and_then(|value| value.to_str()) != Some("json") {
            continue;
        }
        let Ok(body) = std::fs::read_to_string(&path) else {
            continue;
        };
        let Ok(mut record) = serde_json::from_str::<NativeJournalRecord>(&body) else {
            continue;
        };
        if record.kind == "text" {
            if let Some(file_path) = record.file_path.as_deref() {
                if let Ok(content) = std::fs::read_to_string(file_path) {
                    record.content = content;
                }
            }
        }
        records.push(record);
    }
    records.sort_by(|a, b| {
        b.updated_at
            .cmp(&a.updated_at)
            .then_with(|| b.id.cmp(&a.id))
    });
    Ok(records)
}

fn validate_journal_media_kind(kind: &str) -> Result<&'static str, String> {
    match kind.trim().to_ascii_lowercase().as_str() {
        "audio" => Ok("audio"),
        "video" => Ok("video"),
        "image" => Ok("image"),
        _ => Err("Unsupported journal media type.".to_string()),
    }
}

fn decode_journal_media_base64(data_b64: &str) -> Result<Vec<u8>, String> {
    let payload = data_b64
        .rsplit_once(',')
        .map(|(_, suffix)| suffix)
        .unwrap_or(data_b64)
        .trim();
    base64::engine::general_purpose::STANDARD
        .decode(payload)
        .map_err(|e| {
            ui_command_error(
                "journal media base64 decode failed",
                "Failed to save the media recording.",
                e,
            )
        })
}

fn lock_gateway_state<'a>(
    state: &'a Arc<Mutex<GatewayRuntimeState>>,
) -> Result<std::sync::MutexGuard<'a, GatewayRuntimeState>, String> {
    state
        .lock()
        .map_err(|_| "gateway state lock poisoned".to_string())
}

fn lock_openai_state<'a>(
    state: &'a Arc<Mutex<OpenAiDeviceCodeRuntimeState>>,
) -> Result<std::sync::MutexGuard<'a, OpenAiDeviceCodeRuntimeState>, String> {
    state
        .lock()
        .map_err(|_| "openai device-code state lock poisoned".to_string())
}

fn lock_native_local_ai_state<'a>(
    state: &'a Arc<Mutex<NativeLocalAiRuntimeState>>,
) -> Result<std::sync::MutexGuard<'a, NativeLocalAiRuntimeState>, String> {
    state
        .lock()
        .map_err(|_| "native local AI state lock poisoned".to_string())
}
fn snapshot_gateway_state(
    state: &Arc<Mutex<GatewayRuntimeState>>,
) -> Result<EmbeddedGatewayInfo, String> {
    let guard = lock_gateway_state(state)?;
    Ok(EmbeddedGatewayInfo {
        gateway_url: guard.gateway_url.clone(),
        running: guard.running,
        last_error: guard.last_error.clone(),
        provider_api_key_set: guard.provider_api_key_set,
    })
}

fn snapshot_openai_status(
    state: &Arc<Mutex<OpenAiDeviceCodeRuntimeState>>,
) -> Result<OpenAiDeviceCodeStatus, String> {
    let guard = lock_openai_state(state)?;
    Ok(guard.status.clone())
}

fn snapshot_native_local_ai_status(
    state: &Arc<Mutex<NativeLocalAiRuntimeState>>,
) -> Result<NativeLocalAiStatus, String> {
    let guard = lock_native_local_ai_state(state)?;
    Ok(guard.status.clone())
}

fn read_keyring_secret(service: &str, account: &str) -> Result<Option<String>, String> {
    let entry = keyring::Entry::new(service, account)
        .map_err(|e| format!("failed to open keyring entry: {e}"))?;
    match entry.get_password() {
        Ok(value) => {
            let trimmed = value.trim();
            if trimmed.is_empty() {
                Ok(None)
            } else {
                Ok(Some(trimmed.to_string()))
            }
        }
        Err(keyring::Error::NoEntry) => Ok(None),
        Err(e) => Err(format!("failed to read keyring secret: {e}")),
    }
}

fn provider_api_key_from_keyring() -> Result<Option<String>, String> {
    read_keyring_secret(PROVIDER_SECRET_SERVICE, PROVIDER_API_KEY_SECRET_ACCOUNT)
}

fn normalize_provider_id(provider: &str) -> String {
    let trimmed = provider.trim();
    let lowered = trimmed.to_ascii_lowercase();
    match lowered.as_str() {
        "openai_codex" | "codex" => "openai-codex".to_string(),
        _ => lowered,
    }
}

fn provider_api_key_from_keyring_for_provider(provider: &str) -> Result<Option<String>, String> {
    let normalized = normalize_provider_id(provider);
    if normalized == "openrouter" {
        if let Some(key) =
            read_keyring_secret(PROVIDER_SECRET_SERVICE, OPENROUTER_API_KEY_SECRET_ACCOUNT)?
        {
            return Ok(Some(key));
        }
    }
    provider_api_key_from_keyring()
}

fn discover_lan_ipv4() -> Option<String> {
    let socket = UdpSocket::bind("0.0.0.0:0").ok()?;
    socket.connect("8.8.8.8:80").ok()?;
    let addr = socket.local_addr().ok()?;
    match addr.ip() {
        IpAddr::V4(ipv4) if !ipv4.is_loopback() => Some(ipv4.to_string()),
        _ => None,
    }
}

fn parse_gateway_port(gateway_url: &str) -> u16 {
    let without_scheme = gateway_url
        .trim()
        .trim_start_matches("http://")
        .trim_start_matches("https://");
    let host_and_port = without_scheme.split('/').next().unwrap_or(without_scheme);
    host_and_port
        .rsplit_once(':')
        .and_then(|(_, port)| port.parse::<u16>().ok())
        .unwrap_or(42617)
}

fn resolve_mobile_gateway_url(desktop_gateway_url: &str) -> String {
    let port = parse_gateway_port(desktop_gateway_url);
    if let Some(ip) = discover_lan_ipv4() {
        return format!("http://{ip}:{port}");
    }
    desktop_gateway_url.to_string()
}

fn ensure_desktop_gateway_token() -> Result<String, String> {
    if let Some(token) = read_keyring_secret(
        PROVIDER_SECRET_SERVICE,
        DESKTOP_GATEWAY_TOKEN_SECRET_ACCOUNT,
    )? {
        return Ok(token);
    }

    let nanos = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_err(|e| format!("failed to derive desktop token timestamp: {e}"))?
        .as_nanos();
    let generated = format!("desktop-local-{nanos}");

    let entry = keyring::Entry::new(
        PROVIDER_SECRET_SERVICE,
        DESKTOP_GATEWAY_TOKEN_SECRET_ACCOUNT,
    )
    .map_err(|e| format!("failed to open desktop token key entry: {e}"))?;
    entry
        .set_password(&generated)
        .map_err(|e| format!("failed to persist desktop token: {e}"))?;
    Ok(generated)
}

async fn clear_provider_api_key_from_config() -> Result<(), String> {
    let mut config = zeroclaw::Config::load_or_init()
        .await
        .map_err(|e| format!("failed to load config: {e}"))?;
    if config.api_key.is_none() {
        return Ok(());
    }
    config.api_key = None;
    config
        .save()
        .await
        .map_err(|e| format!("failed to save config: {e}"))
}

async fn restart_embedded_gateway(
    shared: Arc<Mutex<GatewayRuntimeState>>,
) -> Result<EmbeddedGatewayInfo, String> {
    let old_gateway_handle = {
        let mut guard = lock_gateway_state(&shared)?;
        guard.running = false;
        guard.gateway_handle.take()
    };

    if let Some(handle) = old_gateway_handle {
        handle.abort();
        std::thread::sleep(Duration::from_millis(120));
    }

    let mut config = zeroclaw::Config::load_or_init()
        .await
        .map_err(|e| format!("failed to load config for embedded gateway: {e}"))?;
    let bind_host = "127.0.0.1".to_string();
    config.gateway.host = bind_host.clone();
    config.gateway.require_pairing = false;
    config.gateway.allow_public_bind = false;

    let normalized_provider =
        normalize_provider_id(config.default_provider.as_deref().unwrap_or(""));
    let key_from_keyring = provider_api_key_from_keyring_for_provider(
        config.default_provider.as_deref().unwrap_or(""),
    )?;
    if let Some(key) = key_from_keyring {
        // Prefer keyring key over config key, but do NOT clear the config
        // value — it serves as a fallback if keyring access fails later.
        config.api_key = Some(key);
    } else if normalized_provider != "openrouter"
        && config
            .api_key
            .as_deref()
            .map(str::trim)
            .is_some_and(|value| value.starts_with("sk-or-"))
    {
        config.api_key = None;
    }
    let provider_api_key_set = config
        .api_key
        .as_ref()
        .is_some_and(|value| !value.trim().is_empty());

    if normalized_provider == NATIVE_LOCAL_AI_PROVIDER {
        match load_native_local_ai_state(&config).await {
            Ok(Some(saved)) => {
                let mut model_path = saved.model_path.clone();
                // Auto-repair stale model path (iOS container UUID changes)
                if !std::path::Path::new(&model_path).is_file() {
                    if let Some(repaired) = try_repair_model_path(&saved.model_id, &model_path) {
                        eprintln!(
                            "[startup] repaired stale model path: {} -> {}",
                            model_path, repaired
                        );
                        model_path = repaired.clone();
                        // Persist the repaired path so next startup is fast
                        let _ = save_native_local_ai_state(
                            &config,
                            &NativeLocalAiPersistedState {
                                model_id: saved.model_id.clone(),
                                model_path: repaired,
                            },
                        )
                        .await;
                    }
                }
                sync_native_local_ai_env(&saved.model_id, &model_path);
            }
            Ok(None) => {}
            Err(err) => eprintln!("native local AI state restore failed: {err}"),
        }
    }

    let host = config.gateway.host.clone();
    let port = config.gateway.port;
    let gateway_url = format!("http://{}:{port}", host);

    {
        let mut guard = lock_gateway_state(&shared)?;
        guard.gateway_url = gateway_url.clone();
        guard.running = true;
        guard.last_error = None;
        guard.provider_api_key_set = provider_api_key_set;
    }

    let shared_for_gateway = shared.clone();
    let gateway_handle = tauri::async_runtime::spawn(async move {
        let result = zeroclaw::gateway::run_gateway(&host, port, config).await;
        if let Ok(mut guard) = shared_for_gateway.lock() {
            guard.running = false;
            guard.gateway_handle = None;
            if let Err(err) = result {
                guard.last_error = Some(err.to_string());
            }
        }
    });

    {
        let mut guard = lock_gateway_state(&shared)?;
        guard.gateway_handle = Some(gateway_handle);
    }

    snapshot_gateway_state(&shared)
}

async fn ensure_embedded_gateway_started(
    shared: Arc<Mutex<GatewayRuntimeState>>,
) -> Result<EmbeddedGatewayInfo, String> {
    let already_running = {
        let guard = lock_gateway_state(&shared)?;
        guard.running && guard.gateway_handle.is_some()
    };
    if already_running {
        return snapshot_gateway_state(&shared);
    }
    restart_embedded_gateway(shared).await
}

fn parse_openai_prefixed_value(line: &str, prefix: &str) -> Option<String> {
    line.strip_prefix(prefix)
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(ToOwned::to_owned)
}

fn is_local_callback_url(value: &str) -> bool {
    value.contains("://localhost:")
        || value.contains("://127.0.0.1:")
        || value.contains("://[::1]:")
}

fn extract_first_url(line: &str) -> Option<String> {
    for token in line.split_whitespace() {
        let token = token.trim_matches(|c: char| {
            c == '"'
                || c == '\''
                || c == '('
                || c == ')'
                || c == '['
                || c == ']'
                || c == ','
                || c == ';'
        });
        if token.starts_with("http://") || token.starts_with("https://") {
            return Some(token.to_string());
        }
    }
    None
}

async fn run_openai_auth_status_probe() -> Result<bool, String> {
    zeroclaw::has_openai_codex_auth(None)
        .await
        .map_err(|err| format!("failed to check OpenAI auth status ({err})"))
}

fn update_openai_status_from_line(
    state: &Arc<Mutex<OpenAiDeviceCodeRuntimeState>>,
    line: &str,
) -> Result<(), String> {
    let trimmed = line.trim();
    if trimmed.is_empty() {
        return Ok(());
    }

    let mut guard = lock_openai_state(state)?;
    let status = &mut guard.status;
    status.message = trimmed.to_string();

    if let Some(url) = parse_openai_prefixed_value(trimmed, "Visit:") {
        if !is_local_callback_url(&url) {
            status.state = "awaiting_user".to_string();
            status.verification_url = Some(url);
            status.error = None;
        }
    } else if let Some(code) = parse_openai_prefixed_value(trimmed, "Code:") {
        status.user_code = Some(code);
    } else if let Some(link) = parse_openai_prefixed_value(trimmed, "Fast link:") {
        if !is_local_callback_url(&link) {
            status.fast_link = Some(link);
        }
    } else if trimmed.starts_with("OpenAI device-code login started.") {
        status.state = "awaiting_user".to_string();
        status.error = None;
    } else if status.verification_url.is_none() {
        if let Some(url) = extract_first_url(trimmed) {
            if !is_local_callback_url(&url) {
                status.state = "awaiting_user".to_string();
                status.verification_url = Some(url);
                status.error = None;
            }
        }
    }

    Ok(())
}

fn workspace_root_dir() -> PathBuf {
    let tauri_manifest_dir = PathBuf::from(env!("CARGO_MANIFEST_DIR"));
    tauri_manifest_dir
        .parent()
        .and_then(|path| path.parent())
        .map(PathBuf::from)
        .unwrap_or(tauri_manifest_dir)
}

fn configure_app_owned_workspace(app: &tauri::App) {
    if std::env::var_os("ZEROCLAW_CONFIG_DIR").is_some() {
        return;
    }
    match app.path().app_data_dir() {
        Ok(app_data_dir) => {
            let config_dir = app_data_dir.join("zeroclaw");
            if let Err(err) = std::fs::create_dir_all(&config_dir) {
                eprintln!(
                    "failed to create app config directory {}: {err}",
                    config_dir.display()
                );
                return;
            }
            std::env::set_var("ZEROCLAW_CONFIG_DIR", &config_dir);
        }
        Err(err) => {
            eprintln!("failed to resolve app data directory: {err}");
        }
    }
}

async fn load_workspace_config_for_ui(context: &str) -> Result<zeroclaw::Config, String> {
    zeroclaw::Config::load_or_init()
        .await
        .map_err(|e| ui_command_error(context, "Failed to load the workspace configuration.", e))
}

fn unix_time_label() -> String {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|duration| duration.as_secs().to_string())
        .unwrap_or_else(|_| "0".to_string())
}

fn safe_filename(value: &str, fallback: &str) -> String {
    let cleaned: String = value
        .chars()
        .map(|ch| {
            if ch.is_ascii_alphanumeric() || matches!(ch, '.' | '-' | '_') {
                ch
            } else {
                '-'
            }
        })
        .collect();
    let trimmed = cleaned.trim_matches('-').trim();
    if trimmed.is_empty() {
        fallback.to_string()
    } else {
        trimmed.to_string()
    }
}

fn title_from_path(path: &Path) -> String {
    let raw = path.file_stem()
        .and_then(|value| value.to_str())
        .map(|value| value.replace(['-', '_'], " "))
        .filter(|value| !value.trim().is_empty())
        .unwrap_or_else(|| "Journal entry".to_string());
    // Strip leading Unix timestamp (10+ digits) prefix for cleaner display
    let trimmed = raw.trim_start();
    if trimmed.len() > 11 && trimmed.as_bytes().iter().take(10).all(|b| b.is_ascii_digit()) {
        let after_digits = trimmed.trim_start_matches(|c: char| c.is_ascii_digit());
        let title_part = after_digits.trim();
        if !title_part.is_empty() {
            return title_part.to_string();
        }
    }
    raw
}

fn media_kind_from_extension(path: &Path) -> Option<&'static str> {
    let extension = path
        .extension()
        .and_then(|value| value.to_str())
        .unwrap_or("")
        .to_ascii_lowercase();
    match extension.as_str() {
        "mp3" | "m4a" | "aac" | "ogg" | "wav" | "flac" | "webm" => Some("audio"),
        "mp4" | "m4v" | "mov" | "mkv" => Some("video"),
        "png" | "jpg" | "jpeg" | "gif" | "webp" | "heic" => Some("image"),
        _ => None,
    }
}

/// Map a media file extension to a MIME type. Falls back to a generic
/// octet-stream type so the webview can still build a blob URL.
fn media_mime_type_for_extension(path: &Path) -> &'static str {
    let extension = path
        .extension()
        .and_then(|value| value.to_str())
        .unwrap_or("")
        .to_ascii_lowercase();
    match extension.as_str() {
        "mp3" => "audio/mpeg",
        "m4a" => "audio/mp4",
        "aac" => "audio/aac",
        "ogg" => "audio/ogg",
        "wav" => "audio/wav",
        "flac" => "audio/flac",
        "webm" => "audio/webm",
        "mp4" | "m4v" | "mkv" => "video/mp4",
        "mov" => "video/quicktime",
        "png" => "image/png",
        "jpg" | "jpeg" => "image/jpeg",
        "gif" => "image/gif",
        "webp" => "image/webp",
        "heic" => "image/heic",
        _ => "application/octet-stream",
    }
}

fn rel_path_to_id(workspace_dir: &Path, path: &Path) -> Option<String> {
    path.strip_prefix(workspace_dir)
        .ok()
        .map(|rel| rel.to_string_lossy().replace('\\', "/"))
}

fn resolve_journal_id(workspace_dir: &Path, id: &str) -> Result<PathBuf, String> {
    let trimmed = id.trim().trim_start_matches('/');
    if trimmed.is_empty() || trimmed.contains("..") {
        return Err("Invalid journal id.".to_string());
    }
    let path = workspace_dir.join(trimmed);
    if !path.starts_with(workspace_dir) {
        return Err("Invalid journal id.".to_string());
    }
    Ok(path)
}

fn journal_entry_from_path(workspace_dir: &Path, path: &Path) -> Option<JournalEntry> {
    let id = rel_path_to_id(workspace_dir, path)?;
    if id.starts_with("journals/text/transcript/")
        || id.starts_with("journals/text/transcriptions/")
    {
        return None;
    }
    let kind = if id.starts_with("journals/media/") {
        media_kind_from_extension(path)?.to_string()
    } else {
        "text".to_string()
    };
    let metadata = std::fs::metadata(path).ok();
    let updated_at = metadata
        .and_then(|m| m.modified().ok())
        .and_then(|time| time.duration_since(UNIX_EPOCH).ok())
        .map(|duration| duration.as_secs().to_string())
        .unwrap_or_else(unix_time_label);
    let content = if kind == "text" {
        std::fs::read_to_string(path).unwrap_or_default()
    } else {
        String::new()
    };

    Some(JournalEntry {
        id,
        title: title_from_path(path),
        content,
        kind,
        file_path: Some(path.display().to_string()),
        created_at: updated_at.clone(),
        updated_at,
    })
}

fn collect_journal_files(root: &Path, out: &mut Vec<PathBuf>) {
    let Ok(entries) = std::fs::read_dir(root) else {
        return;
    };
    for entry in entries.flatten() {
        let path = entry.path();
        if path.is_dir() {
            collect_journal_files(&path, out);
        } else {
            out.push(path);
        }
    }
}

fn open_path_with_system_handler(path: &std::path::Path) -> Result<(), String> {
    #[cfg(target_os = "macos")]
    let mut command = {
        let mut command = Command::new("open");
        command.arg(path);
        command
    };

    #[cfg(target_os = "windows")]
    let mut command = {
        let mut command = Command::new("explorer");
        command.arg(path);
        command
    };

    #[cfg(all(unix, not(target_os = "macos")))]
    let mut command = {
        let mut command = Command::new("xdg-open");
        command.arg(path);
        command
    };

    let status = command
        .status()
        .map_err(|e| format!("failed to launch folder opener: {e}"))?;
    if status.success() {
        Ok(())
    } else {
        Err(format!(
            "folder opener exited with code {}",
            status.code().unwrap_or(-1)
        ))
    }
}

fn open_url_with_system_handler(url: &str) -> Result<(), String> {
    let trimmed = url.trim();
    if trimmed.is_empty() {
        return Err("url is required".to_string());
    }
    if !trimmed.starts_with("http://") && !trimmed.starts_with("https://") {
        return Err("only http(s) urls can be opened".to_string());
    }

    #[cfg(target_os = "macos")]
    let mut command = {
        let mut command = Command::new("open");
        command.arg(trimmed);
        command
    };

    #[cfg(target_os = "windows")]
    let mut command = {
        let mut command = Command::new("explorer");
        command.arg(trimmed);
        command
    };

    #[cfg(all(unix, not(target_os = "macos")))]
    let mut command = {
        let mut command = Command::new("xdg-open");
        command.arg(trimmed);
        command
    };

    let status = command
        .status()
        .map_err(|e| format!("failed to launch browser: {e}"))?;
    if status.success() {
        Ok(())
    } else {
        Err(format!(
            "browser opener exited with code {}",
            status.code().unwrap_or(-1)
        ))
    }
}

fn slowclaw_binary_next_to_current_exe() -> Option<PathBuf> {
    let current_exe = std::env::current_exe().ok()?;
    let file_name = if cfg!(target_os = "windows") {
        "slowclaw.exe"
    } else {
        "slowclaw"
    };
    let candidate = current_exe.with_file_name(file_name);
    candidate.exists().then_some(candidate)
}

fn spawn_output_reader<R: Read + Send + 'static>(reader: R, tx: mpsc::Sender<String>) {
    thread::spawn(move || {
        for line in BufReader::new(reader).lines().map_while(Result::ok) {
            if tx.send(line).is_err() {
                break;
            }
        }
    });
}

fn spawn_openai_device_login_process() -> Result<Child, String> {
    let auth_args = [
        "auth",
        "login",
        "--provider",
        OPENAI_DEVICE_LOGIN_PROVIDER,
        "--profile",
        OPENAI_DEVICE_LOGIN_PROFILE,
        "--device-code",
    ];

    let mut errors = Vec::new();

    if let Some(binary_path) = slowclaw_binary_next_to_current_exe() {
        let mut command = Command::new(&binary_path);
        command
            .args(auth_args)
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped());
        match command.spawn() {
            Ok(child) => return Ok(child),
            Err(err) => errors.push(format!("{}: {err}", binary_path.display())),
        }
    }

    let mut command = Command::new("slowclaw");
    command
        .args(auth_args)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    match command.spawn() {
        Ok(child) => return Ok(child),
        Err(err) => errors.push(format!("slowclaw: {err}")),
    }

    let workspace_dir = workspace_root_dir();
    let mut fallback = Command::new("cargo");
    fallback
        .args([
            "run",
            "--quiet",
            "--bin",
            "slowclaw",
            "--",
            "auth",
            "login",
            "--provider",
            OPENAI_DEVICE_LOGIN_PROVIDER,
            "--profile",
            OPENAI_DEVICE_LOGIN_PROFILE,
            "--device-code",
        ])
        .current_dir(workspace_dir)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    match fallback.spawn() {
        Ok(child) => Ok(child),
        Err(err) => {
            errors.push(format!("cargo run --bin slowclaw: {err}"));
            Err(format!(
                "failed to start OpenAI setup command ({})",
                errors.join("; ")
            ))
        }
    }
}

fn run_openai_device_login_worker(
    openai_state: Arc<Mutex<OpenAiDeviceCodeRuntimeState>>,
    gateway_state: Arc<Mutex<GatewayRuntimeState>>,
) {
    let mut child = match spawn_openai_device_login_process() {
        Ok(child) => child,
        Err(error) => {
            if let Ok(mut guard) = openai_state.lock() {
                guard.status = OpenAiDeviceCodeStatus {
                    state: "error".to_string(),
                    running: false,
                    completed: false,
                    message: "Failed to start OpenAI setup command.".to_string(),
                    verification_url: None,
                    user_code: None,
                    fast_link: None,
                    error: Some("Unable to start the OpenAI setup command.".to_string()),
                };
            }
            eprintln!("openai setup start failed: {error}");
            return;
        }
    };

    let (tx, rx) = mpsc::channel::<String>();
    if let Some(stdout) = child.stdout.take() {
        spawn_output_reader(stdout, tx.clone());
    }
    if let Some(stderr) = child.stderr.take() {
        spawn_output_reader(stderr, tx.clone());
    }
    drop(tx);

    loop {
        while let Ok(line) = rx.try_recv() {
            let _ = update_openai_status_from_line(&openai_state, &line);
        }

        match child.try_wait() {
            Ok(Some(exit_status)) => {
                for line in rx.try_iter() {
                    let _ = update_openai_status_from_line(&openai_state, &line);
                }

                if exit_status.success() {
                    if let Ok(mut guard) = openai_state.lock() {
                        guard.status.running = false;
                        guard.status.completed = true;
                        guard.status.state = "completed".to_string();
                        guard.status.error = None;
                        guard.status.message =
                            "OpenAI setup completed. Restarting gateway...".to_string();
                    }

                    let gateway_state_for_restart = gateway_state.clone();
                    tauri::async_runtime::spawn(async move {
                        if let Err(err) = restart_embedded_gateway(gateway_state_for_restart).await
                        {
                            eprintln!("failed to restart gateway after OpenAI setup: {err}");
                        }
                    });
                } else if let Ok(mut guard) = openai_state.lock() {
                    let code = exit_status.code().unwrap_or(-1);
                    guard.status.running = false;
                    guard.status.completed = false;
                    guard.status.state = "error".to_string();
                    guard.status.message = format!("OpenAI setup exited with code {code}.");
                    guard.status.error = Some(format!("process exited with code {code}"));
                }
                break;
            }
            Ok(None) => {
                thread::sleep(Duration::from_millis(120));
            }
            Err(err) => {
                if let Ok(mut guard) = openai_state.lock() {
                    guard.status.running = false;
                    guard.status.completed = false;
                    guard.status.state = "error".to_string();
                    guard.status.message =
                        "Failed while waiting for OpenAI setup command.".to_string();
                    guard.status.error =
                        Some("Unable to monitor the OpenAI setup command.".to_string());
                }
                eprintln!("openai setup wait failed: {err}");
                break;
            }
        }
    }
}

#[tauri::command]
fn get_secret(req: SecretGetRequest) -> Result<SecretGetResponse, String> {
    validate_secret_locator(&req.service, &req.account)?;
    let entry = keyring::Entry::new(req.service.trim(), req.account.trim()).map_err(|e| {
        ui_command_error(
            "secure storage open failed",
            "Failed to access secure storage.",
            e,
        )
    })?;

    match entry.get_password() {
        Ok(value) => Ok(SecretGetResponse { value: Some(value) }),
        Err(keyring::Error::NoEntry) => Ok(SecretGetResponse { value: None }),
        Err(e) => Err(ui_command_error(
            "secure storage read failed",
            "Failed to read the secure value.",
            e,
        )),
    }
}

#[tauri::command]
fn set_secret(req: SecretSetRequest) -> Result<(), String> {
    validate_secret_locator(&req.service, &req.account)?;
    if req.value.is_empty() {
        return Err("value is required".to_string());
    }
    let entry = keyring::Entry::new(req.service.trim(), req.account.trim()).map_err(|e| {
        ui_command_error(
            "secure storage open failed",
            "Failed to access secure storage.",
            e,
        )
    })?;
    entry.set_password(&req.value).map_err(|e| {
        ui_command_error(
            "secure storage write failed",
            "Failed to save the secure value.",
            e,
        )
    })
}

#[tauri::command]
fn delete_secret(req: SecretGetRequest) -> Result<(), String> {
    validate_secret_locator(&req.service, &req.account)?;
    let entry = keyring::Entry::new(req.service.trim(), req.account.trim()).map_err(|e| {
        ui_command_error(
            "secure storage open failed",
            "Failed to access secure storage.",
            e,
        )
    })?;
    match entry.delete_credential() {
        Ok(()) | Err(keyring::Error::NoEntry) => Ok(()),
        Err(e) => Err(ui_command_error(
            "secure storage delete failed",
            "Failed to delete the secure value.",
            e,
        )),
    }
}

#[tauri::command]
fn get_embedded_gateway_info(
    state: tauri::State<'_, GatewayState>,
) -> Result<EmbeddedGatewayInfo, String> {
    snapshot_gateway_state(&state.inner)
}

#[tauri::command]
fn generate_mobile_pairing_qr(
    state: tauri::State<'_, GatewayState>,
) -> Result<GatewayQrPayload, String> {
    let info = snapshot_gateway_state(&state.inner)?;
    let mobile_gateway_url = resolve_mobile_gateway_url(&info.gateway_url);
    let token = ensure_desktop_gateway_token().map_err(|e| {
        ui_command_error(
            "desktop gateway token generation failed",
            "Failed to prepare the desktop pairing token.",
            e,
        )
    })?;
    let qr_value = serde_json::to_string(&serde_json::json!({
        "gateway_url": mobile_gateway_url.clone(),
        "gatewayUrl": mobile_gateway_url.clone(),
        "token": token.clone(),
    }))
    .map_err(|e| {
        ui_command_error(
            "QR payload encode failed",
            "Failed to generate the pairing QR payload.",
            e,
        )
    })?;

    Ok(GatewayQrPayload {
        gateway_url: mobile_gateway_url,
        token,
        qr_value,
    })
}

#[tauri::command]
fn get_desktop_gateway_bootstrap(
    state: tauri::State<'_, GatewayState>,
) -> Result<DesktopGatewayBootstrap, String> {
    let info = snapshot_gateway_state(&state.inner)?;
    let token = ensure_desktop_gateway_token().map_err(|e| {
        ui_command_error(
            "desktop gateway token generation failed",
            "Failed to prepare the desktop gateway token.",
            e,
        )
    })?;
    Ok(DesktopGatewayBootstrap {
        gateway_url: info.gateway_url,
        token,
    })
}

#[tauri::command]
async fn restart_gateway_daemon(state: tauri::State<'_, GatewayState>) -> Result<String, String> {
    let _ = ensure_desktop_gateway_token().map_err(|e| {
        ui_command_error(
            "desktop gateway token generation failed",
            "Failed to prepare the desktop gateway token.",
            e,
        )
    })?;
    let info = restart_embedded_gateway(state.inner.clone())
        .await
        .map_err(|e| {
            ui_command_error(
                "gateway restart failed",
                "Failed to restart the desktop gateway.",
                e,
            )
        })?;
    Ok(info.gateway_url)
}

#[tauri::command]
async fn set_provider_api_key(
    state: tauri::State<'_, GatewayState>,
    value: String,
) -> Result<EmbeddedGatewayInfo, String> {
    let normalized = value.trim().to_string();
    let entry = keyring::Entry::new(PROVIDER_SECRET_SERVICE, PROVIDER_API_KEY_SECRET_ACCOUNT)
        .map_err(|e| {
            ui_command_error(
                "provider keyring open failed",
                "Failed to access the provider key store.",
                e,
            )
        })?;

    if normalized.is_empty() {
        match entry.delete_credential() {
            Ok(()) | Err(keyring::Error::NoEntry) => {}
            Err(e) => {
                return Err(ui_command_error(
                    "provider keyring delete failed",
                    "Failed to clear the provider API key.",
                    e,
                ))
            }
        }
    } else {
        entry.set_password(&normalized).map_err(|e| {
            ui_command_error(
                "provider keyring write failed",
                "Failed to save the provider API key.",
                e,
            )
        })?;
    }

    clear_provider_api_key_from_config().await.map_err(|e| {
        ui_command_error(
            "provider config cleanup failed",
            "Failed to update desktop configuration after saving the provider API key.",
            e,
        )
    })?;

    restart_embedded_gateway(state.inner.clone())
        .await
        .map_err(|e| {
            ui_command_error(
                "gateway restart failed",
                "Failed to restart the desktop gateway.",
                e,
            )
        })
}

#[tauri::command]
async fn open_workspace_journals_folder() -> Result<String, String> {
    let config = zeroclaw::Config::load_or_init().await.map_err(|e| {
        ui_command_error(
            "journals folder config load failed",
            "Failed to load the workspace configuration.",
            e,
        )
    })?;
    let journals_dir = config.workspace_dir.join("journals");
    for rel in ["", "text/inbox", "media/audio/inbox"] {
        let target = if rel.is_empty() {
            journals_dir.clone()
        } else {
            journals_dir.join(rel)
        };
        std::fs::create_dir_all(&target).map_err(|e| {
            ui_command_error(
                "journals folder create failed",
                "Failed to prepare the journals folder.",
                e,
            )
        })?;
    }
    open_path_with_system_handler(&journals_dir).map_err(|e| {
        ui_command_error(
            "journals folder open failed",
            "Failed to open the journals folder.",
            e,
        )
    })?;
    Ok(journals_dir.display().to_string())
}

#[tauri::command]
async fn save_journal_text(title: String, content: String) -> Result<JournalEntry, String> {
    let config = load_workspace_config_for_ui("journal text config load failed").await?;
    let body = content.trim();
    if body.is_empty() {
        return Err("Write something first.".to_string());
    }
    let timestamp = unix_time_label();
    let filename = format!(
        "{}-{}.txt",
        timestamp,
        safe_filename(&title, "journal-entry")
    );
    let path = config
        .workspace_dir
        .join("journals")
        .join("text")
        .join("inbox")
        .join(filename);
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent).map_err(|e| {
            ui_command_error(
                "journal text dir create failed",
                "Failed to prepare journal storage.",
                e,
            )
        })?;
    }
    std::fs::write(&path, format!("{body}\n")).map_err(|e| {
        ui_command_error(
            "journal text write failed",
            "Failed to save the journal note.",
            e,
        )
    })?;
    journal_entry_from_path(&config.workspace_dir, &path)
        .ok_or_else(|| "Failed to read saved journal note.".to_string())
}

#[tauri::command]
async fn save_journal_media(
    kind: String,
    filename: String,
    data_b64: String,
    title: Option<String>,
) -> Result<JournalEntry, String> {
    let config = load_workspace_config_for_ui("journal media config load failed").await?;
    let normalized_kind = match kind.trim().to_ascii_lowercase().as_str() {
        "audio" => "audio",
        "video" => "video",
        "image" => "image",
        _ => return Err("Unsupported media kind.".to_string()),
    };
    let timestamp = unix_time_label();
    let safe_name = safe_filename(&filename, &format!("{normalized_kind}-{timestamp}"));
    let path = config
        .workspace_dir
        .join("journals")
        .join("media")
        .join(normalized_kind)
        .join("inbox")
        .join(format!("{timestamp}-{safe_name}"));
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent).map_err(|e| {
            ui_command_error(
                "journal media dir create failed",
                "Failed to prepare media storage.",
                e,
            )
        })?;
    }
    use base64::Engine;
    let bytes = base64::engine::general_purpose::STANDARD
        .decode(data_b64.trim())
        .map_err(|e| {
            ui_command_error(
                "journal media decode failed",
                "Failed to read the recorded media.",
                e,
            )
        })?;
    std::fs::write(&path, bytes).map_err(|e| {
        ui_command_error(
            "journal media write failed",
            "Failed to save the media file.",
            e,
        )
    })?;
    let mut entry = journal_entry_from_path(&config.workspace_dir, &path)
        .ok_or_else(|| "Failed to read saved media.".to_string())?;
    if let Some(title) = title
        .map(|value| value.trim().to_string())
        .filter(|value| !value.is_empty())
    {
        entry.title = title;
    }
    Ok(entry)
}

#[tauri::command]
async fn list_journals(
    limit: Option<usize>,
    offset: Option<usize>,
) -> Result<Vec<JournalEntry>, String> {
    let config = load_workspace_config_for_ui("journal list config load failed").await?;
    let mut paths = Vec::new();
    collect_journal_files(
        &config.workspace_dir.join("journals").join("text"),
        &mut paths,
    );
    collect_journal_files(
        &config.workspace_dir.join("journals").join("media"),
        &mut paths,
    );
    paths.sort_by_key(|path| {
        std::fs::metadata(path)
            .and_then(|metadata| metadata.modified())
            .ok()
            .and_then(|time| time.duration_since(UNIX_EPOCH).ok())
            .map(|duration| std::cmp::Reverse(duration.as_secs()))
            .unwrap_or(std::cmp::Reverse(0))
    });
    let start = offset.unwrap_or(0);
    let take = limit.unwrap_or(300);
    Ok(paths
        .into_iter()
        .skip(start)
        .take(take)
        .filter_map(|path| journal_entry_from_path(&config.workspace_dir, &path))
        .collect())
}

#[tauri::command]
async fn get_journal(id: String) -> Result<JournalEntry, String> {
    let config = load_workspace_config_for_ui("journal read config load failed").await?;
    let path = resolve_journal_id(&config.workspace_dir, &id)?;
    journal_entry_from_path(&config.workspace_dir, &path)
        .ok_or_else(|| "Journal entry not found.".to_string())
}

#[tauri::command]
async fn update_journal_text(id: String, content: String) -> Result<JournalEntry, String> {
    let config = load_workspace_config_for_ui("journal update config load failed").await?;
    let path = resolve_journal_id(&config.workspace_dir, &id)?;
    if media_kind_from_extension(&path).is_some() {
        return Err("Only text journal entries can be edited directly.".to_string());
    }
    let body = content.trim();
    if body.is_empty() {
        return Err("Write something first.".to_string());
    }
    std::fs::write(&path, format!("{body}\n")).map_err(|e| {
        ui_command_error(
            "journal update write failed",
            "Failed to update the journal note.",
            e,
        )
    })?;
    journal_entry_from_path(&config.workspace_dir, &path)
        .ok_or_else(|| "Failed to read updated journal note.".to_string())
}

#[tauri::command]
async fn delete_journal(id: String) -> Result<(), String> {
    let config = load_workspace_config_for_ui("journal delete config load failed").await?;
    let path = resolve_journal_id(&config.workspace_dir, &id)?;
    std::fs::remove_file(&path).map_err(|e| {
        ui_command_error(
            "journal delete failed",
            "Failed to delete the journal entry.",
            e,
        )
    })
}

#[tauri::command]
async fn rename_journal(id: String, new_title: String) -> Result<JournalEntry, String> {
    let config = load_workspace_config_for_ui("journal rename config load failed").await?;
    let old_path = resolve_journal_id(&config.workspace_dir, &id)?;
    if !old_path.is_file() {
        return Err("Journal entry not found.".to_string());
    }
    let new_title_trimmed = new_title.trim();
    if new_title_trimmed.is_empty() {
        return Err("Title cannot be empty.".to_string());
    }
    // Keep the same timestamp prefix, replace the title part of the filename
    let filename = old_path.file_name().unwrap_or_default().to_string_lossy();
    let extension = old_path.extension().map(|e| e.to_string_lossy().to_string()).unwrap_or_else(|| "txt".to_string());
    // Filename format: {timestamp}-{title}.{ext}
    let new_filename = if let Some(dash_pos) = filename.find('-') {
        let timestamp_part = &filename[..dash_pos];
        format!("{}-{}.{}", timestamp_part, safe_filename(new_title_trimmed, "journal-entry"), extension)
    } else {
        format!("{}-{}.{}", unix_time_label(), safe_filename(new_title_trimmed, "journal-entry"), extension)
    };
    let new_path = old_path.parent().unwrap_or(&config.workspace_dir).join(&new_filename);
    if new_path != old_path {
        std::fs::rename(&old_path, &new_path).map_err(|e| {
            ui_command_error(
                "journal rename failed",
                "Failed to rename the journal entry.",
                e,
            )
        })?;
    }
    journal_entry_from_path(&config.workspace_dir, &new_path)
        .ok_or_else(|| "Failed to read renamed journal entry.".to_string())
}

#[tauri::command]
async fn get_config() -> Result<AppConfig, String> {
    let config = load_workspace_config_for_ui("app config load failed").await?;
    Ok(AppConfig {
        ollama_base_url: config
            .api_url
            .unwrap_or_else(|| "http://127.0.0.1:11434".to_string()),
        ollama_model: config
            .default_model
            .unwrap_or_else(|| "llama3.2".to_string()),
        bluesky_handle: String::new(),
        bluesky_service_url: "https://bsky.social".to_string(),
        transcription_enabled: config.transcription.enabled,
    })
}

#[tauri::command]
async fn save_config(config: AppConfig) -> Result<(), String> {
    let mut current = load_workspace_config_for_ui("app config save load failed").await?;
    current.default_provider = Some("ollama".to_string());
    current.default_model = Some(config.ollama_model.trim().to_string());
    current.api_url = Some(config.ollama_base_url.trim().to_string());
    current.transcription.enabled = config.transcription_enabled;
    current.save().await.map_err(|e| {
        ui_command_error(
            "app config save failed",
            "Failed to save the workspace configuration.",
            e,
        )
    })
}

fn installed_ollama_models() -> Vec<String> {
    let output = Command::new("ollama").arg("list").output();
    let Ok(output) = output else {
        return Vec::new();
    };
    if !output.status.success() {
        return Vec::new();
    }
    String::from_utf8_lossy(&output.stdout)
        .lines()
        .skip(1)
        .filter_map(|line| line.split_whitespace().next())
        .map(ToOwned::to_owned)
        .collect()
}

#[tauri::command]
async fn list_ollama_models() -> Result<Vec<String>, String> {
    Ok(installed_ollama_models())
}

#[tauri::command]
async fn check_ollama() -> Result<OllamaStatus, String> {
    let config = load_workspace_config_for_ui("ollama config load failed").await?;
    let models = installed_ollama_models();
    Ok(OllamaStatus {
        available: !models.is_empty() || Command::new("ollama").arg("--version").output().is_ok(),
        base_url: config
            .api_url
            .unwrap_or_else(|| "http://127.0.0.1:11434".to_string()),
        model: config
            .default_model
            .unwrap_or_else(|| "llama3.2".to_string()),
        models,
    })
}

#[tauri::command]
async fn download_ollama_model(model: String) -> Result<LocalModelDownloadStatus, String> {
    let model = model.trim();
    if model.is_empty() || model.contains(char::is_whitespace) {
        return Err("Pick a valid model name.".to_string());
    }
    let status = Command::new("ollama")
        .args(["pull", model])
        .status()
        .map_err(|e| {
            ui_command_error(
                "ollama pull start failed",
                "Failed to start the local model download.",
                e,
            )
        })?;
    if !status.success() {
        return Err("Local model download failed.".to_string());
    }
    Ok(LocalModelDownloadStatus {
        model: model.to_string(),
        available: true,
        message: format!("{model} is ready."),
    })
}

#[tauri::command]
fn open_external_url(url: String) -> Result<(), String> {
    open_url_with_system_handler(&url).map_err(|e| {
        ui_command_error(
            "external url open failed",
            "Failed to open the link in your browser.",
            e,
        )
    })
}

#[tauri::command]
async fn get_openai_device_code_status(
    state: tauri::State<'_, OpenAiDeviceCodeState>,
) -> Result<OpenAiDeviceCodeStatus, String> {
    let current = snapshot_openai_status(&state.inner)?;
    if current.running {
        return Ok(current);
    }

    let mut next = current;
    match run_openai_auth_status_probe().await {
        Ok(true) => {
            next.state = "authenticated".to_string();
            next.completed = true;
            next.running = false;
            next.message = "OpenAI auth is already configured for this workspace.".to_string();
            next.error = None;
        }
        Ok(false) => {
            if next.completed {
                next.completed = false;
            }
            if next.state == "authenticated" {
                next.state = "idle".to_string();
                next.message = "Not started.".to_string();
            }
        }
        Err(err) => {
            if next.state == "idle" || next.state == "authenticated" {
                next.state = "error".to_string();
                next.completed = false;
                next.message = "Unable to verify existing OpenAI auth status.".to_string();
                next.error = Some("Unable to verify existing OpenAI auth status.".to_string());
            }
            eprintln!("openai auth status probe failed: {err}");
        }
    }

    if let Ok(mut guard) = state.inner.lock() {
        guard.status = next.clone();
    }
    Ok(next)
}

#[tauri::command]
fn start_openai_device_code_login(
    state: tauri::State<'_, OpenAiDeviceCodeState>,
    gateway_state: tauri::State<'_, GatewayState>,
) -> Result<OpenAiDeviceCodeStatus, String> {
    {
        let mut guard = lock_openai_state(&state.inner)?;
        if guard.status.running {
            return Ok(guard.status.clone());
        }
        guard.status = OpenAiDeviceCodeStatus {
            state: "starting".to_string(),
            running: true,
            completed: false,
            message: "Starting OpenAI setup...".to_string(),
            verification_url: None,
            user_code: None,
            fast_link: None,
            error: None,
        };
    }

    let openai_state = state.inner.clone();
    let gateway_state = gateway_state.inner.clone();
    thread::spawn(move || {
        run_openai_device_login_worker(openai_state, gateway_state);
    });

    snapshot_openai_status(&state.inner)
}

#[tauri::command]
async fn get_anthropic_token_status() -> Result<AnthropicTokenStatus, String> {
    match zeroclaw::has_anthropic_auth(None).await {
        Ok(true) => Ok(AnthropicTokenStatus {
            is_set: true,
            message: "Claude auth token is configured for this workspace.".to_string(),
            error: None,
        }),
        Ok(false) => Ok(AnthropicTokenStatus {
            is_set: false,
            message: "No Claude auth token saved.".to_string(),
            error: None,
        }),
        Err(e) => Ok(AnthropicTokenStatus {
            is_set: false,
            message: "Unable to check Claude auth status.".to_string(),
            error: Some(format!("{e}")),
        }),
    }
}

#[tauri::command]
async fn save_anthropic_token(
    state: tauri::State<'_, GatewayState>,
    token: String,
) -> Result<AnthropicTokenStatus, String> {
    let trimmed = token.trim().to_string();
    if trimmed.is_empty() {
        return Err("Token cannot be empty.".to_string());
    }
    zeroclaw::save_anthropic_token(trimmed).await.map_err(|e| {
        ui_command_error(
            "anthropic token save failed",
            "Failed to save Claude token.",
            e,
        )
    })?;
    let _ = restart_embedded_gateway(state.inner.clone()).await;
    get_anthropic_token_status().await
}

#[tauri::command]
async fn clear_anthropic_token(
    state: tauri::State<'_, GatewayState>,
) -> Result<AnthropicTokenStatus, String> {
    zeroclaw::clear_anthropic_token().await.map_err(|e| {
        ui_command_error(
            "anthropic token clear failed",
            "Failed to clear Claude token.",
            e,
        )
    })?;
    let _ = restart_embedded_gateway(state.inner.clone()).await;
    get_anthropic_token_status().await
}

#[tauri::command]
async fn get_native_local_ai_status(
    state: tauri::State<'_, NativeLocalAiState>,
) -> Result<NativeLocalAiStatus, String> {
    let current = snapshot_native_local_ai_status(&state.inner)?;
    if current.configured {
        return Ok(current);
    }

    let config = zeroclaw::Config::load_or_init().await.map_err(|e| {
        ui_command_error(
            "native local AI config load failed",
            "Failed to load local AI config.",
            e,
        )
    })?;
    if let Some(saved) = load_native_local_ai_state(&config).await.map_err(|e| {
        ui_command_error(
            "native local AI state load failed",
            "Failed to load native local AI state.",
            e,
        )
    })? {
        sync_native_local_ai_env(&saved.model_id, &saved.model_path);
        let restored = status_from_native_local_ai_state(saved);
        {
            let mut guard = lock_native_local_ai_state(&state.inner)?;
            guard.status = restored.clone();
        }
        return Ok(restored);
    }

    Ok(current)
}

#[tauri::command]
async fn configure_native_local_ai(
    state: tauri::State<'_, NativeLocalAiState>,
    gateway_state: tauri::State<'_, GatewayState>,
    req: NativeLocalAiConfigureRequest,
) -> Result<NativeLocalAiStatus, String> {
    let model_id = req.model_id.trim().to_string();
    let model_path = req.model_path.trim().to_string();
    if model_id.is_empty() {
        return Err("model_id is required".to_string());
    }
    if model_path.is_empty() {
        return Err("model_path is required".to_string());
    }
    if !std::path::Path::new(&model_path).is_file() {
        return Err("Downloaded model file was not found on this device.".to_string());
    }

    let mut config = zeroclaw::Config::load_or_init().await.map_err(|e| {
        ui_command_error(
            "native local AI config load failed",
            "Failed to load local AI config.",
            e,
        )
    })?;
    config.default_provider = Some(NATIVE_LOCAL_AI_PROVIDER.to_string());
    config.default_model = Some(model_id.clone());
    config.api_url = None;
    config.save().await.map_err(|e| {
        ui_command_error(
            "native local AI config save failed",
            "Failed to save local AI config.",
            e,
        )
    })?;
    save_native_local_ai_state(
        &config,
        &NativeLocalAiPersistedState {
            model_id: model_id.clone(),
            model_path: model_path.clone(),
        },
    )
    .await
    .map_err(|e| {
        ui_command_error(
            "native local AI state save failed",
            "Failed to save native local AI state.",
            e,
        )
    })?;

    sync_native_local_ai_env(&model_id, &model_path);

    let engine_compiled = cfg!(feature = "native-inference");
    let status = NativeLocalAiStatus {
        provider: NATIVE_LOCAL_AI_PROVIDER.to_string(),
        configured: true,
        available: engine_compiled,
        running: false,
        state: if engine_compiled {
            "configured".to_string()
        } else {
            "configured_engine_missing".to_string()
        },
        model_id: Some(model_id),
        model_path: Some(model_path),
        api_url: NATIVE_LOCAL_AI_URL.to_string(),
        message: if engine_compiled {
            "Model configured. Tap 'Generate' on a journal entry to use on-device AI.".to_string()
        } else {
            "SlowClaw saved this model for the native iOS local AI provider. The inference engine must be compiled with the native-inference feature.".to_string()
        },
        error: if engine_compiled {
            None
        } else {
            Some("Native local inference engine is not compiled into this build.".to_string())
        },
    };

    {
        let mut guard = lock_native_local_ai_state(&state.inner)?;
        guard.status = status.clone();
    }

    let _ = restart_embedded_gateway(gateway_state.inner.clone()).await;
    Ok(status)
}

#[tauri::command]
fn show_main_window(window: tauri::Window) {
    #[cfg(not(mobile))]
    {
        if let Err(e) = window.show() {
            eprintln!("failed to show main window: {e}");
        }
    }

    #[cfg(mobile)]
    {
        let _ = window;
    }
}

#[tauri::command]
async fn native_ai_load_model(
    state: tauri::State<'_, NativeLocalAiState>,
) -> Result<String, String> {
    let status = snapshot_native_local_ai_status(&state.inner)?;
    let model_id = status.model_id.ok_or(
        "No model configured. Download and select a model from the Profile tab.",
    )?;
    let model_path = status.model_path.ok_or(
        "No model path configured. Download and select a model from the Profile tab.",
    )?;
    // Run model loading on a blocking thread to avoid blocking the async runtime
    tauri::async_runtime::spawn_blocking(move || {
        inference::load_model(&model_id, &model_path)
    })
    .await
    .map_err(|e| format!("Model load task failed: {e}"))?
}

#[tauri::command]
async fn native_ai_chat(
    state: tauri::State<'_, NativeLocalAiState>,
    prompt: String,
    system_prompt: Option<String>,
    max_tokens: Option<u32>,
    temperature: Option<f32>,
) -> Result<inference::InferenceResponse, String> {
    // Auto-load the model if not loaded yet
    if !inference::is_model_loaded() {
        let status = snapshot_native_local_ai_status(&state.inner)?;
        if let (Some(model_id), Some(model_path)) = (status.model_id, status.model_path) {
            tauri::async_runtime::spawn_blocking(move || {
                inference::load_model(&model_id, &model_path)
            })
            .await
            .map_err(|e| format!("Model load task failed: {e}"))??;
        } else {
            return Err(
                "No model configured. Download and select a model from the Profile tab."
                    .to_string(),
            );
        }
    }

    let req = inference::InferenceRequest {
        prompt,
        max_tokens: max_tokens.unwrap_or(512),
        temperature: temperature.unwrap_or(0.7),
        system_prompt,
    };

    tauri::async_runtime::spawn_blocking(move || inference::run_inference(&req))
        .await
        .map_err(|e| format!("Inference task failed: {e}"))?
}

#[tauri::command]
fn native_ai_engine_status() -> serde_json::Value {
    serde_json::json!({
        "engineAvailable": cfg!(feature = "native-inference"),
        "modelLoaded": inference::is_model_loaded(),
        "loadedModelId": inference::loaded_model_id(),
    })
}

#[tauri::command]
fn set_metal_mode(enabled: bool) {
    if enabled {
        std::env::set_var("SLOWCLAW_USE_METAL", "1");
    } else {
        std::env::remove_var("SLOWCLAW_USE_METAL");
    }
    eprintln!("[settings] Metal GPU mode set to: {enabled}");
    // Force model to reload on next inference to pick up the change
    // (dropping loaded model so it reloads with new gpu_layers)
    if enabled || !enabled {
        // Clear loaded model so next call to load_model uses new settings
        let _ = std::env::set_var("SLOWCLAW_METAL_CHANGED", "1");
    }
}

#[tauri::command]
async fn transcribe_audio(audio_path: String) -> Result<transcription::TranscriptionResult, String> {
    let path = audio_path.trim().to_string();
    if path.is_empty() {
        return Err("audio_path is required".to_string());
    }
    // Run on a blocking thread since the iOS API uses a sync wait
    tauri::async_runtime::spawn_blocking(move || transcription::transcribe_audio_file(&path))
        .await
        .map_err(|e| format!("transcription task failed: {e}"))?
}

#[derive(Serialize)]
struct JournalMediaBytes {
    #[serde(rename = "dataB64")]
    data_b64: String,
    #[serde(rename = "mimeType")]
    mime_type: String,
}

/// Transcribe a journal audio entry by its workspace-relative id.
///
/// Resolves the id to an absolute workspace path (rejecting traversal and any
/// path outside the workspace), validates it is an audio file, then delegates
/// to the shared on-device transcriber (`transcription::transcribe_audio_file`).
/// On iOS with `native-inference` this uses Speech.framework; elsewhere it
/// returns a clear error so the caller can fall back to the gateway path.
#[tauri::command]
async fn transcribe_journal_media(
    id: String,
) -> Result<transcription::TranscriptionResult, String> {
    let config = load_workspace_config_for_ui("journal transcribe config load failed").await?;
    let path = resolve_journal_id(&config.workspace_dir, &id)?;
    if !path.is_file() {
        return Err("Journal audio entry not found.".to_string());
    }
    if media_kind_from_extension(&path) != Some("audio") {
        return Err("Only audio journal entries can be transcribed.".to_string());
    }
    let abs_path = path.to_string_lossy().to_string();
    tauri::async_runtime::spawn_blocking(move || transcription::transcribe_audio_file(&abs_path))
        .await
        .map_err(|e| format!("transcription task failed: {e}"))?
}

/// Read a journal media entry's bytes by its workspace-relative id, returning
/// base64 + MIME so the webview can build a blob URL for an inline player.
///
/// Workspace-scoped via `resolve_journal_id` (traversal rejected). Restricted to
/// audio/video entries — text entries are read through the existing text paths.
#[tauri::command]
async fn read_journal_media_bytes(id: String) -> Result<JournalMediaBytes, String> {
    let config = load_workspace_config_for_ui("journal media read config load failed").await?;
    let path = resolve_journal_id(&config.workspace_dir, &id)?;
    if !path.is_file() {
        return Err("Journal media entry not found.".to_string());
    }
    match media_kind_from_extension(&path) {
        Some("audio") | Some("video") => {}
        _ => return Err("Only audio or video journal entries can be read.".to_string()),
    }
    let bytes = std::fs::read(&path).map_err(|e| {
        ui_command_error(
            "journal media read failed",
            "Failed to read the recording.",
            e,
        )
    })?;
    let data_b64 = base64::engine::general_purpose::STANDARD.encode(&bytes);
    let mime_type = media_mime_type_for_extension(&path).to_string();
    Ok(JournalMediaBytes {
        data_b64,
        mime_type,
    })
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    let gateway_state = GatewayState::default();
    let openai_state = OpenAiDeviceCodeState::default();
    let native_local_ai_state = NativeLocalAiState::default();
    tauri::Builder::default()
        .manage(gateway_state)
        .manage(openai_state)
        .manage(native_local_ai_state)
        .setup(|app| {
            configure_app_owned_workspace(app);
            let shared = app.state::<GatewayState>().inner.clone();
            tauri::async_runtime::spawn(async move {
                if let Err(err) = ensure_embedded_gateway_started(shared).await {
                    eprintln!("embedded gateway failed to start: {err}");
                }
            });
            Ok(())
        })
        .invoke_handler(tauri::generate_handler![
            get_secret,
            set_secret,
            delete_secret,
            get_embedded_gateway_info,
            generate_mobile_pairing_qr,
            get_desktop_gateway_bootstrap,
            restart_gateway_daemon,
            set_provider_api_key,
            save_journal_text,
            save_journal_media,
            list_journals,
            get_journal,
            update_journal_text,
            rename_journal,
            delete_journal,
            open_workspace_journals_folder,
            open_external_url,
            get_openai_device_code_status,
            start_openai_device_code_login,
            get_anthropic_token_status,
            save_anthropic_token,
            clear_anthropic_token,
            get_native_local_ai_status,
            configure_native_local_ai,
            get_config,
            save_config,
            list_ollama_models,
            check_ollama,
            download_ollama_model,
            show_main_window,
            native_ai_load_model,
            native_ai_chat,
            native_ai_engine_status,
            set_metal_mode,
            transcribe_audio,
            transcribe_journal_media,
            read_journal_media_bytes
        ])
        .run(tauri::generate_context!())
        .expect("error while running tauri app");
}
