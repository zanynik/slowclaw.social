//! Embedding providers — convert text to dense vectors.
//!
//! Ports the `EmbeddingProvider` trait, `HashEmbedding` (deterministic fallback),
//! and `NoopEmbedding` from `src/memory/embeddings.rs`. The heavier providers
//! (`BuiltinEmbedding` via tract-onnx + tokenizers, `OpenAiEmbedding` via HTTP)
//! stay on the FFI/Swift side of a later slice — they have no Zig equivalents.
//!
//! `HashEmbedding` is fully deterministic and pure (FNV-1a hashing into a
//! fixed-size vector, then L2-normalized). It is the production fallback when
//! the ONNX model fails to load, and it doubles as the test embedder for the
//! ranker — replacing the earlier `StubEmbedderCtx` with a real, spec-backed
//! implementation.

const std = @import("std");
const testing = std.testing;

/// Error surface for embedding operations.
pub const EmbedError = error{
    ProviderUnavailable,
    InvalidInput,
    OutOfMemory,
};

/// Vtable for an embedding provider. Mirrors the `EmbeddingProvider` trait in
/// `src/memory/embeddings.rs:15`. Implementers fill in `ctx` (their state) and
/// the three function pointers. `embed_one` is provided as a default method
/// on the `EmbeddingProvider` wrapper (mirrors the Rust trait's default body).
pub const EmbeddingProvider = struct {
    ctx: *anyopaque,
    name_fn: *const fn (ctx: *anyopaque) []const u8,
    dimensions_fn: *const fn (ctx: *anyopaque) usize,
    /// Embed `texts` into `out_vecs`. Each produced vector is allocator-owned
    /// (the caller frees each element and the outer slice).
    embed_fn: *const fn (
        ctx: *anyopaque,
        allocator: std.mem.Allocator,
        texts: []const []const u8,
        out_vecs: *std.ArrayList([]f32),
    ) EmbedError!void,

    pub fn name(self: EmbeddingProvider) []const u8 {
        return self.name_fn(self.ctx);
    }

    pub fn dimensions(self: EmbeddingProvider) usize {
        return self.dimensions_fn(self.ctx);
    }

    /// Embed a batch of texts into vectors. Caller owns the outer slice and
    /// each inner vector; free with `freeEmbeddings`.
    pub fn embed(
        self: EmbeddingProvider,
        allocator: std.mem.Allocator,
        texts: []const []const u8,
    ) EmbedError![][]f32 {
        var out_vecs = std.ArrayList([]f32).empty;
        errdefer {
            for (out_vecs.items) |v| allocator.free(v);
            out_vecs.deinit(allocator);
        }
        try self.embed_fn(self.ctx, allocator, texts, &out_vecs);
        return out_vecs.toOwnedSlice(allocator);
    }

    /// Embed a single text. Mirrors the Rust trait's default `embed_one` body
    /// (embeds a 1-element batch, pops the single result).
    pub fn embed_one(self: EmbeddingProvider, allocator: std.mem.Allocator, text: []const u8) EmbedError![]f32 {
        const slice = try self.embed(allocator, &.{text});
        errdefer allocator.free(slice);
        defer {
            for (slice[1..]) |v| allocator.free(v);
            allocator.free(slice);
        }
        if (slice.len == 0) return error.InvalidInput;
        const first = try allocator.dupe(f32, slice[0]);
        return first;
    }
};

/// Free a slice of embeddings returned by `EmbeddingProvider.embed`.
pub fn freeEmbeddings(allocator: std.mem.Allocator, vecs: [][]f32) void {
    for (vecs) |v| allocator.free(v);
    allocator.free(vecs);
}

// ──────────────────────────────────────────────────────────────────────────
// NoopEmbedding — the "memory disabled" provider. Returns no vectors.
// Mirrors `NoopEmbedding` in src/memory/embeddings.rs:491.
// ──────────────────────────────────────────────────────────────────────────

