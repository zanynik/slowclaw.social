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
pub const provider = @import("provider.zig");
pub const openai_provider = @import("openai_provider.zig");
pub const journal_agent = @import("journal_agent.zig");
pub const feeds_ranking = @import("feeds_ranking.zig");
pub const interest_profile = @import("interest_profile.zig");
pub const saved_items = @import("saved_items.zig");
pub const rss_parser = @import("rss_parser.zig");

// Force-retain every `export fn` in ffi.zig. Zig 0.16 uses lazy compilation:
// `@import("ffi.zig")` alone does NOT make its export functions reachable,
// and a static-library build will omit them, producing a useless archive with
// no linkable symbols (Zig Issue #10174). The `comptime` block below takes
// the address of each export, which forces codegen for every one of them.
//
// When you add a new export fn to ffi.zig, add a matching `_ = &fn_name;`
// line here — the linker will tell you if you forget (undefined symbol at the
// consumer's link step).
comptime {
    _ = &ffi.slowclaw_feed_free;
    _ = &ffi.slowclaw_feed_hash_embedder_new;
    _ = &ffi.slowclaw_feed_hash_embedder_free;
    _ = &ffi.slowclaw_feed_hash_embed;
    _ = &ffi.slowclaw_feed_rank_stage2;
    _ = &ffi.slowclaw_feed_rank_result_free;
    _ = &ffi.slowclaw_feed_sqlite_open;
    _ = &ffi.slowclaw_feed_sqlite_close;
    _ = &ffi.slowclaw_feed_sqlite_health;
    _ = &ffi.slowclaw_feed_sqlite_store;
    _ = &ffi.slowclaw_feed_sqlite_get;
    _ = &ffi.slowclaw_feed_sqlite_forget;
    _ = &ffi.slowclaw_feed_sqlite_count;
    _ = &ffi.slowclaw_feed_sqlite_recall;
    _ = &ffi.slowclaw_feed_sqlite_result_free;
    _ = &ffi.slowclaw_feed_sqlite_entry_free;
    _ = &ffi.slowclaw_feed_provider_new;
    _ = &ffi.slowclaw_feed_provider_free;
    _ = &ffi.slowclaw_feed_provider_chat;
    _ = &ffi.slowclaw_feed_synthesize_journal;
    _ = &ffi.slowclaw_feed_extract_interests;
    _ = &ffi.slowclaw_feed_draft_post;
    _ = &ffi.slowclaw_feed_chat_result_free;
    _ = &ffi.slowclaw_feed_parse_and_rank;
}

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
