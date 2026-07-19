//! Feed ranker — ports the pure-logic core of `src/feed/ranker.rs` (703 lines).
//!
//! This module is the heart of slice 1: it composes the vector, tokenize, and
//! feed_types modules into the ranking pipeline. Functions are ported in
//! dependency order; the Rust source remains the spec.
//!
//! Constants mirror `src/feed/ranker.rs:32-46`.

const std = @import("std");
const testing = std.testing;

const vector_math = @import("vector_math.zig");
const tokenize = @import("tokenize.zig");
const feed_types = @import("feed_types.zig");

pub const FEED_PROFILE_MAX_CHARS: usize = 2_400;
pub const FEED_EMBED_BATCH_SIZE: usize = 16;
pub const FEED_MATCH_THRESHOLD: f32 = 0.62;
pub const FEED_HIGH_CONFIDENCE_STAGE1_SCORE: f32 = 0.72;
pub const STAGE1_SOURCE_WEIGHT: f32 = 0.28;
pub const STAGE2_ITEM_WEIGHT: f32 = 0.72;
pub const STAGE1_KEYWORD_LIMIT: usize = 15;
pub const KEYWORD_PROFILE_FRESHNESS_BONUS_MAX: f32 = 0.18;
pub const KEYWORD_PROFILE_SOURCE_BONUS: f32 = 0.15;

// Negative-lens penalty (mirrors the TS `journalTopicPenalty` in readsRanking.ts):
// down-rank disliked-topic matches, never hide. A single dislike can't outweigh
// a strong positive match.
pub const NEG_MATCH_TOP: f32 = 0.7;
pub const NEG_MATCH_EACH: f32 = 0.25;
pub const NEG_MATCH_CAP: f32 = 0.9;

const InterestVector = feed_types.InterestVector;
const FeedProfile = feed_types.FeedProfile;
const FeedCandidate = feed_types.FeedCandidate;
const PersonalizedFeedItem = feed_types.PersonalizedFeedItem;

/// A candidate plus its computed score and original index, used internally
/// during ranking. Mirrors `RankedCandidate` in `src/feed/ranker.rs:54`.
pub const RankedCandidate = struct {
    dedupe_key: []const u8,
    item: PersonalizedFeedItem,
    original_index: usize,
    score: f32,
};

// ──────────────────────────────────────────────────────────────────────────
// Pure helpers — no allocator, no I/O.
// ──────────────────────────────────────────────────────────────────────────

/// Find the best-matching interest for an embedding. Returns
/// `(weighted_score, similarity, label)` — `label` is null if no interest beat
/// zero. Mirrors `best_interest_match` in `src/feed/ranker.rs:176`.
pub fn best_interest_match(
    embedding: []const f32,
    interests: []const InterestVector,
) struct { weighted: f32, similarity: f32, label: ?[]const u8 } {
    var best_weighted: f32 = 0.0;
    var best_similarity: f32 = 0.0;
    var best_label: ?[]const u8 = null;
    for (interests) |interest| {
        const similarity = vector_math.cosine_similarity(embedding, interest.embedding);
        const weighted = similarity * interest.health_score;
        if (weighted > best_weighted) {
            best_weighted = weighted;
            best_similarity = similarity;
            best_label = interest.label;
        }
    }
    return .{ .weighted = best_weighted, .similarity = best_similarity, .label = best_label };
}

