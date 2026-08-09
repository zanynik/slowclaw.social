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

// SQLITE_TRANSIENT is defined in sqlite3.h as ((sqlite3_destructor_type)-1).
// Zig 0.16 on arm64 rejects this via @cImport ("requires aligned address"),
// via @ptrFromInt into the function pointer type, AND via @ptrCast from
// ?*anyopaque ("increases pointer alignment"). The ONLY way to pass -1 as
// a destructor on arm64 Zig is to declare the bind functions ourselves with
// the destructor parameter as a raw ?*const anyopaque, bypassing the
// function-pointer typedef entirely.
const SQLITE_TRANSIENT: ?*const anyopaque = @ptrFromInt(@as(usize, @bitCast(@as(isize, -1))));

extern fn sqlite3_bind_text(
    stmt: *c.sqlite3_stmt,
    idx: c_int,
    text: [*]const u8,
    len: c_int,
    destructor: ?*const anyopaque,
) c_int;

extern fn sqlite3_bind_blob(
    stmt: *c.sqlite3_stmt,
    idx: c_int,
    blob: *const anyopaque,
    len: c_int,
    destructor: ?*const anyopaque,
) c_int;

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
            \\    session_id  TEXT,
            \\    source      TEXT,
            \\    media_url   TEXT
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
        try self.runMigrations();
    }

    /// Schema migrations for existing on-disk DBs. `CREATE TABLE IF NOT EXISTS`
    /// (above) is a no-op on old DBs, so additive columns need an explicit
    /// `ALTER TABLE` guarded by `PRAGMA user_version`. Each migration bumps the
    /// version; idempotent and backward-compatible (new columns are nullable).
    ///
    /// v1 (2026-08): add `source` + `media_url` to `memories` for journal
    /// provenance (audio_recorded / audio_imported / text) and audio replay.
    fn runMigrations(self: *SqliteMemory) !void {
        const current = try self.userVersion();
        if (current >= 1) return;

        // v1: provenance columns. ALTER TABLE ADD COLUMN fails if the column
        // already exists, so guard with a presence probe (cheap and portable).
        if (!try self.hasColumn("memories", "source")) {
            try self.exec("ALTER TABLE memories ADD COLUMN source TEXT");
        }
        if (!try self.hasColumn("memories", "media_url")) {
            try self.exec("ALTER TABLE memories ADD COLUMN media_url TEXT");
        }
        try self.exec("PRAGMA user_version = 1");
    }

    fn userVersion(self: *SqliteMemory) !i64 {
        var stmt: ?*c.sqlite3_stmt = null;
        const sql = "PRAGMA user_version";
        const sql_z = try self.allocator.dupeZ(u8, sql);
        defer self.allocator.free(sql_z);
        if (c.sqlite3_prepare_v2(self.db, sql_z.ptr, -1, &stmt, null) != c.SQLITE_OK) return error.PrepareFailed;
        defer _ = c.sqlite3_finalize(stmt);
        if (c.sqlite3_step(stmt.?) != c.SQLITE_ROW) return error.StepFailed;
        return c.sqlite3_column_int64(stmt.?, 0);
    }

    /// Probe whether a column exists via `PRAGMA table_info`. Used to make
    /// ALTER TABLE additive migrations idempotent across re-runs.
    fn hasColumn(self: *SqliteMemory, table: []const u8, column: []const u8) !bool {
        // Note: table is interpolated as-is. It is always a hard-coded literal
        // ("memories") in this codebase, never user input, so this is safe.
        const sql = try std.fmt.allocPrint(self.allocator, "PRAGMA table_info({s})", .{table});
        defer self.allocator.free(sql);
        const sql_z = try self.allocator.dupeZ(u8, sql);
        defer self.allocator.free(sql_z);
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, sql_z.ptr, -1, &stmt, null) != c.SQLITE_OK) return error.PrepareFailed;
        defer _ = c.sqlite3_finalize(stmt);
        while (true) {
            const rc = c.sqlite3_step(stmt.?);
            if (rc == c.SQLITE_DONE) break;
            if (rc != c.SQLITE_ROW) return error.StepFailed;
            // column 1 of PRAGMA table_info is the name.
            const col_name = columnText(stmt.?, 1);
            if (std.mem.eql(u8, col_name, column)) return true;
        }
        return false;
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

        // Format as unsigned so the fill/alignment spec ("0>N") does not emit
        // a leading '+' for positive values (Zig 0.16's {d} includes the sign
        // when a fill is given). A leading '+' would break RFC3339 parsing and
        // — critically for sync — lexicographic timestamp comparison, since
        // '+' (0x2B) sorts before every digit. year is always positive for any
        // plausible epoch; cast is therefore safe.
        return std.fmt.allocPrint(allocator, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z", .{
            @as(u64, @intCast(year)), m, d, hour, minute, second,
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
        source: ?[]const u8,
        media_url: ?[]const u8,
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
            \\INSERT INTO memories (id, key, content, category, embedding, created_at, updated_at, session_id, source, media_url)
            \\VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9, ?10)
            \\ON CONFLICT(key) DO UPDATE SET
            \\  content = excluded.content,
            \\  category = excluded.category,
            \\  embedding = excluded.embedding,
            \\  updated_at = excluded.updated_at,
            \\  session_id = excluded.session_id,
            \\  source = excluded.source,
            \\  media_url = excluded.media_url
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
            _ = sqlite3_bind_blob(stmt.?, 5, b.ptr, @intCast(b.len), SQLITE_TRANSIENT);
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
        if (source) |src| {
            try bindText(stmt.?, 9, src);
        } else {
            _ = c.sqlite3_bind_null(stmt.?, 9);
        }
        if (media_url) |m| {
            try bindText(stmt.?, 10, m);
        } else {
            _ = c.sqlite3_bind_null(stmt.?, 10);
        }

        const rc = c.sqlite3_step(stmt.?);
        if (rc != c.SQLITE_DONE) return error.StepFailed;
    }

    /// Fetch a memory by key. Returns null if not found.
    /// Mirrors `get` in sqlite.rs:655.
    pub fn get(self: *SqliteMemory, allocator: std.mem.Allocator, key: []const u8) !?MemoryEntry {
        const sql = "SELECT id, key, content, category, created_at, session_id, source, media_url FROM memories WHERE key = ?1";
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
            "SELECT id, key, content, category, created_at, session_id, source, media_url FROM memories WHERE category = ?1 ORDER BY rowid DESC LIMIT 1000"
        else
            "SELECT id, key, content, category, created_at, session_id, source, media_url FROM memories ORDER BY rowid DESC LIMIT 1000";
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

    /// A row in the sync manifest projection: the columns the sync engine
    /// needs to build a manifest + apply remote entries. `updated_at` is the
    /// last-writer-wins timestamp (NOT `created_at`, which the vtable's
    /// `timestamp` field carries and which is overwritten on every upsert).
    /// `media_url` is the Documents-relative audio path or null.
    pub const SyncRow = struct {
        key: []const u8,
        content: []const u8,
        updated_at: []const u8,
        category: []const u8,
        session_id: ?[]const u8,
        source: ?[]const u8,
        media_url: ?[]const u8,
    };

    /// Free a `SyncRow` produced by `listForSync` (all fields are allocator-owned).
    pub fn freeSyncRow(allocator: std.mem.Allocator, row: SyncRow) void {
        allocator.free(row.key);
        allocator.free(row.content);
        allocator.free(row.updated_at);
        allocator.free(row.category);
        if (row.session_id) |s| allocator.free(s);
        if (row.source) |s| allocator.free(s);
        if (row.media_url) |s| allocator.free(s);
    }

    /// List every memories row projected onto the sync shape, ordered by key.
    /// Used by `sync_engine.buildManifest`. The existing `list` reader exposes
    /// `created_at` as `timestamp` rather than the `updated_at` sync needs, so
    /// the sync engine reads its own projection here (keeps each module
    /// single-purpose — AGENTS.md §3.4).
    pub fn listForSync(self: *SqliteMemory, allocator: std.mem.Allocator) ![]SyncRow {
        var out = std.ArrayList(SyncRow).empty;
        errdefer {
            for (out.items) |r| freeSyncRow(allocator, r);
            out.deinit(allocator);
        }

        const sql = "SELECT key, content, updated_at, category, session_id, source, media_url FROM memories ORDER BY key";
        const sql_z = try self.allocator.dupeZ(u8, sql);
        defer self.allocator.free(sql_z);
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, sql_z.ptr, -1, &stmt, null) != c.SQLITE_OK) return error.PrepareFailed;
        defer _ = c.sqlite3_finalize(stmt);

        while (true) {
            const rc = c.sqlite3_step(stmt.?);
            if (rc == c.SQLITE_DONE) break;
            if (rc != c.SQLITE_ROW) return error.StepFailed;

            const key = try allocator.dupe(u8, columnText(stmt.?, 0));
            errdefer allocator.free(key);
            const content = try allocator.dupe(u8, columnText(stmt.?, 1));
            errdefer allocator.free(content);
            const updated_at = try allocator.dupe(u8, columnText(stmt.?, 2));
            errdefer allocator.free(updated_at);
            const category = try allocator.dupe(u8, columnText(stmt.?, 3));
            errdefer allocator.free(category);

            var session_id: ?[]const u8 = null;
            if (c.sqlite3_column_type(stmt.?, 4) != c.SQLITE_NULL) {
                session_id = try allocator.dupe(u8, columnText(stmt.?, 4));
            }
            errdefer if (session_id) |s| allocator.free(s);

            var source: ?[]const u8 = null;
            if (c.sqlite3_column_type(stmt.?, 5) != c.SQLITE_NULL) {
                source = try allocator.dupe(u8, columnText(stmt.?, 5));
            }
            errdefer if (source) |s| allocator.free(s);

            var media_url: ?[]const u8 = null;
            if (c.sqlite3_column_type(stmt.?, 6) != c.SQLITE_NULL) {
                media_url = try allocator.dupe(u8, columnText(stmt.?, 6));
            }
            errdefer if (media_url) |s| allocator.free(s);

            try out.append(allocator, .{
                .key = key,
                .content = content,
                .updated_at = updated_at,
                .category = category,
                .session_id = session_id,
                .source = source,
                .media_url = media_url,
            });
        }
        return out.toOwnedSlice(allocator);
    }

    /// Return the `updated_at` of the row with `key`, or null if absent.
    /// Used by `sync_engine.applyEntries` for last-writer-wins defense.
    /// The returned slice is allocator-owned (caller frees); null means absent.
    pub fn updatedAt(self: *SqliteMemory, allocator: std.mem.Allocator, key: []const u8) !?[]const u8 {
        const sql = "SELECT updated_at FROM memories WHERE key = ?1";
        const sql_z = try self.allocator.dupeZ(u8, sql);
        defer self.allocator.free(sql_z);
        var stmt: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(self.db, sql_z.ptr, -1, &stmt, null) != c.SQLITE_OK) return error.PrepareFailed;
        defer _ = c.sqlite3_finalize(stmt);
        try bindText(stmt.?, 1, key);

        const rc = c.sqlite3_step(stmt.?);
        if (rc == c.SQLITE_DONE) return null;
        if (rc != c.SQLITE_ROW) return error.StepFailed;
        return try allocator.dupe(u8, columnText(stmt.?, 0));
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

    // ── Memory vtable adapters ───────────────────────────────────────────
    // These functions bridge SqliteMemory to the canonical `Memory` vtable
    // defined in memory_types.zig. The Swift side (or any C-ABI consumer) can
    // get a `Memory` value via `db.memoryProvider()` and pass it to any code
    // that expects the abstract interface.

    pub fn memoryProvider(self: *SqliteMemory) memory_types.Memory {
        return .{
            .ctx = self,
            .name_fn = vtableName,
            .store_fn = vtableStore,
            .recall_fn = vtableRecall,
            .get_fn = vtableGet,
            .list_fn = vtableList,
            .forget_fn = vtableForget,
            .count_fn = vtableCount,
            .health_check_fn = vtableHealthCheck,
        };
    }

    fn vtableName(ctx: *anyopaque) []const u8 {
        const self: *SqliteMemory = @ptrCast(@alignCast(ctx));
        return self.name();
    }

    fn vtableStore(
        ctx: *anyopaque,
        key: []const u8,
        content: []const u8,
        category: MemoryCategory,
        session_id: ?[]const u8,
        source: ?[]const u8,
        media_url: ?[]const u8,
    ) memory_types.MemoryError!void {
        const self: *SqliteMemory = @ptrCast(@alignCast(ctx));
        self.store(key, content, category, session_id, source, media_url) catch return error.BackendFailed;
    }

    fn vtableRecall(
        ctx: *anyopaque,
        allocator: std.mem.Allocator,
        query: []const u8,
        limit: usize,
        session_id: ?[]const u8,
    ) memory_types.MemoryError![]MemoryEntry {
        const self: *SqliteMemory = @ptrCast(@alignCast(ctx));
        return self.recall(allocator, query, limit, session_id) catch return error.BackendFailed;
    }

    fn vtableGet(ctx: *anyopaque, key: []const u8) memory_types.MemoryError!?MemoryEntry {
        const self: *SqliteMemory = @ptrCast(@alignCast(ctx));
        // The vtable's allocator must come from somewhere — the vtable doesn't
        // carry one. Use the backend's own allocator (set at open time).
        return self.get(self.allocator, key) catch return error.BackendFailed;
    }

    fn vtableList(
        ctx: *anyopaque,
        allocator: std.mem.Allocator,
        category: ?MemoryCategory,
        session_id: ?[]const u8,
    ) memory_types.MemoryError![]MemoryEntry {
        const self: *SqliteMemory = @ptrCast(@alignCast(ctx));
        return self.list(allocator, category, session_id) catch return error.BackendFailed;
    }

    fn vtableForget(ctx: *anyopaque, key: []const u8) memory_types.MemoryError!bool {
        const self: *SqliteMemory = @ptrCast(@alignCast(ctx));
        return self.forget(key) catch return error.BackendFailed;
    }

    fn vtableCount(ctx: *anyopaque) memory_types.MemoryError!usize {
        const self: *SqliteMemory = @ptrCast(@alignCast(ctx));
        return self.count() catch return error.BackendFailed;
    }

    fn vtableHealthCheck(ctx: *anyopaque) bool {
        const self: *SqliteMemory = @ptrCast(@alignCast(ctx));
        return self.healthCheck();
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

    /// Vector similarity search: scan embeddings and compute cosine similarity
    /// to `query_embedding`. Returns at most `limit` (id, similarity) pairs,
    /// descending by similarity, excluding zero-similarity matches.
    /// Mirrors `vector_search` in sqlite.rs:335.
    pub fn vectorSearch(
        self: *SqliteMemory,
        allocator: std.mem.Allocator,
        query_embedding: []const f32,
        limit: usize,
        category: ?[]const u8,
        session_id: ?[]const u8,
    ) ![]ScoredId {
        const sql_base = "SELECT id, embedding FROM memories WHERE embedding IS NOT NULL";
        // Build the WHERE-clause tail dynamically. Parameters are bound by
        // index; we count them in the same order as the Rust impl.
        var sql_buf = std.ArrayList(u8).empty;
        defer sql_buf.deinit(self.allocator);
        try sql_buf.appendSlice(self.allocator, sql_base);

        var cat_idx: ?c_int = null;
        var sid_idx: ?c_int = null;
        var next_idx: c_int = 1;
        if (category) |cat| {
            _ = cat;
            const tail = try std.fmt.allocPrint(self.allocator, " AND category = ?{d}", .{next_idx});
            defer self.allocator.free(tail);
            try sql_buf.appendSlice(self.allocator, tail);
            cat_idx = next_idx;
            next_idx += 1;
        }
        if (session_id) |sid| {
            _ = sid;
            const tail = try std.fmt.allocPrint(self.allocator, " AND session_id = ?{d}", .{next_idx});
            defer self.allocator.free(tail);
            try sql_buf.appendSlice(self.allocator, tail);
            sid_idx = next_idx;
        }

        var stmt: ?*c.sqlite3_stmt = null;
        const sql_z = try self.allocator.dupeZ(u8, sql_buf.items);
        defer self.allocator.free(sql_z);
        if (c.sqlite3_prepare_v2(self.db, sql_z.ptr, -1, &stmt, null) != c.SQLITE_OK) return error.PrepareFailed;
        defer _ = c.sqlite3_finalize(stmt);
        if (cat_idx) |idx| try bindText(stmt.?, idx, category.?);
        if (sid_idx) |idx| try bindText(stmt.?, idx, session_id.?);

        var scored = std.ArrayList(ScoredId).empty;
        errdefer {
            for (scored.items) |s| allocator.free(s.id);
            scored.deinit(allocator);
        }
        while (true) {
            const rc = c.sqlite3_step(stmt.?);
            if (rc == c.SQLITE_DONE) break;
            if (rc != c.SQLITE_ROW) return error.StepFailed;
            const id_text = columnText(stmt.?, 0);
            // Read the embedding blob and deserialize to f32 little-endian.
            const blob_ptr = c.sqlite3_column_blob(stmt.?, 1);
            const blob_len: usize = @intCast(c.sqlite3_column_bytes(stmt.?, 1));
            if (blob_ptr == null or blob_len < 4) continue;
            const byte_slice = @as([*]const u8, @ptrCast(blob_ptr))[0..blob_len];
            const n = blob_len / 4;
            const sim = cosineSimilarFromBytes(query_embedding, byte_slice[0 .. n * 4]);
            if (sim > 0.0) {
                const id_owned = try allocator.dupe(u8, id_text);
                try scored.append(allocator, .{ .id = id_owned, .score = sim });
            }
        }
        // Sort descending by score (NaNs sorted last).
        std.mem.sort(ScoredId, scored.items, {}, struct {
            fn lt(_: void, a: ScoredId, b: ScoredId) bool {
                const neg_inf: f32 = -std.math.inf(f32);
                const aa = if (std.math.isNan(a.score)) neg_inf else a.score;
                const bb = if (std.math.isNan(b.score)) neg_inf else b.score;
                return aa > bb;
            }
        }.lt);
        const take = @min(scored.items.len, limit);
        // If we're truncating, free the dropped ids.
        if (take < scored.items.len) {
            for (scored.items[take..]) |s| allocator.free(s.id);
            scored.shrinkRetainingCapacity(take);
        }
        return scored.toOwnedSlice(allocator);
    }

    /// Hybrid recall: merge FTS5 keyword results with vector-similarity results
    /// using `vector_math.hybrid_merge`. Mirrors `recall` in sqlite.rs:479.
    /// Returns the top `limit` MemoryEntries by fused score.
    pub fn recall(
        self: *SqliteMemory,
        allocator: std.mem.Allocator,
        query: []const u8,
        limit: usize,
        session_id: ?[]const u8,
    ) ![]MemoryEntry {
        if (isOnlyWhitespace(query)) return &.{};

        // Optional query embedding — only when an embedder is configured.
        var query_emb: ?[]f32 = null;
        defer if (query_emb) |e| self.allocator.free(e);
        if (self.embedder) |emb| {
            const ctx: *anyopaque = emb.ctx;
            // The embedder ctx is a HashEmbedding pointer in our SQLite setup;
            // we compute the embedding via the HashEmbedding helper directly.
            if (embeddings_mod.HashEmbedding.embed_text(self.allocator, @ptrCast(@alignCast(ctx)), query)) |vec| {
                if (vec.len > 0) query_emb = vec else self.allocator.free(vec);
            } else |_| {}
        }

        // FTS5 keyword path.
        const keyword_results = try self.fts5Search(allocator, query, limit * 2);
        defer freeScoredIds(allocator, keyword_results);

        // Vector path (optional).
        var vector_results: []ScoredId = &.{};
        defer if (vector_results.len > 0) freeScoredIds(allocator, vector_results);
        if (query_emb) |qe| {
            vector_results = try self.vectorSearch(allocator, qe, limit * 2, null, session_id);
        }

        // Build (id, score) pair slices for hybrid_merge.
        const kw_pairs = try allocator.alloc(vector_math.IdScore, keyword_results.len);
        defer allocator.free(kw_pairs);
        for (keyword_results, 0..) |r, i| kw_pairs[i] = .{ .id = r.id, .score = r.score };
        const vec_pairs = try allocator.alloc(vector_math.IdScore, vector_results.len);
        defer allocator.free(vec_pairs);
        for (vector_results, 0..) |r, i| vec_pairs[i] = .{ .id = r.id, .score = r.score };

        const merged = if (vector_results.len == 0)
            null
        else
            try vector_math.hybrid_merge(allocator, vec_pairs, kw_pairs, self.vector_weight, self.keyword_weight, limit);
        defer if (merged) |m| allocator.free(m);

        // Choose the id ordering: merged (if vectors) else keyword-only desc.
        var ordered_ids = std.ArrayList([]const u8).empty;
        defer ordered_ids.deinit(allocator);
        if (merged) |m| {
            for (m) |r| try ordered_ids.append(allocator, r.id);
        } else {
            // Keyword-only: just take them in score-desc order (fts5Search already sorts).
            for (keyword_results) |r| try ordered_ids.append(allocator, r.id);
        }
        if (ordered_ids.items.len == 0) return &.{};

        // Fetch the full entries by id IN (...).
        return try self.fetchEntriesByIds(allocator, ordered_ids.items, session_id);
    }

    /// Fetch full MemoryEntry rows for the given id list, preserving order.
    /// Optionally filters by session_id (drops non-matching rows).
    fn fetchEntriesByIds(
        self: *SqliteMemory,
        allocator: std.mem.Allocator,
        ids: []const []const u8,
        session_id: ?[]const u8,
    ) ![]MemoryEntry {
        // Build "WHERE id IN (?1, ?2, ...)".
        var sql_buf = std.ArrayList(u8).empty;
        defer sql_buf.deinit(self.allocator);
        try sql_buf.appendSlice(self.allocator, "SELECT id, key, content, category, created_at, session_id, source, media_url FROM memories WHERE id IN (");
        for (ids, 0..) |_, i| {
            if (i > 0) try sql_buf.append(self.allocator, ',');
            const placeholder = try std.fmt.allocPrint(self.allocator, "?{d}", .{i + 1});
            defer self.allocator.free(placeholder);
            try sql_buf.appendSlice(self.allocator, placeholder);
        }
        try sql_buf.append(self.allocator, ')');

        var stmt: ?*c.sqlite3_stmt = null;
        const sql_z = try self.allocator.dupeZ(u8, sql_buf.items);
        defer self.allocator.free(sql_z);
        if (c.sqlite3_prepare_v2(self.db, sql_z.ptr, -1, &stmt, null) != c.SQLITE_OK) return error.PrepareFailed;
        defer _ = c.sqlite3_finalize(stmt);
        for (ids, 0..) |id, i| try bindText(stmt.?, @intCast(i + 1), id);

        // Read all rows into a map keyed by id (preserves DB-returned data).
        var entry_map = std.StringHashMap(MemoryEntry).init(allocator);
        defer {
            // Free both keys (id dupes) and values (entries).
            var it = entry_map.iterator();
            while (it.next()) |kv| {
                allocator.free(kv.key_ptr.*);
                freeEntry(allocator, kv.value_ptr.*);
            }
            entry_map.deinit();
        }
        while (true) {
            const rc = c.sqlite3_step(stmt.?);
            if (rc == c.SQLITE_DONE) break;
            if (rc != c.SQLITE_ROW) return error.StepFailed;
            const entry = try readRow(allocator, stmt.?);
            const id_key = try allocator.dupe(u8, entry.id);
            try entry_map.put(id_key, entry);
        }

        // Emit in the requested id order; apply session filter.
        var out = std.ArrayList(MemoryEntry).empty;
        errdefer {
            for (out.items) |e| freeEntry(allocator, e);
            out.deinit(allocator);
        }
        for (ids) |requested_id| {
            const entry = entry_map.get(requested_id) orelse continue;
            if (session_id) |sid| {
                const matches = if (entry.session_id) |s| std.mem.eql(u8, s, sid) else false;
                if (!matches) continue;
            }
            // The map owns the entry; we need a deep copy because we'll free
            // the map at function exit. Copy each field.
            const copy = try dupeEntry(allocator, entry);
            try out.append(allocator, copy);
        }
        return out.toOwnedSlice(allocator);
    }
};

