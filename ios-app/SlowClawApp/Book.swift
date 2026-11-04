import Foundation
import NaturalLanguage
import FoundationModels

struct BookNode: Codable, Identifiable, Hashable {
    var id: String
    var journalID: String?
    var text: String
    /// Unit-length sentence vector, stored as little-endian Float32 bytes. Never synced.
    var vectorData: Data
    var language: String
    var attachedTo: String?
    var position: Double
    var chapter: Int
    var chapterTitle: String
    var x: Double
    var y: Double
    var createdAt: Date
    var updatedAt: Date
    var deleted: Bool
    var dirty: Bool

    var vector: [Float] { BookVectors.decode(vectorData) }
}

/// A passage the book did not take (yet), with the reason. Retried as the book grows.
struct BookCandidate: Codable, Identifiable, Hashable {
    var id: String
    var journalID: String?
    var text: String
    var vectorData: Data
    var language: String
    var reason: String
    var createdAt: Date
    var attempts: Int
}

enum BookVectors {
    static func encode(_ v: [Float]) -> Data { v.withUnsafeBufferPointer { Data(buffer: $0) } }
    static func decode(_ d: Data) -> [Float] {
        var out = [Float](repeating: 0, count: d.count / MemoryLayout<Float>.size)
        _ = out.withUnsafeMutableBytes { d.copyBytes(to: $0) }
        return out
    }
}

/// On-device sentence vectors (NaturalLanguage). Nothing leaves the phone.
enum Embedder {
    nonisolated(unsafe) private static var cache: [String: NLEmbedding] = [:]
    private static let lock = NSLock()

    static func language(of text: String) -> NLLanguage {
        NLLanguageRecognizer.dominantLanguage(for: text) ?? .english
    }

    static func vector(for text: String) -> (vector: [Float], language: String)? {
        let lang = language(of: text)
        guard let embedding = embedding(for: lang) ?? embedding(for: .english),
              let raw = embedding.vector(for: text) else { return nil }
        let v = BookEngine.normalized(raw.map(Float.init))
        guard v.contains(where: { $0 != 0 }) else { return nil }
        return (v, embedding.language?.rawValue ?? lang.rawValue)
    }

    private static func embedding(for lang: NLLanguage) -> NLEmbedding? {
        lock.lock(); defer { lock.unlock() }
        if let e = cache[lang.rawValue] { return e }
        guard let e = NLEmbedding.sentenceEmbedding(for: lang) else { return nil }
        cache[lang.rawValue] = e
        return e
    }

    static var isAvailable: Bool { NLEmbedding.sentenceEmbedding(for: .english) != nil }
}

@Generable
struct BookPassages {
    @Guide(description: "Up to 3 passages worth keeping in a book about the author's life and ideas. Each is 2 to 4 sentences in the author's first-person voice and language. Empty when nothing is worth keeping.")
    var passages: [String]
}

@Generable
struct ChapterTitle {
    @Guide(description: "A short, evocative chapter title of 2 to 5 words, in the language of the passages")
    var title: String
}

@MainActor
final class BookStore: ObservableObject {
    static let shared = BookStore()

    @Published private(set) var nodes: [BookNode] = []
    @Published private(set) var waiting: [BookCandidate] = []
    @Published private(set) var lastEvent: String?

    /// Journals already read into the book (journal id → journal updatedAt at that time).
    private var processed: [String: Date] = [:]
    private var axes: [[Float]] = []
    private var projectedCount = 0
    private var titleCache: [String: String] = [:]
    private var saveTask: Task<Void, Never>?
    var onLocalChange: (@MainActor () -> Void)?

    private struct Snapshot: Codable {
        var version: Int
        var nodes: [BookNode]
        var waiting: [BookCandidate]
        var processed: [String: Date]
        var axes: [[Float]]
        var projectedCount: Int
        var titleCache: [String: String]
    }

