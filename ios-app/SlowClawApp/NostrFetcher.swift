// NostrFetcher.swift — client-side Nostr long-form articles (NIP-23) for Reads.
//
// The reference app fetches kind 30023 (NIP-23) articles from the default
// relays and renders them in Reads via habla.news links (web/src/lib/nostr.ts
// fetchLongFormArticles + socialFeed.ts toUnifiedFromNostrArticle). The iOS
// app doesn't embed the Rust gateway, so this does the same fetch client-side
// via URLSessionWebSocketTask.
//
// Output is [RankedFeedItem] with sourcePlatform = "nostr", so the existing
// ranker/FeedCard handle them uniformly. Articles get a neutral recency score
// (the Zig ranker scores RSS topic-matches higher; Nostr articles arrive
// pre-filtered to well-formed NIP-23, so they rank on recency + topic overlap
// resolved later by sort).

import Foundation

enum NostrFetcher {
    /// The relays the reference app uses (web/src/lib/nostr.ts DEFAULT_RELAYS).
    static let relays = [
        "wss://relay.damus.io",
        "wss://nos.lol",
        "wss://relay.nostr.band",
    ]

    /// Fetch up to ~20 recent long-form articles (kind 30023) with a title tag
    /// and >200-char body. Tolerates partial relay failures; 8s timeout each.
    static func fetchArticles() async -> [RankedFeedItem] {
        var seen = Set<String>()
        var events: [[String: Any]] = []
        // Fan out to all relays concurrently; merge results.
        await withTaskGroup(of: [[String: Any]]?.self) { group in
            for url in relays {
                group.addTask { await queryRelay(url, kinds: [30023], limit: 50) }
            }
            for await batch in group {
                guard let batch else { continue }
                for ev in batch {
                    if let id = ev["id"] as? String, seen.insert(id).inserted {
                        events.append(ev)
                    }
                }
            }
        }

        // Client filter (mirrors fetchLongFormArticles): title tag + >200 body.
        let articles = events.compactMap { Article(event: $0) }
            .filter { $0.title != nil && $0.body.count > 200 }
            .sorted { $0.createdAt > $1.createdAt }
            .prefix(20)

        // Score: simple recency curve (newest = highest), so articles sort
        // alongside RSS items by the unified sort in AppState.loadReads.
        let now = Date().timeIntervalSince1970
        return articles.enumerated().map { idx, art in
            let ageHours = max(0, (now - art.createdAt) / 3600)
            // Half-life ~72h, baseline so articles stay visible early.
            let score = 1.0 + 0.5 * pow(0.5, ageHours / 72.0) - Double(idx) * 0.001
            let minutes = max(1, art.body.count / 900) // ~150 wpm-ish
            return RankedFeedItem(
                id: "nostr:\(art.identifier)",
                title: art.title ?? "Untitled",
                link: art.hablaURL,
                description: art.summary.isEmpty ? String(art.body.prefix(280)) : art.summary,
                sourceLabel: "Nostr",
                score: score,
                readMinutes: minutes,
                sourcePlatform: "nostr",
                thumbnailURL: art.image
            )
        }
    }

    // MARK: - Relay query

    /// Open a WebSocket to one relay, send a REQ for `kinds`/`limit`, collect
    /// EVENT frames until EOSE or timeout. Returns nil on any failure.
    private static func queryRelay(_ urlString: String, kinds: [Int], limit: Int) async -> [[String: Any]]? {
        guard let url = URL(string: urlString) else { return nil }
        let task = URLSession.shared.webSocketTask(with: url)
        task.resume()
        defer { task.cancel(with: .goingAway, reason: nil) }

        let subID = "sc_\(UInt32.random(in: 0..<1_000_000))"
        let req: [Any] = ["REQ", subID, ["kinds": kinds, "limit": limit]]
        guard let reqData = try? JSONSerialization.data(withJSONObject: req),
              let reqStr = String(data: reqData, encoding: .utf8) else { return nil }
        guard (try? await task.send(.string(reqStr))) != nil else { return nil }

        var collected: [[String: Any]] = []
        let deadline = Date().addingTimeInterval(8)
        while Date() < deadline {
            // Drain with a short per-message timeout via Task racing.
            guard let msg = await nextMessage(task, by: deadline) else { break }
            switch msg {
            case .string(let text):
                guard let arr = parseJSONArray(text), arr.count >= 2,
                      let kind = arr[0] as? String else { continue }
                if kind == "EOSE" { break }
                if kind == "EVENT", let ev = arr[2] as? [String: Any] {
                    collected.append(ev)
                }
            case .data:
                continue
            @unknown default:
                continue
            }
            if collected.count >= limit * 2 { break }
        }
        return collected
    }

    /// Race one WebSocket receive against a deadline so we never hang.
    private static func nextMessage(_ task: URLSessionWebSocketTask, by deadline: Date) async -> URLSessionWebSocketTask.Message? {
        await withTaskGroup(of: URLSessionWebSocketTask.Message?.self, returning: URLSessionWebSocketTask.Message?.self) { group in
            group.addTask { try? await task.receive() }
            group.addTask {
                let remain = max(0, deadline.timeIntervalSinceNow)
                try? await Task.sleep(nanoseconds: UInt64(remain * 1_000_000_000))
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    private static func parseJSONArray(_ s: String) -> [Any]? {
        guard let data = s.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [Any]
    }

    // MARK: - Article model

    /// A parsed NIP-23 article event.
    private struct Article {
        let identifier: String      // event id (hex) — used for the habla fallback link
        let pubkey: String          // event author pubkey (hex) — used for the naddr link
        let dTag: String            // NIP-33 "d" identifier — used for the naddr link
        let title: String?
        let summary: String
        let image: String?
        let body: String
        let createdAt: TimeInterval

        init?(event: [String: Any]) {
            guard let id = event["id"] as? String else { return nil }
            identifier = id
            // The author pubkey is a top-level field on every Nostr event.
            // The naddr's author TLV (type 2) MUST be this 32-byte pubkey,
            // NOT the event id — otherwise habla.news decodes a valid bech32
            // string that points at a nonexistent (pubkey, kind, d) → 404.
            pubkey = (event["pubkey"] as? String) ?? ""
            body = (event["content"] as? String) ?? ""
            createdAt = (event["created_at"] as? Double) ?? (event["created_at"] as? Int).map(Double.init) ?? 0
            var d = "", t: String?, sum = "", img: String?
            if let tags = event["tags"] as? [[Any]] {
                for tag in tags {
                    guard tag.count >= 2, let name = tag[0] as? String else { continue }
                    let val = (tag[1] as? String) ?? ""
                    switch name {
                    case "d": d = val
                    case "title": t = val.isEmpty ? nil : val
                    case "summary": sum = val
                    case "image": img = val.isEmpty ? nil : val
                    default: break
                    }
                }
            }
            dTag = d
            title = t
            summary = sum
            image = img
        }

        /// habla.news link, preferring a naddr-encoded address (mirrors
        /// encodeNaddr in web/src/lib/nostr.ts, which encodes the author
        /// PUBKEY — not the event id). Falls back to the hex event id.
        var hablaURL: String {
            if !dTag.isEmpty, !pubkey.isEmpty,
               let naddr = Nip19.encodeNaddr(identifier: dTag, pubkey: pubkey, kind: 30023) {
                return "https://habla.news/a/\(naddr)"
            }
            return "https://habla.news/a/\(identifier)"
        }
    }
}
