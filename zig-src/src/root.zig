//! SlowClaw Social — Zig core pilot (slice 1: feed ranker).
//!
//! Public surface area of the `slowclaw_feed` package. Sub-modules are
//! re-exported here so consumers import a single namespace:
//!
//! ```zig
//! const slowclaw = @import("slowclaw_feed");
//! const sim = slowclaw.vector_math.cosine_similarity(a, b);
//! ```
//!
//! Ported modules (added incrementally per the slice plan in README.md):
//!   - (slice 1, scaffold only — modules land in subsequent commits)

const std = @import("std");

// Re-export sub-modules as they land. Placeholder until slice 2.
// pub const vector_math = @import("vector_math.zig");
// pub const text_util = @import("text_util.zig");
// pub const tokenize = @import("tokenize.zig");
// pub const feed_types = @import("feed_types.zig");
// pub const ranker = @import("ranker.zig");

test "skeleton: package imports std and builds" {
    try std.testing.expect(@import("std").mem.eql(u8, "ok", "ok"));
}
