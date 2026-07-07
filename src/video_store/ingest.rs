//! Ingest: persist video-bearing posts into the local store.
//!
//! Two ingestion paths feed the `video_items` table:
//! - **Bluesky**: the frontend fetches posts over HTTP (already working) and
//!   passes the full post JSON here via IPC. We extract the HLS playlist +
//!   thumbnail + author/caption fields, upserting one row per post. The id is
//!   `bluesky:{uri}`.
//! - **Nostr**: the background ingester in `nostr_ingest.rs` calls
//!   [`upsert_from_nostr_event`] for every kind-1 note it drains. We scan the
//!   note's content + tags for video URLs (same regex as
//!   `web/src/lib/socialFeed.ts`) and upsert one row per video URL found. The
//!   id is `nostr:{event_id}:{url}` so a single note can surface multiple
//!   videos without collision.
//!
//! Only metadata is stored — never video bytes. Dedup is `INSERT OR REPLACE`
//! on the primary-key id, so re-ingesting an updated post (new like count,
//! edited caption) refreshes the row in place.

use anyhow::{Context, Result};
use chrono::Utc;
use nostr_sdk::prelude::{Event, ToBech32};
use regex::Regex;
use rusqlite::{params, Connection};
use serde_json::Value;
use std::path::Path;

use super::schema::{db_path, open_conn};

/// Video URL regex — mirrors `MEDIA_EXT_RE` in `web/src/lib/socialFeed.ts` so
/// Rust and TS agree on what counts as a video-bearing Nostr note. Matches
/// `.mp4`/`.mov`/`.webm`/`.m4v` (the Nostr path; Bluesky HLS `.m3u8` is handled
/// separately from the structured embed, not via this regex).
static NOSTR_VIDEO_URL_RE: std::sync::OnceLock<Regex> = std::sync::OnceLock::new();

fn video_url_regex() -> &'static Regex {
    NOSTR_VIDEO_URL_RE.get_or_init(|| {
        Regex::new(r#"https?://[^\s"'<>]+\.(?:mp4|mov|webm|m4v)"#)
            .expect("video url regex compiles")
    })
}

/// Upsert a batch of Bluesky posts (raw AppView JSON) inside one transaction.
/// Returns the number of rows written (posts that had a video embed).
pub fn upsert_bluesky_posts(workspace_dir: &Path, posts: &[Value]) -> Result<usize> {
    if posts.is_empty() {
        return Ok(0);
    }
    let mut conn = open_conn(&db_path(workspace_dir))?;
    let tx = conn.transaction()?;
    let mut written = 0usize;
    for post in posts {
        if upsert_bluesky_post_with_conn(&tx, post)? {
            written += 1;
        }
    }
    tx.commit()?;
    Ok(written)
}

/// Upsert a single Bluesky post. Returns `true` if a row was written (i.e. the
/// post had a video embed).
fn upsert_bluesky_post_with_conn(conn: &Connection, post: &Value) -> Result<bool> {
    let Some(video) = extract_bluesky_video(post) else {
        return Ok(false);
    };
    let uri = post
        .get("uri")
        .and_then(Value::as_str)
        .unwrap_or("")
        .to_string();
    if uri.is_empty() {
        return Ok(false);
    }
    let id = format!("bluesky:{uri}");

    let author = post.get("author").unwrap_or(&Value::Null);
    let created_at = bluesky_created_at(post);
    let caption = post
        .get("record")
        .and_then(|r| r.get("text"))
        .and_then(Value::as_str)
        .unwrap_or("")
        .to_string();
    let like_count = post.get("likeCount").and_then(Value::as_i64);
    let reply_count = post.get("replyCount").and_then(Value::as_i64);

    upsert_video_with_conn(
        conn,
        &id,
        "bluesky",
        created_at,
        author.get("did").and_then(Value::as_str).unwrap_or(""),
        author.get("handle").and_then(Value::as_str).unwrap_or(""),
        author
            .get("displayName")
            .and_then(Value::as_str)
            .unwrap_or(""),
        author.get("avatar").and_then(Value::as_str).unwrap_or(""),
        &caption,
        &video.playlist,
        &video.thumbnail,
        video.aspect_w,
        video.aspect_h,
        like_count,
        reply_count,
        post,
    )?;
    Ok(true)
}

