//! Axum-based HTTP gateway with proper HTTP/1.1 compliance, body limits, and timeouts.
//!
//! This module replaces the raw TCP implementation with axum for:
//! - Proper HTTP/1.1 parsing and compliance
//! - Content-Length validation (handled by hyper)
//! - Request body size limits (64KB max)
//! - Request timeouts (30s) to prevent slow-loris attacks
//! - Header sanitization (handled by axum/hyper)

pub mod static_files;
pub mod local_store;

use crate::config::{Config, TranscriptionConfig};
use crate::memory::{self, Memory, MemoryCategory};
use crate::providers::{self, ChatMessage, Provider};
use crate::security::pairing::{constant_time_eq, is_public_bind, PairingGuard};
use crate::util::truncate_with_ellipsis;
use anyhow::{Context, Result};
use chrono::Datelike;
use axum::{
    extract::{ConnectInfo, Path as AxumPath, Query, Request, State},
    http::{header, HeaderMap, Method, StatusCode},
    response::{IntoResponse, Json},
    routing::{get, post},
    Router,
};
use http_body_util::BodyExt as _;
use parking_lot::Mutex;
use std::collections::{BTreeSet, HashMap};
use std::net::{IpAddr, SocketAddr};
use std::path::{Path as StdPath, PathBuf};
use std::sync::{Arc, OnceLock};
use std::time::{Duration, Instant, UNIX_EPOCH};
use tokio::io::AsyncWriteExt;
use tokio::process::Command;
use tower::ServiceExt as _;
use tower_http::cors::{Any, CorsLayer};
use tower_http::limit::RequestBodyLimitLayer;
use tower_http::services::ServeFile;
use tower_http::timeout::TimeoutLayer;
use uuid::Uuid;

/// Maximum request body size (64KB) — prevents memory exhaustion
pub const MAX_BODY_SIZE: usize = 65_536;
/// Large media uploads for journal audio/video (1 GiB).
pub const MAX_MEDIA_UPLOAD_BODY_SIZE: usize = 1_073_741_824;
/// Request timeout (30s) — prevents slow-loris attacks
pub const REQUEST_TIMEOUT_SECS: u64 = 30;
/// Workflow template creation timeout (5 min) to allow agent script generation.
pub const WORKFLOW_TEMPLATE_TIMEOUT_SECS: u64 = 300;
/// Media upload timeout (30 min) to tolerate large uploads over Wi-Fi/VPN.
pub const MEDIA_UPLOAD_TIMEOUT_SECS: u64 = 1_800;
/// Sliding window used by gateway rate limiting.
pub const RATE_LIMIT_WINDOW_SECS: u64 = 60;
/// Fallback max distinct client keys tracked in gateway rate limiter.
pub const RATE_LIMIT_MAX_KEYS_DEFAULT: usize = 10_000;
/// Fallback max distinct idempotency keys retained in gateway memory.
pub const IDEMPOTENCY_MAX_KEYS_DEFAULT: usize = 10_000;
const JOURNAL_TEXT_DIR: &str = "journals/text";
const JOURNAL_MEDIA_DIR: &str = "journals/media";

fn webhook_memory_key() -> String {
    format!("webhook_msg_{}", Uuid::new_v4())
}

fn hash_webhook_secret(value: &str) -> String {
    use sha2::{Digest, Sha256};

    let digest = Sha256::digest(value.as_bytes());
    hex::encode(digest)
}

/// How often the rate limiter sweeps stale IP entries from its map.
const RATE_LIMITER_SWEEP_INTERVAL_SECS: u64 = 300; // 5 minutes

#[derive(Debug)]
struct SlidingWindowRateLimiter {
    limit_per_window: u32,
    window: Duration,
    max_keys: usize,
    requests: Mutex<(HashMap<String, Vec<Instant>>, Instant)>,
}

impl SlidingWindowRateLimiter {
    fn new(limit_per_window: u32, window: Duration, max_keys: usize) -> Self {
        Self {
            limit_per_window,
            window,
            max_keys: max_keys.max(1),
            requests: Mutex::new((HashMap::new(), Instant::now())),
        }
    }

    fn prune_stale(requests: &mut HashMap<String, Vec<Instant>>, cutoff: Instant) {
        requests.retain(|_, timestamps| {
            timestamps.retain(|t| *t > cutoff);
            !timestamps.is_empty()
        });
    }

    fn allow(&self, key: &str) -> bool {
        if self.limit_per_window == 0 {
            return true;
        }

        let now = Instant::now();
        let cutoff = now.checked_sub(self.window).unwrap_or_else(Instant::now);

        let mut guard = self.requests.lock();
        let (requests, last_sweep) = &mut *guard;

        // Periodic sweep: remove keys with no recent requests
        if last_sweep.elapsed() >= Duration::from_secs(RATE_LIMITER_SWEEP_INTERVAL_SECS) {
            Self::prune_stale(requests, cutoff);
            *last_sweep = now;
        }

        if !requests.contains_key(key) && requests.len() >= self.max_keys {
            // Opportunistic stale cleanup before eviction under cardinality pressure.
            Self::prune_stale(requests, cutoff);
            *last_sweep = now;

            if requests.len() >= self.max_keys {
                let evict_key = requests
                    .iter()
                    .min_by_key(|(_, timestamps)| timestamps.last().copied().unwrap_or(cutoff))
                    .map(|(k, _)| k.clone());
                if let Some(evict_key) = evict_key {
                    requests.remove(&evict_key);
                }
            }
        }

        let entry = requests.entry(key.to_owned()).or_default();
        entry.retain(|instant| *instant > cutoff);

        if entry.len() >= self.limit_per_window as usize {
            return false;
        }

        entry.push(now);
        true
    }
}

#[derive(Debug)]
pub struct GatewayRateLimiter {
    pair: SlidingWindowRateLimiter,
    webhook: SlidingWindowRateLimiter,
}

impl GatewayRateLimiter {
    fn new(pair_per_minute: u32, webhook_per_minute: u32, max_keys: usize) -> Self {
        let window = Duration::from_secs(RATE_LIMIT_WINDOW_SECS);
        Self {
            pair: SlidingWindowRateLimiter::new(pair_per_minute, window, max_keys),
            webhook: SlidingWindowRateLimiter::new(webhook_per_minute, window, max_keys),
        }
    }

    fn allow_pair(&self, key: &str) -> bool {
        self.pair.allow(key)
    }

    fn allow_webhook(&self, key: &str) -> bool {
        self.webhook.allow(key)
    }
}

#[derive(Debug)]
pub struct IdempotencyStore {
    ttl: Duration,
    max_keys: usize,
    keys: Mutex<HashMap<String, Instant>>,
}

impl IdempotencyStore {
    fn new(ttl: Duration, max_keys: usize) -> Self {
        Self {
            ttl,
            max_keys: max_keys.max(1),
            keys: Mutex::new(HashMap::new()),
        }
    }

    /// Returns true if this key is new and is now recorded.
    fn record_if_new(&self, key: &str) -> bool {
        let now = Instant::now();
        let mut keys = self.keys.lock();

        keys.retain(|_, seen_at| now.duration_since(*seen_at) < self.ttl);

        if keys.contains_key(key) {
            return false;
        }

        if keys.len() >= self.max_keys {
            let evict_key = keys
                .iter()
                .min_by_key(|(_, seen_at)| *seen_at)
                .map(|(k, _)| k.clone());
            if let Some(evict_key) = evict_key {
                keys.remove(&evict_key);
            }
        }

        keys.insert(key.to_owned(), now);
        true
    }
}

fn parse_client_ip(value: &str) -> Option<IpAddr> {
    let value = value.trim().trim_matches('"').trim();
    if value.is_empty() {
        return None;
    }

    if let Ok(ip) = value.parse::<IpAddr>() {
        return Some(ip);
    }

    if let Ok(addr) = value.parse::<SocketAddr>() {
        return Some(addr.ip());
    }

    let value = value.trim_matches(['[', ']']);
    value.parse::<IpAddr>().ok()
}

fn forwarded_client_ip(headers: &HeaderMap) -> Option<IpAddr> {
    if let Some(xff) = headers.get("X-Forwarded-For").and_then(|v| v.to_str().ok()) {
        for candidate in xff.split(',') {
            if let Some(ip) = parse_client_ip(candidate) {
                return Some(ip);
            }
        }
    }

    headers
        .get("X-Real-IP")
        .and_then(|v| v.to_str().ok())
        .and_then(parse_client_ip)
}

fn client_key_from_request(
    peer_addr: Option<SocketAddr>,
    headers: &HeaderMap,
    trust_forwarded_headers: bool,
) -> String {
    if trust_forwarded_headers {
        if let Some(ip) = forwarded_client_ip(headers) {
            return ip.to_string();
        }
    }

    peer_addr
        .map(|addr| addr.ip().to_string())
        .unwrap_or_else(|| "unknown".to_string())
}

fn normalize_max_keys(configured: usize, fallback: usize) -> usize {
    if configured == 0 {
        fallback.max(1)
    } else {
        configured
    }
}

fn desktop_cors_layer() -> CorsLayer {
    CorsLayer::new()
        .allow_origin(Any)
        .allow_methods([
            Method::GET,
            Method::POST,
            Method::PUT,
            Method::PATCH,
            Method::DELETE,
            Method::OPTIONS,
        ])
        .allow_headers(Any)
}

/// Shared state for all axum handlers
#[derive(Clone)]
pub struct AppState {
    pub config: Arc<Mutex<Config>>,
    pub provider: Arc<dyn Provider>,
    pub model: String,
    pub temperature: f64,
    pub mem: Arc<dyn Memory>,
    pub auto_save: bool,
    /// SHA-256 hash of `X-Webhook-Secret` (hex-encoded), never plaintext.
    pub webhook_secret_hash: Option<Arc<str>>,
    pub pairing: Arc<PairingGuard>,
    pub trust_forwarded_headers: bool,
    pub rate_limiter: Arc<GatewayRateLimiter>,
    pub idempotency_store: Arc<IdempotencyStore>,
    /// Observability backend for metrics scraping
    pub observer: Arc<dyn crate::observability::Observer>,
    pub pb_chat_base_url: Option<String>,
    pub pb_chat_collection: String,
    pub pb_chat_token: Option<String>,
    journal_transcription_jobs: Arc<Mutex<HashMap<String, JournalTranscriptionJob>>>,
}

#[derive(Clone, Debug, serde::Serialize)]
#[serde(rename_all = "camelCase")]
struct JournalTranscriptionJob {
    status: String,
    transcript_path: Option<String>,
    error: Option<String>,
    updated_at: String,
}

#[derive(Clone, Debug)]
struct TranscriptionModelCacheEntry {
    cache_key: String,
    models: Vec<String>,
    cached_at: Instant,
}

static TRANSCRIPTION_MODEL_CACHE: OnceLock<Mutex<Option<TranscriptionModelCacheEntry>>> =
    OnceLock::new();

const TRANSCRIPTION_MODEL_CACHE_TTL_SECS: u64 = 600;

impl JournalTranscriptionJob {
    fn queued() -> Self {
        Self {
            status: "queued".to_string(),
            transcript_path: None,
            error: None,
            updated_at: chrono::Utc::now().to_rfc3339(),
        }
    }
}

/// Run the HTTP gateway using axum with proper HTTP/1.1 compliance.
#[allow(clippy::too_many_lines)]
pub async fn run_gateway(host: &str, port: u16, config: Config) -> Result<()> {
    // ── Security: refuse public bind without tunnel or explicit opt-in ──
    if is_public_bind(host) && config.tunnel.provider == "none" && !config.gateway.allow_public_bind
    {
        anyhow::bail!(
            "🛑 Refusing to bind to {host} — gateway would be exposed to the internet.\n\
             Fix: use --host 127.0.0.1 (default), configure a tunnel, or set\n\
             [gateway] allow_public_bind = true in config.toml (NOT recommended)."
        );
    }
    let config_state = Arc::new(Mutex::new(config.clone()));

    if let Err(err) = ensure_workflow_bot_creation_skill(&config.workspace_dir) {
        tracing::warn!("Failed to ensure workflow bot creation skill: {err}");
    }

    // ── Hooks ──────────────────────────────────────────────────────
    let hooks: Option<std::sync::Arc<crate::hooks::HookRunner>> = if config.hooks.enabled {
        Some(std::sync::Arc::new(crate::hooks::HookRunner::new()))
    } else {
        None
    };

    let addr: SocketAddr = format!("{host}:{port}").parse()?;
    let listener = tokio::net::TcpListener::bind(addr).await?;
    let actual_port = listener.local_addr()?.port();
    let display_addr = format!("{host}:{actual_port}");

    let local_bootstrap = local_store::initialize(&config.workspace_dir)
        .context("Failed to initialize local gateway store")?;
    if local_bootstrap.migrated_from_legacy {
        println!(
            "  💾 Local store migration complete from {}",
            local_bootstrap
                .legacy_source
                .as_ref()
                .map(|p| p.display().to_string())
                .unwrap_or_else(|| "unknown source".to_string())
        );
        println!(
            "     chat_messages={} drafts={} post_history={} journal_entries={} media_assets={} artifacts={}",
            local_bootstrap.migrated_chat_messages,
            local_bootstrap.migrated_drafts,
            local_bootstrap.migrated_post_history,
            local_bootstrap.migrated_journal_entries,
            local_bootstrap.migrated_media_assets,
            local_bootstrap.migrated_artifacts
        );
    }

    let provider: Arc<dyn Provider> = Arc::from(providers::create_resilient_provider_with_options(
        config.default_provider.as_deref().unwrap_or("openrouter"),
        config.api_key.as_deref(),
        config.api_url.as_deref(),
        &config.reliability,
        &providers::ProviderRuntimeOptions {
            auth_profile_override: None,
            provider_api_url: config.api_url.clone(),
            zeroclaw_dir: config.config_path.parent().map(std::path::PathBuf::from),
            secrets_encrypt: config.secrets.encrypt,
            reasoning_enabled: config.runtime.reasoning_enabled,
        },
    )?);
    let model = config
        .default_model
        .clone()
        .unwrap_or_else(|| "anthropic/claude-sonnet-4".into());
    let temperature = config.default_temperature;
    let mem: Arc<dyn Memory> = Arc::from(memory::create_memory_with_storage(
        &config.memory,
        Some(&config.storage.provider.config),
        &config.workspace_dir,
        config.api_key.as_deref(),
    )?);
    // Extract webhook secret for authentication
    let webhook_secret_hash: Option<Arc<str>> =
        config.channels_config.webhook.as_ref().and_then(|webhook| {
            webhook.secret.as_ref().and_then(|raw_secret| {
                let trimmed_secret = raw_secret.trim();
                (!trimmed_secret.is_empty())
                    .then(|| Arc::<str>::from(hash_webhook_secret(trimmed_secret)))
            })
        });

    // ── Pairing guard ──────────────────────────────────────
    let pairing = Arc::new(PairingGuard::new(
        config.gateway.require_pairing,
        &config.gateway.paired_tokens,
    ));
    let rate_limit_max_keys = normalize_max_keys(
        config.gateway.rate_limit_max_keys,
        RATE_LIMIT_MAX_KEYS_DEFAULT,
    );
    let rate_limiter = Arc::new(GatewayRateLimiter::new(
        config.gateway.pair_rate_limit_per_minute,
        config.gateway.webhook_rate_limit_per_minute,
        rate_limit_max_keys,
    ));
    let idempotency_max_keys = normalize_max_keys(
        config.gateway.idempotency_max_keys,
        IDEMPOTENCY_MAX_KEYS_DEFAULT,
    );
    let idempotency_store = Arc::new(IdempotencyStore::new(
        Duration::from_secs(config.gateway.idempotency_ttl_secs.max(1)),
        idempotency_max_keys,
    ));

    // ── Tunnel ────────────────────────────────────────────────
    let tunnel = crate::tunnel::create_tunnel(&config.tunnel)?;
    let mut tunnel_url: Option<String> = None;

    if let Some(ref tun) = tunnel {
        println!("🔗 Starting {} tunnel...", tun.name());
        match tun.start(host, actual_port).await {
            Ok(url) => {
                println!("🌐 Tunnel active: {url}");
                tunnel_url = Some(url);
            }
            Err(e) => {
                println!("⚠️  Tunnel failed to start: {e}");
                println!("   Falling back to local-only mode.");
            }
        }
    }

    println!("🦀 SlowClaw Gateway listening on http://{display_addr}");
    if let Some(ref url) = tunnel_url {
        println!("  🌐 Public URL: {url}");
    }
    println!("  🌐 Web UI: http://{display_addr}/");
    println!(
        "  💾 Local store: {}",
        local_bootstrap.db_path.display()
    );
    println!("  📁 Workspace: {}", config.workspace_dir.display());
    println!("  POST /pair      — pair a new client (X-Pairing-Code header)");
    println!("  POST /pair/new-code — mint a fresh one-time pairing code (requires bearer)");
    println!("  POST /webhook   — {{\"message\": \"your prompt\"}}");
    println!("  GET  /health    — health check");
    println!("  GET  /metrics   — Prometheus metrics");
    if let Some(code) = pairing.pairing_code() {
        println!();
        println!("  🔐 PAIRING REQUIRED — use this one-time code:");
        println!("     ┌──────────────┐");
        println!("     │  {code}  │");
        println!("     └──────────────┘");
        println!("     Send: POST /pair with header X-Pairing-Code: {code}");
    } else if pairing.require_pairing() {
        println!("  🔒 Pairing: ACTIVE (bearer token required)");
    } else {
        println!("  ⚠️  Pairing: DISABLED (all requests accepted)");
    }
    println!("  Press Ctrl+C to stop.\n");

    crate::health::mark_component_ok("gateway");

    // Fire gateway start hook
    if let Some(ref hooks) = hooks {
        hooks.fire_gateway_start(host, actual_port).await;
    }

    let observer: Arc<dyn crate::observability::Observer> =
        crate::observability::create_observer(&config.observability).into();

    let state = AppState {
        config: config_state,
        provider,
        model,
        temperature,
        mem,
        auto_save: config.memory.auto_save,
        webhook_secret_hash,
        pairing,
        trust_forwarded_headers: config.gateway.trust_forwarded_headers,
        rate_limiter,
        idempotency_store,
        observer,
        pb_chat_base_url: None,
        pb_chat_collection: "chat_messages".to_string(),
        pb_chat_token: None,
        journal_transcription_jobs: Arc::new(Mutex::new(HashMap::new())),
    };

    // Core API/UI router (small request bodies)
    let core_router = Router::new()
        .route("/health", get(handle_health))
        .route("/metrics", get(handle_metrics))
        .route("/pair", post(handle_pair))
        .route("/pair/new-code", post(handle_pair_new_code))
        .route(
            "/api/config/runtime",
            get(handle_runtime_config).post(handle_runtime_config_update),
        )
        .route("/webhook", post(handle_webhook))
        .route("/api/chat/messages", get(handle_chat_list).post(handle_chat_send))
        .route(
            "/api/feed/workflow-comment",
            post(handle_feed_workflow_comment),
        )
        .route(
            "/api/feed/workflow-settings",
            get(handle_feed_workflow_settings).post(handle_feed_workflow_settings_update),
        )
        .route("/api/feed/workflow-run", post(handle_feed_workflow_run))
        .route("/api/drafts", get(handle_drafts_list).post(handle_drafts_upsert))
        .route(
            "/api/post-history",
            get(handle_post_history_list).post(handle_post_history_create),
        )
        .with_state(state.clone())
        .layer(RequestBodyLimitLayer::new(MAX_BODY_SIZE))
        .layer(TimeoutLayer::with_status_code(
            StatusCode::REQUEST_TIMEOUT,
            Duration::from_secs(REQUEST_TIMEOUT_SECS),
        ));

    // Workflow template creation can take longer because it invokes the agent to generate scripts.
    let workflow_template_router = Router::new()
        .route(
            "/api/feed/workflow-template",
            post(handle_feed_workflow_template_create),
        )
        .with_state(state.clone())
        .layer(RequestBodyLimitLayer::new(MAX_BODY_SIZE))
        .layer(TimeoutLayer::with_status_code(
            StatusCode::REQUEST_TIMEOUT,
            Duration::from_secs(WORKFLOW_TEMPLATE_TIMEOUT_SECS),
        ));

    // Journal/media endpoints (large uploads + file streaming)
    let media_router = Router::new()
        .route("/api/media/upload", post(handle_media_upload))
        .route("/api/journal/text", post(handle_journal_text))
        .route("/api/journal/transcribe", post(handle_journal_transcribe))
        .route(
            "/api/journal/transcribe/status",
            get(handle_journal_transcribe_status),
        )
        .route("/api/library/items", get(handle_library_items))
        .route("/api/library/text", get(handle_library_text))
        .route("/api/library/save-text", post(handle_library_save_text))
        .route("/api/library/delete", post(handle_library_delete))
        .route("/api/media/{*path}", get(handle_media_stream))
        .with_state(state.clone())
        .layer(RequestBodyLimitLayer::new(MAX_MEDIA_UPLOAD_BODY_SIZE))
        .layer(TimeoutLayer::with_status_code(
            StatusCode::REQUEST_TIMEOUT,
            Duration::from_secs(MEDIA_UPLOAD_TIMEOUT_SECS),
        ));

    let app = Router::new()
        .merge(core_router)
        .merge(workflow_template_router)
        .merge(media_router)
        .route("/_app/{*path}", get(static_files::handle_static))
        .fallback(get(static_files::handle_spa_fallback))
        .layer(desktop_cors_layer());

    // Run the server
    axum::serve(
        listener,
        app.into_make_service_with_connect_info::<SocketAddr>(),
    )
    .await?;

    Ok(())
}

// ══════════════════════════════════════════════════════════════════════════════
// AXUM HANDLERS
// ══════════════════════════════════════════════════════════════════════════════

/// GET /health — always public (no secrets leaked)
async fn handle_health(State(state): State<AppState>) -> impl IntoResponse {
    let body = serde_json::json!({
        "status": "ok",
        "paired": state.pairing.is_paired(),
        "require_pairing": state.pairing.require_pairing(),
        "runtime": crate::health::snapshot_json(),
    });
    Json(body)
}

/// Prometheus content type for text exposition format.
const PROMETHEUS_CONTENT_TYPE: &str = "text/plain; version=0.0.4; charset=utf-8";

/// GET /metrics — Prometheus text exposition format
async fn handle_metrics(State(state): State<AppState>) -> impl IntoResponse {
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

async fn handle_runtime_config(
    State(state): State<AppState>,
    headers: HeaderMap,
) -> axum::response::Response {
    if let Some(err) = pairing_auth_error(&state, &headers, "Runtime config") {
        return err.into_response();
    }
    let config = state.config.lock().clone();
    let transcription_models = available_local_transcription_models();
    let body = serde_json::json!({
        "defaultProvider": config.default_provider.unwrap_or_default(),
        "defaultModel": config.default_model.unwrap_or_default(),
        "transcriptionEnabled": config.transcription.enabled,
        "transcriptionModel": config.transcription.model,
        "availableTranscriptionModels": transcription_models,
    });
    (StatusCode::OK, Json(body)).into_response()
}

async fn handle_runtime_config_update(
    State(state): State<AppState>,
    headers: HeaderMap,
    Json(body): Json<RuntimeConfigUpdateBody>,
) -> axum::response::Response {
    if let Some(err) = pairing_auth_error(&state, &headers, "Runtime config update") {
        return err.into_response();
    }

    let provider = body.default_provider.trim();
    if provider.is_empty() {
        let err = serde_json::json!({"error": "defaultProvider is required"});
        return (StatusCode::BAD_REQUEST, Json(err)).into_response();
    }
    let model = body.default_model.trim();
    if model.is_empty() {
        let err = serde_json::json!({"error": "defaultModel is required"});
        return (StatusCode::BAD_REQUEST, Json(err)).into_response();
    }

    let mut next = state.config.lock().clone();
    next.default_provider = Some(provider.to_string());
    next.default_model = Some(model.to_string());
    next.transcription.enabled = body.transcription_enabled;
    if let Some(transcription_model) = body
        .transcription_model
        .as_deref()
        .map(str::trim)
        .filter(|value| !value.is_empty())
    {
        next.transcription.model = transcription_model.to_string();
    }

    if let Err(e) = next.save().await {
        let err = serde_json::json!({"error": format!("Failed to save config: {e}")});
        return (StatusCode::INTERNAL_SERVER_ERROR, Json(err)).into_response();
    }
    *state.config.lock() = next.clone();

    let resp = serde_json::json!({
        "ok": true,
        "restartRequired": true,
        "defaultProvider": next.default_provider.unwrap_or_default(),
        "defaultModel": next.default_model.unwrap_or_default(),
        "transcriptionEnabled": next.transcription.enabled,
        "transcriptionModel": next.transcription.model,
        "availableTranscriptionModels": available_local_transcription_models(),
    });
    (StatusCode::OK, Json(resp)).into_response()
}

/// POST /pair — exchange one-time code for bearer token
#[axum::debug_handler]
async fn handle_pair(
    State(state): State<AppState>,
    ConnectInfo(peer_addr): ConnectInfo<SocketAddr>,
    headers: HeaderMap,
) -> impl IntoResponse {
    let rate_key =
        client_key_from_request(Some(peer_addr), &headers, state.trust_forwarded_headers);
    if !state.rate_limiter.allow_pair(&rate_key) {
        tracing::warn!("/pair rate limit exceeded");
        let err = serde_json::json!({
            "error": "Too many pairing requests. Please retry later.",
            "retry_after": RATE_LIMIT_WINDOW_SECS,
        });
        return (StatusCode::TOO_MANY_REQUESTS, Json(err));
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
            let err = serde_json::json!({"error": "Invalid pairing code"});
            (StatusCode::FORBIDDEN, Json(err))
        }
        Err(lockout_secs) => {
            tracing::warn!(
                "🔐 Pairing locked out — too many failed attempts ({lockout_secs}s remaining)"
            );
            let err = serde_json::json!({
                "error": format!("Too many failed attempts. Try again in {lockout_secs}s."),
                "retry_after": lockout_secs
            });
            (StatusCode::TOO_MANY_REQUESTS, Json(err))
        }
    }
}

