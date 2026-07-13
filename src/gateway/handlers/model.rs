use axum::{
    extract::State,
    http::{HeaderMap, StatusCode},
    response::IntoResponse,
    Json,
};
use std::collections::HashMap;
use std::path::{Path as StdPath, PathBuf};
use std::sync::Arc;
use std::time::{SystemTime, UNIX_EPOCH};
use anyhow::{Context, Result};
use futures_util::StreamExt;
use parking_lot::Mutex;
use tokio::io::AsyncWriteExt;
use tokio::process::Command;

use crate::gateway::state::*;
use crate::gateway::{
    pairing_auth_error, frontend_error_response,
    frontend_internal_error_response,
    reset_workspace_synthesizer_status_for_provider_change,
};

pub const LOCAL_MODEL_DIR: &str = "local-models/llamacpp";

#[derive(Clone, Copy, Debug)]
pub struct LocalModelSpec {
    pub id: &'static str,
    pub title: &'static str,
    pub family: &'static str,
    pub description: &'static str,
    pub engine: &'static str,
    pub provider: &'static str,
    pub download_url: &'static str,
    pub file_name: &'static str,
    pub size_label: &'static str,
    pub size_bytes: u64,
}

#[derive(Clone, Debug, serde::Serialize)]
#[serde(rename_all = "camelCase")]
pub struct LocalModelCatalogItem {
    pub id: String,
    pub title: String,
    pub family: String,
    pub description: String,
    pub engine: String,
    pub provider: String,
    pub download_url: String,
    pub file_name: String,
    pub size_label: String,
    pub size_bytes: u64,
    pub installed: bool,
    pub active: bool,
    pub path: Option<String>,
    pub download: Option<LocalModelDownloadJob>,
}

#[derive(serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct LocalModelIdBody {
    pub model_id: String,
}

pub fn local_model_specs() -> &'static [LocalModelSpec] {
    &[
        LocalModelSpec {
            id: "unsloth/gemma-4-E2B-it-qat-UD-Q2_K_XL",
            title: "Gemma 4 E2B QAT Q2 (Recommended)",
            family: "Gemma",
            description: "QAT (quantization-aware training) build: ~3x less memory, near-original accuracy. Smaller & most stable on iPhone. ~2.1 GB.",
            engine: "llama.cpp GGUF",
            provider: "llamacpp",
            download_url: "https://huggingface.co/unsloth/gemma-4-E2B-it-qat-GGUF/resolve/main/gemma-4-E2B-it-qat-UD-Q2_K_XL.gguf",
            file_name: "gemma-4-E2B-it-qat-UD-Q2_K_XL.gguf",
            size_label: "2.1 GB",
            size_bytes: 2_186_184_768,
        },
        LocalModelSpec {
            id: "unsloth/gemma-4-E2B-it-qat-UD-Q4_K_XL",
            title: "Gemma 4 E2B QAT Q4 (Higher Quality)",
            family: "Gemma",
            description: "QAT build with higher precision. Best quality, larger. ~2.5 GB. Use if Q2 works well and you want better output.",
            engine: "llama.cpp GGUF",
            provider: "llamacpp",
            download_url: "https://huggingface.co/unsloth/gemma-4-E2B-it-qat-GGUF/resolve/main/gemma-4-E2B-it-qat-UD-Q4_K_XL.gguf",
            file_name: "gemma-4-E2B-it-qat-UD-Q4_K_XL.gguf",
            size_label: "2.5 GB",
            size_bytes: 2_620_368_960,
        },
    ]
}

pub fn find_local_model_spec(model_id: &str) -> Option<LocalModelSpec> {
    let normalized = model_id.trim();
    local_model_specs()
        .iter()
        .copied()
        .find(|spec| spec.id == normalized)
}

pub fn safe_local_model_dir_name(model_id: &str) -> String {
    model_id
        .chars()
        .map(|ch| {
            if ch.is_ascii_alphanumeric() || matches!(ch, '.' | '-' | '_') {
                ch
            } else {
                '_'
            }
        })
        .collect()
}

pub fn local_model_file_path(workspace_dir: &StdPath, spec: LocalModelSpec) -> PathBuf {
    workspace_dir
        .join(LOCAL_MODEL_DIR)
        .join(safe_local_model_dir_name(spec.id))
        .join(spec.file_name)
}

pub fn local_model_runtime_api_url() -> String {
    "http://127.0.0.1:8080/v1".to_string()
}

fn now_unix_secs() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|duration| duration.as_secs())
        .unwrap_or_default()
}

