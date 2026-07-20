//! SQLite-backed memory store — ports `src/memory/sqlite.rs` (1900 LOC).
//!
//! Production persistence backend for the SlowClaw Social iOS app. Uses the
//! SQLite C API directly via the vendored amalgamation (compiled by build.zig
//! from `vendor/sqlite/sqlite3.c`). iOS ships libsqlite3 natively, so the same
//! code links cleanly in both environments.
//!
//! The Rust original uses rusqlite + tokio's spawn_blocking for async I/O.
//! The Zig port is synchronous — the iOS caller is expected to run these on a
//! background queue and surface results via the C ABI (a later slice wires
//! `SqliteMemory` into the `Memory` vtable).
//!
//! Schema mirrors `init_schema` in sqlite.rs:124:
//!   - `memories(id, key, content, category, embedding, created_at, updated_at, session_id)`
//!   - `memories_fts` (FTS5 virtual table over key+content, kept in sync via triggers)
//!   - `embedding_cache(content_hash, embedding, created_at, accessed_at)` (LRU)

const std = @import("std");
const testing = std.testing;
const vector_math = @import("vector_math.zig");
const embeddings_mod = @import("embeddings.zig");
const memory_types = @import("memory_types.zig");

const c = @cImport({
    @cInclude("sqlite3.h");
    @cInclude("time.h");
    @cInclude("stdio.h");
});

const MemoryEntry = memory_types.MemoryEntry;
const MemoryCategory = memory_types.MemoryCategory;
const MemoryError = memory_types.MemoryError;

/// Errors from the SQLite layer specifically.
pub const SqliteError = error{
    OpenFailed,
    PrepareFailed,
    BindFailed,
    StepFailed,
    ExecFailed,
    NotFound,
    OutOfMemory,
};