/// Extract the video view (HLS playlist + thumbnail + aspect ratio) from a
/// Bluesky post's embed, handling `recordWithMedia` nesting. Mirrors
/// `blueskyVideoOf` in `web/src/lib/bluesky.ts`. Returns `None` when the post
/// has no video.
struct BlueskyVideo {
    playlist: String,
    thumbnail: String,
    aspect_w: Option<i64>,
    aspect_h: Option<i64>,
}

fn extract_bluesky_video(post: &Value) -> Option<BlueskyVideo> {
    let embed = post.get("embed")?;
    // Unwrap one level of recordWithMedia.
    let media = if embed
        .get("$type")
        .and_then(Value::as_str)
        .map(|t| t == "app.bsky.embed.recordWithMedia#view")
        .unwrap_or(false)
    {
        embed.get("media").unwrap_or(&Value::Null)
    } else {
        embed
    };
    let is_video = media
        .get("$type")
        .and_then(Value::as_str)
        .map(|t| t == "app.bsky.embed.video#view")
        .unwrap_or(false);
    if !is_video {
        return None;
    }
    // Two observed shapes: fields inlined (playlist/thumbnail) or nested under `video`.
    let nested = media.get("video").unwrap_or(&Value::Null);
    let playlist = media
        .get("playlist")
        .and_then(Value::as_str)
        .filter(|s| !s.is_empty())
        .or_else(|| nested.get("playlist").and_then(Value::as_str))
        .unwrap_or("")
        .to_string();
    let thumbnail = media
        .get("thumbnail")
        .and_then(Value::as_str)
        .filter(|s| !s.is_empty())
        .or_else(|| nested.get("thumbnail").and_then(Value::as_str))
        .unwrap_or("")
        .to_string();
    if playlist.is_empty() && thumbnail.is_empty() {
        return None;
    }
    let aspect = media
        .get("aspectRatio")
        .or_else(|| nested.get("aspectRatio"))
        .unwrap_or(&Value::Null);
    let aspect_w = aspect.get("width").and_then(Value::as_i64);
    let aspect_h = aspect.get("height").and_then(Value::as_i64);
    Some(BlueskyVideo {
        playlist,
        thumbnail,
        aspect_w,
        aspect_h,
    })
}

/// Epoch seconds from a Bluesky post. Prefers `indexedAt`, falls back to
/// `record.createdAt`. Mirrors `blueskyPostTimestamp` in `bluesky.ts`.
fn bluesky_created_at(post: &Value) -> i64 {
    let iso = post
        .get("indexedAt")
        .and_then(Value::as_str)
        .or_else(|| {
            post.get("record")
                .and_then(|r| r.get("createdAt"))
                .and_then(Value::as_str)
        })
        .unwrap_or("");
    parse_iso_to_epoch(iso)
}

fn parse_iso_to_epoch(iso: &str) -> i64 {
    if iso.is_empty() {
        return 0;
    }
    match chrono::DateTime::parse_from_rfc3339(iso) {
        Ok(dt) => dt.timestamp(),
        Err(_) => 0,
    }
}

