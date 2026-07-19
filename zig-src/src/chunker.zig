//! Line-based markdown chunker — splits documents into semantic chunks.
//!
//! Ports `src/memory/chunker.rs` (178 LOC + 18 tests). The Rust original splits
//! on markdown headings (`# `, `## `, `### `), then on blank lines (paragraphs),
//! then on line boundaries, respecting a max-token budget per chunk (~4 chars
//! per token). Heading context is preserved across splits.
//!
//! Pure string processing — no I/O, no allocator beyond the caller-provided one.
//! The returned chunks' `content` and `heading` slices are allocator-owned.

const std = @import("std");
const testing = std.testing;

/// A single chunk of text with metadata. Mirrors `Chunk` in chunker.rs:9.
/// `heading` mirrors Rust's `Option<Rc<str>>` — multiple chunks from the same
/// section share the heading slice (we dup once per section).
pub const Chunk = struct {
    index: usize,
    content: []const u8,
    heading: ?[]const u8 = null,
};

/// Split markdown text into chunks, each under `max_tokens` approximate tokens.
/// Mirrors `chunk_markdown` in `src/memory/chunker.rs:24`.
///
/// Strategy:
/// 1. Split on `# `/`## `/`### ` headings (deeper headings stay inline).
/// 2. If a section exceeds the budget, split on blank lines (paragraphs).
/// 3. If a paragraph still exceeds, split on line boundaries.
///
/// Token estimation: ~4 chars per token (rough English average). The caller
/// owns the returned slice and each chunk's `content`/`heading` strings.
pub fn chunk_markdown(
    allocator: std.mem.Allocator,
    text: []const u8,
    max_tokens: usize,
) ![]Chunk {
    if (isOnlyWhitespace(text)) return &.{};

    const max_chars = max_tokens * 4;
    const sections = try split_on_headings(allocator, text);
    defer {
        for (sections) |s| {
            if (s.heading) |h| allocator.free(h);
            allocator.free(s.body);
        }
        allocator.free(sections);
    }

    var chunks = std.ArrayList(Chunk).empty;
    // On success the items move into the returned slice; on error we must free
    // every chunk's owned strings. The `len = 0` at the success path makes the
    // defer a no-op for items while still freeing the ArrayList's backing store.
    defer chunks.deinit(allocator);
    errdefer {
        for (chunks.items) |c| {
            allocator.free(c.content);
            if (c.heading) |h| allocator.free(h);
        }
    }

    for (sections) |sec| {
        // Owns the heading once for the whole section; chunks dupe as needed.
        const heading_owned: ?[]const u8 = if (sec.heading) |h| try allocator.dupe(u8, h) else null;
        const full = if (heading_owned) |h|
            try std.fmt.allocPrint(allocator, "{s}\n{s}", .{ h, sec.body })
        else
            try allocator.dupe(u8, sec.body);
        defer allocator.free(full);

        if (full.len <= max_chars) {
            try chunks.append(allocator, .{
                .index = chunks.items.len,
                .content = try trimOwned(allocator, full),
                .heading = if (heading_owned) |h| try allocator.dupe(u8, h) else null,
            });
            if (heading_owned) |h| allocator.free(h);
            continue;
        }

        // Section exceeds budget — split on paragraphs (blank lines).
        const paragraphs = try split_on_blank_lines(allocator, sec.body);
        defer {
            for (paragraphs) |p| allocator.free(p);
            allocator.free(paragraphs);
        }

        var current = std.ArrayList(u8).empty;
        defer current.deinit(allocator);
        if (heading_owned) |h| {
            try current.appendSlice(allocator, h);
            try current.append(allocator, '\n');
        }

        for (paragraphs) |para| {
            const para_len: usize = para.len;
            if (current.items.len + para_len > max_chars and !isOnlyWhitespace(current.items)) {
                try chunks.append(allocator, .{
                    .index = chunks.items.len,
                    .content = try trimOwned(allocator, current.items),
                    .heading = if (heading_owned) |h| try allocator.dupe(u8, h) else null,
                });
                current.clearRetainingCapacity();
                if (heading_owned) |h| {
                    try current.appendSlice(allocator, h);
                    try current.append(allocator, '\n');
                }
            }

            if (para_len > max_chars) {
                // Paragraph too big — flush current, then split on lines.
                if (!isOnlyWhitespace(current.items)) {
                    try chunks.append(allocator, .{
                        .index = chunks.items.len,
                        .content = try trimOwned(allocator, current.items),
                        .heading = if (heading_owned) |h| try allocator.dupe(u8, h) else null,
                    });
                    current.clearRetainingCapacity();
                    if (heading_owned) |h| {
                        try current.appendSlice(allocator, h);
                        try current.append(allocator, '\n');
                    }
                }
                const line_chunks = try split_on_lines(allocator, para, max_chars);
                // Free each inner lc string AND the outer slice when done.
                defer {
                    for (line_chunks) |lc| allocator.free(lc);
                    allocator.free(line_chunks);
                }
                for (line_chunks) |lc| {
                    // Block scope so `trimmed` is freed per-iteration, not at fn exit.
                    const trimmed = try trimOwned(allocator, lc);
                    errdefer allocator.free(trimmed);
                    const content_owned = try allocator.dupe(u8, trimmed);
                    allocator.free(trimmed);
                    errdefer allocator.free(content_owned);
                    const heading_for_chunk: ?[]const u8 = if (heading_owned) |h| try allocator.dupe(u8, h) else null;
                    errdefer if (heading_for_chunk) |h| allocator.free(h);
                    try chunks.append(allocator, .{
                        .index = chunks.items.len,
                        .content = content_owned,
                        .heading = heading_for_chunk,
                    });
                }
            } else {
                try current.appendSlice(allocator, para);
                try current.append(allocator, '\n');
            }
        }

        if (!isOnlyWhitespace(current.items)) {
            try chunks.append(allocator, .{
                .index = chunks.items.len,
                .content = try trimOwned(allocator, current.items),
                .heading = if (heading_owned) |h| try allocator.dupe(u8, h) else null,
            });
        }
        if (heading_owned) |h| allocator.free(h);
    }

    // Filter out empty chunks, then re-index sequentially.
    var filtered = std.ArrayList(Chunk).empty;
    defer filtered.deinit(allocator);
    for (chunks.items) |c| {
        if (c.content.len == 0) {
            allocator.free(c.content);
            if (c.heading) |h| allocator.free(h);
            continue;
        }
        try filtered.append(allocator, c);
    }
    // Hand ownership to the final slice; reindex.
    const out = try filtered.toOwnedSlice(allocator);
    for (out, 0..) |*c, i| c.index = i;
    // The errdefer on `chunks` is now stale (we moved items out). Clear it.
    chunks.items.len = 0;
    return out;
}

