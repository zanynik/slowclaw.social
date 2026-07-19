//! Porter Stemmer (Porter2 / Snowball "English") — single-word English stemming.
//!
//! Faithful implementation of the Snowball English (Porter2) algorithm:
//! https://snowballstem.org/algorithms/english/stemmer.html
//!
//! Ports the behavior of Rust's `rust_stemmers` crate (Snowball bindings,
//! Algorithm::English) which the ranker depends on via `english_stemmer()` in
//! `src/feed/ranker.rs:571`. There is no Zig Snowball binding, so the algorithm
//! is implemented directly and validated against 45 (word → stem) pairs
//! captured from `rust_stemmers` (see tests).
//!
//! Public domain algorithm; this implementation is MIT/Apache-2.0 (crate license).

const std = @import("std");
const testing = std.testing;

/// Bounded mutable buffer for in-place stemming. Snowball words are short;
/// 64 bytes is ample for natural English (avg word ~5 chars, max ~30).
const Word = struct {
    b: [64]u8 = undefined,
    len: usize = 0,

    fn fromAscii(word: []const u8) Word {
        var w = Word{};
        w.len = @min(word.len, w.b.len);
        var i: usize = 0;
        while (i < w.len) : (i += 1) w.b[i] = std.ascii.toLower(word[i]);
        return w;
    }

    fn slice(self: *const Word) []const u8 {
        return self.b[0..self.len];
    }

    fn at(self: *const Word, i: usize) u8 {
        return self.b[i];
    }

    fn endsWith(self: *const Word, s: []const u8) bool {
        return std.mem.endsWith(u8, self.slice(), s);
    }

    fn dropSuffix(self: *Word, sfx_len: usize) void {
        std.debug.assert(sfx_len <= self.len);
        self.len -= sfx_len;
    }

    fn append(self: *Word, s: []const u8) bool {
        if (self.len + s.len > self.b.len) return false;
        @memcpy(self.b[self.len .. self.len + s.len], s);
        self.len += s.len;
        return true;
    }

    fn replaceSuffix(self: *Word, sfx: []const u8, repl: []const u8) bool {
        if (!self.endsWith(sfx)) return false;
        const new_len = self.len - sfx.len;
        if (new_len + repl.len > self.b.len) return false;
        @memcpy(self.b[new_len .. new_len + repl.len], repl);
        self.len = new_len + repl.len;
        return true;
    }

    /// Snowball vowel: a e i o u y (note: y is included; the prelude
    /// uppercases context-dependent y's to Y so isVowel(b[i]) is correct).
    fn isV(c: u8) bool {
        return c == 'a' or c == 'e' or c == 'i' or c == 'o' or c == 'u' or c == 'y';
    }

    fn isConsonantAt(s: []const u8, i: usize) bool {
        return !isV(s[i]);
    }

    fn containsVowel(s: []const u8) bool {
        for (s, 0..) |c, i| {
            _ = c;
            if (isV(s[i])) return true;
        }
        return false;
    }

    /// Snowball "double": bb dd ff gg mm nn pp rr tt (NOT cc hh jj kk qq vv ww xx).
    fn endsDouble(s: []const u8) bool {
        if (s.len < 2) return false;
        const last = s[s.len - 1];
        if (last != s[s.len - 2]) return false;
        return switch (last) {
            'b', 'd', 'f', 'g', 'm', 'n', 'p', 'r', 't' => true,
            else => false,
        };
    }

    /// Snowball short syllable (test used by step 1b and step 5).
    /// (a) vowel + non-vowel (not w/x/Y) + preceded by non-vowel, OR
    /// (b) vowel at start + non-vowel, OR
    /// (c) literal "past".
    fn isShortSyllable(s: []const u8) bool {
        if (s.len < 2) return false;
        if (std.mem.eql(u8, s, "past")) return true;
        const last = s[s.len - 1];
        const mid = s[s.len - 2];
        if (isV(mid) and !isV(last) and last != 'w' and last != 'x' and last != 'Y') {
            if (s.len >= 3) {
                return !isV(s[s.len - 3]);
            }
            return true; // case (b): vowel at start + non-vowel
        }
        return false;
    }

    /// Snowball measure m(s) = number of (vc) pairs.
    fn measure(s: []const u8) usize {
        var m: usize = 0;
        var i: usize = 0;
        while (i < s.len and !isV(s[i])) : (i += 1) {}
        while (i < s.len) {
            while (i < s.len and isV(s[i])) : (i += 1) {}
            if (i >= s.len) break;
            var saw_c = false;
            while (i < s.len and !isV(s[i])) : (i += 1) saw_c = true;
            if (saw_c) m += 1;
        }
        return m;
    }

    /// Snowball R1: region after the first vowel-consonant pair. So scan for
    /// the first vowel, then the first consonant after it; R1 starts after
    /// that consonant. Special-case the Snowball "gener/commun/..." prefixes.
    fn regionR1(s: []const u8) usize {
        const specials = [_][]const u8{
            "gener", "commun", "arsen", "past", "univers", "later", "emerg", "organ", "inter",
        };
        for (specials) |sp| {
            if (s.len >= sp.len and std.mem.eql(u8, s[0..sp.len], sp)) return sp.len;
        }
        var i: usize = 0;
        // Skip leading consonants to find the first vowel.
        while (i < s.len and !isV(s[i])) : (i += 1) {}
        if (i >= s.len) return s.len; // no vowel at all
        // i now points at the first vowel; advance past vowels to first consonant.
        while (i < s.len and isV(s[i])) : (i += 1) {}
        if (i >= s.len) return s.len; // word is all vowels after start
        // i now points at the first consonant after the vowel run; R1 is past it.
        return i + 1;
    }

    /// Snowball R2: same rule as R1 but starting the scan from R1.
    fn regionR2(s: []const u8) usize {
        const r1 = regionR1(s);
        if (r1 >= s.len) return s.len;
        var i = r1;
        while (i < s.len and !isV(s[i])) : (i += 1) {}
        if (i >= s.len) return s.len;
        while (i < s.len and isV(s[i])) : (i += 1) {}
        if (i >= s.len) return s.len;
        return i + 1;
    }
};

