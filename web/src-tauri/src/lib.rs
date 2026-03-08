mod content_ops;
mod local_workspace;

use serde::{Deserialize, Serialize};
use std::net::{IpAddr, UdpSocket};
use std::sync::{Arc, Mutex};
use std::time::{Duration, SystemTime, UNIX_EPOCH};
use tauri::async_runtime::JoinHandle;
use tauri::Manager;
use zeroclaw::{openai_oauth, AuthService};

use crate::content_ops::{
    extract_calendar_candidates, extract_clips, extract_todos, get_content_job,
    get_latest_content_job_for_target, list_builtin_operations, list_content_jobs, retitle_entry,
    resume_pending_content_jobs, rewrite_text, select_clips, summarize_entry, transcribe_media,
    ContentJobState,
};
use crate::local_workspace::{
    delete_draft, delete_journal, get_config, get_journal, list_drafts, list_journals,
    list_post_history, save_config, save_draft, save_journal_media, save_journal_text,
    save_post_record, update_journal_text,
};

const EMBEDDED_GATEWAY_URL: &str = "http://127.0.0.1:42617";
const PROVIDER_SECRET_SERVICE: &str = "social.slowclaw.gateway";
const PROVIDER_API_KEY_SECRET_ACCOUNT: &str = "provider.api_key";
const DESKTOP_GATEWAY_TOKEN_SECRET_ACCOUNT: &str = "desktop.gateway.token";
const OPENAI_DEVICE_LOGIN_PROVIDER: &str = "openai-codex";
const OPENAI_DEVICE_LOGIN_PROFILE: &str = "default";

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
    scheduler_handle: Option<JoinHandle<()>>,
}

