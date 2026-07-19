//! Vector operations — cosine similarity, normalization, hybrid merge.
//!
//! Ported from `src/memory/vector.rs` (lines 4–132 + tests). The Rust source is
//! the authoritative spec; the tests below mirror the Rust test cases using
//! their original tolerances (0.001 for cosine, `std.math.floatEps(f32)` for
//! byte round-trips). Pure functions, no allocator needed for `cosine_similarity`
//! and `vec_to_bytes`/`bytes_to_vec`; `hybrid_merge` takes an allocator.

const std = @import("std");
const testing = std.testing;

/// Cosine similarity between two f32 vectors. Returns 0.0–1.0 (clamped).
///
/// Mirrors `cosine_similarity` in `src/memory/vector.rs:4`:
///   - 0.0 if lengths differ or either is empty
///   - dot/norms accumulated in f64 for precision, then clamped to f32 in [0, 1]
///   - guards NaN/inf (returns 0.0 on non-finite intermediate results)
pub fn cosine_similarity(a: []const f32, b: []const f32) f32 {
    if (a.len != b.len or a.len == 0) return 0.0;

    var dot: f64 = 0.0;
    var norm_a: f64 = 0.0;
    var norm_b: f64 = 0.0;

    for (a, b) |x, y| {
        const xf: f64 = x;
        const yf: f64 = y;
        dot += xf * yf;
        norm_a += xf * xf;
        norm_b += yf * yf;
    }

    const denom = @sqrt(norm_a) * @sqrt(norm_b);
    if (!std.math.isFinite(denom) or denom < std.math.floatEps(f64)) return 0.0;

    const raw = dot / denom;
    if (!std.math.isFinite(raw)) return 0.0;

    // Clamp to [0, 1] — embeddings are typically positive.
    const clamped: f64 = @max(0.0, @min(1.0, raw));
    return @floatCast(clamped);
}

/// Serialize an f32 vector to little-endian bytes.
/// Mirrors `vec_to_bytes` in `src/memory/vector.rs:38`.
pub fn vec_to_bytes(v: []const f32, out: []u8) []u8 {
    std.debug.assert(out.len >= v.len * 4);
    var i: usize = 0;
    for (v) |f| {
        const le = std.mem.nativeToLittle(f32, f);
        std.mem.writeInt(u32, out[i..][0..4], @bitCast(le), .little);
        i += 4;
    }
    return out[0 .. v.len * 4];
}

/// Deserialize little-endian bytes to f32. Non-aligned trailing bytes are
/// dropped (matches Rust's `chunks_exact(4)` behavior).
/// Mirrors `bytes_to_vec` in `src/memory/vector.rs:47`.
pub fn bytes_to_vec(bytes: []const u8, out: []f32) []f32 {
    const n = bytes.len / 4;
    std.debug.assert(out.len >= n);
    var i: usize = 0;
    var j: usize = 0;
    while (i < n) : (i += 1) {
        const chunk = bytes[j..][0..4];
        const bits = std.mem.readInt(u32, chunk, .little);
        out[i] = @bitCast(bits);
        j += 4;
    }
    return out[0..n];
}

/// A scored hybrid-merge result. Mirrors `ScoredResult` in `src/memory/vector.rs:58`.
pub const ScoredResult = struct {
    id: []const u8,
    vector_score: ?f32 = null,
    keyword_score: ?f32 = null,
    final_score: f32 = 0.0,
};

/// An (id, score) pair, used as input to `hybrid_merge`.
pub const IdScore = struct { id: []const u8, score: f32 };

