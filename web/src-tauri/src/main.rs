use serde::{Deserialize, Serialize};
#[cfg(not(any(target_os = "ios", target_os = "android")))]
use std::fs;
#[cfg(not(any(target_os = "ios", target_os = "android")))]
use std::io;
#[cfg(not(any(target_os = "ios", target_os = "android")))]
use std::fmt::Write as _;
#[cfg(not(any(target_os = "ios", target_os = "android")))]
use std::net::UdpSocket;
#[cfg(not(any(target_os = "ios", target_os = "android")))]
use std::net::{SocketAddr, TcpStream};
#[cfg(all(unix, not(any(target_os = "ios", target_os = "android"))))]
use std::os::unix::fs::PermissionsExt;
#[cfg(not(any(target_os = "ios", target_os = "android")))]
use std::path::{Path, PathBuf};
#[cfg(not(any(target_os = "ios", target_os = "android")))]
use sha2::{Digest, Sha256};
#[cfg(not(any(target_os = "ios", target_os = "android")))]
use std::sync::Mutex;
#[cfg(not(any(target_os = "ios", target_os = "android")))]
use std::time::{Duration, Instant};
#[cfg(not(any(target_os = "ios", target_os = "android")))]
use tauri::async_runtime::{block_on, Receiver};
#[cfg(not(any(target_os = "ios", target_os = "android")))]
use tauri::{Manager, RunEvent, WindowEvent};
#[cfg(not(any(target_os = "ios", target_os = "android")))]
use tauri_plugin_shell::{
    process::{CommandChild, CommandEvent},
    ShellExt,
};
#[cfg(not(any(target_os = "ios", target_os = "android")))]
use toml::Value as TomlValue;

#[cfg(not(any(target_os = "ios", target_os = "android")))]
const GATEWAY_BIND_HOST: &str = "0.0.0.0";
#[cfg(not(any(target_os = "ios", target_os = "android")))]
const GATEWAY_PORT: u16 = 42617;
#[cfg(not(any(target_os = "ios", target_os = "android")))]
const GATEWAY_LOOPBACK_URL: &str = "http://127.0.0.1:42617";
#[cfg(not(any(target_os = "ios", target_os = "android")))]
const POCKETBASE_LOOPBACK_URL: &str = "http://127.0.0.1:8090";
#[cfg(not(any(target_os = "ios", target_os = "android")))]
const BLUESKY_SECRET_SERVICE: &str = "com.example.myskyposter";
#[cfg(not(any(target_os = "ios", target_os = "android")))]
const BLUESKY_SECRET_ACCOUNT: &str = "bluesky.credentials";
#[cfg(not(any(target_os = "ios", target_os = "android")))]
const BLUESKY_SESSION_ACCOUNT: &str = "bluesky.session";
#[cfg(not(any(target_os = "ios", target_os = "android")))]
const GATEWAY_SECRET_SERVICE: &str = "social.slowclaw.gateway";
#[cfg(not(any(target_os = "ios", target_os = "android")))]
const GATEWAY_SECRET_ACCOUNT: &str = "desktop.gateway.token";
#[cfg(not(any(target_os = "ios", target_os = "android")))]
const PROVIDER_API_KEY_ACCOUNT: &str = "provider.api_key";
#[cfg(not(any(target_os = "ios", target_os = "android")))]
const POCKETBASE_SECRET_SERVICE: &str = "social.slowclaw.pocketbase";
#[cfg(not(any(target_os = "ios", target_os = "android")))]
const POCKETBASE_SUPERUSER_ACCOUNT: &str = "local.superuser";
#[cfg(not(any(target_os = "ios", target_os = "android")))]
const CORE_WORKSPACE_FILES: &[&str] = &[
    "AGENTS.md",
    "BOOTSTRAP.md",
    "HEARTBEAT.md",
    "IDENTITY.md",
    "MEMORY.md",
    "SOUL.md",
    "TOOLS.md",
    "USER.md",
];
#[cfg(not(any(target_os = "ios", target_os = "android")))]
const CORE_WORKSPACE_DIRS: &[&str] = &[
    "cron",
    "memory",
    "sessions",
    "skills",
    "scripts",
    "state",
    "journals",
    "journals/text",
    "journals/text/transcripts",
    "journals/text/ocr",
    "journals/media",
    "journals/media/audio",
    "journals/media/video",
    "journals/media/image",
    "journals/processed",
];

#[cfg(not(any(target_os = "ios", target_os = "android")))]
#[derive(Default)]
struct RuntimeProcesses {
    pocketbase: Mutex<Option<CommandChild>>,
    slowclaw_daemon: Mutex<Option<CommandChild>>,
    openai_device_login: Mutex<Option<CommandChild>>,
}

#[cfg(not(any(target_os = "ios", target_os = "android")))]
impl RuntimeProcesses {
    fn set_pocketbase(&self, child: CommandChild) {
        let mut slot = self.pocketbase.lock().expect("pocketbase process mutex poisoned");
        *slot = Some(child);
    }

    fn set_slowclaw_daemon(&self, child: CommandChild) {
        let mut slot = self
            .slowclaw_daemon
            .lock()
            .expect("slowclaw daemon process mutex poisoned");
        *slot = Some(child);
    }

    fn set_openai_device_login(&self, child: CommandChild) {
        let mut slot = self
            .openai_device_login
            .lock()
            .expect("openai device login process mutex poisoned");
        *slot = Some(child);
    }

    fn has_openai_device_login(&self) -> bool {
        self.openai_device_login
            .lock()
            .expect("openai device login process mutex poisoned")
            .is_some()
    }

    fn clear_openai_device_login(&self) {
        let _ = self
            .openai_device_login
            .lock()
            .expect("openai device login process mutex poisoned")
            .take();
    }

    fn shutdown_all(&self) {
        shutdown_process(&self.slowclaw_daemon);
        shutdown_process(&self.openai_device_login);
        shutdown_process(&self.pocketbase);
    }
}

#[cfg(not(any(target_os = "ios", target_os = "android")))]
fn shutdown_process(slot: &Mutex<Option<CommandChild>>) {
    if let Some(child) = slot.lock().expect("process mutex poisoned").take() {
        let _ = child.kill();
    }
}

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

#[derive(Debug, Serialize, Clone)]
struct MobilePairingQrPayload {
    gateway_url: String,
    token: String,
    qr_value: String,
}

#[cfg(not(any(target_os = "ios", target_os = "android")))]
#[derive(Debug, Serialize, Clone)]
#[serde(rename_all = "camelCase")]
struct DesktopGatewayBootstrapPayload {
    token: Option<String>,
    gateway_url: String,
}

#[cfg(not(any(target_os = "ios", target_os = "android")))]
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

