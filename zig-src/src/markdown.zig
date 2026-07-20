//! Markdown-backed memory store — ports `src/memory/markdown.rs` (355 LOC).
//!
//! Plain files as source of truth:
//!   `<workspace>/MEMORY.md`           — curated long-term memory (core)
//!   `<workspace>/memory/YYYY-MM-DD.md` — daily logs (append-only)
//!
//! The Rust original uses tokio::fs for async I/O. The Zig port is synchronous
//! via libc file APIs (the iOS caller is expected to run these on a background
//! queue and surface results via the C ABI). Markdown memory is intentionally
//! append-only — `forget` is a documented no-op (preserves the audit trail).

const std = @import("std");
const testing = std.testing;
const memory_types = @import("memory_types.zig");

const c = @cImport({
    @cInclude("stdio.h");
    @cInclude("sys/stat.h");
    @cInclude("sys/types.h");
    @cInclude("dirent.h");
    @cInclude("time.h");
    @cInclude("stdlib.h");
});

const MemoryEntry = memory_types.MemoryEntry;
const MemoryCategory = memory_types.MemoryCategory;
const MemoryError = memory_types.MemoryError;

pub const MarkdownError = error{
    IoError,
    OutOfMemory,
    InvalidPath,
};

/// Markdown file-as-source-of-truth memory backend. Mirrors `MarkdownMemory`
/// in `src/memory/markdown.rs:12`. Owns the workspace_dir string (allocator).
pub const MarkdownMemory = struct {
    workspace_dir: []const u8,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, workspace_dir: []const u8) !MarkdownMemory {
        return .{
            .workspace_dir = try allocator.dupe(u8, workspace_dir),
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *MarkdownMemory) void {
        self.allocator.free(self.workspace_dir);
    }

    fn memoryDirPath(self: *MarkdownMemory, allocator: std.mem.Allocator) ![]u8 {
        return std.fmt.allocPrint(allocator, "{s}/memory", .{self.workspace_dir});
    }

    fn corePath(self: *MarkdownMemory, allocator: std.mem.Allocator) ![]u8 {
        return std.fmt.allocPrint(allocator, "{s}/MEMORY.md", .{self.workspace_dir});
    }

    /// Build the per-day log path `<workspace>/memory/YYYY-MM-DD.md`. Uses
    /// libc `time()` for the epoch seconds, mirrors the Rust `Local::now()`
    /// behavior at UTC (Zig 0.16 has no timezone-aware time API).
    fn dailyPath(self: *MarkdownMemory, allocator: std.mem.Allocator) ![]u8 {
        var now_c: c.time_t = 0;
        _ = c.time(&now_c);
        const ts: i64 = @intCast(now_c);
        const day_ts = ts + 719468 * 86400;
        const day = @divFloor(day_ts, 86400);

        const era = @divFloor(if (day >= 0) day else day - 146096, 146097);
        const doe: u64 = @intCast(day - era * 146097);
        const yoe: u64 = @divFloor(doe - @divFloor(doe, 1460) + @divFloor(doe, 36524) - @divFloor(doe, 146096), 365);
        const y: i64 = @as(i64, @intCast(yoe)) + era * 400;
        const doy: u64 = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100));
        const mp: u64 = @divFloor(5 * doy + 2, 153);
        const d: u64 = doy - @divFloor(153 * mp + 2, 5) + 1;
        const m: u64 = if (mp < 10) mp + 3 else mp - 9;
        const year: i64 = if (m <= 2) y + 1 else y;

        return std.fmt.allocPrint(allocator, "{s}/memory/{d:0>4}-{d:0>2}-{d:0>2}.md", .{
            self.workspace_dir, year, m, d,
        });
    }

    /// Recursively create the workspace `memory/` directory. Idempotent.
    fn ensureDirs(self: *MarkdownMemory) !void {
        const mem_dir = try self.memoryDirPath(self.allocator);
        defer self.allocator.free(mem_dir);
        const mem_dir_z = try self.allocator.dupeZ(u8, mem_dir);
        defer self.allocator.free(mem_dir_z);
        // mkdir -p: create workspace_dir and memory/ subdir. Windows' mkdir
        // takes only a path (no mode); Unix's takes (path, mode). The @cImport
        // resolves to whichever the host libc declares.
        const ws_z = try self.allocator.dupeZ(u8, self.workspace_dir);
        defer self.allocator.free(ws_z);
        mkdirCompat(ws_z.ptr);
        mkdirCompat(mem_dir_z.ptr);
    }

    /// Read a file into an allocator-owned buffer. Returns empty slice if the
    /// file does not exist or is empty.
    fn readFileOpt(self: *MarkdownMemory, path: []const u8) ![]u8 {
        const path_z = try self.allocator.dupeZ(u8, path);
        defer self.allocator.free(path_z);
        const fp = c.fopen(path_z.ptr, "rb");
        if (fp == null) return self.allocator.dupe(u8, "");
        defer _ = c.fclose(fp);

        // Size up the file.
        _ = c.fseek(fp, 0, c.SEEK_END);
        const size = c.ftell(fp);
        _ = c.fseek(fp, 0, c.SEEK_SET);
        if (size <= 0) return self.allocator.dupe(u8, "");

        const buf = try self.allocator.alloc(u8, @intCast(size));
        const n_read = c.fread(buf.ptr, 1, @intCast(size), fp);
        if (n_read != @as(usize, @intCast(size))) {
            self.allocator.free(buf);
            return error.IoError;
        }
        return buf;
    }

    fn writeFile(self: *MarkdownMemory, path: []const u8, content: []const u8) !void {
        const path_z = try self.allocator.dupeZ(u8, path);
        defer self.allocator.free(path_z);
        const fp = c.fopen(path_z.ptr, "wb");
        if (fp == null) return error.IoError;
        defer _ = c.fclose(fp);
        const n_written = c.fwrite(content.ptr, 1, content.len, fp);
        if (n_written != content.len) return error.IoError;
    }

    /// Append `content` to `path`, adding a file header if the file is new.
    /// Mirrors `append_to_file` in markdown.rs:41.
    fn appendToFile(self: *MarkdownMemory, path: []const u8, content: []const u8, is_core: bool) !void {
        try self.ensureDirs();

        const existing = try self.readFileOpt(path);
        defer self.allocator.free(existing);

        var updated = std.ArrayList(u8).empty;
        defer updated.deinit(self.allocator);
        if (existing.len == 0) {
            // Fresh file → write a header.
            if (is_core) {
                try updated.appendSlice(self.allocator, "# Long-Term Memory\n\n");
            } else {
                // Daily file: include today's date in the header.
                const date_str = try self.todayDateString();
                defer self.allocator.free(date_str);
                const hdr = try std.fmt.allocPrint(self.allocator, "# Daily Log — {s}\n\n", .{date_str});
                defer self.allocator.free(hdr);
                try updated.appendSlice(self.allocator, hdr);
            }
            try updated.appendSlice(self.allocator, content);
            try updated.append(self.allocator, '\n');
        } else {
            try updated.appendSlice(self.allocator, existing);
            try updated.append(self.allocator, '\n');
            try updated.appendSlice(self.allocator, content);
            try updated.append(self.allocator, '\n');
        }

        try self.writeFile(path, updated.items);
    }

    /// Today's date as "YYYY-MM-DD" (UTC). Helper for the daily-file header.
    fn todayDateString(self: *MarkdownMemory) ![]u8 {
        var now_c: c.time_t = 0;
        _ = c.time(&now_c);
        const ts: i64 = @intCast(now_c);
        const day_ts = ts + 719468 * 86400;
        const day = @divFloor(day_ts, 86400);
        const era = @divFloor(if (day >= 0) day else day - 146096, 146097);
        const doe: u64 = @intCast(day - era * 146097);
        const yoe: u64 = @divFloor(doe - @divFloor(doe, 1460) + @divFloor(doe, 36524) - @divFloor(doe, 146096), 365);
        const y: i64 = @as(i64, @intCast(yoe)) + era * 400;
        const doy: u64 = doe - (365 * yoe + @divFloor(yoe, 4) - @divFloor(yoe, 100));
        const mp: u64 = @divFloor(5 * doy + 2, 153);
        const d: u64 = doy - @divFloor(153 * mp + 2, 5) + 1;
        const m: u64 = if (mp < 10) mp + 3 else mp - 9;
        const year: i64 = if (m <= 2) y + 1 else y;
        return std.fmt.allocPrint(self.allocator, "{d:0>4}-{d:0>2}-{d:0>2}", .{ year, m, d });
    }

    /// Parse markdown lines into MemoryEntry records. Skips blank lines and
    /// `#`-prefixed headings. Strips leading `- ` from bullet items.
    /// Mirrors `parse_entries_from_file` in markdown.rs:66.
    fn parseEntriesFromFile(
        allocator: std.mem.Allocator,
        filename_stem: []const u8,
        content: []const u8,
        category: MemoryCategory,
    ) ![]MemoryEntry {
        var entries = std.ArrayList(MemoryEntry).empty;
        errdefer {
            for (entries.items) |e| freeEntry(allocator, e);
            entries.deinit(allocator);
        }

        var line_it = std.mem.splitScalar(u8, content, '\n');
        var idx: usize = 0;
        while (line_it.next()) |raw_line| {
            const line = std.mem.trim(u8, raw_line, " \t\r");
            if (line.len == 0) continue;
            if (std.mem.startsWith(u8, line, "#")) continue;

            const clean = if (std.mem.startsWith(u8, line, "- "))
                line[2..]
            else
                line;

            // Build the per-entry id and key as `<filename>:<idx>`.
            const id = try std.fmt.allocPrint(allocator, "{s}:{d}", .{ filename_stem, idx });
            const key = try allocator.dupe(u8, id);
            const content_owned = try allocator.dupe(u8, clean);
            const ts = try allocator.dupe(u8, filename_stem);

            // For custom categories we need to dupe the name to keep it stable.
            var cat = category;
            if (cat == .custom) {
                cat = .{ .custom = try allocator.dupe(u8, category.custom) };
            }

            try entries.append(allocator, .{
                .id = id,
                .key = key,
                .content = content_owned,
                .category = cat,
                .timestamp = ts,
                .session_id = null,
                .score = null,
            });
            idx += 1;
        }
        return entries.toOwnedSlice(allocator);
    }

    /// Read every entry from MEMORY.md + memory/*.md. Mirrors
    /// `read_all_entries` in markdown.rs:99. Returns entries sorted by
    /// timestamp descending (lexicographic on the filename stem).
    pub fn readAllEntries(self: *MarkdownMemory, allocator: std.mem.Allocator) ![]MemoryEntry {
        var entries = std.ArrayList(MemoryEntry).empty;
        errdefer {
            for (entries.items) |e| freeEntry(allocator, e);
            entries.deinit(allocator);
        }

        // Read MEMORY.md (core).
        const core_path = try self.corePath(allocator);
        defer allocator.free(core_path);
        const core_content = try self.readFileOpt(core_path);
        defer self.allocator.free(core_content);
        if (core_content.len > 0) {
            const core_entries = try parseEntriesFromFile(allocator, "MEMORY", core_content, .{ .core = {} });
            defer allocator.free(core_entries);
            for (core_entries) |e| try entries.append(allocator, e);
        }

        // Read memory/*.md (daily logs).
        const mem_dir_path = try self.memoryDirPath(allocator);
        defer allocator.free(mem_dir_path);
        const mem_dir_z = try allocator.dupeZ(u8, mem_dir_path);
        defer allocator.free(mem_dir_z);
        const dir = c.opendir(mem_dir_z.ptr);
        if (dir != null) {
            defer _ = c.closedir(dir);
            while (true) {
                const ent = c.readdir(dir);
                if (ent == null) break;
                // Defensive d_name read (see removeTempDir for the rationale).
                const name_max: usize = 260;
                var name_buf: [260]u8 = undefined;
                const src_ptr: [*]const u8 = @ptrCast(&ent.*.d_name);
                var name_len: usize = 0;
                while (name_len < name_max) : (name_len += 1) {
                    const ch = src_ptr[name_len];
                    if (ch == 0) break;
                    name_buf[name_len] = ch;
                }
                const entry_name = name_buf[0..name_len];
                if (entry_name.len == 0) continue;
                if (std.mem.eql(u8, entry_name, ".") or std.mem.eql(u8, entry_name, "..")) continue;
                if (!std.mem.endsWith(u8, entry_name, ".md")) continue;
                const fpath = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ mem_dir_path, entry_name });
                defer allocator.free(fpath);
                const fcontent = try self.readFileOpt(fpath);
                defer self.allocator.free(fcontent);
                if (fcontent.len == 0) continue;
                const stem = entry_name[0 .. entry_name.len - 3]; // strip ".md"
                const stem_owned = try allocator.dupe(u8, stem);
                defer allocator.free(stem_owned);
                const daily_entries = try parseEntriesFromFile(allocator, stem_owned, fcontent, .{ .daily = {} });
                defer allocator.free(daily_entries);
                for (daily_entries) |e| try entries.append(allocator, e);
            }
        }

        // Sort by timestamp descending (filename stem comparison).
        std.mem.sort(MemoryEntry, entries.items, {}, struct {
            fn lt(_: void, a: MemoryEntry, b: MemoryEntry) bool {
                return std.mem.order(u8, b.timestamp, a.timestamp) == .lt;
            }
        }.lt);

        return entries.toOwnedSlice(allocator);
    }

    // ── Memory trait operations ───────────────────────────────────────────

    pub fn name(_: *MarkdownMemory) []const u8 {
        return "markdown";
    }

    pub fn store(
        self: *MarkdownMemory,
        key: []const u8,
        content: []const u8,
        category: MemoryCategory,
        _: ?[]const u8,
    ) !void {
        const entry_line = try std.fmt.allocPrint(self.allocator, "- **{s}**: {s}", .{ key, content });
        defer self.allocator.free(entry_line);

        const is_core = (category == .core);
        const path = if (is_core)
            try self.corePath(self.allocator)
        else
            try self.dailyPath(self.allocator);
        defer self.allocator.free(path);

        try self.appendToFile(path, entry_line, is_core);
    }

    pub fn recall(
        self: *MarkdownMemory,
        allocator: std.mem.Allocator,
        query: []const u8,
        limit: usize,
        _: ?[]const u8,
    ) ![]MemoryEntry {
        const all = try self.readAllEntries(allocator);
        defer {
            for (all) |e| freeEntry(allocator, e);
            allocator.free(all);
        }
        if (all.len == 0) return &.{};

        // Lowercase query + split on whitespace (keyword tokenization).
        const query_lower = try allocator.alloc(u8, query.len);
        defer allocator.free(query_lower);
        for (query, 0..) |ch, i| query_lower[i] = std.ascii.toLower(ch);

        var keywords = std.ArrayList([]const u8).empty;
        defer keywords.deinit(allocator);
        var kw_it = std.mem.tokenizeAny(u8, query_lower, " \t\n\r");
        while (kw_it.next()) |kw| try keywords.append(allocator, kw);
        if (keywords.items.len == 0) return &.{};

        var scored = std.ArrayList(MemoryEntry).empty;
        errdefer {
            for (scored.items) |e| freeEntry(allocator, e);
            scored.deinit(allocator);
        }
        for (all) |entry| {
            const content_lower = try allocator.alloc(u8, entry.content.len);
            defer allocator.free(content_lower);
            for (entry.content, 0..) |ch, i| content_lower[i] = std.ascii.toLower(ch);

            var matched: usize = 0;
            for (keywords.items) |kw| {
                if (std.mem.indexOf(u8, content_lower, kw) != null) matched += 1;
            }
            if (matched > 0) {
                const score: f64 = @as(f64, @floatFromInt(matched)) / @as(f64, @floatFromInt(keywords.items.len));
                // Deep-copy the entry so we can free `all` independently.
                const copy = try dupeEntry(allocator, entry);
                var mutable_copy = copy;
                mutable_copy.score = score;
                try scored.append(allocator, mutable_copy);
            }
        }

        // Sort by score descending.
        std.mem.sort(MemoryEntry, scored.items, {}, struct {
            fn lt(_: void, a: MemoryEntry, b: MemoryEntry) bool {
                const sa = a.score orelse 0;
                const sb = b.score orelse 0;
                return sa > sb;
            }
        }.lt);

        // Truncate to limit (free the dropped entries).
        if (scored.items.len > limit) {
            for (scored.items[limit..]) |e| freeEntry(allocator, e);
            scored.shrinkRetainingCapacity(limit);
        }
        return scored.toOwnedSlice(allocator);
    }

    pub fn get(self: *MarkdownMemory, allocator: std.mem.Allocator, key: []const u8) !?MemoryEntry {
        const all = try self.readAllEntries(allocator);
        defer {
            for (all) |e| freeEntry(allocator, e);
            allocator.free(all);
        }
        for (all) |entry| {
            if (std.mem.eql(u8, entry.key, key) or std.mem.indexOf(u8, entry.content, key) != null) {
                return try dupeEntry(allocator, entry);
            }
        }
        return null;
    }

    pub fn list(
        self: *MarkdownMemory,
        allocator: std.mem.Allocator,
        category: ?MemoryCategory,
        _: ?[]const u8,
    ) ![]MemoryEntry {
        const all = try self.readAllEntries(allocator);
        if (category == null) return all;
        defer {
            for (all) |e| freeEntry(allocator, e);
            allocator.free(all);
        }
        var filtered = std.ArrayList(MemoryEntry).empty;
        errdefer {
            for (filtered.items) |e| freeEntry(allocator, e);
            filtered.deinit(allocator);
        }
        for (all) |entry| {
            if (entry.category.eql(category.?)) {
                try filtered.append(allocator, try dupeEntry(allocator, entry));
            }
        }
        return filtered.toOwnedSlice(allocator);
    }

    /// Markdown memory is append-only by design (audit trail). Always returns
    /// false to indicate the entry wasn't removed.
    pub fn forget(_: *MarkdownMemory, _: []const u8) !bool {
        return false;
    }

    pub fn count(self: *MarkdownMemory, allocator: std.mem.Allocator) !usize {
        const all = try self.readAllEntries(allocator);
        defer {
            for (all) |e| freeEntry(allocator, e);
            allocator.free(all);
        }
        return all.len;
    }

    pub fn healthCheck(self: *MarkdownMemory) bool {
        // HealthCheck: workspace_dir must be openable as a directory. Using
        // opendir avoids the platform-specific struct_stat layout differences
        // (Windows _stat vs POSIX struct stat) that crash via @constCast.
        const ws_z = self.allocator.dupeZ(u8, self.workspace_dir) catch return false;
        defer self.allocator.free(ws_z);
        const dir = c.opendir(ws_z.ptr);
        if (dir == null) return false;
        _ = c.closedir(dir);
        return true;
    }

    // ── Memory vtable adapters ───────────────────────────────────────────

    pub fn memoryProvider(self: *MarkdownMemory) memory_types.Memory {
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
        const self: *MarkdownMemory = @ptrCast(@alignCast(ctx));
        return self.name();
    }

    fn vtableStore(
        ctx: *anyopaque,
        key: []const u8,
        content: []const u8,
        category: MemoryCategory,
        session_id: ?[]const u8,
    ) MemoryError!void {
        const self: *MarkdownMemory = @ptrCast(@alignCast(ctx));
        self.store(key, content, category, session_id) catch return error.BackendFailed;
    }

    fn vtableRecall(
        ctx: *anyopaque,
        allocator: std.mem.Allocator,
        query: []const u8,
        limit: usize,
        session_id: ?[]const u8,
    ) MemoryError![]MemoryEntry {
        const self: *MarkdownMemory = @ptrCast(@alignCast(ctx));
        return self.recall(allocator, query, limit, session_id) catch return error.BackendFailed;
    }

    fn vtableGet(ctx: *anyopaque, key: []const u8) MemoryError!?MemoryEntry {
        const self: *MarkdownMemory = @ptrCast(@alignCast(ctx));
        return self.get(self.allocator, key) catch return error.BackendFailed;
    }

    fn vtableList(
        ctx: *anyopaque,
        allocator: std.mem.Allocator,
        category: ?MemoryCategory,
        session_id: ?[]const u8,
    ) MemoryError![]MemoryEntry {
        const self: *MarkdownMemory = @ptrCast(@alignCast(ctx));
        return self.list(allocator, category, session_id) catch return error.BackendFailed;
    }

    fn vtableForget(ctx: *anyopaque, key: []const u8) MemoryError!bool {
        const self: *MarkdownMemory = @ptrCast(@alignCast(ctx));
        return self.forget(key) catch return error.BackendFailed;
    }

    fn vtableCount(ctx: *anyopaque) MemoryError!usize {
        const self: *MarkdownMemory = @ptrCast(@alignCast(ctx));
        return self.count(self.allocator) catch return error.BackendFailed;
    }

    fn vtableHealthCheck(ctx: *anyopaque) bool {
        const self: *MarkdownMemory = @ptrCast(@alignCast(ctx));
        return self.healthCheck();
    }
};

