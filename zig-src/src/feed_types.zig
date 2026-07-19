//! Feed data types — ports `src/feed/types.rs`.
//!
//! Plain-data structs used by the ranker. Field names mirror the Rust originals
//! (snake_case, which is also Zig convention). Strings are `[]const u8` slices
//! borrowed from the caller's owned data; the ranker does not clone or free
//! them. Optionals use Zig's `?T`.

const std = @import("std");
const testing = std.testing;

/// Feed ingestion protocol. Mirrors `FeedProtocol` in `src/feed/types.rs:5`.
/// `sourceType()` mirrors the Rust impl: Bluesky is its own source_type; the
/// other three collapse to "web".
pub const FeedProtocol = enum {
    bluesky,
    rss,
    nostr,
    web,

    pub fn sourceType(self: FeedProtocol) []const u8 {
        return switch (self) {
            .bluesky => "bluesky",
            .rss, .nostr, .web => "web",
        };
    }
};

/// Interest profile health stats. Mirrors `InterestProfileStats` (camelCase
/// JSON in Rust). All default to zero.
pub const InterestProfileStats = struct {
    interest_count: usize = 0,
    source_count: usize = 0,
    refreshed_sources: usize = 0,
    merged_count: usize = 0,
    spawned_count: usize = 0,
    ignored_count: usize = 0,
};

/// Per-source context attached to a ranked item. Mirrors `FeedSourceContext`.
/// Optional fields use Rust's `Option<String>`/`Option<f32>` → Zig `?T`.
pub const FeedSourceContext = struct {
    label: []const u8,
    description: ?[]const u8 = null,
    matched_interest_label: ?[]const u8 = null,
    matched_interest_score: ?f32 = null,
    source_score: ?f32 = null,
};

/// Web article preview payload. Mirrors `WebFeedPreview`.
pub const WebFeedPreview = struct {
    url: []const u8,
    title: []const u8,
    description: []const u8,
    content_text: []const u8,
    image_url: ?[]const u8 = null,
    domain: []const u8,
    provider: []const u8,
    provider_snippet: ?[]const u8 = null,
    discovered_at: []const u8,
};

/// A ranked feed item, the ranker's primary output. Mirrors
/// `PersonalizedFeedItem`. The `feed_item` field in Rust is a
/// `serde_json::Value` (arbitrary JSON); for the Zig port we keep it as an
/// opaque `[]const u8` JSON blob until/unless the consumer needs typed access.
/// `passed_threshold` is set by the ranker.
pub const PersonalizedFeedItem = struct {
    source_type: []const u8,
    feed_item_json: []const u8,
    web_preview: ?WebFeedPreview = null,
    feed_source: ?FeedSourceContext = null,
    score: ?f32 = null,
    matched_interest_label: ?[]const u8 = null,
    matched_interest_score: ?f32 = null,
    passed_threshold: bool = false,
};

/// A user's interest vector — embedding + metadata. Mirrors
/// `InterestVector` in `src/feed/types.rs:93`.
pub const InterestVector = struct {
    id: []const u8,
    label: []const u8,
    embedding: []const f32,
    health_score: f32,
    source_path: []const u8,
    keywords: []const []const u8,
};

/// A user's feed-rank profile — interests + negatives. Mirrors `FeedProfile`
/// in `src/feed/types.rs:102`. The ranker reads this; the caller owns all
/// slices (interests, negative_interests, and everything reachable from them).
pub const FeedProfile = struct {
    status: []const u8 = "",
    stats: InterestProfileStats = .{},
    interests: []const InterestVector = &.{},
    /// Negative steering terms (disliked-card keywords). The ranker applies a
    /// subtractive penalty for matches — down-rank, never hide — mirroring the
    /// client-side `journalTopicPenalty` policy.
    negative_interests: []const InterestVector = &.{},
};

/// A candidate item to rank. Mirrors `FeedCandidate` in `src/feed/types.rs:182`.
/// `original_index` preserves caller ordering across dedup.
pub const FeedCandidate = struct {
    protocol: FeedProtocol,
    dedupe_key: []const u8,
    stage1_score: f32,
    rank_text: []const u8,
    item: PersonalizedFeedItem,
    original_index: usize,
};

// ──────────────────────────────────────────────────────────────────────────
// Tests — layout + behavior (sourceType mapping is the only behavior here).
// ──────────────────────────────────────────────────────────────────────────

test "FeedProtocol.sourceType: bluesky is distinct, others collapse to web" {
    try testing.expectEqualStrings("bluesky", FeedProtocol.bluesky.sourceType());
    try testing.expectEqualStrings("web", FeedProtocol.rss.sourceType());
    try testing.expectEqualStrings("web", FeedProtocol.nostr.sourceType());
    try testing.expectEqualStrings("web", FeedProtocol.web.sourceType());
}

test "InterestProfileStats: defaults are all zero" {
    const s = InterestProfileStats{};
    try testing.expectEqual(@as(usize, 0), s.interest_count);
    try testing.expectEqual(@as(usize, 0), s.source_count);
    try testing.expectEqual(@as(usize, 0), s.refreshed_sources);
    try testing.expectEqual(@as(usize, 0), s.merged_count);
    try testing.expectEqual(@as(usize, 0), s.spawned_count);
    try testing.expectEqual(@as(usize, 0), s.ignored_count);
}

test "FeedProfile: empty defaults" {
    const p = FeedProfile{};
    try testing.expectEqualStrings("", p.status);
    try testing.expectEqual(@as(usize, 0), p.interests.len);
    try testing.expectEqual(@as(usize, 0), p.negative_interests.len);
}

test "InterestVector: constructs with sample data" {
    const emb = [_]f32{ 0.1, 0.2, 0.3 };
    const kw = [_][]const u8{ "rust", "zig" };
    const iv = InterestVector{
        .id = "iv1",
        .label = "rust lang",
        .embedding = &emb,
        .health_score = 0.8,
        .source_path = "journal/abc",
        .keywords = &kw,
    };
    try testing.expectEqualStrings("iv1", iv.id);
    try testing.expectEqualStrings("rust lang", iv.label);
    try testing.expectEqual(@as(usize, 3), iv.embedding.len);
    try testing.expectEqual(@as(f32, 0.8), iv.health_score);
    try testing.expectEqual(@as(usize, 2), iv.keywords.len);
}

test "FeedCandidate: round-trip construction" {
    const item = PersonalizedFeedItem{
        .source_type = "web",
        .feed_item_json = "{}",
    };
    const c = FeedCandidate{
        .protocol = .rss,
        .dedupe_key = "k1",
        .stage1_score = 0.5,
        .rank_text = "hello world",
        .item = item,
        .original_index = 7,
    };
    try testing.expectEqual(FeedProtocol.rss, c.protocol);
    try testing.expectEqualStrings("web", c.item.source_type);
    try testing.expectEqual(@as(usize, 7), c.original_index);
}

test "PersonalizedFeedItem: defaults match Rust Default" {
    const item = PersonalizedFeedItem{
        .source_type = "bluesky",
        .feed_item_json = "{}",
    };
    try testing.expect(!item.passed_threshold);
    try testing.expect(item.score == null);
    try testing.expect(item.web_preview == null);
}