/// SQLite-backed memory store. Owns one connection; not thread-safe (the iOS
/// caller must serialize access — typically via a single background dispatch
/// queue). Mirrors `SqliteMemory` in `src/memory/sqlite.rs:28`.
pub const SqliteMemory = struct {
    db: *c.sqlite3,
    db_path: []const u8,
    embedder: ?embeddings_mod.EmbeddingProvider,
    vector_weight: f32,
    keyword_weight: f32,
    cache_max: usize,
    allocator: std.mem.Allocator,

    /// Open (or create) a SQLite database at `path`. Pass ":memory:" for a
    /// private in-memory database (used by tests). Initializes the schema.
    pub fn open(
        allocator: std.mem.Allocator,
        path: []const u8,
        embedder: ?embeddings_mod.EmbeddingProvider,
        vector_weight: f32,
        keyword_weight: f32,
        cache_max: usize,
    ) !SqliteMemory {
        // sqlite3_open expects a null-terminated path. The path slice we hold
        // is not null-terminated; copy into a small buffer.
        const path_z = try allocator.dupeZ(u8, path);
        defer allocator.free(path_z);

        var db_handle: ?*c.sqlite3 = null;
        const rc = c.sqlite3_open(path_z.ptr, &db_handle);
        if (rc != c.SQLITE_OK or db_handle == null) {
            if (db_handle) |h| _ = c.sqlite3_close(h);
            return error.OpenFailed;
        }
        var self = SqliteMemory{
            .db = db_handle.?,
            .db_path = try allocator.dupe(u8, path),
            .embedder = embedder,
            .vector_weight = vector_weight,
            .keyword_weight = keyword_weight,
            .cache_max = cache_max,
            .allocator = allocator,
        };
        try self.initSchema();
        return self;
    }

    /// Convenience: open with NoopEmbedding-equivalent (no embedder).
    pub fn openNoEmbedder(allocator: std.mem.Allocator, path: []const u8) !SqliteMemory {
        return open(allocator, path, null, 0.7, 0.3, 1024);
    }

    pub fn close(self: *SqliteMemory) void {
        _ = c.sqlite3_close(self.db);
        self.allocator.free(self.db_path);
    }

    // ── Schema initialization ────────────────────────────────────────────

    fn initSchema(self: *SqliteMemory) !void {
        const sql =
            \\CREATE TABLE IF NOT EXISTS memories (
            \\    id          TEXT PRIMARY KEY,
            \\    key         TEXT NOT NULL UNIQUE,
            \\    content     TEXT NOT NULL,
            \\    category    TEXT NOT NULL DEFAULT 'core',
            \\    embedding   BLOB,
            \\    created_at  TEXT NOT NULL,
            \\    updated_at  TEXT NOT NULL,
            \\    session_id  TEXT
            \\);
            \\CREATE INDEX IF NOT EXISTS idx_memories_category ON memories(category);
            \\CREATE INDEX IF NOT EXISTS idx_memories_key ON memories(key);
            \\CREATE INDEX IF NOT EXISTS idx_memories_session ON memories(session_id);
            \\CREATE VIRTUAL TABLE IF NOT EXISTS memories_fts USING fts5(
            \\    key, content, content=memories, content_rowid=rowid
            \\);
            \\CREATE TRIGGER IF NOT EXISTS memories_ai AFTER INSERT ON memories BEGIN
            \\    INSERT INTO memories_fts(rowid, key, content)
            \\    VALUES (new.rowid, new.key, new.content);
            \\END;
            \\CREATE TRIGGER IF NOT EXISTS memories_ad AFTER DELETE ON memories BEGIN
            \\    INSERT INTO memories_fts(memories_fts, rowid, key, content)
            \\    VALUES ('delete', old.rowid, old.key, old.content);
            \\END;
            \\CREATE TRIGGER IF NOT EXISTS memories_au AFTER UPDATE ON memories BEGIN
            \\    INSERT INTO memories_fts(memories_fts, rowid, key, content)
            \\    VALUES ('delete', old.rowid, old.key, old.content);
            \\    INSERT INTO memories_fts(rowid, key, content)
            \\    VALUES (new.rowid, new.key, new.content);
            \\END;
            \\CREATE TABLE IF NOT EXISTS embedding_cache (
            \\    content_hash TEXT PRIMARY KEY,
            \\    embedding    BLOB NOT NULL,
            \\    created_at   TEXT NOT NULL,
            \\    accessed_at  TEXT NOT NULL
            \\);
            \\CREATE INDEX IF NOT EXISTS idx_cache_accessed ON embedding_cache(accessed_at);
        ;
        try self.exec(sql);
    }

    // ── Helpers ──────────────────────────────────────────────────────────

    fn exec(self: *SqliteMemory, sql: []const u8) !void {
        var errmsg: [*c]u8 = null;
        const sql_z = try self.allocator.dupeZ(u8, sql);
        defer self.allocator.free(sql_z);
        const rc = c.sqlite3_exec(self.db, sql_z.ptr, null, null, &errmsg);
        if (rc != c.SQLITE_OK) {
            if (errmsg) |e| c.sqlite3_free(e);
            return error.ExecFailed;
        }
    }

    /// Generate a UUIDv4-like ID (pseudo-random 128-bit hex). Mirrors Rust's
    /// `Uuid::new_v4().to_string()` for primary keys. Seeded from a global
    /// atomic counter + the call-site address to guarantee uniqueness within
    /// one process; not cryptographically strong, which is fine for
    /// non-adversarial IDs.
    fn newId(allocator: std.mem.Allocator) ![]u8 {
        const S = struct {
            var counter = std.atomic.Value(u64).init(0x9e3779b97f4a7c15); // golden ratio seed
        };
        // Mix counter + ASLR-ed stack address + caller-site pointer for entropy.
        var stack_anchor: u8 = 0;
        const ctr = S.counter.fetchAdd(0x9e3779b97f4a7c15, .monotonic);
        const addr_a: u64 = @intFromPtr(&stack_anchor);
        const addr_b: u64 = @returnAddress();
        const seed = ctr ^ addr_a ^ (addr_b << 1);

        var prng = std.Random.DefaultPrng.init(seed);
        var bytes: [16]u8 = undefined;
        prng.random().bytes(&bytes);
        // RFC 4122 v4 variant bits.
        bytes[6] = (bytes[6] & 0x0F) | 0x40;
        bytes[8] = (bytes[8] & 0x3F) | 0x80;
        // Format as 8-4-4-4-12 hex.
        return std.fmt.allocPrint(allocator, "{x:0>2}{x:0>2}{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}-{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}{x:0>2}", .{
            bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15],
        });
    }

    /// RFC3339 timestamp (UTC, second precision). Matches chrono's to_rfc3339
    /// shape closely enough for created_at/updated_at columns. Uses libc's
    /// `time()` for the epoch seconds (Zig 0.16's std.time was pared down to
    /// constants only; libc is already linked).
    fn nowRfc3339(allocator: std.mem.Allocator) ![]u8 {
        var now_c: c.time_t = 0;
        _ = c.time(&now_c);
        const ts: i64 = @intCast(now_c);
        const day_ts = ts + 719468 * 86400; // civil epoch offset
        const secs_per_day: i64 = 86400;
        const day = @divFloor(day_ts, secs_per_day);
        const tod = @mod(day_ts, secs_per_day);
        const hour = @divFloor(tod, 3600);
        const minute = @divFloor(@mod(tod, 3600), 60);
        const second = @mod(tod, 60);

        // Inverse days-from-civil (Howard Hinnant).
        const era = @divFloor(if (day >= 0) day else day - 146096, 146097);
        const doe: u64 = @intCast(day - era * 146097);
        const yoe: u64 = @divFloor(doe - @divFloor(doe, 1460) + @divFloor(doe, 36524) - @divFloor(doe, 146096), 365);
        const y: i64 = @as(i64, @intCast(yoe)) + era * 400;
        const doy: u64 = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100));
        const mp: u64 = @divFloor(5 * doy + 2, 153);
        const d: u64 = doy - @divFloor(153 * mp + 2, 5) + 1;
        const m: u64 = if (mp < 10) mp + 3 else mp - 9;
        const year: i64 = if (m <= 2) y + 1 else y;

        return std.fmt.allocPrint(allocator, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{
            year, m, d, hour, minute, second,
        });
    }

    fn categoryToText(cat: MemoryCategory) []const u8 {
        return cat.toString();
    }

    // ── Memory operations (mirrors the Memory trait impl in sqlite.rs) ───

    pub fn name(_: *SqliteMemory) []const u8 {
        return "sqlite";
    }

    /// Insert or update a memory. If `key` already exists, all fields are
    /// replaced (upsert). Mirrors `store` in sqlite.rs:439.
    pub fn store(
        self: *SqliteMemory,
        key: []const u8,
        content: []const u8,
        category: MemoryCategory,
        session_id: ?[]const u8,
    ) !void {
        const id = try newId(self.allocator);
        defer self.allocator.free(id);
        const now = try nowRfc3339(self.allocator);
        defer self.allocator.free(now);

        const cat = categoryToText(category);

        // Optional embedding blob — only when an embedder is configured AND it
        // produces a non-empty vector. Skipped for the no-embedder case.
        var embedding_bytes: ?[]const u8 = null;
        var embedding_buf: ?[]u8 = null;
        defer if (embedding_buf) |b| self.allocator.free(b);
        if (self.embedder) |emb| {
            if (embeddings_mod.HashEmbedding.embed_text(self.allocator, @ptrCast(@alignCast(emb.ctx)), content)) |vec| {
                if (vec.len > 0) {
                    embedding_buf = try self.allocator.alloc(u8, vec.len * @sizeOf(f32));
                    for (vec, 0..) |v, i| {
                        const le = std.mem.nativeToLittle(f32, v);
                        std.mem.writeInt(u32, embedding_buf.?[i * 4 ..][0..4], @bitCast(le), .little);
                    }
                    embedding_bytes = embedding_buf.?;
                }
                self.allocator.free(vec);
            } else |_| {}
        }

        const sql =
            \\INSERT INTO memories (id, key, content, category, embedding, created_at, updated_at, session_id)
            \\VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8)
            \\ON CONFLICT(key) DO UPDATE SET
            \\  content = excluded.content,
            \\  category = excluded.category,
            \\  embedding = excluded.embedding,
            \\  updated_at = excluded.updated_at,
            \\  session_id = excluded.session_id
        ;

        var stmt: ?*c.sqlite3_stmt = null;
        const sql_z = try self.allocator.dupeZ(u8, sql);
        defer self.allocator.free(sql_z);
        if (c.sqlite3_prepare_v2(self.db, sql_z.ptr, -1, &stmt, null) != c.SQLITE_OK) {
            return error.PrepareFailed;
        }
        defer _ = c.sqlite3_finalize(stmt);

        try bindText(stmt.?, 1, id);
        try bindText(stmt.?, 2, key);
        try bindText(stmt.?, 3, content);
        try bindText(stmt.?, 4, cat);
        if (embedding_bytes) |b| {
            _ = c.sqlite3_bind_blob(stmt.?, 5, b.ptr, @intCast(b.len), c.SQLITE_TRANSIENT);
        } else {
            _ = c.sqlite3_bind_null(stmt.?, 5);
        }
        try bindText(stmt.?, 6, now);
        try bindText(stmt.?, 7, now);
        if (session_id) |sid| {
            try bindText(stmt.?, 8, sid);
        } else {
            _ = c.sqlite3_bind_null(stmt.?, 8);
        }

        const rc = c.sqlite3_step(stmt.?);
        if (rc != c.SQLITE_DONE) return error.StepFailed;
    }

    /// Fetch a memory by key. Returns null if not found.
    /// Mirrors `get` in sqlite.rs:655.
    pub fn get(self: *SqliteMemory, allocator: std.mem.Allocator, key: []const u8) !?MemoryEntry {
        const sql = "SELECT id, key, content, category, created_at, session_id FROM memories WHERE key = ?1";
        var stmt: ?*c.sqlite3_stmt = null;
        const sql_z = try self.allocator.dupeZ(u8, sql);
        defer self.allocator.free(sql_z);
        if (c.sqlite3_prepare_v2(self.db, sql_z.ptr, -1, &stmt, null) != c.SQLITE_OK) return error.PrepareFailed;
        defer _ = c.sqlite3_finalize(stmt);
        try bindText(stmt.?, 1, key);

        const rc = c.sqlite3_step(stmt.?);
        if (rc == c.SQLITE_DONE) return null;
        if (rc != c.SQLITE_ROW) return error.StepFailed;

        return try readRow(allocator, stmt.?);
    }

    /// List memories, optionally filtered by category and/or session.
    /// Mirrors `list` in sqlite.rs:685. Returns at most 1000 entries.
    pub fn list(
        self: *SqliteMemory,
        allocator: std.mem.Allocator,
        category: ?MemoryCategory,
        session_id: ?[]const u8,
    ) ![]MemoryEntry {
        var results = std.ArrayList(MemoryEntry).empty;
        errdefer {
            for (results.items) |e| freeEntry(allocator, e);
            results.deinit(allocator);
        }

        var stmt: ?*c.sqlite3_stmt = null;
        const sql = if (category != null)
            "SELECT id, key, content, category, created_at, session_id FROM memories WHERE category = ?1 ORDER BY rowid DESC LIMIT 1000"
        else
            "SELECT id, key, content, category, created_at, session_id FROM memories ORDER BY rowid DESC LIMIT 1000";
        const sql_z = try self.allocator.dupeZ(u8, sql);
        defer self.allocator.free(sql_z);
        if (c.sqlite3_prepare_v2(self.db, sql_z.ptr, -1, &stmt, null) != c.SQLITE_OK) return error.PrepareFailed;
        defer _ = c.sqlite3_finalize(stmt);

        if (category) |cat| {
            try bindText(stmt.?, 1, categoryToText(cat));
        }

        while (true) {
            const rc = c.sqlite3_step(stmt.?);
            if (rc == c.SQLITE_DONE) break;
            if (rc != c.SQLITE_ROW) return error.StepFailed;
            const entry = try readRow(allocator, stmt.?);
            // Session filter applied in Zig (matches the Rust impl's approach
            // for the cross-database session_id NULL handling).
            if (session_id) |sid| {
                const matches = if (entry.session_id) |s| std.mem.eql(u8, s, sid) else false;
                if (!matches) {
                    freeEntry(allocator, entry);
                    continue;
                }
            }
            try results.append(allocator, entry);
        }

        return results.toOwnedSlice(allocator);
    }

    /// Delete a memory by key. Returns true if a row was removed.
    /// Mirrors `forget` in sqlite.rs:751.
    pub fn forget(self: *SqliteMemory, key: []const u8) !bool {
        const sql = "DELETE FROM memories WHERE key = ?1";
        var stmt: ?*c.sqlite3_stmt = null;
        const sql_z = try self.allocator.dupeZ(u8, sql);
        defer self.allocator.free(sql_z);
        if (c.sqlite3_prepare_v2(self.db, sql_z.ptr, -1, &stmt, null) != c.SQLITE_OK) return error.PrepareFailed;
        defer _ = c.sqlite3_finalize(stmt);
        try bindText(stmt.?, 1, key);
        const rc = c.sqlite3_step(stmt.?);
        if (rc != c.SQLITE_DONE) return error.StepFailed;
        return c.sqlite3_changes(self.db) > 0;
    }

    /// Count memories. Mirrors `count` in sqlite.rs:763.
    pub fn count(self: *SqliteMemory) !usize {
        const sql = "SELECT COUNT(*) FROM memories";
        var stmt: ?*c.sqlite3_stmt = null;
        const sql_z = try self.allocator.dupeZ(u8, sql);
        defer self.allocator.free(sql_z);
        if (c.sqlite3_prepare_v2(self.db, sql_z.ptr, -1, &stmt, null) != c.SQLITE_OK) return error.PrepareFailed;
        defer _ = c.sqlite3_finalize(stmt);
        const rc = c.sqlite3_step(stmt.?);
        if (rc != c.SQLITE_ROW) return error.StepFailed;
        const n = c.sqlite3_column_int64(stmt.?, 0);
        return @intCast(n);
    }

    /// Health check. Mirrors `health_check` in sqlite.rs:776.
    pub fn healthCheck(self: *SqliteMemory) bool {
        self.exec("SELECT 1") catch return false;
        return true;
    }

    /// FTS5 keyword search. Returns (id, score) pairs where score = -bm25
    /// (higher = better, matching the Rust negation).
    /// Mirrors `fts5_search` in sqlite.rs:288.
    pub fn fts5Search(
        self: *SqliteMemory,
        allocator: std.mem.Allocator,
        query: []const u8,
        limit: usize,
    ) ![]ScoredId {
        // Build "word1" OR "word2" OR ... (FTS5 quoted to escape special chars).
        var fts_query = std.ArrayList(u8).empty;
        defer fts_query.deinit(allocator);
        var first_word = true;
        var word_it = std.mem.tokenizeAny(u8, query, " \t\n\r");
        while (word_it.next()) |word| {
            if (!first_word) try fts_query.appendSlice(allocator, " OR ");
            try fts_query.append(allocator, '"');
            // Escape embedded quotes by doubling them (FTS5 SQL string rule).
            for (word) |ch| {
                if (ch == '"') try fts_query.appendSlice(allocator, "\"\"") else try fts_query.append(allocator, ch);
            }
            try fts_query.append(allocator, '"');
            first_word = false;
        }
        if (first_word) return &.{};

        const sql = "SELECT m.id, bm25(memories_fts) as score FROM memories_fts f JOIN memories m ON m.rowid = f.rowid WHERE memories_fts MATCH ?1 ORDER BY score LIMIT ?2";
        var stmt: ?*c.sqlite3_stmt = null;
        const sql_z = try self.allocator.dupeZ(u8, sql);
        defer self.allocator.free(sql_z);
        if (c.sqlite3_prepare_v2(self.db, sql_z.ptr, -1, &stmt, null) != c.SQLITE_OK) return error.PrepareFailed;
        defer _ = c.sqlite3_finalize(stmt);
        try bindText(stmt.?, 1, fts_query.items);
        _ = c.sqlite3_bind_int64(stmt.?, 2, @intCast(limit));

        var results = std.ArrayList(ScoredId).empty;
        errdefer {
            for (results.items) |s| allocator.free(s.id);
            results.deinit(allocator);
        }
        while (true) {
            const rc = c.sqlite3_step(stmt.?);
            if (rc == c.SQLITE_DONE) break;
            if (rc != c.SQLITE_ROW) return error.StepFailed;
            const id_text = columnText(stmt.?, 0);
            const id_owned = try allocator.dupe(u8, id_text);
            // BM25 returns negative (lower=better); negate so higher=better.
            const raw = c.sqlite3_column_double(stmt.?, 1);
            try results.append(allocator, .{ .id = id_owned, .score = @floatCast(-raw) });
        }
        return results.toOwnedSlice(allocator);
    }
};