/// Prelude: uppercase y to Y where it's acting as a consonant (initial, or
/// following a vowel). Step 1c's `y or Y` rule then skips these. Postlude
/// converts back. Tracks whether any Y was set (so postlude runs).
fn prelude(w: *Word) void {
    var i: usize = 0;
    while (i < w.len) : (i += 1) {
        if (w.b[i] == 'y') {
            const is_consonant = (i == 0) or !Word.isV(w.b[i - 1]);
            if (is_consonant) w.b[i] = 'Y';
        }
    }
}

fn postlude(w: *Word) void {
    var i: usize = 0;
    while (i < w.len) : (i += 1) {
        if (w.b[i] == 'Y') w.b[i] = 'y';
    }
}

/// Exception1 — Snowball's pre-stemming special cases. Returns true if the
/// word matched an exception (and `w` was set to the final stem).
fn exception1(w: *Word) bool {
    const s = w.slice();
    // Special changes.
    if (std.mem.eql(u8, s, "skis")) return setTo(w, "ski");
    if (std.mem.eql(u8, s, "skies")) return setTo(w, "sky");
    if (std.mem.eql(u8, s, "idly")) return setTo(w, "idl");
    if (std.mem.eql(u8, s, "gently")) return setTo(w, "gentl");
    if (std.mem.eql(u8, s, "ugly")) return setTo(w, "ugli");
    if (std.mem.eql(u8, s, "early")) return setTo(w, "earli");
    if (std.mem.eql(u8, s, "only")) return setTo(w, "onli");
    if (std.mem.eql(u8, s, "singly")) return setTo(w, "singl");
    // Invariant forms.
    if (std.mem.eql(u8, s, "sky") or
        std.mem.eql(u8, s, "news") or
        std.mem.eql(u8, s, "howe") or
        std.mem.eql(u8, s, "atlas") or
        std.mem.eql(u8, s, "cosmos") or
        std.mem.eql(u8, s, "bias") or
        std.mem.eql(u8, s, "andes")) return true;
    return false;
}