/// POST /pair/new-code — generate a fresh one-time pairing code using an existing bearer token
async fn handle_pair_new_code(
    State(state): State<AppState>,
    headers: HeaderMap,
) -> impl IntoResponse {
    if let Some(err) = pairing_auth_error(&state, &headers, "Pair new code") {
        return err;
    }
    if !state.pairing.require_pairing() {
        let err = serde_json::json!({"error": "Pairing is disabled in config"});
        return (StatusCode::BAD_REQUEST, Json(err));
    }
    let Some(code) = state.pairing.regenerate_pairing_code() else {
        let err = serde_json::json!({"error": "Failed to generate pairing code"});
        return (StatusCode::INTERNAL_SERVER_ERROR, Json(err));
    };
    let body = serde_json::json!({
        "ok": true,
        "code": code,
        "message": "New one-time pairing code generated"
    });
    (StatusCode::OK, Json(body))
}

async fn persist_pairing_tokens(config: Arc<Mutex<Config>>, pairing: &PairingGuard) -> Result<()> {
    let paired_tokens = pairing.tokens();
    // This is needed because parking_lot's guard is not Send so we clone the inner
    // this should be removed once async mutexes are used everywhere
    let mut updated_cfg = { config.lock().clone() };
    updated_cfg.gateway.paired_tokens = paired_tokens;
    updated_cfg
        .save()
        .await
        .context("Failed to persist paired tokens to config.toml")?;

    // Keep shared runtime config in sync with persisted tokens.
    *config.lock() = updated_cfg;
    Ok(())
}

/// Simple chat for webhook endpoint (no tools, for backward compatibility and testing).
async fn run_gateway_chat_simple(state: &AppState, message: &str) -> anyhow::Result<String> {
    let user_messages = vec![ChatMessage::user(message)];

    // Keep webhook/gateway prompts aligned with channel behavior by injecting
    // workspace-aware system context before model invocation.
    let system_prompt = {
        let config_guard = state.config.lock();
        crate::channels::build_system_prompt(
            &config_guard.workspace_dir,
            &state.model,
            &[], // tools - empty for simple chat
            &[], // skills
            Some(&config_guard.identity),
            None, // bootstrap_max_chars - use default
        )
    };

    let mut messages = Vec::with_capacity(1 + user_messages.len());
    messages.push(ChatMessage::system(system_prompt));
    messages.extend(user_messages);

    let multimodal_config = state.config.lock().multimodal.clone();
    let prepared =
        crate::multimodal::prepare_messages_for_provider(&messages, &multimodal_config).await?;

    state
        .provider
        .chat_with_history(&prepared.messages, &state.model, state.temperature)
        .await
}

/// Full-featured chat with tools for channel handlers (WhatsApp, Linq, Nextcloud Talk).
async fn run_gateway_chat_with_tools(state: &AppState, message: &str) -> anyhow::Result<String> {
    let config = state.config.lock().clone();
    crate::agent::process_message(config, message).await
}

/// Webhook request body
#[derive(serde::Deserialize)]
pub struct WebhookBody {
    pub message: String,
}

#[derive(serde::Deserialize)]
struct ChatListQuery {
    #[serde(rename = "threadId")]
    thread_id: Option<String>,
    limit: Option<usize>,
}

#[derive(serde::Deserialize)]
struct ChatSendBody {
    #[serde(rename = "threadId")]
    thread_id: String,
    content: String,
}

#[derive(serde::Deserialize)]
struct DraftListQuery {
    limit: Option<usize>,
}

#[derive(serde::Deserialize)]
struct DraftUpsertBody {
    id: Option<String>,
    text: Option<String>,
    #[serde(rename = "videoName")]
    video_name: Option<String>,
    #[serde(rename = "createdAtClient")]
    created_at_client: Option<String>,
    #[serde(rename = "updatedAtClient")]
    updated_at_client: Option<String>,
}

#[derive(serde::Deserialize)]
struct PostHistoryListQuery {
    limit: Option<usize>,
}

#[derive(serde::Deserialize)]
struct PostHistoryCreateBody {
    provider: Option<String>,
    text: Option<String>,
    #[serde(rename = "videoName")]
    video_name: Option<String>,
    #[serde(rename = "sourcePath")]
    source_path: Option<String>,
    uri: Option<String>,
    cid: Option<String>,
    status: Option<String>,
    error: Option<String>,
    #[serde(rename = "createdAtClient")]
    created_at_client: Option<String>,
}

#[derive(serde::Deserialize)]
struct FeedWorkflowCommentBody {
    path: String,
    comment: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, serde::Serialize, serde::Deserialize, Default)]
#[serde(rename_all = "snake_case")]
enum FeedWorkflowMode {
    #[default]
    DateRange,
    Random,
}

impl FeedWorkflowMode {
    fn as_cli_value(self) -> &'static str {
        match self {
            Self::DateRange => "date_range",
            Self::Random => "random",
        }
    }

    fn parse(raw: &str) -> Option<Self> {
        match raw.trim().to_ascii_lowercase().as_str() {
            "date_range" => Some(Self::DateRange),
            "random" => Some(Self::Random),
            _ => None,
        }
    }
}

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
struct FeedWorkflowSettings {
    #[serde(default)]
    mode: FeedWorkflowMode,
    #[serde(default = "default_feed_workflow_days")]
    days: u32,
    #[serde(default = "default_feed_workflow_random_count")]
    random_count: u32,
    #[serde(default)]
    schedule_enabled: bool,
    #[serde(default)]
    schedule_cron: String,
    #[serde(default)]
    schedule_tz: Option<String>,
    #[serde(default)]
    prompt: Option<String>,
}

#[derive(Debug, Clone, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
struct FeedWorkflowSettingsUpdateBody {
    workflow_key: String,
    mode: Option<String>,
    days: Option<u32>,
    random_count: Option<u32>,
    schedule_enabled: Option<bool>,
    schedule_cron: Option<String>,
    schedule_tz: Option<String>,
    prompt: Option<String>,
}

#[derive(Debug, Clone, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
struct FeedWorkflowRunBody {
    workflow_key: String,
}

#[derive(Debug, Clone, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
struct FeedWorkflowTemplateCreateBody {
    name: String,
    #[serde(default)]
    bot_name: Option<String>,
    #[serde(default)]
    source_kind: Option<String>,
    #[serde(default)]
    prompt: Option<String>,
    #[serde(default)]
    mode: Option<String>,
    #[serde(default)]
    days: Option<u32>,
    #[serde(default)]
    random_count: Option<u32>,
    #[serde(default)]
    schedule_enabled: Option<bool>,
    #[serde(default)]
    schedule_cron: Option<String>,
    #[serde(default)]
    schedule_tz: Option<String>,
    #[serde(default)]
    run_now: Option<bool>,
}

#[derive(Debug, Clone, serde::Serialize)]
#[serde(rename_all = "camelCase")]
struct FeedWorkflowSettingsResponseItem {
    workflow_key: String,
    workflow_bot: String,
    script_path: String,
    output_prefix: String,
    mode: FeedWorkflowMode,
    days: u32,
    random_count: u32,
    schedule_enabled: bool,
    schedule_cron: String,
    schedule_tz: Option<String>,
    schedule_job_id: Option<String>,
    schedule_next_run: Option<String>,
    prompt: Option<String>,
    command_preview: String,
    editable_files: Vec<String>,
}

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
struct FeedWorkflowRecord {
    workflow_key: String,
    workflow_bot: String,
    script_path: String,
    output_prefix: String,
    #[serde(default)]
    editable_files: Vec<String>,
    #[serde(default = "workflow_default_settings")]
    settings: FeedWorkflowSettings,
}

#[derive(Debug, Clone, Default, serde::Serialize, serde::Deserialize)]
struct FeedWorkflowSettingsStore {
    #[serde(default)]
    workflows: HashMap<String, FeedWorkflowRecord>,
}

fn default_feed_workflow_days() -> u32 {
    7
}

fn default_feed_workflow_random_count() -> u32 {
    1
}

#[derive(Debug, Clone)]
struct FeedWorkflowDefinition {
    key: String,
    bot_name: String,
    editable_files: Vec<String>,
    output_prefix: String,
    script_path: String,
}

#[derive(Debug, Clone, Default, serde::Serialize, serde::Deserialize)]
struct LegacyFeedWorkflowSettingsStore {
    #[serde(default)]
    workflows: HashMap<String, FeedWorkflowSettings>,
}

fn default_workflow_schedule_cron() -> String {
    "0 9 * * *".to_string()
}

fn workflow_default_settings() -> FeedWorkflowSettings {
    FeedWorkflowSettings {
        mode: FeedWorkflowMode::DateRange,
        days: default_feed_workflow_days(),
        random_count: default_feed_workflow_random_count(),
        schedule_enabled: false,
        schedule_cron: default_workflow_schedule_cron(),
        schedule_tz: None,
        prompt: None,
    }
}

fn default_workflow_bot_name(workflow_key: &str) -> String {
    let mut title = String::new();
    for token in workflow_key.split('_').filter(|value| !value.is_empty()) {
        if !title.is_empty() {
            title.push(' ');
        }
        let mut chars = token.chars();
        if let Some(first) = chars.next() {
            title.push(first.to_ascii_uppercase());
            title.push_str(chars.as_str());
        }
    }
    if title.is_empty() {
        "WorkflowBot".to_string()
    } else {
        format!("{title} Bot").replace(' ', "")
    }
}

fn normalize_workflow_output_prefix(prefix: &str, workflow_key: &str) -> String {
    let trimmed = prefix.trim().trim_start_matches('/').replace('\\', "/");
    let mut normalized = if trimmed.is_empty() {
        format!("posts/{workflow_key}/")
    } else {
        trimmed
    };
    if !normalized.starts_with("posts/") {
        normalized = format!("posts/{workflow_key}/");
    }
    if !normalized.ends_with('/') {
        normalized.push('/');
    }
    normalized
}

fn normalize_workflow_script_path(script_path: &str, workflow_key: &str) -> String {
    let fallback = format!("scripts/{workflow_key}_skill/run_{workflow_key}.py");
    let trimmed = script_path.trim().trim_start_matches('/').replace('\\', "/");
    if trimmed.is_empty() {
        return fallback;
    }
    if trimmed.contains("..") {
        return fallback;
    }
    if !trimmed.starts_with("scripts/") {
        return fallback;
    }
    trimmed
}

fn normalize_workflow_record(workflow_key: &str, mut record: FeedWorkflowRecord) -> FeedWorkflowRecord {
    record.workflow_key = workflow_key.to_string();
    record.workflow_bot = record
        .workflow_bot
        .trim()
        .to_string()
        .if_empty_then(|| default_workflow_bot_name(workflow_key));
    record.script_path = normalize_workflow_script_path(&record.script_path, workflow_key);
    record.output_prefix = normalize_workflow_output_prefix(&record.output_prefix, workflow_key);
    record.settings = normalize_workflow_settings(record.settings);

    let mut editable = Vec::new();
    for path in &record.editable_files {
        let cleaned = path.trim().trim_start_matches('/').replace('\\', "/");
        if cleaned.is_empty() || cleaned.contains("..") {
            continue;
        }
        if !editable.contains(&cleaned) {
            editable.push(cleaned);
        }
    }
    if !editable.iter().any(|path| path == &record.script_path) {
        editable.push(record.script_path.clone());
    }
    let skill_default = format!("skills/{workflow_key}/SKILL.md");
    if !editable.iter().any(|path| path == &skill_default) {
        editable.push(skill_default);
    }
    record.editable_files = editable;
    record
}

trait StringExt {
    fn if_empty_then<F: FnOnce() -> String>(self, fallback: F) -> String;
}

impl StringExt for String {
    fn if_empty_then<F: FnOnce() -> String>(self, fallback: F) -> String {
        if self.trim().is_empty() {
            fallback()
        } else {
            self
        }
    }
}

fn feed_workflow_definition_from_record(record: &FeedWorkflowRecord) -> FeedWorkflowDefinition {
    FeedWorkflowDefinition {
        key: record.workflow_key.clone(),
        bot_name: record.workflow_bot.clone(),
        editable_files: record.editable_files.clone(),
        output_prefix: record.output_prefix.clone(),
        script_path: record.script_path.clone(),
    }
}

fn workflow_definitions(store: &FeedWorkflowSettingsStore) -> Vec<FeedWorkflowDefinition> {
    let mut defs: Vec<FeedWorkflowDefinition> = store
        .workflows
        .values()
        .map(feed_workflow_definition_from_record)
        .collect();
    defs.sort_by(|a, b| a.key.cmp(&b.key));
    defs
}

fn workflow_definition_by_key(
    store: &FeedWorkflowSettingsStore,
    key: &str,
) -> Option<FeedWorkflowDefinition> {
    let normalized = key.trim().to_ascii_lowercase();
    store
        .workflows
        .get(&normalized)
        .map(feed_workflow_definition_from_record)
}

fn workflow_for_feed_path(
    store: &FeedWorkflowSettingsStore,
    path: &str,
) -> Option<FeedWorkflowDefinition> {
    let normalized_path = path.trim_start_matches('/').to_ascii_lowercase();
    workflow_definitions(store)
        .into_iter()
        .find(|workflow| normalized_path.starts_with(&workflow.output_prefix.to_ascii_lowercase()))
}

fn normalize_workflow_settings(mut settings: FeedWorkflowSettings) -> FeedWorkflowSettings {
    settings.days = settings.days.clamp(1, 30);
    settings.random_count = settings.random_count.clamp(1, 10);
    settings.schedule_cron = settings.schedule_cron.trim().to_string();
    if settings.schedule_cron.is_empty() {
        settings.schedule_cron = default_workflow_schedule_cron();
    }
    settings.schedule_tz = settings
        .schedule_tz
        .and_then(|value| {
            let trimmed = value.trim().to_string();
            (!trimmed.is_empty()).then_some(trimmed)
        });
    settings
}

fn workflow_settings_store_path(workspace_dir: &StdPath) -> PathBuf {
    workspace_dir
        .join("state")
        .join("feed_workflow_settings.json")
}

fn load_feed_workflow_settings_store(workspace_dir: &StdPath) -> Result<FeedWorkflowSettingsStore> {
    let path = workflow_settings_store_path(workspace_dir);
    if !path.exists() {
        return Ok(FeedWorkflowSettingsStore::default());
    }
    let raw = std::fs::read_to_string(&path)
        .with_context(|| format!("Failed to read workflow settings store {}", path.display()))?;
    if let Ok(mut parsed) = serde_json::from_str::<FeedWorkflowSettingsStore>(&raw) {
        parsed.workflows = parsed
            .workflows
            .into_iter()
            .map(|(key, record)| {
                let normalized_key = sanitize_workflow_key(&key);
                (normalized_key.clone(), normalize_workflow_record(&normalized_key, record))
            })
            .collect();
        return Ok(parsed);
    }

    let legacy: LegacyFeedWorkflowSettingsStore = serde_json::from_str(&raw)
        .with_context(|| format!("Invalid workflow settings JSON {}", path.display()))?;
    let mut migrated = FeedWorkflowSettingsStore::default();
    for (legacy_key, legacy_settings) in legacy.workflows {
        let key = sanitize_workflow_key(&legacy_key);
        let record = FeedWorkflowRecord {
            workflow_key: key.clone(),
            workflow_bot: default_workflow_bot_name(&key),
            script_path: format!("scripts/{key}_skill/run_{key}.py"),
            output_prefix: format!("posts/{key}/"),
            editable_files: vec![
                format!("scripts/{key}_skill/run_{key}.py"),
                format!("skills/{key}/SKILL.md"),
            ],
            settings: normalize_workflow_settings(legacy_settings),
        };
        migrated
            .workflows
            .insert(key.clone(), normalize_workflow_record(&key, record));
    }
    Ok(migrated)
}

fn save_feed_workflow_settings_store(
    workspace_dir: &StdPath,
    store: &FeedWorkflowSettingsStore,
) -> Result<()> {
    let path = workflow_settings_store_path(workspace_dir);
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent).with_context(|| {
            format!(
                "Failed to create workflow settings directory {}",
                parent.display()
            )
        })?;
    }
    let body = serde_json::to_string_pretty(store)?;
    std::fs::write(&path, body)
        .with_context(|| format!("Failed to write workflow settings store {}", path.display()))
}

fn workflow_cron_job_name(workflow_key: &str) -> String {
    format!("workflow:{workflow_key}")
}

fn workflow_command_preview(workflow: &FeedWorkflowDefinition, settings: &FeedWorkflowSettings) -> String {
    let mut parts = vec![
        "workspace-script".to_string(),
        workflow.script_path.trim_start_matches('/').to_string(),
        "--mode".to_string(),
        settings.mode.as_cli_value().to_string(),
    ];

    match settings.mode {
        FeedWorkflowMode::DateRange => {
            parts.push("--days".to_string());
            parts.push(settings.days.to_string());
        }
        FeedWorkflowMode::Random => {
            parts.push("--random-count".to_string());
            parts.push(settings.random_count.to_string());
        }
    }

    if let Some(prompt) = &settings.prompt {
        parts.push("--prompt".to_string());
        parts.push(format!("\"{prompt}\""));
    }

    parts.join(" ")
}

fn select_primary_workflow_job(
    config: &Config,
    workflow_key: &str,
) -> Result<Option<crate::cron::CronJob>> {
    let target_name = workflow_cron_job_name(workflow_key);
    let mut jobs: Vec<crate::cron::CronJob> = crate::cron::list_jobs(config)?
        .into_iter()
        .filter(|job| job.name.as_deref() == Some(target_name.as_str()))
        .collect();
    jobs.sort_by_key(|job| job.created_at);

    if jobs.len() > 1 {
        let keep_id = jobs
            .first()
            .map(|job| job.id.clone())
            .unwrap_or_default();
        for dup in jobs.iter().skip(1) {
            if let Err(err) = crate::cron::remove_job(config, &dup.id) {
                tracing::warn!(
                    "Failed to remove duplicate workflow cron job {} ({}): {err}",
                    dup.id,
                    workflow_key
                );
            }
        }
        jobs.retain(|job| job.id == keep_id);
    }

    Ok(jobs.into_iter().next())
}

fn upsert_workflow_schedule_with_command(
    config: &Config,
    workflow_key: &str,
    settings: &FeedWorkflowSettings,
    command: String,
) -> Result<Option<crate::cron::CronJob>> {
    let existing = select_primary_workflow_job(config, workflow_key)?;
    if !settings.schedule_enabled {
        if let Some(job) = existing {
            crate::cron::remove_job(config, &job.id)?;
        }
        return Ok(None);
    }

    if !config.cron.enabled {
        anyhow::bail!("cron scheduling is disabled in config (cron.enabled=false)");
    }

    let expr = settings.schedule_cron.trim();
    if expr.is_empty() {
        anyhow::bail!("schedule cron expression is required when schedule is enabled");
    }

    let schedule = crate::cron::Schedule::Cron {
        expr: expr.to_string(),
        tz: settings.schedule_tz.clone(),
    };
    let name = workflow_cron_job_name(workflow_key);

    if let Some(job) = existing {
        let patch = crate::cron::CronJobPatch {
            schedule: Some(schedule),
            command: Some(command),
            name: Some(name),
            enabled: Some(true),
            ..crate::cron::CronJobPatch::default()
        };
        let updated = crate::cron::update_job(config, &job.id, patch)?;
        Ok(Some(updated))
    } else {
        let created = crate::cron::add_shell_job(config, Some(name), schedule, &command)?;
        Ok(Some(created))
    }
}

fn upsert_workflow_schedule(
    config: &Config,
    workflow: &FeedWorkflowDefinition,
    settings: &FeedWorkflowSettings,
) -> Result<Option<crate::cron::CronJob>> {
    let command = workflow_command_preview(workflow, settings);
    upsert_workflow_schedule_with_command(config, &workflow.key, settings, command)
}

fn workflow_settings_response_item(
    workflow: &FeedWorkflowDefinition,
    settings: FeedWorkflowSettings,
    schedule_job: Option<&crate::cron::CronJob>,
) -> FeedWorkflowSettingsResponseItem {
    FeedWorkflowSettingsResponseItem {
        workflow_key: workflow.key.to_string(),
        workflow_bot: workflow.bot_name.to_string(),
        script_path: workflow.script_path.to_string(),
        output_prefix: workflow.output_prefix.to_string(),
        mode: settings.mode,
        days: settings.days,
        random_count: settings.random_count,
        schedule_enabled: schedule_job.is_some(),
        schedule_cron: schedule_job
            .and_then(|job| match &job.schedule {
                crate::cron::Schedule::Cron { expr, .. } => Some(expr.clone()),
                _ => None,
            })
            .unwrap_or_else(|| settings.schedule_cron.clone()),
        schedule_tz: schedule_job
            .and_then(|job| match &job.schedule {
                crate::cron::Schedule::Cron { tz, .. } => tz.clone(),
                _ => None,
            })
            .or(settings.schedule_tz.clone()),
        schedule_job_id: schedule_job.map(|job| job.id.clone()),
        schedule_next_run: schedule_job.map(|job| job.next_run.to_rfc3339()),
        prompt: settings.prompt.clone(),
        command_preview: workflow_command_preview(workflow, &settings),
        editable_files: workflow
            .editable_files
            .iter()
            .map(std::string::ToString::to_string)
            .collect(),
    }
}

fn build_manual_workflow_job(workflow_key: &str, bot_name: &str, command: String) -> crate::cron::CronJob {
    let now = chrono::Utc::now();
    crate::cron::CronJob {
        id: format!("workflow_manual_{}", Uuid::new_v4().simple()),
        expression: "manual".to_string(),
        schedule: crate::cron::Schedule::At { at: now },
        command,
        prompt: None,
        name: Some(format!("{} ({workflow_key})", bot_name)),
        job_type: crate::cron::JobType::Shell,
        session_target: crate::cron::SessionTarget::Isolated,
        model: None,
        enabled: true,
        delivery: crate::cron::DeliveryConfig::default(),
        delete_after_run: false,
        created_at: now,
        next_run: now,
        last_run: None,
        last_status: None,
        last_output: None,
    }
}

const WORKFLOW_SELF_HEAL_MAX_ATTEMPTS: usize = 1;
const WORKFLOW_TEMPLATE_AGENT_TIMEOUT_SECS: u64 = 180;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct WorkflowEditableFileStamp {
    size: u64,
    modified_secs: u64,
}

fn workflow_editable_file_stamp(path: &StdPath) -> Option<WorkflowEditableFileStamp> {
    let meta = std::fs::metadata(path).ok()?;
    let modified = meta
        .modified()
        .ok()?
        .duration_since(UNIX_EPOCH)
        .ok()?
        .as_secs();
    Some(WorkflowEditableFileStamp {
        size: meta.len(),
        modified_secs: modified,
    })
}