pub const ScoredId = struct { id: []const u8, score: f32 };

pub fn freeScoredIds(allocator: std.mem.Allocator, ids: []ScoredId) void {
    for (ids) |s| allocator.free(s.id);
    allocator.free(ids);
}

// ──────────────────────────────────────────────────────────────────────────
// SQLite C API helpers (binding + row scanning).
// ──────────────────────────────────────────────────────────────────────────

/// Bind a non-null-terminated Zig string as a SQLite text parameter. SQLite
/// copies the bytes (SQLITE_TRANSIENT) so the caller's slice can be freed.
fn bindText(stmt: *c.sqlite3_stmt, idx: c_int, text: []const u8) !void {
    const rc = c.sqlite3_bind_text(stmt, idx, text.ptr, @intCast(text.len), c.SQLITE_TRANSIENT);
    if (rc != c.SQLITE_OK) return error.BindFailed;
}

/// Read a column as a borrowed Zig slice. The slice is valid only until the
/// next sqlite3_step / finalize on this statement.
fn columnText(stmt: *c.sqlite3_stmt, col: c_int) []const u8 {
    const ptr = c.sqlite3_column_text(stmt, col);
    const len: usize = @intCast(c.sqlite3_column_bytes(stmt, col));
    if (ptr == null or len == 0) return "";
    return @as([*]const u8, @ptrCast(ptr))[0..len];
}

