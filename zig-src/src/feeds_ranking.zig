//! Feed ranking — journal-driven "For You" scoring for the Reads stream.
//!
//! Ports `web/src/lib/readsRanking.ts` (433 LOC) from TypeScript to Zig. This
//! moves the entire ranking pipeline (scoring, gating, AI boost) from the
//! client-side JS into the Zig core, keeping Swift thin.
//!
//! Score = topicBoost + recencyDecay + imageBonus + readTimeBonus + lengthTiebreak
//! With journal topics this is the "journal is the lens" signal made concrete;
//! without topics it degrades gracefully to pure recency/quality.

const std = @import("std");
const testing = std.testing;
const tokenize_mod = @import("tokenize.zig");

// ── Constants ─────────────────────────────────────────────────────────────

const WORDS_PER_MINUTE: f64 = 220;
const RECENCY_HALF_LIFE_HOURS: f64 = 36;
const TOPIC_MATCH_TOP: f64 = 0.8;
const TOPIC_MATCH_EACH: f64 = 0.3;
const TOPIC_MATCH_CAP: f64 = 1.2;
const NEG_TOPIC_MATCH_TOP: f64 = 0.7;
const NEG_TOPIC_MATCH_EACH: f64 = 0.25;
const NEG_TOPIC_CAP: f64 = 0.9;
const AI_BOOST_WEIGHT: f64 = 0.6;

// ── Types ─────────────────────────────────────────────────────────────────

/// A topic (label + weight) from the user's journals. Matches the TS `Topic`.
pub const Topic = struct {
    label: []const u8,
    weight: f64 = 1.0,
};

/// A unified feed item. This is the Zig equivalent of the TS `UnifiedItem` —
/// the common shape that articles, RSS feeds, social posts, and videos all
/// collapse into for ranking.
pub const FeedItem = struct {
    id: []const u8,
    title: []const u8,
    body: []const u8,
    author_handle: []const u8,
    source_platform: []const u8, // "rss" | "nostr" | "web"
    timestamp: f64, // epoch seconds
    has_image: bool = false,
    image_url: ?[]const u8 = null,
    reply_count: ?u32 = null,
    author_id: ?[]const u8 = null,
    /// Optional AI-generated relevance score (0..1) from the LLM reranker.
    ai_relevance: ?f64 = null,
};

/// A scored item with its computed score and read-time.
pub const RankedItem = struct {
    item: FeedItem,
    score: f64,
    read_minutes: u32,
    source_label: []const u8,
};

// ── Read-time estimation ──────────────────────────────────────────────────

/// Count words in plain text.
pub fn countWords(text: []const u8) usize {
    const trimmed = std.mem.trim(u8, text, " \t\n\r");
    if (trimmed.len == 0) return 0;
    var count: usize = 0;
    var in_word = false;
    for (trimmed) |ch| {
        if (ch == ' ' or ch == '\t' or ch == '\n' or ch == '\r') {
            in_word = false;
        } else if (!in_word) {
            in_word = true;
            count += 1;
        }
    }
    return count;
}

/// Estimate read time in minutes, minimum 1.
pub fn estimateReadMinutes(text: []const u8) u32 {
    const words = countWords(text);
    const mins = @as(f64, @floatFromInt(words)) / WORDS_PER_MINUTE;
    return @max(@as(u32, 1), @as(u32, @intFromFloat(@round(mins))));
}

// ── Topic matching ────────────────────────────────────────────────────────

/// Check if `item` matches `topic_label`. Case-insensitive substring match on
/// title + body. Mirrors the TS `matchesTopic`.
fn matchesTopic(item: FeedItem, topic_label: []const u8) bool {
    // Lowercase the label and check against title + body (case-insensitive).
    var lower_buf: [256]u8 = undefined;
    const label_lower = lowerSlice(&lower_buf, topic_label);

    // Check title
    if (containsCaseInsensitive(item.title, label_lower)) return true;
    // Check body
    if (containsCaseInsensitive(item.body, label_lower)) return true;
    // Check author handle
    if (containsCaseInsensitive(item.author_handle, label_lower)) return true;
    return false;
}

