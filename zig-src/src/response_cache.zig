//! LLM response cache — ports `src/memory/response_cache.rs` (423 LOC).
//!
//! Saves tokens on repeated prompts by caching LLM responses in a separate
//! SQLite DB at `<workspace>/memory/response_cache.db`. Entries expire after
//! a configurable TTL and evict LRU when over `max_entries`.
//!
//! The cache key is SHA-256(model | system_prompt | user_prompt) — deterministic
//! across runs and process restarts. The Rust original uses SHA-256 via the
//! `sha2` crate; the Zig port uses `std.crypto.hash.sha2.Sha256`.

const std = @import("std");
const testing = std.testing;

const c = @cImport({
    @cInclude("sqlite3.h");
    @cInclude("time.h");
});

// SQLITE_TRANSIENT workaround — see sqlite.zig for the full rationale.
// Declare sqlite3_bind_text with the destructor as ?*const anyopaque to
// bypass the function-pointer alignment check on arm64.
const SQLITE_TRANSIENT: ?*const anyopaque = @ptrFromInt(@as(usize, @bitCast(@as(isize, -1))));

extern fn sqlite3_bind_text(
    stmt: *c.sqlite3_stmt,
    idx: c_int,
    text: [*]const u8,
    len: c_int,
    destructor: ?*const anyopaque,
) c_int;

pub const ResponseCacheError = error{
    OpenFailed,
    PrepareFailed,
    BindFailed,
    StepFailed,
    ExecFailed,
    OutOfMemory,
};

