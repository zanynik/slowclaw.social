//! Experimental weighted BM25 + Needle rank fusion. Not linked into the app.
//! Test with `zig test docs/experiments/needle-pulse-rank.zig` (Zig 0.16).
const std = @import("std");
pub const Interest = struct { topic: []const u8, weight: f64 };

fn tokens(a: std.mem.Allocator, text: []const u8) ![][]const u8 {
    var result: std.ArrayList([]const u8) = .empty;
    var split = std.mem.tokenizeAny(u8, text, " \n\r\t.,:;!?/\\\"'()[]{}<>-_=+|#@&");
    while (split.next()) |word| {
        if (word.len >= 2) try result.append(a, word);
    }
    return result.toOwnedSlice(a);
}
fn frequency(words: []const []const u8, query: []const u8) f64 {
    var result: f64 = 0;
    for (words) |word| {
        if (std.ascii.eqlIgnoreCase(word, query)) result += 1;
    }
    return result;
}

pub fn rank(allocator: std.mem.Allocator, interests: []const Interest, posts: []const []const u8, cosine: []const f64, out: []f64) !void {
    if (posts.len == 0 or posts.len > 120 or cosine.len != posts.len or out.len != posts.len or interests.len == 0 or interests.len > 15) return error.InvalidInput;
    for (cosine) |s| if (!std.math.isFinite(s) or s < -1.001 or s > 1.001) return error.InvalidInput;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const docs = try a.alloc([][]const u8, posts.len);
    var total: f64 = 0;
    for (posts, 0..) |text, i| {
        if (text.len > 2400) return error.InvalidInput;
        docs[i] = try tokens(a, text);
        total += @floatFromInt(docs[i].len);
    }
    const n: f64 = @floatFromInt(posts.len);
    const avg = @max(total / n, 1);
    const lexical = try a.alloc(f64, posts.len);
    @memset(lexical, 0);
    var total_weight: f64 = 0;
    for (interests) |interest| {
        if (!std.math.isFinite(interest.weight) or interest.weight < 0 or interest.weight > 1 or interest.topic.len > 200) return error.InvalidInput;
        total_weight += interest.weight;
        const query = try tokens(a, interest.topic);
        for (query, 0..) |term, term_index| {
            if (frequency(query[0..term_index], term) > 0) continue;
            var df: f64 = 0;
            for (docs) |words| {
                if (frequency(words, term) > 0) df += 1;
            }
            const idf = @log(1 + (n - df + 0.5) / (df + 0.5));
            for (docs, 0..) |words, i| {
                const tf = frequency(words, term);
                const dl: f64 = @floatFromInt(words.len);
                lexical[i] += interest.weight * idf * tf * 2.2 / (tf + 1.2 * (0.25 + 0.75 * dl / avg));
            }
        }
    }
    if (total_weight <= 0) return error.InvalidInput;
    // Weighted reciprocal-rank fusion avoids treating high Needle cosines
    // as calibrated relevance. Equal scores receive equal ranks.
    for (out, 0..) |*score, i| {
        var semantic_rank: f64 = 1;
        var lexical_rank: f64 = 1;
        for (cosine, lexical) |s, l| {
            if (s > cosine[i]) semantic_rank += 1;
            if (l > lexical[i]) lexical_rank += 1;
        }
        score.* = 0.4 / (60 + semantic_rank);
        if (lexical[i] > 0) score.* += 0.6 / (60 + lexical_rank);
    }
}

test "pulse hybrid boosts lexical evidence and rejects invalid scores" {
    const topics = [_]Interest{.{ .topic = "AI", .weight = 1 }};
    const posts = [_][]const u8{ "AI on phones", "football results", "AI agents" };
    var scores: [3]f64 = undefined;
    try rank(std.testing.allocator, &topics, &posts, &.{ 0.91, 0.95, 0.92 }, &scores);
    try std.testing.expect(scores[0] > scores[1] and scores[2] > scores[1]);
    try std.testing.expectError(error.InvalidInput, rank(std.testing.allocator, &topics, &posts, &.{ 0.9, std.math.nan(f64), 0.9 }, &scores));
}
test "pulse no lexical overlap still preserves semantic order" {
    var scores: [2]f64 = undefined;
    try rank(std.testing.allocator, &.{.{ .topic = "gardening", .weight = 1 }}, &.{ "growing vegetables", "football results" }, &.{ 0.8, 0.2 }, &scores);
    try std.testing.expect(scores[0] > scores[1]);
}
