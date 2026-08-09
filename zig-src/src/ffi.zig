//! C ABI boundary — exposes the slowclaw_feed package to Swift (and any other
//! C-ABI consumer). This is the slice that makes the Zig core reachable from
//! the iOS app.
//!
//! ## Conventions
//!
//! - **Strings in**: caller-owned UTF-8 bytes + length. Zig never frees these.
//! - **Strings out**: Zig allocates with `slowclaw_feed_alloc` and returns a
//!   pointer; the caller frees with `slowclaw_feed_free`. (See `SlowclawString`.)
//! - **Error reporting**: C ABI can't propagate Zig errors. Functions return an
//!   integer status code (`0` = OK, negative = error); a `*SlowclawString` out-
//!   param receives the error message when present.
//! - **Embedder callback** (later slice): Swift passes a C function pointer
//!   matching `SlowclawEmbedFunction`. For now, the ranker entrypoint below
//!   uses the deterministic `HashEmbedding` so the round-trip is testable
//!   without a real embedder.
//!
//! ## Memory ownership flow (rank example)
//!
//!   1. Swift builds `SlowclawInterest`/`SlowclawCandidate` arrays.
//!   2. Swift calls `slowclaw_feed_rank_hash(...)`.
//!   3. Zig allocates a `SlowclawRankResult` containing ranked items as JSON.
//!   4. Swift reads `items_json`, copies what it needs, then calls
//!      `slowclaw_feed_rank_result_free(...)`.
//!
//! All allocation goes through a single `std.heap.c_allocator` so Swift's
//! `free` and Zig's allocator agree.

const std = @import("std");
const testing = std.testing;

const ranker = @import("ranker.zig");
const embeddings = @import("embeddings.zig");
const feed_types = @import("feed_types.zig");
const sqlite = @import("sqlite.zig");
const memory_types = @import("memory_types.zig");
const sync_engine = @import("sync_engine.zig");
const provider_mod = @import("provider.zig");
const openai_provider_mod = @import("openai_provider.zig");
const journal_agent = @import("journal_agent.zig");
const rss_parser = @import("rss_parser.zig");
const feeds_ranking = @import("feeds_ranking.zig");
const feed_catalog = @import("feed_catalog.zig");
const local_inference = @import("local_inference.zig");

/// C allocator — pairs with `free` on the Swift side. Using this ensures Zig
/// and Swift agree on the heap.
const c_allocator = std.heap.c_allocator;

// ──────────────────────────────────────────────────────────────────────────
// Opaque types passed across the boundary
// ──────────────────────────────────────────────────────────────────────────

/// A length-prefixed UTF-8 string owned by Zig. The caller frees the `bytes`
/// pointer via `slowclaw_feed_free`. `bytes` is NOT null-terminated — the
/// caller must respect `len`.
pub const SlowclawString = extern struct {
    bytes: ?[*]const u8,
    len: usize,

    /// Build from a Zig-owned slice (caller transfers ownership of `s`).
    fn fromOwnedSlice(s: []const u8) SlowclawString {
        return .{ .bytes = s.ptr, .len = s.len };
    }

    fn empty() SlowclawString {
        return .{ .bytes = null, .len = 0 };
    }
};

/// Status codes returned across the C ABI.
pub const SLOWCLAW_OK: c_int = 0;
pub const SLOWCLAW_ERR_INVALID_ARGUMENT: c_int = -1;
pub const SLOWCLAW_ERR_OUT_OF_MEMORY: c_int = -2;
pub const SLOWCLAW_ERR_INTERNAL: c_int = -3;
pub const SLOWCLAW_ERR_EMBEDDER_MISMATCH: c_int = -4;

/// An interest vector for ranking. Strings are caller-owned UTF-8 + length
/// (Zig does not free them). `embedding` is a pointer to `embedding_len` f32s.
pub const SlowclawInterest = extern struct {
    id: [*]const u8,
    id_len: usize,
    label: [*]const u8,
    label_len: usize,
    embedding: [*]const f32,
    embedding_len: usize,
    health_score: f32,
    source_path: [*]const u8,
    source_path_len: usize,
    keywords: [*]const SlowclawStringSlice,
    keywords_len: usize,
};

pub const SlowclawStringSlice = extern struct {
    bytes: [*]const u8,
    len: usize,
};

/// A candidate to rank.
pub const SlowclawCandidate = extern struct {
    dedupe_key: [*]const u8,
    dedupe_key_len: usize,
    stage1_score: f32,
    rank_text: [*]const u8,
    rank_text_len: usize,
    source_type: [*]const u8,
    source_type_len: usize,
    /// Optional RFC3339 timestamp used for the freshness bonus. Pass
    /// `{ null, 0 }` if absent.
    discovered_at: ?[*]const u8,
    discovered_at_len: usize,
    original_index: usize,
};

/// Ranked result. `items_json` is a Zig-owned UTF-8 JSON array of ranked items
/// (each item has `score`, `matched_interest_label`, `passed_threshold`,
/// `source_type`, `discovered_at`). The caller frees the whole result via
/// `slowclaw_feed_rank_result_free`.
pub const SlowclawRankResult = extern struct {
    items_json: SlowclawString,
    /// Status code echoed for caller convenience (0 = OK).
    status: c_int,
};

// ──────────────────────────────────────────────────────────────────────────
// Allocation primitives exported to Swift.
// ──────────────────────────────────────────────────────────────────────────

/// Free any pointer returned by this library. Safe to call on null.
/// Equivalent to C `free`. Exposed so Swift doesn't need to know which
/// allocator Zig used.
pub export fn slowclaw_feed_free(ptr: ?*anyopaque) void {
    if (ptr) |p| {
        // `c_allocator` backs every allocation in this module, so a plain
        // `free` matches. The slice's full length isn't known here, but C's
        // `free` only needs the pointer.
        std.c.free(p);
    }
}

// ──────────────────────────────────────────────────────────────────────────
// HashEmbedding — direct one-shot embed exposed to Swift (useful for testing
// and for index-time embedding when the on-device CoreML provider isn't wired
// up yet).
// ──────────────────────────────────────────────────────────────────────────

/// Opaque handle to a `HashEmbedding` instance. Created by
/// `slowclaw_feed_hash_embedder_new`, destroyed by
/// `slowclaw_feed_hash_embedder_free`.
pub const SlowclawHashEmbedder = opaque {};

pub export fn slowclaw_feed_hash_embedder_new(model: [*]const u8, model_len: usize, dims: usize) ?*SlowclawHashEmbedder {
    const model_slice = model[0..model_len];
    const he = c_allocator.create(embeddings.HashEmbedding) catch return null;
    he.* = embeddings.HashEmbedding.init(model_slice, dims);
    return @ptrCast(he);
}

pub export fn slowclaw_feed_hash_embedder_free(handle: ?*SlowclawHashEmbedder) void {
    if (handle) |h| {
        const he: *embeddings.HashEmbedding = @ptrCast(@alignCast(h));
        c_allocator.destroy(he);
    }
}

/// Embed a single text. The returned `SlowclawString.bytes` points to a
/// Zig-owned buffer of `dims * sizeof(f32)` bytes; the caller frees it via
/// `slowclaw_feed_free`. On error returns a SlowclawString with null bytes.
pub export fn slowclaw_feed_hash_embed(
    handle: *SlowclawHashEmbedder,
    text: [*]const u8,
    text_len: usize,
    out_dims: *usize,
) SlowclawString {
    const he: *embeddings.HashEmbedding = @ptrCast(@alignCast(handle));
    const text_slice = text[0..text_len];
    const vec = embeddings.HashEmbedding.embed_text(c_allocator, he, text_slice) catch {
        return SlowclawString.empty();
    };
    out_dims.* = vec.len;
    // Reinterpret the f32 slice as bytes for transport.
    const byte_len = vec.len * @sizeOf(f32);
    const byte_ptr: [*]const u8 = @ptrCast(vec.ptr);
    return .{ .bytes = byte_ptr, .len = byte_len };
}

// ──────────────────────────────────────────────────────────────────────────
// rank_candidates_stage2 — the keyword-path orchestrator. Exposed because it
// needs NO embedder callback, making it the simplest end-to-end entrypoint.
// ──────────────────────────────────────────────────────────────────────────

pub export fn slowclaw_feed_rank_stage2(
    interests: [*]const SlowclawInterest,
    interests_len: usize,
    negative_interests: [*]const SlowclawInterest,
    negative_interests_len: usize,
    candidates: [*]const SlowclawCandidate,
    candidates_len: usize,
    limit: usize,
    now_epoch_seconds: i64,
    out_err: ?*SlowclawString,
) SlowclawRankResult {
    const interests_slice = interests[0..interests_len];
    const negatives_slice = negative_interests[0..negative_interests_len];
    const candidates_slice = candidates[0..candidates_len];

    // Convert C structs into Zig feed_types.
    var zig_interests = std.ArrayList(feed_types.InterestVector).empty;
    defer {
        for (zig_interests.items) |iv| freeInterest(iv);
        zig_interests.deinit(c_allocator);
    }
    for (interests_slice) |ci| zig_interests.append(c_allocator, dupInterest(ci)) catch return errResult(SLOWCLAW_ERR_OUT_OF_MEMORY, out_err);

    var zig_negatives = std.ArrayList(feed_types.InterestVector).empty;
    defer {
        for (zig_negatives.items) |iv| freeInterest(iv);
        zig_negatives.deinit(c_allocator);
    }
    for (negatives_slice) |ci| zig_negatives.append(c_allocator, dupInterest(ci)) catch return errResult(SLOWCLAW_ERR_OUT_OF_MEMORY, out_err);

    var zig_candidates = std.ArrayList(feed_types.FeedCandidate).empty;
    defer {
        for (zig_candidates.items) |fc| freeCandidate(fc);
        zig_candidates.deinit(c_allocator);
    }
    for (candidates_slice, 0..) |cc, i| zig_candidates.append(c_allocator, dupCandidate(cc, i)) catch return errResult(SLOWCLAW_ERR_OUT_OF_MEMORY, out_err);

    const profile = feed_types.FeedProfile{
        .interests = zig_interests.items,
        .negative_interests = zig_negatives.items,
    };

    const items = ranker.rank_candidates_stage2(c_allocator, profile, zig_candidates.items, limit, now_epoch_seconds) catch |err| {
        return errResult(toStatus(err), out_err);
    };
    defer c_allocator.free(items);

    const json = serializeItems(c_allocator, items) catch return errResult(SLOWCLAW_ERR_OUT_OF_MEMORY, out_err);
    return .{ .items_json = SlowclawString.fromOwnedSlice(json), .status = SLOWCLAW_OK };
}