/// The set of top interest terms used as a lexical gate. Mirrors
/// `top_interest_terms` in `src/feed/ranker.rs:195`. Takes the top 6 interests
/// by health_score, then collects their keywords (or tokenized label if no
/// keywords). Caller owns the returned slice and each element.
pub fn top_interest_terms(
    allocator: std.mem.Allocator,
    profile: FeedProfile,
) ![][]const u8 {
    // Copy interests so we can sort without mutating the caller's slice.
    const sorted = try allocator.alloc(InterestVector, profile.interests.len);
    defer allocator.free(sorted);
    @memcpy(sorted, profile.interests);
    std.mem.sort(InterestVector, sorted, {}, struct {
        fn lt(_: void, a: InterestVector, b: InterestVector) bool {
            return b.health_score < a.health_score; // descending
        }
    }.lt);

    var out = std.ArrayList([]const u8).empty;
    errdefer {
        for (out.items) |t| allocator.free(t);
        out.deinit(allocator);
    }
    const take = @min(sorted.len, 6);
    for (sorted[0..take]) |interest| {
        if (interest.keywords.len == 0) {
            const tokens = try tokenize.tokenize_terms(allocator, interest.label);
            defer tokenize.freeTokens(allocator, tokens);
            for (tokens) |t| {
                try out.append(allocator, try allocator.dupe(u8, t));
            }
        } else {
            for (interest.keywords) |kw| {
                try out.append(allocator, try allocator.dupe(u8, kw));
            }
        }
    }
    return out.toOwnedSlice(allocator);
}

/// Free a slice of borrowed strings produced by `top_interest_terms`.
pub fn freeTerms(allocator: std.mem.Allocator, terms: [][]const u8) void {
    for (terms) |t| allocator.free(t);
    allocator.free(terms);
}

/// Compute per-keyword weights from the interest profile. Mirrors
/// `weighted_interest_keywords` in `src/feed/ranker.rs:216`. Drops keywords
/// shorter than 3 chars or in the stopword set. Aggregates by max-health,
/// sorts by weight desc then keyword asc, truncates to STAGE1_KEYWORD_LIMIT.
pub fn weighted_interest_keywords(
    allocator: std.mem.Allocator,
    profile: FeedProfile,
) ![]KeywordWeight {
    var scores = std.StringHashMap(f32).init(allocator);
    defer scores.deinit();

    for (profile.interests) |interest| {
        const keywords = if (interest.keywords.len == 0)
            &[_][]const u8{interest.label}
        else
            interest.keywords;
        for (keywords) |keyword| {
            if (keyword.len < 3 or tokenize.is_stopword(keyword)) continue;
            const contribution = @max(interest.health_score, 0.05);
            const gop = try scores.getOrPut(keyword);
            if (!gop.found_existing) gop.value_ptr.* = 0.0;
            gop.value_ptr.* += contribution;
        }
    }

    var ranked = std.ArrayList(KeywordWeight).empty;
    defer ranked.deinit(allocator);
    var it = scores.iterator();
    while (it.next()) |entry| {
        try ranked.append(allocator, .{ .keyword = entry.key_ptr.*, .weight = entry.value_ptr.* });
    }
    std.mem.sort(KeywordWeight, ranked.items, {}, struct {
        fn lt(_: void, a: KeywordWeight, b: KeywordWeight) bool {
            if (a.weight != b.weight) return b.weight < a.weight; // weight desc
            return std.mem.order(u8, a.keyword, b.keyword) == .lt; // keyword asc
        }
    }.lt);

    const take = @min(ranked.items.len, STAGE1_KEYWORD_LIMIT);
    const out = try allocator.alloc(KeywordWeight, take);
    @memcpy(out, ranked.items[0..take]);
    return out;
}

pub const KeywordWeight = struct { keyword: []const u8, weight: f32 };

