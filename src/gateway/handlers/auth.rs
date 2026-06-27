use axum::{
    extract::{ConnectInfo, State},
    http::{header, HeaderMap, StatusCode},
    response::IntoResponse,
    Json,
};
use std::collections::HashMap;
use std::net::SocketAddr;
use std::sync::Arc;
use std::time::Instant;

use crate::gateway::state::*;
use crate::gateway::{
    client_key_from_request, persist_pairing_tokens,
    pairing_auth_error, frontend_error_response,
    frontend_error_response_with_retry_after,
    frontend_internal_error_response,
    available_local_transcription_models,
    local_media_capabilities,
    reset_workspace_synthesizer_status_for_provider_change,
    hash_webhook_secret,
    run_gateway_chat_simple,
    webhook_memory_key,
};
use crate::security::pairing::constant_time_eq;
use crate::memory::MemoryCategory;

#[derive(serde::Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RuntimeConfigUpdateBody {
    pub default_provider: String,
    pub default_model: String,
    pub api_url: Option<String>,
    pub transcription_enabled: bool,
    pub transcription_model: Option<String>,
    pub api_key: Option<String>,
}

#[derive(serde::Deserialize)]
pub struct WebhookBody {
    pub message: String,
}

fn html_escape(s: &str) -> String {
    s.replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
        .replace('"', "&quot;")
}

/// Prometheus content type for text exposition format.
pub const PROMETHEUS_CONTENT_TYPE: &str = "text/plain; version=0.0.4; charset=utf-8";

/// GET /health — health check
pub async fn handle_health(State(state): State<AppState>) -> impl IntoResponse {
    let body = serde_json::json!({
        "status": "ok",
        "paired": state.pairing.is_paired(),
        "require_pairing": state.pairing.require_pairing(),
        "runtime": crate::health::snapshot_json(),
    });
    Json(body)
}

/// GET /metrics — Prometheus text exposition format
pub async fn handle_metrics(State(state): State<AppState>) -> impl IntoResponse {
    let body = if let Some(prom) = state
        .observer
        .as_ref()
        .as_any()
        .downcast_ref::<crate::observability::PrometheusObserver>()
    {
        prom.encode()
    } else {
        String::from("# Prometheus backend not enabled. Set [observability] backend = \"prometheus\" in config.\n")
    };

    (
        StatusCode::OK,
        [(header::CONTENT_TYPE, PROMETHEUS_CONTENT_TYPE)],
        body,
    )
}

/// GET /api/config/runtime — fetch runtime configuration
pub async fn handle_runtime_config(
    State(state): State<AppState>,
    headers: HeaderMap,
) -> axum::response::Response {
    if let Some(err) = pairing_auth_error(&state, &headers, "Runtime config") {
        return err.into_response();
    }
    let config = state.config.lock().clone();
    let transcription_models = available_local_transcription_models();
    let media_capabilities = local_media_capabilities(&config);
    let body = serde_json::json!({
        "defaultProvider": config.default_provider.unwrap_or_default(),
        "defaultModel": config.default_model.unwrap_or_default(),
        "apiUrl": config.api_url.unwrap_or_default(),
        "transcriptionEnabled": config.transcription.enabled,
        "transcriptionModel": config.transcription.model,
        "availableTranscriptionModels": transcription_models,
        "mediaCapabilities": media_capabilities,
        "mediaSummary": media_capabilities.summary(),
    });
    (StatusCode::OK, Json(body)).into_response()
}