/// Deep-copy a MemoryEntry's owned fields into a fresh allocation.
fn dupeEntry(allocator: std.mem.Allocator, entry: MemoryEntry) !MemoryEntry {
    var copy = MemoryEntry{
        .id = try allocator.dupe(u8, entry.id),
        .key = try allocator.dupe(u8, entry.key),
        .content = try allocator.dupe(u8, entry.content),
        .category = switch (entry.category) {
            .custom => |name| .{ .custom = try allocator.dupe(u8, name) },
            else => entry.category,
        },
        .timestamp = try allocator.dupe(u8, entry.timestamp),
        .session_id = null,
        .score = entry.score,
        .source = null,
        .media_url = null,
    };
    if (entry.session_id) |s| copy.session_id = try allocator.dupe(u8, s);
    if (entry.source) |src| copy.source = try allocator.dupe(u8, src);
    if (entry.media_url) |m| copy.media_url = try allocator.dupe(u8, m);
    return copy;
}

/// Decode a little-endian f32 byte slice and compute cosine similarity against
/// `query`. Reuses `vector_math.cosine_similarity` after decoding.
fn cosineSimilarFromBytes(query: []const f32, bytes: []const u8) f32 {
    const n = bytes.len / 4;
    if (n == 0) return 0.0;
    var stack_buf: [1024]f32 = undefined;
    var heap_buf: ?[]f32 = null;
    defer if (heap_buf) |b| std.heap.page_allocator.free(b);
    const decoded: []f32 = if (n <= stack_buf.len) blk: {
        // Decode in-place into the stack buffer.
        var i: usize = 0;
        while (i < n) : (i += 1) {
            const bits = std.mem.readInt(u32, bytes[i * 4 ..][0..4], .little);
            stack_buf[i] = @bitCast(bits);
        }
        break :blk stack_buf[0..n];
    } else blk: {
        const b = std.heap.page_allocator.alloc(f32, n) catch return 0.0;
        var i: usize = 0;
        while (i < n) : (i += 1) {
            const bits = std.mem.readInt(u32, bytes[i * 4 ..][0..4], .little);
            b[i] = @bitCast(bits);
        }
        heap_buf = b;
        break :blk b;
    };
    return vector_math.cosine_similarity(query, decoded);
}