/// Convert a category column string to a MemoryCategory. The returned slice
/// (for the custom case) aliases the input — caller must dupe if it needs to
/// outlive the source buffer.
fn textToCategory(s: []const u8) MemoryCategory {
    if (std.mem.eql(u8, s, "core")) return .{ .core = {} };
    if (std.mem.eql(u8, s, "daily")) return .{ .daily = {} };
    if (std.mem.eql(u8, s, "conversation")) return .{ .conversation = {} };
    return .{ .custom = s };
}

/// Read the current row of `stmt` into an owned MemoryEntry. Caller frees with
/// `freeEntry`. The optional session_id is read as null when SQL NULL.
fn readRow(allocator: std.mem.Allocator, stmt: *c.sqlite3_stmt) !MemoryEntry {
    const id = try allocator.dupe(u8, columnText(stmt, 0));
    errdefer allocator.free(id);
    const key = try allocator.dupe(u8, columnText(stmt, 1));
    errdefer allocator.free(key);
    const content = try allocator.dupe(u8, columnText(stmt, 2));
    errdefer allocator.free(content);
    const cat_text = columnText(stmt, 3);
    // textToCategory returns a slice aliased to cat_text — dupe the custom case.
    var category = textToCategory(cat_text);
    if (category == .custom) {
        category = .{ .custom = try allocator.dupe(u8, cat_text) };
    }
    const ts = try allocator.dupe(u8, columnText(stmt, 4));
    errdefer allocator.free(ts);

    var session_id: ?[]const u8 = null;
    if (c.sqlite3_column_type(stmt, 5) != c.SQLITE_NULL) {
        session_id = try allocator.dupe(u8, columnText(stmt, 5));
    }

    return .{
        .id = id,
        .key = key,
        .content = content,
        .category = category,
        .timestamp = ts,
        .session_id = session_id,
    };
}