/// Deep-copy a MemoryEntry's owned fields.
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
    };
    if (entry.session_id) |s| copy.session_id = try allocator.dupe(u8, s);
    return copy;
}

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
// Tests — port the 10 cases from src/memory/markdown.rs:240-355.
// Each test uses a fresh per-test tmp dir so they don't interfere.
// ──────────────────────────────────────────────────────────────────────────

/// mkdir compatibility shim: Windows libc has `mkdir(path)`; POSIX libc has
/// `mkdir(path, mode)`. Detect at comptime which signature the host `c` import
/// resolved to and dispatch accordingly.
fn mkdirCompat(path: [*:0]const u8) void {
    const T = @TypeOf(c.mkdir);
    const info = @typeInfo(T);
    if (info == .@"fn") {
        const params = info.@"fn".params;
        if (params.len == 1) {
            _ = c.mkdir(path);
        } else {
            _ = c.mkdir(path, @as(c.mode_t, 0o755));
        }
    }
}

/// Per-test unique workspace dir under the OS temp dir. The dir is created
/// fresh each call; the test defer-removes it on cleanup.
fn tempWorkspace(allocator: std.mem.Allocator) ![]u8 {
    const S = struct {
        var counter = std.atomic.Value(u64).init(0);
    };
    const ctr = S.counter.fetchAdd(1, .monotonic);
    const addr: u64 = @returnAddress();

    // Resolve the OS temp dir from $TEMP / $TMP (set on both Windows and Unix).
    // Fall back to "." if neither is set. Use libc getenv — Zig 0.16's
    // std.process.getEnvVarOwned moved into the Io subsystem and is awkward
    // to use from a synchronous context.
    const tmp_root: []const u8 = blk: {
        if (c.getenv("TEMP")) |p| break :blk std.mem.span(p);
        if (c.getenv("TMP")) |p| break :blk std.mem.span(p);
        if (c.getenv("TMPDIR")) |p| break :blk std.mem.span(p);
        break :blk ".";
    };

    const path = try std.fmt.allocPrint(allocator, "{s}/slowclaw-md-{x}-{x}", .{ tmp_root, ctr, addr });
    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);
    mkdirCompat(path_z.ptr);
    return path;
}

