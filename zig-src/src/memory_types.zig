//! Memory data types + the Memory backend trait.
//!
//! Ports `src/memory/traits.rs` (130 LOC + 3 tests). The Rust `Memory` trait
//! (async, via async_trait) becomes a synchronous Zig vtable: a struct of
//! function pointers plus a `ctx: *anyopaque` for implementer state. Async I/O
//! is the implementer's concern — on iOS the SQLite-backed implementation will
//! run on a background thread and surface results via the C ABI.

const std = @import("std");
const testing = std.testing;

/// Memory categories for organization. Mirrors `MemoryCategory` in
/// `src/memory/traits.rs:33`. The Rust enum has a `Custom(String)` variant;
/// in Zig we use a tagged union so the custom name travels with the tag.
///
/// `toString()` and `toJsonTag()` mirror the Rust `Display` and the
/// `#[serde(rename_all = "snake_case")]` serialization for the non-custom
/// variants; custom emits the bare name.
pub const MemoryCategory = union(enum) {
    core,
    daily,
    conversation,
    custom: []const u8,

    /// Lowercase tag name (mirrors Rust `Display`).
    pub fn toString(self: MemoryCategory) []const u8 {
        return switch (self) {
            .core => "core",
            .daily => "daily",
            .conversation => "conversation",
            .custom => |name| name,
        };
    }

    /// Serialization tag for the built-in variants (snake_case, like serde).
    /// Custom emits the bare name without quoting — the caller wraps it.
    pub fn toJsonTag(self: MemoryCategory) []const u8 {
        return self.toString();
    }

    /// Equality (the custom variant compares the name slice).
    pub fn eql(self: MemoryCategory, other: MemoryCategory) bool {
        if (std.meta.activeTag(self) != std.meta.activeTag(other)) return false;
        return switch (self) {
            .custom => |a| std.mem.eql(u8, a, other.custom),
            else => true,
        };
    }

    /// Parse a lowercase tag back into a category. Mirrors the parsing the
    /// SQLite backend does on readRow; shared here so the sync engine (and
    /// any future caller) applies the same mapping. `text` is borrowed for
    /// the call only — the `.custom` variant aliases it, so the caller must
    /// dupe if it needs to outlive `text` (sync_engine does this via store).
    pub fn fromText(text: []const u8) MemoryCategory {
        if (std.mem.eql(u8, text, "core")) return .{ .core = {} };
        if (std.mem.eql(u8, text, "daily")) return .{ .daily = {} };
        if (std.mem.eql(u8, text, "conversation")) return .{ .conversation = {} };
        return .{ .custom = text };
    }
};

/// A single memory entry. Mirrors `MemoryEntry` in `src/memory/traits.rs:6`.
/// String fields are borrowed slices; the caller (or backend) owns the storage.
///
/// `source` and `media_url` were added to carry journal provenance so the UI
/// can distinguish a typed entry from an audio recording/import and replay the
/// linked audio file. Both default to null (legacy rows read back as null and
/// are treated as `text`/no-media by callers).
pub const MemoryEntry = struct {
    id: []const u8,
    key: []const u8,
    content: []const u8,
    category: MemoryCategory,
    timestamp: []const u8,
    session_id: ?[]const u8 = null,
    score: ?f64 = null,
    /// Provenance: "audio_recorded" (in-app recorder), "audio_imported"
    /// (Voice Memos share-sheet), or "text" (typed/AI-polished). Null for
    /// rows written before this column existed.
    source: ?[]const u8 = null,
    /// Documents-relative path to the linked audio file (e.g.
    /// "Recordings/journal_1234.m4a"), so the UI can replay it. Null for
    /// typed entries and legacy rows.
    media_url: ?[]const u8 = null,
};

/// Error set for Memory operations. Backends return these from the vtable.
pub const MemoryError = error{
    BackendFailed,
    NotFound,
    InvalidArgument,
    OutOfMemory,
};