fn candidate_llama_server_binaries(workspace_dir: &StdPath) -> Vec<PathBuf> {
    let mut candidates = Vec::new();
    if let Ok(path) = std::env::var("SLOWCLAW_LLAMA_SERVER") {
        if !path.trim().is_empty() {
            candidates.push(PathBuf::from(path.trim()));
        }
    }
    candidates.push(workspace_dir.join("local-models/bin/llama-server"));
    candidates.push(workspace_dir.join("local-models/bin/llama-server-turbo"));
    candidates.push(PathBuf::from("llama-server"));
    candidates.push(PathBuf::from("llama-server-turbo"));
    candidates
}

fn resolve_llama_server_binary(workspace_dir: &StdPath) -> Option<PathBuf> {
    for candidate in candidate_llama_server_binaries(workspace_dir) {
        let path_str = candidate.to_string_lossy();
        if candidate.components().count() > 1 || path_str.contains(std::path::MAIN_SEPARATOR) {
            if candidate.is_file() {
                return Some(candidate);
            }
            continue;
        }
        if let Ok(found) = which::which(path_str.as_ref()) {
            return Some(found);
        }
    }
    None
}

pub async fn local_model_runtime_snapshot(
    runtime: &Arc<tokio::sync::Mutex<LocalModelRuntimeState>>,
) -> LocalModelRuntimeSnapshot {
    let mut guard = runtime.lock().await;
    if let Some(child) = guard.child.as_mut() {
        match child.try_wait() {
            Ok(Some(status)) => {
                guard.child = None;
                guard.status = "stopped".to_string();
                guard.pid = None;
                guard.error = Some(format!("llama-server exited with {status}"));
            }
            Ok(None) => {
                guard.status = "running".to_string();
            }
            Err(err) => {
                guard.status = "error".to_string();
                guard.error = Some(format!("failed to inspect llama-server: {err}"));
            }
        }
    } else if guard.status.is_empty() {
        guard.status = "stopped".to_string();
    }

    LocalModelRuntimeSnapshot {
        status: guard.status.clone(),
        running: guard.child.is_some() && guard.status == "running",
        model_id: guard.model_id.clone(),
        binary: guard.binary.clone(),
        pid: guard.pid,
        port: if guard.port == 0 { 8080 } else { guard.port },
        api_url: local_model_runtime_api_url(),
        error: guard.error.clone(),
        started_at_unix: guard.started_at_unix,
    }
}

pub fn local_model_catalog_items(state: &AppState) -> Vec<LocalModelCatalogItem> {
    let config = state.config.lock().clone();
    let active_provider = config
        .default_provider
        .as_deref()
        .map(str::trim)
        .unwrap_or_default();
    let active_model = config
        .default_model
        .as_deref()
        .map(str::trim)
        .unwrap_or_default();
    let downloads = state.local_model_downloads.lock().clone();

    local_model_specs()
        .iter()
        .copied()
        .map(|spec| {
            let path = local_model_file_path(&config.workspace_dir, spec);
            let installed = path.is_file();
            LocalModelCatalogItem {
                id: spec.id.to_string(),
                title: spec.title.to_string(),
                family: spec.family.to_string(),
                description: spec.description.to_string(),
                engine: spec.engine.to_string(),
                provider: spec.provider.to_string(),
                download_url: spec.download_url.to_string(),
                file_name: spec.file_name.to_string(),
                size_label: spec.size_label.to_string(),
                size_bytes: spec.size_bytes,
                installed,
                active: installed && active_provider == spec.provider && active_model == spec.id,
                path: installed.then(|| path.display().to_string()),
                download: downloads.get(spec.id).cloned(),
            }
        })
        .collect()
}

pub async fn handle_local_models(
    State(state): State<AppState>,
    headers: HeaderMap,
) -> axum::response::Response {
    if let Some(err) = pairing_auth_error(&state, &headers, "Local models") {
        return err.into_response();
    }
    let runtime = local_model_runtime_snapshot(&state.local_model_runtime).await;
    let body = serde_json::json!({
        "models": local_model_catalog_items(&state),
        "runtime": runtime,
        "engineReady": runtime.running,
        "engineStatus": if runtime.running {
            "Local llama.cpp runtime is running."
        } else {
            "Download/select is ready. Runtime starts when a llama-server binary is bundled or available on PATH."
        },
    });
    (StatusCode::OK, Json(body)).into_response()
}

