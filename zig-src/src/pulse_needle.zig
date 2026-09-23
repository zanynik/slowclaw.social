//! Pinned Needle 3.0.0 ABI. This release embeds its weights in libneedle.a.
//! All calls must run on the same serial off-main executor. No borrowed model
//! buffers, Swift callbacks, or caller-owned allocations survive a call.
const std = @import("std");
const available = @import("builtin").os.tag == .ios;
extern fn needle_init([*:0]const u8, [*:0]const u8, ?[*:0]const u8) c_int;
// The pinned EARLY API has an audio argument. Current 3.0.1 does not!
extern fn needle_embed([*:0]const u8, ?*const anyopaque, ?[*]f32, c_int) c_int;
var ready = false;

pub fn embed(text: []const u8, out: []f32) !void {
    if (text.len == 0 or text.len > 1200 or out.len != 3072 or std.mem.indexOfScalar(u8, text, 0) != null) return error.InvalidInput;
    if (!available) return error.Unavailable;
    if (!ready) {
        if (needle_init("", "[]", null) < 0 or needle_embed("", null, null, 0) != 3072) return error.InferenceFailed;
        ready = true;
    }
    const z = try std.heap.c_allocator.dupeZ(u8, text);
    defer std.heap.c_allocator.free(z);
    if (needle_embed(z.ptr, null, out.ptr, @intCast(out.len)) != 3072) return error.InferenceFailed;
    var norm: f64 = 0;
    for (out) |v| {
        if (!std.math.isFinite(v)) return error.InferenceFailed;
        norm += @as(f64, v) * @as(f64, v);
    }
    if (!std.math.isFinite(norm) or norm <= 0) return error.InferenceFailed;
    norm = @sqrt(norm);
    for (out) |*v| v.* = @floatCast(@as(f64, v.*) / norm);
}

test "needle rejects malformed input before touching global runtime" {
    var out: [3072]f32 = undefined;
    try std.testing.expectError(error.InvalidInput, embed("", &out));
    try std.testing.expectError(error.InvalidInput, embed("AI\x00agents", &out));
    try std.testing.expectError(error.InvalidInput, embed("AI", out[0..4]));
    if (!available) try std.testing.expectError(error.Unavailable, embed("AI", &out));
}
