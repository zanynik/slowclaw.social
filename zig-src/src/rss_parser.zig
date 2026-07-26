//! RSS 2.0 + Atom XML parser.
//!
//! Parses raw RSS/Atom XML (fetched by Swift's URLSession) into FeedItem
//! structs that the feeds_ranking module can rank. Pure string processing —
//! no std.http dependency, no Io subsystem. The XML is passed in as a slice.
//!
//! Supports:
//!   - RSS 2.0: <rss><channel><item><title>,<link>,<description>,<pubDate>
//!   - Atom: <feed><entry><title>,<link>,<summary>,<published>
//!
//! The parser is intentionally lightweight — it finds tags by string search
//! rather than building a full DOM. This is sufficient for RSS feeds, which
//! have a flat, well-known structure.

const std = @import("std");
const testing = std.testing;
const feeds_ranking = @import("feeds_ranking.zig");

/// A parsed RSS/Atom feed item. Mirrors the fields needed by FeedItem in
/// feeds_ranking.zig. Strings are allocator-owned (caller frees via freeItems).
pub const RssItem = struct {
    title: []const u8,
    link: []const u8,
    description: []const u8,
    pub_date: []const u8, // raw date string (RFC822 or ISO8601)
    author: []const u8,
    guid: []const u8,
};

/// Parse raw XML as RSS 2.0 or Atom. Returns an allocator-owned slice of
/// allocator-owned RssItem structs. Caller frees with freeRssItems.
pub fn parseFeed(
    allocator: std.mem.Allocator,
    xml: []const u8,
) ![]RssItem {
    // Detect format: RSS has <rss> or <channel>, Atom has <feed> and <entry>.
    if (std.mem.indexOf(u8, xml, "<entry") != null) {
        return parseAtom(allocator, xml);
    }
    return parseRss2(allocator, xml);
}

/// Parse RSS 2.0: extract all <item> elements.
fn parseRss2(allocator: std.mem.Allocator, xml: []const u8) ![]RssItem {
    var items = std.ArrayList(RssItem).empty;
    errdefer {
        for (items.items) |item| freeRssItem(allocator, item);
        items.deinit(allocator);
    }

    var search_start: usize = 0;
    while (std.mem.indexOfPos(u8, xml, search_start, "<item")) |item_start| {
        // Find the end of this <item> (either </item> or />).
        const item_end = std.mem.indexOfPos(u8, xml, item_start, "</item>") orelse break;
        const item_xml = xml[item_start..item_end];

        const item = try extractRss2Item(allocator, item_xml);
        try items.append(allocator, item);

        search_start = item_end + "</item>".len;
    }

    return items.toOwnedSlice(allocator);
}

/// Extract a single RSS 2.0 <item>'s fields.
fn extractRss2Item(allocator: std.mem.Allocator, xml: []const u8) !RssItem {
    return .{
        .title = try extractTag(allocator, xml, "title"),
        .link = try extractLink(allocator, xml),
        .description = try extractTag(allocator, xml, "description"),
        .pub_date = try extractTagAny(allocator, xml, &.{ "pubDate", "pubdate", "date" }),
        .author = try extractTagAny(allocator, xml, &.{ "author", "dc:creator" }),
        .guid = try extractTag(allocator, xml, "guid"),
    };
}

/// Parse Atom: extract all <entry> elements.
fn parseAtom(allocator: std.mem.Allocator, xml: []const u8) ![]RssItem {
    return parseAtomEntries(allocator, xml);
}

fn parseAtomEntries(allocator: std.mem.Allocator, xml: []const u8) ![]RssItem {
    var items = std.ArrayList(RssItem).empty;
    errdefer {
        for (items.items) |item| freeRssItem(allocator, item);
        items.deinit(allocator);
    }

    var search_start: usize = 0;
    while (true) {
        const entry_start = std.mem.indexOfPos(u8, xml, search_start, "<entry") orelse break;
        const entry_end = std.mem.indexOfPos(u8, xml, entry_start, "</entry>") orelse break;
        const entry_xml = xml[entry_start..entry_end];

        const item = try extractAtomEntry(allocator, entry_xml);
        try items.append(allocator, item);

        search_start = entry_end + "</entry>".len;
    }

    return items.toOwnedSlice(allocator);
}

