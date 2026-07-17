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

pub mod commands;
mod inference;
mod ios_safari;
mod nostr_ingest;
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
/// Secure-storage locator for the Nostr key bundle (mirrors the frontend's
/// `secureStorage.ts` constants). The stored value is JSON:
/// `{"nsec","npub","secretKeyHex","publicKeyHex"}`.
const NOSTR_KEYS_SECRET_SERVICE: &str = "com.example.myskyposter";
const NOSTR_KEYS_SECRET_ACCOUNT: &str = "nostr.keys";

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

#[derive(Debug, Clone, Serialize)]
pub(crate) struct EmbeddedGatewayInfo {
    pub(crate) gateway_url: String,
    pub(crate) running: bool,
    pub(crate) last_error: Option<String>,
    pub(crate) provider_api_key_set: bool,
}

#[derive(Debug, Serialize)]
pub(crate) struct GatewayQrPayload {
    pub(crate) gateway_url: String,
    pub(crate) token: String,
    pub(crate) qr_value: String,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct DesktopGatewayBootstrap {
    pub(crate) gateway_url: String,
    pub(crate) token: String,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct OpenAiDeviceCodeStatus {
    pub(crate) state: String,
    pub(crate) running: bool,
    pub(crate) completed: bool,
    pub(crate) message: String,
    pub(crate) verification_url: Option<String>,
    pub(crate) user_code: Option<String>,
    pub(crate) fast_link: Option<String>,
    pub(crate) error: Option<String>,
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
pub(crate) struct GatewayRuntimeState {
    pub(crate) gateway_url: String,
    pub(crate) running: bool,
    pub(crate) last_error: Option<String>,
    pub(crate) provider_api_key_set: bool,
    pub(crate) gateway_handle: Option<JoinHandle<()>>,
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
pub(crate) struct GatewayState {
    pub(crate) inner: Arc<Mutex<GatewayRuntimeState>>,
}

#[derive(Debug, Default)]
pub(crate) struct OpenAiDeviceCodeRuntimeState {
    pub(crate) status: OpenAiDeviceCodeStatus,
}

#[derive(Clone, Default)]
pub(crate) struct OpenAiDeviceCodeState {
    pub(crate) inner: Arc<Mutex<OpenAiDeviceCodeRuntimeState>>,
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
pub(crate) struct NativeLocalAiState {
    pub(crate) inner: Arc<Mutex<NativeLocalAiRuntimeState>>,
}

/// Runtime state for the background Nostr ingester. Holds the persistent
/// client behind a tokio Mutex so publish commands can reuse the same relay
/// connections the ingester maintains.
#[derive(Debug)]
struct NostrIngestRuntimeState {
    running: bool,
    last_error: Option<String>,
    relays: Vec<String>,
    hashtag_channels: Vec<String>,
    events_ingested: i64,
    last_event_at: Option<String>,
    db_path: Option<PathBuf>,
    /// Wrapped client shared with publish commands. `None` when the ingester
    /// is stopped or failed to start.
    client: Arc<tokio::sync::Mutex<Option<Arc<nostr_sdk::Client>>>>,
    /// Background drain task handle.
    ingest_handle: Option<JoinHandle<()>>,
}

impl Default for NostrIngestRuntimeState {
    fn default() -> Self {
        Self {
            running: false,
            last_error: None,
            relays: nostr_ingest::DEFAULT_INGESTER_RELAYS
                .iter()
                .map(|s| (*s).to_string())
                .collect(),
            hashtag_channels: nostr_ingest::DEFAULT_HASHTAG_CHANNELS
                .iter()
                .map(|s| (*s).to_string())
                .collect(),
            events_ingested: 0,
            last_event_at: None,
            db_path: None,
            client: Arc::new(tokio::sync::Mutex::new(None)),
            ingest_handle: None,
        }
    }
}

#[derive(Clone, Default)]
pub(crate) struct NostrIngestState {
    pub(crate) inner: Arc<Mutex<NostrIngestRuntimeState>>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
struct NostrStoreStatus {
    running: bool,
    relays: Vec<String>,
    hashtag_channels: Vec<String>,
    events_ingested: i64,
    last_event_at: Option<String>,
    db_path: Option<String>,
    last_error: Option<String>,
}

#[derive(Debug, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
struct NostrQueryRequest {
    /// Hex pubkeys to filter on.
    #[serde(default)]
    authors: Vec<String>,
    /// Lowercase hashtag values (no `#`).
    #[serde(default)]
    hashtags: Vec<String>,
    /// Event kinds (e.g. 1, 30023).
    #[serde(default)]
    kinds: Vec<i64>,
    /// UNIX-seconds lower bound.
    #[serde(default)]
    since: Option<i64>,
    /// UNIX-seconds upper bound.
    #[serde(default)]
    until: Option<i64>,
    /// Cap on rows. Defaults to 50 server-side.
    #[serde(default)]
    limit: Option<usize>,
}

#[derive(Debug, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
struct NostrArticleQueryRequest {
    #[serde(default)]
    limit: Option<usize>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
struct NostrPublishResult {
    event_id: String,
    published: bool,
    error: Option<String>,
}

#[derive(Debug, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
struct VideoQueryRequest {
    /// Restrict to a source (`"bluesky"` or `"nostr"`). Empty = all sources.
    #[serde(default)]
    source: Option<String>,
    /// UNIX-seconds lower bound.
    #[serde(default)]
    since: Option<i64>,
    /// Cap on rows. Defaults to 50 server-side.
    #[serde(default)]
    limit: Option<usize>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
struct VideoStoreStatus {
    /// Always true once the store is initialized — there's no long-lived
    /// ingester task to track (unlike Nostr). The UI uses this as the gate.
    initialized: bool,
    total_count: i64,
    bluesky_count: i64,
    nostr_count: i64,
    last_received_at: Option<String>,
    db_path: Option<String>,
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
        slowclaw::providers::local_native::ENV_NATIVE_MODEL_ID,
        model_id,
    );
    std::env::set_var(
        slowclaw::providers::local_native::ENV_NATIVE_MODEL_PATH,
        model_path,
    );
}

fn native_local_ai_state_path(config: &slowclaw::Config) -> PathBuf {
    config
        .workspace_dir
        .join("state")
        .join("native_local_ai.json")
}

async fn save_native_local_ai_state(
    config: &slowclaw::Config,
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
    config: &slowclaw::Config,
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
/// previously saved absolute model paths stale. On desktop the workspace root
/// can likewise move. This function tries to reconstruct the path under the
/// *current* `workspace_dir` rather than a hardcoded home layout.
///
/// It also scans the models directory for any `.gguf` file matching the
/// model_id pattern as a last resort.
fn try_repair_model_path(model_id: &str, old_path: &str, workspace_dir: &Path) -> Option<String> {
    use slowclaw::gateway::handlers::model::{safe_local_model_dir_name, LOCAL_MODEL_DIR};

    // Reuse the canonical layout the catalog/downloader writes to so the
    // repair search stays in sync with the writer.
    let models_root = workspace_dir.join(LOCAL_MODEL_DIR);

    // Strategy 1: re-root the layout-relative suffix under the current
    // workspace. The marker is the models dir itself so this works on every
    // platform (iOS `…/zeroclaw/workspace/local-models/…`,
    // desktop `~/.slowclaw/workspace/local-models/…`, custom `ZEROCLAW_*`).
    if let Some(idx) = old_path.find(LOCAL_MODEL_DIR) {
        let suffix = &old_path[idx + LOCAL_MODEL_DIR.len()..];
        let candidate = models_root.join(suffix.trim_start_matches('/'));
        if candidate.is_file() {
            return Some(candidate.display().to_string());
        }
    }

    // Strategy 2: look for the GGUF by model_id in its models directory.
    let search_dir = models_root.join(safe_local_model_dir_name(model_id));
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

    // Strategy 3: scan ALL model directories for any .gguf file.
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

fn status_from_native_local_ai_state(
    saved: NativeLocalAiPersistedState,
    workspace_dir: &Path,
) -> NativeLocalAiStatus {
    let mut model_path = saved.model_path.clone();
    let mut model_exists = std::path::Path::new(&model_path).is_file();

    // iOS app containers change UUID on update/reinstall.
    // If the saved absolute path is stale, try to reconstruct it
    // from the current workspace directory.
    if !model_exists {
        if let Some(repaired) = try_repair_model_path(&saved.model_id, &saved.model_path, workspace_dir) {
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
pub(crate) struct AppConfig {
    pub(crate) ollama_base_url: String,
    pub(crate) ollama_model: String,
    pub(crate) bluesky_handle: String,
    pub(crate) bluesky_service_url: String,
    pub(crate) transcription_enabled: bool,
}

// Moved OllamaStatus and LocalModelDownloadStatus to commands/desktop.rs

fn validate_secret_locator(service: &str, account: &str) -> Result<(), String> {
    if service.trim().is_empty() {
        return Err("service is required".to_string());
    }
    if account.trim().is_empty() {
        return Err("account is required".to_string());
    }
    Ok(())
}

pub(crate) fn ui_command_error(
    context: &str,
    user_message: &str,
    err: impl std::fmt::Display,
) -> String {
    eprintln!("{context}: {err}");
    user_message.to_string()
}

fn lock_gateway_state<'a>(
    state: &'a Arc<Mutex<GatewayRuntimeState>>,
) -> Result<std::sync::MutexGuard<'a, GatewayRuntimeState>, String> {
    state
        .lock()
        .map_err(|_| "gateway state lock poisoned".to_string())
}

pub(crate) fn lock_openai_state<'a>(
    state: &'a Arc<Mutex<OpenAiDeviceCodeRuntimeState>>,
) -> Result<std::sync::MutexGuard<'a, OpenAiDeviceCodeRuntimeState>, String> {
    state
        .lock()
        .map_err(|_| "openai device-code state lock poisoned".to_string())
}

pub(crate) fn lock_native_local_ai_state<'a>(
    state: &'a Arc<Mutex<NativeLocalAiRuntimeState>>,
) -> Result<std::sync::MutexGuard<'a, NativeLocalAiRuntimeState>, String> {
    state
        .lock()
        .map_err(|_| "native local AI state lock poisoned".to_string())
}
pub(crate) fn snapshot_gateway_state(
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

pub(crate) fn snapshot_openai_status(
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

fn lock_nostr_ingest_state<'a>(
    state: &'a Arc<Mutex<NostrIngestRuntimeState>>,
) -> Result<std::sync::MutexGuard<'a, NostrIngestRuntimeState>, String> {
    state
        .lock()
        .map_err(|_| "nostr ingest state lock poisoned".to_string())
}

/// Build a serializable snapshot of the ingester status. Reads the live
/// `events_ingested` / `last_event_at` from the store so the count stays
/// current even when the background task hasn't updated state recently.
fn snapshot_nostr_ingest_status(
    state: &Arc<Mutex<NostrIngestRuntimeState>>,
) -> Result<NostrStoreStatus, String> {
    let guard = lock_nostr_ingest_state(state)?;
    Ok(NostrStoreStatus {
        running: guard.running,
        relays: guard.relays.clone(),
        hashtag_channels: guard.hashtag_channels.clone(),
        events_ingested: guard.events_ingested,
        last_event_at: guard.last_event_at.clone(),
        db_path: guard.db_path.as_ref().map(|p| p.display().to_string()),
        last_error: guard.last_error.clone(),
    })
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

pub(crate) fn resolve_mobile_gateway_url(desktop_gateway_url: &str) -> String {
    let port = parse_gateway_port(desktop_gateway_url);
    if let Some(ip) = discover_lan_ipv4() {
        return format!("http://{ip}:{port}");
    }
    desktop_gateway_url.to_string()
}

pub(crate) fn ensure_desktop_gateway_token() -> Result<String, String> {
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
    let mut config = slowclaw::Config::load_or_init()
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

pub(crate) async fn restart_embedded_gateway(
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

    let mut config = slowclaw::Config::load_or_init()
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
                    if let Some(repaired) =
                        try_repair_model_path(&saved.model_id, &model_path, &config.workspace_dir)
                    {
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
        let result = slowclaw::gateway::run_gateway(&host, port, config).await;
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
    slowclaw::has_openai_codex_auth(None)
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

pub(crate) async fn load_workspace_config_for_ui(
    context: &str,
) -> Result<slowclaw::Config, String> {
    slowclaw::Config::load_or_init()
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
    let raw = path
        .file_stem()
        .and_then(|value| value.to_str())
        .map(|value| value.replace(['-', '_'], " "))
        .filter(|value| !value.trim().is_empty())
        .unwrap_or_else(|| "Journal entry".to_string());
    // Strip leading Unix timestamp (10+ digits) prefix for cleaner display
    let trimmed = raw.trim_start();
    if trimmed.len() > 11
        && trimmed
            .as_bytes()
            .iter()
            .take(10)
            .all(|b| b.is_ascii_digit())
    {
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

/// Resolve the sidecar transcript path for a media journal entry.
///
/// Mirrors the JS `journalTranscriptPathForMediaPath` convention so the
/// native and web layers agree on where transcripts live: for a media file at
/// `journals/media/<name>.<ext>` the transcript is expected at
/// `journals/text/transcriptions/<name>.txt`, with a legacy fallback to
/// `journals/text/transcript/<name>.txt`. Returns `None` for non-media ids.
fn media_transcript_path(workspace_dir: &Path, media_id: &str) -> Option<PathBuf> {
    let normalized = media_id.trim_start_matches('/');
    let relative = normalized.strip_prefix("journals/media/")?;
    let stem = relative
        .rsplit_once('.')
        .map(|(stem, _)| stem)
        .unwrap_or(relative);
    let primary = workspace_dir
        .join("journals/text/transcriptions")
        .join(format!("{stem}.txt"));
    let legacy = workspace_dir
        .join("journals/text/transcript")
        .join(format!("{stem}.txt"));
    if primary.exists() {
        Some(primary)
    } else if legacy.exists() {
        Some(legacy)
    } else {
        None
    }
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
    // For text journals, read the note body. For media journals, surface the
    // sidecar transcript (when it exists) so voice/video capture feeds the same
    // text-based surfaces as written notes — topic extraction, search, ranking.
    // An untranscribed media entry keeps an empty body (same as before).
    let content = if kind == "text" {
        std::fs::read_to_string(path).unwrap_or_default()
    } else {
        media_transcript_path(workspace_dir, &id)
            .and_then(|transcript| std::fs::read_to_string(&transcript).ok())
            .unwrap_or_default()
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

pub(crate) fn open_path_with_system_handler(path: &std::path::Path) -> Result<(), String> {
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

pub(crate) fn open_url_with_system_handler(url: &str) -> Result<(), String> {
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

pub(crate) fn run_openai_device_login_worker(
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

// generate_mobile_pairing_qr, get_desktop_gateway_bootstrap, and restart_gateway_daemon moved to commands/desktop.rs

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

// open_workspace_journals_folder moved to commands/desktop.rs

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

/// Write a text file to a workspace-relative path (native, iOS-first).
///
/// Used to persist media-journal transcripts (`journals/text/transcriptions/...`)
/// WITHOUT routing through the desktop gateway HTTP API (`/api/library/save-text`),
/// which is not reliably reachable from the mobile runtime and caused
/// "Save failed (Load failed)" on iOS. Workspace-only: `resolve_journal_id`
/// rejects `..` and any resolved path that escapes `workspace_dir`, and the
/// transcript loader (`journal_entry_from_path`) reads back from this same path.
#[tauri::command]
async fn save_journal_text_file(path: String, content: String) -> Result<(), String> {
    let config = load_workspace_config_for_ui("journal text file save failed").await?;
    let resolved = resolve_journal_id(&config.workspace_dir, &path)?;
    if let Some(parent) = resolved.parent() {
        std::fs::create_dir_all(parent).map_err(|e| {
            ui_command_error(
                "journal text file dir create failed",
                "Failed to prepare the transcript storage folder.",
                e,
            )
        })?;
    }
    std::fs::write(&resolved, format!("{content}\n")).map_err(|e| {
        ui_command_error(
            "journal text file write failed",
            "Failed to save the transcript.",
            e,
        )
    })?;
    Ok(())
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

/// Import voice memos shared into the app via iOS file hand-off.
///
/// iOS places files shared through the share sheet ("Copy to SlowClaw",
/// enabled by `CFBundleDocumentTypes` in `Info.ios.plist`) into the app's
/// `Documents/Inbox/`. The user can also drop `.m4a` recordings into the
/// `Documents/Voice Memos/` folder shown in the Files app
/// (`UIFileSharingEnabled`).
///
/// This command scans both folders for audio files, MOVES each one into the
/// same workspace media inbox used by `save_journal_media`
/// (`journals/media/audio/inbox/`), and returns the resulting journal entries.
/// Moving (rather than copying) keeps the Inbox a one-way drop zone and
/// prevents re-importing the same file. The on-device transcription pipeline
/// then treats each imported memo exactly like an in-app recording.
#[tauri::command]
async fn import_voice_memos() -> Result<Vec<JournalEntry>, String> {
    let config = load_workspace_config_for_ui("voice memo import config load failed").await?;
    let home = std::env::var_os("HOME")
        .map(std::path::PathBuf::from)
        .ok_or_else(|| "HOME directory is not set.".to_string())?;

    // Must match `media_kind_from_extension`'s audio set so that
    // `journal_entry_from_path` recognizes the imported file as audio.
    const AUDIO_EXTS: &[&str] = &["m4a", "mp3", "aac", "ogg", "wav", "flac", "webm"];

    // iOS file hand-off locations:
    //  - Documents/Inbox       : "Copy to SlowClaw" share-sheet destination.
    //  - Documents/Voice Memos : manual drag-drop folder from the Files app.
    let sources = [
        home.join("Documents").join("Inbox"),
        home.join("Documents").join("Voice Memos"),
    ];

    let inbox_dir = config
        .workspace_dir
        .join("journals")
        .join("media")
        .join("audio")
        .join("inbox");
    std::fs::create_dir_all(&inbox_dir).map_err(|e| {
        ui_command_error(
            "voice memo inbox create failed",
            "Failed to prepare the voice memo storage.",
            e,
        )
    })?;

    // Recursively collect candidate audio files (dependency-free stack walk).
    let mut candidates: Vec<PathBuf> = Vec::new();
    for source in &sources {
        if !source.is_dir() {
            continue;
        }
        let mut stack = vec![source.clone()];
        while let Some(dir) = stack.pop() {
            let entries = match std::fs::read_dir(&dir) {
                Ok(read_dir) => read_dir,
                Err(_) => continue,
            };
            for entry in entries.flatten() {
                let path = entry.path();
                if path.is_dir() {
                    stack.push(path);
                    continue;
                }
                let is_audio = path
                    .extension()
                    .and_then(|ext| ext.to_str())
                    .map(|ext| AUDIO_EXTS.contains(&ext.to_ascii_lowercase().as_str()))
                    .unwrap_or(false);
                if is_audio {
                    candidates.push(path);
                }
            }
        }
    }

    if candidates.is_empty() {
        return Ok(Vec::new());
    }

    // Per-call timestamp + per-file index guarantees unique names within a bulk
    // import even if two memos share an original filename.
    let base_ts = unix_time_label();
    let mut imported: Vec<JournalEntry> = Vec::new();
    for (index, src) in candidates.into_iter().enumerate() {
        let original_name = src
            .file_name()
            .and_then(|name| name.to_str())
            .unwrap_or("voice-memo");
        let safe_name = safe_filename(original_name, &format!("voice-memo-{base_ts}-{index}"));
        let dest = inbox_dir.join(format!("{base_ts}-{index}-{safe_name}"));

        // Move first; fall back to copy+remove if rename fails (e.g. across
        // volumes). Skip a file on error rather than aborting the whole import.
        if std::fs::rename(&src, &dest).is_err() {
            if let Err(err) = std::fs::copy(&src, &dest).and_then(|_| std::fs::remove_file(&src)) {
                eprintln!("voice memo import skipped {}: {err}", src.display());
                continue;
            }
        }

        if let Some(entry) = journal_entry_from_path(&config.workspace_dir, &dest) {
            imported.push(entry);
        }
    }

    Ok(imported)
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
    })?;
    // Best-effort: clear the enrichment task map for the removed journal so the
    // loop never references a deleted file. Failure is non-fatal (the file is
    // already gone); a stale row would only re-seed a `pending` task that the
    // loop then skips when it can't read the file.
    if let Some(source_path) = rel_path_to_id(&config.workspace_dir, &path) {
        let _ = slowclaw::gateway::local_store::delete_journal_enrichment(
            &config.workspace_dir,
            &source_path,
        );
    }
    Ok(())
}

/// Stores AI-extracted interest keywords for a journal entry into the feed's
/// per-source triage-keywords slot, then marks the world feed dirty so the next
/// `load_world_feed` re-profiles from these keywords instead of the heuristic
/// extractor (see `feed::rebuild_interest_profile` — when `triage_keywords_json`
/// is non-empty, mode switches from `"local"` to `"triage"`).
///
/// `journal_id` is the same local id the UI tracks (`journals/...` relative).
/// `keywords` is a flat `Vec<String>` of lowercase public-vocabulary phrases.
/// `content_hash` is a short UI-supplied fingerprint of the journal text at
/// extraction time; a fresh hash defeats the `profile_input_hash` cache
/// short-circuit so the new keywords always take effect.
#[tauri::command]
async fn save_journal_interest_keywords(
    journal_id: String,
    keywords: Vec<String>,
    content_hash: String,
) -> Result<(), String> {
    let config = load_workspace_config_for_ui("journal interest keywords config load failed").await?;
    let path = resolve_journal_id(&config.workspace_dir, &journal_id)?;
    // Workspace-relative key with forward slashes — must match the path the feed
    // engine stores/reads in `feed_interest_sources` (see `collect_post_text_sources`).
    let Some(source_path) = rel_path_to_id(&config.workspace_dir, &path) else {
        return Err("Journal entry is outside the workspace.".to_string());
    };
    let triage_keywords_json = serde_json::to_string(&keywords)
        .map_err(|e| format!("Failed to serialize interest keywords: {e}"))?;
    // Preserve interest_id/title across re-extraction; blank profile_input_hash
    // forces `rebuild_interest_profile` to recompute (no cache short-circuit).
    let existing = slowclaw::gateway::local_store::get_feed_interest_source(
        &config.workspace_dir,
        &source_path,
    )
    .ok()
    .flatten();
    let record = slowclaw::gateway::local_store::FeedInterestSourceRecord {
        source_path: source_path.clone(),
        content_hash,
        profile_input_hash: String::new(),
        interest_id: existing.as_ref().and_then(|r| r.interest_id.clone()),
        title: existing
            .as_ref()
            .map(|r| r.title.clone())
            .unwrap_or_default(),
        triage_keywords_json,
        updated_at: unix_time_label(),
    };
    slowclaw::gateway::local_store::upsert_feed_interest_source(
        &config.workspace_dir,
        &record,
    )
    .map_err(|e| format!("Failed to store interest keywords: {e}"))?;
    slowclaw::feed::mark_world_feed_dirty(&config.workspace_dir)
        .map_err(|e| format!("Failed to mark feed dirty: {e}"))?;
    Ok(())
}

// ── journal_enrichment: per-journal AI/transcription task-status map ─────────
// The on-device enrichment loop (web/src/hooks/useJournalEnrichmentLoop.ts) is
// the primary writer. `source_path` is the workspace-relative journal key (the
// same key used by `feed_interest_sources`); these commands do no filesystem
// access, so traversal is moot, but `..` is rejected defensively.

/// Reject workspace-relative keys that look like an escape attempt. The
/// enrichment table uses `source_path` purely as a string PK (no fs access),
/// but we keep the defensive guard for consistency with other journal commands.
fn validate_enrichment_source_path(source_path: &str) -> Result<(), String> {
    if source_path.trim().is_empty() {
        return Err("source_path is required".to_string());
    }
    if source_path.contains("..") {
        return Err("Invalid journal path.".to_string());
    }
    Ok(())
}

/// The set of tasks the enrichment pipeline tracks per journal. Kept in sync
/// with the TS `EnrichmentTask` type and the table's `task` column.
const ENRICHMENT_TASKS: &[&str] = &["transcription", "title", "interests", "tweet"];

/// Validate that `task` is one of the known enrichment tasks.
fn validate_enrichment_task(task: &str) -> Result<(), String> {
    if !ENRICHMENT_TASKS.contains(&task) {
        return Err(format!("Unknown enrichment task: {task}"));
    }
    Ok(())
}

/// Insert a `pending` row for each task that does not yet exist for this journal
/// (idempotent — existing rows are preserved). This is how a new capture seeds
/// its task map and how the loop discovers work.
#[tauri::command]
async fn ensure_journal_enrichment(
    source_path: String,
    tasks: Option<Vec<String>>,
) -> Result<(), String> {
    validate_enrichment_source_path(&source_path)?;
    let config =
        load_workspace_config_for_ui("journal enrichment ensure config load failed").await?;
    // Validate caller-supplied tasks, or default to the full set. Own the
    // Strings here (borrowing across the match arm doesn't live long enough)
    // and map to &str for the accessor at the call site.
    let task_list: Vec<String> = match tasks {
        Some(ts) => {
            for t in &ts {
                validate_enrichment_task(t)?;
            }
            ts
        }
        None => ENRICHMENT_TASKS.iter().map(|s| s.to_string()).collect(),
    };
    let task_refs: Vec<&str> = task_list.iter().map(|s| s.as_str()).collect();
    slowclaw::gateway::local_store::ensure_journal_enrichment(
        &config.workspace_dir,
        &source_path,
        &task_refs,
    )
    .map_err(|e| format!("Failed to seed enrichment tasks: {e}"))?;
    Ok(())
}

/// Record the outcome of one task: `status` ∈ {pending, done, error, skipped},
/// with an optional `last_error` for failure diagnostics. Bumps `attempts` on
/// every non-`done` write so the loop's retry cap is enforceable.
#[tauri::command]
async fn set_journal_enrichment(
    source_path: String,
    task: String,
    status: String,
    last_error: Option<String>,
) -> Result<(), String> {
    validate_enrichment_source_path(&source_path)?;
    validate_enrichment_task(&task)?;
    match status.as_str() {
        "pending" | "done" | "error" | "skipped" => {}
        other => return Err(format!("Invalid enrichment status: {other}")),
    }
    let config =
        load_workspace_config_for_ui("journal enrichment set config load failed").await?;
    slowclaw::gateway::local_store::set_journal_enrichment(
        &config.workspace_dir,
        &source_path,
        &task,
        &status,
        last_error.as_deref(),
    )
    .map_err(|e| format!("Failed to set enrichment status: {e}"))?;
    Ok(())
}

/// Every enrichment row in the table — drives the AI Activity "Enrichment
/// progress" summary. Returns JSON objects with camelCase keys for the TS layer.
#[tauri::command]
async fn list_journal_enrichment() -> Result<Vec<serde_json::Value>, String> {
    let config =
        load_workspace_config_for_ui("journal enrichment list config load failed").await?;
    let rows = slowclaw::gateway::local_store::list_all_journal_enrichment(&config.workspace_dir)
        .map_err(|e| format!("Failed to list enrichment rows: {e}"))?;
    Ok(rows
        .into_iter()
        .map(|r| {
            serde_json::json!({
                "sourcePath": r.source_path,
                "task": r.task,
                "status": r.status,
                "attempts": r.attempts,
                "lastError": r.last_error,
                "lastRunAt": r.last_run_at,
                "updatedAt": r.updated_at,
            })
        })
        .collect())
}

/// Delete every enrichment row for a journal — invoked when the journal itself
/// is deleted, so the status map never references a removed file.
#[tauri::command]
async fn delete_journal_enrichment(source_path: String) -> Result<(), String> {
    validate_enrichment_source_path(&source_path)?;
    let config =
        load_workspace_config_for_ui("journal enrichment delete config load failed").await?;
    slowclaw::gateway::local_store::delete_journal_enrichment(&config.workspace_dir, &source_path)
        .map_err(|e| format!("Failed to delete enrichment rows: {e}"))?;
    Ok(())
}

/// Persist on-device-extracted card keywords (from 👍/👎 on Reads cards) into
/// the unified SQLite keyword store, replacing the old localStorage-only path.
/// `liked` become positive steering terms (polarity 0), `disliked` become
/// negative steering terms (polarity 1, persistent). Both then feed the Rust
/// ranker and — via `get_interest_profile` — the TS ranker. Marks the world
/// feed dirty so the ranker picks up the change on the next rebuild.
#[tauri::command]
async fn save_card_keywords(liked: Vec<String>, disliked: Vec<String>) -> Result<(), String> {
    let config = load_workspace_config_for_ui("card keywords config load failed").await?;
    let workspace_dir = &config.workspace_dir;
    let now = unix_time_label();

    // Liked → positive keywords. Modest weight (comparable to a strong
    // journal-derived topic) so an explicit like steers without drowning the
    // journal lens; re-liking reinforces.
    for raw in liked.iter().map(|s| s.trim()).filter(|s| !s.is_empty()) {
        let term = raw.to_ascii_lowercase();
        let existing = slowclaw::gateway::local_store::list_feed_keywords_by_polarity(
            workspace_dir,
            0,
        )
        .ok()
        .into_iter()
        .flatten()
        .find(|r| r.term == term);
        let (id, weight, first_seen, source_count) = match existing {
            Some(r) => (Some(r.id), (r.weight + 1.5).min(4.5), r.first_seen_at, r.source_count + 1),
            None => (None, 1.5_f64, now.clone(), 1),
        };
        slowclaw::gateway::local_store::upsert_feed_keyword(
            workspace_dir,
            &slowclaw::gateway::local_store::FeedKeywordUpsert {
                id,
                term,
                weight,
                first_seen_at: first_seen,
                last_seen_at: now.clone(),
                source_count,
                polarity: 0,
            },
        )
        .map_err(|e| format!("Failed to store liked keyword: {e}"))?;
    }

    // Disliked → negative keywords. Persistent (no decay); a fixed weight since
    // the penalty fn only tests membership, not magnitude. Re-disliking is a
    // no-op (INSERT ON CONFLICT overwrites with the same weight).
    for raw in disliked.iter().map(|s| s.trim()).filter(|s| !s.is_empty()) {
        let term = raw.to_ascii_lowercase();
        slowclaw::gateway::local_store::upsert_feed_keyword(
            workspace_dir,
            &slowclaw::gateway::local_store::FeedKeywordUpsert {
                id: None,
                term,
                weight: 1.0_f64,
                first_seen_at: now.clone(),
                last_seen_at: now.clone(),
                source_count: 1,
                polarity: 1,
            },
        )
        .map_err(|e| format!("Failed to store disliked keyword: {e}"))?;
    }

    slowclaw::feed::mark_world_feed_dirty(workspace_dir)
        .map_err(|e| format!("Failed to mark feed dirty: {e}"))?;
    Ok(())
}

/// The unified interest profile for the TS ranker + lens UI. One read hydrates
/// everything: positive keywords (with lens multipliers applied), negative
/// keywords, the raw overrides map, and manual interests. This is the single
/// source the frontend reads on mount + on `slowclaw:lens-change`.
#[derive(serde::Serialize)]
#[serde(rename_all = "camelCase")]
struct InterestProfileSnapshot {
    /// Positive steering terms with lens multipliers already applied.
    positives: Vec<LensTerm>,
    /// Negative (disliked) steering terms.
    negatives: Vec<LensTerm>,
    /// Raw override map: term → multiplier (for the lens UI state).
    overrides: Vec<LensOverrideEntry>,
    /// Manual interests the journals haven't surfaced yet.
    manual: Vec<String>,
}

#[derive(serde::Serialize)]
#[serde(rename_all = "camelCase")]
struct LensTerm {
    label: String,
    /// Effective weight after lens multiplier (positives only).
    weight: f64,
}

#[derive(serde::Serialize)]
struct LensOverrideEntry {
    term: String,
    multiplier: f64,
}

#[tauri::command]
async fn get_interest_profile() -> Result<InterestProfileSnapshot, String> {
    let config = load_workspace_config_for_ui("interest profile config load failed").await?;
    let workspace_dir = &config.workspace_dir;

    let overrides_map: std::collections::HashMap<String, f64> =
        slowclaw::gateway::local_store::list_feed_lens_overrides(workspace_dir)
            .map_err(|e| format!("Failed to read lens overrides: {e}"))?
            .into_iter()
            .map(|r| (r.term, r.multiplier))
            .collect();
    let manual: Vec<String> = slowclaw::gateway::local_store::list_feed_manual_interests(workspace_dir)
        .map_err(|e| format!("Failed to read manual interests: {e}"))?
        .into_iter()
        .map(|r| r.term)
        .collect();
    let manual_set: std::collections::HashSet<String> = manual.iter().cloned().collect();

    // Positives: derived keywords + manual interests, with lens multipliers
    // applied (mute drops, boost doubles). Mirrors rebuild_interest_profile.
    let mut positives: Vec<LensTerm> = Vec::new();
    for kw in slowclaw::gateway::local_store::list_feed_keywords_by_polarity(workspace_dir, 0)
        .map_err(|e| format!("Failed to read positive keywords: {e}"))?
    {
        let mult = overrides_map.get(&kw.term).copied().unwrap_or(1.0);
        if mult <= 0.0 {
            continue;
        }
        let effective = mult.clamp(0.0, 2.0);
        positives.push(LensTerm {
            label: kw.term,
            weight: kw.weight * effective,
        });
    }
    for term in &manual_set {
        if positives.iter().any(|p| p.label.eq_ignore_ascii_case(term)) {
            continue;
        }
        let mult = overrides_map.get(term).copied().unwrap_or(1.0);
        if mult <= 0.0 {
            continue;
        }
        let effective = mult.clamp(0.0, 2.0);
        positives.push(LensTerm {
            label: term.clone(),
            weight: 3.0 * effective,
        });
    }

    let negatives: Vec<LensTerm> = slowclaw::gateway::local_store::list_feed_keywords_by_polarity(workspace_dir, 1)
        .map_err(|e| format!("Failed to read negative keywords: {e}"))?
        .into_iter()
        .map(|kw| LensTerm { label: kw.term, weight: kw.weight })
        .collect();

    let overrides = overrides_map
        .into_iter()
        .map(|(term, multiplier)| LensOverrideEntry { term, multiplier })
        .collect();

    Ok(InterestProfileSnapshot {
        positives,
        negatives,
        overrides,
        manual,
    })
}

#[tauri::command]
async fn set_lens_override(term: String, multiplier: f64) -> Result<(), String> {
    let config = load_workspace_config_for_ui("set lens override config load failed").await?;
    slowclaw::gateway::local_store::set_feed_lens_override(&config.workspace_dir, &term, multiplier)
        .map_err(|e| format!("Failed to set lens override: {e}"))?;
    slowclaw::feed::mark_world_feed_dirty(&config.workspace_dir)
        .map_err(|e| format!("Failed to mark feed dirty: {e}"))?;
    Ok(())
}

#[tauri::command]
async fn remove_lens_override(term: String) -> Result<(), String> {
    let config = load_workspace_config_for_ui("remove lens override config load failed").await?;
    slowclaw::gateway::local_store::remove_feed_lens_override(&config.workspace_dir, &term)
        .map_err(|e| format!("Failed to remove lens override: {e}"))?;
    slowclaw::feed::mark_world_feed_dirty(&config.workspace_dir)
        .map_err(|e| format!("Failed to mark feed dirty: {e}"))?;
    Ok(())
}

#[tauri::command]
async fn add_manual_interest(term: String) -> Result<(), String> {
    let config = load_workspace_config_for_ui("add manual interest config load failed").await?;
    slowclaw::gateway::local_store::add_feed_manual_interest(&config.workspace_dir, &term)
        .map_err(|e| format!("Failed to add manual interest: {e}"))?;
    slowclaw::feed::mark_world_feed_dirty(&config.workspace_dir)
        .map_err(|e| format!("Failed to mark feed dirty: {e}"))?;
    Ok(())
}

#[tauri::command]
async fn remove_manual_interest(term: String) -> Result<(), String> {
    let config = load_workspace_config_for_ui("remove manual interest config load failed").await?;
    slowclaw::gateway::local_store::remove_feed_manual_interest(&config.workspace_dir, &term)
        .map_err(|e| format!("Failed to remove manual interest: {e}"))?;
    slowclaw::feed::mark_world_feed_dirty(&config.workspace_dir)
        .map_err(|e| format!("Failed to mark feed dirty: {e}"))?;
    Ok(())
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
    let extension = old_path
        .extension()
        .map(|e| e.to_string_lossy().to_string())
        .unwrap_or_else(|| "txt".to_string());
    // Filename format: {timestamp}-{title}.{ext}
    let new_filename = if let Some(dash_pos) = filename.find('-') {
        let timestamp_part = &filename[..dash_pos];
        format!(
            "{}-{}.{}",
            timestamp_part,
            safe_filename(new_title_trimmed, "journal-entry"),
            extension
        )
    } else {
        format!(
            "{}-{}.{}",
            unix_time_label(),
            safe_filename(new_title_trimmed, "journal-entry"),
            extension
        )
    };
    let new_path = old_path
        .parent()
        .unwrap_or(&config.workspace_dir)
        .join(&new_filename);
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

pub(crate) fn installed_ollama_models() -> Vec<String> {
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

// list_ollama_models, check_ollama, download_ollama_model, and open_external_url moved to commands/desktop.rs

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

// start_openai_device_code_login moved to commands/desktop.rs

#[tauri::command]
async fn get_anthropic_token_status() -> Result<AnthropicTokenStatus, String> {
    match slowclaw::has_anthropic_auth(None).await {
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
    slowclaw::save_anthropic_token(trimmed).await.map_err(|e| {
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
    slowclaw::clear_anthropic_token().await.map_err(|e| {
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

    let config = slowclaw::Config::load_or_init().await.map_err(|e| {
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
        let restored = status_from_native_local_ai_state(saved, &config.workspace_dir);
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

    let mut config = slowclaw::Config::load_or_init().await.map_err(|e| {
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

/// Clear the configured native local AI model: remove the persisted config
/// (`state/native_local_ai.json`), reset the in-memory status to the
/// unconfigured default, drop any loaded model from memory, and unset the
/// provider env vars. Does NOT delete the GGUF file — call
/// [`delete_local_model`] for that. Returns the refreshed status so the UI
/// can update.
#[tauri::command]
async fn clear_native_local_ai(
    state: tauri::State<'_, NativeLocalAiState>,
    gateway_state: tauri::State<'_, GatewayState>,
) -> Result<NativeLocalAiStatus, String> {
    clear_native_local_ai_impl(state.inner.clone(), gateway_state.inner.clone()).await
}

/// Shared implementation of "clear the active native local AI model". Takes the
/// inner `Arc` clones directly so it can be reused by [`delete_local_model`]
/// without constructing a `tauri::State`.
async fn clear_native_local_ai_impl(
    native_state: Arc<Mutex<NativeLocalAiRuntimeState>>,
    gateway_state: Arc<Mutex<GatewayRuntimeState>>,
) -> Result<NativeLocalAiStatus, String> {
    let config = load_workspace_config_for_ui("native local AI clear config load failed").await?;

    // 1. Unload the model from memory (frees the mmap'd GGUF + KV cache) so
    //    the frontend can safely delete the file without a held lock.
    tauri::async_runtime::spawn_blocking(inference::unload_model)
        .await
        .map_err(|e| format!("Model unload task failed: {e}"))?;

    // 2. Delete the persisted config so a restart doesn't restore a model the
    //    user just removed. Missing file is not an error (already cleared).
    let state_path = native_local_ai_state_path(&config);
    let _ = std::fs::remove_file(&state_path);

    // 3. Unset the provider env vars so nothing points at the removed model.
    std::env::remove_var(slowclaw::providers::local_native::ENV_NATIVE_MODEL_ID);
    std::env::remove_var(slowclaw::providers::local_native::ENV_NATIVE_MODEL_PATH);

    // 4. Reset the in-memory status to the unconfigured default.
    let status = default_native_local_ai_status();
    {
        let mut guard = lock_native_local_ai_state(&native_state)?;
        guard.status = status.clone();
    }

    let _ = restart_embedded_gateway(gateway_state).await;
    Ok(status)
}

/// Delete an on-device model: unloads it from memory if active, clears the
/// persisted native local AI config if this model is the configured one, then
/// removes the GGUF file from disk. Missing file is not an error. Returns the
/// refreshed status so the UI can update without a separate gateway poll.
///
/// This is the delete path for the Settings "Delete Model" button. It does the
/// file removal server-side via `std::fs` (not the `tauri-plugin-fs` frontend
/// path, which requires a separately-registered plugin + permission scope).
#[tauri::command]
async fn delete_local_model(
    model_id: String,
    state: tauri::State<'_, NativeLocalAiState>,
    gateway_state: tauri::State<'_, GatewayState>,
) -> Result<NativeLocalAiStatus, String> {
    use slowclaw::gateway::handlers::model::{
        find_local_model_spec, local_model_file_path, safe_local_model_dir_name,
    };
    let config =
        load_workspace_config_for_ui("native local AI delete model config load failed").await?;

    // Resolve the GGUF path. Catalog models resolve via their spec; any other
    // id (sideloaded) falls back to the sanitized-dir convention so deletion
    // still works for non-catalog entries. We don't know the exact file_name
    // for sideloaded ids, so for those we delete the whole model dir instead.
    let workspace_dir = &config.workspace_dir;
    let (file_target, dir_target): (Option<PathBuf>, Option<PathBuf>) =
        match find_local_model_spec(&model_id) {
            Some(spec) => (Some(local_model_file_path(workspace_dir, spec)), None),
            None => {
                // Sideloaded/unknown id: target its sanitized directory.
                let dir = workspace_dir
                    .join("local-models/llamacpp")
                    .join(safe_local_model_dir_name(&model_id));
                (None, Some(dir))
            }
        };

    // 1. If this model is the active config, unload it from memory and clear
    //    the config so we never leave a stale path pointing at a deleted file.
    let active_status = snapshot_native_local_ai_status(&state.inner)?;
    let was_active = active_status.model_id.as_deref() == Some(model_id.as_str());
    let status = if was_active {
        clear_native_local_ai_impl(state.inner.clone(), gateway_state.inner.clone()).await?
    } else {
        // Still unload any loaded model to be safe (no-op if a different model
        // or none is loaded), so the OS file handle is released before unlink.
        let _ = tauri::async_runtime::spawn_blocking(inference::unload_model)
            .await
            .map_err(|e| format!("Model unload task failed: {e}"));
        active_status
    };

    // 2. Remove the GGUF file (or the model dir for sideloaded ids).
    if let Some(path) = &file_target {
        match std::fs::remove_file(path) {
            Ok(()) => {}
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => {
                // Already gone — not an error. Config was cleared above.
            }
            Err(e) => {
                return Err(format!("Failed to remove model file: {e}"));
            }
        }
    }
    if let Some(dir) = &dir_target {
        match std::fs::remove_dir_all(dir) {
            Ok(()) => {}
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
            Err(e) => {
                return Err(format!("Failed to remove model directory: {e}"));
            }
        }
    }

    Ok(status)
}

// show_main_window moved to commands/desktop.rs

#[tauri::command]
async fn native_ai_load_model(
    state: tauri::State<'_, NativeLocalAiState>,
) -> Result<String, String> {
    let status = snapshot_native_local_ai_status(&state.inner)?;
    let model_id = status
        .model_id
        .ok_or("No model configured. Download and select a model from the Profile tab.")?;
    let model_path = status
        .model_path
        .ok_or("No model path configured. Download and select a model from the Profile tab.")?;
    // Run model loading on a blocking thread to avoid blocking the async runtime
    tauri::async_runtime::spawn_blocking(move || inference::load_model(&model_id, &model_path))
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
    // (dropping loaded model so it reloads with new gpu_layers). Toggling
    // the setting in either direction always warrants a reload, so set the
    // change flag unconditionally — `load_model` clears it once applied.
    std::env::set_var("SLOWCLAW_METAL_CHANGED", "1");
}

#[tauri::command]
async fn transcribe_audio(
    audio_path: String,
) -> Result<transcription::TranscriptionResult, String> {
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

/// Resolve the workspace_dir for a Nostr-store command. Centralized so every
/// command uses the same error wording.
async fn nostr_workspace_dir() -> Result<PathBuf, String> {
    let config = load_workspace_config_for_ui("nostr store").await?;
    Ok(config.workspace_dir.clone())
}

#[tauri::command]
async fn nostr_store_status(
    state: tauri::State<'_, NostrIngestState>,
) -> Result<NostrStoreStatus, String> {
    // Refresh counts from the store so the UI sees live progress.
    let workspace = nostr_workspace_dir().await.ok();
    if let Some(ws) = workspace {
        let ws_clone = ws.clone();
        let (count, last) = tauri::async_runtime::spawn_blocking(move || {
            let count = nostr_ingest::event_count(&ws_clone).unwrap_or(0);
            let last = nostr_ingest::last_received_at(&ws_clone).ok().flatten();
            (count, last)
        })
        .await
        .map_err(|e| format!("nostr status task failed: {e}"))?;
        if let Ok(mut guard) = state.inner.lock() {
            guard.events_ingested = count;
            guard.last_event_at = last;
        }
    }
    snapshot_nostr_ingest_status(&state.inner)
}

#[tauri::command]
async fn nostr_query_notes(
    req: NostrQueryRequest,
) -> Result<Vec<slowclaw::nostr_store::NoteRecord>, String> {
    let workspace = nostr_workspace_dir().await?;
    let query = slowclaw::nostr_store::NoteQuery {
        authors: if req.authors.is_empty() {
            None
        } else {
            Some(req.authors)
        },
        hashtags: if req.hashtags.is_empty() {
            None
        } else {
            Some(req.hashtags)
        },
        kinds: if req.kinds.is_empty() {
            None
        } else {
            Some(req.kinds)
        },
        since: req.since,
        until: req.until,
        limit: req.limit,
    };
    tauri::async_runtime::spawn_blocking(move || {
        slowclaw::nostr_store::query_notes(&workspace, &query)
    })
    .await
    .map_err(|e| format!("nostr query task failed: {e}"))?
    .map_err(|e| format!("Failed to query nostr notes: {e}"))
}

#[tauri::command]
async fn nostr_get_note(
    event_id: String,
) -> Result<Option<slowclaw::nostr_store::NoteRecord>, String> {
    let workspace = nostr_workspace_dir().await?;
    tauri::async_runtime::spawn_blocking(move || {
        slowclaw::nostr_store::get_note(&workspace, &event_id)
    })
    .await
    .map_err(|e| format!("nostr get_note task failed: {e}"))?
    .map_err(|e| format!("Failed to read nostr note: {e}"))
}

#[tauri::command]
async fn nostr_get_profiles(
    pubkeys: Vec<String>,
) -> Result<Vec<slowclaw::nostr_store::ProfileRecord>, String> {
    let workspace = nostr_workspace_dir().await?;
    tauri::async_runtime::spawn_blocking(move || {
        slowclaw::nostr_store::get_profiles(&workspace, &pubkeys)
    })
    .await
    .map_err(|e| format!("nostr profiles task failed: {e}"))?
    .map_err(|e| format!("Failed to query nostr profiles: {e}"))
}

#[tauri::command]
async fn nostr_get_reactions(
    event_ids: Vec<String>,
) -> Result<std::collections::HashMap<String, i64>, String> {
    let workspace = nostr_workspace_dir().await?;
    tauri::async_runtime::spawn_blocking(move || {
        slowclaw::nostr_store::get_reactions(&workspace, &event_ids)
    })
    .await
    .map_err(|e| format!("nostr reactions task failed: {e}"))?
    .map_err(|e| format!("Failed to query nostr reactions: {e}"))
}

#[tauri::command]
async fn nostr_get_replies(
    event_id: String,
) -> Result<Vec<slowclaw::nostr_store::NoteRecord>, String> {
    let workspace = nostr_workspace_dir().await?;
    tauri::async_runtime::spawn_blocking(move || {
        slowclaw::nostr_store::get_replies(&workspace, &event_id)
    })
    .await
    .map_err(|e| format!("nostr replies task failed: {e}"))?
    .map_err(|e| format!("Failed to query nostr replies: {e}"))
}

#[tauri::command]
async fn nostr_get_articles(
    req: NostrArticleQueryRequest,
) -> Result<Vec<slowclaw::nostr_store::ArticleRecord>, String> {
    let workspace = nostr_workspace_dir().await?;
    tauri::async_runtime::spawn_blocking(move || {
        slowclaw::nostr_store::get_articles(&workspace, req.limit)
    })
    .await
    .map_err(|e| format!("nostr articles task failed: {e}"))?
    .map_err(|e| format!("Failed to query nostr articles: {e}"))
}

#[tauri::command]
async fn nostr_ingest_refresh(state: tauri::State<'_, NostrIngestState>) -> Result<(), String> {
    // Stop any existing ingester, then start a fresh one with current config.
    let old_handle = {
        let mut guard = state.inner.lock().map_err(|_| "state lock poisoned")?;
        guard.ingest_handle.take()
    };
    if let Some(handle) = old_handle {
        handle.abort();
    }
    // Start a fresh ingester; `start_nostr_ingester` writes the new handle,
    // client, and status fields back into the managed state.
    let ingest_state = NostrIngestState {
        inner: state.inner.clone(),
    };
    start_nostr_ingester(ingest_state).await;
    Ok(())
}

#[tauri::command]
async fn nostr_publish_note(
    content: String,
    state: tauri::State<'_, NostrIngestState>,
) -> Result<NostrPublishResult, String> {
    let keys = load_nostr_keys()?;
    let event = nostr_sdk::EventBuilder::text_note(content)
        .sign_with_keys(&keys)
        .map_err(|e| format!("Failed to build text note: {e}"))?;
    finalize_publish(&state, event).await
}

#[tauri::command]
async fn nostr_publish_reaction(
    event_id: String,
    content: String,
    state: tauri::State<'_, NostrIngestState>,
) -> Result<NostrPublishResult, String> {
    let keys = load_nostr_keys()?;
    // NIP-25 reactions need the full target event. Look it up locally — the
    // ingester caches any note the user is reacting to from the feed.
    let target = lookup_target_event(&event_id).await?;
    let event = nostr_sdk::EventBuilder::reaction(&target, content)
        .sign_with_keys(&keys)
        .map_err(|e| format!("Failed to build reaction: {e}"))?;
    finalize_publish(&state, event).await
}

#[tauri::command]
async fn nostr_publish_reply(
    event_id: String,
    relay_url: String,
    content: String,
    state: tauri::State<'_, NostrIngestState>,
) -> Result<NostrPublishResult, String> {
    let keys = load_nostr_keys()?;
    // NIP-10 replies need the full target event (for the `p` tag of its author).
    let target = lookup_target_event(&event_id).await?;
    let relay =
        nostr_sdk::RelayUrl::parse(&relay_url).map_err(|e| format!("Invalid relay url: {e}"))?;
    let event = nostr_sdk::EventBuilder::text_note_reply(content, &target, None, Some(relay))
        .sign_with_keys(&keys)
        .map_err(|e| format!("Failed to build reply: {e}"))?;
    finalize_publish(&state, event).await
}

/// Read the Nostr key bundle from secure storage and parse it into [`Keys`].
fn load_nostr_keys() -> Result<nostr_sdk::Keys, String> {
    let entry = keyring::Entry::new(NOSTR_KEYS_SECRET_SERVICE, NOSTR_KEYS_SECRET_ACCOUNT)
        .map_err(|e| format!("Failed to open nostr key storage: {e}"))?;
    let raw = entry
        .get_password()
        .map_err(|e| format!("Failed to read nostr keys: {e}"))?;
    #[derive(serde::Deserialize)]
    struct NostrKeyBundle {
        #[serde(rename = "secretKeyHex")]
        secret_key_hex: String,
    }
    let bundle: NostrKeyBundle =
        serde_json::from_str(&raw).map_err(|e| format!("Failed to parse nostr keys: {e}"))?;
    nostr_sdk::Keys::parse(bundle.secret_key_hex.trim())
        .map_err(|e| format!("Invalid nostr private key: {e}"))
}

/// Look up a stored event by id so we can build a proper reply/reaction. The
/// store only persists the structural fields needed for queries, so we
/// reconstruct a minimal-but-valid `Event` (the builder only reads `id`,
/// `pubkey`, `kind`, and `coordinate()`).
async fn lookup_target_event(event_id: &str) -> Result<nostr_sdk::Event, String> {
    let workspace = nostr_workspace_dir().await?;
    let id = event_id.to_string();
    let note = tauri::async_runtime::spawn_blocking(move || {
        slowclaw::nostr_store::get_note(&workspace, &id)
    })
    .await
    .map_err(|e| format!("target lookup task failed: {e}"))?
    .map_err(|e| format!("Failed to read target note: {e}"))?
    .ok_or_else(|| "Target note not found in local store".to_string())?;

    // Reconstruct a structurally-complete event. Signature correctness is
    // irrelevant here — `EventBuilder::reaction` / `text_note_reply` only read
    // `id`, `pubkey`, `kind`, tags (for coordinate), not the signature.
    use nostr_sdk::prelude::{EventId, PublicKey, Signature, Timestamp};
    use std::str::FromStr;
    let event_id = EventId::from_hex(&note.id).map_err(|e| format!("bad event id: {e}"))?;
    let public_key = PublicKey::from_hex(&note.pubkey).map_err(|e| format!("bad pubkey: {e}"))?;
    let created_at = Timestamp::from_secs(note.created_at.max(0) as u64);
    let kind = nostr_sdk::Kind::from(note.kind as u16);
    let tags_parsed = nostr_sdk::Tags::parse(note.tags.iter().map(|t| t.to_vec()))
        .map_err(|e| format!("bad tags: {e}"))?;
    // A zero signature — never used for verification here (`EventBuilder`
    // only reads id/pubkey/kind/tags, not the signature).
    let sig = Signature::from_str(
        "0000000000000000000000000000000000000000000000000000000000000000\
         0000000000000000000000000000000000000000000000000000000000000000",
    )
    .map_err(|_| "bad dummy signature".to_string())?;
    // Build directly via `Event::new` so we don't re-sign.
    Ok(nostr_sdk::Event::new(
        event_id,
        public_key,
        created_at,
        kind,
        tags_parsed,
        String::new(),
        sig,
    ))
}

/// Publish through the ingester's persistent client, then ingest our own event
/// so the UI shows it instantly.
async fn finalize_publish(
    state: &tauri::State<'_, NostrIngestState>,
    event: nostr_sdk::Event,
) -> Result<NostrPublishResult, String> {
    let client_opt = {
        let guard = state.inner.lock().map_err(|_| "state lock poisoned")?;
        guard.client.clone()
    };
    let published = match client_opt.lock().await.clone() {
        Some(client) => match client.send_event(&event).await {
            Ok(_) => true,
            Err(e) => {
                eprintln!("nostr publish failed: {e}");
                false
            }
        },
        None => false,
    };

    // Ingest our own event so it appears in the local store immediately.
    let workspace = nostr_workspace_dir().await?;
    let ev_for_ingest = event.clone();
    let _ = tauri::async_runtime::spawn_blocking(move || {
        let _ = slowclaw::nostr_store::ingest_event(&workspace, &ev_for_ingest);
    })
    .await;

    Ok(NostrPublishResult {
        event_id: event.id.to_hex(),
        published,
        error: if published {
            None
        } else {
            Some("Event was not accepted by any relay.".to_string())
        },
    })
}

/// Start (or restart) the background Nostr ingester. Resolves relays + hashtag
/// channels from config, spawns the drain task, and records the handle + a
/// shared client wrapper into `NostrIngestState`.
async fn start_nostr_ingester(state: NostrIngestState) {
    let config = match load_workspace_config_for_ui("nostr ingester config").await {
        Ok(c) => c,
        Err(err) => {
            eprintln!("nostr ingester: failed to load config: {err}");
            if let Ok(mut guard) = state.inner.lock() {
                guard.running = false;
                guard.last_error = Some(err);
            }
            return;
        }
    };

    let workspace_dir = config.workspace_dir.clone();
    let relays = nostr_ingest::resolve_configured_relays(&config);
    // Hashtag channels come from the defaults for now; a future config key can
    // override this. Kept simple per YAGNI.
    let hashtags = nostr_ingest::DEFAULT_HASHTAG_CHANNELS
        .iter()
        .map(|s| (*s).to_string())
        .collect::<Vec<_>>();

    match nostr_ingest::start_ingester(workspace_dir.clone(), relays.clone(), hashtags.clone())
        .await
    {
        Ok(handle) => {
            let client_wrapper = nostr_ingest::wrap_client(handle.client.clone());
            if let Ok(mut guard) = state.inner.lock() {
                guard.running = true;
                guard.last_error = None;
                guard.relays = relays;
                guard.hashtag_channels = hashtags;
                guard.db_path = Some(slowclaw::nostr_store::db_path(&workspace_dir));
                guard.client = client_wrapper;
                guard.ingest_handle = Some(handle.join_handle);
            }
        }
        Err(err) => {
            eprintln!("nostr ingester: failed to start: {err}");
            if let Ok(mut guard) = state.inner.lock() {
                guard.running = false;
                guard.last_error = Some(err);
            }
        }
    }
}

/// Resolve the workspace_dir for a video-store command. Centralized so every
/// command uses the same error wording — mirrors `nostr_workspace_dir`.
async fn video_workspace_dir() -> Result<PathBuf, String> {
    let config = load_workspace_config_for_ui("video store").await?;
    Ok(config.workspace_dir.clone())
}

/// Ensure the video store schema exists. Idempotent — safe to call on every
/// status poll. No-ops if the workspace dir is unavailable.
async fn ensure_video_store_initialized(workspace: &Path) {
    let ws = workspace.to_path_buf();
    let _ = tauri::async_runtime::spawn_blocking(move || {
        slowclaw::video_store::initialize(&ws)
    })
    .await;
}

#[tauri::command]
async fn video_store_status() -> Result<VideoStoreStatus, String> {
    let workspace = video_workspace_dir().await?;
    ensure_video_store_initialized(&workspace).await;
    let ws = workspace.clone();
    let (total, counts, last, path) = tauri::async_runtime::spawn_blocking(move || {
        let total = slowclaw::video_store::video_count(&ws).unwrap_or(0);
        let counts = slowclaw::video_store::count_by_source(&ws).unwrap_or_default();
        let last = slowclaw::video_store::last_received_at(&ws).ok().flatten();
        let path = slowclaw::video_store::db_path(&ws).to_string_lossy().to_string();
        (total, counts, last, path)
    })
    .await
    .map_err(|e| format!("video status task failed: {e}"))?;
    Ok(VideoStoreStatus {
        initialized: true,
        total_count: total,
        bluesky_count: counts.get("bluesky").copied().unwrap_or(0),
        nostr_count: counts.get("nostr").copied().unwrap_or(0),
        last_received_at: last,
        db_path: Some(path),
    })
}

#[tauri::command]
async fn video_query(
    req: VideoQueryRequest,
) -> Result<Vec<slowclaw::video_store::VideoRecord>, String> {
    let workspace = video_workspace_dir().await?;
    ensure_video_store_initialized(&workspace).await;
    let query = slowclaw::video_store::VideoQuery {
        source: req.source,
        since: req.since,
        limit: req.limit,
    };
    tauri::async_runtime::spawn_blocking(move || {
        slowclaw::video_store::query_videos(&workspace, &query)
    })
    .await
    .map_err(|e| format!("video query task failed: {e}"))?
    .map_err(|e| format!("Failed to query video items: {e}"))
}

#[tauri::command]
async fn video_upsert_bluesky(posts: Vec<serde_json::Value>) -> Result<usize, String> {
    let workspace = video_workspace_dir().await?;
    ensure_video_store_initialized(&workspace).await;
    tauri::async_runtime::spawn_blocking(move || {
        slowclaw::video_store::upsert_bluesky_posts(&workspace, &posts)
    })
    .await
    .map_err(|e| format!("video upsert task failed: {e}"))?
    .map_err(|e| format!("Failed to upsert bluesky video posts: {e}"))
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    let gateway_state = GatewayState::default();
    let openai_state = OpenAiDeviceCodeState::default();
    let native_local_ai_state = NativeLocalAiState::default();
    let nostr_ingest_state = NostrIngestState::default();
    tauri::Builder::default()
        .manage(gateway_state)
        .manage(openai_state)
        .manage(native_local_ai_state)
        .manage(nostr_ingest_state.clone())
        .setup(move |app| {
            configure_app_owned_workspace(app);
            let shared = app.state::<GatewayState>().inner.clone();
            tauri::async_runtime::spawn(async move {
                if let Err(err) = ensure_embedded_gateway_started(shared).await {
                    eprintln!("embedded gateway failed to start: {err}");
                }
            });
            // Start the background Nostr ingester. Failures are non-fatal —
            // the UI falls back to direct relay reads when the local store is
            // empty or the ingester is not running.
            let ingest_state = nostr_ingest_state.clone();
            tauri::async_runtime::spawn(async move {
                start_nostr_ingester(ingest_state).await;
            });
            Ok(())
        })
        .invoke_handler(tauri::generate_handler![
            get_secret,
            set_secret,
            delete_secret,
            get_embedded_gateway_info,
            commands::desktop::generate_mobile_pairing_qr,
            commands::desktop::get_desktop_gateway_bootstrap,
            commands::desktop::restart_gateway_daemon,
            set_provider_api_key,
            save_journal_text,
            save_journal_text_file,
            save_journal_media,
            list_journals,
            get_journal,
            update_journal_text,
            rename_journal,
            delete_journal,
            save_journal_interest_keywords,
            save_card_keywords,
            get_interest_profile,
            set_lens_override,
            remove_lens_override,
            add_manual_interest,
            remove_manual_interest,
            ensure_journal_enrichment,
            set_journal_enrichment,
            list_journal_enrichment,
            delete_journal_enrichment,
            commands::desktop::open_workspace_journals_folder,
            commands::desktop::open_external_url,
            commands::desktop::open_in_app_webview,
            get_openai_device_code_status,
            commands::desktop::start_openai_device_code_login,
            get_anthropic_token_status,
            save_anthropic_token,
            clear_anthropic_token,
            get_native_local_ai_status,
            configure_native_local_ai,
            get_config,
            save_config,
            commands::desktop::list_ollama_models,
            commands::desktop::check_ollama,
            commands::desktop::download_ollama_model,
            commands::desktop::show_main_window,
            native_ai_load_model,
            native_ai_chat,
            native_ai_engine_status,
            clear_native_local_ai,
            delete_local_model,
            set_metal_mode,
            transcribe_audio,
            transcribe_journal_media,
            read_journal_media_bytes,
            import_voice_memos,
            nostr_store_status,
            nostr_query_notes,
            nostr_get_note,
            nostr_get_profiles,
            nostr_get_reactions,
            nostr_get_replies,
            nostr_get_articles,
            nostr_ingest_refresh,
            nostr_publish_note,
            nostr_publish_reaction,
            nostr_publish_reply,
            video_store_status,
            video_query,
            video_upsert_bluesky
        ])
        .run(tauri::generate_context!())
        .expect("error while running tauri app");
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use std::path::PathBuf;

    /// Build an isolated temp workspace under std's temp dir. The path is
    /// unique per-test via the test's `&str` name so parallel runs don't clash.
    fn temp_workspace(test_name: &str) -> PathBuf {
        let mut dir = std::env::temp_dir();
        dir.push(format!("slowclaw-repair-tests-{}", std::process::id()));
        dir.push(test_name);
        fs::create_dir_all(&dir).expect("create temp workspace");
        dir
    }

    /// Write an empty marker file shaped like a valid GGUF (magic header only).
    /// `try_repair_model_path` only checks `.is_file()` + extension, so this is
    /// enough for the test without shipping a real multi-GB model.
    fn write_fake_gguf(path: &Path) {
        if let Some(parent) = path.parent() {
            fs::create_dir_all(parent).expect("create model dir");
        }
        fs::write(path, b"GGUF").expect("write fake gguf");
    }

    /// Assert that a repaired path points to the same file as the canonical
    /// gguf. Compares canonicalized forms so path-separator differences (e.g.
    /// `/` in a stale iOS path vs `\` on Windows hosts) don't cause spurious
    /// failures — what matters is that repair resolves to the right file.
    fn assert_resolves_same_file(repaired: Option<String>, expected: &Path) {
        let repaired = repaired.expect("repair should have found the gguf");
        let repaired_path = Path::new(&repaired);
        assert!(repaired_path.is_file(), "repaired path is not a file: {repaired}");
        let repaired_canon = fs::canonicalize(repaired_path).expect("canonicalize repaired");
        let expected_canon = fs::canonicalize(expected).expect("canonicalize expected");
        assert_eq!(
            repaired_canon, expected_canon,
            "repaired path must resolve to the same file as the canonical gguf"
        );
    }

    /// Repair by model_id: a stale old_path pointing nowhere is recovered by
    /// scanning the model's directory under the current workspace.
    #[test]
    fn try_repair_finds_gguf_by_model_id() {
        let workspace = temp_workspace("by_model_id");
        let model_dir = workspace
            .join(slowclaw::gateway::handlers::model::LOCAL_MODEL_DIR)
            .join(safe_local_model_id_dir("gemma-3-4b"));
        let gguf = model_dir.join("model.gguf");
        write_fake_gguf(&gguf);

        // old_path is intentionally stale (wrong container UUID on iOS).
        let old_path = "/var/mobile/Containers/Data/OLD-UUID/.../gemma-3-4b/model.gguf";
        let repaired = try_repair_model_path("gemma-3-4b", old_path, &workspace);
        assert_resolves_same_file(repaired, &gguf);
    }

    /// Repair by re-rooting the layout-relative suffix: the old path carries the
    /// `local-models/llamacpp/<dir>/<file>.gguf` suffix under a different root,
    /// and repair re-roots it under the current workspace.
    #[test]
    fn try_repair_reroots_relative_suffix() {
        let workspace = temp_workspace("reroot_suffix");
        let gguf = workspace
            .join(slowclaw::gateway::handlers::model::LOCAL_MODEL_DIR)
            .join("qwen-2.5-1.5b")
            .join("qwen.gguf");
        write_fake_gguf(&gguf);

        // Same layout, different root prefix (stale container UUID).
        let old_path = "/var/mobile/Containers/Data/OLD-UUID/Library/Application Support/\
                        com.slowclaw.app/zeroclaw/workspace/local-models/llamacpp/\
                        qwen-2.5-1.5b/qwen.gguf";
        let repaired = try_repair_model_path("qwen-2.5-1.5b", old_path, &workspace);
        assert_resolves_same_file(repaired, &gguf);
    }

    /// When no GGUF exists anywhere under the workspace, repair returns None.
    #[test]
    fn try_repair_returns_none_when_no_gguf() {
        let workspace = temp_workspace("no_gguf");
        let repaired = try_repair_model_path("gemma-3-4b", "/stale/path/model.gguf", &workspace);
        assert!(repaired.is_none());
    }

    /// Local copy of the model-id sanitizer so tests don't depend on the
    /// private internals of the gateway handler beyond the public constant.
    fn safe_local_model_id_dir(model_id: &str) -> String {
        slowclaw::gateway::handlers::model::safe_local_model_dir_name(model_id)
    }
}
