const std = @import("std");
const builtin = @import("builtin");

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

    // Resolve the iOS SDK sysroot once, for reuse across every module that
    // does @cImport of system headers (sqlite.zig, markdown.zig, etc.).
    const target_os = target.result.os.tag;
    const ios_sysroot: ?[]const u8 = blk: {
        if (target_os != .ios) break :blk null;
        const sysroot_opt = b.option([]const u8, "ios-sysroot", "Path to the iOS SDK sysroot (for cross-compiling sqlite3.c + @cImport)");
        break :blk sysroot_opt;
    };

    // Helper: add iOS SDK system include paths to a module (for @cImport).
    const addIosSysroot = struct {
        fn add(mod: *std.Build.Module, sdk_opt: ?[]const u8, allocator: std.mem.Allocator) void {
            const sdk = sdk_opt orelse return;
            mod.addSystemIncludePath(.{ .cwd_relative = sdk });
            const usr_inc = std.fmt.allocPrint(allocator, "{s}/usr/include", .{sdk}) catch return;
            mod.addSystemIncludePath(.{ .cwd_relative = usr_inc });
        }
    }.add;

    // Apply to the sqlite module (for sqlite3.c compilation).
    addIosSysroot(sqlite_mod, ios_sysroot, b.allocator);

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
    addIosSysroot(lib_mod, ios_sysroot, b.allocator);
    const lib = b.addLibrary(.{
        .name = "slowclaw_feed",
        .root_module = lib_mod,
        .linkage = .static,
    });

    // ── Workaround: Apple `ld` rejects Zig's staticlib archive ───────────
    // Zig 0.16's archive writer hardcodes the 4-byte (`.p32`) format even for
    // 64-bit Mach-O members, so Apple's `ld` (Xcode 26.4+) fails the link with:
    //     ld: 64-bit mach-o member 'libslowclaw_feed_zcu.o' not 8-byte aligned
    // Tracked upstream as Codeberg ziglang/zig#35280; fixed in the 0.17-dev
    // branch but NOT backported to any 0.16.x release.
    //
    // On a macOS host we repack the archive with Apple's `libtool`/`ranlib`
    // (which write 8-byte-aligned members). A static lib's `.a` is only
    // materialized by the install step, so: install the artifact normally,
    // run a repack `Run` step that reads the installed `.a` and emits an
    // aligned copy as a generated file, then install-copy that aligned file
    // over the lib dir (last writer wins, ordered by `dependOn`). Non-macOS
    // hosts (Linux/Windows local dev) skip the repack — Apple `ld` is never
    // the consumer there. See README for the local-incremental-cache caveat.
    const install_lib = b.addInstallArtifact(lib, .{});
    b.getInstallStep().dependOn(&install_lib.step);

    if (builtin.os.tag == .macos) {
        const aligned = repackInstalledArchiveStep(b, install_lib, "libslowclaw_feed.a");
        const install_aligned = b.addInstallFileWithDir(aligned, .lib, "libslowclaw_feed.a");
        install_aligned.step.dependOn(&install_lib.step);
        b.getInstallStep().dependOn(&install_aligned.step);
    }
}

/// Read the *installed* static archive, extract its members, and reassemble
/// them with Apple `libtool`/`ranlib` so the Mach-O members are 8-byte aligned.
/// Works around Zig 0.16's hardcoded `.p32` archive format (Codeberg #35280).
///
/// The static `.a` is only materialized by the install step, so this depends on
/// `install_lib` and reads from the install destination (`zig-out/lib/<name>`).
/// The aligned result is emitted as a generated file (via `addOutputFileArg`)
/// so the caller can install-copy it over the lib dir with correct caching.
fn repackInstalledArchiveStep(
    b: *std.Build,
    install_lib: *std.Build.Step.InstallArtifact,
    lib_basename: []const u8,
) std.Build.LazyPath {
    // Deterministic path to the installed archive (zig-out/lib/<lib_basename>).
    const installed_path = b.getInstallPath(.lib, lib_basename);

    // Stage 1: extract the archive's members into a temp dir under the cache.
    // `ar -x` can leave members read-only, so `chmod u+rw` before reassembly
    // (Codeberg #35280 comment thread reports `libtool` choking otherwise).
    const extract = b.addSystemCommand(&.{
        "sh", "-c",
        \\set -eu
        \\IN="$1"; DIR="$2"
        \\rm -rf "$DIR"; mkdir -p "$DIR"
        \\cd "$DIR"
        \\xcrun ar -x "$IN"
        \\chmod u+rw "$DIR"/*.o
        ,
        "--",
    });
    extract.step.dependOn(&install_lib.step);
    extract.addArg(installed_path);
    const extracted_dir = extract.addOutputDirectoryArg("extracted");

    // Stage 2: `libtool -static` reassembles the members with correct 8-byte
    // alignment; `ranlib` rebuilds the archive symbol table Apple `ld` expects.
    // `xcrun` resolves both to the active Xcode toolchain regardless of PATH.
    // The aligned archive is emitted as a Zig-generated output file ($2).
    const repack = b.addSystemCommand(&.{
        "sh", "-c",
        \\set -eu
        \\DIR="$1"; OUT="$2"
        \\xcrun libtool -static -o "$OUT" "$DIR"/*.o
        \\xcrun ranlib "$OUT"
        ,
        "--",
    });
    repack.step.dependOn(&extract.step);
    repack.addDirectoryArg(extracted_dir);
    return repack.addOutputFileArg(lib_basename);
}