/// Inspect a Nostr event for video URLs and upsert one row per URL found.
/// No-op when the note carries no video. Called from the background ingester's
/// drain loop for every kind-1 note.
pub fn upsert_from_nostr_event(workspace_dir: &Path, event: &Event) -> Result<usize> {
    let urls = extract_nostr_video_urls(event);
    if urls.is_empty() {
        return Ok(0);
    }
    let conn = open_conn(&db_path(workspace_dir))?;
    let pubkey = event.pubkey.to_hex();
    let npub = event
        .pubkey
        .to_bech32()
        .map_err(|e| anyhow::anyhow!("Failed to encode npub: {e}"))?;
    let created_at = i64::try_from(event.created_at.as_secs()).unwrap_or(0);
    let caption = event.content.clone();
    let raw = serde_json::to_string(event).unwrap_or_else(|_| "{}".to_string());

    let mut written = 0usize;
    for url in urls {
        let id = format!("nostr:{}:{}", event.id.to_hex(), url);
        upsert_video_with_conn(
            &conn,
            &id,
            "nostr",
            created_at,
            &pubkey,
            &npub,
            "",
            "",
            &caption,
            &url,
            "",
            None,
            None,
            None,
            None,
            &Value::String(raw.clone()),
        )?;
        written += 1;
    }
    Ok(written)
}

/// Scan a Nostr event's content + tags for video URLs. Mirrors
/// `extractNostrMedia` in `socialFeed.ts`: NIP-92 `imeta`/`url` tags first,
/// then a regex sweep of the body text.
fn extract_nostr_video_urls(event: &Event) -> Vec<String> {
    let mut urls: Vec<String> = Vec::new();
    let mut seen = std::collections::HashSet::new();

    // 1. Tags: NIP-92 imeta / url markers with a video extension.
    for tag in event.tags.iter() {
        let parts = tag.clone().to_vec();
        let Some(kind) = parts.first() else {
            continue;
        };
        let lk = kind.to_lowercase();
        if lk == "url" || lk == "imeta" {
            if let Some(value) = parts.get(1) {
                if is_video_url(value) && seen.insert(value.clone()) {
                    urls.push(value.clone());
                }
            }
        }
    }

    // 2. Fallback: regex sweep of the body text.
    for m in video_url_regex().find_iter(&event.content) {
        let url = m.as_str().to_string();
        if seen.insert(url.clone()) {
            urls.push(url);
        }
    }

    urls
}

fn is_video_url(s: &str) -> bool {
    let lower = s.to_ascii_lowercase();
    lower.ends_with(".mp4")
        || lower.ends_with(".mov")
        || lower.ends_with(".webm")
        || lower.ends_with(".m4v")
}

/// The shared upsert primitive. `raw` is serialized to `raw_json` so the
/// frontend can reconstruct the original post/event shape without a separate
/// fetch (the Reels player needs the full `BlueskyPublicPost`).
#[allow(clippy::too_many_arguments)]
fn upsert_video_with_conn(
    conn: &Connection,
    id: &str,
    source: &str,
    created_at: i64,
    author_id: &str,
    author_handle: &str,
    author_name: &str,
    author_avatar: &str,
    caption: &str,
    video_url: &str,
    thumbnail_url: &str,
    aspect_w: Option<i64>,
    aspect_h: Option<i64>,
    like_count: Option<i64>,
    reply_count: Option<i64>,
    raw: &Value,
) -> Result<()> {
    let received_at = Utc::now().to_rfc3339();
    let raw_json = serde_json::to_string(raw).unwrap_or_else(|_| "{}".to_string());
    conn.execute(
        "INSERT INTO video_items
            (id, source, created_at, received_at, author_id, author_handle,
             author_name, author_avatar, caption, video_url, thumbnail_url,
             aspect_w, aspect_h, like_count, reply_count, raw_json)
         VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10, ?11, ?12, ?13, ?14, ?15, ?16)
         ON CONFLICT(id) DO UPDATE SET
            source = excluded.source,
            created_at = excluded.created_at,
            received_at = excluded.received_at,
            author_id = excluded.author_id,
            author_handle = excluded.author_handle,
            author_name = excluded.author_name,
            author_avatar = excluded.author_avatar,
            caption = excluded.caption,
            video_url = excluded.video_url,
            thumbnail_url = excluded.thumbnail_url,
            aspect_w = excluded.aspect_w,
            aspect_h = excluded.aspect_h,
            like_count = excluded.like_count,
            reply_count = excluded.reply_count,
            raw_json = excluded.raw_json",
        params![
            id,
            source,
            created_at,
            received_at,
            author_id,
            author_handle,
            author_name,
            author_avatar,
            caption,
            video_url,
            thumbnail_url,
            aspect_w,
            aspect_h,
            like_count,
            reply_count,
            raw_json,
        ],
    )
    .with_context(|| format!("Failed to upsert video item {id}"))?;
    Ok(())
}

