//! Local-first video store.
//!
//! A dedicated SQLite database (`state/videos.db`) that caches the *metadata*
//! of video-bearing posts from Bluesky and Nostr, so the Reels and Media tabs
//! render instantly from local data on tab-open instead of re-fetching from
//! the network every time. This mirrors the `nostr_store` "local relay" model.
//!
//! Only metadata is persisted — never video bytes/blobs. The `<video>` element
//! still streams from the source CDN (HLS for Bluesky, direct URLs for
//! Nostr); the WebView/OS HTTP cache handles segments. This store exists to
//! eliminate the tab-open network fan-out, which is the actual latency pain.
//!
//! Storage lives in the Rust core (not the Tauri host) so the gateway's
//! world-feed pipeline can also read from it in future, honoring the
//! inward-to-contracts dependency direction.
//!
//! See [`schema`], [`ingest`], and [`query`] for the three concerns.

pub mod ingest;
pub mod query;
pub mod schema;

// Re-export the most-used items for callers that want a flat namespace.
pub use ingest::{upsert_bluesky_posts, upsert_from_nostr_event};
pub use query::{
    count_by_source, last_received_at, query_videos, video_count, VideoQuery, VideoRecord,
};
pub use schema::{db_path, initialize, open_conn};
