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
    /// Best-effort cover image (media:thumbnail / media:content / image
    /// enclosure / first <img> in the description). Empty when none found.
    image_url: []const u8 = "",
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
        .image_url = try extractItemImage(allocator, xml),
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
        .image_url = try extractItemImage(allocator, xml),
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

/// Extract the first <img src="..."> URL from arbitrary content (used as a
/// last-resort cover image when the feed carries no explicit media tags).
/// Handles both raw-HTML (CDATA) and entity-encoded descriptions — the
/// latter embed `&lt;img src="…"&gt;` literally.
fn firstImgSrc(content: []const u8) []const u8 {
    var search: usize = 0;
    while (nextImgTag(content, &search)) |tag_start| {
        const tag_end = std.mem.indexOfScalarPos(u8, content, tag_start, '>') orelse {
            // Entity-encoded form: '>' arrives as "&gt;".
            const gt = std.mem.indexOfPos(u8, content, tag_start, "&gt;") orelse return "";
            if (extractAttrValue(content[tag_start..gt], "src")) |src| return src;
            search = gt + 4;
            continue;
        };
        if (extractAttrValue(content[tag_start..tag_end], "src")) |src| return src;
        search = tag_end + 1;
    }
    return "";
}

/// Find the start of the next <img tag — either `<img` or `&lt;img` — and
/// advance `search` past it. The returned index points at the tag's name so
/// attribute scanning can start there.
fn nextImgTag(content: []const u8, search: *usize) ?usize {
    const raw = std.mem.indexOfPos(u8, content, search.*, "<img");
    const enc = std.mem.indexOfPos(u8, content, search.*, "&lt;img");
    const at = if (raw) |r| if (enc) |e| @min(r, e) else r else (enc orelse return null);
    search.* = at + 4;
    return at;
}

/// Find `attr_name="value"` (single or double quotes) inside one tag's
/// `<name …` span. Returns a slice into `tag_span`; empty on absence.
fn extractAttrValue(tag_span: []const u8, attr_name: []const u8) ?[]const u8 {
    // Match the attribute name at a token boundary so "src" doesn't match
    // "data-src" or "srcset".
    var search: usize = 0;
    while (search < tag_span.len) {
        const name_at = std.mem.indexOfPos(u8, tag_span, search, attr_name) orelse return null;
        const before_ok = name_at == 0 or !isAttrNameByte(tag_span[name_at - 1]);
        const after = name_at + attr_name.len;
        const after_ok = after < tag_span.len and (tag_span[after] == '=' or isWhitespaceByte(tag_span[after]));
        if (before_ok and after_ok) {
            // Skip optional whitespace, then require `="` or `='`.
            var i = after;
            while (i < tag_span.len and isWhitespaceByte(tag_span[i])) i += 1;
            if (i < tag_span.len and tag_span[i] == '=' and i + 1 < tag_span.len and
                (tag_span[i + 1] == '"' or tag_span[i + 1] == '\''))
            {
                const quote = tag_span[i + 1];
                const val_start = i + 2;
                const val_end = std.mem.indexOfScalarPos(u8, tag_span, val_start, quote) orelse return null;
                return tag_span[val_start..val_end];
            }
        }
        search = name_at + attr_name.len;
    }
    return null;
}

fn isAttrNameByte(ch: u8) bool {
    return std.ascii.isAlphanumeric(ch) or ch == '-' or ch == '_' or ch == ':';
}

fn isWhitespaceByte(ch: u8) bool {
    return ch == ' ' or ch == '\t' or ch == '\n' or ch == '\r';
}

/// Locate the first occurrence of `<tag_name` that starts an actual tag
/// (next byte is whitespace, `/` or `>`), and return the span from `<` through
/// the closing `>` (exclusive). Null when absent.
fn findTagSpan(xml: []const u8, tag_name: []const u8) ?[]const u8 {
    var search: usize = 0;
    while (std.mem.indexOfPos(u8, xml, search, tag_name)) |at| {
        if (at > 0 and xml[at - 1] == '<') {
            const after = at + tag_name.len;
            if (after < xml.len and
                (isWhitespaceByte(xml[after]) or xml[after] == '/' or xml[after] == '>'))
            {
                const tag_end = std.mem.indexOfScalarPos(u8, xml, after, '>') orelse return null;
                return xml[at - 1 .. tag_end + 1];
            }
        }
        search = at + tag_name.len;
    }
    return null;
}