/// Free an entry produced by `readRow`/`get`/`list`. The category's custom
/// name (if any) is also freed.
pub fn freeEntry(allocator: std.mem.Allocator, entry: MemoryEntry) void {
    allocator.free(entry.id);
    allocator.free(entry.key);
    allocator.free(entry.content);
    allocator.free(entry.timestamp);
    switch (entry.category) {
        .custom => |name| allocator.free(name),
        else => {},
    }
    if (entry.session_id) |sid| allocator.free(sid);
}

// ──────────────────────────────────────────────────────────────────────────
// Tests — port the test cases from src/memory/sqlite.rs:795-1000.
// All tests use ":memory:" databases for speed and isolation.
// ──────────────────────────────────────────────────────────────────────────

test "sqlite: name and health" {
    var db = try SqliteMemory.openNoEmbedder(testing.allocator, ":memory:");
    defer db.close();
    try testing.expectEqualStrings("sqlite", db.name());
    try testing.expect(db.healthCheck());
}

test "sqlite: store and get round-trip" {
    const a = testing.allocator;
    var db = try SqliteMemory.openNoEmbedder(a, ":memory:");
    defer db.close();

    try db.store("favorite_language", "Rust", .{ .core = {} }, null);
    const entry = (try db.get(a, "favorite_language")) orelse return error.NotFound;
    defer freeEntry(a, entry);
    try testing.expectEqualStrings("favorite_language", entry.key);
    try testing.expectEqualStrings("Rust", entry.content);
    try testing.expect(entry.category.eql(.{ .core = {} }));
}

