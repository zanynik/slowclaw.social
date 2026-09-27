import Foundation

struct NostrProfile {
    let event: PublishedEvent
    let fields: [String: Any]
    init?(_ event: PublishedEvent) {
        guard event.kind == 0,
              let fields = try? JSONSerialization.jsonObject(with: Data(event.content.utf8)) as? [String: Any] else { return nil }
        self.event = event; self.fields = fields
    }
    var name: String { String((fields["name"] as? String ?? "").prefix(80)) }
    var displayName: String {
        let display = fields["display_name"] as? String ?? fields["displayName"] as? String ?? ""
        return String((display.isEmpty ? name : display).prefix(80))
    }
    var about: String { String((fields["about"] as? String ?? "").prefix(2000)) }
    var picture: URL? {
        guard let raw = fields["picture"] as? String, let url = URL(string: raw), url.scheme == "https",
              url.host != nil, url.user == nil, url.password == nil else { return nil }
        return url
    }
    static func editedContent(existing: PublishedEvent?, name: String, about: String) throws -> String {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 80, about.count <= 2000 else {
            throw PublishingError.message("Use a username of 1–80 characters and a description of up to 2,000 characters.")
        }
        // Preserve website, avatar, NIP-05, payment address and unknown fields.
        var fields: [String: Any] = [:]
        if let existing {
            guard let profile = NostrProfile(existing) else { throw PublishingError.message("This profile could not be read safely. Retry loading before editing.") }
            fields = profile.fields
        }
        fields["name"] = name; fields["display_name"] = name; fields["displayName"] = name; fields["about"] = about
        let data = try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys, .withoutEscapingSlashes])
        return String(decoding: data, as: UTF8.self)
    }
}

enum NostrSocialRules {
    /// NIP-01: latest replaceable event; lowest ID breaks equal timestamps.
    static func latest(_ events: [PublishedEvent], kind: Int) -> [String: PublishedEvent] {
        var result: [String: PublishedEvent] = [:]
        for event in events.filter({ $0.kind == kind }).sorted(by: {
            $0.created_at == $1.created_at ? $0.id < $1.id : $0.created_at > $1.created_at
        }) where result[event.pubkey] == nil { result[event.pubkey] = event }
        return result
    }
    static func follows(_ event: PublishedEvent) -> [String] {
        guard event.kind == 3 else { return [] }
        var seen = Set<String>()
        return event.tags.compactMap { tag in
            guard tag.count >= 2, tag[0] == "p", NostrEventVerifier.bytes(tag[1], count: 32) != nil,
                  tag[1] != event.pubkey, seen.insert(tag[1]).inserted else { return nil }
            return tag[1]
        }
    }
    static func network(_ lists: [PublishedEvent], roots: [String], excluding: Set<String> = [], limit: Int = 80) -> [String] {
        let currentLists = latest(lists, kind: 3)
        var counts: [String: Int] = [:]
        for root in Set(roots) {
            if let event = currentLists[root] {
                for key in follows(event) where !excluding.contains(key) { counts[key, default: 0] += 1 }
            }
        }
        return Array(counts.keys.sorted { counts[$0] == counts[$1] ? $0 < $1 : counts[$0]! > counts[$1]! }.prefix(limit))
    }
    static func parent(_ event: PublishedEvent) -> String? {
        let refs = event.tags.filter { $0.count >= 2 && $0[0] == "e" }
        if let reply = refs.last(where: { $0.count >= 4 && $0[3] == "reply" }) { return reply[1] }
        if let root = refs.first(where: { $0.count >= 4 && $0[3] == "root" }) { return root[1] }
        return refs.last(where: { $0.count < 4 || $0[3].isEmpty })?[1]
    }
}

