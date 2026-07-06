//! Query: read notes, profiles, reactions, replies, and articles back out of
//! the local store.
//!
//! All public functions are synchronous and re-open the connection per call,
//! mirroring `crate::gateway::local_store`. Callers running in an async
//! context (Tauri commands) wrap these in `spawn_blocking`.

use anyhow::{Context, Result};
use chrono::Utc;
use rusqlite::{params, OptionalExtension};
use serde::{Deserialize, Serialize};
use std::collections::HashMap;
use std::fmt::Write as _;
use std::path::Path;

use super::schema::{db_path, open_conn};

/// A stored Nostr note, in the shape the frontend expects. Field names are
/// camelCase via serde so the JS side receives the existing `NostrNote`/
/// `NostrProfile` shapes unchanged.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct NoteRecord {
    pub id: String,
    pub pubkey: String,
    /// Precomputed at ingest time so the UI never re-encodes bech32 per card.
    #[serde(default)]
    pub npub: String,
    pub content: String,
    pub created_at: i64,
    pub kind: i64,
    /// Canonical JSON array-of-arrays form, e.g. `[["e","id","relay","reply"]]`.
    #[serde(default)]
    pub tags: Vec<Vec<String>>,
}

/// A cached profile (kind-0 metadata).
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq, Default)]
pub struct ProfileRecord {
    pub pubkey: String,
    #[serde(default)]
    pub npub: String,
    #[serde(default)]
    pub name: String,
    #[serde(default)]
    pub display_name: String,
    #[serde(default)]
    pub picture: String,
    #[serde(default)]
    pub about: String,
    #[serde(default)]
    pub website: String,
    #[serde(default)]
    pub nip05: String,
}

/// A stored long-form article (kind 30023). Carries title/image/summary pulled
/// from the `d`/`title`/`image`/`summary` tags where present.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub struct ArticleRecord {
    pub id: String,
    pub pubkey: String,
    #[serde(default)]
    pub npub: String,
    pub created_at: i64,
    pub content: String,
    #[serde(default)]
    pub title: String,
    #[serde(default)]
    pub image: String,
    #[serde(default)]
    pub summary: String,
    #[serde(default)]
    pub tags: Vec<Vec<String>>,
}

/// Filter parameters for `query_notes`. All fields optional.
#[derive(Debug, Clone, Default)]
pub struct NoteQuery {
    /// Restrict to these pubkeys (hex).
    pub authors: Option<Vec<String>>,
    /// Restrict to these hashtag values (lowercase, without `#`).
    pub hashtags: Option<Vec<String>>,
    /// Restrict to these kinds (e.g. 1, 30023).
    pub kinds: Option<Vec<i64>>,
    /// Only events at or after this UNIX timestamp.
    pub since: Option<i64>,
    /// Only events at or before this UNIX timestamp.
    pub until: Option<i64>,
    /// Cap on rows returned. Defaults to 50 if unset.
    pub limit: Option<usize>,
}

