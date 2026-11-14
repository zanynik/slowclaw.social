import Foundation

// Reads: long essays from independent writers, for the themes of your book.
//
//   1. Essays are long-form posts on Nostr (NIP-23), an open network where writers publish under
//      their own keys. The open firehose is mostly spam, so only a list of writers you can change
//      is asked for (prototyped first: docs/discover.md).
//   2. Every post's signature is checked on the phone, so a relay cannot put words in a writer's mouth.
//   3. Title and summary are scored on the phone against each chapter of your book (MiniLM), like
//      Videos. An essay is shown under the chapter it fits best, only if it is clearly close.
//   4. Nothing about you is sent: the relays only see the list of writers.

struct ReadAuthor: Codable, Identifiable, Hashable {
    var id: String          // hex public key
    var name: String
    var enabled: Bool
}

struct ReadArticle: Codable, Identifiable, Hashable {
    var id: String          // "<pubkey>:<identifier>", stable across edits of the essay
    var pubkey: String
    var identifier: String
    var title: String
    var summary: String
    var author: String
    var published: Date
    var content: String     // Markdown
    var theme: String
    var score: Float

    var minutes: Int { max(1, BookEngine.wordCount(content) / 230) }

    /// A web page for this essay that works in any browser.
    var link: URL? {
        NostrLink.naddr(kind: ReadArticle.kind, pubkey: pubkey, identifier: identifier)
            .flatMap { URL(string: "https://njump.me/" + $0) }
    }

    static let kind = 30023
    /// Shorter posts are announcements and stubs, not essays.
    static let minimumLength = 1500

    /// An essay from a long-form event, or nil when it is not one worth showing.
    init?(event e: NostrEvent, author: String) {
        guard e.kind == Self.kind, let identifier = e.tag("d"),
              let title = e.tag("title")?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty,
              e.content.count >= Self.minimumLength else { return nil }
        let plain = ArticleMarkdown.plain(e.content)
        let summary = e.tag("summary")?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        // `published_at` is when it first came out; `created_at` moves with every edit.
        var date = Date(timeIntervalSince1970: TimeInterval(e.createdAt))
        if let raw = e.tag("published_at"), let seconds = TimeInterval(raw), seconds > 1_000_000_000,
           seconds <= TimeInterval(e.createdAt) {
            date = Date(timeIntervalSince1970: seconds)
        }
        self.id = e.pubkey + ":" + identifier
        self.pubkey = e.pubkey
        self.identifier = identifier
        self.title = String(title.prefix(200))
        self.summary = String((summary.isEmpty ? plain : summary).prefix(280))
        self.author = author
        self.published = date
        self.content = String(e.content.prefix(80_000))
        self.theme = ""
        self.score = 0
    }
}

/// Just enough Markdown to read an essay comfortably: headings, paragraphs, quotes, lists, code.
/// Images and raw HTML are left out; "Open in browser" shows the original.
enum ArticleMarkdown {
    enum Block: Equatable {
        case heading(Int, String)
        case paragraph(String)
        case quote(String)
        case bullet(String)
        case numbered(String, String)
        case code(String)
        case rule
    }

    private static func replace(_ s: String, _ pattern: String, _ template: String) -> String {
        s.replacingOccurrences(of: pattern, with: template, options: .regularExpression)
    }