// ──────────────────────────────────────────────────────────────────────────
// Result freeing.
// ──────────────────────────────────────────────────────────────────────────

pub export fn slowclaw_feed_rank_result_free(result: *SlowclawRankResult) void {
    if (result.items_json.bytes) |b| {
        const slice = b[0..result.items_json.len];
        c_allocator.free(slice);
        result.* = .{ .items_json = SlowclawString.empty(), .status = SLOWCLAW_OK };
    }
}

// ──────────────────────────────────────────────────────────────────────────
// SQLite memory store — Swift-callable persistence API.
// ──────────────────────────────────────────────────────────────────────────

/// Opaque handle to a `SqliteMemory` instance.
pub const SlowclawSqlite = opaque {};

/// A memory entry returned from get/list/recall. `id`/`key`/`content`/
/// `category`/`timestamp`/`session_id`/`source`/`media_url` are all Zig-owned
/// UTF-8; the caller frees the entire result via `slowclaw_feed_sqlite_entry_free`.
pub const SlowclawSqliteEntry = extern struct {
    id: SlowclawString,
    key: SlowclawString,
    content: SlowclawString,
    /// Lowercase category name (e.g. "core", "daily", "conversation", or the
    /// custom name). Mirrors `MemoryCategory.toString()`.
    category: SlowclawString,
    timestamp: SlowclawString,
    session_id: SlowclawString, // bytes=null when absent
    /// Provenance tag ("audio_recorded"/"audio_imported"/"text"). bytes=null
    /// for legacy rows or typed entries that didn't set it.
    source: SlowclawString,
    /// Documents-relative path to the linked audio file. bytes=null when absent.
    media_url: SlowclawString,
    /// Optional recall score (NaN/0 when not set).
    score: f64,
};

/// Open (or create) a SQLite database at `path`. Pass ":memory:" for an
/// in-memory DB. Returns null on failure.
/// The optional embedder: pass `null` for no embeddings (keyword-only search),
/// or a HashEmbedder handle to enable hybrid vector+keyword recall.
pub export fn slowclaw_feed_sqlite_open(
    path: [*]const u8,
    path_len: usize,
    embedder_handle: ?*SlowclawHashEmbedder,
) ?*SlowclawSqlite {
    const path_slice = path[0..path_len];
    const emb_opt: ?embeddings.EmbeddingProvider = if (embedder_handle) |h| blk: {
        const he: *embeddings.HashEmbedding = @ptrCast(@alignCast(h));
        break :blk he.provider();
    } else null;
    const db = c_allocator.create(sqlite.SqliteMemory) catch return null;
    db.* = sqlite.SqliteMemory.open(c_allocator, path_slice, emb_opt, 0.7, 0.3, 1024) catch {
        c_allocator.destroy(db);
        return null;
    };
    return @ptrCast(db);
}

pub export fn slowclaw_feed_sqlite_close(handle: ?*SlowclawSqlite) void {
    if (handle) |h| {
        const db: *sqlite.SqliteMemory = @ptrCast(@alignCast(h));
        db.close();
        c_allocator.destroy(db);
    }
}

pub export fn slowclaw_feed_sqlite_health(handle: *SlowclawSqlite) bool {
    const db: *sqlite.SqliteMemory = @ptrCast(@alignCast(handle));
    return db.healthCheck();
}

/// Insert or upsert a memory. `category` is a lowercase tag ("core", "daily",
/// "conversation", or any custom name). `session_id`, `source`, and `media_url`
/// are `{null, 0}` if absent. Returns 0 on success, negative on error.
pub export fn slowclaw_feed_sqlite_store(
    handle: *SlowclawSqlite,
    key: [*]const u8,
    key_len: usize,
    content: [*]const u8,
    content_len: usize,
    category: [*]const u8,
    category_len: usize,
    session_id: ?[*]const u8,
    session_id_len: usize,
    source: ?[*]const u8,
    source_len: usize,
    media_url: ?[*]const u8,
    media_url_len: usize,
) c_int {
    const db: *sqlite.SqliteMemory = @ptrCast(@alignCast(handle));
    const cat = categoryToEnum(category[0..category_len]);
    const sid_slice: ?[]const u8 = if (session_id) |p| p[0..session_id_len] else null;
    const src_slice: ?[]const u8 = if (source) |p| p[0..source_len] else null;
    const media_slice: ?[]const u8 = if (media_url) |p| p[0..media_url_len] else null;
    db.store(key[0..key_len], content[0..content_len], cat, sid_slice, src_slice, media_slice) catch return SLOWCLAW_ERR_INTERNAL;
    return SLOWCLAW_OK;
}

/// Fetch a memory by key. The returned entry is Zig-owned; free via
/// `slowclaw_feed_sqlite_entry_free`. Returns 0 if found, 1 if not found,
/// negative on error.
pub export fn slowclaw_feed_sqlite_get(
    handle: *SlowclawSqlite,
    key: [*]const u8,
    key_len: usize,
    out_entry: *SlowclawSqliteEntry,
) c_int {
    const db: *sqlite.SqliteMemory = @ptrCast(@alignCast(handle));
    const found = db.get(c_allocator, key[0..key_len]) catch return SLOWCLAW_ERR_INTERNAL;
    if (found == null) return 1;
    out_entry.* = entryToC(found.?);
    return SLOWCLAW_OK;
}

/// Delete a memory by key. Returns 1 if a row was deleted, 0 if not found,
/// negative on error.
pub export fn slowclaw_feed_sqlite_forget(
    handle: *SlowclawSqlite,
    key: [*]const u8,
    key_len: usize,
) c_int {
    const db: *sqlite.SqliteMemory = @ptrCast(@alignCast(handle));
    const removed = db.forget(key[0..key_len]) catch return SLOWCLAW_ERR_INTERNAL;
    return if (removed) 1 else 0;
}

/// Count stored memories. Returns the count (>= 0) or negative on error.
pub export fn slowclaw_feed_sqlite_count(handle: *SlowclawSqlite) c_int {
    const db: *sqlite.SqliteMemory = @ptrCast(@alignCast(handle));
    const n = db.count() catch return SLOWCLAW_ERR_INTERNAL;
    return @intCast(n);
}

/// Hybrid recall (FTS5 keyword + vector similarity if an embedder is set).
/// Returns a JSON array of entries (each with id/key/content/category/timestamp/
/// session_id/score). Free via `slowclaw_feed_sqlite_result_free`.
pub export fn slowclaw_feed_sqlite_recall(
    handle: *SlowclawSqlite,
    query: [*]const u8,
    query_len: usize,
    limit: usize,
    session_id: ?[*]const u8,
    session_id_len: usize,
    out_result: *SlowclawRankResult,
) c_int {
    const db: *sqlite.SqliteMemory = @ptrCast(@alignCast(handle));
    const sid_slice: ?[]const u8 = if (session_id) |p| p[0..session_id_len] else null;
    const entries = db.recall(c_allocator, query[0..query_len], limit, sid_slice) catch {
        out_result.* = .{ .items_json = SlowclawString.empty(), .status = SLOWCLAW_ERR_INTERNAL };
        return SLOWCLAW_ERR_INTERNAL;
    };
    defer {
        for (entries) |e| sqlite.freeEntry(c_allocator, e);
        c_allocator.free(entries);
    }
    const json = serializeEntriesFull(c_allocator, entries) catch {
        out_result.* = .{ .items_json = SlowclawString.empty(), .status = SLOWCLAW_ERR_OUT_OF_MEMORY };
        return SLOWCLAW_ERR_OUT_OF_MEMORY;
    };
    out_result.* = .{ .items_json = SlowclawString.fromOwnedSlice(json), .status = SLOWCLAW_OK };
    return SLOWCLAW_OK;
}

pub export fn slowclaw_feed_sqlite_result_free(result: *SlowclawRankResult) void {
    if (result.items_json.bytes) |b| {
        const slice = b[0..result.items_json.len];
        c_allocator.free(slice);
        result.* = .{ .items_json = SlowclawString.empty(), .status = SLOWCLAW_OK };
    }
}

/// Free an entry obtained from `slowclaw_feed_sqlite_get`.
pub export fn slowclaw_feed_sqlite_entry_free(entry: *SlowclawSqliteEntry) void {
    freeEntryCString(&entry.id);
    freeEntryCString(&entry.key);
    freeEntryCString(&entry.content);
    freeEntryCString(&entry.category);
    freeEntryCString(&entry.timestamp);
    freeEntryCString(&entry.session_id);
    freeEntryCString(&entry.source);
    freeEntryCString(&entry.media_url);
    entry.* = std.mem.zeroes(SlowclawSqliteEntry);
}

fn freeEntryCString(s: *SlowclawString) void {
    if (s.bytes) |b| {
        c_allocator.free(b[0..s.len]);
        s.* = SlowclawString.empty();
    }
}

fn categoryToEnum(s: []const u8) memory_types.MemoryCategory {
    if (std.mem.eql(u8, s, "core")) return .{ .core = {} };
    if (std.mem.eql(u8, s, "daily")) return .{ .daily = {} };
    if (std.mem.eql(u8, s, "conversation")) return .{ .conversation = {} };
    // Custom categories: dupe to a c_allocator-owned slice so the value is
    // stable for the duration of the store call.
    const owned = c_allocator.dupe(u8, s) catch return .{ .core = {} };
    return .{ .custom = owned };
}

/// Convert a Zig MemoryEntry to the C-ABI SlowclawSqliteEntry. All string
/// fields are c_allocator-owned (the caller frees them via the entry_free fn).
fn entryToC(entry: sqlite_memory.MemoryEntry) SlowclawSqliteEntry {
    const cat_str = entry.category.toString();
    return .{
        .id = cStringFromSlice(entry.id),
        .key = cStringFromSlice(entry.key),
        .content = cStringFromSlice(entry.content),
        .category = cStringFromSlice(cat_str),
        .timestamp = cStringFromSlice(entry.timestamp),
        .session_id = if (entry.session_id) |s| cStringFromSlice(s) else SlowclawString.empty(),
        .source = if (entry.source) |src| cStringFromSlice(src) else SlowclawString.empty(),
        .media_url = if (entry.media_url) |m| cStringFromSlice(m) else SlowclawString.empty(),
        .score = if (entry.score) |sc| sc else std.math.nan(f64),
    };
}