pub async fn handle_local_model_download(
    State(state): State<AppState>,
    headers: HeaderMap,
    Json(body): Json<LocalModelIdBody>,
) -> axum::response::Response {
    if let Some(err) = pairing_auth_error(&state, &headers, "Local model download") {
        return err.into_response();
    }
    let Some(spec) = find_local_model_spec(&body.model_id) else {
        return frontend_error_response(
            StatusCode::NOT_FOUND,
            "LOCAL_MODEL_NOT_FOUND",
            "Unknown local model.",
        )
        .into_response();
    };

    let workspace_dir = state.config.lock().workspace_dir.clone();
    let final_path = local_model_file_path(&workspace_dir, spec);
    if final_path.is_file() {
        state.local_model_downloads.lock().insert(
            spec.id.to_string(),
            LocalModelDownloadJob {
                model_id: spec.id.to_string(),
                status: "complete".to_string(),
                transferred_bytes: spec.size_bytes,
                total_bytes: Some(spec.size_bytes),
                error: None,
                path: Some(final_path.display().to_string()),
            },
        );
        return (StatusCode::OK, Json(serde_json::json!({ "ok": true }))).into_response();
    }

    {
        let mut jobs = state.local_model_downloads.lock();
        if let Some(job) = jobs.get(spec.id) {
            if job.status == "downloading" {
                return (StatusCode::ACCEPTED, Json(serde_json::json!({ "ok": true }))).into_response();
            }
        }
        jobs.insert(
            spec.id.to_string(),
            LocalModelDownloadJob {
                model_id: spec.id.to_string(),
                status: "downloading".to_string(),
                transferred_bytes: 0,
                total_bytes: Some(spec.size_bytes),
                error: None,
                path: None,
            },
        );
    }

    let jobs = state.local_model_downloads.clone();
    tokio::spawn(async move {
        download_local_model(spec, workspace_dir, jobs).await;
    });

    (StatusCode::ACCEPTED, Json(serde_json::json!({ "ok": true }))).into_response()
}

async fn download_local_model(
    spec: LocalModelSpec,
    workspace_dir: PathBuf,
    jobs: Arc<Mutex<HashMap<String, LocalModelDownloadJob>>>,
) {
    let final_path = local_model_file_path(&workspace_dir, spec);
    let tmp_path = final_path.with_extension("download");
    let result: Result<()> = async {
        let parent = final_path
            .parent()
            .context("local model path has no parent directory")?;
        tokio::fs::create_dir_all(parent)
            .await
            .context("failed to create local model directory")?;

        let mut existing_bytes: u64 = 0;
        if tmp_path.exists() {
            existing_bytes = tokio::fs::metadata(&tmp_path)
                .await
                .map(|m| m.len())
                .unwrap_or(0);
        }

        let client = reqwest::Client::builder()
            .timeout(std::time::Duration::from_secs(3600))
            .connect_timeout(std::time::Duration::from_secs(30))
            .build()
            .context("failed to create HTTP client")?;

        let mut request = client.get(spec.download_url);
        if existing_bytes > 0 {
            request = request.header("Range", format!("bytes={existing_bytes}-"));
            eprintln!(
                "[model-download] resuming {} from byte {existing_bytes}",
                spec.id
            );
        }

        let response = request
            .send()
            .await
            .context("failed to start model download")?;

        let status = response.status();
        if !status.is_success() && status.as_u16() != 206 {
            anyhow::bail!("model download returned HTTP {status}");
        }

        let actually_resuming = status.as_u16() == 206 && existing_bytes > 0;
        let mut transferred = if actually_resuming { existing_bytes } else { 0u64 };

        let total = if actually_resuming {
            response
                .content_length()
                .map(|remaining| existing_bytes + remaining)
                .or(Some(spec.size_bytes))
        } else {
            response.content_length().or(Some(spec.size_bytes))
        };

        {
            let mut guard = jobs.lock();
            if let Some(job) = guard.get_mut(spec.id) {
                job.total_bytes = total;
                job.transferred_bytes = transferred;
            }
        }

        let mut file = if actually_resuming {
            tokio::fs::OpenOptions::new()
                .append(true)
                .open(&tmp_path)
                .await
                .context("failed to open temp file for resume")?  
        } else {
            tokio::fs::File::create(&tmp_path)
                .await
                .context("failed to create temporary model file")?
        };

        let mut stream = response.bytes_stream();
        while let Some(chunk) = stream.next().await {
            let chunk = chunk.context("failed while reading model download stream")?;
            file.write_all(&chunk)
                .await
                .context("failed to write model download chunk")?;
            transferred = transferred.saturating_add(chunk.len() as u64);
            let mut guard = jobs.lock();
            if let Some(job) = guard.get_mut(spec.id) {
                job.transferred_bytes = transferred;
                job.total_bytes = total;
            }
        }
        file.flush().await.context("failed to flush model download")?;

        let min_expected = (spec.size_bytes as f64 * 0.9) as u64;
        if transferred < min_expected {
            anyhow::bail!(
                "download appears incomplete: got {} bytes, expected ~{}",
                transferred,
                spec.size_bytes
            );
        }

        if final_path.exists() {
            let _ = tokio::fs::remove_file(&final_path).await;
        }
        tokio::fs::rename(&tmp_path, &final_path)
            .await
            .context("failed to finalize model download")?;
        Ok(())
    }
    .await;

    let mut guard = jobs.lock();
    match result {
        Ok(()) => {
            guard.insert(
                spec.id.to_string(),
                LocalModelDownloadJob {
                    model_id: spec.id.to_string(),
                    status: "complete".to_string(),
                    transferred_bytes: spec.size_bytes,
                    total_bytes: Some(spec.size_bytes),
                    error: None,
                    path: Some(final_path.display().to_string()),
                },
            );
        }
        Err(err) => {
            let err_msg = err.to_string();
            if err_msg.contains("incomplete") {
                let _ = std::fs::remove_file(&tmp_path);
            }
            let resumed_bytes = std::fs::metadata(&tmp_path)
                .map(|m| m.len())
                .unwrap_or(0);
            guard.insert(
                spec.id.to_string(),
                LocalModelDownloadJob {
                    model_id: spec.id.to_string(),
                    status: "failed".to_string(),
                    transferred_bytes: resumed_bytes,
                    total_bytes: Some(spec.size_bytes),
                    error: Some(if resumed_bytes > 0 {
                        format!("{err_msg} — tap Download to resume from {:.0}%", (resumed_bytes as f64 / spec.size_bytes as f64) * 100.0)
                    } else {
                        err_msg
                    }),
                    path: None,
                },
            );
        }
    }
}