/// Free a slice of chunks returned by `chunk_markdown`.
pub fn freeChunks(allocator: std.mem.Allocator, chunks: []Chunk) void {
    for (chunks) |c| {
        allocator.free(c.content);
        if (c.heading) |h| allocator.free(h);
    }
    allocator.free(chunks);
}

/// Split text into (heading, body) sections. Headings are lines starting with
/// `# `, `## `, or `### `; deeper levels stay inline as body. Mirrors
/// `split_on_headings` in chunker.rs:113.
fn split_on_headings(
    allocator: std.mem.Allocator,
    text: []const u8,
) ![]Section {
    var sections = std.ArrayList(Section).empty;
    errdefer {
        for (sections.items) |s| {
            if (s.heading) |h| allocator.free(h);
            allocator.free(s.body);
        }
        sections.deinit(allocator);
    }

    var current_heading: ?[]u8 = null;
    var current_body = std.ArrayList(u8).empty;
    defer current_body.deinit(allocator);

    var line_iter = std.mem.splitScalar(u8, text, '\n');
    while (line_iter.next()) |raw_line| {
        // Strip a trailing \r (CRLF input) to match Rust's `.lines()` semantics.
        const line = if (raw_line.len > 0 and raw_line[raw_line.len - 1] == '\r')
            raw_line[0 .. raw_line.len - 1]
        else
            raw_line;

        if (startsHeading(line)) {
            if (!isOnlyWhitespace(current_body.items) or current_heading != null) {
                try sections.append(allocator, .{
                    .heading = current_heading,
                    .body = try current_body.toOwnedSlice(allocator),
                });
                current_body = std.ArrayList(u8).empty;
            } else if (current_heading) |h| allocator.free(h);
            current_heading = try allocator.dupe(u8, line);
        } else {
            try current_body.appendSlice(allocator, line);
            try current_body.append(allocator, '\n');
        }
    }

    if (!isOnlyWhitespace(current_body.items) or current_heading != null) {
        try sections.append(allocator, .{
            .heading = current_heading,
            .body = try current_body.toOwnedSlice(allocator),
        });
    } else if (current_heading) |h| {
        allocator.free(h);
    }

    return sections.toOwnedSlice(allocator);
}