test "sqlite: store is upsert (same key replaces)" {
    const a = testing.allocator;
    var db = try SqliteMemory.openNoEmbedder(a, ":memory:");
    defer db.close();

    try db.store("k", "v1", .{ .core = {} }, null);
    try db.store("k", "v2", .{ .daily = {} }, null);
    const entry = (try db.get(a, "k")) orelse return error.NotFound;
    defer freeEntry(a, entry);
    try testing.expectEqualStrings("v2", entry.content);
    try testing.expect(entry.category.eql(.{ .daily = {} }));
}

test "sqlite: get nonexistent returns null" {
    const a = testing.allocator;
    var db = try SqliteMemory.openNoEmbedder(a, ":memory:");
    defer db.close();
    const entry = try db.get(a, "missing");
    try testing.expect(entry == null);
}

test "sqlite: count is zero on empty database" {
    var db = try SqliteMemory.openNoEmbedder(testing.allocator, ":memory:");
    defer db.close();
    try testing.expectEqual(@as(usize, 0), try db.count());
}

test "sqlite: count reflects stored entries" {
    var db = try SqliteMemory.openNoEmbedder(testing.allocator, ":memory:");
    defer db.close();
    try db.store("k1", "c1", .{ .core = {} }, null);
    try db.store("k2", "c2", .{ .core = {} }, null);
    try db.store("k3", "c3", .{ .core = {} }, null);
    try testing.expectEqual(@as(usize, 3), try db.count());
}