/// Vtable for a Memory backend. Mirrors the `Memory` trait in
/// `src/memory/traits.rs:64`. Each implementer (SQLite, None, etc.) creates a
/// `Memory` by filling in `ctx` (its own state pointer) and the function
/// pointers, each of which takes `ctx` as the first argument.
///
/// The async Rust methods (`store`, `recall`, `get`, `list`, `forget`,
/// `count`, `health_check`) become synchronous here; an iOS implementer is
/// expected to marshal work to a background queue and surface completion via
/// the C-ABI boundary (slice 7).
pub const Memory = struct {
    ctx: *anyopaque,
    name_fn: *const fn (ctx: *anyopaque) []const u8,
    store_fn: *const fn (
        ctx: *anyopaque,
        key: []const u8,
        content: []const u8,
        category: MemoryCategory,
        session_id: ?[]const u8,
        source: ?[]const u8,
        media_url: ?[]const u8,
    ) MemoryError!void,
    recall_fn: *const fn (
        ctx: *anyopaque,
        allocator: std.mem.Allocator,
        query: []const u8,
        limit: usize,
        session_id: ?[]const u8,
    ) MemoryError![]MemoryEntry,
    get_fn: *const fn (ctx: *anyopaque, key: []const u8) MemoryError!?MemoryEntry,
    list_fn: *const fn (
        ctx: *anyopaque,
        allocator: std.mem.Allocator,
        category: ?MemoryCategory,
        session_id: ?[]const u8,
    ) MemoryError![]MemoryEntry,
    forget_fn: *const fn (ctx: *anyopaque, key: []const u8) MemoryError!bool,
    count_fn: *const fn (ctx: *anyopaque) MemoryError!usize,
    health_check_fn: *const fn (ctx: *anyopaque) bool,

    pub fn name(self: Memory) []const u8 {
        return self.name_fn(self.ctx);
    }

    pub fn store(
        self: Memory,
        key: []const u8,
        content: []const u8,
        category: MemoryCategory,
        session_id: ?[]const u8,
        source: ?[]const u8,
        media_url: ?[]const u8,
    ) MemoryError!void {
        return self.store_fn(self.ctx, key, content, category, session_id, source, media_url);
    }

    pub fn recall(
        self: Memory,
        allocator: std.mem.Allocator,
        query: []const u8,
        limit: usize,
        session_id: ?[]const u8,
    ) MemoryError![]MemoryEntry {
        return self.recall_fn(self.ctx, allocator, query, limit, session_id);
    }

    pub fn get(self: Memory, key: []const u8) MemoryError!?MemoryEntry {
        return self.get_fn(self.ctx, key);
    }

    pub fn list(
        self: Memory,
        allocator: std.mem.Allocator,
        category: ?MemoryCategory,
        session_id: ?[]const u8,
    ) MemoryError![]MemoryEntry {
        return self.list_fn(self.ctx, allocator, category, session_id);
    }

    pub fn forget(self: Memory, key: []const u8) MemoryError!bool {
        return self.forget_fn(self.ctx, key);
    }

    pub fn count(self: Memory) MemoryError!usize {
        return self.count_fn(self.ctx);
    }

    pub fn healthCheck(self: Memory) bool {
        return self.health_check_fn(self.ctx);
    }
};

// ──────────────────────────────────────────────────────────────────────────
// Tests — verbatim ports of the 3 Rust tests at src/memory/traits.rs:84-128.
// ──────────────────────────────────────────────────────────────────────────

test "MemoryCategory.toString outputs expected values" {
    try testing.expectEqualStrings("core", (MemoryCategory{ .core = {} }).toString());
    try testing.expectEqualStrings("daily", (MemoryCategory{ .daily = {} }).toString());
    try testing.expectEqualStrings("conversation", (MemoryCategory{ .conversation = {} }).toString());
    try testing.expectEqualStrings("project_notes", (MemoryCategory{ .custom = "project_notes" }).toString());
}

test "MemoryCategory.eql: tags and custom names" {
    const core = MemoryCategory{ .core = {} };
    const daily = MemoryCategory{ .daily = {} };
    try testing.expect(core.eql(core));
    try testing.expect(!core.eql(daily));
    try testing.expect((MemoryCategory{ .custom = "x" }).eql(.{ .custom = "x" }));
    try testing.expect(!(MemoryCategory{ .custom = "x" }).eql(.{ .custom = "y" }));
    try testing.expect(!(MemoryCategory{ .custom = "x" }).eql(core));
}

test "MemoryEntry: constructs with all fields including optionals" {
    const entry = MemoryEntry{
        .id = "id-1",
        .key = "favorite_language",
        .content = "Rust",
        .category = .{ .core = {} },
        .timestamp = "2026-02-16T00:00:00Z",
        .session_id = "session-abc",
        .score = 0.98,
    };
    try testing.expectEqualStrings("id-1", entry.id);
    try testing.expectEqualStrings("favorite_language", entry.key);
    try testing.expectEqualStrings("Rust", entry.content);
    try testing.expect(entry.category.eql(.{ .core = {} }));
    try testing.expectEqualStrings("session-abc", entry.session_id.?);
    try testing.expectEqual(@as(f64, 0.98), entry.score.?);
}

test "MemoryEntry: optionals default to null" {
    const entry = MemoryEntry{
        .id = "id-2",
        .key = "k",
        .content = "c",
        .category = .{ .daily = {} },
        .timestamp = "2026-02-16T00:00:00Z",
    };
    try testing.expect(entry.session_id == null);
    try testing.expect(entry.score == null);
}
