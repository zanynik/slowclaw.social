// Smoke test: the pure-Dart JournalEntry decode layer.
//
// The full dart:ffi → Zig core path is exercised by `flutter build windows`
// (which links slowclaw_feed.dll); `flutter test` runs headless and can't load
// dart:ffi, so we test the FFI-free model layer directly.

import 'package:flutter_test/flutter_test.dart';
import 'package:slowclaw_native/src/models.dart';

void main() {
  group('JournalEntry', () {
    test('title is the first line, body is the rest', () {
      final e = JournalEntry(
        key: 'k',
        content: 'My Title\n\nFirst paragraph.\nSecond paragraph.',
      );
      expect(e.title, 'My Title');
      expect(e.body, 'First paragraph.\nSecond paragraph.');
    });

    test('content with no newline: title is the whole content, body empty', () {
      final e = JournalEntry(key: 'k', content: 'Just a title');
      expect(e.title, 'Just a title');
      expect(e.body, '');
    });

    test('blank title falls back to Untitled', () {
      final e = JournalEntry(key: 'k', content: '\n\nbody only');
      expect(e.title, 'Untitled');
    });

    test('fromJson decodes the Zig core recall JSON shape', () {
      final e = JournalEntry.fromJson({
        'key': 'journal_123',
        'content': 'Hello\nWorld',
        'category': 'daily',
        'source': 'text',
        'mediaUrl': '',
      });
      expect(e.key, 'journal_123');
      expect(e.title, 'Hello');
      expect(e.category, 'daily');
    });
  });
}