/// LLM response cache. One connection, not thread-safe (the iOS caller
/// serializes via a dispatch queue). Mirrors `ResponseCache` in
/// `src/memory/response_cache.rs:19`.
pub const ResponseCache = struct {
    db: *c.sqlite3,
    db_path: []const u8,
    ttl_minutes: i64,
    max_entries: usize,
    allocator: std.mem.Allocator,

    /// Open (or create) the response cache at `<workspace>/memory/response_cache.db`.
    /// `:memory:` is accepted for tests. Initializes the schema + WAL pragmas.
    pub fn open(
        allocator: std.mem.Allocator,
        path: []const u8,
        ttl_minutes: u32,
        max_entries: usize,
    ) !ResponseCache {
        const path_z = try allocator.dupeZ(u8, path);
        defer allocator.free(path_z);

        var db_handle: ?*c.sqlite3 = null;
        const rc = c.sqlite3_open(path_z.ptr, &db_handle);
        if (rc != c.SQLITE_OK or db_handle == null) {
            if (db_handle) |h| _ = c.sqlite3_close(h);
            return error.OpenFailed;
        }
        var self = ResponseCache{
            .db = db_handle.?,
            .db_path = try allocator.dupe(u8, path),
            .ttl_minutes = @intCast(ttl_minutes),
            .max_entries = max_entries,
            .allocator = allocator,
        };
        try self.exec("PRAGMA journal_mode = WAL; PRAGMA synchronous = NORMAL; PRAGMA temp_store = MEMORY;");
        try self.exec(
            \\CREATE TABLE IF NOT EXISTS response_cache (
            \\    prompt_hash TEXT PRIMARY KEY,
            \\    model       TEXT NOT NULL,
            \\    response    TEXT NOT NULL,
            \\    token_count INTEGER NOT NULL DEFAULT 0,
            \\    created_at  TEXT NOT NULL,
            \\    accessed_at TEXT NOT NULL,
            \\    hit_count   INTEGER NOT NULL DEFAULT 0
            \\);
            \\CREATE INDEX IF NOT EXISTS idx_rc_accessed ON response_cache(accessed_at);
            \\CREATE INDEX IF NOT EXISTS idx_rc_created ON response_cache(created_at);
        );
        return self;
    }

    pub fn close(self: *ResponseCache) void {
        _ = c.sqlite3_close(self.db);
        self.allocator.free(self.db_path);
    }

    fn exec(self: *ResponseCache, sql: []const u8) !void {
        const sql_z = try self.allocator.dupeZ(u8, sql);
        defer self.allocator.free(sql_z);
        var errmsg: [*c]u8 = null;
        const rc = c.sqlite3_exec(self.db, sql_z.ptr, null, null, &errmsg);
        if (rc != c.SQLITE_OK) {
            if (errmsg) |e| c.sqlite3_free(e);
            return error.ExecFailed;
        }
    }

    /// Build a deterministic cache key from model + system prompt + user prompt.
    /// Returns a 64-char lowercase hex SHA-256. Caller owns the returned slice.
    /// Mirrors `cache_key` in response_cache.rs:64.
    pub fn cacheKey(allocator: std.mem.Allocator, model: []const u8, system_prompt: ?[]const u8, user_prompt: []const u8) ![]u8 {
        var hasher = std.crypto.hash.sha2.Sha256.init(.{});
        hasher.update(model);
        hasher.update("|");
        if (system_prompt) |sys| hasher.update(sys);
        hasher.update("|");
        hasher.update(user_prompt);
        var digest: [32]u8 = undefined;
        hasher.final(&digest);
        const hex = std.fmt.bytesToHex(digest, .lower);
        return allocator.dupe(u8, &hex);
    }

    /// Look up a cached response. Returns null on miss or expired entry.
    /// Mirrors `get` in response_cache.rs:90.
    pub fn get(self: *ResponseCache, allocator: std.mem.Allocator, key: []const u8) !?[]u8 {
        // Cutoff = now - ttl_minutes (epoch-seconds string). Entries with
        // created_at <= cutoff are considered expired. We store all timestamps
        // as epoch-seconds strings to keep comparisons timezone-unambiguous.
        const cutoff_owned = try self.epochMinusMinutes(self.allocator, self.ttl_minutes);
        defer self.allocator.free(cutoff_owned);

        const sql = "SELECT response FROM response_cache WHERE prompt_hash = ?1 AND created_at > ?2";
        var stmt: ?*c.sqlite3_stmt = null;
        const sql_z = try self.allocator.dupeZ(u8, sql);
        defer self.allocator.free(sql_z);
        if (c.sqlite3_prepare_v2(self.db, sql_z.ptr, -1, &stmt, null) != c.SQLITE_OK) return error.PrepareFailed;
        defer _ = c.sqlite3_finalize(stmt);
        try bindText(stmt.?, 1, key);
        try bindText(stmt.?, 2, cutoff_owned);

        const rc = c.sqlite3_step(stmt.?);
        if (rc == c.SQLITE_DONE) return null;
        if (rc != c.SQLITE_ROW) return error.StepFailed;
        const response_text = columnText(stmt.?, 0);
        const response_owned = try allocator.dupe(u8, response_text);

        // Bump hit count and accessed_at.
        const now_str = try self.nowEpochSecs(self.allocator);
        defer self.allocator.free(now_str);
        const update_sql = "UPDATE response_cache SET accessed_at = ?1, hit_count = hit_count + 1 WHERE prompt_hash = ?2";
        var upd: ?*c.sqlite3_stmt = null;
        const upd_z = try self.allocator.dupeZ(u8, update_sql);
        defer self.allocator.free(upd_z);
        if (c.sqlite3_prepare_v2(self.db, upd_z.ptr, -1, &upd, null) != c.SQLITE_OK) {
            allocator.free(response_owned);
            return error.PrepareFailed;
        }
        defer _ = c.sqlite3_finalize(upd);
        try bindText(upd.?, 1, now_str);
        try bindText(upd.?, 2, key);
        const upd_rc = c.sqlite3_step(upd.?);
        if (upd_rc != c.SQLITE_DONE) {
            allocator.free(response_owned);
            return error.StepFailed;
        }
        return response_owned;
    }

    /// Store a response in the cache. Evicts expired + LRU entries.
    /// Mirrors `put` in response_cache.rs:135.
    pub fn put(self: *ResponseCache, key: []const u8, model: []const u8, response: []const u8, token_count: u32) !void {
        const now_str = try self.nowEpochSecs(self.allocator);
        defer self.allocator.free(now_str);

        const sql =
            \\INSERT OR REPLACE INTO response_cache
            \\  (prompt_hash, model, response, token_count, created_at, accessed_at, hit_count)
            \\  VALUES (?1, ?2, ?3, ?4, ?5, ?6, 0)
        ;
        var stmt: ?*c.sqlite3_stmt = null;
        const sql_z = try self.allocator.dupeZ(u8, sql);
        defer self.allocator.free(sql_z);
        if (c.sqlite3_prepare_v2(self.db, sql_z.ptr, -1, &stmt, null) != c.SQLITE_OK) return error.PrepareFailed;
        defer _ = c.sqlite3_finalize(stmt);
        try bindText(stmt.?, 1, key);
        try bindText(stmt.?, 2, model);
        try bindText(stmt.?, 3, response);
        _ = c.sqlite3_bind_int64(stmt.?, 4, @intCast(token_count));
        try bindText(stmt.?, 5, now_str);
        try bindText(stmt.?, 6, now_str);
        const rc = c.sqlite3_step(stmt.?);
        if (rc != c.SQLITE_DONE) return error.StepFailed;

        // Evict expired entries.
        const cutoff = try self.epochMinusMinutes(self.allocator, self.ttl_minutes);
        defer self.allocator.free(cutoff);
        const evict_sql = "DELETE FROM response_cache WHERE created_at <= ?1";
        var evict: ?*c.sqlite3_stmt = null;
        const evict_z = try self.allocator.dupeZ(u8, evict_sql);
        defer self.allocator.free(evict_z);
        if (c.sqlite3_prepare_v2(self.db, evict_z.ptr, -1, &evict, null) != c.SQLITE_OK) return error.PrepareFailed;
        defer _ = c.sqlite3_finalize(evict);
        try bindText(evict.?, 1, cutoff);
        const evict_rc = c.sqlite3_step(evict.?);
        if (evict_rc != c.SQLITE_DONE) return error.StepFailed;

        // LRU eviction if over max_entries.
        const lru_sql =
            \\DELETE FROM response_cache WHERE prompt_hash IN (
            \\    SELECT prompt_hash FROM response_cache
            \\    ORDER BY accessed_at ASC
            \\    LIMIT MAX(0, (SELECT COUNT(*) FROM response_cache) - ?1)
            \\)
        ;
        var lru: ?*c.sqlite3_stmt = null;
        const lru_z = try self.allocator.dupeZ(u8, lru_sql);
        defer self.allocator.free(lru_z);
        if (c.sqlite3_prepare_v2(self.db, lru_z.ptr, -1, &lru, null) != c.SQLITE_OK) return error.PrepareFailed;
        defer _ = c.sqlite3_finalize(lru);
        _ = c.sqlite3_bind_int64(lru.?, 1, @intCast(self.max_entries));
        const lru_rc = c.sqlite3_step(lru.?);
        if (lru_rc != c.SQLITE_DONE) return error.StepFailed;
    }

    pub const Stats = struct { total_entries: usize, total_hits: u64, total_tokens_saved: u64 };

    /// Return cache statistics: (total_entries, total_hits, total_tokens_saved).
    /// Mirrors `stats` in response_cache.rs:164.
    pub fn stats(self: *ResponseCache) !Stats {
        const count = try self.queryInt64("SELECT COUNT(*) FROM response_cache");
        const hits = try self.queryInt64("SELECT COALESCE(SUM(hit_count), 0) FROM response_cache");
        const tokens = try self.queryInt64("SELECT COALESCE(SUM(token_count * hit_count), 0) FROM response_cache");
        return .{
            .total_entries = @intCast(@max(count, 0)),
            .total_hits = @intCast(@max(hits, 0)),
            .total_tokens_saved = @intCast(@max(tokens, 0)),
        };
    }

    /// Wipe the entire cache. Returns the number of rows deleted.
    /// Mirrors `clear` in response_cache.rs:188.
    pub fn clear(self: *ResponseCache) !usize {
        const sql = "DELETE FROM response_cache";
        const sql_z = try self.allocator.dupeZ(u8, sql);
        defer self.allocator.free(sql_z);
        var errmsg: [*c]u8 = null;
        const rc = c.sqlite3_exec(self.db, sql_z.ptr, null, null, &errmsg);
        if (rc != c.SQLITE_OK) {
            if (errmsg) |e| c.sqlite3_free(e);
            return error.ExecFailed;
        }
        return @intCast(c.sqlite3_changes(self.db));
    }

    // ── Helpers ──────────────────────────────────────────────────────────

    fn queryInt64(self: *ResponseCache, sql: []const u8) !i64 {
        var stmt: ?*c.sqlite3_stmt = null;
        const sql_z = try self.allocator.dupeZ(u8, sql);
        defer self.allocator.free(sql_z);
        if (c.sqlite3_prepare_v2(self.db, sql_z.ptr, -1, &stmt, null) != c.SQLITE_OK) return error.PrepareFailed;
        defer _ = c.sqlite3_finalize(stmt);
        const rc = c.sqlite3_step(stmt.?);
        if (rc != c.SQLITE_ROW) return error.StepFailed;
        return c.sqlite3_column_int64(stmt.?, 0);
    }

    /// Current UTC time as epoch-seconds string. Caller owns.
    fn nowEpochSecs(self: *ResponseCache, allocator: std.mem.Allocator) ![]u8 {
        _ = self;
        var now_c: c.time_t = 0;
        _ = c.time(&now_c);
        return std.fmt.allocPrint(allocator, "{d}", .{now_c});
    }

    /// `now - minutes` as epoch-seconds string. Caller owns.
    fn epochMinusMinutes(self: *ResponseCache, allocator: std.mem.Allocator, minutes: i64) ![]u8 {
        _ = self;
        var now_c: c.time_t = 0;
        _ = c.time(&now_c);
        const now: i64 = @intCast(now_c);
        const cutoff = now - minutes * 60;
        return std.fmt.allocPrint(allocator, "{d}", .{cutoff});
    }
};