fn capture_workflow_editable_file_stamps(
    workspace_dir: &StdPath,
    workflow: &FeedWorkflowDefinition,
) -> HashMap<String, Option<WorkflowEditableFileStamp>> {
    let mut out = HashMap::with_capacity(workflow.editable_files.len());
    for rel in &workflow.editable_files {
        let abs = workspace_dir.join(rel);
        out.insert(rel.to_string(), workflow_editable_file_stamp(&abs));
    }
    out
}

fn changed_workflow_editable_files(
    before: &HashMap<String, Option<WorkflowEditableFileStamp>>,
    after: &HashMap<String, Option<WorkflowEditableFileStamp>>,
) -> Vec<String> {
    let mut changed = Vec::new();
    for (path, before_stamp) in before {
        let after_stamp = after.get(path).copied().flatten();
        if *before_stamp != after_stamp {
            changed.push(path.clone());
        }
    }
    changed
}

fn maybe_apply_workflow_run_quickfix(
    workspace_dir: &StdPath,
    workflow: &FeedWorkflowDefinition,
    error_text: &str,
) -> Result<Option<String>> {
    let lowered = error_text.to_ascii_lowercase();
    let is_prompt_arg_failure =
        lowered.contains("unrecognized arguments") && lowered.contains("--prompt");
    if !is_prompt_arg_failure {
        return Ok(None);
    }

    let script_rel = workflow.script_path.trim_start_matches('/');
    if script_rel.is_empty() || !script_rel.ends_with(".py") {
        return Ok(None);
    }
    if !workflow
        .editable_files
        .iter()
        .any(|path| path.trim_start_matches('/') == script_rel)
    {
        return Ok(None);
    }

    let script_abs = workspace_dir.join(script_rel);
    if !script_abs.exists() {
        return Ok(None);
    }

    let script_content = std::fs::read_to_string(&script_abs).with_context(|| {
        format!(
            "failed to read workflow script for deterministic quick fix {}",
            script_abs.display()
        )
    })?;
    if script_content.contains("\"--prompt\"") || script_content.contains("'--prompt'") {
        return Ok(None);
    }

    let prompt_default = if script_content.contains("USER_PROMPT") {
        "USER_PROMPT"
    } else {
        "\"\""
    };
    let prompt_arg_line = format!("    parser.add_argument(\"--prompt\", default={prompt_default})\n");
    let insertion_anchors = [
        "    parser.add_argument(\"--random-count\", type=int, default=1)\n",
        "    parser.add_argument(\"--days\", type=int, default=7)\n",
        "    parser = argparse.ArgumentParser(description=\"Generated workflow bot script\")\n",
    ];

    let mut patched_content = None;
    for anchor in insertion_anchors {
        if let Some(pos) = script_content.find(anchor) {
            let insert_at = pos + anchor.len();
            let mut next = String::with_capacity(script_content.len() + prompt_arg_line.len());
            next.push_str(&script_content[..insert_at]);
            next.push_str(&prompt_arg_line);
            next.push_str(&script_content[insert_at..]);
            patched_content = Some(next);
            break;
        }
    }

    let Some(next_content) = patched_content else {
        return Ok(None);
    };

    std::fs::write(&script_abs, next_content).with_context(|| {
        format!(
            "failed to write workflow script quick fix for {}",
            script_abs.display()
        )
    })?;

    Ok(Some(format!(
        "Applied deterministic quick fix: added `--prompt` CLI argument support to `{script_rel}`."
    )))
}

fn workflow_self_heal_prompt(
    workflow: &FeedWorkflowDefinition,
    bot_name: &str,
    command: &str,
    error_text: &str,
    attempt: usize,
    max_attempts: usize,
) -> String {
    let mut prompt = String::new();
    prompt.push_str(
        "You are the workflow supervisor. A workflow execution failed and must be self-healed.\n\n",
    );
    prompt.push_str("## Workflow\n");
    prompt.push_str(&format!("- Bot: {bot_name}\n"));
    prompt.push_str(&format!("- Key: {}\n", workflow.key));
    prompt.push_str(&format!("- Target command: `{command}`\n"));
    prompt.push_str(&format!(
        "- Attempt: {attempt}/{max_attempts}\n\n"
    ));

    prompt.push_str("## Failure Output\n");
    prompt.push_str("```text\n");
    prompt.push_str(error_text.trim());
    prompt.push_str("\n```\n\n");

    prompt.push_str("## Allowed Files (strict)\n");
    for file in &workflow.editable_files {
        prompt.push_str(&format!("- `{file}`\n"));
    }
    prompt.push('\n');

    prompt.push_str("## Constraints\n");
    prompt.push_str("- Edit only allowed files.\n");
    prompt.push_str("- Keep behavior deterministic and production-safe.\n");
    prompt.push_str(&format!(
        "- Keep feed output rooted under `{}`.\n",
        workflow.output_prefix
    ));
    prompt.push_str("- Make minimal focused edits that fix the observed failure.\n");
    prompt.push_str("- You must apply direct file edits to at least one allowed file.\n");
    prompt.push_str("- Do not introduce new dependencies.\n\n");

    prompt.push_str("After edits, reply with a concise summary of changed files and why.\n");
    prompt
}

async fn try_self_heal_workflow_run(
    state: &AppState,
    workflow: &FeedWorkflowDefinition,
    workflow_key: &str,
    bot_name: &str,
    command: &str,
    thread_id: &str,
    user_id: &str,
    initial_error: &str,
    workspace_dir: &StdPath,
) -> Option<String> {
    let mut last_error = initial_error.to_string();
    let config = state.config.lock().clone();

    for attempt in 1..=WORKFLOW_SELF_HEAL_MAX_ATTEMPTS {
        match maybe_apply_workflow_run_quickfix(workspace_dir, workflow, &last_error) {
            Ok(Some(message)) => {
                let _ = local_store::create_chat_message(
                    workspace_dir,
                    thread_id,
                    "assistant",
                    &message,
                    "done",
                    "workflow-quickfix",
                    Some(user_id),
                    None,
                );

                let retry_job = build_manual_workflow_job(workflow_key, bot_name, command.to_string());
                let (retry_success, retry_output) =
                    crate::cron::scheduler::execute_job_now(&config, &retry_job).await;
                let retry_trimmed = truncate_with_ellipsis(retry_output.trim(), 4000);
                if retry_success {
                    let detail = if retry_trimmed.is_empty() {
                        "Workflow run completed after quick fix.".to_string()
                    } else {
                        format!("Workflow run completed after quick fix.\n\n{retry_trimmed}")
                    };
                    return Some(detail);
                }

                last_error = if retry_trimmed.is_empty() {
                    "Workflow run failed after deterministic quick fix.".to_string()
                } else {
                    retry_trimmed
                };
            }
            Ok(None) => {}
            Err(err) => {
                let err_text = truncate_with_ellipsis(
                    &format!("quick fix failed before self-heal: {err:#}"),
                    2000,
                );
                let _ = local_store::create_chat_message(
                    workspace_dir,
                    thread_id,
                    "assistant",
                    "",
                    "error",
                    "workflow-quickfix",
                    Some(user_id),
                    Some(&err_text),
                );
                last_error = err_text;
            }
        }

        let start_msg = format!(
            "Run failed. Starting self-heal attempt {attempt}/{WORKFLOW_SELF_HEAL_MAX_ATTEMPTS}..."
        );
        let _ = local_store::create_chat_message(
            workspace_dir,
            thread_id,
            "assistant",
            &start_msg,
            "processing",
            "workflow-supervisor",
            Some(user_id),
            None,
        );

        let prompt = workflow_self_heal_prompt(
            workflow,
            bot_name,
            command,
            &last_error,
            attempt,
            WORKFLOW_SELF_HEAL_MAX_ATTEMPTS,
        );
        let before_stamps = capture_workflow_editable_file_stamps(workspace_dir, workflow);

        let channel_ctx = crate::channels::ChannelExecutionContext::new(
            "local",
            thread_id.to_string(),
            Some(thread_id.to_string()),
        );
        let heal_result = crate::channels::with_channel_execution_context(
            channel_ctx,
            crate::agent::process_message(config.clone(), &prompt),
        )
        .await;

        match heal_result {
            Ok(reply) => {
                let after_stamps = capture_workflow_editable_file_stamps(workspace_dir, workflow);
                let changed_files = changed_workflow_editable_files(&before_stamps, &after_stamps);
                if changed_files.is_empty() {
                    let reply_preview = truncate_with_ellipsis(reply.trim(), 600);
                    let no_edit_error = if reply_preview.is_empty() {
                        "Self-heal attempt completed but did not modify any allowed files."
                            .to_string()
                    } else {
                        format!(
                            "Self-heal attempt completed but did not modify any allowed files. \
Agent reply preview: {reply_preview}"
                        )
                    };
                    let _ = local_store::create_chat_message(
                        workspace_dir,
                        thread_id,
                        "assistant",
                        "",
                        "error",
                        "workflow-supervisor",
                        Some(user_id),
                        Some(&no_edit_error),
                    );
                    last_error = no_edit_error;
                    continue;
                }

                let reply_text = if reply.trim().is_empty() {
                    format!(
                        "Self-heal attempt {attempt} applied file changes.\n\nEdited files:\n- {}",
                        changed_files.join("\n- ")
                    )
                } else {
                    format!(
                        "{}\n\nEdited files:\n- {}",
                        reply.trim(),
                        changed_files.join("\n- ")
                    )
                };
                let _ = local_store::create_chat_message(
                    workspace_dir,
                    thread_id,
                    "assistant",
                    &reply_text,
                    "done",
                    "workflow-supervisor",
                    Some(user_id),
                    None,
                );
            }
            Err(err) => {
                let err_text = truncate_with_ellipsis(&format!("{err:#}"), 2000);
                let _ = local_store::create_chat_message(
                    workspace_dir,
                    thread_id,
                    "assistant",
                    "",
                    "error",
                    "workflow-supervisor",
                    Some(user_id),
                    Some(&err_text),
                );
                last_error = err_text;
                continue;
            }
        }

        let retry_job = build_manual_workflow_job(workflow_key, bot_name, command.to_string());
        let (retry_success, retry_output) =
            crate::cron::scheduler::execute_job_now(&config, &retry_job).await;
        let retry_trimmed = truncate_with_ellipsis(retry_output.trim(), 4000);
        if retry_success {
            let detail = if retry_trimmed.is_empty() {
                "Workflow run completed after self-heal.".to_string()
            } else {
                format!("Workflow run completed after self-heal.\n\n{retry_trimmed}")
            };
            return Some(detail);
        }

        last_error = if retry_trimmed.is_empty() {
            "Workflow run failed after self-heal retry.".to_string()
        } else {
            retry_trimmed
        };
    }

    None
}

async fn run_local_agent_prompt_in_thread(
    state: &AppState,
    thread_id: &str,
    prompt: &str,
) -> anyhow::Result<String> {
    let channel_ctx = crate::channels::ChannelExecutionContext::new(
        "local",
        thread_id.to_string(),
        Some(thread_id.to_string()),
    );
    let config = state.config.lock().clone();
    crate::channels::with_channel_execution_context(
        channel_ctx,
        crate::agent::process_message(config, prompt),
    )
    .await
}

fn queue_workflow_run(
    state: AppState,
    workflow_key: String,
    bot_name: String,
    command: String,
    source: &'static str,
) -> Result<String> {
    let workspace_dir = state.config.lock().workspace_dir.clone();
    let thread_id = format!("workflow:{workflow_key}");
    let user_content = format!(
        "[run] Triggered {} for {} using command: {}",
        source, bot_name, command
    );

    let user_record = local_store::create_chat_message(
        &workspace_dir,
        &thread_id,
        "user",
        &user_content,
        "pending",
        source,
        None,
        None,
    )?;
    let user_id = user_record
        .get("id")
        .and_then(serde_json::Value::as_str)
        .unwrap_or("")
        .to_string();

    let state_for_worker = state.clone();
    let workspace_for_worker = workspace_dir.clone();
    let thread_id_for_worker = thread_id.clone();
    let user_id_for_worker = user_id.clone();
    let workflow_key_for_worker = workflow_key.clone();
    let bot_name_for_worker = bot_name.clone();
    let command_for_worker = command.clone();
    tokio::spawn(async move {
        if let Err(err) =
            local_store::patch_chat_status(
                &workspace_for_worker,
                &user_id_for_worker,
                "processing",
                None,
            )
        {
            tracing::warn!("Failed to update workflow-run status to processing: {err}");
        }

        let config = state_for_worker.config.lock().clone();
        let job = build_manual_workflow_job(
            &workflow_key_for_worker,
            &bot_name_for_worker,
            command_for_worker.clone(),
        );
        let (success, output) = crate::cron::scheduler::execute_job_now(&config, &job).await;
        let output_trimmed = crate::util::truncate_with_ellipsis(output.trim(), 4000);

        if success {
            let reply = if output_trimmed.is_empty() {
                "Workflow run completed.".to_string()
            } else {
                output_trimmed
            };
            if let Err(err) = local_store::create_chat_message(
                &workspace_for_worker,
                &thread_id_for_worker,
                "assistant",
                &reply,
                "done",
                "workflow-runner",
                Some(&user_id_for_worker),
                None,
            ) {
                tracing::warn!("Failed to persist workflow-run success reply: {err}");
            }
            if let Err(err) = local_store::patch_chat_status(
                &workspace_for_worker,
                &user_id_for_worker,
                "done",
                None,
            ) {
                tracing::warn!("Failed to mark workflow-run as done: {err}");
            }
        } else {
            let error_text = if output_trimmed.is_empty() {
                "Workflow run failed.".to_string()
            } else {
                output_trimmed
            };
            let workflow_store =
                load_feed_workflow_settings_store(&workspace_for_worker).unwrap_or_default();
            let healed_output = if let Some(workflow) =
                workflow_definition_by_key(&workflow_store, &workflow_key_for_worker)
            {
                if let Err(err) = local_store::patch_chat_status(
                    &workspace_for_worker,
                    &user_id_for_worker,
                    "processing",
                    None,
                ) {
                    tracing::warn!(
                        "Failed to mark workflow-run as processing before self-heal: {err}"
                    );
                }

                try_self_heal_workflow_run(
                    &state_for_worker,
                    &workflow,
                    &workflow_key_for_worker,
                    &bot_name_for_worker,
                    &command_for_worker,
                    &thread_id_for_worker,
                    &user_id_for_worker,
                    &error_text,
                    &workspace_for_worker,
                )
                .await
            } else {
                None
            };

            if let Some(detail) = healed_output {
                let _ = local_store::create_chat_message(
                    &workspace_for_worker,
                    &thread_id_for_worker,
                    "assistant",
                    &detail,
                    "done",
                    "workflow-runner",
                    Some(&user_id_for_worker),
                    None,
                );
                if let Err(err) = local_store::patch_chat_status(
                    &workspace_for_worker,
                    &user_id_for_worker,
                    "done",
                    None,
                ) {
                    tracing::warn!("Failed to mark workflow-run as done after self-heal: {err}");
                }
            } else {
                let final_error = format!("Workflow run failed.\n\n{error_text}");
                let _ = local_store::create_chat_message(
                    &workspace_for_worker,
                    &thread_id_for_worker,
                    "assistant",
                    "",
                    "error",
                    "workflow-runner",
                    Some(&user_id_for_worker),
                    Some(&final_error),
                );
                if let Err(err) = local_store::patch_chat_status(
                    &workspace_for_worker,
                    &user_id_for_worker,
                    "error",
                    Some(&final_error),
                ) {
                    tracing::warn!("Failed to mark workflow-run as error: {err}");
                }
            }
        }
    });

    Ok(thread_id)
}

fn sanitize_workflow_key(raw: &str) -> String {
    let mut out = String::with_capacity(raw.len());
    for ch in raw.chars() {
        if ch.is_ascii_alphanumeric() {
            out.push(ch.to_ascii_lowercase());
        } else if matches!(ch, '_' | '-' | ' ') {
            out.push('_');
        }
    }

    let collapsed = out
        .split('_')
        .filter(|token| !token.is_empty())
        .collect::<Vec<_>>()
        .join("_");
    if collapsed.is_empty() {
        "workflow".to_string()
    } else {
        collapsed
    }
}

const WORKFLOW_BOT_CREATION_SKILL_REL_PATH: &str = "skills/workflow_bot_creation/SKILL.md";

fn ensure_workflow_bot_creation_skill(workspace_dir: &StdPath) -> Result<String> {
    let abs = workspace_dir.join(WORKFLOW_BOT_CREATION_SKILL_REL_PATH);
    if !abs.exists() {
        if let Some(parent) = abs.parent() {
            std::fs::create_dir_all(parent).with_context(|| {
                format!(
                    "failed to create workflow bot creation skill directory {}",
                    parent.display()
                )
            })?;
        }
        std::fs::write(
            &abs,
            include_str!("../../skills/workflow_bot_creation/SKILL.md"),
        )
        .with_context(|| format!("failed to write workflow bot creation skill {}", abs.display()))?;
    }
    std::fs::read_to_string(&abs)
        .with_context(|| format!("failed to read workflow bot creation skill {}", abs.display()))
}

fn render_workflow_script_stub(source_kind: &str, output_dir: &str, user_prompt: &str) -> String {
    let output_literal =
        serde_json::to_string(output_dir.trim()).unwrap_or_else(|_| "\"posts/workflow\"".to_string());
    let user_prompt_literal =
        serde_json::to_string(user_prompt.trim()).unwrap_or_else(|_| "\"\"".to_string());
    let default_source_root = if source_kind == "audio" {
        "journals/media/audio"
    } else {
        "journals/text"
    };
    let source_root_literal = serde_json::to_string(default_source_root).unwrap_or_else(|_| "\"journals/text\"".to_string());

    format!(
        "#!/usr/bin/env python3\n\
from __future__ import annotations\n\
\n\
import argparse\n\
import datetime as dt\n\
import json\n\
import random\n\
from pathlib import Path\n\
\n\
DEFAULT_SOURCE_ROOT = {source_root_literal}\n\
DEFAULT_OUTPUT_DIR = {output_literal}\n\
USER_PROMPT = {user_prompt_literal}\n\
\n\
def parse_args() -> argparse.Namespace:\n\
    parser = argparse.ArgumentParser(description=\"Generated workflow bot script\")\n\
    parser.add_argument(\"--mode\", choices=[\"date_range\", \"random\"], default=\"date_range\")\n\
    parser.add_argument(\"--days\", type=int, default=7)\n\
    parser.add_argument(\"--random-count\", type=int, default=1)\n\
    parser.add_argument(\"--prompt\", default=USER_PROMPT)\n\
    parser.add_argument(\"--workspace\", default=\".\")\n\
    parser.add_argument(\"--source-root\", default=DEFAULT_SOURCE_ROOT)\n\
    parser.add_argument(\"--output-dir\", default=DEFAULT_OUTPUT_DIR)\n\
    parser.add_argument(\"--seed\", type=int, default=None)\n\
    return parser.parse_args()\n\
\n\
def collect_files(root: Path) -> list[Path]:\n\
    if not root.exists():\n\
        return []\n\
    files = [path for path in root.rglob(\"*\") if path.is_file()]\n\
    files.sort(key=lambda p: p.stat().st_mtime, reverse=True)\n\
    return files\n\
\n\
def select_files(files: list[Path], args: argparse.Namespace) -> list[Path]:\n\
    if not files:\n\
        return []\n\
    if args.mode == \"random\":\n\
        target = max(1, min(args.random_count, len(files)))\n\
        rng = random.Random(args.seed)\n\
        picked = rng.sample(files, target)\n\
        picked.sort(key=lambda p: p.stat().st_mtime, reverse=True)\n\
        return picked\n\
\n\
    now = dt.datetime.now(dt.timezone.utc)\n\
    start = now - dt.timedelta(days=max(0, args.days))\n\
    selected = []\n\
    for path in files:\n\
        modified = dt.datetime.fromtimestamp(path.stat().st_mtime, tz=dt.timezone.utc)\n\
        if modified >= start:\n\
            selected.append(path)\n\
    return selected\n\
\n\
def rel(path: Path, workspace: Path) -> str:\n\
    return str(path.resolve().relative_to(workspace.resolve())).replace('\\\\', '/')\n\
\n\
def main() -> int:\n\
    args = parse_args()\n\
    workspace = Path(args.workspace).resolve()\n\
    source_root = (workspace / args.source_root).resolve()\n\
    output_dir = (workspace / args.output_dir).resolve()\n\
    posts_root = (workspace / \"posts\").resolve()\n\
    if not str(output_dir).startswith(str(posts_root)):\n\
        print(json.dumps({{\"ok\": False, \"error\": \"output-dir must be under posts/\"}}))\n\
        return 2\n\
\n\
    files = collect_files(source_root)\n\
    selected = select_files(files, args)\n\
    output_dir.mkdir(parents=True, exist_ok=True)\n\
    stamp = dt.datetime.now(dt.timezone.utc).strftime('%Y%m%d_%H%M%S')\n\
    out_path = output_dir / f\"{{stamp}}_summary.md\"\n\
\n\
    lines = [\n\
        f\"{{args.prompt}}\",\n\
        \"\",\n\
        \"## Selected Journal Files\",\n\
        \"\",\n\
    ]\n\
    if not selected:\n\
        lines.append(\"- none\")\n\
    for path in selected:\n\
        lines.append(f\"- `{{rel(path, workspace)}}`\")\n\
\n\
    lines.append(\"\")\n\
    lines.append(\"## Notes\")\n\
    lines.append(\"\")\n\
    lines.append(\"Edit this script to implement specialized behavior for this workflow bot.\")\n\
    out_path.write_text(\"\\n\".join(lines) + \"\\n\", encoding=\"utf-8\")\n\
\n\
    print(json.dumps({{\"ok\": True, \"output\": rel(out_path, workspace), \"selected\": [rel(p, workspace) for p in selected]}}))\n\
    return 0\n\
\n\
if __name__ == \"__main__\":\n\
    raise SystemExit(main())\n"
    )
}

fn render_workflow_creation_prompt(
    workflow_name: &str,
    workflow_key: &str,
    workflow_bot: &str,
    source_kind: &str,
    source_root: &str,
    script_rel: &str,
    skill_rel: &str,
    output_dir_rel: &str,
    user_prompt: &str,
    creation_skill_markdown: &str,
    script_body: &str,
) -> String {
    let mut prompt = String::new();
    prompt.push_str("Use the workflow bot creation skill below to implement a new workflow bot.\n\n");
    prompt.push_str(&format!(
        "Skill file: `{WORKFLOW_BOT_CREATION_SKILL_REL_PATH}`\n\n"
    ));
    prompt.push_str("## Bot Creation Skill (verbatim)\n");
    prompt.push_str("```markdown\n");
    prompt.push_str(creation_skill_markdown.trim());
    prompt.push_str("\n```\n\n");

    prompt.push_str("## Workflow Request\n");
    prompt.push_str(&format!("- Name: {workflow_name}\n"));
    prompt.push_str(&format!("- Key: {workflow_key}\n"));
    prompt.push_str(&format!("- Bot: {workflow_bot}\n"));
    prompt.push_str(&format!("- Source kind: {source_kind}\n"));
    prompt.push_str(&format!("- Source root: `{source_root}`\n"));
    prompt.push_str(&format!("- User intent: \"{}\"\n\n", user_prompt.trim()));

    prompt.push_str("## Required Files\n");
    prompt.push_str(&format!("- Script (must exist): `{script_rel}`\n"));
    prompt.push_str(&format!("- Skill (must exist): `{skill_rel}`\n"));
    prompt.push_str(&format!("- Output directory root: `{output_dir_rel}`\n\n"));

    prompt.push_str("## Script File Payload (authoritative)\n");
    prompt.push_str("Use this full script content as the source template, then overwrite the script file with your updated implementation.\n");
    prompt.push_str("Do not respond with only a file path reference.\n\n");
    prompt.push_str(&format!("### `{script_rel}` initial content\n"));
    prompt.push_str("```python\n");
    prompt.push_str(script_body.trim());
    prompt.push_str("\n```\n\n");

    prompt.push_str("## Hard Requirements\n");
    prompt.push_str("- The script must support: `--mode`, `--days`, `--random-count`.\n");
    prompt.push_str("- `--mode` values: `date_range` and `random`.\n");
    prompt.push_str("- Script must read journal context from the journal folder (`journals/...`).\n");
    prompt.push_str("- Script must publish outputs under the posts folder (`posts/...`).\n");
    prompt.push_str("- Keep execution deterministic for file selection behavior.\n");
    prompt.push_str("- Keep edits minimal, production-safe, and dependency-light.\n");
    prompt.push_str("- Do not include metadata headers in the output file. Only output the generated content. If generating multiple distinct items, save each as a separate file.\n");
    prompt.push_str(&format!("- Replace `{script_rel}` with your full updated script content (not a patch description).\n"));
    prompt.push_str("- Use the `file_write` tool to save your changes directly to the file.\n");
    prompt.push_str("- Do direct file edits. Do not just describe code.\n\n");
    prompt.push_str("- You must modify the script implementation from the initial template stub.\n\n");

    prompt.push_str("After editing, reply with a concise summary of modified files and behavior.\n");
    prompt
}

