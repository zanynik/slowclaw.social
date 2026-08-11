//! On-device model catalog — the curated GGUF presets offered to the user.
//!
//! This is DATA, not logic. It lived in Swift (LocalModelPreset.presets) and
//! is promoted to the Zig core so every shell (iOS, Flutter, future) reads
//! the same catalog via the C ABI (slowclaw_feed_model_catalog_json). Keeping
//! it in Zig means a model-list change ships in one place and every shell
//! sees it without a per-shell code change.
//!
//! Format mirrors the Swift LocalModelPreset shape so the JSON decodes
//! directly into the existing Swift struct (and the future Dart one).

const std = @import("std");

/// One downloadable GGUF preset (text model, optionally with an audio mmproj).
pub const ModelPreset = struct {
    id: []const u8,
    title: []const u8,
    detail: []const u8,
    file_name: []const u8,
    download_url: []const u8,
    size_bytes: i64,
    size_label: []const u8,
    /// Optional audio multimodal projector (mmproj). Empty string = none.
    mmproj_file_name: []const u8 = "",
    mmproj_download_url: []const u8 = "",
    mmproj_size_label: []const u8 = "",
};

/// The curated catalog. Ordered smaller-first (matches the Swift order so
/// auto-activate picks the same default). Sources: unsloth Hugging Face GGUFs.
pub const PRESETS = [_]ModelPreset{
    .{
        .id = "unsloth/gemma-4-E2B-it-qat-UD-Q2_K_XL",
        .title = "Gemma 4 E2B (Q2_K_XL)",
        .detail = "Smaller, faster. ~2.1 GB. Best for older devices.",
        .file_name = "gemma-4-E2B-it-qat-UD-Q2_K_XL.gguf",
        .download_url = "https://huggingface.co/unsloth/gemma-4-E2B-it-qat-GGUF/resolve/main/gemma-4-E2B-it-qat-UD-Q2_K_XL.gguf",
        .size_bytes = 2_190_000_000,
        .size_label = "2.1 GB",
    },
    .{
        .id = "unsloth/gemma-4-E2B-it-qat-UD-Q4_K_XL",
        .title = "Gemma 4 E2B (Q4_K_XL)",
        .detail = "Higher quality. ~2.5 GB. Best for iPhone 15 Pro+.",
        .file_name = "gemma-4-E2B-it-qat-UD-Q4_K_XL.gguf",
        .download_url = "https://huggingface.co/unsloth/gemma-4-E2B-it-qat-GGUF/resolve/main/gemma-4-E2B-it-qat-UD-Q4_K_XL.gguf",
        .size_bytes = 2_620_000_000,
        .size_label = "2.5 GB",
    },
    .{
        .id = "unsloth/gemma-3n-E4B-it-audio",
        .title = "Gemma 3n E4B Audio (experimental)",
        .detail = "Multimodal: text + audio. Enables on-device transcription via mtmd. Needs the mmproj (see preset).",
        .file_name = "gemma-3n-E4B-it-UD-Q4_K_XL.gguf",
        .download_url = "https://huggingface.co/unsloth/gemma-3n-E4B-it-GGUF/resolve/main/gemma-3n-E4B-it-UD-Q4_K_XL.gguf",
        .size_bytes = 5_390_000_000,
        .size_label = "5.4 GB",
        // TODO: replace with a hosted mmproj URL once generated.
        // Generate via: python convert_hf_to_gguf.py <gemma-3n-E4B-it> --mmproj
        .mmproj_file_name = "gemma-3n-E4B-it-mmproj-f16.gguf",
        .mmproj_download_url = "", // empty = not yet hosted
        .mmproj_size_label = "~500 MB",
    },
};