/// Hybrid merge: combine vector and keyword results with weighted fusion.
///
/// Mirrors `hybrid_merge` in `src/memory/vector.rs:72`:
///   - normalizes keyword scores by the max (vector scores already 0–1)
///   - `final_score = vector_weight * v + keyword_weight * k`
///   - deduplicates by id (first source sets optional fields, second fills in)
///   - sorts descending by final_score, truncates to `limit`
///
/// Caller owns the returned slice (backed by `allocator`).
pub fn hybrid_merge(
    allocator: std.mem.Allocator,
    vector_results: []const IdScore,
    keyword_results: []const IdScore,
    vector_weight: f32,
    keyword_weight: f32,
    limit: usize,
) ![]ScoredResult {
    var map = std.StringHashMap(ScoredResult).init(allocator);
    defer map.deinit();

    // Vector scores are already normalized (cosine similarity ∈ [0, 1]).
    for (vector_results) |entry| {
        const gop = try map.getOrPut(entry.id);
        if (!gop.found_existing) {
            gop.value_ptr.* = .{ .id = entry.id };
        }
        gop.value_ptr.vector_score = entry.score;
    }

    // Normalize keyword scores by the max (BM25 can be any positive number).
    var max_kw: f32 = 0.0;
    for (keyword_results) |entry| max_kw = @max(max_kw, entry.score);
    if (max_kw < std.math.floatEps(f32)) max_kw = 1.0;

    for (keyword_results) |entry| {
        const normalized = entry.score / max_kw;
        const gop = try map.getOrPut(entry.id);
        if (!gop.found_existing) {
            gop.value_ptr.* = .{ .id = entry.id };
        }
        gop.value_ptr.keyword_score = normalized;
    }

    // Compute final scores, collect into a sortable slice.
    var results = try std.ArrayList(ScoredResult).initCapacity(allocator, map.count());
    defer results.deinit(allocator);
    var it = map.iterator();
    while (it.next()) |e| {
        var r = e.value_ptr.*;
        const vs = r.vector_score orelse 0.0;
        const ks = r.keyword_score orelse 0.0;
        r.final_score = vector_weight * vs + keyword_weight * ks;
        try results.append(allocator, r);
    }

    // Sort descending by final_score (NaNs sorted last — Rust uses
    // partial_cmp().unwrap_or(Equal); we map NaN to -inf so it ranks lowest).
    const SortCtx = struct {
        fn lessThan(_: void, a: ScoredResult, b: ScoredResult) bool {
            const neg_inf: f32 = -std.math.inf(f32);
            const ba: f32 = if (std.math.isNan(b.final_score)) neg_inf else b.final_score;
            const aa: f32 = if (std.math.isNan(a.final_score)) neg_inf else a.final_score;
            // Descending: a should come BEFORE b when a's score is greater.
            return aa > ba;
        }
    };
    std.mem.sort(ScoredResult, results.items, {}, SortCtx.lessThan);

    const take = @min(results.items.len, limit);
    const out = try allocator.alloc(ScoredResult, take);
    @memcpy(out, results.items[0..take]);
    return out;
}

// ──────────────────────────────────────────────────────────────────────────
// Tests — ported from `src/memory/vector.rs` (lines 144–402).
// Tolerances match the Rust originals: 0.001 for cosine, f32 epsilon for bytes.
// ──────────────────────────────────────────────────────────────────────────

test "cosine: identical vectors" {
    const v = [_]f32{ 1.0, 2.0, 3.0 };
    const sim = cosine_similarity(&v, &v);
    try testing.expect(@abs(sim - 1.0) < 0.001);
}

test "cosine: orthogonal vectors" {
    const a = [_]f32{ 1.0, 0.0, 0.0 };
    const b = [_]f32{ 0.0, 1.0, 0.0 };
    const sim = cosine_similarity(&a, &b);
    try testing.expect(@abs(sim) < 0.001);
}

test "cosine: similar vectors" {
    const a = [_]f32{ 1.0, 2.0, 3.0 };
    const b = [_]f32{ 1.1, 2.1, 3.1 };
    const sim = cosine_similarity(&a, &b);
    try testing.expect(sim > 0.99);
}

test "cosine: empty returns zero" {
    const empty: [0]f32 = .{};
    try testing.expectEqual(@as(f32, 0.0), cosine_similarity(&empty, &empty));
}

