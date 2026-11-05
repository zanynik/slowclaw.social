import Foundation
import FoundationModels

enum BookNodeKind: String, Codable {
    /// The author's words (cleaned, later condensed on the phone).
    case passage
    /// Kept for rows written by 0.5 (connecting lines); no longer created.
    case bridge
    /// Kept for rows written by 0.5 (chapter openings); no longer created.
    case intro
}

struct BookNode: Codable, Identifiable, Hashable {
    var id: String
    var kind: BookNodeKind
    var journalID: String?
    /// What the book shows: the cleaned excerpt, replaced by a condensed version once polished.
    var text: String
    /// The cleaned segment the passage came from (input for condensing, and the voice check).
    var source: String?
    var polished: Bool
    /// Unit-length MiniLM vector of the excerpt, little-endian Float32. Never synced.
    var vectorData: Data
    /// Which model made the vector ("minilm"); others are remade.
    var language: String
    /// Journal date as yyyymmdd and order within the journal, for reading order.
    var day: Int
    var seq: Int
    var key: String?
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

    enum CodingKeys: String, CodingKey {
        case id, kind, journalID, text, source, polished, vectorData, language, day, seq, key, position, chapter, chapterTitle, x, y,
             createdAt, updatedAt, deleted, dirty
    }

    init(id: String, kind: BookNodeKind = .passage, journalID: String?, text: String, source: String?, vectorData: Data,
         language: String, day: Int, seq: Int, position: Double, createdAt: Date) {
        self.id = id; self.kind = kind; self.journalID = journalID; self.text = text; self.source = source; self.polished = false
        self.vectorData = vectorData; self.language = language; self.day = day; self.seq = seq; self.key = nil
        self.position = position; self.chapter = 0; self.chapterTitle = ""; self.x = 0.5; self.y = 0.5
        self.createdAt = createdAt; self.updatedAt = createdAt; self.deleted = false; self.dirty = true
    }

    /// Reads books saved by earlier versions too, so their rows can be retired cleanly.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        kind = try c.decodeIfPresent(BookNodeKind.self, forKey: .kind) ?? .passage
        journalID = try c.decodeIfPresent(String.self, forKey: .journalID)
        text = try c.decode(String.self, forKey: .text)
        source = try c.decodeIfPresent(String.self, forKey: .source)
        polished = try c.decodeIfPresent(Bool.self, forKey: .polished) ?? false
        vectorData = try c.decodeIfPresent(Data.self, forKey: .vectorData) ?? Data()
        language = try c.decodeIfPresent(String.self, forKey: .language) ?? ""
        day = try c.decodeIfPresent(Int.self, forKey: .day) ?? 0
        seq = try c.decodeIfPresent(Int.self, forKey: .seq) ?? 0
        key = try c.decodeIfPresent(String.self, forKey: .key)
        position = try c.decode(Double.self, forKey: .position)
        chapter = try c.decodeIfPresent(Int.self, forKey: .chapter) ?? 0
        chapterTitle = try c.decodeIfPresent(String.self, forKey: .chapterTitle) ?? ""
        x = try c.decodeIfPresent(Double.self, forKey: .x) ?? 0.5
        y = try c.decodeIfPresent(Double.self, forKey: .y) ?? 0.5
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        updatedAt = try c.decode(Date.self, forKey: .updatedAt)
        deleted = try c.decodeIfPresent(Bool.self, forKey: .deleted) ?? false
        dirty = try c.decodeIfPresent(Bool.self, forKey: .dirty) ?? false
    }
}

enum BookVectors {
    static func encode(_ v: [Float]) -> Data { v.withUnsafeBufferPointer { Data(buffer: $0) } }
    static func decode(_ d: Data) -> [Float] {
        var out = [Float](repeating: 0, count: d.count / MemoryLayout<Float>.size)
        _ = out.withUnsafeMutableBytes { d.copyBytes(to: $0) }
        return out
    }
}

/// On-device text vectors: the bundled MiniLM (the same model the book and Discover were tuned with).
enum Embedder {
    static let tag = "minilm"
    static var isAvailable: Bool { MiniLM.shared != nil }