/// POST /api/config/runtime — update runtime configuration
pub async fn handle_runtime_config_update(
    State(state): State<AppState>,
    headers: HeaderMap,
    Json(body): Json<RuntimeConfigUpdateBody>,
) -> axum::response::Response {
    if let Some(err) = pairing_auth_error(&state, &headers, "Runtime config update") {
        return err.into_response();
    }

    let provider = body.default_provider.trim();
    if provider.is_empty() {
        return frontend_error_response(
            StatusCode::BAD_REQUEST,
            "RUNTIME_CONFIG_DEFAULT_PROVIDER_REQUIRED",
            "defaultProvider is required",
        )
        .into_response();
    }
    let model = body.default_model.trim();
    if model.is_empty() {
        return frontend_error_response(
            StatusCode::BAD_REQUEST,
            "RUNTIME_CONFIG_DEFAULT_MODEL_REQUIRED",
            "defaultModel is required",
        )
        .into_response();
    }
    let api_url = body.api_url.as_deref().map(str::trim).unwrap_or_default();
    if !api_url.is_empty() {
        match reqwest::Url::parse(api_url) {
            Ok(parsed) if matches!(parsed.scheme(), "http" | "https") => {}
            _ => {
                return frontend_error_response(
                    StatusCode::BAD_REQUEST,
                    "RUNTIME_CONFIG_API_URL_INVALID",
                    "apiUrl must be an http(s) URL",
                )
                .into_response();
            }
        }
    }

    let mut next = state.config.lock().clone();
    let provider_changed = next
        .default_provider
        .as_deref()
        .map(str::trim)
        .unwrap_or_default()
        != provider;
    let model_changed = next
        .default_model
        .as_deref()
        .map(str::trim)
        .unwrap_or_default()
        != model;
    let api_url_changed = next
        .api_url
        .as_deref()
        .map(str::trim)
        .unwrap_or_default()
        != api_url;
    let api_key_changed = if let Some(new_key) = body
        .api_key
        .as_deref()
        .map(str::trim)
        .filter(|k| !k.is_empty())
    {
        let old_key = next
            .api_key
            .as_deref()
            .map(str::trim)
            .unwrap_or_default();
        let changed = old_key != new_key;
        tracing::info!(
            provider = provider,
            api_key_provided = true,
            api_key_changed = changed,
            "Runtime config update: API key received via HTTP"
        );
        next.api_key = Some(new_key.to_string());
        changed
    } else {
        tracing::info!(
            provider = provider,
            api_key_provided = false,
            "Runtime config update: no API key in request"
        );
        false
    };
    next.default_provider = Some(provider.to_string());
    next.default_model = Some(model.to_string());
    next.api_url = if api_url.is_empty() {
        None
    } else {
        Some(api_url.to_string())
    };
    next.transcription.enabled = body.transcription_enabled;
    if let Some(transcription_model) = body
        .transcription_model
        .as_deref()
        .map(str::trim)
        .filter(|value| !value.is_empty())
    {
        next.transcription.model = transcription_model.to_string();
    }

    if let Err(err) = next.save().await {
        return frontend_internal_error_response(
            StatusCode::INTERNAL_SERVER_ERROR,
            "runtime config save",
            "Failed to save runtime settings.",
            err,
        );
    }
    *state.config.lock() = next.clone();
    if provider_changed || model_changed || api_url_changed || api_key_changed {
        reset_workspace_synthesizer_status_for_provider_change(&next.workspace_dir);
    }

    let resp = serde_json::json!({
        "ok": true,
        "restartRequired": true,
        "defaultProvider": next.default_provider.unwrap_or_default(),
        "defaultModel": next.default_model.unwrap_or_default(),
        "apiUrl": next.api_url.unwrap_or_default(),
        "transcriptionEnabled": next.transcription.enabled,
        "transcriptionModel": next.transcription.model,
        "availableTranscriptionModels": available_local_transcription_models(),
    });
    (StatusCode::OK, Json(resp)).into_response()
}

/// POST /api/auth/openrouter/start — begin OpenRouter OAuth PKCE flow.
pub async fn handle_openrouter_oauth_start(
    State(state): State<AppState>,
    headers: HeaderMap,
) -> axum::response::Response {
    if let Some(err) = pairing_auth_error(&state, &headers, "OpenRouter OAuth start") {
        return err.into_response();
    }

    let config = state.config.lock().clone();
    let port = config.gateway.port;
    let callback_url = format!("http://localhost:{port}/api/auth/openrouter/callback");

    let pkce = crate::auth::oauth_common::generate_pkce_state();
    let auth_url = crate::auth::openrouter_oauth::build_authorize_url(&pkce, &callback_url);

    *state.openrouter_oauth.lock() = Some(OpenRouterOAuthSession {
        pkce,
        status: OpenRouterOAuthStatus::Pending,
        api_key: None,
        error: None,
    });

    tracing::info!("OpenRouter OAuth PKCE flow started");
    let body = serde_json::json!({ "authUrl": auth_url });
    (StatusCode::OK, Json(body)).into_response()
}

