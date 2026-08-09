//! Sync engine: transport-agnostic manifest diff + apply for the LAN
//! QR-paired sync between the user's own devices (iOS app ↔ Windows
//! companion shell). Authorized as a bounded companion-surface exception
//! in AGENTS.md §1/§9.
//!
//! Design (KISS + YAGNI):
//!   - The Zig core owns sync *logic* only. The wire transport (HTTP/JSON
//!     over LAN) lives in each shell, mirroring the injected-transport
//!     precedent used for LLM HTTP (`SlowclawHttpPostFn` in ffi.zig).
//!   - The sync identity is the stable unique `key` column of `memories`
//!     (NOT `id` — `id` is regenerated on every upsert; see sqlite.zig
//!     store). `updated_at` (RFC3339) is the last-writer-wins tiebreaker.
//!   - A `SyncManifest` is a digest of every journal row + its referenced
//!     audio media file. Each side exchanges manifests, diffs them, then
//!     pulls/pushes only the differing entries.
//!   - v1 does NOT propagate deletes (no tombstones). This is a documented
//!     limitation; adding tombstones later is a non-breaking additive
//!     migration via `runMigrations`. CRDT/conflict-resolution is YAGNI.
//!
//! No networking, no I/O scheduling, no platform code. Pure logic + the
//! existing SQLite handle. This module must build for every target the
//! core builds for (iOS, macOS, Windows).

const std = @import("std");
const sqlite = @import("sqlite.zig");
const memory_types = @import("memory_types.zig");

// std.crypto SHA256 is cross-platform and libc-free.
const Sha256 = std.crypto.hash.sha2.Sha256;

// ──────────────────────────────────────────────────────────────────────────
// Manifest data model
// ──────────────────────────────────────────────────────────────────────────

/// One row of a sync manifest: enough to decide what differs between two
/// devices without transferring full content. `content_sha256_hex` is a
/// 64-char lowercase hex digest of the journal `content` text. `media_*`
/// describe the audio file referenced by `media_url`, if any.
///
/// All string fields are allocator-owned UTF-8 (freed via `freeManifest`).
pub const ManifestEntry = struct {
    key: []const u8,
    updated_at: []const u8,
    content_sha256_hex: []const u8,
    has_media: bool,
    /// Documents-relative path from the `media_url` column (e.g.
    /// "Recordings/journal_1234.m4a"). Empty when `has_media` is false.
    media_path: []const u8,
    /// File size in bytes (0 when `has_media` is false). Used to detect
    /// a re-recorded audio file with the same path but different length.
    media_len: u64,

    pub fn deinit(self: ManifestEntry, allocator: std.mem.Allocator) void {
        allocator.free(self.key);
        allocator.free(self.updated_at);
        allocator.free(self.content_sha256_hex);
        // media_path is always allocator-owned (possibly an empty slice).
        allocator.free(self.media_path);
    }
};

pub const SyncManifest = struct {
    entries: []ManifestEntry,

    pub fn deinit(self: SyncManifest, allocator: std.mem.Allocator) void {
        for (self.entries) |e| e.deinit(allocator);
        allocator.free(self.entries);
    }
};

/// Result of diffing local vs remote manifests. Each slice is a list of
/// `key` strings (allocator-owned; free via `deinit`).
pub const SyncDiff = struct {
    /// Keys present (or newer) on remote that the local side should pull.
    to_pull: [][]const u8,
    /// Keys present (or newer) on local that should be pushed to remote.
    to_push: [][]const u8,
    /// Keys with identical `key` but different `content_sha256_hex`; the
    /// side whose `updated_at` is older should pull. Last-writer-wins.
    conflicts: []Conflict,

    pub const Conflict = struct {
        key: []const u8,
        local_updated_at: []const u8,
        remote_updated_at: []const u8,
        /// `local` or `remote` — which side is newer and therefore wins.
        winner: Winner,
    };
    pub const Winner = enum { local, remote };

    pub fn deinit(self: SyncDiff, allocator: std.mem.Allocator) void {
        for (self.to_pull) |k| allocator.free(k);
        allocator.free(self.to_pull);
        for (self.to_push) |k| allocator.free(k);
        allocator.free(self.to_push);
        for (self.conflicts) |cf| {
            allocator.free(cf.key);
            allocator.free(cf.local_updated_at);
            allocator.free(cf.remote_updated_at);
        }
        allocator.free(self.conflicts);
    }
};