#[cfg(not(any(target_os = "ios", target_os = "android")))]
#[derive(Debug, Clone)]
struct OpenAiDeviceCodeStatusState {
    state: String,
    running: bool,
    completed: bool,
    message: String,
    verification_url: Option<String>,
    user_code: Option<String>,
    fast_link: Option<String>,
    error: Option<String>,
}

#[cfg(not(any(target_os = "ios", target_os = "android")))]
impl Default for OpenAiDeviceCodeStatusState {
    fn default() -> Self {
        Self {
            state: "idle".to_string(),
            running: false,
            completed: false,
            message: "Not started".to_string(),
            verification_url: None,
            user_code: None,
            fast_link: None,
            error: None,
        }
    }
}

#[cfg(not(any(target_os = "ios", target_os = "android")))]
impl From<&OpenAiDeviceCodeStatusState> for OpenAiDeviceCodeStatus {
    fn from(value: &OpenAiDeviceCodeStatusState) -> Self {
        Self {
            state: value.state.clone(),
            running: value.running,
            completed: value.completed,
            message: value.message.clone(),
            verification_url: value.verification_url.clone(),
            user_code: value.user_code.clone(),
            fast_link: value.fast_link.clone(),
            error: value.error.clone(),
        }
    }
}

#[cfg(not(any(target_os = "ios", target_os = "android")))]
#[derive(Default)]
struct OpenAiDeviceCodeFlow {
    status: Mutex<OpenAiDeviceCodeStatusState>,
}

#[cfg(not(any(target_os = "ios", target_os = "android")))]
impl OpenAiDeviceCodeFlow {
    fn snapshot(&self) -> OpenAiDeviceCodeStatus {
        let status = self
            .status
            .lock()
            .expect("openai device-code status mutex poisoned");
        OpenAiDeviceCodeStatus::from(&*status)
    }

    fn set_status(&self, next: OpenAiDeviceCodeStatusState) {
        let mut status = self
            .status
            .lock()
            .expect("openai device-code status mutex poisoned");
        *status = next;
    }

    fn update_status<F>(&self, update: F)
    where
        F: FnOnce(&mut OpenAiDeviceCodeStatusState),
    {
        let mut status = self
            .status
            .lock()
            .expect("openai device-code status mutex poisoned");
        update(&mut status);
    }
}

#[cfg(not(any(target_os = "ios", target_os = "android")))]
#[derive(Debug, Clone)]
struct DesktopPaths {
    config_dir: PathBuf,
    workspace_dir: PathBuf,
}

#[cfg(not(any(target_os = "ios", target_os = "android")))]
#[derive(Debug, Deserialize)]
struct PairNewCodeResponse {
    code: String,
}

#[cfg(not(any(target_os = "ios", target_os = "android")))]
#[derive(Debug, Deserialize)]
struct PairTokenResponse {
    token: String,
}

#[cfg(not(any(target_os = "ios", target_os = "android")))]
#[derive(Debug, Deserialize)]
struct BlueskyCredentialsSecret {
    #[serde(default)]
    service_url: String,
    #[serde(default)]
    handle: String,
    #[serde(default)]
    app_password: String,
    #[serde(rename = "serviceUrl", default)]
    service_url_legacy: String,
    #[serde(rename = "appPassword", default)]
    app_password_legacy: String,
}

#[cfg(not(any(target_os = "ios", target_os = "android")))]
#[derive(Debug, Deserialize)]
struct BlueskySessionSecret {
    #[serde(rename = "accessJwt", default)]
    access_jwt: String,
    #[serde(rename = "refreshJwt", default)]
    refresh_jwt: String,
    #[serde(default)]
    did: String,
    #[serde(default)]
    handle: String,
}