/// Candidate sourcing only; the final relevance scores remain Needle + BM25.
actor NostrDiscovery {
    static let shared = NostrDiscovery()
    static let sourcesKey = "slowclaw.pulse.sources.v1"
    private var graphs: [String: (date: Date, direct: [String], network: [String], counts: [String: Int])] = [:]

    func posts(roots: [String], relays: [String]) async -> [PublishedEvent] {
        await result(roots: roots, relays: relays).events
    }
    struct Result { let events: [PublishedEvent]; let followCount: Int }
    func result(roots: [String], relays: [String]) async -> Result {
        let owner = roots.first
        let roots = Array(Set(roots.filter { NostrEventVerifier.bytes($0, count: 32) != nil })).sorted().prefix(9).map { $0 }
        guard !roots.isEmpty else { return .init(events: [], followCount: 0) }
        let key = (roots + relays.sorted()).joined(separator: ",")
        let direct: [String], network: [String], counts: [String: Int]
        if let cached = graphs[key], Date().timeIntervalSince(cached.date) < 6 * 3600 {
            direct = cached.direct; network = cached.network; counts = cached.counts
        } else {
            let first = await NostrConversations.shared.read(filters: roots.map { ["kinds": [3], "authors": [$0], "limit": 1] }, relays: relays)
            counts = NostrSocialRules.latest(first.events, kind: 3).mapValues { NostrSocialRules.follows($0).count }
            direct = NostrSocialRules.network(first.events, roots: roots, excluding: Set(roots), limit: 60)
            let bridges = Array(direct.prefix(12))
            let second = await NostrConversations.shared.read(filters: bridges.map { ["kinds": [3], "authors": [$0], "limit": 1] }, relays: relays)
            network = NostrSocialRules.network(second.events, roots: bridges, excluding: Set(roots + direct), limit: 40)
            if first.completed > 0 {
                if graphs.count >= 4 { graphs.removeAll() }
                graphs[key] = (Date(), direct, network, counts)
            }
        }
        // Author-specific limits prevent one prolific account filling a batch.
        // Rotate the bounded sample daily, always keeping explicit source roots.
        let day = Int(Date().timeIntervalSince1970 / 86400)
        func sample(_ values: [String], count: Int) -> [String] {
            guard !values.isEmpty else { return [] }
            let offset = day % values.count
            return Array((Array(values[offset...]) + Array(values[..<offset])).prefix(count))
        }
        let authors = roots + sample(direct, count: 10) + sample(network, count: 5)
        let since = Int(Date().addingTimeInterval(-7 * 86400).timeIntervalSince1970)
        let batch = await NostrConversations.shared.read(filters: authors.prefix(24).map {
            ["kinds": [1], "authors": [$0], "since": since, "limit": 4]
        }, relays: relays)
        return .init(events: batch.events, followCount: owner.flatMap { counts[$0] } ?? 0)
    }
}

/// A useful starting feed even before the first follow or journal. The provider
/// supplies public candidates only; no identity, persona or journal is sent.
actor NostrPopular {
    static let shared = NostrPopular()
    private var cached: [PublishedEvent] = []
    private var refreshed: Date = .distantPast
    func posts(relays: [String]) async -> [PublishedEvent] {
        if !cached.isEmpty, Date().timeIntervalSince(refreshed) < 3600 { return cached }
        let trending = await NostrConversations.shared.popularPosts()
        let notes = trending.filter { $0.kind == 1 && NostrSocialRules.parent($0) == nil }
        var authors = Set<String>()
        let roots = Array(notes.filter { authors.insert($0.pubkey).inserted }.prefix(4).map(\.pubkey))
        let network = await NostrDiscovery.shared.posts(roots: roots, relays: relays)
        var ids = Set<String>()
        let next = Array((notes + network).filter { ids.insert($0.id).inserted }.prefix(120))
        if !next.isEmpty { cached = next; refreshed = Date() }
        // An outage retains recent public discovery rather than replacing it
        // with an empty result. Old material expires after one day.
        return Date().timeIntervalSince(refreshed) < 86400 ? cached : []
    }
}