impl Default for GatewayRuntimeState {
    fn default() -> Self {
        Self {
            gateway_url: EMBEDDED_GATEWAY_URL.to_string(),
            running: false,
            last_error: None,
            provider_api_key_set: false,
            gateway_handle: None,
            scheduler_handle: None,
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

fn validate_secret_locator(service: &str, account: &str) -> Result<(), String> {
    if service.trim().is_empty() {
        return Err("service is required".to_string());
    }
    if account.trim().is_empty() {
        return Err("account is required".to_string());
    }
    Ok(())
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

fn snapshot_gateway_state(state: &Arc<Mutex<GatewayRuntimeState>>) -> Result<EmbeddedGatewayInfo, String> {
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
    let host_and_port = without_scheme
        .split('/')
        .next()
        .unwrap_or(without_scheme);
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
    if let Some(token) = read_keyring_secret(PROVIDER_SECRET_SERVICE, DESKTOP_GATEWAY_TOKEN_SECRET_ACCOUNT)? {
        return Ok(token);
    }

    let nanos = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_err(|e| format!("failed to derive desktop token timestamp: {e}"))?
        .as_nanos();
    let generated = format!("desktop-local-{nanos}");

    let entry = keyring::Entry::new(PROVIDER_SECRET_SERVICE, DESKTOP_GATEWAY_TOKEN_SECRET_ACCOUNT)
        .map_err(|e| format!("failed to open desktop token key entry: {e}"))?;
    entry
        .set_password(&generated)
        .map_err(|e| format!("failed to persist desktop token: {e}"))?;
    Ok(generated)
}

async fn persist_provider_api_key_to_config(api_key: Option<String>) -> Result<(), String> {
    let mut config = zeroclaw::Config::load_or_init()
        .await
        .map_err(|e| format!("failed to load config: {e}"))?;
    config.api_key = api_key;
    config
        .save()
        .await
        .map_err(|e| format!("failed to save config: {e}"))
}

async fn restart_embedded_gateway(
    shared: Arc<Mutex<GatewayRuntimeState>>,
) -> Result<EmbeddedGatewayInfo, String> {
    let (old_gateway_handle, old_scheduler_handle) = {
        let mut guard = lock_gateway_state(&shared)?;
        guard.running = false;
        (guard.gateway_handle.take(), guard.scheduler_handle.take())
    };
    let had_old_gateway = old_gateway_handle.is_some();
    let had_old_scheduler = old_scheduler_handle.is_some();

    if let Some(handle) = old_gateway_handle {
        handle.abort();
    }
    if let Some(handle) = old_scheduler_handle {
        handle.abort();
    }
    if had_old_gateway || had_old_scheduler {
        std::thread::sleep(Duration::from_millis(120));
    }

    let mut config = zeroclaw::Config::load_or_init()
        .await
        .map_err(|e| format!("failed to load config for embedded gateway: {e}"))?;
    let bind_host = if cfg!(any(target_os = "ios", target_os = "android")) {
        "127.0.0.1".to_string()
    } else {
        discover_lan_ipv4().unwrap_or_else(|| "127.0.0.1".to_string())
    };
    config.gateway.host = bind_host.clone();
    config.gateway.require_pairing = false;
    config.gateway.allow_public_bind = bind_host != "127.0.0.1";

    let key_from_keyring = provider_api_key_from_keyring()?;
    if let Some(key) = key_from_keyring {
        config.api_key = Some(key);
    }
    let provider_api_key_set = config
        .api_key
        .as_ref()
        .is_some_and(|value| !value.trim().is_empty());

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

    let scheduler_enabled = config.cron.enabled;

    let scheduler_config = config.clone();
    let shared_for_scheduler = shared.clone();
    let scheduler_handle = if scheduler_enabled {
        Some(tauri::async_runtime::spawn(async move {
            let result = zeroclaw::run_scheduler(scheduler_config).await;
            if let Ok(mut guard) = shared_for_scheduler.lock() {
                guard.scheduler_handle = None;
                if let Err(err) = result {
                    guard.last_error = Some(format!("scheduler: {err}"));
                }
            }
        }))
    } else {
        None
    };

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
        guard.scheduler_handle = scheduler_handle;
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

fn run_openai_auth_status_probe() -> Result<bool, String> {
    let runtime = tauri::async_runtime::block_on(async {
        let config = zeroclaw::Config::load_or_init()
            .await
            .map_err(|e| format!("failed to load config: {e}"))?;
        let auth_service = AuthService::from_config(&config);
        auth_service
            .get_profile(OPENAI_DEVICE_LOGIN_PROVIDER, Some(OPENAI_DEVICE_LOGIN_PROFILE))
            .await
            .map(|profile| profile.is_some())
            .map_err(|e| format!("failed to inspect OpenAI auth profile: {e}"))
    });
    runtime
}

async fn run_openai_device_login_worker(
    openai_state: Arc<Mutex<OpenAiDeviceCodeRuntimeState>>,
    gateway_state: Arc<Mutex<GatewayRuntimeState>>,
) {
    let config = match zeroclaw::Config::load_or_init().await {
        Ok(config) => config,
        Err(error) => {
            if let Ok(mut guard) = openai_state.lock() {
                guard.status = OpenAiDeviceCodeStatus {
                    state: "error".to_string(),
                    running: false,
                    completed: false,
                    message: "Failed to load runtime config for OpenAI setup.".to_string(),
                    verification_url: None,
                    user_code: None,
                    fast_link: None,
                    error: Some(error.to_string()),
                };
            }
            return;
        }
    };

    let client = reqwest::Client::new();
    let device = match openai_oauth::start_device_code_flow(&client).await {
        Ok(device) => device,
        Err(error) => {
            if let Ok(mut guard) = openai_state.lock() {
                guard.status = OpenAiDeviceCodeStatus {
                    state: "error".to_string(),
                    running: false,
                    completed: false,
                    message: "Failed to start OpenAI device-code login.".to_string(),
                    verification_url: None,
                    user_code: None,
                    fast_link: None,
                    error: Some(error.to_string()),
                };
            }
            return;
        }
    };

    if let Ok(mut guard) = openai_state.lock() {
        guard.status = OpenAiDeviceCodeStatus {
            state: "awaiting_user".to_string(),
            running: true,
            completed: false,
            message: device
                .message
                .clone()
                .unwrap_or_else(|| "Authorize the app in your browser, then return here.".to_string()),
            verification_url: Some(device.verification_uri.clone()),
            user_code: Some(device.user_code.clone()),
            fast_link: device.verification_uri_complete.clone(),
            error: None,
        };
    }

    let token_set = match openai_oauth::poll_device_code_tokens(&client, &device).await {
        Ok(token_set) => token_set,
        Err(error) => {
            if let Ok(mut guard) = openai_state.lock() {
                guard.status.running = false;
                guard.status.completed = false;
                guard.status.state = "error".to_string();
                guard.status.message = "OpenAI authorization did not complete.".to_string();
                guard.status.error = Some(error.to_string());
            }
            return;
        }
    };

    let auth_service = AuthService::from_config(&config);
    let account_id = openai_oauth::extract_account_id_from_jwt(&token_set.access_token);
    if let Err(error) = auth_service
        .store_openai_tokens(OPENAI_DEVICE_LOGIN_PROFILE, token_set, account_id, true)
        .await
    {
        if let Ok(mut guard) = openai_state.lock() {
            guard.status.running = false;
            guard.status.completed = false;
            guard.status.state = "error".to_string();
            guard.status.message = "OpenAI authorization succeeded, but saving tokens failed.".to_string();
            guard.status.error = Some(error.to_string());
        }
        return;
    }

    if let Ok(mut guard) = openai_state.lock() {
        guard.status.running = false;
        guard.status.completed = true;
        guard.status.state = "authenticated".to_string();
        guard.status.message = "OpenAI setup completed. Restarting gateway...".to_string();
        guard.status.error = None;
    }

    if let Err(err) = restart_embedded_gateway(gateway_state).await {
        eprintln!("failed to restart gateway after OpenAI setup: {err}");
    }
}

#[tauri::command]
fn get_secret(req: SecretGetRequest) -> Result<SecretGetResponse, String> {
    validate_secret_locator(&req.service, &req.account)?;
    let entry = keyring::Entry::new(req.service.trim(), req.account.trim())
        .map_err(|e| format!("failed to open keyring entry: {e}"))?;

    match entry.get_password() {
        Ok(value) => Ok(SecretGetResponse { value: Some(value) }),
        Err(keyring::Error::NoEntry) => Ok(SecretGetResponse { value: None }),
        Err(e) => Err(format!("failed to read keyring secret: {e}")),
    }
}

#[tauri::command]
fn set_secret(req: SecretSetRequest) -> Result<(), String> {
    validate_secret_locator(&req.service, &req.account)?;
    if req.value.is_empty() {
        return Err("value is required".to_string());
    }
    let entry = keyring::Entry::new(req.service.trim(), req.account.trim())
        .map_err(|e| format!("failed to open keyring entry: {e}"))?;
    entry
        .set_password(&req.value)
        .map_err(|e| format!("failed to write keyring secret: {e}"))
}

#[tauri::command]
fn delete_secret(req: SecretGetRequest) -> Result<(), String> {
    validate_secret_locator(&req.service, &req.account)?;
    let entry = keyring::Entry::new(req.service.trim(), req.account.trim())
        .map_err(|e| format!("failed to open keyring entry: {e}"))?;
    match entry.delete_credential() {
        Ok(()) | Err(keyring::Error::NoEntry) => Ok(()),
        Err(e) => Err(format!("failed to delete keyring secret: {e}")),
    }
}

#[tauri::command]
fn get_embedded_gateway_info(state: tauri::State<'_, GatewayState>) -> Result<EmbeddedGatewayInfo, String> {
    snapshot_gateway_state(&state.inner)
}

#[tauri::command]
fn generate_mobile_pairing_qr(
    state: tauri::State<'_, GatewayState>,
) -> Result<GatewayQrPayload, String> {
    let info = snapshot_gateway_state(&state.inner)?;
    let mobile_gateway_url = resolve_mobile_gateway_url(&info.gateway_url);
    let token = ensure_desktop_gateway_token()?;
    let qr_value = serde_json::to_string(&serde_json::json!({
        "gateway_url": mobile_gateway_url.clone(),
        "gatewayUrl": mobile_gateway_url.clone(),
        "token": token.clone(),
    }))
    .map_err(|e| format!("failed to encode QR payload: {e}"))?;

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
    let token = ensure_desktop_gateway_token()?;
    Ok(DesktopGatewayBootstrap {
        gateway_url: info.gateway_url,
        token,
    })
}

#[tauri::command]
async fn restart_gateway_daemon(state: tauri::State<'_, GatewayState>) -> Result<String, String> {
    let _ = ensure_desktop_gateway_token()?;
    let info = restart_embedded_gateway(state.inner.clone()).await?;
    Ok(info.gateway_url)
}

#[tauri::command]
async fn set_provider_api_key(
    state: tauri::State<'_, GatewayState>,
    value: String,
) -> Result<EmbeddedGatewayInfo, String> {
    let normalized = value.trim().to_string();
    let entry = keyring::Entry::new(PROVIDER_SECRET_SERVICE, PROVIDER_API_KEY_SECRET_ACCOUNT)
        .map_err(|e| format!("failed to open provider key entry: {e}"))?;

    if normalized.is_empty() {
        match entry.delete_credential() {
            Ok(()) | Err(keyring::Error::NoEntry) => {}
            Err(e) => return Err(format!("failed to clear provider API key: {e}")),
        }
    } else {
        entry
            .set_password(&normalized)
            .map_err(|e| format!("failed to save provider API key: {e}"))?;
    }

    persist_provider_api_key_to_config(if normalized.is_empty() {
        None
    } else {
        Some(normalized)
    })
    .await?;

    restart_embedded_gateway(state.inner.clone()).await
}

#[tauri::command]
fn get_openai_device_code_status(
    state: tauri::State<'_, OpenAiDeviceCodeState>,
) -> Result<OpenAiDeviceCodeStatus, String> {
    let current = snapshot_openai_status(&state.inner)?;
    if current.running {
        return Ok(current);
    }

    let mut next = current;
    match run_openai_auth_status_probe() {
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
                next.error = Some(err);
            }
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
    tauri::async_runtime::spawn(async move {
        run_openai_device_login_worker(openai_state, gateway_state).await;
    });

    snapshot_openai_status(&state.inner)
}

#[tauri::command]
fn show_main_window(window: tauri::Window) {
    if let Err(e) = window.show() {
        eprintln!("failed to show main window: {e}");
    }
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    let gateway_state = GatewayState::default();
    let openai_state = OpenAiDeviceCodeState::default();
    let content_job_state = ContentJobState::default();
    tauri::Builder::default()
        .manage(gateway_state)
        .manage(openai_state)
        .manage(content_job_state)
        .setup(|app| {
            let shared = app.state::<GatewayState>().inner.clone();
            tauri::async_runtime::spawn(async move {
                if let Err(err) = ensure_embedded_gateway_started(shared).await {
                    eprintln!("embedded gateway failed to start: {err}");
                }
            });
            let content_jobs = app.state::<ContentJobState>().inner().clone();
            let app_handle = app.handle().clone();
            tauri::async_runtime::spawn(async move {
                resume_pending_content_jobs(app_handle, content_jobs).await;
            });
            Ok(())
        })
        .invoke_handler(tauri::generate_handler![
            save_journal_text,
            save_journal_media,
            list_journals,
            get_journal,
            update_journal_text,
            delete_journal,
            save_draft,
            list_drafts,
            delete_draft,
            save_post_record,
            list_post_history,
            get_config,
            save_config,
            list_builtin_operations,
            list_content_jobs,
            get_content_job,
            get_latest_content_job_for_target,
            transcribe_media,
            summarize_entry,
            extract_todos,
            extract_calendar_candidates,
            rewrite_text,
            retitle_entry,
            select_clips,
            extract_clips,
            get_secret,
            set_secret,
            delete_secret,
            get_embedded_gateway_info,
            generate_mobile_pairing_qr,
            get_desktop_gateway_bootstrap,
            restart_gateway_daemon,
            set_provider_api_key,
            get_openai_device_code_status,
            start_openai_device_code_login,
            show_main_window
        ])
        .run(tauri::generate_context!())
        .expect("error while running tauri app");
}