pub async fn handle_local_model_use(
    State(state): State<AppState>,
    headers: HeaderMap,
    Json(body): Json<LocalModelIdBody>,
) -> axum::response::Response {
    if let Some(err) = pairing_auth_error(&state, &headers, "Local model use") {
        return err.into_response();
    }
    let Some(spec) = find_local_model_spec(&body.model_id) else {
        return frontend_error_response(
            StatusCode::NOT_FOUND,
            "LOCAL_MODEL_NOT_FOUND",
            "Unknown local model.",
        )
        .into_response();
    };

    let mut next = state.config.lock().clone();
    let path = local_model_file_path(&next.workspace_dir, spec);
    if !path.is_file() {
        return frontend_error_response(
            StatusCode::BAD_REQUEST,
            "LOCAL_MODEL_NOT_INSTALLED",
            "Download the model before selecting it.",
        )
        .into_response();
    }

    next.default_provider = Some(spec.provider.to_string());
    next.default_model = Some(spec.id.to_string());
    next.api_url = Some(local_model_runtime_api_url());
    if let Err(err) = next.save().await {
        return frontend_internal_error_response(
            StatusCode::INTERNAL_SERVER_ERROR,
            "local model config save",
            "Failed to save local model settings.",
            err,
        );
    }
    *state.config.lock() = next.clone();
    reset_workspace_synthesizer_status_for_provider_change(&next.workspace_dir);

    let resp = serde_json::json!({
        "ok": true,
        "defaultProvider": spec.provider,
        "defaultModel": spec.id,
        "apiUrl": local_model_runtime_api_url(),
    });
    (StatusCode::OK, Json(resp)).into_response()
}

pub async fn handle_local_model_runtime_status(
    State(state): State<AppState>,
    headers: HeaderMap,
) -> axum::response::Response {
    if let Some(err) = pairing_auth_error(&state, &headers, "Local model runtime status") {
        return err.into_response();
    }
    let runtime = local_model_runtime_snapshot(&state.local_model_runtime).await;
    (StatusCode::OK, Json(runtime)).into_response()
}