/// GET /api/auth/openrouter/callback — browser redirect from OpenRouter.
pub async fn handle_openrouter_oauth_callback(
    State(state): State<AppState>,
    Query(params): Query<HashMap<String, String>>,
) -> axum::response::Response {
    let code = match params.get("code") {
        Some(c) if !c.trim().is_empty() => c.trim().to_string(),
        _ => {
            let error_html = "<html><body><h2>OpenRouter login failed</h2>\
                <p>No authorization code received. Please try again.</p></body></html>";
            return axum::response::Html(error_html).into_response();
        }
    };

    let session = state.openrouter_oauth.lock().clone();
    let session = match session {
        Some(s) if s.status == OpenRouterOAuthStatus::Pending => s,
        _ => {
            let error_html = "<html><body><h2>OpenRouter login failed</h2>\
                <p>No pending OAuth session. Please start login again from the app.</p></body></html>";
            return axum::response::Html(error_html).into_response();
        }
    };

    let client = reqwest::Client::new();
    match crate::auth::openrouter_oauth::exchange_code_for_key(&client, &code, &session.pkce).await
    {
        Ok(api_key) => {
            {
                let mut config = state.config.lock();
                config.api_key = Some(api_key.clone());
                config.default_provider = Some("openrouter".to_string());
                if config
                    .default_model
                    .as_deref()
                    .map_or(true, |m| m.is_empty())
                {
                    config.default_model = Some(
                        crate::auth::openrouter_oauth::OPENROUTER_DEFAULT_FREE_MODEL.to_string(),
                    );
                }
            }

            let config_snapshot = state.config.lock().clone();
            if let Err(err) = config_snapshot.save().await {
                tracing::error!("Failed to save config after OpenRouter OAuth: {err:#}");
            }
            reset_workspace_synthesizer_status_for_provider_change(&config_snapshot.workspace_dir);

            *state.openrouter_oauth.lock() = Some(OpenRouterOAuthSession {
                pkce: session.pkce,
                status: OpenRouterOAuthStatus::Complete,
                api_key: Some(api_key),
                error: None,
            });

            tracing::info!("OpenRouter OAuth completed — API key stored");
            let html = "<html><body>\
                <h2>OpenRouter login complete!</h2>\
                <p>You can close this tab and return to the app.</p>\
                <p style=\"color:green\">AI is now enabled with a free model.</p>\
                </body></html>";
            axum::response::Html(html).into_response()
        }
        Err(err) => {
            tracing::error!("OpenRouter OAuth key exchange failed: {err:#}");
            *state.openrouter_oauth.lock() = Some(OpenRouterOAuthSession {
                pkce: session.pkce,
                status: OpenRouterOAuthStatus::Failed,
                api_key: None,
                error: Some(format!("{err:#}")),
            });

            let html = format!(
                "<html><body>\
                <h2>OpenRouter login failed</h2>\
                <p>Could not complete login. Please try again.</p>\
                <p style=\"color:red\">{}</p>\
                </body></html>",
                html_escape(&format!("{err:#}"))
            );
            axum::response::Html(html).into_response()
        }
    }
}

/// GET /api/auth/openrouter/status — poll OAuth session status.
pub async fn handle_openrouter_oauth_status(
    State(state): State<AppState>,
    headers: HeaderMap,
) -> axum::response::Response {
    if let Some(err) = pairing_auth_error(&state, &headers, "OpenRouter OAuth status") {
        return err.into_response();
    }

    let session = state.openrouter_oauth.lock().clone();
    let body = match session {
        Some(s) => serde_json::json!({
            "active": true,
            "status": match s.status {
                OpenRouterOAuthStatus::Pending => "pending",
                OpenRouterOAuthStatus::Complete => "complete",
                OpenRouterOAuthStatus::Failed => "failed",
            },
            "hasKey": s.api_key.is_some(),
            "error": s.error,
        }),
        None => serde_json::json!({
            "active": false,
            "status": "none",
            "hasKey": false,
            "error": null,
        }),
    };
    (StatusCode::OK, Json(body)).into_response()
}

