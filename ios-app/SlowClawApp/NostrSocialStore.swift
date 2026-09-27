import Foundation
import Combine

@MainActor
final class NostrSocialStore: ObservableObject {
    static let shared = NostrSocialStore()
    @Published private(set) var profiles: [String: PublishedEvent] = [:]
    @Published private(set) var events: [String: [PublishedEvent]] = [:]
    @Published private(set) var coverage: [String: String] = [:]
    private var loaded: [String: Date] = [:]
    private var profileLoaded: [String: Date] = [:]
    private var loading = Set<String>()
    private var loadingProfiles = Set<String>()
    static var relays: [String] { NostrPublisher.relayText.split(whereSeparator: { $0.isWhitespace }).map(String.init) }

    init(defaults: UserDefaults = .standard) {
        if let data = defaults.data(forKey: "slowclaw.nostr.profiles.v1"), data.count <= 4_000_000,
           let cached = try? JSONDecoder().decode([PublishedEvent].self, from: data) {
            profiles = NostrSocialRules.latest(cached.prefix(200).filter { NostrEventVerifier.verify($0) }, kind: 0)
        }
    }
    func profile(_ key: String) -> NostrProfile? { profiles[key].flatMap(NostrProfile.init) }
    func name(_ key: String) -> String {
        if let name = profile(key)?.displayName, !name.isEmpty { return name }
        return String(key.prefix(8)) + "…" + String(key.suffix(4))
    }
    func mergeProfiles(_ incoming: [PublishedEvent]) {
        profiles = NostrSocialRules.latest(Array(profiles.values) + incoming.filter { $0.kind == 0 && NostrEventVerifier.verify($0) }, kind: 0)
        let recent = Array(profiles.values.sorted { $0.created_at > $1.created_at }.prefix(200))
        profiles = NostrSocialRules.latest(recent, kind: 0)
        if let data = try? JSONEncoder().encode(recent) { UserDefaults.standard.set(data, forKey: "slowclaw.nostr.profiles.v1") }
    }
    func loadProfiles(_ authors: [String], force: Bool = false) async {
        let keys = Array(Set(authors)).sorted().filter { key in
            !loadingProfiles.contains(key) && (force || Date().timeIntervalSince(profileLoaded[key] ?? .distantPast) > 3600)
        }
        guard !keys.isEmpty else { return }
        loadingProfiles.formUnion(keys)
        defer { loadingProfiles.subtract(keys) }
        for offset in stride(from: 0, to: min(keys.count, 80), by: 8) {
            let batchKeys = Array(keys.dropFirst(offset).prefix(8))
            let batch = await NostrConversations.shared.read(filters: batchKeys.map { ["kinds": [0], "authors": [$0], "limit": 1] }, relays: Self.relays)
            mergeProfiles(batch.events)
            if batch.completed > 0 { for key in batchKeys { profileLoaded[key] = Date() } }
        }
    }
    func load(_ posts: [PublishedEvent], force: Bool = false) async {
        let posts = Array(posts.prefix(40))
        async let authorProfiles: Void = loadProfiles(posts.map(\.pubkey))
        for offset in stride(from: 0, to: posts.count, by: 3) {
            let selected = Array(posts.dropFirst(offset).prefix(3)).filter {
                !loading.contains($0.id) && (force || Date().timeIntervalSince(loaded[$0.id] ?? .distantPast) > 120)
            }
            guard !selected.isEmpty else { continue }
            loading.formUnion(selected.map(\.id))
            // Each post gets its own filters so a viral post cannot crowd out others.
            let filters: [[String: Any]] = selected.flatMap { post -> [[String: Any]] in
                var result: [[String: Any]] = [["kinds": [7], "#e": [post.id], "limit": 60]]
                if post.kind == 30023 {
                    result.append(["kinds": [1111], "#E": [post.id], "limit": 30])
                    if let address = post.address { result.append(["kinds": [1111], "#A": [address], "limit": 30]) }
                } else { result.append(["kinds": [1], "#e": [post.id], "limit": 30]) }
                return result
            }
            let batch = await NostrConversations.shared.read(filters: filters, relays: Self.relays)
            record(batch, posts: selected)
            loading.subtract(selected.map(\.id))
            await loadProfiles(batch.events.filter { [1, 1111].contains($0.kind) }.map(\.pubkey))
        }
        await authorProfiles
        if events.count > 100 {
            let keep = Set(loaded.sorted { $0.value > $1.value }.prefix(80).map(\.key)).union(posts.map(\.id))
            events = events.filter { keep.contains($0.key) }; coverage = coverage.filter { keep.contains($0.key) }
            loaded = loaded.filter { keep.contains($0.key) }
        }
    }
    func record(_ batch: NostrConversations.Batch, posts: [PublishedEvent]) {
        for post in posts {
            let incoming = batch.events.filter { NostrConversationRules.belongs($0, to: post) }
            var seen = Set<String>()
            // Failed requests preserve the previous snapshot, including unknown counts.
            if batch.completed > 0 || !incoming.isEmpty {
                events[post.id] = Array((incoming + (events[post.id] ?? [])).sorted { $0.created_at > $1.created_at }
                    .filter { seen.insert($0.id).inserted }.prefix(300))
            }
            coverage[post.id] = batch.completed == 0 ? "Couldn’t finish loading. Tap to retry."
                : "Counts cover fetched events from \(batch.completed) of \(batch.total) relays; more may exist."
            if batch.completed > 0 { loaded[post.id] = Date() }
        }
    }
    func replies(_ post: PublishedEvent, hidden: Set<String>) -> [PublishedEvent] {
        NostrConversationRules.replies((events[post.id] ?? []).filter { !hidden.contains($0.pubkey) && ReadsContentFilter.isAllowed($0.content) && !$0.tags.contains(where: { $0.first == "content-warning" }) }, to: post)
    }
}
