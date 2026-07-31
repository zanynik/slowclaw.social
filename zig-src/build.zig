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

    // ── On-device LLM (llama.cpp) ────────────────────────────────────────
    // Compiles the vendored llama.cpp (b10201, CPU backend) into libllama.a
    // and wires it into local_inference.zig. Test steps pass
    // -Dwith-llama=false so they stay fast and C++-free; the FFI then reports
    // "not available" exactly like the pre-llama builds did.
    const with_llama = b.option(bool, "with-llama", "Compile the vendored llama.cpp backend into the staticlib") orelse true;
    const llama_opts = b.addOptions();
    llama_opts.addOption(bool, "with_llama", with_llama);
    const llama_opts_mod = llama_opts.createModule();
    const no_llama_opts = b.addOptions();
    no_llama_opts.addOption(bool, "with_llama", false);
    const no_llama_opts_mod = no_llama_opts.createModule();

    // ── Test module (libc-free, no sqlite) ────────────────────────────────
    // Preserves the debug allocator's behavior the ranker tests depend on.
    const test_mod = b.addModule("slowclaw_feed_test", .{
        .root_source_file = b.path("src/test_root.zig"),
        .target = target,
        .optimize = optimize,
    });
    // Tests build the stub local-inference backend (no llama.cpp compile).
    test_mod.addImport("build_options", no_llama_opts_mod);
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
    // Tests build the stub local-inference backend (no llama.cpp compile).
    ffi_test_mod.addImport("build_options", no_llama_opts_mod);
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
    lib_mod.addImport("build_options", llama_opts_mod);

    // ── llama.cpp staticlib (vendored, CPU backend) ──────────────────────
    // Emitted as a THIRD archive (libllama.a) next to libslowclaw_feed.a and
    // libsqlite3.a; the iOS app links all three plus libc++ (-lllama -lc++).
    const llama_lib = if (with_llama) buildLlamaCpp(b, target, optimize, ios_sysroot) else null;
    if (llama_lib) |ll| {
        lib_mod.linkLibrary(ll);
        // For the @cInclude("llama.h") in local_inference.zig (llama.h
        // itself includes ggml.h, so both include roots are needed).
        lib_mod.addIncludePath(b.path("vendor/llama.cpp/include"));
        lib_mod.addIncludePath(b.path("vendor/llama.cpp/ggml/include"));
    }

    const lib = b.addLibrary(.{
        .name = "slowclaw_feed",
        .root_module = lib_mod,
        .linkage = .static,
    });

    // ── On-device LLM smoke test (opt-in; needs a real GGUF model) ───────
    //   SLOWCLAW_TEST_GGUF=/path/to/model.gguf zig build test-local-llm
    // Loads the model through the same code path the iOS app uses and runs a
    // short chat completion. Skips cleanly when the env var is unset.
    if (llama_lib) |ll| {
        const llm_test_mod = b.addModule("slowclaw_feed_llm_test", .{
            .root_source_file = b.path("src/local_inference.zig"),
            .target = target,
            .optimize = optimize,
        });
        llm_test_mod.link_libc = true;
        llm_test_mod.link_libcpp = true;
        llm_test_mod.addImport("build_options", llama_opts_mod);
        llm_test_mod.addIncludePath(b.path("vendor/llama.cpp/include"));
        llm_test_mod.addIncludePath(b.path("vendor/llama.cpp/ggml/include"));
        llm_test_mod.linkLibrary(ll);
        const llm_tests = b.addTest(.{ .root_module = llm_test_mod });
        const run_llm_tests = b.addRunArtifact(llm_tests);
        const llm_test_step = b.step("test-local-llm", "Run the on-device LLM smoke test (set SLOWCLAW_TEST_GGUF)");
        llm_test_step.dependOn(&run_llm_tests.step);
    }

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

        // libllama.a has ~180 members — far more likely than libsqlite3.a to
        // place a member at a non-8-aligned offset, so it needs the same
        // repack for Apple `ld` (Codeberg ziglang/zig#35280).
        if (llama_lib) |ll| {
            const install_llama = b.addInstallArtifact(ll, .{});
            b.getInstallStep().dependOn(&install_llama.step);
            const aligned_llama = repackInstalledArchiveStep(b, install_llama, "libllama.a");
            const install_aligned_llama = b.addInstallFileWithDir(aligned_llama, .lib, "libllama.a");
            install_aligned_llama.step.dependOn(&install_llama.step);
            b.getInstallStep().dependOn(&install_aligned_llama.step);
        }
    } else if (llama_lib) |ll| {
        b.installArtifact(ll);
    }
}