// ──────────────────────────────────────────────────────────────────────────
// Errors
// ──────────────────────────────────────────────────────────────────────────

pub const SyncError = error{
    OutOfMemory,
    BackendFailed,
    InvalidManifest,
    MediaStatFailed,
};

// ──────────────────────────────────────────────────────────────────────────
// Manifest construction
// ──────────────────────────────────────────────────────────────────────────

/// Build a sync manifest for the given SQLite memory store.
///
/// Projects every `memories` row onto the sync shape (key, content,
/// updated_at, media_url) via `SqliteMemory.listForSync`, then hashes the
/// content and sizes any referenced media file. `media_root` is the absolute
/// directory under which `media_url` paths resolve (the iOS `Documents/` dir
/// or the Windows equivalent). Pass an empty slice to skip media sizing
/// (the path is still recorded).
pub fn buildManifest(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteMemory,
    media_root: []const u8,
) SyncError!SyncManifest {
    const rows = db.listForSync(allocator) catch return error.BackendFailed;
    defer {
        for (rows) |r| sqlite.SqliteMemory.freeSyncRow(allocator, r);
        allocator.free(rows);
    }

    var out = std.ArrayList(ManifestEntry).empty;
    errdefer {
        for (out.items) |e| e.deinit(allocator);
        out.deinit(allocator);
    }

    for (rows) |r| {
        const key = allocator.dupe(u8, r.key) catch return error.OutOfMemory;
        errdefer allocator.free(key);
        const updated_at = allocator.dupe(u8, r.updated_at) catch return error.OutOfMemory;
        errdefer allocator.free(updated_at);
        const hash_hex = sha256Hex(allocator, r.content) catch return error.OutOfMemory;
        errdefer allocator.free(hash_hex);

        var has_media = false;
        var media_path: []const u8 = allocator.dupe(u8, "") catch return error.OutOfMemory;
        errdefer allocator.free(media_path);
        var media_len: u64 = 0;
        if (r.media_url) |mp| {
            if (mp.len > 0) {
                allocator.free(media_path);
                media_path = allocator.dupe(u8, mp) catch return error.OutOfMemory;
                has_media = true;
                if (media_root.len > 0) {
                    media_len = sizeMediaFile(allocator, media_root, mp) catch 0;
                    // A failed stat is non-fatal: we still record the path
                    // and a zero length. The puller will retry; a missing
                    // file on the sender just yields an empty body.
                }
            }
        }

        out.append(allocator, .{
            .key = key,
            .updated_at = updated_at,
            .content_sha256_hex = hash_hex,
            .has_media = has_media,
            .media_path = media_path,
            .media_len = media_len,
        }) catch return error.OutOfMemory;
    }

    return .{ .entries = out.toOwnedSlice(allocator) catch return error.OutOfMemory };
}

/// SHA-256 of `data` as a 64-char lowercase hex string (allocator-owned).
fn sha256Hex(allocator: std.mem.Allocator, data: []const u8) ![]u8 {
    var digest: [Sha256.digest_length]u8 = undefined;
    Sha256.hash(data, &digest, .{});
    const hex = try allocator.alloc(u8, digest.len * 2);
    const alphabet = "0123456789abcdef";
    for (digest, 0..) |byte, i| {
        hex[i * 2] = alphabet[byte >> 4];
        hex[i * 2 + 1] = alphabet[byte & 0x0f];
    }
    return hex;
}

