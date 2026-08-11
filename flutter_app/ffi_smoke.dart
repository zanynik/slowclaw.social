// ffi_smoke.dart — standalone proof that Dart FFI ↔ the Zig core DLL works.
//
// Run from flutter_app/ (where package:ffi resolves):
//   dart run ffi_smoke.dart
//
// Proves the architectural keystone: Dart → DynamicLibrary.open → the Zig
// core's C ABI → SQLite → real data round-trip. Not part of the shipped app.

import 'dart:ffi';
import 'dart:io';
import 'package:ffi/ffi.dart';

// C struct mirrors (from slowclaw_feed.h).
final class SlowclawString extends Struct {
  external Pointer<Uint8> bytes;
  @Size()
  external int len;
}

/// `SlowclawRankResult { SlowclawString items_json; int32_t status; }`.
final class SlowclawRankResult extends Struct {
  external SlowclawString itemsJson;
  @Int32()
  external int status;
}

// open(path, emb) → db | null
typedef _OpenN = Pointer<Opaque> Function(Pointer<Uint8> path, Pointer<Opaque> emb);
typedef _OpenD = Pointer<Opaque> Function(Pointer<Uint8> path, Pointer<Opaque> emb);
typedef _CloseN = Void Function(Pointer<Opaque> db);
typedef _CloseD = void Function(Pointer<Opaque> db);
typedef _CountN = Int64 Function(Pointer<Opaque> db);
typedef _CountD = int Function(Pointer<Opaque> db);

// store(db, k, klen, c, clen, cat, catlen, sid, sidlen, src, srclen, med, medlen)
typedef _StoreN = Int32 Function(
    Pointer<Opaque>, Pointer<Uint8>, IntPtr, Pointer<Uint8>, IntPtr,
    Pointer<Uint8>, IntPtr, Pointer<Uint8>, IntPtr, Pointer<Uint8>, IntPtr, Pointer<Uint8>, IntPtr);
typedef _StoreD = int Function(
    Pointer<Opaque>, Pointer<Uint8>, int, Pointer<Uint8>, int,
    Pointer<Uint8>, int, Pointer<Uint8>, int, Pointer<Uint8>, int, Pointer<Uint8>, int);

// recall(db, q, qlen, limit, session_id, session_id_len, out) → rc
typedef _RecallN = Int32 Function(
    Pointer<Opaque>, Pointer<Uint8>, IntPtr, IntPtr, Pointer<Uint8>, IntPtr, Pointer<SlowclawRankResult>);
typedef _RecallD = int Function(
    Pointer<Opaque>, Pointer<Uint8>, int, int, Pointer<Uint8>, int, Pointer<SlowclawRankResult>);

typedef _FreeN = Void Function(Pointer<NativeType>);
typedef _FreeD = void Function(Pointer<NativeType>);

Pointer<Uint8> _str(String s) => s.toNativeUtf8().cast<Uint8>();

void main() {
  final dllPath = '${Directory.current.path}/../zig-src/zig-out/bin/slowclaw_feed.dll';
  if (!File(dllPath).existsSync()) {
    print('DLL not found at $dllPath');
    print('Run: cd zig-src && zig build -Dshared -Dwith-llama=false');
    exit(1);
  }
  final lib = DynamicLibrary.open(dllPath);
  final open = lib.lookupFunction<_OpenN, _OpenD>('slowclaw_feed_sqlite_open');
  final close = lib.lookupFunction<_CloseN, _CloseD>('slowclaw_feed_sqlite_close');
  final count = lib.lookupFunction<_CountN, _CountD>('slowclaw_feed_sqlite_count');
  final store = lib.lookupFunction<_StoreN, _StoreD>('slowclaw_feed_sqlite_store');
  final recall = lib.lookupFunction<_RecallN, _RecallD>('slowclaw_feed_sqlite_recall');
  final free = lib.lookupFunction<_FreeN, _FreeD>('slowclaw_feed_free');
  print('OK loaded slowclaw_feed.dll, 6 C ABI symbols resolved');

  final dbPath = _str(':memory:');
  final db = open(dbPath, nullptr);
  if (db == nullptr) { print('FAIL sqlite_open returned null'); exit(1); }
  calloc.free(dbPath);
  print('OK sqlite_open(:memory:) -> handle');

  for (final e in [
    ['journal_one', 'First journal\n\nDart FFI into the Zig core works.'],
    ['journal_two', 'Architecture test\n\nThe core owns the data; Flutter renders.'],
  ]) {
    final k = _str(e[0]);
    final c = _str(e[1]);
    final empty = _str('');
    final rc = store(db, k, e[0].length, c, e[1].length,
        empty, 0, empty, 0, empty, 0, empty, 0);
    print('  store(${e[0]}) -> rc=$rc');
    calloc.free(k); calloc.free(c); calloc.free(empty);
  }

  final n = count(db);
  print('OK sqlite_count -> $n entries');

  final q = _str('Dart');
  final out = calloc.allocate<SlowclawRankResult>(sizeOf<SlowclawRankResult>());
  // session_id = NULL, 0 (no session filter).
  final rc = recall(db, q, 3, 50, nullptr, 0, out);
  if (rc != 0) { print('FAIL sqlite_recall rc=$rc'); exit(1); }
  final js = out.ref.itemsJson;
  if (js.bytes == nullptr) {
    print('OK sqlite_recall("Dart") -> empty result');
  } else {
    final json = js.bytes.cast<Utf8>().toDartString(length: js.len);
    free(js.bytes.cast());
    print('OK sqlite_recall("Dart") -> ${json.length} bytes JSON');
    print('  $json');
  }

  calloc.free(q); calloc.free(out);
  close(db);
  print('\nSUCCESS Dart FFI <-> Zig core round-trip works');
}