#[cfg(not(any(target_os = "ios", target_os = "android")))]
#[derive(Debug, Clone, Serialize, Deserialize)]
struct PocketBaseSuperuserSecret {
    email: String,
    password: String,
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
async fn generate_mobile_pairing_qr(app: tauri::AppHandle) -> Result<MobilePairingQrPayload, String> {
    #[cfg(any(target_os = "ios", target_os = "android"))]
    {
        let _ = app;
        Err("QR pairing generation is desktop-only".to_string())
    }
    #[cfg(not(any(target_os = "ios", target_os = "android")))]
    {
        generate_mobile_pairing_qr_desktop(app).await
    }
}

#[tauri::command]
async fn get_desktop_gateway_bootstrap(
    app: tauri::AppHandle,
) -> Result<DesktopGatewayBootstrapPayload, String> {
    #[cfg(any(target_os = "ios", target_os = "android"))]
    {
        let _ = app;
        Err("get_desktop_gateway_bootstrap is desktop-only".to_string())
    }
    #[cfg(not(any(target_os = "ios", target_os = "android")))]
    {
        let paths = ensure_workspace_ready_async(&app).await?;
        let config_path = paths.config_dir.join("config.toml");
        let token = load_gateway_token_from_keyring()
            .or_else(|| read_gateway_token_from_config(&config_path));
        if let Some(token_value) = token.as_deref() {
            if let Err(err) = save_gateway_token_to_keyring(token_value) {
                eprintln!("warning: failed to cache desktop gateway token in keyring: {err}");
            }
        }
        Ok(DesktopGatewayBootstrapPayload {
            token,
            gateway_url: format!("http://127.0.0.1:{GATEWAY_PORT}"),
        })
    }
}

#[cfg(not(any(target_os = "ios", target_os = "android")))]
async fn generate_mobile_pairing_qr_desktop(
    app: tauri::AppHandle,
) -> Result<MobilePairingQrPayload, String> {
    wait_for_gateway_ready().await?;
    let desktop_token = if let Some(token) = load_gateway_token_from_keyring() {
        token
    } else {
        let paths = ensure_workspace_ready_async(&app).await?;
        let config_path = paths.config_dir.join("config.toml");
        let token = read_gateway_token_from_config(&config_path).ok_or_else(|| {
            "Desktop gateway token not found in keyring/config. Restart app.".to_string()
        })?;
        if let Err(err) = save_gateway_token_to_keyring(&token) {
            eprintln!("warning: failed to cache desktop gateway token in keyring: {err}");
        }
        token
    };
    if !is_gateway_token_valid(&desktop_token).await {
        return Err(
            "Desktop gateway token is not valid anymore. Restart app to refresh pairing."
                .to_string(),
        );
    }
    let mobile_token = mint_additional_gateway_token(&desktop_token).await?;
    let local_ip = resolve_local_lan_ip().unwrap_or_else(|| "127.0.0.1".to_string());
    let gateway_url = format!("http://{}:{}", local_ip, GATEWAY_PORT);
    let qr_value = serde_json::json!({
        "gatewayUrl": gateway_url,
        "token": mobile_token,
    })
    .to_string();
    Ok(MobilePairingQrPayload {
        gateway_url,
        token: mobile_token,
        qr_value,
    })
}

#[cfg(not(any(target_os = "ios", target_os = "android")))]
fn resolve_desktop_paths(app: &tauri::AppHandle) -> Result<DesktopPaths, String> {
    let app_data_dir = app
        .path()
        .app_data_dir()
        .map_err(|e| format!("failed to resolve app data dir: {e}"))?;
    fs::create_dir_all(&app_data_dir)
        .map_err(|e| format!("failed to create app data dir {}: {e}", app_data_dir.display()))?;
    let workspace_dir = app_data_dir.join("workspace");
    fs::create_dir_all(&workspace_dir)
        .map_err(|e| format!("failed to create workspace dir {}: {e}", workspace_dir.display()))?;
    Ok(DesktopPaths {
        config_dir: app_data_dir,
        workspace_dir,
    })
}

#[cfg(not(any(target_os = "ios", target_os = "android")))]
fn is_effectively_empty(dir: &Path) -> io::Result<bool> {
    if !dir.exists() {
        return Ok(true);
    }
    for entry in fs::read_dir(dir)? {
        let entry = entry?;
        let name = entry.file_name();
        if name == ".DS_Store" {
            continue;
        }
        return Ok(false);
    }
    Ok(true)
}

#[cfg(not(any(target_os = "ios", target_os = "android")))]
fn workspace_skeleton_missing(paths: &DesktopPaths) -> bool {
    let missing_file = CORE_WORKSPACE_FILES
        .iter()
        .any(|name| !paths.workspace_dir.join(name).exists());
    if missing_file {
        return true;
    }
    CORE_WORKSPACE_DIRS
        .iter()
        .any(|name| !paths.workspace_dir.join(name).exists())
}

#[cfg(not(any(target_os = "ios", target_os = "android")))]
fn repair_workspace_skeleton(paths: &DesktopPaths) -> Result<(), String> {
    for dir in CORE_WORKSPACE_DIRS {
        let full = paths.workspace_dir.join(dir);
        fs::create_dir_all(&full)
            .map_err(|e| format!("failed to create workspace dir {}: {e}", full.display()))?;
    }
    for file in CORE_WORKSPACE_FILES {
        let full = paths.workspace_dir.join(file);
        if !full.exists() {
            fs::write(&full, format!("# {}\n", file.trim_end_matches(".md")))
                .map_err(|e| format!("failed to create workspace file {}: {e}", full.display()))?;
        }
    }
    Ok(())
}

#[cfg(not(any(target_os = "ios", target_os = "android")))]
fn repair_workspace_scripts(paths: &DesktopPaths) -> Result<(), String> {
    let scripts_dir = paths.workspace_dir.join("scripts");
    fs::create_dir_all(&scripts_dir).map_err(|e| {
        format!(
            "failed to create workspace scripts dir {}: {e}",
            scripts_dir.display()
        )
    })?;
    repair_shell_script_permissions_recursive(&scripts_dir)
}

#[cfg(all(unix, not(any(target_os = "ios", target_os = "android"))))]
fn repair_shell_script_permissions_recursive(root: &Path) -> Result<(), String> {
    let mut stack = vec![root.to_path_buf()];
    while let Some(dir) = stack.pop() {
        let entries = fs::read_dir(&dir)
            .map_err(|e| format!("failed to read workspace scripts dir {}: {e}", dir.display()))?;
        for entry in entries {
            let entry = entry.map_err(|e| {
                format!("failed to read workspace scripts entry in {}: {e}", dir.display())
            })?;
            let file_type = entry.file_type().map_err(|e| {
                format!(
                    "failed to read workspace scripts entry type {}: {e}",
                    entry.path().display()
                )
            })?;
            if file_type.is_symlink() {
                continue;
            }
            let path = entry.path();
            if file_type.is_dir() {
                stack.push(path);
                continue;
            }
            if !file_type.is_file() {
                continue;
            }
            let is_shell_script = path
                .extension()
                .and_then(|ext| ext.to_str())
                .is_some_and(|ext| ext.eq_ignore_ascii_case("sh"));
            if !is_shell_script {
                continue;
            }
            let metadata = fs::metadata(&path).map_err(|e| {
                format!(
                    "failed to read shell script metadata {}: {e}",
                    path.display()
                )
            })?;
            let mut permissions = metadata.permissions();
            let mode = permissions.mode();
            if mode & 0o100 == 0 {
                permissions.set_mode(mode | 0o100);
                fs::set_permissions(&path, permissions).map_err(|e| {
                    format!(
                        "failed to set shell script execute permission {}: {e}",
                        path.display()
                    )
                })?;
            }
        }
    }
    Ok(())
}

#[cfg(all(not(unix), not(any(target_os = "ios", target_os = "android"))))]
fn repair_shell_script_permissions_recursive(_root: &Path) -> Result<(), String> {
    Ok(())
}

#[cfg(not(any(target_os = "ios", target_os = "android")))]
async fn run_sidecar_onboard_async(
    app: &tauri::AppHandle,
    paths: &DesktopPaths,
    force: bool,
) -> Result<(), String> {
    let config_dir_arg = paths.config_dir.to_string_lossy().to_string();
    let mut command = app
        .shell()
        .sidecar("slowclaw")
        .map_err(|e| format!("failed to resolve slowclaw sidecar for onboarding: {e}"))?;

    command = command
        .args([
            "onboard",
            "--memory",
            "markdown",
            "--provider",
            "openai-codex",
            "--model",
            "gpt-5.3-codex",
        ])
        .env("ZEROCLAW_CONFIG_DIR", &config_dir_arg);
    if force {
        command = command.arg("--force");
    }

    let output = command
        .output()
        .await
        .map_err(|e| format!("failed to execute slowclaw onboard sidecar: {e}"))?;
    if output.status.success() {
        return Ok(());
    }

    let stderr = String::from_utf8_lossy(&output.stderr);
    let stdout = String::from_utf8_lossy(&output.stdout);
    Err(format!(
        "slowclaw onboard failed (status {:?})\nstdout:\n{}\nstderr:\n{}",
        output.status.code(),
        stdout.trim(),
        stderr.trim()
    ))
}

async fn ensure_workspace_ready_async(app: &tauri::AppHandle) -> Result<DesktopPaths, String> {
    let paths = resolve_desktop_paths(app)?;
    let config_path = paths.config_dir.join("config.toml");
    let config_exists = config_path.exists();
    let workspace_empty = is_effectively_empty(&paths.workspace_dir)
        .map_err(|e| format!("failed to inspect workspace dir: {e}"))?;

    if !config_exists || workspace_empty {
        run_sidecar_onboard_async(app, &paths, config_exists).await?;
    }
    if workspace_skeleton_missing(&paths) {
        repair_workspace_skeleton(&paths)?;
    }
    if let Err(err) = repair_workspace_scripts(&paths) {
        eprintln!("warning: workspace script permission repair skipped: {err}");
    }

    if !config_path.exists() {
        return Err(format!(
            "workspace scaffolding incomplete: missing {}",
            config_path.display()
        ));
    }

    let gateway_token = ensure_gateway_token_seeded(&config_path)?;
    if let Err(err) = save_gateway_token_to_keyring(&gateway_token) {
        eprintln!("warning: failed to cache desktop gateway token in keyring: {err}");
    }

    Ok(paths)
}

#[cfg(not(any(target_os = "ios", target_os = "android")))]
fn ensure_workspace_ready_blocking(app: &tauri::AppHandle) -> Result<DesktopPaths, String> {
    block_on(ensure_workspace_ready_async(app))
}

#[cfg(not(any(target_os = "ios", target_os = "android")))]
fn is_paired_token_hash(value: &str) -> bool {
    let trimmed = value.trim();
    trimmed.len() == 64 && trimmed.chars().all(|ch| ch.is_ascii_hexdigit())
}

#[cfg(not(any(target_os = "ios", target_os = "android")))]
fn hash_gateway_token(token: &str) -> String {
    let digest = Sha256::digest(token.as_bytes());
    let mut out = String::with_capacity(digest.len() * 2);
    for byte in digest {
        let _ = write!(&mut out, "{byte:02x}");
    }
    out
}

#[cfg(not(any(target_os = "ios", target_os = "android")))]
fn read_gateway_tokens_from_config(config_path: &Path) -> Option<Vec<String>> {
    let raw = fs::read_to_string(config_path).ok()?;
    let parsed: TomlValue = toml::from_str(&raw).ok()?;
    let gateway = parsed.get("gateway")?.as_table()?;
    let tokens = gateway.get("paired_tokens")?.as_array()?;
    Some(
        tokens
            .iter()
            .filter_map(TomlValue::as_str)
            .map(str::trim)
            .filter(|token| !token.is_empty())
            .map(ToOwned::to_owned)
            .collect(),
    )
}

#[cfg(not(any(target_os = "ios", target_os = "android")))]
fn read_gateway_token_from_config(config_path: &Path) -> Option<String> {
    read_gateway_tokens_from_config(config_path)?
        .into_iter()
        .find(|token| !is_paired_token_hash(token))
}

#[cfg(not(any(target_os = "ios", target_os = "android")))]
fn generate_gateway_bearer_token() -> Result<String, String> {
    let mut bytes = [0_u8; 32];
    getrandom::getrandom(&mut bytes)
        .map_err(|e| format!("failed to generate secure gateway token: {e}"))?;
    let mut hex = String::with_capacity(bytes.len() * 2);
    for byte in bytes {
        let _ = write!(&mut hex, "{byte:02x}");
    }
    Ok(format!("zc_{hex}"))
}

#[cfg(not(any(target_os = "ios", target_os = "android")))]
fn ensure_gateway_token_seeded(config_path: &Path) -> Result<String, String> {
    if let Some(tokens) = read_gateway_tokens_from_config(config_path) {
        if let Some(keyring_token) = load_gateway_token_from_keyring() {
            let keyring_trimmed = keyring_token.trim();
            if !keyring_trimmed.is_empty() {
                let keyring_hash = hash_gateway_token(keyring_trimmed);
                if tokens.iter().any(|token| {
                    let token_trimmed = token.trim();
                    token_trimmed == keyring_trimmed || token_trimmed == keyring_hash
                }) {
                    return Ok(keyring_trimmed.to_string());
                }
            }
        }
        if let Some(existing_plaintext) = tokens
            .iter()
            .find(|token| !is_paired_token_hash(token))
            .cloned()
        {
            return Ok(existing_plaintext);
        }
    }

    let raw = fs::read_to_string(config_path)
        .map_err(|e| format!("failed to read config file {}: {e}", config_path.display()))?;
    let mut parsed: TomlValue =
        toml::from_str(&raw).map_err(|e| format!("failed to parse config TOML: {e}"))?;

    let root = parsed
        .as_table_mut()
        .ok_or_else(|| "config root is not a TOML table".to_string())?;
    let gateway_entry = root
        .entry("gateway".to_string())
        .or_insert_with(|| TomlValue::Table(toml::map::Map::new()));
    let gateway = gateway_entry
        .as_table_mut()
        .ok_or_else(|| "[gateway] config section is not a TOML table".to_string())?;

    let token = generate_gateway_bearer_token()?;
    gateway.insert("require_pairing".to_string(), TomlValue::Boolean(true));
    match gateway.get_mut("paired_tokens").and_then(TomlValue::as_array_mut) {
        Some(tokens) => tokens.push(TomlValue::String(token.clone())),
        None => {
            gateway.insert(
                "paired_tokens".to_string(),
                TomlValue::Array(vec![TomlValue::String(token.clone())]),
            );
        }
    }

    let rendered = toml::to_string_pretty(&parsed)
        .map_err(|e| format!("failed to serialize updated config TOML: {e}"))?;
    fs::write(config_path, rendered)
        .map_err(|e| format!("failed to write config file {}: {e}", config_path.display()))?;
    Ok(token)
}

#[cfg(not(any(target_os = "ios", target_os = "android")))]
fn load_gateway_token_from_keyring() -> Option<String> {
    let entry = keyring::Entry::new(GATEWAY_SECRET_SERVICE, GATEWAY_SECRET_ACCOUNT).ok()?;
    match entry.get_password() {
        Ok(value) if !value.trim().is_empty() => Some(value),
        _ => None,
    }
}

#[cfg(not(any(target_os = "ios", target_os = "android")))]
fn save_gateway_token_to_keyring(token: &str) -> Result<(), String> {
    let entry = keyring::Entry::new(GATEWAY_SECRET_SERVICE, GATEWAY_SECRET_ACCOUNT)
        .map_err(|e| format!("failed to open gateway token keyring entry: {e}"))?;
    entry
        .set_password(token)
        .map_err(|e| format!("failed to write gateway token to keyring: {e}"))
}

#[cfg(not(any(target_os = "ios", target_os = "android")))]
fn load_bluesky_credentials_from_keyring() -> Option<BlueskyCredentialsSecret> {
    let entry = keyring::Entry::new(BLUESKY_SECRET_SERVICE, BLUESKY_SECRET_ACCOUNT).ok()?;
    let raw = entry.get_password().ok()?;
    serde_json::from_str::<BlueskyCredentialsSecret>(&raw).ok()
}

#[cfg(not(any(target_os = "ios", target_os = "android")))]
fn load_bluesky_session_from_keyring() -> Option<BlueskySessionSecret> {
    let entry = keyring::Entry::new(BLUESKY_SECRET_SERVICE, BLUESKY_SESSION_ACCOUNT).ok()?;
    let raw = entry.get_password().ok()?;
    serde_json::from_str::<BlueskySessionSecret>(&raw).ok()
}

#[cfg(not(any(target_os = "ios", target_os = "android")))]
fn load_provider_api_key_from_keyring() -> Option<String> {
    let entry = keyring::Entry::new(GATEWAY_SECRET_SERVICE, PROVIDER_API_KEY_ACCOUNT).ok()?;
    let raw = entry.get_password().ok()?;
    let key = raw.trim();
    if key.is_empty() {
        return None;
    }
    Some(key.to_string())
}

#[cfg(not(any(target_os = "ios", target_os = "android")))]
fn load_pocketbase_superuser_secret_from_keyring() -> Option<PocketBaseSuperuserSecret> {
    let entry = keyring::Entry::new(POCKETBASE_SECRET_SERVICE, POCKETBASE_SUPERUSER_ACCOUNT).ok()?;
    let raw = entry.get_password().ok()?;
    serde_json::from_str::<PocketBaseSuperuserSecret>(&raw).ok()
}

#[cfg(not(any(target_os = "ios", target_os = "android")))]
fn save_pocketbase_superuser_secret_to_keyring(secret: &PocketBaseSuperuserSecret) -> Result<(), String> {
    let entry = keyring::Entry::new(POCKETBASE_SECRET_SERVICE, POCKETBASE_SUPERUSER_ACCOUNT)
        .map_err(|e| format!("failed to open pocketbase keyring entry: {e}"))?;
    let raw = serde_json::to_string(secret)
        .map_err(|e| format!("failed to serialize pocketbase superuser secret: {e}"))?;
    entry
        .set_password(&raw)
        .map_err(|e| format!("failed to write pocketbase superuser secret: {e}"))
}

#[cfg(not(any(target_os = "ios", target_os = "android")))]
fn generate_pocketbase_superuser_secret() -> Result<PocketBaseSuperuserSecret, String> {
    let mut email_seed = [0_u8; 4];
    let mut password_seed = [0_u8; 16];
    getrandom::getrandom(&mut email_seed)
        .map_err(|e| format!("failed to generate PocketBase email seed: {e}"))?;
    getrandom::getrandom(&mut password_seed)
        .map_err(|e| format!("failed to generate PocketBase password seed: {e}"))?;

    let mut email_hex = String::with_capacity(email_seed.len() * 2);
    for byte in email_seed {
        let _ = write!(&mut email_hex, "{byte:02x}");
    }

    let mut password_hex = String::with_capacity(password_seed.len() * 2);
    for byte in password_seed {
        let _ = write!(&mut password_hex, "{byte:02x}");
    }

    Ok(PocketBaseSuperuserSecret {
        email: format!("local-admin+{email_hex}@slowclaw.local"),
        password: format!("zc_{password_hex}"),
    })
}

#[cfg(not(any(target_os = "ios", target_os = "android")))]
fn ensure_pocketbase_superuser_secret() -> Result<PocketBaseSuperuserSecret, String> {
    if let Some(secret) = load_pocketbase_superuser_secret_from_keyring() {
        return Ok(secret);
    }

    let secret = generate_pocketbase_superuser_secret()?;
    save_pocketbase_superuser_secret_to_keyring(&secret)?;
    Ok(secret)
}

#[cfg(not(any(target_os = "ios", target_os = "android")))]
fn bluesky_env_pairs() -> Vec<(String, String)> {
    let Some(mut creds) = load_bluesky_credentials_from_keyring() else {
        return Vec::new();
    };
    if creds.service_url.is_empty() {
        creds.service_url = creds.service_url_legacy.clone();
    }
    if creds.app_password.is_empty() {
        creds.app_password = creds.app_password_legacy.clone();
    }

    let mut envs = Vec::new();
    if !creds.service_url.trim().is_empty() {
        envs.push((
            "SLOWCLAW_BLUESKY_SERVICE_URL".to_string(),
            creds.service_url.trim().to_string(),
        ));
    }
    if !creds.handle.trim().is_empty() {
        envs.push((
            "SLOWCLAW_BLUESKY_HANDLE".to_string(),
            creds.handle.trim().to_string(),
        ));
    }
    if !creds.app_password.trim().is_empty() {
        envs.push((
            "SLOWCLAW_BLUESKY_APP_PASSWORD".to_string(),
            creds.app_password.trim().to_string(),
        ));
    }

    if let Some(session) = load_bluesky_session_from_keyring() {
        if !session.access_jwt.trim().is_empty() {
            envs.push((
                "SLOWCLAW_BLUESKY_ACCESS_JWT".to_string(),
                session.access_jwt.trim().to_string(),
            ));
        }
        if !session.refresh_jwt.trim().is_empty() {
            envs.push((
                "SLOWCLAW_BLUESKY_REFRESH_JWT".to_string(),
                session.refresh_jwt.trim().to_string(),
            ));
        }
        if !session.did.trim().is_empty() {
            envs.push(("SLOWCLAW_BLUESKY_DID".to_string(), session.did.trim().to_string()));
        }
        if !session.handle.trim().is_empty() {
            envs.push((
                "SLOWCLAW_BLUESKY_SESSION_HANDLE".to_string(),
                session.handle.trim().to_string(),
            ));
        }
    }
    envs
}

#[cfg(not(any(target_os = "ios", target_os = "android")))]
fn resolve_pocketbase_data_dir(app: &tauri::AppHandle) -> io::Result<PathBuf> {
    if let Ok(explicit) = std::env::var("ZEROCLAW_POCKETBASE_DATA_DIR") {
        let explicit = explicit.trim();
        if !explicit.is_empty() {
            let path = PathBuf::from(explicit);
            fs::create_dir_all(&path)?;
            return Ok(path);
        }
    }

    if let Ok(paths) = resolve_desktop_paths(app) {
        let app_workspace_pb = paths.workspace_dir.join("pb_data");
        fs::create_dir_all(&app_workspace_pb)?;
        return Ok(app_workspace_pb);
    }

    if let Ok(home) = std::env::var("HOME") {
        let workspace_pb = PathBuf::from(home)
            .join(".zeroclaw")
            .join("workspace")
            .join("pb_data");
        if workspace_pb.exists() {
            return Ok(workspace_pb);
        }
    }

    let repo_pb = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../..")
        .join("pb_data");
    if repo_pb.exists() {
        return Ok(repo_pb);
    }

    let app_data_dir = app
        .path()
        .app_data_dir()
        .map_err(|e| io::Error::other(format!("failed to resolve app data dir: {e}")))?;
    let fallback = app_data_dir.join("pocketbase");
    fs::create_dir_all(&fallback)?;
    Ok(fallback)
}

#[cfg(not(any(target_os = "ios", target_os = "android")))]
#[cfg(debug_assertions)]
fn resolve_pocketbase_migrations_dir(_app: &tauri::AppHandle) -> io::Result<PathBuf> {
    let repo_migrations = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("../..")
        .join("pb_migrations");
    Ok(repo_migrations.canonicalize().unwrap_or(repo_migrations))
}

#[cfg(not(any(target_os = "ios", target_os = "android")))]
#[cfg(not(debug_assertions))]
fn resolve_pocketbase_migrations_dir(app: &tauri::AppHandle) -> io::Result<PathBuf> {
    let resource_dir = app
        .path()
        .resource_dir()
        .map_err(|e| io::Error::other(format!("failed to resolve resource dir: {e}")))?;
    Ok(resource_dir.join("pb_migrations"))
}

#[cfg(not(any(target_os = "ios", target_os = "android")))]
fn resolve_pocketbase_spawn_args(app: &tauri::AppHandle) -> Result<(String, String), String> {
    let pocketbase_data_dir = resolve_pocketbase_data_dir(app)
        .map_err(|e| format!("failed to resolve PocketBase data dir: {e}"))?;
    let pocketbase_data_dir = pocketbase_data_dir
        .canonicalize()
        .unwrap_or(pocketbase_data_dir);
    let data_arg = pocketbase_data_dir.to_string_lossy().to_string();
    let migrations_dir = resolve_pocketbase_migrations_dir(app)
        .map_err(|e| format!("failed to resolve PocketBase migrations dir: {e}"))?;
    let migrations_arg = migrations_dir.to_string_lossy().to_string();
    Ok((data_arg, migrations_arg))
}

#[cfg(not(any(target_os = "ios", target_os = "android")))]
async fn ensure_pocketbase_superuser_seeded(
    app: &tauri::AppHandle,
    data_arg: &str,
    migrations_arg: &str,
) -> Result<(), String> {
    let secret = ensure_pocketbase_superuser_secret()?;
    let mut command = app
        .shell()
        .sidecar("pocketbase")
        .map_err(|e| format!("failed to resolve PocketBase sidecar for superuser bootstrap: {e}"))?;
    command = command.args([
        "superuser",
        "upsert",
        &secret.email,
        &secret.password,
        "--dir",
        data_arg,
        "--migrationsDir",
        migrations_arg,
    ]);
    let output = command
        .output()
        .await
        .map_err(|e| format!("failed to execute PocketBase superuser bootstrap: {e}"))?;
    if output.status.success() {
        return Ok(());
    }

    let stderr = String::from_utf8_lossy(&output.stderr);
    let stdout = String::from_utf8_lossy(&output.stdout);
    Err(format!(
        "PocketBase superuser bootstrap failed (status {:?})\nstdout:\n{}\nstderr:\n{}",
        output.status.code(),
        stdout.trim(),
        stderr.trim()
    ))
}

#[cfg(not(any(target_os = "ios", target_os = "android")))]
fn spawn_pocketbase_sidecar(app: &tauri::AppHandle) -> Result<CommandChild, String> {
    let (data_arg, migrations_arg) = resolve_pocketbase_spawn_args(app)?;

    let mut command = app
        .shell()
        .sidecar("pocketbase")
        .map_err(|e| format!("failed to resolve PocketBase sidecar binary: {e}"))?;
    command = command.args([
        "serve",
        "--http",
        "127.0.0.1:8090",
        "--dir",
        &data_arg,
        "--migrationsDir",
        &migrations_arg,
    ]);
    #[cfg(not(debug_assertions))]
    {
        command = command.args(["--automigrate=0"]);
    }
    let (_rx, child) = command
        .spawn()
        .map_err(|e| format!("failed to spawn PocketBase sidecar: {e}"))?;
    Ok(child)
}

#[cfg(not(any(target_os = "ios", target_os = "android")))]
fn spawn_slowclaw_daemon(
    app: &tauri::AppHandle,
    paths: &DesktopPaths,
) -> Result<(Receiver<CommandEvent>, CommandChild), String> {
    let config_dir = paths.config_dir.to_string_lossy().to_string();
    let workspace_dir = paths.workspace_dir.to_string_lossy().to_string();

    let mut command = app
        .shell()
        .sidecar("slowclaw")
        .map_err(|e| format!("failed to resolve slowclaw sidecar binary: {e}"))?;
    command = command
        .args([
            "daemon",
            "--host",
            GATEWAY_BIND_HOST,
            "--port",
            &GATEWAY_PORT.to_string(),
        ])
        .env("ZEROCLAW_CONFIG_DIR", &config_dir)
        .env("ZEROCLAW_WORKSPACE", &workspace_dir)
        .env("ZEROCLAW_ALLOW_PUBLIC_BIND", "1")
        .env("ZEROCLAW_POCKETBASE_DISABLE", "1")
        .env("ZEROCLAW_POCKETBASE_URL", POCKETBASE_LOOPBACK_URL);

    if let Some(api_key) = load_provider_api_key_from_keyring() {
        command = command.env("ZEROCLAW_API_KEY", api_key);
    }

    for (key, value) in bluesky_env_pairs() {
        command = command.env(key, value);
    }

    command
        .spawn()
        .map_err(|e| format!("failed to spawn slowclaw daemon sidecar: {e}"))
}

#[cfg(not(any(target_os = "ios", target_os = "android")))]
fn extract_marker_value(line: &str, marker: &str) -> Option<String> {
    let (_, tail) = line.split_once(marker)?;
    let value = tail.trim();
    if value.is_empty() {
        return None;
    }
    Some(value.to_string())
}

#[cfg(not(any(target_os = "ios", target_os = "android")))]
fn extract_first_url(line: &str) -> Option<String> {
    for marker in ["https://", "http://"] {
        if let Some(start) = line.find(marker) {
            let candidate = line[start..]
                .split_whitespace()
                .next()
                .unwrap_or_default()
                .trim_matches(|ch: char| matches!(ch, '"' | '\'' | ')' | ']' | '>' | ',' | '.'))
                .to_string();
            if !candidate.is_empty() {
                return Some(candidate);
            }
        }
    }
    None
}

#[cfg(not(any(target_os = "ios", target_os = "android")))]
fn is_loopback_url(url: &str) -> bool {
    let lower = url.trim().to_ascii_lowercase();
    lower.starts_with("http://localhost:")
        || lower.starts_with("https://localhost:")
        || lower.starts_with("http://127.0.0.1:")
        || lower.starts_with("https://127.0.0.1:")
}

#[cfg(not(any(target_os = "ios", target_os = "android")))]
fn apply_openai_device_code_line(status: &mut OpenAiDeviceCodeStatusState, line: &str) {
    let trimmed = line.trim();
    if trimmed.is_empty() {
        return;
    }

    if let Some(url) = extract_marker_value(trimmed, "Visit:") {
        status.verification_url = Some(url.clone());
        status.running = true;
        status.state = "pending".to_string();
        status.message = format!("Open the verification URL and enter code {}", status.user_code.clone().unwrap_or_else(|| "<pending>".to_string()));
        return;
    }

    if let Some(code) = extract_marker_value(trimmed, "Code:") {
        status.user_code = Some(code.clone());
        status.running = true;
        status.state = "pending".to_string();
        status.message = format!("Enter code {code} on the verification page.");
        return;
    }

    if let Some(link) = extract_marker_value(trimmed, "Fast link:") {
        status.fast_link = Some(link.clone());
        status.running = true;
        status.state = "pending".to_string();
        status.message = "Open the fast link to complete OpenAI login.".to_string();
        return;
    }

    if trimmed.starts_with("Open this URL in your browser") {
        status.running = true;
        status.state = "pending".to_string();
        status.message = "Open the login URL below, then finish login in your browser.".to_string();
        return;
    }

    if trimmed.starts_with("Waiting for callback at ") {
        if let Some(url) = extract_first_url(trimmed) {
            if !is_loopback_url(&url) {
                status.verification_url = Some(url);
            }
        }
        status.running = true;
        status.state = "pending".to_string();
        status.message =
            "Login started. Complete browser auth; the app is waiting for callback.".to_string();
        return;
    }

    if let Some(url) = extract_first_url(trimmed) {
        if is_loopback_url(&url) {
            if status.verification_url.is_some() {
                status.running = true;
                status.state = "pending".to_string();
            }
            return;
        }
        status.verification_url = Some(url.clone());
        status.running = true;
        status.state = "pending".to_string();
        status.message = format!("Open this URL to continue login: {url}");
        return;
    }

    if trimmed.contains("OpenAI device-code login started") {
        status.running = true;
        status.state = "starting".to_string();
        status.message = "Waiting for OpenAI device-code instructions...".to_string();
        status.error = None;
        return;
    }

    if trimmed.contains("Saved profile")
        || trimmed.contains("Active profile for openai-codex")
        || trimmed.contains("Login complete")
    {
        status.running = false;
        status.completed = true;
        status.state = "completed".to_string();
        status.message = "OpenAI authentication complete.".to_string();
        status.error = None;
        return;
    }

    if let Some(err) = extract_marker_value(trimmed, "Error:") {
        status.running = false;
        status.completed = false;
        status.state = "error".to_string();
        status.error = Some(err.clone());
        status.message = err;
        return;
    }

    if status.state == "starting" || status.state == "pending" {
        status.message = trimmed.to_string();
    }
}

#[cfg(not(any(target_os = "ios", target_os = "android")))]
async fn wait_for_gateway_ready() -> Result<(), String> {
    let client = reqwest::Client::new();
    let deadline = Instant::now() + Duration::from_secs(20);
    loop {
        if Instant::now() >= deadline {
            return Err("gateway did not become healthy in time".to_string());
        }
        match client
            .get(format!("{GATEWAY_LOOPBACK_URL}/health"))
            .timeout(Duration::from_millis(800))
            .send()
            .await
        {
            Ok(resp) if resp.status().is_success() => return Ok(()),
            _ => {
                tokio::time::sleep(Duration::from_millis(250)).await;
            }
        }
    }
}

#[cfg(not(any(target_os = "ios", target_os = "android")))]
fn wait_for_pocketbase_ready_blocking() -> Result<(), String> {
    let address: SocketAddr = "127.0.0.1:8090"
        .parse()
        .map_err(|e| format!("invalid PocketBase address: {e}"))?;
    let deadline = Instant::now() + Duration::from_secs(10);
    loop {
        if TcpStream::connect_timeout(&address, Duration::from_millis(200)).is_ok() {
            return Ok(());
        }
        if Instant::now() >= deadline {
            return Err("PocketBase did not bind to 127.0.0.1:8090 in time".to_string());
        }
        std::thread::sleep(Duration::from_millis(50));
    }
}

#[cfg(not(any(target_os = "ios", target_os = "android")))]
async fn is_gateway_token_valid(token: &str) -> bool {
    let client = reqwest::Client::new();
    match client
        .get(format!("{GATEWAY_LOOPBACK_URL}/health"))
        .bearer_auth(token.trim())
        .timeout(Duration::from_millis(800))
        .send()
        .await
    {
        Ok(resp) => resp.status().is_success(),
        Err(_) => false,
    }
}

#[cfg(not(any(target_os = "ios", target_os = "android")))]
async fn pair_with_code(code: &str) -> Result<String, String> {
    let client = reqwest::Client::new();
    let response = client
        .post(format!("{GATEWAY_LOOPBACK_URL}/pair"))
        .header("X-Pairing-Code", code)
        .send()
        .await
        .map_err(|e| format!("failed to call gateway /pair: {e}"))?;
    let status = response.status();
    if !status.is_success() {
        let body = response.text().await.unwrap_or_default();
        return Err(format!("gateway /pair failed ({status}) {body}"));
    }
    let body = response
        .json::<PairTokenResponse>()
        .await
        .map_err(|e| format!("failed to parse gateway /pair response: {e}"))?;
    if body.token.trim().is_empty() {
        return Err("gateway returned an empty bearer token".to_string());
    }
    Ok(body.token)
}

#[cfg(not(any(target_os = "ios", target_os = "android")))]
async fn mint_additional_gateway_token(existing_token: &str) -> Result<String, String> {
    let client = reqwest::Client::new();
    let code_resp = client
        .post(format!("{GATEWAY_LOOPBACK_URL}/pair/new-code"))
        .bearer_auth(existing_token.trim())
        .send()
        .await
        .map_err(|e| format!("failed to call gateway /pair/new-code: {e}"))?;
    let status = code_resp.status();
    if !status.is_success() {
        let body = code_resp.text().await.unwrap_or_default();
        return Err(format!("gateway /pair/new-code failed ({status}) {body}"));
    }
    let code_payload = code_resp
        .json::<PairNewCodeResponse>()
        .await
        .map_err(|e| format!("failed to parse /pair/new-code response: {e}"))?;
    pair_with_code(&code_payload.code).await
}

#[cfg(not(any(target_os = "ios", target_os = "android")))]
fn resolve_local_lan_ip() -> Option<String> {
    let socket = UdpSocket::bind("0.0.0.0:0").ok()?;
    socket.connect("8.8.8.8:80").ok()?;
    let addr = socket.local_addr().ok()?;
    if addr.ip().is_loopback() {
        return None;
    }
    Some(addr.ip().to_string())
}

#[tauri::command]
async fn restart_gateway_daemon(app: tauri::AppHandle) -> Result<String, String> {
    #[cfg(any(target_os = "ios", target_os = "android"))]
    {
        let _ = app;
        Err("restart_gateway_daemon is desktop-only".to_string())
    }
    #[cfg(not(any(target_os = "ios", target_os = "android")))]
    {
        let runtime = app.state::<RuntimeProcesses>();
        shutdown_process(&runtime.slowclaw_daemon);

        let paths = ensure_workspace_ready_async(&app).await?;
        let (_daemon_rx, daemon_child) = spawn_slowclaw_daemon(&app, &paths)?;
        runtime.set_slowclaw_daemon(daemon_child);
        Ok("SlowClaw gateway daemon restarted".to_string())
    }
}

#[tauri::command]
async fn start_openai_device_code_login(
    app: tauri::AppHandle,
) -> Result<OpenAiDeviceCodeStatus, String> {
    #[cfg(any(target_os = "ios", target_os = "android"))]
    {
        let _ = app;
        Err("start_openai_device_code_login is desktop-only".to_string())
    }
    #[cfg(not(any(target_os = "ios", target_os = "android")))]
    {
        let runtime = app.state::<RuntimeProcesses>();
        let flow = app.state::<OpenAiDeviceCodeFlow>();
        if runtime.has_openai_device_login() {
            return Ok(flow.snapshot());
        }

        let paths = ensure_workspace_ready_async(&app).await?;
        let config_dir = paths.config_dir.to_string_lossy().to_string();
        let workspace_dir = paths.workspace_dir.to_string_lossy().to_string();

        let mut command = app
            .shell()
            .sidecar("slowclaw")
            .map_err(|e| format!("failed to resolve slowclaw sidecar: {e}"))?;
        command = command
            .args([
                "auth",
                "login",
                "--provider",
                "openai-codex",
                "--device-code",
                "--profile",
                "default",
            ])
            .env("ZEROCLAW_CONFIG_DIR", &config_dir)
            .env("ZEROCLAW_WORKSPACE", &workspace_dir);

        let (mut rx, child) = command
            .spawn()
            .map_err(|e| format!("failed to start OpenAI device-code login: {e}"))?;
        runtime.set_openai_device_login(child);

        flow.set_status(OpenAiDeviceCodeStatusState {
            state: "starting".to_string(),
            running: true,
            completed: false,
            message: "OpenAI device-code login started. Waiting for instructions...".to_string(),
            verification_url: None,
            user_code: None,
            fast_link: None,
            error: None,
        });

        let app_handle = app.clone();
        tauri::async_runtime::spawn(async move {
            while let Some(event) = rx.recv().await {
                match event {
                    CommandEvent::Stdout(bytes) | CommandEvent::Stderr(bytes) => {
                        let chunk = String::from_utf8_lossy(&bytes).to_string();
                        for line in chunk.lines() {
                            let flow = app_handle.state::<OpenAiDeviceCodeFlow>();
                            flow.update_status(|status| apply_openai_device_code_line(status, line));
                        }
                    }
                    CommandEvent::Error(error) => {
                        let flow = app_handle.state::<OpenAiDeviceCodeFlow>();
                        flow.update_status(|status| {
                            status.state = "error".to_string();
                            status.running = false;
                            status.completed = false;
                            status.error = Some(error.to_string());
                            status.message = format!("Device-code login failed: {error}");
                        });
                        app_handle
                            .state::<RuntimeProcesses>()
                            .clear_openai_device_login();
                        break;
                    }
                    CommandEvent::Terminated(payload) => {
                        let success = matches!(payload.code, Some(0));
                        let flow = app_handle.state::<OpenAiDeviceCodeFlow>();
                        flow.update_status(|status| {
                            status.running = false;
                            if success {
                                status.state = "completed".to_string();
                                status.completed = true;
                                status.error = None;
                                status.message = "OpenAI authentication complete.".to_string();
                            } else {
                                status.state = "error".to_string();
                                status.completed = false;
                                let exit_msg = format!("OpenAI device-code login exited with status {:?}", payload.code);
                                status.error = Some(exit_msg.clone());
                                status.message = exit_msg;
                            }
                        });
                        app_handle
                            .state::<RuntimeProcesses>()
                            .clear_openai_device_login();
                        break;
                    }
                    _ => {}
                }
            }
        });

        Ok(flow.snapshot())
    }
}

#[tauri::command]
fn get_openai_device_code_status(app: tauri::AppHandle) -> Result<OpenAiDeviceCodeStatus, String> {
    #[cfg(any(target_os = "ios", target_os = "android"))]
    {
        let _ = app;
        Err("get_openai_device_code_status is desktop-only".to_string())
    }
    #[cfg(not(any(target_os = "ios", target_os = "android")))]
    {
        let flow = app.state::<OpenAiDeviceCodeFlow>();
        Ok(flow.snapshot())
    }
}

fn main() {
    let builder = tauri::Builder::default()
        .plugin(tauri_plugin_shell::init())
        .invoke_handler(tauri::generate_handler![
            get_secret,
            set_secret,
            delete_secret,
            generate_mobile_pairing_qr,
            get_desktop_gateway_bootstrap,
            restart_gateway_daemon,
            start_openai_device_code_login,
            get_openai_device_code_status
        ]);

    #[cfg(not(any(target_os = "ios", target_os = "android")))]
    let app = builder
        .setup(|app| {
            app.manage(RuntimeProcesses::default());
            app.manage(OpenAiDeviceCodeFlow::default());
            let runtime = app.state::<RuntimeProcesses>();
            let paths = ensure_workspace_ready_blocking(app.handle()).map_err(io::Error::other)?;
            let (pb_data_arg, pb_migrations_arg) =
                resolve_pocketbase_spawn_args(app.handle()).map_err(io::Error::other)?;
            if let Err(err) = block_on(ensure_pocketbase_superuser_seeded(
                app.handle(),
                &pb_data_arg,
                &pb_migrations_arg,
            )) {
                eprintln!("warning: PocketBase superuser bootstrap skipped: {err}");
            }

            let pocketbase_child = spawn_pocketbase_sidecar(app.handle()).map_err(io::Error::other)?;
            runtime.set_pocketbase(pocketbase_child);
            wait_for_pocketbase_ready_blocking().map_err(io::Error::other)?;

            let (_daemon_rx, daemon_child) = match spawn_slowclaw_daemon(app.handle(), &paths) {
                Ok(child) => child,
                Err(e) => {
                    runtime.shutdown_all();
                    return Err(io::Error::other(e).into());
                }
            };
            runtime.set_slowclaw_daemon(daemon_child);
            Ok(())
        })
        .on_window_event(|window, event| {
            if matches!(event, WindowEvent::CloseRequested { .. }) {
                window.state::<RuntimeProcesses>().shutdown_all();
            }
        })
        .build(tauri::generate_context!())
        .expect("error while building tauri app");

    #[cfg(any(target_os = "ios", target_os = "android"))]
    let app = builder
        .build(tauri::generate_context!())
        .expect("error while building tauri app");

    app.run(|app_handle, event| {
        #[cfg(not(any(target_os = "ios", target_os = "android")))]
        if matches!(event, RunEvent::ExitRequested { .. } | RunEvent::Exit) {
            app_handle.state::<RuntimeProcesses>().shutdown_all();
        }

        #[cfg(any(target_os = "ios", target_os = "android"))]
        let _ = (app_handle, event);
    });
}
