import Foundation
import FoundationModels

// Videos chosen for the gaps and interests in your journal, not for engagement.
//
//   1. On the iPhone, Apple Intelligence reads recent entries and names a few learning goals:
//      things you said you don't understand, questions you keep asking, skills you want, and
//      what you care about most. Each goal has a YouTube search and a reason. The reason stays
//      on the phone; you can see, edit and remove every search.
//   2. Only the search is sent to YouTube (its public results page, no account, no API key).
//   3. Results are kept to real explanations: no Shorts, nothing under four minutes.

struct LearningGoal: Codable, Identifiable, Hashable {
    var id: String { label.lowercased() }
    var label: String
    /// Why this could help, written on the phone from the journal. Never sent anywhere.
    var why: String
    /// "gap" (something to understand) or "interest" (something to go deeper into).
    var kind: String
    var query: String
    var enabled: Bool
}

struct VideoItem: Codable, Identifiable, Hashable {
    var id: String
    var title: String
    var channel: String
    var duration: String
    var published: String
    var goal: String

    var url: URL { URL(string: "https://www.youtube.com/watch?v=\(id)")! }
    var thumbnail: URL { URL(string: "https://i.ytimg.com/vi/\(id)/hqdefault.jpg")! }
}

enum YouTubeResults {
    /// Pulls videos out of a YouTube results page (`var ytInitialData = {...};`).
    static func parse(html: String) -> [VideoItem] {
        guard let start = html.range(of: "var ytInitialData = ") ?? html.range(of: "window[\"ytInitialData\"] = ") else { return [] }
        let rest = html[start.upperBound...]
        guard let end = rest.range(of: ";</script>") else { return [] }
        guard let data = String(rest[..<end.lowerBound]).data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) else { return [] }
        var out: [VideoItem] = []
        collect(json, into: &out)
        var seen = Set<String>()
        return out.filter { seen.insert($0.id).inserted }
    }

    private static func collect(_ node: Any, into out: inout [VideoItem]) {
        if let dict = node as? [String: Any] {
            if let r = dict["videoRenderer"] as? [String: Any], let item = video(r) { out.append(item) }
            for value in dict.values { collect(value, into: &out) }
        } else if let array = node as? [Any] {
            for value in array { collect(value, into: &out) }
        }
    }

    private static func text(_ v: Any?) -> String {
        guard let d = v as? [String: Any] else { return "" }
        if let s = d["simpleText"] as? String { return s }
        return (d["runs"] as? [[String: Any]])?.compactMap { $0["text"] as? String }.joined() ?? ""
    }

    private static func video(_ r: [String: Any]) -> VideoItem? {
        guard let id = r["videoId"] as? String, id.count == 11,
              id.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }) else { return nil }
        let title = text(r["title"])
        guard !title.isEmpty else { return nil }
        return VideoItem(id: id, title: title, channel: text(r["ownerText"]), duration: text(r["lengthText"]),
                         published: text(r["publishedTimeText"]), goal: "")
    }

    /// "1:02:03" or "12:30" → seconds (0 when unknown, e.g. live streams).
    static func seconds(_ duration: String) -> Int {
        duration.split(separator: ":").reduce(0) { $0 * 60 + (Int($1) ?? 0) }
    }

    /// Long enough to explain something: four minutes to three hours.
    static func worthWatching(_ v: VideoItem) -> Bool {
        let s = seconds(v.duration)
        return s >= 240 && s <= 3 * 3600
    }

    static func searchURL(_ query: String) -> URL? {
        var c = URLComponents(string: "https://www.youtube.com/results")
        // sp=EgIQAQ== limits results to videos (no channels or playlists).
        c?.queryItems = [URLQueryItem(name: "search_query", value: query), URLQueryItem(name: "sp", value: "EgIQAQ==")]
        return c?.url
    }
}

@Generable
struct LearningPlan {
    @Guide(description: "Up to 5 learning goals found in the journal")
    var goals: [LearningGoalDraft]
}

@Generable
struct LearningGoalDraft {
    @Guide(description: "A short label of 2 to 5 words")
    var label: String
    @Guide(description: "One sentence, addressed to the writer as 'you', on why this could help them, based on what they wrote")
    var why: String
    @Guide(description: "gap if they said they don't understand it or keep asking about it; interest if they want to go deeper")
    var kind: String
    @Guide(description: "A YouTube search of 3 to 8 words for a clear explanation of a public subject, e.g. 'how GPUs accelerate neural networks explained'. No private details.")
    var query: String
}

