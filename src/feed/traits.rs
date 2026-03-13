use super::{FeedCandidate, FeedProfile, SelectedSource};
use anyhow::Result;
use async_trait::async_trait;

#[async_trait]
pub trait FeedSource: Send + Sync {
    async fn discover_sources(&self, profile: &FeedProfile) -> Result<Vec<SelectedSource>>;

    async fn fetch_candidates(
        &self,
        profile: &FeedProfile,
        selected_sources: &[SelectedSource],
        limit: usize,
    ) -> Result<Vec<FeedCandidate>>;
}