/// Best-effort size of `<media_root>/<rel_path>`. Uses stdio fopen/fseek
/// to stay libc-only and cross-platform (mirrors the file-pre-check style
/// in local_inference.zig). Returns 0 on any failure.
fn sizeMediaFile(allocator: std.mem.Allocator, media_root: []const u8, rel_path: []const u8) !u64 {
    const full = std.fmt.allocPrint(allocator, "{s}/{s}", .{ media_root, rel_path }) catch return error.OutOfMemory;
    defer allocator.free(full);
    const path_z = allocator.dupeZ(u8, full) catch return error.OutOfMemory;
    defer allocator.free(path_z);

    const c_stdio = @cImport({
        @cInclude("stdio.h");
    });
    const fp = c_stdio.fopen(path_z.ptr, "rb") orelse return 0;
    defer _ = c_stdio.fclose(fp);
    if (c_stdio.fseek(fp, 0, c_stdio.SEEK_END) != 0) return 0;
    const sz = c_stdio.ftell(fp);
    if (sz < 0) return 0;
    return @intCast(sz);
}

// ──────────────────────────────────────────────────────────────────────────
// Manifest JSON (de)serialization
// ──────────────────────────────────────────────────────────────────────────

/// Manifest JSON shape (versioned so the wire protocol can evolve):
///   {"v":1,"entries":[
///     {"key":"...","updated_at":"2026-08-09T...Z","content_sha256":"<64hex>",
///      "has_media":true,"media_path":"Recordings/journal_x.m4a","media_len":12345},
///     ...
///   ]}
pub fn serializeManifest(allocator: std.mem.Allocator, manifest: SyncManifest) ![]u8 {
    var buf = std.ArrayList(u8).empty;
    errdefer buf.deinit(allocator);

    try buf.appendSlice(allocator, "{\"v\":1,\"entries\":[");
    for (manifest.entries, 0..) |e, i| {
        if (i > 0) try buf.append(allocator, ',');
        try buf.append(allocator, '{');
        try writeJsonStringField(allocator, &buf, "key", e.key);
        try buf.append(allocator, ',');
        try writeJsonStringField(allocator, &buf, "updated_at", e.updated_at);
        try buf.append(allocator, ',');
        try writeJsonStringField(allocator, &buf, "content_sha256", e.content_sha256_hex);
        try buf.appendSlice(allocator, ",\"has_media\":");
        try buf.appendSlice(allocator, if (e.has_media) "true" else "false");
        try buf.append(allocator, ',');
        try writeJsonStringField(allocator, &buf, "media_path", e.media_path);
        var len_buf: [32]u8 = undefined;
        const len_str = std.fmt.bufPrint(&len_buf, "{d}", .{e.media_len}) catch unreachable;
        try buf.appendSlice(allocator, ",\"media_len\":");
        try buf.appendSlice(allocator, len_str);
        try buf.append(allocator, '}');
    }
    try buf.appendSlice(allocator, "]}");
    return buf.toOwnedSlice(allocator);
}

/// Write `"key":"escaped-value"` (no leading/trailing comma — caller controls
/// punctuation so the JSON is always well-formed).
fn writeJsonStringField(allocator: std.mem.Allocator, buf: *std.ArrayList(u8), key: []const u8, val: []const u8) !void {
    try buf.append(allocator, '"');
    try buf.appendSlice(allocator, key);
    try buf.appendSlice(allocator, "\":\"");
    try writeJsonString(allocator, buf, val);
    try buf.append(allocator, '"');
}

/// Escape a UTF-8 string into the JSON buffer (handles `"`, `\`, control).
/// Mirrors the manual escaping in ffi.zig:writeJsonString so we keep one
/// consistent JSON style across the codebase.
pub fn writeJsonString(allocator: std.mem.Allocator, buf: *std.ArrayList(u8), s: []const u8) !void {
    for (s) |b| {
        switch (b) {
            '"' => try buf.appendSlice(allocator, "\\\""),
            '\\' => try buf.appendSlice(allocator, "\\\\"),
            '\n' => try buf.appendSlice(allocator, "\\n"),
            '\r' => try buf.appendSlice(allocator, "\\r"),
            '\t' => try buf.appendSlice(allocator, "\\t"),
            0...8, 11, 12, 14...31 => {
                var hex: [6]u8 = .{ '\\', 'u', '0', '0', undefined, undefined };
                const alphabet = "0123456789abcdef";
                hex[4] = alphabet[b >> 4];
                hex[5] = alphabet[b & 0x0f];
                try buf.appendSlice(allocator, &hex);
            },
            else => try buf.append(allocator, b),
        }
    }
}

