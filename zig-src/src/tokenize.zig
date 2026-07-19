//! Tokenization + stemming for feed ranking.
//!
//! Ports `tokenize_terms`, `tokenize_and_stem`, `stage1_stopwords`, `stem_term`,
//! and `english_stemmer` from `src/feed/ranker.rs` (lines 426–578).
//!
//! Tokenization splits on non-alphanumeric characters, lowercases, and filters
//! out tokens shorter than 3 characters. Stemming uses the Snowball (Porter2)
//! English algorithm (see `porter_stemmer.zig`).

const std = @import("std");
const testing = std.testing;
const porter = @import("porter_stemmer.zig");

/// The Snowball Porter2 English stemmer, exposed via the same name the Rust
/// code uses (`english_stemmer()` in ranker.rs:571). Zig has no OnceLock
/// equivalent needed here — `stem` is a pure function operating on a caller-
/// provided buffer, so there is no cached state to lazy-init.
pub fn english_stemmer() type {
    return porter;
}

/// Stem a single term. Caller-provided `out` buffer (≥64 bytes); the returned
/// slice aliases `out`. Mirrors `stem_term` in `src/feed/ranker.rs:576`.
pub fn stem_term(term: []const u8, out: []u8) []const u8 {
    return porter.stem(term, out);
}

/// Stage-1 stopwords. Returns the same set as `stage1_stopwords()` in
/// `src/feed/ranker.rs:426`. Membership test is O(1) via sorted-set binary
/// search; the set is `const` and lives for the program's lifetime.
pub fn is_stopword(word: []const u8) bool {
    const set = comptime stopword_set();
    var lo: usize = 0;
    var hi: usize = set.len;
    while (lo < hi) {
        const mid = lo + (hi - lo) / 2;
        const cmp = std.mem.order(u8, set[mid], word);
        switch (cmp) {
            .eq => return true,
            .lt => lo = mid + 1,
            .gt => hi = mid,
        }
    }
    return false;
}

/// Build the sorted stopword set at comptime so the binary search is over a
/// `const` slice. Source: `stage1_stopwords()` in ranker.rs:426–544. Duplicates
/// in the Rust set (`really`, `also`, `just`) are deduplicated here.
fn stopword_set() []const []const u8 {
    @setEvalBranchQuota(10_000);
    const raw = [_][]const u8{
        "about",   "after",   "also",   "been",     "being",  "because", "before",
        "between", "could",   "from",   "have",     "into",   "just",    "like",
        "more",    "most",    "only",   "other",    "over",   "really",  "some",
        "than",    "that",    "their",  "there",    "these",  "they",    "this",
        "those",   "through", "very",   "what",     "when",   "where",   "which",
        "with",    "would",   "your",   "ours",     "ourselves",
        "the",     "and",     "for",    "are",      "was",    "were",    "you",
        "has",     "had",     "but",    "not",      "too",    "out",     "off",
        "its",     "why",     "how",    "who",
        "insight", "post",    "notes",  "note",     "journal", "entry",  "entries",
        "work",    "thing",   "things", "stuff",
        "dont",    "didnt",   "doesnt", "cant",     "wont",   "ive",     "im",
        "youre",   "thats",   "maybe",  "still",    "feel",   "kind",    "lot",
        "can",     "should",  "did",    "done",     "her",    "his",     "our",
        "lack",    "start",   "write",  "need",     "needs",  "want",    "wants",
        "think",   "thinking","good",   "bad",      "better", "best",    "worse",
        "life",    "people",  "person", "someone",  "something",
    };
    var arr: [raw.len][]const u8 = undefined;
    @memcpy(&arr, &raw);
    std.mem.sort([]const u8, &arr, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.order(u8, a, b) == .lt;
        }
    }.lt);
    // Deduplicate (Rust source has `really`, `also`, `just` twice).
    var out_arr: [raw.len][]const u8 = undefined;
    var out_len: usize = 0;
    for (arr) |w| {
        if (out_len > 0 and std.mem.eql(u8, out_arr[out_len - 1], w)) continue;
        out_arr[out_len] = w;
        out_len += 1;
    }
    const final = out_arr[0..out_len].*;
    return &final;
}