pub const NoopEmbedding = struct {
    pub fn provider(self: *NoopEmbedding) EmbeddingProvider {
        return .{
            .ctx = self,
            .name_fn = noopName,
            .dimensions_fn = noopDimensions,
            .embed_fn = noopEmbed,
        };
    }
    fn noopName(_: *anyopaque) []const u8 {
        return "none";
    }
    fn noopDimensions(_: *anyopaque) usize {
        return 0;
    }
    fn noopEmbed(
        _: *anyopaque,
        _: std.mem.Allocator,
        _: []const []const u8,
        out_vecs: *std.ArrayList([]f32),
    ) EmbedError!void {
        _ = out_vecs;
    }
};

// ──────────────────────────────────────────────────────────────────────────
// HashEmbedding — deterministic fallback embedder.
// Mirrors `HashEmbedding` in src/memory/embeddings.rs:45-165.
// ──────────────────────────────────────────────────────────────────────────

const FNV_OFFSET: u64 = 0xcbf29ce484222325;
const FNV_PRIME: u64 = 0x00000100000001b3;

/// Stable 64-bit FNV-1a hash of a byte string. Matches `stable_hash64` in
/// embeddings.rs:75.
fn stable_hash64(input: []const u8) u64 {
    var hash: u64 = FNV_OFFSET;
    for (input) |b| {
        hash ^= b;
        hash = hash *% FNV_PRIME;
    }
    return hash;
}

/// Add a hashed feature into `vector` at the bucket chosen by `feature`'s hash.
/// The sign is determined by the low bit of the hash. Matches
/// `add_hashed_feature` in embeddings.rs:88.
fn add_hashed_feature(vector: []f32, feature: []const u8, weight: f32) void {
    if (vector.len == 0) return;
    const h = stable_hash64(feature);
    const index = @as(usize, @intCast(h % @as(u64, vector.len)));
    const sign: f32 = if ((h & 1) == 0) 1.0 else -1.0;
    vector[index] += sign * weight;
}

/// Normalize text: lowercase, keep only alphanumeric chars, collapse runs of
/// non-alphanumeric to single ASCII spaces, trim. Matches `normalize_text`
/// in embeddings.rs:58. Returns an allocator-owned slice.
fn normalize_text(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    var out = std.ArrayList(u8).empty;
    defer out.deinit(allocator);
    var last_was_space = true;
    var view = std.unicode.Utf8View.init(raw) catch return allocLowerAsciiFallback(allocator, raw);
    var it = view.iterator();
    while (it.nextCodepoint()) |cp| {
        // For each Unicode codepoint, lowercase it (one codepoint may expand
        // when lowercased; for the ASCII-heavy inputs we expect this is a no-op
        // in practice). Zig's std.unicode doesn't expose full case mapping, so
        // we ASCII-lowercase codepoints < 128 and pass through everything else.
        if (isAlphanumericCodepoint(cp)) {
            const lower_cp = if (cp < 128) std.ascii.toLower(@intCast(cp)) else cp;
            try encodeCp(allocator, &out, lower_cp);
            last_was_space = false;
        } else if (!last_was_space) {
            try out.append(allocator, ' ');
            last_was_space = true;
        }
    }
    const trimmed = std.mem.trim(u8, out.items, " \t\n\r\x0c\x0b");
    return allocator.dupe(u8, trimmed);
}

fn allocLowerAsciiFallback(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    // Defensive fallback for non-UTF-8 input — should not trigger on the happy
    // path (Rust contract assumes &str = valid UTF-8).
    var out = std.ArrayList(u8).empty;
    defer out.deinit(allocator);
    var last_was_space = true;
    for (raw) |b| {
        if (std.ascii.isAlphanumeric(b)) {
            try out.append(allocator, std.ascii.toLower(b));
            last_was_space = false;
        } else if (!last_was_space) {
            try out.append(allocator, ' ');
            last_was_space = true;
        }
    }
    const trimmed = std.mem.trim(u8, out.items, " \t\n\r\x0c\x0b");
    return allocator.dupe(u8, trimmed);
}