const sqlite_memory = memory_types;

/// Same as entryToC but takes the sqlite-owned MemoryEntry shape directly.
fn entryToCFromSqlite(entry: memory_types.MemoryEntry) SlowclawSqliteEntry {
    const cat_str = entry.category.toString();
    return .{
        .id = cStringFromSlice(entry.id),
        .key = cStringFromSlice(entry.key),
        .content = cStringFromSlice(entry.content),
        // For custom categories, category.toString() returns the alias name.
        .category = cStringFromSlice(cat_str),
        .timestamp = cStringFromSlice(entry.timestamp),
        .session_id = if (entry.session_id) |s| cStringFromSlice(s) else SlowclawString.empty(),
        .source = if (entry.source) |src| cStringFromSlice(src) else SlowclawString.empty(),
        .media_url = if (entry.media_url) |m| cStringFromSlice(m) else SlowclawString.empty(),
        .score = if (entry.score) |sc| sc else std.math.nan(f64),
    };
}

/// Dup a Zig slice to a c_allocator-owned UTF-8 buffer, returning the
/// SlowclawString view. The caller frees via `slowclaw_feed_free` or the
/// per-field free helpers.
fn cStringFromSlice(s: []const u8) SlowclawString {
    if (s.len == 0) return SlowclawString.empty();
    const owned = c_allocator.dupe(u8, s) catch return SlowclawString.empty();
    return .{ .bytes = owned.ptr, .len = owned.len };
}

/// Serialize full memory entries (not the abbreviated rank-item form) as JSON.
/// Used by `slowclaw_feed_sqlite_recall`. Each entry:
///   { "id":..., "key":..., "content":..., "category":..., "timestamp":...,
///     "session_id":...|null, "source":...|null, "media_url":...|null,
///     "score":...|null }
fn serializeEntriesFull(allocator: std.mem.Allocator, items: []const memory_types.MemoryEntry) ![]u8 {
    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(allocator);
    try buf.append(allocator, '[');
    for (items, 0..) |item, i| {
        if (i > 0) try buf.append(allocator, ',');
        try buf.appendSlice(allocator, "{\"id\":");
        try writeJsonString(allocator, &buf, item.id);
        try buf.appendSlice(allocator, ",\"key\":");
        try writeJsonString(allocator, &buf, item.key);
        try buf.appendSlice(allocator, ",\"content\":");
        try writeJsonString(allocator, &buf, item.content);
        try buf.appendSlice(allocator, ",\"category\":");
        try writeJsonString(allocator, &buf, item.category.toString());
        try buf.appendSlice(allocator, ",\"timestamp\":");
        try writeJsonString(allocator, &buf, item.timestamp);
        try buf.appendSlice(allocator, ",\"session_id\":");
        if (item.session_id) |s| {
            try writeJsonString(allocator, &buf, s);
        } else {
            try buf.appendSlice(allocator, "null");
        }
        try buf.appendSlice(allocator, ",\"source\":");
        if (item.source) |src| {
            try writeJsonString(allocator, &buf, src);
        } else {
            try buf.appendSlice(allocator, "null");
        }
        try buf.appendSlice(allocator, ",\"media_url\":");
        if (item.media_url) |m| {
            try writeJsonString(allocator, &buf, m);
        } else {
            try buf.appendSlice(allocator, "null");
        }
        try buf.appendSlice(allocator, ",\"score\":");
        if (item.score) |sc| {
            const s_str = try std.fmt.allocPrint(allocator, "{d}", .{sc});
            defer allocator.free(s_str);
            try buf.appendSlice(allocator, s_str);
        } else {
            try buf.appendSlice(allocator, "null");
        }
        try buf.append(allocator, '}');
    }
    try buf.append(allocator, ']');
    return buf.toOwnedSlice(allocator);
}

// ──────────────────────────────────────────────────────────────────────────
// LLM Provider — Swift provides the HTTP transport via a C callback.
// ──────────────────────────────────────────────────────────────────────────

/// C-side HTTP transport callback type. Swift implements this via URLSession.
/// Returns the response body as a Zig-owned SlowclawString (caller frees
/// via slowclaw_feed_free). Returns null bytes on error.
pub const SlowclawHttpPostFn = *const fn (
    ctx: ?*anyopaque,
    url: [*]const u8,
    url_len: usize,
    auth_header: [*]const u8,
    auth_header_len: usize,
    content_type: [*]const u8,
    content_type_len: usize,
    body: [*]const u8,
    body_len: usize,
) callconv(.c) SlowclawString;

/// Adapter: wraps the C-side callback as a Zig HttpTransport.
/// The `ctx` is a pointer to a stored {callback_ctx, post_fn} pair.
const TransportStorage = struct {
    callback_ctx: ?*anyopaque,
    post_fn: SlowclawHttpPostFn,
};

fn cHttpPost(
    ctx: *anyopaque,
    allocator: std.mem.Allocator,
    url: []const u8,
    auth_header: []const u8,
    content_type: []const u8,
    body: []const u8,
) openai_provider_mod.HttpError![]u8 {
    const storage: *TransportStorage = @ptrCast(@alignCast(ctx));
    const result = storage.post_fn(
        storage.callback_ctx,
        url.ptr, url.len,
        auth_header.ptr, auth_header.len,
        content_type.ptr, content_type.len,
        body.ptr, body.len,
    );
    if (result.bytes == null) return error.HttpFailed;
    const slice = result.bytes.?[0..result.len];
    const owned = allocator.dupe(u8, slice) catch return error.OutOfMemory;
    // Free the C-side allocation (it came from Swift, freed via slowclaw_feed_free).
    if (result.bytes) |b| std.c.free(@constCast(b));
    return owned;
}

/// Opaque handle to an OpenAiProvider.
pub const SlowclawProvider = opaque {};

/// Create an OpenAI-compatible LLM provider. The HTTP transport is provided
/// by Swift as a C callback function pointer + opaque context. The base_url
/// and api_key are Zig-owned (duped from the caller's slices).
pub export fn slowclaw_feed_provider_new(
    base_url: [*]const u8,
    base_url_len: usize,
    api_key: [*]const u8,
    api_key_len: usize,
    http_callback_ctx: ?*anyopaque,
    http_post_fn: SlowclawHttpPostFn,
) ?*SlowclawProvider {
    const url_slice = base_url[0..base_url_len];
    const key_slice = api_key[0..api_key_len];

    // Store the transport callback info in heap-allocated memory.
    const storage_ptr = c_allocator.create(TransportStorage) catch return null;
    storage_ptr.* = .{ .callback_ctx = http_callback_ctx, .post_fn = http_post_fn };

    const provider_ptr = c_allocator.create(openai_provider_mod.OpenAiProvider) catch {
        c_allocator.destroy(storage_ptr);
        return null;
    };

    // Build a Zig HttpTransport that wraps the C callback.
    const zig_transport = openai_provider_mod.HttpTransport{
        .ctx = @ptrCast(storage_ptr),
        .post_fn = cHttpPost,
    };

    provider_ptr.* = openai_provider_mod.OpenAiProvider.withBaseUrl(
        c_allocator,
        c_allocator.dupe(u8, url_slice) catch {
            c_allocator.destroy(storage_ptr);
            c_allocator.destroy(provider_ptr);
            return null;
        },
        c_allocator.dupe(u8, key_slice) catch {
            c_allocator.destroy(storage_ptr);
            c_allocator.destroy(provider_ptr);
            return null;
        },
        zig_transport,
    );

    return @ptrCast(provider_ptr);
}

pub export fn slowclaw_feed_provider_free(handle: ?*SlowclawProvider) void {
    if (handle) |h| {
        const p: *openai_provider_mod.OpenAiProvider = @ptrCast(@alignCast(h));
        c_allocator.free(p.base_url);
        if (p.api_key) |k| c_allocator.free(k);
        c_allocator.destroy(p);
    }
}

/// One-shot chat: system prompt + user message → LLM response text.
/// Returns the response as a Zig-owned SlowclawString (caller frees via
/// slowclaw_feed_free). On error, bytes is null and status is negative.
pub const SlowclawChatResult = extern struct {
    text: SlowclawString,
    status: c_int,
};

pub export fn slowclaw_feed_provider_chat(
    handle: *SlowclawProvider,
    system_prompt: ?[*]const u8,
    system_prompt_len: usize,
    message: [*]const u8,
    message_len: usize,
    model: [*]const u8,
    model_len: usize,
    temperature: f64,
) SlowclawChatResult {
    const p: *openai_provider_mod.OpenAiProvider = @ptrCast(@alignCast(handle));
    const msg_slice = message[0..message_len];
    const model_slice = model[0..model_len];
    const sys_slice: ?[]const u8 = if (system_prompt) |s| s[0..system_prompt_len] else null;

    const result = p.chatWithSystem(c_allocator, sys_slice, msg_slice, model_slice, temperature) catch |err| {
        const status: c_int = switch (err) {
            error.InvalidArgument => -1,
            error.OutOfMemory => -2,
            error.HttpFailed => -3,
            error.ApiError => -4,
            error.InvalidResponse => -5,
        };
        return .{ .text = SlowclawString.empty(), .status = status };
    };

    return .{
        .text = SlowclawString.fromOwnedSlice(result),
        .status = SLOWCLAW_OK,
    };
}

/// Journal synthesis: transcript → clean journal entry (via LLM).
pub export fn slowclaw_feed_synthesize_journal(
    handle: *SlowclawProvider,
    transcript: [*]const u8,
    transcript_len: usize,
    model: [*]const u8,
    model_len: usize,
) SlowclawChatResult {
    const p: *openai_provider_mod.OpenAiProvider = @ptrCast(@alignCast(handle));
    const pv = p.provider_();
    const result = journal_agent.synthesizeJournal(
        pv,
        c_allocator,
        transcript[0..transcript_len],
        model[0..model_len],
    ) catch |err| {
        const status: c_int = switch (err) {
            error.InvalidArgument => -1,
            error.OutOfMemory => -2,
            error.HttpFailed => -3,
            error.ApiError => -4,
            error.InvalidResponse => -5,
        };
        return .{ .text = SlowclawString.empty(), .status = status };
    };
    return .{ .text = SlowclawString.fromOwnedSlice(result), .status = SLOWCLAW_OK };
}

