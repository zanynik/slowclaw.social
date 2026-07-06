//! SQLite schema and connection management for the local Nostr store.
//!
//! This is a dedicated database file (`state/nostr.db`) kept separate from the
//! gateway's `local_data.db`. The separation avoids WAL contention, lets the
//! Nostr store be reset independently of app data, and keeps the storage layer
//! portable for a future LMDB/nostrdb swap. The file lives strictly under
//! `workspace_dir/state/`, honoring the workspace-only file policy.

use anyhow::{Context, Result};
use rusqlite::Connection;
use std::path::{Path, PathBuf};
use std::time::Duration;

/// Resolve the on-disk path of the Nostr store.
///
/// Mirrors the convention in `crate::gateway::local_store::db_path` but uses a
/// distinct filename so the two stores do not share a WAL.
pub fn db_path(workspace_dir: &Path) -> PathBuf {
    workspace_dir.join("state").join("nostr.db")
}

/// Open a connection configured for read/write workload.
///
/// Matches the gateway store pragmas: WAL journal, `synchronous=NORMAL`, a 5s
/// busy timeout so the background ingester and UI queries do not collide.
pub fn open_conn(path: &Path) -> Result<Connection> {
    let conn = Connection::open(path)
        .with_context(|| format!("Failed to open nostr store {}", path.display()))?;
    conn.busy_timeout(Duration::from_secs(5))
        .context("Failed to set nostr store busy timeout")?;
    conn.execute_batch(
        "PRAGMA journal_mode=WAL;
         PRAGMA synchronous=NORMAL;
         PRAGMA foreign_keys=ON;",
    )
    .context("Failed to configure nostr store pragmas")?;
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
/// repeatedly without a version pragma — matching the gateway store convention.
fn init_schema(conn: &Connection) -> Result<()> {
    conn.execute_batch(
        "CREATE TABLE IF NOT EXISTS nostr_events (
            id TEXT PRIMARY KEY,
            pubkey TEXT NOT NULL,
            kind INTEGER NOT NULL,
            content TEXT NOT NULL DEFAULT '',
            created_at INTEGER NOT NULL,
            sig TEXT NOT NULL DEFAULT '',
            tags_json TEXT NOT NULL DEFAULT '[]',
            received_at TEXT NOT NULL,
            npub TEXT NOT NULL DEFAULT ''
        );
        CREATE INDEX IF NOT EXISTS idx_nostr_events_pubkey_created
            ON nostr_events(pubkey, created_at DESC);
        CREATE INDEX IF NOT EXISTS idx_nostr_events_kind_created
            ON nostr_events(kind, created_at DESC);
        CREATE INDEX IF NOT EXISTS idx_nostr_events_created
            ON nostr_events(created_at DESC);

        CREATE TABLE IF NOT EXISTS nostr_tags (
            event_id TEXT NOT NULL,
            tag_name TEXT NOT NULL,
            tag_value TEXT NOT NULL DEFAULT '',
            PRIMARY KEY (event_id, tag_name, tag_value)
        );
        CREATE INDEX IF NOT EXISTS idx_nostr_tags_lookup
            ON nostr_tags(tag_name, tag_value, event_id);
        CREATE INDEX IF NOT EXISTS idx_nostr_tags_event
            ON nostr_tags(event_id);

        CREATE TABLE IF NOT EXISTS nostr_profiles (
            pubkey TEXT PRIMARY KEY,
            npub TEXT NOT NULL DEFAULT '',
            name TEXT NOT NULL DEFAULT '',
            display_name TEXT NOT NULL DEFAULT '',
            picture TEXT NOT NULL DEFAULT '',
            about TEXT NOT NULL DEFAULT '',
            website TEXT NOT NULL DEFAULT '',
            nip05 TEXT NOT NULL DEFAULT '',
            content_json TEXT NOT NULL DEFAULT '{}',
            raw_event_id TEXT NOT NULL DEFAULT '',
            fetched_at TEXT NOT NULL,
            event_created_at INTEGER NOT NULL DEFAULT 0
        );

        CREATE TABLE IF NOT EXISTS nostr_reactions (
            event_id TEXT NOT NULL,
            reactor_pubkey TEXT NOT NULL,
            content TEXT NOT NULL DEFAULT '',
            created_at INTEGER NOT NULL DEFAULT 0,
            PRIMARY KEY (event_id, reactor_pubkey)
        );
        CREATE INDEX IF NOT EXISTS idx_nostr_reactions_event
            ON nostr_reactions(event_id);

        CREATE TABLE IF NOT EXISTS nostr_sync_state (
            key TEXT PRIMARY KEY,
            value TEXT NOT NULL DEFAULT ''
        );
        ",
    )
    .context("Failed to initialize nostr store schema")?;
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
        assert!(path.ends_with("state/nostr.db"));
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
            .query_row("SELECT COUNT(*) FROM nostr_events", [], |row| row.get(0))
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
