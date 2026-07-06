//! Local-first Nostr store.
//!
//! A dedicated SQLite database (`state/nostr.db`) that caches Nostr events,
//! profiles, reactions, replies, and articles ingested by the background
//! ingester in the Tauri host. The store is the "local relay" the UI queries
//! instead of re-hitting remote relays on every feed load.
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
pub use ingest::{ingest_event, ingest_events, IngestOutcome};
pub use query::{
    event_count, get_articles, get_note, get_profiles, get_reactions, get_replies, get_sync_state,
    last_received_at, query_notes, reaction_count, set_sync_state, ArticleRecord, NoteQuery,
    NoteRecord, ProfileRecord,
};
pub use schema::{db_path, initialize, open_conn};