test "sqlite: forget deletes by key" {
    const a = testing.allocator;
    var db = try SqliteMemory.openNoEmbedder(a, ":memory:");
    defer db.close();
    try db.store("k", "v", .{ .core = {} }, null);
    try testing.expect(try db.forget("k"));
    try testing.expect(try db.get(a, "k") == null);
}

test "sqlite: forget nonexistent returns false" {
    var db = try SqliteMemory.openNoEmbedder(testing.allocator, ":memory:");
    defer db.close();
    try testing.expect(!try db.forget("never_existed"));
}

test "sqlite: list returns all entries" {
    const a = testing.allocator;
    var db = try SqliteMemory.openNoEmbedder(a, ":memory:");
    defer db.close();
    try db.store("k1", "c1", .{ .core = {} }, null);
    try db.store("k2", "c2", .{ .daily = {} }, null);

    const entries = try db.list(a, null, null);
    defer {
        for (entries) |e| freeEntry(a, e);
        a.free(entries);
    }
    try testing.expectEqual(@as(usize, 2), entries.len);
}

test "sqlite: list filters by category" {
    const a = testing.allocator;
    var db = try SqliteMemory.openNoEmbedder(a, ":memory:");
    defer db.close();
    try db.store("k1", "c1", .{ .core = {} }, null);
    try db.store("k2", "c2", .{ .daily = {} }, null);
    try db.store("k3", "c3", .{ .daily = {} }, null);

    const daily = try db.list(a, .{ .daily = {} }, null);
    defer {
        for (daily) |e| freeEntry(a, e);
        a.free(daily);
    }
    try testing.expectEqual(@as(usize, 2), daily.len);
    for (daily) |e| try testing.expect(e.category.eql(.{ .daily = {} }));
}

test "sqlite: list filters by session_id" {
    const a = testing.allocator;
    var db = try SqliteMemory.openNoEmbedder(a, ":memory:");
    defer db.close();
    try db.store("k1", "c1", .{ .core = {} }, "session-a");
    try db.store("k2", "c2", .{ .core = {} }, "session-b");
    try db.store("k3", "c3", .{ .core = {} }, "session-a");

    const a_entries = try db.list(a, null, "session-a");
    defer {
        for (a_entries) |e| freeEntry(a, e);
        a.free(a_entries);
    }
    try testing.expectEqual(@as(usize, 2), a_entries.len);
    for (a_entries) |e| try testing.expectEqualStrings("session-a", e.session_id.?);
}

