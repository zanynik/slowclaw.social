//! Query: read video items back out of the local store.
//!
//! All public functions are synchronous and re-open the connection per call,
//! mirroring `nostr_store::query`. Callers running in an async context (Tauri
//! commands) wrap these in `spawn_blocking`.

use anyhow::{Context, Result};
use rusqlite::OptionalExtension;
use serde::{Deserialize, Serialize};
use std::path::Path;

use super::schema::{db_path, open_conn};

/// A stored video item, in the shape the frontend expects. Field names are
/// camelCase via serde so the JS side receives a consistent shape regardless
/// of source. `rawJson` carries the full original post/event so the UI can
/// reconstruct the source-specific render shape (e.g. `BlueskyPublicPost`)
/// without a re-fetch.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct VideoRecord {
    pub id: String,
    pub source: String,
    pub created_at: i64,
    /// ISO-8601 timestamp of when the row was last ingested (for status UI).
    pub received_at: String,
    #[serde(default)]
    pub author_id: String,
    #[serde(default)]
    pub author_handle: String,
    #[serde(default)]
    pub author_name: String,
    #[serde(default)]
    pub author_avatar: String,
    #[serde(default)]
    pub caption: String,
    #[serde(default)]
    pub video_url: String,
    #[serde(default)]
    pub thumbnail_url: String,
    #[serde(default)]
    pub aspect_w: Option<i64>,
    #[serde(default)]
    pub aspect_h: Option<i64>,
    #[serde(default)]
    pub like_count: Option<i64>,
    #[serde(default)]
    pub reply_count: Option<i64>,
    /// Full original post/event JSON. The frontend parses this back into the
    /// source-specific shape (e.g. `BlueskyPublicPost`) for rendering.
    #[serde(default)]
    pub raw_json: String,
}

/// Filter parameters for [`query_videos`]. All fields optional.
#[derive(Debug, Clone, Default)]
pub struct VideoQuery {
    /// Restrict to a source (`"bluesky"` or `"nostr"`). None = all sources.
    pub source: Option<String>,
    /// Only items at or after this UNIX timestamp.
    pub since: Option<i64>,
    /// Cap on rows returned. Defaults to 50 if unset.
    pub limit: Option<usize>,
}

/// Read video items matching the filter, newest-first.
pub fn query_videos(workspace_dir: &Path, query: &VideoQuery) -> Result<Vec<VideoRecord>> {
    let conn = open_conn(&db_path(workspace_dir))?;
    let mut sql = String::from(
        "SELECT id, source, created_at, received_at, author_id, author_handle,
                author_name, author_avatar, caption, video_url, thumbnail_url,
                aspect_w, aspect_h, like_count, reply_count, raw_json
         FROM video_items
         WHERE 1=1",
    );
    let mut args: Vec<Box<dyn rusqlite::ToSql>> = Vec::new();

    if let Some(source) = &query.source {
        sql.push_str(" AND source = ?");
        args.push(Box::new(source.clone()));
    }
    if let Some(since) = query.since {
        sql.push_str(" AND created_at >= ?");
        args.push(Box::new(since));
    }

    sql.push_str(" ORDER BY created_at DESC, id ASC LIMIT ?");
    let limit = i64::try_from(query.limit.unwrap_or(50).max(1)).unwrap_or(50);
    args.push(Box::new(limit));

    let mut stmt = conn.prepare(&sql)?;
    let arg_refs: Vec<&dyn rusqlite::ToSql> = args.iter().map(|b| b.as_ref()).collect();
    let rows = stmt
        .query_map(arg_refs.as_slice(), video_row_mapper)
        .context("Failed to query video items")?;
    let mut out = Vec::new();
    for row in rows {
        out.push(row?);
    }
    Ok(out)
}

/// Total stored video items (for the status UI).
pub fn video_count(workspace_dir: &Path) -> Result<i64> {
    let conn = open_conn(&db_path(workspace_dir))?;
    let count = conn
        .query_row("SELECT COUNT(*) FROM video_items", [], |row| row.get(0))
        .context("Failed to count video items")?;
    Ok(count)
}

/// Count items by source. Returns a map of source → count.
pub fn count_by_source(workspace_dir: &Path) -> Result<std::collections::HashMap<String, i64>> {
    let conn = open_conn(&db_path(workspace_dir))?;
    let mut stmt = conn.prepare("SELECT source, COUNT(*) FROM video_items GROUP BY source")?;
    let rows = stmt.query_map([], |row| {
        Ok((row.get::<_, String>(0)?, row.get::<_, i64>(1)?))
    })?;
    let mut out = std::collections::HashMap::new();
    for row in rows {
        let (source, count) = row?;
        out.insert(source, count);
    }
    Ok(out)
}

/// Most recent `received_at` value, for the status UI.
pub fn last_received_at(workspace_dir: &Path) -> Result<Option<String>> {
    let conn = open_conn(&db_path(workspace_dir))?;
    let value: Option<String> = conn
        .query_row(
            "SELECT received_at FROM video_items ORDER BY received_at DESC LIMIT 1",
            [],
            |row| row.get(0),
        )
        .optional()?;
    Ok(value)
}