/// Test helpers shared with the query module's tests. Public within the crate
/// under `cfg(test)`.
#[cfg(test)]
pub(crate) mod test_support {
    use super::*;
    use nostr_sdk::prelude::{EventId, Keys, PublicKey, Signature, Tags, Timestamp};
    use std::str::FromStr;
    use tempfile::TempDir;

    pub fn workspace() -> TempDir {
        tempfile::tempdir().expect("tempdir")
    }

    pub fn init_workspace(ws: &TempDir) {
        super::super::schema::initialize(ws.path()).expect("schema init");
    }

    /// Build a synthetic but validly-shaped Nostr event with the given content.
    /// Signature verification is irrelevant for store tests.
    pub fn make_note(id_hex: &str, pubkey_hex: &str, created_at_secs: u64, content: &str) -> Event {
        let id = EventId::from_hex(id_hex).expect("id");
        let pubkey = PublicKey::from_hex(pubkey_hex).expect("pubkey");
        let timestamp = Timestamp::from_secs(created_at_secs);
        let sig = Signature::from_str(
            "0000000000000000000000000000000000000000000000000000000000000000\
             0000000000000000000000000000000000000000000000000000000000000000",
        )
        .expect("sig");
        Event::new(
            id,
            pubkey,
            timestamp,
            nostr_sdk::Kind::TextNote,
            Tags::parse(Vec::<Vec<String>>::new()).expect("tags"),
            content,
            sig,
        )
    }

    pub fn pk_hex() -> &'static str {
        "3bf0c63fcb93463407af97ef5c6b13c30171b02d6b1fe9e9c1e4b4b4b4b4b4b4"
    }

    /// A minimal Bluesky video post as serde_json::Value (matches the AppView shape).
    pub fn bluesky_video_post(
        uri: &str,
        playlist: &str,
        indexed_at: &str,
        like_count: i64,
    ) -> Value {
        serde_json::json!({
            "uri": uri,
            "cid": "fakecid",
            "author": {
                "did": "did:plc:fake",
                "handle": "example.bsky.social",
                "displayName": "Example User",
                "avatar": "https://cdn.example.com/avatar.jpg"
            },
            "record": {
                "text": "look at this video",
                "createdAt": indexed_at
            },
            "embed": {
                "$type": "app.bsky.embed.video#view",
                "playlist": playlist,
                "thumbnail": "https://cdn.example.com/thumb.jpg",
                "aspectRatio": { "width": 720, "height": 1280 }
            },
            "likeCount": like_count,
            "replyCount": 3,
            "indexedAt": indexed_at
        })
    }

    /// Silence unused-import warning for Keys (kept for future signing tests).
    #[allow(dead_code)]
    fn _keys_marker() -> Keys {
        Keys::generate()
    }
}

#[cfg(test)]
mod tests {
    use super::test_support::{bluesky_video_post, init_workspace, make_note, pk_hex, workspace};
    use super::*;
    use serde_json::json;

