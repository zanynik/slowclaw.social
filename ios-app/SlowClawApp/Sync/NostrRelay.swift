import Foundation

// Reading public events from Nostr relays (NIP-01) with Apple's own WebSocket client.
// Nothing is published from here: one request goes out, events come back, the socket closes.

/// A signed event as relays send it.
struct NostrEvent: Hashable, Sendable {
    var id: String
    var pubkey: String
    var createdAt: Int
    var kind: Int
    var tags: [[String]]
    var content: String
    var sig: String

    /// First value of the tag called `name` (for example "d", "title", "summary").
    func tag(_ name: String) -> String? {
        tags.first { $0.count > 1 && $0[0] == name }?[1]
    }

    /// True when the id is the hash of the event and the signature is the author's.
    /// Relays are not trusted: anything that fails this is dropped.
    var isValid: Bool {
        let hash = NostrIdentity.eventID(pubkey: pubkey, createdAt: createdAt, kind: kind, tags: tags, content: content)
        return Hex.string(hash) == id && NostrIdentity.verify(signature: sig, hash: hash, publicKey: pubkey)
    }
}

extension NostrEvent {
    init?(json o: [String: Any]) {
        guard let id = o["id"] as? String, let pubkey = o["pubkey"] as? String,
              let createdAt = o["created_at"] as? Int, let kind = o["kind"] as? Int,
              let tags = o["tags"] as? [[String]], let content = o["content"] as? String,
              let sig = o["sig"] as? String else { return nil }
        self.init(id: id, pubkey: pubkey, createdAt: createdAt, kind: kind, tags: tags, content: content, sig: sig)
    }
}

/// What to ask a relay for.
struct NostrFilter: Sendable {
    var kinds: [Int]
    var authors: [String]
    var since: Int? = nil
    var limit: Int? = nil

    var json: [String: Any] {
        var o: [String: Any] = ["kinds": kinds, "authors": authors]
        if let since { o["since"] = since }
        if let limit { o["limit"] = limit }
        return o
    }
}

enum NostrRelay {
    /// Sends one request and collects events until the relay has no more stored ones (EOSE),
    /// the timeout passes or `maxEvents` arrive. Failures return what was received so far.
    static func fetch(relay: URL, filters: [NostrFilter], timeout: TimeInterval = 12, maxEvents: Int = 1500) async -> [NostrEvent] {
        var message: [Any] = ["REQ", Hex.random(8)]
        message.append(contentsOf: filters.map(\.json))
        guard let data = try? JSONSerialization.data(withJSONObject: message),
              let request = String(data: data, encoding: .utf8) else { return [] }

        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        let session = URLSession(configuration: config)
        let socket = session.webSocketTask(with: relay)
        socket.maximumMessageSize = 4_000_000
        socket.resume()
        // receive() has no timeout of its own: closing the socket ends the loop below.
        let deadline = Task {
            try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            socket.cancel(with: .goingAway, reason: nil)
        }
        defer {
            deadline.cancel()
            socket.cancel(with: .goingAway, reason: nil)
            session.invalidateAndCancel()
        }

        var events: [NostrEvent] = []
        do {
            try await socket.send(.string(request))
            while events.count < maxEvents {
                let incoming = try await socket.receive()
                guard case .string(let text) = incoming,
                      let array = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [Any],
                      let type = array.first as? String else { continue }
                if type == "EVENT", array.count >= 3, let object = array[2] as? [String: Any] {
                    if let event = NostrEvent(json: object) { events.append(event) }
                } else if type == "EOSE" || type == "CLOSED" {
                    break
                }
            }
        } catch {
            // Offline, refused or timed out: keep what arrived.
        }
        return events
    }

    /// The same request to several relays at once, merged and with duplicate events removed.
    static func fetch(relays: [String], filters: [NostrFilter]) async -> [NostrEvent] {
        var seen = Set<String>()
        var out: [NostrEvent] = []
        await withTaskGroup(of: [NostrEvent].self) { group in
            for relay in relays {
                guard let url = URL(string: relay) else { continue }
                group.addTask { await fetch(relay: url, filters: filters) }
            }
            for await events in group {
                for e in events where seen.insert(e.id).inserted { out.append(e) }
            }
        }
        return out
    }
}

/// NIP-19 identifiers used for links and for adding a writer.
enum NostrLink {
    /// `naddr1…` for an addressable event (kind, author, `d` tag), so any Nostr reader can open it.
    static func naddr(kind: Int, pubkey: String, identifier: String) -> String? {
        let d = Array(identifier.utf8)
        guard let author = Hex.bytes(pubkey), author.count == 32, d.count <= 255, kind >= 0 else { return nil }
        var bytes: [UInt8] = [0, UInt8(d.count)]
        bytes += d
        bytes += [2, 32]
        bytes += author
        bytes += [3, 4, UInt8((kind >> 24) & 0xff), UInt8((kind >> 16) & 0xff), UInt8((kind >> 8) & 0xff), UInt8(kind & 0xff)]
        return Bech32.encode(bytes, prefix: "naddr")
    }

    /// Hex public key from an `npub1…` (optionally pasted as a link or with `nostr:`) or 64 hex characters.
    static func publicKey(from input: String) -> String? {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if value.count == 64, Hex.bytes(value) != nil { return value }
        guard let r = value.range(of: "npub1[a-z0-9]{58}", options: .regularExpression),
              let bytes = Bech32.decode(String(value[r]), prefix: "npub") else { return nil }
        return Hex.string(bytes)
    }
}
