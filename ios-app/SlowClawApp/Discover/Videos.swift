import Foundation

// Videos for the themes of your book, from channels worth your time.
//
//   1. Recent uploads come from YouTube's public channel feeds (no account, no key, no scraping)
//      of a list of educational channels you can change.
//   2. Each video's title and description are scored on the phone against the passages of each
//      of your book's chapters (MiniLM). A video is shown under the chapter it fits best, only if
//      it is clearly close. Tuned on real journals first (docs/discover.md).
//   3. Nothing about you is sent: the feeds are the same for everyone.

struct VideoChannel: Codable, Identifiable, Hashable {
    var id: String          // UC… channel id
    var name: String
    var enabled: Bool
}

struct VideoItem: Codable, Identifiable, Hashable {
    var id: String
    var title: String
    var channel: String
    var published: Date?
    var summary: String
    var theme: String
    var score: Float

    var url: URL { URL(string: "https://www.youtube.com/watch?v=\(id)")! }
    var thumbnail: URL { URL(string: "https://i.ytimg.com/vi/\(id)/hqdefault.jpg")! }
}

/// Parses a channel's Atom feed (youtube.com/feeds/videos.xml?channel_id=…).
final class ChannelFeedParser: NSObject, XMLParserDelegate {
    private var items: [VideoItem] = []
    private var channel = ""
    private var text = ""
    private var inEntry = false
    private var id = "", title = "", published = "", summary = ""

    static func parse(_ data: Data) -> (channel: String, videos: [VideoItem]) {
        let p = ChannelFeedParser()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = false
        parser.delegate = p
        parser.parse()
        return (p.channel, p.items.map { var v = $0; v.channel = p.channel; return v })
    }

    private static let date = ISO8601DateFormatter()

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
        if name == "entry" { inEntry = true; id = ""; title = ""; published = ""; summary = "" }
        text = ""
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch (inEntry, name) {
        case (false, "title"): if channel.isEmpty { channel = value }
        case (true, "yt:videoId"): id = value
        case (true, "title"): title = value
        case (true, "published"): published = value
        case (true, "media:description"): summary = value
        case (true, "entry"):
            inEntry = false
            let short = (title + " " + summary).lowercased().contains("#shorts")
            if id.count == 11, !title.isEmpty, !short {
                items.append(VideoItem(id: id, title: title, channel: "", published: Self.date.date(from: published),
                                       summary: String(summary.prefix(600)), theme: "", score: 0))
            }
        default: break
        }
        text = ""
    }
}

@MainActor
final class VideoStore: ObservableObject {
    static let shared = VideoStore()

    /// Educational channels covering AI and research, engineering, economics, mind and society.
    static let defaultChannels: [VideoChannel] = [
        ("UCSHZKyawb77ixDdsGog4iWA", "Lex Fridman"), ("UCYO_jab_esuFRV4b17AJtAw", "3Blue1Brown"),
        ("UCbfYPyITQ-7l4upoX8nvctg", "Two Minute Papers"), ("UCsXVk37bltHxD1rDPwtNM8Q", "Kurzgesagt – In a Nutshell"),
        ("UCXUPKJO5MZQN11PqgIvyuvQ", "Andrej Karpathy"), ("UCcefcZRL2oaA_uBNeo5UOWg", "Y Combinator"),
        ("UCP7jMXSY2xbc3KCAE0MHQ-A", "Google DeepMind"), ("UCXl4i9dYBrFOabk0xGmbkRA", "Dwarkesh Patel"),
        ("UCMLtBahI5DMrt0NPvDSoIRQ", "Machine Learning Street Talk"), ("UCZ4AMrDcNrfy3X6nsU8-rPg", "Economics Explained"),
        ("UC7IcJI8PUf5Z3zKxnZvTBog", "The School of Life"), ("UCX6b17PVsYBQ0ip5gyeme-Q", "CrashCourse"),
        ("UCLXo7UDZvByw2ixzpQCufnA", "Vox"), ("UCHuiy8bXnmK5nisYHUd1J5g", "NVIDIA"),
        ("UC6t1O76G0jYXOAoYCm153dA", "Lenny's Podcast"), ("UCNAxrHudMfdzNi6NxruKPLw", "Sam Harris"),
        ("UCAuUUnT6oDeKwE6v1NGQxug", "TED"), ("UCvQECJukTDE2i6aCoMnS-Vg", "Big Think"),
        ("UC2D2CMWXMOVWx7giW1n3LIg", "Andrew Huberman"), ("UCHnyfMqiRRG1u-2MsSQLbXA", "Veritasium"),
        ("UCsBjURrPoezykLs9EqgamOA", "Fireship"), ("UCbRP3c757lWg9M-U7TyEkXA", "Theo - t3.gg"),
        ("UC9-y-6csu5WGm29I7JiwpnA", "Computerphile"), ("UCrM7B7SL_g1edFOnmj-SDKg", "Bloomberg Tech"),
        ("UCLB7AzTwc6VFZrBsO2ucBMg", "Robert Miles AI Safety"),
    ].map { VideoChannel(id: $0.0, name: $0.1, enabled: true) }

