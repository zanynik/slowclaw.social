use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum FeedProtocol {
    Bluesky,
    Rss,
    Nostr,
    Web,
}

impl FeedProtocol {
    pub fn source_type(&self) -> &'static str {
        match self {
            Self::Bluesky => "bluesky",
            Self::Rss | Self::Nostr | Self::Web => "web",
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
    pub web: FeedProtocolDiagnostics,
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