/// Case-insensitive substring search. Allocates nothing; uses byte-by-byte
/// comparison with toLower.
fn containsCaseInsensitive(haystack: []const u8, needle_lower: []const u8) bool {
    if (needle_lower.len == 0) return false;
    if (haystack.len < needle_lower.len) return false;
    var i: usize = 0;
    while (i + needle_lower.len <= haystack.len) : (i += 1) {
        var match = true;
        for (needle_lower, 0..) |n, j| {
            if (std.ascii.toLower(haystack[i + j]) != n) {
                match = false;
                break;
            }
        }
        if (match) return true;
    }
    return false;
}

fn lowerSlice(buf: []u8, src: []const u8) []const u8 {
    const n = @min(buf.len, src.len);
    for (src[0..n], 0..) |ch, i| buf[i] = std.ascii.toLower(ch);
    return buf[0..n];
}

// ── Journal-driven topic boost (positive) ─────────────────────────────────

/// Positive journal-derived relevance boost. Matches the TS `journalTopicBoost`.
fn journalTopicBoost(item: FeedItem, topics: []const Topic) f64 {
    if (topics.len == 0) return 0;
    // Topics should be pre-sorted by weight desc (caller responsibility).
    var boost: f64 = 0;
    var first = true;
    for (topics) |t| {
        if (matchesTopic(item, t.label)) {
            boost += if (first) TOPIC_MATCH_TOP else TOPIC_MATCH_EACH;
            first = false;
            if (boost >= TOPIC_MATCH_CAP) return TOPIC_MATCH_CAP;
        }
    }
    return boost;
}

// ── Dislike-driven topic penalty (negative) ───────────────────────────────

/// Negative journal-derived penalty. Matches the TS `journalTopicPenalty`.
fn journalTopicPenalty(item: FeedItem, negative_topics: []const Topic) f64 {
    if (negative_topics.len == 0) return 0;
    var penalty: f64 = 0;
    var first = true;
    for (negative_topics) |t| {
        if (matchesTopic(item, t.label)) {
            penalty += if (first) NEG_TOPIC_MATCH_TOP else NEG_TOPIC_MATCH_EACH;
            first = false;
            if (penalty >= NEG_TOPIC_CAP) return NEG_TOPIC_CAP;
        }
    }
    return penalty;
}

// ── Core scoring ──────────────────────────────────────────────────────────

/// Score a single feed item. Returns score + read_minutes.
/// `now_epoch` is the current time (for deterministic testing).
/// `topics` and `negative_topics` are optional (pass empty slices to disable).
pub fn scoreRead(
    item: FeedItem,
    topics: []const Topic,
    negative_topics: []const Topic,
    now_epoch: f64,
) struct { score: f64, read_minutes: u32 } {
    const age_hours = @max(@as(f64, 0), (now_epoch - item.timestamp) / 3600);
    const recency = std.math.pow(f64, 0.5, age_hours / RECENCY_HALF_LIFE_HOURS);

    const image_bonus: f64 = if (item.has_image) 0.15 else 0;

    const text_for_readtime = if (item.body.len > 0) item.body else item.title;
    const read_minutes = estimateReadMinutes(text_for_readtime);

    var readtime_bonus: f64 = 0;
    if (read_minutes >= 3 and read_minutes <= 15) {
        readtime_bonus = 0.15;
    } else if (read_minutes >= 2 and read_minutes <= 20) {
        readtime_bonus = 0.05;
    }

    const length_tiebreak = @min(@as(f64, 0.05), @as(f64, @floatFromInt(item.body.len)) / 5000);

    const topic_boost = journalTopicBoost(item, topics);
    const topic_penalty = journalTopicPenalty(item, negative_topics);

    return .{
        .score = topic_boost + recency + image_bonus + readtime_bonus + length_tiebreak - topic_penalty,
        .read_minutes = read_minutes,
    };
}