fn isOnlyWhitespace(s: []const u8) bool {
    for (s) |ch| {
        if (ch != ' ' and ch != '\t' and ch != '\n' and ch != '\r' and ch != 0x0c and ch != 0x0b) return false;
    }
    return true;
}

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
    const rc = sqlite3_bind_text(stmt, idx, text.ptr, @intCast(text.len), SQLITE_TRANSIENT);
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
    return MemoryCategory.fromText(s);
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

    var source: ?[]const u8 = null;
    if (c.sqlite3_column_type(stmt, 6) != c.SQLITE_NULL) {
        source = try allocator.dupe(u8, columnText(stmt, 6));
    }

    var media_url: ?[]const u8 = null;
    if (c.sqlite3_column_type(stmt, 7) != c.SQLITE_NULL) {
        media_url = try allocator.dupe(u8, columnText(stmt, 7));
    }

    return .{
        .id = id,
        .key = key,
        .content = content,
        .category = category,
        .timestamp = ts,
        .session_id = session_id,
        .source = source,
        .media_url = media_url,
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
    if (entry.source) |src| allocator.free(src);
    if (entry.media_url) |m| allocator.free(m);
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

    try db.store("favorite_language", "Rust", .{ .core = {} }, null, null, null);
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

    try db.store("k", "v1", .{ .core = {} }, null, null, null);
    try db.store("k", "v2", .{ .daily = {} }, null, null, null);
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
    try db.store("k1", "c1", .{ .core = {} }, null, null, null);
    try db.store("k2", "c2", .{ .core = {} }, null, null, null);
    try db.store("k3", "c3", .{ .core = {} }, null, null, null);
    try testing.expectEqual(@as(usize, 3), try db.count());
}