/// Extract a cover image URL for an RSS <item> or Atom <entry>, in priority
/// order: media:thumbnail → image-typed media:content → image enclosure →
/// first <img> embedded in the item's HTML description. Returns an
/// allocator-owned string (empty when nothing usable is found).
fn extractItemImage(allocator: std.mem.Allocator, xml: []const u8) ![]u8 {
    if (firstCoverCandidate(xml)) |url| {
        return try allocator.dupe(u8, url);
    }
    return try allocator.dupe(u8, "");
}

fn firstCoverCandidate(xml: []const u8) ?[]const u8 {
    // 1. media:thumbnail url="…" (unambiguously an image).
    if (findTagSpan(xml, "media:thumbnail")) |span| {
        if (extractAttrValue(span, "url")) |u| return validImageURL(u);
    }
    // 2. media:content url="…" — only when it declares itself an image
    //    (type="image/*" or medium="image"); media:content is frequently
    //    video/audio.
    if (findTagSpan(xml, "media:content")) |span| {
        const is_image = if (extractAttrValue(span, "type")) |t|
            std.mem.startsWith(u8, t, "image/")
        else if (extractAttrValue(span, "medium")) |m|
            std.mem.eql(u8, m, "image")
        else
            false;
        if (is_image) {
            if (extractAttrValue(span, "url")) |u| return validImageURL(u);
        }
    }
    // 3. RSS <enclosure url="…" type="image/…">.
    var search: usize = 0;
    while (std.mem.indexOfPos(u8, xml, search, "<enclosure")) |at| {
        const tag_end = std.mem.indexOfScalarPos(u8, xml, at, '>') orelse break;
        const span = xml[at .. tag_end + 1];
        const is_image = if (extractAttrValue(span, "type")) |t|
            std.mem.startsWith(u8, t, "image/")
        else
            false;
        if (is_image) {
            if (extractAttrValue(span, "url")) |u| return validImageURL(u);
        }
        search = tag_end + 1;
    }
    // 4. Atom enclosure link: <link rel="enclosure" type="image/…" href="…">.
    if (findTagSpan(xml, "link")) |_| {
        var search2: usize = 0;
        while (std.mem.indexOfPos(u8, xml, search2, "<link")) |at| {
            const tag_end = std.mem.indexOfScalarPos(u8, xml, at, '>') orelse break;
            const span = xml[at .. tag_end + 1];
            const rel_ok = if (extractAttrValue(span, "rel")) |r| std.mem.eql(u8, r, "enclosure") else false;
            const is_image = if (extractAttrValue(span, "type")) |t| std.mem.startsWith(u8, t, "image/") else false;
            if (rel_ok and is_image) {
                if (extractAttrValue(span, "href")) |u| return validImageURL(u);
            }
            search2 = tag_end + 1;
        }
    }
    // 5. First <img> inside the description/summary content.
    return validImageURL(firstImgSrc(xml));
}

/// Accept only absolute http(s) image URLs — relative URLs can't be resolved
/// without the feed's own URL here, and garbage values would only produce
/// broken AsyncImage loads downstream.
fn validImageURL(u: []const u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, u, " \t\n\r");
    if (trimmed.len == 0) return null;
    if (std.mem.startsWith(u8, trimmed, "http://") or std.mem.startsWith(u8, trimmed, "https://")) {
        return trimmed;
    }
    return null;
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
    allocator.free(item.image_url);
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
    now_epoch: f64,
) error{OutOfMemory}![]feeds_ranking.FeedItem {
    // Propagate OOM rather than returning a static `&.{}`: the FFI frees the
    // result with c_allocator, and c_allocator.free() calls libc free()
    // unconditionally (no zero-len guard), so freeing a static pointer would
    // abort. On OOM, let the caller decide (the FFI sets an empty result).
    var feed_items = try allocator.alloc(feeds_ranking.FeedItem, items.len);
    for (items, 0..) |item, i| {
        feed_items[i] = .{
            .id = if (item.guid.len > 0) item.guid else item.link,
            .title = item.title,
            .body = item.description,
            .author_handle = if (item.author.len > 0) item.author else source_label,
            .source_platform = "rss",
            .timestamp = parseRssDate(item.pub_date, now_epoch),
            .has_image = item.image_url.len > 0,
            .image_url = if (item.image_url.len > 0) item.image_url else null,
        };
    }
    return feed_items;
}