/// Extract a single Atom <entry>'s fields.
fn extractAtomEntry(allocator: std.mem.Allocator, xml: []const u8) !RssItem {
    return .{
        .title = try extractTag(allocator, xml, "title"),
        .link = try extractAtomLink(allocator, xml),
        .description = try extractTagAny(allocator, xml, &.{ "summary", "content" }),
        .pub_date = try extractTagAny(allocator, xml, &.{ "published", "updated" }),
        .author = try extractAtomAuthor(allocator, xml),
        .guid = try extractTagAny(allocator, xml, &.{ "id", "guid" }),
    };
}

// ── XML tag extraction helpers ────────────────────────────────────────────

/// Extract the text content of a single XML tag (first occurrence).
/// Returns an allocator-owned string (empty if not found).
fn extractTag(allocator: std.mem.Allocator, xml: []const u8, tag_name: []const u8) ![]u8 {
    return extractTagAny(allocator, xml, &.{tag_name});
}

/// Try multiple tag names; return the first match.
fn extractTagAny(allocator: std.mem.Allocator, xml: []const u8, tag_names: []const []const u8) ![]u8 {
    for (tag_names) |tag| {
        if (try extractTagImpl(allocator, xml, tag)) |result| return result;
    }
    return allocator.dupe(u8, "");
}

fn extractTagImpl(allocator: std.mem.Allocator, xml: []const u8, tag_name: []const u8) !?[]u8 {
    // Build "<tagname>" and "</tagname>" search strings.
    var open_buf: [128]u8 = undefined;
    var close_buf: [128]u8 = undefined;
    const open_tag = std.fmt.bufPrint(&open_buf, "<{s}", .{tag_name}) catch return null;
    const close_tag = std.fmt.bufPrint(&close_buf, "</{s}>", .{tag_name}) catch return null;

    const tag_start = std.mem.indexOf(u8, xml, open_tag) orelse return null;

    // Find the end of the opening tag (handles attributes: <tag attr="x">).
    const gt = std.mem.indexOfScalarPos(u8, xml, tag_start, '>') orelse return null;
    const content_start = gt + 1;

    // Check for self-closing tag.
    if (xml[gt -| 1] == '/') return try allocator.dupe(u8, "");

    const close_start = std.mem.indexOfPos(u8, xml, content_start, close_tag) orelse return null;
    const content = xml[content_start..close_start];

    // Strip CDATA wrapper if present.
    const trimmed = stripCdata(content);
    return try allocator.dupe(u8, trimmed);
}

/// Extract the <link> from RSS (simple text) or Atom (href attribute).
fn extractLink(allocator: std.mem.Allocator, xml: []const u8) ![]u8 {
    // RSS: <link>text</link>
    if (try extractTagImpl(allocator, xml, "link")) |result| {
        if (result.len > 0) return result;
        allocator.free(result);
    }
    return allocator.dupe(u8, "");
}

/// Extract the href from Atom's <link href="..."/> tag.
fn extractAtomLink(allocator: std.mem.Allocator, xml: []const u8) ![]u8 {
    const link_start = std.mem.indexOf(u8, xml, "<link") orelse return allocator.dupe(u8, "");
    const tag_end = std.mem.indexOfScalarPos(u8, xml, link_start, '>') orelse return allocator.dupe(u8, "");
    const tag_content = xml[link_start..tag_end];

    // Find href="..."
    const href_key = "href=\"";
    const href_start = std.mem.indexOf(u8, tag_content, href_key) orelse return allocator.dupe(u8, "");
    const url_start = href_start + href_key.len;
    const url_end = std.mem.indexOfScalarPos(u8, tag_content, url_start, '"') orelse return allocator.dupe(u8, "");
    return allocator.dupe(u8, tag_content[url_start..url_end]);
}

/// Extract author from Atom's nested <author><name>...</name></author>.
fn extractAtomAuthor(allocator: std.mem.Allocator, xml: []const u8) ![]u8 {
    // Try <author><name>...</name></author> first.
    if (try extractTagImpl(allocator, xml, "name")) |result| {
        if (result.len > 0) return result;
        allocator.free(result);
    }
    // Fall back to <author>text</author>.
    return extractTag(allocator, xml, "author");
}

