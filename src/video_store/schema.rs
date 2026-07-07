//! SQLite schema and connection management for the local video store.
//!
//! A dedicated database file (`state/videos.db`) kept separate from
//! `nostr.db` and `local_data.db`, for the same reasons `nostr_store` is
//! isolated: no WAL contention, independent reset, portable storage layer.
//! The file lives strictly under `workspace_dir/state/`, honoring the
//! workspace-only file policy.
//!
//! Only post *metadata* is persisted here — never video bytes/blobs. The
//! `<video>` element still streams from the source CDN (HLS for Bluesky,
//! direct URLs for Nostr); the WebView/OS HTTP cache handles segments. This
//! store exists so the Reels/Media tabs render instantly from local data on
//! tab-open instead of waiting on the network fan-out every time.

use anyhow::{Context, Result};
use rusqlite::Connection;
use std::path::{Path, PathBuf};
use std::time::Duration;

/// Resolve the on-disk path of the video store.
///
/// Mirrors `nostr_store::schema::db_path` but uses a distinct filename so the
/// two stores do not share a WAL.
pub fn db_path(workspace_dir: &Path) -> PathBuf {
    workspace_dir.join("state").join("videos.db")
}

/// Open a connection configured for read/write workload.
///
/// Matches the nostr store pragmas: WAL journal, `synchronous=NORMAL`, a 5s
/// busy timeout so the background ingester and UI queries do not collide.
pub fn open_conn(path: &Path) -> Result<Connection> {
    let conn = Connection::open(path)
        .with_context(|| format!("Failed to open video store {}", path.display()))?;
    conn.busy_timeout(Duration::from_secs(5))
        .context("Failed to set video store busy timeout")?;
    conn.execute_batch(
        "PRAGMA journal_mode=WAL;
         PRAGMA synchronous=NORMAL;
         PRAGMA foreign_keys=ON;",
    )
    .context("Failed to configure video store pragmas")?;
    Ok(conn)
}

/// Create the state directory (if missing) and initialize the schema.
///
/// Idempotent — safe to call on every boot. Returns the resolved DB path so
/// callers can surface it in diagnostics.
pub fn initialize(workspace_dir: &Path) -> Result<PathBuf> {
    let path = db_path(workspace_dir);
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)
            .with_context(|| format!("Failed to create state directory {}", parent.display()))?;
    }
    let conn = open_conn(&path)?;
    init_schema(&conn)?;
    Ok(path)
}

/// Apply the schema. All statements use `IF NOT EXISTS` so this is safe to run
/// repeatedly without a version pragma — matching the nostr store convention.
fn init_schema(conn: &Connection) -> Result<()> {
    conn.execute_batch(
        "CREATE TABLE IF NOT EXISTS video_items (
            id TEXT PRIMARY KEY,
            source TEXT NOT NULL,
            created_at INTEGER NOT NULL,
            received_at TEXT NOT NULL,
            author_id TEXT NOT NULL DEFAULT '',
            author_handle TEXT NOT NULL DEFAULT '',
            author_name TEXT NOT NULL DEFAULT '',
            author_avatar TEXT NOT NULL DEFAULT '',
            caption TEXT NOT NULL DEFAULT '',
            video_url TEXT NOT NULL DEFAULT '',
            thumbnail_url TEXT NOT NULL DEFAULT '',
            aspect_w INTEGER,
            aspect_h INTEGER,
            like_count INTEGER,
            reply_count INTEGER,
            raw_json TEXT NOT NULL DEFAULT '{}'
        );
        CREATE INDEX IF NOT EXISTS idx_video_items_created
            ON video_items(created_at DESC);
        CREATE INDEX IF NOT EXISTS idx_video_items_source_created
            ON video_items(source, created_at DESC);
        ",
    )
    .context("Failed to initialize video store schema")?;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use tempfile::TempDir;

    fn workspace() -> TempDir {
        tempfile::tempdir().expect("tempdir")
    }

    #[test]
    fn initialize_creates_state_dir_and_schema() {
        let ws = workspace();
        let path = initialize(ws.path()).expect("init");
        assert!(path.ends_with("state/videos.db"));
        assert!(path.exists());

        // Re-running is a no-op (idempotent).
        let _ = initialize(ws.path()).expect("re-init");
    }

    #[test]
    fn open_conn_yields_working_connection() {
        let ws = workspace();
        let path = initialize(ws.path()).expect("init");
        let conn = open_conn(&path).expect("open");
        let count: i64 = conn
            .query_row("SELECT COUNT(*) FROM video_items", [], |row| row.get(0))
            .expect("count");
        assert_eq!(count, 0);
    }

    #[test]
    fn db_path_is_under_state_dir() {
        let ws = workspace();
        let p = db_path(ws.path());
        assert!(p.starts_with(ws.path().join("state")));
    }
}