/// Compile the vendored llama.cpp (ggml + llama, CPU backend only) into a
/// static archive. Mirrors the CMake source lists from upstream b10201:
/// ggml-base + ggml + ggml-cpu (+ arch-specific kernels) + src/*.cpp +
/// src/models/*.cpp. Metal/CUDA/other backends are intentionally not
/// vendored — the Rust/Tauri app defaulted to CPU on iOS for stability
/// (uncatchable Metal allocator crashes), so CPU + NEON is the v1 target.
fn buildLlamaCpp(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    ios_sysroot: ?[]const u8,
) *std.Build.Step.Compile {
    const mod = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    // Zig bundles libc++ (headers + compiled objects) for native/desktop
    // targets, making local builds + the smoke test self-contained. For iOS
    // zig does NOT emit its libc++ into the archive (unsupported target), so
    // there the compiled objects reference the system C++ runtime and the
    // iOS app links Apple's libc++ (-lc++ in project.yml). ABI-compatible:
    // zig 0.16's bundled libc++ is 21.1, same generation as Xcode 26's.
    mod.link_libcpp = target.result.os.tag != .ios;

    const includes: []const []const u8 = &.{
        "vendor/llama.cpp/include",
        "vendor/llama.cpp/ggml/include",
        "vendor/llama.cpp/ggml/src",
        "vendor/llama.cpp/ggml/src/ggml-cpu",
        "vendor/llama.cpp/src",
    };
    for (includes) |inc| mod.addIncludePath(b.path(inc));
    if (ios_sysroot) |sdk| {
        mod.addSystemIncludePath(.{ .cwd_relative = sdk });
        const usr_inc = std.fmt.allocPrint(b.allocator, "{s}/usr/include", .{sdk}) catch @panic("oom");
        mod.addSystemIncludePath(.{ .cwd_relative = usr_inc });
        // C++ stdlib headers from the iOS SDK (zig only adds its bundled
        // libc++ headers when it also links its libc++, which iOS skips —
        // see link_libcpp note above).
        const cxx_inc = std.fmt.allocPrint(b.allocator, "{s}/usr/include/c++/v1", .{sdk}) catch @panic("oom");
        mod.addSystemIncludePath(.{ .cwd_relative = cxx_inc });
    }

    // Definitions mirror upstream CMake (ggml/src/CMakeLists.txt):
    // _XOPEN_SOURCE=600 everywhere but OpenBSD/AIX, _DARWIN_C_SOURCE on
    // Apple. GGML_VERSION/GGML_COMMIT are string literals CMake passes in.
    // -fno-sanitize=undefined: Zig compiles C/C++ with UB traps in safety-
    // enabled builds, but ggml intentionally does null-relative pointer
    // arithmetic (ggml_graph_nbytes starts at p = 0). Upstream builds with
    // plain clang — match that, even for local Debug test builds.
    var c_flags = std.ArrayList([]const u8).empty;
    c_flags.appendSlice(b.allocator, &.{
        "-std=c11",
        "-w",
        "-fno-sanitize=undefined",
        "-D_XOPEN_SOURCE=600",
        "-DGGML_VERSION=\"b10201\"",
        "-DGGML_COMMIT=\"b10201\"",
        "-DGGML_USE_LLAMAFILE",
        "-DGGML_USE_CPU",
    }) catch @panic("oom");
    var cxx_flags = std.ArrayList([]const u8).empty;
    cxx_flags.appendSlice(b.allocator, &.{
        "-std=c++17",
        "-w",
        "-fno-sanitize=undefined",
        "-D_XOPEN_SOURCE=600",
        "-DGGML_VERSION=\"b10201\"",
        "-DGGML_COMMIT=\"b10201\"",
        "-DGGML_USE_LLAMAFILE",
        "-DGGML_USE_CPU",
    }) catch @panic("oom");
    switch (target.result.os.tag) {
        .macos, .ios, .tvos, .watchos, .visionos => {
            c_flags.append(b.allocator, "-D_DARWIN_C_SOURCE") catch @panic("oom");
            cxx_flags.append(b.allocator, "-D_DARWIN_C_SOURCE") catch @panic("oom");
        },
        else => {},
    }

    const arch_dir: []const u8 = switch (target.result.cpu.arch) {
        .aarch64 => "arm",
        .x86_64 => "x86",
        else => "", // generic fallback kernels (GGML_CPU_GENERIC)
    };
    const is_generic = arch_dir.len == 0;
    if (is_generic) {
        c_flags.append(b.allocator, "-DGGML_CPU_GENERIC") catch @panic("oom");
        cxx_flags.append(b.allocator, "-DGGML_CPU_GENERIC") catch @panic("oom");
    }

    var c_sources = std.ArrayList([]const u8).empty;
    c_sources.appendSlice(b.allocator, &.{
        "ggml/src/ggml.c",
        "ggml/src/ggml-alloc.c",
        "ggml/src/ggml-quants.c",
        "ggml/src/ggml-cpu/ggml-cpu.c",
        "ggml/src/ggml-cpu/quants.c",
    }) catch @panic("oom");
    var cxx_sources = std.ArrayList([]const u8).empty;
    cxx_sources.appendSlice(b.allocator, &.{
        "ggml/src/ggml.cpp",
        "ggml/src/ggml-backend.cpp",
        "ggml/src/ggml-backend-meta.cpp",
        "ggml/src/ggml-backend-dl.cpp",
        "ggml/src/ggml-backend-reg.cpp",
        "ggml/src/ggml-opt.cpp",
        "ggml/src/ggml-threading.cpp",
        "ggml/src/gguf.cpp",
        "ggml/src/ggml-cpu/ggml-cpu.cpp",
        "ggml/src/ggml-cpu/repack.cpp",
        "ggml/src/ggml-cpu/hbm.cpp",
        "ggml/src/ggml-cpu/traits.cpp",
        "ggml/src/ggml-cpu/amx/amx.cpp",
        "ggml/src/ggml-cpu/amx/mmq.cpp",
        "ggml/src/ggml-cpu/binary-ops.cpp",
        "ggml/src/ggml-cpu/unary-ops.cpp",
        "ggml/src/ggml-cpu/vec.cpp",
        "ggml/src/ggml-cpu/ops.cpp",
        "ggml/src/ggml-cpu/llamafile/sgemm.cpp",
    }) catch @panic("oom");
    if (!is_generic) {
        c_sources.append(b.allocator, b.fmt("ggml/src/ggml-cpu/arch/{s}/quants.c", .{arch_dir})) catch @panic("oom");
        cxx_sources.append(b.allocator, b.fmt("ggml/src/ggml-cpu/arch/{s}/repack.cpp", .{arch_dir})) catch @panic("oom");
    }

    // llama library itself: src/*.cpp (top level, per upstream CMakeLists)
    // plus the per-architecture model files under src/models/ (globbed in
    // upstream; enumerated from the vendored tree here so new model files
    // picked up by a vendor bump are compiled without editing this list).
    appendVendoredCpp(b, &cxx_sources, "vendor/llama.cpp/src");
    appendVendoredCpp(b, &cxx_sources, "vendor/llama.cpp/src/models");

    for (c_sources.items) |src| {
        mod.addCSourceFile(.{
            .file = b.path(b.fmt("vendor/llama.cpp/{s}", .{src})),
            .flags = c_flags.items,
        });
    }
    for (cxx_sources.items) |src| {
        mod.addCSourceFile(.{
            .file = b.path(b.fmt("vendor/llama.cpp/{s}", .{src})),
            .flags = cxx_flags.items,
        });
    }

    return b.addLibrary(.{
        .name = "llama",
        .root_module = mod,
        .linkage = .static,
    });
}

