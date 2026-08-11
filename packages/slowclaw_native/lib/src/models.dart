// models.dart — pure-Dart data types for the SlowClaw shell.
//
// Deliberately has NO dart:ffi import so these types can be unit-tested in any
// Dart environment (including `flutter test`, which runs headless and flags
// dart:ffi as unavailable). The FFI bindings (bindings.dart) and the
// FFI-backed store (slowclaw_native.dart) are separate.

/// One journal entry, decoded from the Zig core's recall JSON.
class JournalEntry {
  JournalEntry({
    required this.key,
    required this.content,
    this.category = '',
    this.source = '',
    this.mediaUrl = '',
  });

  factory JournalEntry.fromJson(Map<String, dynamic> json) {
    return JournalEntry(
      key: json['key'] as String? ?? '',
      content: json['content'] as String? ?? '',
      category: json['category'] as String? ?? '',
      source: json['source'] as String? ?? '',
      mediaUrl: json['mediaUrl'] as String? ?? '',
    );
  }

  final String key;
  final String content;
  final String category;
  final String source;
  final String mediaUrl;

  /// The first line of the content (the entry's title), or a fallback.
  String get title {
    final i = content.indexOf('\n');
    final t = i < 0 ? content : content.substring(0, i);
    return t.trim().isEmpty ? 'Untitled' : t.trim();
  }

  /// The body (everything after the title line).
  String get body {
    final i = content.indexOf('\n');
    return i < 0 ? '' : content.substring(i + 1).trim();
  }
}
