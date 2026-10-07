//! Retired ABI: Needle is no longer linked. Existing callers explicitly abstain.
pub fn embed(_: []const u8, _: []f32) !void {
    return error.Unavailable;
}
