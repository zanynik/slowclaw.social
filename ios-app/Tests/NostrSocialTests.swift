import XCTest
import CryptoKit
@testable import Runtime

final class NostrSocialTests: XCTestCase {
    private func event(_ kind: Int, author: UInt8 = 1, date: Int = 1, tags: [[String]] = [], content: String = "") throws -> PublishedEvent {
        let secret = Array(repeating: UInt8(0), count: 31) + [author]
        let key = try NostrIdentity.publicKey(secret)
        let data = try JSONSerialization.data(withJSONObject: [0, key, date, kind, tags, content], options: [.withoutEscapingSlashes])
        let hash = Array(SHA256.hash(data: data))
        return PublishedEvent(id: NostrIdentity.hex(hash), pubkey: key, created_at: date, kind: kind, tags: tags, content: content, sig: try NostrIdentity.sign(hash: hash, secret: secret))
    }
    func testColdStartNeedsNoFollowsAndRetainsPopularCandidates() {
        func item(_ n: Int) -> RankedFeedItem {
            .init(id: "nostr:\(n)", title: "SlowClaw sample", link: "https://example.com/\(n)", description: "Public observation",
                sourceLabel: "Nostr posts", score: 1, readMinutes: 1, sourcePlatform: "nostr")
        }
        let popular = (0..<40).map(item), global = (30..<70).map(item)
        let cold = NostrFetcher.blendPosts(network: [], popular: popular, global: global)
        XCTAssertEqual(cold.count, 40)
        XCTAssertEqual(Array(cold.prefix(32).map(\.id)), Array(popular.prefix(32).map(\.id)))
        XCTAssertEqual(Set(cold.map(\.id)).count, cold.count)
        let fallback = NostrFetcher.blendPosts(network: [], popular: [], global: global)
        XCTAssertEqual(fallback.map(\.id), global.map(\.id))
        let personal = (100..<140).map(item)
        let warm = NostrFetcher.blendPosts(network: personal, popular: popular, global: global)
        XCTAssertEqual(Array(warm.prefix(24).map(\.id)), Array(personal.prefix(24).map(\.id)))
        XCTAssertTrue(warm.contains { $0.id == popular[0].id })
        let small = NostrFetcher.blendPosts(network: personal, popular: popular, global: global, followCount: 5)
        XCTAssertEqual(small.filter { personal.map(\.id).contains($0.id) }.count, 8)
        XCTAssertEqual(Array(small.dropFirst(8).prefix(28).map(\.id)), Array(popular.prefix(28).map(\.id)))
        let middle = NostrFetcher.blendPosts(network: personal, popular: popular, global: global, followCount: 50)
        XCTAssertEqual(middle.filter { personal.map(\.id).contains($0.id) }.count, 16)
        let mature = NostrFetcher.blendPosts(network: personal, popular: popular, global: global, followCount: 1000)
        XCTAssertEqual(mature.filter { personal.map(\.id).contains($0.id) }.count, 24)
        XCTAssertEqual(Array(mature.dropFirst(24).prefix(12).map(\.id)), Array(popular.prefix(12).map(\.id)))
    }
    func testPublicKeyParsingNeverAcceptsNsec() throws {
        let bytes = Array(repeating: UInt8(1), count: 32)
        let key = NostrIdentity.hex(bytes)
        XCTAssertEqual(Nip19.decodePublicKey(Nip19.encodeKey(bytes, prefix: "npub")), key)
        XCTAssertEqual(Nip19.decodePublicKey("nostr:" + Nip19.encodeKey(bytes, prefix: "npub")), key)
        XCTAssertNil(Nip19.decodePublicKey(Nip19.encodeKey(bytes, prefix: "nsec")))
        XCTAssertNil(Nip19.decodePublicKey("npub1bad"))
    }
    func testNetworkUsesNewestListsUniqueEndorsementsAndExclusions() throws {
        let a = String(repeating: "a", count: 64), b = String(repeating: "b", count: 64)
        let old = try event(3, tags: [["p", b]])
        let newer = try event(3, date: 2, tags: [["p", a], ["p", a], ["p", "invalid"]])
        let other = try event(3, author: 2, tags: [["p", a], ["p", b]])
        let roots = [newer.pubkey, other.pubkey]
        XCTAssertEqual(NostrSocialRules.network([old, newer, other], roots: roots), [a, b])
        XCTAssertEqual(NostrSocialRules.network([newer, other], roots: roots, excluding: [a]), [b])
        let empty = try event(3, date: 3)
        XCTAssertEqual(NostrSocialRules.network([old, newer, empty], roots: [newer.pubkey]), [])
    }
    func testProfileEditsPreserveUnknownMetadataAndReplaceableOrdering() throws {
        let first = try event(0, content: #"{"name":"slowclaw_user","about":"old","picture":"https://example.com/avatar.png","lud16":"slowclaw_user@example.com","custom":{"enabled":true}}"#)
        let content = try NostrProfile.editedContent(existing: first, name: "slowclaw_agent", about: "A new description")
        let updated = try event(0, date: 2, content: content)
        let profile = try XCTUnwrap(NostrProfile(updated))
        XCTAssertEqual(profile.name, "slowclaw_agent")
        XCTAssertEqual(profile.about, "A new description")
        XCTAssertEqual(profile.fields["lud16"] as? String, "slowclaw_user@example.com")
        XCTAssertEqual(profile.fields["custom"] as? [String: Bool], ["enabled": true])
        XCTAssertEqual(NostrSocialRules.latest([updated, first], kind: 0)[first.pubkey]?.id, updated.id)
        XCTAssertThrowsError(try NostrProfile.editedContent(existing: first, name: " ", about: ""))
    }
    func testRelayFiltersRejectWrongAuthorsTargetsAndKinds() throws {
        let note = try event(1, tags: [["e", "target", "", "root"]])
        XCTAssertTrue(NostrConversations.matches(note, filter: ["kinds": [1], "authors": [note.pubkey], "#e": ["target"]]))
        XCTAssertFalse(NostrConversations.matches(note, filter: ["kinds": [0]]))
        XCTAssertFalse(NostrConversations.matches(note, filter: ["authors": ["other"]]))
        XCTAssertFalse(NostrConversations.matches(note, filter: ["#e": ["other"]]))
    }
    @MainActor func testThreadSnapshotsDeduplicateAndSurviveRelayFailure() throws {
        let root = try event(1, content: "SlowClaw garden observation")
        let reply = try event(1, author: 2, tags: [["e", root.id, "", "root"]], content: "SlowClaw garden reply")
        let like = try event(7, author: 2, tags: [["e", root.id]], content: "+")
        let mention = try event(1, author: 3, tags: [["e", root.id, "", "mention"]], content: "Not a reply")
        let defaults = UserDefaults(suiteName: "slowclaw-social-test-" + UUID().uuidString)!
        let store = NostrSocialStore(defaults: defaults)
        store.record(.init(events: [reply, reply, like, mention], completed: 1, total: 2), posts: [root])
        XCTAssertEqual(store.replies(root, hidden: []).map(\.id), [reply.id])
        XCTAssertEqual(NostrConversationRules.likes(store.events[root.id]!, to: root), 1)
        store.record(.init(events: [], completed: 0, total: 2), posts: [root])
        XCTAssertEqual(store.replies(root, hidden: []).count, 1)
        XCTAssertTrue(store.replies(root, hidden: [reply.pubkey]).isEmpty)
        XCTAssertNil(NostrSocialRules.parent(mention))
        XCTAssertEqual(NostrSocialRules.parent(reply), root.id)
    }
    func testMediaURLsUseMimeHintsDeduplicateAndKeepSignedQueries() {
        let image = "https://example.com/photo.jpg?signature=keep-me"
        let hinted = "https://example.com/opaque?token=unchanged"
        let values = NostrContent.attachments("See \(image) and https://example.com/movie.mp4 and https://example.com/sound.mp3 and https://example.com/article", tags: [
            ["imeta", "url " + image, "m image/jpeg"], ["imeta", "url " + hinted, "m video/mp4"]])
        XCTAssertEqual(values.map(\.kind), [.image, .video, .audio, .link, .video])
        XCTAssertEqual(values[0].url.absoluteString, image)
        XCTAssertEqual(values.last?.url.absoluteString, hinted)
        XCTAssertTrue(NostrContent.attachments("https://user:pass@example.com/private http://example.com/plain file:///tmp/local").isEmpty)
        XCTAssertEqual(NostrContent.attachments((0..<20).map { "https://example.com/\($0).jpg" }.joined(separator: " ")).count, 8)
    }
    func testFollowChangesPreserveExistingContactsAndUnknownTags() throws {
        let target = try event(1, author: 2).pubkey, other = try event(1, author: 3).pubkey
        let initial = try event(3, tags: [["p", other, "wss://example.com", "slowclaw_user"], ["custom", "keep"]])
        let followed = try NostrSocialRules.followTags(existing: initial, owner: initial.pubkey, target: target, following: true)
        XCTAssertEqual(Array(followed.prefix(2)), initial.tags)
        XCTAssertEqual(followed.last, ["p", target, ""])
        let current = try event(3, date: 2, tags: followed)
        XCTAssertEqual(try NostrSocialRules.followTags(existing: current, owner: current.pubkey, target: target, following: true), followed)
        XCTAssertEqual(try NostrSocialRules.followTags(existing: current, owner: current.pubkey, target: target, following: false), initial.tags)
        XCTAssertThrowsError(try NostrSocialRules.followTags(existing: initial, owner: other, target: target, following: true))
    }
    @MainActor func testAuthorTimelineKeepsPriorPostsOnOutageAndFiltersOtherAuthors() throws {
        let own = try event(1, content: "SlowClaw public observation"), other = try event(1, author: 2)
        let store = NostrSocialStore(defaults: UserDefaults(suiteName: "slowclaw-author-test-" + UUID().uuidString)!)
        store.recordAuthor(.init(events: [own, own, other], completed: 1, total: 1), key: own.pubkey)
        XCTAssertEqual(store.authorPosts[own.pubkey]?.map(\.id), [own.id])
        store.recordAuthor(.init(events: [], completed: 0, total: 1), key: own.pubkey)
        XCTAssertEqual(store.authorPosts[own.pubkey]?.map(\.id), [own.id])
        XCTAssertFalse(NostrConversations.matches(own, filter: ["until": 0]))
    }

}
