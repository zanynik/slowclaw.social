use serde::{Deserialize, Serialize};
use std::fs;
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

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct AppConfig {
    ollama_base_url: String,
    ollama_model: String,
    bluesky_handle: String,
    bluesky_service_url: String,
    transcription_enabled: bool,
    transcription_model: String,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
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
struct DesktopHostStatus {
    gateway: EmbeddedGatewayInfo,
    bootstrap_ready: bool,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
struct DesktopWorkspacePaths {
    workspace_dir: String,
    journals_dir: String,
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

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct TranscriptionSetupStatus {
    python_configured: bool,
    python_available: bool,
    python_version: Option<String>,
    faster_whisper_available: bool,
    available_models: Vec<String>,
    configured_model: String,
    configured_model_ready: bool,
    recommended_model: String,
    install_commands: Vec<String>,
    last_error: Option<String>,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct TranscriptionSetupProbe {
    python_available: bool,
    python_version: Option<String>,
    faster_whisper_available: bool,
    available_models: Vec<String>,
    configured_model: String,
    configured_model_ready: bool,
    recommended_model: String,
    last_error: Option<String>,
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

fn load_local_app_config_sync() -> Result<AppConfig, String> {
    let config = tauri::async_runtime::block_on(zeroclaw::Config::load_or_init())
        .map_err(|e| format!("failed to load local config: {e}"))?;
    Ok(AppConfig {
        ollama_base_url: config.api_url.unwrap_or_default(),
        ollama_model: config.default_model.unwrap_or_default(),
        bluesky_handle: String::new(),
        bluesky_service_url: "https://bsky.social".to_string(),
        transcription_enabled: config.transcription.enabled,
        transcription_model: config.transcription.model,
    })
}

fn load_local_workspace_paths_sync() -> Result<DesktopWorkspacePaths, String> {
    let config = tauri::async_runtime::block_on(zeroclaw::Config::load_or_init())
        .map_err(|e| format!("failed to load local config: {e}"))?;
    let workspace_dir = config.workspace_dir;
    let journals_dir = workspace_dir.join("journals");
    Ok(DesktopWorkspacePaths {
        workspace_dir: workspace_dir.display().to_string(),
        journals_dir: journals_dir.display().to_string(),
    })
}

fn open_path_in_system_file_manager(path: &Path) -> Result<(), String> {
    if !path.exists() {
        return Err(format!("path does not exist: {}", path.display()));
    }

    #[cfg(target_os = "macos")]
    let mut command = {
        let mut cmd = Command::new("open");
        cmd.arg(path);
        cmd
    };

    #[cfg(target_os = "linux")]
    let mut command = {
        let mut cmd = Command::new("xdg-open");
        cmd.arg(path);
        cmd
    };

    #[cfg(target_os = "windows")]
    let mut command = {
        let mut cmd = Command::new("explorer");
        cmd.arg(path);
        cmd
    };

    command
        .spawn()
        .map_err(|e| format!("failed to open {}: {e}", path.display()))?;
    Ok(())
}

fn transcription_setup_script_name() -> &'static str {
    "transcription_setup.py"
}

fn transcription_setup_script_path(workspace_dir: &Path) -> PathBuf {
    workspace_dir
        .join("scripts")
        .join(transcription_setup_script_name())
}

fn ensure_workspace_transcription_setup_script(workspace_dir: &Path) -> Result<PathBuf, String> {
    let scripts_dir = workspace_dir.join("scripts");
    fs::create_dir_all(&scripts_dir)
        .map_err(|e| format!("failed to create workspace scripts directory: {e}"))?;
    let script_path = transcription_setup_script_path(workspace_dir);
    fs::write(
        &script_path,
        include_str!("../../../scripts/transcription_setup.py"),
    )
    .map_err(|e| format!("failed to write transcription setup helper: {e}"))?;
    Ok(script_path)
}

fn recommended_transcription_model(configured_model: &str) -> String {
    let trimmed = configured_model.trim();
    if trimmed.is_empty() {
        "base".to_string()
    } else {
        trimmed.to_string()
    }
}

fn build_transcription_install_commands(
    python_bin: &str,
    script_path: &Path,
    configured_model: &str,
) -> Vec<String> {
    let interpreter = python_bin.trim();
    let model = recommended_transcription_model(configured_model);
    if interpreter.is_empty() {
        return vec![
            "brew install python".to_string(),
            "Update transcription.python_bin to a working Python 3 interpreter.".to_string(),
        ];
    }

    vec![
        format!("{interpreter} -m pip install faster-whisper"),
        format!(
            "{interpreter} {} install --model {}",
            script_path.display(),
            shell_escape(&model)
        ),
    ]
}

fn shell_escape(value: &str) -> String {
    if value.chars().all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_' || c == '.' || c == '/') {
        value.to_string()
    } else {
        format!("{value:?}")
    }
}

fn run_transcription_setup_probe_sync() -> Result<TranscriptionSetupStatus, String> {
    let config = tauri::async_runtime::block_on(zeroclaw::Config::load_or_init())
        .map_err(|e| format!("failed to load config for transcription setup: {e}"))?;
    let workspace_dir = config.workspace_dir.clone();
    let configured_python = config.transcription.python_bin.trim().to_string();
    let configured_model = recommended_transcription_model(&config.transcription.model);
    let script_path = transcription_setup_script_path(&workspace_dir);
    let install_commands = build_transcription_install_commands(
        &configured_python,
        &script_path,
        &configured_model,
    );

    if configured_python.is_empty() {
        return Ok(TranscriptionSetupStatus {
            python_configured: false,
            python_available: false,
            python_version: None,
            faster_whisper_available: false,
            available_models: Vec::new(),
            configured_model: configured_model.clone(),
            configured_model_ready: false,
            recommended_model: configured_model,
            install_commands,
            last_error: Some("No Python interpreter configured for transcription.".to_string()),
        });
    }

    let version_output = Command::new(&configured_python)
        .arg("--version")
        .output()
        .map_err(|e| format!("failed to run {} --version: {e}", configured_python))?;

    if !version_output.status.success() {
        let stderr = String::from_utf8_lossy(&version_output.stderr).trim().to_string();
        let stdout = String::from_utf8_lossy(&version_output.stdout).trim().to_string();
        return Ok(TranscriptionSetupStatus {
            python_configured: true,
            python_available: false,
            python_version: None,
            faster_whisper_available: false,
            available_models: Vec::new(),
            configured_model: configured_model.clone(),
            configured_model_ready: false,
            recommended_model: configured_model,
            install_commands,
            last_error: Some(if !stderr.is_empty() { stderr } else { stdout }),
        });
    }

    let python_version_raw = {
        let stderr = String::from_utf8_lossy(&version_output.stderr).trim().to_string();
        if stderr.is_empty() {
            String::from_utf8_lossy(&version_output.stdout).trim().to_string()
        } else {
            stderr
        }
    };
    let python_version = python_version_raw
        .strip_prefix("Python ")
        .unwrap_or(&python_version_raw)
        .trim()
        .to_string();

    let script_path = ensure_workspace_transcription_setup_script(&workspace_dir)?;
    let probe_output = Command::new(&configured_python)
        .arg(&script_path)
        .arg("probe")
        .arg("--model")
        .arg(&configured_model)
        .current_dir(&workspace_dir)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .output()
        .map_err(|e| format!("failed to execute transcription setup probe: {e}"))?;

    let stdout = String::from_utf8_lossy(&probe_output.stdout).to_string();
    let stderr = String::from_utf8_lossy(&probe_output.stderr).trim().to_string();
    let probe: TranscriptionSetupProbe = serde_json::from_str(stdout.trim())
        .map_err(|e| format!("failed to parse transcription probe output: {e}"))?;

    Ok(TranscriptionSetupStatus {
        python_configured: true,
        python_available: probe.python_available,
        python_version: probe
            .python_version
            .filter(|value| !value.trim().is_empty())
            .or_else(|| (!python_version.is_empty()).then_some(python_version)),
        faster_whisper_available: probe.faster_whisper_available,
        available_models: probe.available_models,
        configured_model: probe.configured_model,
        configured_model_ready: probe.configured_model_ready,
        recommended_model: probe.recommended_model,
        install_commands: build_transcription_install_commands(
            &configured_python,
            &script_path,
            &configured_model,
        ),
        last_error: probe
            .last_error
            .filter(|value| !value.trim().is_empty())
            .or_else(|| (!probe_output.status.success() && !stderr.is_empty()).then_some(stderr)),
    })
}

fn run_transcription_setup_install_sync() -> Result<TranscriptionSetupStatus, String> {
    let config = tauri::async_runtime::block_on(zeroclaw::Config::load_or_init())
        .map_err(|e| format!("failed to load config for transcription setup: {e}"))?;
    let workspace_dir = config.workspace_dir.clone();
    let configured_python = config.transcription.python_bin.trim().to_string();
    let configured_model = recommended_transcription_model(&config.transcription.model);

    let mut status = run_transcription_setup_probe_sync()?;
    if !status.python_available {
        return Ok(status);
    }

    let script_path = ensure_workspace_transcription_setup_script(&workspace_dir)?;
    let install_output = Command::new(&configured_python)
        .arg(&script_path)
        .arg("install")
        .arg("--model")
        .arg(&configured_model)
        .arg("--device")
        .arg(config.transcription.device.trim())
        .arg("--compute-type")
        .arg(config.transcription.compute_type.trim())
        .current_dir(&workspace_dir)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .output()
        .map_err(|e| format!("failed to execute transcription setup installer: {e}"))?;

    status = run_transcription_setup_probe_sync()?;
    if !install_output.status.success() {
        let stdout = String::from_utf8_lossy(&install_output.stdout).trim().to_string();
        let stderr = String::from_utf8_lossy(&install_output.stderr).trim().to_string();
        if status.last_error.is_none() {
            status.last_error = Some(if !stderr.is_empty() { stderr } else { stdout });
        }
    }
    Ok(status)
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
    let bind_host = discover_lan_ipv4().unwrap_or_else(|| "127.0.0.1".to_string());
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

fn openai_auth_is_configured_from_status_output(output: &str) -> bool {
    let lower = output.to_ascii_lowercase();
    lower.contains("openai-codex")
        && lower.contains("active profiles:")
        && lower.contains("openai-codex:")
}

fn run_openai_auth_status_probe() -> Result<bool, String> {
    let mut attempts: Vec<(String, Command)> = Vec::new();
    if let Some(binary_path) = slowclaw_binary_next_to_current_exe() {
        let mut command = Command::new(&binary_path);
        command.args(["auth", "status"]);
        attempts.push((binary_path.display().to_string(), command));
    }
    let mut command = Command::new("slowclaw");
    command.args(["auth", "status"]);
    attempts.push(("slowclaw".to_string(), command));

    let workspace_dir = workspace_root_dir();
    let mut fallback = Command::new("cargo");
    fallback
        .args(["run", "--quiet", "--bin", "slowclaw", "--", "auth", "status"])
        .current_dir(workspace_dir);
    attempts.push(("cargo run --bin slowclaw".to_string(), fallback));

    let mut errors = Vec::new();
    for (label, mut cmd) in attempts {
        match cmd.output() {
            Ok(output) => {
                let stdout = String::from_utf8_lossy(&output.stdout);
                if output.status.success() {
                    return Ok(openai_auth_is_configured_from_status_output(&stdout));
                }
                errors.push(format!(
                    "{label} exited with code {}",
                    output.status.code().unwrap_or(-1)
                ));
            }
            Err(err) => errors.push(format!("{label}: {err}")),
        }
    }
    Err(format!("failed to check OpenAI auth status ({})", errors.join("; ")))
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

fn slowclaw_binary_file_names() -> Vec<String> {
    let base_name = if cfg!(target_os = "windows") {
        "slowclaw.exe".to_string()
    } else {
        "slowclaw".to_string()
    };
    let mut names = vec![base_name.clone()];
    if let Some(target) = option_env!("TARGET") {
        let suffixed = if cfg!(target_os = "windows") {
            format!("slowclaw-{target}.exe")
        } else {
            format!("slowclaw-{target}")
        };
        if suffixed != base_name {
            names.push(suffixed);
        }
    }
    names
}

fn slowclaw_binary_next_to_current_exe() -> Option<PathBuf> {
    let current_exe = std::env::current_exe().ok()?;
    let current_dir = current_exe.parent()?;
    for file_name in slowclaw_binary_file_names() {
        let sibling_candidate = current_dir.join(&file_name);
        if sibling_candidate.exists() {
            return Some(sibling_candidate);
        }

        let source_tree_candidate = workspace_root_dir()
            .join("web")
            .join("src-tauri")
            .join("binaries")
            .join(&file_name);
        if source_tree_candidate.exists() {
            return Some(source_tree_candidate);
        }
    }
    None
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
                    error: Some(error),
                };
            }
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
                    guard.status.error = Some(err.to_string());
                }
                break;
            }
        }
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
fn get_desktop_host_status(
    state: tauri::State<'_, GatewayState>,
) -> Result<DesktopHostStatus, String> {
    let gateway = snapshot_gateway_state(&state.inner)?;
    let bootstrap_ready = ensure_desktop_gateway_token()
        .map(|token| !token.trim().is_empty())
        .unwrap_or(false);
    Ok(DesktopHostStatus {
        gateway,
        bootstrap_ready,
    })
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
fn get_config() -> Result<AppConfig, String> {
    load_local_app_config_sync()
}

#[tauri::command]
fn get_workspace_paths() -> Result<DesktopWorkspacePaths, String> {
    load_local_workspace_paths_sync()
}

#[tauri::command]
fn open_workspace_dir() -> Result<(), String> {
    let paths = load_local_workspace_paths_sync()?;
    open_path_in_system_file_manager(Path::new(&paths.workspace_dir))
}

#[tauri::command]
fn open_journals_dir() -> Result<(), String> {
    let paths = load_local_workspace_paths_sync()?;
    let journals_path = Path::new(&paths.journals_dir);
    if !journals_path.exists() {
        fs::create_dir_all(journals_path).map_err(|e| {
            format!(
                "failed to create journals directory {}: {e}",
                journals_path.display()
            )
        })?;
    }
    open_path_in_system_file_manager(journals_path)
}

#[tauri::command]
async fn save_config(
    state: tauri::State<'_, GatewayState>,
    config: AppConfig,
) -> Result<AppConfig, String> {
    let mut loaded = zeroclaw::Config::load_or_init()
        .await
        .map_err(|e| format!("failed to load local config: {e}"))?;
    loaded.api_url = Some(config.ollama_base_url.trim().to_string()).filter(|value| !value.is_empty());
    loaded.default_model = Some(config.ollama_model.trim().to_string()).filter(|value| !value.is_empty());
    loaded.transcription.enabled = config.transcription_enabled;
    loaded.transcription.model = recommended_transcription_model(&config.transcription_model);
    loaded
        .save()
        .await
        .map_err(|e| format!("failed to save local config: {e}"))?;

    let _ = restart_embedded_gateway(state.inner.clone()).await?;
    load_local_app_config_sync()
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
    thread::spawn(move || {
        run_openai_device_login_worker(openai_state, gateway_state);
    });

    snapshot_openai_status(&state.inner)
}

#[tauri::command]
async fn get_transcription_setup_status() -> Result<TranscriptionSetupStatus, String> {
    tauri::async_runtime::spawn_blocking(run_transcription_setup_probe_sync)
        .await
        .map_err(|e| format!("failed to join transcription setup probe: {e}"))?
}

#[tauri::command]
async fn run_transcription_setup() -> Result<TranscriptionSetupStatus, String> {
    tauri::async_runtime::spawn_blocking(run_transcription_setup_install_sync)
        .await
        .map_err(|e| format!("failed to join transcription setup installer: {e}"))?
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
            if let Some(window) = app.get_webview_window("main") {
                if let Err(err) = window.show() {
                    eprintln!("failed to show main window during setup: {err}");
                }
                if let Err(err) = window.set_focus() {
                    eprintln!("failed to focus main window during setup: {err}");
                }
            }
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
            get_desktop_host_status,
            generate_mobile_pairing_qr,
            get_desktop_gateway_bootstrap,
            restart_gateway_daemon,
            get_config,
            get_workspace_paths,
            open_workspace_dir,
            open_journals_dir,
            save_config,
            set_provider_api_key,
            get_openai_device_code_status,
            start_openai_device_code_login,
            get_transcription_setup_status,
            run_transcription_setup,
            show_main_window
        ])
        .run(tauri::generate_context!())
        .expect("error while running tauri app");
}

#[cfg(test)]
mod tests {
    use super::slowclaw_binary_file_names;

    #[test]
    fn slowclaw_binary_names_start_with_plain_binary_name() {
        let names = slowclaw_binary_file_names();
        if cfg!(target_os = "windows") {
            assert_eq!(names.first().map(String::as_str), Some("slowclaw.exe"));
        } else {
            assert_eq!(names.first().map(String::as_str), Some("slowclaw"));
        }
    }
}