    #[test]
    fn upsert_bluesky_post_writes_video_row() {
        let ws = workspace();
        init_workspace(&ws);
        let post = bluesky_video_post(
            "at://did:plc:fake/app.bsky.feed.post/abc",
            "https://video.bsky.app/playlist/abc.m3u8",
            "2024-01-01T00:00:00Z",
            42,
        );
        let written = upsert_bluesky_posts(ws.path(), &[post]).expect("upsert");
        assert_eq!(written, 1);

        let conn = open_conn(&db_path(ws.path())).expect("open");
        let count: i64 = conn
            .query_row("SELECT COUNT(*) FROM video_items", [], |row| row.get(0))
            .expect("count");
        assert_eq!(count, 1);
        let video_url: String = conn
            .query_row(
                "SELECT video_url FROM video_items WHERE source = 'bluesky'",
                [],
                |row| row.get(0),
            )
            .expect("video_url");
        assert_eq!(video_url, "https://video.bsky.app/playlist/abc.m3u8");
    }

    #[test]
    fn upsert_bluesky_dedupes_by_uri() {
        let ws = workspace();
        init_workspace(&ws);
        let uri = "at://did:plc:fake/app.bsky.feed.post/abc";
        let post_v1 = bluesky_video_post(
            uri,
            "https://video.bsky.app/playlist/abc.m3u8",
            "2024-01-01T00:00:00Z",
            10,
        );
        let post_v2 = bluesky_video_post(
            uri,
            "https://video.bsky.app/playlist/abc.m3u8",
            "2024-01-01T00:00:00Z",
            99,
        );

        upsert_bluesky_posts(ws.path(), &[post_v1]).expect("upsert 1");
        upsert_bluesky_posts(ws.path(), &[post_v2]).expect("upsert 2");

        let conn = open_conn(&db_path(ws.path())).expect("open");
        let count: i64 = conn
            .query_row("SELECT COUNT(*) FROM video_items", [], |row| row.get(0))
            .expect("count");
        assert_eq!(count, 1, "same uri must not duplicate");
        let likes: i64 = conn
            .query_row("SELECT like_count FROM video_items", [], |row| row.get(0))
            .expect("likes");
        assert_eq!(likes, 99, "re-ingest must refresh the row");
    }

    #[test]
    fn upsert_bluesky_skips_non_video_post() {
        let ws = workspace();
        init_workspace(&ws);
        let post = json!({
            "uri": "at://did:plc:fake/app.bsky.feed.post/text",
            "author": { "did": "did:plc:fake", "handle": "example.bsky.social" },
            "record": { "text": "just text", "createdAt": "2024-01-01T00:00:00Z" },
            "embed": { "$type": "app.bsky.embed.images#view", "images": [] },
            "indexedAt": "2024-01-01T00:00:00Z"
        });
        let written = upsert_bluesky_posts(ws.path(), &[post]).expect("upsert");
        assert_eq!(written, 0);
    }

    #[test]
    fn upsert_from_nostr_event_extracts_video_url_from_content() {
        let ws = workspace();
        init_workspace(&ws);
        let note = make_note(
            "aa0000000000000000000000000000000000000000000000000000000000aa01",
            pk_hex(),
            1_700_000_000,
            "check this out https://cdn.example.com/clip.mp4 cool right",
        );
        let written = upsert_from_nostr_event(ws.path(), &note).expect("upsert");
        assert_eq!(written, 1);

        let conn = open_conn(&db_path(ws.path())).expect("open");
        let source: String = conn
            .query_row("SELECT source FROM video_items", [], |row| row.get(0))
            .expect("source");
        assert_eq!(source, "nostr");
        let video_url: String = conn
            .query_row("SELECT video_url FROM video_items", [], |row| row.get(0))
            .expect("video_url");
        assert_eq!(video_url, "https://cdn.example.com/clip.mp4");
    }

    #[test]
    fn upsert_from_nostr_event_is_noop_for_text_only() {
        let ws = workspace();
        init_workspace(&ws);
        let note = make_note(
            "bb0000000000000000000000000000000000000000000000000000000000bb01",
            pk_hex(),
            1_700_000_000,
            "just a text note, no media here",
        );
        let written = upsert_from_nostr_event(ws.path(), &note).expect("upsert");
        assert_eq!(written, 0);
    }
}