test "sqlite: session_id round-trips as null when not set" {
    const a = testing.allocator;
    var db = try SqliteMemory.openNoEmbedder(a, ":memory:");
    defer db.close();
    try db.store("k", "v", .{ .core = {} }, null);
    const entry = (try db.get(a, "k")) orelse return error.NotFound;
    defer freeEntry(a, entry);
    try testing.expect(entry.session_id == null);
}

test "sqlite: session_id round-trips when set" {
    const a = testing.allocator;
    var db = try SqliteMemory.openNoEmbedder(a, ":memory:");
    defer db.close();
    try db.store("k", "v", .{ .core = {} }, "my-session");
    const entry = (try db.get(a, "k")) orelse return error.NotFound;
    defer freeEntry(a, entry);
    try testing.expectEqualStrings("my-session", entry.session_id.?);
}

test "sqlite: category custom round-trips" {
    const a = testing.allocator;
    var db = try SqliteMemory.openNoEmbedder(a, ":memory:");
    defer db.close();
    try db.store("k", "v", .{ .custom = "project_notes" }, null);
    const entry = (try db.get(a, "k")) orelse return error.NotFound;
    defer freeEntry(a, entry);
    try testing.expect(entry.category.eql(.{ .custom = "project_notes" }));
}

test "sqlite: fts5 keyword search finds matches" {
    const a = testing.allocator;
    var db = try SqliteMemory.openNoEmbedder(a, ":memory:");
    defer db.close();
    try db.store("rust", "Rust is a systems programming language", .{ .core = {} }, null);
    try db.store("python", "Python is great for scripting", .{ .core = {} }, null);
    try db.store("rust-2", "More about the Rust programming language", .{ .core = {} }, null);

    const results = try db.fts5Search(a, "rust programming", 10);
    defer freeScoredIds(a, results);
    try testing.expect(results.len >= 2);
}

test "sqlite: fts5 search with empty query returns empty" {
    const a = testing.allocator;
    var db = try SqliteMemory.openNoEmbedder(a, ":memory:");
    defer db.close();
    try db.store("k", "some content", .{ .core = {} }, null);
    const results = try db.fts5Search(a, "   ", 10);
    try testing.expectEqual(@as(usize, 0), results.len);
}

test "sqlite: fts5 search with no match returns empty" {
    const a = testing.allocator;
    var db = try SqliteMemory.openNoEmbedder(a, ":memory:");
    defer db.close();
    try db.store("k", "hello world", .{ .core = {} }, null);
    const results = try db.fts5Search(a, "nonexistentword", 10);
    defer freeScoredIds(a, results);
    try testing.expectEqual(@as(usize, 0), results.len);
}

test "sqlite: database persists across close (file-backed)" {
    const a = testing.allocator;
    const tmp_path = "test-sqlite-persist.db";
    {
        var db = try SqliteMemory.openNoEmbedder(a, tmp_path);
        try db.store("k", "persisted-value", .{ .core = {} }, null);
        db.close();
    }
    defer _ = c.remove(tmp_path);

    var db2 = try SqliteMemory.openNoEmbedder(a, tmp_path);
    defer db2.close();
    const entry = (try db2.get(a, "k")) orelse return error.NotFound;
    defer freeEntry(a, entry);
    try testing.expectEqualStrings("persisted-value", entry.content);
}

test "sqlite: newId generates distinct 36-char hex UUIDs" {
    const a = testing.allocator;
    const id1 = try SqliteMemory.newId(a);
    defer a.free(id1);
    const id2 = try SqliteMemory.newId(a);
    defer a.free(id2);
    try testing.expectEqual(@as(usize, 36), id1.len);
    try testing.expect(!std.mem.eql(u8, id1, id2));
    // 8-4-4-4-12 dashes.
    try testing.expectEqual(@as(u8, '-'), id1[8]);
    try testing.expectEqual(@as(u8, '-'), id1[13]);
    try testing.expectEqual(@as(u8, '-'), id1[18]);
    try testing.expectEqual(@as(u8, '-'), id1[23]);
}
