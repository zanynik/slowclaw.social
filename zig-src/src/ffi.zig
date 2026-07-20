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
/// `category`/`timestamp`/`session_id` are all Zig-owned UTF-8; the caller
/// frees the entire result via `slowclaw_feed_sqlite_entry_free`.
pub const SlowclawSqliteEntry = extern struct {
    id: SlowclawString,
    key: SlowclawString,
    content: SlowclawString,
    /// Lowercase category name (e.g. "core", "daily", "conversation", or the
    /// custom name). Mirrors `MemoryCategory.toString()`.
    category: SlowclawString,
    timestamp: SlowclawString,
    session_id: SlowclawString, // bytes=null when absent
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
/// "conversation", or any custom name). `session_id` is `{null, 0}` if absent.
/// Returns 0 on success, negative on error.
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
) c_int {
    const db: *sqlite.SqliteMemory = @ptrCast(@alignCast(handle));
    const cat = categoryToEnum(category[0..category_len]);
    const sid_slice: ?[]const u8 = if (session_id) |p| p[0..session_id_len] else null;
    db.store(key[0..key_len], content[0..content_len], cat, sid_slice) catch return SLOWCLAW_ERR_INTERNAL;
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
///     "session_id":...|null, "score":...|null }
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
// Internal helpers — C-struct ↔ Zig-struct conversion and JSON serialization.
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
    _ = slowclaw_feed_sqlite_store(handle, "rust", "rust".len, "rust programming language", "rust programming language".len, "core", "core".len, null, 0);
    _ = slowclaw_feed_sqlite_store(handle, "weather", "weather".len, "sunny day today", "sunny day today".len, "core", "core".len, null, 0);

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