/// Like `weighted_interest_keywords` but uses a floor of 0.1 (vs 0.05) and
/// tokenizes the label if keywords are absent. Mirrors `broad_interest_keywords`
/// in `src/feed/ranker.rs:580`. Returns just the keywords (no weights), limited
/// to STAGE1_KEYWORD_LIMIT.
pub fn broad_interest_keywords(
    allocator: std.mem.Allocator,
    profile: FeedProfile,
) ![][]const u8 {
    var scores = std.StringHashMap(f32).init(allocator);
    defer {
        // Keys are borrowed from profile.interests (caller-owned) or from
        // tokenized labels (we own). Track owned keys separately.
    }
    var owned_keys = std.ArrayList([]const u8).empty;
    defer owned_keys.deinit(allocator);

    for (profile.interests) |interest| {
        var keywords_owned: ?[][]const u8 = null;
        const keywords: []const []const u8 = blk: {
            if (interest.keywords.len == 0) {
                const tokens = try tokenize.tokenize_terms(allocator, interest.label);
                keywords_owned = tokens;
                break :blk @ptrCast(tokens);
            }
            break :blk interest.keywords;
        };
        defer if (keywords_owned) |t| tokenize.freeTokens(allocator, t);

        for (keywords) |keyword| {
            if (keyword.len < 3 or tokenize.is_stopword(keyword)) continue;
            const contribution = @max(interest.health_score, 0.1);
            const gop = try scores.getOrPut(keyword);
            if (!gop.found_existing) gop.value_ptr.* = 0.0;
            gop.value_ptr.* += contribution;
        }
    }

    var ranked = std.ArrayList(KeywordWeight).empty;
    defer ranked.deinit(allocator);
    var it = scores.iterator();
    while (it.next()) |entry| {
        try ranked.append(allocator, .{ .keyword = entry.key_ptr.*, .weight = entry.value_ptr.* });
    }
    std.mem.sort(KeywordWeight, ranked.items, {}, struct {
        fn lt(_: void, a: KeywordWeight, b: KeywordWeight) bool {
            if (a.weight != b.weight) return b.weight < a.weight;
            return std.mem.order(u8, a.keyword, b.keyword) == .lt;
        }
    }.lt);

    const take = @min(ranked.items.len, STAGE1_KEYWORD_LIMIT);
    const out = try allocator.alloc([]const u8, take);
    for (ranked.items[0..take], 0..) |kw, i| out[i] = kw.keyword;
    return out;
}

/// Sum keyword weights whose keyword appears (substring or stemmed-token
/// match) in `text`. Returns the summed weight and the highest-weight keyword
/// that matched (or null). Mirrors `keyword_weight_sum` in ranker.rs:243.
pub fn keyword_weight_sum(
    allocator: std.mem.Allocator,
    text: []const u8,
    keyword_weights: []const KeywordWeight,
) !struct { sum: f32, best: ?[]const u8 } {
    if (keyword_weights.len == 0) return .{ .sum = 0.0, .best = null };

    const lower = try allocator.alloc(u8, text.len);
    defer allocator.free(lower);
    for (text, 0..) |c, i| lower[i] = std.ascii.toLower(c);

    const stemmed = try tokenize.tokenize_and_stem(allocator, lower);
    defer tokenize.freeTokens(allocator, stemmed);

    var sum: f32 = 0.0;
    var best: ?[]const u8 = null;
    var best_weight: f32 = 0.0;
    var have_best = false;
    for (keyword_weights) |kw| {
        const matched = std.mem.indexOf(u8, lower, kw.keyword) != null or
            containsStr(stemmed, kw.keyword);
        if (!matched) continue;
        sum += kw.weight;
        if (!have_best or kw.weight > best_weight) {
            best = kw.keyword;
            best_weight = kw.weight;
            have_best = true;
        }
    }
    return .{ .sum = sum, .best = best };
}

/// Score a text by how many keywords it matches (substring or stemmed token).
/// Mirrors `keyword_match_score` in ranker.rs:617. Returns 0 if no match,
/// else `(0.65 + (matched-1)*0.15).min(1.0)`.
pub fn keyword_match_score(
    allocator: std.mem.Allocator,
    text: []const u8,
    keywords: []const []const u8,
) !f32 {
    if (keywords.len == 0) return 0.0;

    const lower = try allocator.alloc(u8, text.len);
    defer allocator.free(lower);
    for (text, 0..) |c, i| lower[i] = std.ascii.toLower(c);

    const stemmed = try tokenize.tokenize_and_stem(allocator, lower);
    defer tokenize.freeTokens(allocator, stemmed);

    var matched: usize = 0;
    for (keywords) |kw| {
        if (std.mem.indexOf(u8, lower, kw) != null or containsStr(stemmed, kw)) matched += 1;
    }
    if (matched == 0) return 0.0;
    const m: f32 = @floatFromInt(matched);
    return @min(0.65 + (m - 1.0) * 0.15, 1.0);
}