const Section = struct {
    heading: ?[]u8,
    body: []u8,
};

/// A line counts as a heading split point if it begins with exactly `# `, `## `,
/// or `### ` (followed by anything). `#### ` and deeper are NOT split points —
/// they stay inline as body content.
fn startsHeading(line: []const u8) bool {
    return std.mem.startsWith(u8, line, "# ") or
        std.mem.startsWith(u8, line, "## ") or
        std.mem.startsWith(u8, line, "### ") or
        std.mem.eql(u8, line, "#") or
        std.mem.eql(u8, line, "##") or
        std.mem.eql(u8, line, "###");
}

/// Split text on blank lines (paragraph boundaries). Mirrors
/// `split_on_blank_lines` in chunker.rs:138.
fn split_on_blank_lines(
    allocator: std.mem.Allocator,
    text: []const u8,
) ![][]u8 {
    var paragraphs = std.ArrayList([]u8).empty;
    errdefer {
        for (paragraphs.items) |p| allocator.free(p);
        paragraphs.deinit(allocator);
    }

    var current = std.ArrayList(u8).empty;
    defer current.deinit(allocator);

    var line_iter = std.mem.splitScalar(u8, text, '\n');
    while (line_iter.next()) |raw_line| {
        const line = if (raw_line.len > 0 and raw_line[raw_line.len - 1] == '\r')
            raw_line[0 .. raw_line.len - 1]
        else
            raw_line;

        if (isOnlyWhitespace(line)) {
            if (!isOnlyWhitespace(current.items)) {
                try paragraphs.append(allocator, try current.toOwnedSlice(allocator));
                current = std.ArrayList(u8).empty;
            }
        } else {
            try current.appendSlice(allocator, line);
            try current.append(allocator, '\n');
        }
    }

    if (!isOnlyWhitespace(current.items)) {
        try paragraphs.append(allocator, try current.toOwnedSlice(allocator));
    }
    return paragraphs.toOwnedSlice(allocator);
}

/// Split text on line boundaries to fit within `max_chars`. Mirrors
/// `split_on_lines` in chunker.rs:161.
fn split_on_lines(
    allocator: std.mem.Allocator,
    text: []const u8,
    max_chars: usize,
) ![][]u8 {
    var chunks = std.ArrayList([]u8).empty;
    errdefer {
        for (chunks.items) |c| allocator.free(c);
        chunks.deinit(allocator);
    }

    var current = std.ArrayList(u8).empty;
    defer current.deinit(allocator);

    var line_iter = std.mem.splitScalar(u8, text, '\n');
    while (line_iter.next()) |line| {
        if (current.items.len + line.len + 1 > max_chars and current.items.len > 0) {
            try chunks.append(allocator, try current.toOwnedSlice(allocator));
            current = std.ArrayList(u8).empty;
        }
        try current.appendSlice(allocator, line);
        try current.append(allocator, '\n');
    }

    if (current.items.len > 0) {
        try chunks.append(allocator, try current.toOwnedSlice(allocator));
    }
    return chunks.toOwnedSlice(allocator);
}

fn isOnlyWhitespace(s: []const u8) bool {
    for (s) |c| {
        if (c != ' ' and c != '\t' and c != '\n' and c != '\r' and c != 0x0c and c != 0x0b) return false;
    }
    return true;
}

/// Trim leading/trailing whitespace and return an allocator-owned slice.
fn trimOwned(allocator: std.mem.Allocator, s: []const u8) ![]u8 {
    const trimmed = std.mem.trim(u8, s, " \t\n\r\x0c\x0b");
    return allocator.dupe(u8, trimmed);
}

