import CryptoKit
import Foundation
import LinkPresentation
import NaturalLanguage
import UIKit

// News for the themes of your book, without your journal leaving the phone.
//
//   1. The book's chapters are your themes. Each gets a few searches made from the named things
//      and concept phrases it keeps returning to (never people or places). You can see them all.
//   2. Only those searches are sent, to Google News' public RSS feed.
//   3. Every headline is scored on the phone against the passages of its theme (MiniLM); only
//      clearly close ones are kept. Tuned on real journals first (docs/discover.md).

struct NewsTopic: Codable, Identifiable, Hashable {
    var id: String { name.lowercased() }
    /// Short label shown on cards ("Zero-profit food").
    var name: String
    /// The specific search actually sent ("community supermarket returning profits to shoppers").
    var query: String
    var fromJournal: Bool
    var enabled: Bool

    init(name: String, query: String? = nil, fromJournal: Bool, enabled: Bool) {
        self.name = name; self.query = query ?? name; self.fromJournal = fromJournal; self.enabled = enabled
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        query = try c.decodeIfPresent(String.self, forKey: .query) ?? name
        fromJournal = try c.decode(Bool.self, forKey: .fromJournal)
        enabled = try c.decode(Bool.self, forKey: .enabled)
    }
}

/// An article opened from News, kept so nothing read is lost (with time spent reading).
struct ReadRecord: Codable, Identifiable, Hashable {
    var id: String { url }
    var url: String
    var title: String
    var source: String
    var topic: String
    var openedAt: Date
    var seconds: Int
}

struct NewsArticle: Codable, Hashable, Identifiable {
    var id: String { url }
    var title: String
    var source: String
    var url: String
    var published: Date?
}

struct NewsCard: Codable, Identifiable, Hashable {
    var id: String
    var topic: String
    var headline: String
    var summary: String
    var articles: [NewsArticle]
    var summarized: Bool
    var hasImage: Bool
    var newest: Date?

    var sourcesLabel: String {
        let names = Array(NSOrderedSet(array: articles.map(\.source))) as? [String] ?? []
        guard let first = names.first else { return "" }
        if names.count == 1 { return first }
        if names.count == 2 { return first + " · " + names[1] }
        return first + " · " + names[1] + " +\(names.count - 2)"
    }
}

// MARK: - Pure helpers (tested)

enum NewsTopics {
    /// A specific search phrase: 2–10 words, the same rules as topics otherwise.
    static func sanitizeQuery(_ raw: String) -> String? {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        guard (4...90).contains(t.count), !t.contains("@"), !t.contains("http") else { return nil }
        guard (2...10).contains(t.split(separator: " ").count) else { return nil }
        guard t.range(of: #"\d{3,}"#, options: .regularExpression) == nil else { return nil }
        guard t.allSatisfy({ $0.isLetter || $0.isNumber || " &-'".contains($0) }) else { return nil }
        return t
    }

    /// Fallback without Apple Intelligence: the most repeated two-word phrases of content words.
    static func frequentPhrases(in texts: [String], limit: Int = 6) -> [String] {
        var counts: [String: Int] = [:]
        for text in texts {
            let words = text.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init)
            for (a, b) in zip(words, words.dropFirst()) where a.count >= 4 && b.count >= 4
                && BookEngine.contentWords(a).count == 1 && BookEngine.contentWords(b).count == 1 {
                counts[a + " " + b, default: 0] += 1
            }
        }
        return counts.filter { $0.value >= 3 }.sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            .prefix(limit).map(\.key)
    }