/// First keyword (in input order) that matches `text`. Mirrors
/// `first_matched_keyword` in ranker.rs:636.
pub fn first_matched_keyword(
    allocator: std.mem.Allocator,
    text: []const u8,
    keywords: []const []const u8,
) !?[]const u8 {
    const lower = try allocator.alloc(u8, text.len);
    defer allocator.free(lower);
    for (text, 0..) |c, i| lower[i] = std.ascii.toLower(c);

    const stemmed = try tokenize.tokenize_and_stem(allocator, lower);
    defer tokenize.freeTokens(allocator, stemmed);

    for (keywords) |kw| {
        if (std.mem.indexOf(u8, lower, kw) != null or containsStr(stemmed, kw)) return kw;
    }
    return null;
}

/// Negative-lens penalty for disliked keywords. Returns a positive penalty
/// magnitude to subtract from a candidate's score (0 when no negatives match).
/// Matches the TS `journalTopicPenalty` policy: strongest match contributes
/// most, additional matches stack, capped — so the item sinks but stays.
/// Mirrors `negative_keyword_penalty` in `src/feed/ranker.rs:273`.
pub fn negative_keyword_penalty(
    allocator: std.mem.Allocator,
    text: []const u8,
    negatives: []const InterestVector,
) !f32 {
    if (negatives.len == 0) return 0.0;

    const lower = try allocator.alloc(u8, text.len);
    defer allocator.free(lower);
    for (text, 0..) |c, i| lower[i] = std.ascii.toLower(c);

    const stemmed = try tokenize.tokenize_and_stem(allocator, lower);
    defer tokenize.freeTokens(allocator, stemmed);

    var penalty: f32 = 0.0;
    var first = true;
    for (negatives) |interest| {
        const keyword = if (interest.keywords.len > 0) interest.keywords[0] else interest.label;
        const matched = std.mem.indexOf(u8, lower, keyword) != null or
            containsStr(stemmed, keyword);
        if (!matched) continue;
        penalty += if (first) NEG_MATCH_TOP else NEG_MATCH_EACH;
        first = false;
        if (penalty >= NEG_MATCH_CAP) return NEG_MATCH_CAP;
    }
    return penalty;
}

/// Lexical gate. The Rust implementation is currently a no-op stub that
/// returns `true` (see ranker.rs:318). We preserve that behavior.
pub fn passes_lexical_gate(_: []const u8, _: []const []const u8, _: f32) bool {
    return true;
}

fn containsStr(tokens: [][]const u8, needle: []const u8) bool {
    for (tokens) |t| {
        if (std.mem.eql(u8, t, needle)) return true;
    }
    return false;
}

// ──────────────────────────────────────────────────────────────────────────
// Tests — pure helpers.
// The negative_keyword_penalty tests are verbatim ports of the 3 Rust tests at
// src/feed/ranker.rs:664-702.
// ──────────────────────────────────────────────────────────────────────────

fn neg(label: []const u8) InterestVector {
    return .{
        .id = "",
        .label = label,
        .embedding = &.{},
        .health_score = 1.0,
        .source_path = "",
        .keywords = &.{label},
    };
}

test "negative_keyword_penalty: zero when no negatives or no match" {
    const a = testing.allocator;
    try testing.expectEqual(@as(f32, 0.0), try negative_keyword_penalty(a, "a post about rust", &.{}));
    try testing.expectEqual(
        @as(f32, 0.0),
        try negative_keyword_penalty(a, "a post about rust", &.{ neg("celebrity gossip"), neg("sports") }),
    );
}

test "negative_keyword_penalty: stacked and capped" {
    const a = testing.allocator;
    // Single match → top penalty (0.7).
    const p1 = try negative_keyword_penalty(a, "celebrity gossip drama", &.{neg("celebrity gossip")});
    try testing.expect(@abs(p1 - 0.7) < 1e-6);

    // Two matches → top + each (0.7 + 0.25 = 0.95) → capped at 0.9.
    const p2 = try negative_keyword_penalty(
        a,
        "celebrity gossip and sports news",
        &.{ neg("celebrity gossip"), neg("sports") },
    );
    try testing.expect(@abs(p2 - 0.9) < 1e-6);

    // Three matches still capped at 0.9 (down-rank, never hide).
    const p3 = try negative_keyword_penalty(
        a,
        "celebrity gossip, sports, and reality tv",
        &.{ neg("celebrity gossip"), neg("sports"), neg("reality tv") },
    );
    try testing.expect(@abs(p3 - 0.9) < 1e-6);
}