/// Interest extraction: journal text → comma-separated keywords (via LLM).
pub export fn slowclaw_feed_extract_interests(
    handle: *SlowclawProvider,
    journal_text: [*]const u8,
    journal_text_len: usize,
    model: [*]const u8,
    model_len: usize,
) SlowclawChatResult {
    const p: *openai_provider_mod.OpenAiProvider = @ptrCast(@alignCast(handle));
    const pv = p.provider_();
    const result = journal_agent.extractInterests(
        pv,
        c_allocator,
        journal_text[0..journal_text_len],
        model[0..model_len],
    ) catch |err| {
        const status: c_int = switch (err) {
            error.InvalidArgument => -1,
            error.OutOfMemory => -2,
            error.HttpFailed => -3,
            error.ApiError => -4,
            error.InvalidResponse => -5,
        };
        return .{ .text = SlowclawString.empty(), .status = status };
    };
    return .{ .text = SlowclawString.fromOwnedSlice(result), .status = SLOWCLAW_OK };
}

/// Post drafting: journal text → short-form post draft (via LLM).
pub export fn slowclaw_feed_draft_post(
    handle: *SlowclawProvider,
    journal_text: [*]const u8,
    journal_text_len: usize,
    model: [*]const u8,
    model_len: usize,
    max_chars: usize,
) SlowclawChatResult {
    const p: *openai_provider_mod.OpenAiProvider = @ptrCast(@alignCast(handle));
    const pv = p.provider_();
    const result = journal_agent.draftPost(
        pv,
        c_allocator,
        journal_text[0..journal_text_len],
        model[0..model_len],
        max_chars,
    ) catch |err| {
        const status: c_int = switch (err) {
            error.InvalidArgument => -1,
            error.OutOfMemory => -2,
            error.HttpFailed => -3,
            error.ApiError => -4,
            error.InvalidResponse => -5,
        };
        return .{ .text = SlowclawString.empty(), .status = status };
    };
    return .{ .text = SlowclawString.fromOwnedSlice(result), .status = SLOWCLAW_OK };
}

pub export fn slowclaw_feed_chat_result_free(result: *SlowclawChatResult) void {
    if (result.text.bytes) |b| {
        c_allocator.free(b[0..result.text.len]);
        result.* = .{ .text = SlowclawString.empty(), .status = SLOWCLAW_OK };
    }
}

// ──────────────────────────────────────────────────────────────────────────
// RSS parsing + feed ranking — the "journal is the lens" feed pipeline.
// Swift fetches raw XML via URLSession → Zig parses + ranks → returns JSON.
// ──────────────────────────────────────────────────────────────────────────

/// Parse RSS/Atom XML and rank items by the user's interests. Returns a JSON
/// array of ranked items with score, title, link, description, readMinutes,
/// sourceLabel. The caller frees via slowclaw_feed_rank_result_free.
///
/// `topics_json` is a JSON array of {"label":"rust","weight":1.0} objects
/// representing the user's current journal-derived interests. Pass null/empty
/// for pure recency ranking.
pub export fn slowclaw_feed_parse_and_rank(
    xml: [*]const u8,
    xml_len: usize,
    source_label: [*]const u8,
    source_label_len: usize,
    topics_json: ?[*]const u8,
    topics_json_len: usize,
    now_epoch: f64,
    out_result: *SlowclawRankResult,
) c_int {
    const xml_slice = xml[0..xml_len];
    const src_slice = source_label[0..source_label_len];

    // Parse the RSS/Atom XML.
    const items = rss_parser.parseFeed(c_allocator, xml_slice) catch {
        out_result.* = .{ .items_json = SlowclawString.empty(), .status = SLOWCLAW_ERR_INTERNAL };
        return SLOWCLAW_ERR_INTERNAL;
    };
    defer rss_parser.freeRssItems(c_allocator, items);

    // Convert to FeedItems for ranking. Allocated with c_allocator so the
    // defer below frees with the matching allocator (a mismatch here —
    // page_allocator alloc + c_allocator free — was the iOS Reads SIGABRT).
    const feed_items = rss_parser.toFeedItems(c_allocator, items, src_slice) catch {
        out_result.* = .{ .items_json = SlowclawString.empty(), .status = SLOWCLAW_ERR_OUT_OF_MEMORY };
        return SLOWCLAW_ERR_OUT_OF_MEMORY;
    };
    defer c_allocator.free(feed_items);

    // Parse the topics JSON if provided. Labels are duped into c_allocator
    // by parseTopicsJson (the JSON arena is freed inside it), so free with
    // freeTopics — NOT a bare slice free (which would leak the labels and,
    // before the dup fix, read freed arena memory → heap corruption).
    var topics: []feeds_ranking.Topic = &.{};
    defer freeTopics(c_allocator, topics);
    if (topics_json) |tj| {
        const tj_slice = tj[0..topics_json_len];
        topics = parseTopicsJson(c_allocator, tj_slice) catch &.{};
    }

    // Rank.
    const ranked = feeds_ranking.rankReads(c_allocator, feed_items, topics, &.{}, now_epoch) catch {
        out_result.* = .{ .items_json = SlowclawString.empty(), .status = SLOWCLAW_ERR_INTERNAL };
        return SLOWCLAW_ERR_INTERNAL;
    };
    defer c_allocator.free(ranked);

    // Serialize to JSON.
    const json = serializeRankedFeed(c_allocator, ranked) catch {
        out_result.* = .{ .items_json = SlowclawString.empty(), .status = SLOWCLAW_ERR_OUT_OF_MEMORY };
        return SLOWCLAW_ERR_OUT_OF_MEMORY;
    };
    out_result.* = .{ .items_json = SlowclawString.fromOwnedSlice(json), .status = SLOWCLAW_OK };
    return SLOWCLAW_OK;
}

/// Return the default Reads feed catalog as a JSON array of
/// {"title","domain","htmlUrl","xmlUrl"} objects. The bytes are
/// c_allocator-owned; the caller frees via slowclaw_feed_free.
///
/// Mirrors src/gateway/feed_web_sources.rs (DEFAULT_FEED_WEB_SOURCES) so the
/// iOS app reads the same sources as the reference app. Swift fetches each
/// xml_url client-side and parses+ranks via slowclaw_feed_parse_and_rank.
pub export fn slowclaw_feed_catalog_json(out_str: *SlowclawString) c_int {
    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(c_allocator);
    buf.append(c_allocator, '[') catch return SLOWCLAW_ERR_OUT_OF_MEMORY;
    for (feed_catalog.DEFAULT_FEED_SOURCES, 0..) |src, i| {
        if (i > 0) buf.append(c_allocator, ',') catch return SLOWCLAW_ERR_OUT_OF_MEMORY;
        buf.appendSlice(c_allocator, "{\"title\":") catch return SLOWCLAW_ERR_OUT_OF_MEMORY;
        writeJsonString(c_allocator, &buf, src.title) catch return SLOWCLAW_ERR_OUT_OF_MEMORY;
        buf.appendSlice(c_allocator, ",\"domain\":") catch return SLOWCLAW_ERR_OUT_OF_MEMORY;
        writeJsonString(c_allocator, &buf, src.domain) catch return SLOWCLAW_ERR_OUT_OF_MEMORY;
        buf.appendSlice(c_allocator, ",\"htmlUrl\":") catch return SLOWCLAW_ERR_OUT_OF_MEMORY;
        writeJsonString(c_allocator, &buf, src.html_url) catch return SLOWCLAW_ERR_OUT_OF_MEMORY;
        buf.appendSlice(c_allocator, ",\"xmlUrl\":") catch return SLOWCLAW_ERR_OUT_OF_MEMORY;
        writeJsonString(c_allocator, &buf, src.xml_url) catch return SLOWCLAW_ERR_OUT_OF_MEMORY;
        buf.append(c_allocator, '}') catch return SLOWCLAW_ERR_OUT_OF_MEMORY;
    }
    buf.append(c_allocator, ']') catch return SLOWCLAW_ERR_OUT_OF_MEMORY;
    const json = buf.toOwnedSlice(c_allocator) catch return SLOWCLAW_ERR_OUT_OF_MEMORY;
    out_str.* = SlowclawString.fromOwnedSlice(json);
    return SLOWCLAW_OK;
}

test "ffi: catalog_json returns all default sources as valid JSON" {
    var out: SlowclawString = SlowclawString.empty();
    const status = slowclaw_feed_catalog_json(&out);
    try testing.expectEqual(SLOWCLAW_OK, status);
    defer if (out.bytes) |b| c_allocator.free(b[0..out.len]);

    const json_bytes = out.bytes orelse return error.NullJson;
    const parsed = std.json.parseFromSlice(std.json.Value, testing.allocator, json_bytes[0..out.len], .{}) catch return error.JsonInvalid;
    defer parsed.deinit();
    try testing.expectEqual(std.meta.Tag(std.json.Value).array, std.meta.activeTag(parsed.value));
    // Same count as the Rust catalog (DEFAULT_FEED_WEB_SOURCES, 1:1 port).
    try testing.expectEqual(@as(usize, 114), parsed.value.array.items.len);
    // First entry must be simonwillison.net.
    const first = parsed.value.array.items[0];
    try testing.expectEqualStrings("simonwillison.net", first.object.get("domain").?.string);
}

// ── On-device LLM (llama.cpp) ─────────────────────────────────────────────
//
// When the vendored llama.cpp backend is compiled in (build option
// -Dwith-llama=true, the default for the shipped staticlib), these entry
// points drive real on-device inference through local_inference.zig. When
// compiled out (unit-test steps), they report `available: false` exactly
// like the pre-llama builds — the FFI shape never changes.

/// Return on-device LLM status as JSON:
/// {"available","loaded","modelId"?,"reason"}. `available` reflects whether
/// the llama.cpp backend is linked; `loaded` whether a model is in memory.
/// Bytes are c_allocator-owned; caller frees via slowclaw_feed_free.
pub export fn slowclaw_feed_local_llm_status(out_str: *SlowclawString) c_int {
    const json = local_inference.statusJson(c_allocator) catch {
        out_str.* = SlowclawString.empty();
        return SLOWCLAW_ERR_OUT_OF_MEMORY;
    };
    out_str.* = SlowclawString.fromOwnedSlice(json);
    return SLOWCLAW_OK;
}