/// Combined cleanup: remove the temp workspace dir, THEN free the path slice.
/// Use this from a single defer so the order is correct (removeTempDir runs
/// while `path` is still alive, then the path slice is freed).
fn freeTempWorkspace(allocator: std.mem.Allocator, path: []const u8) void {
    removeTempDir(path);
    allocator.free(path);
}

fn removeTempDir(path: []const u8) void {
    // Best-effort cleanup of the per-test workspace dir. Test-only; if any
    // step fails we leak and let the OS reclaim its temp dir on its own
    // schedule. Kept narrow to avoid platform-specific readdir quirks that
    // crashed cross-built tests: we only attempt the two known files
    // (MEMORY.md and memory/<today>.md) plus the memory/ subdir + workspace.
    var buf: [512]u8 = undefined;

    if (std.fmt.bufPrintZ(&buf, "{s}/memory", .{path})) |mem_dir_z| {
        _ = c.rmdir(mem_dir_z.ptr);
    } else |_| {}

    if (std.fmt.bufPrintZ(&buf, "{s}/MEMORY.md", .{path})) |md_z| {
        _ = c.remove(md_z.ptr);
    } else |_| {}

    if (std.fmt.bufPrintZ(&buf, "{s}", .{path})) |path_z| {
        _ = c.rmdir(path_z.ptr);
    } else |_| {}
}

