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
const embeddings = @import("embeddings.zig");

/// Canonical embedder interface for the ranker. Aliases
/// `embeddings.EmbeddingProvider` so the whole package has ONE embedder
/// contract (no parallel "Embedder" type). Mirrors the Rust ranker's use of
/// `Arc<dyn EmbeddingProvider>` from `src/memory/embeddings.rs`.
pub const Embedder = embeddings.EmbeddingProvider;

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
// Timestamp freshness — needs a minimal RFC3339 parser.
// ──────────────────────────────────────────────────────────────────────────

/// Parse a 2-digit ASCII decimal number at `s[offset..offset+2]`. Returns null
/// on malformed input.
fn parse2(s: []const u8, offset: usize) ?u32 {
    if (offset + 2 > s.len) return null;
    const a = std.ascii.toLower(s[offset]);
    const b = std.ascii.toLower(s[offset + 1]);
    if (!std.ascii.isDigit(a) or !std.ascii.isDigit(b)) return null;
    return (@as(u32, a - '0') * 10) + @as(u32, b - '0');
}

/// Parse a 4-digit ASCII decimal number at `s[offset..offset+4]`.
fn parse4(s: []const u8, offset: usize) ?u32 {
    if (offset + 4 > s.len) return null;
    var n: u32 = 0;
    var i: usize = offset;
    while (i < offset + 4) : (i += 1) {
        if (!std.ascii.isDigit(s[i])) return null;
        n = n * 10 + @as(u32, s[i] - '0');
    }
    return n;
}

/// Days in a given (Gregorian) month. February accounts for leap years.
fn daysInMonth(year: u32, month: u32) u32 {
    return switch (month) {
        1, 3, 5, 7, 8, 10, 12 => 31,
        4, 6, 9, 11 => 30,
        2 => if (isLeapYear(year)) 29 else 28,
        else => 0,
    };
}

fn isLeapYear(year: u32) bool {
    return (year % 4 == 0 and year % 100 != 0) or (year % 400 == 0);
}

/// Convert a (UTC) civil date to Unix epoch seconds. Uses the well-known
/// days-from-civil algorithm (Howard Hinnant). Handles years 1970–9999.
fn civilToEpochSeconds(year: u32, month: u32, day: u32, hour: u32, minute: u32, second: u32) i64 {
    const month_adj: i64 = if (month <= 2) 1 else 0;
    const y: i64 = @as(i64, year) - month_adj;
    const era: i64 = @divFloor(if (y >= 0) y else y - 399, 400);
    const yoe: u64 = @intCast(y - era * 400); // [0, 399]
    const m: u64 = month;
    const d: u64 = day;
    const doy: u64 = @divFloor(153 * (if (m > 2) m - 3 else m + 9) + 2, 5) + d - 1; // [0, 365]
    const doe: u64 = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy; // [0, 146096]
    const days_since_epoch: i64 = @as(i64, era * 146097 + @as(i64, @intCast(doe)) - 719468);
    return days_since_epoch * 86400 +
        @as(i64, hour) * 3600 + @as(i64, minute) * 60 + @as(i64, second);
}

/// Parse an RFC3339 timestamp into Unix epoch seconds (UTC). Accepts the
/// formats produced by Bluesky/Nostr/ISO-8601 sources:
///   `2026-07-19T20:47:00Z`, `2026-07-19T20:47:00+00:00`,
///   `2026-07-19T20:47:00.123Z`, `2026-07-19T20:47:00.123456789+05:30`.
/// Returns null on malformed input (mirrors chrono's parse_from_rfc3339
/// returning an Err, which the ranker treats as "no freshness bonus").
pub fn parse_rfc3339(s: []const u8) ?i64 {
    // Layout: YYYY-MM-DDTHH:MM:SS[.fraction][Z|±HH:MM]
    if (s.len < 20) return null;
    if (s[4] != '-' or s[7] != '-' or (s[10] != 'T' and s[10] != 't' and s[10] != ' ')) return null;
    if (s[13] != ':' or s[16] != ':') return null;

    const year = parse4(s, 0) orelse return null;
    const month = parse2(s, 5) orelse return null;
    const day = parse2(s, 8) orelse return null;
    const hour = parse2(s, 11) orelse return null;
    const minute = parse2(s, 14) orelse return null;
    const second = parse2(s, 17) orelse return null;

    if (month < 1 or month > 12 or day < 1 or day > daysInMonth(year, month)) return null;
    if (hour > 23 or minute > 59 or second > 60) return null; // 60 for leap seconds

    var i: usize = 19;
    // Optional fractional seconds.
    if (i < s.len and s[i] == '.') {
        i += 1;
        var saw_digit = false;
        while (i < s.len and std.ascii.isDigit(s[i])) : (i += 1) saw_digit = true;
        if (!saw_digit) return null;
    }

    if (i >= s.len) return null;
    var offset_secs: i64 = 0;
    switch (s[i]) {
        'Z', 'z' => i += 1,
        '+', '-' => {
            const sign: i64 = if (s[i] == '-') -1 else 1;
            if (i + 6 > s.len) return null;
            if (s[i + 3] != ':') return null;
            const oh = parse2(s, i + 1) orelse return null;
            const om = parse2(s, i + 4) orelse return null;
            if (oh > 23 or om > 59) return null;
            offset_secs = sign * (@as(i64, oh) * 3600 + @as(i64, om) * 60);
            i += 6;
        },
        else => return null,
    }
    // Trailing garbage fails the parse (chrono is strict about a complete match).
    if (i != s.len) return null;

    const local_secs = civilToEpochSeconds(year, month, day, hour, minute, second);
    return local_secs - offset_secs;
}