/// Load a GGUF model. Returns SLOWCLAW_OK on success; SLOWCLAW_ERR_INVALID_ARGUMENT
/// when the file is missing/invalid/not a GGUF; SLOWCLAW_ERR_INTERNAL when
/// llama.cpp itself rejects the model (too large, unsupported arch).
pub export fn slowclaw_feed_local_llm_load(
    model_path: [*]const u8,
    model_path_len: usize,
) c_int {
    local_inference.loadModel(model_path[0..model_path_len]) catch |err| return switch (err) {
        error.OutOfMemory => SLOWCLAW_ERR_OUT_OF_MEMORY,
        error.ModelLoadFailed => SLOWCLAW_ERR_INVALID_ARGUMENT,
        else => SLOWCLAW_ERR_INTERNAL,
    };
    return SLOWCLAW_OK;
}

/// Unload the current model (frees RAM). No-op when nothing is loaded.
pub export fn slowclaw_feed_local_llm_unload() void {
    local_inference.unloadModel();
}

/// Run a chat completion on the loaded model. Shape mirrors
/// slowclaw_feed_provider_chat so the Swift overlay can swap transports.
pub export fn slowclaw_feed_local_llm_chat(
    system_prompt: ?[*]const u8,
    system_prompt_len: usize,
    message: [*]const u8,
    message_len: usize,
    max_tokens: u32,
    temperature: f64,
    out_result: *SlowclawChatResult,
) c_int {
    const sys_slice: ?[]const u8 = if (system_prompt) |s| s[0..system_prompt_len] else null;
    const result = local_inference.chat(
        c_allocator,
        sys_slice,
        message[0..message_len],
        max_tokens,
        @floatCast(temperature),
    ) catch |err| {
        const status: c_int = switch (err) {
            error.ModelNotLoaded => SLOWCLAW_ERR_INVALID_ARGUMENT,
            error.OutOfMemory => SLOWCLAW_ERR_OUT_OF_MEMORY,
            else => SLOWCLAW_ERR_INTERNAL,
        };
        out_result.* = .{ .text = SlowclawString.empty(), .status = status };
        return status;
    };
    out_result.* = .{ .text = SlowclawString.fromOwnedSlice(result), .status = SLOWCLAW_OK };
    return SLOWCLAW_OK;
}

/// Local inference through the same journal_agent prompts the HTTP provider
/// uses — synthesize / extract / draft behave identically on-device. `model`
/// is accepted for call-site symmetry with the provider variants and ignored
/// (the loaded GGUF is the model).
fn localJournalAgentCall(
    comptime agent_fn: anytype,
    args: anytype,
    out_result: *SlowclawChatResult,
) c_int {
    var engine = local_inference.LocalInference.init("");
    engine.is_loaded = local_inference.isLoaded();
    const pv = engine.provider_();
    const result = @call(.auto, agent_fn, .{pv, c_allocator} ++ args) catch |err| {
        const status: c_int = switch (err) {
            error.InvalidArgument => SLOWCLAW_ERR_INVALID_ARGUMENT,
            error.OutOfMemory => SLOWCLAW_ERR_OUT_OF_MEMORY,
            else => SLOWCLAW_ERR_INTERNAL,
        };
        out_result.* = .{ .text = SlowclawString.empty(), .status = status };
        return status;
    };
    out_result.* = .{ .text = SlowclawString.fromOwnedSlice(result), .status = SLOWCLAW_OK };
    return SLOWCLAW_OK;
}

/// Journal synthesis on-device: transcript → clean journal entry.
pub export fn slowclaw_feed_local_llm_synthesize_journal(
    transcript: [*]const u8,
    transcript_len: usize,
    out_result: *SlowclawChatResult,
) c_int {
    return localJournalAgentCall(journal_agent.synthesizeJournal, .{ transcript[0..transcript_len], "local" }, out_result);
}

/// Interest extraction on-device: journal text → comma-separated keywords.
pub export fn slowclaw_feed_local_llm_extract_interests(
    journal_text: [*]const u8,
    journal_text_len: usize,
    out_result: *SlowclawChatResult,
) c_int {
    return localJournalAgentCall(journal_agent.extractInterests, .{ journal_text[0..journal_text_len], "local" }, out_result);
}

/// Post drafting on-device: journal text → short-form post draft.
pub export fn slowclaw_feed_local_llm_draft_post(
    journal_text: [*]const u8,
    journal_text_len: usize,
    max_chars: usize,
    out_result: *SlowclawChatResult,
) c_int {
    return localJournalAgentCall(journal_agent.draftPost, .{ journal_text[0..journal_text_len], "local", max_chars }, out_result);
}

/// Title generation on-device: transcript/text → concise title.
pub export fn slowclaw_feed_local_llm_generate_title(
    transcript: [*]const u8,
    transcript_len: usize,
    out_result: *SlowclawChatResult,
) c_int {
    return localJournalAgentCall(journal_agent.generateTitle, .{ transcript[0..transcript_len], "local" }, out_result);
}

// ──────────────────────────────────────────────────────────────────────────
// Sync engine — LAN QR-paired sync (AGENTS.md §1/§9 companion exception).
// Transport-agnostic: the shell owns the wire; these exports cover manifest
// build/exchange/diff/apply. The same surface is consumed by both the iOS
// shell (Swift) and the Windows companion (C# P/Invoke).
// ──────────────────────────────────────────────────────────────────────────

/// Build a sync manifest for the given SQLite store. `media_root` is the
/// absolute directory under which `media_url` paths resolve (iOS Documents/
/// or the Windows equivalent); pass {null, 0} to skip media file sizing.
/// On success writes a Zig-owned JSON manifest to `out_json` (caller frees
/// via `slowclaw_feed_free`). Returns 0 on success, negative on error.
pub export fn slowclaw_feed_sync_build_manifest(
    handle: *SlowclawSqlite,
    media_root: ?[*]const u8,
    media_root_len: usize,
    out_json: *SlowclawString,
) c_int {
    const db: *sqlite.SqliteMemory = @ptrCast(@alignCast(handle));
    const root_slice: []const u8 = if (media_root) |p| p[0..media_root_len] else &.{};
    var manifest = sync_engine.buildManifest(c_allocator, db, root_slice) catch {
        out_json.* = SlowclawString.empty();
        return SLOWCLAW_ERR_INTERNAL;
    };
    defer manifest.deinit(c_allocator);
    const json = sync_engine.serializeManifest(c_allocator, manifest) catch {
        out_json.* = SlowclawString.empty();
        return SLOWCLAW_ERR_OUT_OF_MEMORY;
    };
    out_json.* = SlowclawString.fromOwnedSlice(json);
    return SLOWCLAW_OK;
}

/// Diff a local manifest against a remote manifest. Both are JSON blobs in
/// the shape produced by `slowclaw_feed_sync_build_manifest`. Writes a
/// Zig-owned JSON diff ({ "to_pull":[...], "to_push":[...], "conflicts":[...] })
/// to `out_result`. Returns 0 on success, negative on error (incl. malformed
/// manifest JSON → SLOWCLAW_ERR_INVALID_ARGUMENT). Free via
/// `slowclaw_feed_sync_result_free`.
pub export fn slowclaw_feed_sync_diff(
    local_json: [*]const u8,
    local_len: usize,
    remote_json: [*]const u8,
    remote_len: usize,
    out_result: *SlowclawRankResult,
) c_int {
    var local = sync_engine.parseManifest(c_allocator, local_json[0..local_len]) catch {
        out_result.* = .{ .items_json = SlowclawString.empty(), .status = SLOWCLAW_ERR_INVALID_ARGUMENT };
        return SLOWCLAW_ERR_INVALID_ARGUMENT;
    };
    defer local.deinit(c_allocator);
    var remote = sync_engine.parseManifest(c_allocator, remote_json[0..remote_len]) catch {
        out_result.* = .{ .items_json = SlowclawString.empty(), .status = SLOWCLAW_ERR_INVALID_ARGUMENT };
        return SLOWCLAW_ERR_INVALID_ARGUMENT;
    };
    defer remote.deinit(c_allocator);

    var d = sync_engine.diff(c_allocator, local, remote) catch {
        out_result.* = .{ .items_json = SlowclawString.empty(), .status = SLOWCLAW_ERR_INTERNAL };
        return SLOWCLAW_ERR_INTERNAL;
    };
    defer d.deinit(c_allocator);

    const json = sync_engine.serializeDiff(c_allocator, d) catch {
        out_result.* = .{ .items_json = SlowclawString.empty(), .status = SLOWCLAW_ERR_OUT_OF_MEMORY };
        return SLOWCLAW_ERR_OUT_OF_MEMORY;
    };
    out_result.* = .{ .items_json = SlowclawString.fromOwnedSlice(json), .status = SLOWCLAW_OK };
    return SLOWCLAW_OK;
}

/// Free a diff result from `slowclaw_feed_sync_diff`. Safe on a zeroed result.
pub export fn slowclaw_feed_sync_result_free(result: *SlowclawRankResult) void {
    if (result.items_json.bytes) |b| {
        c_allocator.free(b[0..result.items_json.len]);
        result.* = .{ .items_json = SlowclawString.empty(), .status = SLOWCLAW_OK };
    }
}

/// Apply a batch of remote entries to the local store. `entries_json` is a
/// JSON array of full TransferEntry objects (the shell fetches each entry's
/// content from the peer, batches them, then calls this). Last-writer-wins:
/// entries whose local `updated_at` is newer are skipped. Returns 0 on
/// success, negative on error.
///
/// TransferEntry JSON shape:
///   [{"key":"...","content":"...","category":"daily","updated_at":"...",
///     "session_id":"..."|null,"source":"..."|null,"media_url":"..."|null}, ...]
pub export fn slowclaw_feed_sync_apply_entries(
    handle: *SlowclawSqlite,
    entries_json: [*]const u8,
    entries_len: usize,
) c_int {
    const db: *sqlite.SqliteMemory = @ptrCast(@alignCast(handle));
    const entries = sync_engine.parseTransferEntries(c_allocator, entries_json[0..entries_len]) catch {
        return SLOWCLAW_ERR_INVALID_ARGUMENT;
    };
    defer sync_engine.freeTransferEntries(c_allocator, entries);
    sync_engine.applyEntries(c_allocator, db, entries) catch return SLOWCLAW_ERR_INTERNAL;
    return SLOWCLAW_OK;
}