fn bindText(stmt: *c.sqlite3_stmt, idx: c_int, text: []const u8) !void {
    const rc = sqlite3_bind_text(stmt, idx, text.ptr, @intCast(text.len), SQLITE_TRANSIENT);
    if (rc != c.SQLITE_OK) return error.BindFailed;
}

fn columnText(stmt: *c.sqlite3_stmt, col: c_int) []const u8 {
    const ptr = c.sqlite3_column_text(stmt, col);
    const len: usize = @intCast(c.sqlite3_column_bytes(stmt, col));
    if (ptr == null or len == 0) return "";
    return @as([*]const u8, @ptrCast(ptr))[0..len];
}

// ──────────────────────────────────────────────────────────────────────────
// Tests — port the cases from src/memory/response_cache.rs:213+.
// ──────────────────────────────────────────────────────────────────────────

test "cacheKey: deterministic SHA-256 hex" {
    const a = testing.allocator;
    const k1 = try ResponseCache.cacheKey(a, "gpt-4", "sys", "hello");
    defer a.free(k1);
    const k2 = try ResponseCache.cacheKey(a, "gpt-4", "sys", "hello");
    defer a.free(k2);
    try testing.expectEqualStrings(k1, k2);
    try testing.expectEqual(@as(usize, 64), k1.len);
}

