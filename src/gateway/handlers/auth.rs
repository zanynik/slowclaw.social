use axum::{
    extract::{Query, State},
    http::{HeaderMap, StatusCode},
    response::IntoResponse,
    Json,
};
use std::collections::HashMap;

use crate::gateway::state::{AppState, OpenRouterOAuthSession, OpenRouterOAuthStatus};
use crate::gateway::{pairing_auth_error, reset_workspace_synthesizer_status_for_provider_change};

fn html_escape(s: &str) -> String {
    s.replace('&', "&amp;")
        .replace('<', "&lt;")
        .replace('>', "&gt;")
        .replace('"', "&quot;")
}

/// GET /api/auth/openrouter/start — begin OpenRouter OAuth PKCE flow.
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