/// Parse an RSS date string to epoch seconds. Handles the two shapes real
/// feeds emit — RFC822/1123 ("Mon, 15 Jan 2024 10:30:00 GMT") and ISO8601
/// ("2024-01-15T10:30:00Z", optional fractional seconds / numeric offset,
/// date-only) — plus lowercase/other weekdays harmlessly (weekday is not
/// consulted). Unparseable or missing dates fall back to `now_epoch` (the
/// documented intent: unknown dates are treated as recent; the old constant
/// 1e9 ≈ 2001 zeroed the recency term for every RSS item).
fn parseRssDate(date_str: []const u8, now_epoch: f64) f64 {
    const s = std.mem.trim(u8, date_str, " \t\n\r");
    if (s.len == 0) return now_epoch;

    // RFC822 starts with an optional weekday prefix "Www, " — skip it.
    var body = s;
    if (std.mem.indexOfScalar(u8, s, ',')) |comma| {
        if (comma <= 4) body = std.mem.trim(u8, s[comma + 1 ..], " \t");
    }

    if (parseRFC822(body)) |epoch| return epoch;
    if (parseISO8601(body)) |epoch| return epoch;
    // Some feeds emit "15 Jan 2024 10:30:00 -0000" without a weekday, or
    // ISO dates with a space separator — try the raw string too.
    if (body.ptr != s.ptr) {
        if (parseRFC822(s)) |epoch| return epoch;
        if (parseISO8601(s)) |epoch| return epoch;
    }
    return now_epoch;
}

/// "15 Jan 2024 10:30[:00] [GMT|+HHMM|UT]". Day may be space-padded (" 5").
fn parseRFC822(s: []const u8) ?f64 {
    var i: usize = 0;
    const day = parseIntBounds(s, &i, 1, 2) orelse return null;
    skipSpaces(s, &i);
    const month = parseMonthName(s, &i) orelse return null;
    skipSpaces(s, &i);
    const year = parseIntBounds(s, &i, 4, 4) orelse return null;
    skipSpaces(s, &i);
    const hour = parseIntBounds(s, &i, 1, 2) orelse return null;
    expectColon(s, &i) orelse return null;
    const minute = parseIntBounds(s, &i, 2, 2) orelse return null;
    var second: u32 = 0;
    if (expectColon(s, &i) != null) {
        second = parseIntBounds(s, &i, 2, 2) orelse return null;
    }
    skipSpaces(s, &i);
    const tz_offset = parseTZOffset(s, &i); // seconds to subtract

    if (month < 1 or month > 12 or day < 1 or day > 31) return null;
    if (hour > 23 or minute > 59 or second > 60) return null;

    const days = daysFromCivil(year, month, @intCast(day));
    const epoch_sec = days * 86400 + @as(i64, hour) * 3600 + @as(i64, minute) * 60 + @as(i64, second);
    return @floatFromInt(epoch_sec - tz_offset);
}

/// "2024-01-15[T ]10:30[:00[.f*]][Z|+HH[:]MM|-HH[:]MM]" or date-only
/// "2024-01-15".
fn parseISO8601(s: []const u8) ?f64 {
    if (s.len < 10) return null;
    if (s[4] != '-' or s[7] != '-') return null;
    const year = std.fmt.parseInt(i64, s[0..4], 10) catch return null;
    const month = std.fmt.parseInt(u32, s[5..7], 10) catch return null;
    const day = std.fmt.parseInt(u32, s[8..10], 10) catch return null;
    if (month < 1 or month > 12 or day < 1 or day > 31) return null;

    const days = daysFromCivil(year, month, @intCast(day));
    var epoch_sec = days * 86400;
    if (s.len == 10) return @floatFromInt(epoch_sec);

    // Time separator: 'T', 't' or space.
    if (s[10] != 'T' and s[10] != 't' and s[10] != ' ') return null;
    var i: usize = 11;
    const hour = parseIntBounds(s, &i, 2, 2) orelse return null;
    expectColon(s, &i) orelse return null;
    const minute = parseIntBounds(s, &i, 2, 2) orelse return null;
    var second: u32 = 0;
    if (expectColon(s, &i) != null) {
        second = parseIntBounds(s, &i, 2, 2) orelse return null;
        // Skip fractional seconds.
        if (i < s.len and s[i] == '.') {
            i += 1;
            while (i < s.len and std.ascii.isDigit(s[i])) i += 1;
        }
    }
    if (hour > 23 or minute > 59 or second > 60) return null;
    epoch_sec += @as(i64, hour) * 3600 + @as(i64, minute) * 60 + @as(i64, second);

    // Zone: Z | ±HH[:MM] | ±HHMM. Missing zone = local-naive; feeds use it
    // for UTC timestamps, so treat it as UTC (0 offset).
    var offset: i64 = 0;
    if (i < s.len) {
        if (s[i] == 'Z' or s[i] == 'z') {
            // UTC.
        } else if (s[i] == '+' or s[i] == '-') {
            const neg = s[i] == '-';
            i += 1;
            const oh = parseIntBounds(s, &i, 2, 2) orelse return null;
            var om: u32 = 0;
            if (i < s.len and s[i] == ':') {
                i += 1;
                om = parseIntBounds(s, &i, 2, 2) orelse return null;
            } else if (i + 2 <= s.len and std.ascii.isDigit(s[i])) {
                om = parseIntBounds(s, &i, 2, 2) orelse return null;
            }
            offset = @as(i64, oh) * 3600 + @as(i64, om) * 60;
            if (neg) offset = -offset;
        } else {
            return null; // trailing garbage
        }
    }
    return @floatFromInt(epoch_sec - offset);
}