/// Parse a manifest JSON blob (allocator-owned strings).
pub fn parseManifest(allocator: std.mem.Allocator, json: []const u8) SyncError!SyncManifest {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, json, .{}) catch return error.InvalidManifest;
    defer parsed.deinit();

    const root = switch (parsed.value) {
        .object => |o| o,
        else => return error.InvalidManifest,
    };
    const entries_val = root.get("entries") orelse return error.InvalidManifest;
    const arr = switch (entries_val) {
        .array => |a| a,
        else => return error.InvalidManifest,
    };

    var out = std.ArrayList(ManifestEntry).empty;
    errdefer {
        for (out.items) |e| e.deinit(allocator);
        out.deinit(allocator);
    }

    for (arr.items) |item| {
        const obj = switch (item) {
            .object => |o| o,
            else => return error.InvalidManifest,
        };
        const key = jsonFieldDup(allocator, obj, "key") catch return error.OutOfMemory;
        errdefer allocator.free(key);
        const updated_at = jsonFieldDup(allocator, obj, "updated_at") catch return error.OutOfMemory;
        errdefer allocator.free(updated_at);
        const sha = jsonFieldDup(allocator, obj, "content_sha256") catch return error.OutOfMemory;
        errdefer allocator.free(sha);
        const has_media = blk: {
            const v = obj.get("has_media") orelse break :blk false;
            switch (v) {
                .bool => |b| break :blk b,
                else => break :blk false,
            }
        };
        const media_path = if (has_media)
            (jsonFieldDup(allocator, obj, "media_path") catch return error.OutOfMemory)
        else
            (allocator.dupe(u8, "") catch return error.OutOfMemory);
        errdefer allocator.free(media_path);
        const media_len = blk: {
            const v = obj.get("media_len") orelse break :blk 0;
            break :blk switch (v) {
                .integer => |n| if (n < 0) 0 else @as(u64, @intCast(n)),
                else => 0,
            };
        };

        out.append(allocator, .{
            .key = key,
            .updated_at = updated_at,
            .content_sha256_hex = sha,
            .has_media = has_media,
            .media_path = media_path,
            .media_len = media_len,
        }) catch return error.OutOfMemory;
    }

    return .{ .entries = out.toOwnedSlice(allocator) catch return error.OutOfMemory };
}

fn jsonFieldDup(allocator: std.mem.Allocator, obj: std.json.ObjectMap, name: []const u8) ![]const u8 {
    const v = obj.get(name) orelse return allocator.dupe(u8, "");
    return switch (v) {
        .string => |s| allocator.dupe(u8, s),
        else => allocator.dupe(u8, ""),
    };
}

// ──────────────────────────────────────────────────────────────────────────
// Diff
// ──────────────────────────────────────────────────────────────────────────

