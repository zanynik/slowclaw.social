//! Saved items + content filtering.
//!
//! Ports `web/src/lib/savedItems.ts` (239 LOC) + `web/src/lib/feedFilter.ts`
//! (264 LOC) from TypeScript to Zig. Moves bookmarking, liking, and the
//! Nostr/content quality filter from the frontend into the Zig core.

const std = @import("std");
const testing = std.testing;

// ── Saved items (bookmarking) ─────────────────────────────────────────────

/// A saved/bookmarked feed item. Mirrors the TS `SavedItem`.
pub const SavedItem = struct {
    id: []const u8,
    source: []const u8, // "nostr" | "reads" | "reels"
    saved_at: i64, // epoch ms
    title: []const u8 = "",
    body: []const u8 = "",
    author_handle: []const u8 = "",
    url: []const u8 = "",
};

/// In-memory saved-items store. The caller persists to SQLite or UserDefaults.
pub const SavedItems = struct {
    allocator: std.mem.Allocator,
    items: std.ArrayList(SavedItem),
    liked_ids: std.StringHashMap(void),

    pub fn init(allocator: std.mem.Allocator) SavedItems {
        return .{
            .allocator = allocator,
            .items = std.ArrayList(SavedItem).empty,
            .liked_ids = std.StringHashMap(void).init(allocator),
        };
    }

    pub fn deinit(self: *SavedItems) void {
        for (self.items.items) |item| {
            self.allocator.free(item.id);
            self.allocator.free(item.source);
            self.allocator.free(item.title);
            self.allocator.free(item.body);
            self.allocator.free(item.author_handle);
            self.allocator.free(item.url);
        }
        self.items.deinit(self.allocator);
        var it = self.liked_ids.keyIterator();
        while (it.next()) |k| self.allocator.free(k.*);
        self.liked_ids.deinit();
    }

    pub fn isSaved(self: *const SavedItems, id: []const u8) bool {
        for (self.items.items) |item| {
            if (std.mem.eql(u8, item.id, id)) return true;
        }
        return false;
    }

    pub fn save(self: *SavedItems, item: SavedItem) !bool {
        if (self.isSaved(item.id)) return false;
        const owned: SavedItem = .{
            .id = try self.allocator.dupe(u8, item.id),
            .source = try self.allocator.dupe(u8, item.source),
            .saved_at = item.saved_at,
            .title = try self.allocator.dupe(u8, item.title),
            .body = try self.allocator.dupe(u8, item.body),
            .author_handle = try self.allocator.dupe(u8, item.author_handle),
            .url = try self.allocator.dupe(u8, item.url),
        };
        try self.items.append(self.allocator, owned);
        return true;
    }

    pub fn unsave(self: *SavedItems, id: []const u8) void {
        for (self.items.items, 0..) |item, i| {
            if (std.mem.eql(u8, item.id, id)) {
                self.allocator.free(item.id);
                self.allocator.free(item.source);
                self.allocator.free(item.title);
                self.allocator.free(item.body);
                self.allocator.free(item.author_handle);
                self.allocator.free(item.url);
                _ = self.items.orderedRemove(i);
                return;
            }
        }
    }

    /// Toggle saved state. Returns true if now saved, false if removed.
    pub fn toggleSaved(self: *SavedItems, item: SavedItem) !bool {
        if (self.isSaved(item.id)) {
            self.unsave(item.id);
            return false;
        }
        _ = try self.save(item);
        return true;
    }

    /// Get all saved items sorted newest-first.
    pub fn getSaved(self: *const SavedItems) []const SavedItem {
        // Items are appended in order; caller can sort by saved_at desc.
        return self.items.items;
    }

    pub fn isLiked(self: *const SavedItems, id: []const u8) bool {
        return self.liked_ids.contains(id);
    }

    pub fn setLiked(self: *SavedItems, id: []const u8, liked: bool) !void {
        if (liked) {
            if (!self.liked_ids.contains(id)) {
                const owned = try self.allocator.dupe(u8, id);
                try self.liked_ids.put(owned, {});
            }
        } else {
            if (self.liked_ids.fetchRemove(id)) |kv| {
                self.allocator.free(kv.key);
            }
        }
    }
};

// ── Content quality filtering (feedFilter.ts) ─────────────────────────────

/// Unicode script classification. Mirrors the TS `Script` type.
pub const Script = enum {
    latin,
    cjk,
    kana,
    hangul,
    cyrillic,
    arabic,
    hebrew,
    thai,
    devanagari,
    other,
};