fn validate_workflow_script_contract(script_abs: &StdPath) -> Result<()> {
    let raw = std::fs::read_to_string(script_abs)
        .with_context(|| format!("failed to read generated script {}", script_abs.display()))?;
    let required_fragments = [
        "--mode",
        "date_range",
        "random",
        "--days",
        "--random-count",
        "journals/",
        "posts/",
    ];
    for fragment in required_fragments {
        if !raw.contains(fragment) {
            anyhow::bail!(
                "generated workflow script is missing required fragment `{fragment}` (file: {})",
                script_abs.display()
            );
        }
    }
    Ok(())
}

fn render_template_skill_markdown(
    skill_name: &str,
    source_kind: &str,
    script_rel_path: &str,
    output_dir: &str,
) -> String {
    let source_hint = if source_kind == "audio" {
        "`journals/media/audio` (with transcriptions in `journals/text/transcriptions`)"
    } else {
        "`journals/text`"
    };
    format!(
        "# {skill_name} Workflow\n\n\
Use this skill to generate feed-ready posts from {source_hint}.\n\n\
## Script\n\n\
- `{script_rel_path}`\n\n\
## Default Command\n\n\
```bash\n\
workspace-script {script_rel_path} --mode date_range --days 7\n\
```\n\n\
## Output\n\n\
- `{output_dir}`\n"
    )
}

fn workflow_comment_prompt(
    workflow: &FeedWorkflowDefinition,
    feed_item_path: &str,
    comment: &str,
) -> String {
    let mut prompt = String::from(
        "Apply this workflow modification request by editing files in the workspace.\n\n",
    );
    prompt.push_str("## Request Context\n");
    prompt.push_str(&format!("- Workflow: {} ({})\n", workflow.bot_name, workflow.key));
    prompt.push_str(&format!("- Feed item path: `{}`\n", feed_item_path));
    prompt.push_str(&format!("- User comment: \"{}\"\n\n", comment.trim()));

    prompt.push_str("## Allowed Files\n");
    for file in &workflow.editable_files {
        prompt.push_str(&format!("- `{file}`\n"));
    }
    prompt.push('\n');

    prompt.push_str("## Guardrails\n");
    prompt.push_str("- Edit only files from the allowed list.\n");
    prompt.push_str("- Keep behavior deterministic and production-safe.\n");
    prompt.push_str(&format!(
        "- Keep feed output rooted under `{}`.\n",
        workflow.output_prefix
    ));
    prompt.push_str("- Do not return full code in chat; make direct file edits.\n");
    prompt.push_str("- Keep changes minimal and focused on the user request.\n\n");

    prompt.push_str("After editing, reply with a concise summary of what changed.\n");
    prompt
}

fn maybe_apply_workflow_comment_quickfix(
    _workspace_dir: &StdPath,
    _workflow: &FeedWorkflowDefinition,
    _feed_item_path: &str,
    _comment: &str,
) -> Result<Option<String>> {
    Ok(None)
}

async fn handle_chat_list(
    State(state): State<AppState>,
    headers: HeaderMap,
    Query(query): Query<ChatListQuery>,
) -> impl IntoResponse {
    if let Some(err) = pairing_auth_error(&state, &headers, "Chat API") {
        return err;
    }

    let workspace_dir = state.config.lock().workspace_dir.clone();
    let thread_id = query
        .thread_id
        .as_deref()
        .map(str::trim)
        .filter(|v| !v.is_empty())
        .unwrap_or("default");
    let limit = query.limit.unwrap_or(200).clamp(1, 500);

    match local_store::list_chat_messages(&workspace_dir, thread_id, limit) {
        Ok(items) => (StatusCode::OK, Json(serde_json::json!({ "items": items }))),
        Err(e) => {
            tracing::warn!("Chat API list failed: {e}");
            let err = serde_json::json!({"error": e.to_string()});
            (StatusCode::INTERNAL_SERVER_ERROR, Json(err))
        }
    }
}

async fn handle_chat_send(
    State(state): State<AppState>,
    headers: HeaderMap,
    Json(body): Json<ChatSendBody>,
) -> impl IntoResponse {
    if let Some(err) = pairing_auth_error(&state, &headers, "Chat API") {
        return err;
    }

    let thread_id = body.thread_id.trim();
    let content = body.content.trim();
    if thread_id.is_empty() || content.is_empty() {
        let err = serde_json::json!({"error": "threadId and content are required"});
        return (StatusCode::BAD_REQUEST, Json(err));
    }

    let workspace_dir = state.config.lock().workspace_dir.clone();
    match local_store::create_chat_message(
        &workspace_dir,
        thread_id,
        "user",
        content,
        "pending",
        "gateway-ui",
        None,
        None,
    ) {
        Ok(record) => {
            if state.auto_save {
                let key = format!("chat_{}_{}", thread_id, Uuid::new_v4());
                let mem = state.mem.clone();
                let content_copy = content.to_string();
                tokio::spawn(async move {
                    let _ = mem
                        .store(&key, &content_copy, MemoryCategory::Conversation, None)
                        .await;
                });
            }

            let user_id = record
                .get("id")
                .and_then(serde_json::Value::as_str)
                .unwrap_or("")
                .to_string();
            let thread_id_owned = thread_id.to_string();
            let content_owned = content.to_string();
            let state_for_worker = state.clone();
            let workspace_for_worker = workspace_dir.clone();
            tokio::spawn(async move {
                if let Err(err) =
                    local_store::patch_chat_status(&workspace_for_worker, &user_id, "processing", None)
                {
                    tracing::warn!("Chat worker status update failed: {err}");
                }

                let channel_ctx = crate::channels::ChannelExecutionContext::new(
                    "local",
                    thread_id_owned.clone(),
                    Some(thread_id_owned.clone()),
                );
                let config = state_for_worker.config.lock().clone();
                let result = crate::channels::with_channel_execution_context(
                    channel_ctx,
                    crate::agent::process_message(config, &content_owned),
                )
                .await;

                match result {
                    Ok(reply) => {
                        let reply_text = if reply.trim().is_empty() {
                            "(empty response)"
                        } else {
                            reply.trim()
                        };
                        if let Err(err) = local_store::create_chat_message(
                            &workspace_for_worker,
                            &thread_id_owned,
                            "assistant",
                            reply_text,
                            "done",
                            "slowclaw",
                            Some(&user_id),
                            None,
                        ) {
                            tracing::warn!("Chat worker failed to save assistant reply: {err}");
                        }
                        if let Err(err) =
                            local_store::patch_chat_status(&workspace_for_worker, &user_id, "done", None)
                        {
                            tracing::warn!("Chat worker failed to mark done: {err}");
                        }
                        if state_for_worker.auto_save {
                            let key = format!("chat_{}_{}", thread_id_owned, Uuid::new_v4());
                            let _ = state_for_worker
                                .mem
                                .store(&key, reply_text, MemoryCategory::Conversation, None)
                                .await;
                        }
                    }
                    Err(err) => {
                        let err_text =
                            crate::util::truncate_with_ellipsis(&format!("{err:#}"), 2000);
                        let _ = local_store::create_chat_message(
                            &workspace_for_worker,
                            &thread_id_owned,
                            "assistant",
                            "",
                            "error",
                            "slowclaw",
                            Some(&user_id),
                            Some(&err_text),
                        );
                        if let Err(update_err) = local_store::patch_chat_status(
                            &workspace_for_worker,
                            &user_id,
                            "error",
                            Some(&err_text),
                        ) {
                            tracing::warn!("Chat worker failed to persist error status: {update_err}");
                        }
                    }
                }
            });

            (StatusCode::OK, Json(record))
        }
        Err(e) => {
            tracing::warn!("Chat API send failed: {e}");
            let err = serde_json::json!({"error": e.to_string()});
            (StatusCode::INTERNAL_SERVER_ERROR, Json(err))
        }
    }
}

async fn handle_feed_workflow_settings(
    State(state): State<AppState>,
    headers: HeaderMap,
) -> impl IntoResponse {
    if let Some(err) = pairing_auth_error(&state, &headers, "Feed workflow settings") {
        return err;
    }

    let workspace_dir = state.config.lock().workspace_dir.clone();
    let config_snapshot = state.config.lock().clone();

    let store = match load_feed_workflow_settings_store(&workspace_dir) {
        Ok(store) => store,
        Err(err) => {
            tracing::warn!("Failed to load workflow settings store: {err}");
            return (
                StatusCode::INTERNAL_SERVER_ERROR,
                Json(serde_json::json!({"error": err.to_string()})),
            );
        }
    };

    let mut items = Vec::new();
    for workflow in workflow_definitions(&store) {
        let configured = store
            .workflows
            .get(&workflow.key)
            .map(|record| record.settings.clone())
            .unwrap_or_else(workflow_default_settings);
        let settings = normalize_workflow_settings(configured);

        let schedule_job = match select_primary_workflow_job(&config_snapshot, &workflow.key) {
            Ok(job) => job,
            Err(err) => {
                tracing::warn!("Failed to load cron state for {}: {err}", workflow.key);
                None
            }
        };

        items.push(workflow_settings_response_item(
            &workflow,
            settings,
            schedule_job.as_ref(),
        ));
    }

    (
        StatusCode::OK,
        Json(serde_json::json!({
            "items": items,
        })),
    )
}

async fn handle_feed_workflow_settings_update(
    State(state): State<AppState>,
    headers: HeaderMap,
    Json(body): Json<FeedWorkflowSettingsUpdateBody>,
) -> impl IntoResponse {
    if let Some(err) = pairing_auth_error(&state, &headers, "Feed workflow settings update") {
        return err;
    }

    let workflow_key = body.workflow_key.trim().to_ascii_lowercase();
    let workspace_dir = state.config.lock().workspace_dir.clone();
    let mut store = match load_feed_workflow_settings_store(&workspace_dir) {
        Ok(store) => store,
        Err(err) => {
            tracing::warn!("Failed to load workflow settings store for update: {err}");
            return (
                StatusCode::INTERNAL_SERVER_ERROR,
                Json(serde_json::json!({"error": err.to_string()})),
            );
        }
    };

    let Some(workflow) = workflow_definition_by_key(&store, &workflow_key) else {
        let err = serde_json::json!({
            "error": "unknown workflowKey",
            "supportedWorkflowKeys": store.workflows.keys().collect::<Vec<_>>(),
        });
        return (StatusCode::BAD_REQUEST, Json(err));
    };

    let Some(mut workflow_record) = store.workflows.get(&workflow.key).cloned() else {
        let err = serde_json::json!({"error": "workflow record missing"});
        return (StatusCode::BAD_REQUEST, Json(err));
    };
    let mut next = workflow_record.settings.clone();

    if let Some(raw_mode) = body.mode.as_deref() {
        let Some(parsed_mode) = FeedWorkflowMode::parse(raw_mode) else {
            let err = serde_json::json!({"error": "mode must be one of: date_range, random"});
            return (StatusCode::BAD_REQUEST, Json(err));
        };
        next.mode = parsed_mode;
    }
    if let Some(days) = body.days {
        next.days = days;
    }
    if let Some(random_count) = body.random_count {
        next.random_count = random_count;
    }
    if let Some(schedule_enabled) = body.schedule_enabled {
        next.schedule_enabled = schedule_enabled;
    }
    if let Some(schedule_cron) = body.schedule_cron {
        next.schedule_cron = schedule_cron;
    }
    if let Some(schedule_tz) = body.schedule_tz {
        next.schedule_tz = Some(schedule_tz);
    }
    if let Some(prompt) = body.prompt {
        next.prompt = Some(prompt);
    }

    next = normalize_workflow_settings(next);
    if next.schedule_enabled && next.schedule_cron.is_empty() {
        let err = serde_json::json!({"error": "scheduleCron is required when scheduleEnabled=true"});
        return (StatusCode::BAD_REQUEST, Json(err));
    }

    let config_snapshot = state.config.lock().clone();
    let schedule_job = match upsert_workflow_schedule(&config_snapshot, &workflow, &next) {
        Ok(job) => job,
        Err(err) => {
            tracing::warn!("Workflow schedule update failed for {}: {err}", workflow.key);
            let payload = serde_json::json!({
                "error": format!("{err:#}"),
            });
            return (StatusCode::BAD_REQUEST, Json(payload));
        }
    };

    workflow_record.settings = next.clone();
    store.workflows.insert(workflow.key.to_string(), workflow_record);
    if let Err(err) = save_feed_workflow_settings_store(&workspace_dir, &store) {
        tracing::warn!("Failed to persist workflow settings: {err}");
        return (
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(serde_json::json!({"error": err.to_string()})),
        );
    }

    let run_command = workflow_command_preview(&workflow, &next);
    let run_thread_id = match queue_workflow_run(
        state.clone(),
        workflow.key.to_string(),
        workflow.bot_name.to_string(),
        run_command,
        "workflow-settings-save",
    ) {
        Ok(thread_id) => Some(thread_id),
        Err(err) => {
            tracing::warn!("Failed to queue workflow run after settings save: {err}");
            None
        }
    };

    let item = workflow_settings_response_item(&workflow, next, schedule_job.as_ref());
    (
        StatusCode::OK,
        Json(serde_json::json!({
            "updated": true,
            "item": item,
            "runQueued": run_thread_id.is_some(),
            "runThreadId": run_thread_id,
        })),
    )
}

async fn handle_feed_workflow_run(
    State(state): State<AppState>,
    headers: HeaderMap,
    Json(body): Json<FeedWorkflowRunBody>,
) -> impl IntoResponse {
    if let Some(err) = pairing_auth_error(&state, &headers, "Feed workflow run") {
        return err;
    }

    let workflow_key = body.workflow_key.trim().to_ascii_lowercase();
    let workspace_dir = state.config.lock().workspace_dir.clone();
    let store = load_feed_workflow_settings_store(&workspace_dir).unwrap_or_default();
    let Some(workflow) = workflow_definition_by_key(&store, &workflow_key) else {
        let err = serde_json::json!({
            "error": "unknown workflowKey",
            "supportedWorkflowKeys": store.workflows.keys().collect::<Vec<_>>(),
        });
        return (StatusCode::BAD_REQUEST, Json(err));
    };

    let configured = store
        .workflows
        .get(&workflow.key)
        .map(|record| record.settings.clone())
        .unwrap_or_else(workflow_default_settings);
    let settings = normalize_workflow_settings(configured);
    let command = workflow_command_preview(&workflow, &settings);

    match queue_workflow_run(
        state.clone(),
        workflow.key.to_string(),
        workflow.bot_name.to_string(),
        command,
        "workflow-run-manual",
    ) {
        Ok(thread_id) => (
            StatusCode::OK,
            Json(serde_json::json!({
                "queued": true,
                "threadId": thread_id,
                "workflowKey": workflow.key,
                "workflowBot": workflow.bot_name,
            })),
        ),
        Err(err) => {
            tracing::warn!("Failed to queue manual workflow run: {err}");
            (
                StatusCode::INTERNAL_SERVER_ERROR,
                Json(serde_json::json!({"error": err.to_string()})),
            )
        }
    }
}

async fn handle_feed_workflow_template_create(
    State(state): State<AppState>,
    headers: HeaderMap,
    Json(body): Json<FeedWorkflowTemplateCreateBody>,
) -> impl IntoResponse {
    if let Some(err) = pairing_auth_error(&state, &headers, "Feed workflow template create") {
        return err;
    }

    let name = body.name.trim();
    if name.is_empty() {
        return (
            StatusCode::BAD_REQUEST,
            Json(serde_json::json!({"error": "name is required"})),
        );
    }

    let workflow_key = sanitize_workflow_key(name);
    let source_kind = body
        .source_kind
        .as_deref()
        .map(str::trim)
        .unwrap_or("text")
        .to_ascii_lowercase();
    let source_kind = if source_kind == "audio" { "audio" } else { "text" };

    let workflow_bot = body
        .bot_name
        .as_deref()
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(ToOwned::to_owned)
        .unwrap_or_else(|| default_workflow_bot_name(&workflow_key));
    let prompt = body
        .prompt
        .as_deref()
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .unwrap_or("Write in a clear, natural voice.");

    let default_mode = body
        .mode
        .as_deref()
        .and_then(FeedWorkflowMode::parse)
        .unwrap_or(FeedWorkflowMode::DateRange);
    let mut settings = FeedWorkflowSettings {
        mode: default_mode,
        days: body.days.unwrap_or(default_feed_workflow_days()),
        random_count: body.random_count.unwrap_or(default_feed_workflow_random_count()),
        schedule_enabled: body.schedule_enabled.unwrap_or(false),
        schedule_cron: body.schedule_cron.unwrap_or_else(default_workflow_schedule_cron),
        schedule_tz: body.schedule_tz,
        prompt: Some(prompt.to_string()),
    };
    settings = normalize_workflow_settings(settings);

    let workspace_dir = state.config.lock().workspace_dir.clone();
    let store = match load_feed_workflow_settings_store(&workspace_dir) {
        Ok(store) => store,
        Err(err) => {
            tracing::warn!("Failed to load workflow settings store for create: {err}");
            return (
                StatusCode::INTERNAL_SERVER_ERROR,
                Json(serde_json::json!({"error": err.to_string()})),
            );
        }
    };
    if workflow_definition_by_key(&store, &workflow_key).is_some() {
        return (
            StatusCode::CONFLICT,
            Json(serde_json::json!({"error": "workflow key already exists"})),
        );
    }

    let output_dir_rel = format!("posts/{workflow_key}");
    let script_rel = format!("scripts/{}_skill/run_{}.py", workflow_key, workflow_key);
    let skill_rel = format!("skills/{workflow_key}/SKILL.md");
    let script_abs = workspace_dir.join(&script_rel);
    let skill_abs = workspace_dir.join(&skill_rel);

    let script_body = render_workflow_script_stub(source_kind, &output_dir_rel, prompt);
    let skill_body = render_template_skill_markdown(name, source_kind, &script_rel, &output_dir_rel);

    if let Some(parent) = script_abs.parent() {
        if let Err(err) = std::fs::create_dir_all(parent) {
            return (
                StatusCode::INTERNAL_SERVER_ERROR,
                Json(serde_json::json!({"error": format!("failed to create script directory: {err}")})),
            );
        }
    }
    if let Some(parent) = skill_abs.parent() {
        if let Err(err) = std::fs::create_dir_all(parent) {
            return (
                StatusCode::INTERNAL_SERVER_ERROR,
                Json(serde_json::json!({"error": format!("failed to create skill directory: {err}")})),
            );
        }
    }
    if let Err(err) = std::fs::create_dir_all(workspace_dir.join(&output_dir_rel)) {
        return (
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(serde_json::json!({"error": format!("failed to create output directory: {err}")})),
        );
    }

    if let Err(err) = std::fs::write(&script_abs, &script_body) {
        return (
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(serde_json::json!({"error": format!("failed to write script: {err}")})),
        );
    }
    if let Err(err) = std::fs::write(&skill_abs, skill_body) {
        return (
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(serde_json::json!({"error": format!("failed to write skill: {err}")})),
        );
    }

    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let _ = std::fs::set_permissions(&script_abs, std::fs::Permissions::from_mode(0o755));
    }

    let creation_skill_markdown = match ensure_workflow_bot_creation_skill(&workspace_dir) {
        Ok(markdown) => markdown,
        Err(err) => {
            return (
                StatusCode::INTERNAL_SERVER_ERROR,
                Json(serde_json::json!({"error": format!("{err:#}")})),
            )
        }
    };
    let source_root = if source_kind == "audio" {
        "journals/media/audio"
    } else {
        "journals/text"
    };
    let creation_prompt = render_workflow_creation_prompt(
        name,
        &workflow_key,
        &workflow_bot,
        source_kind,
        source_root,
        &script_rel,
        &skill_rel,
        &output_dir_rel,
        prompt,
        &creation_skill_markdown,
        &script_body,
    );

    let creation_thread_id = format!("workflow:create:{workflow_key}");
    let creation_user_content = format!(
        "[create] name={name}; key={workflow_key}; script={script_rel}; output={output_dir_rel}; source={source_kind}"
    );
    let creation_user_record = match local_store::create_chat_message(
        &workspace_dir,
        &creation_thread_id,
        "user",
        &creation_user_content,
        "pending",
        "workflow-template-create",
        None,
        None,
    ) {
        Ok(record) => record,
        Err(err) => {
            tracing::warn!("Failed to persist workflow template create request: {err}");
            return (
                StatusCode::INTERNAL_SERVER_ERROR,
                Json(serde_json::json!({"error": err.to_string()})),
            );
        }
    };
    let creation_user_id = creation_user_record
        .get("id")
        .and_then(serde_json::Value::as_str)
        .unwrap_or("")
        .to_string();

    let run_now = body.run_now.unwrap_or(true);
    let output_prefix = format!("{output_dir_rel}/");
    let preview_def = FeedWorkflowDefinition {
        key: workflow_key.clone(),
        bot_name: workflow_bot.clone(),
        editable_files: vec![
            script_rel.clone(),
            skill_rel.clone(),
            WORKFLOW_BOT_CREATION_SKILL_REL_PATH.to_string(),
        ],
        output_prefix: output_prefix.clone(),
        script_path: script_rel.clone(),
    };
    let command_preview = workflow_command_preview(&preview_def, &settings);

    let state_for_worker = state.clone();
    let workspace_for_worker = workspace_dir.clone();
    let thread_id_for_worker = creation_thread_id.clone();
    let user_id_for_worker = creation_user_id.clone();
    let workflow_key_for_worker = workflow_key.clone();
    let workflow_bot_for_worker = workflow_bot.clone();
    let script_rel_for_worker = script_rel.clone();
    let skill_rel_for_worker = skill_rel.clone();
    let output_dir_for_worker = output_dir_rel.clone();
    let output_prefix_for_worker = output_prefix.clone();
    let settings_for_worker = settings.clone();
    let script_abs_for_worker = script_abs.clone();
    let script_body_for_worker = script_body.clone();
    let creation_prompt_for_worker = creation_prompt.clone();

    tokio::spawn(async move {
        let persist_error = |message: &str| {
            let _ = local_store::create_chat_message(
                &workspace_for_worker,
                &thread_id_for_worker,
                "assistant",
                "",
                "error",
                "workflow-template-create",
                Some(&user_id_for_worker),
                Some(message),
            );
            if let Err(update_err) = local_store::patch_chat_status(
                &workspace_for_worker,
                &user_id_for_worker,
                "error",
                Some(message),
            ) {
                tracing::warn!(
                    "Failed to persist workflow-template-create error status: {update_err}"
                );
            }
        };

        if let Err(err) = local_store::patch_chat_status(
            &workspace_for_worker,
            &user_id_for_worker,
            "processing",
            None,
        ) {
            tracing::warn!("Failed to mark workflow-template-create as processing: {err}");
        }

        let creation_result = tokio::time::timeout(
            Duration::from_secs(WORKFLOW_TEMPLATE_AGENT_TIMEOUT_SECS),
            run_local_agent_prompt_in_thread(
                &state_for_worker,
                &thread_id_for_worker,
                &creation_prompt_for_worker,
            ),
        )
        .await;
        let creation_reply = match creation_result {
            Ok(Ok(reply)) => reply,
            Ok(Err(err)) => {
                let err_text = truncate_with_ellipsis(
                    &format!("workflow bot creation agent failed: {err:#}"),
                    2000,
                );
                persist_error(&err_text);
                return;
            }
            Err(_) => {
                let err_text = format!(
                    "workflow bot creation agent timed out after {}s",
                    WORKFLOW_TEMPLATE_AGENT_TIMEOUT_SECS
                );
                persist_error(&err_text);
                return;
            }
        };

        if let Err(err) = validate_workflow_script_contract(&script_abs_for_worker) {
            let err_text = truncate_with_ellipsis(
                &format!("generated script failed workflow contract validation: {err:#}"),
                2000,
            );
            persist_error(&err_text);
            return;
        }
        let final_script = match std::fs::read_to_string(&script_abs_for_worker) {
            Ok(raw) => raw,
            Err(err) => {
                let err_text =
                    truncate_with_ellipsis(&format!("failed to read generated script: {err}"), 2000);
                persist_error(&err_text);
                return;
            }
        };
        if final_script.trim() == script_body_for_worker.trim() {
            persist_error(
                "workflow bot creation agent left the template script unchanged; creation aborted",
            );
            return;
        }

        let mut worker_store = match load_feed_workflow_settings_store(&workspace_for_worker) {
            Ok(store) => store,
            Err(err) => {
                let err_text = truncate_with_ellipsis(
                    &format!("failed to load workflow settings store: {err:#}"),
                    2000,
                );
                persist_error(&err_text);
                return;
            }
        };
        if workflow_definition_by_key(&worker_store, &workflow_key_for_worker).is_some() {
            persist_error("workflow key already exists");
            return;
        }

        let mut workflow_record = FeedWorkflowRecord {
            workflow_key: workflow_key_for_worker.clone(),
            workflow_bot: workflow_bot_for_worker.clone(),
            script_path: script_rel_for_worker.clone(),
            output_prefix: output_prefix_for_worker.clone(),
            editable_files: vec![
                script_rel_for_worker.clone(),
                skill_rel_for_worker.clone(),
                WORKFLOW_BOT_CREATION_SKILL_REL_PATH.to_string(),
            ],
            settings: settings_for_worker.clone(),
        };
        workflow_record = normalize_workflow_record(&workflow_key_for_worker, workflow_record);
        let workflow_def = feed_workflow_definition_from_record(&workflow_record);
        let command = workflow_command_preview(&workflow_def, &settings_for_worker);

        let config_snapshot = state_for_worker.config.lock().clone();
        if let Err(err) = upsert_workflow_schedule_with_command(
            &config_snapshot,
            &workflow_key_for_worker,
            &settings_for_worker,
            command.clone(),
        ) {
            let err_text = truncate_with_ellipsis(
                &format!("failed to upsert workflow schedule: {err:#}"),
                2000,
            );
            persist_error(&err_text);
            return;
        }

        worker_store
            .workflows
            .insert(workflow_key_for_worker.clone(), workflow_record);
        if let Err(err) = save_feed_workflow_settings_store(&workspace_for_worker, &worker_store) {
            let err_text = truncate_with_ellipsis(
                &format!("failed to persist workflow settings store: {err:#}"),
                2000,
            );
            persist_error(&err_text);
            return;
        }

        let run_thread_id = if run_now {
            match queue_workflow_run(
                state_for_worker.clone(),
                workflow_key_for_worker.clone(),
                workflow_bot_for_worker.clone(),
                command.clone(),
                "workflow-template-create",
            ) {
                Ok(thread_id) => Some(thread_id),
                Err(err) => {
                    tracing::warn!("Failed to queue workflow run after template creation: {err}");
                    None
                }
            }
        } else {
            None
        };

        let mut summary = format!(
            "Workflow `{}` ({}) created.\n\nScript: `{}`\nOutput: `{}`\n",
            workflow_bot_for_worker,
            workflow_key_for_worker,
            script_rel_for_worker,
            output_dir_for_worker
        );
        if let Some(thread_id) = &run_thread_id {
            summary.push_str(&format!("\nInitial run queued: `{thread_id}`\n"));
        } else if run_now {
            summary.push_str("\nInitial run requested, but queueing failed.\n");
        } else {
            summary.push_str("\nInitial run not requested.\n");
        }
        let reply_preview = truncate_with_ellipsis(creation_reply.trim(), 1200);
        if !reply_preview.is_empty() {
            summary.push_str("\nAgent summary:\n");
            summary.push_str(&reply_preview);
        }

        if let Err(err) = local_store::create_chat_message(
            &workspace_for_worker,
            &thread_id_for_worker,
            "assistant",
            &summary,
            "done",
            "workflow-template-create",
            Some(&user_id_for_worker),
            None,
        ) {
            tracing::warn!("Failed to persist workflow-template-create success message: {err}");
        }
        if let Err(err) =
            local_store::patch_chat_status(&workspace_for_worker, &user_id_for_worker, "done", None)
        {
            tracing::warn!("Failed to mark workflow-template-create as done: {err}");
        }
    });

    (
        StatusCode::OK,
        Json(serde_json::json!({
            "created": false,
            "queued": true,
            "threadId": creation_thread_id,
            "messageId": creation_user_id,
            "workflowKey": workflow_key,
            "workflowBot": workflow_bot,
            "scriptPath": script_rel,
            "skillPath": skill_rel,
            "outputDir": output_dir_rel,
            "outputPrefix": output_prefix,
            "commandPreview": command_preview,
            "scheduleJobId": serde_json::Value::Null,
            "runQueued": false,
            "runThreadId": serde_json::Value::Null,
            "creationSummary": "Workflow creation queued.",
        })),
    )
}

