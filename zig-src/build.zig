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
    // On iOS/macOS we link the system libsqlite3 (smaller binary, no version
    // drift, no need for the iOS sysroot to compile sqlite3.c — which Zig's
    // cross-compiler doesn't ship). On every other target we compile the
    // vendored SQLite amalgamation so dev/test boxes without a system SQLite
    // (notably Windows) still work out of the box.
    const target_os = target.result.os.tag;
    const use_system_sqlite = (target_os == .ios or target_os == .macos);

    // `sqlite_c` is the library artifact other modules link against. It's
    // either the compiled amalgamation or null (the system framework is
    // linked directly by the consumer via linker flags).
    var sqlite_c: ?*std.Build.Step.Compile = null;
    if (!use_system_sqlite) {
        const sqlite_mod = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        });
        sqlite_mod.addCSourceFile(.{
            .file = b.path("vendor/sqlite/sqlite3.c"),
            .flags = &.{
                "-std=c11", "-w",
                "-DSQLITE_THREADSAFE=1",
                "-DSQLITE_ENABLE_FTS5",
                "-DSQLITE_OMIT_DEPRECATED",
            },
        });
        const artifact = b.addLibrary(.{
            .name = "sqlite3",
            .root_module = sqlite_mod,
            .linkage = .static,
        });
        artifact.installHeader(b.path("vendor/sqlite/sqlite3.h"), "sqlite3.h");
        b.installArtifact(artifact);
        sqlite_c = artifact;
    }

    // Helper: link SQLite into a consumer module, picking the right source.
    const linkSqlite = struct {
        fn link(mod: *std.Build.Module, sc: ?*std.Build.Step.Compile) void {
            if (sc) |artifact| {
                mod.linkLibrary(artifact);
                mod.addIncludePath(.{ .cwd_relative = "vendor/sqlite" });
            } else {
                // System framework path (iOS/macOS).
                mod.linkSystemLibrary("sqlite3", .{});
            }
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