test "cosine: mismatched lengths" {
    const a = [_]f32{1.0};
    const b = [_]f32{ 1.0, 2.0 };
    try testing.expectEqual(@as(f32, 0.0), cosine_similarity(&a, &b));
}

test "cosine: zero vector" {
    const a = [_]f32{ 0.0, 0.0, 0.0 };
    const b = [_]f32{ 1.0, 2.0, 3.0 };
    try testing.expectEqual(@as(f32, 0.0), cosine_similarity(&a, &b));
}

test "cosine: NaN returns finite" {
    const a = [_]f32{ std.math.nan(f32), 1.0, 2.0 };
    const b = [_]f32{ 1.0, 2.0, 3.0 };
    const sim = cosine_similarity(&a, &b);
    try testing.expect(std.math.isFinite(sim));
}

test "cosine: infinity returns finite" {
    const a = [_]f32{ std.math.inf(f32), 1.0 };
    const b = [_]f32{ 1.0, 2.0 };
    const sim = cosine_similarity(&a, &b);
    try testing.expect(std.math.isFinite(sim));
}

test "cosine: negative values (identical) → clamped to 1.0" {
    const a = [_]f32{ -1.0, -2.0, -3.0 };
    const b = [_]f32{ -1.0, -2.0, -3.0 };
    const sim = cosine_similarity(&a, &b);
    try testing.expect(@abs(sim - 1.0) < 0.001);
}

test "cosine: opposite vectors clamped to 0" {
    const a = [_]f32{ 1.0, 0.0 };
    const b = [_]f32{ -1.0, 0.0 };
    const sim = cosine_similarity(&a, &b);
    try testing.expect(@abs(sim) < std.math.floatEps(f32));
}

test "cosine: high dimensional (1536)" {
    var a_buf: [1536]f32 = undefined;
    var b_buf: [1536]f32 = undefined;
    for (0..1536) |i| {
        const fi: f32 = @floatFromInt(i);
        a_buf[i] = fi * 0.001;
        b_buf[i] = fi * 0.001 + 0.0001;
    }
    const sim = cosine_similarity(&a_buf, &b_buf);
    try testing.expect(sim > 0.99);
}

test "cosine: single element" {
    const a1 = [_]f32{5.0};
    const b1 = [_]f32{5.0};
    try testing.expect(@abs(cosine_similarity(&a1, &b1) - 1.0) < 0.001);
    const a2 = [_]f32{5.0};
    const b2 = [_]f32{-5.0};
    try testing.expect(@abs(cosine_similarity(&a2, &b2)) < std.math.floatEps(f32));
}

test "cosine: both zero vectors" {
    const a = [_]f32{ 0.0, 0.0 };
    const b = [_]f32{ 0.0, 0.0 };
    try testing.expect(@abs(cosine_similarity(&a, &b)) < std.math.floatEps(f32));
}

test "vec_bytes: roundtrip" {
    const original = [_]f32{ 1.0, -2.5, 3.14, 0.0, std.math.floatMax(f32) };
    var bytes_buf: [original.len * 4]u8 = undefined;
    const bytes = vec_to_bytes(&original, &bytes_buf);
    var restored_buf: [original.len]f32 = undefined;
    const restored = bytes_to_vec(bytes, &restored_buf);
    try testing.expectEqualSlices(f32, &original, restored);
}

test "vec_bytes: empty" {
    const empty: [0]f32 = .{};
    var bytes_buf: [0]u8 = .{};
    const bytes = vec_to_bytes(&empty, &bytes_buf);
    try testing.expect(bytes.len == 0);
    var restored_buf: [0]f32 = .{};
    const restored = bytes_to_vec(bytes, &restored_buf);
    try testing.expect(restored.len == 0);
}

test "vec_bytes: non-aligned truncates" {
    // 5 bytes → only first 4 used (1 float), last byte dropped.
    const bytes = [_]u8{ 0, 0, 0, 0, 0xFF };
    var out_buf: [1]f32 = undefined;
    const result = bytes_to_vec(&bytes, &out_buf);
    try testing.expectEqual(@as(usize, 1), result.len);
    try testing.expect(@abs(result[0]) < std.math.floatEps(f32));
}