/// Read notes matching the filter, newest-first.
pub fn query_notes(workspace_dir: &Path, query: &NoteQuery) -> Result<Vec<NoteRecord>> {
    let conn = open_conn(&db_path(workspace_dir))?;
    let mut sql = String::from(
        "SELECT id, pubkey, npub, content, created_at, kind, tags_json
         FROM nostr_events
         WHERE 1=1",
    );
    let mut args: Vec<Box<dyn rusqlite::ToSql>> = Vec::new();

    if let Some(kinds) = &query.kinds {
        if !kinds.is_empty() {
            let placeholders = (0..kinds.len()).map(|_| "?").collect::<Vec<_>>().join(",");
            let _ = write!(sql, " AND kind IN ({placeholders})");
            for k in kinds {
                args.push(Box::new(*k));
            }
        }
    }
    if let Some(authors) = &query.authors {
        if !authors.is_empty() {
            let placeholders = (0..authors.len())
                .map(|_| "?")
                .collect::<Vec<_>>()
                .join(",");
            let _ = write!(sql, " AND pubkey IN ({placeholders})");
            for a in authors {
                args.push(Box::new(a.clone()));
            }
        }
    }
    if let Some(hashtags) = &query.hashtags {
        if !hashtags.is_empty() {
            let placeholders = (0..hashtags.len())
                .map(|_| "?")
                .collect::<Vec<_>>()
                .join(",");
            let _ = write!(
                sql,
                " AND id IN (SELECT event_id FROM nostr_tags \
                 WHERE tag_name = 't' AND tag_value IN ({placeholders}))"
            );
            for h in hashtags {
                args.push(Box::new(h.clone()));
            }
        }
    }
    if let Some(since) = query.since {
        sql.push_str(" AND created_at >= ?");
        args.push(Box::new(since));
    }
    if let Some(until) = query.until {
        sql.push_str(" AND created_at <= ?");
        args.push(Box::new(until));
    }

    sql.push_str(" ORDER BY created_at DESC, id ASC LIMIT ?");
    let limit = i64::try_from(query.limit.unwrap_or(50).max(1)).unwrap_or(50);
    args.push(Box::new(limit));

    let mut stmt = conn.prepare(&sql)?;
    let arg_refs: Vec<&dyn rusqlite::ToSql> = args.iter().map(|b| b.as_ref()).collect();
    let rows = stmt
        .query_map(arg_refs.as_slice(), note_row_mapper)
        .context("Failed to query nostr notes")?;
    let mut out = Vec::new();
    for row in rows {
        out.push(row?);
    }
    Ok(out)
}

/// Look up a single note by id.
pub fn get_note(workspace_dir: &Path, event_id: &str) -> Result<Option<NoteRecord>> {
    let conn = open_conn(&db_path(workspace_dir))?;
    let note = conn
        .query_row(
            "SELECT id, pubkey, npub, content, created_at, kind, tags_json
             FROM nostr_events
             WHERE id = ?1
             LIMIT 1",
            params![event_id],
            note_row_mapper,
        )
        .optional()?;
    Ok(note)
}

/// Fetch cached profiles for the given pubkeys. Returns only the pubkeys found.
/// Callers should diff against the input list to detect cache misses and
/// backfill from relays.
pub fn get_profiles(workspace_dir: &Path, pubkeys: &[String]) -> Result<Vec<ProfileRecord>> {
    if pubkeys.is_empty() {
        return Ok(Vec::new());
    }
    let conn = open_conn(&db_path(workspace_dir))?;
    let placeholders = (0..pubkeys.len())
        .map(|_| "?")
        .collect::<Vec<_>>()
        .join(",");
    let sql = format!(
        "SELECT pubkey, npub, name, display_name, picture, about, website, nip05
         FROM nostr_profiles
         WHERE pubkey IN ({placeholders})"
    );
    let mut stmt = conn.prepare(&sql)?;
    let pubkeys_ref: Vec<&dyn rusqlite::ToSql> =
        pubkeys.iter().map(|p| p as &dyn rusqlite::ToSql).collect();
    let rows = stmt
        .query_map(pubkeys_ref.as_slice(), |row| {
            Ok(ProfileRecord {
                pubkey: row.get(0)?,
                npub: row.get(1)?,
                name: row.get(2)?,
                display_name: row.get(3)?,
                picture: row.get(4)?,
                about: row.get(5)?,
                website: row.get(6)?,
                nip05: row.get(7)?,
            })
        })
        .context("Failed to query nostr profiles")?;
    let mut out = Vec::new();
    for row in rows {
        out.push(row?);
    }
    Ok(out)
}

