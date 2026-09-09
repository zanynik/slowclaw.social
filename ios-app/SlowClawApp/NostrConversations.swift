import Foundation
import CryptoKit
import libsecp256k1

extension PublishedEvent: Identifiable {}

/// Verify both event ID and Schnorr signature before attributing relay content.
enum NostrEventVerifier {
    static func bytes(_ hex: String, count: Int) -> [UInt8]? {
        guard hex.utf8.count == count * 2 else { return nil }
        let chars = Array(hex.utf8)
        func digit(_ c: UInt8) -> UInt8? {
            switch c { case 48...57: return c - 48; case 97...102: return c - 87; default: return nil }
        }
        var result: [UInt8] = []
        for i in stride(from: 0, to: chars.count, by: 2) {
            guard let a = digit(chars[i]), let b = digit(chars[i + 1]) else { return nil }
            result.append(a * 16 + b)
        }
        return result
    }

    static func verify(_ event: PublishedEvent, now: Date = Date()) -> Bool {
        guard event.created_at >= 0, Double(event.created_at) <= now.timeIntervalSince1970 + 600,
              event.content.utf8.count <= 60_000, event.tags.count <= 256,
              event.tags.allSatisfy({ $0.count <= 8 && $0.allSatisfy { $0.utf8.count <= 2048 } }),
              let id = bytes(event.id, count: 32), let pubkey = bytes(event.pubkey, count: 32),
              let signature = bytes(event.sig, count: 64),
              let data = try? JSONSerialization.data(withJSONObject:
                [0, event.pubkey, event.created_at, event.kind, event.tags, event.content], options: [.withoutEscapingSlashes]),
              Array(SHA256.hash(data: data)) == id,
              let ctx = secp256k1_context_create(UInt32(SECP256K1_CONTEXT_NONE)) else { return false }
        defer { secp256k1_context_destroy(ctx) }
        var key = secp256k1_xonly_pubkey()
        return secp256k1_xonly_pubkey_parse(ctx, &key, pubkey) == 1
            && secp256k1_schnorrsig_verify(ctx, signature, id, 32, &key) == 1
    }
}

extension PublishedEvent {
    func tag(_ name: String) -> String? { tags.first { $0.count >= 2 && $0[0] == name }?[1] }
    var address: String? {
        guard kind == 30023, let d = tag("d"), !d.isEmpty else { return nil }
        return "30023:\(pubkey):\(d)"
    }
    var displayTitle: String { kind == 30023 ? (tag("title") ?? "Article") : String(content.prefix(100)) }
}

/// Pure threading rules. Mentions are not replies; emoji are not likes.
enum NostrConversationRules {
    static func belongs(_ event: PublishedEvent, to post: PublishedEvent) -> Bool {
        if event.kind == 7 {
            return event.tags.last(where: { $0.count >= 2 && $0[0] == "e" })?[1] == post.id
        }
        if event.kind == 1111, post.kind == 30023 {
            guard event.tag("K") == "30023", event.tag("P") == post.pubkey,
                  event.tag("k") != nil, event.tag("p") != nil else { return false }
            return event.tag("E") == post.id || (post.address != nil && event.tag("A") == post.address)
        }
        guard event.kind == 1, post.kind == 1 else { return false }
        let refs = event.tags.filter { $0.count >= 2 && $0[0] == "e" }
        let marked = refs.filter { $0.count >= 4 && ["root", "reply"].contains($0[3]) }
        if !marked.isEmpty { return marked.contains { $0[1] == post.id } }
        let unmarked = refs.filter { $0.count < 4 || $0[3].isEmpty }
        return unmarked.first?[1] == post.id || unmarked.last?[1] == post.id
    }

    static func replies(_ events: [PublishedEvent], to post: PublishedEvent) -> [PublishedEvent] {
        var seen = Set<String>()
        return events.filter { [1, 1111].contains($0.kind) && belongs($0, to: post) && seen.insert($0.id).inserted }
            .sorted { $0.created_at == $1.created_at ? $0.id < $1.id : $0.created_at < $1.created_at }
    }

    static func likes(_ events: [PublishedEvent], to post: PublishedEvent) -> Int {
        var authors = Set<String>()
        return events.filter { $0.kind == 7 && belongs($0, to: post) }
            .sorted { $0.created_at == $1.created_at ? $0.id < $1.id : $0.created_at > $1.created_at }
            .filter { authors.insert($0.pubkey).inserted && ["", "+"].contains($0.content) }.count
    }