    static func vector(for text: String) -> [Float]? { MiniLM.shared?.embed(text) }

    /// Embeds many texts off the main thread.
    static func vectors(for texts: [String]) async -> [[Float]]? {
        await Task.detached(priority: .utility) { () -> [[Float]]? in
            guard let m = MiniLM.shared else { return nil }
            return texts.map { m.embed($0) }
        }.value
    }
}

@Generable
struct ChapterTitle {
    @Guide(description: "A short, evocative chapter title of 2 to 5 words, in the language of the passages")
    var title: String
}

@Generable
struct CondensedPassage {
    @Guide(description: "The passage: 2 to 4 sentences in the speaker's first-person voice")
    var text: String
}

@MainActor
final class BookStore: ObservableObject {
    static let shared = BookStore()
    /// 3 = MiniLM, segment passages, whole-book layout, background condensing.
    static let bookVersion = 3
    static let looseEndsChapter = 999

    @Published private(set) var nodes: [BookNode] = []
    @Published private(set) var lastEvent: String?
    @Published private(set) var progress: (done: Int, total: Int)?
    /// Layout or condensing still to do (done when the phone is idle).
    @Published private(set) var needsPolish = false
    private(set) var layoutDirty = false

    private var processed: [String: Date] = [:]
    private var axes: [[Float]] = []
    private var projectedCount = 0
    private var titleCache: [String: String] = [:]
    private var version = BookStore.bookVersion
    private var saveTask: Task<Void, Never>?
    var onLocalChange: (@MainActor () -> Void)?

    private struct Snapshot: Codable {
        var version: Int
        var nodes: [BookNode]
        var processed: [String: Date]
        var axes: [[Float]]
        var projectedCount: Int
        var titleCache: [String: String]
        var needsPolish: Bool?
        var layoutDirty: Bool?
    }