// ──────────────────────────────────────────────────────────────────────────
// Tests — verbatim ports of the 18 Rust tests at src/memory/chunker.rs:184-377.
// ──────────────────────────────────────────────────────────────────────────

test "empty_text" {
    const a = testing.allocator;
    const c1 = try chunk_markdown(a, "", 512);
    try testing.expectEqual(@as(usize, 0), c1.len);
    freeChunks(a, c1);
    const c2 = try chunk_markdown(a, "   ", 512);
    try testing.expectEqual(@as(usize, 0), c2.len);
    freeChunks(a, c2);
}

test "single_short_paragraph" {
    const a = testing.allocator;
    const chunks = try chunk_markdown(a, "Hello world", 512);
    defer freeChunks(a, chunks);
    try testing.expectEqual(@as(usize, 1), chunks.len);
    try testing.expectEqualStrings("Hello world", chunks[0].content);
    try testing.expect(chunks[0].heading == null);
}

test "heading_sections" {
    const a = testing.allocator;
    const text = "# Title\nSome intro.\n\n## Section A\nContent A.\n\n## Section B\nContent B.";
    const chunks = try chunk_markdown(a, text, 512);
    defer freeChunks(a, chunks);
    try testing.expect(chunks.len >= 3);
    // First chunk either has no heading or is the "# Title" heading itself.
    if (chunks[0].heading) |h| {
        try testing.expectEqualStrings("# Title", h);
    }
}

test "respects_max_tokens" {
    const a = testing.allocator;
    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(a);
    var i: usize = 0;
    while (i < 200) : (i += 1) {
        const line = try std.fmt.allocPrint(a, "This is sentence number {d} with some extra words to fill it up.\n", .{i});
        defer a.free(line);
        try buf.appendSlice(a, line);
    }
    const chunks = try chunk_markdown(a, buf.items, 50); // 50 tokens ≈ 200 chars
    defer freeChunks(a, chunks);
    try testing.expect(chunks.len > 1);
    for (chunks) |c| try testing.expect(c.content.len <= 300);
}

test "preserves_heading_in_split_sections" {
    const a = testing.allocator;
    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(a);
    try buf.appendSlice(a, "## Big Section\n");
    var i: usize = 0;
    while (i < 100) : (i += 1) {
        const line = try std.fmt.allocPrint(a, "Line {d} with some content here.\n\n", .{i});
        defer a.free(line);
        try buf.appendSlice(a, line);
    }
    const chunks = try chunk_markdown(a, buf.items, 50);
    defer freeChunks(a, chunks);
    try testing.expect(chunks.len > 1);
    for (chunks) |c| {
        if (c.heading) |h| try testing.expectEqualStrings("## Big Section", h);
    }
}

test "indexes_are_sequential" {
    const a = testing.allocator;
    const text = "# A\nContent A\n\n# B\nContent B\n\n# C\nContent C";
    const chunks = try chunk_markdown(a, text, 512);
    defer freeChunks(a, chunks);
    for (chunks, 0..) |c, idx| try testing.expectEqual(idx, c.index);
}

test "chunk_count_reasonable" {
    const a = testing.allocator;
    const text = "Hello world. This is a test document.";
    const chunks = try chunk_markdown(a, text, 512);
    defer freeChunks(a, chunks);
    try testing.expectEqual(@as(usize, 1), chunks.len);
}

test "headings_only_no_body" {
    const a = testing.allocator;
    const text = "# Title\n## Section A\n## Section B\n### Subsection";
    const chunks = try chunk_markdown(a, text, 512);
    defer freeChunks(a, chunks);
    try testing.expect(chunks.len > 0);
}

test "deeply_nested_headings_ignored" {
    const a = testing.allocator;
    const text = "# Top\nIntro\n#### Deep heading\nDeep content";
    const chunks = try chunk_markdown(a, text, 512);
    defer freeChunks(a, chunks);
    try testing.expect(chunks.len > 0);
    // "#### Deep heading" should stay with its parent section's body.
    var found_heading = false;
    var found_content = false;
    for (chunks) |c| {
        if (std.mem.indexOf(u8, c.content, "Deep heading") != null) found_heading = true;
        if (std.mem.indexOf(u8, c.content, "Deep content") != null) found_content = true;
    }
    try testing.expect(found_heading);
    try testing.expect(found_content);
}