/// Rank a list of feed items, highest score first. Stable on ties (keeps
/// input order). Returns an allocator-owned slice of RankedItem.
/// Topics should be pre-sorted by weight desc.
pub fn rankReads(
    allocator: std.mem.Allocator,
    items: []const FeedItem,
    topics: []const Topic,
    negative_topics: []const Topic,
    now_epoch: f64,
) ![]RankedItem {
    const ranked = try allocator.alloc(RankedItem, items.len);

    for (items, 0..) |item, i| {
        const s = scoreRead(item, topics, negative_topics, now_epoch);
        const source_label = if (std.mem.eql(u8, item.source_platform, "rss"))
            item.author_handle
        else if (std.mem.eql(u8, item.source_platform, "nostr"))
            "Nostr"
        else
            item.author_handle;

        ranked[i] = .{
            .item = item,
            .score = s.score,
            .read_minutes = s.read_minutes,
            .source_label = source_label,
        };
    }

    // Sort by score descending (stable — preserves input order on ties).
    std.sort.block(RankedItem, ranked, {}, struct {
        fn cmp(_: void, a: RankedItem, b: RankedItem) bool {
            return a.score > b.score;
        }
    }.cmp);

    // Cold start (no journal topics): a brand-new user has no "lens" yet, so a
    // pure score sort lets one prolific source (e.g. Hacker News) own the whole
    // top of the feed. Diversify instead — cap per source + round-robin — so the
    // initial feed reads as "latest tech + latest news, diverse sources" rather
    // than a wall of HN. Once the user writes journals (topics != empty), the
    // journal-driven boost takes over and diversification is skipped.
    if (topics.len == 0) {
        const diversified = diversifyColdStart(allocator, ranked, 3, 60) catch return ranked;
        allocator.free(ranked);
        return diversified;
    }

    return ranked;
}

/// Cold-start diversity pass. Given a score-sorted (desc) slice, cap each
/// `source_label` to `max_per_source` items, then interleave the remaining
/// items round-robin (one per source per round, score order within a source)
/// until `limit` is reached. This prevents a single source from dominating the
/// visible feed when the user has no journal topics yet.
///
/// The result is a freshly-allocated, allocator-owned slice (caller frees).
pub fn diversifyColdStart(
    allocator: std.mem.Allocator,
    ranked: []const RankedItem,
    max_per_source: usize,
    limit: usize,
) ![]RankedItem {
    if (ranked.len == 0) return try allocator.alloc(RankedItem, 0);

    // Per-source queues, preserving score order (ranked is already sorted desc).
    // Each queue holds at most max_per_source items for that source.
    var queues = std.StringHashMap(std.ArrayList(RankedItem)).init(allocator);
    defer {
        var it = queues.iterator();
        while (it.next()) |entry| entry.value_ptr.deinit(allocator);
        queues.deinit();
    }
    for (ranked) |r| {
        const gop = try queues.getOrPut(r.source_label);
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        if (gop.value_ptr.items.len < max_per_source) {
            try gop.value_ptr.append(allocator, r);
        }
    }

    const cap = if (limit == 0) ranked.len else @min(limit, ranked.len);
    var out: std.ArrayList(RankedItem) = .empty;
    errdefer out.deinit(allocator);

    // Round-robin: each pass takes the next item from every source, score-order
    // within a source, until the cap is filled or no source has more to give.
    var any_left = true;
    while (out.items.len < cap and any_left) {
        any_left = false;
        var it = queues.iterator();
        while (it.next()) |entry| {
            if (out.items.len >= cap) break;
            const taken_from_source = countSource(out.items, entry.key_ptr.*);
            if (taken_from_source >= max_per_source) continue;
            if (entry.value_ptr.items.len > taken_from_source) {
                try out.append(allocator, entry.value_ptr.items[taken_from_source]);
                any_left = true;
            }
        }
    }

    return try out.toOwnedSlice(allocator);
}

fn countSource(out: []const RankedItem, source: []const u8) usize {
    var n: usize = 0;
    for (out) |r| {
        if (std.mem.eql(u8, r.source_label, source)) n += 1;
    }
    return n;
}

