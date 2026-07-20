const std = @import("std");

// SlowClaw Social — Zig core pilot.
//
// Build modes:
//   zig build           → emit `zig-out/libslowclaw_feed.a` (staticlib, includes
//                          vendored SQLite amalgamation + the C ABI surface)
//   zig build test      → run libc-free unit tests (excludes ffi + sqlite)
//   zig build test-ffi  → run the libc-linked C ABI tests (excludes sqlite)
//   zig build test-sqlite → run the SQLite-backed tests (libc + sqlite linked)
//
// See README.md for the port status and slice breakdown.

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // ── Test module (libc-free, no sqlite) ────────────────────────────────
    // Preserves the debug allocator's behavior the ranker tests depend on.
    const test_mod = b.addModule("slowclaw_feed_test", .{
        .root_source_file = b.path("src/test_root.zig"),
        .target = target,
        .optimize = optimize,
    });
    const lib_tests = b.addTest(.{
        .root_module = test_mod,
    });
    const run_lib_tests = b.addRunArtifact(lib_tests);
    const test_step = b.step("test", "Run all unit tests in the slowclaw_feed package (libc-free)");
    test_step.dependOn(&run_lib_tests.step);

    // ── SQLite source ────────────────────────────────────────────────────
    // Always compile the vendored SQLite amalgamation. The amalgamation needs
    // the target's libc headers (stdio.h etc.). Zig ships libc for most
    // targets but NOT for iOS — when targeting iOS, the caller must provide
    // the iOS SDK sysroot via the SLOWCLAW_IOS_SYSROOT env var (set by the
    // CI workflow to `xcrun --sdk iphoneos --show-sdk-path`). We plumb it
    // through as -isysroot for the C compile.
    const sqlite_mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });

    // Build the C compile flags. Add -isysroot when targeting iOS and a
    // sysroot path is available; otherwise Zig's bundled libc provides the
    // headers.
    var sqlite_flags = std.ArrayList([]const u8).empty;
    sqlite_flags.append(b.allocator, "-std=c11") catch unreachable;
    sqlite_flags.append(b.allocator, "-w") catch unreachable;
    sqlite_flags.append(b.allocator, "-DSQLITE_THREADSAFE=1") catch unreachable;
    sqlite_flags.append(b.allocator, "-DSQLITE_ENABLE_FTS5") catch unreachable;
    sqlite_flags.append(b.allocator, "-DSQLITE_OMIT_DEPRECATED") catch unreachable;

    const target_os = target.result.os.tag;
    if (target_os == .ios) {
        // iOS targets need the iOS SDK sysroot for libc headers (stdio.h etc).
        // Pass it via -Dios-sysroot=<path>. The CI workflow and project.yml
        // both resolve it via `xcrun --sdk iphoneos --show-sdk-path`.
        const sysroot_opt = b.option([]const u8, "ios-sysroot", "Path to the iOS SDK sysroot (for cross-compiling sqlite3.c)");
        if (sysroot_opt) |sdk| {
            const isysroot = std.fmt.allocPrint(b.allocator, "-isysroot{s}", .{sdk}) catch unreachable;
            sqlite_flags.append(b.allocator, isysroot) catch unreachable;
        }
    }

    sqlite_mod.addCSourceFile(.{
        .file = b.path("vendor/sqlite/sqlite3.c"),
        .flags = sqlite_flags.items,
    });
    const sqlite_c = b.addLibrary(.{
        .name = "sqlite3",
        .root_module = sqlite_mod,
        .linkage = .static,
    });
    sqlite_c.installHeader(b.path("vendor/sqlite/sqlite3.h"), "sqlite3.h");
    b.installArtifact(sqlite_c);

    // Helper: link SQLite into a consumer module.
    const linkSqlite = struct {
        fn link(mod: *std.Build.Module, sc: *std.Build.Step.Compile) void {
            mod.linkLibrary(sc);
            mod.addIncludePath(.{ .cwd_relative = "vendor/sqlite" });
        }
    }.link;

    // ── FFI + SQLite test module (libc + sqlite linked) ───────────────────
    // ffi.zig now exposes the SQLite-backed memory store through the C ABI,
    // so the FFI tests need both libc and sqlite.
    const ffi_test_mod = b.addModule("slowclaw_feed_ffi_test", .{
        .root_source_file = b.path("src/ffi.zig"),
        .target = target,
        .optimize = optimize,
    });
    ffi_test_mod.link_libc = true;
    linkSqlite(ffi_test_mod, sqlite_c);
    const ffi_tests = b.addTest(.{
        .root_module = ffi_test_mod,
    });
    const run_ffi_tests = b.addRunArtifact(ffi_tests);
    const ffi_test_step = b.step("test-ffi", "Run the C ABI tests (libc + sqlite linked)");
    ffi_test_step.dependOn(&run_ffi_tests.step);

    // ── SQLite test module (libc + sqlite linked) ─────────────────────────
    const sqlite_test_mod = b.addModule("slowclaw_feed_sqlite_test", .{
        .root_source_file = b.path("src/sqlite.zig"),
        .target = target,
        .optimize = optimize,
    });
    sqlite_test_mod.link_libc = true;
    linkSqlite(sqlite_test_mod, sqlite_c);
    const sqlite_tests = b.addTest(.{
        .root_module = sqlite_test_mod,
    });
    const run_sqlite_tests = b.addRunArtifact(sqlite_tests);
    const sqlite_test_step = b.step("test-sqlite", "Run the SQLite-backed tests (libc + sqlite linked)");
    sqlite_test_step.dependOn(&run_sqlite_tests.step);

    // ── Markdown test module (libc linked for file I/O) ───────────────────
    const markdown_test_mod = b.addModule("slowclaw_feed_markdown_test", .{
        .root_source_file = b.path("src/markdown.zig"),
        .target = target,
        .optimize = optimize,
    });
    markdown_test_mod.link_libc = true;
    const markdown_tests = b.addTest(.{
        .root_module = markdown_test_mod,
    });
    const run_markdown_tests = b.addRunArtifact(markdown_tests);
    const markdown_test_step = b.step("test-markdown", "Run the Markdown memory tests (libc linked)");
    markdown_test_step.dependOn(&run_markdown_tests.step);

    // ── Response-cache test module (libc + sqlite linked) ─────────────────
    const response_cache_test_mod = b.addModule("slowclaw_feed_response_cache_test", .{
        .root_source_file = b.path("src/response_cache.zig"),
        .target = target,
        .optimize = optimize,
    });
    response_cache_test_mod.link_libc = true;
    linkSqlite(response_cache_test_mod, sqlite_c);
    const response_cache_tests = b.addTest(.{
        .root_module = response_cache_test_mod,
    });
    const run_response_cache_tests = b.addRunArtifact(response_cache_tests);
    const response_cache_test_step = b.step("test-response-cache", "Run the LLM response cache tests (libc + sqlite)");
    response_cache_test_step.dependOn(&run_response_cache_tests.step);

    // ── Library artifact (libc + sqlite + ffi, ships to iOS) ─────────────
    const lib_mod = b.addModule("slowclaw_feed_lib", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    lib_mod.link_libc = true;
    linkSqlite(lib_mod, sqlite_c);
    const lib = b.addLibrary(.{
        .name = "slowclaw_feed",
        .root_module = lib_mod,
        .linkage = .static,
    });
    b.installArtifact(lib);
}