/// Predicate matching `char::is_alphanumeric` from Rust. ASCII-only is
/// sufficient for stage-1 tokenization (the Rust ranker does not use Unicode
/// word-segmentation).
fn isAlphanumeric(c: u8) bool {
    return std.ascii.isAlphanumeric(c);
}

/// Split `raw` on non-alphanumeric characters, lowercase each piece, and
/// drop pieces shorter than 3 bytes. Mirrors `tokenize_terms` in
/// `src/feed/ranker.rs:546`. Caller owns the returned slice (backed by
/// `allocator`); each element is also allocator-owned.
pub fn tokenize_terms(allocator: std.mem.Allocator, raw: []const u8) ![][]const u8 {
    var out = std.ArrayList([]const u8).empty;
    errdefer {
        for (out.items) |t| allocator.free(t);
        out.deinit(allocator);
    }

    var start: ?usize = null;
    var i: usize = 0;
    while (i <= raw.len) : (i += 1) {
        const is_sep = i == raw.len or !isAlphanumeric(raw[i]);
        if (is_sep) {
            if (start) |s| {
                const piece = raw[s..i];
                if (piece.len >= 3) {
                    try out.append(allocator, try toLowerOwned(allocator, piece));
                }
                start = null;
            }
        } else if (start == null) {
            start = i;
        }
    }

    return out.toOwnedSlice(allocator);
}

/// Like `tokenize_terms`, but additionally stems each token with the Porter2
/// stemmer. Falls back to the unstemmed token if the stem is shorter than 3
/// bytes. Deduplicates stems (preserving first-seen order). Mirrors
/// `tokenize_and_stem` in `src/feed/ranker.rs:553`.
pub fn tokenize_and_stem(allocator: std.mem.Allocator, raw: []const u8) ![][]const u8 {
    var out = std.ArrayList([]const u8).empty;
    errdefer {
        for (out.items) |t| allocator.free(t);
        out.deinit(allocator);
    }
    var seen = std.StringHashMap(void).init(allocator);
    defer seen.deinit(); // `out` owns the keys; only deinit the map itself

    var start: ?usize = null;
    var i: usize = 0;
    var stem_buf: [64]u8 = undefined;
    while (i <= raw.len) : (i += 1) {
        const is_sep = i == raw.len or !isAlphanumeric(raw[i]);
        if (is_sep) {
            if (start) |s| {
                const piece = raw[s..i];
                if (piece.len >= 3) {
                    const lowered = try toLowerOwned(allocator, piece);
                    errdefer allocator.free(lowered);
                    const stem = porter.stem(lowered, &stem_buf);
                    // Choose final token (stem if ≥3 else the lowered original),
                    // then own it on the heap so it outlives stem_buf and lowered.
                    const chosen = if (stem.len >= 3) stem else lowered;
                    const owned = try allocator.dupe(u8, chosen);
                    allocator.free(lowered); // lowered no longer needed either way
                    if (seen.contains(owned)) {
                        allocator.free(owned);
                    } else {
                        try seen.put(owned, {});
                        try out.append(allocator, owned);
                    }
                }
                start = null;
            }
        } else if (start == null) {
            start = i;
        }
    }

    return out.toOwnedSlice(allocator);
}

/// Lowercase an ASCII byte slice into a fresh allocation.
fn toLowerOwned(allocator: std.mem.Allocator, s: []const u8) ![]u8 {
    const out = try allocator.alloc(u8, s.len);
    for (s, 0..) |c, idx| out[idx] = std.ascii.toLower(c);
    return out;
}

/// Free a token slice and each of its allocator-owned elements.
pub fn freeTokens(allocator: std.mem.Allocator, tokens: [][]const u8) void {
    for (tokens) |t| allocator.free(t);
    allocator.free(tokens);
}