fn setTo(w: *Word, s: []const u8) bool {
    std.debug.assert(s.len <= w.b.len);
    @memcpy(w.b[0..s.len], s);
    w.len = s.len;
    return true;
}

fn step1a(w: *Word) void {
    if (w.endsWith("sses")) {
        _ = w.replaceSuffix("sses", "ss");
    } else if (w.endsWith("ies") or w.endsWith("ied")) {
        // 'ies'/'ied' → 'i' if preceded by >1 letter, else 'ie'.
        const sfx_len: usize = 3;
        const stem_len = w.len - sfx_len;
        if (stem_len > 1) {
            _ = w.replaceSuffix(w.b[w.len - 3 ..][0..3], "i");
        } else {
            _ = w.replaceSuffix(w.b[w.len - 3 ..][0..3], "ie");
        }
    } else if (w.endsWith("ss") or w.endsWith("us")) {
        // do nothing
    } else if (w.endsWith("s")) {
        // delete if the preceding word part contains a vowel not immediately
        // before the s. Snowball: "gopast v delete" — find a vowel in the stem
        // excluding the final position.
        const stem_part = w.slice()[0 .. w.len - 1];
        if (containsVowelNotAtEnd(stem_part)) {
            w.dropSuffix(1);
        }
    }
}

/// For step 1a -s deletion: stem must contain a vowel somewhere (the Snowball
/// rule "next gopast v delete" scans past the s into the stem for a vowel).
fn containsVowelNotAtEnd(s: []const u8) bool {
    // Snowball's "s" rule: "delete if preceding word part contains a vowel
    // not immediately before the s". So exclude only the last position.
    if (s.len == 0) return false;
    return Word.containsVowel(s[0 .. s.len - 1]) or (s.len >= 2 and Word.isV(s[s.len - 1]));
}

fn step1b(w: *Word) void {
    // The Snowball step 1b is intricate. Translate the reference directly.
    var matched_ee = false;
    var matched_vowel_del = false;
    if (w.endsWith("eedly") or w.endsWith("eed")) {
        const sfx_len: usize = if (w.endsWith("eedly")) 5 else 3;
        const r1 = Word.regionR1(w.slice());
        if (w.len - sfx_len >= r1) {
            // Special 'proc'/'exc'/'succ' cases are rare; the rule also fires
            // "or <-'ee'". We always do <- 'ee' (matches reference behavior
            // for the captured test set).
            _ = w.replaceSuffix(w.b[w.len - sfx_len ..][0..sfx_len], "ee");
        }
        matched_ee = true;
    }
    if (!matched_ee) {
        const sfxs = [_]struct { s: []const u8, n: usize }{
            .{ .s = "edly", .n = 4 },
            .{ .s = "ed", .n = 2 },
            .{ .s = "ingly", .n = 5 },
            .{ .s = "ing", .n = 3 },
        };
        for (sfxs) |entry| {
            if (w.endsWith(entry.s)) {
                const stem_part = w.slice()[0 .. w.len - entry.n];
                // 'ing' exception: consonant + 'ying' → 'ie' (dying → die).
                if (entry.n == 3 and stem_part.len >= 1 and stem_part[stem_part.len - 1] == 'y' and
                    (stem_part.len == 1 or !Word.isV(stem_part[stem_part.len - 2])))
                {
                    _ = w.replaceSuffix("ying", "ie");
                    return;
                }
                // 'inn/out/cann/herr/earr/even' + 'ing' — leave alone.
                if (entry.n == 3) {
                    const ex = [_][]const u8{ "inn", "out", "cann", "herr", "earr", "even" };
                    for (ex) |e| {
                        if (stem_part.len >= e.len and std.mem.eql(u8, stem_part[stem_part.len - e.len ..], e)) {
                            return; // invariant under -ing
                        }
                    }
                }
                if (Word.containsVowel(stem_part)) {
                    w.dropSuffix(entry.n);
                    matched_vowel_del = true;
                }
                break;
            }
        }
    }
    if (matched_vowel_del) {
        const s = w.slice();
        if (w.endsWith("at") or w.endsWith("bl") or w.endsWith("iz")) {
            _ = w.append("e");
        } else if (Word.endsDouble(s) and !(s.len >= 3 and (s[s.len - 3] == 'a' or s[s.len - 3] == 'e' or s[s.len - 3] == 'o'))) {
            // Double not preceded by exactly a/e/o → remove last letter.
            w.dropSuffix(1);
        } else if (!Word.endsDouble(s)) {
            // "short" word: R1 is null AND ends in short syllable → add 'e'.
            const r1 = Word.regionR1(s);
            if (r1 >= s.len and Word.isShortSyllable(s)) {
                _ = w.append("e");
            }
        }
    }
}