/// Fetch one full entry (content + metadata) by key, for transfer to the
/// peer. Writes a Zig-owned SlowclawSqliteEntry to `out_entry` (caller frees
/// via `slowclaw_feed_sqlite_entry_free`). Returns 0 if found, 1 if not
/// found, negative on error.
pub export fn slowclaw_feed_sync_entry_for_transfer(
    handle: *SlowclawSqlite,
    key: [*]const u8,
    key_len: usize,
    out_entry: *SlowclawSqliteEntry,
) c_int {
    const db: *sqlite.SqliteMemory = @ptrCast(@alignCast(handle));
    const found = db.get(c_allocator, key[0..key_len]) catch return SLOWCLAW_ERR_INTERNAL;
    if (found == null) return 1;
    out_entry.* = entryToC(found.?);
    return SLOWCLAW_OK;
}

/// Parse a JSON array of {"label":"...","weight":N} into Topic structs.
fn parseTopicsJson(allocator: std.mem.Allocator, json: []const u8) ![]feeds_ranking.Topic {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, json, .{}) catch return &.{};
    // NOTE: must not `defer parsed.deinit()` here and then return slices that
    // alias it. std.json stores ESCAPED strings in the parsed arena (and
    // unescaped strings as slices into the caller's `json` buffer). The
    // returned Topic labels must outlive this function — they're read by
    // rankReads after we return — so dup every label into `allocator` (which
    // is c_allocator in the FFI path) before the arena is freed. Failing to
    // dup was a use-after-free → heap corruption → SIGABRT on the next free
    // for any label containing a JSON escape.
    defer parsed.deinit();

    if (std.meta.activeTag(parsed.value) != .array) return &.{};
    const arr = parsed.value.array;
    var topics = try allocator.alloc(feeds_ranking.Topic, arr.items.len);
    // Track how many labels we duped so an alloc failure below frees what's
    // already owned before unwinding (the slice itself is freed by `errdefer`).
    errdefer {
        for (topics) |t| if (t.label.len > 0) allocator.free(t.label);
        allocator.free(topics);
    }

    for (arr.items, 0..) |item, i| {
        if (std.meta.activeTag(item) != .object) {
            topics[i] = .{ .label = "", .weight = 0 };
            continue;
        }
        const label_val = item.object.get("label") orelse std.json.Value{ .string = "" };
        const weight_val = item.object.get("weight") orelse std.json.Value{ .float = 1.0 };
        const raw_label = switch (label_val) {
            .string => |s| s,
            else => "",
        };
        // Own the label: arena (escaped) and input buffer (unescaped) are both
        // gone by the time rankReads reads this, so dup into `allocator`.
        const owned_label = if (raw_label.len == 0)
            ""
        else
            (allocator.dupe(u8, raw_label) catch {
                topics[i] = .{ .label = "", .weight = 0 };
                continue;
            });
        topics[i] = .{
            .label = owned_label,
            .weight = switch (weight_val) {
                .float => |f| f,
                .integer => |n| @floatFromInt(n),
                else => 1.0,
            },
        };
    }
    return topics;
}

/// Free a topics slice produced by `parseTopicsJson`. Each label was duped
/// into `allocator`, so free them individually, then the slice. Safe on the
/// `&.{}` fallback (len 0 → no-op) and on entries whose label is the static
/// "" (len 0 → not freed).
fn freeTopics(allocator: std.mem.Allocator, topics: []feeds_ranking.Topic) void {
    for (topics) |t| if (t.label.len > 0) allocator.free(t.label);
    if (topics.len > 0) allocator.free(topics);
}

/// Serialize ranked feed items as a JSON array for Swift to decode.
fn serializeRankedFeed(allocator: std.mem.Allocator, ranked: []const feeds_ranking.RankedItem) ![]u8 {
    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(allocator);
    try buf.append(allocator, '[');

    for (ranked, 0..) |r, i| {
        if (i > 0) try buf.append(allocator, ',');
        try buf.appendSlice(allocator, "{\"title\":");
        try writeJsonString(allocator, &buf, r.item.title);
        try buf.appendSlice(allocator, ",\"link\":");
        try writeJsonString(allocator, &buf, r.item.id);
        try buf.appendSlice(allocator, ",\"description\":");
        try writeJsonString(allocator, &buf, r.item.body);
        try buf.appendSlice(allocator, ",\"sourceLabel\":");
        try writeJsonString(allocator, &buf, r.source_label);
        try buf.appendSlice(allocator, ",\"score\":");
        const score_str = try std.fmt.allocPrint(allocator, "{d:.4}", .{r.score});
        defer allocator.free(score_str);
        try buf.appendSlice(allocator, score_str);
        const rm_str = try std.fmt.allocPrint(allocator, ",\"readMinutes\":{d}", .{r.read_minutes});
        defer allocator.free(rm_str);
        try buf.appendSlice(allocator, rm_str);
        try buf.append(allocator, '}');
    }
    try buf.append(allocator, ']');
    return buf.toOwnedSlice(allocator);
}
// ──────────────────────────────────────────────────────────────────────────

fn dupInterest(ci: SlowclawInterest) feed_types.InterestVector {
    // Strings are duplicated so the Zig side owns them — the C side may free
    // its buffers as soon as this function returns.
    return .{
        .id = dupSlice(ci.id, ci.id_len),
        .label = dupSlice(ci.label, ci.label_len),
        .embedding = dupF32Slice(ci.embedding, ci.embedding_len),
        .health_score = ci.health_score,
        .source_path = dupSlice(ci.source_path, ci.source_path_len),
        .keywords = dupKeywords(ci.keywords, ci.keywords_len),
    };
}

fn freeInterest(iv: feed_types.InterestVector) void {
    c_allocator.free(iv.id);
    c_allocator.free(iv.label);
    c_allocator.free(iv.embedding);
    c_allocator.free(iv.source_path);
    for (iv.keywords) |kw| c_allocator.free(kw);
    c_allocator.free(iv.keywords);
}

fn dupKeywords(ptr: [*]const SlowclawStringSlice, len: usize) [][]const u8 {
    const src = ptr[0..len];
    const out = c_allocator.alloc([]const u8, len) catch return &.{};
    for (src, 0..) |s, i| {
        out[i] = dupSlice(s.bytes, s.len);
    }
    return out;
}

fn dupCandidate(cc: SlowclawCandidate, original_index: usize) feed_types.FeedCandidate {
    const web_preview: ?feed_types.WebFeedPreview = blk: {
        if (cc.discovered_at) |ptr| {
            break :blk .{
                .url = "",
                .title = "",
                .description = "",
                .content_text = "",
                .domain = "",
                .provider = "",
                .discovered_at = dupSlice(ptr, cc.discovered_at_len),
            };
        }
        break :blk null;
    };
    return .{
        .protocol = .web,
        .dedupe_key = dupSlice(cc.dedupe_key, cc.dedupe_key_len),
        .stage1_score = cc.stage1_score,
        .rank_text = dupSlice(cc.rank_text, cc.rank_text_len),
        .item = .{
            .source_type = dupSlice(cc.source_type, cc.source_type_len),
            .feed_item_json = "{}",
            .web_preview = web_preview,
        },
        .original_index = original_index,
    };
}

fn freeCandidate(fc: feed_types.FeedCandidate) void {
    c_allocator.free(fc.dedupe_key);
    c_allocator.free(fc.rank_text);
    c_allocator.free(fc.item.source_type);
    if (fc.item.web_preview) |wp| c_allocator.free(wp.discovered_at);
}

fn dupSlice(ptr: [*]const u8, len: usize) []const u8 {
    if (len == 0) return "";
    const src = ptr[0..len];
    return c_allocator.dupe(u8, src) catch "";
}

fn dupF32Slice(ptr: [*]const f32, len: usize) []const f32 {
    if (len == 0) return &.{};
    const src = ptr[0..len];
    return c_allocator.dupe(f32, src) catch &.{};
}

fn errResult(status: c_int, out_err: ?*SlowclawString) SlowclawRankResult {
    if (out_err) |p| {
        const msg = switch (status) {
            SLOWCLAW_ERR_INVALID_ARGUMENT => "invalid argument",
            SLOWCLAW_ERR_OUT_OF_MEMORY => "out of memory",
            SLOWCLAW_ERR_EMBEDDER_MISMATCH => "embedder returned wrong vector count",
            else => "internal error",
        };
        const owned = c_allocator.dupe(u8, msg) catch {
            p.* = SlowclawString.empty();
            return .{ .items_json = SlowclawString.empty(), .status = status };
        };
        p.* = SlowclawString.fromOwnedSlice(owned);
    }
    return .{ .items_json = SlowclawString.empty(), .status = status };
}

fn toStatus(err: anyerror) c_int {
    return switch (err) {
        error.OutOfMemory => SLOWCLAW_ERR_OUT_OF_MEMORY,
        error.EmbedderCountMismatch => SLOWCLAW_ERR_EMBEDDER_MISMATCH,
        else => SLOWCLAW_ERR_INTERNAL,
    };
}

/// Serialize ranked items as a JSON array. Caller owns the returned slice.
/// Schema per item:
///   { "score": number|null,
///     "matched_interest_label": string|null,
///     "matched_interest_score": number|null,
///     "passed_threshold": bool,
///     "source_type": string }
fn serializeItems(allocator: std.mem.Allocator, items: []const feed_types.PersonalizedFeedItem) ![]u8 {
    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(allocator);
    try buf.append(allocator, '[');
    for (items, 0..) |item, i| {
        if (i > 0) try buf.append(allocator, ',');
        try buf.appendSlice(allocator, "{\"score\":");
        if (item.score) |s| {
            const s_str = try std.fmt.allocPrint(allocator, "{d}", .{s});
            defer allocator.free(s_str);
            try buf.appendSlice(allocator, s_str);
        } else {
            try buf.appendSlice(allocator, "null");
        }
        try buf.appendSlice(allocator, ",\"matched_interest_label\":");
        if (item.matched_interest_label) |lbl| {
            try writeJsonString(allocator, &buf, lbl);
        } else {
            try buf.appendSlice(allocator, "null");
        }
        try buf.appendSlice(allocator, ",\"matched_interest_score\":");
        if (item.matched_interest_score) |s| {
            const s_str = try std.fmt.allocPrint(allocator, "{d}", .{s});
            defer allocator.free(s_str);
            try buf.appendSlice(allocator, s_str);
        } else {
            try buf.appendSlice(allocator, "null");
        }
        const pt_str: []const u8 = if (item.passed_threshold) "true" else "false";
        const pt_chunk = try std.fmt.allocPrint(allocator, ",\"passed_threshold\":{s},\"source_type\":", .{pt_str});
        defer allocator.free(pt_chunk);
        try buf.appendSlice(allocator, pt_chunk);
        try writeJsonString(allocator, &buf, item.source_type);
        try buf.append(allocator, '}');
    }
    try buf.append(allocator, ']');
    return buf.toOwnedSlice(allocator);
}