/// Append every *.cpp directly inside a vendored directory (non-recursive)
/// to `sources`, as paths relative to the zig-src build root.
fn appendVendoredCpp(b: *std.Build, sources: *std.ArrayList([]const u8), dir_path: []const u8) void {
    const io = b.graph.io;
    var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch @panic("vendored llama.cpp tree missing");
    defer dir.close(io);
    var it = dir.iterate();
    while (it.next(io) catch @panic("dir iterate failed")) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".cpp")) continue;
        const rel = std.fmt.allocPrint(b.allocator, "{s}/{s}", .{ dir_path, entry.name }) catch @panic("oom");
        // Strip the leading "vendor/llama.cpp/" — callers prepend it.
        sources.append(b.allocator, rel["vendor/llama.cpp/".len..]) catch @panic("oom");
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
    // Duplicate member basenames are expected (ggml.c + ggml.cpp both become
    // ggml.o, quants.c lives in three dirs, …) and a plain `ar -x` extracts
    // them onto the same path — silently losing members. Apple's `ar` has no
    // instance modifier, so extraction uses `zig ar xN <n>` (llvm-ar) with a
    // per-name instance counter, renaming each member to `<n>-<name>` for
    // uniqueness. `chmod u+rw` because ar leaves members read-only, which
    // libtool otherwise chokes on (Codeberg #35280 comment thread).
    const extract = b.addSystemCommand(&.{
        "sh", "-c",
        \\set -eu
        \\IN="$1"; ZIG="$2"; DIR="$3"
        \\rm -rf "$DIR"; mkdir -p "$DIR"
        \\cd "$DIR"
        \\"$ZIG" ar t "$IN" | awk '{c[$1]++; print c[$1], $1}' | while read -r n name; do
        \\    case "$name" in __.SYMDEF*) continue ;; esac
        \\    "$ZIG" ar xN "$n" "$IN" "$name"
        \\    chmod u+rw "$name"
        \\    mv "$name" "$n-$name"
        \\done
        ,
        "--",
    });
    extract.step.dependOn(&install_lib.step);
    extract.addArg(installed_path);
    extract.addArg(b.graph.zig_exe);
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