    /// Keeps a topic only if it looks like a public subject, not a private detail.
    static func sanitize(_ raw: String) -> String? {
        let t = raw.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
        guard (2...40).contains(t.count), !t.contains("@"), !t.contains("http") else { return nil }
        let words = t.split(separator: " ")
        guard (1...4).contains(words.count) else { return nil }
        // Long digit runs are phone numbers, addresses or dates, not news topics.
        guard t.range(of: #"\d{3,}"#, options: .regularExpression) == nil else { return nil }
        guard t.allSatisfy({ $0.isLetter || $0.isNumber || " &-'".contains($0) }) else { return nil }
        return t
    }

    /// Fallback without Apple Intelligence: frequent nouns across recent entries.
    static func frequentNouns(in texts: [String], limit: Int = 6) -> [String] {
        var counts: [String: Int] = [:]
        let tagger = NLTagger(tagSchemes: [.lexicalClass])
        for text in texts {
            tagger.string = text
            tagger.enumerateTags(in: text.startIndex..<text.endIndex, unit: .word, scheme: .lexicalClass,
                                 options: [.omitPunctuation, .omitWhitespace]) { tag, range in
                if tag == .noun {
                    let w = text[range].lowercased()
                    if w.count >= 4 { counts[w, default: 0] += 1 }
                }
                return true
            }
        }
        let common: Set<String> = ["time", "today", "thing", "things", "week", "day", "days", "people", "something",
                                   "anything", "everything", "work", "life", "lot", "bit", "morning", "evening",
                                   "night", "year", "years", "way", "kind", "idea", "ideas"]
        return counts.filter { $0.value >= 3 && !common.contains($0.key) }
            .sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            .prefix(limit).map(\.key)
    }

    /// Journals that mention a topic (computed on the phone, only for display).
    static func matches(topic: String, in journals: [Journal]) -> [String] {
        let words = topic.lowercased().split(separator: " ").map(String.init).filter { $0.count >= 4 }
        let needles = words.isEmpty ? [topic.lowercased()] : words
        return journals.filter { j in
            let hay = (j.title + " " + j.body).lowercased()
            return needles.contains { hay.contains($0) }
        }.map(\.id)
    }
}

/// Parses Google News RSS (`<item><title>Headline - Source</title><link/><pubDate/><source url/></item>`).
final class RSSParser: NSObject, XMLParserDelegate {
    private var items: [NewsArticle] = []
    private var text = ""
    private var title = "", link = "", source = "", date = ""
    private var inItem = false

    static func parse(_ data: Data) -> [NewsArticle] {
        let p = RSSParser()
        let parser = XMLParser(data: data)
        parser.delegate = p
        parser.parse()
        return p.items
    }

    private static let dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return f
    }()

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
        if name == "item" { inItem = true; title = ""; link = ""; source = ""; date = "" }
        text = ""
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        guard inItem else { return }
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch name {
        case "title": title = value
        case "link": link = value
        case "source": source = value
        case "pubDate": date = value
        case "item":
            inItem = false
            var headline = title
            if !source.isEmpty, headline.hasSuffix(" - " + source) { headline = String(headline.dropLast(source.count + 3)) }
            if let url = URL(string: link), url.scheme == "https", !headline.isEmpty {
                items.append(NewsArticle(title: headline, source: source.isEmpty ? (url.host ?? "") : source,
                                         url: link, published: Self.dateFormatter.date(from: date)))
            }
        default: break
        }
        text = ""
    }
}

// MARK: - Store

@MainActor
final class NewsStore: ObservableObject {
    static let shared = NewsStore()

    @Published private(set) var topics: [NewsTopic] = []
    @Published private(set) var history: [ReadRecord] = []
    @Published private(set) var cards: [NewsCard] = []
    @Published private(set) var updatedAt: Date?
    @Published private(set) var loading = false
    @Published var error: String?

    private struct Snapshot: Codable {
        var history: [ReadRecord]?
        var topics: [NewsTopic]
        var cards: [NewsCard]
        var updatedAt: Date?
        var topicsUpdatedAt: Date?
    }
    private var topicsUpdatedAt: Date?