fn encodeCp(allocator: std.mem.Allocator, list: *std.ArrayList(u8), cp: u21) !void {
    var buf: [4]u8 = undefined;
    const n = std.unicode.utf8Encode(cp, &buf) catch return;
    try list.appendSlice(allocator, buf[0..n]);
}

fn isAlphanumericCodepoint(cp: u21) bool {
    // ASCII fast path. (Full Unicode `is_alphanumeric` would need a table; the
    // Rust impl uses char::is_alphanumeric which covers Unicode. For our input
    // distribution — English text, journal snippets — ASCII is the common case.
    // Non-ASCII letters fall back to the separator branch, matching Rust's
    // behavior for unsupported codepoints only loosely. TODO: extend for the
    // Unicode alphas we actually see in journals.)
    if (cp < 128) return std.ascii.isAlphanumeric(@intCast(cp));
    return false;
}

/// Compute char-trigrams of `token`. Empty if the token has fewer than 3
/// codepoints. Matches `token_char_trigrams` in embeddings.rs:99.
/// Returned strings are allocator-owned; caller frees via the slice + each item.
fn token_char_trigrams(
    allocator: std.mem.Allocator,
    out: *std.ArrayList([]u8),
    token: []const u8,
) !void {
    // Collect codepoints into a temporary buffer.
    var cps = std.ArrayList(u21).empty;
    defer cps.deinit(allocator);
    var view = std.unicode.Utf8View.init(token) catch return;
    var it = view.iterator();
    while (it.nextCodepoint()) |cp| try cps.append(allocator, cp);
    if (cps.items.len < 3) return;

    var i: usize = 0;
    while (i + 3 <= cps.items.len) : (i += 1) {
        var buf = std.ArrayList(u8).empty;
        errdefer buf.deinit(allocator);
        try encodeCp(allocator, &buf, cps.items[i]);
        try encodeCp(allocator, &buf, cps.items[i + 1]);
        try encodeCp(allocator, &buf, cps.items[i + 2]);
        try out.append(allocator, try buf.toOwnedSlice(allocator));
    }
}