    static func mergedPosts(_ events: [PublishedEvent], author: String) -> [PublishedEvent] {
        var seen = Set<String>()
        return events.filter { $0.pubkey == author && [1, 30023].contains($0.kind) }
            .sorted { $0.created_at == $1.created_at ? $0.id < $1.id : $0.created_at > $1.created_at }
            .filter { seen.insert($0.address ?? $0.id).inserted }
    }
}

/// Bounded, read-only queries to the user's configured relays. No journals,
/// inferred interests, keys or private queries enter these requests.
actor NostrConversations {
    struct Batch: Sendable { let events: [PublishedEvent]; let completed: Int; let total: Int }
    static let shared = NostrConversations()

    func fetch(author: String, posts: [PublishedEvent], relays: [String], includePosts: Bool) async -> Batch {
        guard NostrEventVerifier.bytes(author, count: 32) != nil else { return Batch(events: [], completed: 0, total: 0) }
        var filters: [[String: Any]] = []
        if includePosts { filters.append(["kinds": [1, 30023], "authors": [author], "limit": 50]) }
        let selected = Array(posts.prefix(20))
        if !selected.isEmpty {
            let ids = selected.map(\.id)
            filters.append(["kinds": [1, 7], "#e": ids, "limit": 100])
            filters.append(["kinds": [1111], "#E": ids, "limit": 100])
            let addresses = selected.compactMap(\.address)
            if !addresses.isEmpty { filters.append(["kinds": [1111], "#A": addresses, "limit": 100]) }
        }
        guard !filters.isEmpty else { return Batch(events: [], completed: 0, total: 0) }
        let sub = "sc_conversation_" + UUID().uuidString
        let request: [Any] = ["REQ", sub] + filters.map { $0 as Any }
        guard let data = try? JSONSerialization.data(withJSONObject: request),
              let wire = String(data: data, encoding: .utf8) else { return Batch(events: [], completed: 0, total: 0) }
        let urls = Array(Set(relays)).sorted().prefix(5).compactMap { raw -> URL? in
            guard let url = URL(string: raw), url.scheme == "wss", url.host != nil,
                  url.user == nil, url.password == nil else { return nil }
            return url
        }
        var seen = Set<String>(), events: [PublishedEvent] = [], completed = 0
        await withTaskGroup(of: (events: [PublishedEvent], completed: Bool).self) { group in
            for url in urls { group.addTask { await Self.query(url, wire: wire, subscription: sub) } }
            for await result in group {
                if result.completed { completed += 1 }
                for event in result.events where seen.insert(event.id).inserted {
                    if (includePosts && event.pubkey == author && [1, 30023].contains(event.kind))
                        || selected.contains(where: { NostrConversationRules.belongs(event, to: $0) }) {
                        events.append(event)
                    }
                }
            }
        }
        return Batch(events: events, completed: completed, total: urls.count)
    }

    nonisolated private static func query(_ url: URL, wire: String, subscription: String) async -> (events: [PublishedEvent], completed: Bool) {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        let session = URLSession(configuration: config)
        let socket = session.webSocketTask(with: url)
        socket.maximumMessageSize = 128_000
        socket.resume()
        let timeout = Task {
            do { try await Task.sleep(for: .seconds(10)) } catch { return }
            socket.cancel(with: .goingAway, reason: nil)
        }
        defer { timeout.cancel(); socket.cancel(with: .normalClosure, reason: nil); session.invalidateAndCancel() }
        var events: [PublishedEvent] = []
        do {
            try await socket.send(.string(wire))
            for _ in 0..<320 {
                try Task.checkCancellation()
                let message = try await socket.receive()
                let data: Data
                switch message { case .string(let text): data = Data(text.utf8); case .data(let bytes): data = bytes; @unknown default: continue }
                guard data.count <= 128_000, let frame = try JSONSerialization.jsonObject(with: data) as? [Any],
                      frame.count >= 2, frame[1] as? String == subscription else { continue }
                if frame[0] as? String == "EOSE" { return (events, true) }
                guard frame[0] as? String == "EVENT", frame.count >= 3,
                      let raw = try? JSONSerialization.data(withJSONObject: frame[2]),
                      let event = try? JSONDecoder().decode(PublishedEvent.self, from: raw),
                      [1, 7, 1111, 30023].contains(event.kind), NostrEventVerifier.verify(event) else { continue }
                events.append(event)
            }
        } catch { /* Partial results remain usable; the UI reports incomplete coverage. */ }
        return (events, false)
    }
}