fn writeJsonString(allocator: std.mem.Allocator, buf: *std.ArrayList(u8), s: []const u8) !void {
    try buf.append(allocator, '"');
    for (s) |c| {
        switch (c) {
            '"' => try buf.appendSlice(allocator, "\\\""),
            '\\' => try buf.appendSlice(allocator, "\\\\"),
            '\n' => try buf.appendSlice(allocator, "\\n"),
            '\r' => try buf.appendSlice(allocator, "\\r"),
            '\t' => try buf.appendSlice(allocator, "\\t"),
            else => {
                if (c < 0x20) {
                    const esc = try std.fmt.allocPrint(allocator, "\\u{x:0>4}", .{c});
                    defer allocator.free(esc);
                    try buf.appendSlice(allocator, esc);
                } else {
                    try buf.append(allocator, c);
                }
            },
        }
    }
    try buf.append(allocator, '"');
}

// ──────────────────────────────────────────────────────────────────────────
// Tests — exercise the C ABI surface from Zig (round-trip without an actual
// Swift caller). Proves the conversions + JSON serialization are correct.
// ──────────────────────────────────────────────────────────────────────────

test "ffi: hash embedder round-trip" {
    const handle = slowclaw_feed_hash_embedder_new("model", 5, 32) orelse return error.OOM;
    defer slowclaw_feed_hash_embedder_free(handle);

    var dims: usize = 0;
    const result = slowclaw_feed_hash_embed(handle, "hello world", 11, &dims);
    try testing.expectEqual(@as(usize, 32), dims);
    try testing.expect(result.bytes != null);
    defer slowclaw_feed_free(@constCast(result.bytes.?));
    // 32 f32s = 128 bytes.
    try testing.expectEqual(@as(usize, 32 * 4), result.len);
}

test "ffi: rank_stage2 produces valid JSON via the C ABI" {
    const emb = [_]f32{ 1.0, 0.0, 0.0 };
    const kw = [_]SlowclawStringSlice{.{ .bytes = "rust", .len = 4 }};
    var interest = SlowclawInterest{
        .id = "i1".ptr,
        .id_len = 2,
        .label = "rust lang".ptr,
        .label_len = 9,
        .embedding = emb[0..].ptr,
        .embedding_len = emb.len,
        .health_score = 0.9,
        .source_path = "".ptr,
        .source_path_len = 0,
        .keywords = kw[0..].ptr,
        .keywords_len = kw.len,
    };
    _ = &interest;

    var cand = SlowclawCandidate{
        .dedupe_key = "k1".ptr,
        .dedupe_key_len = 2,
        .stage1_score = 0.5,
        .rank_text = "an article about rust the language".ptr,
        .rank_text_len = 35,
        .source_type = "web".ptr,
        .source_type_len = 3,
        .discovered_at = null,
        .discovered_at_len = 0,
        .original_index = 0,
    };
    _ = &cand;

    var result = slowclaw_feed_rank_stage2(
        @ptrCast(&[_]SlowclawInterest{interest}),
        1,
        @ptrCast(&[_]SlowclawInterest{}),
        0,
        @ptrCast(&[_]SlowclawCandidate{cand}),
        1,
        10,
        0,
        null,
    );
    defer slowclaw_feed_rank_result_free(&result);
    try testing.expectEqual(SLOWCLAW_OK, result.status);

    const json_bytes = result.items_json.bytes orelse return error.NullJson;
    const json = json_bytes[0..result.items_json.len];
    // Must parse as a JSON array.
    const parsed = std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{}) catch return error.JsonInvalid;
    defer parsed.deinit();
    const Tag = std.meta.Tag(std.json.Value);
    try testing.expectEqual(Tag.array, std.meta.activeTag(parsed.value));
    try testing.expect(parsed.value.array.items.len >= 1);
    const first = parsed.value.array.items[0];
    try testing.expectEqual(Tag.object, std.meta.activeTag(first));
    try testing.expect(first.object.contains("score"));
    try testing.expect(first.object.contains("source_type"));
}

test "ffi: empty inputs return empty JSON array" {
    var result = slowclaw_feed_rank_stage2(
        @ptrCast(&[_]SlowclawInterest{}),
        0,
        @ptrCast(&[_]SlowclawInterest{}),
        0,
        @ptrCast(&[_]SlowclawCandidate{}),
        0,
        10,
        0,
        null,
    );
    defer slowclaw_feed_rank_result_free(&result);
    try testing.expectEqual(SLOWCLAW_OK, result.status);
    if (result.items_json.bytes) |b| {
        try testing.expectEqualStrings("[]", b[0..result.items_json.len]);
    }
}

test "ffi: writeJsonString escapes special chars" {
    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(testing.allocator);
    try writeJsonString(testing.allocator, &buf, "hello \"world\"\n\t");
    try testing.expectEqualStrings("\"hello \\\"world\\\"\\n\\t\"", buf.items);
}

// ── SQLite FFI round-trip tests ───────────────────────────────────────────

test "ffi: sqlite open/store/get/forget round-trip via C ABI" {
    const handle = slowclaw_feed_sqlite_open(":memory:", ":memory:".len, null) orelse return error.OOM;
    defer slowclaw_feed_sqlite_close(handle);

    try testing.expect(slowclaw_feed_sqlite_health(handle));

    // Store
    const status = slowclaw_feed_sqlite_store(
        handle,
        "favorite_lang", "favorite_lang".len,
        "Rust", "Rust".len,
        "core", "core".len,
        null, 0,
        null, 0,
        null, 0,
    );
    try testing.expectEqual(SLOWCLAW_OK, status);
    try testing.expectEqual(@as(c_int, 1), slowclaw_feed_sqlite_count(handle));

    // Get
    var entry: SlowclawSqliteEntry = std.mem.zeroes(SlowclawSqliteEntry);
    const get_status = slowclaw_feed_sqlite_get(handle, "favorite_lang", "favorite_lang".len, &entry);
    try testing.expectEqual(SLOWCLAW_OK, get_status);
    defer slowclaw_feed_sqlite_entry_free(&entry);
    try testing.expectEqualStrings("favorite_lang", entry.key.bytes.?[0..entry.key.len]);
    try testing.expectEqualStrings("Rust", entry.content.bytes.?[0..entry.content.len]);
    try testing.expectEqualStrings("core", entry.category.bytes.?[0..entry.category.len]);

    // Forget
    try testing.expectEqual(@as(c_int, 1), slowclaw_feed_sqlite_forget(handle, "favorite_lang", "favorite_lang".len));
    try testing.expectEqual(@as(c_int, 0), slowclaw_feed_sqlite_count(handle));
}

test "ffi: sqlite get nonexistent returns 1" {
    const handle = slowclaw_feed_sqlite_open(":memory:", ":memory:".len, null) orelse return error.OOM;
    defer slowclaw_feed_sqlite_close(handle);
    var entry: SlowclawSqliteEntry = std.mem.zeroes(SlowclawSqliteEntry);
    const status = slowclaw_feed_sqlite_get(handle, "nope", "nope".len, &entry);
    try testing.expectEqual(@as(c_int, 1), status);
}

test "ffi: sqlite store with session_id round-trips" {
    const handle = slowclaw_feed_sqlite_open(":memory:", ":memory:".len, null) orelse return error.OOM;
    defer slowclaw_feed_sqlite_close(handle);
    _ = slowclaw_feed_sqlite_store(
        handle,
        "k", "k".len,
        "v", "v".len,
        "core", "core".len,
        "session-abc", "session-abc".len,
        null, 0,
        null, 0,
    );
    var entry: SlowclawSqliteEntry = std.mem.zeroes(SlowclawSqliteEntry);
    _ = slowclaw_feed_sqlite_get(handle, "k", "k".len, &entry);
    defer slowclaw_feed_sqlite_entry_free(&entry);
    try testing.expectEqualStrings("session-abc", entry.session_id.bytes.?[0..entry.session_id.len]);
}

test "ffi: sqlite recall returns JSON array via C ABI" {
    // No embedder → keyword-only path; still works.
    const handle = slowclaw_feed_sqlite_open(":memory:", ":memory:".len, null) orelse return error.OOM;
    defer slowclaw_feed_sqlite_close(handle);
    _ = slowclaw_feed_sqlite_store(handle, "rust", "rust".len, "rust programming language", "rust programming language".len, "core", "core".len, null, 0, null, 0, null, 0);
    _ = slowclaw_feed_sqlite_store(handle, "weather", "weather".len, "sunny day today", "sunny day today".len, "core", "core".len, null, 0, null, 0, null, 0);

    var result: SlowclawRankResult = std.mem.zeroes(SlowclawRankResult);
    const status = slowclaw_feed_sqlite_recall(handle, "rust", "rust".len, 10, null, 0, &result);
    try testing.expectEqual(SLOWCLAW_OK, status);
    defer slowclaw_feed_sqlite_result_free(&result);

    const json_bytes = result.items_json.bytes orelse return error.NullJson;
    const json = json_bytes[0..result.items_json.len];
    const Tag = std.meta.Tag(std.json.Value);
    const parsed = std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{}) catch return error.JsonInvalid;
    defer parsed.deinit();
    try testing.expectEqual(Tag.array, std.meta.activeTag(parsed.value));
    try testing.expect(parsed.value.array.items.len >= 1);
}