/// Serialize the catalog as a JSON array. Each object mirrors the Swift
/// LocalModelPreset fields so it decodes 1:1. Allocator-owned; caller frees.
pub fn catalogJson(allocator: std.mem.Allocator) ![]u8 {
    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(allocator);
    try buf.append(allocator, '[');
    for (PRESETS, 0..) |p, i| {
        if (i > 0) try buf.append(allocator, ',');
        try buf.appendSlice(allocator, "{\"id\":");
        try writeJsonString(allocator, &buf, p.id);
        try buf.appendSlice(allocator, ",\"title\":");
        try writeJsonString(allocator, &buf, p.title);
        try buf.appendSlice(allocator, ",\"detail\":");
        try writeJsonString(allocator, &buf, p.detail);
        try buf.appendSlice(allocator, ",\"fileName\":");
        try writeJsonString(allocator, &buf, p.file_name);
        try buf.appendSlice(allocator, ",\"downloadURL\":");
        try writeJsonString(allocator, &buf, p.download_url);
        const size_str = try std.fmt.allocPrint(allocator, ",\"sizeBytes\":{d}", .{p.size_bytes});
        defer allocator.free(size_str);
        try buf.appendSlice(allocator, size_str);
        try buf.appendSlice(allocator, ",\"sizeLabel\":");
        try writeJsonString(allocator, &buf, p.size_label);
        // mmproj fields: omitted when no mmproj (keeps the JSON clean + lets the
        // Swift/Dart decoder treat them as optional / nil).
        if (p.mmproj_file_name.len > 0) {
            try buf.appendSlice(allocator, ",\"mmprojFileName\":");
            try writeJsonString(allocator, &buf, p.mmproj_file_name);
            try buf.appendSlice(allocator, ",\"mmprojDownloadURL\":");
            try writeJsonString(allocator, &buf, p.mmproj_download_url);
            try buf.appendSlice(allocator, ",\"mmprojSizeLabel\":");
            try writeJsonString(allocator, &buf, p.mmproj_size_label);
        }
        try buf.append(allocator, '}');
    }
    try buf.append(allocator, ']');
    return buf.toOwnedSlice(allocator);
}

/// Minimal JSON string escaper (mirrors ffi.zig's writeJsonString, kept local
/// so this module has no cross-module helper dependency).
fn writeJsonString(allocator: std.mem.Allocator, buf: *std.ArrayList(u8), s: []const u8) !void {
    try buf.append(allocator, '"');
    for (s) |c| {
        switch (c) {
            '"' => try buf.appendSlice(allocator, "\\\""),
            '\\' => try buf.appendSlice(allocator, "\\\\"),
            '\n' => try buf.appendSlice(allocator, "\\n"),
            '\r' => try buf.appendSlice(allocator, "\\r"),
            '\t' => try buf.appendSlice(allocator, "\\t"),
            else => {
                if (c < 0x20) {
                    const hex = try std.fmt.allocPrint(allocator, "\\u{x:0>4}", .{c});
                    defer allocator.free(hex);
                    try buf.appendSlice(allocator, hex);
                } else {
                    try buf.append(allocator, c);
                }
            },
        }
    }
    try buf.append(allocator, '"');
}

// ──────────────────────────────────────────────────────────────────────────
// Tests
// ──────────────────────────────────────────────────────────────────────────

const testing = std.testing;

test "catalogJson: emits valid JSON with all presets" {
    const json = try catalogJson(testing.allocator);
    defer testing.allocator.free(json);
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{});
    defer parsed.deinit();
    try testing.expectEqual(@as(usize, PRESETS.len), parsed.value.array.items.len);

    // First preset is the Q2_K_XL (smallest-first ordering).
    const first = parsed.value.array.items[0].object;
    try testing.expectEqualStrings("unsloth/gemma-4-E2B-it-qat-UD-Q2_K_XL", first.get("id").?.string);

    // The audio preset carries mmproj fields; the text-only ones do not.
    const audio = parsed.value.array.items[2].object;
    try testing.expect(audio.get("mmprojFileName") != null);
    try testing.expect(parsed.value.array.items[0].object.get("mmprojFileName") == null);
}

test "catalogJson: mmproj download URL is empty until hosted" {
    const json = try catalogJson(testing.allocator);
    defer testing.allocator.free(json);
    try testing.expect(std.mem.indexOf(u8, json, "\"mmprojDownloadURL\":\"\"") != null);
}
