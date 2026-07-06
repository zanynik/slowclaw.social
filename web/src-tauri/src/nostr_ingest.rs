//! Background Nostr ingester.
//!
//! Mirrors the engine-module pattern of `inference.rs` / `transcription.rs`:
//! pure engine logic in this file, `#[tauri::command]` wrappers in `lib.rs`.
//! The engine owns a long-lived [`nostr_sdk::Client`] and drains its
//! notification stream, persisting every incoming event into the core crate's
//! `zeroclaw::nostr_store`. The UI then queries the local store via IPC
//! instead of re-hitting relays on every feed load.
//!
//! Lifecycle:
//! - [`start_ingester`] spawns a tokio task and returns its `JoinHandle`.
//! - The task builds a `Client`, connects to configured relays, subscribes to
//!   the configured hashtag channels + text notes + articles, and loops on
//!   `client.notifications()`, ingesting each `RelayPoolNotification::Event`.
//! - [`IngesterHandle::stop`] aborts the task and shuts the client down.
//!
//! All public functions return `Result<T, String>` and map errors to
//! human-readable strings, matching `inference.rs`.

use std::path::{Path, PathBuf};
use std::sync::Arc;

use nostr_sdk::prelude::{Client as NostrClient, Filter, Kind, RelayPoolNotification, Timestamp};
use tauri::async_runtime::JoinHandle;
use tokio::sync::Mutex;

use zeroclaw::nostr_store;

/// How far back to fetch on a cold start (seconds). Matches the gateway's
/// `NOSTR_LOOKBACK_SECS` (7 days) so the local store sees the same window the
/// world-feed pipeline does.
const COLD_START_LOOKBACK_SECS: u64 = 7 * 24 * 60 * 60;

/// Cap on the initial backfill subscription `limit` per filter.
const BACKFILL_LIMIT: usize = 200;

/// Default relays used when the config provides none. Mirrors the browser's
/// `DEFAULT_RELAYS` plus Primal for video-rich content.
pub const DEFAULT_INGESTER_RELAYS: &[&str] = &[
    "wss://relay.damus.io",
    "wss://nos.lol",
    "wss://relay.nostr.band",
    "wss://relay.primal.net",
];

/// Hashtag channels to subscribe to (lowercase, no `#`). Mirrors the frontend's
/// `CONTENT_CHANNELS` presets so the ingester stays in sync with what the UI
/// surfaces. Empty list means "firehose" (subscribe to all recent text notes).
pub const DEFAULT_HASHTAG_CHANNELS: &[&str] = &[
    "nostr",
    "bitcoin",
    "ai",
    "art",
    "photography",
    "music",
    "tech",
    "philosophy",
];

/// Handle returned by [`start_ingester`]. Owns the client (shared with the
/// managed state so publish commands reuse the same relay connections) and the
/// background drain-task handle.
pub struct IngesterHandle {
    pub client: Arc<NostrClient>,
    pub join_handle: JoinHandle<()>,
}

/// Spawn the background ingester. The task runs until [`IngesterHandle::stop`]
/// is called or the runtime is torn down.
///
/// `workspace_dir` is where `nostr.db` lives (under `state/`). `relays` is the
/// list of relay URLs to connect (falls back to [`DEFAULT_INGESTER_RELAYS`] if
/// empty). `hashtag_channels` drives the per-hashtag subscriptions (falls back
/// to [`DEFAULT_HASHTAG_CHANNELS`] if empty).
pub async fn start_ingester(
    workspace_dir: PathBuf,
    relays: Vec<String>,
    hashtag_channels: Vec<String>,
) -> Result<IngesterHandle, String> {
    // Ensure the schema exists before the first ingest.
    {
        let ws = workspace_dir.clone();
        tauri::async_runtime::spawn_blocking(move || {
            nostr_store::initialize(&ws).map_err(|e| format!("Failed to init nostr store: {e}"))
        })
        .await
        .map_err(|e| format!("Init task failed: {e}"))??;
    }

    let client = NostrClient::default();
    let resolved_relays: Vec<String> = if relays.is_empty() {
        DEFAULT_INGESTER_RELAYS
            .iter()
            .map(|s| (*s).to_string())
            .collect()
    } else {
        relays
    };
    for url in &resolved_relays {
        client
            .add_relay(url.clone())
            .await
            .map_err(|e| format!("Failed to add relay {url}: {e}"))?;
    }
    client.connect().await;

    let filters = build_subscription_filters(
        &hashtag_channels,
        Timestamp::now()
            .as_secs()
            .saturating_sub(COLD_START_LOOKBACK_SECS),
    );
    // `opts = None` means a long-lived subscription (no auto-close). The
    // ingester keeps receiving new events from the relay after the initial
    // backfill — that is the whole point of the "local relay" model.
    for filter in filters {
        let _ = client.subscribe(filter, None).await;
    }

    let client_arc = Arc::new(client);
    let drain_client = client_arc.clone();
    let workspace_for_drain = workspace_dir.clone();

    let join_handle = tauri::async_runtime::spawn(async move {
        drain_notifications(drain_client, workspace_for_drain).await;
    });

    Ok(IngesterHandle {
        client: client_arc,
        join_handle,
    })
}

