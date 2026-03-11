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
pub mod feed_web_sources;
pub mod workspace_synthesizer;

use crate::config::{Config, TranscriptionConfig};
use crate::gateway::feed_web_sources::DEFAULT_FEED_WEB_SOURCES;
use crate::media::{command_media_backend, MediaToolCapabilities};
use crate::memory::{self, Memory, MemoryCategory};
use crate::memory::vector::{bytes_to_vec, cosine_similarity, vec_to_bytes};
use crate::providers::{self, ChatMessage, Provider};
use crate::security::pairing::{constant_time_eq, is_public_bind, PairingGuard};
use crate::tools::web_search_tool::WebSearchTool;
use crate::util::truncate_with_ellipsis;
use anyhow::{Context, Result};
use base64::{engine::general_purpose::STANDARD as BASE64_STANDARD, Engine as _};
use chrono::{Datelike, Utc};
use axum::{
    extract::{ConnectInfo, Path as AxumPath, Query, Request, State},
    http::{header, HeaderMap, Method, StatusCode},
    response::{IntoResponse, Json},
    routing::{get, patch, post},
    Router,
};
use http_body_util::BodyExt as _;
use parking_lot::Mutex;
use regex::Regex;
use std::collections::{BTreeSet, HashMap, HashSet};
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
/// Workflow template creation timeout (5 min) to allow agent skill authoring.
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
const SYNC_ALLOWED_ROOTS: &[&str] = &["journals", "posts", "skills"];
const CONTENT_AGENT_APP_OPEN_STALE_SECS: i64 = 15 * 60;
const WORKSPACE_SYNTHESIZER_WORKFLOW_KEY: &str = "workspace_synthesizer";
const LEGACY_AUDIO_INSIGHT_CLIPS_GOAL: &str =
    "Use my journal notes and available audio/video transcripts to identify practical insights and turn them into concise feed-ready posts, with each post saved as a separate file in posts/.";

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

    if config.memory.embedding_provider.trim().eq_ignore_ascii_case("builtin") {
        let provider = config.memory.embedding_provider.clone();
        let model = config.memory.embedding_model.clone();
        tokio::spawn(async move {
            if let Err(err) =
                memory::embeddings::prewarm_builtin_embedding_assets(&provider, &model).await
            {
                tracing::warn!(
                    error = %err,
                    "Failed to prewarm local builtin embedding assets"
                );
            }
        });
    }

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
        .route("/api/media/capabilities", get(handle_media_capabilities))
        .route("/webhook", post(handle_webhook))
        .route("/api/chat/messages", get(handle_chat_list).post(handle_chat_send))
        .route(
            "/api/feed/workflow-comment",
            post(handle_feed_workflow_comment),
        )
        .route("/api/feed/workflow-settings", get(handle_feed_workflow_settings))
        .route(
            "/api/feed/bluesky/personalized",
            post(handle_feed_personalized),
        )
        .route("/api/feed/personalized", post(handle_feed_personalized))
        .route("/api/sync/export", get(handle_sync_export))
        .route("/api/sync/import", post(handle_sync_import))
        .route("/api/feed/workflow-run", post(handle_feed_workflow_run))
        .route("/api/feed/workflow-auto-run", post(handle_feed_workflow_auto_run))
        .route(
            "/api/workspace/synthesizer/status",
            get(handle_workspace_synthesizer_status),
        )
        .route(
            "/api/workspace/synthesizer/run",
            post(handle_workspace_synthesizer_run),
        )
        .route(
            "/api/workspace/synthesizer/auto-run",
            post(handle_workspace_synthesizer_auto_run),
        )
        .route("/api/workspace/todos", get(handle_workspace_todos_list))
        .route(
            "/api/workspace/todos/{todo_id}",
            patch(handle_workspace_todo_update),
        )
        .route("/api/workspace/events", get(handle_workspace_events_list))
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

    // Content-agent creation can take longer because it invokes the agent to author skills.
    let workflow_template_router = Router::new()
        .route(
            "/api/feed/workflow-settings",
            post(handle_feed_workflow_settings_update),
        )
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
    let media_capabilities = local_media_capabilities(&config);
    let body = serde_json::json!({
        "defaultProvider": config.default_provider.unwrap_or_default(),
        "defaultModel": config.default_model.unwrap_or_default(),
        "transcriptionEnabled": config.transcription.enabled,
        "transcriptionModel": config.transcription.model,
        "availableTranscriptionModels": transcription_models,
        "mediaCapabilities": media_capabilities,
        "mediaSummary": media_capabilities.summary(),
    });
    (StatusCode::OK, Json(body)).into_response()
}

fn local_media_capabilities(config: &Config) -> MediaToolCapabilities {
    command_media_backend(config.workspace_dir.clone(), config.transcription.clone()).capabilities()
}