/// Classify the dominant script of text by scanning codepoints.
/// Emoji and ASCII punctuation/digits are neutral. Mirrors `detectScript`.
pub fn detectScript(text: []const u8) Script {
    if (text.len == 0) return .latin;

    var counts = [_]u32{0} ** 10;
    var i: usize = 0;
    const limit = @min(text.len, 400 * 4); // first ~400 chars
    while (i < limit) {
        const len = std.unicode.utf8ByteSequenceLength(text[i]) catch {
            i += 1;
            continue;
        };
        if (i + len > text.len) break;
        const cp = std.unicode.utf8Decode(text[i .. i + len]) catch {
            i += len;
            continue;
        };
        i += len;

        if (cp <= 0x7f) {
            if ((cp >= 'a' and cp <= 'z') or (cp >= 'A' and cp <= 'Z')) counts[@intFromEnum(Script.latin)] += 1;
            continue;
        }
        if (cp >= 0x1f000) continue; // emoji
        if (cp >= 0x4e00 and cp <= 0x9fff) { counts[@intFromEnum(Script.cjk)] += 1; continue; }
        if (cp >= 0x3040 and cp <= 0x30ff) { counts[@intFromEnum(Script.kana)] += 1; continue; }
        if (cp >= 0xac00 and cp <= 0xd7af) { counts[@intFromEnum(Script.hangul)] += 1; continue; }
        if (cp >= 0x0400 and cp <= 0x04ff) { counts[@intFromEnum(Script.cyrillic)] += 1; continue; }
        if (cp >= 0x0600 and cp <= 0x06ff) { counts[@intFromEnum(Script.arabic)] += 1; continue; }
        if (cp >= 0x0590 and cp <= 0x05ff) { counts[@intFromEnum(Script.hebrew)] += 1; continue; }
        if (cp >= 0x0e00 and cp <= 0x0e7f) { counts[@intFromEnum(Script.thai)] += 1; continue; }
        if (cp >= 0x0900 and cp <= 0x097f) { counts[@intFromEnum(Script.devanagari)] += 1; continue; }
    }

    // Find the dominant non-latin script.
    var best: Script = .latin;
    var best_count: u32 = counts[@intFromEnum(Script.latin)];
    for ([_]Script{ .cjk, .kana, .hangul, .cyrillic, .arabic, .hebrew, .thai, .devanagari, .other }) |s| {
        if (counts[@intFromEnum(s)] > best_count) {
            best_count = counts[@intFromEnum(s)];
            best = s;
        }
    }
    return best;
}

/// Check if text is predominantly Latin script. Mirrors `isLatinText`.
pub fn isLatinText(text: []const u8) bool {
    return detectScript(text) == .latin;
}

/// Spam classification reason. Mirrors the TS `SpamReason`.
pub const SpamReason = enum {
    empty,
    too_short,
    content_warning,
    hashtag_spam,
    url_only,
    bot_template,
};

/// Classify text as spam/low-quality. Returns null if clean.
/// Simplified version of the TS `classifyNostrSpam` (no tags input — caller
/// strips content-warning before calling if needed).
pub fn classifySpam(text: []const u8) ?SpamReason {
    const t = std.mem.trim(u8, text, " \t\n\r");
    if (t.len == 0) return .empty;
    if (t.len < 3) return .too_short;

    // Count hashtags.
    var hashtag_count: usize = 0;
    var i: usize = 0;
    while (i < t.len) {
        if (t[i] == '#') {
            var j = i + 1;
            while (j < t.len and (std.ascii.isAlphanumeric(t[j]) or t[j] == '_')) j += 1;
            if (j - i >= 3) hashtag_count += 1;
            i = j;
        } else i += 1;
    }
    if (hashtag_count > 6) return .hashtag_spam;

    // URL-only check: strip URLs + hashtags + whitespace, if <3 chars left → spam.
    var stripped_len: usize = 0;
    var si: usize = 0;
    while (si < t.len) {
        // Skip URLs.
        if (si + 7 < t.len and std.mem.startsWith(u8, t[si..], "http://")) {
            while (si < t.len and t[si] != ' ') si += 1;
            continue;
        }
        if (si + 8 < t.len and std.mem.startsWith(u8, t[si..], "https://")) {
            while (si < t.len and t[si] != ' ') si += 1;
            continue;
        }
        // Skip hashtags.
        if (t[si] == '#') {
            si += 1;
            while (si < t.len and (std.ascii.isAlphanumeric(t[si]) or t[si] == '_')) si += 1;
            continue;
        }
        // Count non-whitespace, non-punct.
        if (std.ascii.isAlphanumeric(t[si])) stripped_len += 1;
        si += 1;
    }
    if (stripped_len < 3) return .url_only;

    // Bot templates.
    if (startsWithCI(t, "block found!")) return .bot_template;
    if (startsWithCI(t, "network: testnet")) return .bot_template;
    if (startsWithCI(t, "lightning address")) return .bot_template;

    return null;
}