/// Post-merge production filter (the curation the iOS app was missing — the
/// reference does this in the Rust gateway `ranker.rs`). Apply to the merged,
/// score-sorted batch from many feeds AFTER rankReads:
///   1. Quality gate — drop items with no title AND no body (spam/empty).
///   2. Dedup by link (item.id — the RSS link/guid). Input is score-sorted
///      desc, so first occurrence wins (highest-scored survives). Collapses
///      cross-feed reposts and HN→blog mirrors.
///   3. Per-source cap + round-robin (`diversifyColdStart`) so one feed can't
///      dominate the merged output. Runs UNCONDITIONALLY.
/// Returns an allocator-owned slice (caller frees).
pub fn filterAndDiversify(
    allocator: std.mem.Allocator,
    ranked: []const RankedItem,
    max_per_source: usize,
    limit: usize,
) ![]RankedItem {
    if (ranked.len == 0) return try allocator.alloc(RankedItem, 0);

    // (1) Quality gate: drop items with no title AND no body.
    var quality: std.ArrayList(RankedItem) = .empty;
    errdefer quality.deinit(allocator);
    for (ranked) |r| {
        if (r.item.title.len > 0 or r.item.body.len > 0) {
            try quality.append(allocator, r);
        }
    }

    // (2) Dedup by link (item.id), first-wins (input is score-sorted desc).
    var seen = std.StringHashMap(void).init(allocator);
    defer seen.deinit();
    var deduped: std.ArrayList(RankedItem) = .empty;
    errdefer deduped.deinit(allocator);
    for (quality.items) |r| {
        // Empty link — keep (can't dedup; rare). Non-empty — first wins.
        if (r.item.id.len == 0) {
            try deduped.append(allocator, r);
            continue;
        }
        const gop = try seen.getOrPut(r.item.id);
        if (!gop.found_existing) try deduped.append(allocator, r);
    }
    quality.deinit(allocator);

    // (3) Per-source cap + round-robin (reuse diversifyColdStart's logic).
    const capped = try diversifyColdStart(allocator, deduped.items, max_per_source, limit);
    deduped.deinit(allocator);
    return capped;
}

// ── Chronological variant ─────────────────────────────────────────────────

/// Rank by timestamp (newest first). Returns allocator-owned slice.
pub fn chronologicalReads(
    allocator: std.mem.Allocator,
    items: []const FeedItem,
    now_epoch: f64,
) ![]RankedItem {
    const ranked = try allocator.alloc(RankedItem, items.len);

    for (items, 0..) |item, i| {
        const s = scoreRead(item, &.{}, &.{}, now_epoch);
        const source_label = if (std.mem.eql(u8, item.source_platform, "rss"))
            item.author_handle
        else if (std.mem.eql(u8, item.source_platform, "nostr"))
            "Nostr"
        else
            item.author_handle;

        ranked[i] = .{
            .item = item,
            .score = s.score,
            .read_minutes = s.read_minutes,
            .source_label = source_label,
        };
    }

    // Sort by timestamp descending (stable).
    std.sort.block(RankedItem, ranked, {}, struct {
        fn cmp(_: void, a: RankedItem, b: RankedItem) bool {
            return a.item.timestamp > b.item.timestamp;
        }
    }.cmp);

    return ranked;
}

// ── Social quality gate ───────────────────────────────────────────────────

pub const DEFAULT_MIN_POST_ENGAGEMENT: u32 = 1;
pub const DEFAULT_MIN_AUTHOR_ENGAGEMENT: u32 = 2;
pub const DEFAULT_COLD_START_CAP: usize = 12;

/// Check if a social post is admitted by the reputation gate.
/// Admitted if: author is in WoT, OR post engagement ≥ min_post, OR
/// author engagement ≥ min_author.
pub fn isSocialPostAdmitted(
    author_id: []const u8,
    wot_set: []const []const u8,
    post_engagement: u32,
    author_engagement: u32,
    min_post: u32,
    min_author: u32,
) bool {
    // Check WoT
    for (wot_set) |trusted| {
        if (std.mem.eql(u8, trusted, author_id)) return true;
    }
    if (post_engagement >= min_post) return true;
    if (author_engagement >= min_author) return true;
    return false;
}

// ── Social reply-count admission ──────────────────────────────────────────

pub const DEFAULT_MIN_SOCIAL_REPLIES: u32 = 5;