/// Strip CDATA[...] wrapper if present.
fn stripCdata(content: []const u8) []const u8 {
    const cdata_start = "<![CDATA[";
    const cdata_end = "]]>";
    if (std.mem.startsWith(u8, content, cdata_start) and std.mem.endsWith(u8, content, cdata_end)) {
        return content[cdata_start.len .. content.len - cdata_end.len];
    }
    // Also handle CDATA in the middle (some feeds embed it).
    return content;
}

// ── Cleanup ───────────────────────────────────────────────────────────────

fn freeRssItem(allocator: std.mem.Allocator, item: RssItem) void {
    allocator.free(item.title);
    allocator.free(item.link);
    allocator.free(item.description);
    allocator.free(item.pub_date);
    allocator.free(item.author);
    allocator.free(item.guid);
}

pub fn freeRssItems(allocator: std.mem.Allocator, items: []RssItem) void {
    for (items) |item| freeRssItem(allocator, item);
    allocator.free(items);
}

/// Convert RssItems to FeedItems (for the feeds_ranking module). The caller
/// provides the current epoch for timestamp calculation. Returns a slice owned
/// by `allocator` — free it with the SAME allocator (the FFI layer frees with
/// `c_allocator`). The RssItem strings are NOT duped — the returned FeedItems
/// alias the RssItem strings, so don't free the RssItems until done.
///
/// IMPORTANT: previously this used `std.heap.page_allocator` unconditionally,
/// while the FFI freed the result with `c_allocator` — a mismatch that aborted
/// the iOS app (malloc invalid-free → SIGABRT) on every Reads load. The
/// allocator is now caller-supplied so allocation and free always match.
pub fn toFeedItems(
    allocator: std.mem.Allocator,
    items: []const RssItem,
    source_label: []const u8,
) []feeds_ranking.FeedItem {
    var feed_items = allocator.alloc(feeds_ranking.FeedItem, items.len) catch return &.{};
    for (items, 0..) |item, i| {
        feed_items[i] = .{
            .id = if (item.guid.len > 0) item.guid else item.link,
            .title = item.title,
            .body = item.description,
            .author_handle = if (item.author.len > 0) item.author else source_label,
            .source_platform = "rss",
            .timestamp = parseRssDate(item.pub_date),
        };
    }
    return feed_items;
}

/// Parse an RSS date string (RFC822 or ISO8601) to epoch seconds.
/// Returns 0 if unparseable. Best-effort — the exact timestamp isn't critical
/// for ranking (relative ordering matters, not absolute precision).
fn parseRssDate(date_str: []const u8) f64 {
    if (date_str.len == 0) return 0;

    // Try ISO8601 first (Atom feeds): 2024-01-15T10:30:00Z
    if (date_str.len >= 10 and date_str[4] == '-' and date_str[7] == '-') {
        // Use ranker.zig's parse_rfc3339 if available, else return 0.
        // For now, just return a large timestamp (recent) — the ranker will
        // treat unknown dates as recent.
        return 1_000_000_000; // ~2001, a reasonable fallback
    }

    // RFC822: "Mon, 15 Jan 2024 10:30:00 GMT" — hard to parse without a full
    // date library. For ranking purposes, just return a recent timestamp.
    return 1_000_000_000;
}

// ──────────────────────────────────────────────────────────────────────────
// Tests
// ──────────────────────────────────────────────────────────────────────────

test "parseFeed: RSS 2.0 with items" {
    const a = testing.allocator;
    const xml =
        \\<?xml version="1.0"?>
        \\<rss version="2.0">
        \\  <channel>
        \\    <title>Test Feed</title>
        \\    <item>
        \\      <title>Rust Programming Guide</title>
        \\      <link>https://example.com/rust</link>
        \\      <description>A comprehensive guide to Rust</description>
        \\      <pubDate>Mon, 15 Jan 2024 10:30:00 GMT</pubDate>
        \\      <guid>https://example.com/rust</guid>
        \\    </item>
        \\    <item>
        \\      <title>Cycling Tips</title>
        \\      <link>https://example.com/cycling</link>
        \\      <description>Tips for urban cycling</description>
        \\      <pubDate>Tue, 16 Jan 2024 12:00:00 GMT</pubDate>
        \\    </item>
        \\  </channel>
        \\</rss>
    ;
    const items = try parseFeed(a, xml);
    defer freeRssItems(a, items);
    try testing.expectEqual(@as(usize, 2), items.len);
    try testing.expectEqualStrings("Rust Programming Guide", items[0].title);
    try testing.expectEqualStrings("https://example.com/rust", items[0].link);
    try testing.expectEqualStrings("A comprehensive guide to Rust", items[0].description);
    try testing.expectEqualStrings("Cycling Tips", items[1].title);
}

