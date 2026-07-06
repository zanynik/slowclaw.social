//! Ingest: persist [`nostr_sdk::Event`]s into the local store.
//!
//! Routing by kind:
//! - kind 0 (metadata)   -> `nostr_profiles` (newer `created_at` wins)
//! - kind 1 (text note)  -> `nostr_events` + tag index
//! - kind 7 (reaction)   -> `nostr_reactions`
//! - kind 30023 (article)-> `nostr_events` + tag index
//! - other kinds         -> `nostr_events` (stored generically, indexed)
//!
//! `npub` is precomputed once at ingest via `ToBech32`, retiring the per-render
//! browser-side `npubFromHex` hot path. Events are deduplicated by id
//! (`INSERT OR IGNORE`).

use anyhow::{Context, Result};
use chrono::Utc;
use nostr_sdk::prelude::{Event, ToBech32};
use rusqlite::{params, Connection};
use std::path::Path;

use super::schema::{db_path, open_conn};

/// Indexed tag names. We keep the inverted index narrow on purpose: only the
/// tag names the query layer actually uses (replies via `e`, mentions via `p`,
/// hashtag channels via `t`, NIP-23 `d`, NIP-33 `a`). Other tags remain
/// available via `nostr_events.tags_json` but are not separately indexed.
pub const INDEXED_TAG_NAMES: &[&str] = &["e", "p", "t", "d", "a"];

/// Kind constants as integers, for the routing `match`. `pub(crate)` so the
/// query module's tests can reuse them.
pub(crate) const KIND_METADATA: u16 = 0;
pub(crate) const KIND_TEXT_NOTE: u16 = 1;
pub(crate) const KIND_REACTION: u16 = 7;

/// Outcome of ingesting a single event. `Inserted == false` means the event id
/// was already present (dedup).
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct IngestOutcome {
    pub inserted: bool,
    pub kind: u16,
}

/// Inspect the kind and route the event to the right table(s).
pub fn ingest_event(workspace_dir: &Path, event: &Event) -> Result<IngestOutcome> {
    let conn = open_conn(&db_path(workspace_dir))?;
    ingest_event_with_conn(&conn, event)
}

/// Batch-ingest many events inside a single transaction.
pub fn ingest_events(workspace_dir: &Path, events: &[Event]) -> Result<usize> {
    let mut conn = open_conn(&db_path(workspace_dir))?;
    let tx = conn.transaction()?;
    let mut inserted = 0usize;
    for event in events {
        // `&tx` derefs to `&Connection` via rusqlite's Deref impl.
        if ingest_event_with_conn(&tx, event)?.inserted {
            inserted += 1;
        }
    }
    tx.commit()?;
    Ok(inserted)
}

/// Inner ingest taking a borrowed connection. Works for both `&Connection`
/// and `&Transaction` (Transaction derefs to Connection).
fn ingest_event_with_conn(conn: &Connection, event: &Event) -> Result<IngestOutcome> {
    let kind_u16 = event.kind.as_u16();
    match kind_u16 {
        KIND_METADATA => {
            upsert_profile_from_event_with_conn(conn, event)?;
            // kind-0 is metadata only; do not also store as a generic event.
            Ok(IngestOutcome {
                inserted: true,
                kind: kind_u16,
            })
        }
        KIND_REACTION => {
            upsert_reaction_from_event_with_conn(conn, event)?;
            Ok(IngestOutcome {
                inserted: true,
                kind: kind_u16,
            })
        }
        // Text notes (1), long-form articles (30023), and any other kind are
        // all stored generically via the events table + tag index. kind-0 and
        // kind-7 above are the only kinds that route to a dedicated table.
        _ => {
            let inserted = upsert_text_event_with_conn(conn, event)?;
            Ok(IngestOutcome {
                inserted,
                kind: kind_u16,
            })
        }
    }
}

