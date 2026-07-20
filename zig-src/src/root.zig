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

// Re-export sub-modules as they land.
pub const vector_math = @import("vector_math.zig");
pub const text_util = @import("text_util.zig");
pub const porter_stemmer = @import("porter_stemmer.zig");
pub const tokenize = @import("tokenize.zig");
pub const feed_types = @import("feed_types.zig");
pub const ranker = @import("ranker.zig");
pub const memory_types = @import("memory_types.zig");
pub const chunker = @import("chunker.zig");
pub const embeddings = @import("embeddings.zig");
pub const ffi = @import("ffi.zig");
pub const sqlite = @import("sqlite.zig");
pub const markdown = @import("markdown.zig");
pub const response_cache = @import("response_cache.zig");

test {
    // Zig 0.16 only collects test blocks from the root source file of a test
    // binary; transitively-imported modules must be referenced here so their
    // `test {}` blocks are included in `zig build test`. Add one line per
    // sub-module.
    _ = vector_math;
    _ = text_util;
    _ = porter_stemmer;
    _ = tokenize;
    _ = feed_types;
    _ = ranker;
    _ = memory_types;
    _ = chunker;
    _ = embeddings;
    _ = ffi;

    // Sanity: std is reachable.
    try std.testing.expect(std.mem.eql(u8, "ok", "ok"));
}