/// Count reactions per target note id, excluding NIP-25 dislikes (content `-`).
pub fn get_reactions(workspace_dir: &Path, event_ids: &[String]) -> Result<HashMap<String, i64>> {
    if event_ids.is_empty() {
        return Ok(HashMap::new());
    }
    let conn = open_conn(&db_path(workspace_dir))?;
    let placeholders = (0..event_ids.len())
        .map(|_| "?")
        .collect::<Vec<_>>()
        .join(",");
    let sql = format!(
        "SELECT event_id, COUNT(*) FROM nostr_reactions
         WHERE content <> '-' AND event_id IN ({placeholders})
         GROUP BY event_id"
    );
    let mut stmt = conn.prepare(&sql)?;
    let ids_ref: Vec<&dyn rusqlite::ToSql> = event_ids
        .iter()
        .map(|p| p as &dyn rusqlite::ToSql)
        .collect();
    let rows = stmt
        .query_map(ids_ref.as_slice(), |row| {
            Ok((row.get::<_, String>(0)?, row.get::<_, i64>(1)?))
        })
        .context("Failed to query nostr reactions")?;
    let mut out = HashMap::new();
    for row in rows {
        let (id, count) = row?;
        out.insert(id, count);
    }
    Ok(out)
}

/// Resolve direct replies to a note via the `#e` tag index, newest-first.
pub fn get_replies(workspace_dir: &Path, event_id: &str) -> Result<Vec<NoteRecord>> {
    let conn = open_conn(&db_path(workspace_dir))?;
    let mut stmt = conn.prepare(
        "SELECT e.id, e.pubkey, e.npub, e.content, e.created_at, e.kind, e.tags_json
         FROM nostr_events e
         INNER JOIN nostr_tags t
           ON t.event_id = e.id
         WHERE t.tag_name = 'e' AND t.tag_value = ?1
         ORDER BY e.created_at DESC, e.id ASC",
    )?;
    let rows = stmt.query_map(params![event_id], note_row_mapper)?;
    let mut out = Vec::new();
    for row in rows {
        out.push(row?);
    }
    Ok(out)
}

/// Read kind-30023 articles, newest-first. Title/image/summary are pulled from
/// the corresponding NIP-23 tags where present.
pub fn get_articles(workspace_dir: &Path, limit: Option<usize>) -> Result<Vec<ArticleRecord>> {
    let conn = open_conn(&db_path(workspace_dir))?;
    let lim = i64::try_from(limit.unwrap_or(50).max(1)).unwrap_or(50);
    let mut stmt = conn.prepare(
        "SELECT id, pubkey, npub, created_at, content, tags_json
         FROM nostr_events
         WHERE kind = 30023
         ORDER BY created_at DESC, id ASC
         LIMIT ?1",
    )?;
    let rows = stmt.query_map(params![lim], |row| {
        let id: String = row.get(0)?;
        let pubkey: String = row.get(1)?;
        let npub: String = row.get(2)?;
        let created_at: i64 = row.get(3)?;
        let content: String = row.get(4)?;
        let tags_json: String = row.get(5)?;
        let tags: Vec<Vec<String>> = serde_json::from_str(&tags_json).unwrap_or_default();
        let mut title = String::new();
        let mut image = String::new();
        let mut summary = String::new();
        for tag in &tags {
            if let Some(name) = tag.first() {
                match name.as_str() {
                    "title" => title = tag.get(1).cloned().unwrap_or_default(),
                    "image" => image = tag.get(1).cloned().unwrap_or_default(),
                    "summary" => summary = tag.get(1).cloned().unwrap_or_default(),
                    _ => {}
                }
            }
        }
        Ok(ArticleRecord {
            id,
            pubkey,
            npub,
            created_at,
            content,
            title,
            image,
            summary,
            tags,
        })
    })?;
    let mut out = Vec::new();
    for row in rows {
        out.push(row?);
    }
    Ok(out)
}

/// Approximate event count, for the status UI.
pub fn event_count(workspace_dir: &Path) -> Result<i64> {
    let conn = open_conn(&db_path(workspace_dir))?;
    let count = conn
        .query_row("SELECT COUNT(*) FROM nostr_events", [], |row| row.get(0))
        .context("Failed to count nostr events")?;
    Ok(count)
}