/// Diff two manifests. `local` is this device's manifest, `remote` is the
/// peer's. Conflict resolution is last-writer-wins on `updated_at` (RFC3339
/// compares lexicographically for the same timezone, which our `nowRfc3339`
/// guarantees — always UTC `...Z`).
pub fn diff(
    allocator: std.mem.Allocator,
    local: SyncManifest,
    remote: SyncManifest,
) SyncError!SyncDiff {
    var to_pull = std.ArrayList([]const u8).empty;
    errdefer {
        for (to_pull.items) |k| allocator.free(k);
        to_pull.deinit(allocator);
    }
    var to_push = std.ArrayList([]const u8).empty;
    errdefer {
        for (to_push.items) |k| allocator.free(k);
        to_push.deinit(allocator);
    }
    var conflicts = std.ArrayList(SyncDiff.Conflict).empty;
    errdefer {
        for (conflicts.items) |cf| {
            allocator.free(cf.key);
            allocator.free(cf.local_updated_at);
            allocator.free(cf.remote_updated_at);
        }
        conflicts.deinit(allocator);
    }

    // Index local by key for O(1) lookup.
    var local_map = std.StringHashMap(ManifestEntry).init(allocator);
    defer local_map.deinit();
    for (local.entries) |e| {
        local_map.put(e.key, e) catch return error.OutOfMemory;
    }

    // Walk remote: classify each key vs local.
    for (remote.entries) |r| {
        if (local_map.get(r.key)) |l| {
            if (std.mem.eql(u8, l.content_sha256_hex, r.content_sha256_hex) and
                l.media_len == r.media_len and !mediaDiffers(l, r))
            {
                // Identical content + media — nothing to do.
            } else {
                // Conflict: same key, different content. Last-writer-wins.
                const remote_wins = std.mem.order(u8, r.updated_at, l.updated_at) == .gt;
                const winner: SyncDiff.Winner = if (remote_wins) .remote else .local;
                conflicts.append(allocator, .{
                    .key = allocator.dupe(u8, r.key) catch return error.OutOfMemory,
                    .local_updated_at = allocator.dupe(u8, l.updated_at) catch return error.OutOfMemory,
                    .remote_updated_at = allocator.dupe(u8, r.updated_at) catch return error.OutOfMemory,
                    .winner = winner,
                }) catch return error.OutOfMemory;
                if (remote_wins) {
                    to_pull.append(allocator, allocator.dupe(u8, r.key) catch return error.OutOfMemory) catch return error.OutOfMemory;
                } else {
                    to_push.append(allocator, allocator.dupe(u8, r.key) catch return error.OutOfMemory) catch return error.OutOfMemory;
                }
            }
            _ = local_map.remove(r.key); // accounted for
        } else {
            // Remote-only key → pull.
            to_pull.append(allocator, allocator.dupe(u8, r.key) catch return error.OutOfMemory) catch return error.OutOfMemory;
        }
    }

    // Anything left in local_map is local-only → push.
    var it = local_map.iterator();
    while (it.next()) |entry| {
        to_push.append(allocator, allocator.dupe(u8, entry.key_ptr.*) catch return error.OutOfMemory) catch return error.OutOfMemory;
    }

    return .{
        .to_pull = to_pull.toOwnedSlice(allocator) catch return error.OutOfMemory,
        .to_push = to_push.toOwnedSlice(allocator) catch return error.OutOfMemory,
        .conflicts = conflicts.toOwnedSlice(allocator) catch return error.OutOfMemory,
    };
}

/// Media differs if both sides reference media but the path differs, or if
/// exactly one side has media. (When both reference the same path+length we
/// already returned false in `diff`.)
fn mediaDiffers(l: ManifestEntry, r: ManifestEntry) bool {
    if (l.has_media != r.has_media) return true;
    if (l.has_media) return !std.mem.eql(u8, l.media_path, r.media_path);
    return false;
}

// ──────────────────────────────────────────────────────────────────────────
// Apply (remote entries → local store)
// ──────────────────────────────────────────────────────────────────────────

/// One full journal entry as transferred over the wire (content + metadata).
/// `category` is the lowercase tag ("core" | "daily" | "conversation" | custom).
/// `session_id`, `source`, `media_url` are optional (null → stored as SQL NULL).
pub const TransferEntry = struct {
    key: []const u8,
    content: []const u8,
    category: []const u8,
    updated_at: []const u8,
    session_id: ?[]const u8 = null,
    source: ?[]const u8 = null,
    media_url: ?[]const u8 = null,
};

/// Apply a batch of remote entries to the local store. Skips any entry whose
/// local `updated_at` is newer than the incoming one (defensive: the diff
/// already directs traffic, but a concurrent local edit between manifest
/// exchange and apply must not be clobbered).
///
/// NOTE: this reuses `SqliteMemory.store`, which upserts on `key` and
/// regenerates `id`/`created_at`. For sync that is acceptable: the `key` is
/// the stable identity (matched on both devices) and `created_at` is not
/// part of the sync contract. The FTS triggers fire automatically.
pub fn applyEntries(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteMemory,
    entries: []const TransferEntry,
) SyncError!void {
    for (entries) |e| {
        // Defensive last-writer-wins: skip if local is newer.
        if (try localNewer(allocator, db, e.key, e.updated_at)) continue;

        const cat = memory_types.MemoryCategory.fromText(e.category);
        db.store(e.key, e.content, cat, e.session_id, e.source, e.media_url) catch return error.BackendFailed;
    }
}