fn video_row_mapper(row: &rusqlite::Row<'_>) -> rusqlite::Result<VideoRecord> {
    Ok(VideoRecord {
        id: row.get(0)?,
        source: row.get(1)?,
        created_at: row.get(2)?,
        received_at: row.get(3)?,
        author_id: row.get(4)?,
        author_handle: row.get(5)?,
        author_name: row.get(6)?,
        author_avatar: row.get(7)?,
        caption: row.get(8)?,
        video_url: row.get(9)?,
        thumbnail_url: row.get(10)?,
        aspect_w: row.get(11)?,
        aspect_h: row.get(12)?,
        like_count: row.get(13)?,
        reply_count: row.get(14)?,
        raw_json: row.get(15)?,
    })
}

#[cfg(test)]
mod tests {
    use super::super::ingest::test_support::{
        bluesky_video_post, init_workspace, make_note, pk_hex, workspace,
    };
    use super::super::ingest::{upsert_bluesky_posts, upsert_from_nostr_event};
    use super::*;
    use serde_json::json;

    fn workspace_with_videos() -> TempDir {
        let ws = workspace();
        init_workspace(&ws);

        // Two Bluesky posts (newer + older) and one Nostr video note.
        let bsky_new = bluesky_video_post(
            "at://did:plc:fake/app.bsky.feed.post/new",
            "https://video.bsky.app/playlist/new.m3u8",
            "2024-06-01T00:00:00Z",
            5,
        );
        let bsky_old = bluesky_video_post(
            "at://did:plc:fake/app.bsky.feed.post/old",
            "https://video.bsky.app/playlist/old.m3u8",
            "2024-01-01T00:00:00Z",
            1,
        );
        upsert_bluesky_posts(ws.path(), &[bsky_new, bsky_old]).expect("bluesky upsert");

        let note = make_note(
            "cc0000000000000000000000000000000000000000000000000000000000cc01",
            pk_hex(),
            1_717_192_000, // 2024-04-01ish — between the two bluesky posts
            "clip https://cdn.example.com/note.mp4",
        );
        upsert_from_nostr_event(ws.path(), &note).expect("nostr upsert");
        ws
    }

    use tempfile::TempDir;

    #[test]
    fn query_returns_newest_first() {
        let ws = workspace_with_videos();
        let items = query_videos(
            ws.path(),
            &VideoQuery {
                limit: Some(10),
                ..Default::default()
            },
        )
        .expect("query");
        assert_eq!(items.len(), 3);
        assert!(items[0].created_at >= items[1].created_at);
        assert!(items[1].created_at >= items[2].created_at);
    }

    #[test]
    fn query_filters_by_source() {
        let ws = workspace_with_videos();
        let bluesky = query_videos(
            ws.path(),
            &VideoQuery {
                source: Some("bluesky".to_string()),
                limit: Some(10),
                ..Default::default()
            },
        )
        .expect("query bluesky");
        assert_eq!(bluesky.len(), 2);
        assert!(bluesky.iter().all(|v| v.source == "bluesky"));

        let nostr = query_videos(
            ws.path(),
            &VideoQuery {
                source: Some("nostr".to_string()),
                limit: Some(10),
                ..Default::default()
            },
        )
        .expect("query nostr");
        assert_eq!(nostr.len(), 1);
        assert_eq!(nostr[0].source, "nostr");
    }

    #[test]
    fn query_filters_by_since() {
        let ws = workspace_with_videos();
        // 2024-03-01 = 1709251200. Should drop the Jan Bluesky post, keep Jun + Apr.
        let items = query_videos(
            ws.path(),
            &VideoQuery {
                since: Some(1_709_251_200),
                limit: Some(10),
                ..Default::default()
            },
        )
        .expect("query since");
        assert_eq!(items.len(), 2);
    }

    #[test]
    fn raw_json_roundtrips_for_bluesky() {
        let ws = workspace_with_videos();
        let items = query_videos(
            ws.path(),
            &VideoQuery {
                source: Some("bluesky".to_string()),
                limit: Some(1),
                ..Default::default()
            },
        )
        .expect("query");
        let parsed: serde_json::Value = serde_json::from_str(&items[0].raw_json).expect("parse");
        assert_eq!(
            parsed["uri"],
            json!("at://did:plc:fake/app.bsky.feed.post/new")
        );
    }

    #[test]
    fn count_by_source_reports_correct_totals() {
        let ws = workspace_with_videos();
        let counts = count_by_source(ws.path()).expect("counts");
        assert_eq!(counts.get("bluesky"), Some(&2));
        assert_eq!(counts.get("nostr"), Some(&1));
    }

    #[test]
    fn video_count_returns_total() {
        let ws = workspace_with_videos();
        assert_eq!(video_count(ws.path()).expect("count"), 3);
    }
}