    /// Removes what the reader does not draw: images, HTML tags, long `nostr:` references.
    static func tidy(_ line: String) -> String {
        var s = replace(line, #"!\[[^\]]*\]\([^)]*\)"#, "")
        s = replace(s, #"</?[A-Za-z][^>]*>"#, "")
        s = replace(s, #"nostr:((?:npub|nprofile|note|nevent|naddr)1[a-z0-9]{6})[a-z0-9]*"#, "$1…")
        return s.trimmingCharacters(in: .whitespaces)
    }

    static func blocks(_ markdown: String) -> [Block] {
        var out: [Block] = []
        var paragraph: [String] = []
        var quote: [String] = []
        var code: [String]? = nil

        func flush() {
            if !paragraph.isEmpty { out.append(.paragraph(paragraph.joined(separator: " "))); paragraph = [] }
            if !quote.isEmpty { out.append(.quote(quote.joined(separator: " "))); quote = [] }
        }

        for raw in markdown.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n") {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") {
                if let lines = code {
                    out.append(.code(lines.joined(separator: "\n")))
                    code = nil
                } else {
                    flush()
                    code = []
                }
                continue
            }
            if code != nil { code?.append(raw); continue }

            let line = tidy(raw)
            if line.isEmpty { flush(); continue }
            if line.range(of: #"^(-{3,}|\*{3,}|_{3,})$"#, options: .regularExpression) != nil {
                flush(); out.append(.rule); continue
            }
            if let r = line.range(of: #"^#{1,6}\s+"#, options: .regularExpression) {
                flush()
                let level = line[r].filter { $0 == "#" }.count
                let text = replace(String(line[r.upperBound...]), #"\s+#+$"#, "")
                if !text.isEmpty { out.append(.heading(level, text)) }
                continue
            }
            if line.hasPrefix(">") {
                if !paragraph.isEmpty { flush() }
                let text = line.drop { $0 == ">" || $0 == " " }
                if !text.isEmpty { quote.append(String(text)) }
                continue
            }
            if let r = line.range(of: #"^[-*+]\s+"#, options: .regularExpression) {
                flush(); out.append(.bullet(String(line[r.upperBound...]))); continue
            }
            if let r = line.range(of: #"^\d{1,3}[.)]\s+"#, options: .regularExpression) {
                flush()
                let number = line[r].filter(\.isNumber)
                out.append(.numbered(String(number), String(line[r.upperBound...])))
                continue
            }
            if !quote.isEmpty { flush() }
            paragraph.append(line)
        }
        if let lines = code, !lines.isEmpty { out.append(.code(lines.joined(separator: "\n"))) }
        flush()
        return out
    }

    /// The essay's opening as plain text, for summaries and for scoring.
    static func plain(_ markdown: String, limit: Int = 400) -> String {
        var parts: [String] = []
        var count = 0
        for block in blocks(String(markdown.prefix(4000))) {
            guard case .paragraph(let text) = block else { continue }
            var s = replace(text, #"\[([^\]]*)\]\([^)]*\)"#, "$1")
            s = replace(s, #"[*_`]+"#, "")
            parts.append(s)
            count += s.count
            if count >= limit { break }
        }
        return String(parts.joined(separator: " ").prefix(limit))
    }

    /// Inline styling (bold, italic, links, code) for one block of text.
    static func inline(_ text: String) -> AttributedString {
        (try? AttributedString(markdown: text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }
}

@MainActor
final class ReadsStore: ObservableObject {
    static let shared = ReadsStore()

    static let relays = ["wss://relay.primal.net", "wss://nos.lol", "wss://relay.damus.io"]

    /// Writers who publish long essays on Nostr and are followed by several well-known accounts there
    /// (technology, money, freedom, the open web). Keys were read from the relays, not typed from memory.
    static let defaultAuthors: [ReadAuthor] = [
        ("6e468422dfb74a5738702a8823b9b28168abab8655faacb6853cd0ee15deee93", "Gigi"),
        ("eab0e756d32b80bcd464f3d844b8040303075a13eabc3599a762c9ac7ab91f4f", "Lyn Alden"),
        ("97c70a44366a6535c145b333f973ea86dfdc2d7a99da618c40c64705ad98e322", "hodlbod"),
        ("b7ed68b062de6b4a12e51fd5285c1e1e0ed0e5128cda93ab11b4150b55ed32fc", "Max"),
        ("f1989a96d75aa386b4c871543626cbb362c03248b220dc9ae53d7cefbcaaf2c1", "HRF"),
        ("3f770d65d3a764a9c5cb503ae123e62ec7598ad035d836e2a810f3877a745b24", "Derek Ross"),
        ("af5aa898e8d13b6aef7a9f5a5e6f7e40c0fc5ae9ac3cf8301574e894488e4973", "Frank Corva"),
        ("85bdb5875e113dcc99498b474636449882ee15a1c78154ab07c065b47339d672", "TFTC"),
        ("adc14fa3ad590856dd8b80815d367f7c1e6735ad00fd98a86d002fbe9fb535e1", "Contra"),
        ("efe5d120df0cc290fa748727fb45ac487caad346d4f2293ab069e8f01fc51981", "aljaz"),
        ("e771af0b05c8e95fcdf6feb3500544d2fb1ccd384788e9f490bb3ee28e8ed66f", "sandwich"),
        ("a723805cda67251191c8786f4da58f797e6977582301354ba8e91bcb0342dc9c", "Seth"),
        ("bbb5dda0e15567979f0543407bdc2033d6f0bbb30f72512a981cfdb2f09e2747", "Arjen"),
        ("7459d333af66066f066cf87796e690db3a96ff4534f9edf4eab74df2f207289b", "m0wer"),
        ("dc4cd086cd7ce5b1832adf4fdd1211289880d2c7e295bcb0e684c01acee77c06", "liminal"),
        ("16f1a0100d4cfffbcc4230e8e0e4290cc5849c1adc64d6653fda07c031b1074b", "OceanSlim"),
        ("c21b1a6cdb247ccbd938dcb16b15a4fa382d00ffd7b12d5cbbad172a0cd4d170", "ABH3PO"),
        ("4535551a40271b059ab92b71e7ab7e8700061a2d91b0d20f313ef82f052eb085", "uncleJim21"),
        ("0461fcbecc4c3374439932d6b8f11269ccdb7cc973ad7a50ae362db135a474dd", "Alex Gleason"),
        ("06639a386c9c1014217622ccbcf40908c4f1a0c33e23f8d6d68f4abf655f8f71", "Sebastix"),
        ("9bde421491f3ead1ac21bd1d01667aab947f4c1c4aed87624cf2273b06ca052b", "No Solutions"),
        ("3bf0c63fcb93463407af97a5e5ee64fa883d107ef9e558472c4eb9aaaefa459d", "fiatjaf"),
        ("fa984bd7dbb282f07e16e7ae87b26a2a7b9b90b7246a44771f0cf5ae58018f52", "pablof7z"),
        ("04c915daefee38317fa734444acee390a8269fe5810b2241e5e6dd343dfbecc9", "ODELL"),
        ("82341f882b6eabcd2ba7f1ef90aad961cf074af15b9ef44a09f9d2a8fbfbe6a2", "jack"),
    ].map { ReadAuthor(id: $0.0, name: $0.1, enabled: true) }

    @Published private(set) var authors: [ReadAuthor] = ReadsStore.defaultAuthors
    @Published private(set) var articles: [ReadArticle] = []
    @Published private(set) var opened: Set<String> = []
    @Published private(set) var updatedAt: Date?
    @Published private(set) var loading = false
    @Published var error: String?

    private struct Snapshot: Codable {
        var authors: [ReadAuthor]?
        var articles: [ReadArticle]?
        var opened: [String]
        var updatedAt: Date?
    }

    private static var fileURL: URL {
        (FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory()))
            .appendingPathComponent("SlowClaw", isDirectory: true).appendingPathComponent("reads.json")
    }

    init() {
        if let data = try? Data(contentsOf: Self.fileURL), let s = try? JSONDecoder().decode(Snapshot.self, from: data) {
            if let a = s.authors, !a.isEmpty { authors = a }
            articles = s.articles ?? []; opened = Set(s.opened); updatedAt = s.updatedAt
        }
    }

    private func save() {
        let snap = Snapshot(authors: authors, articles: articles, opened: Array(opened), updatedAt: updatedAt)
        guard let data = try? JSONEncoder().encode(snap) else { return }
        try? FileManager.default.createDirectory(at: Self.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: Self.fileURL, options: .atomic)
    }

    /// Essays are slow: twice a day is plenty.
    var isStale: Bool { (updatedAt ?? .distantPast) < Date().addingTimeInterval(-12 * 3600) }

    func markOpened(_ a: ReadArticle) {
        guard opened.insert(a.id).inserted else { return }
        save()
    }

    func setEnabled(_ a: ReadAuthor, _ on: Bool) {
        guard let i = authors.firstIndex(where: { $0.id == a.id }) else { return }
        authors[i].enabled = on; save()
    }

    func remove(_ a: ReadAuthor) { authors.removeAll { $0.id == a.id }; save() }

    enum AddResult { case added(String), invalid, duplicate }

    /// Adds a writer from their public key (`npub1…`). Their profile on the relays gives the name.
    func addAuthor(_ input: String) async -> AddResult {
        guard let key = NostrLink.publicKey(from: input) else { return .invalid }
        guard !authors.contains(where: { $0.id == key }) else { return .duplicate }
        let profiles = await NostrRelay.fetch(relays: Self.relays, filters: [NostrFilter(kinds: [0], authors: [key], limit: 2)])
        let name = Self.profileName(profiles.filter { $0.pubkey == key && $0.isValid }) ?? String(key.prefix(8)) + "…"
        guard !authors.contains(where: { $0.id == key }) else { return .duplicate }
        authors.append(ReadAuthor(id: key, name: name, enabled: true))
        save()
        return .added(name)
    }

    /// Display name from the newest profile event (kind 0).
    nonisolated static func profileName(_ events: [NostrEvent]) -> String? {
        guard let newest = events.filter({ $0.kind == 0 }).max(by: { $0.createdAt < $1.createdAt }),
              let o = (try? JSONSerialization.jsonObject(with: Data(newest.content.utf8))) as? [String: Any] else { return nil }
        for key in ["display_name", "name"] {
            if let v = (o[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty {
                return String(v.prefix(60))
            }
        }
        return nil
    }

    /// Verified essays by the given writers: newest version of each, newest first.
    nonisolated static func essays(from events: [NostrEvent], names: [String: String]) -> [ReadArticle] {
        var newest: [String: NostrEvent] = [:]
        for e in events where e.kind == ReadArticle.kind && names[e.pubkey] != nil {
            guard let d = e.tag("d") else { continue }
            let key = e.pubkey + ":" + d
            if let have = newest[key], have.createdAt >= e.createdAt { continue }
            newest[key] = e
        }
        return newest.values
            .filter(\.isValid)
            .compactMap { ReadArticle(event: $0, author: names[$0.pubkey] ?? "") }
            .sorted { $0.published > $1.published }
    }

    /// Recent essays from your writers, ranked against your book's chapters.
    func refresh() async {
        guard !loading else { return }
        loading = true
        error = nil
        defer { loading = false }
        await BookStore.shared.layout()
        let themes = BookStore.shared.themes
        guard !themes.isEmpty else {
            error = "Your book is still being written. Reads appear once it has chapters."
            return
        }
        let enabled = authors.filter(\.enabled)
        guard !enabled.isEmpty else {
            articles = []; save()
            error = "Turn on at least one writer to get essays."
            return
        }
        let names = Dictionary(enabled.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        let since = Int(Date().addingTimeInterval(-180 * 86400).timeIntervalSince1970)
        let filter = NostrFilter(kinds: [ReadArticle.kind], authors: enabled.map(\.id), since: since, limit: 400)
        let events = await NostrRelay.fetch(relays: Self.relays, filters: [filter])
        guard !events.isEmpty else {
            error = "Could not load essays. Check your connection and pull to refresh."
            return
        }
        let all = await Task.detached(priority: .utility) { Self.essays(from: events, names: names) }.value
        guard !all.isEmpty,
              let vectors = await Embedder.vectors(for: all.map { $0.title + ". " + $0.summary }) else { return }

        let best = Relevance.best(vectors, themes: themes)
        var next: [ReadArticle] = []
        for (t, theme) in themes.enumerated() {
            let mine = all.indices.filter { best[$0].theme == t }
            for k in Relevance.keep(scores: mine.map { best[$0].score }, minimum: 0.45, limit: 3) {
                var a = all[mine[k]]
                a.theme = theme.title; a.score = best[mine[k]].score
                next.append(a)
            }
        }
        articles = next
        updatedAt = Date()
        if next.isEmpty { error = "Nothing recent from your writers is close to your themes. Add writers you like." }
        save()
    }
}
