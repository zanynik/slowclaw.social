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
    source_platform: []const u8, // "rss" | "nostr" | "bluesky" | "web" | "youtube"
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

    return ranked;
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

// ── Bluesky reply-count admission ─────────────────────────────────────────

pub const DEFAULT_MIN_BLUESKY_REPLIES: u32 = 5;

/// Filter Bluesky posts by minimum reply count. Posts without reply_count
/// are dropped (treated as 0).
pub fn filterBlueskyByReplies(
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

test "filterBlueskyByReplies: drops low-reply posts" {
    const a = testing.allocator;
    const items = [_]FeedItem{
        .{ .id = "1", .title = "T", .body = "", .author_handle = "a", .source_platform = "bluesky", .timestamp = 0, .reply_count = 10 },
        .{ .id = "2", .title = "T", .body = "", .author_handle = "b", .source_platform = "bluesky", .timestamp = 0, .reply_count = 2 },
        .{ .id = "3", .title = "T", .body = "", .author_handle = "c", .source_platform = "bluesky", .timestamp = 0 }, // no reply_count
    };
    const filtered = try filterBlueskyByReplies(a, &items, 5);
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
