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
export fn slowclaw_feed_free(ptr: ?*anyopaque) void {
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

export fn slowclaw_feed_hash_embedder_new(model: [*]const u8, model_len: usize, dims: usize) ?*SlowclawHashEmbedder {
    const model_slice = model[0..model_len];
    const he = c_allocator.create(embeddings.HashEmbedding) catch return null;
    he.* = embeddings.HashEmbedding.init(model_slice, dims);
    return @ptrCast(he);
}

export fn slowclaw_feed_hash_embedder_free(handle: ?*SlowclawHashEmbedder) void {
    if (handle) |h| {
        const he: *embeddings.HashEmbedding = @ptrCast(@alignCast(h));
        c_allocator.destroy(he);
    }
}

/// Embed a single text. The returned `SlowclawString.bytes` points to a
/// Zig-owned buffer of `dims * sizeof(f32)` bytes; the caller frees it via
/// `slowclaw_feed_free`. On error returns a SlowclawString with null bytes.
export fn slowclaw_feed_hash_embed(
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

export fn slowclaw_feed_rank_stage2(
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

export fn slowclaw_feed_rank_result_free(result: *SlowclawRankResult) void {
    if (result.items_json.bytes) |b| {
        const slice = b[0..result.items_json.len];
        c_allocator.free(slice);
        result.* = .{ .items_json = SlowclawString.empty(), .status = SLOWCLAW_OK };
    }
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