test "markdown: name and health" {
    const a = testing.allocator;
    const dir = try tempWorkspace(a);
    defer freeTempWorkspace(a, dir);
    var mem = try MarkdownMemory.init(a, dir);
    defer mem.deinit();
    try testing.expectEqualStrings("markdown", mem.name());
    try testing.expect(mem.healthCheck());
}

test "markdown: store core appends to MEMORY.md" {
    const a = testing.allocator;
    const dir = try tempWorkspace(a);
    defer freeTempWorkspace(a, dir);
    var mem = try MarkdownMemory.init(a, dir);
    defer mem.deinit();
    try mem.store("pref", "User likes Rust", .{ .core = {} }, null);

    const core_path = try mem.corePath(a);
    defer a.free(core_path);
    const content = try mem.readFileOpt(core_path);
    defer a.free(content);
    try testing.expect(std.mem.indexOf(u8, content, "User likes Rust") != null);
    try testing.expect(std.mem.indexOf(u8, content, "# Long-Term Memory") != null);
}

test "markdown: store daily goes to memory/YYYY-MM-DD.md" {
    const a = testing.allocator;
    const dir = try tempWorkspace(a);
    defer freeTempWorkspace(a, dir);
    var mem = try MarkdownMemory.init(a, dir);
    defer mem.deinit();
    try mem.store("note", "Finished tests", .{ .daily = {} }, null);

    const daily_path = try mem.dailyPath(a);
    defer a.free(daily_path);
    const content = try mem.readFileOpt(daily_path);
    defer a.free(content);
    try testing.expect(std.mem.indexOf(u8, content, "Finished tests") != null);
    try testing.expect(std.mem.indexOf(u8, content, "# Daily Log") != null);
}

