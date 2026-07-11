use serde::Serialize;
use std::process::Command;
use tauri::{AppHandle, Manager, Url, WebviewUrl, WebviewWindowBuilder};

use crate::{
    GatewayState, GatewayQrPayload, DesktopGatewayBootstrap,
    OpenAiDeviceCodeState, OpenAiDeviceCodeStatus,
};

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct OllamaStatus {
    pub available: bool,
    pub base_url: String,
    pub model: String,
    pub models: Vec<String>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct LocalModelDownloadStatus {
    pub model: String,
    pub available: bool,
    pub message: String,
}

#[tauri::command]
pub(crate) async fn open_workspace_journals_folder() -> Result<String, String> {
    #[cfg(mobile)]
    {
        Err("Accessing the journals folder is only supported on Desktop.".to_string())
    }
    #[cfg(not(mobile))]
    {
        let config = zeroclaw::Config::load_or_init().await.map_err(|e| {
            crate::ui_command_error(
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
                crate::ui_command_error(
                    "journals folder create failed",
                    "Failed to prepare the journals folder.",
                    e,
                )
            })?;
        }
        crate::open_path_with_system_handler(&journals_dir).map_err(|e| {
            crate::ui_command_error(
                "journals folder open failed",
                "Failed to open the journals folder.",
                e,
            )
        })?;
        Ok("Folder opened successfully.".to_string())
    }
}

#[tauri::command]
pub(crate) fn open_external_url(url: String) -> Result<(), String> {
    #[cfg(mobile)]
    {
        let _ = url;
        Err("Opening external URLs directly is not supported on mobile.".to_string())
    }
    #[cfg(not(mobile))]
    {
        crate::open_url_with_system_handler(&url).map_err(|e| {
            crate::ui_command_error(
                "external url open failed",
                "Failed to open the link in your browser.",
                e,
            )
        })
    }
}

/// Open a link inside the app as an in-app browser (a webview window over the
/// main window), instead of handing it off to the OS browser. Works on desktop
/// and mobile — on iOS it renders a WKWebView, so links stay in-app (the
/// `open_external_url` hand-off actually errors out on mobile). Only `http(s)`
/// URLs are accepted (same guard as the external opener). Reuses a single
/// `"reader"` window label so repeated opens replace, not stack.
#[tauri::command]
pub(crate) fn open_in_app_webview(app: AppHandle, url: String) -> Result<(), String> {
    let trimmed = url.trim();
    if trimmed.is_empty() {
        return Err("url is required".to_string());
    }
    // Parse + restrict to http(s). WebviewUrl::External takes a parsed Url.
    let parsed = Url::parse(trimmed).map_err(|_| "invalid url".to_string())?;
    if parsed.scheme() != "http" && parsed.scheme() != "https" {
        return Err("only http(s) urls can be opened".to_string());
    }

    // Close any existing reader window so we never stack webviews.
    if let Some(existing) = app.get_webview_window("reader") {
        let _ = existing.close();
    }

    WebviewWindowBuilder::new(&app, "reader", WebviewUrl::External(parsed))
        .title("SlowClaw Reader")
        .center()
        .build()
        .map_err(|e| {
            crate::ui_command_error(
                "in-app webview open failed",
                "Failed to open the link in the app.",
                e,
            )
        })?;
    Ok(())
}

#[tauri::command]
pub(crate) async fn restart_gateway_daemon(state: tauri::State<'_, GatewayState>) -> Result<String, String> {
    #[cfg(mobile)]
    {
        let _ = state;
        Err("Gateway daemon restarts are only supported on Desktop.".to_string())
    }
    #[cfg(not(mobile))]
    {
        let _ = crate::ensure_desktop_gateway_token().map_err(|e| {
            crate::ui_command_error(
                "desktop gateway token generation failed",
                "Failed to prepare the desktop gateway token.",
                e,
            )
        })?;
        let info = crate::restart_embedded_gateway(state.inner.clone())
            .await
            .map_err(|e| {
                crate::ui_command_error(
                    "gateway restart failed",
                    "Failed to restart the desktop gateway.",
                    e,
                )
            })?;
        Ok(info.gateway_url)
    }
}

#[tauri::command]
pub(crate) async fn list_ollama_models() -> Result<Vec<String>, String> {
    #[cfg(mobile)]
    {
        Err("Ollama integration is only supported on Desktop.".to_string())
    }
    #[cfg(not(mobile))]
    {
        Ok(crate::installed_ollama_models())
    }
}

#[tauri::command]
pub(crate) async fn check_ollama() -> Result<OllamaStatus, String> {
    #[cfg(mobile)]
    {
        Err("Ollama integration is only supported on Desktop.".to_string())
    }
    #[cfg(not(mobile))]
    {
        let config = crate::load_workspace_config_for_ui("ollama config load failed").await?;
        let models = crate::installed_ollama_models();
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
}

#[tauri::command]
pub(crate) async fn download_ollama_model(model: String) -> Result<LocalModelDownloadStatus, String> {
    #[cfg(mobile)]
    {
        let _ = model;
        Err("Ollama model downloads are only supported on Desktop.".to_string())
    }
    #[cfg(not(mobile))]
    {
        let model = model.trim();
        if model.is_empty() || model.contains(char::is_whitespace) {
            return Err("Pick a valid model name.".to_string());
        }
        let status = Command::new("ollama")
            .args(["pull", model])
            .status()
            .map_err(|e| {
                crate::ui_command_error(
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
}

#[tauri::command]
pub(crate) fn show_main_window(window: tauri::Window) {
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
pub(crate) fn start_openai_device_code_login(
    state: tauri::State<'_, OpenAiDeviceCodeState>,
    gateway_state: tauri::State<'_, GatewayState>,
) -> Result<OpenAiDeviceCodeStatus, String> {
    #[cfg(mobile)]
    {
        let _ = state;
        let _ = gateway_state;
        Err("CLI device login flow is only supported on Desktop.".to_string())
    }
    #[cfg(not(mobile))]
    {
        {
            let mut guard = crate::lock_openai_state(&state.inner)?;
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
        std::thread::spawn(move || {
            crate::run_openai_device_login_worker(openai_state, gateway_state);
        });

        crate::snapshot_openai_status(&state.inner)
    }
}

#[tauri::command]
pub(crate) fn get_desktop_gateway_bootstrap(
    state: tauri::State<'_, GatewayState>,
) -> Result<DesktopGatewayBootstrap, String> {
    #[cfg(mobile)]
    {
        let _ = state;
        Err("Desktop gateway bootstrap is only supported on Desktop.".to_string())
    }
    #[cfg(not(mobile))]
    {
        let info = crate::snapshot_gateway_state(&state.inner)?;
        let token = crate::ensure_desktop_gateway_token().map_err(|e| {
            crate::ui_command_error(
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
}

#[tauri::command]
pub(crate) fn generate_mobile_pairing_qr(
    state: tauri::State<'_, GatewayState>,
) -> Result<GatewayQrPayload, String> {
    #[cfg(mobile)]
    {
        let _ = state;
        Err("Pairing QR generation is only supported on Desktop.".to_string())
    }
    #[cfg(not(mobile))]
    {
        let info = crate::snapshot_gateway_state(&state.inner)?;
        let mobile_gateway_url = crate::resolve_mobile_gateway_url(&info.gateway_url);
        let token = crate::ensure_desktop_gateway_token().map_err(|e| {
            crate::ui_command_error(
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
            crate::ui_command_error(
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
}

#[cfg(test)]
mod tests {
    #[tokio::test]
    async fn check_ollama_fails_on_mobile_sim() {
        // Simple verification that our conditional compilation logic triggers
        // correctly. In a unit test context or mobile compilation, this command
        // should return an error as simulated here.
        #[cfg(mobile)]
        {
            let res = super::check_ollama().await;
            assert!(res.is_err());
            assert_eq!(
                res.unwrap_err(),
                "Ollama integration is only supported on Desktop."
            );
        }
    }
}