    private static var fileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("SlowClaw", isDirectory: true).appendingPathComponent("book.json")
    }

    init() {
        let d = JSONDecoder(); d.dateDecodingStrategy = .secondsSince1970
        if let data = try? Data(contentsOf: Self.fileURL), let s = try? d.decode(Snapshot.self, from: data) {
            nodes = s.nodes; waiting = s.waiting; processed = s.processed
            axes = s.axes; projectedCount = s.projectedCount; titleCache = s.titleCache
        }
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            self?.saveNow()
        }
    }

    func saveNow() {
        let e = JSONEncoder(); e.dateEncodingStrategy = .secondsSince1970
        let snap = Snapshot(version: 1, nodes: nodes, waiting: waiting, processed: processed,
                            axes: axes, projectedCount: projectedCount, titleCache: titleCache)
        guard let data = try? e.encode(snap) else { return }
        try? FileManager.default.createDirectory(at: Self.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: Self.fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    private func changed() {
        scheduleSave()
        onLocalChange?()
    }

    // MARK: - Reading order

    /// Live passages in reading order.
    var path: [BookNode] {
        nodes.filter { !$0.deleted }.sorted { $0.position < $1.position }
    }

    struct Chapter: Identifiable {
        var id: Int
        var title: String
        var nodes: [BookNode]
    }

    var chapters: [Chapter] {
        var out: [Chapter] = []
        for n in path {
            if let last = out.last, last.id == n.chapter {
                out[out.count - 1].nodes.append(n)
            } else {
                out.append(Chapter(id: n.chapter, title: n.chapterTitle, nodes: [n]))
            }
        }
        return out
    }

    // MARK: - Feeding

    /// True when this journal still has to be read into the book.
    func needsReading(_ j: Journal) -> Bool {
        guard j.status == .ready, !j.deleted, processed[j.id] == nil else { return false }
        return BookEngine.wordCount(j.body) >= 15
    }

    /// Reads one journal: pulls out passages and runs each through the book's gate.
    func read(_ j: Journal) async {
        processed[j.id] = j.updatedAt
        defer { scheduleSave() }
        guard Embedder.isAvailable else { return }
        let passages = await Self.passages(from: j)
        var accepted = 0
        for text in passages {
            guard let e = Embedder.vector(for: text) else { continue }
            if consider(text: text, vector: e.vector, language: e.language, journalID: j.id, candidateID: nil) { accepted += 1 }
        }
        if accepted > 0 {
            retryWaiting()
            await refreshStructure()
            lastEvent = accepted == 1 ? "1 new passage joined your book." : "\(accepted) new passages joined your book."
            changed()
        }
    }

    /// Runs the gate. Accepted passages join the path; others go to the waiting room.
    @discardableResult
    private func consider(text: String, vector: [Float], language: String, journalID: String?, candidateID: String?) -> Bool {
        let live = path
        let points = live.map { BookPoint(id: $0.id, vector: $0.language == language ? $0.vector : [], text: $0.text, position: $0.position) }
        switch BookEngine.decide(vector: vector, text: text, path: points) {
        case let .accept(position, attachTo):
            insert(text: text, vector: vector, language: language, journalID: journalID, position: position, attachTo: attachTo)
            if let candidateID { waiting.removeAll { $0.id == candidateID } }
            return true
        case let .reject(reason):
            if let candidateID, let i = waiting.firstIndex(where: { $0.id == candidateID }) {
                waiting[i].reason = reason
                waiting[i].attempts += 1
            } else if !reason.hasPrefix("Too short") {
                waiting.append(BookCandidate(id: newID("cand"), journalID: journalID, text: text,
                                             vectorData: BookVectors.encode(vector), language: language,
                                             reason: reason, createdAt: Date(), attempts: 1))
                if waiting.count > 200 { waiting.removeFirst(waiting.count - 200) }
            }
            return false
        }
    }

    private func insert(text: String, vector: [Float], language: String, journalID: String?, position: Double, attachTo: String?) {
        let now = Date()
        // Start new passages next to the one they attached to; the map is redrawn in batches.
        let anchor = attachTo.flatMap { id in nodes.first { $0.id == id } }
        let jitter = { Double.random(in: -0.02...0.02) }
        nodes.append(BookNode(id: newID("node"), journalID: journalID, text: String(text.prefix(4000)),
                              vectorData: BookVectors.encode(vector), language: language, attachedTo: attachTo,
                              position: position, chapter: 0, chapterTitle: "",
                              x: min(0.95, max(0.05, (anchor?.x ?? 0.5) + jitter())),
                              y: min(0.95, max(0.05, (anchor?.y ?? 0.5) + jitter())),
                              createdAt: now, updatedAt: now, deleted: false, dirty: true))
    }

    /// Passages that did not fit before may attach now that the book has grown.
    private func retryWaiting() {
        var progress = true
        var rounds = 0
        while progress && rounds < 3 {
            progress = false
            rounds += 1
            for c in waiting.filter({ $0.attempts < 12 && !$0.reason.hasPrefix("Says nearly") }).prefix(30) {
                if consider(text: c.text, vector: BookVectors.decode(c.vectorData), language: c.language,
                            journalID: c.journalID, candidateID: c.id) { progress = true }
            }
        }
    }

    /// The user's choice wins: put a waiting passage into the book anyway.
    func addAnyway(_ id: String) async {
        guard let c = waiting.first(where: { $0.id == id }) else { return }
        let vector = BookVectors.decode(c.vectorData)
        let points = path.map { BookPoint(id: $0.id, vector: $0.vector, text: $0.text, position: $0.position) }
        let index = BookEngine.insertionIndex(vector: vector, path: points)
        let nearest = points.max { BookEngine.similarity(vector, $0.vector) < BookEngine.similarity(vector, $1.vector) }
        insert(text: c.text, vector: vector, language: c.language, journalID: c.journalID,
               position: BookEngine.position(at: index, in: points), attachTo: nearest?.id)
        waiting.removeAll { $0.id == id }
        await refreshStructure()
        changed()
    }

    func dismiss(_ id: String) {
        waiting.removeAll { $0.id == id }
        scheduleSave()
    }

    func remove(_ nodeID: String) async {
        guard let i = nodes.firstIndex(where: { $0.id == nodeID }) else { return }
        nodes[i].deleted = true
        nodes[i].text = ""
        nodes[i].updatedAt = Date()
        nodes[i].dirty = true
        await refreshStructure()
        changed()
    }

    /// Called when a journal is deleted: its passages leave the book too.
    func journalDeleted(_ journalID: String) {
        var touched = false
        for i in nodes.indices where nodes[i].journalID == journalID && !nodes[i].deleted {
            nodes[i].deleted = true; nodes[i].text = ""; nodes[i].updatedAt = Date(); nodes[i].dirty = true
            touched = true
        }
        waiting.removeAll { $0.journalID == journalID }
        if touched { changed() } else { scheduleSave() }
    }

    /// Starts the book over from all journals (keeps nothing).
    func rebuild() {
        let now = Date()
        for i in nodes.indices where !nodes[i].deleted {
            nodes[i].deleted = true; nodes[i].text = ""; nodes[i].updatedAt = now; nodes[i].dirty = true
        }
        waiting = []; processed = [:]; axes = []; projectedCount = 0; titleCache = [:]
        changed()
    }

    // MARK: - Chapters and map

    private func refreshStructure() async {
        var live = path
        guard !live.isEmpty else { return }
        // Keep positions well apart after many midpoint insertions.
        if zip(live, live.dropFirst()).contains(where: { $1.position - $0.position < 1e-6 }) {
            for (i, n) in live.enumerated() { update(n.id) { $0.position = Double(i + 1) } }
            live = path
        }

        let points = live.map { BookPoint(id: $0.id, vector: $0.vector, text: $0.text, position: $0.position) }
        let numbers = BookEngine.chapters(points)
        var groups: [Int: [BookNode]] = [:]
        for (n, c) in zip(live, numbers) { groups[c, default: []].append(n) }
        for c in groups.keys.sorted() {
            let members = groups[c] ?? []
            let key = members.map(\.id).joined(separator: ",")
            let title: String
            if let cached = titleCache[key] { title = cached } else {
                title = await Self.chapterTitle(members.map(\.text))
                titleCache[key] = title
            }
            for n in members { update(n.id) { $0.chapter = c; $0.chapterTitle = title } }
        }
        if titleCache.count > 400 { titleCache = [:] }

        // Redraw the map while the book is small, then every 10% of growth.
        if live.count < 20 || Double(live.count) >= Double(projectedCount) * 1.1 {
            let (xy, newAxes) = BookEngine.project(live.map(\.vector), previousAxes: axes)
            axes = newAxes
            projectedCount = live.count
            for (n, p) in zip(live, xy) {
                update(n.id) { $0.x = p.0; $0.y = p.1 }
            }
        }
    }

    /// Mutates a node; marks it for sync only when something visible changed.
    private func update(_ id: String, _ mutate: (inout BookNode) -> Void) {
        guard let i = nodes.firstIndex(where: { $0.id == id }) else { return }
        var n = nodes[i]
        mutate(&n)
        let moved = abs(n.x - nodes[i].x) > 0.01 || abs(n.y - nodes[i].y) > 0.01
        let visible = moved || n.chapter != nodes[i].chapter || n.chapterTitle != nodes[i].chapterTitle
            || n.position != nodes[i].position
        guard visible || n != nodes[i] else { return }
        if visible { n.updatedAt = Date(); n.dirty = true }
        nodes[i] = n
    }

    // MARK: - On-device AI

    static func passages(from j: Journal) async -> [String] {
        let body = String(j.body.prefix(5000))
        if OnDeviceAI.isAvailable {
            do {
                let session = LanguageModelSession(instructions: """
                You help someone grow a living book from their journal. From the entry, choose up to 3 \
                passages worth keeping: insights, reflections, decisions, vivid moments. Lightly edit each \
                into 2 to 4 clear sentences in the author's first-person voice and language. Do not add \
                facts. Skip to-dos, logistics and small talk. Return an empty list when nothing is worth keeping.
                """)
                let r = try await session.respond(to: "Journal entry:\n" + body, generating: BookPassages.self).content
                let clean = r.passages.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { BookEngine.wordCount($0) >= 12 }
                return Array(clean.prefix(3))
            } catch {
                // Fall through to paragraphs, e.g. when a guardrail declines.
            }
        }
        return fallbackPassages(body)
    }

    /// Without Apple Intelligence: the entry's own substantial paragraphs.
    static func fallbackPassages(_ body: String) -> [String] {
        var out: [String] = []
        for para in body.components(separatedBy: "\n\n") {
            let p = para.trimmingCharacters(in: .whitespacesAndNewlines)
            let words = BookEngine.wordCount(p)
            guard words >= 20 else { continue }
            if words <= 120 { out.append(p) } else {
                // Split long paragraphs into ~4-sentence passages.
                var chunk = "", count = 0
                p.enumerateSubstrings(in: p.startIndex..., options: .bySentences) { s, _, _, _ in
                    guard let s else { return }
                    chunk += s; count += 1
                    if count == 4 { out.append(chunk.trimmingCharacters(in: .whitespaces)); chunk = ""; count = 0 }
                }
                if BookEngine.wordCount(chunk) >= 20 { out.append(chunk.trimmingCharacters(in: .whitespaces)) }
            }
            if out.count >= 3 { break }
        }
        return Array(out.prefix(3))
    }

    static func chapterTitle(_ texts: [String]) async -> String {
        if OnDeviceAI.isAvailable {
            var context = ""
            for t in texts where context.count < 2500 { context += "- " + String(t.prefix(400)) + "\n" }
            if let r = try? await LanguageModelSession(instructions: "You title chapters of a personal book.")
                .respond(to: "Passages:\n" + context, generating: ChapterTitle.self).content {
                let t = r.title.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"“”")))
                if !t.isEmpty && t.count <= 60 { return t }
            }
        }
        return BookEngine.keywordTitle(texts)
    }

    // MARK: - Sync

    var dirtyNodes: [BookNode] { nodes.filter(\.dirty) }

    func markPushed(_ pushed: [BookNode]) {
        for p in pushed {
            if let i = nodes.firstIndex(where: { $0.id == p.id }), nodes[i].updatedAt == p.updatedAt { nodes[i].dirty = false }
        }
        scheduleSave()
    }

    func markAllDirty() {
        for i in nodes.indices { nodes[i].dirty = true }
        scheduleSave()
    }

    static func row(from n: BookNode, user: String?) -> [String: Any] {
        var r: [String: Any] = ["id": n.id, "journal_id": n.journalID.map { $0 as Any } ?? NSNull(), "text": n.text,
                                "position": n.position, "chapter": n.chapter, "chapter_title": n.chapterTitle,
                                "x": n.x, "y": n.y, "created_at": CloudDates.format(n.createdAt),
                                "updated_at": CloudDates.format(n.updatedAt), "deleted": n.deleted]
        if let user { r["user_id"] = user }
        return r
    }

    /// Restores passages from the cloud this phone does not have (e.g. after reinstalling).
    func applyRemote(rows: [[String: Any]]) {
        var added = false
        for r in rows {
            guard let id = r["id"] as? String, let updated = CloudDates.parse(r["updated_at"] as? String) else { continue }
            if let i = nodes.firstIndex(where: { $0.id == id }) {
                guard updated > nodes[i].updatedAt else { continue }
                if r["deleted"] as? Bool == true { nodes[i].deleted = true; nodes[i].text = "" }
                nodes[i].updatedAt = updated
                nodes[i].dirty = false
                continue
            }
            guard r["deleted"] as? Bool != true, let text = r["text"] as? String,
                  let embedded = Embedder.vector(for: text) else { continue }
            let vector = embedded.vector, lang = embedded.language
            let journalID = r["journal_id"] as? String
            if let journalID { processed[journalID] = processed[journalID] ?? updated }
            nodes.append(BookNode(id: id, journalID: journalID, text: text, vectorData: BookVectors.encode(vector),
                                  language: lang, attachedTo: nil,
                                  position: (r["position"] as? NSNumber)?.doubleValue ?? 0,
                                  chapter: (r["chapter"] as? NSNumber)?.intValue ?? 0,
                                  chapterTitle: r["chapter_title"] as? String ?? "",
                                  x: (r["x"] as? NSNumber)?.doubleValue ?? 0.5, y: (r["y"] as? NSNumber)?.doubleValue ?? 0.5,
                                  createdAt: CloudDates.parse(r["created_at"] as? String) ?? updated,
                                  updatedAt: updated, deleted: false, dirty: false))
            added = true
        }
        if added || !rows.isEmpty { scheduleSave() }
    }
}
