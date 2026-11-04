import CryptoKit
import Foundation
import FoundationModels
import LinkPresentation
import NaturalLanguage
import UIKit

// News that follows what you journal about, without your journal leaving the phone.
//
//   1. Topics are worked out on the iPhone from recent entries (Apple Intelligence, or word
//      counts as a fallback). You can see, switch off, add and remove every topic.
//   2. Only the topic words are sent, as a search, to Google News' public RSS feed.
//   3. Headlines are grouped into stories and summarized on the iPhone. The link back to
//      the entries that made a topic relevant is worked out locally and never sent.

struct NewsTopic: Codable, Identifiable, Hashable {
    var id: String { name.lowercased() }
    var name: String
    var fromJournal: Bool
    var enabled: Bool
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

enum NewsClustering {
    /// Groups headlines about the same story by shared words.
    static func stories(_ articles: [NewsArticle], threshold: Double = 0.34) -> [[NewsArticle]] {
        var groups: [(words: Set<String>, items: [NewsArticle])] = []
        for a in articles {
            let w = BookEngine.contentWords(a.title)
            if let i = groups.firstIndex(where: { jaccard($0.words, w) >= threshold }) {
                groups[i].items.append(a)
                groups[i].words.formUnion(w)
            } else {
                groups.append((w, [a]))
            }
        }
        return groups.map(\.items).sorted {
            $0.count == $1.count ? ($0.first?.published ?? .distantPast) > ($1.first?.published ?? .distantPast) : $0.count > $1.count
        }
    }