/// Sort timestamp extracted from a ranked item. Prefers
/// `web_preview.discovered_at`; falls back to the `feed_item` JSON's
/// `post.indexedAt` then `publishedAt`; else empty string. Mirrors
/// `item_sort_timestamp` in ranker.rs:359.
pub fn item_sort_timestamp(item: PersonalizedFeedItem) []const u8 {
    if (item.web_preview) |wp| {
        if (wp.discovered_at.len > 0) return wp.discovered_at;
    }
    // The Zig PersonalizedFeedItem stores feed_item as an opaque JSON blob.
    // A full JSON lookup would require parsing; for the pilot we expose the
    // discovered_at path (the only one used in the test fixtures) and treat
    // the JSON path as a TODO until the JSON shape is needed by callers.
    // TODO(slice-7): parse feed_item_json for post.indexedAt / publishedAt.
    return "";
}

/// Freshness bonus for a ranked item based on its age. Mirrors
/// `candidate_freshness_bonus` in ranker.rs:301. Returns 0 if the timestamp
/// is missing or unparseable, else a tiered bonus:
///   ≤24h → KEYWORD_PROFILE_FRESHNESS_BONUS_MAX
///   ≤72h → max × 0.5
///   ≤168h → max × 0.2
///   else → 0
pub fn candidate_freshness_bonus(item: PersonalizedFeedItem, now_epoch: i64) f32 {
    const ts = item_sort_timestamp(item);
    if (ts.len == 0) return 0.0;
    const parsed_epoch = parse_rfc3339(ts) orelse return 0.0;
    const age_secs = now_epoch - parsed_epoch;
    if (age_secs < 0) return KEYWORD_PROFILE_FRESHNESS_BONUS_MAX;
    const age_hours = @as(f32, @floatFromInt(age_secs)) / 3600.0;
    if (age_hours <= 24.0) return KEYWORD_PROFILE_FRESHNESS_BONUS_MAX;
    if (age_hours <= 72.0) return KEYWORD_PROFILE_FRESHNESS_BONUS_MAX * 0.5;
    if (age_hours <= 168.0) return KEYWORD_PROFILE_FRESHNESS_BONUS_MAX * 0.2;
    return 0.0;
}

// ──────────────────────────────────────────────────────────────────────────
// Ranking comparators + interleave.
// ──────────────────────────────────────────────────────────────────────────

/// Three-key comparison for sorting ranked candidates: score desc, then
/// timestamp desc (lexicographic on the raw string — matches Rust's `&str`
/// comparison), then original_index asc. Mirrors `rank_candidate_cmp` in
/// ranker.rs:332.
pub fn rank_candidate_cmp(left: RankedCandidate, right: RankedCandidate) std.math.Order {
    const neg_inf: f32 = -std.math.inf(f32);
    const l = if (std.math.isNan(left.score)) neg_inf else left.score;
    const r = if (std.math.isNan(right.score)) neg_inf else right.score;
    if (l != r) {
        // Descending by score: left ranks first (Less) when its score is higher.
        return if (l > r) .lt else .gt;
    }
    // Tie on score → descending by timestamp string (lexicographic).
    const lt_ts = item_sort_timestamp(left.item);
    const rt_ts = item_sort_timestamp(right.item);
    const ts_order = std.mem.order(u8, rt_ts, lt_ts);
    if (ts_order != .eq) return ts_order;
    // Final tiebreak → ascending original_index.
    if (left.original_index < right.original_index) return .lt;
    if (left.original_index > right.original_index) return .gt;
    return .eq;
}