/// Days since 1970-01-01 for a civil date (proleptic Gregorian). Howard
/// Hinnant's algorithm — valid for any year representable in i64.
fn daysFromCivil(y_in: i64, m: u32, d: u32) i64 {
    var y = y_in;
    if (m <= 2) y -= 1;
    const era = @divFloor(y, 400);
    const yoe = y - era * 400; // [0, 399]
    const mp = @mod(@as(i64, m) + 9, 12); // [0, 11], Mar=0
    const doy = @divFloor(153 * mp + 2, 5) + @as(i64, d) - 1; // [0, 365]
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy; // [0, 146096]
    return era * 146097 + doe - 719468;
}

fn parseMonthName(s: []const u8, i: *usize) ?u32 {
    const months = [_][]const u8{ "jan", "feb", "mar", "apr", "may", "jun", "jul", "aug", "sep", "oct", "nov", "dec" };
    if (i.* + 3 > s.len) return null;
    for (months, 0..) |m, idx| {
        if (std.ascii.eqlIgnoreCase(s[i.* .. i.* + 3], m)) {
            i.* += 3;
            return @intCast(idx + 1);
        }
    }
    return null;
}

/// Parse 1..max_digits digits (at least min_digits). Advances `i`.
fn parseIntBounds(s: []const u8, i: *usize, min_digits: usize, max_digits: usize) ?u32 {
    var n: usize = 0;
    var val: u32 = 0;
    while (i.* + n < s.len and n < max_digits and std.ascii.isDigit(s[i.* + n])) {
        val = val * 10 + (s[i.* + n] - '0');
        n += 1;
    }
    if (n < min_digits) return null;
    i.* += n;
    return val;
}

fn skipSpaces(s: []const u8, i: *usize) void {
    while (i.* < s.len and (s[i.*] == ' ' or s[i.*] == '\t')) i.* += 1;
}

/// Consume a ':' at `i` if present. Returns non-null when consumed.
fn expectColon(s: []const u8, i: *usize) ?void {
    if (i.* < s.len and s[i.*] == ':') {
        i.* += 1;
        return {};
    }
    return null;
}

/// Parse an RFC822 zone — "GMT"/"UT"/"UTC"/named (treated as 0; named
/// military zones are non-standard in feeds) or "+HHMM"/"-HHMM" — returning
/// the offset in seconds TO SUBTRACT from the local time to get UTC.
fn parseTZOffset(s: []const u8, i: *usize) i64 {
    if (i.* >= s.len) return 0;
    if (s[i.*] == '+' or s[i.*] == '-') {
        const neg = s[i.*] == '-';
        var j = i.* + 1;
        const hh = parseIntBounds(s, &j, 2, 2) orelse return 0;
        const mm = parseIntBounds(s, &j, 2, 2) orelse 0;
        i.* = j;
        var off: i64 = @as(i64, hh) * 3600 + @as(i64, mm) * 60;
        if (neg) off = -off;
        return off;
    }
    // Alphabetic zone name — GMT/UT/UTC and all named zones: treat as UTC.
    while (i.* < s.len and std.ascii.isAlphabetic(s[i.*])) i.* += 1;
    return 0;
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
    const feed_items = try toFeedItems(a, &items, "test-source", 1_700_000_000.0);
    defer a.free(feed_items);
    try testing.expectEqual(@as(usize, 1), feed_items.len);
    try testing.expectEqualStrings("Test", feed_items[0].title);
    try testing.expectEqualStrings("Body", feed_items[0].body);
    try testing.expectEqualStrings("rss", feed_items[0].source_platform);
    try testing.expectEqualStrings("guid1", feed_items[0].id);
    // Empty pub_date falls back to now_epoch (treated as recent).
    try testing.expectEqual(@as(f64, 1_700_000_000.0), feed_items[0].timestamp);
    try testing.expectEqual(false, feed_items[0].has_image);
    try testing.expectEqual(@as(?[]const u8, null), feed_items[0].image_url);
}

