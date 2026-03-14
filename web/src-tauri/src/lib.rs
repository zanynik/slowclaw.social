use serde::{Deserialize, Serialize};
use std::io::{BufRead, BufReader, Read};
use std::net::{IpAddr, UdpSocket};
use std::path::PathBuf;
use std::process::{Child, Command, Stdio};
use std::sync::mpsc;
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::{Duration, SystemTime, UNIX_EPOCH};
use tauri::async_runtime::JoinHandle;
use tauri::Manager;

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

fn ui_command_error(context: &str, user_message: &str, err: impl std::fmt::Display) -> String {
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

async fn clear_matching_provider_api_key_from_config(expected: &str) -> Result<(), String> {
    let expected = expected.trim();
    if expected.is_empty() {
        return Ok(());
    }

    let mut config = zeroclaw::Config::load_or_init()
        .await
        .map_err(|e| format!("failed to load config: {e}"))?;
    if config
        .api_key
        .as_deref()
        .map(str::trim)
        .is_none_or(|value| value != expected)
    {
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
    let bind_host = discover_lan_ipv4().unwrap_or_else(|| "127.0.0.1".to_string());
    config.gateway.host = bind_host.clone();
    config.gateway.require_pairing = false;
    config.gateway.allow_public_bind = bind_host != "127.0.0.1";

    let key_from_keyring = provider_api_key_from_keyring()?;
    if let Some(key) = key_from_keyring {
        if let Err(err) = clear_matching_provider_api_key_from_config(&key).await {
            eprintln!("provider api key migration failed: {err}");
        }
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
                        guard.status.message = "OpenAI setup completed. Restarting gateway...".to_string();
                    }

                    let gateway_state_for_restart = gateway_state.clone();
                    tauri::async_runtime::spawn(async move {
                        if let Err(err) = restart_embedded_gateway(gateway_state_for_restart).await {
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
                    guard.status.message = "Failed while waiting for OpenAI setup command.".to_string();
                    guard.status.error = Some("Unable to monitor the OpenAI setup command.".to_string());
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
    let entry = keyring::Entry::new(req.service.trim(), req.account.trim())
        .map_err(|e| ui_command_error("secure storage open failed", "Failed to access secure storage.", e))?;

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
    let entry = keyring::Entry::new(req.service.trim(), req.account.trim())
        .map_err(|e| ui_command_error("secure storage open failed", "Failed to access secure storage.", e))?;
    entry
        .set_password(&req.value)
        .map_err(|e| ui_command_error(
            "secure storage write failed",
            "Failed to save the secure value.",
            e,
        ))
}

#[tauri::command]
fn delete_secret(req: SecretGetRequest) -> Result<(), String> {
    validate_secret_locator(&req.service, &req.account)?;
    let entry = keyring::Entry::new(req.service.trim(), req.account.trim())
        .map_err(|e| ui_command_error("secure storage open failed", "Failed to access secure storage.", e))?;
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
fn get_embedded_gateway_info(state: tauri::State<'_, GatewayState>) -> Result<EmbeddedGatewayInfo, String> {
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
        .map_err(|e| ui_command_error("gateway restart failed", "Failed to restart the desktop gateway.", e))?;
    Ok(info.gateway_url)
}

#[tauri::command]
async fn set_provider_api_key(
    state: tauri::State<'_, GatewayState>,
    value: String,
) -> Result<EmbeddedGatewayInfo, String> {
    let normalized = value.trim().to_string();
    let entry = keyring::Entry::new(PROVIDER_SECRET_SERVICE, PROVIDER_API_KEY_SECRET_ACCOUNT)
        .map_err(|e| ui_command_error("provider keyring open failed", "Failed to access the provider key store.", e))?;

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
        entry
            .set_password(&normalized)
            .map_err(|e| {
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
        .map_err(|e| ui_command_error("gateway restart failed", "Failed to restart the desktop gateway.", e))
}

#[tauri::command]
async fn open_workspace_journals_folder() -> Result<String, String> {
    let config = zeroclaw::Config::load_or_init()
        .await
        .map_err(|e| ui_command_error("journals folder config load failed", "Failed to load the workspace configuration.", e))?;
    let journals_dir = config.workspace_dir.join("journals");
    std::fs::create_dir_all(&journals_dir).map_err(|e| {
        ui_command_error(
            "journals folder create failed",
            "Failed to prepare the journals folder.",
            e,
        )
    })?;
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
fn show_main_window(window: tauri::Window) {
    if let Err(e) = window.show() {
        eprintln!("failed to show main window: {e}");
    }
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    let gateway_state = GatewayState::default();
    let openai_state = OpenAiDeviceCodeState::default();
    tauri::Builder::default()
        .manage(gateway_state)
        .manage(openai_state)
        .setup(|app| {
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
            open_workspace_journals_folder,
            open_external_url,
            get_openai_device_code_status,
            start_openai_device_code_login,
            show_main_window
        ])
        .run(tauri::generate_context!())
        .expect("error while running tauri app");
}