async fn handle_feed_workflow_comment(
    State(state): State<AppState>,
    headers: HeaderMap,
    Json(body): Json<FeedWorkflowCommentBody>,
) -> impl IntoResponse {
    if let Some(err) = pairing_auth_error(&state, &headers, "Feed workflow comment") {
        return err;
    }

    let requested_path = body.path.trim().trim_start_matches('/').to_string();
    let comment = body.comment.trim();
    if requested_path.is_empty() || comment.is_empty() {
        let err = serde_json::json!({"error": "path and comment are required"});
        return (StatusCode::BAD_REQUEST, Json(err));
    }
    if comment.chars().count() > 1500 {
        let err = serde_json::json!({"error": "comment is too long (max 1500 characters)"});
        return (StatusCode::BAD_REQUEST, Json(err));
    }
    if !requested_path.starts_with("posts/") {
        let err = serde_json::json!({"error": "workflow comments are only supported for posts/* feed items"});
        return (StatusCode::BAD_REQUEST, Json(err));
    }

    let workspace_dir = state.config.lock().workspace_dir.clone();
    let store = load_feed_workflow_settings_store(&workspace_dir).unwrap_or_default();
    let Some(workflow) = workflow_for_feed_path(&store, &requested_path) else {
        let supported_prefixes: Vec<String> = workflow_definitions(&store)
            .into_iter()
            .map(|item| item.output_prefix)
            .collect();
        let err = serde_json::json!({
            "error": "No editable workflow is mapped to this feed path yet",
            "supportedPrefixes": supported_prefixes,
        });
        return (StatusCode::BAD_REQUEST, Json(err));
    };

    let Some(resolved_target) = resolve_workspace_text_path(&workspace_dir, &requested_path) else {
        let err = serde_json::json!({"error": "invalid feed item path"});
        return (StatusCode::BAD_REQUEST, Json(err));
    };
    if !resolved_target.exists() || !resolved_target.is_file() {
        let err = serde_json::json!({"error": "feed item file not found"});
        return (StatusCode::NOT_FOUND, Json(err));
    }

    let quickfix_result =
        maybe_apply_workflow_comment_quickfix(&workspace_dir, &workflow, &requested_path, comment);
    match quickfix_result {
        Ok(Some(quickfix_message)) => {
            let thread_id = format!("workflow:{}", workflow.key);
            let user_content = format!("[{requested_path}] {comment}");
            let user_record = match local_store::create_chat_message(
                &workspace_dir,
                &thread_id,
                "user",
                &user_content,
                "done",
                "feed-comment",
                None,
                None,
            ) {
                Ok(record) => record,
                Err(err) => {
                    tracing::warn!("Failed to persist feed workflow quickfix request: {err}");
                    let payload = serde_json::json!({"error": err.to_string()});
                    return (StatusCode::INTERNAL_SERVER_ERROR, Json(payload));
                }
            };
            let user_id = user_record
                .get("id")
                .and_then(serde_json::Value::as_str)
                .unwrap_or("")
                .to_string();
            if let Err(err) = local_store::create_chat_message(
                &workspace_dir,
                &thread_id,
                "assistant",
                &quickfix_message,
                "done",
                "workflow-quickfix",
                Some(&user_id),
                None,
            ) {
                tracing::warn!("Failed to persist workflow quickfix assistant message: {err}");
            }

            let configured = load_feed_workflow_settings_store(&workspace_dir)
                .ok()
                .and_then(|loaded| {
                    loaded
                        .workflows
                        .get(&workflow.key)
                        .map(|record| record.settings.clone())
                })
                .unwrap_or_else(workflow_default_settings);
            let settings = normalize_workflow_settings(configured);
            let command = workflow_command_preview(&workflow, &settings);
            let run_thread_id = queue_workflow_run(
                state.clone(),
                workflow.key.to_string(),
                workflow.bot_name.to_string(),
                command,
                "workflow-quickfix",
            )
            .ok();

            let response_message = if run_thread_id.is_some() {
                format!("{quickfix_message} Rerun queued.")
            } else {
                quickfix_message.clone()
            };
            return (
                StatusCode::OK,
                Json(serde_json::json!({
                    "queued": run_thread_id.is_some(),
                    "threadId": run_thread_id.unwrap_or(thread_id),
                    "workflowKey": workflow.key,
                    "workflowBot": workflow.bot_name,
                    "editableFiles": workflow.editable_files,
                    "messageId": user_id,
                    "message": response_message,
                    "quickfixApplied": true,
                })),
            );
        }
        Ok(None) => {}
        Err(err) => {
            tracing::warn!(
                "workflow quickfix check failed for {} on {}: {err}",
                workflow.key,
                requested_path
            );
        }
    }

    let thread_id = format!("workflow:{}", workflow.key);
    let user_content = format!("[{requested_path}] {comment}");
    let user_record = match local_store::create_chat_message(
        &workspace_dir,
        &thread_id,
        "user",
        &user_content,
        "pending",
        "feed-comment",
        None,
        None,
    ) {
        Ok(record) => record,
        Err(err) => {
            tracing::warn!("Failed to persist feed workflow comment: {err}");
            let payload = serde_json::json!({"error": err.to_string()});
            return (StatusCode::INTERNAL_SERVER_ERROR, Json(payload));
        }
    };

    let user_id = user_record
        .get("id")
        .and_then(serde_json::Value::as_str)
        .unwrap_or("")
        .to_string();
    let prompt = workflow_comment_prompt(&workflow, &requested_path, comment);
    let thread_id_for_worker = thread_id.clone();
    let workspace_for_worker = workspace_dir.clone();
    let state_for_worker = state.clone();
    let user_id_for_worker = user_id.clone();

    tokio::spawn(async move {
        if let Err(err) =
            local_store::patch_chat_status(
                &workspace_for_worker,
                &user_id_for_worker,
                "processing",
                None,
            )
        {
            tracing::warn!("Failed to update feed-comment status to processing: {err}");
        }

        let channel_ctx = crate::channels::ChannelExecutionContext::new(
            "local",
            thread_id_for_worker.clone(),
            Some(thread_id_for_worker.clone()),
        );
        let config = state_for_worker.config.lock().clone();
        let result = crate::channels::with_channel_execution_context(
            channel_ctx,
            crate::agent::process_message(config, &prompt),
        )
        .await;

        match result {
            Ok(reply) => {
                let reply_text = if reply.trim().is_empty() {
                    "Workflow update applied."
                } else {
                    reply.trim()
                };
                if let Err(err) = local_store::create_chat_message(
                    &workspace_for_worker,
                    &thread_id_for_worker,
                    "assistant",
                    reply_text,
                    "done",
                    "workflow-modifier",
                    Some(&user_id_for_worker),
                    None,
                ) {
                    tracing::warn!("Failed to persist workflow-modifier reply: {err}");
                }
                if let Err(err) = local_store::patch_chat_status(
                    &workspace_for_worker,
                    &user_id_for_worker,
                    "done",
                    None,
                ) {
                    tracing::warn!("Failed to mark feed-comment as done: {err}");
                }
            }
            Err(err) => {
                let err_text = crate::util::truncate_with_ellipsis(&format!("{err:#}"), 2000);
                let _ = local_store::create_chat_message(
                    &workspace_for_worker,
                    &thread_id_for_worker,
                    "assistant",
                    "",
                    "error",
                    "workflow-modifier",
                    Some(&user_id_for_worker),
                    Some(&err_text),
                );
                if let Err(update_err) = local_store::patch_chat_status(
                    &workspace_for_worker,
                    &user_id_for_worker,
                    "error",
                    Some(&err_text),
                ) {
                    tracing::warn!(
                        "Failed to mark feed-comment as error after workflow-modifier failure: {update_err}"
                    );
                }
            }
        }
    });

    (
        StatusCode::OK,
        Json(serde_json::json!({
            "queued": true,
            "threadId": thread_id,
            "workflowKey": workflow.key,
            "workflowBot": workflow.bot_name,
            "editableFiles": workflow.editable_files,
            "messageId": user_id,
            "message": format!("Queued update for {}", workflow.bot_name),
        })),
    )
}

async fn handle_drafts_list(
    State(state): State<AppState>,
    headers: HeaderMap,
    Query(query): Query<DraftListQuery>,
) -> impl IntoResponse {
    if let Some(err) = pairing_auth_error(&state, &headers, "Drafts API") {
        return err;
    }
    let workspace_dir = state.config.lock().workspace_dir.clone();
    let limit = query.limit.unwrap_or(20).clamp(1, 200);
    match local_store::list_drafts(&workspace_dir, limit) {
        Ok(items) => (StatusCode::OK, Json(serde_json::json!({ "items": items }))),
        Err(err) => {
            tracing::warn!("Drafts list failed: {err}");
            (
                StatusCode::INTERNAL_SERVER_ERROR,
                Json(serde_json::json!({"error": err.to_string()})),
            )
        }
    }
}

async fn handle_drafts_upsert(
    State(state): State<AppState>,
    headers: HeaderMap,
    Json(body): Json<DraftUpsertBody>,
) -> impl IntoResponse {
    if let Some(err) = pairing_auth_error(&state, &headers, "Drafts API") {
        return err;
    }
    let workspace_dir = state.config.lock().workspace_dir.clone();
    let payload = local_store::DraftUpsert {
        id: body.id,
        text: body.text.unwrap_or_default(),
        video_name: body.video_name.unwrap_or_default(),
        created_at_client: body.created_at_client,
        updated_at_client: body.updated_at_client,
    };
    match local_store::upsert_draft(&workspace_dir, &payload) {
        Ok(record) => (StatusCode::OK, Json(record)),
        Err(err) => {
            tracing::warn!("Draft upsert failed: {err}");
            (
                StatusCode::INTERNAL_SERVER_ERROR,
                Json(serde_json::json!({"error": err.to_string()})),
            )
        }
    }
}

async fn handle_post_history_list(
    State(state): State<AppState>,
    headers: HeaderMap,
    Query(query): Query<PostHistoryListQuery>,
) -> impl IntoResponse {
    if let Some(err) = pairing_auth_error(&state, &headers, "Post history API") {
        return err;
    }
    let workspace_dir = state.config.lock().workspace_dir.clone();
    let limit = query.limit.unwrap_or(50).clamp(1, 500);
    match local_store::list_post_history(&workspace_dir, limit) {
        Ok(items) => (StatusCode::OK, Json(serde_json::json!({ "items": items }))),
        Err(err) => {
            tracing::warn!("Post history list failed: {err}");
            (
                StatusCode::INTERNAL_SERVER_ERROR,
                Json(serde_json::json!({"error": err.to_string()})),
            )
        }
    }
}

async fn handle_post_history_create(
    State(state): State<AppState>,
    headers: HeaderMap,
    Json(body): Json<PostHistoryCreateBody>,
) -> impl IntoResponse {
    if let Some(err) = pairing_auth_error(&state, &headers, "Post history API") {
        return err;
    }
    let workspace_dir = state.config.lock().workspace_dir.clone();
    let payload = local_store::PostHistoryInput {
        provider: body.provider.unwrap_or_else(|| "bluesky".to_string()),
        text: body.text.unwrap_or_default(),
        video_name: body.video_name.unwrap_or_default(),
        source_path: body.source_path.unwrap_or_default(),
        uri: body.uri.unwrap_or_default(),
        cid: body.cid.unwrap_or_default(),
        status: body.status.unwrap_or_else(|| "success".to_string()),
        error: body.error.unwrap_or_default(),
        created_at_client: body.created_at_client,
    };
    match local_store::create_post_history(&workspace_dir, &payload) {
        Ok(record) => (StatusCode::OK, Json(record)),
        Err(err) => {
            tracing::warn!("Post history create failed: {err}");
            (
                StatusCode::INTERNAL_SERVER_ERROR,
                Json(serde_json::json!({"error": err.to_string()})),
            )
        }
    }
}

fn pairing_auth_error(
    state: &AppState,
    headers: &HeaderMap,
    scope: &str,
) -> Option<(StatusCode, Json<serde_json::Value>)> {
    if !state.pairing.require_pairing() {
        return None;
    }
    let auth = headers
        .get(header::AUTHORIZATION)
        .and_then(|v| v.to_str().ok())
        .unwrap_or("");
    let token = auth.strip_prefix("Bearer ").unwrap_or("");
    if state.pairing.is_authenticated(token) {
        return None;
    }
    tracing::warn!("{scope}: rejected — not paired / invalid bearer token");
    let err = serde_json::json!({
        "error": "Unauthorized — pair first via POST /pair, then send Authorization: Bearer <token>"
    });
    Some((StatusCode::UNAUTHORIZED, Json(err)))
}

#[derive(serde::Deserialize)]
struct MediaUploadQuery {
    kind: Option<String>,
    filename: Option<String>,
    title: Option<String>,
    source: Option<String>,
    entry_id: Option<String>,
}

#[derive(serde::Deserialize)]
struct JournalTextBody {
    title: Option<String>,
    content: String,
    source: Option<String>,
    tags: Option<Vec<String>>,
}

#[derive(serde::Deserialize)]
struct LibraryItemsQuery {
    scope: Option<String>,
    limit: Option<usize>,
}

#[derive(serde::Deserialize)]
struct LibraryTextQuery {
    path: String,
}

#[derive(serde::Deserialize)]
struct SaveTextBody {
    path: String,
    content: String,
}

#[derive(serde::Deserialize)]
struct DeleteLibraryBody {
    path: String,
}

#[derive(serde::Deserialize)]
#[serde(rename_all = "camelCase")]
struct JournalTranscribeBody {
    media_path: String,
}

#[derive(serde::Deserialize)]
#[serde(rename_all = "camelCase")]
struct RuntimeConfigUpdateBody {
    default_provider: String,
    default_model: String,
    transcription_enabled: bool,
    transcription_model: Option<String>,
}

fn available_local_transcription_models() -> Vec<String> {
    let (cache_key, models) = compute_available_transcription_models();
    let cache = TRANSCRIPTION_MODEL_CACHE.get_or_init(|| Mutex::new(None));
    let mut guard = cache.lock();
    if let Some(entry) = guard.as_ref() {
        let fresh = entry.cached_at.elapsed() < Duration::from_secs(TRANSCRIPTION_MODEL_CACHE_TTL_SECS);
        if fresh && entry.cache_key == cache_key {
            return entry.models.clone();
        }
    }
    let models_vec: Vec<String> = models.into_iter().collect();
    *guard = Some(TranscriptionModelCacheEntry {
        cache_key,
        models: models_vec.clone(),
        cached_at: Instant::now(),
    });
    models_vec
}

fn compute_available_transcription_models() -> (String, BTreeSet<String>) {
    let roots = transcription_cache_roots();
    let mut signature_parts: Vec<String> = Vec::new();
    let mut models = BTreeSet::new();

    for root in roots {
        let root_display = root.display().to_string();
        if !root.exists() || !root.is_dir() {
            signature_parts.push(format!("{root_display}:missing"));
            continue;
        }
        let read = match std::fs::read_dir(&root) {
            Ok(entries) => entries,
            Err(_) => {
                signature_parts.push(format!("{root_display}:unreadable"));
                continue;
            }
        };

        for entry in read.flatten() {
            let Ok(file_type) = entry.file_type() else {
                continue;
            };
            if !file_type.is_dir() {
                continue;
            }
            let dir_name = entry.file_name().to_string_lossy().to_string();
            let lower = dir_name.to_ascii_lowercase();
            if !(lower.starts_with("models--") && lower.contains("faster-whisper")) {
                continue;
            }
            let modified = entry
                .metadata()
                .ok()
                .and_then(|m| m.modified().ok())
                .and_then(|ts| ts.duration_since(UNIX_EPOCH).ok())
                .map_or(0, |dur| dur.as_secs());
            signature_parts.push(format!("{root_display}:{dir_name}:{modified}"));

            if lower.contains("faster-whisper-large-v3-turbo") {
                models.insert("whisper-large-v3-turbo".to_string());
                models.insert("large-v3".to_string());
            }
            if lower.contains("faster-whisper-large-v3") {
                models.insert("large-v3".to_string());
            }
            if lower.contains("faster-whisper-large-v2") {
                models.insert("large-v2".to_string());
            }
            if lower.contains("faster-whisper-large-v1") {
                models.insert("large-v1".to_string());
            }
            if lower.contains("faster-whisper-large") {
                models.insert("large".to_string());
            }
            if lower.contains("faster-whisper-medium") {
                models.insert("medium".to_string());
            }
            if lower.contains("faster-whisper-small") {
                models.insert("small".to_string());
            }
            if lower.contains("faster-whisper-base") {
                models.insert("base".to_string());
            }
            if lower.contains("faster-whisper-tiny") {
                models.insert("tiny".to_string());
            }
        }
    }

    signature_parts.sort();
    let cache_key = signature_parts.join("|");
    (cache_key, models)
}

fn transcription_cache_roots() -> Vec<PathBuf> {
    let mut roots: Vec<PathBuf> = Vec::new();
    if let Some(home) = std::env::var("HOME")
        .ok()
        .map(|value| value.trim().to_string())
        .filter(|value| !value.is_empty())
    {
        roots.push(PathBuf::from(home).join(".cache/huggingface/hub"));
    }
    if let Some(hf_home) = std::env::var("HF_HOME")
        .ok()
        .map(|value| value.trim().to_string())
        .filter(|value| !value.is_empty())
    {
        roots.push(PathBuf::from(hf_home).join("hub"));
    }
    roots
}

#[derive(serde::Deserialize)]
#[serde(rename_all = "camelCase")]
struct JournalTranscribeStatusQuery {
    media_path: String,
}

async fn handle_media_upload(
    State(state): State<AppState>,
    Query(query): Query<MediaUploadQuery>,
    req: Request,
) -> axum::response::Response {
    if let Some(err) = pairing_auth_error(&state, req.headers(), "Media upload") {
        return err.into_response();
    }

    let headers = req.headers().clone();
    let content_type = headers
        .get(header::CONTENT_TYPE)
        .and_then(|v| v.to_str().ok())
        .unwrap_or("application/octet-stream")
        .to_string();

    let kind = query
        .kind
        .as_deref()
        .map(str::trim)
        .filter(|v| !v.is_empty())
        .unwrap_or_else(|| infer_media_kind_from_content_type(&content_type));
    let source = query
        .source
        .as_deref()
        .map(str::trim)
        .filter(|v| !v.is_empty())
        .unwrap_or("mobile");
    let title = query
        .title
        .as_deref()
        .map(str::trim)
        .filter(|v| !v.is_empty())
        .map(ToOwned::to_owned);
    let original_name = query
        .filename
        .clone()
        .or_else(|| {
            headers
                .get("X-File-Name")
                .and_then(|v| v.to_str().ok())
                .map(ToOwned::to_owned)
        })
        .unwrap_or_else(|| format!("upload-{}", Uuid::new_v4()));

    let workspace_dir = state.config.lock().workspace_dir.clone();
    let rel_path = media_storage_rel_path(kind, &original_name);
    let abs_path = workspace_dir.join(&rel_path);
    if let Some(parent) = abs_path.parent() {
        if let Err(e) = tokio::fs::create_dir_all(parent).await {
            let err = serde_json::json!({"error": format!("Failed to create media directory: {e}")});
            return (StatusCode::INTERNAL_SERVER_ERROR, Json(err)).into_response();
        }
    }

    let mut file = match tokio::fs::File::create(&abs_path).await {
        Ok(f) => f,
        Err(e) => {
            let err = serde_json::json!({"error": format!("Failed to create upload file: {e}")});
            return (StatusCode::INTERNAL_SERVER_ERROR, Json(err)).into_response();
        }
    };

    let mut body = req.into_body();
    let mut bytes_written: u64 = 0;
    while let Some(frame_result) = body.frame().await {
        let frame = match frame_result {
            Ok(frame) => frame,
            Err(e) => {
                let _ = tokio::fs::remove_file(&abs_path).await;
                let err = serde_json::json!({"error": format!("Upload stream error: {e}")});
                return (StatusCode::BAD_REQUEST, Json(err)).into_response();
            }
        };
        if let Some(data) = frame.data_ref() {
            if let Err(e) = file.write_all(data).await {
                let _ = tokio::fs::remove_file(&abs_path).await;
                let err = serde_json::json!({"error": format!("Failed writing upload file: {e}")});
                return (StatusCode::INTERNAL_SERVER_ERROR, Json(err)).into_response();
            }
            bytes_written = bytes_written.saturating_add(data.len() as u64);
        }
    }
    let _ = file.flush().await;

    let pb_record = match upsert_media_asset_metadata(
        &state,
        &rel_path,
        &content_type,
        kind,
        title.as_deref(),
        source,
        bytes_written,
        query.entry_id.as_deref(),
    )
    .await
    {
        Ok(record) => Some(record),
        Err(e) => {
            tracing::warn!("Media metadata write failed: {e}");
            None
        }
    };

    let transcription = if kind.eq_ignore_ascii_case("audio") {
        enqueue_journal_transcription(&state, rel_path.clone()).await
    } else {
        None
    };

    let body = serde_json::json!({
        "ok": true,
        "kind": kind,
        "contentType": content_type,
        "bytes": bytes_written,
        "path": rel_path,
        "title": title,
        "metadata": pb_record,
        "transcription": transcription,
    });
    (StatusCode::OK, Json(body)).into_response()
}