@MainActor
final class VideoStore: ObservableObject {
    static let shared = VideoStore()

    @Published private(set) var goals: [LearningGoal] = []
    @Published private(set) var videos: [VideoItem] = []
    @Published private(set) var watched: Set<String> = []
    @Published private(set) var updatedAt: Date?
    @Published private(set) var loading = false
    /// Goals whose search could not be read from YouTube's page (shown as a search link instead).
    @Published private(set) var unreadable: Set<String> = []
    @Published var error: String?

    private struct Snapshot: Codable {
        var goals: [LearningGoal]
        var videos: [VideoItem]
        var watched: [String]
        var updatedAt: Date?
        var goalsUpdatedAt: Date?
    }
    private var goalsUpdatedAt: Date?

    private static var fileURL: URL {
        (FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory()))
            .appendingPathComponent("SlowClaw", isDirectory: true).appendingPathComponent("videos.json")
    }

    init() {
        if let data = try? Data(contentsOf: Self.fileURL), let s = try? JSONDecoder().decode(Snapshot.self, from: data) {
            goals = s.goals; videos = s.videos; watched = Set(s.watched); updatedAt = s.updatedAt; goalsUpdatedAt = s.goalsUpdatedAt
        }
    }

    private func save() {
        let snap = Snapshot(goals: goals, videos: videos, watched: Array(watched), updatedAt: updatedAt, goalsUpdatedAt: goalsUpdatedAt)
        guard let data = try? JSONEncoder().encode(snap) else { return }
        try? FileManager.default.createDirectory(at: Self.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: Self.fileURL, options: .atomic)
    }

    var isStale: Bool { (updatedAt ?? .distantPast) < Date().addingTimeInterval(-12 * 3600) }

    func markWatched(_ v: VideoItem) { watched.insert(v.id); save() }

    func setEnabled(_ g: LearningGoal, _ on: Bool) {
        guard let i = goals.firstIndex(of: g) else { return }
        goals[i].enabled = on; save()
    }

    func remove(_ g: LearningGoal) {
        goals.removeAll { $0.id == g.id }
        videos.removeAll { $0.goal == g.label }
        save()
    }

    func setQuery(_ g: LearningGoal, _ query: String) {
        guard let i = goals.firstIndex(of: g), let q = NewsTopics.sanitizeQuery(query) else { return }
        goals[i].query = q; save()
    }

    func add(_ query: String) {
        guard let q = NewsTopics.sanitizeQuery(query) else { return }
        let label = q.split(separator: " ").prefix(4).joined(separator: " ").capitalized
        guard !goals.contains(where: { $0.id == label.lowercased() }) else { return }
        goals.append(LearningGoal(label: label, why: "Added by you.", kind: "interest", query: q, enabled: true))
        save()
    }

    /// Finds learning goals in the last month of entries, on this iPhone.
    func refreshGoals(from journals: [Journal]) async {
        let recent = journals.filter { $0.status == .ready && !$0.deleted && $0.createdAt > Date().addingTimeInterval(-30 * 86_400) }
        let pool = recent.isEmpty ? Array(journals.filter { $0.status == .ready }.prefix(20)) : recent
        guard !pool.isEmpty else { return }
        var drafts: [LearningGoal] = []
        if OnDeviceAI.isAvailable {
            var context = ""
            for j in pool where context.count < 5500 { context += "- " + j.displayTitle + ": " + String(j.body.prefix(550)) + "\n" }
            if let r = try? await LanguageModelSession(instructions: """
            You are a thoughtful mentor reading someone's journal to suggest what they could learn next. \
            Look for things they say they don't understand, questions they keep asking, skills they want, \
            and the subjects they care about most. Suggest explanations that would help them grow, not \
            entertainment. Never put private details into a search.
            """).respond(to: "Recent journal entries:\n" + context, generating: LearningPlan.self).content {
                drafts = r.goals.compactMap { d in
                    guard let label = NewsTopics.sanitize(d.label), let q = NewsTopics.sanitizeQuery(d.query) else { return nil }
                    return LearningGoal(label: label, why: String(d.why.prefix(240)), kind: d.kind == "gap" ? "gap" : "interest",
                                        query: q, enabled: true)
                }
            }
        }
        if drafts.isEmpty {
            // Without Apple Intelligence: the questions you asked yourself.
            drafts = Self.questions(in: pool.map(\.body)).prefix(4).compactMap { q in
                guard let query = NewsTopics.sanitizeQuery(q) else { return nil }
                return LearningGoal(label: query.split(separator: " ").prefix(4).joined(separator: " ").capitalized,
                                    why: "You asked yourself about this.", kind: "gap", query: query, enabled: true)
            }
        }
        guard !drafts.isEmpty else { return }
        let previous = Dictionary(goals.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var next = goals.filter { $0.why == "Added by you." }
        for d in drafts where !next.contains(where: { $0.id == d.id }) {
            var g = d
            if let old = previous[d.id] { g.enabled = old.enabled }
            next.append(g)
        }
        goals = next
        goalsUpdatedAt = Date()
        save()
    }

    /// "How does X work?" style sentences, reduced to their content words.
    static func questions(in texts: [String]) -> [String] {
        var out: [String] = []
        for t in texts {
            for s in BookOrganizer.sentences(t) where s.hasSuffix("?") {
                let lower = s.lowercased()
                guard ["what is", "how does", "how do", "why does", "why is", "what does", "how can"].contains(where: { lower.contains($0) }) else { continue }
                let words = lower.split(whereSeparator: { !$0.isLetter }).map(String.init)
                    .filter { $0.count >= 4 && !BookEngine.contentWords($0).isEmpty }
                if words.count >= 2 { out.append(words.prefix(6).joined(separator: " ") + " explained") }
            }
        }
        return out
    }

    func refresh(journals: [Journal]) async {
        guard !loading else { return }
        loading = true
        error = nil
        defer { loading = false }
        if goals.isEmpty || (goalsUpdatedAt ?? .distantPast) < Date().addingTimeInterval(-3 * 86_400) {
            await refreshGoals(from: journals)
        }
        let active = goals.filter(\.enabled)
        var found: [VideoItem] = []
        var failed = Set<String>()
        await withTaskGroup(of: (String, [VideoItem]?).self) { group in
            for g in active { group.addTask { (g.label, await Self.search(g.query)) } }
            for await (label, items) in group {
                guard let items else { failed.insert(label); continue }
                found += items.filter(YouTubeResults.worthWatching).prefix(4).map { var v = $0; v.goal = label; return v }
            }
        }
        unreadable = failed
        if found.isEmpty && !active.isEmpty {
            error = "Could not load videos right now. Each goal below links to the search on YouTube."
            return
        }
        // Keep goal order; unwatched first within a goal.
        let order = Dictionary(uniqueKeysWithValues: active.enumerated().map { ($1.label, $0) })
        videos = found.sorted {
            (order[$0.goal] ?? 0, watched.contains($0.id) ? 1 : 0) < (order[$1.goal] ?? 0, watched.contains($1.id) ? 1 : 0)
        }
        updatedAt = Date()
        save()
    }

    /// The only request with your interests in it: the search text, sent to YouTube's results page.
    /// Returns nil when the page could not be read (YouTube changes it from time to time).
    nonisolated static func search(_ query: String) async -> [VideoItem]? {
        guard let url = YouTubeResults.searchURL(query) else { return nil }
        var r = URLRequest(url: url, timeoutInterval: 15)
        r.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 26_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Mobile/15E148 Safari/604.1",
                   forHTTPHeaderField: "User-Agent")
        r.setValue("en", forHTTPHeaderField: "Accept-Language")
        // Skip the cookie-consent interstitial shown in the EU; no tracking cookies are accepted.
        r.setValue("SOCS=CAI", forHTTPHeaderField: "Cookie")
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        guard let result = try? await URLSession(configuration: config).data(for: r),
              (result.1 as? HTTPURLResponse)?.statusCode == 200,
              let html = String(data: result.0, encoding: .utf8) else { return nil }
        let items = YouTubeResults.parse(html: html)
        return items.isEmpty ? nil : items
    }
}
