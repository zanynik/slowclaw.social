# CMakeLists.txt for the slowclaw_native Flutter plugin (Windows).
#
# Builds the Zig core (libslowclaw_feed) as a shared library and bundles the
# DLL with the Flutter Windows app. dart:ffi loads slowclaw_feed.dll at runtime.
#
# The Zig toolchain is resolved from tools/zig/ (local) or tools-zig/ (CI), the
# same convention as the iOS project.yml pre-build script. The build runs:
#   zig build -Dshared -Dwith-llama=false -Doptimize=ReleaseFast -Dtarget=x86_64-windows-msvc
# (-Dwith-llama=false: the llama pthread_mutex_t path is unported on Windows —
#  pre-existing, separate concern. macOS desktop can link llama.)

cmake_minimum_required(VERSION 3.14)

set(PROJECT_NAME "slowclaw_native")
project(${PROJECT_NAME} LANGUAGES CXX)

# ── Locate the Zig binary ───────────────────────────────────────────────────
# Same convention as ios-app/project.yml: tools/zig/ locally, tools-zig/ in CI.
set(ZIG_BIN "${CMAKE_SOURCE_DIR}/../../../tools/zig/zig.exe")
if(NOT EXISTS "${ZIG_BIN}")
  set(ZIG_BIN "${CMAKE_SOURCE_DIR}/../../../tools-zig/zig.exe")
endif()

# ── Build the Zig shared library ───────────────────────────────────────────
set(ZIG_SRC "${CMAKE_SOURCE_DIR}/../../../zig-src")
set(ZIG_OUT "${ZIG_SRC}/zig-out")
# The .dll lands in zig-out/bin/; the import stub in zig-out/lib/.
set(DLL_PATH "${ZIG_OUT}/bin/slowclaw_feed.dll")
set(IMPLIB_PATH "${ZIG_OUT}/lib/slowclaw_feed.lib")

# Run zig build once per configuration. BYPRODUCTS lets CMake know the files
# this custom command produces (so the install step can pick them up).
add_custom_command(
  OUTPUT "${DLL_PATH}"
  COMMAND "${ZIG_BIN}" build -Dshared -Dwith-llama=false -Doptimize=ReleaseFast
          --build-file "${ZIG_SRC}/build.zig"
  WORKING_DIRECTORY "${ZIG_SRC}"
  DEPENDS "${ZIG_SRC}/build.zig"
  COMMENT "Building libslowclaw_feed.dll via zig (Windows desktop, no llama)"
  VERBATIM
)

# A pseudo-target that depends on the DLL build. The Flutter app links against
# the import lib; the DLL is bundled into the output via the install rule.
add_custom_target(slowclaw_feed_dll ALL DEPENDS "${DLL_PATH}")

# Expose the import library so the Flutter app can link -lslowclaw_feed.
add_library(slowclaw_native SHARED IMPORTED GLOBAL)
add_dependencies(slowclaw_native slowclaw_feed_dll)
set_target_properties(slowclaw_native PROPERTIES
  IMPORTED_LOCATION "${DLL_PATH}"
  IMPORTED_IMPLIB "${IMPLIB_PATH}"
)

# ── Bundle the DLL next to the Flutter executable ──────────────────────────
# Flutter's Windows runner copies dependencies from the plugin's
# `${BINARY_DIR}/$<CONFIG>/` directory; the generic plugin install step below
# places the DLL there so it ships beside the .exe.
install(FILES "${DLL_PATH}" DESTINATION "${INSTALL_BUNDLE_LIB_DIR}")