/// POST /pair — exchange one-time code for bearer token
pub async fn handle_pair(
    State(state): State<AppState>,
    ConnectInfo(peer_addr): ConnectInfo<SocketAddr>,
    headers: HeaderMap,
) -> impl IntoResponse {
    let rate_key =
        client_key_from_request(Some(peer_addr), &headers, state.trust_forwarded_headers);
    if !state.rate_limiter.allow_pair(&rate_key) {
        tracing::warn!("/pair rate limit exceeded");
        return frontend_error_response_with_retry_after(
            StatusCode::TOO_MANY_REQUESTS,
            "PAIR_RATE_LIMITED",
            "Too many pairing requests. Please retry later.",
            RATE_LIMIT_WINDOW_SECS,
        );
    }

    let code = headers
        .get("X-Pairing-Code")
        .and_then(|v| v.to_str().ok())
        .unwrap_or("");

    match state.pairing.try_pair(code, &rate_key).await {
        Ok(Some(token)) => {
            tracing::info!("🔐 New client paired successfully");
            if let Err(err) = persist_pairing_tokens(state.config.clone(), &state.pairing).await {
                tracing::error!("🔐 Pairing succeeded but token persistence failed: {err:#}");
                let body = serde_json::json!({
                    "paired": true,
                    "persisted": false,
                    "token": token,
                    "message": "Paired for this process, but failed to persist token to config.toml. Check config path and write permissions.",
                });
                return (StatusCode::OK, Json(body));
            }

            let body = serde_json::json!({
                "paired": true,
                "persisted": true,
                "token": token,
                "message": "Save this token — use it as Authorization: Bearer <token>"
            });
            (StatusCode::OK, Json(body))
        }
        Ok(None) => {
            tracing::warn!("🔐 Pairing attempt with invalid code");
            frontend_error_response(
                StatusCode::FORBIDDEN,
                "PAIR_INVALID_CODE",
                "Invalid pairing code",
            )
        }
        Err(lockout_secs) => {
            tracing::warn!(
                "🔐 Pairing locked out — too many failed attempts ({lockout_secs}s remaining)"
            );
            frontend_error_response_with_retry_after(
                StatusCode::TOO_MANY_REQUESTS,
                "PAIR_ATTEMPTS_LOCKED",
                format!("Too many failed attempts. Try again in {lockout_secs}s."),
                lockout_secs,
            )
        }
    }
}

/// POST /pair/new-code — generate a fresh one-time pairing code using an existing bearer token
pub async fn handle_pair_new_code(
    State(state): State<AppState>,
    headers: HeaderMap,
) -> impl IntoResponse {
    if let Some(err) = pairing_auth_error(&state, &headers, "Pair new code") {
        return err;
    }
    if !state.pairing.require_pairing() {
        return frontend_error_response(
            StatusCode::BAD_REQUEST,
            "PAIRING_DISABLED",
            "Pairing is disabled in config",
        );
    }
    let Some(code) = state.pairing.regenerate_pairing_code() else {
        return frontend_error_response(
            StatusCode::INTERNAL_SERVER_ERROR,
            "PAIR_CODE_GENERATION_FAILED",
            "Failed to generate pairing code",
        );
    };
    let body = serde_json::json!({
        "ok": true,
        "code": code,
        "message": "New one-time pairing code generated"
    });
    (StatusCode::OK, Json(body))
}