test "vec_bytes: three bytes returns empty" {
    const bytes = [_]u8{ 1, 2, 3 };
    var out_buf: [1]f32 = undefined;
    const result = bytes_to_vec(&bytes, &out_buf);
    try testing.expect(result.len == 0);
}

test "vec_bytes: roundtrip special values (bit-exact)" {
    const special = [_]f32{ std.math.floatMin(f32), std.math.floatMax(f32), std.math.floatEps(f32), -0.0, 0.0 };
    var bytes_buf: [special.len * 4]u8 = undefined;
    const bytes = vec_to_bytes(&special, &bytes_buf);
    var restored_buf: [special.len]f32 = undefined;
    const restored = bytes_to_vec(bytes, &restored_buf);
    try testing.expectEqual(special.len, restored.len);
    for (special, restored) |a, b| {
        try testing.expectEqual(@as(u32, @bitCast(a)), @as(u32, @bitCast(b)));
    }
}

test "vec_bytes: NaN preserves bits" {
    const nan_vec = [_]f32{std.math.nan(f32)};
    var bytes_buf: [4]u8 = undefined;
    const bytes = vec_to_bytes(&nan_vec, &bytes_buf);
    var restored_buf: [1]f32 = undefined;
    const restored = bytes_to_vec(bytes, &restored_buf);
    try testing.expect(std.math.isNan(restored[0]));
}

// ── hybrid_merge tests (ported from src/memory/vector.rs:201–401) ────────

const Pair = IdScore;

fn freeMerged(allocator: std.mem.Allocator, merged: []ScoredResult) void {
    allocator.free(merged);
}

test "hybrid_merge: vector only" {
    const allocator = std.testing.allocator;
    const vec_results = [_]Pair{ .{ .id = "a", .score = 0.9 }, .{ .id = "b", .score = 0.5 } };
    const merged = try hybrid_merge(allocator, &vec_results, &.{}, 0.7, 0.3, 10);
    defer freeMerged(allocator, merged);
    try testing.expectEqual(@as(usize, 2), merged.len);
    try testing.expectEqualStrings("a", merged[0].id);
    try testing.expect(merged[0].final_score > merged[1].final_score);
}

test "hybrid_merge: keyword only" {
    const allocator = std.testing.allocator;
    const kw_results = [_]Pair{ .{ .id = "x", .score = 10.0 }, .{ .id = "y", .score = 5.0 } };
    const merged = try hybrid_merge(allocator, &.{}, &kw_results, 0.7, 0.3, 10);
    defer freeMerged(allocator, merged);
    try testing.expectEqual(@as(usize, 2), merged.len);
    try testing.expectEqualStrings("x", merged[0].id);
}

test "hybrid_merge: deduplicates" {
    const allocator = std.testing.allocator;
    const vec_results = [_]Pair{.{ .id = "a", .score = 0.9 }};
    const kw_results = [_]Pair{.{ .id = "a", .score = 10.0 }};
    const merged = try hybrid_merge(allocator, &vec_results, &kw_results, 0.7, 0.3, 10);
    defer freeMerged(allocator, merged);
    try testing.expectEqual(@as(usize, 1), merged.len);
    try testing.expectEqualStrings("a", merged[0].id);
    try testing.expect(merged[0].vector_score != null);
    try testing.expect(merged[0].keyword_score != null);
    try testing.expect(merged[0].final_score > 0.7 * 0.9);
}