test "very_long_single_line_no_newlines" {
    const a = testing.allocator;
    var buf = try a.alloc(u8, 5000 * 5);
    defer a.free(buf);
    var written: usize = 0;
    while (written + 5 <= buf.len) {
        @memcpy(buf[written .. written + 5], "word ");
        written += 5;
    }
    const chunks = try chunk_markdown(a, buf[0..written], 50);
    defer freeChunks(a, chunks);
    try testing.expect(chunks.len > 0);
}

test "only_newlines_and_whitespace" {
    const a = testing.allocator;
    const chunks = try chunk_markdown(a, "\n\n\n   \n\n", 512);
    defer freeChunks(a, chunks);
    try testing.expectEqual(@as(usize, 0), chunks.len);
}

test "max_tokens_zero" {
    const a = testing.allocator;
    const chunks = try chunk_markdown(a, "Hello world", 0);
    defer freeChunks(a, chunks);
    try testing.expect(chunks.len > 0);
}

test "max_tokens_one" {
    const a = testing.allocator;
    const text = "Line one\nLine two\nLine three";
    const chunks = try chunk_markdown(a, text, 1);
    defer freeChunks(a, chunks);
    try testing.expect(chunks.len > 0);
}

test "unicode_content" {
    const a = testing.allocator;
    const text = "# 日本語\nこんにちは世界\n\n## Émojis\n🦀 Rust is great 🚀";
    const chunks = try chunk_markdown(a, text, 512);
    defer freeChunks(a, chunks);
    try testing.expect(chunks.len > 0);
    var found_jp = false;
    var found_crab = false;
    for (chunks) |c| {
        if (std.mem.indexOf(u8, c.content, "こんにちは") != null) found_jp = true;
        if (std.mem.indexOf(u8, c.content, "🦀") != null) found_crab = true;
    }
    try testing.expect(found_jp);
    try testing.expect(found_crab);
}

test "fts5_special_chars_in_content" {
    const a = testing.allocator;
    const text = "Content with \"quotes\" and (parentheses) and * asterisks *";
    const chunks = try chunk_markdown(a, text, 512);
    defer freeChunks(a, chunks);
    try testing.expectEqual(@as(usize, 1), chunks.len);
    try testing.expect(std.mem.indexOf(u8, chunks[0].content, "\"quotes\"") != null);
}

test "multiple_blank_lines_between_paragraphs" {
    const a = testing.allocator;
    const text = "Paragraph one.\n\n\n\n\nParagraph two.\n\n\n\nParagraph three.";
    const chunks = try chunk_markdown(a, text, 512);
    defer freeChunks(a, chunks);
    try testing.expectEqual(@as(usize, 1), chunks.len);
    try testing.expect(std.mem.indexOf(u8, chunks[0].content, "Paragraph one") != null);
    try testing.expect(std.mem.indexOf(u8, chunks[0].content, "Paragraph three") != null);
}

test "heading_at_end_of_text" {
    const a = testing.allocator;
    const text = "Some content\n# Trailing Heading";
    const chunks = try chunk_markdown(a, text, 512);
    defer freeChunks(a, chunks);
    try testing.expect(chunks.len > 0);
}

test "single_heading_no_content" {
    const a = testing.allocator;
    const chunks = try chunk_markdown(a, "# Just a heading", 512);
    defer freeChunks(a, chunks);
    try testing.expectEqual(@as(usize, 1), chunks.len);
    try testing.expectEqualStrings("# Just a heading", chunks[0].heading.?);
}

test "no_content_loss" {
    const a = testing.allocator;
    const text = "# A\nContent A line 1\nContent A line 2\n\n## B\nContent B\n\n## C\nContent C";
    const chunks = try chunk_markdown(a, text, 512);
    defer freeChunks(a, chunks);
    var reassembled = std.ArrayList(u8).empty;
    defer reassembled.deinit(a);
    for (chunks) |c| {
        try reassembled.appendSlice(a, c.content);
        try reassembled.append(a, '\n');
    }
    const words = [_][]const u8{ "Content", "line", "1", "2" };
    for (words) |w| {
        try testing.expect(std.mem.indexOf(u8, reassembled.items, w) != null);
    }
}