test "cacheKey: varies by model" {
    const a = testing.allocator;
    const k1 = try ResponseCache.cacheKey(a, "gpt-4", null, "hello");
    defer a.free(k1);
    const k2 = try ResponseCache.cacheKey(a, "claude-3", null, "hello");
    defer a.free(k2);
    try testing.expect(!std.mem.eql(u8, k1, k2));
}

test "cacheKey: varies by system prompt" {
    const a = testing.allocator;
    const k1 = try ResponseCache.cacheKey(a, "gpt-4", "sys-a", "hello");
    defer a.free(k1);
    const k2 = try ResponseCache.cacheKey(a, "gpt-4", "sys-b", "hello");
    defer a.free(k2);
    try testing.expect(!std.mem.eql(u8, k1, k2));
}

test "cacheKey: varies by user prompt" {
    const a = testing.allocator;
    const k1 = try ResponseCache.cacheKey(a, "gpt-4", null, "hello");
    defer a.free(k1);
    const k2 = try ResponseCache.cacheKey(a, "gpt-4", null, "world");
    defer a.free(k2);
    try testing.expect(!std.mem.eql(u8, k1, k2));
}

test "ResponseCache: put and get round-trip" {
    const a = testing.allocator;
    var cache = try ResponseCache.open(a, ":memory:", 60, 1000);
    defer cache.close();
    const key = try ResponseCache.cacheKey(a, "gpt-4", null, "hello");
    defer a.free(key);
    try cache.put(key, "gpt-4", "Hello back!", 5);
    const got = (try cache.get(a, key)) orelse return error.Miss;
    defer a.free(got);
    try testing.expectEqualStrings("Hello back!", got);
}