/// Filter social posts (Nostr) by minimum reply count. Posts without
/// reply_count are dropped (treated as 0).
pub fn filterSocialByReplies(
    allocator: std.mem.Allocator,
    posts: []const FeedItem,
    min_replies: u32,
) ![]const FeedItem {
    var out = std.ArrayList(FeedItem).empty;
    errdefer out.deinit(allocator);
    for (posts) |post| {
        if (post.reply_count) |rc| {
            if (rc >= min_replies) try out.append(allocator, post);
        }
    }
    return out.toOwnedSlice(allocator);
}

// ── AI re-rank boost ──────────────────────────────────────────────────────

/// Apply an AI relevance boost to ranked items. Items with a higher `ai_relevance`
/// score get boosted proportionally. Returns a re-sorted slice.
pub fn applyAiRankBoost(
    allocator: std.mem.Allocator,
    ranked: []RankedItem,
) ![]RankedItem {
    const boosted = try allocator.dupe(RankedItem, ranked);

    for (boosted) |*r| {
        if (r.item.ai_relevance) |ai| {
            r.score += ai * AI_BOOST_WEIGHT;
        }
    }

    // Re-sort by boosted score.
    std.sort.block(RankedItem, boosted, {}, struct {
        fn cmp(_: void, a: RankedItem, b: RankedItem) bool {
            return a.score > b.score;
        }
    }.cmp);

    return boosted;
}

// ──────────────────────────────────────────────────────────────────────────
// Tests
// ──────────────────────────────────────────────────────────────────────────

test "countWords: basic" {
    try testing.expectEqual(@as(usize, 0), countWords(""));
    try testing.expectEqual(@as(usize, 0), countWords("   "));
    try testing.expectEqual(@as(usize, 3), countWords("hello world foo"));
    try testing.expectEqual(@as(usize, 1), countWords("single"));
}

test "estimateReadMinutes: floors to 1" {
    try testing.expectEqual(@as(u32, 1), estimateReadMinutes(""));
    try testing.expectEqual(@as(u32, 1), estimateReadMinutes("a few words"));
    // 660 words = 3 minutes at 220 wpm
    var long = std.ArrayList(u8).empty;
    defer long.deinit(testing.allocator);
    for (0..660) |_| {
        long.appendSlice(testing.allocator, "word ") catch unreachable;
    }
    try testing.expectEqual(@as(u32, 3), estimateReadMinutes(long.items));
}

test "scoreRead: fresh item with no topics gets recency ~1" {
    const now: f64 = 1_000_000;
    const item = FeedItem{
        .id = "1",
        .title = "Test",
        .body = "Some content here",
        .author_handle = "author",
        .source_platform = "rss",
        .timestamp = now, // same time → age 0 → recency 1.0
    };
    const result = scoreRead(item, &.{}, &.{}, now);
    try testing.expect(result.score >= 1.0); // recency alone ≥ 1
    try testing.expect(result.score < 1.3); // no image/topic boost
}

test "scoreRead: topic match boosts score" {
    const now: f64 = 1_000_000;
    const item = FeedItem{
        .id = "1",
        .title = "Rust programming language",
        .body = "An article about rust",
        .author_handle = "author",
        .source_platform = "rss",
        .timestamp = now,
    };
    const topics = [_]Topic{.{ .label = "rust", .weight = 1.0 }};
    const result_with = scoreRead(item, &topics, &.{}, now);

    const result_without = scoreRead(item, &.{}, &.{}, now);
    try testing.expect(result_with.score > result_without.score + 0.5); // significant boost
}

test "scoreRead: negative topic penalizes" {
    const now: f64 = 1_000_000;
    const item = FeedItem{
        .id = "1",
        .title = "Celebrity gossip drama",
        .body = "Drama about celebrities",
        .author_handle = "author",
        .source_platform = "rss",
        .timestamp = now,
    };
    const neg_topics = [_]Topic{.{ .label = "celebrity gossip", .weight = 1.0 }};
    const result_with = scoreRead(item, &.{}, &neg_topics, now);
    const result_without = scoreRead(item, &.{}, &.{}, now);
    try testing.expect(result_with.score < result_without.score);
}

