pub mod traits;

use crate::config::Config;
use crate::gateway::{feed_web_sources::DEFAULT_FEED_WEB_SOURCES, local_store};
use crate::memory::{self, vector::{cosine_similarity, vec_to_bytes}};
use crate::tools::web_search_tool::WebSearchTool;
use crate::util::truncate_with_ellipsis;
use anyhow::{Context, Result};
use async_trait::async_trait;
use chrono::{TimeZone, Utc};
use nostr_sdk::prelude::{
    Client as NostrClient, Event as NostrEvent, Filter as NostrFilter, Kind as NostrKind,
    Timestamp as NostrTimestamp, ToBech32,
};
use parking_lot::Mutex;
use regex::Regex;
use rust_stemmers::{Algorithm as StemAlgorithm, Stemmer};
use serde::{Deserialize, Serialize};
use std::cmp::Ordering;
use std::collections::{BTreeSet, HashMap, HashSet};
use std::path::{Path, PathBuf};
use std::sync::{Arc, OnceLock};
use std::time::Duration;

pub use traits::FeedSource;

pub const WORLD_FEED_KEY: &str = "world";

const WORLD_FEED_CACHE_TTL_SECS: i64 = 5 * 60;
const WORLD_FEED_RANK_LIMIT: usize = 50;
const WORLD_FEED_COLD_START_SYNC_TIMEOUT_SECS: u64 = 8;
const WORLD_FEED_FALLBACK_MIN_BLUESKY_ITEMS: usize = 6;
const WORLD_FEED_STAGE1_PREVIEW_TIMEOUT_SECS: u64 = 6;
const FEED_PROFILE_MAX_CHARS: usize = 2_400;
const FEED_EMBED_BATCH_SIZE: usize = 16;
const FEED_MATCH_THRESHOLD: f32 = 0.62;
const FEED_HIGH_CONFIDENCE_STAGE1_SCORE: f32 = 0.72;
const STAGE1_SOURCE_WEIGHT: f32 = 0.28;
const STAGE2_ITEM_WEIGHT: f32 = 0.72;
const INTEREST_MERGE_THRESHOLD: f32 = 0.75;
const INTEREST_SPAWN_THRESHOLD: f32 = 0.35;
const INTEREST_DECAY_RATE: f64 = 0.95;
const INTEREST_EMA_NEW_WEIGHT: f32 = 0.2;
const BLUESKY_TIMELINE_LIMIT_MAX: usize = 100;
const BLUESKY_DISCOVER_FEED_URI: &str =
    "at://did:plc:qh3lfd7q24h3fn3pejqr25ct/app.bsky.feed.generator/whats-hot";
const BLUESKY_FEED_GENERATOR_DISCOVERY_PAGE_LIMIT: usize = 3;
const BLUESKY_FEED_GENERATOR_DISCOVERY_PAGE_SIZE: usize = 25;
const BLUESKY_FEED_GENERATOR_MATCH_LIMIT: usize = 6;
const BLUESKY_FEED_SOURCE_MATCH_THRESHOLD: f32 = 0.55;
const BLUESKY_PERSONALIZED_PAGE_LIMIT_PER_SOURCE: usize = 4;
const BLUESKY_PERSONALIZED_PAGE_SIZE: usize = 20;
const RSS_SOURCE_MATCH_THRESHOLD: f32 = 0.28;
const RSS_SELECTED_SOURCE_LIMIT: usize = 10;
const RSS_RECENT_SCAN_LIMIT: usize = 256;
const RSS_CANDIDATE_PER_SOURCE_LIMIT: usize = 6;
const RSS_CONTENT_REFRESH_TTL_SECS: i64 = 30 * 60;
const RSS_CONTENT_FETCH_TIMEOUT_SECS: u64 = 8;
const BLUESKY_FETCH_TIMEOUT_SECS: u64 = 8;
const NOSTR_RELAY_MATCH_THRESHOLD: f32 = 0.28;
const NOSTR_SELECTED_RELAY_LIMIT: usize = 4;
const NOSTR_RECENT_NOTE_LIMIT_PER_RELAY: usize = 20;
const NOSTR_LOOKBACK_SECS: u64 = 7 * 24 * 60 * 60;
const NOSTR_RELAY_METADATA_TIMEOUT_SECS: u64 = 5;
const NOSTR_RELAY_CONNECT_TIMEOUT_SECS: u64 = 5;
const NOSTR_EVENT_FETCH_TIMEOUT_SECS: u64 = 8;
const NOSTR_NIP66_DISCOVERY_KIND: u16 = 30166;
const NOSTR_NIP66_DISCOVERY_EVENT_LIMIT: usize = 75;
const NOSTR_PRIMAL_FALLBACK_RELAY: &str = "wss://relay.primal.net";
const WEB_SEARCH_RESULT_LIMIT_PER_QUERY: usize = 4;
const STAGE1_KEYWORD_LIMIT: usize = 15;
const STAGE1_KEYWORDS_PER_INTEREST_LIMIT: usize = 8;
const KEYWORD_PROFILE_LIMIT: usize = 200;
const KEYWORD_PROFILE_BATCH_LIMIT: usize = 15;
const KEYWORD_PROFILE_DECAY_RATE: f64 = 0.94;
const KEYWORD_PROFILE_MIN_WEIGHT: f64 = 0.12;
const KEYWORD_PROFILE_MAX_WEIGHT: f64 = 4.5;
const KEYWORD_PROFILE_SOURCE_BONUS: f32 = 0.15;
const KEYWORD_PROFILE_FRESHNESS_BONUS_MAX: f32 = 0.18;

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum FeedProtocol {
    Bluesky,
    Rss,
    Nostr,
}

impl FeedProtocol {
    fn source_type(&self) -> &'static str {
        match self {
            Self::Bluesky => "bluesky",
            Self::Rss | Self::Nostr => "web",
        }
    }
}