fn startsWithCI(haystack: []const u8, needle: []const u8) bool {
    if (haystack.len < needle.len) return false;
    for (needle, 0..) |ch, i| {
        if (std.ascii.toLower(haystack[i]) != std.ascii.toLower(ch)) return false;
    }
    return true;
}

// ──────────────────────────────────────────────────────────────────────────
// Tests
// ──────────────────────────────────────────────────────────────────────────

test "SavedItems: save + isSaved + unsave" {
    var store = SavedItems.init(testing.allocator);
    defer store.deinit();

    try testing.expect(!store.isSaved("a"));
    _ = try store.save(.{ .id = "a", .source = "nostr", .saved_at = 1000, .title = "Test" });
    try testing.expect(store.isSaved("a"));
    try testing.expectEqual(@as(usize, 1), store.getSaved().len);

    // Duplicate save returns false.
    try testing.expect(!try store.save(.{ .id = "a", .source = "nostr", .saved_at = 1000 }));

    store.unsave("a");
    try testing.expect(!store.isSaved("a"));
}

test "SavedItems: toggleSaved" {
    var store = SavedItems.init(testing.allocator);
    defer store.deinit();

    const now_saved = try store.toggleSaved(.{ .id = "x", .source = "reads", .saved_at = 1000 });
    try testing.expect(now_saved);
    try testing.expect(store.isSaved("x"));

    const now_removed = try store.toggleSaved(.{ .id = "x", .source = "reads", .saved_at = 1000 });
    try testing.expect(!now_removed);
    try testing.expect(!store.isSaved("x"));
}

test "SavedItems: liked IDs" {
    var store = SavedItems.init(testing.allocator);
    defer store.deinit();

    try testing.expect(!store.isLiked("p1"));
    try store.setLiked("p1", true);
    try testing.expect(store.isLiked("p1"));
    try store.setLiked("p1", false);
    try testing.expect(!store.isLiked("p1"));
}

test "detectScript: English → latin" {
    try testing.expectEqual(Script.latin, detectScript("Hello world, this is English."));
}

test "detectScript: CJK → cjk" {
    try testing.expectEqual(Script.cjk, detectScript("你好世界"));
}

test "detectScript: Cyrillic → cyrillic" {
    try testing.expectEqual(Script.cyrillic, detectScript("Привет мир"));
}

test "detectScript: emoji-heavy English → latin" {
    try testing.expectEqual(Script.latin, detectScript("🦀 Rust is great 🚀"));
}

test "isLatinText: English passes, CJK fails" {
    try testing.expect(isLatinText("Hello world"));
    try testing.expect(!isLatinText("你好世界"));
}

test "classifySpam: empty returns spam" {
    try testing.expect(classifySpam("") != null);
    try testing.expect(classifySpam("   ") != null);
}

test "classifySpam: too short" {
    try testing.expectEqual(SpamReason.too_short, classifySpam("ab").?);
}

test "classifySpam: clean text passes" {
    try testing.expect(classifySpam("This is a thoughtful post about programming.") == null);
}

test "classifySpam: hashtag spam" {
    var many_tags = std.ArrayList(u8).empty;
    defer many_tags.deinit(testing.allocator);
    many_tags.appendSlice(testing.allocator, "check this out ") catch unreachable;
    for (0..8) |_| {
        many_tags.appendSlice(testing.allocator, "#spam ") catch unreachable;
    }
    try testing.expectEqual(SpamReason.hashtag_spam, classifySpam(many_tags.items).?);
}

test "classifySpam: URL-only" {
    try testing.expectEqual(SpamReason.url_only, classifySpam("https://spam.link").?);
}

test "classifySpam: bot template" {
    try testing.expectEqual(SpamReason.bot_template, classifySpam("Block found! Hash: 000000").?);
}