/// POST /webhook — simple client trigger
pub async fn handle_webhook(
    State(state): State<AppState>,
    ConnectInfo(peer_addr): ConnectInfo<SocketAddr>,
    headers: HeaderMap,
    body: Result<Json<WebhookBody>, axum::extract::rejection::JsonRejection>,
) -> impl IntoResponse {
    let rate_key =
        client_key_from_request(Some(peer_addr), &headers, state.trust_forwarded_headers);
    if !state.rate_limiter.allow_webhook(&rate_key) {
        tracing::warn!("/webhook rate limit exceeded");
        let err = serde_json::json!({
            "error": "Too many webhook requests. Please retry later.",
            "retry_after": RATE_LIMIT_WINDOW_SECS,
        });
        return (StatusCode::TOO_MANY_REQUESTS, Json(err));
    }

    if state.pairing.require_pairing() {
        let auth = headers
            .get(header::AUTHORIZATION)
            .and_then(|v| v.to_str().ok())
            .unwrap_or("");
        let token = auth.strip_prefix("Bearer ").unwrap_or("");
        if !state.pairing.is_authenticated(token) {
            tracing::warn!("Webhook: rejected — not paired / invalid bearer token");
            let err = serde_json::json!({
                "error": "Unauthorized — pair first via POST /pair, then send Authorization: Bearer <token>"
            });
            return (StatusCode::UNAUTHORIZED, Json(err));
        }
    }

    if let Some(ref secret_hash) = state.webhook_secret_hash {
        let header_hash = headers
            .get("X-Webhook-Secret")
            .and_then(|v| v.to_str().ok())
            .map(str::trim)
            .filter(|value| !value.is_empty())
            .map(hash_webhook_secret);
        match header_hash {
            Some(val) if constant_time_eq(&val, secret_hash.as_ref()) => {}
            _ => {
                tracing::warn!("Webhook: rejected request — invalid or missing X-Webhook-Secret");
                let err = serde_json::json!({"error": "Unauthorized — invalid or missing X-Webhook-Secret header"});
                return (StatusCode::UNAUTHORIZED, Json(err));
            }
        }
    }

    let Json(webhook_body) = match body {
        Ok(b) => b,
        Err(e) => {
            tracing::warn!("Webhook JSON parse error: {e}");
            let err = serde_json::json!({
                "error": "Invalid JSON body. Expected: {\"message\": \"...\"}"
            });
            return (StatusCode::BAD_REQUEST, Json(err));
        }
    };

    if let Some(idempotency_key) = headers
        .get("X-Idempotency-Key")
        .and_then(|v| v.to_str().ok())
        .map(str::trim)
        .filter(|value| !value.is_empty())
    {
        if !state.idempotency_store.record_if_new(idempotency_key) {
            tracing::info!("Webhook duplicate ignored (idempotency key: {idempotency_key})");
            let body = serde_json::json!({
                "status": "duplicate",
                "idempotent": true,
                "message": "Request already processed for this idempotency key"
            });
            return (StatusCode::OK, Json(body));
        }
    }

    let message = &webhook_body.message;

    if state.auto_save {
        let key = webhook_memory_key();
        let _ = state
            .mem
            .store(&key, message, MemoryCategory::Conversation, None)
            .await;
    }

    let provider_label = state
        .config
        .lock()
        .default_provider
        .clone()
        .unwrap_or_else(|| "unknown".to_string());
    let model_label = state.model.clone();
    let started_at = Instant::now();

    state
        .observer
        .record_event(&crate::observability::ObserverEvent::AgentStart {
            provider: provider_label.clone(),
            model: model_label.clone(),
        });
    state
        .observer
        .record_event(&crate::observability::ObserverEvent::LlmRequest {
            provider: provider_label.clone(),
            model: model_label.clone(),
            messages_count: 1,
        });

    match run_gateway_chat_simple(&state, message).await {
        Ok(response) => {
            let duration = started_at.elapsed();
            state
                .observer
                .record_event(&crate::observability::ObserverEvent::LlmResponse {
                    provider: provider_label.clone(),
                    model: model_label.clone(),
                    duration,
                    success: true,
                    error_message: None,
                    input_tokens: None,
                    output_tokens: None,
                });
            state.observer.record_metric(
                &crate::observability::traits::ObserverMetric::RequestLatency(duration),
            );
            state
                .observer
                .record_event(&crate::observability::ObserverEvent::AgentEnd {
                    provider: provider_label,
                    model: model_label,
                    duration,
                    tokens_used: None,
                    cost_usd: None,
                });

            let body = serde_json::json!({"response": response, "model": state.model});
            (StatusCode::OK, Json(body))
        }
        Err(err) => {
            let duration = started_at.elapsed();
            let err_msg = format!("{err:#}");
            state
                .observer
                .record_event(&crate::observability::ObserverEvent::LlmResponse {
                    provider: provider_label.clone(),
                    model: model_label.clone(),
                    duration,
                    success: false,
                    error_message: Some(err_msg.clone()),
                    input_tokens: None,
                    output_tokens: None,
                });
            state
                .observer
                .record_event(&crate::observability::ObserverEvent::AgentEnd {
                    provider: provider_label,
                    model: model_label,
                    duration,
                    tokens_used: None,
                    cost_usd: None,
                });

            let body = serde_json::json!({"error": err_msg});
            (StatusCode::INTERNAL_SERVER_ERROR, Json(body))
        }
    }
}