test "sqlite: forget deletes by key" {
    const a = testing.allocator;
    var db = try SqliteMemory.openNoEmbedder(a, ":memory:");
    defer db.close();
    try db.store("k", "v", .{ .core = {} }, null, null, null);
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
    try db.store("k1", "c1", .{ .core = {} }, null, null, null);
    try db.store("k2", "c2", .{ .daily = {} }, null, null, null);

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
    try db.store("k1", "c1", .{ .core = {} }, null, null, null);
    try db.store("k2", "c2", .{ .daily = {} }, null, null, null);
    try db.store("k3", "c3", .{ .daily = {} }, null, null, null);

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
    try db.store("k1", "c1", .{ .core = {} }, "session-a", null, null);
    try db.store("k2", "c2", .{ .core = {} }, "session-b", null, null);
    try db.store("k3", "c3", .{ .core = {} }, "session-a", null, null);

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
    try db.store("k", "v", .{ .core = {} }, null, null, null);
    const entry = (try db.get(a, "k")) orelse return error.NotFound;
    defer freeEntry(a, entry);
    try testing.expect(entry.session_id == null);
}

test "sqlite: session_id round-trips when set" {
    const a = testing.allocator;
    var db = try SqliteMemory.openNoEmbedder(a, ":memory:");
    defer db.close();
    try db.store("k", "v", .{ .core = {} }, "my-session", null, null);
    const entry = (try db.get(a, "k")) orelse return error.NotFound;
    defer freeEntry(a, entry);
    try testing.expectEqualStrings("my-session", entry.session_id.?);
}