/// Total stored reactions (for status UI).
pub fn reaction_count(workspace_dir: &Path) -> Result<i64> {
    let conn = open_conn(&db_path(workspace_dir))?;
    let count = conn
        .query_row("SELECT COUNT(*) FROM nostr_reactions", [], |row| row.get(0))
        .context("Failed to count nostr reactions")?;
    Ok(count)
}

/// Most recent `received_at` value across events, for the status UI.
pub fn last_received_at(workspace_dir: &Path) -> Result<Option<String>> {
    let conn = open_conn(&db_path(workspace_dir))?;
    let value: Option<String> = conn
        .query_row(
            "SELECT received_at FROM nostr_events ORDER BY received_at DESC LIMIT 1",
            [],
            |row| row.get(0),
        )
        .optional()?;
    Ok(value)
}

/// Read a sync-state cursor value (e.g. `since:<relay>`).
pub fn get_sync_state(workspace_dir: &Path, key: &str) -> Result<Option<String>> {
    let conn = open_conn(&db_path(workspace_dir))?;
    let value: Option<String> = conn
        .query_row(
            "SELECT value FROM nostr_sync_state WHERE key = ?1",
            params![key],
            |row| row.get(0),
        )
        .optional()?;
    Ok(value)
}

/// Upsert a sync-state cursor value.
pub fn set_sync_state(workspace_dir: &Path, key: &str, value: &str) -> Result<()> {
    let conn = open_conn(&db_path(workspace_dir))?;
    let now = Utc::now().to_rfc3339();
    conn.execute(
        "INSERT INTO nostr_sync_state (key, value) VALUES (?1, ?2)
         ON CONFLICT(key) DO UPDATE SET value = excluded.value",
        params![key, format!("{value}\t{now}")],
    )
    .with_context(|| format!("Failed to set nostr sync state {key}"))?;
    Ok(())
}

fn note_row_mapper(row: &rusqlite::Row<'_>) -> rusqlite::Result<NoteRecord> {
    let tags_json: String = row.get(6)?;
    let tags: Vec<Vec<String>> = serde_json::from_str(&tags_json).unwrap_or_default();
    Ok(NoteRecord {
        id: row.get(0)?,
        pubkey: row.get(1)?,
        npub: row.get(2)?,
        content: row.get(3)?,
        created_at: row.get(4)?,
        kind: row.get(5)?,
        tags,
    })
}

#[cfg(test)]
mod tests {
    use super::super::ingest::{self, test_support, KIND_METADATA, KIND_REACTION, KIND_TEXT_NOTE};
    use super::*;
    use tempfile::TempDir;

    fn workspace_with_events() -> TempDir {
        let ws = test_support::workspace();
        test_support::init_workspace(&ws);

        let note1 = make_event(
            "100000000000000000000000000000000000000000000000000000000000000a",
            test_support::PK_HEX_A,
            1_700_000_100,
            KIND_TEXT_NOTE,
            "#nostr hello world",
            &[&["t", "nostr"]],
        );
        let note2 = make_event(
            "100000000000000000000000000000000000000000000000000000000000000b",
            test_support::PK_HEX_B,
            1_700_000_200,
            KIND_TEXT_NOTE,
            "second post",
            &[&[
                "e",
                "100000000000000000000000000000000000000000000000000000000000000a",
            ]],
        );
        ingest::ingest_events(ws.path(), &[note1, note2]).expect("ingest");
        ws
    }

    // Re-export the shared helper locally so test bodies read cleanly.
    use test_support::make_event;

    #[test]
    fn query_notes_by_hashtag_uses_tag_index() {
        let ws = workspace_with_events();
        let notes = query_notes(
            ws.path(),
            &NoteQuery {
                hashtags: Some(vec!["nostr".to_string()]),
                limit: Some(10),
                ..Default::default()
            },
        )
        .expect("query");
        assert_eq!(notes.len(), 1);
        assert_eq!(notes[0].content, "#nostr hello world");
    }