async fn handle_journal_text(
    State(state): State<AppState>,
    headers: HeaderMap,
    Json(body): Json<JournalTextBody>,
) -> axum::response::Response {
    if let Some(err) = pairing_auth_error(&state, &headers, "Journal text") {
        return err.into_response();
    }
    let content = body.content.trim();
    if content.is_empty() {
        let err = serde_json::json!({"error": "content is required"});
        return (StatusCode::BAD_REQUEST, Json(err)).into_response();
    }

    let title = body
        .title
        .as_deref()
        .map(str::trim)
        .filter(|v| !v.is_empty())
        .unwrap_or("Journal entry");
    let source = body
        .source
        .as_deref()
        .map(str::trim)
        .filter(|v| !v.is_empty())
        .unwrap_or("mobile");
    let workspace_dir = state.config.lock().workspace_dir.clone();
    let rel_path = text_journal_rel_path(title);
    let abs_path = workspace_dir.join(&rel_path);
    if let Some(parent) = abs_path.parent() {
        if let Err(e) = tokio::fs::create_dir_all(parent).await {
            let err = serde_json::json!({"error": format!("Failed to create journal directory: {e}")});
            return (StatusCode::INTERNAL_SERVER_ERROR, Json(err)).into_response();
        }
    }
    let file_body = format!("# {}\n\n{}\n", title, content);
    if let Err(e) = tokio::fs::write(&abs_path, file_body).await {
        let err = serde_json::json!({"error": format!("Failed to save journal note: {e}")});
        return (StatusCode::INTERNAL_SERVER_ERROR, Json(err)).into_response();
    }

    let pb_record = match create_journal_entry_metadata(
        &state,
        &rel_path,
        title,
        content,
        source,
        body.tags.as_deref(),
    )
    .await
    {
        Ok(record) => Some(record),
        Err(e) => {
            tracing::warn!("Journal metadata write failed: {e}");
            None
        }
    };

    let resp = serde_json::json!({
        "ok": true,
        "path": rel_path,
        "title": title,
        "metadata": pb_record,
    });
    (StatusCode::OK, Json(resp)).into_response()
}

async fn handle_media_stream(
    State(state): State<AppState>,
    AxumPath(path): AxumPath<String>,
    req: Request,
) -> axum::response::Response {
    if let Some(err) = pairing_auth_error(&state, req.headers(), "Media stream") {
        return err.into_response();
    }
    let workspace_dir = state.config.lock().workspace_dir.clone();
    let Some(abs_path) = resolve_workspace_media_path(&workspace_dir, &path) else {
        let err = serde_json::json!({"error": "Invalid media path"});
        return (StatusCode::BAD_REQUEST, Json(err)).into_response();
    };
    if !abs_path.exists() || !abs_path.is_file() {
        let err = serde_json::json!({"error": "Media file not found"});
        return (StatusCode::NOT_FOUND, Json(err)).into_response();
    }

    match ServeFile::new(abs_path).oneshot(req).await {
        Ok(resp) => resp.into_response(),
        Err(e) => {
            tracing::warn!("Media stream failed: {e}");
            let err = serde_json::json!({"error": format!("Media stream failed: {e}")});
            (StatusCode::INTERNAL_SERVER_ERROR, Json(err)).into_response()
        }
    }
}

async fn handle_library_items(
    State(state): State<AppState>,
    headers: HeaderMap,
    Query(query): Query<LibraryItemsQuery>,
) -> axum::response::Response {
    if let Some(err) = pairing_auth_error(&state, &headers, "Library list") {
        return err.into_response();
    }
    let workspace_dir = state.config.lock().workspace_dir.clone();
    let scope = query.scope.as_deref().unwrap_or("all");
    let limit = query.limit.unwrap_or(200).clamp(1, 1000);
    match list_workspace_library_items(&workspace_dir, scope, limit) {
        Ok(items) => (StatusCode::OK, Json(serde_json::json!({ "items": items }))).into_response(),
        Err(e) => {
            let err = serde_json::json!({"error": format!("Failed to list library items: {e}")});
            (StatusCode::INTERNAL_SERVER_ERROR, Json(err)).into_response()
        }
    }
}

async fn handle_library_text(
    State(state): State<AppState>,
    headers: HeaderMap,
    Query(query): Query<LibraryTextQuery>,
) -> axum::response::Response {
    if let Some(err) = pairing_auth_error(&state, &headers, "Library text") {
        return err.into_response();
    }
    let workspace_dir = state.config.lock().workspace_dir.clone();
    let Some(path) = resolve_workspace_text_path(&workspace_dir, &query.path) else {
        let err = serde_json::json!({"error": "Invalid text path"});
        return (StatusCode::BAD_REQUEST, Json(err)).into_response();
    };
    match tokio::fs::read_to_string(&path).await {
        Ok(content) => {
            let rel = path
                .strip_prefix(&workspace_dir)
                .ok()
                .map(|p| p.to_string_lossy().to_string())
                .unwrap_or_else(|| query.path.clone());
            (StatusCode::OK, Json(serde_json::json!({"path": rel, "content": content}))).into_response()
        }
        Err(e) => {
            let err = serde_json::json!({"error": format!("Failed to read text file: {e}")});
            (StatusCode::NOT_FOUND, Json(err)).into_response()
        }
    }
}

async fn handle_library_save_text(
    State(state): State<AppState>,
    headers: HeaderMap,
    Json(body): Json<SaveTextBody>,
) -> axum::response::Response {
    if let Some(err) = pairing_auth_error(&state, &headers, "Library save") {
        return err.into_response();
    }
    let workspace_dir = state.config.lock().workspace_dir.clone();
    let Some(path) = resolve_workspace_text_path(&workspace_dir, &body.path) else {
        let err = serde_json::json!({"error": "Invalid text path"});
        return (StatusCode::BAD_REQUEST, Json(err)).into_response();
    };
    if let Some(parent) = path.parent() {
        if let Err(e) = tokio::fs::create_dir_all(parent).await {
            let err = serde_json::json!({"error": format!("Failed to create directory: {e}")});
            return (StatusCode::INTERNAL_SERVER_ERROR, Json(err)).into_response();
        }
    }
    if let Err(e) = tokio::fs::write(&path, &body.content).await {
        let err = serde_json::json!({"error": format!("Failed to save text file: {e}")});
        return (StatusCode::INTERNAL_SERVER_ERROR, Json(err)).into_response();
    }
    let rel = path
        .strip_prefix(&workspace_dir)
        .ok()
        .map(|p| p.to_string_lossy().to_string())
        .unwrap_or(body.path);
    (StatusCode::OK, Json(serde_json::json!({"ok": true, "path": rel}))).into_response()
}

async fn handle_library_delete(
    State(state): State<AppState>,
    headers: HeaderMap,
    Json(body): Json<DeleteLibraryBody>,
) -> axum::response::Response {
    if let Some(err) = pairing_auth_error(&state, &headers, "Library delete") {
        return err.into_response();
    }
    let requested = body.path.trim().trim_start_matches('/').to_string();
    if requested.is_empty() {
        let err = serde_json::json!({"error": "path is required"});
        return (StatusCode::BAD_REQUEST, Json(err)).into_response();
    }

    let workspace_dir = state.config.lock().workspace_dir.clone();
    let lower = requested.to_ascii_lowercase();
    let target_path = if lower.starts_with("journals/media/") {
        resolve_workspace_media_path(&workspace_dir, &requested)
    } else {
        resolve_workspace_text_path(&workspace_dir, &requested)
    };
    let Some(abs_path) = target_path else {
        let err = serde_json::json!({"error": "Invalid path"});
        return (StatusCode::BAD_REQUEST, Json(err)).into_response();
    };
    if !abs_path.exists() || !abs_path.is_file() {
        let err = serde_json::json!({"error": "File not found"});
        return (StatusCode::NOT_FOUND, Json(err)).into_response();
    }

    if let Err(e) = tokio::fs::remove_file(&abs_path).await {
        let err = serde_json::json!({"error": format!("Failed to delete file: {e}")});
        return (StatusCode::INTERNAL_SERVER_ERROR, Json(err)).into_response();
    }

    let mut removed_related: Vec<String> = Vec::new();
    if lower.starts_with("journals/media/") {
        let transcript_candidates = [
            transcript_rel_path_for_media(&requested),
            legacy_transcript_rel_path_for_media(&requested),
        ];
        for transcript_rel in transcript_candidates.into_iter().flatten() {
            if let Some(transcript_abs) =
                resolve_workspace_text_path(&workspace_dir, &transcript_rel)
            {
                if transcript_abs.exists()
                    && transcript_abs.is_file()
                    && tokio::fs::remove_file(&transcript_abs).await.is_ok()
                {
                    removed_related.push(transcript_rel);
                }
            }
        }
        let legacy_caption_rel = format!("{requested}.caption.txt");
        if let Some(legacy_caption_abs) =
            resolve_workspace_text_path(&workspace_dir, &legacy_caption_rel)
        {
            if legacy_caption_abs.exists() && legacy_caption_abs.is_file() {
                if tokio::fs::remove_file(&legacy_caption_abs).await.is_ok() {
                    removed_related.push(legacy_caption_rel);
                }
            }
        }
    }

    let body = serde_json::json!({
        "ok": true,
        "path": requested,
        "removedRelated": removed_related,
    });
    (StatusCode::OK, Json(body)).into_response()
}

async fn handle_journal_transcribe(
    State(state): State<AppState>,
    headers: HeaderMap,
    Json(body): Json<JournalTranscribeBody>,
) -> axum::response::Response {
    if let Some(err) = pairing_auth_error(&state, &headers, "Journal transcribe") {
        return err.into_response();
    }

    let requested = body.media_path.trim().trim_start_matches('/').to_string();
    if requested.is_empty() {
        let err = serde_json::json!({"error": "mediaPath is required"});
        return (StatusCode::BAD_REQUEST, Json(err)).into_response();
    }

    let config_snapshot = state.config.lock().clone();
    if !config_snapshot.transcription.enabled {
        let err = serde_json::json!({
            "error": "Transcription is disabled. Enable [transcription] enabled = true in config."
        });
        return (StatusCode::BAD_REQUEST, Json(err)).into_response();
    }

    let workspace_dir = config_snapshot.workspace_dir.clone();
    let Some(abs_media_path) = resolve_workspace_media_path(&workspace_dir, &requested) else {
        let err = serde_json::json!({"error": "Invalid media path"});
        return (StatusCode::BAD_REQUEST, Json(err)).into_response();
    };
    if !abs_media_path.exists() || !abs_media_path.is_file() {
        let err = serde_json::json!({"error": "Media file not found"});
        return (StatusCode::NOT_FOUND, Json(err)).into_response();
    }

    let Some(transcript_rel_path) = transcript_rel_path_for_media(&requested) else {
        let err = serde_json::json!({"error": "Could not derive transcript path"});
        return (StatusCode::BAD_REQUEST, Json(err)).into_response();
    };
    let transcript_abs_path = workspace_dir.join(&transcript_rel_path);

    if transcript_abs_path.exists() && transcript_abs_path.is_file() {
        let transcript_text = tokio::fs::read_to_string(&transcript_abs_path)
            .await
            .unwrap_or_default();
        if !transcript_text.trim().is_empty() {
            let body = serde_json::json!({
                "ok": true,
                "mediaPath": requested,
                "path": transcript_rel_path,
                "text": transcript_text,
                "status": "done",
            });
            return (StatusCode::OK, Json(body)).into_response();
        }
    }

    let enqueue_result = enqueue_transcription_job(
        state.clone(),
        requested.clone(),
        abs_media_path,
        transcript_rel_path.clone(),
        transcript_abs_path,
        config_snapshot.transcription.clone(),
    );

    let body = serde_json::json!({
        "ok": true,
        "mediaPath": requested,
        "path": transcript_rel_path,
        "status": enqueue_result.status,
        "error": enqueue_result.error,
        "updatedAt": enqueue_result.updated_at,
    });
    (StatusCode::OK, Json(body)).into_response()
}

async fn handle_journal_transcribe_status(
    State(state): State<AppState>,
    headers: HeaderMap,
    Query(query): Query<JournalTranscribeStatusQuery>,
) -> axum::response::Response {
    if let Some(err) = pairing_auth_error(&state, &headers, "Journal transcribe status") {
        return err.into_response();
    }

    let requested = query.media_path.trim().trim_start_matches('/').to_string();
    if requested.is_empty() {
        let err = serde_json::json!({"error": "mediaPath is required"});
        return (StatusCode::BAD_REQUEST, Json(err)).into_response();
    }

    let workspace_dir = state.config.lock().workspace_dir.clone();
    let Some(transcript_rel_path) = transcript_rel_path_for_media(&requested) else {
        let err = serde_json::json!({"error": "Could not derive transcript path"});
        return (StatusCode::BAD_REQUEST, Json(err)).into_response();
    };
    let transcript_abs_path = workspace_dir.join(&transcript_rel_path);

    if transcript_abs_path.exists() && transcript_abs_path.is_file() {
        let transcript_text = tokio::fs::read_to_string(&transcript_abs_path)
            .await
            .unwrap_or_default();
        if !transcript_text.trim().is_empty() {
            let body = serde_json::json!({
                "ok": true,
                "mediaPath": requested,
                "path": transcript_rel_path,
                "text": transcript_text,
                "status": "done",
            });
            return (StatusCode::OK, Json(body)).into_response();
        }
    }

    let jobs = state.journal_transcription_jobs.lock();
    if let Some(job) = jobs.get(&requested) {
        let body = serde_json::json!({
            "ok": true,
            "mediaPath": requested,
            "path": transcript_rel_path,
            "status": job.status,
            "error": job.error,
            "updatedAt": job.updated_at,
        });
        return (StatusCode::OK, Json(body)).into_response();
    }

    let body = serde_json::json!({
        "ok": true,
        "mediaPath": requested,
        "path": transcript_rel_path,
        "status": "idle",
    });
    (StatusCode::OK, Json(body)).into_response()
}

fn transcript_rel_path_for_media(media_rel_path: &str) -> Option<String> {
    let normalized = media_rel_path.trim_start_matches('/');
    let relative = normalized.strip_prefix("journals/media/")?;
    let media_rel = StdPath::new(relative);
    let stem = media_rel.file_stem()?.to_str()?.trim();
    if stem.is_empty() {
        return None;
    }

    let mut out = PathBuf::from("journals/text/transcriptions");
    if let Some(parent) = media_rel.parent() {
        if !parent.as_os_str().is_empty() {
            out.push(parent);
        }
    }
    out.push(format!("{stem}.txt"));
    Some(out.to_string_lossy().replace('\\', "/"))
}

fn legacy_transcript_rel_path_for_media(media_rel_path: &str) -> Option<String> {
    let stem = StdPath::new(media_rel_path).file_stem()?.to_str()?.trim();
    if stem.is_empty() {
        return None;
    }
    Some(format!("journals/text/transcript/{stem}.txt"))
}

fn enqueue_transcription_job(
    state: AppState,
    media_rel_path: String,
    media_abs_path: PathBuf,
    transcript_rel_path: String,
    transcript_abs_path: PathBuf,
    transcription_config: TranscriptionConfig,
) -> JournalTranscriptionJob {
    {
        let mut jobs = state.journal_transcription_jobs.lock();
        if let Some(existing) = jobs.get(&media_rel_path).cloned() {
            if existing.status == "queued" || existing.status == "running" {
                return existing;
            }
        }
        jobs.insert(media_rel_path.clone(), JournalTranscriptionJob::queued());
    }

    let queued_path = transcript_rel_path.clone();
    let task_transcript_rel_path = transcript_rel_path.clone();
    let state_for_task = state.clone();
    tokio::spawn(async move {
        {
            let mut jobs = state_for_task.journal_transcription_jobs.lock();
            jobs.insert(
                media_rel_path.clone(),
                JournalTranscriptionJob {
                    status: "running".to_string(),
                    transcript_path: Some(task_transcript_rel_path.clone()),
                    error: None,
                    updated_at: chrono::Utc::now().to_rfc3339(),
                },
            );
        }

        let final_state = match run_local_faster_whisper(
            &state_for_task,
            &media_abs_path,
            &transcript_abs_path,
            &transcription_config,
        )
        .await
        {
            Ok(_) => JournalTranscriptionJob {
                status: "done".to_string(),
                transcript_path: Some(task_transcript_rel_path.clone()),
                error: None,
                updated_at: chrono::Utc::now().to_rfc3339(),
            },
            Err(error) => JournalTranscriptionJob {
                status: "error".to_string(),
                transcript_path: Some(task_transcript_rel_path.clone()),
                error: Some(error.to_string()),
                updated_at: chrono::Utc::now().to_rfc3339(),
            },
        };

        let mut jobs = state_for_task.journal_transcription_jobs.lock();
        jobs.insert(media_rel_path, final_state);
    });

    JournalTranscriptionJob {
        status: "queued".to_string(),
        transcript_path: Some(queued_path),
        error: None,
        updated_at: chrono::Utc::now().to_rfc3339(),
    }
}

async fn enqueue_journal_transcription(
    state: &AppState,
    media_rel_path: String,
) -> Option<serde_json::Value> {
    let workspace_dir = state.config.lock().workspace_dir.clone();
    let Some(abs_media_path) = resolve_workspace_media_path(&workspace_dir, &media_rel_path) else {
        return None;
    };
    let Some(transcript_rel_path) = transcript_rel_path_for_media(&media_rel_path) else {
        return None;
    };
    let transcript_abs_path = workspace_dir.join(&transcript_rel_path);
    if transcript_abs_path.exists() && transcript_abs_path.is_file() {
        let existing = tokio::fs::read_to_string(&transcript_abs_path)
            .await
            .unwrap_or_default();
        if !existing.trim().is_empty() {
            return Some(serde_json::json!({
                "status": "done",
                "path": transcript_rel_path,
            }));
        }
    }
    let cfg = state.config.lock().transcription.clone();
    if !cfg.enabled {
        return Some(serde_json::json!({
            "status": "disabled",
            "path": transcript_rel_path,
        }));
    }
    let job = enqueue_transcription_job(
        state.clone(),
        media_rel_path,
        abs_media_path,
        transcript_rel_path.clone(),
        transcript_abs_path,
        cfg,
    );
    Some(serde_json::json!({
        "status": job.status,
        "path": transcript_rel_path,
        "error": job.error,
        "updatedAt": job.updated_at,
    }))
}

async fn run_local_faster_whisper(
    state: &AppState,
    media_abs_path: &StdPath,
    transcript_abs_path: &StdPath,
    transcription_config: &TranscriptionConfig,
) -> Result<()> {
    let workspace_dir = state.config.lock().workspace_dir.clone();
    ensure_workspace_transcriber_script(&workspace_dir).await?;

    let script_path = workspace_dir.join("scripts/transcribe_audio_journal.py");
    let mut cmd = Command::new(transcription_config.python_bin.trim());
    cmd.arg(&script_path)
        .arg("--input")
        .arg(media_abs_path)
        .arg("--output")
        .arg(transcript_abs_path)
        .arg("--model")
        .arg(transcription_config.model.trim())
        .arg("--device")
        .arg(transcription_config.device.trim())
        .arg("--compute-type")
        .arg(transcription_config.compute_type.trim())
        .arg("--beam-size")
        .arg(transcription_config.beam_size.max(1).to_string())
        .current_dir(&workspace_dir)
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::piped())
        .kill_on_drop(true);

    if let Some(language) = transcription_config
        .language
        .as_deref()
        .map(str::trim)
        .filter(|value: &&str| !value.is_empty())
    {
        cmd.arg("--language").arg(language);
    }

    let output = tokio::time::timeout(Duration::from_secs(3_600), cmd.output())
        .await
        .context("local transcription timed out")?
        .context("failed to execute local transcriber script")?;

    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr).to_string();
        let stdout = String::from_utf8_lossy(&output.stdout).to_string();
        anyhow::bail!(
            "transcriber script failed ({}): {}",
            output.status,
            truncate_with_ellipsis(
                &(if stderr.trim().is_empty() { stdout } else { stderr }),
                300
            )
        );
    }

    Ok(())
}

async fn ensure_workspace_transcriber_script(workspace_dir: &StdPath) -> Result<()> {
    let scripts_dir = workspace_dir.join("scripts");
    tokio::fs::create_dir_all(&scripts_dir).await?;
    let script_path = scripts_dir.join("transcribe_audio_journal.py");
    let script = include_str!("../../scripts/transcribe_audio_journal.py");
    tokio::fs::write(&script_path, script).await?;
    Ok(())
}

fn infer_media_kind_from_content_type(content_type: &str) -> &'static str {
    let lower = content_type.to_ascii_lowercase();
    if lower.starts_with("audio/") {
        "audio"
    } else if lower.starts_with("video/") {
        "video"
    } else if lower.starts_with("image/") {
        "image"
    } else {
        "file"
    }
}

fn safe_file_name(name: &str) -> String {
    let mut out = String::with_capacity(name.len().min(128));
    for ch in name.chars() {
        if ch.is_ascii_alphanumeric() || matches!(ch, '.' | '_' | '-') {
            out.push(ch);
        } else {
            out.push('_');
        }
    }
    let trimmed = out.trim_matches('_');
    if trimmed.is_empty() {
        "upload.bin".to_string()
    } else {
        trimmed.chars().take(128).collect()
    }
}

fn media_storage_rel_path(kind: &str, original_name: &str) -> String {
    let now = chrono::Utc::now();
    let kind = kind.trim().to_ascii_lowercase();
    let kind_dir = match kind.as_str() {
        "audio" => "audio",
        "video" => "video",
        "image" => "image",
        _ => "files",
    };
    let safe_name = safe_file_name(original_name);
    format!(
        "{}/{}/{:04}/{:02}/{:02}/{}_{}",
        JOURNAL_MEDIA_DIR,
        kind_dir,
        now.year(),
        now.month(),
        now.day(),
        now.format("%H%M%S"),
        safe_name
    )
}

fn text_journal_rel_path(title: &str) -> String {
    let now = chrono::Utc::now();
    let safe = safe_file_name(title).trim_end_matches('.').to_string();
    let stem = if safe.is_empty() { "journal" } else { &safe };
    format!(
        "{}/{:04}/{:02}/{:02}/{}_{}.md",
        JOURNAL_TEXT_DIR,
        now.year(),
        now.month(),
        now.day(),
        now.format("%H%M%S"),
        stem
    )
}

fn resolve_workspace_media_path(workspace_dir: &StdPath, requested: &str) -> Option<PathBuf> {
    let trimmed = requested.trim_start_matches('/');
    if trimmed.is_empty() {
        return None;
    }
    let candidate = workspace_dir.join(trimmed);
    let resolved = candidate.canonicalize().ok()?;
    if !resolved.starts_with(workspace_dir) {
        return None;
    }
    let journals_dir = workspace_dir.join("journals");
    if !resolved.starts_with(journals_dir) {
        return None;
    }
    Some(resolved)
}