test "stripCdata: handles CDATA wrapper" {
    try testing.expectEqualStrings("hello", stripCdata("<![CDATA[hello]]>"));
    try testing.expectEqualStrings("plain", stripCdata("plain"));
}

// ── Date parsing ─────────────────────────────────────────────────────────

test "parseRssDate: RFC822 with weekday and GMT zone" {
    // 2024-01-15 10:30:00 UTC = 1705314600
    try testing.expectEqual(@as(f64, 1705314600), parseRssDate("Mon, 15 Jan 2024 10:30:00 GMT", 0));
    // Without seconds.
    try testing.expectEqual(@as(f64, 1705314600), parseRssDate("Mon, 15 Jan 2024 10:30 GMT", 0));
}

test "parseRssDate: RFC822 numeric offsets" {
    // 15 Jan 2024 10:30:00 +0100 == 10:30 - 1h UTC = 1705311000
    try testing.expectEqual(@as(f64, 1705311000), parseRssDate("Mon, 15 Jan 2024 10:30:00 +0100", 0));
    // -0500 == 10:30 + 5h UTC = 1705332600
    try testing.expectEqual(@as(f64, 1705332600), parseRssDate("Mon, 15 Jan 2024 10:30:00 -0500", 0));
    // Space-padded single-digit day.
    try testing.expectEqual(@as(f64, 1705314600 - 14 * 86400), parseRssDate("Mon,  1 Jan 2024 10:30:00 GMT", 0));
}

test "parseRssDate: ISO8601 variants" {
    try testing.expectEqual(@as(f64, 1705314600), parseRssDate("2024-01-15T10:30:00Z", 0));
    try testing.expectEqual(@as(f64, 1705314600), parseRssDate("2024-01-15T10:30:00+00:00", 0));
    try testing.expectEqual(@as(f64, 1705314600 - 3600), parseRssDate("2024-01-15T10:30:00+01:00", 0));
    try testing.expectEqual(@as(f64, 1705314600), parseRssDate("2024-01-15T10:30:00.123Z", 0));
    // Date-only → midnight UTC.
    try testing.expectEqual(@as(f64, 1705276800), parseRssDate("2024-01-15", 0));
    // Lowercase t/z.
    try testing.expectEqual(@as(f64, 1705314600), parseRssDate("2024-01-15t10:30:00z", 0));
}

test "parseRssDate: unparseable falls back to now_epoch, not the year 2001" {
    // Regression: every date used to map to 1e9 (2001), zeroing recency.
    try testing.expectEqual(@as(f64, 42), parseRssDate("not a date", 42));
    try testing.expectEqual(@as(f64, 7), parseRssDate("", 7));
    try testing.expectEqual(@as(f64, 9), parseRssDate("   ", 9));
}

test "daysFromCivil: known epochs" {
    try testing.expectEqual(@as(i64, 0), daysFromCivil(1970, 1, 1));
    try testing.expectEqual(@as(i64, 19737), daysFromCivil(2024, 1, 15)); // 1705276800 / 86400
    // Leap year handling: 2024-02-29 exists; 2023-02-29 must not matter.
    try testing.expectEqual(daysFromCivil(2024, 3, 1) - 1, daysFromCivil(2024, 2, 29));
    try testing.expectEqual(daysFromCivil(1969, 12, 31), -1);
}

// ── Cover image extraction ───────────────────────────────────────────────

