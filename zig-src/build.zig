const std = @import("std");

// SlowClaw Social — Zig core pilot (slice 1: feed ranker).
//
// This package is a port-in-progress of selected pure-logic modules from the
// Rust core (`src/feed/ranker.rs`, `src/memory/vector.rs`, `src/util.rs`) to
// Zig. It is intentionally additive: the Rust source remains the authoritative
// spec until the port reaches feature parity and the iOS shell wires up.
//
// Build modes:
//   zig build           → emit `zig-out/libslowclaw_feed.a` (staticlib, future iOS FFI artifact)
//   zig build test      → run all `test {}` blocks across the package
//
// See README.md in this directory for the port status and slice breakdown.

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // ── Test module (libc-free) ────────────────────────────────────────────
    // The test binary runs every `test {}` block in the package EXCEPT those
    // in ffi.zig (which require libc and round-trip through `export fn`s — not
    // useful in the test runner anyway). Keeping the test binary libc-free
    // preserves the debug allocator's behavior the ranker tests depend on.
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

    // ── FFI tests (libc-linked) ───────────────────────────────────────────
    // ffi.zig uses `std.c.free` for cross-language memory ownership, so its
    // tests need libc. Compile and run them as a separate `zig build test-ffi`
    // step so they don't change the default test binary's allocator behavior.
    const ffi_test_mod = b.addModule("slowclaw_feed_ffi_test", .{
        .root_source_file = b.path("src/ffi.zig"),
        .target = target,
        .optimize = optimize,
    });
    ffi_test_mod.link_libc = true;
    const ffi_tests = b.addTest(.{
        .root_module = ffi_test_mod,
    });
    const run_ffi_tests = b.addRunArtifact(ffi_tests);
    const ffi_test_step = b.step("test-ffi", "Run the C ABI tests (libc-linked)");
    ffi_test_step.dependOn(&run_ffi_tests.step);

    // ── Library artifact (libc-linked, includes the C ABI surface) ────────
    // The staticlib that ships to iOS / Xcode MUST link libc because ffi.zig
    // uses `std.c.free` for cross-language memory ownership. The library
    // module is separate from the test module so adding libc here doesn't
    // affect the test binary.
    const lib_mod = b.addModule("slowclaw_feed_lib", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });
    lib_mod.link_libc = true;
    const lib = b.addLibrary(.{
        .name = "slowclaw_feed",
        .root_module = lib_mod,
        .linkage = .static,
    });
    b.installArtifact(lib);
}
