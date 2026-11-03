import Foundation

/// The phone's source of truth: journals, spaces, and space items in one small
/// JSON file. Every mutation marks the record dirty so CloudSync can push it.
@MainActor
final class Store: ObservableObject {
    static let shared = Store()

    @Published private(set) var journals: [Journal] = []
    @Published private(set) var spaces: [Space] = []
    @Published private(set) var items: [SpaceItem] = []
    @Published var loadError: String?

    /// Called after any local change; CloudSync uses it to schedule a push.
    var onLocalChange: (@MainActor () -> Void)?

    private struct Snapshot: Codable {
        var version: Int
        var journals: [Journal]
        var spaces: [Space]
        var items: [SpaceItem]
    }

    private var saveTask: Task<Void, Never>?

    private static var fileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("SlowClaw", isDirectory: true).appendingPathComponent("store.json")
    }

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder(); d.dateDecodingStrategy = .secondsSince1970; return d
    }()
    private static let encoder: JSONEncoder = {
        let e = JSONEncoder(); e.dateEncodingStrategy = .secondsSince1970; return e
    }()

    init() {
        load()
    }

    // MARK: - Persistence

    private func load() {
        let url = Self.fileURL
        guard FileManager.default.fileExists(atPath: url.path) else {
            seedDefaultSpaces()
            return
        }
        do {
            let snap = try Self.decoder.decode(Snapshot.self, from: Data(contentsOf: url))
            journals = snap.journals
            spaces = snap.spaces
            items = snap.items
        } catch {
            // Never overwrite a file we could not read.
            let backup = url.deletingLastPathComponent()
                .appendingPathComponent("store-unreadable-\(Int(Date().timeIntervalSince1970)).json")
            try? FileManager.default.copyItem(at: url, to: backup)
            loadError = "Saved journals could not be read. A backup copy was kept."
        }
    }

    private func seedDefaultSpaces() {
        let now = Date()
        spaces = DefaultSpaces.all.enumerated().map { index, pair in
            Space(id: newID("space"), name: pair.0, icon: pair.1, summary: "", sortOrder: index,
                  createdAt: now, updatedAt: now, deleted: false, dirty: true)
        }
        scheduleSave()
    }

    func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    func saveNow() {
        guard loadError == nil else { return }
        let snap = Snapshot(version: 1, journals: journals, spaces: spaces, items: items)
        do {
            let url = Self.fileURL
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = try Self.encoder.encode(snap)
            try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch {
            loadError = "Could not save: \(error.localizedDescription)"
        }
    }

    private func changed() {
        scheduleSave()
        onLocalChange?()
    }

    // MARK: - Queries

    var visibleJournals: [Journal] {
        journals.filter { !$0.deleted }.sorted { $0.createdAt > $1.createdAt }
    }

    var visibleSpaces: [Space] {
        spaces.filter { !$0.deleted }.sorted {
            $0.sortOrder == $1.sortOrder ? $0.name < $1.name : $0.sortOrder < $1.sortOrder
        }
    }

    func journal(_ id: String) -> Journal? { journals.first { $0.id == id } }
    func space(_ id: String?) -> Space? {
        guard let id else { return nil }
        return spaces.first { $0.id == id && !$0.deleted }
    }

    func journals(in spaceID: String) -> [Journal] {
        visibleJournals.filter { $0.spaceID == spaceID }
    }

    func items(in spaceID: String) -> [SpaceItem] {
        items.filter { $0.spaceID == spaceID && !$0.deleted }
            .sorted { $0.createdAt > $1.createdAt }
    }

    func items(fromJournal journalID: String) -> [SpaceItem] {
        items.filter { $0.journalID == journalID && !$0.deleted }
    }

    func openTodoCount(_ spaceID: String) -> Int {
        items.filter { $0.spaceID == spaceID && !$0.deleted && $0.kind == .todo && !$0.done }.count
    }

    var unsortedJournals: [Journal] {
        visibleJournals.filter { $0.status == .ready && space($0.spaceID) == nil }
    }

    // MARK: - Journals

    @discardableResult
    func addJournal(title: String, body: String, transcript: String? = nil, audioPath: String? = nil,
                    status: JournalStatus = .ready, createdAt: Date = Date(), id: String? = nil) -> Journal {
        let now = Date()
        let j = Journal(id: id ?? newID("journal"), title: title, body: body, transcript: transcript,
                        audioPath: audioPath, spaceID: nil, createdAt: createdAt, updatedAt: now,
                        status: status, organized: false, deleted: false, dirty: true)
        journals.append(j)
        changed()
        return j
    }

    func updateJournal(_ id: String, _ mutate: (inout Journal) -> Void) {
        guard let i = journals.firstIndex(where: { $0.id == id }) else { return }
        var j = journals[i]
        mutate(&j)
        guard j != journals[i] else { return }
        j.updatedAt = Date()
        j.dirty = true
        journals[i] = j
        changed()
    }

    func deleteJournal(_ id: String) {
        updateJournal(id) { $0.deleted = true; $0.body = ""; $0.title = ""; $0.transcript = nil }
        // Items that came from this journal go too.
        for item in items where item.journalID == id && !item.deleted {
            updateItem(item.id) { $0.deleted = true }
        }
        if let path = journal(id)?.audioPath, let url = AudioRecorder.absoluteURL(forMediaRelativePath: path) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Bulk insert used by the one-time legacy import. Skips IDs already present.
    func importLegacy(_ incoming: [Journal]) -> Int {
        let existing = Set(journals.map(\.id))
        let fresh = incoming.filter { !existing.contains($0.id) }
        guard !fresh.isEmpty else { return 0 }
        journals.append(contentsOf: fresh)
        changed()
        return fresh.count
    }

    // MARK: - Spaces

    @discardableResult
    func addSpace(name: String, icon: String? = nil) -> Space {
        let now = Date()
        let s = Space(id: newID("space"), name: name, icon: icon ?? SpaceIcons.guess(for: name), summary: "",
                      sortOrder: (spaces.map(\.sortOrder).max() ?? 0) + 1,
                      createdAt: now, updatedAt: now, deleted: false, dirty: true)
        spaces.append(s)
        changed()
        return s
    }

    func updateSpace(_ id: String, _ mutate: (inout Space) -> Void) {
        guard let i = spaces.firstIndex(where: { $0.id == id }) else { return }
        var s = spaces[i]
        mutate(&s)
        guard s != spaces[i] else { return }
        s.updatedAt = Date()
        s.dirty = true
        spaces[i] = s
        changed()
    }

    /// Deleting a space keeps its journals (they become unsorted) and removes its items.
    func deleteSpace(_ id: String) {
        updateSpace(id) { $0.deleted = true }
        for j in journals where j.spaceID == id {
            updateJournal(j.id) { $0.spaceID = nil; $0.organized = false }
        }
        for item in items where item.spaceID == id && !item.deleted {
            updateItem(item.id) { $0.deleted = true }
        }
    }

    func moveSpace(from source: IndexSet, to destination: Int) {
        var ordered = visibleSpaces
        ordered.move(fromOffsets: source, toOffset: destination)
        for (index, s) in ordered.enumerated() where s.sortOrder != index {
            updateSpace(s.id) { $0.sortOrder = index }
        }
    }

    /// Finds a space by name (case-insensitive) or creates it.
    func spaceNamed(_ name: String) -> Space {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if let found = visibleSpaces.first(where: { $0.name.caseInsensitiveCompare(clean) == .orderedSame }) {
            return found
        }
        return addSpace(name: clean.isEmpty ? "Reflections" : String(clean.prefix(40)))
    }

    // MARK: - Items

    @discardableResult
    func addItem(spaceID: String, kind: ItemKind, text: String, journalID: String? = nil) -> SpaceItem? {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return nil }
        // Avoid duplicate items when a journal is organized twice.
        if items.contains(where: { $0.spaceID == spaceID && !$0.deleted && $0.kind == kind
            && $0.text.caseInsensitiveCompare(clean) == .orderedSame }) { return nil }
        let now = Date()
        let item = SpaceItem(id: newID("item"), spaceID: spaceID, journalID: journalID, kind: kind,
                             text: String(clean.prefix(500)), done: false, createdAt: now, updatedAt: now,
                             deleted: false, dirty: true)
        items.append(item)
        changed()
        return item
    }

    func updateItem(_ id: String, _ mutate: (inout SpaceItem) -> Void) {
        guard let i = items.firstIndex(where: { $0.id == id }) else { return }
        var item = items[i]
        mutate(&item)
        guard item != items[i] else { return }
        item.updatedAt = Date()
        item.dirty = true
        items[i] = item
        changed()
    }

    func clearDone(in spaceID: String) {
        for item in items where item.spaceID == spaceID && item.kind == .todo && item.done && !item.deleted {
            updateItem(item.id) { $0.deleted = true }
        }
    }

    // MARK: - Sync support

    var dirtyJournals: [Journal] { journals.filter { $0.dirty && $0.status == .ready } }
    var dirtySpaces: [Space] { spaces.filter(\.dirty) }
    var dirtyItems: [SpaceItem] { items.filter(\.dirty) }

    /// Clears dirty flags only for records that did not change while the push was in flight.
    func markPushed(journals pushedJ: [Journal], spaces pushedS: [Space], items pushedI: [SpaceItem]) {
        for p in pushedJ { if let i = journals.firstIndex(where: { $0.id == p.id }), journals[i].updatedAt == p.updatedAt { journals[i].dirty = false } }
        for p in pushedS { if let i = spaces.firstIndex(where: { $0.id == p.id }), spaces[i].updatedAt == p.updatedAt { spaces[i].dirty = false } }
        for p in pushedI { if let i = items.firstIndex(where: { $0.id == p.id }), items[i].updatedAt == p.updatedAt { items[i].dirty = false } }
        scheduleSave()
    }

    /// Marks everything dirty, e.g. after signing in to a new account.
    func markAllDirty() {
        for i in journals.indices { journals[i].dirty = true }
        for i in spaces.indices { spaces[i].dirty = true }
        for i in items.indices { items[i].dirty = true }
        scheduleSave()
    }

    /// Applies a record from the cloud when it is newer than the local copy.
    func applyRemote(journal r: Journal) {
        if let i = journals.firstIndex(where: { $0.id == r.id }) {
            let local = journals[i]
            guard r.updatedAt > local.updatedAt else { return }
            var merged = local
            merged.title = r.title; merged.body = r.body; merged.spaceID = r.spaceID
            merged.deleted = r.deleted; merged.updatedAt = r.updatedAt; merged.dirty = false
            if r.spaceID != nil { merged.organized = true }
            journals[i] = merged
        } else {
            journals.append(r)
        }
        scheduleSave()
    }

    func applyRemote(space r: Space) {
        if let i = spaces.firstIndex(where: { $0.id == r.id }) {
            guard r.updatedAt > spaces[i].updatedAt else { return }
            spaces[i] = r
        } else {
            // A cloud space with the same name as an untouched local default replaces it.
            if let dup = spaces.firstIndex(where: { !$0.deleted && $0.name.caseInsensitiveCompare(r.name) == .orderedSame && $0.id != r.id }) {
                let oldID = spaces[dup].id
                spaces.remove(at: dup)
                for i in journals.indices where journals[i].spaceID == oldID { journals[i].spaceID = r.id; journals[i].dirty = true; journals[i].updatedAt = Date() }
                for i in items.indices where items[i].spaceID == oldID { items[i].spaceID = r.id; items[i].dirty = true; items[i].updatedAt = Date() }
            }
            spaces.append(r)
        }
        scheduleSave()
    }

    func applyRemote(item r: SpaceItem) {
        if let i = items.firstIndex(where: { $0.id == r.id }) {
            guard r.updatedAt > items[i].updatedAt else { return }
            items[i] = r
        } else {
            items.append(r)
        }
        scheduleSave()
    }
}
