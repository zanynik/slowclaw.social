// SlowClawApp.swift — minimal SwiftUI app proving the Zig core round-trip.
//
// Run from Xcode: open this file's containing project, build for the iOS
// simulator, launch. The app:
//   1. Opens a SQLite DB in the app's Documents directory.
//   2. Lets the user type a memory and store it.
//   3. Lists all stored memories (refreshed on every store).
//   4. Lets the user run a hybrid recall search across stored memories.
//
// This proves the entire Swift → C ABI → Zig → SQLite path works end-to-end
// on iOS, validating the slice-7 deliverable.

import SwiftUI
// SlowClawFeed.swift is compiled into the same target (no separate module).
// The C ABI is imported via the bridging header (SWIFT_OBJC_BRIDGING_HEADER).

@main
struct SlowClawApp: App {
    var body: some Scene {
        WindowGroup {
            MemoryView()
        }
    }
}

struct MemoryView: View {
    @StateObject private var store = MemoryStore()

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Store form
                VStack(spacing: 8) {
                    TextField("Key", text: $store.newKey)
                        .textFieldStyle(.roundedBorder)
                    TextField("Content", text: $store.newContent, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(2...4)
                    Picker("Category", selection: $store.newCategory) {
                        ForEach(SlowClawMemoryCategory.allCases, id: \.self) { cat in
                            Text(cat.rawValue.capitalized).tag(cat)
                        }
                    }
                    .pickerStyle(.segmented)
                    Button("Store") {
                        try? store.store()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(store.newKey.isEmpty || store.newContent.isEmpty)
                }
                .padding()

                Divider()

                // Recall search
                HStack {
                    TextField("Search memories", text: $store.query)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { try? store.recall() }
                    Button("Search") { try? store.recall() }
                }
                .padding()

                // Results list
                List(store.displayedEntries, id: \.id) { entry in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(entry.content)
                            .font(.body)
                        HStack {
                            Text(entry.key)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Text(entry.category)
                                .font(.caption.monospaced())
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(.quaternary, in: Capsule())
                        }
                    }
                }
            }
            .navigationTitle("SlowClaw Feed")
            .navigationBarTitleDisplayMode(.inline)
            .task { try? store.refresh() }
        }
    }
}

@MainActor
final class MemoryStore: ObservableObject {
    @Published var newKey: String = ""
    @Published var newContent: String = ""
    @Published var newCategory: SlowClawMemoryCategory = .core
    @Published var query: String = ""
    @Published var displayedEntries: [SlowClawMemoryEntry] = []

    private var db: SlowClawSqliteMemory?

    // The DB lives in the app's Documents directory so it persists across launches.
    private let dbPath: String = {
        let urls = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
        let dir = urls.first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let path = dir.appendingPathComponent("slowclaw.sqlite").path
        // Make sure the parent dir exists (Documents should, but be defensive).
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return path
    }()

    init() {
        do {
            // embedder: true enables hybrid vector+keyword recall via the
            // deterministic HashEmbedder. Toggle to false for keyword-only.
            db = try SlowClawSqliteMemory(path: dbPath, embedder: true)
        } catch {
            print("SlowClaw init failed: \(error)")
        }
    }

    func store() throws {
        guard let db else { return }
        try db.store(key: newKey, content: newContent, category: newCategory)
        newKey = ""
        newContent = ""
        try refresh()
    }

    func recall() throws {
        guard let db else { return }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            try refresh()
            return
        }
        displayedEntries = try db.recall(query: trimmed, limit: 50)
    }

    func refresh() throws {
        guard let db else { return }
        // Cheap "list everything": a recall with a single common keyword.
        // In production the app would use a dedicated list API; this is a demo.
        if displayedEntries.isEmpty {
            displayedEntries = try db.recall(query: "the a an of to and in", limit: 50)
        }
    }
}