test "negative_keyword_penalty: case-insensitive substring" {
    const a = testing.allocator;
    // Uppercase in the candidate text still matches the lowercase keyword.
    const p = try negative_keyword_penalty(a, "CELEBRITY GOSSIP overload", &.{neg("celebrity gossip")});
    try testing.expect(@abs(p - 0.7) < 1e-6);
}

test "best_interest_match: picks the highest weighted similarity" {
    const emb_a = [_]f32{ 1.0, 0.0 };
    const emb_b = [_]f32{ 0.0, 1.0 };
    const interests = [_]InterestVector{
        .{ .id = "i1", .label = "a", .embedding = &emb_a, .health_score = 0.5, .source_path = "", .keywords = &.{} },
        .{ .id = "i2", .label = "b", .embedding = &emb_b, .health_score = 1.0, .source_path = "", .keywords = &.{} },
    };
    // Query embedding matches b exactly: similarity 1.0, weighted = 1.0.
    const result = best_interest_match(&emb_b, &interests);
    try testing.expect(@abs(result.weighted - 1.0) < 1e-6);
    try testing.expect(@abs(result.similarity - 1.0) < 1e-6);
    try testing.expectEqualStrings("b", result.label.?);
}

test "best_interest_match: returns null label when nothing beats zero" {
    const emb = [_]f32{ 1.0, 0.0 };
    const interests = [_]InterestVector{
        .{ .id = "i1", .label = "x", .embedding = &[_]f32{0.0, 1.0}, .health_score = 1.0, .source_path = "", .keywords = &.{} },
    };
    // Orthogonal embeddings → cosine 0 → weighted 0 → no improvement over the
    // initial best_weighted of 0.0 (strictly-greater guard).
    const result = best_interest_match(&emb, &interests);
    try testing.expectEqual(@as(f32, 0.0), result.weighted);
    try testing.expect(result.label == null);
}

test "weighted_interest_keywords: aggregates and ranks" {
    const a = testing.allocator;
    const interests = [_]InterestVector{
        .{ .id = "i1", .label = "rust lang", .embedding = &.{}, .health_score = 0.9, .source_path = "", .keywords = &.{ "rust", "language" } },
        .{ .id = "i2", .label = "more rust", .embedding = &.{}, .health_score = 0.5, .source_path = "", .keywords = &.{"rust"} },
    };
    const profile = FeedProfile{ .interests = &interests };
    const weights = try weighted_interest_keywords(a, profile);
    defer a.free(weights);
    // "rust" aggregates 0.9 + 0.5 = 1.4; "language" = 0.9. Sorted desc.
    try testing.expectEqual(@as(usize, 2), weights.len);
    try testing.expectEqualStrings("rust", weights[0].keyword);
    try testing.expect(@abs(weights[0].weight - 1.4) < 1e-6);
    try testing.expectEqualStrings("language", weights[1].keyword);
}

test "keyword_match_score: 0.65 base, +0.15 per extra match, capped at 1.0" {
    const a = testing.allocator;
    const kws = [_][]const u8{ "rust", "language", "memory" };
    try testing.expectEqual(@as(f32, 0.0), try keyword_match_score(a, "nothing relevant here", &kws));
    try testing.expect(@abs((try keyword_match_score(a, "i love rust", &kws)) - 0.65) < 1e-6);
    try testing.expect(@abs((try keyword_match_score(a, "rust language stuff", &kws)) - 0.80) < 1e-6);
}

test "keyword_match_score: empty keywords returns 0" {
    const a = testing.allocator;
    try testing.expectEqual(@as(f32, 0.0), try keyword_match_score(a, "anything", &.{}));
}
