import Foundation
import NaturalLanguage
import FoundationModels

enum BookNodeKind: String, Codable {
    /// The author's own words, lightly edited.
    case passage
    /// A short connecting line written on the phone where the thread jumps.
    case bridge
    /// One or two lines written on the phone that open a chapter.
    case intro
}

struct BookNode: Codable, Identifiable, Hashable {
    var id: String
    var kind: BookNodeKind
    var journalID: String?
    var text: String
    /// Unit-length vector (passages only), little-endian Float32 bytes. Never synced.
    var vectorData: Data
    /// Which embedding model made the vector, e.g. "ctx-en" or "sent-en".
    var language: String
    /// Journal date as yyyymmdd and order within the journal, for reading order.
    var day: Int
    var seq: Int
    /// For bridges and intros: what they were written for, so they are rewritten only when that changes.
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
        case id, kind, journalID, text, vectorData, language, day, seq, key, position, chapter, chapterTitle, x, y, createdAt, updatedAt, deleted, dirty
    }

    init(id: String, kind: BookNodeKind, journalID: String?, text: String, vectorData: Data, language: String,
         day: Int, seq: Int, key: String?, position: Double, chapter: Int, chapterTitle: String,
         x: Double, y: Double, createdAt: Date, updatedAt: Date, deleted: Bool, dirty: Bool) {
        self.id = id; self.kind = kind; self.journalID = journalID; self.text = text; self.vectorData = vectorData
        self.language = language; self.day = day; self.seq = seq; self.key = key; self.position = position
        self.chapter = chapter; self.chapterTitle = chapterTitle; self.x = x; self.y = y
        self.createdAt = createdAt; self.updatedAt = updatedAt; self.deleted = deleted; self.dirty = dirty
    }

    /// Reads books saved by 0.4 too (no kind/day/seq/key), so their rows can be retired cleanly.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        kind = try c.decodeIfPresent(BookNodeKind.self, forKey: .kind) ?? .passage
        journalID = try c.decodeIfPresent(String.self, forKey: .journalID)
        text = try c.decode(String.self, forKey: .text)
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

/// A passage the book did not take yet, with the reason. Retried as the book grows.
struct BookCandidate: Codable, Identifiable, Hashable {
    var id: String
    var journalID: String?
    var text: String
    var vectorData: Data
    var language: String
    var day: Int
    var seq: Int
    var reason: String
    var createdAt: Date
    var attempts: Int

    enum CodingKeys: String, CodingKey { case id, journalID, text, vectorData, language, day, seq, reason, createdAt, attempts }