/// True if the local row for `key` has an `updated_at` strictly greater than
/// `incoming_updated_at`. Returns false if the row is absent or on any error
/// (favor applying over silently dropping). Uses `SqliteMemory.updatedAt`
/// (the backend owns its sqlite handle + cImport types).
fn localNewer(
    allocator: std.mem.Allocator,
    db: *sqlite.SqliteMemory,
    key: []const u8,
    incoming_updated_at: []const u8,
) !bool {
    const maybe_local = db.updatedAt(allocator, key) catch return false;
    if (maybe_local) |local| {
        defer allocator.free(local);
        return std.mem.order(u8, local, incoming_updated_at) == .gt;
    }
    return false;
}

// ──────────────────────────────────────────────────────────────────────────
// Tests
//
// Hermetic and deterministic: every test uses a `:memory:` SQLite DB and no
// media files (media_root=""), so there is no filesystem or network
// dependence. The build_manifest → serialize → parse → diff → apply round-trip
// is the deterministic proxy for cross-device sync correctness (AGENTS.md §7).
// ──────────────────────────────────────────────────────────────────────────

const testing = std.testing;

test "sync_engine: sha256_hex produces lowercase 64-char digest" {
    const a = testing.allocator;
    // SHA-256("") = e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
    const hex = try sha256Hex(a, "");
    defer a.free(hex);
    try testing.expectEqual(@as(usize, 64), hex.len);
    try testing.expectEqualStrings("e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855", hex);
}

test "sync_engine: build_manifest reflects stored rows" {
    const a = testing.allocator;
    var db = try sqlite.SqliteMemory.openNoEmbedder(a, ":memory:");
    defer db.close();

    try db.store("slowclaw_user_key_a", "journal entry one", .{ .daily = {} }, null, "text", null);
    try db.store("slowclaw_user_key_b", "journal entry two", .{ .daily = {} }, null, "text", null);

    var manifest = try buildManifest(a, &db, "");
    defer manifest.deinit(a);
    try testing.expectEqual(@as(usize, 2), manifest.entries.len);

    // Keys are returned sorted (ORDER BY key).
    try testing.expectEqualStrings("slowclaw_user_key_a", manifest.entries[0].key);
    try testing.expectEqualStrings("slowclaw_user_key_b", manifest.entries[1].key);
    // Both are text entries → no media.
    try testing.expect(!manifest.entries[0].has_media);
    try testing.expect(!manifest.entries[1].has_media);
    // SHA is stable for the content.
    const expected_hash = try sha256Hex(a, "journal entry one");
    defer a.free(expected_hash);
    try testing.expectEqualStrings(expected_hash, manifest.entries[0].content_sha256_hex);
}

test "sync_engine: manifest serialize → parse round-trip" {
    const a = testing.allocator;
    var db = try sqlite.SqliteMemory.openNoEmbedder(a, ":memory:");
    defer db.close();
    try db.store("slowclaw_user_key_a", "entry A", .{ .daily = {} }, null, "text", null);

    var m1 = try buildManifest(a, &db, "");
    defer m1.deinit(a);
    const json = try serializeManifest(a, m1);
    defer a.free(json);

    var m2 = try parseManifest(a, json);
    defer m2.deinit(a);
    try testing.expectEqual(@as(usize, 1), m2.entries.len);
    try testing.expectEqualStrings("slowclaw_user_key_a", m2.entries[0].key);
    try testing.expectEqualStrings(m1.entries[0].content_sha256_hex, m2.entries[0].content_sha256_hex);
}

