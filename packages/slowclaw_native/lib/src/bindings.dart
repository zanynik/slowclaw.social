// bindings.dart — Dart FFI bindings over the SlowClaw Zig core (libslowclaw_feed).
//
// Mirrors ios-app/SlowClawFeed/Sources/SlowClawFeed/include/slowclaw_feed.h.
// dart:ffi calls the C ABI DIRECTLY — no method-channel hop — for every
// pure-Zig function (memory store, ranking, status, on-device LLM, audio).
// The method channel (platform_adapter.dart) exists ONLY for what the OS
// uniquely requires: mic capture, Apple Speech STT, background tasks.
//
// This first increment binds the subset needed for the journal-list screen
// (sqlite store + recall + free + local-llm status). Adding more bindings is
// mechanical: declare the C prototype in _NativeBindings, then a Dart wrapper
// in SlowclawNative. ffigen (libclang-based autogeneration) is a follow-on for
// the full ~40-fn surface.

import 'dart:ffi.dart';
import 'dart:io' show Platform;
import 'package:ffi/ffi.dart';

// ── C struct mirrors (from slowclaw_feed.h) ────────────────────────────────

/// `SlowclawString { const uint8_t* bytes; size_t len; }` — a length-prefixed
/// UTF-8 string owned by the Zig core (caller frees via slowclaw_feed_free).
final class SlowclawString extends Struct {
  external Pointer<UnsignedChar> bytes;
  @Size()
  external int len;
}

/// `SlowclawRankResult { SlowclawString items_json; int32_t status; }` — the
/// out-param shape used by slowclaw_feed_sqlite_recall (and the rank fns).
final class SlowclawRankResult extends Struct {
  external SlowclawString itemsJson;
  @Int32()
  external int status;
}

// ── Native function signatures ─────────────────────────────────────────────

typedef _FreeNative = Void Function(Pointer<NativeType> ptr);
typedef _FreeDart = void Function(Pointer<NativeType> ptr);

typedef _StatusNative = Int32 Function(Pointer<SlowclawString>);
typedef _StatusDart = int Function(Pointer<SlowclawString>);

typedef _SqliteOpenNative = Pointer<Opaque> Function(
    Pointer<Utf8> path, Pointer<Opaque> embedder);
typedef _SqliteOpenDart = Pointer<Opaque> Function(
    Pointer<Utf8> path, Pointer<Opaque> embedder);

typedef _SqliteCloseNative = Void Function(Pointer<Opaque> db);
typedef _SqliteCloseDart = void Function(Pointer<Opaque> db);

typedef _SqliteCountNative = Int64 Function(Pointer<Opaque> db);
typedef _SqliteCountDart = int Function(Pointer<Opaque> db);

// recall(db, query, query_len, limit, session_id, session_id_len, out_result)
typedef _SqliteRecallNative = Int32 Function(
    Pointer<Opaque> db,
    Pointer<Utf8> query,
    @Size() int queryLen,
    @Size() int limit,
    Pointer<Utf8> sessionId,
    @Size() int sessionIdLen,
    Pointer<SlowclawRankResult> out);
typedef _SqliteRecallDart = int Function(
    Pointer<Opaque> db,
    Pointer<Utf8> query,
    int queryLen,
    int limit,
    Pointer<Utf8> sessionId,
    int sessionIdLen,
    Pointer<SlowclawRankResult> out);

typedef _SqliteStoreNative = Int32 Function(
    Pointer<Opaque> db,
    Pointer<Utf8> key, @Size() int keyLen,
    Pointer<Utf8> content, @Size() int contentLen,
    Pointer<Utf8> category, @Size() int categoryLen,
    Pointer<Utf8> sessionId, @Size() int sessionIdLen,
    Pointer<Utf8> source, @Size() int sourceLen,
    Pointer<Utf8> mediaUrl, @Size() int mediaUrlLen);
typedef _SqliteStoreDart = int Function(
    Pointer<Opaque> db,
    Pointer<Utf8> key, int keyLen,
    Pointer<Utf8> content, int contentLen,
    Pointer<Utf8> category, int categoryLen,
    Pointer<Utf8> sessionId, int sessionIdLen,
    Pointer<Utf8> source, int sourceLen,
    Pointer<Utf8> mediaUrl, int mediaUrlLen);

// ── The loaded native library ──────────────────────────────────────────────

/// Loads libslowclaw_feed and exposes its C functions as Dart callables.
/// The library file is built by the platform build system (CMake on Windows,
/// podspec on iOS/macOS) and bundled with the app; DynamicLibrary.open finds
/// it on the loader path.
class _Native {
  _Native(this._lib);

  final DynamicLibrary _lib;