    private static var fileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("SlowClaw", isDirectory: true).appendingPathComponent("book.json")
    }

    init() {
        let d = JSONDecoder(); d.dateDecodingStrategy = .secondsSince1970
        if let data = try? Data(contentsOf: Self.fileURL), let s = try? d.decode(Snapshot.self, from: data) {
            nodes = s.nodes; processed = s.processed; axes = s.axes; projectedCount = s.projectedCount
            titleCache = s.titleCache; needsPolish = s.needsPolish ?? false; layoutDirty = s.layoutDirty ?? false
            version = s.version
        } else if FileManager.default.fileExists(atPath: Self.fileURL.path) {
            version = 0   // unreadable older format: start over
        }
        if version < Self.bookVersion { rebuild() }
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
        let snap = Snapshot(version: version, nodes: nodes, processed: processed, axes: axes, projectedCount: projectedCount,
                            titleCache: titleCache, needsPolish: needsPolish, layoutDirty: layoutDirty)
        guard let data = try? e.encode(snap) else { return }
        try? FileManager.default.createDirectory(at: Self.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: Self.fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    private func changed() {
        scheduleSave()
        onLocalChange?()
    }

    // MARK: - Reading order

    var path: [BookNode] { nodes.filter { !$0.deleted }.sorted { $0.position < $1.position } }
    var passages: [BookNode] { path.filter { $0.kind == .passage } }

    struct Chapter: Identifiable {
        var id: Int
        var title: String
        var nodes: [BookNode]
        var passageCount: Int { nodes.filter { $0.kind == .passage }.count }
        var isLooseEnds: Bool { id == BookStore.looseEndsChapter }
    }

    var chapters: [Chapter] {
        var out: [Chapter] = []
        for n in path {
            if let last = out.last, last.id == n.chapter { out[out.count - 1].nodes.append(n) }
            else { out.append(Chapter(id: n.chapter, title: n.chapterTitle, nodes: [n])) }
        }
        return out
    }

    // MARK: - Feeding

    func needsReading(_ j: Journal) -> Bool {
        guard j.status == .ready, !j.deleted, processed[j.id] == nil else { return false }
        return BookEngine.wordCount(j.body) >= 15
    }

    static func dayNumber(_ date: Date) -> Int {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return (c.year ?? 2000) * 10000 + (c.month ?? 1) * 100 + (c.day ?? 1)
    }

    /// Reads one journal into the book: no language model involved, just MiniLM vectors.
    func read(_ j: Journal, remaining: Int = 0) async {
        processed[j.id] = j.updatedAt
        defer { scheduleSave() }
        guard Embedder.isAvailable else { return }
        let others = processed.keys.filter { $0 != j.id }.compactMap { Store.shared.journal($0) }.filter { !$0.deleted }
        if others.contains(where: { BookOrganizer.isRepeatJournal(j.body, of: $0.body) }) { return }

        let sentences = BookOrganizer.bookSentences(j.body)
        guard sentences.count >= 3, let vectors = await Embedder.vectors(for: sentences) else { return }
        let found = BookOrganizer.passages(sentences: sentences, vectors: vectors, journalLength: j.body.count)
        guard !found.isEmpty, let passageVectors = await Embedder.vectors(for: found.map(\.text)) else { return }

        let day = Self.dayNumber(j.createdAt)
        let existing = passages
        var added = 0
        for (p, v) in zip(found, passageVectors) {
            let repeats = existing.contains { BookOrganizer.isRepeatPassage(p.text, vector: v, of: $0.text, otherVector: $0.vector) }
                || nodes.suffix(added).contains { BookOrganizer.isRepeatPassage(p.text, vector: v, of: $0.text, otherVector: $0.vector) }
            if repeats { continue }
            let context = String(sentences[p.range].joined(separator: " ").prefix(1500))
            nodes.append(BookNode(id: newID("node"), journalID: j.id, text: String(p.text.prefix(4000)), source: context,
                                  vectorData: BookVectors.encode(v), language: Embedder.tag, day: day, seq: p.start,
                                  position: Double(nodes.count + 1) * 10, createdAt: Date()))
            added += 1
        }
        if added > 0 {
            layoutDirty = true
            needsPolish = true
            lastEvent = added == 1 ? "1 passage joined your book." : "\(added) passages joined your book."
            // While many journals are being read, lay the book out every 8 journals.
            if remaining == 0 || processed.count % 8 == 0 { await layout() }
            changed()
        }
    }

    func reread(_ journalID: String) {
        processed[journalID] = nil
        scheduleSave()
    }

    func remove(_ nodeID: String) {
        guard let i = nodes.firstIndex(where: { $0.id == nodeID }) else { return }
        retire(i)
        layoutDirty = true
        Task { await layout(); changed() }
    }

    private func retire(_ i: Int) {
        nodes[i].deleted = true; nodes[i].text = ""; nodes[i].source = nil; nodes[i].updatedAt = Date(); nodes[i].dirty = true
    }

    func journalDeleted(_ journalID: String) {
        var touched = false
        for i in nodes.indices where nodes[i].journalID == journalID && !nodes[i].deleted { retire(i); touched = true }
        if touched { layoutDirty = true; Task { await layout(); changed() } } else { scheduleSave() }
    }

    /// Starts the book over from all journals.
    func rebuild() {
        for i in nodes.indices where !nodes[i].deleted { retire(i) }
        processed = [:]; axes = []; projectedCount = 0; titleCache = [:]
        needsPolish = false; layoutDirty = false
        version = Self.bookVersion
        changed()
    }

    // MARK: - Layout

    /// Chapters, order, positions and the map, for the whole book. Heavy maths runs off the main thread.
    func layout() async {
        guard layoutDirty else { return }
        layoutDirty = false
        // Vectors from another model are remade so everything is comparable.
        for i in nodes.indices where nodes[i].kind == .passage && !nodes[i].deleted && nodes[i].language != Embedder.tag {
            if let v = Embedder.vector(for: nodes[i].source ?? nodes[i].text) {
                nodes[i].vectorData = BookVectors.encode(v); nodes[i].language = Embedder.tag
            }
        }
        // Lines from 0.5 are retired.
        for i in nodes.indices where nodes[i].kind != .passage && !nodes[i].deleted { retire(i) }

        let live = nodes.filter { !$0.deleted && $0.kind == .passage }
        guard !live.isEmpty else { return }
        let items = live.map { OrgPassage(vector: $0.vector, day: $0.day, journal: $0.journalID ?? $0.id, seq: $0.seq) }
        let previousAxes = axes
        let (chapters, loners, xy, newAxes) = await Task.detached(priority: .utility) { () -> ([[Int]], Set<Int>, [(Double, Double)], [[Float]]) in
            let lonely = BookOrganizer.loners(items.map(\.vector))
            let keptIndices = items.indices.filter { !lonely.contains($0) }
            let kept = keptIndices.map { items[$0] }
            let chapters = BookOrganizer.organize(kept).map { $0.map { keptIndices[$0] } }
            return (chapters, lonely, [(Double, Double)](), previousAxes)
        }.value

        let keyphrases = BookOrganizer.keyphrases(groups: chapters.map { $0.map { live[$0].source ?? live[$0].text } })
        var position = 0.0
        for (c, members) in chapters.enumerated() {
            // Named after the phrases the chapter keeps returning to: the author's own words, instantly.
            let title = Self.labelTitle(keyphrases[c], fallback: members.map { live[$0].text })
            for m in members {
                position += 10
                update(live[m].id) { $0.chapter = c; $0.chapterTitle = title; $0.position = position }
            }
        }
        for m in loners.sorted(by: { live[$0].day < live[$1].day }) {
            position += 10
            update(live[m].id) { $0.chapter = Self.looseEndsChapter; $0.chapterTitle = "Loose ends"; $0.position = position }
        }
        axes = newAxes
        projectedCount = live.count
        _ = xy
        needsPolish = true
        scheduleSave()
    }

    static func labelTitle(_ phrases: [String], fallback: [String]) -> String {
        let picked = phrases.prefix(2).map { $0.split(separator: " ").map { $0.prefix(1).uppercased() + $0.dropFirst() }.joined(separator: " ") }
        return picked.isEmpty ? BookEngine.keywordTitle(fallback) : picked.joined(separator: " & ")
    }

    /// A cached title still fits when the chapter keeps most of the same passages.
    static func reuseTitle(_ ids: Set<String>, _ cache: [String: String]) -> String? {
        cache.first { key, _ in
            let old = Set(key.split(separator: ",").map(String.init))
            let union = old.union(ids).count
            return union > 0 && Double(old.intersection(ids).count) / Double(union) >= 0.6
        }?.value
    }

    /// Titles and condensed passages, written with Apple Intelligence when the phone is idle.
    /// Stops early when other work arrives; picks up where it left off next time.
    func polish(shouldStop: () -> Bool = { false }) async {
        if layoutDirty { await layout() }
        guard needsPolish else { return }
        defer { scheduleSave() }
        guard OnDeviceAI.isAvailable else { needsPolish = false; return }

        let todo = passages.filter { !$0.polished }
        progress = todo.isEmpty ? nil : (0, todo.count)
        for (i, n) in todo.enumerated() {
            if shouldStop() { progress = nil; return }
            let source = n.source ?? n.text
            if let condensed = await Self.condense(source),
               BookOrganizer.voiceKept(edited: condensed, source: source) >= 0.6 {
                update(n.id) { $0.text = condensed; $0.polished = true }
            } else {
                update(n.id) { $0.polished = true }
            }
            progress = (i + 1, todo.count)
            if (i + 1) % 10 == 0 { changed() }
        }
        progress = nil
        if titleCache.count > 500 { titleCache = [:] }
        needsPolish = false
        changed()
    }

    private func update(_ id: String, _ mutate: (inout BookNode) -> Void) {
        guard let i = nodes.firstIndex(where: { $0.id == id }) else { return }
        var n = nodes[i]
        mutate(&n)
        let moved = abs(n.x - nodes[i].x) > 0.01 || abs(n.y - nodes[i].y) > 0.01
        let visible = moved || n.chapter != nodes[i].chapter || n.chapterTitle != nodes[i].chapterTitle
            || n.position != nodes[i].position || n.text != nodes[i].text
        guard visible || n != nodes[i] else { return }
        if visible { n.updatedAt = Date(); n.dirty = true }
        nodes[i] = n
    }

    // MARK: - On-device AI (polish only)

    /// Turns a spoken segment into a clean passage in the speaker's voice. Small input, one call.
    static func condense(_ source: String) async -> String? {
        let r = try? await LanguageModelSession(instructions: """
        You edit excerpts from someone's spoken journal into clear passages for a book of their own \
        thinking. Write 2 to 4 sentences in their first-person voice. Keep their own words, names and \
        specific details; remove filler, false starts and repetition. Do not add conclusions, advice or \
        feelings they did not say, and do not begin with "I realized".
        """).respond(to: "Excerpt:\n" + source, generating: CondensedPassage.self).content
        guard let t = r?.text.trimmingCharacters(in: .whitespacesAndNewlines), BookEngine.wordCount(t) >= 12,
              BookEngine.wordCount(t) <= 110 else { return nil }
        return t
    }

    static func chapterTitle(_ texts: [String]) async -> String {
        if OnDeviceAI.isAvailable {
            var context = ""
            for t in texts where context.count < 2500 { context += "- " + String(t.prefix(300)) + "\n" }
            if let r = try? await LanguageModelSession(instructions: "You title chapters of a personal book. Name the shared subject plainly.")
                .respond(to: "Passages:\n" + context, generating: ChapterTitle.self).content {
                let t = r.title.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"“”")))
                if !t.isEmpty && t.count <= 60 { return t }
            }
        }
        return BookEngine.keywordTitle(texts)
    }

    // MARK: - Themes for Discover

    struct Theme {
        var title: String
        var vectors: [[Float]]
        var texts: [String]
    }

    /// The book's chapters as themes (passage vectors and the text they came from).
    var themes: [Theme] {
        chapters.filter { !$0.isLooseEnds }.map { c in
            let ps = c.nodes.filter { $0.kind == .passage }
            return Theme(title: c.title, vectors: ps.map(\.vector), texts: ps.map { $0.source ?? $0.text })
        }.filter { !$0.vectors.isEmpty }
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
        var r: [String: Any] = ["id": n.id, "kind": n.kind.rawValue, "journal_id": n.journalID.map { $0 as Any } ?? NSNull(),
                                "text": n.text, "position": n.position, "chapter": n.chapter, "chapter_title": n.chapterTitle,
                                "x": n.x, "y": n.y, "created_at": CloudDates.format(n.createdAt),
                                "updated_at": CloudDates.format(n.updatedAt), "deleted": n.deleted]
        if let user { r["user_id"] = user }
        return r
    }

    /// Restores a book from the cloud this phone does not have (e.g. after reinstalling).
    func applyRemote(rows: [[String: Any]]) {
        for r in rows {
            guard let id = r["id"] as? String, let updated = CloudDates.parse(r["updated_at"] as? String) else { continue }
            if let i = nodes.firstIndex(where: { $0.id == id }) {
                guard updated > nodes[i].updatedAt else { continue }
                if r["deleted"] as? Bool == true { nodes[i].deleted = true; nodes[i].text = "" }
                nodes[i].updatedAt = updated
                nodes[i].dirty = false
                continue
            }
            guard r["deleted"] as? Bool != true, (r["kind"] as? String ?? "passage") == "passage",
                  let text = r["text"] as? String, !text.isEmpty, let v = Embedder.vector(for: text) else { continue }
            let journalID = r["journal_id"] as? String
            if let journalID { processed[journalID] = processed[journalID] ?? updated }
            let created = CloudDates.parse(r["created_at"] as? String) ?? updated
            var node = BookNode(id: id, journalID: journalID, text: text, source: nil, vectorData: BookVectors.encode(v),
                                language: Embedder.tag, day: Self.dayNumber(created), seq: 0,
                                position: (r["position"] as? NSNumber)?.doubleValue ?? 0, createdAt: created)
            node.updatedAt = updated; node.dirty = false; node.polished = true
            node.chapter = (r["chapter"] as? NSNumber)?.intValue ?? 0
            node.chapterTitle = r["chapter_title"] as? String ?? ""
            node.x = (r["x"] as? NSNumber)?.doubleValue ?? 0.5; node.y = (r["y"] as? NSNumber)?.doubleValue ?? 0.5
            nodes.append(node)
        }
        if !rows.isEmpty { scheduleSave() }
    }
}