fn resolve_workspace_text_path(workspace_dir: &StdPath, requested: &str) -> Option<PathBuf> {
    let trimmed = requested.trim_start_matches('/');
    if trimmed.is_empty() {
        return None;
    }
    let candidate = workspace_dir.join(trimmed);
    let parent = candidate.parent()?.to_path_buf();
    let parent_resolved = parent.canonicalize().unwrap_or(parent);
    if !parent_resolved.starts_with(workspace_dir) {
        return None;
    }
    let allowed = ["journals", "memory", "state", "posts", "outputs", "artifacts"];
    let rel_parent = parent_resolved.strip_prefix(workspace_dir).ok()?;
    let first = rel_parent.components().next()?.as_os_str().to_string_lossy();
    if !allowed.iter().any(|a| *a == first) {
        return None;
    }
    Some(candidate)
}

#[derive(Copy, Clone, Eq, PartialEq)]
enum LibraryScope {
    Journal,
    Feed,
    All,
}

fn list_workspace_library_items(
    workspace_dir: &StdPath,
    scope: &str,
    limit: usize,
) -> Result<Vec<serde_json::Value>> {

    let mut roots: Vec<PathBuf> = Vec::new();
    let normalized = scope.trim().to_ascii_lowercase();
    let requested_scope = match normalized.as_str() {
        "journal" => {
            roots.push(workspace_dir.join("journals"));
            LibraryScope::Journal
        }
        "feed" => {
            roots.push(workspace_dir.join("posts"));
            LibraryScope::Feed
        }
        _ => {
            roots.push(workspace_dir.join("journals"));
            roots.push(workspace_dir.join("posts"));
            LibraryScope::All
        }
    };

    let mut items: Vec<serde_json::Value> = Vec::new();
    for root in roots {
        if !root.exists() {
            continue;
        }
        collect_library_items_recursive(workspace_dir, &root, &mut items, limit, requested_scope)?;
        if items.len() >= limit {
            break;
        }
    }

    items.sort_by(|a, b| {
        let a_ts = a.get("modifiedAt").and_then(serde_json::Value::as_i64).unwrap_or(0);
        let b_ts = b.get("modifiedAt").and_then(serde_json::Value::as_i64).unwrap_or(0);
        b_ts.cmp(&a_ts)
    });
    items.truncate(limit);
    Ok(items)
}

fn collect_library_items_recursive(
    workspace_dir: &StdPath,
    dir: &StdPath,
    out: &mut Vec<serde_json::Value>,
    limit: usize,
    requested_scope: LibraryScope,
) -> Result<()> {
    if out.len() >= limit {
        return Ok(());
    }
    let entries = match std::fs::read_dir(dir) {
        Ok(e) => e,
        Err(_) => return Ok(()),
    };
    for entry in entries {
        if out.len() >= limit {
            break;
        }
        let entry = match entry {
            Ok(e) => e,
            Err(_) => continue,
        };
        let path = entry.path();
        let meta = match entry.metadata() {
            Ok(m) => m,
            Err(_) => continue,
        };
        if meta.is_dir() {
            collect_library_items_recursive(workspace_dir, &path, out, limit, requested_scope)?;
            continue;
        }
        if !meta.is_file() {
            continue;
        }
        let ext = path
            .extension()
            .and_then(|s| s.to_str())
            .unwrap_or("")
            .to_ascii_lowercase();
        let kind = match ext.as_str() {
            "md" | "txt" | "json" | "srt" => "text",
            "mp3" | "wav" | "m4a" | "aac" | "flac" => "audio",
            "mp4" | "mov" | "webm" | "mkv" => "video",
            "jpg" | "jpeg" | "png" | "webp" => "image",
            _ => {
                // Hide unknown binaries for a cleaner mobile UI.
                continue;
            }
        };
        let rel = match path.strip_prefix(workspace_dir) {
            Ok(p) => p.to_string_lossy().to_string(),
            Err(_) => continue,
        };
        let rel_lower = rel.to_ascii_lowercase();

        let scope_value = if rel.starts_with("posts/") {
            "feed"
        } else {
            "journal"
        };

        let is_feed_item = scope_value == "feed";
        match requested_scope {
            LibraryScope::Feed if !is_feed_item => continue,
            LibraryScope::Journal if is_feed_item => continue,
            _ => {}
        }
        if is_feed_item {
            if rel_lower.contains("/artifacts/")
                || rel_lower.contains("/pipeline/")
                || rel_lower.ends_with(".srt")
                || rel_lower.ends_with(".json")
                || rel_lower.ends_with(".caption.txt")
            {
                continue;
            }
        }

        let modified_at = meta
            .modified()
            .ok()
            .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
            .map(|d| i64::try_from(d.as_secs()).unwrap_or(0))
            .unwrap_or(0);
        let title = path
            .file_stem()
            .and_then(|s| s.to_str())
            .unwrap_or("untitled")
            .replace('_', " ");
        let preview = if kind == "text" {
            std::fs::read_to_string(&path)
                .ok()
                .map(|s| truncate_with_ellipsis(&s, 240))
                .unwrap_or_default()
        } else {
            String::new()
        };
        out.push(serde_json::json!({
            "id": rel.clone(),
            "path": rel.clone(),
            "title": title,
            "kind": kind,
            "sizeBytes": meta.len(),
            "modifiedAt": modified_at,
            "previewText": preview,
            "mediaUrl": if kind == "audio" || kind == "video" || kind == "image" {
                serde_json::Value::String(format!("/api/media/{rel}"))
            } else {
                serde_json::Value::Null
            },
            "editableText": kind == "text",
            "scope": scope_value,
        }));
    }
    Ok(())
}

async fn create_journal_entry_metadata(
    state: &AppState,
    rel_path: &str,
    title: &str,
    content: &str,
    source: &str,
    tags: Option<&[String]>,
) -> Result<serde_json::Value> {
    let preview = truncate_with_ellipsis(content, 240);
    let workspace_dir = state.config.lock().workspace_dir.clone();
    local_store::create_journal_entry_metadata(
        &workspace_dir,
        &local_store::JournalEntryInput {
            title: title.to_string(),
            entry_type: "text".to_string(),
            source: source.to_string(),
            status: "raw".to_string(),
            workspace_path: rel_path.to_string(),
            preview_text: preview,
            text_body: content.to_string(),
            tags_csv: tags.map(|t| t.join(",")).unwrap_or_default(),
            created_at_client: Some(chrono::Utc::now().to_rfc3339()),
        },
    )
}

async fn upsert_media_asset_metadata(
    state: &AppState,
    rel_path: &str,
    content_type: &str,
    kind: &str,
    title: Option<&str>,
    source: &str,
    bytes: u64,
    entry_id: Option<&str>,
) -> Result<serde_json::Value> {
    let workspace_dir = state.config.lock().workspace_dir.clone();
    local_store::create_media_asset_metadata(
        &workspace_dir,
        &local_store::MediaAssetInput {
            title: title.unwrap_or("").to_string(),
            entry_id: entry_id.unwrap_or("").to_string(),
            asset_type: kind.to_string(),
            mime_type: content_type.to_string(),
            source: source.to_string(),
            status: "uploaded".to_string(),
            workspace_path: rel_path.to_string(),
            size_bytes: bytes as i64,
            created_at_client: Some(chrono::Utc::now().to_rfc3339()),
        },
    )
}