  // Bindings are looked up lazily on first use and cached.
  late final free = _lib.lookupFunction<_FreeNative, _FreeDart>('slowclaw_feed_free');
  late final localLlmStatus =
      _lib.lookupFunction<_StatusNative, _StatusDart>('slowclaw_feed_local_llm_status');
  late final sqliteOpen =
      _lib.lookupFunction<_SqliteOpenNative, _SqliteOpenDart>('slowclaw_feed_sqlite_open');
  late final sqliteClose =
      _lib.lookupFunction<_SqliteCloseNative, _SqliteCloseDart>('slowclaw_feed_sqlite_close');
  late final sqliteCount =
      _lib.lookupFunction<_SqliteCountNative, _SqliteCountDart>('slowclaw_feed_sqlite_count');
  late final sqliteRecall =
      _lib.lookupFunction<_SqliteRecallNative, _SqliteRecallDart>('slowclaw_feed_sqlite_recall');
  late final sqliteStore =
      _lib.lookupFunction<_SqliteStoreNative, _SqliteStoreDart>('slowclaw_feed_sqlite_store');

  static _Native load() {
    // The bundle name; the platform build installs it on the loader path.
    // Windows: slowclaw_feed.dll; macOS/iOS: the framework / dylib.
    final name = Platform.isWindows
        ? 'slowclaw_feed.dll'
        : Platform.isMacOS
            ? 'slowclaw_feed.dylib'
            : 'slowclaw_feed.so';
    return _Native(DynamicLibrary.open(name));
  }
}

// ── Dart-facing helpers ────────────────────────────────────────────────────

/// Reads a SlowclawString out-param into a Dart String, then frees the
/// Zig-owned bytes via slowclaw_feed_free. Returns null if bytes is null.
String? _readAndFree(_Native n, Pointer<SlowclawString> outPtr) {
  final s = outPtr.ref;
  if (s.bytes == nullptr) return null;
  try {
    return s.bytes.cast<Utf8>().toDartString(length: s.len);
  } finally {
    n.free(s.bytes.cast());
  }
}

/// The singleton native binding. Initialized once on first access.
final _native = _Native.load();
_Native get _n => _native;

/// On-device LLM status as raw JSON ({available,loaded,modelId?,reason}).
String localLlmStatusJson() {
  final out = calloc.allocate<SlowclawString>(sizeOf<SlowclawString>());
  try {
    _n.localLlmStatus(out);
    return _readAndFree(_n, out) ?? '{"available":false,"loaded":false}';
  } finally {
    calloc.free(out);
  }
}

/// Open a SQLite-backed memory store. Pass ":memory:" for an in-memory DB, or
/// a filesystem path for persistence. Returns an opaque handle.
Pointer<Opaque> sqliteOpen(String path) {
  final p = path.toNativeUtf8();
  try {
    return _n.sqliteOpen(p, nullptr);
  } finally {
    calloc.free(p);
  }
}

/// Close a memory store handle (no-op safe on null/already-closed).
void sqliteClose(Pointer<Opaque> db) => _n.sqliteClose(db);

/// Count of entries in the store.
int sqliteCount(Pointer<Opaque> db) => _n.sqliteCount(db);

/// Store (upsert) a journal entry. Empty optionals pass as empty strings.
int sqliteStore(
    Pointer<Opaque> db, {
    required String key,
    required String content,
    String category = 'daily',
    String sessionId = '',
    String source = '',
    String mediaUrl = '',
  }) {
  // Allocate each native string and free them all together in finally.
  final k = key.toNativeUtf8();
  final c = content.toNativeUtf8();
  final cat = category.toNativeUtf8();
  final sid = sessionId.toNativeUtf8();
  final src = source.toNativeUtf8();
  final media = mediaUrl.toNativeUtf8();
  try {
    return _n.sqliteStore(
        db,
        k, key.length,
        c, content.length,
        cat, category.length,
        sid, sessionId.length,
        src, source.length,
        media, mediaUrl.length);
  } finally {
    calloc.free(k);
    calloc.free(c);
    calloc.free(cat);
    calloc.free(sid);
    calloc.free(src);
    calloc.free(media);
  }
}

/// Hybrid FTS5 + vector recall → a JSON array of entries. Returns the raw JSON
/// string (decode on the Dart side with dart:convert).
String sqliteRecall(Pointer<Opaque> db, String query, int limit) {
  final out = calloc.allocate<SlowclawRankResult>(sizeOf<SlowclawRankResult>());
  final q = query.toNativeUtf8();
  try {
    // session_id = NULL / 0 → no session filter.
    _n.sqliteRecall(db, q, query.length, limit, nullptr.cast(), 0, out);
    final js = out.ref.itemsJson;
    if (js.bytes == nullptr) return '[]';
    try {
      return js.bytes.cast<Utf8>().toDartString(length: js.len);
    } finally {
      _n.free(js.bytes.cast());
    }
  } finally {
    calloc.free(q);
    calloc.free(out);
  }
}