/// Insert a kind-1 / kind-30023 / generic event plus its tag index rows.
/// Returns `false` if the event id was already present.
fn upsert_text_event_with_conn(conn: &Connection, event: &Event) -> Result<bool> {
    let id = event.id.to_hex();
    let pubkey = event.pubkey.to_hex();
    let npub = event
        .pubkey
        .to_bech32()
        .map_err(|e| anyhow::anyhow!("Failed to encode npub: {e}"))?;
    let kind_i64 = i64::from(event.kind.as_u16());
    let created_at_i64 = i64::try_from(event.created_at.as_secs()).unwrap_or(i64::MAX);
    let sig = format!("{}", event.sig);
    let tags_json = serialize_tags(event);
    let received_at = Utc::now().to_rfc3339();

    let inserted_rows = conn
        .execute(
            "INSERT OR IGNORE INTO nostr_events
                (id, pubkey, kind, content, created_at, sig, tags_json, received_at, npub)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9)",
            params![
                id,
                pubkey,
                kind_i64,
                event.content,
                created_at_i64,
                sig,
                tags_json,
                received_at,
                npub,
            ],
        )
        .with_context(|| format!("Failed to insert nostr event {id}"))?;

    if inserted_rows == 0 {
        // Already present; do not duplicate tag rows.
        return Ok(false);
    }

    // Index only the whitelisted tag names.
    let mut seen: std::collections::HashSet<(String, String)> = std::collections::HashSet::new();
    for tag in event.tags.iter() {
        let parts = tag.clone().to_vec();
        let Some(name) = parts.first().cloned() else {
            continue;
        };
        if !INDEXED_TAG_NAMES.contains(&name.as_str()) {
            continue;
        }
        let value = parts.get(1).cloned().unwrap_or_default();
        if value.is_empty() {
            continue;
        }
        let key = (name.clone(), value.clone());
        if !seen.insert(key) {
            continue;
        }
        conn.execute(
            "INSERT OR IGNORE INTO nostr_tags (event_id, tag_name, tag_value)
             VALUES (?1, ?2, ?3)",
            params![id, name, value],
        )
        .with_context(|| format!("Failed to index nostr tag for {id}"))?;
    }

    Ok(true)
}

/// Upsert a kind-0 metadata event into `nostr_profiles`. Newer `created_at`
/// wins; ties go to the incoming event.
fn upsert_profile_from_event_with_conn(conn: &Connection, event: &Event) -> Result<()> {
    let pubkey = event.pubkey.to_hex();
    let npub = event
        .pubkey
        .to_bech32()
        .map_err(|e| anyhow::anyhow!("Failed to encode npub: {e}"))?;
    let event_created_at = i64::try_from(event.created_at.as_secs()).unwrap_or(0);
    let raw_event_id = event.id.to_hex();
    let fetched_at = Utc::now().to_rfc3339();

    let metadata: nostr_sdk::Metadata = serde_json::from_str(&event.content).unwrap_or_default();
    let name = metadata.name.clone().unwrap_or_default();
    let display_name = metadata.display_name.clone().unwrap_or_default();
    let picture = metadata.picture.clone().unwrap_or_default();
    let about = metadata.about.clone().unwrap_or_default();
    let website = metadata.website.clone().unwrap_or_default();
    let nip05 = metadata.nip05.clone().unwrap_or_default();
    let content_json = if event.content.trim().is_empty() {
        "{}".to_string()
    } else {
        event.content.clone()
    };

    // Only update if incoming metadata is at least as recent as what we have.
    let existing_created_at: Option<i64> = conn
        .query_row(
            "SELECT event_created_at FROM nostr_profiles WHERE pubkey = ?1",
            params![pubkey],
            |row| row.get(0),
        )
        .ok();
    if let Some(existing) = existing_created_at {
        if event_created_at < existing {
            return Ok(());
        }
    }

    conn.execute(
        "INSERT INTO nostr_profiles
            (pubkey, npub, name, display_name, picture, about, website, nip05,
             content_json, raw_event_id, fetched_at, event_created_at)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12)
         ON CONFLICT(pubkey) DO UPDATE SET
            npub = excluded.npub,
            name = excluded.name,
            display_name = excluded.display_name,
            picture = excluded.picture,
            about = excluded.about,
            website = excluded.website,
            nip05 = excluded.nip05,
            content_json = excluded.content_json,
            raw_event_id = excluded.raw_event_id,
            fetched_at = excluded.fetched_at,
            event_created_at = excluded.event_created_at",
        params![
            pubkey,
            npub,
            name,
            display_name,
            picture,
            about,
            website,
            nip05,
            content_json,
            raw_event_id,
            fetched_at,
            event_created_at,
        ],
    )
    .with_context(|| format!("Failed to upsert nostr profile {pubkey}"))?;
    Ok(())
}

/// Upsert a kind-7 reaction. Primary key `(event_id, reactor_pubkey)` means
/// each reactor can register exactly one reaction per target note.
fn upsert_reaction_from_event_with_conn(conn: &Connection, event: &Event) -> Result<()> {
    let reactor_pubkey = event.pubkey.to_hex();
    let created_at_i64 = i64::try_from(event.created_at.as_secs()).unwrap_or(0);
    let content = event.content.clone();

    // Resolve the target note id from the first `e` tag.
    let mut target_event_id: Option<String> = None;
    for tag in event.tags.iter() {
        let parts = tag.clone().to_vec();
        if parts.first().map(String::as_str) == Some("e") {
            if let Some(val) = parts.get(1) {
                target_event_id = Some(val.clone());
                break;
            }
        }
    }

    let Some(event_id) = target_event_id else {
        // Reaction without a target note — nothing to attach to.
        return Ok(());
    };

    conn.execute(
        "INSERT INTO nostr_reactions
            (event_id, reactor_pubkey, content, created_at)
         VALUES (?1, ?2, ?3, ?4)
         ON CONFLICT(event_id, reactor_pubkey) DO UPDATE SET
            content = excluded.content,
            created_at = excluded.created_at",
        params![event_id, reactor_pubkey, content, created_at_i64],
    )
    .with_context(|| format!("Failed to upsert nostr reaction for {event_id}"))?;
    Ok(())
}