/// Lowercased "source mix" key for interleaving. Prefers the feed_source
/// label when non-empty, else falls back to source_type. Mirrors
/// `candidate_source_mix_key` in ranker.rs:347.
pub fn candidate_source_mix_key(allocator: std.mem.Allocator, item: PersonalizedFeedItem) ![]u8 {
    if (item.feed_source) |src| {
        const trimmed = std.mem.trim(u8, src.label, " \t\n\r");
        if (trimmed.len > 0) {
            return asciiLowerOwned(allocator, trimmed);
        }
    }
    const trimmed = std.mem.trim(u8, item.source_type, " \t\n\r");
    return asciiLowerOwned(allocator, trimmed);
}

fn asciiLowerOwned(allocator: std.mem.Allocator, s: []const u8) ![]u8 {
    const out = try allocator.alloc(u8, s.len);
    for (s, 0..) |c, i| out[i] = std.ascii.toLower(c);
    return out;
}

/// Round-robin interleave ranked candidates by source-key bucket so no single
/// source dominates the top of the feed. Mirrors
/// `interleave_ranked_candidates_by_source` in ranker.rs:380.
///
/// Takes the already-sorted ranked candidates and `limit`; returns a fresh
/// slice (allocator-owned) of interleaved candidates. Caller owns the slice
/// (the items inside are copied by value and their inner slices alias the
/// originals — do not free those).
pub fn interleave_ranked_candidates_by_source(
    allocator: std.mem.Allocator,
    ranked: []RankedCandidate,
    limit: usize,
) ![]RankedCandidate {
    if (ranked.len <= 2) {
        const take = @min(ranked.len, limit);
        const out = try allocator.alloc(RankedCandidate, take);
        @memcpy(out, ranked[0..take]);
        return out;
    }

    // Bucket by source key, preserving first-seen order of buckets.
    var bucket_keys = std.ArrayList([]u8).empty;
    defer {
        for (bucket_keys.items) |k| allocator.free(k);
        bucket_keys.deinit(allocator);
    }
    var buckets = std.ArrayList(std.ArrayList(RankedCandidate)).empty;
    defer {
        for (buckets.items) |*b| b.deinit(allocator);
        buckets.deinit(allocator);
    }

    for (ranked) |c| {
        const key = try candidate_source_mix_key(allocator, c.item);
        var found: ?usize = null;
        for (bucket_keys.items, 0..) |k, idx| {
            if (std.mem.eql(u8, k, key)) {
                found = idx;
                break;
            }
        }
        allocator.free(key);
        if (found) |idx| {
            try buckets.items[idx].append(allocator, c);
        } else {
            const owned_key = try candidate_source_mix_key(allocator, c.item);
            try bucket_keys.append(allocator, owned_key);
            var new_bucket = std.ArrayList(RankedCandidate).empty;
            try new_bucket.append(allocator, c);
            try buckets.append(allocator, new_bucket);
        }
    }

    if (buckets.items.len <= 1) {
        const take = @min(ranked.len, limit);
        const out = try allocator.alloc(RankedCandidate, take);
        @memcpy(out, ranked[0..take]);
        return out;
    }

    var out = std.ArrayList(RankedCandidate).empty;
    errdefer out.deinit(allocator);
    while (true) {
        var advanced = false;
        for (buckets.items) |*b| {
            if (b.items.len == 0) continue;
            try out.append(allocator, b.orderedRemove(0));
            advanced = true;
            if (out.items.len >= limit) return out.toOwnedSlice(allocator);
        }
        if (!advanced) break;
    }
    return out.toOwnedSlice(allocator);
}

// ──────────────────────────────────────────────────────────────────────────
// rank_candidates_stage2 — keyword-path orchestrator (no embedder).
// Mirrors `rank_candidates_stage2` in ranker.rs:123.
// ──────────────────────────────────────────────────────────────────────────