    static func jaccard(_ a: Set<String>, _ b: Set<String>) -> Double {
        let union = a.union(b).count
        return union == 0 ? 0 : Double(a.intersection(b).count) / Double(union)
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

@Generable
struct NewsInterests {
    @Guide(description: "Up to 6 public news topics of 1 to 3 words, such as 'electric cars' or 'marathon training'. General subjects only: no names of private people, no places where the author lives, no health or money details.")
    var topics: [String]
}

@Generable
struct NewsSummary {
    @Guide(description: "A clear, neutral headline for the story, under 12 words")
    var headline: String
    @Guide(description: "Two or three neutral sentences summarizing what is happening, using only the headlines given")
    var summary: String
}

@MainActor
final class NewsStore: ObservableObject {
    static let shared = NewsStore()

    @Published private(set) var topics: [NewsTopic] = []
    @Published private(set) var cards: [NewsCard] = []
    @Published private(set) var updatedAt: Date?
    @Published private(set) var loading = false
    @Published var error: String?

    private struct Snapshot: Codable {
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
            topics = s.topics; cards = s.cards; updatedAt = s.updatedAt; topicsUpdatedAt = s.topicsUpdatedAt
        }
    }

    private func save() {
        let snap = Snapshot(topics: topics, cards: cards, updatedAt: updatedAt, topicsUpdatedAt: topicsUpdatedAt)
        guard let data = try? JSONEncoder().encode(snap) else { return }
        try? FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        try? data.write(to: Self.fileURL, options: .atomic)
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
        guard let name = NewsTopics.sanitize(raw), !topics.contains(where: { $0.id == name.lowercased() }) else { return }
        topics.append(NewsTopic(name: name, fromJournal: false, enabled: true))
        save()
    }

    /// Works out topics from the last month of entries, on this iPhone.
    func refreshTopics(from journals: [Journal]) async {
        let recent = journals.filter { $0.status == .ready && !$0.deleted && $0.createdAt > Date().addingTimeInterval(-30 * 86_400) }
        let pool = recent.isEmpty ? Array(journals.filter { $0.status == .ready }.prefix(20)) : recent
        guard !pool.isEmpty else { return }
        var suggested: [String] = []
        if OnDeviceAI.isAvailable {
            var context = ""
            for j in pool where context.count < 5000 { context += "- " + j.displayTitle + ": " + String(j.body.prefix(400)) + "\n" }
            if let r = try? await LanguageModelSession(instructions: """
            You suggest public news topics for a reader, based on what they write about. \
            Use general subjects that newspapers cover. Never include private details.
            """).respond(to: "Recent journal entries:\n" + context, generating: NewsInterests.self).content {
                suggested = r.topics
            }
        }
        if suggested.isEmpty { suggested = NewsTopics.frequentNouns(in: pool.map(\.body)) }
        let hidden = Set(UserDefaults.standard.stringArray(forKey: "slowclaw.news.hidden") ?? [])
        let clean = suggested.compactMap(NewsTopics.sanitize).filter { !hidden.contains($0.lowercased()) }
        // Keep manual topics and switched-off choices; replace the journal-derived ones.
        var next = topics.filter { !$0.fromJournal }
        let previous = Dictionary(topics.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        for name in clean.prefix(6) where !next.contains(where: { $0.id == name.lowercased() }) {
            next.append(NewsTopic(name: name, fromJournal: true, enabled: previous[name.lowercased()]?.enabled ?? true))
        }
        topics = next
        topicsUpdatedAt = Date()
        save()
    }

    // MARK: Stories

    var isStale: Bool { (updatedAt ?? .distantPast) < Date().addingTimeInterval(-3 * 3600) }

    func refresh(journals: [Journal]) async {
        guard !loading else { return }
        loading = true
        error = nil
        defer { loading = false }
        if topics.isEmpty || (topicsUpdatedAt ?? .distantPast) < Date().addingTimeInterval(-86_400) {
            await refreshTopics(from: journals)
        }
        let active = topics.filter(\.enabled)
        guard !active.isEmpty else {
            cards = []
            save()
            return
        }

        var fetched: [(String, [NewsArticle])] = []
        await withTaskGroup(of: (String, [NewsArticle]).self) { group in
            for t in active {
                group.addTask { (t.name, await Self.search(t.name)) }
            }
            for await r in group { fetched.append(r) }
        }
        guard fetched.contains(where: { !$0.1.isEmpty }) else {
            error = "Could not load news. Check your connection and pull to refresh."
            return
        }

        var next: [NewsCard] = []
        for t in active {
            guard let articles = fetched.first(where: { $0.0 == t.name })?.1, !articles.isEmpty else { continue }
            for story in NewsClustering.stories(articles).prefix(3) {
                let top = story[0]
                let id = "card_" + String(Hex.string(Array(SHA256.hash(data: Data(top.url.utf8)))).prefix(24))
                let old = cards.first { $0.id == id }
                next.append(old ?? NewsCard(id: id, topic: t.name, headline: top.title,
                                            summary: Self.fallbackSummary(story), articles: Array(story.prefix(8)),
                                            summarized: false, hasImage: false,
                                            newest: story.compactMap(\.published).max()))
            }
        }
        // Interleave topics so one subject does not fill the screen.
        cards = Self.interleave(next)
        updatedAt = Date()
        save()

        for card in cards where !card.summarized { await summarize(card.id) }
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

    static func fallbackSummary(_ story: [NewsArticle]) -> String {
        let sources = Array(NSOrderedSet(array: story.map(\.source))) as? [String] ?? []
        if story.count == 1 { return "Reported by \(story[0].source)." }
        let others = story.dropFirst().prefix(2).map { "“\($0.title)”" }.joined(separator: " and ")
        return "Covered by \(sources.prefix(3).joined(separator: ", "))\(sources.count > 3 ? " and others" : ""). Also: \(others)."
    }

    private func summarize(_ id: String) async {
        guard OnDeviceAI.isAvailable, let i = cards.firstIndex(where: { $0.id == id }) else { return }
        let card = cards[i]
        let lines = card.articles.prefix(8).map { "- \($0.title) (\($0.source))" }.joined(separator: "\n")
        guard let r = try? await LanguageModelSession(instructions: """
        You write short, neutral news briefs from headlines only. Do not speculate or add facts \
        that are not in the headlines. If the headlines disagree, say so.
        """).respond(to: "Topic: \(card.topic)\nHeadlines:\n\(lines)", generating: NewsSummary.self).content,
              let j = cards.firstIndex(where: { $0.id == id }) else { return }
        let headline = r.headline.trimmingCharacters(in: .whitespacesAndNewlines)
        let summary = r.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        if !headline.isEmpty { cards[j].headline = String(headline.prefix(140)) }
        if !summary.isEmpty { cards[j].summary = String(summary.prefix(600)) }
        cards[j].summarized = true
        save()
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
    nonisolated static func searchURL(_ topic: String, locale: Locale = .current) -> URL? {
        let lang = locale.language.languageCode?.identifier ?? "en"
        let region = locale.region?.identifier ?? "US"
        var c = URLComponents(string: "https://news.google.com/rss/search")
        c?.queryItems = [
            URLQueryItem(name: "q", value: topic + " when:3d"),
            URLQueryItem(name: "hl", value: "\(lang)-\(region)"),
            URLQueryItem(name: "gl", value: region),
            URLQueryItem(name: "ceid", value: "\(region):\(lang)"),
        ]
        return c?.url
    }

    nonisolated static func search(_ topic: String) async -> [NewsArticle] {
        guard let url = searchURL(topic) else { return [] }
        var r = URLRequest(url: url, timeoutInterval: 15)
        r.setValue("SlowClaw", forHTTPHeaderField: "User-Agent")
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        guard let (data, response) = try? await URLSession(configuration: config).data(for: r),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return [] }
        return Array(RSSParser.parse(data).prefix(30))
    }
}