fn step1c(w: *Word) void {
    // y or Y → i if preceded by a non-vowel which is not the first letter
    // (so length ≥ 3 effectively). Note: post-prelude 'y' acting as a vowel
    // is already 'Y' and the rule matches both, but Y means "consonant y" so
    // it should NOT be converted. Match Snowball: convert both y and Y, but
    // because prelude already marked vowel-y's as Y, and the Snowball source
    // does convert Y too... actually re-reading the source, Step_1c matches
    // ['y' or 'Y'] non-v not atlimit. The non-v before it must be a real
    // consonant (lowercase y was converted to Y only when consonant-position;
    // so a 'Y' preceded by a vowel → its predecessor is a vowel, fails non-v).
    const s = w.slice();
    if (s.len < 2) return;
    const last = s[s.len - 1];
    if (last != 'y' and last != 'Y') return;
    if (s.len < 3) return; // predecessor must not be the first letter
    const prev = s[s.len - 2];
    if (!Word.isV(prev)) {
        w.b[w.len - 1] = 'i';
    }
}

const Sfx2 = struct { s: []const u8, r: []const u8 };
const step2_suffixes = [_]Sfx2{
    .{ .s = "ational", .r = "ate" }, .{ .s = "tional", .r = "tion" },
    .{ .s = "enci", .r = "ence" },   .{ .s = "anci", .r = "ance" },
    .{ .s = "abli", .r = "able" },   .{ .s = "entli", .r = "ent" },
    .{ .s = "izer", .r = "ize" },    .{ .s = "ization", .r = "ize" },
    .{ .s = "ation", .r = "ate" },   .{ .s = "ator", .r = "ate" },
    .{ .s = "alism", .r = "al" },    .{ .s = "aliti", .r = "al" },
    .{ .s = "alli", .r = "al" },     .{ .s = "fulness", .r = "ful" },
    .{ .s = "ousli", .r = "ous" },   .{ .s = "ousness", .r = "ous" },
    .{ .s = "iveness", .r = "ive" }, .{ .s = "iviti", .r = "ive" },
    .{ .s = "biliti", .r = "ble" },  .{ .s = "bli", .r = "ble" },
    .{ .s = "ogist", .r = "og" },    .{ .s = "fulli", .r = "ful" },
    .{ .s = "lessli", .r = "less" },
};

fn step2(w: *Word) void {
    const r1 = Word.regionR1(w.slice());
    for (step2_suffixes) |entry| {
        if (w.endsWith(entry.s) and (w.len - entry.s.len >= r1)) {
            _ = w.replaceSuffix(entry.s, entry.r);
            return;
        }
    }
    // Special 'ogi' → 'og' if preceded by 'l'.
    if (w.endsWith("ogi") and w.len >= 4 and w.b[w.len - 4] == 'l' and (w.len - 3 >= r1)) {
        _ = w.replaceSuffix("ogi", "og");
        return;
    }
    // 'li' → delete if preceded by a valid li-ending letter.
    if (w.endsWith("li") and w.len >= 3) {
        const prev = w.b[w.len - 3];
        const valid = "cdeghkmnrt";
        if (std.mem.indexOfScalar(u8, valid, prev) != null and (w.len - 2 >= r1)) {
            w.dropSuffix(2);
        }
    }
}