/// Rank candidates using the keyword path (stage 2). Pure orchestrator over
/// the helpers above; takes a `now_epoch` for deterministic freshness scoring.
/// The returned slice and each item's mutable fields (score, matched_*,
/// passed_threshold) are allocator-owned COPIES of the inputs — the caller's
/// candidates are not mutated.
pub fn rank_candidates_stage2(
    allocator: std.mem.Allocator,
    profile: FeedProfile,
    candidates: []const FeedCandidate,
    limit: usize,
    now_epoch: i64,
) ![]PersonalizedFeedItem {
    const keyword_weights = try weighted_interest_keywords(allocator, profile);
    defer allocator.free(keyword_weights);

    var ranked = std.ArrayList(RankedCandidate).empty;
    defer ranked.deinit(allocator);

    for (candidates) |candidate| {
        const kws = try keyword_weight_sum(allocator, candidate.rank_text, keyword_weights);
        const freshness_bonus = candidate_freshness_bonus(candidate.item, now_epoch);
        const penalty = try negative_keyword_penalty(allocator, candidate.rank_text, profile.negative_interests);
        const final_score = kws.sum +
            freshness_bonus +
            (candidate.stage1_score * KEYWORD_PROFILE_SOURCE_BONUS) -
            penalty;

        var item = candidate.item;
        item.score = final_score;
        item.matched_interest_label = kws.best;
        item.matched_interest_score = if (kws.sum > 0.0) kws.sum else null;
        item.passed_threshold = final_score > 0.0;
        try ranked.append(allocator, .{
            .dedupe_key = candidate.dedupe_key,
            .item = item,
            .original_index = candidate.original_index,
            .score = final_score,
        });
    }

    // Dedupe by dedupe_key, keeping the better-ranked candidate per key.
    var deduped = std.StringHashMap(RankedCandidate).init(allocator);
    defer deduped.deinit();
    for (ranked.items) |c| {
        const gop = try deduped.getOrPut(c.dedupe_key);
        if (gop.found_existing) {
            // Keep the new candidate only if it strictly outranks the existing.
            if (rank_candidate_cmp(c, gop.value_ptr.*) == .lt) continue;
        }
        gop.value_ptr.* = c;
    }

    var deduped_list = std.ArrayList(RankedCandidate).empty;
    defer deduped_list.deinit(allocator);
    var it = deduped.valueIterator();
    while (it.next()) |v| try deduped_list.append(allocator, v.*);
    std.mem.sort(RankedCandidate, deduped_list.items, {}, struct {
        fn lt(_: void, a: RankedCandidate, b: RankedCandidate) bool {
            return rank_candidate_cmp(a, b) == .lt;
        }
    }.lt);

    const interleaved = try interleave_ranked_candidates_by_source(allocator, deduped_list.items, limit);
    defer allocator.free(interleaved);

    const out = try allocator.alloc(PersonalizedFeedItem, interleaved.len);
    for (interleaved, 0..) |c, i| out[i] = c.item;
    return out;
}

// ──────────────────────────────────────────────────────────────────────────
// rank_candidates — embedder-driven path. Mirrors the async
// `FeedRanker::rank_candidates` in ranker.rs:40, but synchronous with an
// injected `EmbeddingProvider` (idiomatic Zig dependency injection, replacing
// tokio + Arc<dyn EmbeddingProvider>).
// ──────────────────────────────────────────────────────────────────────────