#[derive(Debug, Clone)]
pub struct BlueskyAuth {
    pub service_url: String,
    pub access_jwt: String,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub struct InterestProfileStats {
    pub interest_count: usize,
    pub source_count: usize,
    pub refreshed_sources: usize,
    pub merged_count: usize,
    pub spawned_count: usize,
    pub ignored_count: usize,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct FeedSourceContext {
    pub label: String,
    pub description: Option<String>,
    pub matched_interest_label: Option<String>,
    pub matched_interest_score: Option<f32>,
    pub source_score: Option<f32>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct WebFeedPreview {
    pub url: String,
    pub title: String,
    pub description: String,
    pub content_text: String,
    pub image_url: Option<String>,
    pub domain: String,
    pub provider: String,
    pub provider_snippet: Option<String>,
    pub discovered_at: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PersonalizedFeedItem {
    pub source_type: String,
    pub feed_item: serde_json::Value,
    pub web_preview: Option<WebFeedPreview>,
    pub feed_source: Option<FeedSourceContext>,
    pub score: Option<f32>,
    pub matched_interest_label: Option<String>,
    pub matched_interest_score: Option<f32>,
    pub passed_threshold: bool,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub struct PersonalizedFeedResponse {
    pub items: Vec<PersonalizedFeedItem>,
    pub profile_status: String,
    pub profile_stats: InterestProfileStats,
    pub used_fallback: bool,
    pub message: Option<String>,
    pub refresh_state: String,
    pub refreshed_at: Option<String>,
    pub refresh_status: String,
    pub last_error: Option<String>,
    pub selected_sources: Vec<SelectedSource>,
    pub diagnostics: FeedRefreshDiagnostics,
    pub generation: i64,
}

#[derive(Debug, Clone)]
pub struct InterestVector {
    pub id: String,
    pub label: String,
    pub embedding: Vec<f32>,
    pub health_score: f32,
    pub source_path: String,
    pub keywords: Vec<String>,
}

#[derive(Debug, Clone, Default)]
pub struct FeedProfile {
    pub status: String,
    pub stats: InterestProfileStats,
    pub interests: Vec<InterestVector>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct FeedInterestDiagnosticItem {
    pub id: String,
    pub label: String,
    pub source_path: String,
    pub health_score: f64,
    pub last_seen_at: String,
    pub created_at: String,
    pub updated_at: String,
    pub embedding_dimensions: usize,
    pub synthetic: bool,
    pub deletable: bool,
    pub keywords: Vec<String>,
    pub keywords_override: Option<Vec<String>>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct FeedInterestDiagnosticsResponse {
    pub items: Vec<FeedInterestDiagnosticItem>,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub struct FeedProtocolDiagnostics {
    pub available: bool,
    pub scanned_count: usize,
    pub metadata_fetched_count: usize,
    pub shortlisted_count: usize,
    pub candidate_count: usize,
    pub sampled_sources: Vec<SelectedSource>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub struct FeedRankingDiagnostics {
    pub candidate_count_before_ranking: usize,
    pub ranked_item_count: usize,
}

#[derive(Debug, Clone, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
#[serde(default)]
pub struct FeedRefreshDiagnostics {
    pub rss: FeedProtocolDiagnostics,
    pub nostr: FeedProtocolDiagnostics,
    pub bluesky: FeedProtocolDiagnostics,
    pub ranking: FeedRankingDiagnostics,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SelectedSource {
    pub protocol: FeedProtocol,
    pub key: String,
    pub label: String,
    pub stage1_score: f32,
    pub description: Option<String>,
    pub matched_interest_label: Option<String>,
    pub matched_interest_score: Option<f32>,
    #[serde(default)]
    pub metadata_json: serde_json::Value,
}

#[derive(Debug, Clone)]
pub struct FeedCandidate {
    pub protocol: FeedProtocol,
    pub dedupe_key: String,
    pub stage1_score: f32,
    pub rank_text: String,
    pub item: PersonalizedFeedItem,
    pub original_index: usize,
}

struct PreparedWorldFeedData {
    profile: FeedProfile,
    selected_sources: Vec<SelectedSource>,
    diagnostics: FeedRefreshDiagnostics,
    candidates: Vec<FeedCandidate>,
}

#[derive(Debug, Clone)]
struct CandidateFeedGenerator {
    uri: String,
    display_name: String,
    description: String,
    creator_handle: String,
    creator_display_name: String,
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

#[derive(Debug, Clone)]
struct BlueskyCandidateSource {
    endpoint: BlueskyCandidateSourceEndpoint,
    label: String,
    feed_source: Option<FeedSourceContext>,
    stage1_score: f32,
}

#[derive(Debug, Clone)]
enum BlueskyCandidateSourceEndpoint {
    HomeTimeline,
    FeedGenerator { uri: String },
}

impl BlueskyCandidateSource {
    fn home_timeline() -> Self {
        Self {
            endpoint: BlueskyCandidateSourceEndpoint::HomeTimeline,
            label: "home".to_string(),
            feed_source: Some(FeedSourceContext {
                label: "Home timeline".to_string(),
                description: None,
                matched_interest_label: None,
                matched_interest_score: None,
                source_score: Some(0.18),
            }),
            stage1_score: 0.18,
        }
    }

    fn discover_fallback() -> Self {
        Self {
            endpoint: BlueskyCandidateSourceEndpoint::FeedGenerator {
                uri: BLUESKY_DISCOVER_FEED_URI.to_string(),
            },
            label: "discover".to_string(),
            feed_source: Some(FeedSourceContext {
                label: "Discover".to_string(),
                description: None,
                matched_interest_label: None,
                matched_interest_score: None,
                source_score: Some(0.2),
            }),
            stage1_score: 0.2,
        }
    }

    fn endpoint_key(&self) -> String {
        match &self.endpoint {
            BlueskyCandidateSourceEndpoint::HomeTimeline => "home".to_string(),
            BlueskyCandidateSourceEndpoint::FeedGenerator { uri } => format!("feed:{uri}"),
        }
    }
}

fn fallback_bluesky_selected_sources() -> Vec<SelectedSource> {
    vec![
        SelectedSource {
            protocol: FeedProtocol::Bluesky,
            key: "home".to_string(),
            label: "Home timeline".to_string(),
            stage1_score: 0.18,
            description: Some(
                "Fallback Bluesky home timeline while interest-matched feeds warm up.".to_string(),
            ),
            matched_interest_label: None,
            matched_interest_score: None,
            metadata_json: serde_json::json!({}),
        },
        SelectedSource {
            protocol: FeedProtocol::Bluesky,
            key: format!("feed:{BLUESKY_DISCOVER_FEED_URI}"),
            label: "Discover".to_string(),
            stage1_score: 0.2,
            description: Some(
                "Fallback Bluesky Discover feed while personalized feed matching warms up."
                    .to_string(),
            ),
            matched_interest_label: None,
            matched_interest_score: None,
            metadata_json: serde_json::json!({
                "uri": BLUESKY_DISCOVER_FEED_URI,
            }),
        },
    ]
}

#[derive(Debug, Clone)]
struct RankedCandidate {
    dedupe_key: String,
    item: PersonalizedFeedItem,
    original_index: usize,
    score: f32,
}

type SharedEmbedder = Arc<dyn memory::embeddings::EmbeddingProvider>;

pub struct FeedRanker;

impl FeedRanker {
    pub async fn rank_candidates(
        embedder: SharedEmbedder,
        profile: &FeedProfile,
        candidates: Vec<FeedCandidate>,
        limit: usize,
    ) -> Result<Vec<PersonalizedFeedItem>> {
        if profile.interests.is_empty() || candidates.is_empty() {
            return Ok(Vec::new());
        }

        let lexical_terms = top_interest_terms(profile);
        let mut candidates_to_embed = Vec::new();
        let mut texts = Vec::new();

        for candidate in candidates {
            let trimmed = candidate.rank_text.trim();
            if trimmed.is_empty() {
                continue;
            }
            if !passes_lexical_gate(trimmed, &lexical_terms, candidate.stage1_score) {
                continue;
            }
            texts.push(truncate_with_ellipsis(trimmed, FEED_PROFILE_MAX_CHARS));
            candidates_to_embed.push(candidate);
        }

        if candidates_to_embed.is_empty() {
            return Ok(Vec::new());
        }

        let embeddings = embed_text_batch(embedder, &texts).await?;
        let mut ranked = Vec::new();
        let mut has_strong_match = false;
        for (candidate, embedding) in candidates_to_embed.into_iter().zip(embeddings.into_iter()) {
            let (weighted_score, similarity, matched_label) =
                best_interest_match(&embedding, &profile.interests);
            let final_score =
                STAGE1_SOURCE_WEIGHT * candidate.stage1_score + STAGE2_ITEM_WEIGHT * weighted_score;
            let mut item = candidate.item;
            item.score = Some(final_score);
            item.matched_interest_label = matched_label;
            item.matched_interest_score = if similarity > 0.0 {
                Some(similarity)
            } else {
                None
            };
            item.passed_threshold = final_score >= FEED_MATCH_THRESHOLD;
            has_strong_match |= item.passed_threshold;

            ranked.push(RankedCandidate {
                dedupe_key: candidate.dedupe_key,
                item,
                original_index: candidate.original_index,
                score: final_score,
            });
        }

        let mut deduped: HashMap<String, RankedCandidate> = HashMap::new();
        for candidate in ranked {
            if let Some(existing) = deduped.get(&candidate.dedupe_key) {
                if rank_candidate_cmp(&candidate, existing) != Ordering::Less {
                    continue;
                }
            }
            deduped.insert(candidate.dedupe_key.clone(), candidate);
        }

        let mut ranked_items: Vec<RankedCandidate> = deduped.into_values().collect();
        ranked_items.sort_by(rank_candidate_cmp);
        if has_strong_match {
            ranked_items.retain(|candidate| candidate.item.passed_threshold);
        }
        ranked_items = interleave_ranked_candidates_by_source(ranked_items, limit);
        Ok(ranked_items.into_iter().map(|candidate| candidate.item).collect())
    }
}

fn rank_candidates_stage2(
    profile: &FeedProfile,
    candidates: Vec<FeedCandidate>,
    limit: usize,
) -> Vec<PersonalizedFeedItem> {
    let keyword_weights = weighted_interest_keywords(profile);
    let mut ranked = Vec::new();
    for candidate in candidates {
        let (keyword_score, matched_keyword) =
            keyword_weight_sum(&candidate.rank_text, &keyword_weights);
        let freshness_bonus = candidate_freshness_bonus(&candidate.item);
        let final_score =
            keyword_score + freshness_bonus + (candidate.stage1_score * KEYWORD_PROFILE_SOURCE_BONUS);
        let mut item = candidate.item;
        item.score = Some(final_score);
        item.matched_interest_label = matched_keyword;
        item.matched_interest_score = if keyword_score > 0.0 {
            Some(keyword_score)
        } else {
            None
        };
        item.passed_threshold = final_score > 0.0;
        ranked.push(RankedCandidate {
            dedupe_key: candidate.dedupe_key,
            item,
            original_index: candidate.original_index,
            score: final_score,
        });
    }

    let mut deduped: HashMap<String, RankedCandidate> = HashMap::new();
    for candidate in ranked {
        if let Some(existing) = deduped.get(&candidate.dedupe_key) {
            if rank_candidate_cmp(&candidate, existing) != Ordering::Less {
                continue;
            }
        }
        deduped.insert(candidate.dedupe_key.clone(), candidate);
    }

    let mut ranked_items: Vec<RankedCandidate> = deduped.into_values().collect();
    ranked_items.sort_by(rank_candidate_cmp);
    ranked_items = interleave_ranked_candidates_by_source(ranked_items, limit);
    ranked_items
        .into_iter()
        .map(|candidate| candidate.item)
        .collect()
}

fn interleave_ranked_candidates_by_source(
    ranked_items: Vec<RankedCandidate>,
    limit: usize,
) -> Vec<RankedCandidate> {
    if ranked_items.len() <= 2 {
        return ranked_items.into_iter().take(limit).collect();
    }

    let mut buckets: Vec<(String, Vec<RankedCandidate>)> = Vec::new();
    for candidate in ranked_items {
        let source_key = candidate_source_mix_key(&candidate.item);
        if let Some((_, bucket)) = buckets.iter_mut().find(|(key, _)| key == &source_key) {
            bucket.push(candidate);
        } else {
            buckets.push((source_key, vec![candidate]));
        }
    }

    if buckets.len() <= 1 {
        return buckets
            .into_iter()
            .flat_map(|(_, bucket)| bucket)
            .take(limit)
            .collect();
    }

    let mut interleaved = Vec::new();
    loop {
        let mut advanced = false;
        for (_, bucket) in &mut buckets {
            if bucket.is_empty() {
                continue;
            }
            interleaved.push(bucket.remove(0));
            advanced = true;
            if interleaved.len() >= limit {
                return interleaved;
            }
        }
        if !advanced {
            break;
        }
    }
    interleaved
}

pub fn mark_world_feed_dirty(workspace_dir: &Path) -> Result<()> {
    local_store::mark_personalized_feed_dirty(workspace_dir, WORLD_FEED_KEY)
}

async fn build_prepared_world_feed_data(
    config: &Config,
    bluesky_auth: Option<BlueskyAuth>,
    include_web_search: bool,
) -> Result<Option<PreparedWorldFeedData>> {
    tracing::info!("World feed: building prepared data (include_web_search={include_web_search})");
    let profile = rebuild_interest_profile(config).await?;
    tracing::info!(
        status = %profile.status,
        interest_count = profile.interests.len(),
        source_count = profile.stats.source_count,
        "World feed: interest profile built"
    );

    // Write progress: profile built, discovery starting
    write_progress_diagnostics(
        &config.workspace_dir,
        "discovering",
        &profile.status,
        &profile.stats,
        &FeedRefreshDiagnostics::default(),
        &[],
        &Utc::now().to_rfc3339(),
    );

    if profile.interests.is_empty() || profile.status != "ready" {
        return Ok(Some(PreparedWorldFeedData {
            profile,
            selected_sources: Vec::new(),
            diagnostics: FeedRefreshDiagnostics::default(),
            candidates: Vec::new(),
        }));
    }

    // Each protocol is independent — run all three in parallel.
    // A failure in one must not kill the others.

    let rss_source = RssFeedSource::new(config);
    let nostr_source = NostrFeedSource::new(config);

    // Use the freshest Bluesky auth: prefer the globally stored latest auth
    // (which may have been updated by a newer request while this task was running),
    // falling back to the auth captured at spawn time.
    let effective_bluesky_auth = take_latest_bluesky_auth(&config.workspace_dir)
        .or(bluesky_auth);

    let rss_future = async {
        match rss_source.discover_sources_with_diagnostics(&profile).await {
            Ok((selected, diagnostics)) => {
                let cloned = selected.clone();
                match rss_source.fetch_candidates(&profile, &selected, limit_for_candidates()).await {
                    Ok(fetched) => {
                        let mut d = diagnostics;
                        d.candidate_count = fetched.len();
                        (cloned, d, fetched, selected)
                    }
                    Err(err) => {
                        tracing::warn!("RSS candidate fetch failed: {err}");
                        let mut d = diagnostics;
                        d.candidate_count = 0;
                        (cloned.clone(), d, Vec::new(), cloned)
                    }
                }
            }
            Err(err) => {
                tracing::warn!("RSS source discovery failed: {err}");
                (Vec::new(), FeedProtocolDiagnostics { available: false, error: Some(format!("{err}")), ..Default::default() }, Vec::new(), Vec::new())
            }
        }
    };

    let nostr_future = async {
        let mut diagnostics = FeedProtocolDiagnostics::default();
        let mut selected = Vec::new();
        let mut candidates = Vec::new();
        match nostr_source.discover_sources_with_diagnostics(&profile).await {
            Ok((nostr_selected, mut discovered_diagnostics)) => {
                match nostr_source.fetch_candidates(&profile, &nostr_selected, limit_for_candidates()).await {
                    Ok(nostr_candidates) => {
                        discovered_diagnostics.candidate_count = nostr_candidates.len();
                        candidates = nostr_candidates;
                    }
                    Err(err) => {
                        tracing::warn!("Nostr candidate fetch failed: {err}");
                        discovered_diagnostics.candidate_count = 0;
                    }
                }
                selected = nostr_selected;
                diagnostics = discovered_diagnostics;
            }
            Err(err) => {
                tracing::warn!("Nostr source discovery failed: {err}");
                diagnostics.available = false;
                diagnostics.error = Some(format!("{err}"));
            }
        }
        (selected, diagnostics, candidates)
    };

    let bluesky_future = async {
        let mut diagnostics = FeedProtocolDiagnostics::default();
        let mut selected = Vec::new();
        let mut candidates = Vec::new();
        match effective_bluesky_auth {
            Some(auth) => {
                tracing::info!(service_url = %auth.service_url, "World feed: Bluesky auth available, running discovery");
                let bluesky_source = BlueskyFeedSource::new(auth);
                match bluesky_source.discover_sources_with_diagnostics(&profile).await {
                    Ok((bluesky_selected, mut discovered_diagnostics)) => {
                        match bluesky_source.fetch_candidates(&profile, &bluesky_selected, limit_for_candidates()).await {
                            Ok(bluesky_candidates) => {
                                discovered_diagnostics.candidate_count = bluesky_candidates.len();
                                candidates = bluesky_candidates;
                            }
                            Err(err) => {
                                tracing::warn!("Bluesky candidate fetch failed: {err}");
                                discovered_diagnostics.candidate_count = 0;
                            }
                        }
                        selected = bluesky_selected;
                        diagnostics = discovered_diagnostics;
                    }
                    Err(err) => {
                        tracing::warn!("Bluesky source discovery failed: {err}");
                        diagnostics.available = false;
                        diagnostics.error = Some(format!("{err}"));
                    }
                }
            }
            None => {
                tracing::info!("World feed: Bluesky auth not provided, skipping Bluesky discovery");
                diagnostics.error = Some("Bluesky auth not available".to_string());
            }
        }
        (selected, diagnostics, candidates)
    };

    // Run all three protocol pipelines in parallel
    let (
        (rss_selected, rss_diagnostics, mut candidates, mut selected_sources),
        (nostr_selected, nostr_diagnostics, nostr_candidates),
        (bluesky_selected, bluesky_diagnostics, bluesky_candidates),
    ) = tokio::join!(rss_future, nostr_future, bluesky_future);

    selected_sources.extend(nostr_selected);
    selected_sources.extend(bluesky_selected);
    candidates.extend(nostr_candidates);
    candidates.extend(bluesky_candidates);

    if include_web_search && config.web_search.enabled {
        let mut web_aug = collect_web_search_augmented_candidates(
            config,
            &profile,
            &rss_selected,
            candidates.len(),
        )
        .await
        .unwrap_or_default();
        candidates.append(&mut web_aug);
    }

    tracing::info!(
        rss_scanned = rss_diagnostics.scanned_count,
        rss_shortlisted = rss_diagnostics.shortlisted_count,
        rss_candidates = rss_diagnostics.candidate_count,
        rss_error = rss_diagnostics.error.as_deref().unwrap_or("none"),
        nostr_scanned = nostr_diagnostics.scanned_count,
        nostr_shortlisted = nostr_diagnostics.shortlisted_count,
        nostr_candidates = nostr_diagnostics.candidate_count,
        nostr_error = nostr_diagnostics.error.as_deref().unwrap_or("none"),
        bluesky_scanned = bluesky_diagnostics.scanned_count,
        bluesky_shortlisted = bluesky_diagnostics.shortlisted_count,
        bluesky_candidates = bluesky_diagnostics.candidate_count,
        bluesky_error = bluesky_diagnostics.error.as_deref().unwrap_or("none"),
        total_candidates = candidates.len(),
        selected_sources = selected_sources.len(),
        "World feed: source discovery complete"
    );

    Ok(Some(PreparedWorldFeedData {
        profile,
        selected_sources,
        diagnostics: FeedRefreshDiagnostics {
            rss: rss_diagnostics,
            nostr: nostr_diagnostics,
            bluesky: bluesky_diagnostics,
            ranking: FeedRankingDiagnostics {
                candidate_count_before_ranking: candidates.len(),
                ranked_item_count: 0,
            },
        },
        candidates,
    }))
}

pub async fn load_world_feed(
    config: &Config,
    bluesky_auth: Option<BlueskyAuth>,
    limit: usize,
    force: bool,
) -> Result<PersonalizedFeedResponse> {
    let workspace_dir = &config.workspace_dir;

    // Always store the latest Bluesky auth so background tasks can use the freshest JWT,
    // even if they were spawned before this request arrived.
    if let Some(ref auth) = bluesky_auth {
        store_latest_bluesky_auth(workspace_dir, auth);
    }

    let state = local_store::get_personalized_feed_state(workspace_dir, WORLD_FEED_KEY)?
        .unwrap_or_else(default_feed_state_record);
    let cache_records =
        local_store::list_personalized_feed_cache(workspace_dir, WORLD_FEED_KEY, limit)?;
    let cached_items = deserialize_cached_items(&cache_records);
    let cache_exists = !cached_items.is_empty();
    let mut inflight = world_feed_refresh_inflight().lock().contains(workspace_dir);
    let mut refresh_state = compute_refresh_state(cache_exists, &state, inflight);

    let mut needs_refresh = force || should_refresh_world_feed(cache_exists, &state, inflight);

    // If Bluesky diagnostics show an ExpiredToken error and the caller is now providing
    // fresh auth, force a refresh to retry Bluesky discovery with the new token.
    if !needs_refresh && !inflight && bluesky_auth.is_some() {
        let prev_diagnostics = parse_refresh_diagnostics(&state.details_json);
        if let Some(ref bsky_err) = prev_diagnostics.bluesky.error {
            if bsky_err.contains("ExpiredToken") || bsky_err.contains("token") {
                needs_refresh = true;
            }
        }
    }

    if needs_refresh && !inflight {
        spawn_world_feed_refresh(config.clone(), bluesky_auth.clone());
        inflight = world_feed_refresh_inflight().lock().contains(workspace_dir);
        refresh_state = compute_refresh_state(cache_exists, &state, inflight);
    }

    let profile_status = if !state.profile_status.trim().is_empty() {
        state.profile_status.clone()
    } else if cache_exists {
        "ready".to_string()
    } else {
        "warming".to_string()
    };
    let profile_stats = parse_profile_stats(&state.profile_stats_json);
    let mut selected_sources = parse_selected_sources(&state.details_json);
    let mut diagnostics = parse_refresh_diagnostics(&state.details_json);
    let refreshed_at = non_empty_string(state.refreshed_at.clone());
    let last_error = non_empty_string(state.last_error.clone());
    let refresh_status = if state.refresh_status.trim().is_empty() {
        "idle".to_string()
    } else {
        state.refresh_status.clone()
    };

    if cache_exists {
        return Ok(PersonalizedFeedResponse {
            items: cached_items,
            profile_status: profile_status.clone(),
            profile_stats: profile_stats.clone(),
            used_fallback: false,
            message: world_feed_message(
                &profile_status,
                &profile_stats,
                &refresh_state,
                false,
                state.last_error.trim(),
            ),
            refresh_state,
            refreshed_at,
            refresh_status,
            last_error,
            selected_sources,
            diagnostics,
            generation: state.generation,
        });
    }

    match tokio::time::timeout(
        Duration::from_secs(WORLD_FEED_STAGE1_PREVIEW_TIMEOUT_SECS),
        build_prepared_world_feed_data(config, bluesky_auth.clone(), false),
    )
    .await
    {
        Ok(Ok(Some(prepared))) => {
            diagnostics = prepared.diagnostics.clone();
            selected_sources = prepared.selected_sources.clone();
            tracing::info!(
                profile_status = %prepared.profile.status,
                interest_count = prepared.profile.interests.len(),
                candidate_count = prepared.candidates.len(),
                selected_source_count = selected_sources.len(),
                "World feed keyword preview completed"
            );
            if !prepared.candidates.is_empty() {
                let preview_items =
                    build_stage1_preview_items(&prepared.profile, prepared.candidates, limit);
                if !preview_items.is_empty() {
                    return Ok(PersonalizedFeedResponse {
                        items: preview_items,
                        profile_status: prepared.profile.status.clone(),
                        profile_stats: prepared.profile.stats.clone(),
                        used_fallback: true,
                        message: Some(
                            "Showing a keyword-ranked world feed while the background refresh finishes."
                                .to_string(),
                        ),
                        refresh_state,
                        refreshed_at,
                        refresh_status,
                        last_error,
                        selected_sources: prepared.selected_sources,
                        diagnostics: prepared.diagnostics,
                        generation: state.generation,
                    });
                }
            }
        }
        Ok(Ok(None)) => {}
        Ok(Err(err)) => {
            tracing::warn!("World feed keyword preview failed: {err}");
        }
        Err(_) => {
            tracing::debug!(
                timeout_secs = WORLD_FEED_STAGE1_PREVIEW_TIMEOUT_SECS,
                "World feed keyword preview timed out, diagnostics will come from background refresh"
            );
        }
    }

    let mut fallback_items = Vec::new();
    if let Some(auth) = bluesky_auth {
        let bluesky_limit = limit
            .min(limit.saturating_div(2).max(WORLD_FEED_FALLBACK_MIN_BLUESKY_ITEMS));
        let raw_candidates =
            fetch_bluesky_fallback_candidates(&auth.service_url, &auth.access_jwt, bluesky_limit)
                .await
                .unwrap_or_default();
        let bluesky_items = build_raw_feed_items(raw_candidates, bluesky_limit);
        let recent_limit = limit.saturating_sub(bluesky_items.len().min(bluesky_limit));
        let recent_items = build_recent_content_fallback(workspace_dir, recent_limit)?;
        fallback_items.extend(recent_items);
        fallback_items.extend(bluesky_items);
        fallback_items = interleave_personalized_items_by_source(fallback_items, limit);
    } else {
        fallback_items = build_recent_content_fallback(workspace_dir, limit)?;
    }

    Ok(PersonalizedFeedResponse {
        items: fallback_items,
        profile_status,
        profile_stats,
        used_fallback: true,
        message: world_feed_message(
            if state.profile_status.trim().is_empty() {
                "warming"
            } else {
                state.profile_status.trim()
            },
            &parse_profile_stats(&state.profile_stats_json),
            &refresh_state,
            true,
            state.last_error.trim(),
        ),
        refresh_state,
        refreshed_at,
        refresh_status,
        last_error,
        selected_sources,
        diagnostics,
        generation: state.generation,
    })
}

fn spawn_world_feed_refresh(config: Config, bluesky_auth: Option<BlueskyAuth>) {
    let workspace_dir = config.workspace_dir.clone();
    if !begin_world_feed_refresh(&workspace_dir) {
        return;
    }
    tokio::spawn(async move {
        let refresh_result = refresh_world_feed(config, bluesky_auth).await;
        if let Err(err) = refresh_result {
            tracing::warn!("Failed to refresh world feed: {err}");
            record_world_feed_refresh_error(&workspace_dir, &err.to_string());
        }
        finish_world_feed_refresh(&workspace_dir);
    });
}

async fn prime_world_feed_refresh(config: Config, bluesky_auth: Option<BlueskyAuth>) {
    let workspace_dir = config.workspace_dir.clone();
    if !begin_world_feed_refresh(&workspace_dir) {
        return;
    }

    match tokio::time::timeout(
        Duration::from_secs(WORLD_FEED_COLD_START_SYNC_TIMEOUT_SECS),
        refresh_world_feed(config.clone(), bluesky_auth.clone()),
    )
    .await
    {
        Ok(Ok(())) => {
            finish_world_feed_refresh(&workspace_dir);
        }
        Ok(Err(err)) => {
            tracing::warn!("Failed to prime world feed: {err}");
            record_world_feed_refresh_error(&workspace_dir, &err.to_string());
            finish_world_feed_refresh(&workspace_dir);
        }
        Err(_) => {
            finish_world_feed_refresh(&workspace_dir);
            spawn_world_feed_refresh(config, bluesky_auth);
        }
    }
}

fn begin_world_feed_refresh(workspace_dir: &Path) -> bool {
    let mut inflight = world_feed_refresh_inflight().lock();
    if !inflight.insert(workspace_dir.to_path_buf()) {
        return false;
    }
    drop(inflight);
    mark_world_feed_refreshing(workspace_dir);
    true
}

fn finish_world_feed_refresh(workspace_dir: &Path) {
    world_feed_refresh_inflight()
        .lock()
        .remove(workspace_dir);
}

/// Write partial diagnostics to SQLite and bump generation so the frontend poll
/// picks up rolling progress numbers.
fn write_progress_diagnostics(
    workspace_dir: &Path,
    refresh_status: &str,
    profile_status: &str,
    profile_stats: &InterestProfileStats,
    diagnostics: &FeedRefreshDiagnostics,
    selected_sources: &[serde_json::Value],
    refresh_started_at: &str,
) {
    let now = Utc::now().to_rfc3339();
    let _ = local_store::upsert_personalized_feed_state(
        workspace_dir,
        &local_store::PersonalizedFeedStateUpsert {
            feed_key: WORLD_FEED_KEY.to_string(),
            dirty: true,
            refresh_status: refresh_status.to_string(),
            refreshed_at: now.clone(),
            refresh_started_at: refresh_started_at.to_string(),
            refresh_finished_at: String::new(),
            last_error: String::new(),
            profile_status: profile_status.to_string(),
            profile_stats_json: serde_json::json!(profile_stats).to_string(),
            details_json: serde_json::json!({
                "selectedSources": selected_sources,
                "diagnostics": diagnostics,
            })
            .to_string(),
        },
    );
    let _ = local_store::bump_feed_generation(workspace_dir, WORLD_FEED_KEY);
}

async fn refresh_world_feed(config: Config, bluesky_auth: Option<BlueskyAuth>) -> Result<()> {
    let workspace_dir = config.workspace_dir.clone();
    let Some(mut prepared) = build_prepared_world_feed_data(&config, bluesky_auth, true).await? else {
        return Ok(());
    };

    let now = Utc::now().to_rfc3339();
    if prepared.profile.interests.is_empty() || prepared.profile.status != "ready" {
        local_store::replace_personalized_feed_cache(&workspace_dir, WORLD_FEED_KEY, &[])?;
        let _ = local_store::upsert_personalized_feed_state(
            &workspace_dir,
            &local_store::PersonalizedFeedStateUpsert {
                feed_key: WORLD_FEED_KEY.to_string(),
                dirty: false,
                refresh_status: "idle".to_string(),
                refreshed_at: now.clone(),
                refresh_started_at: now.clone(),
                refresh_finished_at: now.clone(),
                last_error: String::new(),
                profile_status: prepared.profile.status.clone(),
                profile_stats_json: serde_json::json!(prepared.profile.stats).to_string(),
                details_json: serde_json::json!({
                    "selectedSources": [],
                    "diagnostics": prepared.diagnostics,
                })
                .to_string(),
            },
        )?;
        return Ok(());
    }
    let selected_sources_json: Vec<serde_json::Value> = prepared
        .selected_sources
        .iter()
        .map(selected_source_summary)
        .collect();

    // ── Progress: Write discovery diagnostics so frontend sees live counts ──
    write_progress_diagnostics(
        &workspace_dir,
        "discovering",
        &prepared.profile.status,
        &prepared.profile.stats,
        &prepared.diagnostics,
        &selected_sources_json,
        &now,
    );

    let final_items = rank_candidates_stage2(
        &prepared.profile,
        prepared.candidates,
        WORLD_FEED_RANK_LIMIT,
    );

    prepared.diagnostics.ranking.ranked_item_count = final_items.len();
    let refreshed_at = Utc::now().to_rfc3339();
    let cache_rows = build_cache_rows(&final_items, &refreshed_at);
    local_store::replace_personalized_feed_cache(&workspace_dir, WORLD_FEED_KEY, &cache_rows)?;
    let _ = local_store::bump_feed_generation(&workspace_dir, WORLD_FEED_KEY);
    local_store::upsert_personalized_feed_state(
        &workspace_dir,
        &local_store::PersonalizedFeedStateUpsert {
            feed_key: WORLD_FEED_KEY.to_string(),
            dirty: false,
            refresh_status: "idle".to_string(),
            refreshed_at: refreshed_at.clone(),
            refresh_started_at: now,
            refresh_finished_at: refreshed_at.clone(),
            last_error: String::new(),
            profile_status: prepared.profile.status.clone(),
            profile_stats_json: serde_json::json!(prepared.profile.stats).to_string(),
            details_json: serde_json::json!({
                "selectedSources": selected_sources_json,
                "diagnostics": prepared.diagnostics,
            })
            .to_string(),
        },
    )?;
    Ok(())
}

fn build_cache_rows(
    items: &[PersonalizedFeedItem],
    refreshed_at: &str,
) -> Vec<local_store::PersonalizedFeedCacheUpsert> {
    items
        .iter()
        .enumerate()
        .map(|(index, item)| local_store::PersonalizedFeedCacheUpsert {
            feed_key: WORLD_FEED_KEY.to_string(),
            cache_key: cache_item_key(item, index),
            payload_json: serde_json::to_string(item).unwrap_or_else(|_| "{}".to_string()),
            score: f64::from(item.score.unwrap_or(0.0)),
            sort_order: i64::try_from(index).unwrap_or(0),
            refreshed_at: refreshed_at.to_string(),
        })
        .collect()
}

fn mark_world_feed_refreshing(workspace_dir: &Path) {
    let current = local_store::get_personalized_feed_state(workspace_dir, WORLD_FEED_KEY)
        .ok()
        .flatten()
        .unwrap_or_else(default_feed_state_record);
    let started_at = Utc::now().to_rfc3339();
    let _ = local_store::upsert_personalized_feed_state(
        workspace_dir,
        &local_store::PersonalizedFeedStateUpsert {
            feed_key: WORLD_FEED_KEY.to_string(),
            dirty: true,
            refresh_status: "refreshing".to_string(),
            refreshed_at: current.refreshed_at,
            refresh_started_at: started_at,
            refresh_finished_at: current.refresh_finished_at,
            last_error: String::new(),
            profile_status: current.profile_status,
            profile_stats_json: if current.profile_stats_json.trim().is_empty() {
                "{}".to_string()
            } else {
                current.profile_stats_json
            },
            details_json: if current.details_json.trim().is_empty() {
                "{}".to_string()
            } else {
                current.details_json
            },
        },
    );
}

fn record_world_feed_refresh_error(workspace_dir: &Path, error: &str) {
    let current = local_store::get_personalized_feed_state(workspace_dir, WORLD_FEED_KEY)
        .ok()
        .flatten()
        .unwrap_or_else(default_feed_state_record);
    let finished_at = Utc::now().to_rfc3339();
    let _ = local_store::upsert_personalized_feed_state(
        workspace_dir,
        &local_store::PersonalizedFeedStateUpsert {
            feed_key: WORLD_FEED_KEY.to_string(),
            dirty: true,
            refresh_status: "error".to_string(),
            refreshed_at: current.refreshed_at,
            refresh_started_at: current.refresh_started_at,
            refresh_finished_at: finished_at,
            last_error: truncate_with_ellipsis(error.trim(), 1_000),
            profile_status: current.profile_status,
            profile_stats_json: if current.profile_stats_json.trim().is_empty() {
                "{}".to_string()
            } else {
                current.profile_stats_json
            },
            details_json: if current.details_json.trim().is_empty() {
                "{}".to_string()
            } else {
                current.details_json
            },
        },
    );
}

fn world_feed_refresh_inflight() -> &'static Mutex<HashSet<PathBuf>> {
    static INFLIGHT: OnceLock<Mutex<HashSet<PathBuf>>> = OnceLock::new();
    INFLIGHT.get_or_init(|| Mutex::new(HashSet::new()))
}

/// Stores the most recent Bluesky auth per workspace so that background refresh
/// tasks always use the freshest JWT, even if they were spawned with an older one.
fn latest_bluesky_auth_store() -> &'static Mutex<HashMap<PathBuf, BlueskyAuth>> {
    static STORE: OnceLock<Mutex<HashMap<PathBuf, BlueskyAuth>>> = OnceLock::new();
    STORE.get_or_init(|| Mutex::new(HashMap::new()))
}

fn store_latest_bluesky_auth(workspace_dir: &Path, auth: &BlueskyAuth) {
    latest_bluesky_auth_store()
        .lock()
        .insert(workspace_dir.to_path_buf(), auth.clone());
}

fn take_latest_bluesky_auth(workspace_dir: &Path) -> Option<BlueskyAuth> {
    latest_bluesky_auth_store().lock().get(workspace_dir).cloned()
}

fn default_feed_state_record() -> local_store::PersonalizedFeedStateRecord {
    local_store::PersonalizedFeedStateRecord {
        feed_key: WORLD_FEED_KEY.to_string(),
        dirty: true,
        refresh_status: "idle".to_string(),
        refreshed_at: String::new(),
        refresh_started_at: String::new(),
        refresh_finished_at: String::new(),
        last_error: String::new(),
        profile_status: String::new(),
        profile_stats_json: "{}".to_string(),
        details_json: "{}".to_string(),
        updated_at: String::new(),
        generation: 0,
    }
}

fn compute_refresh_state(
    cache_exists: bool,
    state: &local_store::PersonalizedFeedStateRecord,
    inflight: bool,
) -> String {
    if inflight {
        return if cache_exists {
            "refreshing".to_string()
        } else {
            "warming".to_string()
        };
    }
    if state.refresh_status == "refreshing" {
        return if cache_exists {
            "stale".to_string()
        } else {
            "warming".to_string()
        };
    }
    if cache_exists {
        if state.dirty || state_is_stale(&state.refreshed_at) {
            return "stale".to_string();
        }
        return "fresh".to_string();
    }
    if !state.dirty && !state.profile_status.trim().is_empty() && !state_is_stale(&state.refreshed_at) {
        "fresh".to_string()
    } else {
        "warming".to_string()
    }
}

fn should_refresh_world_feed(
    cache_exists: bool,
    state: &local_store::PersonalizedFeedStateRecord,
    inflight: bool,
) -> bool {
    if inflight {
        return false;
    }
    if state.refresh_status == "refreshing" {
        return true;
    }
    if cache_exists {
        return state.dirty || state_is_stale(&state.refreshed_at);
    }
    state.dirty || state.refreshed_at.trim().is_empty() || state_is_stale(&state.refreshed_at)
}

fn state_is_stale(refreshed_at: &str) -> bool {
    chrono::DateTime::parse_from_rfc3339(refreshed_at.trim())
        .ok()
        .map(|value| Utc::now().signed_duration_since(value.with_timezone(&Utc)).num_seconds())
        .map(|age| age < 0 || age > WORLD_FEED_CACHE_TTL_SECS)
        .unwrap_or(true)
}

fn parse_profile_stats(raw: &str) -> InterestProfileStats {
    serde_json::from_str(raw).unwrap_or_default()
}

fn parse_selected_sources(raw: &str) -> Vec<SelectedSource> {
    let Ok(value) = serde_json::from_str::<serde_json::Value>(raw) else {
        return Vec::new();
    };
    let items = value
        .get("selectedSources")
        .and_then(serde_json::Value::as_array)
        .cloned()
        .unwrap_or_default();
    items
        .into_iter()
        .filter_map(|item| serde_json::from_value::<SelectedSource>(item).ok())
        .collect()
}

fn parse_refresh_diagnostics(raw: &str) -> FeedRefreshDiagnostics {
    let Ok(value) = serde_json::from_str::<serde_json::Value>(raw) else {
        return FeedRefreshDiagnostics::default();
    };
    value
        .get("diagnostics")
        .cloned()
        .and_then(|item| serde_json::from_value::<FeedRefreshDiagnostics>(item).ok())
        .unwrap_or_default()
}

fn deserialize_cached_items(
    records: &[local_store::PersonalizedFeedCacheRecord],
) -> Vec<PersonalizedFeedItem> {
    records
        .iter()
        .filter_map(|record| serde_json::from_str::<PersonalizedFeedItem>(&record.payload_json).ok())
        .collect()
}

fn world_feed_message(
    profile_status: &str,
    profile_stats: &InterestProfileStats,
    refresh_state: &str,
    used_fallback: bool,
    last_error: &str,
) -> Option<String> {
    if profile_status.eq_ignore_ascii_case("noInterests") {
        return Some("Personalized feed starts after text items exist under posts/ or journals/.".to_string());
    }
    if !last_error.trim().is_empty() && used_fallback {
        return Some(format!(
            "Updating the world feed failed recently. Showing fallback items. {}",
            truncate_with_ellipsis(last_error.trim(), 240)
        ));
    }
    if refresh_state == "refreshing" || refresh_state == "stale" {
        return Some("Updating the world feed in the background. Showing the last ranked results.".to_string());
    }
    if used_fallback {
        if profile_status.eq_ignore_ascii_case("ready") && refresh_state == "fresh" {
            return Some(
                "No keyword-ranked world-feed matches landed yet. Showing recent sources while the next refresh widens the search."
                    .to_string(),
            );
        }
        return Some("Building your world feed. Showing recent cached sources while keyword ranking catches up.".to_string());
    }
    if profile_stats.interest_count > 0 {
        return Some(format!(
            "Personalized by {} weighted keywords.",
            profile_stats.interest_count
        ));
    }
    None
}

fn append_feed_items_up_to_limit(
    target: &mut Vec<PersonalizedFeedItem>,
    mut extra: Vec<PersonalizedFeedItem>,
    limit: usize,
) {
    if target.len() >= limit {
        return;
    }
    let remaining = limit - target.len();
    extra.truncate(remaining);
    target.extend(extra);
}

fn interleave_personalized_items_by_source(
    items: Vec<PersonalizedFeedItem>,
    limit: usize,
) -> Vec<PersonalizedFeedItem> {
    if items.len() <= 2 {
        return items.into_iter().take(limit).collect();
    }

    let mut buckets: Vec<(String, Vec<PersonalizedFeedItem>)> = Vec::new();
    for item in items {
        let source_key = candidate_source_mix_key(&item);
        if let Some((_, bucket)) = buckets.iter_mut().find(|(key, _)| key == &source_key) {
            bucket.push(item);
        } else {
            buckets.push((source_key, vec![item]));
        }
    }

    if buckets.len() <= 1 {
        return buckets
            .into_iter()
            .flat_map(|(_, bucket)| bucket)
            .take(limit)
            .collect();
    }

    let mut interleaved = Vec::new();
    loop {
        let mut advanced = false;
        for (_, bucket) in &mut buckets {
            if bucket.is_empty() {
                continue;
            }
            interleaved.push(bucket.remove(0));
            advanced = true;
            if interleaved.len() >= limit {
                return interleaved;
            }
        }
        if !advanced {
            break;
        }
    }
    interleaved
}

fn build_stage1_preview_items(
    profile: &FeedProfile,
    candidates: Vec<FeedCandidate>,
    limit: usize,
) -> Vec<PersonalizedFeedItem> {
    rank_candidates_stage2(profile, candidates, limit)
}

fn cache_item_key(item: &PersonalizedFeedItem, index: usize) -> String {
    item.feed_item
        .get("url")
        .and_then(serde_json::Value::as_str)
        .map(ToOwned::to_owned)
        .or_else(|| {
            item.feed_item
                .get("post")
                .and_then(|post| post.get("uri"))
                .and_then(serde_json::Value::as_str)
                .map(ToOwned::to_owned)
        })
        .unwrap_or_else(|| format!("item-{index}"))
}

fn selected_source_summary(source: &SelectedSource) -> serde_json::Value {
    serde_json::json!({
        "protocol": source.protocol,
        "key": source.key,
        "label": source.label,
        "score": source.stage1_score,
        "description": source.description,
        "matchedInterestLabel": source.matched_interest_label,
        "matchedInterestScore": source.matched_interest_score,
        "metadata": source.metadata_json,
    })
}

fn limit_for_candidates() -> usize {
    96
}

fn build_recent_content_fallback(workspace_dir: &Path, limit: usize) -> Result<Vec<PersonalizedFeedItem>> {
    let items = local_store::list_recent_content_items(workspace_dir, limit)?;
    Ok(items
        .into_iter()
        .filter(|item| !item.canonical_url.trim().is_empty())
        .map(|item| {
            let preview = build_content_preview(&item);
            PersonalizedFeedItem {
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
                feed_source: Some(FeedSourceContext {
                    label: item.source_title,
                    description: Some(format!("RSS/Atom source from {}", item.domain)),
                    matched_interest_label: None,
                    matched_interest_score: None,
                    source_score: None,
                }),
                score: None,
                matched_interest_label: None,
                matched_interest_score: None,
                passed_threshold: false,
            }
        })
        .collect())
}

fn configured_nostr_world_feed_relays(config: &Config) -> Vec<String> {
    let configured = config
        .channels_config
        .nostr
        .as_ref()
        .map(|nostr| nostr.relays.clone())
        .filter(|relays| !relays.is_empty())
        .unwrap_or_else(crate::config::schema::default_nostr_relays);
    let mut seen = BTreeSet::new();
    configured
        .into_iter()
        .map(|relay| relay.trim().to_string())
        .filter(|relay| {
            if relay.is_empty() {
                return false;
            }
            let lower = relay.to_ascii_lowercase();
            if !(lower.starts_with("ws://") || lower.starts_with("wss://")) {
                return false;
            }
            seen.insert(lower)
        })
        .collect()
}

fn fallback_nostr_world_feed_relays(config: &Config) -> Vec<String> {
    let mut relays = configured_nostr_world_feed_relays(config);
    if !relays
        .iter()
        .any(|relay| relay.eq_ignore_ascii_case(NOSTR_PRIMAL_FALLBACK_RELAY))
    {
        relays.insert(0, NOSTR_PRIMAL_FALLBACK_RELAY.to_string());
    }
    relays.truncate(NOSTR_SELECTED_RELAY_LIMIT.max(1));
    relays
}

fn fallback_nostr_selected_source(relay_url: &str) -> SelectedSource {
    let relay_http_url = nostr_relay_http_url(relay_url).unwrap_or_default();
    SelectedSource {
        protocol: FeedProtocol::Nostr,
        key: relay_url.to_string(),
        label: nostr_relay_label(relay_url, None),
        stage1_score: 0.2,
        description: Some("Fallback Nostr relay while interest-matched relays warm up.".to_string()),
        matched_interest_label: None,
        matched_interest_score: None,
        metadata_json: serde_json::json!({
            "relayUrl": relay_url,
            "domain": resolve_feed_web_domain(&relay_http_url).unwrap_or_default(),
        }),
    }
}

fn fallback_nostr_selected_sources(config: &Config) -> Vec<SelectedSource> {
    fallback_nostr_world_feed_relays(config)
        .into_iter()
        .map(|relay| fallback_nostr_selected_source(&relay))
        .collect()
}

async fn fetch_nip66_relay_candidates(
    seed_relays: &[String],
    keyword_weights: &[(String, f32)],
) -> Result<Vec<SelectedSource>> {
    if seed_relays.is_empty() || keyword_weights.is_empty() {
        return Ok(Vec::new());
    }

    let client = NostrClient::default();
    let mut connected_relays = Vec::new();
    for relay in seed_relays {
        if client.add_relay(relay).await.is_ok()
            && client
                .try_connect_relay(relay, Duration::from_secs(NOSTR_RELAY_CONNECT_TIMEOUT_SECS))
                .await
                .is_ok()
        {
            connected_relays.push(relay.clone());
        }
    }
    if connected_relays.is_empty() {
        return Ok(Vec::new());
    }

    let filter = NostrFilter::new()
        .kind(NostrKind::from(NOSTR_NIP66_DISCOVERY_KIND))
        .since(NostrTimestamp::from_secs(
            Utc::now().timestamp().saturating_sub(NOSTR_LOOKBACK_SECS as i64) as u64,
        ))
        .limit(NOSTR_NIP66_DISCOVERY_EVENT_LIMIT);
    let events = client
        .fetch_events_from(
            connected_relays.iter().map(String::as_str),
            filter,
            Duration::from_secs(NOSTR_EVENT_FETCH_TIMEOUT_SECS),
        )
        .await?;
    let _ = tokio::time::timeout(Duration::from_secs(2), client.shutdown()).await;

    let mut selected = Vec::new();
    let mut seen = HashSet::new();
    for event in events {
        let mut relay_url = event.tags.identifier().unwrap_or("").trim().to_string();
        let mut relay_tags = Vec::new();
        for tag in event.tags.iter() {
            let values = tag.as_slice();
            if values.is_empty() {
                continue;
            }
            if values[0] == "r" && values.len() > 1 && relay_url.is_empty() {
                relay_url = values[1].trim().to_string();
            }
            if values[0] == "t" && values.len() > 1 {
                relay_tags.push(values[1].trim().to_string());
            }
        }
        if relay_url.is_empty() || !seen.insert(relay_url.clone()) {
            continue;
        }
        let label = resolve_feed_web_domain(&nostr_relay_http_url(&relay_url).unwrap_or_default())
            .unwrap_or_else(|| relay_url.clone());
        let search_text = format!(
            "{}\n{}\n{}",
            label,
            event.content.trim(),
            relay_tags.join(" ")
        );
        let (keyword_score, matched_keyword) =
            keyword_weight_sum(&search_text, keyword_weights);
        if keyword_score <= 0.0 {
            continue;
        }
        selected.push(SelectedSource {
            protocol: FeedProtocol::Nostr,
            key: relay_url.clone(),
            label,
            stage1_score: keyword_score,
            description: non_empty_string(event.content.trim().to_string()),
            matched_interest_label: matched_keyword,
            matched_interest_score: Some(keyword_score),
            metadata_json: serde_json::json!({
                "relayUrl": relay_url,
                "tags": relay_tags,
                "nip66": true,
            }),
        });
    }
    selected.sort_by(|left, right| {
        right
            .stage1_score
            .partial_cmp(&left.stage1_score)
            .unwrap_or(Ordering::Equal)
    });
    selected.truncate(NOSTR_SELECTED_RELAY_LIMIT);
    Ok(selected)
}

fn nostr_relay_http_url(relay_url: &str) -> Option<String> {
    let trimmed = relay_url.trim();
    if trimmed.is_empty() {
        return None;
    }
    if let Some(rest) = trimmed.strip_prefix("wss://") {
        return Some(format!("https://{rest}"));
    }
    if let Some(rest) = trimmed.strip_prefix("ws://") {
        return Some(format!("http://{rest}"));
    }
    None
}

async fn fetch_nostr_relay_metadata(relay_url: &str) -> Result<Option<nostr_sdk::prelude::RelayInformationDocument>> {
    let Some(http_url) = nostr_relay_http_url(relay_url) else {
        return Ok(None);
    };
    let response = reqwest::Client::builder()
        .timeout(Duration::from_secs(NOSTR_RELAY_METADATA_TIMEOUT_SECS))
        .build()?
        .get(&http_url)
        .header("Accept", "application/nostr+json")
        .send()
        .await
        .with_context(|| format!("Failed to fetch Nostr relay metadata from {relay_url}"))?;
    if !response.status().is_success() {
        return Ok(None);
    }
    let body = response.text().await?;
    let metadata = serde_json::from_str::<nostr_sdk::prelude::RelayInformationDocument>(&body)
        .with_context(|| format!("Failed to parse Nostr relay metadata from {relay_url}"))?;
    Ok(Some(metadata))
}

fn nostr_relay_label(
    relay_url: &str,
    metadata: Option<&nostr_sdk::prelude::RelayInformationDocument>,
) -> String {
    metadata
        .and_then(|doc| doc.name.clone())
        .filter(|value| !value.trim().is_empty())
        .or_else(|| resolve_feed_web_domain(&nostr_relay_http_url(relay_url).unwrap_or_default()))
        .unwrap_or_else(|| relay_url.to_string())
}

fn nostr_relay_description(
    metadata: Option<&nostr_sdk::prelude::RelayInformationDocument>,
) -> Option<String> {
    let description = metadata
        .and_then(|doc| doc.description.clone())
        .filter(|value| !value.trim().is_empty());
    if description.is_some() {
        return description;
    }
    metadata.and_then(|doc| {
        let software = doc.software.clone().unwrap_or_default();
        let version = doc.version.clone().unwrap_or_default();
        let summary = format!("{} {}", software.trim(), version.trim())
            .trim()
            .to_string();
        if summary.is_empty() {
            None
        } else {
            Some(summary)
        }
    })
}

fn nostr_relay_search_text(
    relay_url: &str,
    metadata: Option<&nostr_sdk::prelude::RelayInformationDocument>,
) -> String {
    let mut parts = Vec::new();
    parts.push(nostr_relay_label(relay_url, metadata));
    if let Some(description) = nostr_relay_description(metadata) {
        parts.push(description);
    }
    if let Some(doc) = metadata {
        if !doc.tags.is_empty() {
            parts.push(doc.tags.join(", "));
        }
        if !doc.language_tags.is_empty() {
            parts.push(doc.language_tags.join(", "));
        }
        if let Some(pubkey) = doc.pubkey.clone().filter(|value| !value.trim().is_empty()) {
            parts.push(pubkey);
        }
    }
    parts.join("\n")
}

async fn fetch_nostr_text_notes(relay_url: &str, limit: usize) -> Result<Vec<NostrEvent>> {
    let client = NostrClient::default();
    client.add_relay(relay_url).await?;
    client
        .try_connect_relay(relay_url, Duration::from_secs(NOSTR_RELAY_CONNECT_TIMEOUT_SECS))
        .await?;
    let filter = NostrFilter::new()
        .kind(NostrKind::TextNote)
        .since(NostrTimestamp::from_secs(
            Utc::now().timestamp().saturating_sub(NOSTR_LOOKBACK_SECS as i64) as u64,
        ))
        .limit(limit);
    let events = client
        .fetch_events_from(
            [relay_url],
            filter,
            Duration::from_secs(NOSTR_EVENT_FETCH_TIMEOUT_SECS),
        )
        .await?;
    let _ = tokio::time::timeout(Duration::from_secs(2), client.shutdown()).await;
    let mut out: Vec<NostrEvent> = events.into_iter().collect();
    out.sort_by(|left, right| right.created_at.cmp(&left.created_at));
    Ok(out)
}

fn nostr_event_permalink(event: &NostrEvent) -> String {
    event
        .to_bech32()
        .map(|bech32| format!("https://njump.me/{bech32}"))
        .unwrap_or_else(|_| format!("https://njump.me/{}", event.id.to_hex()))
}

fn nostr_timestamp_to_rfc3339(timestamp: NostrTimestamp) -> String {
    Utc.timestamp_opt(timestamp.as_secs() as i64, 0)
        .single()
        .map(|value| value.to_rfc3339())
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
        content_text: item.content_text.trim().to_string(),
        image_url: None,
        domain: item.domain.clone(),
        provider: "RSS/Atom".to_string(),
        provider_snippet: non_empty_string(item.source_title.clone()),
        discovered_at: content_preview_timestamp(item),
    }
}

fn content_preview_timestamp(item: &local_store::ContentItemRecord) -> String {
    non_empty_string(item.published_at.clone())
        .or_else(|| non_empty_string(item.discovered_at.clone()))
        .or_else(|| non_empty_string(item.updated_at.clone()))
        .unwrap_or_default()
}

fn non_empty_string(value: String) -> Option<String> {
    let trimmed = value.trim();
    if trimmed.is_empty() {
        None
    } else {
        Some(trimmed.to_string())
    }
}

fn feed_interest_to_diagnostic(
    _workspace_dir: &Path,
    record: local_store::FeedKeywordRecord,
) -> FeedInterestDiagnosticItem {
    FeedInterestDiagnosticItem {
        id: record.id,
        label: record.term.clone(),
        source_path: String::new(),
        health_score: record.weight,
        last_seen_at: record.last_seen_at,
        created_at: record.first_seen_at,
        updated_at: record.updated_at,
        embedding_dimensions: 0,
        synthetic: false,
        deletable: true,
        keywords: vec![record.term],
        keywords_override: None,
    }
}

pub fn list_world_feed_interest_diagnostics(
    config: &Config,
) -> Result<FeedInterestDiagnosticsResponse> {
    let items = local_store::list_feed_keywords(&config.workspace_dir)?
        .into_iter()
        .map(|record| feed_interest_to_diagnostic(&config.workspace_dir, record))
        .collect();
    Ok(FeedInterestDiagnosticsResponse { items })
}

pub async fn create_dummy_world_feed_interest(
    config: &Config,
    label: &str,
) -> Result<FeedInterestDiagnosticItem> {
    let normalized_label = label.trim();
    if normalized_label.is_empty() {
        anyhow::bail!("Interest label is required");
    }
    let now = Utc::now().to_rfc3339();
    let record = local_store::upsert_feed_keyword(
        &config.workspace_dir,
        &local_store::FeedKeywordUpsert {
            id: None,
            term: normalized_label.to_ascii_lowercase(),
            weight: 1.0,
            first_seen_at: now.clone(),
            last_seen_at: now,
            source_count: 1,
        },
    )?;
    mark_world_feed_dirty(&config.workspace_dir)?;
    Ok(feed_interest_to_diagnostic(&config.workspace_dir, record))
}

pub fn delete_world_feed_interest(config: &Config, interest_id: &str) -> Result<bool> {
    let deleted = local_store::delete_feed_keyword(&config.workspace_dir, interest_id)?;
    if deleted {
        mark_world_feed_dirty(&config.workspace_dir)?;
    }
    Ok(deleted)
}

pub async fn update_world_feed_interest(
    config: &Config,
    interest_id: &str,
    label: Option<&str>,
    keywords_override: Option<Vec<String>>,
) -> Result<Option<FeedInterestDiagnosticItem>> {
    let interest = local_store::list_feed_keywords(&config.workspace_dir)?
        .into_iter()
        .find(|item| item.id == interest_id);
    let Some(interest) = interest else {
        return Ok(None);
    };

    if let Some(new_label) = label {
        let trimmed = new_label.trim();
        if !trimmed.is_empty() && trimmed != interest.term {
            local_store::update_feed_keyword_term(
                &config.workspace_dir,
                interest_id,
                &trimmed.to_ascii_lowercase(),
            )?;
        }
    }

    if let Some(kw) = keywords_override {
        let first = kw
            .iter()
            .map(|keyword| keyword.trim())
            .find(|keyword| !keyword.is_empty())
            .unwrap_or("");
        if !first.is_empty() {
            local_store::update_feed_keyword_term(
                &config.workspace_dir,
                interest_id,
                &first.to_ascii_lowercase(),
            )?;
        }
    }

    mark_world_feed_dirty(&config.workspace_dir)?;
    let updated = local_store::list_feed_keywords(&config.workspace_dir)?
        .into_iter()
        .find(|item| item.id == interest_id)
        .map(|record| feed_interest_to_diagnostic(&config.workspace_dir, record));
    Ok(updated)
}

async fn select_feed_embedder(config: &Config) -> Result<Option<SharedEmbedder>> {
    let configured = memory::create_embedder_from_config(config);
    if configured.dimensions() == 0 {
        return Ok(None);
    }

    match configured.embed_one("feed profile probe").await {
        Ok(embedding) if !embedding.is_empty() => Ok(Some(configured)),
        Ok(_) => Ok(None),
        Err(err) => {
            tracing::warn!(
                provider = config.memory.embedding_provider.trim(),
                model = config.memory.embedding_model.trim(),
                error = %err,
                "Feed embedder probe failed — world feed will not be personalized until this is resolved"
            );
            Ok(None)
        }
    }
}

async fn resolve_feed_embedder(
    config: &Config,
) -> Result<(Option<SharedEmbedder>, Option<String>)> {
    if config.memory.embedding_provider.trim().eq_ignore_ascii_case("none") {
        return Ok((
            None,
            Some(
                "Personalized feed embeddings are disabled in [memory].".to_string(),
            ),
        ));
    }

    if let Some(embedder) = select_feed_embedder(config).await? {
        return Ok((Some(embedder), None));
    }

    Ok((
        None,
        Some("Configured embedding provider is unavailable.".to_string()),
    ))
}

async fn rebuild_interest_profile(config: &Config) -> Result<FeedProfile> {
    let workspace_dir = &config.workspace_dir;
    let _ = local_store::decay_feed_keywords(workspace_dir, KEYWORD_PROFILE_DECAY_RATE)?;
    let mut active_keywords: HashMap<String, local_store::FeedKeywordRecord> = local_store::list_feed_keywords(workspace_dir)?
        .into_iter()
        .map(|record| (record.term.clone(), record))
        .collect();

    let text_sources = collect_post_text_sources(workspace_dir)?;
    tracing::info!(
        source_count = text_sources.len(),
        workspace = %workspace_dir.display(),
        "World feed: collected text sources from posts/ and journals/"
    );
    let mut stats = InterestProfileStats {
        source_count: text_sources.len(),
        ..InterestProfileStats::default()
    };

    let mut changed_sources = Vec::new();
    for source in text_sources {
        let previous = local_store::get_feed_interest_source(workspace_dir, &source.source_path)?;
        let triage_keywords = previous
            .as_ref()
            .map(|record| normalize_stored_triage_keywords(&record.triage_keywords_json))
            .unwrap_or_default();
        let (extracted_keywords, keyword_mode) = if triage_keywords.is_empty() {
            (
                extract_weighted_profile_keywords(&source.title, &source.content),
                "local",
            )
        } else {
            (triage_keywords, "triage")
        };
        let profile_input_hash =
            profile_keyword_input_hash(&source.content_hash, keyword_mode, &extracted_keywords);
        if let Some(previous) = previous.as_ref() {
            if previous.profile_input_hash == profile_input_hash {
                continue;
            }
        }
        changed_sources.push((source, previous, extracted_keywords, profile_input_hash));
    }

    for (source, previous, extracted_keywords, profile_input_hash) in changed_sources {
        let now = Utc::now().to_rfc3339();
        if extracted_keywords.is_empty() {
            stats.ignored_count += 1;
        } else {
            stats.refreshed_sources += 1;
        }
        for (term, increment) in extracted_keywords {
            let existing = active_keywords.get(&term);
            let weight = existing
                .map(|record| record.weight)
                .unwrap_or(0.0)
                .min(KEYWORD_PROFILE_MAX_WEIGHT);
            let next_weight = (weight + increment).min(KEYWORD_PROFILE_MAX_WEIGHT);
            let first_seen_at = existing
                .map(|record| record.first_seen_at.clone())
                .unwrap_or_else(|| now.clone());
            let source_count = existing
                .map(|record| record.source_count + 1)
                .unwrap_or(1);
            let saved = local_store::upsert_feed_keyword(
                workspace_dir,
                &local_store::FeedKeywordUpsert {
                    id: existing.map(|record| record.id.clone()),
                    term: term.clone(),
                    weight: next_weight,
                    first_seen_at,
                    last_seen_at: now.clone(),
                    source_count,
                },
            )?;
            active_keywords.insert(term, saved);
        }

        local_store::upsert_feed_interest_source(
            workspace_dir,
            &local_store::FeedInterestSourceRecord {
                source_path: source.source_path,
                content_hash: source.content_hash,
                profile_input_hash,
                interest_id: None,
                title: derive_interest_label(&source.title, &source.content),
                triage_keywords_json: previous
                    .as_ref()
                    .map(|record| record.triage_keywords_json.clone())
                    .unwrap_or_default(),
                updated_at: now,
            },
        )?;
    }

    let _ = local_store::prune_feed_keywords(
        workspace_dir,
        KEYWORD_PROFILE_MIN_WEIGHT,
        KEYWORD_PROFILE_LIMIT,
    )?;
    let active_keywords = local_store::list_feed_keywords(workspace_dir)?;
    stats.interest_count = active_keywords.len();
    Ok(FeedProfile {
        status: if active_keywords.is_empty() {
            "noInterests".to_string()
        } else {
            "ready".to_string()
        },
        stats,
        interests: active_keywords
            .into_iter()
            .map(|keyword| InterestVector {
                id: keyword.id,
                label: keyword.term.clone(),
                embedding: Vec::new(),
                health_score: keyword.weight as f32,
                source_path: String::new(),
                keywords: vec![keyword.term],
            })
            .collect(),
    })
}

#[derive(Debug, Clone)]
struct PostTextSource {
    source_path: String,
    title: String,
    content: String,
    content_hash: String,
}

fn collect_post_text_sources(workspace_dir: &Path) -> Result<Vec<PostTextSource>> {
    let mut out = Vec::new();
    // Scan posts/ for AI-extracted/curated interest items.
    let posts_root = workspace_dir.join("posts");
    collect_post_text_sources_recursive(workspace_dir, &posts_root, &mut out)?;
    // Also scan journals/ for raw daily entries which provide broader interest
    // signals even before AI extraction has run.
    let journals_root = workspace_dir.join("journals");
    collect_post_text_sources_recursive(workspace_dir, &journals_root, &mut out)?;
    Ok(out)
}

fn collect_post_text_sources_recursive(
    workspace_dir: &Path,
    dir: &Path,
    out: &mut Vec<PostTextSource>,
) -> Result<()> {
    if !dir.exists() {
        return Ok(());
    }
    let mut entries: Vec<_> = std::fs::read_dir(dir)
        .with_context(|| format!("Failed to read {}", dir.display()))?
        .filter_map(|entry| entry.ok())
        .collect();
    entries.sort_by_key(|entry| entry.path());
    for entry in entries {
        let path = entry.path();
        let meta = match entry.metadata() {
            Ok(meta) => meta,
            Err(_) => continue,
        };
        if meta.is_dir() {
            collect_post_text_sources_recursive(workspace_dir, &path, out)?;
            continue;
        }
        if !is_post_text_file(&path) {
            continue;
        }
        let content = match std::fs::read_to_string(&path) {
            Ok(content) => content,
            Err(_) => continue,
        };
        let trimmed = content.trim();
        if trimmed.is_empty() {
            continue;
        }
        let rel = path
            .strip_prefix(workspace_dir)
            .ok()
            .map(|value| value.to_string_lossy().replace('\\', "/"))
            .unwrap_or_else(|| path.to_string_lossy().replace('\\', "/"));
        let title = path
            .file_stem()
            .map(|value| value.to_string_lossy().replace(['_', '-'], " "))
            .unwrap_or_else(|| "Workspace interest".to_string());
        out.push(PostTextSource {
            source_path: rel,
            title,
            content: trimmed.to_string(),
            content_hash: content_hash_16(trimmed),
        });
    }
    Ok(())
}

fn is_post_text_file(path: &Path) -> bool {
    matches!(
        path.extension().and_then(|value| value.to_str()).map(|value| value.to_ascii_lowercase()),
        Some(ext) if matches!(ext.as_str(), "md" | "markdown" | "txt")
    )
}

fn label_looks_auto_generated(label: &str) -> bool {
    let normalized = normalize_label_for_quality_checks(label);
    if normalized.is_empty() {
        return true;
    }

    if normalized.chars().all(|ch| ch.is_ascii_digit() || ch.is_ascii_whitespace()) {
        return true;
    }

    let generic_patterns = [
        "journal entry",
        "insight ",
        "workspace interest",
        "untitled",
        "note ",
        "notes ",
        "entry ",
    ];
    if generic_patterns
        .iter()
        .any(|pattern| normalized.starts_with(pattern) || normalized == *pattern)
    {
        return true;
    }

    let digit_count = normalized.chars().filter(|ch| ch.is_ascii_digit()).count();
    digit_count >= 6
}

fn normalize_label_for_quality_checks(label: &str) -> String {
    label
        .trim()
        .replace(['_', '-'], " ")
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ")
        .to_ascii_lowercase()
}

fn is_meaningful_label_candidate(candidate: &str) -> bool {
    let trimmed = candidate.trim().trim_matches(|ch: char| ch == '"' || ch == '\'' || ch == '`');
    if trimmed.len() < 8 {
        return false;
    }
    if label_looks_auto_generated(trimmed) {
        return false;
    }
    let alpha_count = trimmed.chars().filter(|ch| ch.is_alphabetic()).count();
    alpha_count >= 5
}

fn cleaned_line_for_label(line: &str) -> String {
    line.trim()
        .trim_start_matches('#')
        .trim_start_matches('-')
        .trim_start_matches('*')
        .trim()
        .trim_matches('|')
        .trim()
        .to_string()
}

fn derive_interest_label(default_title: &str, content: &str) -> String {
    for line in content.lines() {
        let cleaned = cleaned_line_for_label(line);
        if is_meaningful_label_candidate(&cleaned) {
            return truncate_with_ellipsis(cleaned.trim(), 80);
        }
    }
    let normalized_title = default_title.trim();
    if !normalized_title.is_empty()
        && !normalized_title.eq_ignore_ascii_case("untitled")
        && !label_looks_auto_generated(normalized_title)
    {
        return truncate_with_ellipsis(normalized_title, 80);
    }
    "Workspace interest".to_string()
}

fn stage1_stopwords() -> &'static HashSet<&'static str> {
    static WORDS: OnceLock<HashSet<&'static str>> = OnceLock::new();
    WORDS.get_or_init(|| {
        HashSet::from([
            "about", "after", "also", "been", "being", "because", "before", "between", "could",
            "from", "have", "into", "just", "like", "more", "most", "only", "other", "over",
            "really", "some", "than", "that", "their", "there", "these", "they", "this",
            "those", "through", "very", "what", "when", "where", "which", "with", "would",
            "your", "ours", "ourselves", "the", "and", "for", "are", "was", "were", "you",
            "has", "had", "but", "not", "too", "out", "off", "its", "why", "how", "who",
            "insight", "post", "notes", "note", "journal", "entry", "entries", "work", "thing",
            "things", "stuff", "really", "just", "dont", "didnt", "doesnt", "cant", "wont",
            "ive", "im", "youre", "thats", "maybe", "also", "still", "feel", "kind", "lot",
            "can", "should", "did", "done", "her", "his", "our", "lack", "start", "write",
            "need", "needs", "want", "wants", "think", "thinking", "good", "bad", "better",
            "best", "worse", "life", "people", "person", "someone", "something",
        ])
    })
}

fn broaden_stage1_keyword(term: &str) -> &'static [&'static str] {
    match term {
        "ai" => &["llm", "ml", "machine", "learning", "intelligence"],
        "llm" | "gpt" | "claude" | "model" => &["ai", "machine", "learning"],
        "ml" | "machine" => &["ai", "learning", "model"],
        "startup" | "startups" => &["founder", "business", "venture"],
        "founder" | "venture" => &["startup", "business"],
        "rust" => &["systems", "compiler", "software", "engineering"],
        "python" | "javascript" | "typescript" | "golang" => &["software", "programming", "engineering"],
        "programming" | "coding" | "code" => &["software", "engineering", "technology"],
        "software" => &["programming", "engineering", "technology"],
        "engineering" => &["software", "systems", "technology"],
        "technology" | "tech" => &["software", "engineering"],
        "bluesky" => &["bsky", "atproto", "social"],
        "nostr" => &["relay", "relays", "protocol"],
        "design" => &["product", "frontend", "web"],
        "web" | "frontend" => &["javascript", "react", "design"],
        "security" | "infosec" => &["privacy", "security", "hacking"],
        "privacy" => &["security", "infosec"],
        "agent" | "agents" => &["ai", "runtime", "autonomous"],
        "runtime" | "systems" => &["software", "engineering", "compiler"],
        "protocol" | "protocols" => &["network", "systems", "decentralized"],
        "hardware" | "embedded" => &["systems", "firmware", "electronics"],
        "crypto" | "blockchain" => &["decentralized", "protocol", "web3"],
        "data" | "database" => &["engineering", "analytics", "software"],
        "science" | "research" => &["analysis", "academic"],
        "writing" | "blog" => &["content", "publishing"],
        // Mindfulness, Buddhism, Consciousness
        "meditation" | "meditate" | "mindfulness" | "mindful" => &["consciousness", "buddhism", "awareness", "psychology", "contemplation"],
        "buddhism" | "buddhist" | "dharma" | "vipassana" => &["meditation", "mindfulness", "consciousness", "philosophy"],
        "consciousness" | "awareness" => &["meditation", "mindfulness", "philosophy", "psychology"],
        "craving" | "attachment" | "aversion" => &["mindfulness", "psychology", "buddhism", "behavior"],
        "contemplation" | "contemplative" => &["meditation", "mindfulness", "philosophy", "reflection"],
        // Psychology, Behavior, Learning
        "reinforcement" => &["learning", "psychology", "behavior", "reward"],
        "reward" | "punishment" => &["reinforcement", "psychology", "behavior", "learning"],
        "psychology" | "cognitive" => &["behavior", "consciousness", "mindfulness", "neuroscience"],
        "behavior" | "behavioral" => &["psychology", "cognitive", "economics", "learning"],
        "neuroscience" => &["psychology", "consciousness", "cognitive", "brain"],
        // Philosophy, Ideas
        "philosophy" | "philosophical" => &["consciousness", "ideas", "ethics", "thinking"],
        "ethics" | "moral" => &["philosophy", "consciousness", "values"],
        "ideas" | "thinking" => &["philosophy", "creativity", "innovation"],
        // Economics, Business, Social
        "economics" | "economic" | "economy" => &["business", "policy", "markets", "innovation"],
        "sustainability" | "sustainable" => &["economics", "innovation", "environment"],
        "innovation" => &["technology", "economics", "ideas", "creativity"],
        // Workflows, Productivity, Content
        "workflow" | "automation" | "pipeline" => &["productivity", "tools", "systems"],
        "productivity" | "habits" => &["workflow", "mindfulness", "psychology"],
        "podcast" | "content" | "creation" => &["media", "publishing", "writing", "workflow"],
        "artifact" | "artifacts" => &["workflow", "content", "creation", "digital"],
        "digital" => &["technology", "workflow", "content"],
        "feedback" => &["systems", "learning", "improvement"],
        _ => &[],
    }
}

fn score_terms_from_text(raw: &str, weight: f32, scores: &mut HashMap<String, f32>) {
    let stopwords = stage1_stopwords();
    let cleaned = sanitize_text_for_keyword_extraction(raw);
    for term in tokenize_terms(&cleaned) {
        if term.len() < 3 || stopwords.contains(term.as_str()) {
            continue;
        }
        if !term.chars().any(|ch| ch.is_alphabetic()) {
            continue;
        }
        let stemmed = stem_term(&term);
        let canonical = if stemmed.len() >= 3 { &stemmed } else { &term };
        *scores.entry(canonical.clone()).or_insert(0.0) += weight;
        // Also score the original if different from stemmed, to keep specificity
        if *canonical != term {
            *scores.entry(term.clone()).or_insert(0.0) += weight * 0.3;
        }
        for broadened in broaden_stage1_keyword(&term) {
            *scores.entry((*broadened).to_string()).or_insert(0.0) += weight * 0.6;
        }
    }
    score_phrases_from_text(&cleaned, weight, scores);
}

fn derive_interest_keywords(label: &str, content: &str) -> Vec<String> {
    extract_weighted_profile_keywords(label, content)
        .into_iter()
        .map(|(term, _)| term)
        .collect()
}

fn useful_single_keyword(term: &str) -> bool {
    matches!(
        term,
        "ai"
            | "rust"
            | "python"
            | "javascript"
            | "typescript"
            | "golang"
            | "bluesky"
            | "nostr"
            | "rss"
            | "workflow"
            | "automation"
            | "ranking"
            | "video"
            | "audio"
            | "design"
            | "frontend"
            | "backend"
            | "productivity"
            | "protocol"
            | "meditation"
            | "mindfulness"
            | "buddhism"
            | "psychology"
            | "philosophy"
            | "economics"
            | "startup"
            | "writing"
            | "podcast"
    )
}

fn extract_weighted_profile_keywords(label: &str, content: &str) -> Vec<(String, f64)> {
    let mut scores: HashMap<String, f32> = HashMap::new();
    score_terms_from_text(label, 3.0, &mut scores);
    let mut heading_count = 0;
    for line in content.lines() {
        let trimmed = line.trim();
        if trimmed.is_empty() {
            continue;
        }
        if trimmed.starts_with('#') {
            heading_count += 1;
            score_terms_from_text(trimmed.trim_start_matches('#').trim(), 2.0, &mut scores);
            if heading_count >= 8 {
                break;
            }
        }
    }
    score_terms_from_text(&truncate_with_ellipsis(content.trim(), 1_600), 1.0, &mut scores);

    let mut ranked: Vec<(String, f32)> = scores.into_iter().collect();
    ranked.sort_by(|left, right| {
        right
            .1
            .partial_cmp(&left.1)
            .unwrap_or(Ordering::Equal)
            .then_with(|| left.0.cmp(&right.0))
    });
    let mut phrase_terms = Vec::new();
    let mut single_terms = Vec::new();
    for (term, score) in ranked.into_iter().filter(|(term, _)| keyword_is_meaningful(term)) {
        if term.split_whitespace().count() >= 2 {
            phrase_terms.push((term, score));
        } else if useful_single_keyword(&term) {
            single_terms.push((term, score));
        }
    }
    phrase_terms
        .into_iter()
        .chain(single_terms)
        .take(KEYWORD_PROFILE_BATCH_LIMIT)
        .enumerate()
        .map(|(index, (term, score))| {
            let normalized = (score / 6.0).clamp(0.2, 1.0) as f64;
            let rank_bonus = (KEYWORD_PROFILE_BATCH_LIMIT.saturating_sub(index) as f64)
                / (KEYWORD_PROFILE_BATCH_LIMIT as f64)
                * 0.08;
            let increment = (0.18 + normalized * 0.24 + rank_bonus).min(0.55);
            (term, increment)
        })
        .collect()
}

fn normalize_stored_triage_keywords(raw_json: &str) -> Vec<(String, f64)> {
    let raw_terms: Vec<String> = serde_json::from_str(raw_json.trim()).unwrap_or_default();
    if raw_terms.is_empty() {
        return Vec::new();
    }

    let mut scores: HashMap<String, f64> = HashMap::new();
    for (idx, raw) in raw_terms.into_iter().enumerate() {
        let Some(term) = normalize_profile_keyword_seed(&raw) else {
            continue;
        };
        let rank_bonus = (1.1 - ((idx as f64) * 0.06)).max(0.55);
        *scores.entry(term).or_insert(0.0) += rank_bonus;
    }

    let mut ranked: Vec<(String, f64)> = scores.into_iter().collect();
    ranked.sort_by(|left, right| {
        right
            .1
            .partial_cmp(&left.1)
            .unwrap_or(Ordering::Equal)
            .then_with(|| left.0.cmp(&right.0))
    });
    ranked.truncate(KEYWORD_PROFILE_BATCH_LIMIT);
    ranked
}

fn normalize_profile_keyword_seed(raw: &str) -> Option<String> {
    let cleaned = sanitize_text_for_keyword_extraction(raw);
    if cleaned.is_empty() {
        return None;
    }
    let normalized = cleaned
        .split_whitespace()
        .take(3)
        .collect::<Vec<_>>()
        .join(" ");
    if normalized.is_empty() {
        return None;
    }
    if keyword_is_meaningful(&normalized) || useful_single_keyword(&normalized) {
        Some(normalized)
    } else {
        None
    }
}

fn profile_keyword_input_hash(
    content_hash: &str,
    keyword_mode: &str,
    keywords: &[(String, f64)],
) -> String {
    let terms: Vec<&str> = keywords.iter().map(|(term, _)| term.as_str()).collect();
    content_hash_16(&format!(
        "{}::{keyword_mode}::{}",
        content_hash.trim(),
        terms.join("|")
    ))
}

fn sanitize_text_for_keyword_extraction(raw: &str) -> String {
    raw.lines()
        .map(|line| {
            line.trim()
                .replace("http://", " ")
                .replace("https://", " ")
                .replace("www.", " ")
                .replace("```", " ")
                .replace('`', " ")
                .replace('|', " ")
        })
        .filter(|line| {
            let trimmed = line.trim();
            !trimmed.is_empty()
                && !trimmed.chars().all(|ch| ch == '-' || ch == '_' || ch == '=' || ch == '*')
        })
        .collect::<Vec<_>>()
        .join(" ")
}

fn score_phrases_from_text(raw: &str, weight: f32, scores: &mut HashMap<String, f32>) {
    let stopwords = stage1_stopwords();
    let tokens: Vec<String> = tokenize_terms(raw)
        .into_iter()
        .filter(|term| !stopwords.contains(term.as_str()))
        .filter(|term| term.chars().any(|ch| ch.is_alphabetic()))
        .collect();
    for window_size in [2usize, 3usize] {
        for window in tokens.windows(window_size) {
            if window.iter().any(|term| label_looks_auto_generated(term)) {
                continue;
            }
            let phrase = window.join(" ");
            if keyword_is_meaningful(&phrase) {
                *scores.entry(phrase).or_insert(0.0) += weight * if window_size == 2 { 1.35 } else { 1.6 };
            }
        }
    }
}

fn keyword_is_meaningful(term: &str) -> bool {
    let trimmed = term.trim();
    if trimmed.len() < 3 || label_looks_auto_generated(trimmed) {
        return false;
    }
    if trimmed.chars().filter(|ch| ch.is_ascii_digit()).count() >= 4 {
        return false;
    }
    let stopwords = stage1_stopwords();
    let parts: Vec<&str> = trimmed.split_whitespace().collect();
    if parts.is_empty() {
        return false;
    }
    if parts.len() == 1 {
        let token = parts[0];
        return token.chars().any(|ch| ch.is_alphabetic()) && !stopwords.contains(token);
    }
    parts.iter().all(|part| {
        part.chars().any(|ch| ch.is_alphabetic()) && !stopwords.contains(*part)
    })
}

fn load_interest_source_text(workspace_dir: &Path, source_path: &str) -> String {
    let trimmed = source_path.trim().trim_start_matches('/');
    if trimmed.is_empty() {
        return String::new();
    }
    let path = workspace_dir.join(trimmed);
    std::fs::read_to_string(path)
        .map(|content| truncate_with_ellipsis(content.trim(), FEED_PROFILE_MAX_CHARS))
        .unwrap_or_default()
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

fn ema_merge_vectors(current: &[f32], previous: &[f32]) -> Vec<f32> {
    current
        .iter()
        .zip(previous.iter())
        .map(|(new_value, previous_value)| {
            INTEREST_EMA_NEW_WEIGHT * *new_value + (1.0 - INTEREST_EMA_NEW_WEIGHT) * *previous_value
        })
        .collect()
}

fn best_interest_match(embedding: &[f32], interests: &[InterestVector]) -> (f32, f32, Option<String>) {
    let mut best_weighted = 0.0_f32;
    let mut best_similarity = 0.0_f32;
    let mut best_label: Option<String> = None;
    for interest in interests {
        let similarity = cosine_similarity(embedding, &interest.embedding);
        let weighted = similarity * interest.health_score;
        if weighted > best_weighted {
            best_weighted = weighted;
            best_similarity = similarity;
            best_label = Some(interest.label.clone());
        }
    }
    (best_weighted, best_similarity, best_label)
}

fn top_interest_terms(profile: &FeedProfile) -> BTreeSet<String> {
    let mut interests = profile.interests.clone();
    interests.sort_by(|left, right| {
        right
            .health_score
            .partial_cmp(&left.health_score)
            .unwrap_or(Ordering::Equal)
    });
    interests
        .into_iter()
        .take(6)
        .flat_map(|interest| {
            if interest.keywords.is_empty() {
                tokenize_terms(&interest.label)
            } else {
                interest.keywords.clone()
            }
        })
        .collect()
}

fn broad_interest_keywords(profile: &FeedProfile) -> Vec<String> {
    let mut scores: HashMap<String, f32> = HashMap::new();
    for interest in &profile.interests {
        let keywords = if interest.keywords.is_empty() {
            tokenize_terms(&interest.label)
        } else {
            interest.keywords.clone()
        };
        for keyword in keywords {
            if keyword.len() < 3 || stage1_stopwords().contains(keyword.as_str()) {
                continue;
            }
            *scores.entry(keyword).or_insert(0.0) += interest.health_score.max(0.1);
        }
    }
    let mut ranked: Vec<(String, f32)> = scores.into_iter().collect();
    ranked.sort_by(|left, right| {
        right
            .1
            .partial_cmp(&left.1)
            .unwrap_or(Ordering::Equal)
            .then_with(|| left.0.cmp(&right.0))
    });
    let result: Vec<String> = ranked
        .into_iter()
        .map(|(keyword, _)| keyword)
        .take(STAGE1_KEYWORD_LIMIT)
        .collect();
    tracing::debug!(
        keyword_count = result.len(),
        keywords = %result.join(", "),
        interest_count = profile.interests.len(),
        "World feed: broad interest keywords for source matching"
    );
    result
}

fn weighted_interest_keywords(profile: &FeedProfile) -> Vec<(String, f32)> {
    let mut scores: HashMap<String, f32> = HashMap::new();
    for interest in &profile.interests {
        let keywords = if interest.keywords.is_empty() {
            vec![interest.label.clone()]
        } else {
            interest.keywords.clone()
        };
        for keyword in keywords {
            if keyword.len() < 3 || stage1_stopwords().contains(keyword.as_str()) {
                continue;
            }
            *scores.entry(keyword).or_insert(0.0) += interest.health_score.max(0.05);
        }
    }
    let mut ranked: Vec<(String, f32)> = scores.into_iter().collect();
    ranked.sort_by(|left, right| {
        right
            .1
            .partial_cmp(&left.1)
            .unwrap_or(Ordering::Equal)
            .then_with(|| left.0.cmp(&right.0))
    });
    ranked.truncate(STAGE1_KEYWORD_LIMIT);
    ranked
}

fn keyword_weight_sum(text: &str, keyword_weights: &[(String, f32)]) -> (f32, Option<String>) {
    if keyword_weights.is_empty() {
        return (0.0, None);
    }
    let lower = text.to_ascii_lowercase();
    let stemmed_tokens: Vec<String> = tokenize_and_stem(&lower);
    let mut matched_weight = 0.0_f32;
    let mut best_match: Option<(String, f32)> = None;
    for (keyword, weight) in keyword_weights {
        let matched = lower.contains(keyword.as_str())
            || stemmed_tokens.iter().any(|token| token == keyword.as_str());
        if !matched {
            continue;
        }
        matched_weight += *weight;
        if best_match
            .as_ref()
            .map(|(_, best)| *weight > *best)
            .unwrap_or(true)
        {
            best_match = Some((keyword.clone(), *weight));
        }
    }
    (matched_weight, best_match.map(|(keyword, _)| keyword))
}

fn candidate_freshness_bonus(item: &PersonalizedFeedItem) -> f32 {
    let timestamp = item_sort_timestamp(item);
    let Ok(parsed) = chrono::DateTime::parse_from_rfc3339(timestamp) else {
        return 0.0;
    };
    let age_hours = (Utc::now() - parsed.with_timezone(&Utc))
        .num_hours()
        .max(0) as f32;
    if age_hours <= 24.0 {
        KEYWORD_PROFILE_FRESHNESS_BONUS_MAX
    } else if age_hours <= 72.0 {
        KEYWORD_PROFILE_FRESHNESS_BONUS_MAX * 0.5
    } else if age_hours <= 168.0 {
        KEYWORD_PROFILE_FRESHNESS_BONUS_MAX * 0.2
    } else {
        0.0
    }
}

fn keyword_match_score(text: &str, keywords: &[String]) -> f32 {
    if keywords.is_empty() {
        return 0.0;
    }
    let lower = text.to_ascii_lowercase();
    let stemmed_tokens: Vec<String> = tokenize_and_stem(&lower);
    let matched = keywords
        .iter()
        .filter(|keyword| {
            lower.contains(keyword.as_str())
                || stemmed_tokens.iter().any(|token| token == keyword.as_str())
        })
        .count();
    if matched == 0 {
        return 0.0;
    }
    (0.65 + (matched as f32 - 1.0) * 0.15).min(1.0)
}

fn first_matched_keyword<'a>(text: &str, keywords: &'a [String]) -> Option<&'a str> {
    let lower = text.to_ascii_lowercase();
    let stemmed_tokens: Vec<String> = tokenize_and_stem(&lower);
    keywords
        .iter()
        .find(|keyword| {
            lower.contains(keyword.as_str())
                || stemmed_tokens.iter().any(|token| token == keyword.as_str())
        })
        .map(|keyword| keyword.as_str())
}

fn english_stemmer() -> &'static Stemmer {
    static STEMMER: OnceLock<Stemmer> = OnceLock::new();
    STEMMER.get_or_init(|| Stemmer::create(StemAlgorithm::English))
}

fn stem_term(term: &str) -> String {
    english_stemmer().stem(term).into_owned()
}

fn tokenize_terms(raw: &str) -> Vec<String> {
    raw.split(|char: char| !char.is_alphanumeric())
        .map(|part| part.trim().to_ascii_lowercase())
        .filter(|part| part.len() >= 3)
        .collect()
}

fn tokenize_and_stem(raw: &str) -> Vec<String> {
    let stemmer = english_stemmer();
    let mut seen = HashSet::new();
    raw.split(|char: char| !char.is_alphanumeric())
        .map(|part| part.trim().to_ascii_lowercase())
        .filter(|part| part.len() >= 3)
        .map(|part| {
            let stemmed = stemmer.stem(&part).into_owned();
            if stemmed.len() >= 3 { stemmed } else { part }
        })
        .filter(|term| seen.insert(term.clone()))
        .collect()
}

fn passes_lexical_gate(_text: &str, _terms: &BTreeSet<String>, _stage1_score: f32) -> bool {
    // Lexical gate disabled: all candidates now reach the semantic ranker
    // (Stage 3). The old keyword gate was counterproductive — it dropped
    // items that were semantically relevant but used different vocabulary
    // (e.g., "autonomous systems" vs "self-driving robotics"). The embedding
    // similarity in rank_candidates is the right place for quality filtering.
    true
}

async fn embed_text_batch(embedder: SharedEmbedder, texts: &[String]) -> Result<Vec<Vec<f32>>> {
    let mut out = Vec::new();
    for chunk in texts.chunks(FEED_EMBED_BATCH_SIZE) {
        let refs: Vec<&str> = chunk.iter().map(String::as_str).collect();
        let mut batch = embedder.embed(&refs).await?;
        out.append(&mut batch);
    }
    Ok(out)
}

#[derive(Clone)]
struct BlueskyFeedSource {
    auth: BlueskyAuth,
}

impl BlueskyFeedSource {
    fn new(auth: BlueskyAuth) -> Self {
        Self { auth }
    }

    async fn discover_sources_with_diagnostics(
        &self,
        profile: &FeedProfile,
    ) -> Result<(Vec<SelectedSource>, FeedProtocolDiagnostics)> {
        let keyword_weights = weighted_interest_keywords(profile);
        let mut diagnostics = FeedProtocolDiagnostics {
            available: true,
            ..FeedProtocolDiagnostics::default()
        };
        let mut generators = Vec::new();
        let mut seen_uris = HashSet::new();
        let mut cursor: Option<String> = None;

        for _ in 0..BLUESKY_FEED_GENERATOR_DISCOVERY_PAGE_LIMIT {
            let (page, next_cursor) = fetch_bluesky_feed_generator_page(
                &self.auth.service_url,
                &self.auth.access_jwt,
                cursor.as_deref(),
                BLUESKY_FEED_GENERATOR_DISCOVERY_PAGE_SIZE,
            )
            .await?;
            if page.is_empty() {
                break;
            }
            for generator in page {
                if seen_uris.insert(generator.uri.clone()) {
                    generators.push(generator);
                }
            }
            let Some(next_cursor) = next_cursor.filter(|value| !value.trim().is_empty()) else {
                break;
            };
            cursor = Some(next_cursor);
        }
        diagnostics.scanned_count = generators.len();
        let mut ranked = Vec::new();
        for generator in generators {
            let search_text = bluesky_feed_generator_search_text(&generator);
            let (keyword_score, matched_keyword) =
                keyword_weight_sum(&search_text, &keyword_weights);
            if keyword_score <= 0.0 {
                continue;
            }
            let label = bluesky_feed_generator_label(&generator);
            ranked.push(SelectedSource {
                protocol: FeedProtocol::Bluesky,
                key: format!("feed:{}", generator.uri),
                label: label.clone(),
                stage1_score: keyword_score,
                description: non_empty_string(generator.description.clone()),
                matched_interest_label: matched_keyword,
                matched_interest_score: Some(keyword_score),
                metadata_json: serde_json::json!({
                    "uri": generator.uri,
                    "creatorHandle": generator.creator_handle,
                }),
            });
        }
        ranked.sort_by(|left, right| {
            right
                .stage1_score
                .partial_cmp(&left.stage1_score)
                .unwrap_or(Ordering::Equal)
        });
        let selected = if !ranked.is_empty() {
            ranked.truncate(BLUESKY_FEED_GENERATOR_MATCH_LIMIT);
            ranked
        } else {
            fallback_bluesky_selected_sources()
        };
        diagnostics.shortlisted_count = selected.len();
        diagnostics.sampled_sources = selected.iter().take(6).cloned().collect();
        Ok((selected, diagnostics))
    }
}

#[async_trait]
impl FeedSource for BlueskyFeedSource {
    async fn discover_sources(&self, profile: &FeedProfile) -> Result<Vec<SelectedSource>> {
        Ok(self.discover_sources_with_diagnostics(profile).await?.0)
    }

    async fn fetch_candidates(
        &self,
        _profile: &FeedProfile,
        selected_sources: &[SelectedSource],
        limit: usize,
    ) -> Result<Vec<FeedCandidate>> {
        let mut candidate_sources = selected_sources
            .iter()
            .filter_map(selected_source_to_bluesky_source)
            .collect::<Vec<_>>();
        append_unique_bluesky_sources(
            &mut candidate_sources,
            vec![
                BlueskyCandidateSource::home_timeline(),
                BlueskyCandidateSource::discover_fallback(),
            ],
        );

        let mut matched = Vec::new();
        let mut seen = BTreeSet::new();
        for source in candidate_sources {
            let mut cursor: Option<String> = None;
            for _ in 0..BLUESKY_PERSONALIZED_PAGE_LIMIT_PER_SOURCE {
                let (page, next_cursor) = fetch_bluesky_candidate_page(
                    &self.auth.service_url,
                    &self.auth.access_jwt,
                    &source,
                    cursor.as_deref(),
                    BLUESKY_PERSONALIZED_PAGE_SIZE,
                )
                .await?;
                if page.is_empty() {
                    break;
                }

                let unique_page = dedupe_candidate_posts(page, &mut seen);
                for page_item in unique_page {
                    let rank_text = extract_bluesky_post_text(&page_item.feed_item);
                    if rank_text.trim().is_empty() {
                        continue;
                    }
                    matched.push(FeedCandidate {
                        protocol: FeedProtocol::Bluesky,
                        dedupe_key: bluesky_candidate_dedup_key(&page_item.feed_item)
                            .unwrap_or_else(|| format!("bs-{}", matched.len())),
                        stage1_score: source.stage1_score,
                        rank_text,
                        item: PersonalizedFeedItem {
                            source_type: FeedProtocol::Bluesky.source_type().to_string(),
                            feed_item: page_item.feed_item,
                            web_preview: None,
                            feed_source: source.feed_source.clone(),
                            score: None,
                            matched_interest_label: None,
                            matched_interest_score: None,
                            passed_threshold: false,
                        },
                        original_index: matched.len(),
                    });
                    if matched.len() >= limit {
                        return Ok(matched);
                    }
                }

                let Some(next_cursor) = next_cursor.filter(|value| !value.trim().is_empty()) else {
                    break;
                };
                cursor = Some(next_cursor);
            }
        }
        Ok(matched)
    }
}

#[derive(Clone)]
struct NostrFeedSource {
    config: Config,
}

impl NostrFeedSource {
    fn new(config: &Config) -> Self {
        Self {
            config: config.clone(),
        }
    }

    async fn discover_sources_with_diagnostics(
        &self,
        profile: &FeedProfile,
    ) -> Result<(Vec<SelectedSource>, FeedProtocolDiagnostics)> {
        let keyword_weights = weighted_interest_keywords(profile);
        let relay_urls = configured_nostr_world_feed_relays(&self.config);
        let fallback_relays = fallback_nostr_world_feed_relays(&self.config);
        let mut diagnostics = FeedProtocolDiagnostics {
            available: true,
            scanned_count: if relay_urls.is_empty() { fallback_relays.len() } else { relay_urls.len() },
            ..FeedProtocolDiagnostics::default()
        };
        let mut selected = fetch_nip66_relay_candidates(&fallback_relays, &keyword_weights)
            .await
            .unwrap_or_default();
        if relay_urls.is_empty() {
            if selected.is_empty() {
                selected = fallback_nostr_selected_sources(&self.config);
            }
            tracing::info!(
                nip66_found = selected.len(),
                "Nostr discovery: no configured relays, using fallback"
            );
            diagnostics.shortlisted_count = selected.len();
            diagnostics.sampled_sources = selected.iter().take(6).cloned().collect();
            return Ok((selected, diagnostics));
        }

        let mut relay_metadata = Vec::new();
        for relay_url in relay_urls {
            let metadata = fetch_nostr_relay_metadata(&relay_url)
                .await
                .unwrap_or(None);
            if metadata.is_some() {
                diagnostics.metadata_fetched_count += 1;
            }
            relay_metadata.push((relay_url, metadata));
        }
        let mut ranked = Vec::new();
        for (relay_url, metadata) in relay_metadata {
            let search_text = nostr_relay_search_text(&relay_url, metadata.as_ref());
            let (keyword_score, matched_keyword) =
                keyword_weight_sum(&search_text, &keyword_weights);
            if keyword_score <= 0.0 {
                continue;
            }
            let relay_http_url = nostr_relay_http_url(&relay_url).unwrap_or_default();
            ranked.push(SelectedSource {
                protocol: FeedProtocol::Nostr,
                key: relay_url.clone(),
                label: nostr_relay_label(&relay_url, metadata.as_ref()),
                stage1_score: keyword_score,
                description: nostr_relay_description(metadata.as_ref()),
                matched_interest_label: matched_keyword,
                matched_interest_score: Some(keyword_score),
                metadata_json: serde_json::json!({
                    "relayUrl": relay_url,
                    "domain": resolve_feed_web_domain(&relay_http_url).unwrap_or_default(),
                }),
            });
        }

        ranked.sort_by(|left, right| {
            right
                .stage1_score
                .partial_cmp(&left.stage1_score)
                .unwrap_or(Ordering::Equal)
        });
        append_selected_sources_unique(&mut selected, ranked);
        if selected.is_empty() {
            selected = fallback_nostr_selected_sources(&self.config);
        } else {
            selected.sort_by(|left, right| {
                right
                    .stage1_score
                    .partial_cmp(&left.stage1_score)
                    .unwrap_or(Ordering::Equal)
            });
            selected.truncate(NOSTR_SELECTED_RELAY_LIMIT);
        }
        diagnostics.shortlisted_count = selected.len();
        diagnostics.sampled_sources = selected.iter().take(6).cloned().collect();
        Ok((selected, diagnostics))
    }
}

#[async_trait]
impl FeedSource for NostrFeedSource {
    async fn discover_sources(&self, profile: &FeedProfile) -> Result<Vec<SelectedSource>> {
        Ok(self.discover_sources_with_diagnostics(profile).await?.0)
    }

    async fn fetch_candidates(
        &self,
        _profile: &FeedProfile,
        selected_sources: &[SelectedSource],
        limit: usize,
    ) -> Result<Vec<FeedCandidate>> {
        let mut matched = Vec::new();
        let mut seen = BTreeSet::new();
        for selected in selected_sources {
            let Some(relay_url) = selected
                .metadata_json
                .get("relayUrl")
                .and_then(serde_json::Value::as_str)
                .map(str::trim)
                .filter(|value| !value.is_empty())
            else {
                continue;
            };

            let events = match fetch_nostr_text_notes(relay_url, NOSTR_RECENT_NOTE_LIMIT_PER_RELAY).await {
                Ok(events) => events,
                Err(err) => {
                    tracing::debug!(relay = relay_url, error = %err, "Failed to fetch Nostr world-feed events");
                    continue;
                }
            };

            for event in events {
                let rank_text = truncate_with_ellipsis(event.content.trim(), FEED_PROFILE_MAX_CHARS);
                if rank_text.trim().is_empty() {
                    continue;
                }
                let dedupe_key = event.id.to_hex();
                if !seen.insert(dedupe_key.clone()) {
                    continue;
                }
                let permalink = nostr_event_permalink(&event);
                let relay_domain = resolve_feed_web_domain(&nostr_relay_http_url(relay_url).unwrap_or_default())
                    .unwrap_or_else(|| relay_url.to_string());
                let description = truncate_with_ellipsis(event.content.trim(), 220);
                let title = derive_interest_label("Nostr note", &event.content);
                let published_at = nostr_timestamp_to_rfc3339(event.created_at);
                let author = event
                    .pubkey
                    .to_bech32()
                    .unwrap_or_else(|_| event.pubkey.to_string());
                matched.push(FeedCandidate {
                    protocol: FeedProtocol::Nostr,
                    dedupe_key,
                    stage1_score: selected.stage1_score,
                    rank_text,
                    item: PersonalizedFeedItem {
                        source_type: FeedProtocol::Nostr.source_type().to_string(),
                        feed_item: serde_json::json!({
                            "url": permalink.clone(),
                            "title": title.clone(),
                            "description": description.clone(),
                            "domain": relay_domain.clone(),
                            "author": author,
                            "sourceTitle": selected.label.clone(),
                            "publishedAt": published_at.clone(),
                        }),
                        web_preview: Some(WebFeedPreview {
                            url: permalink,
                            title,
                            description,
                            content_text: event.content.clone(),
                            image_url: None,
                            domain: relay_domain,
                            provider: "Nostr".to_string(),
                            provider_snippet: Some(selected.label.clone()),
                            discovered_at: published_at,
                        }),
                        feed_source: Some(FeedSourceContext {
                            label: selected.label.clone(),
                            description: selected.description.clone(),
                            matched_interest_label: selected.matched_interest_label.clone(),
                            matched_interest_score: selected.matched_interest_score,
                            source_score: Some(selected.stage1_score),
                        }),
                        score: None,
                        matched_interest_label: None,
                        matched_interest_score: None,
                        passed_threshold: false,
                    },
                    original_index: matched.len(),
                });
                if matched.len() >= limit {
                    return Ok(matched);
                }
            }
        }
        Ok(matched)
    }
}

#[derive(Clone)]
struct RssFeedSource {
    config: Config,
}

impl RssFeedSource {
    fn new(config: &Config) -> Self {
        Self {
            config: config.clone(),
        }
    }

    async fn discover_sources_with_diagnostics(
        &self,
        profile: &FeedProfile,
    ) -> Result<(Vec<SelectedSource>, FeedProtocolDiagnostics)> {
        seed_default_feed_web_sources(&self.config.workspace_dir)?;
        let sources = local_store::list_feed_web_sources(&self.config.workspace_dir)?;
        let mut diagnostics = FeedProtocolDiagnostics {
            available: true,
            scanned_count: sources.len(),
            ..FeedProtocolDiagnostics::default()
        };
        let keyword_weights = weighted_interest_keywords(profile);
        let mut ranked = Vec::new();
        for source in &sources {
            let metadata_text = catalog_metadata_text(
                &source.title,
                &source.domain,
                &source.description,
                &source.topics_csv,
            );
            let (keyword_score, matched_keyword) =
                keyword_weight_sum(&metadata_text, &keyword_weights);
            if keyword_score <= 0.0 {
                tracing::trace!(
                    domain = %source.domain,
                    metadata_snippet = %truncate_with_ellipsis(&metadata_text, 120),
                    "RSS source: no keyword match"
                );
                continue;
            }
            ranked.push(SelectedSource {
                protocol: FeedProtocol::Rss,
                key: source.xml_url.clone(),
                label: source.title.clone(),
                stage1_score: keyword_score,
                description: non_empty_string(source.description.clone()),
                matched_interest_label: matched_keyword,
                matched_interest_score: Some(keyword_score),
                metadata_json: serde_json::json!({
                    "domain": source.domain,
                    "topics": source.topics_csv,
                    "htmlUrl": source.html_url,
                }),
            });
        }
        tracing::info!(
            keyword_matched = ranked.len(),
            total_sources = sources.len(),
            keyword_count = keyword_weights.len(),
            "RSS source discovery: keyword matching complete"
        );

        ranked.sort_by(|left, right| {
            right
                .stage1_score
                .partial_cmp(&left.stage1_score)
                .unwrap_or(Ordering::Equal)
        });
        // When both keyword and semantic matching fail, guarantee at least some
        // sources are shortlisted so the rest of the pipeline can produce items.
        let selected = if !ranked.is_empty() {
            ranked.truncate(RSS_SELECTED_SOURCE_LIMIT);
            ranked
        } else {
            tracing::info!(
                "RSS source discovery: no keyword or semantic matches, using unranked fallback sources"
            );
            sources
                .iter()
                .take(RSS_SELECTED_SOURCE_LIMIT.min(4))
                .map(|source| SelectedSource {
                    protocol: FeedProtocol::Rss,
                    key: source.xml_url.clone(),
                    label: source.title.clone(),
                    stage1_score: 0.2,
                    description: non_empty_string(source.description.clone()),
                    matched_interest_label: None,
                    matched_interest_score: None,
                    metadata_json: serde_json::json!({
                        "domain": source.domain,
                        "topics": source.topics_csv,
                        "htmlUrl": source.html_url,
                    }),
                })
                .collect()
        };
        diagnostics.shortlisted_count = selected.len();
        diagnostics.sampled_sources = selected.iter().take(6).cloned().collect();
        Ok((selected, diagnostics))
    }
}

#[async_trait]
impl FeedSource for RssFeedSource {
    async fn discover_sources(&self, profile: &FeedProfile) -> Result<Vec<SelectedSource>> {
        Ok(self.discover_sources_with_diagnostics(profile).await?.0)
    }

    async fn fetch_candidates(
        &self,
        profile: &FeedProfile,
        selected_sources: &[SelectedSource],
        limit: usize,
    ) -> Result<Vec<FeedCandidate>> {
        sync_content_sources_from_selected_sources(&self.config.workspace_dir, selected_sources)?;
        refresh_selected_content_sources(&self.config.workspace_dir, selected_sources).await?;

        let selected_keys: HashMap<String, &SelectedSource> = selected_sources
            .iter()
            .map(|source| (source.key.clone(), source))
            .collect();
        let mut per_source_counts: HashMap<String, usize> = HashMap::new();
        let mut candidates = Vec::new();
        for item in local_store::list_recent_content_items(&self.config.workspace_dir, RSS_RECENT_SCAN_LIMIT)? {
            let Some(selected) = selected_keys.get(&item.source_key) else {
                continue;
            };
            let count = per_source_counts.entry(item.source_key.clone()).or_insert(0);
            if *count >= RSS_CANDIDATE_PER_SOURCE_LIMIT {
                continue;
            }
            *count += 1;
            let preview = build_content_preview(&item);
            let rank_text = content_item_rank_text(&item, profile);
            candidates.push(FeedCandidate {
                protocol: FeedProtocol::Rss,
                dedupe_key: item.canonical_url.clone(),
                stage1_score: selected.stage1_score,
                rank_text,
                item: PersonalizedFeedItem {
                    source_type: FeedProtocol::Rss.source_type().to_string(),
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
                    feed_source: Some(FeedSourceContext {
                        label: selected.label.clone(),
                        description: selected.description.clone(),
                        matched_interest_label: selected.matched_interest_label.clone(),
                        matched_interest_score: selected.matched_interest_score,
                        source_score: Some(selected.stage1_score),
                    }),
                    score: None,
                    matched_interest_label: None,
                    matched_interest_score: None,
                    passed_threshold: false,
                },
                original_index: candidates.len(),
            });
            if candidates.len() >= limit {
                break;
            }
        }
        Ok(candidates)
    }
}

async fn ensure_catalog_metadata_embeddings(
    workspace_dir: &Path,
    embedder: SharedEmbedder,
) -> Result<Vec<local_store::FeedWebSourceRecord>> {
    let existing_sources = local_store::list_feed_web_sources(workspace_dir)?;
    let mut updates = Vec::new();
    let mut texts = Vec::new();

    for source in existing_sources {
        let (description, topics_csv) = enrich_feed_source_metadata(&source);
        let needs_embedding = source.metadata_embedding.is_empty();
        if needs_embedding {
            let metadata_text = catalog_metadata_text(
                &source.title,
                &source.domain,
                &description,
                &topics_csv,
            );
            texts.push(metadata_text);
        }
        updates.push((source, description, topics_csv, needs_embedding));
    }

    let embeddings = if texts.is_empty() {
        Vec::new()
    } else {
        embed_text_batch(embedder, &texts).await?
    };
    let mut embedding_iter = embeddings.into_iter();
    for (source, description, topics_csv, needs_embedding) in updates {
        let metadata_embedding = if needs_embedding {
            vec_to_bytes(&embedding_iter.next().unwrap_or_default())
        } else {
            source.metadata_embedding.clone()
        };
        let _ = local_store::upsert_feed_web_source(
            workspace_dir,
            &local_store::FeedWebSourceUpsert {
                domain: source.domain,
                title: source.title,
                html_url: source.html_url,
                xml_url: source.xml_url,
                description,
                topics_csv,
                metadata_embedding,
                enabled: source.enabled,
                source_kind: source.source_kind,
            },
        )?;
    }

    local_store::list_feed_web_sources(workspace_dir)
}

fn seed_default_feed_web_sources(workspace_dir: &Path) -> Result<()> {
    for source in DEFAULT_FEED_WEB_SOURCES {
        let (description, topics_csv) = infer_default_feed_source_metadata(source.domain, source.title);
        let _ = local_store::upsert_feed_web_source(
            workspace_dir,
            &local_store::FeedWebSourceUpsert {
                domain: source.domain.to_string(),
                title: source.title.to_string(),
                html_url: source.html_url.to_string(),
                xml_url: source.xml_url.to_string(),
                description,
                topics_csv,
                metadata_embedding: Vec::new(),
                enabled: true,
                source_kind: "curated-rss-catalog".to_string(),
            },
        )?;
    }
    Ok(())
}

fn enrich_feed_source_metadata(source: &local_store::FeedWebSourceRecord) -> (String, String) {
    let fallback = infer_default_feed_source_metadata(&source.domain, &source.title);
    let description = if source.description.trim().is_empty() {
        fallback.0
    } else {
        source.description.clone()
    };
    let topics_csv = if source.topics_csv.trim().is_empty() {
        fallback.1
    } else {
        source.topics_csv.clone()
    };
    (description, topics_csv)
}

fn infer_default_feed_source_metadata(domain: &str, title: &str) -> (String, String) {
    let domain_lower = domain.to_ascii_lowercase();
    let title_lower = title.to_ascii_lowercase();
    let combined = format!("{domain_lower} {title_lower}");
    let mut topics = Vec::new();

    if combined.contains("security") || combined.contains("krebs") || combined.contains("snort") {
        topics.extend(["security", "privacy", "infosec"]);
    }
    if combined.contains("rust")
        || combined.contains("compiler")
        || combined.contains("kernel")
        || combined.contains("systems")
        || combined.contains("devblog")
        || combined.contains("software")
        || combined.contains("program")
    {
        topics.extend(["software", "systems", "engineering", "programming"]);
    }
    if combined.contains("ai")
        || combined.contains("llm")
        || combined.contains("machine")
        || combined.contains("learning")
        || combined.contains("model")
    {
        topics.extend(["ai", "machine-learning", "llm"]);
    }
    if combined.contains("web") || combined.contains("react") || combined.contains("javascript") {
        topics.extend(["web", "frontend", "programming"]);
    }
    if combined.contains("econom") || combined.contains("policy") || combined.contains("construction") {
        topics.extend(["policy", "analysis"]);
    }
    if combined.contains("science") || combined.contains("physics") || combined.contains("math") {
        topics.extend(["science", "research"]);
    }
    if combined.contains("startup") || combined.contains("venture") || combined.contains("founder") {
        topics.extend(["startup", "business", "founder"]);
    }
    if combined.contains("open") || combined.contains("protocol") || combined.contains("decentrali") {
        topics.extend(["protocol", "decentralized", "open-source"]);
    }
    if combined.contains("data") || combined.contains("database") || combined.contains("analytics") {
        topics.extend(["data", "engineering", "analytics"]);
    }
    if combined.contains("hardware") || combined.contains("embedded") || combined.contains("gpio") {
        topics.extend(["hardware", "embedded", "systems"]);
    }
    if combined.contains("mindful")
        || combined.contains("meditation")
        || combined.contains("zen")
        || combined.contains("buddhis")
        || combined.contains("dharma")
        || combined.contains("vipassana")
        || combined.contains("contemplat")
    {
        topics.extend(["mindfulness", "meditation", "consciousness", "philosophy", "psychology"]);
    }
    if combined.contains("psycholog")
        || combined.contains("psyche")
        || combined.contains("cogniti")
        || combined.contains("behavior")
        || combined.contains("neuroscien")
    {
        topics.extend(["psychology", "behavior", "consciousness", "neuroscience"]);
    }
    if combined.contains("philosoph")
        || combined.contains("aeon")
        || combined.contains("marginalian")
        || combined.contains("ideas")
        || combined.contains("ethics")
    {
        topics.extend(["philosophy", "ideas", "consciousness", "thinking"]);
    }
    if combined.contains("tricycle")
        || combined.contains("lionsroar")
        || combined.contains("lion")
    {
        topics.extend(["buddhism", "meditation", "mindfulness", "consciousness", "philosophy"]);
    }
    if combined.contains("productiv")
        || combined.contains("nesslabs")
        || combined.contains("habits")
        || combined.contains("workflow")
    {
        topics.extend(["productivity", "mindfulness", "neuroscience", "workflow"]);
    }
    if combined.contains("every.to") || combined.contains("every to") {
        topics.extend(["ai", "productivity", "content", "workflow", "writing"]);
    }
    if combined.contains("oneusefulthing") || combined.contains("useful thing") {
        topics.extend(["ai", "productivity", "education", "workflow"]);
    }
    if combined.contains("astralcodex") || combined.contains("slate star") {
        topics.extend(["rationality", "ai", "economics", "psychology", "philosophy"]);
    }
    if combined.contains("nautil") {
        topics.extend(["science", "philosophy", "psychology", "ideas"]);
    }
    if combined.contains("evonomics") {
        topics.extend(["economics", "innovation", "behavior", "sustainability"]);
    }
    if combined.contains("marginalrevolution") {
        topics.extend(["economics", "policy", "ideas", "innovation"]);
    }
    if combined.contains("farnam") || combined.contains("fs.blog") {
        topics.extend(["mental-models", "decision-making", "philosophy", "psychology"]);
    }

    // Most tech blogs cover general software/technology even if not keyword-matched.
    // Add broad coverage topics so semantic matching has more to work with.
    if topics.is_empty() {
        topics.extend(["technology", "software", "engineering", "writing"]);
    }
    topics.sort_unstable();
    topics.dedup();

    (
        format!("{} posts and articles from {}", title.trim(), domain.trim()),
        topics.join(","),
    )
}

fn catalog_metadata_text(title: &str, domain: &str, description: &str, topics_csv: &str) -> String {
    format!(
        "{}\n{}\n{}\n{}",
        title.trim(),
        domain.trim(),
        description.trim(),
        topics_csv.replace(',', " ")
    )
}

fn sync_content_sources_from_selected_sources(
    workspace_dir: &Path,
    selected_sources: &[SelectedSource],
) -> Result<()> {
    let source_map: HashMap<String, local_store::FeedWebSourceRecord> = local_store::list_feed_web_sources(workspace_dir)?
        .into_iter()
        .map(|source| (source.xml_url.clone(), source))
        .collect();

    for selected in selected_sources {
        let Some(source) = source_map.get(&selected.key) else {
            continue;
        };
        let _ = local_store::upsert_content_source(
            workspace_dir,
            &local_store::ContentSourceUpsert {
                source_key: source.xml_url.clone(),
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

async fn refresh_selected_content_sources(
    workspace_dir: &Path,
    selected_sources: &[SelectedSource],
) -> Result<()> {
    for selected in selected_sources {
        let Some(source) = local_store::get_content_source(workspace_dir, &selected.key)? else {
            continue;
        };
        if !content_source_is_stale(&source.last_fetch_at) {
            continue;
        }

        let fetched_at = Utc::now().to_rfc3339();
        match fetch_remote_feed(&source).await {
            Ok(result) => {
                if !result.not_modified {
                    upsert_feed_entries(workspace_dir, &source, result.entries, &fetched_at).await?;
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
                tracing::debug!(source = %source.xml_url, error = %err, "Failed to refresh selected RSS source");
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

async fn upsert_feed_entries(
    workspace_dir: &Path,
    source: &local_store::ContentSourceRecord,
    entries: Vec<ParsedFeedEntry>,
    discovered_at: &str,
) -> Result<()> {
    for entry in entries.into_iter() {
        let embedding_text = content_item_embedding_text(&entry);
        if embedding_text.trim().is_empty() {
            continue;
        }
        let canonical_url = if entry.canonical_url.trim().is_empty() {
            source.html_url.clone()
        } else {
            entry.canonical_url.clone()
        };
        let id = build_content_item_id(&source.source_key, &canonical_url, &entry.external_id);
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
                external_id: entry.external_id,
                title: entry.title,
                author: entry.author,
                summary: truncate_with_ellipsis(entry.summary.trim(), 280),
                content_text: embedding_text,
                content_hash,
                embedding: Vec::new(),
                published_at: entry.published_at,
                discovered_at: discovered_at.to_string(),
            },
        )?;
    }
    Ok(())
}

fn content_source_is_stale(last_fetch_at: &str) -> bool {
    chrono::DateTime::parse_from_rfc3339(last_fetch_at.trim())
        .ok()
        .map(|value| Utc::now().signed_duration_since(value.with_timezone(&Utc)).num_seconds())
        .map(|age| age < 0 || age > RSS_CONTENT_REFRESH_TTL_SECS)
        .unwrap_or(true)
}

struct RemoteFeedFetchResult {
    entries: Vec<ParsedFeedEntry>,
    etag: Option<String>,
    last_modified: Option<String>,
    not_modified: bool,
}

async fn fetch_remote_feed(source: &local_store::ContentSourceRecord) -> Result<RemoteFeedFetchResult> {
    let client = reqwest::Client::builder()
        .timeout(Duration::from_secs(RSS_CONTENT_FETCH_TIMEOUT_SECS))
        .build()?;
    let mut request = client.get(source.xml_url.trim());
    if !source.etag.trim().is_empty() {
        request = request.header(reqwest::header::IF_NONE_MATCH, source.etag.trim());
    }
    if !source.last_modified.trim().is_empty() {
        request = request.header(reqwest::header::IF_MODIFIED_SINCE, source.last_modified.trim());
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

fn content_item_embedding_text(entry: &ParsedFeedEntry) -> String {
    let combined = format!(
        "{}\n{}\n{}",
        entry.title.trim(),
        entry.summary.trim(),
        entry.content_text.trim()
    );
    truncate_with_ellipsis(combined.trim(), FEED_PROFILE_MAX_CHARS)
}

fn content_item_rank_text(item: &local_store::ContentItemRecord, profile: &FeedProfile) -> String {
    let base = format!(
        "{}\n{}\n{}",
        item.title.trim(),
        item.summary.trim(),
        item.content_text.trim()
    );
    let terms = top_interest_terms(profile);
    if passes_lexical_gate(&base, &terms, 0.0) {
        truncate_with_ellipsis(base.trim(), FEED_PROFILE_MAX_CHARS)
    } else {
        truncate_with_ellipsis(
            format!("{}\n{}", item.title.trim(), item.summary.trim()).trim(),
            FEED_PROFILE_MAX_CHARS,
        )
    }
}

fn build_content_item_id(source_key: &str, canonical_url: &str, external_id: &str) -> String {
    format!(
        "content_{}",
        content_hash_16(&format!("{source_key}\n{canonical_url}\n{external_id}"))
    )
}

async fn collect_web_search_augmented_candidates(
    config: &Config,
    profile: &FeedProfile,
    selected_sources: &[SelectedSource],
    starting_index: usize,
) -> Result<Vec<FeedCandidate>> {
    let Some(tool) = build_feed_web_search_tool(config) else {
        return Ok(Vec::new());
    };
    let selected_domains: HashMap<String, &SelectedSource> = selected_sources
        .iter()
        .filter_map(|source| {
            source
                .metadata_json
                .get("domain")
                .and_then(serde_json::Value::as_str)
                .map(|domain| (normalize_feed_web_domain(domain), source))
        })
        .collect();
    if selected_domains.is_empty() {
        return Ok(Vec::new());
    }

    let queries = build_selected_domain_queries(profile, selected_sources);
    let mut seen_urls = BTreeSet::new();
    let mut candidates = Vec::new();
    for query in queries {
        let results = tool.search_structured(&query).await.unwrap_or_default();
        for result in results {
            let Some(domain) = resolve_feed_web_domain(&result.url) else {
                continue;
            };
            let Some(source) = selected_domains.get(&domain) else {
                continue;
            };
            if !seen_urls.insert(result.url.clone()) {
                continue;
            }
            let preview = WebFeedPreview {
                url: result.url.clone(),
                title: result.title.clone(),
                description: result.description.clone(),
                content_text: String::new(),
                image_url: None,
                domain: domain.clone(),
                provider: result.provider.clone(),
                provider_snippet: non_empty_string(result.description.clone()),
                discovered_at: Utc::now().to_rfc3339(),
            };
            candidates.push(FeedCandidate {
                protocol: FeedProtocol::Rss,
                dedupe_key: result.url.clone(),
                stage1_score: source.stage1_score * 0.92,
                rank_text: format!("{}\n{}", result.title.trim(), result.description.trim()),
                item: PersonalizedFeedItem {
                    source_type: FeedProtocol::Rss.source_type().to_string(),
                    feed_item: serde_json::json!({
                        "url": result.url,
                        "title": result.title,
                        "description": result.description,
                        "domain": domain,
                    }),
                    web_preview: Some(preview),
                    feed_source: Some(FeedSourceContext {
                        label: source.label.clone(),
                        description: source.description.clone(),
                        matched_interest_label: source.matched_interest_label.clone(),
                        matched_interest_score: source.matched_interest_score,
                        source_score: Some(source.stage1_score),
                    }),
                    score: None,
                    matched_interest_label: None,
                    matched_interest_score: None,
                    passed_threshold: false,
                },
                original_index: starting_index + candidates.len(),
            });
            if candidates.len() >= WEB_SEARCH_RESULT_LIMIT_PER_QUERY * 3 {
                return Ok(candidates);
            }
        }
    }
    Ok(candidates)
}

fn build_feed_web_search_tool(config: &Config) -> Option<WebSearchTool> {
    if !config.web_search.enabled {
        return None;
    }
    Some(WebSearchTool::new(
        config.web_search.provider.clone(),
        config.web_search.brave_api_key.clone(),
        WEB_SEARCH_RESULT_LIMIT_PER_QUERY.min(config.web_search.max_results),
        config.web_search.timeout_secs,
    ))
}

fn build_selected_domain_queries(profile: &FeedProfile, selected_sources: &[SelectedSource]) -> Vec<String> {
    let domains: Vec<String> = selected_sources
        .iter()
        .filter_map(|source| {
            source
                .metadata_json
                .get("domain")
                .and_then(serde_json::Value::as_str)
                .map(normalize_feed_web_domain)
        })
        .collect();
    let terms: Vec<String> = top_interest_terms(profile).into_iter().take(4).collect();
    if domains.is_empty() || terms.is_empty() {
        return Vec::new();
    }
    let batches: Vec<&[String]> = domains.chunks(4).collect();
    let mut queries = Vec::new();
    for (index, term) in terms.iter().enumerate() {
        let batch = batches[index % batches.len()];
        let site_filters = batch
            .iter()
            .map(|domain| format!("site:{domain}"))
            .collect::<Vec<_>>()
            .join(" OR ");
        queries.push(format!("{term} ({site_filters})"));
    }
    queries
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

fn rank_candidate_cmp(left: &RankedCandidate, right: &RankedCandidate) -> Ordering {
    let score_order = right
        .score
        .partial_cmp(&left.score)
        .unwrap_or(Ordering::Equal);
    if score_order != Ordering::Equal {
        return score_order;
    }
    let timestamp_order = item_sort_timestamp(&right.item).cmp(item_sort_timestamp(&left.item));
    if timestamp_order != Ordering::Equal {
        return timestamp_order;
    }
    left.original_index.cmp(&right.original_index)
}

fn candidate_source_mix_key(item: &PersonalizedFeedItem) -> String {
    if let Some(label) = item
        .feed_source
        .as_ref()
        .map(|source| source.label.trim())
        .filter(|label| !label.is_empty())
    {
        return label.to_ascii_lowercase();
    }
    item.source_type.trim().to_ascii_lowercase()
}

fn item_sort_timestamp(item: &PersonalizedFeedItem) -> &str {
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
        .or_else(|| {
            item.feed_item
                .get("publishedAt")
                .and_then(serde_json::Value::as_str)
        })
        .unwrap_or("")
}

fn build_raw_feed_items(
    candidates: Vec<CandidateFeedPost>,
    limit: usize,
) -> Vec<PersonalizedFeedItem> {
    candidates
        .into_iter()
        .take(limit)
        .map(|candidate| PersonalizedFeedItem {
            source_type: FeedProtocol::Bluesky.source_type().to_string(),
            feed_item: candidate.feed_item,
            web_preview: None,
            feed_source: candidate.feed_source,
            score: None,
            matched_interest_label: None,
            matched_interest_score: None,
            passed_threshold: false,
        })
        .collect()
}

#[derive(Debug, Clone)]
struct CandidateFeedPost {
    feed_item: serde_json::Value,
    feed_source: Option<FeedSourceContext>,
}

fn selected_source_to_bluesky_source(source: &SelectedSource) -> Option<BlueskyCandidateSource> {
    if source.protocol != FeedProtocol::Bluesky {
        return None;
    }
    if source.key == "home" {
        return Some(BlueskyCandidateSource {
            endpoint: BlueskyCandidateSourceEndpoint::HomeTimeline,
            label: source.label.clone(),
            feed_source: Some(FeedSourceContext {
                label: source.label.clone(),
                description: source.description.clone(),
                matched_interest_label: source.matched_interest_label.clone(),
                matched_interest_score: source.matched_interest_score,
                source_score: Some(source.stage1_score),
            }),
            stage1_score: source.stage1_score,
        });
    }
    let uri = source
        .metadata_json
        .get("uri")
        .and_then(serde_json::Value::as_str)
        .map(ToOwned::to_owned)
        .or_else(|| source.key.strip_prefix("feed:").map(ToOwned::to_owned))?;
    Some(BlueskyCandidateSource {
        endpoint: BlueskyCandidateSourceEndpoint::FeedGenerator { uri },
        label: source.label.clone(),
        feed_source: Some(FeedSourceContext {
            label: source.label.clone(),
            description: source.description.clone(),
            matched_interest_label: source.matched_interest_label.clone(),
            matched_interest_score: source.matched_interest_score,
            source_score: Some(source.stage1_score),
        }),
        stage1_score: source.stage1_score,
    })
}

fn append_unique_bluesky_sources(
    target: &mut Vec<BlueskyCandidateSource>,
    extra: Vec<BlueskyCandidateSource>,
) {
    let mut seen: HashSet<String> = target.iter().map(BlueskyCandidateSource::endpoint_key).collect();
    for source in extra {
        if seen.insert(source.endpoint_key()) {
            target.push(source);
        }
    }
}

fn append_selected_sources_unique(target: &mut Vec<SelectedSource>, extra: Vec<SelectedSource>) {
    let mut seen: HashSet<String> = target
        .iter()
        .map(|source| format!("{:?}:{}", source.protocol, source.key))
        .collect();
    for source in extra {
        let key = format!("{:?}:{}", source.protocol, source.key);
        if seen.insert(key) {
            target.push(source);
        }
    }
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

fn build_bluesky_feed_endpoint(
    service_url: &str,
    source: &BlueskyCandidateSource,
    cursor: Option<&str>,
    limit: usize,
) -> String {
    let trimmed_service = service_url.trim().trim_end_matches('/');
    let normalized_limit = limit.clamp(1, BLUESKY_TIMELINE_LIMIT_MAX);
    let mut url = match &source.endpoint {
        BlueskyCandidateSourceEndpoint::HomeTimeline => format!(
            "{trimmed_service}/xrpc/app.bsky.feed.getTimeline?limit={normalized_limit}"
        ),
        BlueskyCandidateSourceEndpoint::FeedGenerator { uri } => format!(
            "{trimmed_service}/xrpc/app.bsky.feed.getFeed?feed={}&limit={normalized_limit}",
            urlencoding::encode(uri)
        ),
    };
    if let Some(next_cursor) = cursor.map(str::trim).filter(|value| !value.is_empty()) {
        url.push_str("&cursor=");
        url.push_str(urlencoding::encode(next_cursor).as_ref());
    }
    url
}

fn build_bluesky_feed_generator_discovery_endpoint(
    service_url: &str,
    cursor: Option<&str>,
    limit: usize,
) -> String {
    let trimmed_service = service_url.trim().trim_end_matches('/');
    let normalized_limit = limit.clamp(1, BLUESKY_TIMELINE_LIMIT_MAX);
    let mut url = format!(
        "{trimmed_service}/xrpc/app.bsky.unspecced.getPopularFeedGenerators?limit={normalized_limit}"
    );
    if let Some(next_cursor) = cursor.map(str::trim).filter(|value| !value.is_empty()) {
        url.push_str("&cursor=");
        url.push_str(urlencoding::encode(next_cursor).as_ref());
    }
    url
}

fn bluesky_feed_generator_label(candidate: &CandidateFeedGenerator) -> String {
    non_empty_string(candidate.display_name.clone())
        .or_else(|| non_empty_string(candidate.creator_display_name.clone()))
        .or_else(|| non_empty_string(candidate.creator_handle.clone()))
        .unwrap_or_else(|| candidate.uri.clone())
}

fn bluesky_feed_generator_search_text(candidate: &CandidateFeedGenerator) -> String {
    [
        candidate.display_name.trim(),
        candidate.description.trim(),
        candidate.creator_display_name.trim(),
        candidate.creator_handle.trim(),
    ]
    .into_iter()
    .filter(|value| !value.is_empty())
    .collect::<Vec<_>>()
    .join("\n")
}

async fn fetch_bluesky_feed_generator_page(
    service_url: &str,
    access_jwt: &str,
    cursor: Option<&str>,
    limit: usize,
) -> Result<(Vec<CandidateFeedGenerator>, Option<String>)> {
    let url = build_bluesky_feed_generator_discovery_endpoint(service_url, cursor, limit);
    let response = reqwest::Client::builder()
        .timeout(Duration::from_secs(BLUESKY_FETCH_TIMEOUT_SECS))
        .build()?
        .get(url)
        .bearer_auth(access_jwt.trim())
        .send()
        .await
        .context("Failed to fetch Bluesky feed generators")?;

    if !response.status().is_success() {
        let status = response.status();
        let body = response.text().await.unwrap_or_default();
        anyhow::bail!("Bluesky feed generator request failed ({status}): {body}");
    }

    let json: serde_json::Value = response
        .json()
        .await
        .context("Failed to decode Bluesky feed generator response")?;
    let feeds = json
        .get("feeds")
        .and_then(serde_json::Value::as_array)
        .cloned()
        .unwrap_or_default();
    let next_cursor = json
        .get("cursor")
        .and_then(serde_json::Value::as_str)
        .map(ToOwned::to_owned);

    let generators = feeds
        .into_iter()
        .filter_map(|item| {
            let uri = item
                .get("uri")
                .and_then(serde_json::Value::as_str)
                .map(str::trim)
                .filter(|value| !value.is_empty())?
                .to_string();
            Some(CandidateFeedGenerator {
                uri,
                display_name: item
                    .get("displayName")
                    .and_then(serde_json::Value::as_str)
                    .unwrap_or("")
                    .trim()
                    .to_string(),
                description: item
                    .get("description")
                    .and_then(serde_json::Value::as_str)
                    .unwrap_or("")
                    .trim()
                    .to_string(),
                creator_handle: item
                    .get("creator")
                    .and_then(|creator| creator.get("handle"))
                    .and_then(serde_json::Value::as_str)
                    .unwrap_or("")
                    .trim()
                    .to_string(),
                creator_display_name: item
                    .get("creator")
                    .and_then(|creator| creator.get("displayName"))
                    .and_then(serde_json::Value::as_str)
                    .unwrap_or("")
                    .trim()
                    .to_string(),
            })
        })
        .collect();

    Ok((generators, next_cursor))
}

async fn fetch_bluesky_candidate_page(
    service_url: &str,
    access_jwt: &str,
    source: &BlueskyCandidateSource,
    cursor: Option<&str>,
    limit: usize,
) -> Result<(Vec<CandidateFeedPost>, Option<String>)> {
    let url = build_bluesky_feed_endpoint(service_url, source, cursor, limit);
    let response = reqwest::Client::builder()
        .timeout(Duration::from_secs(BLUESKY_FETCH_TIMEOUT_SECS))
        .build()?
        .get(url)
        .bearer_auth(access_jwt.trim())
        .send()
        .await
        .with_context(|| format!("Failed to fetch Bluesky {} feed", source.label))?;

    if !response.status().is_success() {
        let status = response.status();
        let body = response.text().await.unwrap_or_default();
        anyhow::bail!("Bluesky {} feed request failed ({status}): {body}", source.label);
    }

    let json: serde_json::Value = response
        .json()
        .await
        .with_context(|| format!("Failed to decode Bluesky {} feed response", source.label))?;
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
                feed_item,
                feed_source: source.feed_source.clone(),
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
    for source in [
        BlueskyCandidateSource::home_timeline(),
        BlueskyCandidateSource::discover_fallback(),
    ] {
        let (page, _) = fetch_bluesky_candidate_page(
            service_url,
            access_jwt,
            &source,
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

fn html_unescape_basic(raw: &str) -> String {
    raw.replace("&amp;", "&")
        .replace("&quot;", "\"")
        .replace("&#39;", "'")
        .replace("&lt;", "<")
        .replace("&gt;", ">")
        .replace("&nbsp;", " ")
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

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::tempdir;

    struct MockEmbedder;

    #[async_trait]
    impl memory::embeddings::EmbeddingProvider for MockEmbedder {
        fn name(&self) -> &str {
            "mock"
        }

        fn dimensions(&self) -> usize {
            3
        }

        async fn embed(&self, texts: &[&str]) -> anyhow::Result<Vec<Vec<f32>>> {
            Ok(texts
                .iter()
                .map(|text| {
                    let lower = text.to_ascii_lowercase();
                    if lower.contains("rust") || lower.contains("systems") {
                        vec![1.0, 0.0, 0.0]
                    } else if lower.contains("security") {
                        vec![0.0, 1.0, 0.0]
                    } else {
                        vec![0.0, 0.0, 1.0]
                    }
                })
                .collect())
        }
    }

    fn test_profile() -> FeedProfile {
        FeedProfile {
            status: "ready".to_string(),
            stats: InterestProfileStats {
                interest_count: 1,
                ..InterestProfileStats::default()
            },
            interests: vec![InterestVector {
                id: "i1".into(),
                label: "Rust systems".into(),
                embedding: vec![1.0, 0.0, 0.0],
                health_score: 1.0,
                source_path: "posts/rust-systems.md".into(),
                keywords: vec!["rust".into(), "systems".into()],
            }],
        }
    }

    fn weak_test_profile() -> FeedProfile {
        FeedProfile {
            status: "ready".to_string(),
            stats: InterestProfileStats {
                interest_count: 1,
                ..InterestProfileStats::default()
            },
            interests: vec![InterestVector {
                id: "i1".into(),
                label: "Rust systems".into(),
                embedding: vec![1.0, 0.0, 0.0],
                health_score: 0.2,
                source_path: "posts/rust-systems.md".into(),
                keywords: vec!["rust".into(), "systems".into()],
            }],
        }
    }

    fn test_config(workspace_dir: &Path) -> Config {
        let mut config = Config::default();
        config.workspace_dir = workspace_dir.to_path_buf();
        config.memory.embedding_provider = "none".to_string();
        config
    }

    fn sample_feed_item(url: &str) -> PersonalizedFeedItem {
        PersonalizedFeedItem {
            source_type: "web".into(),
            feed_item: serde_json::json!({ "url": url }),
            web_preview: Some(WebFeedPreview {
                url: url.to_string(),
                title: "Example item".into(),
                description: "Example description".into(),
                content_text: "Example article body".into(),
                image_url: None,
                domain: "example.com".into(),
                provider: "RSS/Atom".into(),
                provider_snippet: None,
                discovered_at: "2026-03-13T10:00:00Z".into(),
            }),
            feed_source: Some(FeedSourceContext {
                label: "Example Feed".into(),
                description: Some("Systems programming".into()),
                matched_interest_label: Some("Rust systems".into()),
                matched_interest_score: Some(0.91),
                source_score: Some(0.77),
            }),
            score: Some(0.88),
            matched_interest_label: Some("Rust systems".into()),
            matched_interest_score: Some(0.91),
            passed_threshold: true,
        }
    }

    fn ranked_candidate_for_test(
        url: &str,
        source_label: &str,
        score: f32,
        original_index: usize,
    ) -> RankedCandidate {
        RankedCandidate {
            dedupe_key: url.to_string(),
            item: PersonalizedFeedItem {
                source_type: "web".into(),
                feed_item: serde_json::json!({ "url": url }),
                web_preview: Some(WebFeedPreview {
                    url: url.to_string(),
                    title: source_label.to_string(),
                    description: "Example description".into(),
                    content_text: "Example article body".into(),
                    image_url: None,
                    domain: "example.com".into(),
                    provider: "RSS/Atom".into(),
                    provider_snippet: None,
                    discovered_at: "2026-03-13T10:00:00Z".into(),
                }),
                feed_source: Some(FeedSourceContext {
                    label: source_label.to_string(),
                    description: None,
                    matched_interest_label: None,
                    matched_interest_score: None,
                    source_score: Some(score),
                }),
                score: Some(score),
                matched_interest_label: None,
                matched_interest_score: None,
                passed_threshold: true,
            },
            original_index,
            score,
        }
    }

    fn seed_cached_world_feed(
        workspace_dir: &Path,
        item: &PersonalizedFeedItem,
        dirty: bool,
        refreshed_at: &str,
    ) {
        local_store::replace_personalized_feed_cache(
            workspace_dir,
            WORLD_FEED_KEY,
            &[local_store::PersonalizedFeedCacheUpsert {
                feed_key: WORLD_FEED_KEY.to_string(),
                cache_key: "item-1".into(),
                payload_json: serde_json::to_string(item).unwrap(),
                score: 0.88,
                sort_order: 0,
                refreshed_at: refreshed_at.to_string(),
            }],
        )
        .unwrap();
        local_store::upsert_personalized_feed_state(
            workspace_dir,
            &local_store::PersonalizedFeedStateUpsert {
                feed_key: WORLD_FEED_KEY.to_string(),
                dirty,
                refresh_status: "idle".into(),
                refreshed_at: refreshed_at.to_string(),
                refresh_started_at: refreshed_at.to_string(),
                refresh_finished_at: refreshed_at.to_string(),
                last_error: String::new(),
                profile_status: "ready".into(),
                profile_stats_json: serde_json::json!(InterestProfileStats {
                    interest_count: 1,
                    ..InterestProfileStats::default()
                })
                .to_string(),
                details_json: "{\"selectedSources\":[]}".into(),
            },
        )
        .unwrap();
    }

    fn seed_recent_rss_content(workspace_dir: &Path) {
        local_store::upsert_content_source(
            workspace_dir,
            &local_store::ContentSourceUpsert {
                source_key: "https://example.com/feed.xml".into(),
                domain: "example.com".into(),
                title: "Example Feed".into(),
                html_url: "https://example.com".into(),
                xml_url: "https://example.com/feed.xml".into(),
                source_kind: "rss".into(),
                enabled: true,
            },
        )
        .unwrap();
        local_store::upsert_content_item(
            workspace_dir,
            &local_store::ContentItemUpsert {
                id: "item-1".into(),
                source_key: "https://example.com/feed.xml".into(),
                source_title: "Example Feed".into(),
                source_kind: "rss".into(),
                domain: "example.com".into(),
                canonical_url: "https://example.com/posts/1".into(),
                external_id: "guid-1".into(),
                title: "Fallback item".into(),
                author: "Example Author".into(),
                summary: "Summary".into(),
                content_text: "Rust systems article".into(),
                content_hash: "hash-1".into(),
                embedding: Vec::new(),
                published_at: "2026-03-13T09:55:00Z".into(),
                discovered_at: "2026-03-13T10:00:00Z".into(),
            },
        )
        .unwrap();
    }

    #[tokio::test]
    async fn rss_source_metadata_ranking_prefers_matching_topics() {
        let workspace = tempdir().unwrap();
        local_store::initialize(workspace.path()).unwrap();
        local_store::upsert_feed_web_source(
            workspace.path(),
            &local_store::FeedWebSourceUpsert {
                domain: "systems.example".into(),
                title: "Systems".into(),
                html_url: "https://systems.example".into(),
                xml_url: "https://systems.example/feed.xml".into(),
                description: "Systems programming".into(),
                topics_csv: "rust,systems".into(),
                metadata_embedding: Vec::new(),
                enabled: true,
                source_kind: "seed".into(),
            },
        )
        .unwrap();
        local_store::upsert_feed_web_source(
            workspace.path(),
            &local_store::FeedWebSourceUpsert {
                domain: "security.example".into(),
                title: "Security".into(),
                html_url: "https://security.example".into(),
                xml_url: "https://security.example/feed.xml".into(),
                description: "Security news".into(),
                topics_csv: "security".into(),
                metadata_embedding: Vec::new(),
                enabled: true,
                source_kind: "seed".into(),
            },
        )
        .unwrap();

        let mut config = Config::default();
        config.workspace_dir = workspace.path().to_path_buf();
        let source = RssFeedSource::new(&config);
        let ranked = source.discover_sources(&test_profile()).await.unwrap();
        assert!(!ranked.is_empty());
        assert_eq!(ranked[0].label, "Systems");
    }

    #[tokio::test]
    async fn rss_source_fallback_prefers_best_scored_source_when_matches_are_weak() {
        let workspace = tempdir().unwrap();
        local_store::initialize(workspace.path()).unwrap();
        local_store::upsert_feed_web_source(
            workspace.path(),
            &local_store::FeedWebSourceUpsert {
                domain: "systems.example".into(),
                title: "Systems".into(),
                html_url: "https://systems.example".into(),
                xml_url: "https://systems.example/feed.xml".into(),
                description: "Systems programming".into(),
                topics_csv: "rust,systems".into(),
                metadata_embedding: Vec::new(),
                enabled: true,
                source_kind: "seed".into(),
            },
        )
        .unwrap();
        local_store::upsert_feed_web_source(
            workspace.path(),
            &local_store::FeedWebSourceUpsert {
                domain: "security.example".into(),
                title: "Security".into(),
                html_url: "https://security.example".into(),
                xml_url: "https://security.example/feed.xml".into(),
                description: "Security news".into(),
                topics_csv: "security".into(),
                metadata_embedding: Vec::new(),
                enabled: true,
                source_kind: "seed".into(),
            },
        )
        .unwrap();

        let mut config = Config::default();
        config.workspace_dir = workspace.path().to_path_buf();
        let source = RssFeedSource::new(&config);
        let ranked = source.discover_sources(&weak_test_profile()).await.unwrap();

        assert!(!ranked.is_empty());
        assert_eq!(ranked[0].label, "Systems");
        assert!(ranked.iter().all(|item| item.stage1_score < RSS_SOURCE_MATCH_THRESHOLD));
    }

    #[test]
    fn bluesky_source_fallback_includes_home_timeline() {
        let mut sources = Vec::new();
        append_unique_bluesky_sources(
            &mut sources,
            vec![BlueskyCandidateSource::home_timeline()],
        );
        append_unique_bluesky_sources(
            &mut sources,
            vec![BlueskyCandidateSource::home_timeline(), BlueskyCandidateSource::discover_fallback()],
        );
        assert!(sources.iter().any(|source| matches!(source.endpoint, BlueskyCandidateSourceEndpoint::HomeTimeline)));
    }

    #[test]
    fn fallback_bluesky_selected_sources_include_home_and_discover() {
        let sources = fallback_bluesky_selected_sources();
        assert!(sources.iter().any(|source| source.key == "home"));
        assert!(sources
            .iter()
            .any(|source| source.key == format!("feed:{BLUESKY_DISCOVER_FEED_URI}")));
    }

    #[test]
    fn fallback_nostr_selected_sources_include_primal() {
        let sources = fallback_nostr_selected_sources(&Config::default());
        assert!(sources
            .iter()
            .any(|source| source.key.eq_ignore_ascii_case(NOSTR_PRIMAL_FALLBACK_RELAY)));
    }

    #[tokio::test]
    async fn feed_ranker_batches_and_preserves_input_order_for_ties() {
        let profile = test_profile();
        let items = FeedRanker::rank_candidates(
            Arc::new(MockEmbedder),
            &profile,
            vec![
                FeedCandidate {
                    protocol: FeedProtocol::Rss,
                    dedupe_key: "a".into(),
                    stage1_score: 0.9,
                    rank_text: "rust systems".into(),
                    item: PersonalizedFeedItem {
                        source_type: "web".into(),
                        feed_item: serde_json::json!({"url":"https://example.com/a"}),
                        web_preview: Some(WebFeedPreview {
                            url: "https://example.com/a".into(),
                            title: "A".into(),
                            description: "desc".into(),
                            content_text: "Article A body".into(),
                            image_url: None,
                            domain: "example.com".into(),
                            provider: "RSS/Atom".into(),
                            provider_snippet: None,
                            discovered_at: "2026-03-13T10:00:00Z".into(),
                        }),
                        feed_source: None,
                        score: None,
                        matched_interest_label: None,
                        matched_interest_score: None,
                        passed_threshold: false,
                    },
                    original_index: 0,
                },
                FeedCandidate {
                    protocol: FeedProtocol::Rss,
                    dedupe_key: "b".into(),
                    stage1_score: 0.9,
                    rank_text: "rust systems".into(),
                    item: PersonalizedFeedItem {
                        source_type: "web".into(),
                        feed_item: serde_json::json!({"url":"https://example.com/b"}),
                        web_preview: Some(WebFeedPreview {
                            url: "https://example.com/b".into(),
                            title: "B".into(),
                            description: "desc".into(),
                            content_text: "Article B body".into(),
                            image_url: None,
                            domain: "example.com".into(),
                            provider: "RSS/Atom".into(),
                            provider_snippet: None,
                            discovered_at: "2026-03-13T10:00:00Z".into(),
                        }),
                        feed_source: None,
                        score: None,
                        matched_interest_label: None,
                        matched_interest_score: None,
                        passed_threshold: false,
                    },
                    original_index: 1,
                },
            ],
            10,
        )
        .await
        .unwrap();

        assert_eq!(items.len(), 2);
        assert_eq!(items[0].feed_item.get("url").and_then(serde_json::Value::as_str), Some("https://example.com/a"));
        assert_eq!(items[1].feed_item.get("url").and_then(serde_json::Value::as_str), Some("https://example.com/b"));
    }

    #[tokio::test]
    async fn feed_ranker_keeps_best_effort_items_when_no_candidate_passes_threshold() {
        let items = FeedRanker::rank_candidates(
            Arc::new(MockEmbedder),
            &weak_test_profile(),
            vec![FeedCandidate {
                protocol: FeedProtocol::Rss,
                dedupe_key: "best-effort".into(),
                stage1_score: 0.1,
                rank_text: "rust systems".into(),
                item: PersonalizedFeedItem {
                    source_type: "web".into(),
                    feed_item: serde_json::json!({"url":"https://example.com/best-effort"}),
                    web_preview: Some(WebFeedPreview {
                        url: "https://example.com/best-effort".into(),
                        title: "Best effort".into(),
                        description: "desc".into(),
                        content_text: "Best effort article body".into(),
                        image_url: None,
                        domain: "example.com".into(),
                        provider: "RSS/Atom".into(),
                        provider_snippet: None,
                        discovered_at: "2026-03-13T10:00:00Z".into(),
                    }),
                    feed_source: None,
                    score: None,
                    matched_interest_label: None,
                    matched_interest_score: None,
                    passed_threshold: false,
                },
                original_index: 0,
            }],
            10,
        )
        .await
        .unwrap();

        assert_eq!(items.len(), 1);
        assert_eq!(
            items[0]
                .feed_item
                .get("url")
                .and_then(serde_json::Value::as_str),
            Some("https://example.com/best-effort")
        );
        assert_eq!(items[0].matched_interest_label.as_deref(), Some("Rust systems"));
        assert_eq!(items[0].passed_threshold, false);
        assert!(items[0].score.unwrap_or_default() > 0.0);
    }

    #[test]
    fn interleave_ranked_candidates_by_source_rotates_sources() {
        let ranked = vec![
            ranked_candidate_for_test("https://example.com/a1", "Alpha", 0.95, 0),
            ranked_candidate_for_test("https://example.com/a2", "Alpha", 0.94, 1),
            ranked_candidate_for_test("https://example.com/b1", "Beta", 0.93, 2),
            ranked_candidate_for_test("https://example.com/b2", "Beta", 0.92, 3),
        ];
        let items = interleave_ranked_candidates_by_source(ranked, 4);
        assert_eq!(items[0].item.feed_source.as_ref().unwrap().label, "Alpha");
        assert_eq!(items[1].item.feed_source.as_ref().unwrap().label, "Beta");
        assert_eq!(items[2].item.feed_source.as_ref().unwrap().label, "Alpha");
        assert_eq!(items[3].item.feed_source.as_ref().unwrap().label, "Beta");
    }

    #[test]
    fn refresh_state_transitions_cover_fresh_stale_and_warming() {
        let mut state = default_feed_state_record();
        state.dirty = false;
        state.refreshed_at = Utc::now().to_rfc3339();
        assert_eq!(compute_refresh_state(true, &state, false), "fresh");
        state.dirty = true;
        assert_eq!(compute_refresh_state(true, &state, false), "stale");
        assert_eq!(compute_refresh_state(false, &state, true), "warming");
    }

    #[test]
    fn nostr_relay_http_url_converts_websocket_schemes() {
        assert_eq!(
            nostr_relay_http_url("wss://relay.example.com"),
            Some("https://relay.example.com".to_string())
        );
        assert_eq!(
            nostr_relay_http_url("ws://relay.example.com"),
            Some("http://relay.example.com".to_string())
        );
        assert_eq!(nostr_relay_http_url("https://relay.example.com"), None);
    }

    #[test]
    fn configured_nostr_world_feed_relays_prefers_explicit_relay_list() {
        let mut config = Config::default();
        config.channels_config.nostr = Some(crate::config::schema::NostrConfig {
            private_key: "nsec_test".into(),
            relays: vec![
                "wss://relay.primal.net".into(),
                "wss://relay.primal.net".into(),
                "https://not-a-relay.example".into(),
                "wss://nos.lol".into(),
            ],
            allowed_pubkeys: Vec::new(),
        });

        assert_eq!(
            configured_nostr_world_feed_relays(&config),
            vec![
                "wss://relay.primal.net".to_string(),
                "wss://nos.lol".to_string(),
            ]
        );
    }

    #[test]
    fn derive_interest_label_prefers_meaningful_content_over_generated_filename() {
        let label = derive_interest_label(
            "103944 Journal entry",
            "Super duper intelligence sitting in the cloud computing centers.\nThere is a lot of work we dont want to do",
        );
        assert_eq!(
            label,
            "Super duper intelligence sitting in the cloud computing centers."
        );
    }

    #[test]
    fn derive_interest_keywords_prefers_content_phrases_over_filename_artifacts() {
        let keywords = derive_interest_keywords(
            "insight 20260314 03",
            "A strong AI workflow does most of the production in the background and returns only the minimal questions that need human judgment.",
        );
        assert!(keywords.iter().any(|term| term.contains("workflow")));
        assert!(keywords.iter().any(|term| term.contains("human judgment") || term.contains("judgment")));
        assert!(!keywords.iter().any(|term| term.contains("20260314")));
        assert!(!keywords.iter().any(|term| term == "insight"));
    }

    #[tokio::test]
    async fn rebuild_interest_profile_prefers_persisted_triage_keywords() {
        let workspace = tempdir().unwrap();
        local_store::initialize(workspace.path()).unwrap();
        let journal_dir = workspace.path().join("journals/text/2026/03/28");
        std::fs::create_dir_all(&journal_dir).unwrap();
        let rel_path = "journals/text/2026/03/28/sample_note.md";
        let content = "I spent the day reflecting on product direction, parenting, and a lot of scattered emotions.";
        std::fs::write(workspace.path().join(rel_path), content).unwrap();

        local_store::upsert_feed_interest_source(
            workspace.path(),
            &local_store::FeedInterestSourceRecord {
                source_path: rel_path.to_string(),
                content_hash: content_hash_16(content),
                profile_input_hash: String::new(),
                interest_id: None,
                title: "sample note".into(),
                triage_keywords_json: serde_json::json!([
                    "local first",
                    "video workflow",
                    "feed ranking"
                ])
                .to_string(),
                updated_at: Utc::now().to_rfc3339(),
            },
        )
        .unwrap();

        let profile = rebuild_interest_profile(&test_config(workspace.path()))
            .await
            .unwrap();
        let labels: Vec<String> = profile.interests.iter().map(|item| item.label.clone()).collect();

        assert!(labels.iter().any(|term| term == "local first"));
        assert!(labels.iter().any(|term| term == "video workflow"));
        assert!(labels.iter().any(|term| term == "feed ranking"));
    }

    #[test]
    fn label_looks_auto_generated_flags_timestamp_and_insight_patterns() {
        assert!(label_looks_auto_generated("103944 Journal entry"));
        assert!(label_looks_auto_generated("insight 20260314 03"));
        assert!(!label_looks_auto_generated(
            "A strong AI workflow does most of the production in the background"
        ));
    }

    #[test]
    fn world_feed_message_reports_empty_ranked_result_without_warming_copy() {
        let message = world_feed_message(
            "ready",
            &InterestProfileStats {
                interest_count: 2,
                ..InterestProfileStats::default()
            },
            "fresh",
            true,
            "",
        );

        assert_eq!(
            message.as_deref(),
            Some(
                "No ranked world-feed matches landed yet. Showing recent sources while the next refresh widens the search."
            )
        );
    }

    #[tokio::test]
    async fn warm_cache_request_path_returns_cached_ranked_items() {
        let workspace = tempdir().unwrap();
        local_store::initialize(workspace.path()).unwrap();
        let refreshed_at = Utc::now().to_rfc3339();
        seed_cached_world_feed(
            workspace.path(),
            &sample_feed_item("https://example.com/posts/cached"),
            false,
            &refreshed_at,
        );

        let response = load_world_feed(&test_config(workspace.path()), None, 10, false)
            .await
            .unwrap();

        assert!(!response.used_fallback);
        assert_eq!(response.refresh_state, "fresh");
        assert_eq!(response.items.len(), 1);
        assert_eq!(
            response.items[0]
                .feed_item
                .get("url")
                .and_then(serde_json::Value::as_str),
            Some("https://example.com/posts/cached")
        );
    }

    #[tokio::test]
    async fn cold_cache_request_path_returns_recent_fallback_items_while_warming() {
        let workspace = tempdir().unwrap();
        local_store::initialize(workspace.path()).unwrap();
        seed_recent_rss_content(workspace.path());

        let response = load_world_feed(&test_config(workspace.path()), None, 10, false)
            .await
            .unwrap();

        assert!(response.used_fallback);
        assert_eq!(response.refresh_state, "warming");
        assert_eq!(response.items.len(), 1);
        assert_eq!(
            response.items[0]
                .web_preview
                .as_ref()
                .map(|preview| preview.url.as_str()),
            Some("https://example.com/posts/1")
        );
    }

    #[tokio::test]
    async fn stale_cache_request_path_returns_cached_items_and_marks_state_stale() {
        let workspace = tempdir().unwrap();
        local_store::initialize(workspace.path()).unwrap();
        let refreshed_at = Utc::now().to_rfc3339();
        seed_cached_world_feed(
            workspace.path(),
            &sample_feed_item("https://example.com/posts/stale"),
            true,
            &refreshed_at,
        );

        let response = load_world_feed(&test_config(workspace.path()), None, 10, false)
            .await
            .unwrap();

        assert!(!response.used_fallback);
        assert_eq!(response.refresh_state, "stale");
        assert_eq!(response.items.len(), 1);
        assert_eq!(
            response.items[0]
                .feed_item
                .get("url")
                .and_then(serde_json::Value::as_str),
            Some("https://example.com/posts/stale")
        );
    }
}