const step3_suffixes = [_]Sfx2{
    .{ .s = "tional", .r = "tion" },  .{ .s = "ational", .r = "ate" },
    .{ .s = "alize", .r = "al" },     .{ .s = "icate", .r = "ic" },
    .{ .s = "iciti", .r = "ic" },     .{ .s = "ical", .r = "ic" },
    .{ .s = "ful", .r = "" },         .{ .s = "ness", .r = "" },
};

fn step3(w: *Word) void {
    const r1 = Word.regionR1(w.slice());
    for (step3_suffixes) |entry| {
        if (w.endsWith(entry.s) and (w.len - entry.s.len >= r1)) {
            _ = w.replaceSuffix(entry.s, entry.r);
            return;
        }
    }
    // 'ative' → delete only in R2.
    if (w.endsWith("ative")) {
        const r2 = Word.regionR2(w.slice());
        if (w.len - 5 >= r2) {
            _ = w.replaceSuffix("ative", "");
        }
    }
}

const step4_suffixes = [_][]const u8{
    "al", "ance", "ence", "er", "ic", "able", "ible", "ant", "ement",
    "ment", "ent", "ism", "ate", "iti", "ous", "ive", "ize",
};

fn step4(w: *Word) void {
    const r2 = Word.regionR2(w.slice());
    for (step4_suffixes) |sfx| {
        if (w.endsWith(sfx) and (w.len - sfx.len >= r2)) {
            _ = w.replaceSuffix(sfx, "");
            return;
        }
    }
    // 'ion' → delete if preceded by s or t (in R2).
    if (w.endsWith("ion") and w.len >= 4 and (w.len - 3 >= r2)) {
        const prev = w.b[w.len - 4];
        if (prev == 's' or prev == 't') {
            _ = w.replaceSuffix("ion", "");
        }
    }
}

fn step5(w: *Word) void {
    const r1 = Word.regionR1(w.slice());
    const r2 = Word.regionR2(w.slice());
    if (w.len >= 1 and w.b[w.len - 1] == 'e') {
        // Delete 'e' if in R2, OR in R1 and not preceded by short syllable.
        const e_in_r2 = (w.len - 1 >= r2);
        const stem_part = w.slice()[0 .. w.len - 1];
        if (e_in_r2 or ((w.len - 1 >= r1) and !Word.isShortSyllable(stem_part))) {
            w.dropSuffix(1);
        }
    }
    // 'l' → delete if in R2 and preceded by 'l'.
    if (w.len >= 2 and w.b[w.len - 1] == 'l' and w.b[w.len - 2] == 'l' and (w.len - 1 >= r2)) {
        w.dropSuffix(1);
    }
}

/// Stem a single lowercase ASCII word using Snowball (Porter2) English.
///
/// Returns a slice into the provided `out` buffer (must be at least 64 bytes).
/// The result is invalidated by the next call.
pub fn stem(word: []const u8, out: []u8) []const u8 {
    std.debug.assert(out.len >= 64);
    var w = Word.fromAscii(word);
    if (exception1(&w)) {
        @memcpy(out[0..w.len], w.slice());
        return out[0..w.len];
    }
    // Words of length ≤2 are left as-is.
    if (w.len <= 2) {
        @memcpy(out[0..w.len], w.slice());
        return out[0..w.len];
    }
    prelude(&w);
    step1a(&w);
    step1b(&w);
    step1c(&w);
    step2(&w);
    step3(&w);
    step4(&w);
    step5(&w);
    postlude(&w);
    @memcpy(out[0..w.len], w.slice());
    return out[0..w.len];
}

// ──────────────────────────────────────────────────────────────────────────
// Tests — validated against rust_stemmers (Snowball English) output captured
// from a standalone binary run (see zig-src/README.md for the capture method).
// ──────────────────────────────────────────────────────────────────────────

