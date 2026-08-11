// main.dart — SlowClaw Flutter shell (Phase 1 scaffold).
//
// One screen: a journal list rendered from the Zig core's memory store via
// dart:ffi. This proves the full pipeline on Windows desktop:
//   Flutter UI → dart:ffi → libslowclaw_feed.dll → SQLite → recall JSON → render
//
// The Zig core owns the data + the recall/ranking logic; Flutter owns only
// presentation. This is the architecture boundary: pure-Zig functions are
// called DIRECTLY via FFI (no method channel); only OS-specific surfaces
// (mic, Speech STT, background tasks) will later use a method channel.

import 'dart:io' show Directory, Platform;
import 'package:flutter/material.dart';
import 'package:slowclaw_native/slowclaw_native.dart';

void main() {
  runApp(const SlowClawApp());
}

class SlowClawApp extends StatelessWidget {
  const SlowClawApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'SlowClaw',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorSchemeSeed: const Color(0xFF6750A4),
        brightness: Brightness.dark,
        useMaterial3: true,
      ),
      home: const JournalListScreen(),
    );
  }
}

class JournalListScreen extends StatefulWidget {
  const JournalListScreen({super.key});

  @override
  State<JournalListScreen> createState() => _JournalListScreenState();
}

class _JournalListScreenState extends State<JournalListScreen> {
  late final MemoryStore _store;
  List<JournalEntry> _entries = [];
  String? _statusLine;

  @override
  void initState() {
    super.initState();
    // Open a persistent store under the app's docs dir. Falls back to an
    // in-memory DB if the directory isn't resolvable (e.g. some test contexts).
    final dbPath = _dbPath();
    _store = MemoryStore.open(dbPath);
    _seedIfEmpty();
    _refresh();
  }

  @override
  void dispose() {
    _store.close();
    super.dispose();
  }

  /// A stable on-disk path for the journal DB under the user's docs dir.
  String _dbPath() {
    final docs = Platform.isWindows
        ? '${Platform.environment['APPDATA']}\\SlowClaw'
        : '${Directory.systemTemp.path}/slowclaw';
    try {
      Directory(docs).createSync(recursive: true);
    } catch (_) {}
    return '$docs${Platform.isWindows ? '\\' : '/'}journals.db';
  }

  /// Seed a couple of example entries on first run so the list isn't empty.
  /// (Purely for the scaffold demo — real entries come from capture later.)
  void _seedIfEmpty() {
    if (_store.count > 0) return;
    _store.store(
      key: 'journal_welcome',
      content: 'Welcome to SlowClaw\n\nThis entry is stored in the Zig core '
          '(libslowclaw_feed) and read back via dart:ffi — no method channel. '
          'The Flutter shell renders what the core owns.',
      category: 'daily',
      source: 'text',
    );
    _store.store(
      key: 'journal_demo',
      content: 'Architecture boundary\n\n'
          'dart:ffi → libslowclaw_feed (direct C ABI)\n'
          'MethodChannel → OS adapters (mic, Speech STT, BGTask) — Phase 2.\n\n'
          'The Zig core stays the single source of truth for data + logic.',
      category: 'daily',
      source: 'text',
    );
  }

  void _refresh() {
    // Recall with an empty query returns the most recent entries (the Zig
    // core's recall path handles empty-query as a chronological listing).
    final entries = _store.recall('', limit: 50);
    final llm = localLlmStatusJson();
    setState(() {
      _entries = entries;
      _statusLine = '${entries.length} entries · on-device AI: '
          '${llm.contains('"loaded":true') ? "ready" : "off"}';
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('SlowClaw'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _refresh,
            tooltip: 'Refresh',
          ),
        ],
      ),
      body: Column(
        children: [
          if (_statusLine != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  _statusLine!,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
            ),
          Expanded(
            child: _entries.isEmpty
                ? const Center(child: Text('No journals yet.'))
                : ListView.builder(
                    itemCount: _entries.length,
                    itemBuilder: (context, i) {
                      final e = _entries[i];
                      return ListTile(
                        title: Text(e.title, maxLines: 1, overflow: TextOverflow.ellipsis),
                        subtitle: Text(
                          e.body.isEmpty ? e.title : e.body,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        leading: const Icon(Icons.article_outlined),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