test "ResponseCache: miss returns null" {
    const a = testing.allocator;
    var cache = try ResponseCache.open(a, ":memory:", 60, 1000);
    defer cache.close();
    const got = try cache.get(a, "nonexistent-key");
    try testing.expect(got == null);
}

test "ResponseCache: stats reports entries + hits + tokens" {
    const a = testing.allocator;
    var cache = try ResponseCache.open(a, ":memory:", 60, 1000);
    defer cache.close();

    const k1 = try ResponseCache.cacheKey(a, "m", null, "q1");
    defer a.free(k1);
    const k2 = try ResponseCache.cacheKey(a, "m", null, "q2");
    defer a.free(k2);
    try cache.put(k1, "m", "r1", 10);
    try cache.put(k2, "m", "r2", 20);

    // Two hits on k1, one on k2.
    const g1 = (try cache.get(a, k1)) orelse return error.Miss;
    defer a.free(g1);
    const g2 = (try cache.get(a, k1)) orelse return error.Miss;
    defer a.free(g2);
    const g3 = (try cache.get(a, k2)) orelse return error.Miss;
    defer a.free(g3);

    const s = try cache.stats();
    try testing.expectEqual(@as(usize, 2), s.total_entries);
    try testing.expectEqual(@as(u64, 3), s.total_hits);
    // tokens_saved = sum(token_count * hit_count) = 10*2 + 20*1 = 40
    try testing.expectEqual(@as(u64, 40), s.total_tokens_saved);
}

test "ResponseCache: clear wipes the cache" {
    const a = testing.allocator;
    var cache = try ResponseCache.open(a, ":memory:", 60, 1000);
    defer cache.close();
    try cache.put("k1", "m", "r1", 1);
    try cache.put("k2", "m", "r2", 1);
    const removed = try cache.clear();
    try testing.expectEqual(@as(usize, 2), removed);
    const s = try cache.stats();
    try testing.expectEqual(@as(usize, 0), s.total_entries);
}

test "ResponseCache: TTL expiry returns null" {
    const a = testing.allocator;
    // ttl=0 minutes means anything stored is already expired by the time we
    // get it (created_at <= now is the cutoff).
    var cache = try ResponseCache.open(a, ":memory:", 0, 1000);
    defer cache.close();
    try cache.put("k", "m", "r", 1);
    const got = try cache.get(a, "k");
    // With TTL=0, the entry is expired immediately. (Boundary: created_at is
    // "now" and cutoff is "now - 0 min" = now; created_at > cutoff is false.)
    try testing.expect(got == null);
}

test "ResponseCache: LRU evicts over max_entries" {
    const a = testing.allocator;
    var cache = try ResponseCache.open(a, ":memory:", 60, 2);
    defer cache.close();
    try cache.put("k1", "m", "r1", 1);
    try cache.put("k2", "m", "r2", 1);
    try cache.put("k3", "m", "r3", 1); // exceeds max=2 → evicts least-recently-used
    const s = try cache.stats();
    try testing.expect(s.total_entries <= 2);
}