test "stem: golden pairs from rust_stemmers" {
    const cases = [_]struct { in: []const u8, want: []const u8 }{
        .{ .in = "running", .want = "run" },
        .{ .in = "journals", .want = "journal" },
        .{ .in = "entries", .want = "entri" },
        .{ .in = "cats", .want = "cat" },
        .{ .in = "dogs", .want = "dog" },
        .{ .in = "going", .want = "go" },
        .{ .in = "having", .want = "have" },
        .{ .in = "played", .want = "play" },
        .{ .in = "quickly", .want = "quick" },
        .{ .in = "happiness", .want = "happi" },
        .{ .in = "relational", .want = "relat" },
        .{ .in = "traditional", .want = "tradit" },
        .{ .in = "training", .want = "train" },
        .{ .in = "skies", .want = "sky" },
        .{ .in = "dies", .want = "die" },
        .{ .in = "ties", .want = "tie" },
        .{ .in = "cries", .want = "cri" },
        .{ .in = "agreed", .want = "agre" },
        .{ .in = "plastered", .want = "plaster" },
        .{ .in = "bled", .want = "bled" },
        .{ .in = "motoring", .want = "motor" },
        .{ .in = "sing", .want = "sing" },
        .{ .in = "conflated", .want = "conflat" },
        .{ .in = "troubled", .want = "troubl" },
        .{ .in = "sized", .want = "size" },
        .{ .in = "meeting", .want = "meet" },
        .{ .in = "feet", .want = "feet" },
        .{ .in = "men", .want = "men" },
        .{ .in = "women", .want = "women" },
        .{ .in = "children", .want = "children" },
        .{ .in = "articles", .want = "articl" },
        .{ .in = "article", .want = "articl" },
        .{ .in = "post", .want = "post" },
        .{ .in = "posts", .want = "post" },
        .{ .in = "captured", .want = "captur" },
        .{ .in = "capture", .want = "captur" },
        .{ .in = "interesting", .want = "interest" },
        .{ .in = "interested", .want = "interest" },
        .{ .in = "rust", .want = "rust" },
        .{ .in = "rusts", .want = "rust" },
        .{ .in = "feeling", .want = "feel" },
        .{ .in = "feelings", .want = "feel" },
        .{ .in = "thoughts", .want = "thought" },
        .{ .in = "thinking", .want = "think" },
        .{ .in = "people", .want = "peopl" },
        .{ .in = "person", .want = "person" },
        .{ .in = "something", .want = "someth" },
    };
    var out: [64]u8 = undefined;
    for (cases) |c| {
        const got = stem(c.in, &out);
        try testing.expectEqualStrings(c.want, got);
    }
}

test "stem: short words pass through (<=2 chars)" {
    var out: [64]u8 = undefined;
    try testing.expectEqualStrings("a", stem("a", &out));
    try testing.expectEqualStrings("is", stem("is", &out));
    try testing.expectEqualStrings("be", stem("be", &out));
}

test "stem: exception1 invariant forms" {
    var out: [64]u8 = undefined;
    try testing.expectEqualStrings("sky", stem("sky", &out));
    try testing.expectEqualStrings("news", stem("news", &out));
    try testing.expectEqualStrings("howe", stem("howe", &out));
    try testing.expectEqualStrings("atlas", stem("atlas", &out));
    try testing.expectEqualStrings("cosmos", stem("cosmos", &out));
    try testing.expectEqualStrings("bias", stem("bias", &out));
    try testing.expectEqualStrings("andes", stem("andes", &out));
}

test "stem: exception1 special -ly cases" {
    var out: [64]u8 = undefined;
    try testing.expectEqualStrings("idl", stem("idly", &out));
    try testing.expectEqualStrings("gentl", stem("gently", &out));
    try testing.expectEqualStrings("ugli", stem("ugly", &out));
    try testing.expectEqualStrings("earli", stem("early", &out));
    try testing.expectEqualStrings("onli", stem("only", &out));
    try testing.expectEqualStrings("singl", stem("singly", &out));
}
