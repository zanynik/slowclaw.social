// slowclaw_native.dart — the public Dart API over the SlowClaw Zig core.
//
// Re-exports the FFI bindings and the pure-Dart models, plus an FFI-backed
// MemoryStore wrapper. Flutter UI imports this library; it never touches
// dart:ffi directly. The boundary:
//   - everything here → direct C ABI call (no method channel)
//   - platform_adapter.dart (future) → method channel for OS-specific surfaces
//
// NOTE: this file imports dart:ffi (via bindings.dart) and so is only usable
// on platforms with a native runtime (iOS, macOS, Windows desktop). The pure
// model types live in src/models.dart and are testable anywhere.

library slowclaw_native;

export 'src/bindings.dart'
    show sqliteOpen, sqliteClose, sqliteCount, sqliteStore, sqliteRecall, localLlmStatusJson;
export 'src/models.dart' show JournalEntry;

import 'dart:convert';
import 'dart:ffi.dart';
import 'src/bindings.dart';
import 'src/models.dart';

/// A thin wrapper over a SQLite-backed memory-store handle. Manages the
/// native pointer's lifetime: call [close] when done (or let it leak for the
/// app's lifetime, which is fine for a single long-lived store).
class MemoryStore {
  MemoryStore(this._db);
  final Pointer<Opaque> _db;
  bool _closed = false;

  /// Open a store backed by a file path (persistent) or ":memory:".
  factory MemoryStore.open(String path) => MemoryStore(sqliteOpen(path));

  /// Number of entries in the store.
  int get count => _closed ? 0 : sqliteCount(_db);

  /// Hybrid FTS5 + vector recall → ranked journal entries.
  List<JournalEntry> recall(String query, {int limit = 50}) {
    if (_closed) return [];
    final json = sqliteRecall(_db, query, limit);
    final list = jsonDecode(json) as List<dynamic>;
    return list
        .cast<Map<String, dynamic>>()
        .map(JournalEntry.fromJson)
        .toList(growable: false);
  }

  /// Store (upsert) a journal entry. Returns the SQLite-style result code
  /// (0 = OK).
  int store({
    required String key,
    required String content,
    String category = 'daily',
    String sessionId = '',
    String source = '',
    String mediaUrl = '',
  }) {
    if (_closed) return -1;
    return sqliteStore(
      _db,
      key: key,
      content: content,
      category: category,
      sessionId: sessionId,
      source: source,
      mediaUrl: mediaUrl,
    );
  }

  /// Close the store and release the native handle. Idempotent.
  void close() {
    if (_closed) return;
    sqliteClose(_db);
    _closed = true;
  }
}