test "markdown: recall keyword finds matches" {
    const a = testing.allocator;
    const dir = try tempWorkspace(a);
    defer freeTempWorkspace(a, dir);
    var mem = try MarkdownMemory.init(a, dir);
    defer mem.deinit();
    try mem.store("a", "Rust is fast", .{ .core = {} }, null);
    try mem.store("b", "Python is slow", .{ .core = {} }, null);
    try mem.store("c", "Rust and safety", .{ .core = {} }, null);

    const results = try mem.recall(a, "Rust", 10, null);
    defer {
        for (results) |e| freeEntry(a, e);
        a.free(results);
    }
    try testing.expect(results.len >= 2);
    for (results) |r| {
        var lower_buf: [128]u8 = undefined;
        const lower = lowerBuf(&lower_buf, r.content);
        try testing.expect(std.mem.indexOf(u8, lower, "rust") != null);
    }
}

test "markdown: recall with no match returns empty" {
    const a = testing.allocator;
    const dir = try tempWorkspace(a);
    defer freeTempWorkspace(a, dir);
    var mem = try MarkdownMemory.init(a, dir);
    defer mem.deinit();
    try mem.store("a", "Rust is great", .{ .core = {} }, null);
    const results = try mem.recall(a, "javascript", 10, null);
    defer {
        for (results) |e| freeEntry(a, e);
        a.free(results);
    }
    try testing.expectEqual(@as(usize, 0), results.len);
}