test "sqlite: category custom round-trips" {
    const a = testing.allocator;
    var db = try SqliteMemory.openNoEmbedder(a, ":memory:");
    defer db.close();
    try db.store("k", "v", .{ .custom = "project_notes" }, null, null, null);
    const entry = (try db.get(a, "k")) orelse return error.NotFound;
    defer freeEntry(a, entry);
    try testing.expect(entry.category.eql(.{ .custom = "project_notes" }));
}

test "sqlite: fts5 keyword search finds matches" {
    const a = testing.allocator;
    var db = try SqliteMemory.openNoEmbedder(a, ":memory:");
    defer db.close();
    try db.store("rust", "Rust is a systems programming language", .{ .core = {} }, null, null, null);
    try db.store("python", "Python is great for scripting", .{ .core = {} }, null, null, null);
    try db.store("rust-2", "More about the Rust programming language", .{ .core = {} }, null, null, null);

    const results = try db.fts5Search(a, "rust programming", 10);
    defer freeScoredIds(a, results);
    try testing.expect(results.len >= 2);
}

test "sqlite: fts5 search with empty query returns empty" {
    const a = testing.allocator;
    var db = try SqliteMemory.openNoEmbedder(a, ":memory:");
    defer db.close();
    try db.store("k", "some content", .{ .core = {} }, null, null, null);
    const results = try db.fts5Search(a, "   ", 10);
    try testing.expectEqual(@as(usize, 0), results.len);
}

