use crate::config::Config;
use crate::providers::Provider;
use crate::memory::Memory;
use crate::security::pairing::PairingGuard;
use parking_lot::Mutex;
use std::collections::HashMap;
use std::sync::{Arc, OnceLock};
use std::time::{Duration, Instant};
use serde::{Deserialize, Serialize};

/// Maximum request body size (64KB) — prevents memory exhaustion
pub const MAX_BODY_SIZE: usize = 65_536;
/// Request timeout (30s) — prevents slow-loris attacks
pub const REQUEST_TIMEOUT_SECS: u64 = 30;
/// Rate limiting sliding window.
pub const RATE_LIMIT_WINDOW_SECS: u64 = 60;
/// Rate limit sweep interval
const RATE_LIMITER_SWEEP_INTERVAL_SECS: u64 = 300;

#[derive(Debug)]
pub struct SlidingWindowRateLimiter {
    pub limit_per_window: u32,
    pub window: Duration,
    pub max_keys: usize,
    pub requests: Mutex<(HashMap<String, Vec<Instant>>, Instant)>,
}

impl SlidingWindowRateLimiter {
    pub fn new(limit_per_window: u32, window: Duration, max_keys: usize) -> Self {
        Self {
            limit_per_window,
            window,
            max_keys: max_keys.max(1),
            requests: Mutex::new((HashMap::new(), Instant::now())),
        }
    }

    pub fn prune_stale(requests: &mut HashMap<String, Vec<Instant>>, cutoff: Instant) {
        requests.retain(|_, timestamps| {
            timestamps.retain(|t| *t > cutoff);
            !timestamps.is_empty()
        });
    }

    pub fn allow(&self, key: &str) -> bool {
        if self.limit_per_window == 0 {
            return true;
        }

        let now = Instant::now();
        let cutoff = now.checked_sub(self.window).unwrap_or(now);

        let mut guard = self.requests.lock();
        let (requests, last_sweep) = &mut *guard;

        if last_sweep.elapsed() >= Duration::from_secs(RATE_LIMITER_SWEEP_INTERVAL_SECS) {
            Self::prune_stale(requests, cutoff);
            *last_sweep = now;
        }

        if !requests.contains_key(key) && requests.len() >= self.max_keys {
            Self::prune_stale(requests, cutoff);
        }

        let entry = requests.entry(key.to_string()).or_default();
        entry.retain(|t| *t > cutoff);

        if entry.len() >= self.limit_per_window as usize {
            return false;
        }

        entry.push(now);
        true
    }
}

#[derive(Debug)]
pub struct GatewayRateLimiter {
    pub pair: SlidingWindowRateLimiter,
    pub webhook: SlidingWindowRateLimiter,
}

impl GatewayRateLimiter {
    pub fn new(pair_per_minute: u32, webhook_per_minute: u32, max_keys: usize) -> Self {
        let window = Duration::from_secs(RATE_LIMIT_WINDOW_SECS);
        Self {
            pair: SlidingWindowRateLimiter::new(pair_per_minute, window, max_keys),
            webhook: SlidingWindowRateLimiter::new(webhook_per_minute, window, max_keys),
        }
    }

    pub fn allow_pair(&self, key: &str) -> bool {
        self.pair.allow(key)
    }

    pub fn allow_webhook(&self, key: &str) -> bool {
        self.webhook.allow(key)
    }
}

#[derive(Debug)]
pub struct IdempotencyStore {
    pub ttl: Duration,
    pub max_keys: usize,
    pub keys: Mutex<HashMap<String, Instant>>,
}

impl IdempotencyStore {
    pub fn new(ttl: Duration, max_keys: usize) -> Self {
        Self {
            ttl,
            max_keys: max_keys.max(1),
            keys: Mutex::new(HashMap::new()),
        }
    }

    pub fn record_if_new(&self, key: &str) -> bool {
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

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct LocalModelDownloadJob {
    pub model_id: String,
    pub status: String,
    pub transferred_bytes: u64,
    pub total_bytes: Option<u64>,
    pub error: Option<String>,
    pub path: Option<String>,
}

#[derive(Debug, Default)]
pub struct LocalModelRuntimeState {
    pub child: Option<tokio::process::Child>,
    pub model_id: Option<String>,
    pub status: String,
    pub binary: Option<String>,
    pub pid: Option<u32>,
    pub port: u16,
    pub error: Option<String>,
    pub started_at_unix: Option<u64>,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct LocalModelRuntimeSnapshot {
    pub status: String,
    pub running: bool,
    pub model_id: Option<String>,
    pub binary: Option<String>,
    pub pid: Option<u32>,
    pub port: u16,
    pub api_url: String,
    pub error: Option<String>,
    pub started_at_unix: Option<u64>,
}

#[derive(Clone, Debug)]
pub struct OpenRouterOAuthSession {
    pub pkce: crate::auth::oauth_common::PkceState,
    pub status: OpenRouterOAuthStatus,
    pub api_key: Option<String>,
    pub error: Option<String>,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum OpenRouterOAuthStatus {
    Pending,
    Complete,
    Failed,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct JournalTranscriptionJob {
    pub status: String,
    pub transcript_path: Option<String>,
    pub error: Option<String>,
    pub updated_at: String,
}

impl JournalTranscriptionJob {
    pub fn queued() -> Self {
        Self {
            status: "queued".to_string(),
            transcript_path: None,
            error: None,
            updated_at: chrono::Utc::now().to_rfc3339(),
        }
    }
}

#[derive(Clone, Debug)]
pub struct TranscriptionModelCacheEntry {
    pub cache_key: String,
    pub models: Vec<String>,
    pub cached_at: Instant,
}

pub static TRANSCRIPTION_MODEL_CACHE: OnceLock<Mutex<Option<TranscriptionModelCacheEntry>>> =
    OnceLock::new();

pub const TRANSCRIPTION_MODEL_CACHE_TTL_SECS: u64 = 600;

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
    pub journal_transcription_jobs: Arc<Mutex<HashMap<String, JournalTranscriptionJob>>>,
    pub local_model_downloads: Arc<Mutex<HashMap<String, LocalModelDownloadJob>>>,
    pub local_model_runtime: Arc<tokio::sync::Mutex<LocalModelRuntimeState>>,
    /// In-flight OpenRouter OAuth PKCE session (one at a time).
    pub openrouter_oauth: Arc<Mutex<Option<OpenRouterOAuthSession>>>,
}
