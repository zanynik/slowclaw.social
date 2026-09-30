import Foundation
import Combine

@MainActor
final class NostrSocialStore: ObservableObject {
    static let shared = NostrSocialStore()
    @Published private(set) var profiles: [String: PublishedEvent] = [:]
    @Published private(set) var events: [String: [PublishedEvent]] = [:]
    @Published private(set) var authorPosts: [String: [PublishedEvent]] = [:]
    @Published private(set) var authorStatus: [String: String] = [:]
    @Published private(set) var followList: PublishedEvent?
    @Published private(set) var followsReady = false
    @Published private(set) var followBusy = false
    @Published private(set) var followStatus: String?
    private var followOwner: String?
    private var loadingAuthors = Set<String>()
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
    func loadAuthor(_ key: String, before: Int? = nil) async {
        guard NostrEventVerifier.bytes(key, count: 32) != nil, !loadingAuthors.contains(key) else { return }
        loadingAuthors.insert(key)
        defer { loadingAuthors.remove(key) }
        var filter: [String: Any] = ["kinds": [1, 30023], "authors": [key], "limit": 30]
        if let before { filter["until"] = before }
        async let profile: Void = loadProfiles([key])
        let batch = await NostrConversations.shared.read(filters: [filter], relays: Self.relays)
        recordAuthor(batch, key: key)
        await profile
    }
    func recordAuthor(_ batch: NostrConversations.Batch, key: String) {
        let incoming = batch.events.filter {
            $0.pubkey == key && [1, 30023].contains($0.kind) && NostrEventVerifier.verify($0)
                && ReadsContentFilter.isAllowed($0.content) && !$0.tags.contains(where: { $0.first == "content-warning" })
        }
        authorPosts[key] = Array(NostrConversationRules.mergedPosts(incoming + (authorPosts[key] ?? []), author: key).prefix(120))
        if authorPosts.count > 40, let evicted = authorPosts.keys.filter({ $0 != key }).sorted().first {
            authorPosts.removeValue(forKey: evicted); authorStatus.removeValue(forKey: evicted)
        }
        authorStatus[key] = batch.completed == 0 ? "Couldn’t load posts. Pull to retry." : incoming.isEmpty ? "No more posts found on these relays." : nil
    }
    func isFollowing(_ key: String) -> Bool { followList.map { NostrSocialRules.follows($0).contains(key) } ?? false }
    func loadFollows() async {
        followsReady = false
        do {
            let owner = try NostrIdentity.publicKey(NostrIdentity.secret())
            if followOwner != owner { followList = nil; followOwner = owner }
            let relays = Array(Set(Self.relays))
            guard !relays.isEmpty, relays.count <= 5 else { throw PublishingError.message("Choose one to five relays in your publishing settings.") }
            let batch = await NostrConversations.shared.read(filters: [["kinds": [3], "authors": [owner], "limit": 1]], relays: relays)
            // Never overwrite a partially loaded list with just one new follow.
            guard batch.completed == relays.count else { throw PublishingError.message("Couldn’t check the full follow list. Retry before changing it.") }
            let local = NostrPublisher.confirmedEvents().filter { $0.pubkey == owner && $0.kind == 3 && NostrEventVerifier.verify($0) }
            followList = NostrSocialRules.latest(batch.events + local + (followList.map { [$0] } ?? []), kind: 3)[owner]
            followsReady = true; followStatus = nil
        } catch { followStatus = error.localizedDescription }
    }
    func setFollowing(_ key: String, following: Bool) async throws {
        guard !followBusy else { throw PublishingError.message("A follow update is already in progress.") }
        followBusy = true
        defer { followBusy = false }
        await loadFollows()
        guard followsReady, let owner = followOwner else { throw PublishingError.message(followStatus ?? "Load your follow list first.") }
        let tags = try NostrSocialRules.followTags(existing: followList, owner: owner, target: key, following: following)
        if tags == followList?.tags { return }
        let id = try await NostrPublisher.shared.publish(draftKey: "follow-list-" + owner,
            content: followList?.content ?? "", title: "", article: false,
            metadataAfter: followList?.created_at, followTags: tags)
        guard let confirmed = NostrPublisher.confirmedEvents().first(where: { $0.id == id && $0.kind == 3 }) else {
            throw PublishingError.message("Could not find the confirmed follow update. Reload to check it.")
        }
        followList = confirmed; followStatus = nil
        await NostrDiscovery.shared.invalidate()
    }
    func replies(_ post: PublishedEvent, hidden: Set<String>) -> [PublishedEvent] {
        NostrConversationRules.replies((events[post.id] ?? []).filter { !hidden.contains($0.pubkey) && ReadsContentFilter.isAllowed($0.content) && !$0.tags.contains(where: { $0.first == "content-warning" }) }, to: post)
    }
}