/// Build the subscription filter set. We keep this narrow: text notes (kind 1)
/// and long-form articles (kind 30023), either scoped to the configured
/// hashtags or, when no hashtags are set, a broad recent-text-notes filter.
fn build_subscription_filters(hashtags: &[String], since_secs: u64) -> Vec<Filter> {
    let since = Timestamp::from_secs(since_secs);
    let mut filters = Vec::new();

    let cleaned: Vec<String> = hashtags
        .iter()
        .filter_map(|h| {
            let trimmed = h.trim().trim_start_matches('#').to_ascii_lowercase();
            if trimmed.is_empty() {
                None
            } else {
                Some(trimmed)
            }
        })
        .collect();

    if cleaned.is_empty() {
        // Firehose-ish: recent text notes + articles.
        filters.push(
            Filter::new()
                .kind(Kind::TextNote)
                .since(since)
                .limit(BACKFILL_LIMIT),
        );
        filters.push(
            Filter::new()
                .kind(Kind::from(30023))
                .since(since)
                .limit(BACKFILL_LIMIT / 4),
        );
    } else {
        // NIP-12 hashtag filter. The relay does the per-tag filtering. We
        // rebuild the `&str` slice for each filter since `Filter::hashtags`
        // consumes the iterator.
        let build_hashtag_filter = |kind: Kind, limit: usize| {
            let refs: Vec<&str> = cleaned.iter().map(String::as_str).collect();
            Filter::new()
                .kind(kind)
                .hashtags(refs)
                .since(since)
                .limit(limit)
        };
        filters.push(build_hashtag_filter(Kind::TextNote, BACKFILL_LIMIT));
        filters.push(build_hashtag_filter(Kind::from(30023), BACKFILL_LIMIT / 4));
    }

    filters
}

/// Drain the client's notification stream and persist every event.
///
/// Runs forever (until the task is aborted). Errors from individual ingests are
/// logged but do not stop the loop — a single bad event must not kill the
/// ingester.
async fn drain_notifications(client: Arc<NostrClient>, workspace_dir: PathBuf) {
    let mut notifications = client.notifications();
    loop {
        match notifications.recv().await {
            Ok(RelayPoolNotification::Event { event, .. }) => {
                let ws = workspace_dir.clone();
                let ev = (*event).clone();
                // Ingest on a blocking thread so SQLite I/O never stalls the
                // async notification stream.
                let _ = tauri::async_runtime::spawn_blocking(move || {
                    let _ = nostr_store::ingest_event(&ws, &ev);
                })
                .await;
            }
            Ok(_) => {
                // Message / Shutdown / Stop variants — not persisted.
            }
            Err(e) => {
                eprintln!("nostr ingester: notification channel closed: {e}");
                // Back off briefly to avoid a tight loop if the channel is
                // repeatedly erroring, then try to resume.
                tokio::time::sleep(std::time::Duration::from_secs(1)).await;
            }
        }
    }
}

/// Resolve the configured relays from the slowclaw config, falling back to
/// the built-in defaults. Reads `Config.channels_config.nostr.relays`.
pub fn resolve_configured_relays(config: &zeroclaw::Config) -> Vec<String> {
    let configured: Vec<String> = config
        .channels_config
        .nostr
        .as_ref()
        .map(|n| n.relays.clone())
        .unwrap_or_default()
        .into_iter()
        .filter(|s| !s.trim().is_empty())
        .collect();
    if configured.is_empty() {
        DEFAULT_INGESTER_RELAYS
            .iter()
            .map(|s| (*s).to_string())
            .collect()
    } else {
        configured
    }
}

/// Wrap the client in a `Mutex` for the managed-state pattern used elsewhere
/// in `lib.rs`. Kept here so the type lives next to the engine.
pub fn wrap_client(client: Arc<NostrClient>) -> Arc<Mutex<Option<Arc<NostrClient>>>> {
    Arc::new(Mutex::new(Some(client)))
}

/// Count events currently in the store (for the status UI).
pub fn event_count(workspace_dir: &Path) -> Result<i64, String> {
    nostr_store::event_count(workspace_dir)
        .map_err(|e| format!("Failed to count nostr events: {e}"))
}

/// Most recent `received_at` timestamp (RFC3339), for the status UI.
pub fn last_received_at(workspace_dir: &Path) -> Result<Option<String>, String> {
    nostr_store::last_received_at(workspace_dir)
        .map_err(|e| format!("Failed to read nostr last received_at: {e}"))
}