    @Published private(set) var channels: [VideoChannel] = VideoStore.defaultChannels
    @Published private(set) var videos: [VideoItem] = []
    @Published private(set) var watched: Set<String> = []
    @Published private(set) var updatedAt: Date?
    @Published private(set) var loading = false
    @Published var error: String?

    private struct Snapshot: Codable {
        var channels: [VideoChannel]?
        var videos: [VideoItem]?
        var watched: [String]
        var updatedAt: Date?
    }

    private static var fileURL: URL {
        (FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory()))
            .appendingPathComponent("SlowClaw", isDirectory: true).appendingPathComponent("videos.json")
    }

    init() {
        if let data = try? Data(contentsOf: Self.fileURL), let s = try? JSONDecoder().decode(Snapshot.self, from: data) {
            if let c = s.channels, !c.isEmpty { channels = c }
            videos = s.videos ?? []; watched = Set(s.watched); updatedAt = s.updatedAt
        }
    }

    private func save() {
        let snap = Snapshot(channels: channels, videos: videos, watched: Array(watched), updatedAt: updatedAt)
        guard let data = try? JSONEncoder().encode(snap) else { return }
        try? FileManager.default.createDirectory(at: Self.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: Self.fileURL, options: .atomic)
    }

    var isStale: Bool { (updatedAt ?? .distantPast) < Date().addingTimeInterval(-6 * 3600) }

    func markWatched(_ v: VideoItem) { watched.insert(v.id); save() }

    func setEnabled(_ c: VideoChannel, _ on: Bool) {
        guard let i = channels.firstIndex(of: c) else { return }
        channels[i].enabled = on; save()
    }

    func remove(_ c: VideoChannel) { channels.removeAll { $0.id == c.id }; save() }

    /// Adds a channel from a link like youtube.com/channel/UC… (the channel's feed gives its name).
    func addChannel(_ link: String) async -> Bool {
        guard let r = link.range(of: #"UC[A-Za-z0-9_-]{22}"#, options: .regularExpression) else { return false }
        let id = String(link[r])
        guard !channels.contains(where: { $0.id == id }), let feed = await Self.feed(id), !feed.channel.isEmpty else { return false }
        channels.append(VideoChannel(id: id, name: feed.channel, enabled: true))
        save()
        return true
    }

    nonisolated static func feed(_ channelID: String) async -> (channel: String, videos: [VideoItem])? {
        guard let url = URL(string: "https://www.youtube.com/feeds/videos.xml?channel_id=\(channelID)") else { return nil }
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        guard let result = try? await URLSession(configuration: config).data(for: URLRequest(url: url, timeoutInterval: 15)),
              (result.1 as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return ChannelFeedParser.parse(result.0)
    }

    /// Recent uploads from your channels, ranked against your book's chapters.
    func refresh() async {
        guard !loading else { return }
        loading = true
        error = nil
        defer { loading = false }
        await BookStore.shared.layout()
        let themes = BookStore.shared.themes
        guard !themes.isEmpty else {
            error = "Your book is still being written. Videos appear once it has chapters."
            return
        }
        var all: [VideoItem] = []
        await withTaskGroup(of: [VideoItem].self) { group in
            for c in channels where c.enabled { group.addTask { await Self.feed(c.id)?.videos ?? [] } }
            for await items in group { all += items }
        }
        guard !all.isEmpty else { error = "Could not load videos. Check your connection and pull to refresh."; return }
        guard let vectors = await Embedder.vectors(for: all.map { $0.title + ". " + String($0.summary.prefix(300)) }) else { return }

        let best = Relevance.best(vectors, themes: themes)
        var next: [VideoItem] = []
        for (t, theme) in themes.enumerated() {
            let mine = all.indices.filter { best[$0].theme == t }
            for k in Relevance.keep(scores: mine.map { best[$0].score }, minimum: 0.45, limit: 3) {
                var v = all[mine[k]]
                v.theme = theme.title; v.score = best[mine[k]].score
                next.append(v)
            }
        }
        videos = next
        updatedAt = Date()
        if next.isEmpty { error = "No recent videos from your channels are close to your themes. Add channels you like." }
        save()
    }
}