test "markdown: count tracks stored entries" {
    const a = testing.allocator;
    const dir = try tempWorkspace(a);
    defer freeTempWorkspace(a, dir);
    var mem = try MarkdownMemory.init(a, dir);
    defer mem.deinit();
    try mem.store("a", "first", .{ .core = {} }, null);
    try mem.store("b", "second", .{ .core = {} }, null);
    const n = try mem.count(a);
    try testing.expect(n >= 2);
}

test "markdown: list filters by category" {
    const a = testing.allocator;
    const dir = try tempWorkspace(a);
    defer freeTempWorkspace(a, dir);
    var mem = try MarkdownMemory.init(a, dir);
    defer mem.deinit();
    try mem.store("a", "core fact", .{ .core = {} }, null);
    try mem.store("b", "daily note", .{ .daily = {} }, null);

    const core = try mem.list(a, .{ .core = {} }, null);
    defer {
        for (core) |e| freeEntry(a, e);
        a.free(core);
    }
    for (core) |e| try testing.expect(e.category.eql(.{ .core = {} }));

    const daily = try mem.list(a, .{ .daily = {} }, null);
    defer {
        for (daily) |e| freeEntry(a, e);
        a.free(daily);
    }
    for (daily) |e| try testing.expect(e.category.eql(.{ .daily = {} }));
}