test "rankReads: sorts by score descending" {
    const a = testing.allocator;
    const now: f64 = 1_000_000;
    const topics = [_]Topic{.{ .label = "rust", .weight = 1.0 }};
    const items = [_]FeedItem{
        .{ .id = "1", .title = "Rust article", .body = "about rust", .author_handle = "a", .source_platform = "rss", .timestamp = now },
        .{ .id = "2", .title = "Unrelated", .body = "boring stuff", .author_handle = "b", .source_platform = "rss", .timestamp = now },
    };
    const ranked = try rankReads(a, &items, &topics, &.{}, now);
    defer a.free(ranked);
    try testing.expectEqualStrings("1", ranked[0].item.id); // rust match ranks first
    try testing.expectEqualStrings("2", ranked[1].item.id);
}

test "chronologicalReads: sorts by timestamp descending" {
    const a = testing.allocator;
    const now: f64 = 1_000_000;
    const items = [_]FeedItem{
        .{ .id = "old", .title = "Old", .body = "x", .author_handle = "a", .source_platform = "rss", .timestamp = now - 3600 },
        .{ .id = "new", .title = "New", .body = "x", .author_handle = "b", .source_platform = "rss", .timestamp = now },
    };
    const ranked = try chronologicalReads(a, &items, now);
    defer a.free(ranked);
    try testing.expectEqualStrings("new", ranked[0].item.id);
    try testing.expectEqualStrings("old", ranked[1].item.id);
}

test "filterSocialByReplies: drops low-reply posts" {
    const a = testing.allocator;
    const items = [_]FeedItem{
        .{ .id = "1", .title = "T", .body = "", .author_handle = "a", .source_platform = "bluesky", .timestamp = 0, .reply_count = 10 },
        .{ .id = "2", .title = "T", .body = "", .author_handle = "b", .source_platform = "bluesky", .timestamp = 0, .reply_count = 2 },
        .{ .id = "3", .title = "T", .body = "", .author_handle = "c", .source_platform = "bluesky", .timestamp = 0 }, // no reply_count
    };
    const filtered = try filterSocialByReplies(a, &items, 5);
    defer a.free(filtered);
    try testing.expectEqual(@as(usize, 1), filtered.len);
    try testing.expectEqualStrings("1", filtered[0].id);
}

test "applyAiRankBoost: boosts items with ai_relevance" {
    const a = testing.allocator;
    const items = [_]FeedItem{
        .{ .id = "low", .title = "T", .body = "", .author_handle = "a", .source_platform = "rss", .timestamp = 0, .ai_relevance = 0.1 },
        .{ .id = "high", .title = "T", .body = "", .author_handle = "b", .source_platform = "rss", .timestamp = 0, .ai_relevance = 0.9 },
    };
    const ranked = try rankReads(a, &items, &.{}, &.{}, 1_000_000);
    defer a.free(ranked);
    const boosted = try applyAiRankBoost(a, ranked);
    defer a.free(boosted);
    // The high-relevance item should rank first after boosting.
    try testing.expectEqualStrings("high", boosted[0].item.id);
}

test "containsCaseInsensitive: works with mixed case" {
    try testing.expect(containsCaseInsensitive("Hello World", "world"));
    try testing.expect(containsCaseInsensitive("RUST Programming", "rust"));
    try testing.expect(!containsCaseInsensitive("Hello", "world"));
    try testing.expect(!containsCaseInsensitive("", "x"));
}

test "matchesTopic: matches title, body, author" {
    const item = FeedItem{
        .id = "1",
        .title = "Rust Programming",
        .body = "About systems languages",
        .author_handle = "rustacean",
        .source_platform = "rss",
        .timestamp = 0,
    };
    try testing.expect(matchesTopic(item, "rust"));
    try testing.expect(matchesTopic(item, "systems"));
    try testing.expect(matchesTopic(item, "rustacean"));
    try testing.expect(!matchesTopic(item, "python"));
}

// ── Cold-start diversity (TDD) ─────────────────────────────────────────────

/// Helper: build a RankedItem with a given source label and score.
fn rankedOf(id: []const u8, source_label: []const u8, score: f64) RankedItem {
    return .{
        .item = .{
            .id = id,
            .title = id,
            .body = "",
            .author_handle = source_label,
            .source_platform = "rss",
            .timestamp = 0,
        },
        .score = score,
        .read_minutes = 1,
        .source_label = source_label,
    };
}

