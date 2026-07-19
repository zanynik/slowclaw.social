//! Text utilities — UTF-8 safe truncation.
//!
//! Ported from `src/util.rs:35-44`. The Rust original uses `char_indices` to
//! operate on Unicode codepoints (not bytes), and trims trailing whitespace
//! from the truncated prefix before appending "...". This module reproduces
//! that behavior.

const std = @import("std");
const testing = std.testing;
const unicode = std.unicode;

/// Truncate `s` to at most `max_chars` Unicode codepoints. If truncation
/// occurs, trailing whitespace is trimmed from the prefix and `"..."` is
/// appended. If `s` has `<= max_chars` codepoints, `s` is returned unchanged.
///
/// The returned slice is owned by `allocator`.
///
/// Mirrors `truncate_with_ellipsis` in `src/util.rs:35`.
pub fn truncate_with_ellipsis(
    allocator: std.mem.Allocator,
    s: []const u8,
    max_chars: usize,
) ![]u8 {
    // Walk codepoints via Utf8View; if s is invalid UTF-8, fall back to a
    // byte-count truncation (the Rust path also works on `&str`, which is
    // always valid UTF-8 — so this is a defensive default only).
    const view = unicode.Utf8View.init(s) catch {
        return truncateBytesFallback(allocator, s, max_chars);
    };

    // Find the byte offset where the (max_chars)-th codepoint (0-indexed)
    // begins. Mirrors Rust's `char_indices().nth(max_chars)`, which returns
    // `Some((byte_offset, ch))` for the char at 0-based position `max_chars`;
    // we keep `s[..byte_offset]`.
    var it = view.iterator();
    var count: usize = 0;
    var cut_byte_idx: ?usize = null;
    while (it.nextCodepointSlice()) |slice| {
        if (count == max_chars) {
            // `slice.ptr` points into `s`; its offset is the byte position
            // where this codepoint begins — exactly Rust's `idx`.
            cut_byte_idx = @intFromPtr(slice.ptr) - @intFromPtr(s.ptr);
            break;
        }
        count += 1;
    }

    const cut = cut_byte_idx orelse return allocator.dupe(u8, s);
    const prefix = std.mem.trimEnd(u8, s[0..cut], " \t\n\r\x0c\x0b");

    var out = try allocator.alloc(u8, prefix.len + 3);
    @memcpy(out[0..prefix.len], prefix);
    out[prefix.len] = '.';
    out[prefix.len + 1] = '.';
    out[prefix.len + 2] = '.';
    return out;
}

/// Defensive fallback for non-UTF-8 input (the Rust API contract assumes &str,
/// so this never triggers on the happy path; we still avoid crashing).
fn truncateBytesFallback(
    allocator: std.mem.Allocator,
    s: []const u8,
    max_chars: usize,
) ![]u8 {
    if (s.len <= max_chars) return allocator.dupe(u8, s);
    const prefix = std.mem.trimEnd(u8, s[0..max_chars], " \t\n\r\x0c\x0b");
    var out = try allocator.alloc(u8, prefix.len + 3);
    @memcpy(out[0..prefix.len], prefix);
    out[prefix.len] = '.';
    out[prefix.len + 1] = '.';
    out[prefix.len + 2] = '.';
    return out;
}

// ──────────────────────────────────────────────────────────────────────────
// Tests — cases drawn from the Rust docstring at src/util.rs:19-34.
// ──────────────────────────────────────────────────────────────────────────

test "truncate: ascii no truncation" {
    const allocator = testing.allocator;
    const out = try truncate_with_ellipsis(allocator, "hello", 10);
    defer allocator.free(out);
    try testing.expectEqualStrings("hello", out);
}

test "truncate: ascii truncation" {
    const allocator = testing.allocator;
    const out = try truncate_with_ellipsis(allocator, "hello world", 5);
    defer allocator.free(out);
    try testing.expectEqualStrings("hello...", out);
}

test "truncate: multibyte emoji safe cut" {
    // "Hello 🦀 World" — 🦀 is one codepoint (4 bytes in UTF-8). Cutting at
    // 8 codepoints keeps "Hello 🦀" (no trailing space yet), then "...".
    const allocator = testing.allocator;
    const out = try truncate_with_ellipsis(allocator, "Hello 🦀 World", 8);
    defer allocator.free(out);
    try testing.expectEqualStrings("Hello 🦀...", out);
}

test "truncate: pure emoji cut" {
    const allocator = testing.allocator;
    const out = try truncate_with_ellipsis(allocator, "😀😀😀😀", 2);
    defer allocator.free(out);
    try testing.expectEqualStrings("😀😀...", out);
}

test "truncate: empty string" {
    const allocator = testing.allocator;
    const out = try truncate_with_ellipsis(allocator, "", 10);
    defer allocator.free(out);
    try testing.expectEqualStrings("", out);
}

test "truncate: trailing whitespace trimmed before ellipsis" {
    // "hello    " cut at 9 chars → "hello   " → trim → "hello" → "hello..."
    const allocator = testing.allocator;
    const out = try truncate_with_ellipsis(allocator, "hello    world", 9);
    defer allocator.free(out);
    try testing.expectEqualStrings("hello...", out);
}

test "truncate: max_chars zero" {
    const allocator = testing.allocator;
    const out = try truncate_with_ellipsis(allocator, "hello", 0);
    defer allocator.free(out);
    try testing.expectEqualStrings("...", out);
}

test "truncate: max_chars equal to length" {
    const allocator = testing.allocator;
    const out = try truncate_with_ellipsis(allocator, "hello", 5);
    defer allocator.free(out);
    // Exactly 5 codepoints, nth(5) is None → no truncation.
    try testing.expectEqualStrings("hello", out);
}

test "truncate: CJK multibyte safe cut" {
    // Each 中/文/字/测/试 is 3 bytes UTF-8, 1 codepoint. Cut at 2 → "中文..."
    const allocator = testing.allocator;
    const out = try truncate_with_ellipsis(allocator, "中文字测试", 2);
    defer allocator.free(out);
    try testing.expectEqualStrings("中文...", out);
}