/// Serialize a Nostr event's tags to a JSON array of arrays, matching the
/// wire format (`[["e", id, relay, "reply"], ["p", pubkey], ...]`). This is
/// the form the frontend already understands from `web/src/lib/nostr.ts`.
fn serialize_tags(event: &Event) -> String {
    let raw: Vec<Vec<String>> = event.tags.iter().map(|tag| tag.clone().to_vec()).collect();
    serde_json::to_string(&raw).unwrap_or_else(|_| "[]".to_string())
}

/// Test helpers shared with `query` module's tests. Public within the crate
/// under `cfg(test)`.
#[cfg(test)]
pub(crate) mod test_support {
    use super::*;
    use nostr_sdk::prelude::{EventId, Kind, PublicKey, Signature, Tags, Timestamp};
    use std::str::FromStr;
    use tempfile::TempDir;

    pub const PK_HEX_A: &str = "3bf0c63fcb93463407af97ef5c6b13c30171b02d6b1fe9e9c1e4b4b4b4b4b4b4";
    pub const PK_HEX_B: &str = "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff";

    pub fn workspace() -> TempDir {
        tempfile::tempdir().expect("tempdir")
    }

    pub fn init_workspace(ws: &TempDir) {
        super::super::schema::initialize(ws.path()).expect("schema init");
    }

    /// Build a synthetic but validly-shaped event. Signature verification is
    /// irrelevant for store tests — relays verify; the store only persists the
    /// structural fields. `tags` accepts slice-of-slices so callers can write
    /// `&[["t", "nostr"], ["e", id, relay, "reply"]]` directly.
    pub fn make_event(
        id_hex: &str,
        pubkey_hex: &str,
        created_at_secs: u64,
        kind: u16,
        content: &str,
        tags: &[&[&str]],
    ) -> Event {
        let id = EventId::from_hex(id_hex).expect("id");
        let pubkey = PublicKey::from_hex(pubkey_hex).expect("pubkey");
        let timestamp = Timestamp::from_secs(created_at_secs);
        let parsed_tags: Vec<Vec<String>> = tags
            .iter()
            .map(|parts| parts.iter().map(|s| (*s).to_string()).collect())
            .collect();
        let tags_parsed = Tags::parse(parsed_tags).expect("tags");
        // Dummy 64-byte hex signature (does not need to verify for store tests).
        let sig = Signature::from_str(
            "0000000000000000000000000000000000000000000000000000000000000000\
             0000000000000000000000000000000000000000000000000000000000000000",
        )
        .expect("sig");
        Event::new(
            id,
            pubkey,
            timestamp,
            Kind::from(kind),
            tags_parsed,
            content,
            sig,
        )
    }
}

#[cfg(test)]
mod tests {
    use super::test_support::{init_workspace, make_event, workspace, PK_HEX_A, PK_HEX_B};
    use super::*;

    #[test]
    fn ingest_event_dedupes_by_id() {
        let ws = workspace();
        init_workspace(&ws);
        let ev = make_event(
            "aa0000000000000000000000000000000000000000000000000000000000aa01",
            PK_HEX_A,
            1_700_000_000,
            KIND_TEXT_NOTE,
            "hello",
            &[],
        );
        let outcome = ingest_event(ws.path(), &ev).expect("ingest 1");
        assert!(outcome.inserted);

        let again = ingest_event(ws.path(), &ev).expect("ingest 2");
        assert!(!again.inserted, "duplicate id must not be re-inserted");
    }

    #[test]
    fn ingest_event_prepares_tag_index() {
        let ws = workspace();
        init_workspace(&ws);
        let ev = make_event(
            "bb0000000000000000000000000000000000000000000000000000000000bb01",
            PK_HEX_A,
            1_700_000_001,
            KIND_TEXT_NOTE,
            "#nostr hello",
            &[&["t", "nostr"], &["e", "parent123", "wss://relay", "reply"]],
        );
        ingest_event(ws.path(), &ev).expect("ingest");

        let conn = open_conn(&db_path(ws.path())).expect("open");
        let hashtag_rows: i64 = conn
            .query_row(
                "SELECT COUNT(*) FROM nostr_tags WHERE tag_name = 't' AND tag_value = 'nostr'",
                [],
                |row| row.get(0),
            )
            .expect("count t");
        assert_eq!(hashtag_rows, 1);

        let reply_rows: i64 = conn
            .query_row(
                "SELECT COUNT(*) FROM nostr_tags WHERE tag_name = 'e' AND tag_value = 'parent123'",
                [],
                |row| row.get(0),
            )
            .expect("count e");
        assert_eq!(reply_rows, 1);
    }