test "diversifyColdStart: caps per source and interleaves (no one source dominates)" {
    const a = testing.allocator;
    // Source "hn" has 8 items, "wsj" has 5, "arxiv" has 1 — score-sorted.
    // Without a cap, hn would own the top 8 slots.
    var input = std.ArrayList(RankedItem).empty;
    defer input.deinit(a);
    var i: usize = 0;
    while (i < 8) : (i += 1) try input.append(a, rankedOf("hn-a", "hn", 10.0 - @as(f64, @floatFromInt(i))));
    i = 0;
    while (i < 5) : (i += 1) try input.append(a, rankedOf("wsj-a", "wsj", 9.0 - @as(f64, @floatFromInt(i))));
    try input.append(a, rankedOf("arxiv-a", "arxiv", 8.0));

    const out = try diversifyColdStart(a, input.items, 4, 20);
    defer a.free(out);

    // hn(8)→4, wsj(5)→4, arxiv(1)→1 = 9 capped items. Limit 20 doesn't pad.
    try testing.expectEqual(@as(usize, 9), out.len);
    // No source exceeds the cap of 4.
    var counts = std.StringHashMap(usize).init(a);
    defer counts.deinit();
    for (out) |r| {
        const entry = try counts.getOrPut(r.source_label);
        if (!entry.found_existing) entry.value_ptr.* = 0;
        entry.value_ptr.* += 1;
        try testing.expect(entry.value_ptr.* <= 4);
    }
    // Each capped source contributed its full allotment.
    try testing.expectEqual(@as(usize, 4), counts.get("hn").?);
    try testing.expectEqual(@as(usize, 4), counts.get("wsj").?);
    try testing.expectEqual(@as(usize, 1), counts.get("arxiv").?);
    // Round-robin: the top 3 slots are one-per-source (3 distinct sources),
    // regardless of which source the hash iteration visits first.
    var topSources = std.StringHashMap(void).init(a);
    defer topSources.deinit();
    var k: usize = 0;
    while (k < 3) : (k += 1) try topSources.put(out[k].source_label, {});
    try testing.expectEqual(@as(usize, 3), topSources.count());
}

test "diversifyColdStart: passthrough when input smaller than cap total" {
    const a = testing.allocator;
    const input = [_]RankedItem{
        rankedOf("a", "src1", 5.0),
        rankedOf("b", "src1", 4.0),
        rankedOf("c", "src2", 3.0),
    };
    const out = try diversifyColdStart(a, &input, 4, 20);
    defer a.free(out);
    try testing.expectEqual(@as(usize, 3), out.len); // all 3, no padding
}

test "rankReads: cold-start (no topics) diversifies the output" {
    // Integration: rankReads with no topics should produce a diversified list,
    // not let one source own every top slot.
    const a = testing.allocator;
    var items = std.ArrayList(FeedItem).empty;
    defer items.deinit(a);
    var n: usize = 0;
    while (n < 6) : (n += 1) {
        const id = try std.fmt.allocPrint(a, "hn-{d}", .{n});
        defer a.free(id);
        try items.append(a, .{ .id = id, .title = id, .body = "x", .author_handle = "hackernews", .source_platform = "rss", .timestamp = 1_000_000 - @as(f64, @floatFromInt(n)) });
    }
    n = 0;
    while (n < 3) : (n += 1) {
        const id = try std.fmt.allocPrint(a, "sim-{d}", .{n});
        defer a.free(id);
        try items.append(a, .{ .id = id, .title = id, .body = "x", .author_handle = "simonwillison", .source_platform = "rss", .timestamp = 900_000 - @as(f64, @floatFromInt(n)) });
    }
    const ranked = try rankReads(a, items.items, &.{}, &.{}, 1_000_000);
    defer a.free(ranked);
    // Top 4 must contain at least 2 distinct sources (diversified).
    var seen = std.StringHashMap(void).init(a);
    defer seen.deinit();
    var k: usize = 0;
    while (k < @min(ranked.len, 4)) : (k += 1) try seen.put(ranked[k].source_label, {});
    try testing.expect(seen.count() >= 2);
}