/// Rank candidates via the embedding path (stage 1 weighted + stage 2). Mirrors
/// `FeedRanker::rank_candidates` in ranker.rs:40. Synchronous — the embedder is
/// injected via the canonical `EmbeddingProvider` interface.
///
/// Returns the ranked items (allocator-owned slice; inner slices alias inputs).
pub fn rank_candidates(
    allocator: std.mem.Allocator,
    embedder: Embedder,
    profile: FeedProfile,
    candidates: []const FeedCandidate,
    limit: usize,
) ![]PersonalizedFeedItem {
    if (profile.interests.len == 0 or candidates.len == 0) return &.{};

    const lexical_terms = try top_interest_terms(allocator, profile);
    defer freeTerms(allocator, lexical_terms);

    // Pass lexical gate + truncate rank_text to FEED_PROFILE_MAX_CHARS.
    var texts = std.ArrayList([]const u8).empty;
    defer texts.deinit(allocator);
    var kept_candidates = std.ArrayList(FeedCandidate).empty;
    defer kept_candidates.deinit(allocator);

    for (candidates) |candidate| {
        const trimmed = std.mem.trim(u8, candidate.rank_text, " \t\n\r");
        if (trimmed.len == 0) continue;
        if (!passes_lexical_gate(trimmed, lexical_terms, candidate.stage1_score)) continue;
        // Truncate to FEED_PROFILE_MAX_CHARS for the embedder call (best-effort;
        // embedders typically have their own token budgets).
        const text_slice = if (trimmed.len > FEED_PROFILE_MAX_CHARS) trimmed[0..FEED_PROFILE_MAX_CHARS] else trimmed;
        try texts.append(allocator, text_slice);
        try kept_candidates.append(allocator, candidate);
    }
    if (kept_candidates.items.len == 0) return &.{};

    const embedded = try embedder.embed(allocator, texts.items);
    defer embeddings.freeEmbeddings(allocator, embedded);

    // Defensive: a misbehaving embedder (e.g. NoopEmbedding returning zero
    // vectors for non-empty input) would otherwise cause an out-of-bounds
    // access below. Surface it as a clear error instead of crashing.
    if (embedded.len != texts.items.len) return error.EmbedderCountMismatch;

    var ranked = std.ArrayList(RankedCandidate).empty;
    defer ranked.deinit(allocator);
    var has_strong_match = false;

    for (kept_candidates.items, 0..) |candidate, i| {
        const embedding = embedded[i];
        const m = best_interest_match(embedding, profile.interests);
        const penalty = try negative_keyword_penalty(allocator, candidate.rank_text, profile.negative_interests);
        const final_score = STAGE1_SOURCE_WEIGHT * candidate.stage1_score +
            STAGE2_ITEM_WEIGHT * m.weighted -
            penalty;
        var item = candidate.item;
        item.score = final_score;
        item.matched_interest_label = m.label;
        item.matched_interest_score = if (m.similarity > 0.0) m.similarity else null;
        item.passed_threshold = final_score >= FEED_MATCH_THRESHOLD;
        if (item.passed_threshold) has_strong_match = true;
        try ranked.append(allocator, .{
            .dedupe_key = candidate.dedupe_key,
            .item = item,
            .original_index = candidate.original_index,
            .score = final_score,
        });
    }

    // Dedupe by dedupe_key, keeping the better-ranked candidate per key.
    var deduped = std.StringHashMap(RankedCandidate).init(allocator);
    defer deduped.deinit();
    for (ranked.items) |c| {
        const gop = try deduped.getOrPut(c.dedupe_key);
        if (gop.found_existing) {
            if (rank_candidate_cmp(c, gop.value_ptr.*) == .lt) continue;
        }
        gop.value_ptr.* = c;
    }
    var deduped_list = std.ArrayList(RankedCandidate).empty;
    defer deduped_list.deinit(allocator);
    var it = deduped.valueIterator();
    while (it.next()) |v| try deduped_list.append(allocator, v.*);
    std.mem.sort(RankedCandidate, deduped_list.items, {}, struct {
        fn lt(_: void, a: RankedCandidate, b: RankedCandidate) bool {
            return rank_candidate_cmp(a, b) == .lt;
        }
    }.lt);

    // If any candidate passed threshold, retain only passing candidates.
    if (has_strong_match) {
        var retained = std.ArrayList(RankedCandidate).empty;
        defer retained.deinit(allocator);
        for (deduped_list.items) |c| {
            if (c.item.passed_threshold) try retained.append(allocator, c);
        }
        const interleaved = try interleave_ranked_candidates_by_source(allocator, retained.items, limit);
        defer allocator.free(interleaved);
        const out = try allocator.alloc(PersonalizedFeedItem, interleaved.len);
        for (interleaved, 0..) |c, i| out[i] = c.item;
        return out;
    } else {
        const interleaved = try interleave_ranked_candidates_by_source(allocator, deduped_list.items, limit);
        defer allocator.free(interleaved);
        const out = try allocator.alloc(PersonalizedFeedItem, interleaved.len);
        for (interleaved, 0..) |c, i| out[i] = c.item;
        return out;
    }
}

// ──────────────────────────────────────────────────────────────────────────
// Tests — pure helpers.
// The negative_keyword_penalty tests are verbatim ports of the 3 Rust tests at
// src/feed/ranker.rs:664-702.
// ──────────────────────────────────────────────────────────────────────────