/// The deterministic fallback embedder. Mirrors `HashEmbedding` in
/// embeddings.rs:45. Constructs a `dims`-sized f32 vector per text, accumulates
/// hashed features (token, char-trigram, bigram, meta), then L2-normalizes.
pub const HashEmbedding = struct {
    model: []const u8,
    dims: usize,

    pub fn init(model: []const u8, dims: usize) HashEmbedding {
        return .{ .model = model, .dims = if (dims == 0) 1 else dims };
    }

    pub fn provider(self: *HashEmbedding) EmbeddingProvider {
        return .{
            .ctx = self,
            .name_fn = hashName,
            .dimensions_fn = hashDimensions,
            .embed_fn = hashEmbed,
        };
    }

    fn hashName(_: *anyopaque) []const u8 {
        return "builtin-fallback";
    }

    fn hashDimensions(ctx: *anyopaque) usize {
        const self: *HashEmbedding = @ptrCast(@alignCast(ctx));
        return self.dims;
    }

    fn hashEmbed(
        ctx: *anyopaque,
        allocator: std.mem.Allocator,
        texts: []const []const u8,
        out_vecs: *std.ArrayList([]f32),
    ) EmbedError!void {
        const self: *HashEmbedding = @ptrCast(@alignCast(ctx));
        for (texts) |t| {
            const v = embed_text(allocator, self, t) catch return error.OutOfMemory;
            try out_vecs.append(allocator, v);
        }
    }

    /// Embed a single text into a fresh `dims`-length f32 vector. Allocator-owned.
    pub fn embed_text(allocator: std.mem.Allocator, self: *HashEmbedding, text: []const u8) ![]f32 {
        const vector = try allocator.alloc(f32, self.dims);
        errdefer allocator.free(vector);
        @memset(vector, 0.0);

        const normalized = try normalize_text(allocator, text);
        defer allocator.free(normalized);
        if (normalized.len == 0) return vector;

        // Tokenize on whitespace.
        var tokens = std.ArrayList([]const u8).empty;
        defer tokens.deinit(allocator);
        var tok_it = std.mem.tokenizeAny(u8, normalized, " \t\n\r\x0c\x0b");
        while (tok_it.next()) |t| try tokens.append(allocator, t);

        for (tokens.items) |token| {
            // Token length measured in codepoints, capped at 12.
            const cp_count = countCodepoints(token);
            const token_len: f32 = @floatFromInt(@min(cp_count, 12));
            const token_weight = 1.0 + (token_len / 24.0);

            const tok_feat = try std.fmt.allocPrint(allocator, "tok:{s}", .{token});
            defer allocator.free(tok_feat);
            add_hashed_feature(vector, tok_feat, token_weight);

            // Char trigrams.
            var trigrams = std.ArrayList([]u8).empty;
            defer {
                for (trigrams.items) |tri| allocator.free(tri);
                trigrams.deinit(allocator);
            }
            try token_char_trigrams(allocator, &trigrams, token);
            for (trigrams.items) |tri| {
                const tri_feat = try std.fmt.allocPrint(allocator, "tri:{s}", .{tri});
                defer allocator.free(tri_feat);
                add_hashed_feature(vector, tri_feat, 0.35);
            }
        }

        // Bigrams of adjacent tokens.
        if (tokens.items.len >= 2) {
            var i: usize = 0;
            while (i + 2 <= tokens.items.len) : (i += 1) {
                const bi_feat = try std.fmt.allocPrint(allocator, "bi:{s}_{s}", .{ tokens.items[i], tokens.items[i + 1] });
                defer allocator.free(bi_feat);
                add_hashed_feature(vector, bi_feat, 1.2);
            }
        }

        // Meta features.
        const model_feat = try std.fmt.allocPrint(allocator, "meta:model={s}", .{self.model});
        defer allocator.free(model_feat);
        add_hashed_feature(vector, model_feat, 0.1);

        const tok_meta_feat = try std.fmt.allocPrint(allocator, "meta:tokens={d}", .{tokens.items.len / 8});
        defer allocator.free(tok_meta_feat);
        add_hashed_feature(vector, tok_meta_feat, 0.15);

        // L2-normalize.
        var norm_sq: f32 = 0.0;
        for (vector) |v| norm_sq += v * v;
        const norm = @sqrt(norm_sq);
        if (norm > 0.0) {
            for (vector) |*v| v.* /= norm;
        }
        return vector;
    }
};

fn countCodepoints(s: []const u8) usize {
    var n: usize = 0;
    var view = std.unicode.Utf8View.init(s) catch return s.len;
    var it = view.iterator();
    while (it.nextCodepoint()) |_| n += 1;
    return n;
}

// ──────────────────────────────────────────────────────────────────────────
// Tests
// ──────────────────────────────────────────────────────────────────────────

test "NoopEmbedding: returns empty vectors" {
    const a = testing.allocator;
    var noop = NoopEmbedding{};
    const p = noop.provider();
    try testing.expectEqualStrings("none", p.name());
    try testing.expectEqual(@as(usize, 0), p.dimensions());
    const vecs = try p.embed(a, &.{ "anything", "here" });
    defer freeEmbeddings(a, vecs);
    try testing.expectEqual(@as(usize, 0), vecs.len);
}

test "HashEmbedding: dimensions respected" {
    const a = testing.allocator;
    var he = HashEmbedding.init("test-model", 64);
    const p = he.provider();
    try testing.expectEqualStrings("builtin-fallback", p.name());
    try testing.expectEqual(@as(usize, 64), p.dimensions());
    const vecs = try p.embed(a, &.{"hello world"});
    defer freeEmbeddings(a, vecs);
    try testing.expectEqual(@as(usize, 1), vecs.len);
    try testing.expectEqual(@as(usize, 64), vecs[0].len);
}