    #[test]
    fn query_notes_returns_newest_first() {
        let ws = workspace_with_events();
        let notes = query_notes(
            ws.path(),
            &NoteQuery {
                limit: Some(10),
                ..Default::default()
            },
        )
        .expect("query");
        assert_eq!(notes.len(), 2);
        assert!(notes[0].created_at >= notes[1].created_at);
    }

    #[test]
    fn get_note_finds_by_id() {
        let ws = workspace_with_events();
        let opt = get_note(
            ws.path(),
            "100000000000000000000000000000000000000000000000000000000000000a",
        )
        .expect("get");
        assert!(opt.is_some());
        assert_eq!(opt.unwrap().content, "#nostr hello world");

        let miss = get_note(
            ws.path(),
            "deadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef",
        )
        .expect("get");
        assert!(miss.is_none());
    }

    #[test]
    fn get_replies_resolves_via_e_tag() {
        let ws = workspace_with_events();
        let replies = get_replies(
            ws.path(),
            "100000000000000000000000000000000000000000000000000000000000000a",
        )
        .expect("replies");
        assert_eq!(replies.len(), 1);
        assert_eq!(replies[0].content, "second post");
    }

    #[test]
    fn get_reactions_excludes_dislikes() {
        let ws = test_support::workspace();
        test_support::init_workspace(&ws);
        let note = make_event(
            "2000000000000000000000000000000000000000000000000000000000000001",
            test_support::PK_HEX_A,
            1_700_000_000,
            KIND_TEXT_NOTE,
            "react to me",
            &[],
        );
        let like = make_event(
            "2000000000000000000000000000000000000000000000000000000000000002",
            test_support::PK_HEX_B,
            1_700_000_050,
            KIND_REACTION,
            "+",
            &[&[
                "e",
                "2000000000000000000000000000000000000000000000000000000000000001",
            ]],
        );
        let dislike = make_event(
            "2000000000000000000000000000000000000000000000000000000000000003",
            "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
            1_700_000_060,
            KIND_REACTION,
            "-",
            &[&[
                "e",
                "2000000000000000000000000000000000000000000000000000000000000001",
            ]],
        );
        ingest::ingest_events(ws.path(), &[note, like, dislike]).expect("ingest");

        let counts = get_reactions(
            ws.path(),
            &["2000000000000000000000000000000000000000000000000000000000000001".to_string()],
        )
        .expect("reactions");
        assert_eq!(
            counts.get("2000000000000000000000000000000000000000000000000000000000000001"),
            Some(&1),
            "dislike (content '-') must be excluded"
        );
    }

    #[test]
    fn get_profiles_returns_only_cached() {
        let ws = test_support::workspace();
        test_support::init_workspace(&ws);
        let pk_a = test_support::PK_HEX_A;
        let pk_b = test_support::PK_HEX_B;
        let profile_a = make_event(
            "3000000000000000000000000000000000000000000000000000000000000001",
            pk_a,
            1_700_000_000,
            KIND_METADATA,
            r#"{"name":"alice","about":"hi"}"#,
            &[],
        );
        ingest::ingest_event(ws.path(), &profile_a).expect("ingest");

        let profiles =
            get_profiles(ws.path(), &[pk_a.to_string(), pk_b.to_string()]).expect("profiles");
        assert_eq!(profiles.len(), 1, "only pk_a should be present");
        assert_eq!(profiles[0].name, "alice");
    }

    #[test]
    fn sync_state_round_trips() {
        let ws = test_support::workspace();
        test_support::init_workspace(&ws);
        assert!(get_sync_state(ws.path(), "since:relay1")
            .expect("get")
            .is_none());
        set_sync_state(ws.path(), "since:relay1", "1700000000").expect("set");
        let value = get_sync_state(ws.path(), "since:relay1")
            .expect("get")
            .unwrap();
        assert!(value.starts_with("1700000000"));
    }
}