/// POST /webhook — main webhook endpoint
async fn handle_webhook(
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

    // ── Bearer token auth (pairing) ──
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

    // ── Webhook secret auth (optional, additional layer) ──
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

    // ── Parse body ──
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

    // ── Idempotency (optional) ──
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
        Err(e) => {
            let duration = started_at.elapsed();
            let sanitized = providers::sanitize_api_error(&e.to_string());

            state
                .observer
                .record_event(&crate::observability::ObserverEvent::LlmResponse {
                    provider: provider_label.clone(),
                    model: model_label.clone(),
                    duration,
                    success: false,
                    error_message: Some(sanitized.clone()),
                    input_tokens: None,
                    output_tokens: None,
                });
            state.observer.record_metric(
                &crate::observability::traits::ObserverMetric::RequestLatency(duration),
            );
            state
                .observer
                .record_event(&crate::observability::ObserverEvent::Error {
                    component: "gateway".to_string(),
                    message: sanitized.clone(),
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

            tracing::error!("Webhook provider error: {}", sanitized);
            let err = serde_json::json!({"error": "LLM request failed"});
            (StatusCode::INTERNAL_SERVER_ERROR, Json(err))
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::memory::{Memory, MemoryCategory, MemoryEntry};
    use crate::providers::Provider;
    use async_trait::async_trait;
    use axum::http::HeaderValue;
    use axum::response::IntoResponse;
    use http_body_util::BodyExt;
    use parking_lot::Mutex;
    use std::sync::atomic::{AtomicUsize, Ordering};

    /// Generate a random hex secret at runtime to avoid hard-coded cryptographic values.
    fn generate_test_secret() -> String {
        let bytes: [u8; 32] = rand::random();
        hex::encode(bytes)
    }

    #[test]
    fn security_body_limit_is_64kb() {
        assert_eq!(MAX_BODY_SIZE, 65_536);
    }

    #[test]
    fn security_timeout_is_30_seconds() {
        assert_eq!(REQUEST_TIMEOUT_SECS, 30);
    }

    #[test]
    fn webhook_body_requires_message_field() {
        let valid = r#"{"message": "hello"}"#;
        let parsed: Result<WebhookBody, _> = serde_json::from_str(valid);
        assert!(parsed.is_ok());
        assert_eq!(parsed.unwrap().message, "hello");

        let missing = r#"{"other": "field"}"#;
        let parsed: Result<WebhookBody, _> = serde_json::from_str(missing);
        assert!(parsed.is_err());
    }

    #[test]
    fn app_state_is_clone() {
        fn assert_clone<T: Clone>() {}
        assert_clone::<AppState>();
    }

    #[tokio::test]
    async fn metrics_endpoint_returns_hint_when_prometheus_is_disabled() {
        let state = AppState {
            config: Arc::new(Mutex::new(Config::default())),
            provider: Arc::new(MockProvider::default()),
            model: "test-model".into(),
            temperature: 0.0,
            mem: Arc::new(MockMemory),
            auto_save: false,
            webhook_secret_hash: None,
            pairing: Arc::new(PairingGuard::new(false, &[])),
            trust_forwarded_headers: false,
            rate_limiter: Arc::new(GatewayRateLimiter::new(100, 100, 100)),
            idempotency_store: Arc::new(IdempotencyStore::new(Duration::from_secs(300), 1000)),
            pb_chat_base_url: None,
            pb_chat_collection: "chat_messages".into(),
            pb_chat_token: None,
            observer: Arc::new(crate::observability::NoopObserver),
            journal_transcription_jobs: Arc::new(Mutex::new(HashMap::new())),
        };

        let response = handle_metrics(State(state)).await.into_response();
        assert_eq!(response.status(), StatusCode::OK);
        assert_eq!(
            response
                .headers()
                .get(header::CONTENT_TYPE)
                .and_then(|value| value.to_str().ok()),
            Some(PROMETHEUS_CONTENT_TYPE)
        );

        let body = response.into_body().collect().await.unwrap().to_bytes();
        let text = String::from_utf8(body.to_vec()).unwrap();
        assert!(text.contains("Prometheus backend not enabled"));
    }

    #[tokio::test]
    async fn metrics_endpoint_renders_prometheus_output() {
        let prom = Arc::new(crate::observability::PrometheusObserver::new());
        crate::observability::Observer::record_event(
            prom.as_ref(),
            &crate::observability::ObserverEvent::HeartbeatTick,
        );

        let observer: Arc<dyn crate::observability::Observer> = prom;
        let state = AppState {
            config: Arc::new(Mutex::new(Config::default())),
            provider: Arc::new(MockProvider::default()),
            model: "test-model".into(),
            temperature: 0.0,
            mem: Arc::new(MockMemory),
            auto_save: false,
            webhook_secret_hash: None,
            pairing: Arc::new(PairingGuard::new(false, &[])),
            trust_forwarded_headers: false,
            rate_limiter: Arc::new(GatewayRateLimiter::new(100, 100, 100)),
            idempotency_store: Arc::new(IdempotencyStore::new(Duration::from_secs(300), 1000)),
            pb_chat_base_url: None,
            pb_chat_collection: "chat_messages".into(),
            pb_chat_token: None,
            observer,
            journal_transcription_jobs: Arc::new(Mutex::new(HashMap::new())),
        };

        let response = handle_metrics(State(state)).await.into_response();
        assert_eq!(response.status(), StatusCode::OK);

        let body = response.into_body().collect().await.unwrap().to_bytes();
        let text = String::from_utf8(body.to_vec()).unwrap();
        assert!(text.contains("zeroclaw_heartbeat_ticks_total 1"));
    }

    #[test]
    fn gateway_rate_limiter_blocks_after_limit() {
        let limiter = GatewayRateLimiter::new(2, 2, 100);
        assert!(limiter.allow_pair("127.0.0.1"));
        assert!(limiter.allow_pair("127.0.0.1"));
        assert!(!limiter.allow_pair("127.0.0.1"));
    }

    #[test]
    fn rate_limiter_sweep_removes_stale_entries() {
        let limiter = SlidingWindowRateLimiter::new(10, Duration::from_secs(60), 100);
        // Add entries for multiple IPs
        assert!(limiter.allow("ip-1"));
        assert!(limiter.allow("ip-2"));
        assert!(limiter.allow("ip-3"));

        {
            let guard = limiter.requests.lock();
            assert_eq!(guard.0.len(), 3);
        }

        // Force a sweep by backdating last_sweep
        {
            let mut guard = limiter.requests.lock();
            guard.1 = Instant::now()
                .checked_sub(Duration::from_secs(RATE_LIMITER_SWEEP_INTERVAL_SECS + 1))
                .unwrap();
            // Clear timestamps for ip-2 and ip-3 to simulate stale entries
            guard.0.get_mut("ip-2").unwrap().clear();
            guard.0.get_mut("ip-3").unwrap().clear();
        }

        // Next allow() call should trigger sweep and remove stale entries
        assert!(limiter.allow("ip-1"));

        {
            let guard = limiter.requests.lock();
            assert_eq!(guard.0.len(), 1, "Stale entries should have been swept");
            assert!(guard.0.contains_key("ip-1"));
        }
    }

    #[test]
    fn rate_limiter_zero_limit_always_allows() {
        let limiter = SlidingWindowRateLimiter::new(0, Duration::from_secs(60), 10);
        for _ in 0..100 {
            assert!(limiter.allow("any-key"));
        }
    }

    #[test]
    fn idempotency_store_rejects_duplicate_key() {
        let store = IdempotencyStore::new(Duration::from_secs(30), 10);
        assert!(store.record_if_new("req-1"));
        assert!(!store.record_if_new("req-1"));
        assert!(store.record_if_new("req-2"));
    }

    #[test]
    fn rate_limiter_bounded_cardinality_evicts_oldest_key() {
        let limiter = SlidingWindowRateLimiter::new(5, Duration::from_secs(60), 2);
        assert!(limiter.allow("ip-1"));
        assert!(limiter.allow("ip-2"));
        assert!(limiter.allow("ip-3"));

        let guard = limiter.requests.lock();
        assert_eq!(guard.0.len(), 2);
        assert!(guard.0.contains_key("ip-2"));
        assert!(guard.0.contains_key("ip-3"));
    }

    #[test]
    fn idempotency_store_bounded_cardinality_evicts_oldest_key() {
        let store = IdempotencyStore::new(Duration::from_secs(300), 2);
        assert!(store.record_if_new("k1"));
        std::thread::sleep(Duration::from_millis(2));
        assert!(store.record_if_new("k2"));
        std::thread::sleep(Duration::from_millis(2));
        assert!(store.record_if_new("k3"));

        let keys = store.keys.lock();
        assert_eq!(keys.len(), 2);
        assert!(!keys.contains_key("k1"));
        assert!(keys.contains_key("k2"));
        assert!(keys.contains_key("k3"));
    }

    #[test]
    fn client_key_defaults_to_peer_addr_when_untrusted_proxy_mode() {
        let peer = SocketAddr::from(([10, 0, 0, 5], 42617));
        let mut headers = HeaderMap::new();
        headers.insert(
            "X-Forwarded-For",
            HeaderValue::from_static("198.51.100.10, 203.0.113.11"),
        );

        let key = client_key_from_request(Some(peer), &headers, false);
        assert_eq!(key, "10.0.0.5");
    }

    #[test]
    fn client_key_uses_forwarded_ip_only_in_trusted_proxy_mode() {
        let peer = SocketAddr::from(([10, 0, 0, 5], 42617));
        let mut headers = HeaderMap::new();
        headers.insert(
            "X-Forwarded-For",
            HeaderValue::from_static("198.51.100.10, 203.0.113.11"),
        );

        let key = client_key_from_request(Some(peer), &headers, true);
        assert_eq!(key, "198.51.100.10");
    }

    #[test]
    fn client_key_falls_back_to_peer_when_forwarded_header_invalid() {
        let peer = SocketAddr::from(([10, 0, 0, 5], 42617));
        let mut headers = HeaderMap::new();
        headers.insert("X-Forwarded-For", HeaderValue::from_static("garbage-value"));

        let key = client_key_from_request(Some(peer), &headers, true);
        assert_eq!(key, "10.0.0.5");
    }

    #[test]
    fn normalize_max_keys_uses_fallback_for_zero() {
        assert_eq!(normalize_max_keys(0, 10_000), 10_000);
        assert_eq!(normalize_max_keys(0, 0), 1);
    }

    #[test]
    fn normalize_max_keys_preserves_nonzero_values() {
        assert_eq!(normalize_max_keys(2_048, 10_000), 2_048);
        assert_eq!(normalize_max_keys(1, 10_000), 1);
    }

    #[tokio::test]
    async fn persist_pairing_tokens_writes_config_tokens() {
        let temp = tempfile::tempdir().unwrap();
        let config_path = temp.path().join("config.toml");
        let workspace_path = temp.path().join("workspace");

        let mut config = Config::default();
        config.config_path = config_path.clone();
        config.workspace_dir = workspace_path;
        config.save().await.unwrap();

        let guard = PairingGuard::new(true, &[]);
        let code = guard.pairing_code().unwrap();
        let token = guard.try_pair(&code, "test_client").await.unwrap().unwrap();
        assert!(guard.is_authenticated(&token));

        let shared_config = Arc::new(Mutex::new(config));
        persist_pairing_tokens(shared_config.clone(), &guard)
            .await
            .unwrap();

        let saved = tokio::fs::read_to_string(config_path).await.unwrap();
        let parsed: Config = toml::from_str(&saved).unwrap();
        assert_eq!(parsed.gateway.paired_tokens.len(), 1);
        let persisted = &parsed.gateway.paired_tokens[0];
        assert_eq!(persisted.len(), 64);
        assert!(persisted.chars().all(|c| c.is_ascii_hexdigit()));

        let in_memory = shared_config.lock();
        assert_eq!(in_memory.gateway.paired_tokens.len(), 1);
        assert_eq!(&in_memory.gateway.paired_tokens[0], persisted);
    }

    #[test]
    fn webhook_memory_key_is_unique() {
        let key1 = webhook_memory_key();
        let key2 = webhook_memory_key();

        assert!(key1.starts_with("webhook_msg_"));
        assert!(key2.starts_with("webhook_msg_"));
        assert_ne!(key1, key2);
    }

    #[derive(Default)]
    struct MockMemory;

    #[async_trait]
    impl Memory for MockMemory {
        fn name(&self) -> &str {
            "mock"
        }

        async fn store(
            &self,
            _key: &str,
            _content: &str,
            _category: MemoryCategory,
            _session_id: Option<&str>,
        ) -> anyhow::Result<()> {
            Ok(())
        }

        async fn recall(
            &self,
            _query: &str,
            _limit: usize,
            _session_id: Option<&str>,
        ) -> anyhow::Result<Vec<MemoryEntry>> {
            Ok(Vec::new())
        }

        async fn get(&self, _key: &str) -> anyhow::Result<Option<MemoryEntry>> {
            Ok(None)
        }

        async fn list(
            &self,
            _category: Option<&MemoryCategory>,
            _session_id: Option<&str>,
        ) -> anyhow::Result<Vec<MemoryEntry>> {
            Ok(Vec::new())
        }

        async fn forget(&self, _key: &str) -> anyhow::Result<bool> {
            Ok(false)
        }

        async fn count(&self) -> anyhow::Result<usize> {
            Ok(0)
        }

        async fn health_check(&self) -> bool {
            true
        }
    }

    #[derive(Default)]
    struct MockProvider {
        calls: AtomicUsize,
    }

    #[async_trait]
    impl Provider for MockProvider {
        async fn chat_with_system(
            &self,
            _system_prompt: Option<&str>,
            _message: &str,
            _model: &str,
            _temperature: f64,
        ) -> anyhow::Result<String> {
            self.calls.fetch_add(1, Ordering::SeqCst);
            Ok("ok".into())
        }
    }

    #[derive(Default)]
    struct TrackingMemory {
        keys: Mutex<Vec<String>>,
    }

    #[async_trait]
    impl Memory for TrackingMemory {
        fn name(&self) -> &str {
            "tracking"
        }

        async fn store(
            &self,
            key: &str,
            _content: &str,
            _category: MemoryCategory,
            _session_id: Option<&str>,
        ) -> anyhow::Result<()> {
            self.keys.lock().push(key.to_string());
            Ok(())
        }

        async fn recall(
            &self,
            _query: &str,
            _limit: usize,
            _session_id: Option<&str>,
        ) -> anyhow::Result<Vec<MemoryEntry>> {
            Ok(Vec::new())
        }

        async fn get(&self, _key: &str) -> anyhow::Result<Option<MemoryEntry>> {
            Ok(None)
        }

        async fn list(
            &self,
            _category: Option<&MemoryCategory>,
            _session_id: Option<&str>,
        ) -> anyhow::Result<Vec<MemoryEntry>> {
            Ok(Vec::new())
        }

        async fn forget(&self, _key: &str) -> anyhow::Result<bool> {
            Ok(false)
        }

        async fn count(&self) -> anyhow::Result<usize> {
            let size = self.keys.lock().len();
            Ok(size)
        }

        async fn health_check(&self) -> bool {
            true
        }
    }

    fn test_connect_info() -> ConnectInfo<SocketAddr> {
        ConnectInfo(SocketAddr::from(([127, 0, 0, 1], 30_300)))
    }

    #[tokio::test]
    async fn webhook_idempotency_skips_duplicate_provider_calls() {
        let provider_impl = Arc::new(MockProvider::default());
        let provider: Arc<dyn Provider> = provider_impl.clone();
        let memory: Arc<dyn Memory> = Arc::new(MockMemory);

        let state = AppState {
            config: Arc::new(Mutex::new(Config::default())),
            provider,
            model: "test-model".into(),
            temperature: 0.0,
            mem: memory,
            auto_save: false,
            webhook_secret_hash: None,
            pairing: Arc::new(PairingGuard::new(false, &[])),
            trust_forwarded_headers: false,
            rate_limiter: Arc::new(GatewayRateLimiter::new(100, 100, 100)),
            idempotency_store: Arc::new(IdempotencyStore::new(Duration::from_secs(300), 1000)),
            pb_chat_base_url: None,
            pb_chat_collection: "chat_messages".into(),
            pb_chat_token: None,
            observer: Arc::new(crate::observability::NoopObserver),
            journal_transcription_jobs: Arc::new(Mutex::new(HashMap::new())),
        };

        let mut headers = HeaderMap::new();
        headers.insert("X-Idempotency-Key", HeaderValue::from_static("abc-123"));

        let body = Ok(Json(WebhookBody {
            message: "hello".into(),
        }));
        let first = handle_webhook(
            State(state.clone()),
            test_connect_info(),
            headers.clone(),
            body,
        )
        .await
        .into_response();
        assert_eq!(first.status(), StatusCode::OK);

        let body = Ok(Json(WebhookBody {
            message: "hello".into(),
        }));
        let second = handle_webhook(State(state), test_connect_info(), headers, body)
            .await
            .into_response();
        assert_eq!(second.status(), StatusCode::OK);

        let payload = second.into_body().collect().await.unwrap().to_bytes();
        let parsed: serde_json::Value = serde_json::from_slice(&payload).unwrap();
        assert_eq!(parsed["status"], "duplicate");
        assert_eq!(parsed["idempotent"], true);
        assert_eq!(provider_impl.calls.load(Ordering::SeqCst), 1);
    }

    #[tokio::test]
    async fn webhook_autosave_stores_distinct_keys_per_request() {
        let provider_impl = Arc::new(MockProvider::default());
        let provider: Arc<dyn Provider> = provider_impl.clone();

        let tracking_impl = Arc::new(TrackingMemory::default());
        let memory: Arc<dyn Memory> = tracking_impl.clone();

        let state = AppState {
            config: Arc::new(Mutex::new(Config::default())),
            provider,
            model: "test-model".into(),
            temperature: 0.0,
            mem: memory,
            auto_save: true,
            webhook_secret_hash: None,
            pairing: Arc::new(PairingGuard::new(false, &[])),
            trust_forwarded_headers: false,
            rate_limiter: Arc::new(GatewayRateLimiter::new(100, 100, 100)),
            idempotency_store: Arc::new(IdempotencyStore::new(Duration::from_secs(300), 1000)),
            pb_chat_base_url: None,
            pb_chat_collection: "chat_messages".into(),
            pb_chat_token: None,
            observer: Arc::new(crate::observability::NoopObserver),
            journal_transcription_jobs: Arc::new(Mutex::new(HashMap::new())),
        };

        let headers = HeaderMap::new();

        let body1 = Ok(Json(WebhookBody {
            message: "hello one".into(),
        }));
        let first = handle_webhook(
            State(state.clone()),
            test_connect_info(),
            headers.clone(),
            body1,
        )
        .await
        .into_response();
        assert_eq!(first.status(), StatusCode::OK);

        let body2 = Ok(Json(WebhookBody {
            message: "hello two".into(),
        }));
        let second = handle_webhook(State(state), test_connect_info(), headers, body2)
            .await
            .into_response();
        assert_eq!(second.status(), StatusCode::OK);

        let keys = tracking_impl.keys.lock().clone();
        assert_eq!(keys.len(), 2);
        assert_ne!(keys[0], keys[1]);
        assert!(keys[0].starts_with("webhook_msg_"));
        assert!(keys[1].starts_with("webhook_msg_"));
        assert_eq!(provider_impl.calls.load(Ordering::SeqCst), 2);
    }

    #[test]
    fn webhook_secret_hash_is_deterministic_and_nonempty() {
        let secret_a = generate_test_secret();
        let secret_b = generate_test_secret();
        let one = hash_webhook_secret(&secret_a);
        let two = hash_webhook_secret(&secret_a);
        let other = hash_webhook_secret(&secret_b);

        assert_eq!(one, two);
        assert_ne!(one, other);
        assert_eq!(one.len(), 64);
    }

    #[tokio::test]
    async fn webhook_secret_hash_rejects_missing_header() {
        let provider_impl = Arc::new(MockProvider::default());
        let provider: Arc<dyn Provider> = provider_impl.clone();
        let memory: Arc<dyn Memory> = Arc::new(MockMemory);
        let secret = generate_test_secret();

        let state = AppState {
            config: Arc::new(Mutex::new(Config::default())),
            provider,
            model: "test-model".into(),
            temperature: 0.0,
            mem: memory,
            auto_save: false,
            webhook_secret_hash: Some(Arc::from(hash_webhook_secret(&secret))),
            pairing: Arc::new(PairingGuard::new(false, &[])),
            trust_forwarded_headers: false,
            rate_limiter: Arc::new(GatewayRateLimiter::new(100, 100, 100)),
            idempotency_store: Arc::new(IdempotencyStore::new(Duration::from_secs(300), 1000)),
            pb_chat_base_url: None,
            pb_chat_collection: "chat_messages".into(),
            pb_chat_token: None,
            observer: Arc::new(crate::observability::NoopObserver),
            journal_transcription_jobs: Arc::new(Mutex::new(HashMap::new())),
        };

        let response = handle_webhook(
            State(state),
            test_connect_info(),
            HeaderMap::new(),
            Ok(Json(WebhookBody {
                message: "hello".into(),
            })),
        )
        .await
        .into_response();

        assert_eq!(response.status(), StatusCode::UNAUTHORIZED);
        assert_eq!(provider_impl.calls.load(Ordering::SeqCst), 0);
    }

    #[tokio::test]
    async fn webhook_secret_hash_rejects_invalid_header() {
        let provider_impl = Arc::new(MockProvider::default());
        let provider: Arc<dyn Provider> = provider_impl.clone();
        let memory: Arc<dyn Memory> = Arc::new(MockMemory);
        let valid_secret = generate_test_secret();
        let wrong_secret = generate_test_secret();

        let state = AppState {
            config: Arc::new(Mutex::new(Config::default())),
            provider,
            model: "test-model".into(),
            temperature: 0.0,
            mem: memory,
            auto_save: false,
            webhook_secret_hash: Some(Arc::from(hash_webhook_secret(&valid_secret))),
            pairing: Arc::new(PairingGuard::new(false, &[])),
            trust_forwarded_headers: false,
            rate_limiter: Arc::new(GatewayRateLimiter::new(100, 100, 100)),
            idempotency_store: Arc::new(IdempotencyStore::new(Duration::from_secs(300), 1000)),
            pb_chat_base_url: None,
            pb_chat_collection: "chat_messages".into(),
            pb_chat_token: None,
            observer: Arc::new(crate::observability::NoopObserver),
            journal_transcription_jobs: Arc::new(Mutex::new(HashMap::new())),
        };

        let mut headers = HeaderMap::new();
        headers.insert(
            "X-Webhook-Secret",
            HeaderValue::from_str(&wrong_secret).unwrap(),
        );

        let response = handle_webhook(
            State(state),
            test_connect_info(),
            headers,
            Ok(Json(WebhookBody {
                message: "hello".into(),
            })),
        )
        .await
        .into_response();

        assert_eq!(response.status(), StatusCode::UNAUTHORIZED);
        assert_eq!(provider_impl.calls.load(Ordering::SeqCst), 0);
    }

    #[tokio::test]
    async fn webhook_secret_hash_accepts_valid_header() {
        let provider_impl = Arc::new(MockProvider::default());
        let provider: Arc<dyn Provider> = provider_impl.clone();
        let memory: Arc<dyn Memory> = Arc::new(MockMemory);
        let secret = generate_test_secret();

        let state = AppState {
            config: Arc::new(Mutex::new(Config::default())),
            provider,
            model: "test-model".into(),
            temperature: 0.0,
            mem: memory,
            auto_save: false,
            webhook_secret_hash: Some(Arc::from(hash_webhook_secret(&secret))),
            pairing: Arc::new(PairingGuard::new(false, &[])),
            trust_forwarded_headers: false,
            rate_limiter: Arc::new(GatewayRateLimiter::new(100, 100, 100)),
            idempotency_store: Arc::new(IdempotencyStore::new(Duration::from_secs(300), 1000)),
            pb_chat_base_url: None,
            pb_chat_collection: "chat_messages".into(),
            pb_chat_token: None,
            observer: Arc::new(crate::observability::NoopObserver),
            journal_transcription_jobs: Arc::new(Mutex::new(HashMap::new())),
        };

        let mut headers = HeaderMap::new();
        headers.insert("X-Webhook-Secret", HeaderValue::from_str(&secret).unwrap());

        let response = handle_webhook(
            State(state),
            test_connect_info(),
            headers,
            Ok(Json(WebhookBody {
                message: "hello".into(),
            })),
        )
        .await
        .into_response();

        assert_eq!(response.status(), StatusCode::OK);
        assert_eq!(provider_impl.calls.load(Ordering::SeqCst), 1);
    }

    // ══════════════════════════════════════════════════════════
    // IdempotencyStore Edge-Case Tests
    // ══════════════════════════════════════════════════════════

    #[test]
    fn idempotency_store_allows_different_keys() {
        let store = IdempotencyStore::new(Duration::from_secs(60), 100);
        assert!(store.record_if_new("key-a"));
        assert!(store.record_if_new("key-b"));
        assert!(store.record_if_new("key-c"));
        assert!(store.record_if_new("key-d"));
    }

    #[test]
    fn idempotency_store_max_keys_clamped_to_one() {
        let store = IdempotencyStore::new(Duration::from_secs(60), 0);
        assert!(store.record_if_new("only-key"));
        assert!(!store.record_if_new("only-key"));
    }

    #[test]
    fn idempotency_store_rapid_duplicate_rejected() {
        let store = IdempotencyStore::new(Duration::from_secs(300), 100);
        assert!(store.record_if_new("rapid"));
        assert!(!store.record_if_new("rapid"));
    }

    #[test]
    fn idempotency_store_accepts_after_ttl_expires() {
        let store = IdempotencyStore::new(Duration::from_millis(1), 100);
        assert!(store.record_if_new("ttl-key"));
        std::thread::sleep(Duration::from_millis(10));
        assert!(store.record_if_new("ttl-key"));
    }

    #[test]
    fn idempotency_store_eviction_preserves_newest() {
        let store = IdempotencyStore::new(Duration::from_secs(300), 1);
        assert!(store.record_if_new("old-key"));
        std::thread::sleep(Duration::from_millis(2));
        assert!(store.record_if_new("new-key"));

        let keys = store.keys.lock();
        assert_eq!(keys.len(), 1);
        assert!(!keys.contains_key("old-key"));
        assert!(keys.contains_key("new-key"));
    }

    #[test]
    fn rate_limiter_allows_after_window_expires() {
        let window = Duration::from_millis(50);
        let limiter = SlidingWindowRateLimiter::new(2, window, 100);
        assert!(limiter.allow("ip-1"));
        assert!(limiter.allow("ip-1"));
        assert!(!limiter.allow("ip-1")); // blocked

        // Wait for window to expire
        std::thread::sleep(Duration::from_millis(60));

        // Should be allowed again
        assert!(limiter.allow("ip-1"));
    }

    #[test]
    fn rate_limiter_independent_keys_tracked_separately() {
        let limiter = SlidingWindowRateLimiter::new(2, Duration::from_secs(60), 100);
        assert!(limiter.allow("ip-1"));
        assert!(limiter.allow("ip-1"));
        assert!(!limiter.allow("ip-1")); // ip-1 blocked

        // ip-2 should still work
        assert!(limiter.allow("ip-2"));
        assert!(limiter.allow("ip-2"));
        assert!(!limiter.allow("ip-2")); // ip-2 now blocked
    }

    #[test]
    fn rate_limiter_exact_boundary_at_max_keys() {
        let limiter = SlidingWindowRateLimiter::new(10, Duration::from_secs(60), 3);
        assert!(limiter.allow("ip-1"));
        assert!(limiter.allow("ip-2"));
        assert!(limiter.allow("ip-3"));
        // At capacity now
        assert!(limiter.allow("ip-4")); // should evict ip-1

        let guard = limiter.requests.lock();
        assert_eq!(guard.0.len(), 3);
        assert!(
            !guard.0.contains_key("ip-1"),
            "ip-1 should have been evicted"
        );
        assert!(guard.0.contains_key("ip-2"));
        assert!(guard.0.contains_key("ip-3"));
        assert!(guard.0.contains_key("ip-4"));
    }

    #[test]
    fn gateway_rate_limiter_pair_and_webhook_are_independent() {
        let limiter = GatewayRateLimiter::new(2, 3, 100);

        // Exhaust pair limit
        assert!(limiter.allow_pair("ip-1"));
        assert!(limiter.allow_pair("ip-1"));
        assert!(!limiter.allow_pair("ip-1")); // pair blocked

        // Webhook should still work
        assert!(limiter.allow_webhook("ip-1"));
        assert!(limiter.allow_webhook("ip-1"));
        assert!(limiter.allow_webhook("ip-1"));
        assert!(!limiter.allow_webhook("ip-1")); // webhook now blocked
    }

    #[test]
    fn rate_limiter_single_key_max_allows_one_request() {
        let limiter = SlidingWindowRateLimiter::new(5, Duration::from_secs(60), 1);
        assert!(limiter.allow("ip-1"));
        assert!(limiter.allow("ip-2")); // evicts ip-1

        let guard = limiter.requests.lock();
        assert_eq!(guard.0.len(), 1);
        assert!(guard.0.contains_key("ip-2"));
        assert!(!guard.0.contains_key("ip-1"));
    }

    #[test]
    fn rate_limiter_concurrent_access_safe() {
        use std::sync::Arc;

        let limiter = Arc::new(SlidingWindowRateLimiter::new(
            1000,
            Duration::from_secs(60),
            1000,
        ));
        let mut handles = Vec::new();

        for i in 0..10 {
            let limiter = limiter.clone();
            handles.push(std::thread::spawn(move || {
                for j in 0..100 {
                    limiter.allow(&format!("thread-{i}-req-{j}"));
                }
            }));
        }

        for handle in handles {
            handle.join().unwrap();
        }

        // Should not panic or deadlock
        let guard = limiter.requests.lock();
        assert!(guard.0.len() <= 1000, "should respect max_keys");
    }

    #[test]
    fn idempotency_store_concurrent_access_safe() {
        use std::sync::Arc;

        let store = Arc::new(IdempotencyStore::new(Duration::from_secs(300), 1000));
        let mut handles = Vec::new();

        for i in 0..10 {
            let store = store.clone();
            handles.push(std::thread::spawn(move || {
                for j in 0..100 {
                    store.record_if_new(&format!("thread-{i}-key-{j}"));
                }
            }));
        }

        for handle in handles {
            handle.join().unwrap();
        }

        let keys = store.keys.lock();
        assert!(keys.len() <= 1000, "should respect max_keys");
    }

    #[test]
    fn rate_limiter_rapid_burst_then_cooldown() {
        let limiter = SlidingWindowRateLimiter::new(5, Duration::from_millis(50), 100);

        // Burst: use all 5 requests
        for _ in 0..5 {
            assert!(limiter.allow("burst-ip"));
        }
        assert!(!limiter.allow("burst-ip")); // 6th should fail

        // Cooldown
        std::thread::sleep(Duration::from_millis(60));

        // Should be allowed again
        assert!(limiter.allow("burst-ip"));
    }

    #[test]
    fn list_library_feed_scope_includes_posts_only() {
        let temp = tempfile::tempdir().unwrap();
        let workspace = temp.path();

        let posts_dir = workspace.join("posts");
        let legacy_feed_dir = workspace.join("journals/processed");
        std::fs::create_dir_all(&posts_dir).unwrap();
        std::fs::create_dir_all(&legacy_feed_dir).unwrap();

        std::fs::write(posts_dir.join("workflow_post.md"), "# post\n").unwrap();
        std::fs::write(legacy_feed_dir.join("legacy_clip.md"), "# old\n").unwrap();

        let items = list_workspace_library_items(workspace, "feed", 20).unwrap();
        assert!(!items.is_empty());

        let paths: Vec<String> = items
            .iter()
            .filter_map(|item| item.get("path").and_then(serde_json::Value::as_str))
            .map(ToString::to_string)
            .collect();

        assert!(paths.iter().any(|path| path.starts_with("posts/")));
        assert!(!paths.iter().any(|path| path.starts_with("journals/processed/")));
    }

    #[test]
    fn list_library_all_scope_keeps_journal_and_feed_labels() {
        let temp = tempfile::tempdir().unwrap();
        let workspace = temp.path();

        std::fs::create_dir_all(workspace.join("posts")).unwrap();
        std::fs::create_dir_all(workspace.join("journals/text")).unwrap();
        std::fs::write(workspace.join("posts/feed_note.md"), "# feed\n").unwrap();
        std::fs::write(workspace.join("journals/text/note.md"), "# journal\n").unwrap();

        let items = list_workspace_library_items(workspace, "all", 20).unwrap();
        assert!(items.len() >= 2);

        let mut has_feed = false;
        let mut has_journal = false;

        for item in items {
            let path = item
                .get("path")
                .and_then(serde_json::Value::as_str)
                .unwrap_or_default();
            let scope = item
                .get("scope")
                .and_then(serde_json::Value::as_str)
                .unwrap_or_default();

            if path.starts_with("posts/") && scope == "feed" {
                has_feed = true;
            }
            if path.starts_with("journals/") && scope == "journal" {
                has_journal = true;
            }
        }

        assert!(has_feed);
        assert!(has_journal);
    }

    fn sample_workflow_store() -> FeedWorkflowSettingsStore {
        let mut store = FeedWorkflowSettingsStore::default();

        let daily_key = "daily_summary";
        let daily_record = FeedWorkflowRecord {
            workflow_key: daily_key.to_string(),
            workflow_bot: "DailySummaryBot".to_string(),
            script_path: "scripts/daily_summary_skill/run_daily_summary.py".to_string(),
            output_prefix: "posts/daily_summary/".to_string(),
            editable_files: vec![
                "scripts/daily_summary_skill/run_daily_summary.py".to_string(),
                "skills/daily_summary/SKILL.md".to_string(),
            ],
            settings: workflow_default_settings(),
        };
        store.workflows.insert(
            daily_key.to_string(),
            normalize_workflow_record(daily_key, daily_record),
        );

        let audio_key = "audio_roundup";
        let audio_record = FeedWorkflowRecord {
            workflow_key: audio_key.to_string(),
            workflow_bot: "AudioRoundupBot".to_string(),
            script_path: "scripts/audio_roundup_skill/run_audio_roundup.py".to_string(),
            output_prefix: "posts/audio_roundup/".to_string(),
            editable_files: vec![
                "scripts/audio_roundup_skill/run_audio_roundup.py".to_string(),
                "skills/audio_roundup/SKILL.md".to_string(),
            ],
            settings: workflow_default_settings(),
        };
        store.workflows.insert(
            audio_key.to_string(),
            normalize_workflow_record(audio_key, audio_record),
        );

        store
    }

    #[test]
    fn workflow_path_mapping_uses_dynamic_store_output_prefixes() {
        let store = sample_workflow_store();

        let daily = workflow_for_feed_path(&store, "posts/daily_summary/20260303_summary.md");
        assert!(daily.is_some());
        let daily = daily.unwrap();
        assert_eq!(daily.key, "daily_summary");
        assert_eq!(daily.bot_name, "DailySummaryBot");

        let audio = workflow_for_feed_path(&store, "posts/audio_roundup/20260303/clip_01.mp4");
        assert!(audio.is_some());
        let audio = audio.unwrap();
        assert_eq!(audio.key, "audio_roundup");
        assert_eq!(audio.bot_name, "AudioRoundupBot");

        assert!(workflow_for_feed_path(&store, "posts/other/something.md").is_none());
    }

    #[test]
    fn workflow_creation_prompt_embeds_script_payload_and_overwrite_instruction() {
        let prompt = render_workflow_creation_prompt(
            "Daily Summary",
            "daily_summary",
            "DailySummaryBot",
            "text",
            "journals/text",
            "scripts/daily_summary_skill/run_daily_summary.py",
            "skills/daily_summary/SKILL.md",
            "posts/daily_summary",
            "Write in a clear, natural voice.",
            "# Workflow Bot Creation Skill\n",
            "#!/usr/bin/env python3\nprint('template')\n",
        );
        assert!(prompt.contains("## Script File Payload (authoritative)"));
        assert!(prompt.contains(
            "Do not respond with only a file path reference."
        ));
        assert!(prompt.contains("### `scripts/daily_summary_skill/run_daily_summary.py` initial content"));
        assert!(prompt.contains("print('template')"));
        assert!(prompt.contains("Replace `scripts/daily_summary_skill/run_daily_summary.py` with your full updated script content"));
    }

    #[test]
    fn workflow_comment_prompt_mentions_allowed_files_and_guardrails() {
        let store = sample_workflow_store();
        let wf = workflow_definition_by_key(&store, "daily_summary").unwrap();
        let prompt = workflow_comment_prompt(
            &wf,
            "posts/daily_summary/item.md",
            "Make tone more human and less robotic",
        );
        assert!(prompt.contains("Workflow: DailySummaryBot (daily_summary)"));
        assert!(prompt.contains("scripts/daily_summary_skill/run_daily_summary.py"));
        assert!(prompt.contains("Keep feed output rooted under `posts/daily_summary/`"));
    }

    #[test]
    fn workflow_self_heal_prompt_mentions_allowed_files_and_command() {
        let store = sample_workflow_store();
        let wf = workflow_definition_by_key(&store, "audio_roundup").unwrap();
        let prompt = workflow_self_heal_prompt(
            &wf,
            &wf.bot_name,
            "workspace-script scripts/audio_roundup_skill/run_audio_roundup.py --mode random --random-count 1",
            "python3: can't open file 'scripts/audio_roundup_skill/processor.py'",
            1,
            1,
        );
        assert!(prompt.contains("workflow supervisor"));
        assert!(prompt.contains("scripts/audio_roundup_skill/run_audio_roundup.py"));
        assert!(prompt.contains("can't open file"));
        assert!(prompt.contains("Target command"));
    }

    #[test]
    fn workflow_command_preview_respects_mode_controls() {
        let store = sample_workflow_store();
        let wf = workflow_definition_by_key(&store, "daily_summary").unwrap();
        let mut settings = workflow_default_settings();

        settings.mode = FeedWorkflowMode::DateRange;
        settings.days = 5;
        let date_cmd = workflow_command_preview(&wf, &settings);
        assert!(date_cmd.contains("workspace-script"));
        assert!(date_cmd.contains("scripts/daily_summary_skill/run_daily_summary.py"));
        assert!(date_cmd.contains("--mode date_range"));
        assert!(date_cmd.contains("--days 5"));

        settings.mode = FeedWorkflowMode::Random;
        settings.random_count = 3;
        let random_cmd = workflow_command_preview(&wf, &settings);
        assert!(random_cmd.contains("--mode random"));
        assert!(random_cmd.contains("--random-count 3"));
    }

    #[test]
    fn normalize_workflow_settings_clamps_out_of_range_values() {
        let settings = FeedWorkflowSettings {
            mode: FeedWorkflowMode::Random,
            days: 999,
            random_count: 0,
            schedule_enabled: true,
            schedule_cron: "   ".to_string(),
            schedule_tz: Some("   ".to_string()),
            prompt: None,
        };

        let normalized = normalize_workflow_settings(settings);
        assert_eq!(normalized.days, 30);
        assert_eq!(normalized.random_count, 1);
        assert_eq!(normalized.schedule_cron, default_workflow_schedule_cron());
        assert!(normalized.schedule_tz.is_none());
    }

    #[test]
    fn workflow_comment_quickfix_is_noop() {
        let store = sample_workflow_store();
        let wf = workflow_definition_by_key(&store, "audio_roundup").unwrap();
        let temp = tempfile::tempdir().unwrap();

        let result = maybe_apply_workflow_comment_quickfix(
            temp.path(),
            &wf,
            "posts/audio_roundup/20260303_audio_roundup.md",
            "please fix this import error",
        )
        .unwrap();
        assert!(result.is_none());
    }

    #[test]
    fn workflow_run_quickfix_adds_missing_prompt_arg_for_legacy_script() {
        let store = sample_workflow_store();
        let wf = workflow_definition_by_key(&store, "daily_summary").unwrap();
        let temp = tempfile::tempdir().unwrap();
        let script_path = temp.path().join(&wf.script_path);
        std::fs::create_dir_all(script_path.parent().unwrap()).unwrap();
        std::fs::write(
            &script_path,
            "#!/usr/bin/env python3\n\
from __future__ import annotations\n\
\n\
import argparse\n\
\n\
USER_PROMPT = \"\"\n\
\n\
def parse_args() -> argparse.Namespace:\n\
    parser = argparse.ArgumentParser(description=\"Generated workflow bot script\")\n\
    parser.add_argument(\"--mode\", choices=[\"date_range\", \"random\"], default=\"date_range\")\n\
    parser.add_argument(\"--days\", type=int, default=7)\n\
    parser.add_argument(\"--random-count\", type=int, default=1)\n\
    return parser.parse_args()\n\
",
        )
        .unwrap();

        let result = maybe_apply_workflow_run_quickfix(
            temp.path(),
            &wf,
            "run_tweeto.py: error: unrecognized arguments: --prompt \"generate insightful tweets\"",
        )
        .unwrap();
        assert!(result.is_some());

        let script = std::fs::read_to_string(&script_path).unwrap();
        assert!(script.contains("parser.add_argument(\"--prompt\", default=USER_PROMPT)"));
    }

    #[test]
    fn workflow_run_quickfix_skips_when_error_is_unrelated() {
        let store = sample_workflow_store();
        let wf = workflow_definition_by_key(&store, "daily_summary").unwrap();
        let temp = tempfile::tempdir().unwrap();

        let result = maybe_apply_workflow_run_quickfix(
            temp.path(),
            &wf,
            "{\"ok\": false, \"error\": \"script missing\"}",
        )
        .unwrap();
        assert!(result.is_none());
    }
}