test "HashEmbedding: empty text returns zero vector" {
    const a = testing.allocator;
    var he = HashEmbedding.init("m", 16);
    const vecs = try he.provider().embed(a, &.{"   "});
    defer freeEmbeddings(a, vecs);
    try testing.expectEqual(@as(usize, 16), vecs[0].len);
    for (vecs[0]) |v| try testing.expectEqual(@as(f32, 0.0), v);
}

test "HashEmbedding: identical inputs produce identical outputs (deterministic)" {
    const a = testing.allocator;
    var he = HashEmbedding.init("m", 128);
    const v1 = try he.provider().embed(a, &.{"the quick brown fox"});
    defer freeEmbeddings(a, v1);
    const v2 = try he.provider().embed(a, &.{"the quick brown fox"});
    defer freeEmbeddings(a, v2);
    try testing.expectEqual(v1[0].len, v2[0].len);
    for (v1[0], v2[0]) |a_v, b_v| try testing.expectEqual(a_v, b_v);
}

test "HashEmbedding: output is L2-normalized" {
    const a = testing.allocator;
    var he = HashEmbedding.init("m", 64);
    const v = try he.provider().embed(a, &.{ "an apple a day keeps the doctor away", "rust programming language" });
    defer freeEmbeddings(a, v);
    for (v) |vec| {
        var norm_sq: f32 = 0.0;
        for (vec) |x| norm_sq += x * x;
        // Either zero vector (no features) or unit norm.
        try testing.expect(@abs(norm_sq - 1.0) < 1e-5 or norm_sq == 0.0);
    }
}

test "HashEmbedding: different texts produce different vectors" {
    const a = testing.allocator;
    var he = HashEmbedding.init("m", 128);
    const v1 = try he.provider().embed(a, &.{"rustacean thoughts"});
    defer freeEmbeddings(a, v1);
    const v2 = try he.provider().embed(a, &.{"completely unrelated celebrity gossip"});
    defer freeEmbeddings(a, v2);
    // At least one component must differ.
    var any_diff = false;
    for (v1[0], v2[0]) |x, y| {
        if (x != y) {
            any_diff = true;
            break;
        }
    }
    try testing.expect(any_diff);
}

test "HashEmbedding: dims=0 normalizes to 1" {
    const he = HashEmbedding.init("m", 0);
    try testing.expectEqual(@as(usize, 1), he.dims);
}

test "stable_hash64: FNV-1a known values" {
    // FNV-1a 64-bit: empty string → offset basis.
    try testing.expectEqual(FNV_OFFSET, stable_hash64(""));
    // "a" → standard FNV-1a test vector.
    // hash = (offset ^ 'a') * prime
    const expected_a = (FNV_OFFSET ^ 'a') *% FNV_PRIME;
    try testing.expectEqual(expected_a, stable_hash64("a"));
}

test "add_hashed_feature: deterministic bucket + sign" {
    var v = [_]f32{ 0.0, 0.0, 0.0, 0.0 };
    add_hashed_feature(&v, "feature_x", 1.0);

    // Reference: add the same feature to a fresh vector, then find its bucket.
    var before = [_]f32{ 0.0, 0.0, 0.0, 0.0 };
    add_hashed_feature(&before, "feature_x", 1.0);
    var idx: usize = 0;
    while (idx < before.len) : (idx += 1) {
        if (before[idx] != 0.0) break;
    }
    try testing.expect(v[idx] != 0.0);

    // Adding twice doubles the value at the same bucket.
    var v2 = [_]f32{ 0.0, 0.0, 0.0, 0.0 };
    add_hashed_feature(&v2, "feature_x", 1.0);
    add_hashed_feature(&v2, "feature_x", 1.0);
    try testing.expectEqual(before[idx] * 2.0, v2[idx]);
}