test "hybrid_merge: respects limit" {
    const allocator = std.testing.allocator;
    var vec_buf: [20]Pair = undefined;
    for (0..20) |i| {
        vec_buf[i] = .{ .id = "", .score = 1.0 - @as(f32, @floatFromInt(i)) * 0.05 };
        // Distinct ids needed for dedupe semantics — use the buffer index.
        vec_buf[i].id = switch (i) {
            0 => "item_0",
            1 => "item_1",
            2 => "item_2",
            3 => "item_3",
            4 => "item_4",
            5 => "item_5",
            6 => "item_6",
            7 => "item_7",
            8 => "item_8",
            9 => "item_9",
            10 => "item_10",
            11 => "item_11",
            12 => "item_12",
            13 => "item_13",
            14 => "item_14",
            15 => "item_15",
            16 => "item_16",
            17 => "item_17",
            18 => "item_18",
            else => "item_19",
        };
    }
    const merged = try hybrid_merge(allocator, &vec_buf, &.{}, 1.0, 0.0, 5);
    defer freeMerged(allocator, merged);
    try testing.expectEqual(@as(usize, 5), merged.len);
}

test "hybrid_merge: empty inputs" {
    const allocator = std.testing.allocator;
    const merged = try hybrid_merge(allocator, &.{}, &.{}, 0.7, 0.3, 10);
    defer freeMerged(allocator, merged);
    try testing.expect(merged.len == 0);
}

test "hybrid_merge: limit zero" {
    const allocator = std.testing.allocator;
    const vec_results = [_]Pair{.{ .id = "a", .score = 0.9 }};
    const merged = try hybrid_merge(allocator, &vec_results, &.{}, 0.7, 0.3, 0);
    defer freeMerged(allocator, merged);
    try testing.expect(merged.len == 0);
}

test "hybrid_merge: zero weights" {
    const allocator = std.testing.allocator;
    const vec_results = [_]Pair{.{ .id = "a", .score = 0.9 }};
    const kw_results = [_]Pair{.{ .id = "b", .score = 10.0 }};
    const merged = try hybrid_merge(allocator, &vec_results, &kw_results, 0.0, 0.0, 10);
    defer freeMerged(allocator, merged);
    for (merged) |r| try testing.expect(@abs(r.final_score) < std.math.floatEps(f32));
}

test "hybrid_merge: negative keyword scores stay finite" {
    const allocator = std.testing.allocator;
    const kw_results = [_]Pair{ .{ .id = "a", .score = -5.0 }, .{ .id = "b", .score = -1.0 } };
    const merged = try hybrid_merge(allocator, &.{}, &kw_results, 0.7, 0.3, 10);
    defer freeMerged(allocator, merged);
    try testing.expectEqual(@as(usize, 2), merged.len);
    for (merged) |r| try testing.expect(std.math.isFinite(r.final_score));
}

test "hybrid_merge: duplicate ids in same source dedupe" {
    const allocator = std.testing.allocator;
    const vec_results = [_]Pair{ .{ .id = "a", .score = 0.9 }, .{ .id = "a", .score = 0.5 } };
    const merged = try hybrid_merge(allocator, &vec_results, &.{}, 1.0, 0.0, 10);
    defer freeMerged(allocator, merged);
    try testing.expectEqual(@as(usize, 1), merged.len);
}

test "hybrid_merge: large bm25 normalization" {
    const allocator = std.testing.allocator;
    const kw_results = [_]Pair{ .{ .id = "a", .score = 1000.0 }, .{ .id = "b", .score = 500.0 }, .{ .id = "c", .score = 1.0 } };
    const merged = try hybrid_merge(allocator, &.{}, &kw_results, 0.0, 1.0, 10);
    defer freeMerged(allocator, merged);
    try testing.expect((merged[0].keyword_score.? - 1.0) < 0.001);
    try testing.expect((merged[1].keyword_score.? - 0.5) < 0.001);
}

test "hybrid_merge: single item" {
    const allocator = std.testing.allocator;
    const vec_results = [_]Pair{.{ .id = "only", .score = 0.8 }};
    const merged = try hybrid_merge(allocator, &vec_results, &.{}, 0.7, 0.3, 10);
    defer freeMerged(allocator, merged);
    try testing.expectEqual(@as(usize, 1), merged.len);
    try testing.expectEqualStrings("only", merged[0].id);
}