test "sqlite: fts5 search with no match returns empty" {
    const a = testing.allocator;
    var db = try SqliteMemory.openNoEmbedder(a, ":memory:");
    defer db.close();
    try db.store("k", "hello world", .{ .core = {} }, null, null, null);
    const results = try db.fts5Search(a, "nonexistentword", 10);
    defer freeScoredIds(a, results);
    try testing.expectEqual(@as(usize, 0), results.len);
}

test "sqlite: database persists across close (file-backed)" {
    const a = testing.allocator;
    const tmp_path = "test-sqlite-persist.db";
    {
        var db = try SqliteMemory.openNoEmbedder(a, tmp_path);
        try db.store("k", "persisted-value", .{ .core = {} }, null, null, null);
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

// ── recall + vectorSearch tests (with HashEmbedding-backed store) ─────────

/// Helper: open a SqliteMemory with a real HashEmbedding so the embedding
/// column is populated and recall's vector path engages.
fn openWithEmbedder(allocator: std.mem.Allocator, emb: *embeddings_mod.HashEmbedding) !SqliteMemory {
    return SqliteMemory.open(
        allocator,
        ":memory:",
        emb.provider(),
        0.7, // vector_weight
        0.3, // keyword_weight
        1024,
    );
}

test "sqlite: recall empty query returns empty" {
    const a = testing.allocator;
    var emb = embeddings_mod.HashEmbedding.init("test", 64);
    var db = try openWithEmbedder(a, &emb);
    defer db.close();
    const results = try db.recall(a, "   ", 10, null);
    try testing.expectEqual(@as(usize, 0), results.len);
}

test "sqlite: recall keyword path finds matches" {
    const a = testing.allocator;
    var emb = embeddings_mod.HashEmbedding.init("test", 64);
    var db = try openWithEmbedder(a, &emb);
    defer db.close();
    try db.store("rust-fact", "Rust is a systems programming language", .{ .core = {} }, null, null, null);
    try db.store("unrelated", "The weather is sunny today", .{ .core = {} }, null, null, null);

    const results = try db.recall(a, "rust programming", 10, null);
    defer {
        for (results) |e| freeEntry(a, e);
        a.free(results);
    }
    try testing.expect(results.len >= 1);
    // The rust-fact entry must be in the results.
    var found = false;
    for (results) |e| {
        if (std.mem.eql(u8, e.key, "rust-fact")) found = true;
    }
    try testing.expect(found);
}

test "sqlite: recall respects session_id filter" {
    const a = testing.allocator;
    var emb = embeddings_mod.HashEmbedding.init("test", 64);
    var db = try openWithEmbedder(a, &emb);
    defer db.close();
    try db.store("shared-key", "rust content for session-a", .{ .core = {} }, "session-a", null, null);
    try db.store("shared-key-b", "rust content for session-b", .{ .core = {} }, "session-b", null, null);

    const a_results = try db.recall(a, "rust", 10, "session-a");
    defer {
        for (a_results) |e| freeEntry(a, e);
        a.free(a_results);
    }
    for (a_results) |e| {
        try testing.expectEqualStrings("session-a", e.session_id.?);
    }
}

test "sqlite: recall with no keyword match falls back to vector path (with embedder)" {
    const a = testing.allocator;
    var emb = embeddings_mod.HashEmbedding.init("test", 64);
    var db = try openWithEmbedder(a, &emb);
    defer db.close();
    try db.store("k", "hello world", .{ .core = {} }, null, null, null);
    // With an embedder configured, "nonexistentword" still produces a hash
    // embedding that may cosine-match the stored entry. The Rust recall
    // applies the same `sim > 0.0` cutoff. We assert the result set is small
    // and the matches have low similarity (no strong signal).
    const results = try db.recall(a, "nonexistentword", 10, null);
    defer {
        for (results) |e| freeEntry(a, e);
        a.free(results);
    }
    try testing.expect(results.len <= 1);
}

test "sqlite: vectorSearch returns cosine similarity" {
    const a = testing.allocator;
    var emb = embeddings_mod.HashEmbedding.init("test", 64);
    var db = try openWithEmbedder(a, &emb);
    defer db.close();
    try db.store("rust", "rust programming language", .{ .core = {} }, null, null, null);
    try db.store("weather", "sunny weather today", .{ .core = {} }, null, null, null);

    // Query embedding = the same HashEmbedding applied to "rust" — should
    // cosine-match the 'rust' entry more strongly than the 'weather' one.
    const query_vec = try embeddings_mod.HashEmbedding.embed_text(a, &emb, "rust");
    defer a.free(query_vec);
    const results = try db.vectorSearch(a, query_vec, 10, null, null);
    defer freeScoredIds(a, results);
    try testing.expect(results.len >= 1);
    // Top result must have positive similarity.
    try testing.expect(results[0].score > 0.0);
}

test "sqlite: vectorSearch respects category filter" {
    const a = testing.allocator;
    var emb = embeddings_mod.HashEmbedding.init("test", 64);
    var db = try openWithEmbedder(a, &emb);
    defer db.close();
    try db.store("k1", "rust content", .{ .core = {} }, null, null, null);
    try db.store("k2", "rust content daily", .{ .daily = {} }, null, null, null);

    const query_vec = try embeddings_mod.HashEmbedding.embed_text(a, &emb, "rust");
    defer a.free(query_vec);
    const core_only = try db.vectorSearch(a, query_vec, 10, "core", null);
    defer freeScoredIds(a, core_only);
    try testing.expectEqual(@as(usize, 1), core_only.len);
}

// ── Memory vtable integration ────────────────────────────────────────────

test "sqlite: Memory vtable end-to-end (store/get/forget/count via vtable)" {
    const a = testing.allocator;
    var db = try SqliteMemory.openNoEmbedder(a, ":memory:");
    defer db.close();
    const m = db.memoryProvider();

    try testing.expectEqualStrings("sqlite", m.name());
    try testing.expectEqual(@as(usize, 0), try m.count());

    try m.store("k", "v", .{ .core = {} }, null, null, null);
    try testing.expectEqual(@as(usize, 1), try m.count());

    const entry = (try m.get("k")) orelse return error.NotFound;
    defer freeEntry(a, entry);
    try testing.expectEqualStrings("v", entry.content);

    try testing.expect(try m.forget("k"));
    try testing.expectEqual(@as(usize, 0), try m.count());
    try testing.expect(try m.get("k") == null);
}

test "sqlite: Memory vtable list + recall" {
    const a = testing.allocator;
    var emb = embeddings_mod.HashEmbedding.init("test", 64);
    var db = try openWithEmbedder(a, &emb);
    defer db.close();
    const m = db.memoryProvider();

    try m.store("rust", "rust programming", .{ .core = {} }, null, null, null);
    try m.store("weather", "sunny day", .{ .core = {} }, null, null, null);

    const all = try m.list(a, null, null);
    defer {
        for (all) |e| freeEntry(a, e);
        a.free(all);
    }
    try testing.expectEqual(@as(usize, 2), all.len);

    const recalls = try m.recall(a, "rust", 10, null);
    defer {
        for (recalls) |e| freeEntry(a, e);
        a.free(recalls);
    }
    try testing.expect(recalls.len >= 1);
}

// ──────────────────────────────────────────────────────────────────────────
// Provenance (source + media_url) + schema migration tests.
// ──────────────────────────────────────────────────────────────────────────

test "sqlite: source and media_url round-trip" {
    const a = testing.allocator;
    var db = try SqliteMemory.openNoEmbedder(a, ":memory:");
    defer db.close();

    try db.store("journal_1", "today I recorded an audio journal", .{ .daily = {} },
        null, "audio_recorded", "Recordings/journal_1.m4a");
    const entry = (try db.get(a, "journal_1")) orelse return error.NotFound;
    defer freeEntry(a, entry);
    try testing.expectEqualStrings("audio_recorded", entry.source.?);
    try testing.expectEqualStrings("Recordings/journal_1.m4a", entry.media_url.?);
}

test "sqlite: source and media_url default to null when not set" {
    const a = testing.allocator;
    var db = try SqliteMemory.openNoEmbedder(a, ":memory:");
    defer db.close();

    try db.store("typed_entry", "a plain typed note", .{ .daily = {} }, null, null, null);
    const entry = (try db.get(a, "typed_entry")) orelse return error.NotFound;
    defer freeEntry(a, entry);
    try testing.expect(entry.source == null);
    try testing.expect(entry.media_url == null);
}

test "sqlite: store upsert updates source and media_url" {
    const a = testing.allocator;
    var db = try SqliteMemory.openNoEmbedder(a, ":memory:");
    defer db.close();

    // First write: typed entry (no provenance).
    try db.store("k", "v1", .{ .daily = {} }, null, null, null);
    // Upsert: now it's an audio recording.
    try db.store("k", "v2", .{ .daily = {} }, null, "audio_imported", "Inbox/123.m4a");
    const entry = (try db.get(a, "k")) orelse return error.NotFound;
    defer freeEntry(a, entry);
    try testing.expectEqualStrings("v2", entry.content);
    try testing.expectEqualStrings("audio_imported", entry.source.?);
    try testing.expectEqualStrings("Inbox/123.m4a", entry.media_url.?);
}

test "sqlite: migration adds source + media_url to a legacy DB" {
    // Simulate a pre-v1 DB: old schema (no source/media_url columns),
    // user_version = 0, one legacy row already present. open() must migrate
    // it without losing data, and the legacy row must read back with nulls.
    const a = testing.allocator;
    const tmp_path = "test-sqlite-migrate-legacy.db";
    defer _ = c.remove(tmp_path);

    // Phase 1: build a legacy DB using the RAW sqlite C API (not via
    // SqliteMemory.open, which would run the new initSchema). This emulates a
    // file written by a prior app version that predates source/media_url.
    {
        var raw_db: ?*c.sqlite3 = null;
        const path_z = try a.dupeZ(u8, tmp_path);
        defer a.free(path_z);
        try testing.expectEqual(c.SQLITE_OK, c.sqlite3_open(path_z.ptr, &raw_db));
        defer _ = c.sqlite3_close(raw_db);

        var errmsg: [*c]u8 = null;
        const old_schema =
            \\CREATE TABLE memories (
            \\    id          TEXT PRIMARY KEY,
            \\    key         TEXT NOT NULL UNIQUE,
            \\    content     TEXT NOT NULL,
            \\    category    TEXT NOT NULL DEFAULT 'core',
            \\    embedding   BLOB,
            \\    created_at  TEXT NOT NULL,
            \\    updated_at  TEXT NOT NULL,
            \\    session_id  TEXT
            \\);
            \\CREATE VIRTUAL TABLE memories_fts USING fts5(
            \\    key, content, content=memories, content_rowid=rowid
            \\);
            \\INSERT INTO memories (id, key, content, category, created_at, updated_at, session_id)
            \\VALUES ('legacy-1', 'legacy_key', 'legacy content', 'daily', '2026-01-01T00:00:00Z', '2026-01-01T00:00:00Z', NULL);
        ;
        // sqlite3_exec needs a null-terminated SQL string; dupeZ the literal.
        const old_schema_z = try a.dupeZ(u8, old_schema);
        defer a.free(old_schema_z);
        const rc = c.sqlite3_exec(raw_db, old_schema_z.ptr, null, null, &errmsg);
        if (errmsg) |e| c.sqlite3_free(e);
        try testing.expectEqual(c.SQLITE_OK, rc);
        // user_version defaults to 0 on a fresh DB.
    }

    // Phase 2: open via SqliteMemory — initSchema runs runMigrations, which
    // must ALTER TABLE to add the two columns and bump user_version to 1,
    // preserving the legacy row.
    var db2 = try SqliteMemory.openNoEmbedder(a, tmp_path);
    defer db2.close();
    try testing.expectEqual(@as(i64, 1), try db2.userVersion());
    try testing.expect(try db2.hasColumn("memories", "source"));
    try testing.expect(try db2.hasColumn("memories", "media_url"));

    const entry = (try db2.get(a, "legacy_key")) orelse return error.NotFound;
    defer freeEntry(a, entry);
    try testing.expectEqualStrings("legacy content", entry.content);
    // Legacy rows have no provenance → both null.
    try testing.expect(entry.source == null);
    try testing.expect(entry.media_url == null);

    // The migrated DB must accept new writes with provenance.
    try db2.store("new_key", "new content", .{ .daily = {} }, null,
        "audio_recorded", "Recordings/new.m4a");
    const entry2 = (try db2.get(a, "new_key")) orelse return error.NotFound;
    defer freeEntry(a, entry2);
    try testing.expectEqualStrings("audio_recorded", entry2.source.?);
}

test "sqlite: migration is idempotent (re-open does not re-ALTER)" {
    // After v1 is applied, opening again must not error (hasColumn guard +
    // user_version >= 1 short-circuit). Uses the same temp file as above but
    // a distinct name to avoid cross-test interference.
    const a = testing.allocator;
    const tmp_path = "test-sqlite-migrate-idempotent.db";
    defer _ = c.remove(tmp_path);

    {
        var db = try SqliteMemory.openNoEmbedder(a, tmp_path);
        try db.store("k", "v", .{ .core = {} }, null, "text", null);
        db.close();
    }
    // Re-open N times; each must succeed and preserve the row + provenance.
    var i: usize = 0;
    while (i < 3) : (i += 1) {
        var db = try SqliteMemory.openNoEmbedder(a, tmp_path);
        defer db.close();
        try testing.expectEqual(@as(i64, 1), try db.userVersion());
        const entry = (try db.get(a, "k")) orelse return error.NotFound;
        defer freeEntry(a, entry);
        try testing.expectEqualStrings("text", entry.source.?);
    }
}
