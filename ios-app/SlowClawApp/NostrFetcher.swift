// NostrFetcher.swift — client-side Nostr long-form articles (NIP-23) for Reads.
//
// The reference app fetched kind 30023 (NIP-23) articles from the default
// relays and rendered them in Reads via habla.news links (web/src/lib/nostr.ts
// fetchLongFormArticles + socialFeed.ts toUnifiedFromNostrArticle). habla.news
// has since gone offline (the domain now serves a Vercel DEPLOYMENT_NOT_FOUND
// — every /a/<naddr> link 404s), so article URLs point at highlighter.com —
// a living long-form Nostr reader that resolves naddr links server-side.
// The iOS app doesn't embed a gateway, so this does the same fetch
// client-side via URLSessionWebSocketTask.
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
    static func fetchArticles(topics: [String]) async -> [RankedFeedItem] {
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

        // Port the pre-pivot React feed's admission step before ranking:
        // language/script, obvious spam and content warnings, plus a per-author
        // cap. A global relay feed is otherwise dominated by bot traffic.
        let articles = filterArticles(events.compactMap { Article(event: $0) })

        // Score: simple recency curve (newest = highest), so articles sort
        // alongside RSS items by the unified sort in AppState.loadReads.
        let now = Date().timeIntervalSince1970
        return articles.enumerated().map { idx, art in
            let ageHours = max(0, (now - art.createdAt) / 3600)
            // Journal relevance dominates recency, matching the Reads ranker.
            let score = 1.0 + 0.5 * pow(0.5, ageHours / 72.0)
                + topicBoost(article: art, topics: topics) - Double(idx) * 0.001
            let minutes = max(1, art.body.count / 900) // ~150 wpm-ish
            return RankedFeedItem(
                id: "nostr:\(art.identifier)",
                title: art.title ?? "Untitled",
                link: art.articleURL,
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
        recvLoop: while Date() < deadline {
            // Drain with a short per-message timeout via Task racing.
            guard let msg = await nextMessage(task, by: deadline) else { break }
            switch msg {
            case .string(let text):
                switch admitFrame(text, subID: subID, kinds: kinds) {
                case .eose:
                    // `break` alone would only exit this switch — label the
                    // loop so EOSE ends the receive immediately.
                    break recvLoop
                case .event(var ev):
                    // Type-1 NIP-19 relay hints give the reader a concrete
                    // location for an article it has not indexed yet.
                    ev["slowclaw_relay"] = urlString
                    collected.append(ev)
                case .ignore:
                    break
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

    /// Outcome of admitting one relay text frame.
    private enum RelayFrame {
        case eose                    // our subscription is done
        case event([String: Any])    // admitted EVENT payload for our sub
        case ignore                  // foreign sub / malformed / other kind
    }

    /// Parse one relay text frame against our subscription id. Enforces the
    /// frame shape (element count checked BEFORE indexing — a 2-element
    /// `["EVENT", <subid>]` frame must not crash us), the subscription id
    /// (relays multiplex and may emit frames for other clients' REQs), and
    /// EVENT admission via `isAdmissibleEvent`, all before any Article is
    /// constructed. Pure and unit-testable; loop control stays in queryRelay.
    private static func admitFrame(_ text: String, subID: String, kinds: [Int]) -> RelayFrame {
        guard let arr = parseJSONArray(text), arr.count >= 2,
              let kind = arr[0] as? String,
              let frameSubID = arr[1] as? String,
              frameSubID == subID else { return .ignore }
        if kind == "EOSE" { return .eose }
        if kind == "EVENT", arr.count >= 3,
           let ev = arr[2] as? [String: Any],
           isAdmissibleEvent(ev, kinds: kinds) {
            return .event(ev)
        }
        return .ignore
    }

    /// Race one WebSocket receive against a deadline so we never hang.
    /// When the deadline wins, cancel the underlying URLSessionWebSocketTask:
    /// task cancellation alone cannot interrupt a pending receive(), so a
    /// silent relay would otherwise leave this group suspended past 8s.
    private static func nextMessage(_ task: URLSessionWebSocketTask, by deadline: Date) async -> URLSessionWebSocketTask.Message? {
        await withTaskGroup(of: URLSessionWebSocketTask.Message?.self, returning: URLSessionWebSocketTask.Message?.self) { group in
            group.addTask { try? await task.receive() }
            group.addTask {
                let remain = max(0, deadline.timeIntervalSinceNow)
                try? await Task.sleep(nanoseconds: UInt64(remain * 1_000_000_000))
                return nil
            }
            let first = await group.next() ?? nil
            if first == nil {
                // Fails the pending receive() with an error, unblocking the
                // child task so the group (and queryRelay) can actually end.
                task.cancel(with: .goingAway, reason: nil)
            }
            group.cancelAll()
            return first
        }
    }

    /// Admission check for a received EVENT payload before any Article is
    /// constructed: it must be a kind we asked for, and id/pubkey must be a
    /// Nostr-style 32-byte (64-char hex) value. Malformed frames are ignored.
    private static func isAdmissibleEvent(_ ev: [String: Any], kinds: [Int]) -> Bool {
        guard let kind = ev["kind"] as? Int, kinds.contains(kind),
              let id = ev["id"] as? String, isHex64(id),
              let pubkey = ev["pubkey"] as? String, isHex64(pubkey) else { return false }
        return true
    }

    /// Strict ASCII hex, exactly 64 chars (a Nostr 32-byte id/pubkey).
    private static func isHex64(_ s: String) -> Bool {
        guard s.count == 64 else { return false }
        for scalar in s.unicodeScalars {
            switch scalar.value {
            case 0x30...0x39, 0x41...0x46, 0x61...0x66:
                continue
            default:
                return false
            }
        }
        return true
    }

    private static func parseJSONArray(_ s: String) -> [Any]? {
        guard let data = s.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [Any]
    }

    // MARK: - Quality and relevance

    private static func filterArticles(_ input: [Article]) -> [Article] {
        var seen = Set<String>()
        var perAuthor: [String: Int] = [:]
        var accepted: [Article] = []

        for article in input.sorted(by: { $0.createdAt > $1.createdAt }) {
            guard seen.insert(article.identifier).inserted,
                  article.title != nil,
                  article.body.count > 200,
                  article.isLanguageAllowed,
                  article.isTitleLatinOrEmpty,
                  ReadsContentFilter.isAllowed(article.title ?? "", article.summary, article.body),
                  !article.isSpam else { continue }

            let count = (perAuthor[article.pubkey] ?? 0) + 1
            guard count <= 2 else { continue }
            perAuthor[article.pubkey] = count
            accepted.append(article)
            if accepted.count == 20 { break }
        }
        return accepted
    }

    private static func topicBoost(article: Article, topics: [String]) -> Double {
        var boost = 0.0
        var firstMatch = true
        let searchable = "\(article.title ?? "") \(article.summary) \(article.body)".lowercased()
        for topic in topics.map({ $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }) where !topic.isEmpty {
            if searchable.contains(topic) {
                boost += firstMatch ? 0.8 : 0.3
                firstMatch = false
                if boost >= 1.2 { return 1.2 }
            }
        }
        return boost
    }

    // MARK: - Article model

    /// A parsed NIP-23 article event.
    private struct Article {
        let identifier: String      // event id (hex) — used for the viewer fallback link
        let pubkey: String          // event author pubkey (hex) — used for the naddr link
        let dTag: String            // NIP-33 "d" identifier — used for the naddr link
        let title: String?
        let summary: String
        let image: String?
        let body: String
        let createdAt: TimeInterval
        let relay: String?
        let hasContentWarning: Bool
        let declaredLanguage: String?

        init?(event: [String: Any]) {
            guard let id = event["id"] as? String else { return nil }
            identifier = id
            // The author pubkey is a top-level field on every Nostr event.
            // The naddr's author TLV (type 2) MUST be this 32-byte pubkey,
            // NOT the event id — otherwise readers decode a valid bech32
            // string that points at a nonexistent (pubkey, kind, d) → 404.
            pubkey = (event["pubkey"] as? String) ?? ""
            body = (event["content"] as? String) ?? ""
            createdAt = (event["created_at"] as? Double) ?? (event["created_at"] as? Int).map(Double.init) ?? 0
            relay = event["slowclaw_relay"] as? String
            var d = "", t: String?, sum = "", img: String?
            var contentWarning = false
            var language: String?
            if let tags = event["tags"] as? [[Any]] {
                for tag in tags {
                    guard tag.count >= 2, let name = tag[0] as? String else { continue }
                    let val = (tag[1] as? String) ?? ""
                    switch name {
                    case "d": d = val
                    case "title": t = val.isEmpty ? nil : val
                    case "summary": sum = val
                    case "image": img = val.isEmpty ? nil : val
                    case "content-warning": contentWarning = true
                    case "L", "cl":
                        if val.range(of: "^[a-z]{2}(-[a-z0-9]+)?$", options: [.regularExpression, .caseInsensitive]) != nil {
                            language = val.lowercased()
                        }
                    default: break
                    }
                }
            }
            dTag = d
            title = t
            summary = sum
            image = img
            hasContentWarning = contentWarning
            declaredLanguage = language
        }

        /// Default to Latin-script content, with an explicit language tag able
        /// to reject known non-English articles. This is the old local filter's
        /// intentionally lightweight, dependency-free language signal.
        var isLanguageAllowed: Bool {
            if let declaredLanguage, !declaredLanguage.hasPrefix("en") { return false }
            // Strip URLs and hashtags BEFORE the script ratio: spam bodies
            // carry Latin-character URLs that flipped the ratio and let
            // CJK/Cyrillic spam (incl. adult content) through the gate.
            let cleaned = (title ?? "") + " " + String(body.prefix(600))
                .replacingOccurrences(of: "https?://\\S+", with: "", options: .regularExpression)
                .replacingOccurrences(of: "#[A-Za-z0-9_]+", with: "", options: .regularExpression)
            var latin = 0
            var nonLatin = 0
            for scalar in cleaned.unicodeScalars {
                switch scalar.value {
                case 65...90, 97...122, 0x00c0...0x024f:
                    latin += 1
                case 0x0400...0x052f, 0x0590...0x05ff, 0x0600...0x06ff,
                     0x0900...0x097f, 0x0e00...0x0e7f, 0x3040...0x30ff,
                     0x3400...0x9fff, 0xac00...0xd7af:
                    nonLatin += 1
                default:
                    continue
                }
            }
            return nonLatin == 0 || latin >= nonLatin
        }

        /// A title with letters but ZERO Latin ones (e.g. CJK-only spam
        /// titles like "脚 交") is not content this feed wants even when the
        /// body's URL soup passed the ratio check above.
        var isTitleLatinOrEmpty: Bool {
            guard let title else { return true }
            var latin = 0
            var nonLatin = 0
            for scalar in title.unicodeScalars {
                switch scalar.value {
                case 65...90, 97...122, 0x00c0...0x024f:
                    latin += 1
                case 0x0400...0x052f, 0x0590...0x05ff, 0x0600...0x06ff,
                     0x0900...0x097f, 0x0e00...0x0e7f, 0x3040...0x30ff,
                     0x3400...0x9fff, 0xac00...0xd7af:
                    nonLatin += 1
                default:
                    continue
                }
            }
            return nonLatin == 0 || latin > 0
        }

        var isSpam: Bool {
            let text = body.trimmingCharacters(in: .whitespacesAndNewlines)
            guard text.count >= 3, !hasContentWarning else { return true }
            let hashtagCount = text.components(separatedBy: "#").dropFirst().count
            guard hashtagCount <= 6 else { return true }
            let stripped = text
                .replacingOccurrences(of: "https?://\\S+", with: "", options: .regularExpression)
                .replacingOccurrences(of: "#[A-Za-z0-9_]+", with: "", options: .regularExpression)
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .joined()
            guard stripped.count >= 3 else { return true }
            let lowered = text.lowercased()
            return lowered.hasPrefix("block found!") ||
                lowered.hasPrefix("network: testnet") ||
                lowered.hasPrefix("lightning address")
        }

        /// Article URL, preferring a naddr-encoded address (mirrors
        /// encodeNaddr in web/src/lib/nostr.ts, which encodes the author
        /// PUBKEY — not the event id). highlighter.com is a long-form Nostr
        /// reader that resolves naddr links server-side (verified against live
        /// relay events; habla.news is offline — 404 for the whole domain).
        /// An article without a valid NIP-33 coordinate cannot resolve there;
        /// use a generic Nostr viewer for that malformed case rather than
        /// creating a known 404.
        var articleURL: String {
            if !dTag.isEmpty, !pubkey.isEmpty,
               let naddr = Nip19.encodeNaddr(identifier: dTag, pubkey: pubkey, kind: 30023, relay: relay) {
                return "https://highlighter.com/a/\(naddr)"
            }
            return "https://njump.me/\(identifier)"
        }
    }
}