test "sync_engine: diff flags remote-only key for pull" {
    const a = testing.allocator;

    var local = SyncManifest{ .entries = try a.alloc(ManifestEntry, 1) };
    defer local.deinit(a);
    local.entries[0] = .{
        .key = try a.dupe(u8, "shared_key"),
        .updated_at = try a.dupe(u8, "2026-08-09T10:00:00Z"),
        .content_sha256_hex = try a.dupe(u8, "aaa"),
        .has_media = false,
        .media_path = try a.dupe(u8, ""),
        .media_len = 0,
    };

    var remote = SyncManifest{ .entries = try a.alloc(ManifestEntry, 2) };
    defer remote.deinit(a);
    remote.entries[0] = .{
        .key = try a.dupe(u8, "shared_key"),
        .updated_at = try a.dupe(u8, "2026-08-09T10:00:00Z"),
        .content_sha256_hex = try a.dupe(u8, "aaa"),
        .has_media = false,
        .media_path = try a.dupe(u8, ""),
        .media_len = 0,
    };
    remote.entries[1] = .{
        .key = try a.dupe(u8, "remote_only_key"),
        .updated_at = try a.dupe(u8, "2026-08-09T11:00:00Z"),
        .content_sha256_hex = try a.dupe(u8, "bbb"),
        .has_media = false,
        .media_path = try a.dupe(u8, ""),
        .media_len = 0,
    };

    var d = try diff(a, local, remote);
    defer d.deinit(a);
    try testing.expectEqual(@as(usize, 1), d.to_pull.len);
    try testing.expectEqualStrings("remote_only_key", d.to_pull[0]);
    try testing.expectEqual(@as(usize, 0), d.to_push.len);
    try testing.expectEqual(@as(usize, 0), d.conflicts.len);
}

test "sync_engine: diff flags local-only key for push" {
    const a = testing.allocator;

    var local = SyncManifest{ .entries = try a.alloc(ManifestEntry, 1) };
    defer local.deinit(a);
    local.entries[0] = .{
        .key = try a.dupe(u8, "local_only_key"),
        .updated_at = try a.dupe(u8, "2026-08-09T10:00:00Z"),
        .content_sha256_hex = try a.dupe(u8, "aaa"),
        .has_media = false,
        .media_path = try a.dupe(u8, ""),
        .media_len = 0,
    };

    const remote = SyncManifest{ .entries = &.{} };

    var d = try diff(a, local, remote);
    defer d.deinit(a);
    try testing.expectEqual(@as(usize, 0), d.to_pull.len);
    try testing.expectEqual(@as(usize, 1), d.to_push.len);
    try testing.expectEqualStrings("local_only_key", d.to_push[0]);
}

test "sync_engine: diff conflict resolves last-writer-wins (remote newer)" {
    const a = testing.allocator;

    var local = SyncManifest{ .entries = try a.alloc(ManifestEntry, 1) };
    defer local.deinit(a);
    local.entries[0] = .{
        .key = try a.dupe(u8, "slowclaw_user_key"),
        .updated_at = try a.dupe(u8, "2026-08-09T10:00:00Z"), // older
        .content_sha256_hex = try a.dupe(u8, "older_hash"),
        .has_media = false,
        .media_path = try a.dupe(u8, ""),
        .media_len = 0,
    };

    var remote = SyncManifest{ .entries = try a.alloc(ManifestEntry, 1) };
    defer remote.deinit(a);
    remote.entries[0] = .{
        .key = try a.dupe(u8, "slowclaw_user_key"),
        .updated_at = try a.dupe(u8, "2026-08-09T11:00:00Z"), // newer
        .content_sha256_hex = try a.dupe(u8, "newer_hash"),
        .has_media = false,
        .media_path = try a.dupe(u8, ""),
        .media_len = 0,
    };

    var d = try diff(a, local, remote);
    defer d.deinit(a);
    try testing.expectEqual(@as(usize, 1), d.conflicts.len);
    try testing.expectEqual(SyncDiff.Winner.remote, d.conflicts[0].winner);
    try testing.expectEqual(@as(usize, 1), d.to_pull.len);
    try testing.expectEqual(@as(usize, 0), d.to_push.len);
}

test "sync_engine: apply_entries writes remote content to local store" {
    const a = testing.allocator;
    var db = try sqlite.SqliteMemory.openNoEmbedder(a, ":memory:");
    defer db.close();

    const entries = [_]TransferEntry{.{
        .key = "slowclaw_user_key",
        .content = "applied from remote",
        .category = "daily",
        .updated_at = "2026-08-09T12:00:00Z",
        .source = "text",
    }};
    try applyEntries(a, &db, &entries);

    const got = (try db.get(a, "slowclaw_user_key")) orelse return error.NotFound;
    defer sqlite.freeEntry(a, got);
    try testing.expectEqualStrings("applied from remote", got.content);
}

