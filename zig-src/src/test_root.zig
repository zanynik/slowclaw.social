//! Test entry point — runs every `test {}` block in the package EXCEPT ffi.zig.
//! Kept separate from `root.zig` because ffi.zig requires libc, and linking
//! libc into the test binary changes the debug allocator's behavior (which
//! breaks the ranker tests). The library artifact (build.zig) uses `root.zig`
//! and DOES link libc — that's the path Swift consumes.

const std = @import("std");

pub const vector_math = @import("vector_math.zig");
pub const text_util = @import("text_util.zig");
pub const porter_stemmer = @import("porter_stemmer.zig");
pub const tokenize = @import("tokenize.zig");
pub const feed_types = @import("feed_types.zig");
pub const ranker = @import("ranker.zig");
pub const memory_types = @import("memory_types.zig");
pub const chunker = @import("chunker.zig");
pub const embeddings = @import("embeddings.zig");
pub const provider = @import("provider.zig");
pub const openai_provider = @import("openai_provider.zig");
pub const journal_agent = @import("journal_agent.zig");
pub const feeds_ranking = @import("feeds_ranking.zig");
pub const interest_profile = @import("interest_profile.zig");

test {
    _ = vector_math;
    _ = text_util;
    _ = porter_stemmer;
    _ = tokenize;
    _ = feed_types;
    _ = ranker;
    _ = memory_types;
    _ = chunker;
    _ = embeddings;
    _ = provider;
    _ = openai_provider;
    _ = journal_agent;
    _ = feeds_ranking;
    _ = interest_profile;

    try std.testing.expect(std.mem.eql(u8, "ok", "ok"));
}