test "markdown: forget is always a no-op" {
    const a = testing.allocator;
    const dir = try tempWorkspace(a);
    defer freeTempWorkspace(a, dir);
    var mem = try MarkdownMemory.init(a, dir);
    defer mem.deinit();
    try mem.store("a", "permanent", .{ .core = {} }, null);
    const removed = try mem.forget("a");
    try testing.expect(!removed);
}

test "markdown: empty workspace has zero count" {
    const a = testing.allocator;
    const dir = try tempWorkspace(a);
    defer freeTempWorkspace(a, dir);
    var mem = try MarkdownMemory.init(a, dir);
    defer mem.deinit();
    try testing.expectEqual(@as(usize, 0), try mem.count(a));
}

test "markdown: empty workspace recall returns empty" {
    const a = testing.allocator;
    const dir = try tempWorkspace(a);
    defer freeTempWorkspace(a, dir);
    var mem = try MarkdownMemory.init(a, dir);
    defer mem.deinit();
    const results = try mem.recall(a, "anything", 10, null);
    try testing.expectEqual(@as(usize, 0), results.len);
}

fn lowerBuf(buf: []u8, s: []const u8) []const u8 {
    const n = @min(buf.len, s.len);
    for (s[0..n], 0..) |ch, i| buf[i] = std.ascii.toLower(ch);
    return buf[0..n];
}