// ── Quality filtering + dedup (TDD) ────────────────────────────────────────
//
// filterAndDiversify is the post-merge production filter the iOS app was
// missing (the reference does this in the Rust gateway ranker.rs). It runs on
// the merged, score-sorted batch from many feeds: drop empty/spam items,
// dedupe by URL/title keeping the highest-scored, then cap per source.

test "filterAndDiversify: drops items with no title AND no body (spam/empty)" {
    const a = testing.allocator;
    // Input score-sorted desc: a spam item (empty title+body) ranks highest,
    // proving the quality gate drops it regardless of score.
    const input = [_]RankedItem{
        .{
            .item = .{ .id = "spam", .title = "", .body = "", .author_handle = "src1", .source_platform = "rss", .timestamp = 0 },
            .score = 9.0, .read_minutes = 1, .source_label = "src1",
        },
        rankedOf("good-a", "src1", 5.0),
        rankedOf("good-b", "src2", 4.0),
    };
    const out = try filterAndDiversify(a, &input, 6, 80);
    defer a.free(out);
    try testing.expectEqual(@as(usize, 2), out.len); // spam dropped
    // Spam id must never appear (round-robin reorders, so check membership).
    for (out) |r| try testing.expect(!std.mem.eql(u8, r.item.id, "spam"));
}

test "filterAndDiversify: dedupes by link (item.id), keeps highest-scored" {
    const a = testing.allocator;
    // Two items share the SAME link (item.id); input is score-sorted desc so
    // the first (higher-scored) is the one that survives (first-wins).
    const dup_hi: RankedItem = .{
        .item = .{ .id = "https://example.com/same", .title = "Hi", .body = "body", .author_handle = "src1", .source_platform = "rss", .timestamp = 0 },
        .score = 8.0, .read_minutes = 2, .source_label = "src1",
    };
    const dup_lo: RankedItem = .{
        .item = .{ .id = "https://example.com/same", .title = "Lo", .body = "body", .author_handle = "src2", .source_platform = "rss", .timestamp = 0 },
        .score = 5.0, .read_minutes = 2, .source_label = "src2",
    };
    const other = rankedOf("other", "src3", 3.0);
    const input = [_]RankedItem{ dup_hi, dup_lo, other };
    const out = try filterAndDiversify(a, &input, 6, 80);
    defer a.free(out);
    try testing.expectEqual(@as(usize, 2), out.len); // dup collapsed
    // The higher-scored dup must be the survivor.
    var survivor_score: f64 = -1;
    for (out) |r| if (std.mem.eql(u8, r.item.id, "https://example.com/same")) {
        survivor_score = r.score;
    };
    try testing.expectEqual(@as(f64, 8.0), survivor_score);
}

test "filterAndDiversify: per-source cap applies unconditionally" {
    // Unlike diversifyColdStart (cold-only), filterAndDiversify caps sources
    // on EVERY batch so one prolific feed can't dominate the merged output.
    const a = testing.allocator;
    var input = std.ArrayList(RankedItem).empty;
    defer input.deinit(a);
    // Keep the id strings alive for the test's lifetime (RankedItem.item.id
    // borrows them; freeing mid-build would be a use-after-free).
    var ids = std.ArrayList([]u8).empty;
    defer {
        for (ids.items) |s| a.free(s);
        ids.deinit(a);
    }
    var n: usize = 0;
    while (n < 9) : (n += 1) {
        const id = try std.fmt.allocPrint(a, "hn-{d}", .{n});
        try ids.append(a, id);
        try input.append(a, rankedOf(id, "hackernews", @as(f64, @floatFromInt(10 - n))));
    }
    try input.append(a, rankedOf("other", "simon", 1.0));
    const out = try filterAndDiversify(a, input.items, 3, 80);
    defer a.free(out);
    // hackernews capped to 3; "other" survives -> 4 total.
    try testing.expectEqual(@as(usize, 4), out.len);
    var hn = std.StringHashMap(usize).init(a);
    defer hn.deinit();
    for (out) |r| {
        const e = try hn.getOrPut(r.source_label);
        if (!e.found_existing) e.value_ptr.* = 0;
        e.value_ptr.* += 1;
    }
    try testing.expectEqual(@as(usize, 3), hn.get("hackernews").?);
    try testing.expectEqual(@as(usize, 1), hn.get("simon").?);
}
