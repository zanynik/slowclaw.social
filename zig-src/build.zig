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

    // The library module. All public surface area is re-exported from
    // `src/root.zig`; sub-modules are private to the package.
    const lib_mod = b.addModule("slowclaw_feed", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
        .optimize = optimize,
    });

    // Static library artifact. This is what a future iOS Swift bridge (or any
    // C-ABI consumer) will link against. Not wired to anything yet.
    const lib = b.addLibrary(.{
        .name = "slowclaw_feed",
        .root_module = lib_mod,
        .linkage = .static,
    });
    b.installArtifact(lib);

    // Test runner: compiles every `test {}` block reachable from root.zig.
    const lib_tests = b.addTest(.{
        .root_module = lib_mod,
    });
    const run_lib_tests = b.addRunArtifact(lib_tests);

    const test_step = b.step("test", "Run all unit tests in the slowclaw_feed package");
    test_step.dependOn(&run_lib_tests.step);
}