    #[test]
    fn ingest_events_batch_is_transactional() {
        let ws = workspace();
        init_workspace(&ws);
        let ev1 = make_event(
            "cc0000000000000000000000000000000000000000000000000000000000cc01",
            PK_HEX_A,
            1_700_000_010,
            KIND_TEXT_NOTE,
            "one",
            &[],
        );
        let ev2 = make_event(
            "cc0000000000000000000000000000000000000000000000000000000000cc02",
            PK_HEX_B,
            1_700_000_020,
            KIND_TEXT_NOTE,
            "two",
            &[],
        );
        let inserted = ingest_events(ws.path(), &[ev1, ev2]).expect("batch");
        assert_eq!(inserted, 2);
    }

    #[test]
    fn profile_upsert_keeps_newest() {
        let ws = workspace();
        init_workspace(&ws);

        let old = make_event(
            "dd0000000000000000000000000000000000000000000000000000000000dd01",
            PK_HEX_A,
            1_700_000_000,
            KIND_METADATA,
            r#"{"name":"old_name","about":"v1"}"#,
            &[],
        );
        ingest_event(ws.path(), &old).expect("ingest old");

        let new = make_event(
            "dd0000000000000000000000000000000000000000000000000000000000dd02",
            PK_HEX_A,
            1_700_010_000,
            KIND_METADATA,
            r#"{"name":"new_name","about":"v2"}"#,
            &[],
        );
        ingest_event(ws.path(), &new).expect("ingest new");

        let conn = open_conn(&db_path(ws.path())).expect("open");
        let name: String = conn
            .query_row(
                "SELECT name FROM nostr_profiles WHERE pubkey = ?1",
                params![PK_HEX_A],
                |row| row.get(0),
            )
            .expect("select name");
        assert_eq!(name, "new_name");

        // Re-ingesting the older event must NOT clobber the newer one.
        ingest_event(ws.path(), &old).expect("re-ingest old");
        let name_again: String = conn
            .query_row(
                "SELECT name FROM nostr_profiles WHERE pubkey = ?1",
                params![PK_HEX_A],
                |row| row.get(0),
            )
            .expect("select name again");
        assert_eq!(name_again, "new_name");
    }

    #[test]
    fn reaction_targeting_note_is_stored() {
        let ws = workspace();
        init_workspace(&ws);
        let note = make_event(
            "ee0000000000000000000000000000000000000000000000000000000000ee01",
            PK_HEX_A,
            1_700_000_000,
            KIND_TEXT_NOTE,
            "react to me",
            &[],
        );
        ingest_event(ws.path(), &note).expect("ingest note");

        let reaction = make_event(
            "ee0000000000000000000000000000000000000000000000000000000000ee02",
            PK_HEX_B,
            1_700_000_500,
            KIND_REACTION,
            "+",
            &[&[
                "e",
                "ee0000000000000000000000000000000000000000000000000000000000ee01",
            ]],
        );
        ingest_event(ws.path(), &reaction).expect("ingest reaction");

        let conn = open_conn(&db_path(ws.path())).expect("open");
        let reaction_count: i64 = conn
            .query_row(
                "SELECT COUNT(*) FROM nostr_reactions WHERE event_id = ?1",
                params!["ee0000000000000000000000000000000000000000000000000000000000ee01"],
                |row| row.get(0),
            )
            .expect("count");
        assert_eq!(reaction_count, 1);
    }

    #[test]
    fn npub_is_precomputed_at_ingest() {
        let ws = workspace();
        init_workspace(&ws);
        let ev = make_event(
            "ff0000000000000000000000000000000000000000000000000000000000ff01",
            PK_HEX_A,
            1_700_000_000,
            KIND_TEXT_NOTE,
            "precompute me",
            &[],
        );
        ingest_event(ws.path(), &ev).expect("ingest");

        let conn = open_conn(&db_path(ws.path())).expect("open");
        let npub: String = conn
            .query_row(
                "SELECT npub FROM nostr_events WHERE id = ?1",
                params!["ff0000000000000000000000000000000000000000000000000000000000ff01"],
                |row| row.get(0),
            )
            .expect("select npub");
        assert!(npub.starts_with("npub1"), "npub should be bech32-encoded");
    }
}