test "ffi: parse_and_rank frees feed_items with the matching allocator (regression for iOS Reads SIGABRT)" {
    // Real-world RSS shape: many items, some with empty guid/link (HN-style).
    // The original bug: rss_parser.toFeedItems allocated with page_allocator
    // but this function freed with c_allocator → invalid free → the iOS app
    // aborted (malloc heap-corruption SIGABRT) every time Reads loaded.
    // This test runs the full parse→rank→serialize→free cycle through the FFI
    // (which uses c_allocator internally) many times; a mismatch would abort.
    const xml =
        \\<?xml version="1.0"?>
        \\<rss version="2.0"><channel>
        \\<title>Hacker News</title><link>https://news.ycombinator.com/</link>
        \\<description>HN</description>
        \\<item><title>Rust is memory safe</title><link>https://example.com/a</link><description>A post about rust</description><guid>a</guid><pubDate>Mon, 15 Jan 2024 10:30:00 GMT</pubDate></item>
        \\<item><title>AI news</title><link>https://example.com/b</link><description>LLM updates</description><guid>b</guid><pubDate>Mon, 15 Jan 2024 11:30:00 GMT</pubDate></item>
        \\<item><title>No guid item</title><link>https://example.com/c</link><description>Empty guid</description><pubDate></pubDate></item>
        \\<item><title>Empty link too</title><link></link><description>Edge case</description><pubDate></pubDate></item>
        \\</channel></rss>
    ;
    const src = "Hacker News";
    const now: f64 = 1_700_000_000.0;

    var i: usize = 0;
    while (i < 25) : (i += 1) {
        var result: SlowclawRankResult = .{ .items_json = SlowclawString.empty(), .status = 0 };
        const status = slowclaw_feed_parse_and_rank(
            xml.ptr, xml.len, src.ptr, src.len, null, 0, now, &result,
        );
        try testing.expectEqual(SLOWCLAW_OK, status);
        try testing.expectEqual(@as(c_int, SLOWCLAW_OK), result.status);
        slowclaw_feed_rank_result_free(&result);
    }
}

test "ffi: parse_and_rank with topics incl. escaped label does not corrupt the heap (UAF regression)" {
    // std.json stores ESCAPED strings in its parsed arena and unescaped
    // strings as slices into the caller's input buffer. parseTopicsJson must
    // dup every label into c_allocator because the arena is freed (defer
    // parsed.deinit()) before rankReads reads the topics — and the caller's
    // input buffer only lives for the FFI call. Before the dup fix, an escaped
    // label (the "a\"b" below) was a dangling arena pointer → rankReads read
    // freed memory → heap corruption → SIGABRT at the next free. Run many
    // iterations so a freed arena page is more likely to be reused/overwritten.
    const xml =
        \\<?xml version="1.0"?>
        \\<rss version="2.0"><channel>
        \\<title>Tech</title><link>https://example.com/</link><description>Tech news</description>
        \\<item><title>Rust async runtime</title><link>https://example.com/a</link><description>tokio internals</description><guid>a</guid><pubDate>Mon, 15 Jan 2024 10:30:00 GMT</pubDate></item>
        \\<item><title>Cycling in Berlin</title><link>https://example.com/b</link><description>urban riding</description><guid>b</guid><pubDate>Mon, 15 Jan 2024 11:30:00 GMT</pubDate></item>
        \\</channel></rss>
    ;
    // The "a\"b" label is a JSON-escaped string — forces the arena path.
    const topics_json =
        \\[{"label":"a\"b","weight":1.0},{"label":"rust","weight":2.0}]
    ;
    const src = "Tech";
    const now: f64 = 1_700_000_000.0;

    var i: usize = 0;
    while (i < 50) : (i += 1) {
        var result: SlowclawRankResult = .{ .items_json = SlowclawString.empty(), .status = 0 };
        const status = slowclaw_feed_parse_and_rank(
            xml.ptr, xml.len, src.ptr, src.len, topics_json.ptr, topics_json.len, now, &result,
        );
        try testing.expectEqual(SLOWCLAW_OK, status);
        try testing.expectEqual(@as(c_int, SLOWCLAW_OK), result.status);
        try testing.expect(result.items_json.len > 0);
        slowclaw_feed_rank_result_free(&result);
    }
}

// ──────────────────────────────────────────────────────────────────────────
// Sync FFI round-trip: the deterministic proxy for cross-device sync
// correctness (AGENTS.md §7). build_manifest → diff → entry_for_transfer →
// apply_entries must converge two stores through the C ABI.
// ──────────────────────────────────────────────────────────────────────────

test "ffi: sync manifest build/diff/apply round-trip via C ABI" {
    // Device A: two journal entries.
    const handle_a = slowclaw_feed_sqlite_open(":memory:", ":memory:".len, null) orelse return error.OOM;
    defer slowclaw_feed_sqlite_close(handle_a);
    try testing.expectEqual(SLOWCLAW_OK, slowclaw_feed_sqlite_store(
        handle_a,
        "slowclaw_user_key_1", "slowclaw_user_key_1".len,
        "journal from A1", "journal from A1".len,
        "daily", "daily".len,
        null, 0, "text", "text".len, null, 0,
    ));
    try testing.expectEqual(SLOWCLAW_OK, slowclaw_feed_sqlite_store(
        handle_a,
        "slowclaw_user_key_2", "slowclaw_user_key_2".len,
        "journal from A2", "journal from A2".len,
        "daily", "daily".len,
        null, 0, "text", "text".len, null, 0,
    ));

    // Device B: empty.
    const handle_b = slowclaw_feed_sqlite_open(":memory:", ":memory:".len, null) orelse return error.OOM;
    defer slowclaw_feed_sqlite_close(handle_b);

    // A builds its manifest.
    var manifest_a_json = SlowclawString.empty();
    try testing.expectEqual(SLOWCLAW_OK, slowclaw_feed_sync_build_manifest(handle_a, null, 0, &manifest_a_json));
    defer if (manifest_a_json.bytes) |b| c_allocator.free(b[0..manifest_a_json.len]);
    try testing.expect(manifest_a_json.len > 0);

    // B builds its (empty) manifest.
    var manifest_b_json = SlowclawString.empty();
    try testing.expectEqual(SLOWCLAW_OK, slowclaw_feed_sync_build_manifest(handle_b, null, 0, &manifest_b_json));
    defer if (manifest_b_json.bytes) |b| c_allocator.free(b[0..manifest_b_json.len]);

    // B diffs: local=B(empty), remote=A. Both keys should be in to_pull.
    var diff_result: SlowclawRankResult = .{ .items_json = SlowclawString.empty(), .status = 0 };
    const diff_status = slowclaw_feed_sync_diff(
        manifest_b_json.bytes.?, manifest_b_json.len,
        manifest_a_json.bytes.?, manifest_a_json.len,
        &diff_result,
    );
    try testing.expectEqual(SLOWCLAW_OK, diff_status);
    defer slowclaw_feed_sync_result_free(&diff_result);
    try testing.expect(diff_result.items_json.len > 0);
    const diff_slice = diff_result.items_json.bytes.?[0..diff_result.items_json.len];
    try testing.expect(std.mem.indexOf(u8, diff_slice, "slowclaw_user_key_1") != null);
    try testing.expect(std.mem.indexOf(u8, diff_slice, "slowclaw_user_key_2") != null);

    // Fetch each entry from A (proves entry_for_transfer works) then apply on B.
    var e1: SlowclawSqliteEntry = std.mem.zeroes(SlowclawSqliteEntry);
    try testing.expectEqual(SLOWCLAW_OK, slowclaw_feed_sync_entry_for_transfer(handle_a, "slowclaw_user_key_1", "slowclaw_user_key_1".len, &e1));
    defer slowclaw_feed_sqlite_entry_free(&e1);
    try testing.expectEqualStrings("journal from A1", e1.content.bytes.?[0..e1.content.len]);

    // The shell builds the transfer JSON; here we hand-roll it for the test.
    const transfer_json =
        "[{\"key\":\"slowclaw_user_key_1\",\"content\":\"journal from A1\",\"category\":\"daily\",\"updated_at\":\"2026-01-01T00:00:00Z\",\"source\":\"text\"}," ++
        "{\"key\":\"slowclaw_user_key_2\",\"content\":\"journal from A2\",\"category\":\"daily\",\"updated_at\":\"2026-01-01T00:00:00Z\",\"source\":\"text\"}]";
    try testing.expectEqual(SLOWCLAW_OK, slowclaw_feed_sync_apply_entries(handle_b, transfer_json.ptr, transfer_json.len));
    try testing.expectEqual(@as(c_int, 2), slowclaw_feed_sqlite_count(handle_b));

    // B's manifest now matches A's content (same keys).
    var manifest_b_after = SlowclawString.empty();
    try testing.expectEqual(SLOWCLAW_OK, slowclaw_feed_sync_build_manifest(handle_b, null, 0, &manifest_b_after));
    defer if (manifest_b_after.bytes) |b| c_allocator.free(b[0..manifest_b_after.len]);
    const after_slice = manifest_b_after.bytes.?[0..manifest_b_after.len];
    try testing.expect(std.mem.indexOf(u8, after_slice, "slowclaw_user_key_1") != null);
    try testing.expect(std.mem.indexOf(u8, after_slice, "slowclaw_user_key_2") != null);

    // Re-diff A vs B's new manifest: nothing to transfer.
    var diff2: SlowclawRankResult = .{ .items_json = SlowclawString.empty(), .status = 0 };
    try testing.expectEqual(SLOWCLAW_OK, slowclaw_feed_sync_diff(
        manifest_a_json.bytes.?, manifest_a_json.len,
        manifest_b_after.bytes.?, manifest_b_after.len,
        &diff2,
    ));
    defer slowclaw_feed_sync_result_free(&diff2);
    const d2_slice = diff2.items_json.bytes.?[0..diff2.items_json.len];
    try testing.expect(std.mem.indexOf(u8, d2_slice, "\"to_pull\":[]") != null);
    try testing.expect(std.mem.indexOf(u8, d2_slice, "\"to_push\":[]") != null);
}

test "ffi: sync entry_for_transfer returns 1 for missing key" {
    const handle = slowclaw_feed_sqlite_open(":memory:", ":memory:".len, null) orelse return error.OOM;
    defer slowclaw_feed_sqlite_close(handle);
    var entry: SlowclawSqliteEntry = std.mem.zeroes(SlowclawSqliteEntry);
    try testing.expectEqual(@as(c_int, 1), slowclaw_feed_sync_entry_for_transfer(handle, "missing", "missing".len, &entry));
}