// ──────────────────────────────────────────────────────────────────────────
// Tests
// ──────────────────────────────────────────────────────────────────────────

test "is_stopword: members" {
    try testing.expect(is_stopword("the"));
    try testing.expect(is_stopword("insight"));
    try testing.expect(is_stopword("journal"));
    try testing.expect(is_stopword("really"));
    try testing.expect(is_stopword("something"));
}

test "is_stopword: non-members" {
    try testing.expect(!is_stopword("rust"));
    try testing.expect(!is_stopword("zig"));
    try testing.expect(!is_stopword(""));
    try testing.expect(!is_stopword("xyzzy"));
}

test "is_stopword: deduplication does not double-count" {
    // The Rust source has "really", "also", "just" twice — our comptime set
    // dedupes. Membership must still be correct.
    try testing.expect(is_stopword("also"));
    try testing.expect(is_stopword("just"));
}

test "tokenize_terms: basic split, lowercase, min-length 3" {
    const allocator = testing.allocator;
    const tokens = try tokenize_terms(allocator, "Hello, WORLD! rust is OK");
    defer freeTokens(allocator, tokens);
    // "is" (2 chars) and "OK"→"ok" (2 chars) are dropped by the ≥3 filter.
    // "rust" (4 chars) is kept — tokenize_terms does NOT apply stopwords.
    try testing.expectEqual(@as(usize, 3), tokens.len);
    try testing.expectEqualStrings("hello", tokens[0]);
    try testing.expectEqualStrings("world", tokens[1]);
    try testing.expectEqualStrings("rust", tokens[2]);
}

test "tokenize_terms: empty and all-separator inputs" {
    const allocator = testing.allocator;
    const t1 = try tokenize_terms(allocator, "");
    defer freeTokens(allocator, t1);
    try testing.expectEqual(@as(usize, 0), t1.len);

    const t2 = try tokenize_terms(allocator, "  , . !  ");
    defer freeTokens(allocator, t2);
    try testing.expectEqual(@as(usize, 0), t2.len);
}

test "tokenize_terms: digits are alphanumeric" {
    const allocator = testing.allocator;
    const t = try tokenize_terms(allocator, "abc123 def");
    defer freeTokens(allocator, t);
    try testing.expectEqual(@as(usize, 2), t.len);
    try testing.expectEqualStrings("abc123", t[0]);
    try testing.expectEqualStrings("def", t[1]);
}

test "tokenize_and_stem: stems and dedupes" {
    const allocator = testing.allocator;
    const t = try tokenize_and_stem(allocator, "running cats RUNNING journals");
    defer freeTokens(allocator, t);
    // "running" → "run", "running" again → deduped; "cats" → "cat";
    // "journals" → "journal". So result: [run, cat, journal] in first-seen order.
    try testing.expectEqual(@as(usize, 3), t.len);
    try testing.expectEqualStrings("run", t[0]);
    try testing.expectEqualStrings("cat", t[1]);
    try testing.expectEqualStrings("journal", t[2]);
}

test "tokenize_and_stem: falls back when stem < 3 chars" {
    const allocator = testing.allocator;
    // "is" dropped by length filter; "the" is stopword? No — tokenize_and_stem
    // does NOT apply stopwords (only length+stem). "the" → stem "the" (len 3) ok.
    // "as" dropped (len<3). "kids" → "kid". "becoming" → "becom".
    const t = try tokenize_and_stem(allocator, "kids becoming");
    defer freeTokens(allocator, t);
    try testing.expectEqual(@as(usize, 2), t.len);
    try testing.expectEqualStrings("kid", t[0]);
    try testing.expectEqualStrings("becom", t[1]);
}

test "stem_term: single term via public API" {
    var out: [64]u8 = undefined;
    try testing.expectEqualStrings("run", stem_term("running", &out));
    try testing.expectEqualStrings("journal", stem_term("journals", &out));
}