pub async fn handle_local_model_runtime_start(
    State(state): State<AppState>,
    headers: HeaderMap,
    Json(body): Json<LocalModelIdBody>,
) -> axum::response::Response {
    if let Some(err) = pairing_auth_error(&state, &headers, "Local model runtime start") {
        return err.into_response();
    }
    let Some(spec) = find_local_model_spec(&body.model_id) else {
        return frontend_error_response(
            StatusCode::NOT_FOUND,
            "LOCAL_MODEL_NOT_FOUND",
            "Unknown local model.",
        )
        .into_response();
    };

    let workspace_dir = state.config.lock().workspace_dir.clone();
    let model_path = local_model_file_path(&workspace_dir, spec);
    if !model_path.is_file() {
        return frontend_error_response(
            StatusCode::BAD_REQUEST,
            "LOCAL_MODEL_NOT_INSTALLED",
            "Download the model before starting it.",
        )
        .into_response();
    }
    let Some(binary) = resolve_llama_server_binary(&workspace_dir) else {
        let mut runtime = state.local_model_runtime.lock().await;
        runtime.status = "unavailable".to_string();
        runtime.model_id = Some(spec.id.to_string());
        runtime.error = Some(
            "No llama-server binary is bundled yet. Add one at local-models/bin/llama-server or set SLOWCLAW_LLAMA_SERVER."
                .to_string(),
        );
        let snapshot = LocalModelRuntimeSnapshot {
            status: runtime.status.clone(),
            running: false,
            model_id: runtime.model_id.clone(),
            binary: None,
            pid: None,
            port: 8080,
            api_url: local_model_runtime_api_url(),
            error: runtime.error.clone(),
            started_at_unix: None,
        };
        return (StatusCode::OK, Json(snapshot)).into_response();
    };

    let old_child = {
        let mut runtime = state.local_model_runtime.lock().await;
        runtime.child.take()
    };
    if let Some(mut child) = old_child {
        let _ = child.kill().await;
    }

    let mut cmd = Command::new(&binary);
    cmd.arg("--model")
        .arg(&model_path)
        .arg("--host")
        .arg("127.0.0.1")
        .arg("--port")
        .arg("8080")
        .arg("--ctx-size")
        .arg("4096")
        .kill_on_drop(true)
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::null())
        .stderr(std::process::Stdio::null());

    match cmd.spawn() {
        Ok(child) => {
            let pid = child.id();
            {
                let mut runtime = state.local_model_runtime.lock().await;
                runtime.child = Some(child);
                runtime.status = "running".to_string();
                runtime.model_id = Some(spec.id.to_string());
                runtime.binary = Some(binary.display().to_string());
                runtime.pid = pid;
                runtime.port = 8080;
                runtime.error = None;
                runtime.started_at_unix = Some(now_unix_secs());
            }

            let mut next = state.config.lock().clone();
            next.default_provider = Some(spec.provider.to_string());
            next.default_model = Some(spec.id.to_string());
            next.api_url = Some(local_model_runtime_api_url());
            if let Err(err) = next.save().await {
                return frontend_internal_error_response(
                    StatusCode::INTERNAL_SERVER_ERROR,
                    "local model runtime config save",
                    "Started the local model runtime, but failed to save runtime settings.",
                    err,
                );
            }
            *state.config.lock() = next.clone();
            reset_workspace_synthesizer_status_for_provider_change(&next.workspace_dir);

            let snapshot = local_model_runtime_snapshot(&state.local_model_runtime).await;
            (StatusCode::OK, Json(snapshot)).into_response()
        }
        Err(err) => {
            let mut runtime = state.local_model_runtime.lock().await;
            runtime.status = "error".to_string();
            runtime.model_id = Some(spec.id.to_string());
            runtime.binary = Some(binary.display().to_string());
            runtime.pid = None;
            runtime.port = 8080;
            runtime.error = Some(format!("failed to start llama-server: {err}"));
            let snapshot = LocalModelRuntimeSnapshot {
                status: runtime.status.clone(),
                running: false,
                model_id: runtime.model_id.clone(),
                binary: runtime.binary.clone(),
                pid: None,
                port: 8080,
                api_url: local_model_runtime_api_url(),
                error: runtime.error.clone(),
                started_at_unix: runtime.started_at_unix,
            };
            (StatusCode::OK, Json(snapshot)).into_response()
        }
    }
}

pub async fn handle_local_model_runtime_stop(
    State(state): State<AppState>,
    headers: HeaderMap,
) -> axum::response::Response {
    if let Some(err) = pairing_auth_error(&state, &headers, "Local model runtime stop") {
        return err.into_response();
    }
    let old_child = {
        let mut runtime = state.local_model_runtime.lock().await;
        runtime.child.take()
    };
    if let Some(mut child) = old_child {
        let _ = child.kill().await;
    }
    {
        let mut runtime = state.local_model_runtime.lock().await;
        runtime.status = "stopped".to_string();
        runtime.pid = None;
        runtime.error = None;
    }
    let snapshot = local_model_runtime_snapshot(&state.local_model_runtime).await;
    (StatusCode::OK, Json(snapshot)).into_response()
}