async fn handle_media_capabilities(
    State(state): State<AppState>,
    headers: HeaderMap,
) -> axum::response::Response {
    if let Some(err) = pairing_auth_error(&state, &headers, "Media capabilities") {
        return err.into_response();
    }
    let config = state.config.lock().clone();
    let capabilities = local_media_capabilities(&config);
    let body = serde_json::json!({
        "capabilities": capabilities,
        "summary": capabilities.summary(),
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

async fn handle_sync_export(
    State(state): State<AppState>,
    headers: HeaderMap,
) -> impl IntoResponse {
    if let Some(err) = pairing_auth_error(&state, &headers, "Sync export") {
        return err;
    }

    let workspace_dir = state.config.lock().workspace_dir.clone();
    match export_workspace_sync_snapshot(&workspace_dir) {
        Ok(snapshot) => (StatusCode::OK, Json(serde_json::json!(snapshot))),
        Err(err) => (
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(serde_json::json!({"error": format!("Failed to export sync snapshot: {err}")})),
        ),
    }
}

async fn handle_sync_import(
    State(state): State<AppState>,
    headers: HeaderMap,
    Json(snapshot): Json<WorkspaceSyncSnapshot>,
) -> impl IntoResponse {
    if let Some(err) = pairing_auth_error(&state, &headers, "Sync import") {
        return err;
    }

    let workspace_dir = state.config.lock().workspace_dir.clone();
    match import_workspace_sync_snapshot(&workspace_dir, &snapshot) {
        Ok((imported_files, imported_db)) => (
            StatusCode::OK,
            Json(serde_json::json!({
                "importedFiles": imported_files,
                "importedDb": imported_db,
                "imported": true,
            })),
        ),
        Err(err) => (
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(serde_json::json!({"error": format!("Failed to import sync snapshot: {err}")})),
        ),
    }
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
struct WorkspaceListQuery {
    limit: Option<usize>,
}

#[derive(Debug, Clone, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
struct WorkspaceSynthesizerAutoRunBody {
    #[serde(default)]
    reason: Option<String>,
}

#[derive(Debug, Clone, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
struct WorkspaceTodoUpdateBody {
    status: Option<String>,
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
struct FeedContentAgentCommentBody {
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

#[derive(Debug, Clone, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
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
    goal: Option<String>,
    #[serde(default)]
    prompt: Option<String>,
}

#[derive(Debug, Clone, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
struct FeedContentAgentUpdateBody {
    workflow_key: String,
    goal: Option<String>,
    prompt: Option<String>,
    enabled: Option<bool>,
    run_now: Option<bool>,
}

#[derive(Debug, Clone, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
struct FeedContentAgentRunBody {
    workflow_key: String,
}

#[derive(Debug, Clone, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
struct FeedContentAgentAutoRunBody {
    #[serde(default)]
    reason: Option<String>,
}

#[derive(Debug, Clone, serde::Serialize)]
#[serde(rename_all = "camelCase")]
struct FeedContentAgentAutoRunItem {
    workflow_key: String,
    workflow_bot: String,
    thread_id: String,
}

#[derive(Debug, Clone, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
struct FeedContentAgentCreateBody {
    #[serde(default)]
    name: Option<String>,
    #[serde(default)]
    goal: Option<String>,
    #[serde(default)]
    enabled: Option<bool>,
    #[serde(default)]
    bot_name: Option<String>,
    #[serde(default)]
    prompt: Option<String>,
    #[serde(default)]
    run_now: Option<bool>,
}

#[derive(Debug, Clone, serde::Serialize)]
#[serde(rename_all = "camelCase")]
struct FeedContentAgentResponseItem {
    workflow_key: String,
    workflow_bot: String,
    skill_path: String,
    output_prefix: String,
    enabled: bool,
    supported: bool,
    unsupported_reason: Option<String>,
    goal: Option<String>,
    editable_files: Vec<String>,
}

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
struct FeedContentAgentRecord {
    workflow_key: String,
    workflow_bot: String,
    #[serde(default)]
    skill_path: String,
    output_prefix: String,
    #[serde(default = "default_content_agent_enabled")]
    enabled: bool,
    #[serde(default)]
    editable_files: Vec<String>,
    #[serde(default)]
    goal: Option<String>,
    #[serde(default)]
    last_triggered_at: Option<String>,
    #[serde(default)]
    last_run_at: Option<String>,
    #[serde(default)]
    last_triggered_source_updated_at: Option<i64>,
    #[serde(default)]
    built_in_skill_fingerprint: Option<String>,
    #[serde(default = "default_workflow_visible_in_ui")]
    visible_in_ui: bool,
    #[serde(default = "workflow_default_settings")]
    #[serde(skip_serializing_if = "is_default_workflow_settings")]
    settings: FeedWorkflowSettings,
}

#[derive(Debug, Clone, Default, serde::Serialize, serde::Deserialize)]
struct FeedContentAgentStore {
    #[serde(default)]
    workflows: HashMap<String, FeedContentAgentRecord>,
}

fn default_feed_workflow_days() -> u32 {
    7
}

fn default_feed_workflow_random_count() -> u32 {
    1
}

fn default_content_agent_enabled() -> bool {
    true
}

fn default_workflow_visible_in_ui() -> bool {
    true
}

#[derive(Debug, Clone)]
struct FeedContentAgentDefinition {
    key: String,
    bot_name: String,
    editable_files: Vec<String>,
    output_prefix: String,
    skill_path: String,
    goal: String,
    visible_in_ui: bool,
}

#[derive(Debug, Clone, Default, serde::Serialize, serde::Deserialize)]
struct LegacyFeedContentAgentSettingsStore {
    #[serde(default)]
    workflows: HashMap<String, FeedWorkflowSettings>,
}

#[derive(Debug, Clone, Copy)]
struct BuiltInContentAgentSpec {
    key: &'static str,
    name: &'static str,
    goal: &'static str,
    output_prefix: &'static str,
    visible_in_ui: bool,
    enabled_by_default: bool,
}

#[derive(Debug, Clone, Copy)]
enum ContentAgentAutoRunTrigger {
    JournalSave,
    TranscriptReady,
    AppOpen,
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
        goal: None,
        prompt: None,
    }
}

fn is_default_workflow_settings(settings: &FeedWorkflowSettings) -> bool {
    settings == &workflow_default_settings()
}

fn built_in_content_agent_specs() -> &'static [BuiltInContentAgentSpec] {
    &[
        BuiltInContentAgentSpec {
            key: WORKSPACE_SYNTHESIZER_WORKFLOW_KEY,
            name: "Workspace Synthesizer",
            goal: "Use the workspace synthesizer index skill as shared guidance for specialized extractor skills. The runtime will run those extractors, validate their typed JSON handoffs, and turn them into feed posts, todos, events, and clip plans.",
            output_prefix: "posts/workspace_synthesizer/",
            visible_in_ui: true,
            enabled_by_default: false,
        },
        BuiltInContentAgentSpec {
            key: workspace_synthesizer::WORKSPACE_INSIGHT_EXTRACTOR_WORKFLOW_KEY,
            name: "Workspace Insight Extractor",
            goal: "Extract concise workspace feed posts from recent journals and transcripts. Write only the insight_posts handoff JSON for Rust to materialize into feed posts.",
            output_prefix: "posts/workspace_synthesizer/",
            visible_in_ui: false,
            enabled_by_default: true,
        },
        BuiltInContentAgentSpec {
            key: workspace_synthesizer::WORKSPACE_TODO_EXTRACTOR_WORKFLOW_KEY,
            name: "Workspace Todo Extractor",
            goal: "Extract concrete action items and commitments from recent journals and transcripts. Write only the todos handoff JSON for Rust to store in the planner.",
            output_prefix: "posts/workspace_synthesizer/",
            visible_in_ui: false,
            enabled_by_default: true,
        },
        BuiltInContentAgentSpec {
            key: workspace_synthesizer::WORKSPACE_EVENT_EXTRACTOR_WORKFLOW_KEY,
            name: "Workspace Event Extractor",
            goal: "Extract scheduled events with clear timing from recent journals and transcripts. Write only the events handoff JSON for Rust to store in the planner.",
            output_prefix: "posts/workspace_synthesizer/",
            visible_in_ui: false,
            enabled_by_default: true,
        },
        BuiltInContentAgentSpec {
            key: workspace_synthesizer::WORKSPACE_CLIP_EXTRACTOR_WORKFLOW_KEY,
            name: "Workspace Clip Extractor",
            goal: "Extract transcript-backed clip plans from recent journals and transcript text. Write only the clip_plans handoff JSON for Rust to keep as pipeline artifacts.",
            output_prefix: "posts/workspace_synthesizer/",
            visible_in_ui: false,
            enabled_by_default: true,
        },
        BuiltInContentAgentSpec {
            key: "bluesky_insight_posts",
            name: "Bluesky Insight Posts",
            goal: "Create interesting Bluesky post drafts from my recent journal notes. Extract standout insights and save each post as a separate file in posts/ so it appears in the workspace feed.",
            output_prefix: "posts/bluesky_insight_posts/",
            visible_in_ui: true,
            enabled_by_default: false,
        },
        BuiltInContentAgentSpec {
            key: "weekly_highlights",
            name: "Weekly Highlights",
            goal: "Turn my recent journal notes into polished weekly highlight posts for the workspace feed. Save each highlight as a separate file in posts/.",
            output_prefix: "posts/weekly_highlights/",
            visible_in_ui: true,
            enabled_by_default: false,
        },
        BuiltInContentAgentSpec {
            key: "audio_insight_clips",
            name: "Audio Insight Clips",
            goal: "Create simple vertical video clips from my journal audio recordings. If a transcript is missing, generate it first, extract exact insightful lines, build black-background text cards, and render a feed-ready mp4 into posts/.",
            output_prefix: "posts/audio_insight_clips/",
            visible_in_ui: true,
            enabled_by_default: false,
        },
    ]
}

impl ContentAgentAutoRunTrigger {
    fn queue_source(self) -> &'static str {
        match self {
            ContentAgentAutoRunTrigger::JournalSave => "journal-save",
            ContentAgentAutoRunTrigger::TranscriptReady => "transcript-ready",
            ContentAgentAutoRunTrigger::AppOpen => "app-open",
        }
    }

    fn requires_staleness_gate(self) -> bool {
        matches!(self, ContentAgentAutoRunTrigger::AppOpen)
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

fn normalize_workflow_record(workflow_key: &str, mut record: FeedContentAgentRecord) -> FeedContentAgentRecord {
    record.workflow_key = workflow_key.to_string();
    record.workflow_bot = record
        .workflow_bot
        .trim()
        .to_string()
        .if_empty_then(|| default_workflow_bot_name(workflow_key));
    record.output_prefix = normalize_workflow_output_prefix(&record.output_prefix, workflow_key);
    record.settings = normalize_workflow_settings(record.settings);
    record.skill_path = {
        let trimmed = record
            .skill_path
            .trim()
            .trim_start_matches('/')
            .replace('\\', "/");
        if trimmed.is_empty() || trimmed.contains("..") || !trimmed.starts_with("skills/") {
            format!("skills/{workflow_key}/SKILL.md")
        } else {
            trimmed
        }
    };
    record.goal = normalize_goal_text(record.goal)
        .or(record.settings.goal.clone())
        .or(record.settings.prompt.clone());
    record.last_triggered_at = normalize_goal_text(record.last_triggered_at);
    record.last_run_at = normalize_goal_text(record.last_run_at);
    record.last_triggered_source_updated_at = record
        .last_triggered_source_updated_at
        .filter(|value| *value > 0);
    record.built_in_skill_fingerprint = normalize_goal_text(record.built_in_skill_fingerprint);

    record.editable_files = vec![record.skill_path.clone()];
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

fn feed_workflow_definition_from_record(record: &FeedContentAgentRecord) -> FeedContentAgentDefinition {
    FeedContentAgentDefinition {
        key: record.workflow_key.clone(),
        bot_name: record.workflow_bot.clone(),
        editable_files: record.editable_files.clone(),
        output_prefix: record.output_prefix.clone(),
        skill_path: record.skill_path.clone(),
        goal: record
            .goal
            .clone()
            .or(record.settings.goal.clone())
            .or(record.settings.prompt.clone())
            .unwrap_or_default(),
        visible_in_ui: record.visible_in_ui,
    }
}

fn workflow_definitions(store: &FeedContentAgentStore) -> Vec<FeedContentAgentDefinition> {
    let mut defs: Vec<FeedContentAgentDefinition> = store
        .workflows
        .values()
        .map(feed_workflow_definition_from_record)
        .filter(|workflow| workflow.visible_in_ui)
        .collect();
    defs.sort_by(|a, b| a.key.cmp(&b.key));
    defs
}

fn workflow_definition_by_key(
    store: &FeedContentAgentStore,
    key: &str,
) -> Option<FeedContentAgentDefinition> {
    let normalized = key.trim().to_ascii_lowercase();
    store
        .workflows
        .get(&normalized)
        .map(feed_workflow_definition_from_record)
}

fn workflow_for_feed_path(
    store: &FeedContentAgentStore,
    path: &str,
) -> Option<FeedContentAgentDefinition> {
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
    settings.goal = normalize_goal_text(settings.goal);
    settings.prompt = normalize_goal_text(settings.prompt);
    if settings.goal.is_none() {
        settings.goal = settings.prompt.clone();
    }
    if settings.prompt.is_none() {
        settings.prompt = settings.goal.clone();
    }
    settings
}

fn built_in_content_agent_settings(goal: &str) -> FeedWorkflowSettings {
    let mut settings = workflow_default_settings();
    settings.goal = Some(goal.to_string());
    settings.prompt = Some(goal.to_string());
    normalize_workflow_settings(settings)
}

fn is_built_in_content_agent_key(workflow_key: &str) -> bool {
    let normalized = sanitize_workflow_key(workflow_key);
    built_in_content_agent_specs()
        .iter()
        .any(|spec| sanitize_workflow_key(spec.key) == normalized)
}

fn canonical_content_agent_skill_body(record: &FeedContentAgentRecord) -> Result<Option<String>> {
    if !is_built_in_content_agent_key(&record.workflow_key) {
        return Ok(None);
    }
    let goal = record
        .goal
        .clone()
        .or(record.settings.goal.clone())
        .or(record.settings.prompt.clone())
        .unwrap_or_else(|| "Create workspace feed posts from journal notes.".to_string());
    let output_dir = record.output_prefix.trim_end_matches('/');
    let body = match record.workflow_key.as_str() {
        WORKSPACE_SYNTHESIZER_WORKFLOW_KEY => workspace_synthesizer::render_skill_markdown()?,
        workspace_synthesizer::WORKSPACE_INSIGHT_EXTRACTOR_WORKFLOW_KEY
        | workspace_synthesizer::WORKSPACE_TODO_EXTRACTOR_WORKFLOW_KEY
        | workspace_synthesizer::WORKSPACE_EVENT_EXTRACTOR_WORKFLOW_KEY
        | workspace_synthesizer::WORKSPACE_CLIP_EXTRACTOR_WORKFLOW_KEY => {
            workspace_synthesizer::render_extractor_skill_markdown(&record.workflow_key)?
        }
        "audio_insight_clips" => render_audio_insight_clip_skill_markdown(output_dir),
        _ => render_template_skill_markdown(&record.workflow_bot, &goal, output_dir),
    };
    Ok(Some(body))
}

fn content_agent_skill_fingerprint(body: &str) -> String {
    use sha2::{Digest, Sha256};

    let digest = Sha256::digest(body.as_bytes());
    hex::encode(digest)
}

fn built_in_content_agent_record(spec: BuiltInContentAgentSpec) -> FeedContentAgentRecord {
    let key = sanitize_workflow_key(spec.key);
    let mut record = FeedContentAgentRecord {
        workflow_key: key.clone(),
        workflow_bot: spec.name.to_string(),
        skill_path: format!("skills/{key}/SKILL.md"),
        output_prefix: spec.output_prefix.to_string(),
        enabled: spec.enabled_by_default,
        editable_files: vec![format!("skills/{key}/SKILL.md")],
        goal: Some(spec.goal.to_string()),
        last_triggered_at: None,
        last_run_at: None,
        last_triggered_source_updated_at: None,
        built_in_skill_fingerprint: None,
        visible_in_ui: spec.visible_in_ui,
        settings: built_in_content_agent_settings(spec.goal),
    };
    record = normalize_workflow_record(&key, record);
    if let Ok(Some(body)) = canonical_content_agent_skill_body(&record) {
        record.built_in_skill_fingerprint = Some(content_agent_skill_fingerprint(&body));
    }
    record
}

fn ensure_content_agent_skill_file(
    workspace_dir: &StdPath,
    record: &FeedContentAgentRecord,
) -> Result<()> {
    let skill_abs = workspace_dir.join(&record.skill_path);
    if skill_abs.exists() && skill_abs.is_file() {
        return Ok(());
    }
    if let Some(parent) = skill_abs.parent() {
        std::fs::create_dir_all(parent)
            .with_context(|| format!("failed to create skill directory {}", parent.display()))?;
    }
    let skill_body = canonical_content_agent_skill_body(record)?.unwrap_or_else(|| {
        let goal = record
            .goal
            .clone()
            .or(record.settings.goal.clone())
            .or(record.settings.prompt.clone())
            .unwrap_or_else(|| "Create workspace feed posts from journal notes.".to_string());
        let output_dir = record.output_prefix.trim_end_matches('/');
        render_template_skill_markdown(&record.workflow_bot, &goal, output_dir)
    });
    std::fs::write(&skill_abs, skill_body)
    .with_context(|| format!("failed to write starter skill {}", skill_abs.display()))
}

fn ensure_built_in_content_agents(
    workspace_dir: &StdPath,
    store: &mut FeedContentAgentStore,
) -> Result<bool> {
    let mut changed = false;
    for spec in built_in_content_agent_specs() {
        let key = sanitize_workflow_key(spec.key);
        if !store.workflows.contains_key(&key) {
            let record = normalize_workflow_record(&key, built_in_content_agent_record(*spec));
            store.workflows.insert(key.clone(), record);
            changed = true;
        }
        if let Some(record) = store.workflows.get_mut(&key) {
            if key == "audio_insight_clips"
                && record.goal.as_deref() == Some(LEGACY_AUDIO_INSIGHT_CLIPS_GOAL)
            {
                record.goal = Some(spec.goal.to_string());
                record.settings = built_in_content_agent_settings(spec.goal);
                *record = normalize_workflow_record(&key, record.clone());
                changed = true;
            }

            if let Some(canonical_body) = canonical_content_agent_skill_body(record)? {
                let canonical_fingerprint = content_agent_skill_fingerprint(&canonical_body);
                let skill_abs = workspace_dir.join(&record.skill_path);
                let should_refresh_skill = record
                    .built_in_skill_fingerprint
                    .as_deref()
                    != Some(canonical_fingerprint.as_str())
                    || !skill_abs.exists();
                if should_refresh_skill {
                    if let Some(parent) = skill_abs.parent() {
                        std::fs::create_dir_all(parent).with_context(|| {
                            format!("failed to create skill directory {}", parent.display())
                        })?;
                    }
                    std::fs::write(&skill_abs, canonical_body).with_context(|| {
                        format!("failed to refresh built-in skill {}", skill_abs.display())
                    })?;
                    record.built_in_skill_fingerprint = Some(canonical_fingerprint);
                    changed = true;
                }
            }
            ensure_content_agent_skill_file(workspace_dir, record)?;
        }
    }
    Ok(changed)
}

fn workflow_settings_store_path(workspace_dir: &StdPath) -> PathBuf {
    workspace_dir
        .join("state")
        .join("feed_workflow_settings.json")
}

fn load_feed_workflow_settings_store(workspace_dir: &StdPath) -> Result<FeedContentAgentStore> {
    let path = workflow_settings_store_path(workspace_dir);
    if !path.exists() {
        return Ok(FeedContentAgentStore::default());
    }
    let raw = std::fs::read_to_string(&path)
        .with_context(|| format!("Failed to read workflow settings store {}", path.display()))?;
    if let Ok(mut parsed) = serde_json::from_str::<FeedContentAgentStore>(&raw) {
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

    let legacy: LegacyFeedContentAgentSettingsStore = serde_json::from_str(&raw)
        .with_context(|| format!("Invalid workflow settings JSON {}", path.display()))?;
    let mut migrated = FeedContentAgentStore::default();
    for (legacy_key, legacy_settings) in legacy.workflows {
        let key = sanitize_workflow_key(&legacy_key);
        let record = FeedContentAgentRecord {
            workflow_key: key.clone(),
            workflow_bot: default_workflow_bot_name(&key),
            skill_path: format!("skills/{key}/SKILL.md"),
            output_prefix: format!("posts/{key}/"),
            enabled: default_content_agent_enabled(),
            editable_files: vec![format!("skills/{key}/SKILL.md")],
            goal: legacy_settings.goal.clone().or(legacy_settings.prompt.clone()),
            last_triggered_at: None,
            last_run_at: None,
            last_triggered_source_updated_at: None,
            built_in_skill_fingerprint: None,
            visible_in_ui: true,
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
    store: &FeedContentAgentStore,
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

fn load_or_seed_feed_workflow_settings_store(workspace_dir: &StdPath) -> Result<FeedContentAgentStore> {
    let mut store = load_feed_workflow_settings_store(workspace_dir)?;
    if ensure_built_in_content_agents(workspace_dir, &mut store)? {
        save_feed_workflow_settings_store(workspace_dir, &store)?;
    }
    Ok(store)
}

fn workflow_settings_response_item(
    workflow: &FeedContentAgentDefinition,
    enabled: bool,
    media_capabilities: MediaToolCapabilities,
) -> FeedContentAgentResponseItem {
    let unsupported_reason = workflow_unsupported_reason(workflow, media_capabilities);
    FeedContentAgentResponseItem {
        workflow_key: workflow.key.to_string(),
        workflow_bot: workflow.bot_name.to_string(),
        skill_path: workflow.skill_path.to_string(),
        output_prefix: workflow.output_prefix.to_string(),
        enabled,
        supported: unsupported_reason.is_none(),
        unsupported_reason,
        goal: Some(workflow.goal.clone()).filter(|value| !value.trim().is_empty()),
        editable_files: workflow
            .editable_files
            .iter()
            .map(std::string::ToString::to_string)
            .collect(),
    }
}

fn goal_requests_media_output(goal: &str) -> bool {
    let lower = goal.to_ascii_lowercase();
    [
        " audio ",
        " video ",
        " clip",
        " clips",
        " mp4",
        " slideshow",
        " image ",
        " images",
        " transcript",
        " narration",
    ]
    .iter()
    .any(|needle| lower.contains(needle.trim()))
}

fn workflow_requires_media_capabilities(workflow: &FeedContentAgentDefinition) -> bool {
    if workflow.key == WORKSPACE_SYNTHESIZER_WORKFLOW_KEY {
        return false;
    }
    workflow.key == "audio_insight_clips" || goal_requests_media_output(&workflow.goal)
}

fn required_media_capability_reason(media_capabilities: MediaToolCapabilities) -> String {
    let mut missing = Vec::new();
    if !media_capabilities.transcribe_media {
        missing.push("transcribe_media");
    }
    if !media_capabilities.compose_simple_clip {
        missing.push("compose_simple_clip");
    }
    let available = media_capabilities.available_tool_names();
    if available.is_empty() {
        format!(
            "This workflow requires local media tools: {}. No local media tools are currently available on this device.",
            missing.join(", ")
        )
    } else {
        format!(
            "This workflow requires local media tools: {}. Available on this device: {}.",
            missing.join(", "),
            available.join(", ")
        )
    }
}

fn workflow_unsupported_reason(
    workflow: &FeedContentAgentDefinition,
    media_capabilities: MediaToolCapabilities,
) -> Option<String> {
    if !workflow_requires_media_capabilities(workflow) {
        return None;
    }
    if media_capabilities.transcribe_media && media_capabilities.compose_simple_clip {
        return None;
    }
    Some(required_media_capability_reason(media_capabilities))
}

const CONTENT_AGENT_MIN_TOOL_ITERATIONS: usize = 32;
const CONTENT_AGENT_MIN_ACTIONS_PER_HOUR: u32 = 200;
const CONTENT_AGENT_TIMEOUT_SECS: u64 = 420;

fn content_agent_config_with_headroom(base: &Config) -> Config {
    let mut config = base.clone();
    config.agent.max_tool_iterations = config
        .agent
        .max_tool_iterations
        .max(CONTENT_AGENT_MIN_TOOL_ITERATIONS);
    config.autonomy.max_actions_per_hour = config
        .autonomy
        .max_actions_per_hour
        .max(CONTENT_AGENT_MIN_ACTIONS_PER_HOUR);
    config
}

fn parse_rfc3339_timestamp_secs(value: &str) -> Option<i64> {
    chrono::DateTime::parse_from_rfc3339(value)
        .ok()
        .map(|parsed| parsed.timestamp())
}

fn source_file_modified_at_secs(path: &StdPath) -> i64 {
    path.metadata()
        .ok()
        .and_then(|meta| meta.modified().ok())
        .and_then(|ts| ts.duration_since(UNIX_EPOCH).ok())
        .and_then(|dur| i64::try_from(dur.as_secs()).ok())
        .unwrap_or(0)
}

fn is_content_agent_source_file(path: &StdPath) -> bool {
    let extension = path
        .extension()
        .and_then(|value| value.to_str())
        .unwrap_or("")
        .to_ascii_lowercase();
    matches!(extension.as_str(), "md" | "txt" | "json" | "srt")
}

fn latest_content_agent_source_updated_at(workspace_dir: &StdPath) -> i64 {
    let root = workspace_dir.join(JOURNAL_TEXT_DIR);
    if !root.exists() || !root.is_dir() {
        return 0;
    }

    let mut latest = 0_i64;
    let mut stack = vec![root];
    while let Some(dir) = stack.pop() {
        let entries = match std::fs::read_dir(&dir) {
            Ok(entries) => entries,
            Err(_) => continue,
        };
        for entry in entries.flatten() {
            let path = entry.path();
            let Ok(file_type) = entry.file_type() else {
                continue;
            };
            if file_type.is_dir() {
                stack.push(path);
                continue;
            }
            if !file_type.is_file() || !is_content_agent_source_file(&path) {
                continue;
            }
            latest = latest.max(source_file_modified_at_secs(&path));
        }
    }
    latest
}

fn should_auto_run_content_agent(
    record: &FeedContentAgentRecord,
    latest_source_updated_at: i64,
    trigger: ContentAgentAutoRunTrigger,
) -> bool {
    if !record.enabled || latest_source_updated_at <= 0 {
        return false;
    }
    if record.last_triggered_source_updated_at.unwrap_or(0) >= latest_source_updated_at {
        return false;
    }
    if trigger.requires_staleness_gate() {
        let last_triggered_secs = record
            .last_triggered_at
            .as_deref()
            .and_then(parse_rfc3339_timestamp_secs)
            .unwrap_or(0);
        if last_triggered_secs > 0
            && Utc::now().timestamp() - last_triggered_secs < CONTENT_AGENT_APP_OPEN_STALE_SECS
        {
            return false;
        }
    }
    true
}

fn save_workspace_synthesizer_status(
    workspace_dir: &StdPath,
    status: &str,
    trigger_reason: &str,
    thread_id: &str,
    latest_source_updated_at: i64,
    last_run_at: Option<String>,
    last_summary: Option<String>,
    last_error: Option<String>,
    artifact_counts: Option<workspace_synthesizer::WorkspaceSynthArtifactCounts>,
    artifact_states: Option<workspace_synthesizer::WorkspaceSynthArtifactStates>,
) {
    let mut next = workspace_synthesizer::load_status(workspace_dir);
    next.status = status.to_string();
    next.trigger_reason = trigger_reason.trim().to_string();
    next.thread_id = thread_id.trim().to_string();
    next.last_source_updated_at = latest_source_updated_at;
    next.last_manifest_path =
        workspace_synthesizer::WORKSPACE_SYNTHESIZER_PIPELINE_DIR.to_string();
    if let Some(last_run_at) = last_run_at {
        next.last_run_at = last_run_at;
    }
    match last_summary {
        Some(summary) => next.last_summary = summary,
        None if status != "done" => next.last_summary.clear(),
        None => {}
    }
    match last_error {
        Some(error) => next.last_error = error,
        None => next.last_error.clear(),
    }
    if let Some(artifact_counts) = artifact_counts {
        next.artifact_counts = artifact_counts;
    } else if status != "done" {
        next.artifact_counts = workspace_synthesizer::WorkspaceSynthArtifactCounts::default();
    }
    if let Some(artifact_states) = artifact_states {
        next.artifact_states = artifact_states;
    } else if status != "done" {
        next.artifact_states = workspace_synthesizer::WorkspaceSynthArtifactStates::default();
    }
    if let Err(err) = workspace_synthesizer::save_status(workspace_dir, &next) {
        tracing::warn!("Failed to persist workspace synthesizer status `{status}`: {err}");
    }
}

fn queue_eligible_content_agents_for_trigger(
    state: &AppState,
    trigger: ContentAgentAutoRunTrigger,
) -> Result<Vec<FeedContentAgentAutoRunItem>> {
    let config_snapshot = state.config.lock().clone();
    let workspace_dir = config_snapshot.workspace_dir.clone();
    let media_capabilities = local_media_capabilities(&config_snapshot);
    let mut store = load_or_seed_feed_workflow_settings_store(&workspace_dir)?;
    let latest_source_updated_at = latest_content_agent_source_updated_at(&workspace_dir);
    if latest_source_updated_at <= 0 {
        return Ok(Vec::new());
    }

    let now = Utc::now().to_rfc3339();
    let mut queued = Vec::new();
    let defs = workflow_definitions(&store);
    let mut changed = false;
    for workflow in defs {
        let Some(record) = store.workflows.get_mut(&workflow.key) else {
            continue;
        };
        if workflow_unsupported_reason(&workflow, media_capabilities).is_some() {
            continue;
        }
        if !should_auto_run_content_agent(record, latest_source_updated_at, trigger) {
            continue;
        }
        match queue_workflow_run(state.clone(), workflow.clone(), trigger.queue_source()) {
            Ok(thread_id) => {
                record.last_triggered_at = Some(now.clone());
                record.last_triggered_source_updated_at = Some(latest_source_updated_at);
                queued.push(FeedContentAgentAutoRunItem {
                    workflow_key: workflow.key.clone(),
                    workflow_bot: workflow.bot_name.clone(),
                    thread_id,
                });
                changed = true;
            }
            Err(err) => {
                tracing::warn!(
                    "Failed to queue content agent `{}` for {}: {err}",
                    workflow.key,
                    trigger.queue_source()
                );
            }
        }
    }

    if changed {
        save_feed_workflow_settings_store(&workspace_dir, &store)?;
    }

    Ok(queued)
}

fn queue_workspace_synthesizer_for_trigger(
    state: &AppState,
    reason: &str,
) -> Result<Option<String>> {
    let workspace_dir = state.config.lock().workspace_dir.clone();
    let latest_source_updated_at = latest_content_agent_source_updated_at(&workspace_dir);
    if latest_source_updated_at <= 0 {
        return Ok(None);
    }

    let store = load_or_seed_feed_workflow_settings_store(&workspace_dir)?;
    let Some(record) = store.workflows.get(WORKSPACE_SYNTHESIZER_WORKFLOW_KEY) else {
        return Ok(None);
    };
    if !record.enabled {
        return Ok(None);
    }

    let status = workspace_synthesizer::load_status(&workspace_dir);
    if reason.eq_ignore_ascii_case("app-open")
        && status.last_source_updated_at > 0
        && status.last_source_updated_at >= latest_source_updated_at
    {
        return Ok(None);
    }
    if matches!(status.status.as_str(), "pending" | "processing") && !status.thread_id.trim().is_empty()
    {
        return Ok(Some(status.thread_id));
    }

    queue_workspace_synthesizer_run(state.clone(), reason, latest_source_updated_at).map(Some)
}

fn queue_workspace_synthesizer_run(
    state: AppState,
    source: &str,
    latest_source_updated_at: i64,
) -> Result<String> {
    let workspace_dir = state.config.lock().workspace_dir.clone();
    let existing_status = workspace_synthesizer::load_status(&workspace_dir);
    if matches!(existing_status.status.as_str(), "pending" | "processing")
        && !existing_status.thread_id.trim().is_empty()
    {
        return Ok(existing_status.thread_id);
    }
    let store = load_or_seed_feed_workflow_settings_store(&workspace_dir)?;
    let workflow = workflow_definition_by_key(&store, WORKSPACE_SYNTHESIZER_WORKFLOW_KEY)
        .context("workspace synthesizer workflow is missing")?;
    let source_label = match source.trim() {
        "app-open" => "app-open",
        "journal-save" => "journal-save",
        "transcript-ready" => "transcript-ready",
        "workspace-run-manual" => "workspace-run-manual",
        _ => "workspace-synthesizer",
    };
    let thread_id = queue_workflow_run(state.clone(), workflow, source_label)?;
    save_workspace_synthesizer_status(
        &workspace_dir,
        "pending",
        source_label,
        &thread_id,
        latest_source_updated_at,
        None,
        None,
        None,
        None,
        None,
    );
    Ok(thread_id)
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
    let config = content_agent_config_with_headroom(&state.config.lock().clone());
    crate::channels::with_channel_execution_context(
        channel_ctx,
        crate::agent::process_message(config, prompt),
    )
    .await
}

fn workspace_synth_default_artifact_states() -> workspace_synthesizer::WorkspaceSynthArtifactStates {
    workspace_synthesizer::WorkspaceSynthArtifactStates {
        insight_posts: workspace_synthesizer::WorkspaceSynthArtifactState {
            status: "skipped".to_string(),
            path: workspace_synthesizer::WORKSPACE_SYNTHESIZER_INSIGHT_POSTS_PATH.to_string(),
            item_count: 0,
            error: String::new(),
        },
        todos: workspace_synthesizer::WorkspaceSynthArtifactState {
            status: "skipped".to_string(),
            path: workspace_synthesizer::WORKSPACE_SYNTHESIZER_TODOS_PATH.to_string(),
            item_count: 0,
            error: String::new(),
        },
        events: workspace_synthesizer::WorkspaceSynthArtifactState {
            status: "skipped".to_string(),
            path: workspace_synthesizer::WORKSPACE_SYNTHESIZER_EVENTS_PATH.to_string(),
            item_count: 0,
            error: String::new(),
        },
        clip_plans: workspace_synthesizer::WorkspaceSynthArtifactState {
            status: "skipped".to_string(),
            path: workspace_synthesizer::WORKSPACE_SYNTHESIZER_CLIP_PLANS_PATH.to_string(),
            item_count: 0,
            error: String::new(),
        },
    }
}

fn workspace_synth_artifact_state_mut<'a>(
    states: &'a mut workspace_synthesizer::WorkspaceSynthArtifactStates,
    workflow_key: &str,
) -> Option<&'a mut workspace_synthesizer::WorkspaceSynthArtifactState> {
    match workflow_key {
        workspace_synthesizer::WORKSPACE_INSIGHT_EXTRACTOR_WORKFLOW_KEY => {
            Some(&mut states.insight_posts)
        }
        workspace_synthesizer::WORKSPACE_TODO_EXTRACTOR_WORKFLOW_KEY => Some(&mut states.todos),
        workspace_synthesizer::WORKSPACE_EVENT_EXTRACTOR_WORKFLOW_KEY => Some(&mut states.events),
        workspace_synthesizer::WORKSPACE_CLIP_EXTRACTOR_WORKFLOW_KEY => {
            Some(&mut states.clip_plans)
        }
        _ => None,
    }
}

fn render_workspace_synth_extractor_run_prompt(
    orchestrator: &FeedContentAgentDefinition,
    orchestrator_skill_markdown: &str,
    extractor: &FeedContentAgentDefinition,
    extractor_skill_markdown: &str,
    media_tool_summary: &str,
    handoff_path: &str,
) -> String {
    let mut prompt = String::new();
    prompt.push_str("Run the following workspace extractor skill and write only its typed handoff file.\n\n");
    prompt.push_str("## Workspace Synthesizer Index Skill\n");
    prompt.push_str(&format!("- Name: {}\n", orchestrator.bot_name));
    prompt.push_str(&format!("- Key: {}\n", orchestrator.key));
    prompt.push_str(&format!("- Goal: {}\n", orchestrator.goal.trim()));
    prompt.push_str("```markdown\n");
    prompt.push_str(orchestrator_skill_markdown.trim());
    prompt.push_str("\n```\n\n");
    prompt.push_str("## Extractor Skill\n");
    prompt.push_str(&format!("- Name: {}\n", extractor.bot_name));
    prompt.push_str(&format!("- Key: {}\n", extractor.key));
    prompt.push_str(&format!("- Goal: {}\n", extractor.goal.trim()));
    prompt.push_str(&format!("- Skill file: `{}`\n", extractor.skill_path));
    prompt.push_str(&format!("- Allowed output file: `{}`\n\n", handoff_path));
    prompt.push_str("```markdown\n");
    prompt.push_str(extractor_skill_markdown.trim());
    prompt.push_str("\n```\n\n");
    prompt.push_str("## Execution Rules\n");
    prompt.push_str("- Read from `journals/text/**`, available transcript files, and journal media files when relevant to the goal.\n");
    prompt.push_str("- If a needed transcript for journal media is missing, use `transcribe_media` and save outputs under `journals/text/transcriptions/**`.\n");
    prompt.push_str(&format!("- {media_tool_summary}\n"));
    prompt.push_str("- For deterministic media transforms, use only the built-in media tools that are available on this device.\n");
    prompt.push_str("- Write exactly one handoff file at the allowed path, even if the `items` array is empty.\n");
    prompt.push_str("- Do not write any other handoff file, final feed post, todo, event, or clip artifact.\n");
    prompt.push_str("- Use direct file edits in the workspace, not code blocks in chat.\n");
    prompt.push_str("- Reply with a concise summary of what you wrote to the handoff file.\n");
    prompt
}

async fn run_workspace_synthesizer_orchestrator(
    state: &AppState,
    workspace_dir: &StdPath,
    orchestrator_workflow: &FeedContentAgentDefinition,
    orchestrator_skill_markdown: &str,
    media_tool_summary: &str,
) -> Result<(String, workspace_synthesizer::WorkspaceSynthesisApplyResult)> {
    let store = load_or_seed_feed_workflow_settings_store(workspace_dir)?;
    workspace_synthesizer::reset_handoff_files(workspace_dir)?;

    let mut extractor_replies = Vec::new();
    let mut extractor_errors = Vec::new();
    let mut artifact_states = workspace_synth_default_artifact_states();

    for extractor_spec in workspace_synthesizer::extractor_specs() {
        let Some(extractor_workflow) = workflow_definition_by_key(&store, extractor_spec.workflow_key) else {
            let error = format!("missing extractor workflow `{}`", extractor_spec.workflow_key);
            if let Some(state) =
                workspace_synth_artifact_state_mut(&mut artifact_states, extractor_spec.workflow_key)
            {
                state.status = "error".to_string();
                state.error = error.clone();
            }
            extractor_errors.push(error);
            continue;
        };
        let enabled = store
            .workflows
            .get(extractor_spec.workflow_key)
            .map(|record| record.enabled)
            .unwrap_or(false);
        if !enabled {
            continue;
        }

        let extractor_skill_abs = workspace_dir.join(&extractor_workflow.skill_path);
        let extractor_skill_markdown = match std::fs::read_to_string(&extractor_skill_abs) {
            Ok(raw) => raw,
            Err(err) => {
                let message = truncate_with_ellipsis(
                    &format!(
                        "{} failed: unable to read skill `{}`: {}",
                        extractor_workflow.bot_name, extractor_workflow.skill_path, err
                    ),
                    800,
                );
                if let Some(state) =
                    workspace_synth_artifact_state_mut(&mut artifact_states, extractor_spec.workflow_key)
                {
                    state.status = "error".to_string();
                    state.error = message.clone();
                }
                extractor_errors.push(message);
                continue;
            }
        };
        let prompt = render_workspace_synth_extractor_run_prompt(
            orchestrator_workflow,
            orchestrator_skill_markdown,
            &extractor_workflow,
            &extractor_skill_markdown,
            media_tool_summary,
            extractor_spec.handoff_path,
        );
        let subthread_id = format!(
            "workflow:{}:{}",
            orchestrator_workflow.key, extractor_workflow.key
        );
        match tokio::time::timeout(
            Duration::from_secs(CONTENT_AGENT_TIMEOUT_SECS),
            run_local_agent_prompt_in_thread(state, &subthread_id, &prompt),
        )
        .await
        {
            Ok(Ok(reply)) => {
                let trimmed = reply.trim();
                if !trimmed.is_empty() {
                    extractor_replies.push(format!("{}: {}", extractor_workflow.bot_name, trimmed));
                }
            }
            Ok(Err(err)) => {
                let message = truncate_with_ellipsis(
                    &format!("{} failed: {err:#}", extractor_workflow.bot_name),
                    800,
                );
                if let Some(state) =
                    workspace_synth_artifact_state_mut(&mut artifact_states, extractor_spec.workflow_key)
                {
                    state.status = "error".to_string();
                    state.error = message.clone();
                }
                extractor_errors.push(message);
            }
            Err(_) => {
                let message = format!(
                    "{} timed out after {}s",
                    extractor_workflow.bot_name, CONTENT_AGENT_TIMEOUT_SECS
                );
                if let Some(state) =
                    workspace_synth_artifact_state_mut(&mut artifact_states, extractor_spec.workflow_key)
                {
                    state.status = "error".to_string();
                    state.error = message.clone();
                }
                extractor_errors.push(message);
            }
        }
    }

    let workspace_for_apply = workspace_dir.to_path_buf();
    let mut applied = tokio::task::spawn_blocking(move || {
        workspace_synthesizer::apply_handoff_files(&workspace_for_apply, &Utc::now().to_rfc3339())
    })
    .await
    .context("workspace synthesis apply task failed")??;

    if !artifact_states.insight_posts.error.trim().is_empty() {
        applied.artifact_states.insight_posts = artifact_states.insight_posts.clone();
    }
    if !artifact_states.todos.error.trim().is_empty() {
        applied.artifact_states.todos = artifact_states.todos.clone();
    }
    if !artifact_states.events.error.trim().is_empty() {
        applied.artifact_states.events = artifact_states.events.clone();
    }
    if !artifact_states.clip_plans.error.trim().is_empty() {
        applied.artifact_states.clip_plans = artifact_states.clip_plans.clone();
    }

    if !extractor_errors.is_empty() {
        applied.had_errors = true;
        let joined = extractor_errors.join(" | ");
        if applied.summary.trim().is_empty() {
            applied.summary = format!("Workspace synthesis extractor issues: {joined}");
        } else {
            applied.summary = format!("{} Extractor issues: {}", applied.summary.trim(), joined);
        }
    }

    let reply = if extractor_replies.is_empty() {
        applied.summary.clone()
    } else {
        format!(
            "{}\n\nExtractor summaries:\n- {}",
            applied.summary.trim(),
            extractor_replies.join("\n- ")
        )
    };

    Ok((reply, applied))
}

fn queue_workflow_run(
    state: AppState,
    workflow: FeedContentAgentDefinition,
    source: &'static str,
) -> Result<String> {
    let workspace_dir = state.config.lock().workspace_dir.clone();
    let thread_id = format!("workflow:{}", workflow.key);
    let user_content = format!("[run] Triggered {} for {}", source, workflow.bot_name);

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
    if workflow.key == WORKSPACE_SYNTHESIZER_WORKFLOW_KEY {
        save_workspace_synthesizer_status(
            &workspace_dir,
            "pending",
            source,
            &thread_id,
            latest_content_agent_source_updated_at(&workspace_dir),
            None,
            None,
            None,
            None,
            None,
        );
    }

    let state_for_worker = state.clone();
    let workspace_for_worker = workspace_dir.clone();
    let thread_id_for_worker = thread_id.clone();
    let user_id_for_worker = user_id.clone();
    let workflow_for_worker = workflow.clone();
    let is_workspace_synth = workflow.key == WORKSPACE_SYNTHESIZER_WORKFLOW_KEY;
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
        if is_workspace_synth {
            save_workspace_synthesizer_status(
                &workspace_for_worker,
                "processing",
                source,
                &thread_id_for_worker,
                latest_content_agent_source_updated_at(&workspace_for_worker),
                None,
                None,
                None,
                None,
                None,
            );
        }

        let skill_abs = workspace_for_worker.join(&workflow_for_worker.skill_path);
        let skill_markdown = match std::fs::read_to_string(&skill_abs) {
            Ok(raw) => raw,
            Err(err) => {
                let final_error = format!(
                    "Content agent run failed.\n\nUnable to read skill `{}`: {err}",
                    workflow_for_worker.skill_path
                );
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
                let _ = local_store::patch_chat_status(
                    &workspace_for_worker,
                    &user_id_for_worker,
                    "error",
                    Some(&final_error),
                );
                if is_workspace_synth {
                    save_workspace_synthesizer_status(
                        &workspace_for_worker,
                        "error",
                        source,
                        &thread_id_for_worker,
                        latest_content_agent_source_updated_at(&workspace_for_worker),
                        None,
                        None,
                        Some(final_error),
                        None,
                        None,
                    );
                }
                return;
            }
        };
        let config_snapshot = state.config.lock().clone();
        let media_tool_summary = local_media_capabilities(&config_snapshot).summary();
        if is_workspace_synth {
            match run_workspace_synthesizer_orchestrator(
                &state_for_worker,
                &workspace_for_worker,
                &workflow_for_worker,
                &skill_markdown,
                &media_tool_summary,
            )
            .await
            {
                Ok((reply, applied)) => {
                    let run_finished_at = Utc::now().to_rfc3339();
                    if applied.had_errors && !applied.applied_any {
                        let final_error = truncate_with_ellipsis(&applied.summary, 4000);
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
                        let _ = local_store::patch_chat_status(
                            &workspace_for_worker,
                            &user_id_for_worker,
                            "error",
                            Some(&final_error),
                        );
                        save_workspace_synthesizer_status(
                            &workspace_for_worker,
                            "error",
                            source,
                            &thread_id_for_worker,
                            latest_content_agent_source_updated_at(&workspace_for_worker),
                            Some(run_finished_at),
                            Some(applied.summary.clone()),
                            Some(final_error),
                            Some(applied.counts.clone()),
                            Some(applied.artifact_states.clone()),
                        );
                    } else {
                        let final_reply = truncate_with_ellipsis(reply.trim(), 4000);
                        let _ = local_store::create_chat_message(
                            &workspace_for_worker,
                            &thread_id_for_worker,
                            "assistant",
                            &final_reply,
                            "done",
                            "workflow-runner",
                            Some(&user_id_for_worker),
                            None,
                        );
                        let _ = local_store::patch_chat_status(
                            &workspace_for_worker,
                            &user_id_for_worker,
                            "done",
                            None,
                        );
                        save_workspace_synthesizer_status(
                            &workspace_for_worker,
                            "done",
                            source,
                            &thread_id_for_worker,
                            latest_content_agent_source_updated_at(&workspace_for_worker),
                            Some(run_finished_at),
                            Some(applied.summary.clone()),
                            None,
                            Some(applied.counts.clone()),
                            Some(applied.artifact_states.clone()),
                        );
                    }
                }
                Err(err) => {
                    let final_error = truncate_with_ellipsis(
                        &format!("Workspace synthesis orchestration failed.\n\n{err:#}"),
                        4000,
                    );
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
                    let _ = local_store::patch_chat_status(
                        &workspace_for_worker,
                        &user_id_for_worker,
                        "error",
                        Some(&final_error),
                    );
                    save_workspace_synthesizer_status(
                        &workspace_for_worker,
                        "error",
                        source,
                        &thread_id_for_worker,
                        latest_content_agent_source_updated_at(&workspace_for_worker),
                        None,
                        None,
                        Some(final_error),
                        None,
                        Some(workspace_synth_default_artifact_states()),
                    );
                }
            }
            return;
        }
        let run_prompt =
            render_content_agent_run_prompt(&workflow_for_worker, &skill_markdown, &media_tool_summary);
        let run_result = tokio::time::timeout(
            Duration::from_secs(CONTENT_AGENT_TIMEOUT_SECS),
            run_local_agent_prompt_in_thread(
                &state_for_worker,
                &thread_id_for_worker,
                &run_prompt,
            ),
        )
        .await;

        match run_result {
            Ok(Ok(reply)) => {
                if is_workspace_synth {
                    let workspace_for_apply = workspace_for_worker.clone();
                    let apply_result = tokio::task::spawn_blocking(move || {
                        workspace_synthesizer::apply_handoff_files(
                            &workspace_for_apply,
                            &Utc::now().to_rfc3339(),
                        )
                    })
                    .await;

                    match apply_result {
                        Ok(Ok(applied)) => {
                            let run_finished_at = Utc::now().to_rfc3339();
                            if applied.had_errors && !applied.applied_any {
                                let final_error = truncate_with_ellipsis(&applied.summary, 4000);
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
                                let _ = local_store::patch_chat_status(
                                    &workspace_for_worker,
                                    &user_id_for_worker,
                                    "error",
                                    Some(&final_error),
                                );
                                save_workspace_synthesizer_status(
                                    &workspace_for_worker,
                                    "error",
                                    source,
                                    &thread_id_for_worker,
                                    latest_content_agent_source_updated_at(&workspace_for_worker),
                                    Some(run_finished_at),
                                    Some(applied.summary.clone()),
                                    Some(final_error),
                                    Some(applied.counts.clone()),
                                    Some(applied.artifact_states.clone()),
                                );
                            } else {
                                let combined_reply = if reply.trim().is_empty() {
                                    applied.summary.clone()
                                } else {
                                    format!("{}\n\nAgent reply:\n{}", applied.summary, reply.trim())
                                };
                                let final_reply =
                                    truncate_with_ellipsis(combined_reply.trim(), 4000);
                                let _ = local_store::create_chat_message(
                                    &workspace_for_worker,
                                    &thread_id_for_worker,
                                    "assistant",
                                    &final_reply,
                                    "done",
                                    "workflow-runner",
                                    Some(&user_id_for_worker),
                                    None,
                                );
                                let _ = local_store::patch_chat_status(
                                    &workspace_for_worker,
                                    &user_id_for_worker,
                                    "done",
                                    None,
                                );
                                save_workspace_synthesizer_status(
                                    &workspace_for_worker,
                                    "done",
                                    source,
                                    &thread_id_for_worker,
                                    latest_content_agent_source_updated_at(&workspace_for_worker),
                                    Some(run_finished_at),
                                    Some(applied.summary.clone()),
                                    None,
                                    Some(applied.counts.clone()),
                                    Some(applied.artifact_states.clone()),
                                );
                            }
                        }
                        Ok(Err(err)) => {
                            let final_error = truncate_with_ellipsis(
                                &format!("Workspace synthesis apply failed.\n\n{err:#}"),
                                4000,
                            );
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
                            let _ = local_store::patch_chat_status(
                                &workspace_for_worker,
                                &user_id_for_worker,
                                "error",
                                Some(&final_error),
                            );
                            save_workspace_synthesizer_status(
                                &workspace_for_worker,
                                "error",
                                source,
                                &thread_id_for_worker,
                                latest_content_agent_source_updated_at(&workspace_for_worker),
                                None,
                                None,
                                Some(final_error),
                                None,
                                None,
                            );
                        }
                        Err(err) => {
                            let final_error = truncate_with_ellipsis(
                                &format!("Workspace synthesis apply task failed.\n\n{err:#}"),
                                4000,
                            );
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
                            let _ = local_store::patch_chat_status(
                                &workspace_for_worker,
                                &user_id_for_worker,
                                "error",
                                Some(&final_error),
                            );
                            save_workspace_synthesizer_status(
                                &workspace_for_worker,
                                "error",
                                source,
                                &thread_id_for_worker,
                                latest_content_agent_source_updated_at(&workspace_for_worker),
                                None,
                                None,
                                Some(final_error),
                                None,
                                None,
                            );
                        }
                    }
                    return;
                }

                let final_reply = if reply.trim().is_empty() {
                    "Content agent run completed.".to_string()
                } else {
                    truncate_with_ellipsis(reply.trim(), 4000)
                };
                let _ = local_store::create_chat_message(
                    &workspace_for_worker,
                    &thread_id_for_worker,
                    "assistant",
                    &final_reply,
                    "done",
                    "workflow-runner",
                    Some(&user_id_for_worker),
                    None,
                );
                let _ = local_store::patch_chat_status(
                    &workspace_for_worker,
                    &user_id_for_worker,
                    "done",
                    None,
                );
                match load_feed_workflow_settings_store(&workspace_for_worker) {
                    Ok(mut store) => {
                        if let Some(record) = store.workflows.get_mut(&workflow_for_worker.key) {
                            record.last_run_at = Some(Utc::now().to_rfc3339());
                            if let Err(err) =
                                save_feed_workflow_settings_store(&workspace_for_worker, &store)
                            {
                                tracing::warn!(
                                    "Failed to persist content agent last_run_at for `{}`: {err}",
                                    workflow_for_worker.key
                                );
                            }
                        }
                    }
                    Err(err) => {
                        tracing::warn!(
                            "Failed to load workflow settings store after run success for `{}`: {err}",
                            workflow_for_worker.key
                        );
                    }
                }
            }
            Ok(Err(err)) => {
                let final_error =
                    truncate_with_ellipsis(&format!("Content agent run failed.\n\n{err:#}"), 4000);
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
                let _ = local_store::patch_chat_status(
                    &workspace_for_worker,
                    &user_id_for_worker,
                    "error",
                    Some(&final_error),
                );
                if is_workspace_synth {
                    save_workspace_synthesizer_status(
                        &workspace_for_worker,
                        "error",
                        source,
                        &thread_id_for_worker,
                        latest_content_agent_source_updated_at(&workspace_for_worker),
                        None,
                        None,
                        Some(final_error),
                        None,
                        None,
                    );
                }
            }
            Err(_) => {
                let final_error = format!(
                    "Content agent run timed out after {}s",
                    CONTENT_AGENT_TIMEOUT_SECS
                );
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
                let _ = local_store::patch_chat_status(
                    &workspace_for_worker,
                    &user_id_for_worker,
                    "error",
                    Some(&final_error),
                );
                if is_workspace_synth {
                    save_workspace_synthesizer_status(
                        &workspace_for_worker,
                        "error",
                        source,
                        &thread_id_for_worker,
                        latest_content_agent_source_updated_at(&workspace_for_worker),
                        None,
                        None,
                        Some(final_error),
                        None,
                        None,
                    );
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

fn normalize_goal_text(value: Option<String>) -> Option<String> {
    value.and_then(|raw| {
        let trimmed = raw.trim().to_string();
        (!trimmed.is_empty()).then_some(trimmed)
    })
}

fn derive_workflow_name_from_goal(goal: &str) -> String {
    let tokens: Vec<String> = goal
        .split(|ch: char| !ch.is_ascii_alphanumeric())
        .filter(|token| !token.is_empty())
        .take(6)
        .map(|token| {
            let mut chars = token.chars();
            match chars.next() {
                Some(first) => {
                    let mut out = String::new();
                    out.push(first.to_ascii_uppercase());
                    out.push_str(chars.as_str());
                    out
                }
                None => String::new(),
            }
        })
        .filter(|token| !token.is_empty())
        .collect();
    if tokens.is_empty() {
        "Content Agent".to_string()
    } else {
        tokens.join(" ")
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

fn render_template_skill_markdown(
    skill_name: &str,
    goal: &str,
    output_dir: &str,
) -> String {
    format!(
        "# {skill_name}\n\n\
Use this content agent to fulfill the following goal:\n\n\
> {goal}\n\n\
## Sources\n\n\
- `journals/text/**`\n\
- transcript files under `journals/text/transcriptions/**` when present\n\n\
 - `journals/media/audio/**` and `journals/media/video/**` when the goal depends on journal media\n\n\
## Output\n\n\
- `{output_dir}`\n\n\
## Output Rules\n\n\
- Write feed-visible artifacts only under `{output_dir}`.\n\
- Hidden intermediates may go under `{output_dir}/pipeline/` or `{output_dir}/artifacts/`.\n\
- If generating multiple distinct post candidates, save each as a separate file.\n\
- Prefer built-in runtime tools for media and transcription tasks; do not hardcode scripts or shell pipelines when a built-in tool exists.\n\
- Keep unrelated workspace files untouched.\n"
    )
}

fn render_audio_insight_clip_skill_markdown(output_dir: &str) -> String {
    format!(
        "# Audio Insight Clips\n\n\
Create simple vertical video clips from journal audio recordings.\n\n\
## Sources\n\n\
- `journals/media/audio/**`\n\
- `journals/text/transcriptions/audio/**` when present\n\
- `journals/text/transcriptions/**` for existing transcript sidecars\n\
- `journals/text/**` for context if useful\n\n\
## Output\n\n\
- Final feed-visible clips: `{output_dir}`\n\
- Hidden intermediates: `{output_dir}/pipeline/`\n\n\
## Workflow\n\n\
1. Find one or more strong source recordings under `journals/media/audio/**`.\n\
2. For each chosen recording, look for a transcript text file under `journals/text/transcriptions/**` using the same stem and relative media path.\n\
3. If the transcript is missing, call the built-in `transcribe_media` tool for that recording.\n\
4. Read the transcript and extract exact insightful lines. Do not rewrite the quoted line if it will appear inside the video card.\n\
5. Optionally call `clean_audio` when the source recording is noisy.\n\
6. If you need a precise quote segment, call `extract_audio_segment` with the exact start/end range.\n\
7. Render the final clip with `compose_simple_clip` or `render_text_card_video` using white text on a black background.\n\
8. Save the final `.mp4` directly under `{output_dir}` so it appears in the workspace feed.\n\n\
## Output Rules\n\n\
- Use a black background with white text cards.\n\
- Prefer 1 to 3 exact lines per clip.\n\
- Keep final clips concise and feed-ready.\n\
- Put JSON manifests, transcripts, and other machine files only under `{output_dir}/pipeline/`.\n\
- Prefer built-in runtime tools over shell commands or scripts.\n\
- Do not overwrite unrelated posts.\n"
    )
}

fn validate_content_agent_skill_contract(skill_abs: &StdPath) -> Result<()> {
    let raw = std::fs::read_to_string(skill_abs)
        .with_context(|| format!("failed to read generated skill {}", skill_abs.display()))?;
    let required_fragments = ["journals/text", "posts/", "Output Rules"];
    for fragment in required_fragments {
        if !raw.contains(fragment) {
            anyhow::bail!(
                "generated content agent skill is missing required fragment `{fragment}` (file: {})",
                skill_abs.display()
            );
        }
    }
    for banned in ["python3 ", "ffmpeg ", "ffprobe ", "scripts/"] {
        if raw.contains(banned) {
            anyhow::bail!(
                "generated content agent skill must use built-in media tools instead of `{banned}` (file: {})",
                skill_abs.display()
            );
        }
    }
    Ok(())
}

fn render_content_agent_authoring_prompt(
    workflow_name: &str,
    workflow_key: &str,
    workflow_bot: &str,
    skill_rel: &str,
    output_dir_rel: &str,
    goal: &str,
    creation_skill_markdown: &str,
    current_skill_body: &str,
    media_tool_summary: &str,
) -> String {
    let mut prompt = String::new();
    prompt.push_str("Use the content agent creation skill below to author or update a workspace feed content agent.\n\n");
    prompt.push_str("## Creation Skill\n");
    prompt.push_str("```markdown\n");
    prompt.push_str(creation_skill_markdown.trim());
    prompt.push_str("\n```\n\n");
    prompt.push_str("## Agent Request\n");
    prompt.push_str(&format!("- Name: {workflow_name}\n"));
    prompt.push_str(&format!("- Key: {workflow_key}\n"));
    prompt.push_str(&format!("- Bot: {workflow_bot}\n"));
    prompt.push_str(&format!("- Goal: \"{}\"\n", goal.trim()));
    prompt.push_str("- Fixed journal sources: `journals/text/**`, transcript files under `journals/text/transcriptions/**`, and journal media under `journals/media/audio/**` or `journals/media/video/**` when the goal requires media-derived output\n");
    prompt.push_str(&format!("- Fixed output root: `{output_dir_rel}`\n\n"));

    prompt.push_str("## Required File\n");
    prompt.push_str(&format!("- Content agent skill: `{skill_rel}`\n\n"));

    prompt.push_str("## Current Skill Content\n");
    prompt.push_str("Replace this file with improved content aligned to the goal.\n\n");
    prompt.push_str("```markdown\n");
    prompt.push_str(current_skill_body.trim());
    prompt.push_str("\n```\n\n");

    prompt.push_str("## Hard Requirements\n");
    prompt.push_str("- Update only the content agent skill file.\n");
    prompt.push_str("- Keep the sources fixed to journal notes, available transcripts, and journal media only when the goal requires media-derived output.\n");
    prompt.push_str("- Keep the output fixed under the posts folder.\n");
    prompt.push_str("- Hidden intermediate files may live under the output root in `pipeline/` or `artifacts/`.\n");
    prompt.push_str("- Tell the agent to create multiple files when multiple distinct post candidates are useful.\n");
    prompt.push_str("- Keep instructions concrete and operational, not generic.\n");
    prompt.push_str(&format!("- {media_tool_summary}\n"));
    prompt.push_str("- Prefer built-in runtime media tools such as `transcribe_media`, `clean_audio`, `extract_audio_segment`, `render_text_card_video`, `stitch_images_with_audio`, and `compose_simple_clip` when they are available on this device.\n");
    prompt.push_str("- Do not hardcode `python3`, `ffmpeg`, `ffprobe`, or `scripts/...` into the generated skill.\n");
    prompt.push_str("- Use the file_write tool to overwrite the skill file directly.\n");
    prompt.push_str("- Do not respond with a patch description only.\n\n");
    prompt.push_str("After editing, reply with a concise summary of what changed in the skill.\n");
    prompt
}

fn render_content_agent_run_prompt(
    workflow: &FeedContentAgentDefinition,
    skill_markdown: &str,
    media_tool_summary: &str,
) -> String {
    let mut prompt = String::new();
    prompt.push_str("Run the following content agent and create feed artifacts in the workspace.\n\n");
    prompt.push_str("## Agent\n");
    prompt.push_str(&format!("- Name: {}\n", workflow.bot_name));
    prompt.push_str(&format!("- Key: {}\n", workflow.key));
    prompt.push_str(&format!("- Goal: {}\n", workflow.goal.trim()));
    prompt.push_str(&format!("- Skill file: `{}`\n", workflow.skill_path));
    prompt.push_str(&format!("- Output root: `{}`\n\n", workflow.output_prefix));
    prompt.push_str("## Skill\n");
    prompt.push_str("```markdown\n");
    prompt.push_str(skill_markdown.trim());
    prompt.push_str("\n```\n\n");
    prompt.push_str("## Execution Rules\n");
    prompt.push_str("- Read from `journals/text/**`, available transcript files, and journal media files when relevant to the goal.\n");
    prompt.push_str("- If a needed transcript for journal media is missing, use `transcribe_media` and save outputs under `journals/text/transcriptions/**`.\n");
    prompt.push_str(&format!("- {media_tool_summary}\n"));
    prompt.push_str("- For deterministic media transforms, use only the built-in media tools that are available on this device.\n");
    prompt.push_str("- Do not invent script paths or raw ffmpeg commands inside the skill execution.\n");
    if workflow.key == WORKSPACE_SYNTHESIZER_WORKFLOW_KEY {
        prompt.push_str(&format!(
            "- Write only small JSON handoff files under `{}`.\n",
            workspace_synthesizer::WORKSPACE_SYNTHESIZER_PIPELINE_DIR
        ));
        prompt.push_str(&format!(
            "- Allowed handoff files: `{}`, `{}`, `{}`, `{}`.\n",
            workspace_synthesizer::WORKSPACE_SYNTHESIZER_INSIGHT_POSTS_PATH,
            workspace_synthesizer::WORKSPACE_SYNTHESIZER_TODOS_PATH,
            workspace_synthesizer::WORKSPACE_SYNTHESIZER_EVENTS_PATH,
            workspace_synthesizer::WORKSPACE_SYNTHESIZER_CLIP_PLANS_PATH
        ));
        prompt.push_str("- Omit any handoff file that has no strong candidates, or write an empty `items` array.\n");
        prompt.push_str("- Do not directly write feed posts, todos, events, or clip plan outputs.\n");
        prompt.push_str("- Use direct file edits in the workspace so the runtime can validate and apply each handoff independently.\n");
    } else {
        prompt.push_str(&format!("- Write feed-visible artifacts only under `{}`.\n", workflow.output_prefix));
        prompt.push_str(&format!("- Hidden intermediate artifacts may go under `{}/pipeline/` or `{}/artifacts/`.\n", workflow.output_prefix.trim_end_matches('/'), workflow.output_prefix.trim_end_matches('/')));
        prompt.push_str("- If multiple distinct post candidates are useful, save each as a separate file.\n");
    }
    prompt.push_str("- Use direct file edits in the workspace, not code blocks in chat.\n");
    prompt.push_str("- Reply with a concise summary of files written.\n");
    prompt
}

fn workflow_comment_prompt(
    workflow: &FeedContentAgentDefinition,
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
    prompt.push_str(&format!("- Agent skill: `{}`\n", workflow.skill_path));
    prompt.push_str(&format!("- Feed item: `{feed_item_path}`\n\n"));

    prompt.push_str("## Guardrails\n");
    prompt.push_str("- Edit only the listed files.\n");
    prompt.push_str("- Update the target feed item directly when the request is about that one item.\n");
    prompt.push_str("- Update the skill only if the request should change future generated posts too.\n");
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
    _workflow: &FeedContentAgentDefinition,
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

    let store = match load_or_seed_feed_workflow_settings_store(&workspace_dir) {
        Ok(store) => store,
        Err(err) => {
            tracing::warn!("Failed to load workflow settings store: {err}");
            return (
                StatusCode::INTERNAL_SERVER_ERROR,
                Json(serde_json::json!({"error": err.to_string()})),
            );
        }
    };

    let media_capabilities = local_media_capabilities(&state.config.lock().clone());
    let mut items = Vec::new();
    for workflow in workflow_definitions(&store) {
        let enabled = store
            .workflows
            .get(&workflow.key)
            .map(|record| record.enabled)
            .unwrap_or_else(default_content_agent_enabled);
        items.push(workflow_settings_response_item(
            &workflow,
            enabled,
            media_capabilities,
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
    Json(body): Json<FeedContentAgentUpdateBody>,
) -> impl IntoResponse {
    if let Some(err) = pairing_auth_error(&state, &headers, "Feed workflow settings update") {
        return err;
    }

    let workflow_key = body.workflow_key.trim().to_ascii_lowercase();
    let workspace_dir = state.config.lock().workspace_dir.clone();
    let mut store = match load_or_seed_feed_workflow_settings_store(&workspace_dir) {
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
    let updated_goal = normalize_goal_text(body.goal.or(body.prompt));
    let previous_goal = normalize_goal_text(workflow_record.goal.clone())
        .or_else(|| normalize_goal_text(workflow_record.settings.goal.clone()))
        .or_else(|| normalize_goal_text(workflow_record.settings.prompt.clone()));
    let Some(goal) = updated_goal
        .clone()
        .or_else(|| previous_goal.clone())
    else {
        let err = serde_json::json!({"error": "goal is required"});
        return (StatusCode::BAD_REQUEST, Json(err));
    };
    let media_capabilities = local_media_capabilities(&state.config.lock().clone());
    if goal_requests_media_output(&goal)
        && !(media_capabilities.transcribe_media && media_capabilities.compose_simple_clip)
    {
        let err = serde_json::json!({
            "error": required_media_capability_reason(media_capabilities),
        });
        return (StatusCode::BAD_REQUEST, Json(err));
    }
    let goal_changed = updated_goal
        .as_ref()
        .map(|value| previous_goal.as_deref() != Some(value.as_str()))
        .unwrap_or(false);
    if updated_goal.is_some() {
        workflow_record.goal = Some(goal.clone());
        workflow_record.settings.goal = Some(goal.clone());
        workflow_record.settings.prompt = Some(goal.clone());
    }
    workflow_record.enabled = body.enabled.unwrap_or(workflow_record.enabled);
    workflow_record = normalize_workflow_record(&workflow.key, workflow_record);

    let skill_abs = workspace_dir.join(&workflow_record.skill_path);
    if goal_changed {
        let replacement_skill = render_template_skill_markdown(
            &workflow_record.workflow_bot,
            &goal,
            workflow_record.output_prefix.trim_end_matches('/'),
        );
        if let Err(err) = std::fs::write(&skill_abs, replacement_skill) {
            return (
                StatusCode::INTERNAL_SERVER_ERROR,
                Json(serde_json::json!({"error": format!("failed to update skill: {err}")})),
            );
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
        let authoring_prompt = render_content_agent_authoring_prompt(
            &workflow_record.workflow_bot,
            &workflow.key,
            &workflow_record.workflow_bot,
            &workflow_record.skill_path,
            workflow_record.output_prefix.trim_end_matches('/'),
            &goal,
            &creation_skill_markdown,
            &std::fs::read_to_string(&skill_abs).unwrap_or_default(),
            &local_media_capabilities(&state.config.lock().clone()).summary(),
        );
        let authoring_thread_id = format!("workflow:update:{}", workflow.key);
        let authoring_result = tokio::time::timeout(
            Duration::from_secs(CONTENT_AGENT_TIMEOUT_SECS),
            run_local_agent_prompt_in_thread(&state, &authoring_thread_id, &authoring_prompt),
        )
        .await;
        match authoring_result {
            Ok(Ok(_)) => {}
            Ok(Err(err)) => {
                return (
                    StatusCode::INTERNAL_SERVER_ERROR,
                    Json(serde_json::json!({"error": format!("content agent update failed: {err:#}")})),
                );
            }
            Err(_) => {
                return (
                    StatusCode::INTERNAL_SERVER_ERROR,
                    Json(serde_json::json!({"error": format!("content agent update timed out after {}s", CONTENT_AGENT_TIMEOUT_SECS)})),
                );
            }
        }

        if let Err(err) = validate_content_agent_skill_contract(&skill_abs) {
            return (
                StatusCode::INTERNAL_SERVER_ERROR,
                Json(serde_json::json!({"error": format!("updated skill failed validation: {err:#}")})),
            );
        }
    } else if let Err(err) = ensure_content_agent_skill_file(&workspace_dir, &workflow_record) {
        return (
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(serde_json::json!({"error": format!("failed to ensure skill: {err:#}")})),
        );
    }

    store
        .workflows
        .insert(workflow.key.to_string(), workflow_record.clone());
    if let Err(err) = save_feed_workflow_settings_store(&workspace_dir, &store) {
        tracing::warn!("Failed to persist workflow settings: {err}");
        return (
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(serde_json::json!({"error": err.to_string()})),
        );
    }

    let workflow_def = feed_workflow_definition_from_record(&workflow_record);
    let run_thread_id = if workflow_record.enabled && body.run_now.unwrap_or(false) {
        match queue_workflow_run(state.clone(), workflow_def.clone(), "workflow-settings-save") {
            Ok(thread_id) => Some(thread_id),
            Err(err) => {
                tracing::warn!("Failed to queue workflow run after settings save: {err}");
                None
            }
        }
    } else {
        None
    };

    let item = workflow_settings_response_item(
        &workflow_def,
        workflow_record.enabled,
        local_media_capabilities(&state.config.lock().clone()),
    );
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
    Json(body): Json<FeedContentAgentRunBody>,
) -> impl IntoResponse {
    if let Some(err) = pairing_auth_error(&state, &headers, "Feed workflow run") {
        return err;
    }

    let workflow_key = body.workflow_key.trim().to_ascii_lowercase();
    let workspace_dir = state.config.lock().workspace_dir.clone();
    let store = load_or_seed_feed_workflow_settings_store(&workspace_dir).unwrap_or_default();
    let Some(workflow) = workflow_definition_by_key(&store, &workflow_key) else {
        let err = serde_json::json!({
            "error": "unknown workflowKey",
            "supportedWorkflowKeys": store.workflows.keys().collect::<Vec<_>>(),
        });
        return (StatusCode::BAD_REQUEST, Json(err));
    };
    let media_capabilities = local_media_capabilities(&state.config.lock().clone());
    if let Some(reason) = workflow_unsupported_reason(&workflow, media_capabilities) {
        let err = serde_json::json!({
            "error": reason,
            "workflowKey": workflow_key,
            "workflowBot": workflow.bot_name,
        });
        return (StatusCode::BAD_REQUEST, Json(err));
    }

    let workflow_bot = workflow.bot_name.clone();
    match queue_workflow_run(state.clone(), workflow, "workflow-run-manual") {
        Ok(thread_id) => (
            StatusCode::OK,
            Json(serde_json::json!({
                "queued": true,
                "threadId": thread_id,
                "workflowKey": workflow_key,
                "workflowBot": workflow_bot,
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

async fn handle_feed_workflow_auto_run(
    State(state): State<AppState>,
    headers: HeaderMap,
    Json(body): Json<FeedContentAgentAutoRunBody>,
) -> impl IntoResponse {
    if let Some(err) = pairing_auth_error(&state, &headers, "Feed workflow auto run") {
        return err;
    }

    let trigger = match body.reason.as_deref().map(str::trim) {
        Some(reason) if reason.eq_ignore_ascii_case("journal-save") => {
            ContentAgentAutoRunTrigger::JournalSave
        }
        Some(reason) if reason.eq_ignore_ascii_case("transcript-ready") => {
            ContentAgentAutoRunTrigger::TranscriptReady
        }
        _ => ContentAgentAutoRunTrigger::AppOpen,
    };

    match queue_eligible_content_agents_for_trigger(&state, trigger) {
        Ok(items) => (
            StatusCode::OK,
            Json(serde_json::json!({
                "queuedCount": items.len(),
                "items": items,
            })),
        ),
        Err(err) => {
            tracing::warn!("Failed to auto-run eligible content agents: {err}");
            (
                StatusCode::INTERNAL_SERVER_ERROR,
                Json(serde_json::json!({"error": err.to_string()})),
            )
        }
    }
}

async fn handle_workspace_synthesizer_status(
    State(state): State<AppState>,
    headers: HeaderMap,
) -> impl IntoResponse {
    if let Some(err) = pairing_auth_error(&state, &headers, "Workspace synthesizer status") {
        return err;
    }

    let workspace_dir = state.config.lock().workspace_dir.clone();
    let status = workspace_synthesizer::load_status(&workspace_dir);
    (
        StatusCode::OK,
        Json(serde_json::to_value(status).unwrap_or_else(|_| serde_json::json!({}))),
    )
}

async fn handle_workspace_synthesizer_run(
    State(state): State<AppState>,
    headers: HeaderMap,
) -> impl IntoResponse {
    if let Some(err) = pairing_auth_error(&state, &headers, "Workspace synthesizer run") {
        return err;
    }

    let workspace_dir = state.config.lock().workspace_dir.clone();
    let latest_source_updated_at = latest_content_agent_source_updated_at(&workspace_dir);
    if latest_source_updated_at <= 0 {
        return (
            StatusCode::BAD_REQUEST,
            Json(serde_json::json!({"error": "No journal text sources are available yet"})),
        );
    }

    match queue_workspace_synthesizer_run(
        state.clone(),
        "manual",
        latest_source_updated_at,
    ) {
        Ok(thread_id) => (
            StatusCode::OK,
            Json(serde_json::json!({
                "queued": true,
                "threadId": thread_id,
            })),
        ),
        Err(err) => (
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(serde_json::json!({"error": err.to_string()})),
        ),
    }
}

async fn handle_workspace_synthesizer_auto_run(
    State(state): State<AppState>,
    headers: HeaderMap,
    Json(body): Json<WorkspaceSynthesizerAutoRunBody>,
) -> impl IntoResponse {
    if let Some(err) = pairing_auth_error(&state, &headers, "Workspace synthesizer auto run") {
        return err;
    }

    let reason = body
        .reason
        .as_deref()
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .unwrap_or("app-open");

    match queue_workspace_synthesizer_for_trigger(&state, reason) {
        Ok(Some(thread_id)) => (
            StatusCode::OK,
            Json(serde_json::json!({
                "queued": true,
                "threadId": thread_id,
            })),
        ),
        Ok(None) => (
            StatusCode::OK,
            Json(serde_json::json!({
                "queued": false,
            })),
        ),
        Err(err) => (
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(serde_json::json!({"error": err.to_string()})),
        ),
    }
}

async fn handle_workspace_todos_list(
    State(state): State<AppState>,
    headers: HeaderMap,
    Query(query): Query<WorkspaceListQuery>,
) -> impl IntoResponse {
    if let Some(err) = pairing_auth_error(&state, &headers, "Workspace todos") {
        return err;
    }

    let workspace_dir = state.config.lock().workspace_dir.clone();
    let limit = query.limit.unwrap_or(100);
    match local_store::list_workspace_todos(&workspace_dir, limit) {
        Ok(items) => (StatusCode::OK, Json(serde_json::json!({ "items": items }))),
        Err(err) => (
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(serde_json::json!({ "error": err.to_string() })),
        ),
    }
}

async fn handle_workspace_todo_update(
    State(state): State<AppState>,
    headers: HeaderMap,
    AxumPath(todo_id): AxumPath<String>,
    Json(body): Json<WorkspaceTodoUpdateBody>,
) -> impl IntoResponse {
    if let Some(err) = pairing_auth_error(&state, &headers, "Workspace todo update") {
        return err;
    }

    let status = body.status.unwrap_or_default().trim().to_ascii_lowercase();
    if status != "open" && status != "done" {
        return (
            StatusCode::BAD_REQUEST,
            Json(serde_json::json!({"error": "status must be `open` or `done`"})),
        );
    }
    let workspace_dir = state.config.lock().workspace_dir.clone();
    let update = local_store::WorkspaceTodoStatusUpdate {
        id: todo_id,
        status_override: status,
    };
    match local_store::update_workspace_todo_status(&workspace_dir, &update) {
        Ok(item) => (StatusCode::OK, Json(serde_json::json!({ "item": item }))),
        Err(err) => (
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(serde_json::json!({ "error": err.to_string() })),
        ),
    }
}

async fn handle_workspace_events_list(
    State(state): State<AppState>,
    headers: HeaderMap,
    Query(query): Query<WorkspaceListQuery>,
) -> impl IntoResponse {
    if let Some(err) = pairing_auth_error(&state, &headers, "Workspace events") {
        return err;
    }

    let workspace_dir = state.config.lock().workspace_dir.clone();
    let limit = query.limit.unwrap_or(100);
    match local_store::list_workspace_events(&workspace_dir, limit) {
        Ok(items) => (StatusCode::OK, Json(serde_json::json!({ "items": items }))),
        Err(err) => (
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(serde_json::json!({ "error": err.to_string() })),
        ),
    }
}

async fn handle_feed_personalized(
    State(state): State<AppState>,
    headers: HeaderMap,
    Json(body): Json<PersonalizedFeedRequest>,
) -> impl IntoResponse {
    if let Some(err) = pairing_auth_error(&state, &headers, "Personalized feed") {
        return err;
    }

    let limit = body.limit.unwrap_or(30).clamp(1, BLUESKY_TIMELINE_LIMIT_MAX);
    let config_snapshot = state.config.lock().clone();
    let workspace_dir = config_snapshot.workspace_dir.clone();
    let bluesky_auth = match (
        body.service_url
            .as_deref()
            .map(str::trim)
            .filter(|value| !value.is_empty()),
        body.access_jwt
            .as_deref()
            .map(str::trim)
            .filter(|value| !value.is_empty()),
    ) {
        (Some(service_url), Some(access_jwt)) => {
            Some((service_url.to_string(), access_jwt.to_string()))
        }
        _ => None,
    };

    let fallback_candidates = || {
        let bluesky_auth = bluesky_auth.clone();
        async move {
            match bluesky_auth.as_ref() {
                Some((service_url, access_jwt)) => {
                    fetch_bluesky_fallback_candidates(service_url, access_jwt, limit).await
                }
                None => Ok(Vec::new()),
            }
        }
    };

    let (embedder, embedder_message) = match resolve_feed_embedder(&config_snapshot).await {
        Ok((embedder, message)) => (embedder, message),
        Err(err) => (
            None,
            Some(format!(
                "Failed to initialize the configured embedding provider: {err}"
            )),
        ),
    };

    if let Err(err) = refresh_cached_content_sources(&workspace_dir, embedder.clone()).await {
        tracing::warn!("Failed to refresh cached content sources: {err}");
    }

    if let Some(embedder) = embedder.as_ref() {
        spawn_cached_content_item_embedding_backfill(workspace_dir.clone(), embedder.clone());
    }

    let recent_content_items = build_recent_content_items(&workspace_dir, limit).unwrap_or_default();

    let Some(embedder) = embedder else {
        let mut items = recent_content_items.clone();
        match fallback_candidates().await {
            Ok(candidates) => append_feed_items_up_to_limit(
                &mut items,
                build_raw_personalized_items(candidates, limit),
                limit,
            ),
            Err(err) => {
                if items.is_empty() {
                    return (
                        StatusCode::BAD_GATEWAY,
                        Json(serde_json::json!({
                            "error": format!("Failed to fetch Bluesky candidates: {err}")
                        })),
                    );
                }
            }
        }
        return (
            StatusCode::OK,
            Json(serde_json::json!({
                "items": items,
                "profileStatus": "embeddingUnavailable",
                "profileStats": InterestProfileStats::default(),
                "usedFallback": true,
                "message": embedder_message.unwrap_or_else(|| {
                    "Configured feed embeddings are unavailable. Showing recent cached content and raw Bluesky items when available.".to_string()
                }),
            })),
        );
    };

    let profile = match rebuild_interest_profile(&config_snapshot, embedder.clone()).await {
        Ok(profile) => profile,
        Err(err) => {
            let mut items = recent_content_items.clone();
            match fallback_candidates().await {
                Ok(candidates) => append_feed_items_up_to_limit(
                    &mut items,
                    build_raw_personalized_items(candidates, limit),
                    limit,
                ),
                Err(fetch_err) => {
                    if items.is_empty() {
                        return (
                            StatusCode::BAD_GATEWAY,
                            Json(serde_json::json!({
                                "error": format!("Failed to fetch Bluesky candidates: {fetch_err}")
                            })),
                        );
                    }
                }
            }
            return (
                StatusCode::OK,
                Json(serde_json::json!({
                    "items": items,
                    "profileStatus": "fallbackRaw",
                    "profileStats": InterestProfileStats::default(),
                    "usedFallback": true,
                    "message": format!("Failed to rebuild interest profile: {err}"),
                })),
            );
        }
    };

    if profile.status != "ready" || profile.interests.is_empty() {
        let mut items = recent_content_items.clone();
        match fallback_candidates().await {
            Ok(candidates) => append_feed_items_up_to_limit(
                &mut items,
                build_raw_personalized_items(candidates, limit),
                limit,
            ),
            Err(err) => {
                if items.is_empty() {
                    return (
                        StatusCode::BAD_GATEWAY,
                        Json(serde_json::json!({
                            "error": format!("Failed to fetch Bluesky candidates: {err}")
                        })),
                    );
                }
            }
        }
        return (
            StatusCode::OK,
            Json(serde_json::json!({
                "items": items,
                "profileStatus": profile.status,
                "profileStats": profile.stats,
                "usedFallback": true,
                "message": "Personalized feed starts after text items exist under posts/.",
            })),
        );
    }

    let mut ranked_items = match rank_cached_content_items(&workspace_dir, &profile.interests, limit) {
        Ok(items) => items,
        Err(err) => {
            tracing::warn!("Failed to rank cached content items: {err}");
            Vec::new()
        }
    };

    let (ranked_bluesky_items, raw_bluesky_candidates, mut fallback_message): (
        Vec<PersonalizedBlueskyItem>,
        Vec<CandidateFeedPost>,
        Option<String>,
    ) = match bluesky_auth.as_ref() {
        Some((service_url, access_jwt)) => match collect_ranked_bluesky_matches(
            service_url,
            access_jwt,
            embedder.clone(),
            &profile.interests,
            limit,
        )
        .await
        {
            Ok((items, raw_candidates)) => (items, raw_candidates, None),
            Err(err) => {
                tracing::warn!("Failed to rank personalized Bluesky feed: {err}");
                let raw_candidates = match fallback_candidates().await {
                    Ok(candidates) => candidates,
                    Err(fetch_err) => {
                        return (
                            StatusCode::BAD_GATEWAY,
                            Json(serde_json::json!({
                                "error": format!("Failed to fetch Bluesky candidates: {fetch_err}")
                            })),
                        );
                    }
                };
                (
                    Vec::new(),
                    raw_candidates,
                    Some("Personalized Bluesky ranking failed. Raw Bluesky results are available.".to_string()),
                )
            }
        },
        None => (Vec::new(), Vec::new(), None),
    };
    ranked_items.extend(ranked_bluesky_items);

    match collect_web_search_candidates(&config_snapshot, &profile.interests).await {
        Ok(web_candidates) if !web_candidates.is_empty() => {
            match rank_web_candidates(
                &workspace_dir,
                embedder,
                &profile.interests,
                web_candidates,
                limit,
            )
            .await
            {
                Ok(mut web_items) => ranked_items.append(&mut web_items),
                Err(err) => {
                    tracing::warn!("Failed to rank web feed candidates: {err}");
                    if fallback_message.is_none() {
                        fallback_message = Some(
                            "Web link discovery failed; showing cached and Bluesky results only."
                                .to_string(),
                        );
                    }
                }
            }
        }
        Ok(_) => {}
        Err(err) => {
            tracing::warn!("Failed to collect web feed candidates: {err}");
            if fallback_message.is_none() {
                fallback_message =
                    Some("Web link discovery failed; showing cached and Bluesky results only.".to_string());
            }
        }
    }

    sort_personalized_items(&mut ranked_items);
    ranked_items.truncate(limit);
    if ranked_items.is_empty() {
        let mut fallback_items = recent_content_items;
        append_feed_items_up_to_limit(
            &mut fallback_items,
            build_raw_personalized_items(raw_bluesky_candidates, limit),
            limit,
        );
        let message = fallback_message.unwrap_or_else(|| {
            if fallback_items.is_empty() {
                "No personalized matches are available yet.".to_string()
            } else {
                "No matches passed the similarity threshold. Showing recent cached content and raw Bluesky items."
                    .to_string()
            }
        });
        return (
            StatusCode::OK,
            Json(serde_json::json!({
                "items": fallback_items,
                "profileStatus": "fallbackRaw",
                "profileStats": profile.stats,
                "usedFallback": true,
                "message": message,
            })),
        );
    }

    let used_fallback = false;
    (
        StatusCode::OK,
        Json(serde_json::json!({
            "items": ranked_items,
            "profileStatus": profile.status,
            "profileStats": profile.stats,
            "usedFallback": used_fallback,
            "message": fallback_message,
        })),
    )
}

async fn handle_feed_workflow_template_create(
    State(state): State<AppState>,
    headers: HeaderMap,
    Json(body): Json<FeedContentAgentCreateBody>,
) -> impl IntoResponse {
    if let Some(err) = pairing_auth_error(&state, &headers, "Feed workflow template create") {
        return err;
    }

    let name = body
        .name
        .as_deref()
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(ToOwned::to_owned);
    let Some(name) = name else {
        return (
            StatusCode::BAD_REQUEST,
            Json(serde_json::json!({"error": "name is required"})),
        );
    };

    let goal = normalize_goal_text(body.goal.clone().or(body.prompt.clone()));
    let Some(goal) = goal else {
        return (
            StatusCode::BAD_REQUEST,
            Json(serde_json::json!({"error": "goal is required"})),
        );
    };
    let media_capabilities = local_media_capabilities(&state.config.lock().clone());
    if goal_requests_media_output(&goal)
        && !(media_capabilities.transcribe_media && media_capabilities.compose_simple_clip)
    {
        return (
            StatusCode::BAD_REQUEST,
            Json(serde_json::json!({
                "error": required_media_capability_reason(media_capabilities),
            })),
        );
    }
    let workflow_name = name.clone();
    let workflow_key = sanitize_workflow_key(&workflow_name);

    let workflow_bot = body
        .bot_name
        .as_deref()
        .map(str::trim)
        .filter(|value| !value.is_empty())
        .map(ToOwned::to_owned)
        .unwrap_or_else(|| name.clone());

    let mut settings = FeedWorkflowSettings {
        mode: FeedWorkflowMode::DateRange,
        days: default_feed_workflow_days(),
        random_count: default_feed_workflow_random_count(),
        schedule_enabled: false,
        schedule_cron: default_workflow_schedule_cron(),
        schedule_tz: None,
        goal: Some(goal.clone()),
        prompt: Some(goal.clone()),
    };
    settings = normalize_workflow_settings(settings);

    let workspace_dir = state.config.lock().workspace_dir.clone();
    let store = match load_or_seed_feed_workflow_settings_store(&workspace_dir) {
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
    let skill_rel = format!("skills/{workflow_key}/SKILL.md");
    let skill_abs = workspace_dir.join(&skill_rel);

    let skill_body = render_template_skill_markdown(&workflow_name, &goal, &output_dir_rel);

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
    if let Err(err) = std::fs::write(&skill_abs, skill_body) {
        return (
            StatusCode::INTERNAL_SERVER_ERROR,
            Json(serde_json::json!({"error": format!("failed to write skill: {err}")})),
        );
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
    let creation_prompt = render_content_agent_authoring_prompt(
        &workflow_name,
        &workflow_key,
        &workflow_bot,
        &skill_rel,
        &output_dir_rel,
        &goal,
        &creation_skill_markdown,
        &std::fs::read_to_string(&skill_abs).unwrap_or_default(),
        &local_media_capabilities(&state.config.lock().clone()).summary(),
    );

    let creation_thread_id = format!("workflow:create:{workflow_key}");
    let creation_user_content =
        format!("[create] goal={goal}; key={workflow_key}; skill={skill_rel}; output={output_dir_rel}");
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

    let enabled = body.enabled.unwrap_or(true);
    let run_now = enabled && body.run_now.unwrap_or(true);
    let output_prefix = format!("{output_dir_rel}/");

    let state_for_worker = state.clone();
    let workspace_for_worker = workspace_dir.clone();
    let thread_id_for_worker = creation_thread_id.clone();
    let user_id_for_worker = creation_user_id.clone();
    let workflow_key_for_worker = workflow_key.clone();
    let workflow_bot_for_worker = workflow_bot.clone();
    let skill_rel_for_worker = skill_rel.clone();
    let output_dir_for_worker = output_dir_rel.clone();
    let output_prefix_for_worker = output_prefix.clone();
    let settings_for_worker = settings.clone();
    let creation_prompt_for_worker = creation_prompt.clone();
    let goal_for_worker = goal.clone();

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
            Duration::from_secs(CONTENT_AGENT_TIMEOUT_SECS),
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
                    CONTENT_AGENT_TIMEOUT_SECS
                );
                persist_error(&err_text);
                return;
            }
        };

        let skill_abs_for_worker = workspace_for_worker.join(&skill_rel_for_worker);
        if let Err(err) = validate_content_agent_skill_contract(&skill_abs_for_worker) {
            let err_text = truncate_with_ellipsis(
                &format!("generated content agent skill failed validation: {err:#}"),
                2000,
            );
            persist_error(&err_text);
            return;
        }
        let final_skill = match std::fs::read_to_string(&skill_abs_for_worker) {
            Ok(raw) => raw,
            Err(err) => {
                let err_text =
                    truncate_with_ellipsis(&format!("failed to read generated skill: {err}"), 2000);
                persist_error(&err_text);
                return;
            }
        };
        if final_skill.trim().is_empty() {
            persist_error("content agent creation produced an empty skill file");
            return;
        }

        let mut worker_store = match load_or_seed_feed_workflow_settings_store(&workspace_for_worker) {
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

        let mut workflow_record = FeedContentAgentRecord {
            workflow_key: workflow_key_for_worker.clone(),
            workflow_bot: workflow_bot_for_worker.clone(),
            skill_path: skill_rel_for_worker.clone(),
            output_prefix: output_prefix_for_worker.clone(),
            enabled,
            editable_files: vec![skill_rel_for_worker.clone()],
            goal: Some(goal_for_worker.clone()),
            last_triggered_at: None,
            last_run_at: None,
            last_triggered_source_updated_at: None,
            built_in_skill_fingerprint: None,
            visible_in_ui: true,
            settings: settings_for_worker.clone(),
        };
        workflow_record = normalize_workflow_record(&workflow_key_for_worker, workflow_record);
        let workflow_def = feed_workflow_definition_from_record(&workflow_record);

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
                workflow_def,
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
            "Content agent `{}` ({}) created.\n\nSkill: `{}`\nOutput: `{}`\n",
            workflow_bot_for_worker,
            workflow_key_for_worker,
            skill_rel_for_worker,
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
            "skillPath": skill_rel,
            "outputDir": output_dir_rel,
            "outputPrefix": output_prefix,
            "runQueued": false,
            "runThreadId": serde_json::Value::Null,
            "creationSummary": "Content agent creation queued.",
        })),
    )
}

async fn handle_feed_workflow_comment(
    State(state): State<AppState>,
    headers: HeaderMap,
    Json(body): Json<FeedContentAgentCommentBody>,
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
    let store = load_or_seed_feed_workflow_settings_store(&workspace_dir).unwrap_or_default();
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

            return (
                StatusCode::OK,
                Json(serde_json::json!({
                    "queued": false,
                    "threadId": thread_id,
                    "workflowKey": workflow.key,
                    "workflowBot": workflow.bot_name,
                    "editableFiles": workflow.editable_files,
                    "messageId": user_id,
                    "message": quickfix_message,
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

    if let Err(err) = queue_workspace_synthesizer_for_trigger(&state, "journal-save") {
        tracing::warn!("Failed to queue workspace synthesizer after journal save: {err}");
    }

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
    let media_capabilities = local_media_capabilities(&config_snapshot);
    if !media_capabilities.transcribe_media {
        let err = serde_json::json!({
            "error": "Local transcription is unavailable on this device. Check local media capabilities in settings."
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
    let transcript_json_path = transcript_json_rel_path(&transcript_rel_path);
    let transcript_srt_path = transcript_srt_rel_path(&transcript_rel_path);

    if transcript_abs_path.exists() && transcript_abs_path.is_file() {
        let transcript_text = tokio::fs::read_to_string(&transcript_abs_path)
            .await
            .unwrap_or_default();
        if !transcript_text.trim().is_empty() {
            let body = serde_json::json!({
                "ok": true,
                "mediaPath": requested,
                "path": transcript_rel_path,
                "jsonPath": transcript_json_path,
                "srtPath": transcript_srt_path,
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
        "jsonPath": transcript_json_path,
        "srtPath": transcript_srt_path,
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
    let transcript_json_path = transcript_json_rel_path(&transcript_rel_path);
    let transcript_srt_path = transcript_srt_rel_path(&transcript_rel_path);

    if transcript_abs_path.exists() && transcript_abs_path.is_file() {
        let transcript_text = tokio::fs::read_to_string(&transcript_abs_path)
            .await
            .unwrap_or_default();
        if !transcript_text.trim().is_empty() {
            let body = serde_json::json!({
                "ok": true,
                "mediaPath": requested,
                "path": transcript_rel_path,
                "jsonPath": transcript_json_path,
                "srtPath": transcript_srt_path,
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
            "jsonPath": transcript_json_path,
            "srtPath": transcript_srt_path,
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
        "jsonPath": transcript_json_path,
        "srtPath": transcript_srt_path,
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

fn transcript_json_rel_path(transcript_rel_path: &str) -> String {
    match transcript_rel_path.rsplit_once('.') {
        Some((base, _)) => format!("{base}.json"),
        None => format!("{transcript_rel_path}.json"),
    }
}

fn transcript_srt_rel_path(transcript_rel_path: &str) -> String {
    match transcript_rel_path.rsplit_once('.') {
        Some((base, _)) => format!("{base}.srt"),
        None => format!("{transcript_rel_path}.srt"),
    }
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

        if final_state.status == "done" {
            if let Err(err) =
                queue_workspace_synthesizer_for_trigger(&state_for_task, "transcript-ready")
            {
                tracing::warn!("Failed to queue workspace synthesizer after transcription: {err}");
            }
        }

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
    let transcript_json_path = transcript_json_rel_path(&transcript_rel_path);
    let transcript_srt_path = transcript_srt_rel_path(&transcript_rel_path);
    let transcript_abs_path = workspace_dir.join(&transcript_rel_path);
    if transcript_abs_path.exists() && transcript_abs_path.is_file() {
        let existing = tokio::fs::read_to_string(&transcript_abs_path)
            .await
            .unwrap_or_default();
        if !existing.trim().is_empty() {
            return Some(serde_json::json!({
                "status": "done",
                "path": transcript_rel_path,
                "jsonPath": transcript_json_path,
                "srtPath": transcript_srt_path,
            }));
        }
    }
    let cfg = state.config.lock().transcription.clone();
    if !cfg.enabled {
        return Some(serde_json::json!({
            "status": "disabled",
            "path": transcript_rel_path,
            "jsonPath": transcript_json_path,
            "srtPath": transcript_srt_path,
        }));
    }
    let media_capabilities = local_media_capabilities(&state.config.lock().clone());
    if !media_capabilities.transcribe_media {
        return Some(serde_json::json!({
            "status": "unsupported",
            "path": transcript_rel_path,
            "jsonPath": transcript_json_path,
            "srtPath": transcript_srt_path,
            "error": "Local transcription is unavailable on this device.",
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
        "jsonPath": transcript_json_path,
        "srtPath": transcript_srt_path,
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
    ensure_workspace_content_agent_helper_scripts(&workspace_dir).await?;

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

fn write_workspace_helper_script(
    workspace_dir: &StdPath,
    filename: &str,
    body: &str,
) -> Result<()> {
    let scripts_dir = workspace_dir.join("scripts");
    std::fs::create_dir_all(&scripts_dir)?;
    std::fs::write(scripts_dir.join(filename), body)?;
    Ok(())
}

fn ensure_workspace_content_agent_helper_scripts_sync(workspace_dir: &StdPath) -> Result<()> {
    write_workspace_helper_script(
        workspace_dir,
        "transcribe_audio_journal.py",
        include_str!("../../scripts/transcribe_audio_journal.py"),
    )?;
    write_workspace_helper_script(
        workspace_dir,
        "render_audio_insight_clip.py",
        include_str!("../../scripts/render_audio_insight_clip.py"),
    )?;
    Ok(())
}

async fn ensure_workspace_content_agent_helper_scripts(workspace_dir: &StdPath) -> Result<()> {
    let scripts_dir = workspace_dir.join("scripts");
    tokio::fs::create_dir_all(&scripts_dir).await?;
    tokio::fs::write(
        scripts_dir.join("transcribe_audio_journal.py"),
        include_str!("../../scripts/transcribe_audio_journal.py"),
    )
    .await?;
    tokio::fs::write(
        scripts_dir.join("render_audio_insight_clip.py"),
        include_str!("../../scripts/render_audio_insight_clip.py"),
    )
    .await?;
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

const INTEREST_MERGE_THRESHOLD: f32 = 0.75;
const INTEREST_SPAWN_THRESHOLD: f32 = 0.35;
const FEED_MATCH_THRESHOLD: f32 = 0.65;
const INTEREST_DECAY_RATE: f64 = 0.95;
const INTEREST_EMA_NEW_WEIGHT: f32 = 0.2;
const BLUESKY_TIMELINE_LIMIT_MAX: usize = 100;
const BLUESKY_DISCOVER_FEED_URI: &str =
    "at://did:plc:qh3lfd7q24h3fn3pejqr25ct/app.bsky.feed.generator/whats-hot";
const BLUESKY_PERSONALIZED_PAGE_LIMIT_PER_SOURCE: usize = 10;
const BLUESKY_PERSONALIZED_MATCH_LIMIT: usize = 10;
const BLUESKY_PERSONALIZED_PAGE_SIZE: usize = 30;
const FEED_WEB_SOURCE_KIND: &str = "hn-popular-blogs-2025";
const FEED_WEB_PREVIEW_CACHE_TTL_SECS: i64 = 24 * 60 * 60;
const FEED_WEB_INTEREST_QUERY_COUNT: usize = 3;
const FEED_WEB_DOMAIN_BATCH_SIZE: usize = 5;
const FEED_WEB_DOMAIN_BATCHES_PER_INTEREST: usize = 2;
const FEED_WEB_RESULT_LIMIT_PER_QUERY: usize = 5;
const CONTENT_SOURCE_REFRESH_TTL_SECS: i64 = 30 * 60;
const CONTENT_SOURCE_REFRESH_BATCH_SIZE: usize = 6;
const CONTENT_ITEM_EMBEDDING_BACKFILL_BATCH_SIZE: usize = 16;
const CONTENT_SOURCE_ITEM_LIMIT: usize = 12;
const CONTENT_RANK_CANDIDATE_LIMIT: usize = 160;
const CONTENT_TEXT_MAX_CHARS: usize = 2400;
const CONTENT_FETCH_TIMEOUT_SECS: u64 = 8;

#[derive(Debug, Clone, serde::Serialize)]
#[serde(rename_all = "camelCase")]
struct WebFeedPreview {
    url: String,
    title: String,
    description: String,
    image_url: Option<String>,
    domain: String,
    provider: String,
    provider_snippet: Option<String>,
    discovered_at: String,
}

#[derive(Debug, Clone, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
struct PersonalizedFeedRequest {
    service_url: Option<String>,
    access_jwt: Option<String>,
    limit: Option<usize>,
}

#[derive(Debug, Clone, serde::Serialize, Default)]
#[serde(rename_all = "camelCase")]
struct InterestProfileStats {
    interest_count: usize,
    source_count: usize,
    refreshed_sources: usize,
    merged_count: usize,
    spawned_count: usize,
    ignored_count: usize,
}

#[derive(Debug, Clone, serde::Serialize)]
#[serde(rename_all = "camelCase")]
struct PersonalizedBlueskyItem {
    source_type: String,
    feed_item: serde_json::Value,
    web_preview: Option<WebFeedPreview>,
    score: Option<f32>,
    matched_interest_label: Option<String>,
    matched_interest_score: Option<f32>,
    passed_threshold: bool,
}

#[derive(Debug, Clone)]
struct ActiveInterest {
    record: local_store::FeedInterestRecord,
    embedding: Vec<f32>,
}

#[derive(Debug, Clone)]
struct CandidateFeedPost {
    feed_item: serde_json::Value,
    text: String,
}

#[derive(Debug, Clone)]
struct CandidateWebResult {
    url: String,
    title: String,
    description: String,
    domain: String,
    provider: String,
    search_query: String,
}

#[derive(Debug, Clone)]
struct ParsedFeedEntry {
    external_id: String,
    canonical_url: String,
    title: String,
    author: String,
    summary: String,
    content_text: String,
    published_at: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum BlueskyCandidateSource {
    HomeTimeline,
    Discover,
}

impl BlueskyCandidateSource {
    fn label(self) -> &'static str {
        match self {
            Self::HomeTimeline => "home",
            Self::Discover => "discover",
        }
    }
}

#[derive(Debug, Clone, Default)]
struct RebuildInterestProfileResult {
    status: &'static str,
    stats: InterestProfileStats,
    interests: Vec<ActiveInterest>,
}

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
struct WorkspaceSyncFile {
    path: String,
    modified_at: i64,
    content_base64: String,
}

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
struct LocalStoreSyncBlob {
    modified_at: i64,
    content_base64: String,
}

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
struct WorkspaceSyncSnapshot {
    exported_at: i64,
    files: Vec<WorkspaceSyncFile>,
    local_store: Option<LocalStoreSyncBlob>,
}

fn content_hash_16(text: &str) -> String {
    use sha2::{Digest, Sha256};

    let hash = Sha256::digest(text.as_bytes());
    format!(
        "{:016x}",
        u64::from_be_bytes(
            hash[..8]
                .try_into()
                .expect("SHA-256 always produces at least 8 bytes")
        )
    )
}

fn derive_interest_label(default_title: &str, content: &str) -> String {
    let normalized_title = default_title.trim();
    if !normalized_title.is_empty() && !normalized_title.eq_ignore_ascii_case("untitled") {
        return truncate_with_ellipsis(normalized_title, 80);
    }

    for line in content.lines() {
        let trimmed = line.trim().trim_start_matches('#').trim();
        if !trimmed.is_empty() {
            return truncate_with_ellipsis(trimmed, 80);
        }
    }

    "Workspace interest".to_string()
}

fn non_empty_string(value: String) -> Option<String> {
    let trimmed = value.trim();
    if trimmed.is_empty() {
        None
    } else {
        Some(trimmed.to_string())
    }
}

fn ema_merge_vectors(current: &[f32], previous: &[f32]) -> Vec<f32> {
    current
        .iter()
        .zip(previous.iter())
        .map(|(new_value, previous_value)| {
            INTEREST_EMA_NEW_WEIGHT * *new_value + (1.0 - INTEREST_EMA_NEW_WEIGHT) * *previous_value
        })
        .collect()
}

fn sort_personalized_items(items: &mut [PersonalizedBlueskyItem]) {
    items.sort_by(|left, right| {
        let score_order = right
            .score
            .unwrap_or(0.0)
            .partial_cmp(&left.score.unwrap_or(0.0))
            .unwrap_or(std::cmp::Ordering::Equal);
        if score_order != std::cmp::Ordering::Equal {
            return score_order;
        }
        let right_ts = item_sort_timestamp(right);
        let left_ts = item_sort_timestamp(left);
        right_ts.cmp(left_ts)
    });
}

fn item_sort_timestamp(item: &PersonalizedBlueskyItem) -> &str {
    if let Some(discovered_at) = item
        .web_preview
        .as_ref()
        .map(|preview| preview.discovered_at.as_str())
        .filter(|value| !value.is_empty())
    {
        return discovered_at;
    }

    item.feed_item
        .get("post")
        .and_then(|post| post.get("indexedAt"))
        .and_then(serde_json::Value::as_str)
        .unwrap_or("")
}

fn extract_bluesky_post_text(feed_item: &serde_json::Value) -> String {
    let post = feed_item.get("post").unwrap_or(feed_item);
    let text = post
        .get("record")
        .and_then(|record| record.get("text"))
        .and_then(serde_json::Value::as_str)
        .unwrap_or("")
        .trim();
    if !text.is_empty() {
        return text.to_string();
    }

    post.get("embed")
        .and_then(|embed| embed.get("external"))
        .and_then(|external| external.get("title"))
        .and_then(serde_json::Value::as_str)
        .unwrap_or("")
        .trim()
        .to_string()
}

fn bluesky_candidate_sources() -> [BlueskyCandidateSource; 2] {
    [BlueskyCandidateSource::HomeTimeline, BlueskyCandidateSource::Discover]
}

fn build_bluesky_feed_endpoint(
    service_url: &str,
    source: BlueskyCandidateSource,
    cursor: Option<&str>,
    limit: usize,
) -> String {
    let trimmed_service = service_url.trim().trim_end_matches('/');
    let normalized_limit = limit.clamp(1, BLUESKY_TIMELINE_LIMIT_MAX);
    let mut url = match source {
        BlueskyCandidateSource::HomeTimeline => format!(
            "{trimmed_service}/xrpc/app.bsky.feed.getTimeline?limit={normalized_limit}"
        ),
        BlueskyCandidateSource::Discover => format!(
            "{trimmed_service}/xrpc/app.bsky.feed.getFeed?feed={}&limit={normalized_limit}",
            urlencoding::encode(BLUESKY_DISCOVER_FEED_URI)
        ),
    };

    if let Some(next_cursor) = cursor.map(str::trim).filter(|value| !value.is_empty()) {
        url.push_str("&cursor=");
        url.push_str(urlencoding::encode(next_cursor).as_ref());
    }

    url
}

fn bluesky_candidate_dedup_key(feed_item: &serde_json::Value) -> Option<String> {
    let post = feed_item.get("post").unwrap_or(feed_item);
    post.get("uri")
        .and_then(serde_json::Value::as_str)
        .map(ToOwned::to_owned)
        .or_else(|| {
            post.get("cid")
                .and_then(serde_json::Value::as_str)
                .map(ToOwned::to_owned)
        })
}

fn dedupe_candidate_posts(
    candidates: Vec<CandidateFeedPost>,
    seen: &mut BTreeSet<String>,
) -> Vec<CandidateFeedPost> {
    let mut out = Vec::new();
    for candidate in candidates {
        if let Some(key) = bluesky_candidate_dedup_key(&candidate.feed_item) {
            if !seen.insert(key) {
                continue;
            }
        }
        out.push(candidate);
    }
    out
}

fn build_raw_personalized_items(
    candidates: Vec<CandidateFeedPost>,
    limit: usize,
) -> Vec<PersonalizedBlueskyItem> {
    candidates
        .into_iter()
        .take(limit)
        .map(|candidate| PersonalizedBlueskyItem {
            source_type: "bluesky".to_string(),
            feed_item: candidate.feed_item,
            web_preview: None,
            score: None,
            matched_interest_label: None,
            matched_interest_score: None,
            passed_threshold: false,
        })
        .collect()
}

async fn fetch_bluesky_candidate_page(
    service_url: &str,
    access_jwt: &str,
    source: BlueskyCandidateSource,
    cursor: Option<&str>,
    limit: usize,
) -> Result<(Vec<CandidateFeedPost>, Option<String>)> {
    let url = build_bluesky_feed_endpoint(service_url, source, cursor, limit);
    let response = reqwest::Client::new()
        .get(url)
        .bearer_auth(access_jwt.trim())
        .send()
        .await
        .with_context(|| format!("Failed to fetch Bluesky {} feed", source.label()))?;

    if !response.status().is_success() {
        let status = response.status();
        let body = response.text().await.unwrap_or_default();
        anyhow::bail!(
            "Bluesky {} feed request failed ({status}): {body}",
            source.label()
        );
    }

    let json: serde_json::Value = response
        .json()
        .await
        .with_context(|| format!("Failed to decode Bluesky {} feed response", source.label()))?;
    let feed = json
        .get("feed")
        .and_then(serde_json::Value::as_array)
        .cloned()
        .unwrap_or_default();
    let next_cursor = json
        .get("cursor")
        .and_then(serde_json::Value::as_str)
        .map(ToOwned::to_owned);

    Ok((
        feed.into_iter()
            .map(|feed_item| CandidateFeedPost {
                text: extract_bluesky_post_text(&feed_item),
                feed_item,
            })
            .collect(),
        next_cursor,
    ))
}

async fn fetch_bluesky_fallback_candidates(
    service_url: &str,
    access_jwt: &str,
    limit: usize,
) -> Result<Vec<CandidateFeedPost>> {
    let mut seen = BTreeSet::new();
    let mut all_candidates = Vec::new();
    for source in bluesky_candidate_sources() {
        let (page, _) = fetch_bluesky_candidate_page(
            service_url,
            access_jwt,
            source,
            None,
            limit.min(BLUESKY_PERSONALIZED_PAGE_SIZE),
        )
        .await?;
        let unique_page = dedupe_candidate_posts(page, &mut seen);
        all_candidates.extend(unique_page);
        if all_candidates.len() >= limit {
            break;
        }
    }
    Ok(all_candidates)
}

fn normalize_feed_web_domain(raw: &str) -> String {
    raw.trim()
        .trim_start_matches("www.")
        .trim_end_matches('.')
        .to_ascii_lowercase()
}

fn resolve_feed_web_domain(url: &str) -> Option<String> {
    let parsed = reqwest::Url::parse(url).ok()?;
    let host = parsed.host_str()?;
    Some(normalize_feed_web_domain(host))
}

fn is_allowed_feed_web_domain(host: &str, allowed: &BTreeSet<String>) -> bool {
    let normalized = normalize_feed_web_domain(host);
    allowed.iter().any(|domain| {
        normalized == *domain || normalized.ends_with(&format!(".{domain}"))
    })
}

fn seed_default_feed_web_sources(workspace_dir: &StdPath) -> Result<()> {
    for source in DEFAULT_FEED_WEB_SOURCES {
        let _ = local_store::upsert_feed_web_source(
            workspace_dir,
            &local_store::FeedWebSourceUpsert {
                domain: source.domain.to_string(),
                title: source.title.to_string(),
                html_url: source.html_url.to_string(),
                xml_url: source.xml_url.to_string(),
                enabled: true,
                source_kind: FEED_WEB_SOURCE_KIND.to_string(),
            },
        )?;
    }
    Ok(())
}

fn build_feed_web_queries(
    interests: &[ActiveInterest],
    sources: &[local_store::FeedWebSourceRecord],
) -> Vec<String> {
    let top_interests: Vec<&ActiveInterest> = interests
        .iter()
        .filter(|interest| !interest.record.label.trim().is_empty())
        .collect();
    let mut top_interests = top_interests;
    top_interests.sort_by(|left, right| {
        right
            .record
            .health_score
            .partial_cmp(&left.record.health_score)
            .unwrap_or(std::cmp::Ordering::Equal)
    });
    top_interests.truncate(FEED_WEB_INTEREST_QUERY_COUNT);

    let domains: Vec<String> = sources
        .iter()
        .map(|source| normalize_feed_web_domain(&source.domain))
        .filter(|domain| !domain.is_empty())
        .collect();
    if domains.is_empty() {
        return Vec::new();
    }

    let batches: Vec<&[String]> = domains.chunks(FEED_WEB_DOMAIN_BATCH_SIZE).collect();
    let mut queries = Vec::new();
    for (interest_index, interest) in top_interests.iter().enumerate() {
        for batch_offset in 0..FEED_WEB_DOMAIN_BATCHES_PER_INTEREST {
            let batch_index = (interest_index * FEED_WEB_DOMAIN_BATCHES_PER_INTEREST + batch_offset)
                % batches.len();
            let batch = batches[batch_index];
            let site_filters = batch
                .iter()
                .map(|domain| format!("site:{domain}"))
                .collect::<Vec<_>>()
                .join(" OR ");
            queries.push(format!("{} ({site_filters})", interest.record.label));
        }
    }
    queries
}

fn build_feed_web_search_tool(config: &Config) -> Option<WebSearchTool> {
    if !config.web_search.enabled {
        return None;
    }

    Some(WebSearchTool::new(
        config.web_search.provider.clone(),
        config.web_search.brave_api_key.clone(),
        FEED_WEB_RESULT_LIMIT_PER_QUERY.min(config.web_search.max_results),
        config.web_search.timeout_secs,
    ))
}

async fn collect_web_search_candidates(
    config: &Config,
    interests: &[ActiveInterest],
) -> Result<Vec<CandidateWebResult>> {
    let Some(tool) = build_feed_web_search_tool(config) else {
        return Ok(Vec::new());
    };

    let workspace_dir = &config.workspace_dir;
    seed_default_feed_web_sources(workspace_dir)?;
    let sources = local_store::list_feed_web_sources(workspace_dir)?;
    if sources.is_empty() {
        return Ok(Vec::new());
    }

    let allowed_domains: BTreeSet<String> = sources
        .iter()
        .map(|source| normalize_feed_web_domain(&source.domain))
        .collect();
    let mut candidates = Vec::new();
    let mut seen_urls = BTreeSet::new();

    for query in build_feed_web_queries(interests, &sources) {
        let results = match tool.search_structured(&query).await {
            Ok(results) => results,
            Err(err) => {
                tracing::debug!(query, error = %err, "Feed web search query failed");
                continue;
            }
        };
        for result in results {
            let Some(domain) = resolve_feed_web_domain(&result.url) else {
                continue;
            };
            if !is_allowed_feed_web_domain(&domain, &allowed_domains) {
                continue;
            }
            if !seen_urls.insert(result.url.clone()) {
                continue;
            }
            candidates.push(CandidateWebResult {
                url: result.url,
                title: result.title,
                description: result.description,
                domain,
                provider: result.provider,
                search_query: query.clone(),
            });
        }
    }

    Ok(candidates)
}

fn web_preview_cache_is_fresh(updated_at: &str) -> bool {
    chrono::DateTime::parse_from_rfc3339(updated_at)
        .ok()
        .map(|value| Utc::now().signed_duration_since(value.with_timezone(&Utc)).num_seconds())
        .map(|age| age >= 0 && age <= FEED_WEB_PREVIEW_CACHE_TTL_SECS)
        .unwrap_or(false)
}

fn first_meta_capture(html: &str, patterns: &[&str]) -> Option<String> {
    for pattern in patterns {
        let regex = Regex::new(pattern).ok()?;
        if let Some(capture) = regex.captures(html) {
            if let Some(value) = capture.get(1) {
                let trimmed = html_unescape_basic(value.as_str().trim());
                if !trimmed.is_empty() {
                    return Some(trimmed);
                }
            }
        }
    }
    None
}

fn html_unescape_basic(raw: &str) -> String {
    raw.replace("&amp;", "&")
        .replace("&quot;", "\"")
        .replace("&#39;", "'")
        .replace("&lt;", "<")
        .replace("&gt;", ">")
        .replace("&nbsp;", " ")
}

fn xml_block_regex(tag: &str) -> Regex {
    Regex::new(&format!(r"(?is)<{tag}\b[^>]*>(.*?)</{tag}>", tag = regex::escape(tag)))
        .expect("valid XML block regex")
}

fn xml_tag_regex(tag: &str) -> Regex {
    Regex::new(&format!(r"(?is)<{tag}\b[^>]*>(.*?)</{tag}>", tag = regex::escape(tag)))
        .expect("valid XML tag regex")
}

fn xml_link_regex() -> &'static Regex {
    static REGEX: OnceLock<Regex> = OnceLock::new();
    REGEX.get_or_init(|| Regex::new(r#"(?is)<link\b([^>]*)>"#).expect("valid XML link regex"))
}

fn xml_href_attr_regex() -> &'static Regex {
    static REGEX: OnceLock<Regex> = OnceLock::new();
    REGEX.get_or_init(|| {
        Regex::new(r#"(?is)\bhref\s*=\s*["']([^"']+)["']"#).expect("valid href regex")
    })
}

fn xml_rel_attr_regex() -> &'static Regex {
    static REGEX: OnceLock<Regex> = OnceLock::new();
    REGEX.get_or_init(|| {
        Regex::new(r#"(?is)\brel\s*=\s*["']([^"']+)["']"#).expect("valid rel regex")
    })
}

fn html_tag_regex() -> &'static Regex {
    static REGEX: OnceLock<Regex> = OnceLock::new();
    REGEX.get_or_init(|| Regex::new(r"(?is)<[^>]+>").expect("valid HTML tag regex"))
}

fn html_break_regex() -> &'static Regex {
    static REGEX: OnceLock<Regex> = OnceLock::new();
    REGEX.get_or_init(|| Regex::new(r"(?is)<br\s*/?>").expect("valid break regex"))
}

fn html_paragraph_regex() -> &'static Regex {
    static REGEX: OnceLock<Regex> = OnceLock::new();
    REGEX.get_or_init(|| Regex::new(r"(?is)</p\s*>").expect("valid paragraph regex"))
}

fn collapse_whitespace(raw: &str) -> String {
    raw.split_whitespace().collect::<Vec<_>>().join(" ")
}

fn sanitize_feed_text(raw: &str) -> String {
    let without_breaks = html_break_regex().replace_all(raw, "\n");
    let with_paragraphs = html_paragraph_regex().replace_all(&without_breaks, "\n");
    let without_tags = html_tag_regex().replace_all(&with_paragraphs, " ");
    let without_cdata = without_tags
        .replace("<![CDATA[", "")
        .replace("]]>", "")
        .replace("&apos;", "'");
    collapse_whitespace(&html_unescape_basic(&without_cdata))
}

fn extract_xml_tag_text(fragment: &str, tags: &[&str]) -> Option<String> {
    for tag in tags {
        let regex = xml_tag_regex(tag);
        if let Some(capture) = regex.captures(fragment) {
            if let Some(value) = capture.get(1) {
                let sanitized = sanitize_feed_text(value.as_str());
                if !sanitized.is_empty() {
                    return Some(sanitized);
                }
            }
        }
    }
    None
}

fn extract_atom_link(fragment: &str, base_url: &str) -> Option<String> {
    let mut fallback: Option<String> = None;
    for capture in xml_link_regex().captures_iter(fragment) {
        let attrs = capture.get(1).map(|value| value.as_str()).unwrap_or("");
        let href = xml_href_attr_regex()
            .captures(attrs)
            .and_then(|value| value.get(1))
            .map(|value| value.as_str().trim().to_string());
        let Some(href) = href.filter(|value| !value.is_empty()) else {
            continue;
        };
        let rel = xml_rel_attr_regex()
            .captures(attrs)
            .and_then(|value| value.get(1))
            .map(|value| value.as_str().trim().to_ascii_lowercase());
        if rel.as_deref() != Some("self") {
            return Some(absolutize_feed_url(base_url, &href));
        }
        if fallback.is_none() {
            fallback = Some(absolutize_feed_url(base_url, &href));
        }
    }
    fallback
}

fn absolutize_feed_url(base_url: &str, raw_url: &str) -> String {
    let trimmed = raw_url.trim();
    if trimmed.is_empty() {
        return String::new();
    }
    if let Ok(parsed) = reqwest::Url::parse(trimmed) {
        return parsed.to_string();
    }
    reqwest::Url::parse(base_url)
        .and_then(|base| base.join(trimmed))
        .map(|url| url.to_string())
        .unwrap_or_else(|_| trimmed.to_string())
}

fn normalize_feed_timestamp(raw: &str) -> String {
    let trimmed = raw.trim();
    if trimmed.is_empty() {
        return String::new();
    }
    if let Ok(parsed) = chrono::DateTime::parse_from_rfc3339(trimmed) {
        return parsed.with_timezone(&Utc).to_rfc3339();
    }
    if let Ok(parsed) = chrono::DateTime::parse_from_rfc2822(trimmed) {
        return parsed.with_timezone(&Utc).to_rfc3339();
    }
    trimmed.to_string()
}

fn parse_rss_feed_entries(xml: &str, base_url: &str) -> Vec<ParsedFeedEntry> {
    let mut items = Vec::new();
    for capture in xml_block_regex("item").captures_iter(xml) {
        let fragment = capture.get(1).map(|value| value.as_str()).unwrap_or("");
        let title = extract_xml_tag_text(fragment, &["title"]).unwrap_or_default();
        let canonical_url = extract_xml_tag_text(fragment, &["link"])
            .map(|value| absolutize_feed_url(base_url, &value))
            .filter(|value| !value.is_empty())
            .or_else(|| {
                extract_xml_tag_text(fragment, &["guid"])
                    .map(|value| absolutize_feed_url(base_url, &value))
                    .filter(|value| !value.is_empty())
            })
            .unwrap_or_else(|| base_url.to_string());
        let summary = extract_xml_tag_text(fragment, &["description"]).unwrap_or_default();
        let content_text =
            extract_xml_tag_text(fragment, &["content:encoded", "content", "description"])
                .unwrap_or_else(|| summary.clone());
        let author = extract_xml_tag_text(fragment, &["author", "dc:creator"]).unwrap_or_default();
        let published_at = extract_xml_tag_text(fragment, &["pubDate", "published", "updated"])
            .map(|value| normalize_feed_timestamp(&value))
            .unwrap_or_default();
        let external_id = extract_xml_tag_text(fragment, &["guid"])
            .or_else(|| non_empty_string(canonical_url.clone()))
            .unwrap_or_default();
        if title.is_empty() && content_text.is_empty() {
            continue;
        }
        items.push(ParsedFeedEntry {
            external_id,
            canonical_url,
            title,
            author,
            summary,
            content_text,
            published_at,
        });
    }
    items
}

fn parse_atom_feed_entries(xml: &str, base_url: &str) -> Vec<ParsedFeedEntry> {
    let mut items = Vec::new();
    for capture in xml_block_regex("entry").captures_iter(xml) {
        let fragment = capture.get(1).map(|value| value.as_str()).unwrap_or("");
        let title = extract_xml_tag_text(fragment, &["title"]).unwrap_or_default();
        let canonical_url = extract_atom_link(fragment, base_url).unwrap_or_else(|| base_url.to_string());
        let summary = extract_xml_tag_text(fragment, &["summary"]).unwrap_or_default();
        let content_text = extract_xml_tag_text(fragment, &["content", "summary"])
            .unwrap_or_else(|| summary.clone());
        let author = xml_block_regex("author")
            .captures(fragment)
            .and_then(|value| value.get(1))
            .and_then(|value| extract_xml_tag_text(value.as_str(), &["name"]))
            .or_else(|| extract_xml_tag_text(fragment, &["author", "name"]))
            .unwrap_or_default();
        let published_at = extract_xml_tag_text(fragment, &["published", "updated"])
            .map(|value| normalize_feed_timestamp(&value))
            .unwrap_or_default();
        let external_id = extract_xml_tag_text(fragment, &["id"])
            .or_else(|| non_empty_string(canonical_url.clone()))
            .unwrap_or_default();
        if title.is_empty() && content_text.is_empty() {
            continue;
        }
        items.push(ParsedFeedEntry {
            external_id,
            canonical_url,
            title,
            author,
            summary,
            content_text,
            published_at,
        });
    }
    items
}

fn parse_feed_entries(xml: &str, base_url: &str) -> Vec<ParsedFeedEntry> {
    let trimmed = xml.trim();
    if trimmed.is_empty() {
        return Vec::new();
    }
    let mut items = if trimmed.contains("<feed") {
        parse_atom_feed_entries(trimmed, base_url)
    } else {
        parse_rss_feed_entries(trimmed, base_url)
    };
    items.retain(|item| !item.canonical_url.trim().is_empty());
    items
}

fn content_source_is_stale(last_fetch_at: &str) -> bool {
    chrono::DateTime::parse_from_rfc3339(last_fetch_at.trim())
        .ok()
        .map(|value| Utc::now().signed_duration_since(value.with_timezone(&Utc)).num_seconds())
        .map(|age| age < 0 || age > CONTENT_SOURCE_REFRESH_TTL_SECS)
        .unwrap_or(true)
}

fn content_item_embedding_text(entry: &ParsedFeedEntry) -> String {
    let combined = format!(
        "{}\n{}\n{}",
        entry.title.trim(),
        entry.summary.trim(),
        entry.content_text.trim()
    );
    truncate_with_ellipsis(combined.trim(), CONTENT_TEXT_MAX_CHARS)
}

fn build_content_item_id(source_key: &str, canonical_url: &str, external_id: &str) -> String {
    format!(
        "content_{}",
        content_hash_16(&format!("{source_key}\n{canonical_url}\n{external_id}"))
    )
}

fn sync_content_sources_from_feed_web_sources(workspace_dir: &StdPath) -> Result<()> {
    seed_default_feed_web_sources(workspace_dir)?;
    for source in local_store::list_feed_web_sources(workspace_dir)? {
        let source_key = source.xml_url.trim();
        if source_key.is_empty() {
            continue;
        }
        let _ = local_store::upsert_content_source(
            workspace_dir,
            &local_store::ContentSourceUpsert {
                source_key: source_key.to_string(),
                domain: source.domain.clone(),
                title: source.title.clone(),
                html_url: source.html_url.clone(),
                xml_url: source.xml_url.clone(),
                source_kind: source.source_kind.clone(),
                enabled: source.enabled,
            },
        )?;
    }
    Ok(())
}

struct RemoteFeedFetchResult {
    entries: Vec<ParsedFeedEntry>,
    etag: Option<String>,
    last_modified: Option<String>,
    not_modified: bool,
}

async fn fetch_remote_feed(source: &local_store::ContentSourceRecord) -> Result<RemoteFeedFetchResult> {
    let client = reqwest::Client::builder()
        .timeout(Duration::from_secs(CONTENT_FETCH_TIMEOUT_SECS))
        .build()?;
    let mut request = client.get(source.xml_url.trim());
    if !source.etag.trim().is_empty() {
        request = request.header(reqwest::header::IF_NONE_MATCH, source.etag.trim());
    }
    if !source.last_modified.trim().is_empty() {
        request = request.header(
            reqwest::header::IF_MODIFIED_SINCE,
            source.last_modified.trim(),
        );
    }

    let response = request
        .send()
        .await
        .with_context(|| format!("Failed to fetch content source {}", source.xml_url))?;
    let etag = response
        .headers()
        .get(reqwest::header::ETAG)
        .and_then(|value| value.to_str().ok())
        .map(ToOwned::to_owned);
    let last_modified = response
        .headers()
        .get(reqwest::header::LAST_MODIFIED)
        .and_then(|value| value.to_str().ok())
        .map(ToOwned::to_owned);

    if response.status() == reqwest::StatusCode::NOT_MODIFIED {
        return Ok(RemoteFeedFetchResult {
            entries: Vec::new(),
            etag,
            last_modified,
            not_modified: true,
        });
    }

    if !response.status().is_success() {
        let status = response.status();
        let body = response.text().await.unwrap_or_default();
        anyhow::bail!("Feed fetch failed for {} ({status}): {body}", source.xml_url);
    }

    let body = response.bytes().await?;
    let xml = String::from_utf8_lossy(&body);
    Ok(RemoteFeedFetchResult {
        entries: parse_feed_entries(&xml, &source.html_url),
        etag,
        last_modified,
        not_modified: false,
    })
}

async fn refresh_cached_content_sources(
    workspace_dir: &StdPath,
    embedder: Option<Arc<dyn memory::embeddings::EmbeddingProvider>>,
) -> Result<()> {
    sync_content_sources_from_feed_web_sources(workspace_dir)?;
    let sources = local_store::list_content_sources(workspace_dir, 128)?;
    let stale_sources: Vec<local_store::ContentSourceRecord> = sources
        .into_iter()
        .filter(|source| content_source_is_stale(&source.last_fetch_at))
        .take(CONTENT_SOURCE_REFRESH_BATCH_SIZE)
        .collect();

    for source in stale_sources {
        let fetched_at = Utc::now().to_rfc3339();
        match fetch_remote_feed(&source).await {
            Ok(result) => {
                if !result.not_modified {
                    for entry in result.entries.into_iter().take(CONTENT_SOURCE_ITEM_LIMIT) {
                        let embedding_text = content_item_embedding_text(&entry);
                        if embedding_text.trim().is_empty() {
                            continue;
                        }
                        let embedding = if let Some(embedder) = embedder.as_ref() {
                            match embedder.embed_one(&embedding_text).await {
                                Ok(value) => vec_to_bytes(&value),
                                Err(err) => {
                                    tracing::debug!(
                                        source = %source.xml_url,
                                        url = %entry.canonical_url,
                                        error = %err,
                                        "Failed to embed feed content item"
                                    );
                                    Vec::new()
                                }
                            }
                        } else {
                            Vec::new()
                        };
                        let canonical_url = if entry.canonical_url.trim().is_empty() {
                            source.html_url.clone()
                        } else {
                            entry.canonical_url.clone()
                        };
                        let id = build_content_item_id(
                            &source.source_key,
                            &canonical_url,
                            &entry.external_id,
                        );
                        let content_hash = content_hash_16(&embedding_text);
                        let _ = local_store::upsert_content_item(
                            workspace_dir,
                            &local_store::ContentItemUpsert {
                                id,
                                source_key: source.source_key.clone(),
                                source_title: source.title.clone(),
                                source_kind: source.source_kind.clone(),
                                domain: source.domain.clone(),
                                canonical_url,
                                external_id: entry.external_id.clone(),
                                title: entry.title.clone(),
                                author: entry.author.clone(),
                                summary: truncate_with_ellipsis(entry.summary.trim(), 280),
                                content_text: embedding_text,
                                content_hash,
                                embedding,
                                published_at: entry.published_at.clone(),
                                discovered_at: fetched_at.clone(),
                            },
                        )?;
                    }
                }
                local_store::update_content_source_fetch(
                    workspace_dir,
                    &source.source_key,
                    &fetched_at,
                    result.etag.as_deref(),
                    result.last_modified.as_deref(),
                    None,
                    true,
                )?;
            }
            Err(err) => {
                tracing::debug!(
                    source = %source.xml_url,
                    error = %err,
                    "Failed to refresh content source"
                );
                local_store::update_content_source_fetch(
                    workspace_dir,
                    &source.source_key,
                    &fetched_at,
                    None,
                    None,
                    Some(&err.to_string()),
                    false,
                )?;
            }
        }
    }

    Ok(())
}

async fn backfill_cached_content_item_embeddings(
    workspace_dir: &StdPath,
    embedder: Arc<dyn memory::embeddings::EmbeddingProvider>,
) -> Result<usize> {
    let missing_items = local_store::list_content_items_missing_embeddings(
        workspace_dir,
        CONTENT_ITEM_EMBEDDING_BACKFILL_BATCH_SIZE,
    )?;
    if missing_items.is_empty() {
        return Ok(0);
    }

    let mut updated_count = 0usize;
    for item in missing_items {
        let content = item.content_text.trim();
        if content.is_empty() {
            continue;
        }
        match embedder.embed_one(content).await {
            Ok(embedding) if !embedding.is_empty() => {
                local_store::update_content_item_embedding(
                    workspace_dir,
                    &item.id,
                    &vec_to_bytes(&embedding),
                )?;
                updated_count += 1;
            }
            Ok(_) => {
                tracing::debug!(
                    item_id = %item.id,
                    url = %item.canonical_url,
                    "Feed embedder returned an empty vector for cached content item"
                );
            }
            Err(err) => {
                tracing::debug!(
                    item_id = %item.id,
                    url = %item.canonical_url,
                    error = %err,
                    "Failed to backfill cached content item embedding"
                );
            }
        }
    }

    Ok(updated_count)
}

fn cached_content_backfill_inflight() -> &'static Mutex<HashSet<PathBuf>> {
    static INFLIGHT: OnceLock<Mutex<HashSet<PathBuf>>> = OnceLock::new();
    INFLIGHT.get_or_init(|| Mutex::new(HashSet::new()))
}

fn spawn_cached_content_item_embedding_backfill(
    workspace_dir: PathBuf,
    embedder: Arc<dyn memory::embeddings::EmbeddingProvider>,
) {
    {
        let mut inflight = cached_content_backfill_inflight().lock();
        if !inflight.insert(workspace_dir.clone()) {
            return;
        }
    }

    tokio::spawn(async move {
        let result = backfill_cached_content_item_embeddings(&workspace_dir, embedder).await;
        if let Err(err) = result {
            tracing::warn!("Failed to backfill cached content item embeddings: {err}");
        }
        cached_content_backfill_inflight()
            .lock()
            .remove(&workspace_dir);
    });
}

fn content_preview_timestamp(item: &local_store::ContentItemRecord) -> String {
    non_empty_string(item.published_at.clone())
        .or_else(|| non_empty_string(item.discovered_at.clone()))
        .or_else(|| non_empty_string(item.updated_at.clone()))
        .unwrap_or_default()
}

fn build_content_preview(item: &local_store::ContentItemRecord) -> WebFeedPreview {
    let description = if !item.summary.trim().is_empty() {
        item.summary.trim().to_string()
    } else {
        truncate_with_ellipsis(item.content_text.trim(), 220)
    };
    WebFeedPreview {
        url: item.canonical_url.clone(),
        title: if item.title.trim().is_empty() {
            item.canonical_url.clone()
        } else {
            item.title.clone()
        },
        description,
        image_url: None,
        domain: item.domain.clone(),
        provider: "RSS/Atom".to_string(),
        provider_snippet: non_empty_string(item.source_title.clone()),
        discovered_at: content_preview_timestamp(item),
    }
}

fn build_recent_content_items(
    workspace_dir: &StdPath,
    limit: usize,
) -> Result<Vec<PersonalizedBlueskyItem>> {
    let items = local_store::list_recent_content_items(workspace_dir, limit)?;
    Ok(items
        .into_iter()
        .filter(|item| !item.canonical_url.trim().is_empty())
        .map(|item| {
            let preview = build_content_preview(&item);
            PersonalizedBlueskyItem {
                source_type: "web".to_string(),
                feed_item: serde_json::json!({
                    "url": item.canonical_url,
                    "title": item.title,
                    "description": item.summary,
                    "domain": item.domain,
                    "author": item.author,
                    "sourceTitle": item.source_title,
                    "publishedAt": item.published_at,
                }),
                web_preview: Some(preview),
                score: None,
                matched_interest_label: None,
                matched_interest_score: None,
                passed_threshold: false,
            }
        })
        .collect())
}

fn rank_cached_content_items(
    workspace_dir: &StdPath,
    interests: &[ActiveInterest],
    limit: usize,
) -> Result<Vec<PersonalizedBlueskyItem>> {
    let mut ranked = Vec::new();
    for item in local_store::list_recent_content_items(workspace_dir, CONTENT_RANK_CANDIDATE_LIMIT)? {
        let embedding = bytes_to_vec(&item.embedding);
        if embedding.is_empty() {
            continue;
        }
        let (best_weighted, best_similarity, best_label) =
            best_interest_match(&embedding, interests);
        if best_weighted < FEED_MATCH_THRESHOLD {
            continue;
        }
        let preview = build_content_preview(&item);
        ranked.push(PersonalizedBlueskyItem {
            source_type: "web".to_string(),
            feed_item: serde_json::json!({
                "url": item.canonical_url,
                "title": item.title,
                "description": item.summary,
                "domain": item.domain,
                "author": item.author,
                "sourceTitle": item.source_title,
                "publishedAt": item.published_at,
            }),
            web_preview: Some(preview),
            score: Some(best_weighted),
            matched_interest_label: best_label,
            matched_interest_score: if best_similarity > 0.0 {
                Some(best_similarity)
            } else {
                None
            },
            passed_threshold: true,
        });
    }
    sort_personalized_items(&mut ranked);
    ranked.truncate(limit);
    Ok(ranked)
}

fn append_feed_items_up_to_limit(
    target: &mut Vec<PersonalizedBlueskyItem>,
    mut extra: Vec<PersonalizedBlueskyItem>,
    limit: usize,
) {
    if target.len() >= limit {
        return;
    }
    let remaining = limit - target.len();
    extra.truncate(remaining);
    target.extend(extra);
}

async fn fetch_web_preview_html(url: &str) -> Result<String> {
    let response = reqwest::Client::builder()
        .timeout(Duration::from_secs(12))
        .user_agent("SlowClawFeedPreview/1.0")
        .build()?
        .get(url)
        .send()
        .await
        .with_context(|| format!("Failed to fetch preview URL {url}"))?;

    if !response.status().is_success() {
        anyhow::bail!("Preview fetch failed for {url} ({})", response.status());
    }

    response
        .text()
        .await
        .with_context(|| format!("Failed to read preview body {url}"))
}

fn preview_from_html(candidate: &CandidateWebResult, html: &str) -> WebFeedPreview {
    let title = first_meta_capture(
        html,
        &[
            r#"(?is)<meta[^>]+property=["']og:title["'][^>]+content=["']([^"']+)["']"#,
            r#"(?is)<meta[^>]+name=["']twitter:title["'][^>]+content=["']([^"']+)["']"#,
            r#"(?is)<title[^>]*>\s*([^<]+?)\s*</title>"#,
        ],
    )
    .unwrap_or_else(|| candidate.title.clone());
    let description = first_meta_capture(
        html,
        &[
            r#"(?is)<meta[^>]+property=["']og:description["'][^>]+content=["']([^"']+)["']"#,
            r#"(?is)<meta[^>]+name=["']description["'][^>]+content=["']([^"']+)["']"#,
            r#"(?is)<meta[^>]+name=["']twitter:description["'][^>]+content=["']([^"']+)["']"#,
        ],
    )
    .unwrap_or_else(|| candidate.description.clone());
    let image_url = first_meta_capture(
        html,
        &[
            r#"(?is)<meta[^>]+property=["']og:image["'][^>]+content=["']([^"']+)["']"#,
            r#"(?is)<meta[^>]+name=["']twitter:image["'][^>]+content=["']([^"']+)["']"#,
        ],
    );

    WebFeedPreview {
        url: candidate.url.clone(),
        title,
        description,
        image_url,
        domain: candidate.domain.clone(),
        provider: candidate.provider.clone(),
        provider_snippet: (!candidate.description.trim().is_empty())
            .then(|| candidate.description.clone()),
        discovered_at: Utc::now().to_rfc3339(),
    }
}

async fn resolve_web_preview(
    workspace_dir: &StdPath,
    candidate: &CandidateWebResult,
) -> WebFeedPreview {
    if let Ok(Some(cached)) = local_store::get_feed_web_cache(workspace_dir, &candidate.url) {
        if web_preview_cache_is_fresh(&cached.updated_at) {
            return WebFeedPreview {
                url: cached.url,
                title: if cached.title.trim().is_empty() {
                    candidate.title.clone()
                } else {
                    cached.title
                },
                description: if cached.description.trim().is_empty() {
                    candidate.description.clone()
                } else {
                    cached.description
                },
                image_url: non_empty_string(cached.image_url),
                domain: if cached.domain.trim().is_empty() {
                    candidate.domain.clone()
                } else {
                    cached.domain
                },
                provider: if cached.provider.trim().is_empty() {
                    candidate.provider.clone()
                } else {
                    cached.provider
                },
                provider_snippet: non_empty_string(cached.snippet),
                discovered_at: if cached.fetched_at.trim().is_empty() {
                    Utc::now().to_rfc3339()
                } else {
                    cached.fetched_at
                },
            };
        }
    }

    let preview = match fetch_web_preview_html(&candidate.url).await {
        Ok(html) => preview_from_html(candidate, &html),
        Err(err) => {
            tracing::debug!(url = %candidate.url, error = %err, "Feed preview fetch failed");
            WebFeedPreview {
                url: candidate.url.clone(),
                title: candidate.title.clone(),
                description: candidate.description.clone(),
                image_url: None,
                domain: candidate.domain.clone(),
                provider: candidate.provider.clone(),
                provider_snippet: (!candidate.description.trim().is_empty())
                    .then(|| candidate.description.clone()),
                discovered_at: Utc::now().to_rfc3339(),
            }
        }
    };

    let _ = local_store::upsert_feed_web_cache(
        workspace_dir,
        &local_store::FeedWebCacheUpsert {
            url: preview.url.clone(),
            domain: preview.domain.clone(),
            title: preview.title.clone(),
            description: preview.description.clone(),
            image_url: preview.image_url.clone().unwrap_or_default(),
            provider: preview.provider.clone(),
            snippet: preview.provider_snippet.clone().unwrap_or_default(),
            search_query: candidate.search_query.clone(),
            fetched_at: preview.discovered_at.clone(),
        },
    );

    preview
}

async fn select_feed_embedder(
    config: &Config,
) -> Result<Option<Arc<dyn memory::embeddings::EmbeddingProvider>>> {
    let configured = memory::create_embedder_from_config(config);
    if configured.dimensions() == 0 {
        return Ok(None);
    }

    match configured.embed_one("feed profile probe").await {
        Ok(embedding) if !embedding.is_empty() => Ok(Some(configured)),
        Ok(_) => {
            tracing::debug!(
                provider = config.memory.embedding_provider.trim(),
                model = config.memory.embedding_model.trim(),
                dimensions = configured.dimensions(),
                "Configured feed embedder returned an empty probe vector"
            );
            Ok(None)
        }
        Err(err) => {
            tracing::debug!(
                provider = config.memory.embedding_provider.trim(),
                model = config.memory.embedding_model.trim(),
                dimensions = configured.dimensions(),
                error = %err,
                "Configured feed embedder probe failed"
            );
            Ok(None)
        }
    }
}

async fn resolve_feed_embedder(
    config: &Config,
) -> Result<(
    Option<Arc<dyn memory::embeddings::EmbeddingProvider>>,
    Option<String>,
)> {
    if config.memory.embedding_provider.trim().eq_ignore_ascii_case("none") {
        return Ok((
            None,
            Some(
                "Personalized feed embeddings are disabled in [memory]. Showing recent cached content and raw Bluesky items when available.".to_string(),
            ),
        ));
    }

    if let Some(embedder) = select_feed_embedder(config).await? {
        return Ok((Some(embedder), None));
    }

    Ok((
        None,
        Some(
            "Configured embedding provider is unavailable. Showing recent cached content and raw Bluesky items when available.".to_string(),
        ),
    ))
}

async fn rebuild_interest_profile(
    config: &Config,
    embedder: Arc<dyn memory::embeddings::EmbeddingProvider>,
) -> Result<RebuildInterestProfileResult> {
    if embedder.dimensions() == 0 {
        return Ok(RebuildInterestProfileResult {
            status: "embeddingUnavailable",
            ..RebuildInterestProfileResult::default()
        });
    }

    let workspace_dir = &config.workspace_dir;
    let _ = local_store::decay_feed_interests(workspace_dir, INTEREST_DECAY_RATE)?;
    let mut active_interests: Vec<ActiveInterest> = local_store::list_feed_interests(workspace_dir)?
        .into_iter()
        .map(|record| ActiveInterest {
            embedding: bytes_to_vec(&record.embedding),
            record,
        })
        .filter(|interest| !interest.embedding.is_empty())
        .collect();

    let items = list_workspace_library_items(workspace_dir, "feed", 2_000)?;
    let text_items: Vec<serde_json::Value> = items
        .into_iter()
        .filter(|item| item.get("kind").and_then(serde_json::Value::as_str) == Some("text"))
        .collect();

    let mut stats = InterestProfileStats {
        source_count: text_items.len(),
        ..InterestProfileStats::default()
    };

    for item in text_items {
        let Some(path) = item.get("path").and_then(serde_json::Value::as_str) else {
            continue;
        };
        let abs_path = workspace_dir.join(path);
        let content = match tokio::fs::read_to_string(&abs_path).await {
            Ok(content) => content,
            Err(_) => continue,
        };
        let trimmed = content.trim();
        if trimmed.is_empty() {
            continue;
        }
        let content_hash = content_hash_16(trimmed);
        if let Some(previous) = local_store::get_feed_interest_source(workspace_dir, path)? {
            if previous.content_hash == content_hash {
                continue;
            }
        }

        let label = derive_interest_label(
            item.get("title")
                .and_then(serde_json::Value::as_str)
                .unwrap_or("Workspace interest"),
            trimmed,
        );
        let embedding = embedder
            .embed_one(trimmed)
            .await
            .with_context(|| format!("Failed to embed feed source {path}"))?;

        let mut best_match: Option<(usize, f32)> = None;
        for (index, interest) in active_interests.iter().enumerate() {
            let similarity = cosine_similarity(&embedding, &interest.embedding);
            if best_match
                .as_ref()
                .map(|(_, current_best)| similarity > *current_best)
                .unwrap_or(true)
            {
                best_match = Some((index, similarity));
            }
        }

        let now = Utc::now().to_rfc3339();
        let mapped_interest_id = if let Some((index, similarity)) = best_match {
            if similarity >= INTEREST_MERGE_THRESHOLD {
                let current = active_interests[index].clone();
                let merged_embedding = ema_merge_vectors(&embedding, &current.embedding);
                let next_label = if current.record.label.trim().is_empty() {
                    label.clone()
                } else {
                    current.record.label.clone()
                };
                let updated = local_store::upsert_feed_interest(
                    workspace_dir,
                    &local_store::FeedInterestUpsert {
                        id: Some(current.record.id.clone()),
                        label: next_label,
                        source_path: path.to_string(),
                        embedding: vec_to_bytes(&merged_embedding),
                        health_score: 1.0,
                        last_seen_at: now.clone(),
                    },
                )?;
                active_interests[index] = ActiveInterest {
                    embedding: merged_embedding,
                    record: updated.clone(),
                };
                stats.refreshed_sources += 1;
                stats.merged_count += 1;
                Some(updated.id)
            } else if similarity >= INTEREST_SPAWN_THRESHOLD {
                let created = local_store::upsert_feed_interest(
                    workspace_dir,
                    &local_store::FeedInterestUpsert {
                        id: None,
                        label: label.clone(),
                        source_path: path.to_string(),
                        embedding: vec_to_bytes(&embedding),
                        health_score: 1.0,
                        last_seen_at: now.clone(),
                    },
                )?;
                active_interests.push(ActiveInterest {
                    embedding,
                    record: created.clone(),
                });
                stats.refreshed_sources += 1;
                stats.spawned_count += 1;
                Some(created.id)
            } else {
                stats.ignored_count += 1;
                None
            }
        } else {
            let created = local_store::upsert_feed_interest(
                workspace_dir,
                &local_store::FeedInterestUpsert {
                    id: None,
                    label: label.clone(),
                    source_path: path.to_string(),
                    embedding: vec_to_bytes(&embedding),
                    health_score: 1.0,
                    last_seen_at: now.clone(),
                },
            )?;
            active_interests.push(ActiveInterest {
                embedding,
                record: created.clone(),
            });
            stats.refreshed_sources += 1;
            stats.spawned_count += 1;
            Some(created.id)
        };

        local_store::upsert_feed_interest_source(
            workspace_dir,
            &local_store::FeedInterestSourceRecord {
                source_path: path.to_string(),
                content_hash,
                interest_id: mapped_interest_id,
                title: label,
                updated_at: now,
            },
        )?;
    }

    stats.interest_count = active_interests.len();
    Ok(RebuildInterestProfileResult {
        status: if active_interests.is_empty() {
            "noInterests"
        } else {
            "ready"
        },
        stats,
        interests: active_interests,
    })
}

fn best_interest_match(
    embedding: &[f32],
    interests: &[ActiveInterest],
) -> (f32, f32, Option<String>) {
    let mut best_weighted = 0.0_f32;
    let mut best_similarity = 0.0_f32;
    let mut best_label: Option<String> = None;
    for interest in interests {
        let similarity = cosine_similarity(embedding, &interest.embedding);
        let weighted = similarity * interest.record.health_score as f32;
        if weighted > best_weighted {
            best_weighted = weighted;
            best_similarity = similarity;
            best_label = Some(interest.record.label.clone());
        }
    }
    (best_weighted, best_similarity, best_label)
}

async fn rank_bluesky_candidates(
    embedder: Arc<dyn memory::embeddings::EmbeddingProvider>,
    interests: &[ActiveInterest],
    candidates: Vec<CandidateFeedPost>,
) -> Result<Vec<PersonalizedBlueskyItem>> {
    let mut ranked = Vec::new();
    for candidate in candidates {
        let trimmed = candidate.text.trim();
        if trimmed.is_empty() {
            ranked.push(PersonalizedBlueskyItem {
                source_type: "bluesky".to_string(),
                feed_item: candidate.feed_item,
                web_preview: None,
                score: None,
                matched_interest_label: None,
                matched_interest_score: None,
                passed_threshold: false,
            });
            continue;
        }

        let embedding = embedder
            .embed_one(trimmed)
            .await
            .context("Failed to embed Bluesky candidate post")?;

        let (best_weighted, best_similarity, best_label) =
            best_interest_match(&embedding, interests);

        ranked.push(PersonalizedBlueskyItem {
            source_type: "bluesky".to_string(),
            feed_item: candidate.feed_item,
            web_preview: None,
            score: Some(best_weighted),
            matched_interest_label: best_label,
            matched_interest_score: if best_similarity > 0.0 {
                Some(best_similarity)
            } else {
                None
            },
            passed_threshold: best_weighted >= FEED_MATCH_THRESHOLD,
        });
    }

    let mut filtered: Vec<PersonalizedBlueskyItem> =
        ranked.into_iter().filter(|item| item.passed_threshold).collect();
    sort_personalized_items(&mut filtered);
    Ok(filtered)
}

async fn rank_web_candidates(
    workspace_dir: &StdPath,
    embedder: Arc<dyn memory::embeddings::EmbeddingProvider>,
    interests: &[ActiveInterest],
    candidates: Vec<CandidateWebResult>,
    limit: usize,
) -> Result<Vec<PersonalizedBlueskyItem>> {
    let mut ranked = Vec::new();
    for candidate in candidates {
        let combined = format!("{}\n{}", candidate.title.trim(), candidate.description.trim());
        let trimmed = combined.trim();
        if trimmed.is_empty() {
            continue;
        }

        let embedding = embedder
            .embed_one(trimmed)
            .await
            .with_context(|| format!("Failed to embed web candidate {}", candidate.url))?;
        let (best_weighted, best_similarity, best_label) =
            best_interest_match(&embedding, interests);
        if best_weighted < FEED_MATCH_THRESHOLD {
            continue;
        }

        let preview = resolve_web_preview(workspace_dir, &candidate).await;
        ranked.push(PersonalizedBlueskyItem {
            source_type: "web".to_string(),
            feed_item: serde_json::json!({
                "url": candidate.url,
                "title": candidate.title,
                "description": candidate.description,
                "domain": candidate.domain,
            }),
            web_preview: Some(preview),
            score: Some(best_weighted),
            matched_interest_label: best_label,
            matched_interest_score: if best_similarity > 0.0 {
                Some(best_similarity)
            } else {
                None
            },
            passed_threshold: true,
        });
    }

    sort_personalized_items(&mut ranked);
    ranked.truncate(limit);
    Ok(ranked)
}

async fn collect_ranked_bluesky_matches(
    service_url: &str,
    access_jwt: &str,
    embedder: Arc<dyn memory::embeddings::EmbeddingProvider>,
    interests: &[ActiveInterest],
    limit: usize,
) -> Result<(Vec<PersonalizedBlueskyItem>, Vec<CandidateFeedPost>)> {
    let mut matched = Vec::new();
    let mut raw_candidates = Vec::new();
    let mut seen = BTreeSet::new();
    let target_matches = limit.min(BLUESKY_PERSONALIZED_MATCH_LIMIT);

    for source in bluesky_candidate_sources() {
        let mut cursor: Option<String> = None;
        for _ in 0..BLUESKY_PERSONALIZED_PAGE_LIMIT_PER_SOURCE {
            let (page, next_cursor) = fetch_bluesky_candidate_page(
                service_url,
                access_jwt,
                source,
                cursor.as_deref(),
                BLUESKY_PERSONALIZED_PAGE_SIZE,
            )
            .await?;
            if page.is_empty() {
                break;
            }

            let unique_page = dedupe_candidate_posts(page, &mut seen);
            if !unique_page.is_empty() {
                raw_candidates.extend(unique_page.clone());
                let mut ranked_page =
                    rank_bluesky_candidates(embedder.clone(), interests, unique_page).await?;
                matched.append(&mut ranked_page);
                if matched.len() >= target_matches {
                    sort_personalized_items(&mut matched);
                    matched.truncate(target_matches);
                    return Ok((matched, raw_candidates));
                }
            }

            let Some(next_cursor) = next_cursor.filter(|value| !value.trim().is_empty()) else {
                break;
            };
            cursor = Some(next_cursor);
        }
    }

    sort_personalized_items(&mut matched);
    matched.truncate(target_matches);
    Ok((matched, raw_candidates))
}

fn modified_unix_secs(path: &StdPath) -> i64 {
    path.metadata()
        .ok()
        .and_then(|meta| meta.modified().ok())
        .and_then(|time| time.duration_since(UNIX_EPOCH).ok())
        .map(|duration| i64::try_from(duration.as_secs()).unwrap_or(0))
        .unwrap_or(0)
}

fn sync_file_allowed(path: &str) -> bool {
    let normalized = path.trim().trim_start_matches('/').replace('\\', "/");
    if normalized.is_empty() || normalized.contains("..") {
        return false;
    }
    if normalized == "feed_workflow_settings.json" {
        return true;
    }
    SYNC_ALLOWED_ROOTS
        .iter()
        .any(|root| normalized == *root || normalized.starts_with(&format!("{root}/")))
}

fn collect_sync_files_recursive(
    workspace_dir: &StdPath,
    dir: &StdPath,
    out: &mut Vec<WorkspaceSyncFile>,
) -> Result<()> {
    let entries = match std::fs::read_dir(dir) {
        Ok(entries) => entries,
        Err(_) => return Ok(()),
    };

    for entry in entries {
        let entry = match entry {
            Ok(entry) => entry,
            Err(_) => continue,
        };
        let path = entry.path();
        let metadata = match entry.metadata() {
            Ok(metadata) => metadata,
            Err(_) => continue,
        };
        if metadata.is_dir() {
            collect_sync_files_recursive(workspace_dir, &path, out)?;
            continue;
        }
        if !metadata.is_file() {
            continue;
        }
        let rel = match path.strip_prefix(workspace_dir) {
            Ok(rel) => rel.to_string_lossy().replace('\\', "/"),
            Err(_) => continue,
        };
        if !sync_file_allowed(&rel) {
            continue;
        }
        let bytes = match std::fs::read(&path) {
            Ok(bytes) => bytes,
            Err(_) => continue,
        };
        out.push(WorkspaceSyncFile {
            path: rel,
            modified_at: modified_unix_secs(&path),
            content_base64: BASE64_STANDARD.encode(bytes),
        });
    }
    Ok(())
}

fn export_local_store_blob(workspace_dir: &StdPath) -> Result<Option<LocalStoreSyncBlob>> {
    let db_path = local_store::db_path(workspace_dir);
    if !db_path.exists() {
        return Ok(None);
    }

    {
        let conn = rusqlite::Connection::open(&db_path)
            .with_context(|| format!("Failed to open sync export DB {}", db_path.display()))?;
        let _ = conn.execute_batch("PRAGMA wal_checkpoint(TRUNCATE);");
    }

    let bytes = std::fs::read(&db_path)
        .with_context(|| format!("Failed to read local store DB {}", db_path.display()))?;
    Ok(Some(LocalStoreSyncBlob {
        modified_at: modified_unix_secs(&db_path),
        content_base64: BASE64_STANDARD.encode(bytes),
    }))
}

fn export_workspace_sync_snapshot(workspace_dir: &StdPath) -> Result<WorkspaceSyncSnapshot> {
    let mut files = Vec::new();
    for root in SYNC_ALLOWED_ROOTS {
        collect_sync_files_recursive(workspace_dir, &workspace_dir.join(root), &mut files)?;
    }
    let workflow_settings = workspace_dir.join("feed_workflow_settings.json");
    if workflow_settings.exists() && workflow_settings.is_file() {
        let bytes = std::fs::read(&workflow_settings)
            .with_context(|| format!("Failed to read {}", workflow_settings.display()))?;
        files.push(WorkspaceSyncFile {
            path: "feed_workflow_settings.json".to_string(),
            modified_at: modified_unix_secs(&workflow_settings),
            content_base64: BASE64_STANDARD.encode(bytes),
        });
    }
    files.sort_by(|left, right| left.path.cmp(&right.path));
    Ok(WorkspaceSyncSnapshot {
        exported_at: Utc::now().timestamp(),
        files,
        local_store: export_local_store_blob(workspace_dir)?,
    })
}

fn import_workspace_sync_snapshot(
    workspace_dir: &StdPath,
    snapshot: &WorkspaceSyncSnapshot,
) -> Result<(usize, bool)> {
    let mut imported_files = 0_usize;
    for file in &snapshot.files {
        if !sync_file_allowed(&file.path) {
            continue;
        }
        let abs_path = workspace_dir.join(&file.path);
        let current_modified = modified_unix_secs(&abs_path);
        if abs_path.exists() && current_modified > file.modified_at {
            continue;
        }
        let bytes = BASE64_STANDARD
            .decode(file.content_base64.as_bytes())
            .with_context(|| format!("Failed to decode sync file {}", file.path))?;
        if let Some(parent) = abs_path.parent() {
            std::fs::create_dir_all(parent)
                .with_context(|| format!("Failed to create {}", parent.display()))?;
        }
        std::fs::write(&abs_path, bytes)
            .with_context(|| format!("Failed to write synced file {}", abs_path.display()))?;
        imported_files += 1;
    }

    let mut imported_db = false;
    if let Some(local_store_blob) = &snapshot.local_store {
        let db_path = local_store::db_path(workspace_dir);
        let local_modified = modified_unix_secs(&db_path);
        if !db_path.exists() || local_modified <= local_store_blob.modified_at {
            let bytes = BASE64_STANDARD
                .decode(local_store_blob.content_base64.as_bytes())
                .context("Failed to decode synced local store")?;
            if let Some(parent) = db_path.parent() {
                std::fs::create_dir_all(parent)
                    .with_context(|| format!("Failed to create {}", parent.display()))?;
            }
            let temp_path = db_path.with_extension("db.sync.tmp");
            std::fs::write(&temp_path, bytes)
                .with_context(|| format!("Failed to write temp DB {}", temp_path.display()))?;
            std::fs::rename(&temp_path, &db_path)
                .with_context(|| format!("Failed to replace DB {}", db_path.display()))?;
            let wal_path = db_path.with_extension("db-wal");
            if wal_path.exists() {
                let _ = std::fs::remove_file(&wal_path);
            }
            let shm_path = db_path.with_extension("db-shm");
            if shm_path.exists() {
                let _ = std::fs::remove_file(&shm_path);
            }
            imported_db = true;
        }
    }

    Ok((imported_files, imported_db))
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

    fn test_app_state_with_config(config: Config) -> AppState {
        AppState {
            config: Arc::new(Mutex::new(config)),
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
        }
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
    fn derive_interest_label_prefers_title_then_content() {
        assert_eq!(derive_interest_label("Machine Learning", "ignored"), "Machine Learning");
        assert_eq!(
            derive_interest_label("untitled", "# Systems Thinking\nBody"),
            "Systems Thinking"
        );
    }

    #[test]
    fn extract_bluesky_post_text_reads_record_text() {
        let feed_item = serde_json::json!({
            "post": {
                "record": {
                    "text": "hello from bluesky"
                }
            }
        });
        assert_eq!(extract_bluesky_post_text(&feed_item), "hello from bluesky");
    }

    #[test]
    fn build_bluesky_feed_endpoint_uses_discover_feed_generator() {
        let url = build_bluesky_feed_endpoint(
            "https://bsky.social/",
            BlueskyCandidateSource::Discover,
            Some("cursor-1"),
            30,
        );
        assert!(url.contains("/xrpc/app.bsky.feed.getFeed?feed="));
        assert!(url.contains("app.bsky.feed.generator%2Fwhats-hot"));
        assert!(url.contains("cursor=cursor-1"));
    }

    #[test]
    fn dedupe_candidate_posts_drops_duplicate_post_uri() {
        let mut seen = BTreeSet::new();
        let deduped = dedupe_candidate_posts(
            vec![
                CandidateFeedPost {
                    text: "first".to_string(),
                    feed_item: serde_json::json!({"post": {"uri": "at://post/1"}}),
                },
                CandidateFeedPost {
                    text: "second".to_string(),
                    feed_item: serde_json::json!({"post": {"uri": "at://post/1"}}),
                },
                CandidateFeedPost {
                    text: "third".to_string(),
                    feed_item: serde_json::json!({"post": {"uri": "at://post/2"}}),
                },
            ],
            &mut seen,
        );
        assert_eq!(deduped.len(), 2);
        assert_eq!(deduped[0].text, "first");
        assert_eq!(deduped[1].text, "third");
    }

    #[test]
    fn sort_personalized_items_orders_by_score_then_recency() {
        let mut items = vec![
            PersonalizedBlueskyItem {
                source_type: "bluesky".to_string(),
                feed_item: serde_json::json!({"post": {"indexedAt": "2026-03-09T09:00:00Z"}}),
                web_preview: None,
                score: Some(0.8),
                matched_interest_label: None,
                matched_interest_score: None,
                passed_threshold: true,
            },
            PersonalizedBlueskyItem {
                source_type: "bluesky".to_string(),
                feed_item: serde_json::json!({"post": {"indexedAt": "2026-03-09T10:00:00Z"}}),
                web_preview: None,
                score: Some(0.8),
                matched_interest_label: None,
                matched_interest_score: None,
                passed_threshold: true,
            },
            PersonalizedBlueskyItem {
                source_type: "bluesky".to_string(),
                feed_item: serde_json::json!({"post": {"indexedAt": "2026-03-09T11:00:00Z"}}),
                web_preview: None,
                score: Some(0.6),
                matched_interest_label: None,
                matched_interest_score: None,
                passed_threshold: false,
            },
        ];

        sort_personalized_items(&mut items);
        assert_eq!(
            items[0]
                .feed_item
                .get("post")
                .and_then(|post| post.get("indexedAt"))
                .and_then(serde_json::Value::as_str),
            Some("2026-03-09T10:00:00Z")
        );
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

    #[tokio::test]
    async fn content_agent_create_requires_name() {
        let temp = tempfile::tempdir().unwrap();
        let mut config = Config::default();
        config.workspace_dir = temp.path().to_path_buf();

        let state = AppState {
            config: Arc::new(Mutex::new(config)),
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

        let response = handle_feed_workflow_template_create(
            State(state),
            HeaderMap::new(),
            Json(FeedContentAgentCreateBody {
                name: None,
                goal: Some("Create concise feed posts from recent notes.".to_string()),
                bot_name: None,
                prompt: None,
                enabled: Some(true),
                run_now: Some(true),
            }),
        )
        .await
        .into_response();

        assert_eq!(response.status(), StatusCode::BAD_REQUEST);
        let payload = response.into_body().collect().await.unwrap().to_bytes();
        let parsed: serde_json::Value = serde_json::from_slice(&payload).unwrap();
        assert_eq!(parsed["error"], "name is required");
    }

    #[tokio::test]
    async fn content_agent_create_requires_goal() {
        let temp = tempfile::tempdir().unwrap();
        let mut config = Config::default();
        config.workspace_dir = temp.path().to_path_buf();

        let state = AppState {
            config: Arc::new(Mutex::new(config)),
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

        let response = handle_feed_workflow_template_create(
            State(state),
            HeaderMap::new(),
            Json(FeedContentAgentCreateBody {
                name: Some("Bluesky Scout".to_string()),
                goal: None,
                bot_name: None,
                prompt: Some("   ".to_string()),
                enabled: Some(true),
                run_now: Some(true),
            }),
        )
        .await
        .into_response();

        assert_eq!(response.status(), StatusCode::BAD_REQUEST);
        let payload = response.into_body().collect().await.unwrap().to_bytes();
        let parsed: serde_json::Value = serde_json::from_slice(&payload).unwrap();
        assert_eq!(parsed["error"], "goal is required");
    }

    #[tokio::test]
    async fn content_agent_create_rejects_media_goal_without_local_media_capabilities() {
        let temp = tempfile::tempdir().unwrap();
        let mut config = Config::default();
        config.workspace_dir = temp.path().to_path_buf();
        config.transcription.enabled = false;

        let response = handle_feed_workflow_template_create(
            State(test_app_state_with_config(config)),
            HeaderMap::new(),
            Json(FeedContentAgentCreateBody {
                name: Some("Clip Maker".to_string()),
                goal: Some(
                    "Create simple vertical video clips from my journal audio recordings.".to_string(),
                ),
                bot_name: None,
                prompt: None,
                enabled: Some(true),
                run_now: Some(true),
            }),
        )
        .await
        .into_response();

        assert_eq!(response.status(), StatusCode::BAD_REQUEST);
        let payload = response.into_body().collect().await.unwrap().to_bytes();
        let parsed: serde_json::Value = serde_json::from_slice(&payload).unwrap();
        assert!(
            parsed["error"]
                .as_str()
                .unwrap_or_default()
                .to_ascii_lowercase()
                .contains("requires local media tools"),
            "unexpected error payload: {parsed:?}"
        );
    }

    #[test]
    fn load_or_seed_feed_workflow_settings_store_preseeds_builtin_agents() {
        let temp = tempfile::tempdir().unwrap();
        let workspace = temp.path();

        let store = load_or_seed_feed_workflow_settings_store(workspace).unwrap();

        assert_eq!(store.workflows.len(), built_in_content_agent_specs().len());
        for spec in built_in_content_agent_specs() {
            let key = sanitize_workflow_key(spec.key);
            let record = store.workflows.get(&key).expect("missing built-in content agent");
            assert_eq!(record.workflow_bot, spec.name);
            assert_eq!(record.goal.as_deref(), Some(spec.goal));
            assert_eq!(record.enabled, spec.enabled_by_default);
            assert_eq!(record.visible_in_ui, spec.visible_in_ui);
            assert!(workspace.join(&record.skill_path).exists());
        }
    }

    #[test]
    fn workflow_definitions_hide_internal_workspace_extractors() {
        let temp = tempfile::tempdir().unwrap();
        let workspace = temp.path();
        let store = load_or_seed_feed_workflow_settings_store(workspace).unwrap();

        let defs = workflow_definitions(&store);

        assert!(defs.iter().any(|workflow| workflow.key == WORKSPACE_SYNTHESIZER_WORKFLOW_KEY));
        assert!(!defs.iter().any(|workflow| {
            workflow.key == workspace_synthesizer::WORKSPACE_INSIGHT_EXTRACTOR_WORKFLOW_KEY
        }));
        assert!(!defs.iter().any(|workflow| {
            workflow.key == workspace_synthesizer::WORKSPACE_TODO_EXTRACTOR_WORKFLOW_KEY
        }));
        assert!(!defs.iter().any(|workflow| {
            workflow.key == workspace_synthesizer::WORKSPACE_EVENT_EXTRACTOR_WORKFLOW_KEY
        }));
        assert!(!defs.iter().any(|workflow| {
            workflow.key == workspace_synthesizer::WORKSPACE_CLIP_EXTRACTOR_WORKFLOW_KEY
        }));
    }

    #[test]
    fn load_or_seed_feed_workflow_settings_store_refreshes_stale_builtin_skills() {
        let temp = tempfile::tempdir().unwrap();
        let workspace = temp.path();
        let key = sanitize_workflow_key(WORKSPACE_SYNTHESIZER_WORKFLOW_KEY);
        let mut record = built_in_content_agent_record(built_in_content_agent_specs()[0]);
        record.built_in_skill_fingerprint = None;

        let skill_abs = workspace.join(&record.skill_path);
        if let Some(parent) = skill_abs.parent() {
            std::fs::create_dir_all(parent).unwrap();
        }
        std::fs::write(
            &skill_abs,
            "# Workspace Synthesizer\n\nCreate a single strict JSON manifest.\n",
        )
        .unwrap();

        let mut store = FeedContentAgentStore::default();
        store.workflows.insert(key.clone(), record);
        save_feed_workflow_settings_store(workspace, &store).unwrap();

        let refreshed = load_or_seed_feed_workflow_settings_store(workspace).unwrap();
        let refreshed_record = refreshed.workflows.get(&key).unwrap();
        let refreshed_skill = std::fs::read_to_string(&skill_abs).unwrap();
        let expected_fingerprint = content_agent_skill_fingerprint(&refreshed_skill);

        assert!(refreshed_skill.contains("This is the index skill for workspace synthesis."));
        assert_eq!(
            refreshed_record.built_in_skill_fingerprint.as_deref(),
            Some(expected_fingerprint.as_str())
        );
    }

    #[test]
    fn content_agent_auto_run_requires_new_source_and_staleness_gate() {
        let mut record = built_in_content_agent_record(built_in_content_agent_specs()[0]);
        record.enabled = true;

        assert!(should_auto_run_content_agent(
            &record,
            100,
            ContentAgentAutoRunTrigger::JournalSave
        ));

        record.last_triggered_source_updated_at = Some(100);
        assert!(!should_auto_run_content_agent(
            &record,
            100,
            ContentAgentAutoRunTrigger::JournalSave
        ));

        record.last_triggered_source_updated_at = Some(50);
        record.last_triggered_at = Some(Utc::now().to_rfc3339());
        assert!(!should_auto_run_content_agent(
            &record,
            100,
            ContentAgentAutoRunTrigger::AppOpen
        ));

        record.last_triggered_at = Some(
            (Utc::now() - chrono::Duration::seconds(CONTENT_AGENT_APP_OPEN_STALE_SECS + 5))
                .to_rfc3339(),
        );
        assert!(should_auto_run_content_agent(
            &record,
            100,
            ContentAgentAutoRunTrigger::AppOpen
        ));
    }

    #[test]
    fn latest_content_agent_source_updated_at_reads_nested_transcripts() {
        let temp = tempfile::tempdir().unwrap();
        let workspace = temp.path();
        let journal_dir = workspace.join("journals/text");
        let transcript_dir = workspace.join("journals/text/transcriptions/session");
        std::fs::create_dir_all(&transcript_dir).unwrap();
        std::fs::create_dir_all(&journal_dir).unwrap();
        std::fs::write(journal_dir.join("entry.md"), "# entry\n").unwrap();
        std::thread::sleep(Duration::from_millis(5));
        std::fs::write(transcript_dir.join("clip.txt"), "transcript\n").unwrap();

        assert!(latest_content_agent_source_updated_at(workspace) > 0);
    }

    #[test]
    fn transcript_sidecar_paths_follow_transcript_txt_path() {
        let transcript = "journals/text/transcriptions/audio/clip.txt";
        assert_eq!(
            transcript_json_rel_path(transcript),
            "journals/text/transcriptions/audio/clip.json"
        );
        assert_eq!(
            transcript_srt_rel_path(transcript),
            "journals/text/transcriptions/audio/clip.srt"
        );
    }

    #[test]
    fn content_agent_config_with_headroom_keeps_existing_command_allowlist() {
        let base = Config::default();
        let config = content_agent_config_with_headroom(&base);
        assert_eq!(config.autonomy.allowed_commands, base.autonomy.allowed_commands);
        for command in ["python", "python3", "ffmpeg", "ffprobe"] {
            assert!(
                !config.autonomy.allowed_commands.iter().any(|value| value == command),
                "unexpected command {command}"
            );
        }
    }

    #[tokio::test]
    async fn content_agent_run_rejects_unsupported_media_workflow() {
        let temp = tempfile::tempdir().unwrap();
        let mut config = Config::default();
        config.workspace_dir = temp.path().to_path_buf();
        config.transcription.enabled = false;

        let response = handle_feed_workflow_run(
            State(test_app_state_with_config(config)),
            HeaderMap::new(),
            Json(FeedContentAgentRunBody {
                workflow_key: "audio_insight_clips".to_string(),
            }),
        )
        .await
        .into_response();

        assert_eq!(response.status(), StatusCode::BAD_REQUEST);
        let payload = response.into_body().collect().await.unwrap().to_bytes();
        let parsed: serde_json::Value = serde_json::from_slice(&payload).unwrap();
        assert_eq!(parsed["workflowKey"], "audio_insight_clips");
        assert_eq!(parsed["workflowBot"], "Audio Insight Clips");
        assert!(
            parsed["error"]
                .as_str()
                .unwrap_or_default()
                .to_ascii_lowercase()
                .contains("requires local media tools"),
            "unexpected error payload: {parsed:?}"
        );
    }

    fn sample_workflow_store() -> FeedContentAgentStore {
        let mut store = FeedContentAgentStore::default();

        let daily_key = "daily_summary";
        let daily_record = FeedContentAgentRecord {
            workflow_key: daily_key.to_string(),
            workflow_bot: "DailySummaryBot".to_string(),
            skill_path: "skills/daily_summary/SKILL.md".to_string(),
            output_prefix: "posts/daily_summary/".to_string(),
            enabled: true,
            editable_files: vec!["skills/daily_summary/SKILL.md".to_string()],
            goal: Some("Create daily summary posts from recent journal notes".to_string()),
            last_triggered_at: None,
            last_run_at: None,
            last_triggered_source_updated_at: None,
            built_in_skill_fingerprint: None,
            visible_in_ui: true,
            settings: workflow_default_settings(),
        };
        store.workflows.insert(
            daily_key.to_string(),
            normalize_workflow_record(daily_key, daily_record),
        );

        let audio_key = "audio_roundup";
        let audio_record = FeedContentAgentRecord {
            workflow_key: audio_key.to_string(),
            workflow_bot: "AudioRoundupBot".to_string(),
            skill_path: "skills/audio_roundup/SKILL.md".to_string(),
            output_prefix: "posts/audio_roundup/".to_string(),
            enabled: true,
            editable_files: vec!["skills/audio_roundup/SKILL.md".to_string()],
            goal: Some("Create roundup posts from audio transcripts".to_string()),
            last_triggered_at: None,
            last_run_at: None,
            last_triggered_source_updated_at: None,
            built_in_skill_fingerprint: None,
            visible_in_ui: true,
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
    fn workflow_comment_prompt_mentions_allowed_files_and_guardrails() {
        let store = sample_workflow_store();
        let wf = workflow_definition_by_key(&store, "daily_summary").unwrap();
        let prompt = workflow_comment_prompt(
            &wf,
            "posts/daily_summary/item.md",
            "Make tone more human and less robotic",
        );
        assert!(prompt.contains("Workflow: DailySummaryBot (daily_summary)"));
        assert!(prompt.contains("skills/daily_summary/SKILL.md"));
        assert!(prompt.contains("Keep feed output rooted under `posts/daily_summary/`"));
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
            goal: None,
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
    fn parse_feed_entries_reads_rss_items() {
        let xml = r#"
            <rss version="2.0">
              <channel>
                <title>Example Feed</title>
                <item>
                  <title>First item</title>
                  <link>https://example.com/posts/1</link>
                  <description><![CDATA[<p>Hello <strong>world</strong></p>]]></description>
                  <pubDate>Tue, 10 Mar 2026 10:00:00 +0000</pubDate>
                </item>
              </channel>
            </rss>
        "#;

        let entries = parse_feed_entries(xml, "https://example.com/feed.xml");
        assert_eq!(entries.len(), 1);
        assert_eq!(entries[0].title, "First item");
        assert_eq!(entries[0].canonical_url, "https://example.com/posts/1");
        assert_eq!(entries[0].summary, "Hello world");
        assert_eq!(entries[0].published_at, "2026-03-10T10:00:00+00:00");
    }

    #[test]
    fn parse_feed_entries_reads_atom_entries() {
        let xml = r#"
            <feed xmlns="http://www.w3.org/2005/Atom">
              <title>Example Atom</title>
              <entry>
                <title>Atom item</title>
                <id>tag:example.com,2026:1</id>
                <link rel="alternate" href="/posts/atom-1" />
                <summary type="html">&lt;p&gt;Atom summary&lt;/p&gt;</summary>
                <updated>2026-03-10T11:00:00Z</updated>
                <author><name>Example Author</name></author>
              </entry>
            </feed>
        "#;

        let entries = parse_feed_entries(xml, "https://example.com/feed.xml");
        assert_eq!(entries.len(), 1);
        assert_eq!(entries[0].title, "Atom item");
        assert_eq!(entries[0].canonical_url, "https://example.com/posts/atom-1");
        assert_eq!(entries[0].summary, "Atom summary");
        assert_eq!(entries[0].author, "Example Author");
    }

    #[tokio::test]
    async fn resolve_feed_embedder_returns_disabled_message_when_embeddings_are_off() {
        let mut config = Config::default();
        config.memory.embedding_provider = "none".to_string();

        let (embedder, message) = resolve_feed_embedder(&config).await.unwrap();
        assert!(embedder.is_none());
        assert_eq!(
            message.as_deref(),
            Some(
                "Personalized feed embeddings are disabled in [memory]. Showing recent cached content and raw Bluesky items when available."
            )
        );
    }

}