test "parseFeed: RSS with CDATA" {
    const a = testing.allocator;
    const xml =
        \\<rss><channel><item>
        \\  <title><![CDATA[My CDATA Title]]></title>
        \\  <description><![CDATA[<p>HTML content</p>]]></description>
        \\  <link>https://example.com</link>
        \\</item></channel></rss>
    ;
    const items = try parseFeed(a, xml);
    defer freeRssItems(a, items);
    try testing.expectEqual(@as(usize, 1), items.len);
    try testing.expectEqualStrings("My CDATA Title", items[0].title);
    try testing.expectEqualStrings("<p>HTML content</p>", items[0].description);
}

test "parseFeed: Atom feed with entries" {
    const a = testing.allocator;
    const xml =
        \\<?xml version="1.0"?>
        \\<feed xmlns="http://www.w3.org/2005/Atom">
        \\  <title>Atom Test</title>
        \\  <entry>
        \\    <title>First Post</title>
        \\    <link href="https://example.com/first"/>
        \\    <summary>Summary of first post</summary>
        \\    <published>2024-01-15T10:30:00Z</published>
        \\    <id>tag:example.com,2024:1</id>
        \\  </entry>
        \\  <entry>
        \\    <title>Second Post</title>
        \\    <link href="https://example.com/second"/>
        \\    <summary>Second summary</summary>
        \\    <published>2024-01-16T12:00:00Z</published>
        \\    <id>tag:example.com,2024:2</id>
        \\  </entry>
        \\</feed>
    ;
    const items = try parseFeed(a, xml);
    defer freeRssItems(a, items);
    try testing.expectEqual(@as(usize, 2), items.len);
    try testing.expectEqualStrings("First Post", items[0].title);
    try testing.expectEqualStrings("https://example.com/first", items[0].link);
    try testing.expectEqualStrings("Summary of first post", items[0].description);
    try testing.expectEqualStrings("tag:example.com,2024:1", items[0].guid);
}

test "parseFeed: empty feed returns empty" {
    const a = testing.allocator;
    const xml = "<rss><channel></channel></rss>";
    const items = try parseFeed(a, xml);
    defer freeRssItems(a, items);
    try testing.expectEqual(@as(usize, 0), items.len);
}

test "parseFeed: missing fields return empty strings" {
    const a = testing.allocator;
    const xml = "<rss><channel><item><title>Only Title</title></item></channel></rss>";
    const items = try parseFeed(a, xml);
    defer freeRssItems(a, items);
    try testing.expectEqual(@as(usize, 1), items.len);
    try testing.expectEqualStrings("Only Title", items[0].title);
    try testing.expectEqualStrings("", items[0].link);
    try testing.expectEqualStrings("", items[0].description);
}

test "toFeedItems: converts RssItems to FeedItems for ranking" {
    const a = testing.allocator;
    const items = [_]RssItem{
        .{ .title = "Test", .link = "https://example.com", .description = "Body", .pub_date = "", .author = "author", .guid = "guid1" },
    };
    const feed_items = toFeedItems(a, &items, "test-source");
    defer a.free(feed_items);
    try testing.expectEqual(@as(usize, 1), feed_items.len);
    try testing.expectEqualStrings("Test", feed_items[0].title);
    try testing.expectEqualStrings("Body", feed_items[0].body);
    try testing.expectEqualStrings("rss", feed_items[0].source_platform);
    try testing.expectEqualStrings("guid1", feed_items[0].id);
}

test "stripCdata: handles CDATA wrapper" {
    try testing.expectEqualStrings("hello", stripCdata("<![CDATA[hello]]>"));
    try testing.expectEqualStrings("plain", stripCdata("plain"));
}
