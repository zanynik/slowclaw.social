use serde::{Deserialize, Serialize};
#[cfg(not(any(target_os = "ios", target_os = "android")))]
use std::fs;
#[cfg(not(any(target_os = "ios", target_os = "android")))]
use std::io;
#[cfg(not(any(target_os = "ios", target_os = "android")))]
use std::net::UdpSocket;
#[cfg(not(any(target_os = "ios", target_os = "android")))]
use std::path::{Path, PathBuf};
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
const GATEWAY_LOOPBACK_HOST: &str = "127.0.0.1";
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
const CORE_WORKSPACE_DIRS: &[&str] = &["cron", "memory", "sessions", "skills", "state"];

#[cfg(not(any(target_os = "ios", target_os = "android")))]
#[derive(Default)]
struct RuntimeProcesses {
    pocketbase: Mutex<Option<CommandChild>>,
    slowclaw_daemon: Mutex<Option<CommandChild>>,
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

    fn shutdown_all(&self) {
        shutdown_process(&self.slowclaw_daemon);
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

#[cfg(not(any(target_os = "ios", target_os = "android")))]
async fn generate_mobile_pairing_qr_desktop(
    _app: tauri::AppHandle,
) -> Result<MobilePairingQrPayload, String> {
    wait_for_gateway_ready().await?;
    let desktop_token = load_gateway_token_from_keyring()
        .ok_or_else(|| "Desktop gateway token not found. Restart app or pair again.".to_string())?;
    if !is_gateway_token_valid(&desktop_token).await {
        return Err("Desktop gateway token is not valid anymore. Restart app to refresh pairing.".to_string());
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
fn run_sidecar_onboard(app: &tauri::AppHandle, paths: &DesktopPaths, force: bool) -> Result<(), String> {
    let config_dir_arg = paths.config_dir.to_string_lossy().to_string();
    let mut command = app
        .shell()
        .sidecar("slowclaw")
        .map_err(|e| format!("failed to resolve slowclaw sidecar for onboarding: {e}"))?;

    command = command
        .args(["onboard", "--memory", "sqlite"])
        .env("ZEROCLAW_CONFIG_DIR", &config_dir_arg);
    if force {
        command = command.arg("--force");
    }

    let output = block_on(command.output())
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

#[cfg(not(any(target_os = "ios", target_os = "android")))]
fn ensure_workspace_ready(app: &tauri::AppHandle) -> Result<DesktopPaths, String> {
    let paths = resolve_desktop_paths(app)?;
    let config_path = paths.config_dir.join("config.toml");
    let config_exists = config_path.exists();
    let workspace_empty = is_effectively_empty(&paths.workspace_dir)
        .map_err(|e| format!("failed to inspect workspace dir: {e}"))?;

    if !config_exists || workspace_empty {
        run_sidecar_onboard(app, &paths, config_exists)?;
    } else if workspace_skeleton_missing(&paths) {
        repair_workspace_skeleton(&paths)?;
    }

    if !config_path.exists() {
        return Err(format!(
            "workspace scaffolding incomplete: missing {}",
            config_path.display()
        ));
    }
    Ok(paths)
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
fn spawn_pocketbase_sidecar(app: &tauri::AppHandle) -> Result<CommandChild, String> {
    let pocketbase_data_dir = resolve_pocketbase_data_dir(app)
        .map_err(|e| format!("failed to resolve PocketBase data dir: {e}"))?;
    let pocketbase_data_dir = pocketbase_data_dir
        .canonicalize()
        .unwrap_or(pocketbase_data_dir);
    let data_arg = pocketbase_data_dir.to_string_lossy().to_string();
    let migrations_dir = resolve_pocketbase_migrations_dir(app)
        .map_err(|e| format!("failed to resolve PocketBase migrations dir: {e}"))?;
    let migrations_arg = migrations_dir.to_string_lossy().to_string();

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
            GATEWAY_LOOPBACK_HOST,
            "--port",
            &GATEWAY_PORT.to_string(),
        ])
        .env("ZEROCLAW_CONFIG_DIR", &config_dir)
        .env("ZEROCLAW_WORKSPACE", &workspace_dir)
        .env("ZEROCLAW_POCKETBASE_DISABLE", "1")
        .env("ZEROCLAW_POCKETBASE_URL", POCKETBASE_LOOPBACK_URL);

    for (key, value) in bluesky_env_pairs() {
        command = command.env(key, value);
    }

    command
        .spawn()
        .map_err(|e| format!("failed to spawn slowclaw daemon sidecar: {e}"))
}

#[cfg(not(any(target_os = "ios", target_os = "android")))]
fn extract_pairing_code(line: &str) -> Option<String> {
    if let Some(idx) = line.find("X-Pairing-Code:") {
        let tail = &line[(idx + "X-Pairing-Code:".len())..];
        let digits: String = tail
            .chars()
            .skip_while(|ch| !ch.is_ascii_digit())
            .take_while(|ch| ch.is_ascii_digit())
            .collect();
        if digits.len() == 6 {
            return Some(digits);
        }
    }

    if !line.contains('│') {
        return None;
    }

    let mut run = String::new();
    for ch in line.chars() {
        if ch.is_ascii_digit() {
            run.push(ch);
            if run.len() == 6 {
                return Some(run);
            }
            if run.len() > 6 {
                run.clear();
            }
        } else {
            run.clear();
        }
    }
    None
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
fn bootstrap_desktop_gateway_token(rx: &mut Receiver<CommandEvent>) -> Result<Option<String>, String> {
    block_on(async {
        wait_for_gateway_ready().await?;

        if let Some(existing) = load_gateway_token_from_keyring() {
            if is_gateway_token_valid(&existing).await {
                return Ok(Some(existing));
            }
        }

        let deadline = Instant::now() + Duration::from_secs(25);
        while Instant::now() < deadline {
            let remaining = deadline.saturating_duration_since(Instant::now());
            let next_event = tokio::time::timeout(remaining.min(Duration::from_millis(500)), rx.recv())
                .await
                .ok()
                .flatten();

            if let Some(event) = next_event {
                let line = match event {
                    CommandEvent::Stdout(bytes) | CommandEvent::Stderr(bytes) => {
                        String::from_utf8_lossy(&bytes).to_string()
                    }
                    CommandEvent::Error(_) | CommandEvent::Terminated(_) => continue,
                    _ => continue,
                };
                if let Some(code) = extract_pairing_code(&line) {
                    let token = pair_with_code(&code).await?;
                    save_gateway_token_to_keyring(&token)?;
                    return Ok(Some(token));
                }
            }
        }

        Ok(None)
    })
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

fn main() {
    let builder = tauri::Builder::default()
        .plugin(tauri_plugin_shell::init())
        .invoke_handler(tauri::generate_handler![
            get_secret,
            set_secret,
            delete_secret,
            generate_mobile_pairing_qr
        ]);

    #[cfg(not(any(target_os = "ios", target_os = "android")))]
    let app = builder
        .setup(|app| {
            app.manage(RuntimeProcesses::default());
            let runtime = app.state::<RuntimeProcesses>();
            let paths = ensure_workspace_ready(app.handle()).map_err(io::Error::other)?;

            let pocketbase_child = spawn_pocketbase_sidecar(app.handle()).map_err(io::Error::other)?;
            runtime.set_pocketbase(pocketbase_child);

            let (mut daemon_rx, daemon_child) = match spawn_slowclaw_daemon(app.handle(), &paths) {
                Ok(child) => child,
                Err(e) => {
                    runtime.shutdown_all();
                    return Err(io::Error::other(e).into());
                }
            };
            runtime.set_slowclaw_daemon(daemon_child);

            if let Err(err) = bootstrap_desktop_gateway_token(&mut daemon_rx) {
                eprintln!("warning: desktop gateway token bootstrap failed: {err}");
            }
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