test "sync_engine: apply_entries skips when local is newer" {
    const a = testing.allocator;
    var db = try sqlite.SqliteMemory.openNoEmbedder(a, ":memory:");
    defer db.close();

    // Store a local row (its updated_at is "now" from sqlite, which is
    // after the 2020 timestamp below).
    try db.store("slowclaw_user_key", "local newer content", .{ .daily = {} }, null, "text", null);

    // Incoming claims an OLDER updated_at → must be skipped.
    const entries = [_]TransferEntry{.{
        .key = "slowclaw_user_key",
        .content = "stale remote content",
        .category = "daily",
        .updated_at = "2020-01-01T00:00:00Z",
        .source = "text",
    }};
    try applyEntries(a, &db, &entries);

    const got = (try db.get(a, "slowclaw_user_key")) orelse return error.NotFound;
    defer sqlite.freeEntry(a, got);
    try testing.expectEqualStrings("local newer content", got.content);
}

// Full end-to-end round-trip: two stores, manifest exchange, diff, apply,
// and the receiver ends up with identical content. This is the canonical
// correctness proxy for cross-device sync (AGENTS.md §7).
test "sync_engine: full manifest exchange round-trip converges" {
    const a = testing.allocator;

    // Device A: has two entries.
    var db_a = try sqlite.SqliteMemory.openNoEmbedder(a, ":memory:");
    defer db_a.close();
    try db_a.store("slowclaw_user_key_1", "content from A1", .{ .daily = {} }, null, "text", null);
    try db_a.store("slowclaw_user_key_2", "content from A2", .{ .daily = {} }, null, "text", null);

    // Device B: starts empty.
    var db_b = try sqlite.SqliteMemory.openNoEmbedder(a, ":memory:");
    defer db_b.close();

    // A builds + serializes its manifest; B parses it as "remote".
    var manifest_a = try buildManifest(a, &db_a, "");
    defer manifest_a.deinit(a);
    const json_a = try serializeManifest(a, manifest_a);
    defer a.free(json_a);
    var remote_a = try parseManifest(a, json_a);
    defer remote_a.deinit(a);

    // B builds its (empty) local manifest and diffs.
    var manifest_b = try buildManifest(a, &db_b, "");
    defer manifest_b.deinit(a);
    var d = try diff(a, manifest_b, remote_a);
    defer d.deinit(a);

    // Both A entries are remote-only → both should pull.
    try testing.expectEqual(@as(usize, 2), d.to_pull.len);

    // B applies the two entries (simulating the transfer of full content).
    const transfers = [_]TransferEntry{
        .{ .key = "slowclaw_user_key_1", .content = "content from A1", .category = "daily", .updated_at = manifest_a.entries[0].updated_at, .source = "text" },
        .{ .key = "slowclaw_user_key_2", .content = "content from A2", .category = "daily", .updated_at = manifest_a.entries[1].updated_at, .source = "text" },
    };
    try applyEntries(a, &db_b, &transfers);

    // Now B's manifest should match A's (same keys, same hashes).
    var manifest_b_after = try buildManifest(a, &db_b, "");
    defer manifest_b_after.deinit(a);
    try testing.expectEqual(@as(usize, 2), manifest_b_after.entries.len);
    try testing.expectEqualStrings(manifest_a.entries[0].content_sha256_hex, manifest_b_after.entries[0].content_sha256_hex);
    try testing.expectEqualStrings(manifest_a.entries[1].content_sha256_hex, manifest_b_after.entries[1].content_sha256_hex);

    // A re-diff against B's new manifest: nothing to transfer.
    var d2 = try diff(a, manifest_a, manifest_b_after);
    defer d2.deinit(a);
    try testing.expectEqual(@as(usize, 0), d2.to_pull.len);
    try testing.expectEqual(@as(usize, 0), d2.to_push.len);
    try testing.expectEqual(@as(usize, 0), d2.conflicts.len);
}