test "parseFeed: RSS media:thumbnail and media:content image extraction" {
    const a = testing.allocator;
    const xml =
        \\<rss><channel><item>
        \\<title>With media:thumbnail</title>
        \\<link>https://example.com/a</link>
        \\<media:thumbnail url="https://img.example.com/a.jpg" width="640" height="480"/>
        \\</item>
        \\<item>
        \\<title>With image media:content</title>
        \\<link>https://example.com/b</link>
        \\<media:content url="https://img.example.com/b.jpg" type="image/jpeg"/>
        \\</item>
        \\<item>
        \\<title>Video media:content must not be a cover</title>
        \\<link>https://example.com/c</link>
        \\<media:content url="https://vid.example.com/c.mp4" type="video/mp4"/>
        \\<media:thumbnail url="https://img.example.com/c.jpg"/>
        \\</item>
        \\<item>
        \\<title>Image enclosure</title>
        \\<link>https://example.com/d</link>
        \\<enclosure url="https://img.example.com/d.png" type="image/png" length="1000"/>
        \\</item>
        \\<item>
        \\<title>Audio enclosure must not be a cover</title>
        \\<link>https://example.com/e</link>
        \\<enclosure url="https://audio.example.com/e.mp3" type="audio/mpeg" length="1000"/>
        \\</item>
        \\<item>
        \\<title>img in description</title>
        \\<link>https://example.com/f</link>
        \\<description>&lt;p&gt;&lt;img src="https://img.example.com/f.jpg" alt="x"/&gt; Hello &lt;/p&gt;</description>
        \\</item>
        \\<item>
        \\<title>relative img must be ignored</title>
        \\<link>https://example.com/g</link>
        \\<description><![CDATA[<img src="/relative/g.jpg">]]&gt;</description>
        \\</item>
        \\</channel></rss>
    ;
    const items = try parseFeed(a, xml);
    defer freeRssItems(a, items);
    try testing.expectEqual(@as(usize, 7), items.len);
    try testing.expectEqualStrings("https://img.example.com/a.jpg", items[0].image_url);
    try testing.expectEqualStrings("https://img.example.com/b.jpg", items[1].image_url);
    // media:thumbnail wins even when a video media:content precedes it.
    try testing.expectEqualStrings("https://img.example.com/c.jpg", items[2].image_url);
    try testing.expectEqualStrings("https://img.example.com/d.png", items[3].image_url);
    try testing.expectEqualStrings("", items[4].image_url);
    try testing.expectEqualStrings("https://img.example.com/f.jpg", items[5].image_url);
    try testing.expectEqualStrings("", items[6].image_url);
}

test "parseFeed: Atom enclosure link image extraction" {
    const a = testing.allocator;
    const xml =
        \\<feed xmlns="http://www.w3.org/2005/Atom">
        \\<entry>
        \\<title>Atom with image enclosure</title>
        \\<link rel="alternate" href="https://example.com/a"/>
        \\<link rel="enclosure" type="image/jpeg" href="https://img.example.com/a.jpg"/>
        \\<summary>Some summary</summary>
        \\</entry>
        \\<entry>
        \\<title>Atom with media:thumbnail</title>
        \\<link rel="alternate" href="https://example.com/b"/>
        \\<media:thumbnail url="https://img.example.com/b.jpg"/>
        \\<summary>Some summary</summary>
        \\</entry>
        \\<entry>
        \\<title>Atom no image</title>
        \\<link rel="alternate" href="https://example.com/c"/>
        \\<summary>Plain</summary>
        \\</entry>
        \\</feed>
    ;
    const items = try parseFeed(a, xml);
    defer freeRssItems(a, items);
    try testing.expectEqual(@as(usize, 3), items.len);
    try testing.expectEqualStrings("https://img.example.com/a.jpg", items[0].image_url);
    try testing.expectEqualStrings("https://img.example.com/b.jpg", items[1].image_url);
    try testing.expectEqualStrings("", items[2].image_url);
}

test "extractAttrValue: boundary-matches attribute names" {
    const span = "<img data-src=\"x\" srcset=\"a 1x\" src=\"https://ok.example/i.jpg\"/>";
    try testing.expectEqualStrings("https://ok.example/i.jpg", extractAttrValue(span, "src").?);
    try testing.expect(extractAttrValue(span, "sr") == null);
    // Single quotes.
    try testing.expectEqualStrings("v", extractAttrValue("<t a='v'>", "a").?);
    try testing.expect(extractAttrValue("<t b=\"unquoted>", "a") == null);
}