    private static var directory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("SlowClaw", isDirectory: true)
    }
    private static var fileURL: URL { directory.appendingPathComponent("news.json") }
    static var imageDirectory: URL {
        (FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())).appendingPathComponent("news-images", isDirectory: true)
    }
    static func imageURL(for cardID: String) -> URL { imageDirectory.appendingPathComponent(cardID + ".jpg") }

    init() {
        if let data = try? Data(contentsOf: Self.fileURL), let s = try? JSONDecoder().decode(Snapshot.self, from: data) {
            // Topics suggested by 0.5's language model are retired; your own topics stay.
            topics = s.topics.filter { !$0.fromJournal }; cards = s.cards; updatedAt = s.updatedAt; topicsUpdatedAt = s.topicsUpdatedAt
            history = s.history ?? []
        }
    }

    private func save() {
        let snap = Snapshot(history: history, topics: topics, cards: cards, updatedAt: updatedAt, topicsUpdatedAt: topicsUpdatedAt)
        guard let data = try? JSONEncoder().encode(snap) else { return }
        try? FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        try? data.write(to: Self.fileURL, options: .atomic)
    }

    // MARK: Reading history

    /// Records an article read from News (time counted while it was open).
    func recordRead(_ article: NewsArticle, topic: String, openedAt: Date) {
        let seconds = max(0, Int(Date().timeIntervalSince(openedAt)))
        if let i = history.firstIndex(where: { $0.url == article.url }) {
            history[i].seconds += seconds
            history[i].openedAt = openedAt
        } else {
            history.insert(ReadRecord(url: article.url, title: article.title, source: article.source, topic: topic,
                                      openedAt: openedAt, seconds: seconds), at: 0)
            if history.count > 500 { history.removeLast(history.count - 500) }
        }
        history.sort { $0.openedAt > $1.openedAt }
        save()
    }

    func isRead(_ card: NewsCard) -> Bool {
        card.articles.contains { a in history.contains { $0.url == a.url } }
    }

    func forget(_ record: ReadRecord) {
        history.removeAll { $0.url == record.url }
        save()
    }

    func setQuery(_ topic: NewsTopic, _ query: String) {
        guard let i = topics.firstIndex(of: topic), let q = NewsTopics.sanitizeQuery(query) ?? NewsTopics.sanitize(query) else { return }
        topics[i].query = q
        save()
    }

    // MARK: Topics

    func setEnabled(_ topic: NewsTopic, _ on: Bool) {
        guard let i = topics.firstIndex(of: topic) else { return }
        topics[i].enabled = on
        save()
    }

    func remove(_ topic: NewsTopic) {
        topics.removeAll { $0.id == topic.id }
        cards.removeAll { $0.topic.lowercased() == topic.id }
        // Remember removed journal topics so they are not suggested again.
        var hidden = Set(UserDefaults.standard.stringArray(forKey: "slowclaw.news.hidden") ?? [])
        hidden.insert(topic.id)
        UserDefaults.standard.set(Array(hidden), forKey: "slowclaw.news.hidden")
        save()
    }

    func add(_ raw: String) {
        let words = raw.split(separator: " ")
        // Long entries become the search; the first words become the label.
        let label = words.count > 4 ? words.prefix(3).joined(separator: " ") : raw
        guard let name = NewsTopics.sanitize(label), !topics.contains(where: { $0.id == name.lowercased() }) else { return }
        topics.append(NewsTopic(name: name, query: NewsTopics.sanitizeQuery(raw) ?? name, fromJournal: false, enabled: true))
        save()
    }

    // MARK: Stories

    /// Searches made from the book's themes (shown in the Topics screen).
    struct ThemeSearch: Identifiable { var theme: String; var searches: [String]; var id: String { theme } }
    @Published private(set) var themeSearches: [ThemeSearch] = []

    var isStale: Bool { (updatedAt ?? .distantPast) < Date().addingTimeInterval(-3 * 3600) }

    /// Finds news for the book's themes and your own topics, keeping only stories that are
    /// clearly close to what you wrote (scored with MiniLM against your passages).
    func refresh(journals: [Journal]) async {
        guard !loading else { return }
        loading = true
        error = nil
        defer { loading = false }
        await BookStore.shared.layout()
        let themes = BookStore.shared.themes.prefix(10).map { $0 }
        let searches = ThemeSearches.searches(for: themes)
        themeSearches = zip(themes, searches).map { ThemeSearch(theme: $0.title, searches: $1) }

        // Each theme, plus each topic you added yourself (scored against its own words).
        struct Lane { var title: String; var searches: [String]; var vectors: [[Float]]; var manual: Bool }
        var lanes = zip(themes, searches).map { Lane(title: $0.title, searches: $1, vectors: $0.vectors, manual: false) }
        for t in topics where t.enabled && !t.fromJournal {
            if let v = Embedder.vector(for: t.query) { lanes.append(Lane(title: t.name, searches: [t.query], vectors: [v], manual: true)) }
        }
        guard !lanes.isEmpty else {
            error = journals.isEmpty ? nil : "Your book is still being written. News appears once it has chapters."
            cards = []; save(); return
        }

        let allSearches = Array(Set(lanes.flatMap(\.searches)))
        var results: [String: [NewsArticle]] = [:]
        await withTaskGroup(of: (String, [NewsArticle]).self) { group in
            for q in allSearches { group.addTask { (q, Array(await Self.search(q, days: 14).prefix(15))) } }
            for await (q, items) in group { results[q] = items }
        }
        guard results.values.contains(where: { !$0.isEmpty }) else {
            error = "Could not load news. Check your connection and pull to refresh."
            return
        }

        var next: [NewsCard] = []
        var seen = Set<String>()
        for lane in lanes {
            var pool: [NewsArticle] = []
            for q in lane.searches { for a in results[q] ?? [] where !pool.contains(where: { $0.title == a.title }) { pool.append(a) } }
            guard !pool.isEmpty, let vectors = await Embedder.vectors(for: pool.map(\.title)) else { continue }
            let centroid = Relevance.centroid(lane.vectors)
            let scores = vectors.map { Relevance.score($0, passages: lane.vectors, centroid: centroid) }
            for i in Relevance.keep(scores: scores, minimum: lane.manual ? 0.35 : 0.48, limit: lane.manual ? 5 : 4) {
                let a = pool[i]
                guard seen.insert(a.url).inserted else { continue }
                let id = "card_" + String(Hex.string(Array(SHA256.hash(data: Data(a.url.utf8)))).prefix(24))
                let old = cards.first { $0.id == id }
                next.append(NewsCard(id: id, topic: lane.title, headline: a.title, summary: "", articles: [a],
                                     summarized: false, hasImage: old?.hasImage ?? false, newest: a.published))
            }
        }
        cards = Self.interleave(next)
        updatedAt = Date()
        if cards.isEmpty { error = "Nothing new close to your themes right now." }
        save()
        for card in cards.prefix(12) where !card.hasImage { await loadImage(card.id) }
    }

    static func interleave(_ cards: [NewsCard]) -> [NewsCard] {
        var byTopic: [String: [NewsCard]] = [:]
        var order: [String] = []
        for c in cards {
            if byTopic[c.topic] == nil { order.append(c.topic) }
            byTopic[c.topic, default: []].append(c)
        }
        var out: [NewsCard] = []
        var round = 0
        while out.count < cards.count {
            for t in order where (byTopic[t]?.count ?? 0) > round { out.append(byTopic[t]![round]) }
            round += 1
        }
        return out
    }

    /// Picture for a card from the article's own link preview. Skipped when the preview
    /// only shows the news aggregator's logo.
    private func loadImage(_ id: String) async {
        guard let card = cards.first(where: { $0.id == id }) else { return }
        for article in card.articles.prefix(2) {
            guard let url = URL(string: article.url) else { continue }
            let provider = LPMetadataProvider()
            provider.timeout = 8
            guard let meta = try? await provider.startFetchingMetadata(for: url),
                  let host = meta.url?.host, !host.contains("google."),
                  let imageProvider = meta.imageProvider,
                  let image = await Self.loadImage(imageProvider),
                  let jpeg = Self.thumbnail(image)?.jpegData(compressionQuality: 0.75) else { continue }
            try? FileManager.default.createDirectory(at: Self.imageDirectory, withIntermediateDirectories: true)
            try? jpeg.write(to: Self.imageURL(for: id), options: .atomic)
            if let i = cards.firstIndex(where: { $0.id == id }) { cards[i].hasImage = true; save() }
            return
        }
    }

    private static func loadImage(_ provider: NSItemProvider) async -> UIImage? {
        await withCheckedContinuation { cont in
            provider.loadObject(ofClass: UIImage.self) { object, _ in cont.resume(returning: object as? UIImage) }
        }
    }

    private static func thumbnail(_ image: UIImage) -> UIImage? {
        let maxSide: CGFloat = 900
        let scale = min(1, maxSide / max(image.size.width, image.size.height))
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        guard size.width > 40, size.height > 40 else { return nil }
        return UIGraphicsImageRenderer(size: size).image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
    }

    // MARK: Feed

    /// The only network request with your interests in it: the topic as a search query.
    nonisolated static func searchURL(_ topic: String, days: Int = 3, locale: Locale = .current) -> URL? {
        let lang = locale.language.languageCode?.identifier ?? "en"
        let region = locale.region?.identifier ?? "US"
        var c = URLComponents(string: "https://news.google.com/rss/search")
        c?.queryItems = [
            URLQueryItem(name: "q", value: topic + " when:\(days)d"),
            URLQueryItem(name: "hl", value: "\(lang)-\(region)"),
            URLQueryItem(name: "gl", value: region),
            URLQueryItem(name: "ceid", value: "\(region):\(lang)"),
        ]
        return c?.url
    }

    nonisolated static func search(_ topic: String, days: Int = 3) async -> [NewsArticle] {
        guard let url = searchURL(topic, days: days) else { return [] }
        var r = URLRequest(url: url, timeoutInterval: 15)
        r.setValue("SlowClaw", forHTTPHeaderField: "User-Agent")
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        guard let result = try? await URLSession(configuration: config).data(for: r),
              (result.1 as? HTTPURLResponse)?.statusCode == 200 else { return [] }
        return Array(RSSParser.parse(result.0).prefix(30))
    }
}