/// Test helper: build a negative InterestVector whose single keyword is the
/// label. The `keyword_array` comptime parameter materializes a stable static
/// array (the label is always a string literal in tests), avoiding the
/// dangling-pointer issue of `&.{label}` when `label` is a runtime slice.
fn neg(comptime label: []const u8) InterestVector {
    const keyword_array = [_][]const u8{label};
    return .{
        .id = "",
        .label = label,
        .embedding = &.{},
        .health_score = 1.0,
        .source_path = "",
        .keywords = &keyword_array,
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

// ── RFC3339 parser tests ──────────────────────────────────────────────────

test "parse_rfc3339: Zulu timestamp" {
    // 2026-07-19T20:47:00Z → known epoch value.
    const ts = parse_rfc3339("2026-07-19T20:47:00Z");
    try testing.expect(ts != null);
    // Sanity: same instant via +00:00 offset must match.
    const ts2 = parse_rfc3339("2026-07-19T20:47:00+00:00");
    try testing.expectEqual(ts.?, ts2.?);
}

test "parse_rfc3339: offset shifts the epoch" {
    // 12:00 UTC vs 12:00+02:00 (== 10:00 UTC) — differ by 2 hours.
    const a = parse_rfc3339("2026-07-19T12:00:00Z").?;
    const b = parse_rfc3339("2026-07-19T12:00:00+02:00").?;
    try testing.expectEqual(@as(i64, 2 * 3600), a - b);
}

test "parse_rfc3339: fractional seconds accepted" {
    const a = parse_rfc3339("2026-07-19T12:00:00.123Z");
    const b = parse_rfc3339("2026-07-19T12:00:00.123456789Z");
    try testing.expect(a != null);
    try testing.expect(b != null);
    // Fractional part is ignored (we truncate to whole seconds, like chrono's
    // second-level comparison the ranker uses).
    try testing.expectEqual(a.?, b.?);
}

test "parse_rfc3339: lowercase t and space separators accepted" {
    const a = parse_rfc3339("2026-07-19T20:47:00Z");
    const t_lower = parse_rfc3339("2026-07-19t20:47:00Z");
    const space = parse_rfc3339("2026-07-19 20:47:00Z");
    try testing.expect(t_lower != null);
    try testing.expect(space != null);
    try testing.expectEqual(a.?, t_lower.?);
    try testing.expectEqual(a.?, space.?);
}

test "parse_rfc3339: malformed returns null" {
    try testing.expect(parse_rfc3339("") == null);
    try testing.expect(parse_rfc3339("not-a-date") == null);
    try testing.expect(parse_rfc3339("2026-13-01T00:00:00Z") == null); // bad month
    try testing.expect(parse_rfc3339("2026-02-30T00:00:00Z") == null); // bad day
    try testing.expect(parse_rfc3339("2026-07-19T25:00:00Z") == null); // bad hour
    try testing.expect(parse_rfc3339("2026-07-19T20:47:00") == null); // no Z/offset
    try testing.expect(parse_rfc3339("2026-07-19T20:47:00Zextra") == null); // trailing
}

test "parse_rfc3339: leap year Feb 29 valid in 2024" {
    try testing.expect(parse_rfc3339("2024-02-29T00:00:00Z") != null);
    try testing.expect(parse_rfc3339("2023-02-29T00:00:00Z") == null);
}

// ── Freshness tests ───────────────────────────────────────────────────────

test "candidate_freshness_bonus: tiered by age" {
    // Anchor "now" = 2026-07-19T20:47:00Z.
    const now = parse_rfc3339("2026-07-19T20:47:00Z").?;
    const max = KEYWORD_PROFILE_FRESHNESS_BONUS_MAX;

    const recent = PersonalizedFeedItem{
        .source_type = "web",
        .feed_item_json = "{}",
        .web_preview = .{
            .url = "u",
            .title = "t",
            .description = "",
            .content_text = "",
            .domain = "d",
            .provider = "p",
            .discovered_at = "2026-07-19T10:47:00Z", // 10h ago
        },
    };
    try testing.expect(@abs(candidate_freshness_bonus(recent, now) - max) < 1e-6);

    const day_old = PersonalizedFeedItem{
        .source_type = "web",
        .feed_item_json = "{}",
        .web_preview = .{
            .url = "u",
            .title = "t",
            .description = "",
            .content_text = "",
            .domain = "d",
            .provider = "p",
            .discovered_at = "2026-07-17T10:47:00Z", // ~58h ago
        },
    };
    try testing.expect(@abs(candidate_freshness_bonus(day_old, now) - max * 0.5) < 1e-6);

    const week_old = PersonalizedFeedItem{
        .source_type = "web",
        .feed_item_json = "{}",
        .web_preview = .{
            .url = "u",
            .title = "t",
            .description = "",
            .content_text = "",
            .domain = "d",
            .provider = "p",
            .discovered_at = "2026-07-15T10:47:00Z", // ~106h ago
        },
    };
    try testing.expect(@abs(candidate_freshness_bonus(week_old, now) - max * 0.2) < 1e-6);

    const ancient = PersonalizedFeedItem{
        .source_type = "web",
        .feed_item_json = "{}",
        .web_preview = .{
            .url = "u",
            .title = "t",
            .description = "",
            .content_text = "",
            .domain = "d",
            .provider = "p",
            .discovered_at = "2020-01-01T00:00:00Z",
        },
    };
    try testing.expectEqual(@as(f32, 0.0), candidate_freshness_bonus(ancient, now));
}

test "candidate_freshness_bonus: no timestamp returns 0" {
    const item = PersonalizedFeedItem{
        .source_type = "web",
        .feed_item_json = "{}",
    };
    try testing.expectEqual(@as(f32, 0.0), candidate_freshness_bonus(item, 1_000_000));
}

test "candidate_freshness_bonus: malformed timestamp returns 0" {
    const item = PersonalizedFeedItem{
        .source_type = "web",
        .feed_item_json = "{}",
        .web_preview = .{
            .url = "u",
            .title = "t",
            .description = "",
            .content_text = "",
            .domain = "d",
            .provider = "p",
            .discovered_at = "not-a-date",
        },
    };
    try testing.expectEqual(@as(f32, 0.0), candidate_freshness_bonus(item, 1_000_000));
}

// ── Comparator + interleave tests ──────────────────────────────────────────

fn makeRanked(score: f32, ts: []const u8, idx: usize) RankedCandidate {
    return .{
        .dedupe_key = "",
        .item = .{
            .source_type = "web",
            .feed_item_json = "{}",
            .web_preview = if (ts.len > 0) .{
                .url = "u",
                .title = "t",
                .description = "",
                .content_text = "",
                .domain = "d",
                .provider = "p",
                .discovered_at = ts,
            } else null,
        },
        .original_index = idx,
        .score = score,
    };
}

test "rank_candidate_cmp: score desc primary" {
    const a = makeRanked(0.9, "", 1);
    const b = makeRanked(0.5, "", 2);
    try testing.expectEqual(std.math.Order.lt, rank_candidate_cmp(a, b)); // a ranks higher
    try testing.expectEqual(std.math.Order.gt, rank_candidate_cmp(b, a));
}

test "rank_candidate_cmp: timestamp breaks ties, descending" {
    const a = makeRanked(0.5, "2026-07-19T10:00:00Z", 1);
    const b = makeRanked(0.5, "2026-07-18T10:00:00Z", 2);
    try testing.expectEqual(std.math.Order.lt, rank_candidate_cmp(a, b)); // newer ranks higher
}

test "rank_candidate_cmp: original_index breaks further ties, ascending" {
    const a = makeRanked(0.5, "", 1);
    const b = makeRanked(0.5, "", 2);
    try testing.expectEqual(std.math.Order.lt, rank_candidate_cmp(a, b));
}

test "interleave: single bucket returns in order" {
    const a = testing.allocator;
    var items = [_]RankedCandidate{
        makeRanked(0.9, "", 0),
        makeRanked(0.8, "", 1),
    };
    // Both items share source_type "web" and no feed_source label → same bucket.
    const out = try interleave_ranked_candidates_by_source(a, &items, 10);
    defer a.free(out);
    try testing.expectEqual(@as(usize, 2), out.len);
}

test "interleave: two buckets round-robin" {
    const a = testing.allocator;
    var items = [_]RankedCandidate{
        .{ .dedupe_key = "", .item = .{ .source_type = "bluesky", .feed_item_json = "{}" }, .original_index = 0, .score = 0.9 },
        .{ .dedupe_key = "", .item = .{ .source_type = "bluesky", .feed_item_json = "{}" }, .original_index = 1, .score = 0.8 },
        .{ .dedupe_key = "", .item = .{ .source_type = "web", .feed_item_json = "{}" }, .original_index = 2, .score = 0.7 },
    };
    const out = try interleave_ranked_candidates_by_source(a, &items, 10);
    defer a.free(out);
    try testing.expectEqual(@as(usize, 3), out.len);
    // Round-robin: bluesky, web, bluesky.
    try testing.expectEqualStrings("bluesky", out[0].item.source_type);
    try testing.expectEqualStrings("web", out[1].item.source_type);
    try testing.expectEqualStrings("bluesky", out[2].item.source_type);
}

test "interleave: respects limit" {
    const a = testing.allocator;
    var items = [_]RankedCandidate{
        .{ .dedupe_key = "", .item = .{ .source_type = "bluesky", .feed_item_json = "{}" }, .original_index = 0, .score = 0.9 },
        .{ .dedupe_key = "", .item = .{ .source_type = "web", .feed_item_json = "{}" }, .original_index = 1, .score = 0.8 },
        .{ .dedupe_key = "", .item = .{ .source_type = "bluesky", .feed_item_json = "{}" }, .original_index = 2, .score = 0.7 },
        .{ .dedupe_key = "", .item = .{ .source_type = "web", .feed_item_json = "{}" }, .original_index = 3, .score = 0.6 },
    };
    const out = try interleave_ranked_candidates_by_source(a, &items, 2);
    defer a.free(out);
    try testing.expectEqual(@as(usize, 2), out.len);
}

// ── rank_candidates_stage2 test ───────────────────────────────────────────

test "rank_candidates_stage2: keyword path ranks and dedupes" {
    const a = testing.allocator;
    const interests = [_]InterestVector{
        .{ .id = "i1", .label = "rust", .embedding = &.{}, .health_score = 0.9, .source_path = "", .keywords = &.{"rust"} },
    };
    const profile = FeedProfile{ .interests = &interests };
    var cands = [_]FeedCandidate{
        .{
            .protocol = .web,
            .dedupe_key = "k1",
            .stage1_score = 0.5,
            .rank_text = "an article about rust the language",
            .item = .{ .source_type = "web", .feed_item_json = "{}" },
            .original_index = 0,
        },
        .{
            .protocol = .web,
            .dedupe_key = "k2",
            .stage1_score = 0.1,
            .rank_text = "celebrity gossip and nothing relevant",
            .item = .{ .source_type = "web", .feed_item_json = "{}" },
            .original_index = 1,
        },
    };
    const now = parse_rfc3339("2026-07-19T20:47:00Z").?;
    const out = try rank_candidates_stage2(a, profile, &cands, 10, now);
    defer a.free(out);
    try testing.expect(out.len >= 1);
    // The rust article should rank higher than the gossip one (keyword match).
    try testing.expectEqualStrings("web", out[0].source_type);
    // First item should have a non-null matched_interest_label ("rust").
    try testing.expect(out[0].matched_interest_label != null);
    try testing.expectEqualStrings("rust", out[0].matched_interest_label.?);
}

// ── rank_candidates (embedder path) tests using the real HashEmbedding ───
//
// The ranker tests previously used a hand-rolled StubEmbedderCtx. Now that the
// package has the canonical HashEmbedding (deterministic fallback from
// src/memory/embeddings.rs), we use it — proving the ranker works against the
// real embedder contract end-to-end.

test "rank_candidates: embedder path ranks matching candidate first" {
    const a = testing.allocator;
    const dim: usize = 64;
    var hash_embed = embeddings.HashEmbedding.init("test", dim);
    const embedder = hash_embed.provider();

    // Build the interest's embedding from HashEmbedding's own output for
    // "rust", so candidate texts about rust will cosine-match strongly.
    const rust_emb = try embeddings.HashEmbedding.embed_text(a, &hash_embed, "rust");
    defer a.free(rust_emb);

    const interests = [_]InterestVector{
        .{ .id = "i1", .label = "rust", .embedding = rust_emb, .health_score = 1.0, .source_path = "", .keywords = &.{"rust"} },
    };
    const profile = FeedProfile{ .interests = &interests };

    var cands = [_]FeedCandidate{
        .{
            .protocol = .web,
            .dedupe_key = "k1",
            .stage1_score = 0.5,
            .rank_text = "all about rust programming",
            .item = .{ .source_type = "web", .feed_item_json = "{}" },
            .original_index = 0,
        },
        .{
            .protocol = .web,
            .dedupe_key = "k2",
            .stage1_score = 0.5,
            .rank_text = "celebrity gossip unrelated fluff",
            .item = .{ .source_type = "web", .feed_item_json = "{}" },
            .original_index = 1,
        },
    };
    const out = try rank_candidates(a, embedder, profile, &cands, 10);
    defer a.free(out);
    try testing.expect(out.len >= 1);
    // The rust candidate must outrank the gossip one (its embedding shares
    // hashed features with the interest's "rust" embedding).
    try testing.expectEqualStrings("web", out[0].source_type);
}

test "rank_candidates: empty inputs return empty" {
    const a = testing.allocator;
    var hash_embed = embeddings.HashEmbedding.init("test", 16);
    const embedder = hash_embed.provider();
    const empty_profile = FeedProfile{};
    const out = try rank_candidates(a, embedder, empty_profile, &.{}, 10);
    try testing.expectEqual(@as(usize, 0), out.len);
}