    init(id: String, journalID: String?, text: String, vectorData: Data, language: String, day: Int, seq: Int,
         reason: String, createdAt: Date, attempts: Int) {
        self.id = id; self.journalID = journalID; self.text = text; self.vectorData = vectorData; self.language = language
        self.day = day; self.seq = seq; self.reason = reason; self.createdAt = createdAt; self.attempts = attempts
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        journalID = try c.decodeIfPresent(String.self, forKey: .journalID)
        text = try c.decode(String.self, forKey: .text)
        vectorData = try c.decodeIfPresent(Data.self, forKey: .vectorData) ?? Data()
        language = try c.decodeIfPresent(String.self, forKey: .language) ?? ""
        day = try c.decodeIfPresent(Int.self, forKey: .day) ?? 0
        seq = try c.decodeIfPresent(Int.self, forKey: .seq) ?? 0
        reason = try c.decodeIfPresent(String.self, forKey: .reason) ?? ""
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        attempts = try c.decodeIfPresent(Int.self, forKey: .attempts) ?? 0
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

/// On-device text vectors. Prefers Apple's contextual (transformer) embedding, averaged over
/// tokens; falls back to the older sentence embedding while its model downloads.
enum Embedder {
    nonisolated(unsafe) private static var contextual: [String: NLContextualEmbedding] = [:]
    nonisolated(unsafe) private static var sentence: [String: NLEmbedding] = [:]
    private static let lock = NSLock()

    static func language(of text: String) -> NLLanguage {
        NLLanguageRecognizer.dominantLanguage(for: text) ?? .english
    }

    /// The tag a vector made now would carry; vectors with another tag get remade.
    static func tag(for text: String) -> String {
        let lang = language(of: text)
        return contextualModel(for: lang) != nil ? "ctx-" + lang.rawValue : "sent-" + lang.rawValue
    }

    static func vector(for text: String) -> (vector: [Float], language: String)? {
        let lang = language(of: text)
        if let model = contextualModel(for: lang), let v = meanPooled(model, text: text, language: lang) {
            return (v, "ctx-" + lang.rawValue)
        }
        guard let e = sentenceModel(for: lang) ?? sentenceModel(for: .english),
              let raw = e.vector(for: text) else { return nil }
        let v = BookEngine.normalized(raw.map(Float.init))
        guard v.contains(where: { $0 != 0 }) else { return nil }
        return (v, "sent-" + (e.language ?? lang).rawValue)
    }

    private static func meanPooled(_ model: NLContextualEmbedding, text: String, language: NLLanguage) -> [Float]? {
        guard let result = try? model.embeddingResult(for: text, language: language) else { return nil }
        var sum = [Double](repeating: 0, count: model.dimension)
        var count = 0
        result.enumerateTokenVectors(in: text.startIndex..<text.endIndex) { vector, _ in
            for i in 0..<min(vector.count, sum.count) { sum[i] += vector[i] }
            count += 1
            return true
        }
        guard count > 0 else { return nil }
        let v = BookEngine.normalized(sum.map { Float($0 / Double(count)) })
        return v.contains(where: { $0 != 0 }) ? v : nil
    }

    private static func contextualModel(for lang: NLLanguage) -> NLContextualEmbedding? {
        lock.lock(); defer { lock.unlock() }
        if let m = contextual[lang.rawValue] { return m }
        guard let m = NLContextualEmbedding(language: lang), m.hasAvailableAssets, (try? m.load()) != nil else { return nil }
        contextual[lang.rawValue] = m
        return m
    }

    private static func sentenceModel(for lang: NLLanguage) -> NLEmbedding? {
        lock.lock(); defer { lock.unlock() }
        if let e = sentence[lang.rawValue] { return e }
        guard let e = NLEmbedding.sentenceEmbedding(for: lang) else { return nil }
        sentence[lang.rawValue] = e
        return e
    }

    /// Asks iOS to download the contextual model (a one-off, in the background).
    static func prepare(for languages: [NLLanguage] = [.english]) async {
        for lang in languages {
            guard let m = NLContextualEmbedding(language: lang), !m.hasAvailableAssets else { continue }
            _ = try? await m.requestAssets()
        }
    }

    static var isAvailable: Bool { NLEmbedding.sentenceEmbedding(for: .english) != nil || NLContextualEmbedding(language: .english) != nil }
}

@Generable
struct BookExcerpts {
    @Guide(description: "Passages copied from the entry in the author's own words: each 2 to 5 consecutive sentences. Empty when nothing is worth keeping.")
    var excerpts: [String]
}

@Generable
struct ChapterTitle {
    @Guide(description: "A short, evocative chapter title of 2 to 5 words, in the language of the passages")
    var title: String
}

@Generable
struct BookLine {
    @Guide(description: "The line, in the author's first-person voice")
    var text: String
}

@MainActor
final class BookStore: ObservableObject {
    static let shared = BookStore()
    /// 2 = own-voice passages, whole-book organisation, bridges.
    static let bookVersion = 2

    @Published private(set) var nodes: [BookNode] = []
    @Published private(set) var waiting: [BookCandidate] = []
    @Published private(set) var lastEvent: String?
    /// Titles, chapter openings and connecting lines still to be written (done when idle).
    @Published private(set) var needsPolish = false

    private var processed: [String: Date] = [:]
    private var axes: [[Float]] = []
    private var projectedCount = 0
    private var titleCache: [String: String] = [:]
    private var lineCache: [String: String] = [:]
    private var version = BookStore.bookVersion
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
        var lineCache: [String: String]?
        var needsPolish: Bool?
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
            lineCache = s.lineCache ?? [:]; needsPolish = s.needsPolish ?? false; version = s.version
        }
        if version < Self.bookVersion {
            // Books from 0.4 were AI summaries in one voice. Start again from the journals.
            rebuild()
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
        let snap = Snapshot(version: version, nodes: nodes, waiting: waiting, processed: processed, axes: axes,
                            projectedCount: projectedCount, titleCache: titleCache, lineCache: lineCache, needsPolish: needsPolish)
        guard let data = try? e.encode(snap) else { return }
        try? FileManager.default.createDirectory(at: Self.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: Self.fileURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    private func changed() {
        scheduleSave()
        onLocalChange?()
    }

    // MARK: - Reading order

    /// Everything in reading order: passages, chapter openings and connecting lines.
    var path: [BookNode] { nodes.filter { !$0.deleted }.sorted { $0.position < $1.position } }
    /// Passages only (the map and counts use these).
    var passages: [BookNode] { path.filter { $0.kind == .passage } }

    struct Chapter: Identifiable {
        var id: Int
        var title: String
        var nodes: [BookNode]
        var passageCount: Int { nodes.filter { $0.kind == .passage }.count }
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

    func needsReading(_ j: Journal) -> Bool {
        guard j.status == .ready, !j.deleted, processed[j.id] == nil else { return false }
        return BookEngine.wordCount(j.body) >= 15
    }

    static func dayNumber(_ date: Date) -> Int {
        let c = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return (c.year ?? 2000) * 10000 + (c.month ?? 1) * 100 + (c.day ?? 1)
    }

    /// Reads one journal: picks passages in the author's words and lets each one in, keeps it
    /// waiting, or drops it as a repeat. Then reorganises the book.
    func read(_ j: Journal) async {
        processed[j.id] = j.updatedAt
        defer { scheduleSave() }
        guard Embedder.isAvailable else { return }
        // The same recording imported twice: read it once.
        let others = processed.keys.filter { $0 != j.id }.compactMap { Store.shared.journal($0) }.filter { !$0.deleted }
        if others.contains(where: { BookOrganizer.isRepeatJournal(j.body, of: $0.body) }) { return }

        let excerpts = await Self.passages(from: j)
        let day = Self.dayNumber(j.createdAt)
        var joined = 0
        for (seq, text) in excerpts.enumerated() {
            guard let e = Embedder.vector(for: text) else { continue }
            if consider(text: text, vector: e.vector, language: e.language, journalID: j.id, day: day, seq: seq, candidateID: nil) {
                joined += 1
            }
        }
        if joined > 0 {
            joined += retryWaiting()
            reorganize()
            lastEvent = joined == 1 ? "1 passage joined your book." : "\(joined) passages joined your book."
            changed()
        }
    }

    @discardableResult
    private func consider(text: String, vector: [Float], language: String, journalID: String?, day: Int, seq: Int,
                          candidateID: String?) -> Bool {
        let book = passages.filter { $0.language == language }
        let waitingVectors = waiting.filter { $0.id != candidateID && $0.language == language }.map { BookVectors.decode($0.vectorData) }
        switch BookOrganizer.admit(vector: vector, text: text, bookVectors: book.map(\.vector), bookTexts: book.map(\.text),
                                   waitingVectors: waitingVectors) {
        case .join:
            let now = Date()
            nodes.append(BookNode(id: newID("node"), kind: .passage, journalID: journalID, text: String(text.prefix(4000)),
                                  vectorData: BookVectors.encode(vector), language: language, day: day, seq: seq, key: nil,
                                  position: Double(nodes.count + 1), chapter: 0, chapterTitle: "", x: 0.5, y: 0.5,
                                  createdAt: now, updatedAt: now, deleted: false, dirty: true))
            if let candidateID { waiting.removeAll { $0.id == candidateID } }
            return true
        case let .wait(reason):
            if let candidateID, let i = waiting.firstIndex(where: { $0.id == candidateID }) {
                waiting[i].reason = reason; waiting[i].attempts += 1
            } else if candidateID == nil {
                waiting.append(BookCandidate(id: newID("cand"), journalID: journalID, text: text, vectorData: BookVectors.encode(vector),
                                             language: language, day: day, seq: seq, reason: reason, createdAt: Date(), attempts: 1))
                if waiting.count > 300 { waiting.removeFirst(waiting.count - 300) }
            }
            return false
        case .drop:
            if let candidateID { waiting.removeAll { $0.id == candidateID } }
            return false
        }
    }

    /// Waiting passages may connect now that the book has grown.
    private func retryWaiting() -> Int {
        var joined = 0
        for c in waiting.filter({ $0.attempts < 20 }) {
            if consider(text: c.text, vector: BookVectors.decode(c.vectorData), language: c.language,
                        journalID: c.journalID, day: c.day, seq: c.seq, candidateID: c.id) { joined += 1 }
        }
        return joined
    }

    /// The user's choice wins: put a waiting passage into the book.
    func addAnyway(_ id: String) {
        guard let c = waiting.first(where: { $0.id == id }) else { return }
        let now = Date()
        nodes.append(BookNode(id: newID("node"), kind: .passage, journalID: c.journalID, text: c.text, vectorData: c.vectorData,
                              language: c.language, day: c.day, seq: c.seq, key: nil, position: Double(nodes.count + 1),
                              chapter: 0, chapterTitle: "", x: 0.5, y: 0.5, createdAt: now, updatedAt: now, deleted: false, dirty: true))
        waiting.removeAll { $0.id == id }
        reorganize()
        changed()
    }

    /// Reads a journal again after it grew (passages already in the book are recognised as repeats).
    func reread(_ journalID: String) {
        processed[journalID] = nil
        scheduleSave()
    }

    func dismiss(_ id: String) {
        waiting.removeAll { $0.id == id }
        scheduleSave()
    }

    func remove(_ nodeID: String) {
        guard let i = nodes.firstIndex(where: { $0.id == nodeID }) else { return }
        retire(i)
        reorganize()
        changed()
    }

    private func retire(_ i: Int) {
        nodes[i].deleted = true; nodes[i].text = ""; nodes[i].updatedAt = Date(); nodes[i].dirty = true
    }

    func journalDeleted(_ journalID: String) {
        var touched = false
        for i in nodes.indices where nodes[i].journalID == journalID && !nodes[i].deleted { retire(i); touched = true }
        waiting.removeAll { $0.journalID == journalID }
        if touched { reorganize(); changed() } else { scheduleSave() }
    }

    /// Starts the book over from all journals.
    func rebuild() {
        for i in nodes.indices where !nodes[i].deleted { retire(i) }
        waiting = []; processed = [:]; axes = []; projectedCount = 0; titleCache = [:]; lineCache = [:]
        needsPolish = false
        version = Self.bookVersion
        changed()
    }

    // MARK: - Organising

    /// Re-makes vectors made by an older model so all passages are comparable.
    private func refreshVectors() {
        for i in nodes.indices where nodes[i].kind == .passage && !nodes[i].deleted {
            guard nodes[i].language != Embedder.tag(for: nodes[i].text), let e = Embedder.vector(for: nodes[i].text) else { continue }
            nodes[i].vectorData = BookVectors.encode(e.vector)
            nodes[i].language = e.language
        }
    }

    /// Lays out the whole book: chapters, order, positions and the map. Writing (titles,
    /// openings, connecting lines) is left for `polish()` when the phone is idle.
    private func reorganize() {
        refreshVectors()
        let live = nodes.filter { !$0.deleted && $0.kind == .passage }
        guard !live.isEmpty else { return }
        let chapters = BookOrganizer.organize(live.map { OrgPassage(vector: $0.vector, day: $0.day, journal: $0.journalID ?? $0.id, seq: $0.seq) })

        var position = 0.0
        for (c, members) in chapters.enumerated() {
            let ids = Set(members.map { live[$0].id })
            let title = titleCache[ids.sorted().joined(separator: ",")]
                ?? BookOrganizer.reuseTitle(for: ids, cache: titleCache.map { (ids: Set($0.key.split(separator: ",").map(String.init)), title: $0.value) })
                ?? BookEngine.keywordTitle(members.map { live[$0].text })
            for m in members {
                position += 10
                update(live[m].id) { $0.chapter = c; $0.chapterTitle = title; $0.position = position }
            }
        }
        // Lines written for an older layout are kept only while their place still exists.
        let wanted = Set(wantedLines(chapters: chapters, live: live).map(\.key))
        for i in nodes.indices where nodes[i].kind != .passage && !nodes[i].deleted && !wanted.contains(nodes[i].key ?? "") { retire(i) }
        placeLines(chapters: chapters, live: live)
        needsPolish = true

        // Redraw the map while the book is small, then every 10% of growth.
        let ordered = passages
        if ordered.count < 20 || Double(ordered.count) >= Double(projectedCount) * 1.1 || ordered.contains(where: { $0.x == 0.5 && $0.y == 0.5 }) {
            let (xy, newAxes) = BookEngine.project(ordered.map(\.vector), previousAxes: axes)
            axes = newAxes
            projectedCount = ordered.count
            for (n, p) in zip(ordered, xy) { update(n.id) { $0.x = p.0; $0.y = p.1 } }
        }
    }

    private struct LineSpot { var key: String; var kind: BookNodeKind; var chapter: Int; var before: String; var after: String? }

    /// Where an opening or a connecting line belongs in the current layout.
    private func wantedLines(chapters: [[Int]], live: [BookNode]) -> [LineSpot] {
        var out: [LineSpot] = []
        let vectors = live.map(\.vector)
        for (c, members) in chapters.enumerated() {
            guard let first = members.first else { continue }
            if members.count >= 3 {
                out.append(LineSpot(key: "intro:" + members.map { live[$0].id }.sorted().joined(separator: ","),
                                    kind: .intro, chapter: c, before: live[first].id, after: nil))
            }
            for gap in BookOrganizer.bridgeGaps(members, vectors: vectors) {
                let a = live[members[gap - 1]].id, b = live[members[gap]].id
                out.append(LineSpot(key: "bridge:" + a + ">" + b, kind: .bridge, chapter: c, before: b, after: a))
            }
        }
        return out
    }

    /// Positions existing lines just before the passage they lead into.
    private func placeLines(chapters: [[Int]], live: [BookNode]) {
        for spot in wantedLines(chapters: chapters, live: live) {
            guard let i = nodes.firstIndex(where: { !$0.deleted && $0.key == spot.key }),
                  let target = nodes.first(where: { $0.id == spot.before }) else { continue }
            let pos = target.position - (spot.kind == .intro ? 6 : 3)
            let title = target.chapterTitle
            update(nodes[i].id) { $0.position = pos; $0.chapter = spot.chapter; $0.chapterTitle = title }
        }
    }

    /// Writes chapter titles, openings and connecting lines with Apple Intelligence. Runs when
    /// nothing else is waiting; stops early if new work arrives.
    func polish(shouldStop: () -> Bool = { false }) async {
        guard needsPolish else { return }
        defer { scheduleSave() }
        let live = nodes.filter { !$0.deleted && $0.kind == .passage }
        guard OnDeviceAI.isAvailable, !live.isEmpty else { needsPolish = false; return }
        let byChapter = Dictionary(grouping: live, by: \.chapter)

        // Titles.
        for (_, members) in byChapter.sorted(by: { $0.key < $1.key }) {
            let key = members.map(\.id).sorted().joined(separator: ",")
            guard titleCache[key] == nil else { continue }
            if shouldStop() { return }
            let ordered = members.sorted { $0.position < $1.position }
            let title = await Self.chapterTitle(ordered.map(\.text))
            titleCache[key] = title
            for m in members { update(m.id) { $0.chapterTitle = title } }
        }

        // Openings and connecting lines.
        let chapters = byChapter.keys.sorted().map { c in byChapter[c]!.sorted { $0.position < $1.position } }
        let indexOf = Dictionary(uniqueKeysWithValues: live.enumerated().map { ($1.id, $0) })
        let layout = chapters.map { $0.compactMap { indexOf[$0.id] } }
        for spot in wantedLines(chapters: layout, live: live) {
            if nodes.contains(where: { !$0.deleted && $0.key == spot.key }) { continue }
            if shouldStop() { return }
            let text: String?
            if let cached = lineCache[spot.key] { text = cached } else {
                switch spot.kind {
                case .intro:
                    let members = live.filter { $0.chapter == spot.chapter }.sorted { $0.position < $1.position }
                    text = await Self.opening(title: members.first?.chapterTitle ?? "", passages: members.map(\.text))
                case .bridge:
                    let a = live.first { $0.id == spot.after }?.text ?? "", b = live.first { $0.id == spot.before }?.text ?? ""
                    text = await Self.bridge(from: a, to: b)
                case .passage:
                    text = nil
                }
                if let text { lineCache[spot.key] = text }
            }
            guard let text, let target = nodes.first(where: { $0.id == spot.before }) else { continue }
            let now = Date()
            nodes.append(BookNode(id: newID("line"), kind: spot.kind, journalID: nil, text: text, vectorData: Data(), language: "",
                                  day: target.day, seq: 0, key: spot.key,
                                  position: target.position - (spot.kind == .intro ? 6 : 3),
                                  chapter: spot.chapter, chapterTitle: target.chapterTitle, x: target.x, y: target.y,
                                  createdAt: now, updatedAt: now, deleted: false, dirty: true))
        }
        if lineCache.count > 2000 { lineCache = [:] }
        needsPolish = false
        changed()
    }

    /// Mutates a node; marks it for sync only when something visible changed.
    private func update(_ id: String, _ mutate: (inout BookNode) -> Void) {
        guard let i = nodes.firstIndex(where: { $0.id == id }) else { return }
        var n = nodes[i]
        mutate(&n)
        let moved = abs(n.x - nodes[i].x) > 0.01 || abs(n.y - nodes[i].y) > 0.01
        let visible = moved || n.chapter != nodes[i].chapter || n.chapterTitle != nodes[i].chapterTitle || n.position != nodes[i].position
        guard visible || n != nodes[i] else { return }
        if visible { n.updatedAt = Date(); n.dirty = true }
        nodes[i] = n
    }

    // MARK: - On-device AI

    /// Excerpts in the author's own words. Apple Intelligence chooses and tidies them; any
    /// excerpt that drifts from what was said is replaced by a plain cleaned excerpt.
    static func passages(from j: Journal) async -> [String] {
        let body = j.body
        let budget = max(1, min(8, body.count / 1800 + 1))
        if OnDeviceAI.isAvailable {
            var kept: [String] = []
            for chunk in OnDeviceAI.chunks(of: body, limit: 6000) {
                let n = max(1, min(4, chunk.count / 1800 + 1))
                do {
                    let session = LanguageModelSession(instructions: """
                    You help build a book from someone's journal, in their own words. From the entry, copy up to \
                    \(n) passages worth keeping: insights, decisions, questions, vivid moments. Each passage is 2 to 5 \
                    consecutive sentences copied from the entry. You may only remove filler words, false starts and \
                    repetitions, fix grammar and punctuation, and replace a vague "it" or "this" with what it refers \
                    to. Do not paraphrase, summarize, or add words such as "I realized". Skip logistics and small talk.
                    """)
                    let r = try await session.respond(to: "Journal entry:\n" + chunk, generating: BookExcerpts.self).content
                    for e in r.excerpts.prefix(n) {
                        let t = e.trimmingCharacters(in: .whitespacesAndNewlines)
                        if BookEngine.wordCount(t) >= 25, BookOrganizer.voiceKept(edited: t, source: chunk) >= 0.85 { kept.append(t) }
                    }
                } catch {
                    continue
                }
            }
            if !kept.isEmpty { return Array(kept.prefix(budget)) }
        }
        return BookOrganizer.extractPassages(body)
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

    static func opening(title: String, passages: [String]) async -> String? {
        var context = ""
        for t in passages where context.count < 2500 { context += "- " + String(t.prefix(350)) + "\n" }
        let r = try? await LanguageModelSession(instructions: """
        You write the opening lines of chapters in a personal book, in the author's first-person voice. \
        One or two plain sentences that name the thread running through the passages. Add no new facts, \
        events or advice, and no flourishes.
        """).respond(to: "Chapter: \(title)\nPassages:\n\(context)", generating: BookLine.self).content
        return clean(r?.text, maxWords: 45)
    }

    static func bridge(from a: String, to b: String) async -> String? {
        let r = try? await LanguageModelSession(instructions: """
        You write connecting lines in a personal book, in the author's first-person voice. Write one short \
        sentence, under 20 words, that leads the reader from the first passage to the second. Only connect \
        the ideas; add no new facts, events or advice.
        """).respond(to: "First passage:\n\(a.prefix(700))\n\nSecond passage:\n\(b.prefix(700))", generating: BookLine.self).content
        return clean(r?.text, maxWords: 28)
    }

    private static func clean(_ text: String?, maxWords: Int) -> String? {
        guard let t = text?.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "\"“”"))),
              !t.isEmpty, BookEngine.wordCount(t) <= maxWords else { return nil }
        return t
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
            let kind = BookNodeKind(rawValue: r["kind"] as? String ?? "passage") ?? .passage
            guard r["deleted"] as? Bool != true, let text = r["text"] as? String, !text.isEmpty else { continue }
            var vector = Data(), language = ""
            if kind == .passage {
                guard let e = Embedder.vector(for: text) else { continue }
                vector = BookVectors.encode(e.vector); language = e.language
            }
            let journalID = r["journal_id"] as? String
            if let journalID { processed[journalID] = processed[journalID] ?? updated }
            let created = CloudDates.parse(r["created_at"] as? String) ?? updated
            nodes.append(BookNode(id: id, kind: kind, journalID: journalID, text: text, vectorData: vector, language: language,
                                  day: Self.dayNumber(created), seq: 0, key: nil,
                                  position: (r["position"] as? NSNumber)?.doubleValue ?? 0,
                                  chapter: (r["chapter"] as? NSNumber)?.intValue ?? 0,
                                  chapterTitle: r["chapter_title"] as? String ?? "",
                                  x: (r["x"] as? NSNumber)?.doubleValue ?? 0.5, y: (r["y"] as? NSNumber)?.doubleValue ?? 0.5,
                                  createdAt: created, updatedAt: updated, deleted: false, dirty: false))
            added = true
        }
        if added || !rows.isEmpty { scheduleSave() }
    }
}
