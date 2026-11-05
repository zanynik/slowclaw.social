import XCTest
@testable import SlowClaw

// MARK: - Nostr

final class NostrTests: XCTestCase {
    private let secret: [UInt8] = Array(repeating: 0, count: 31) + [3]
    private let pubkey = "f9308a019258c31049344f85f89d5229b531c845836f99b08601f113bce036f9"

    func testPublicKeyMatchesBIP340Vector() throws {
        XCTAssertEqual(try NostrIdentity.publicKey(for: secret), pubkey)
    }

    func testBech32() throws {
        let pk = try XCTUnwrap(Hex.bytes(pubkey))
        XCTAssertEqual(Bech32.encode(pk, prefix: "npub"), "npub1lycg5qvjtrp3qjf5f7zl382j9x6nrjz9sdhenvyxq8c3808qxmus6gq266")
        let nsec = Bech32.encode(secret, prefix: "nsec")
        XCTAssertEqual(nsec, "nsec1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqps52s3re")
        XCTAssertEqual(Bech32.decodeSecret(nsec), secret)
        XCTAssertNil(Bech32.decodeSecret("nsec1qqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqqps52s3rf"))
    }

    /// Same event the server-side verifier (noble-curves) reconstructs and hashes.
    func testNIP98EventIDMatchesServer() {
        let url = "https://docmtelcjyvfyjlujibb.supabase.co/functions/v1/cloud-login"
        let tags = [["u", url], ["method", "POST"],
                    ["payload", "5b71cbedb6b4ee089192812d2a18d5b86010299e51677e6478f4fdcca06be6db"]]
        let serialized = String(decoding: NostrIdentity.serialize(pubkey: pubkey, createdAt: 1793800000, kind: 27235, tags: tags, content: ""), as: UTF8.self)
        XCTAssertEqual(serialized, #"[0,"f9308a019258c31049344f85f89d5229b531c845836f99b08601f113bce036f9",1793800000,27235,[["u","https://docmtelcjyvfyjlujibb.supabase.co/functions/v1/cloud-login"],["method","POST"],["payload","5b71cbedb6b4ee089192812d2a18d5b86010299e51677e6478f4fdcca06be6db"]],""]"#)
        XCTAssertEqual(Hex.string(NostrIdentity.eventID(pubkey: pubkey, createdAt: 1793800000, kind: 27235, tags: tags, content: "")),
                       "b241e3f173495054ab09d293672e2de2c5e438f13d999c53feaf6f9fc2242dd9")
    }

    func testSignAndVerify() throws {
        let hash = Array(repeating: UInt8(7), count: 32)
        let sig = try NostrIdentity.sign(hash: hash, secret: secret)
        XCTAssertEqual(sig.count, 128)
        XCTAssertTrue(NostrIdentity.verify(signature: sig, hash: hash, publicKey: pubkey))
        XCTAssertFalse(NostrIdentity.verify(signature: sig, hash: Array(repeating: 8, count: 32), publicKey: pubkey))
    }

    func testBrowserCodes() {
        let id = String(repeating: "a", count: 64), key = String(repeating: "b", count: 64)
        XCTAssertEqual(BrowserCode.parse(#"{"type":"slowclaw-cloud","id":"\#(id)","key":"\#(key)","expires":1800000000}"#),
                       .cloud(id: id, key: key, expires: 1800000000))
        XCTAssertEqual(BrowserCode.parse(#"{"type":"slowclaw-local","id":"\#(String(repeating: "c", count: 32))"}"#),
                       .local(id: String(repeating: "c", count: 32)))
        XCTAssertNil(BrowserCode.parse("https://example.com"))
        XCTAssertNil(BrowserCode.parse(#"{"type":"slowclaw-cloud","id":"zz","key":"\#(key)","expires":1}"#))
    }
}

// MARK: - Embeddings

final class MiniLMTests: XCTestCase {
    /// Same tokens and vectors as the Python prototype the book and Discover were tuned with.
    func testMatchesPrototypeGoldenVectors() throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "minilm-golden", withExtension: "json"))
        let gold = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let texts = try XCTUnwrap(gold["texts"] as? [String])
        let ids = try XCTUnwrap(gold["ids"] as? [[Int]])
        let vectors = try XCTUnwrap(gold["vectors"] as? [[Double]])
        let model = try XCTUnwrap(MiniLM.shared, "bundled model missing")
        for (i, text) in texts.enumerated() {
            XCTAssertEqual(model.encode(text), ids[i], "tokens differ for: \(text)")
            let v = model.embed(text)
            let cos = zip(v, vectors[i]).reduce(0) { $0 + Double($1.0) * $1.1 }
            XCTAssertGreaterThan(cos, 0.999, "vector differs for: \(text)")
        }
    }

    func testMeaningIsSeparated() throws {
        let m = try XCTUnwrap(MiniLM.shared)
        let a = m.embed("I meditate to watch my cravings without reacting.")
        let b = m.embed("Vipassana teaches observing sensations with equanimity.")
        let c = m.embed("GPU shortages and the AI investment bubble.")
        XCTAssertGreaterThan(BookEngine.similarity(a, b), BookEngine.similarity(a, c) + 0.2)
    }
}

// MARK: - Book

final class BookOrganizerTests: XCTestCase {
    private func v(_ angleDegrees: Double, plane: Int = 0) -> [Float] {
        var out = [Float](repeating: 0, count: 8)
        let a = angleDegrees * .pi / 180
        out[plane * 2] = Float(cos(a)); out[plane * 2 + 1] = Float(sin(a))
        return out
    }

    func testRepeatJournalsAreRecognised() {
        let a = String(repeating: "We talked about the food hub and how profit could be returned to every shopper each month. ", count: 6)
        let b = "Intro. " + a.replacingOccurrences(of: "each month", with: "every month")
        XCTAssertTrue(BookOrganizer.isRepeatJournal(b, of: a))
        XCTAssertFalse(BookOrganizer.isRepeatJournal("A walk by the harbour this morning before work, slow and quiet.", of: a))
    }

    func testLightCleanKeepsWords() {
        XCTAssertEqual(BookOrganizer.lightClean("so I I think, um, yeah the food hub matters"), "So I think, the food hub matters.")
    }

    func testVoiceCheck() {
        let source = "I clicked the chess app and the urge was so strong, but I paused and watched it."
        XCTAssertGreaterThanOrEqual(BookOrganizer.voiceKept(edited: "I clicked the chess app; the urge was strong, but I paused and watched it.", source: source), 0.85)
        XCTAssertLessThan(BookOrganizer.voiceKept(edited: "Mindful curiosity dissolves cravings.", source: source), 0.6)
    }

    func testSegmentsCutWhereMeaningTurns() {
        let vectors = (0..<6).map { _ in v(0) } + (0..<6).map { _ in v(0, plane: 2) }
        let segs = BookOrganizer.segments(vectors)
        XCTAssertEqual(segs.first, 0..<6)
        XCTAssertEqual(segs.last?.upperBound, 12)
    }

    func testCentralPassageStartsWhereAThoughtStarts() {
        let sentences = ["And then it went on and on for a while.",
                         "I think the food hub should return its profits to the people who shop there every month.",
                         "That would make people curious about why a shop gives money back.",
                         "Curiosity is how the idea of zero profit could spread from person to person.",
                         "It is a small change with a large meaning for how we trade."]
        let vectors = sentences.indices.map { v(Double($0)) }
        let p = BookOrganizer.centralPassage(sentences, vectors, in: 0..<5)
        XCTAssertNotNil(p)
        XCTAssertFalse(p!.text.hasPrefix("And"))
    }

    func testThemesSeparateAndReadByDate() {
        var ps: [OrgPassage] = []
        // Two themes written on alternating days; 8 passages → about √(8/2) = 2 chapters.
        for i in 0..<4 { ps.append(OrgPassage(vector: v(Double(3 - i) * 3), day: 20260901 + i * 2, journal: "j\(i)", seq: 0)) }
        for i in 0..<4 { ps.append(OrgPassage(vector: v(Double(i) * 3, plane: 2), day: 20260902 + i * 2, journal: "k\(i)", seq: 0)) }
        let chapters = BookOrganizer.organize(ps)
        XCTAssertEqual(chapters.count, 2)
        XCTAssertEqual(chapters[0], Array(0..<4))      // the theme that began first, in date order
        XCTAssertEqual(Set(chapters[1]), Set(4..<8))
        XCTAssertEqual(BookOrganizer.organize(ps), chapters)   // same book, same chapters
    }

    func testLonersWait() {
        var vs = (0..<20).map { v(Double($0)) }
        vs.append(v(0, plane: 3))
        XCTAssertEqual(BookOrganizer.loners(vs), [20])
    }

    func testKeyphrasesAreDistinctive() {
        let food = ["The food hub returns profits to shoppers.", "A zero profit food hub builds trust.", "Members volunteer on Saturdays."]
        let mind = ["Meditation shows sensations change.", "In meditation I watch cravings.", "Breathing slowly at dawn."]
        let travel = ["Trains across the mountains.", "A ferry to the island.", "Packing light for trips."]
        let k = BookOrganizer.keyphrases(groups: [food, mind, travel])
        XCTAssertEqual(k[0].first, "food hub")
        XCTAssertEqual(k[1].first, "meditation")
    }

    func testProjectionIsBoundedAndStable() {
        let vs = [v(0), v(40), v(80), v(10, plane: 1), v(70, plane: 2)].map(BookEngine.normalized)
        let first = BookEngine.project(vs)
        let again = BookEngine.project(vs, previousAxes: first.axes)
        for (a, b) in zip(first.points, again.points) {
            XCTAssertTrue((0.049...0.951).contains(a.0) && (0.049...0.951).contains(a.1))
            XCTAssertEqual(a.0, b.0, accuracy: 1e-6)
        }
    }

    func testOldBookNodesStillDecode() throws {
        let json = #"{"id":"n1","journalID":null,"text":"t","vectorData":"","language":"en","position":1,"chapter":0,"chapterTitle":"","x":0.5,"y":0.5,"createdAt":0,"updatedAt":0,"deleted":false,"dirty":false}"#
        let d = JSONDecoder(); d.dateDecodingStrategy = .secondsSince1970
        let node = try d.decode(BookNode.self, from: Data(json.utf8))
        XCTAssertEqual(node.kind, .passage)
        XCTAssertFalse(node.polished)
    }
}

// MARK: - News

final class NewsTests: XCTestCase {
    func testTopicsStayGeneral() {
        XCTAssertEqual(NewsTopics.sanitize(" Electric cars. "), "Electric cars")
        XCTAssertNil(NewsTopics.sanitize("call 555 1234567"))
        XCTAssertNil(NewsTopics.sanitize("user_a@example.com"))
        XCTAssertNil(NewsTopics.sanitize("a"))
        XCTAssertNil(NewsTopics.sanitize("one two three four five"))
    }

    func testRSSParsing() {
        let xml = """
        <?xml version="1.0"?><rss><channel><title>Feed</title>
        <item><title>Rain returns to the valley - Example News</title><link>https://example.com/a</link>
        <pubDate>Tue, 03 Nov 2026 14:00:00 GMT</pubDate><source url="https://example.com">Example News</source></item>
        <item><title>No link here</title></item>
        </channel></rss>
        """
        let items = RSSParser.parse(Data(xml.utf8))
        XCTAssertEqual(items.count, 1)
        XCTAssertEqual(items[0].title, "Rain returns to the valley")
        XCTAssertEqual(items[0].source, "Example News")
        XCTAssertNotNil(items[0].published)
    }

    func testOnlyTheTopicGoesInTheQuery() throws {
        let url = try XCTUnwrap(NewsStore.searchURL("electric cars", locale: Locale(identifier: "en_US")))
        XCTAssertEqual(url.host, "news.google.com")
        XCTAssertTrue(url.absoluteString.contains("q=electric%20cars%20when:3d"))
        XCTAssertTrue(NewsStore.searchURL("open source coding agents", days: 7)!.absoluteString.contains("when:7d"))
    }
}

// MARK: - Discover

final class DiscoverTests: XCTestCase {
    func testQueriesAreSpecificButPrivate() {
        XCTAssertEqual(NewsTopics.sanitizeQuery("cooperative supermarkets returning profits"), "cooperative supermarkets returning profits")
        XCTAssertNil(NewsTopics.sanitizeQuery("food"))
        XCTAssertNil(NewsTopics.sanitizeQuery("call me on 0151 2345678 about the hub"))
        XCTAssertNil(NewsTopics.sanitizeQuery("mail user_a@example.com the zero profit plan"))
    }

    func testNamedThingsNeverIncludePeopleOrPlaces() {
        let names = ThemeSearches.namedThings(in: ["Yesterday Anoop said DeepMind and OpenAI are hiring in Munich.",
                                                   "Anoop thinks DeepMind will open an office. The GPU shortage is real."])
        XCTAssertGreaterThanOrEqual(names["DeepMind"] ?? 0, 2)
        XCTAssertNotNil(names["OpenAI"])
        XCTAssertNotNil(names["GPU"])
        XCTAssertNil(names["Anoop"])
        XCTAssertNil(names["Munich"])
        XCTAssertNil(names["Yesterday"])
    }

    func testRelevanceKeepsOnlyCloseResults() {
        XCTAssertEqual(Relevance.keep(scores: [0.62, 0.30, 0.55, 0.49, 0.47], minimum: 0.48, limit: 4), [0, 2])
        XCTAssertEqual(Relevance.keep(scores: [0.40, 0.30], minimum: 0.48, limit: 4), [])
    }

    func testChannelFeedParsing() {
        let xml = """
        <?xml version="1.0"?><feed xmlns:yt="http://www.youtube.com/xml/schemas/2015" xmlns:media="http://search.yahoo.com/mrss/" xmlns="http://www.w3.org/2005/Atom">
        <title>Example Channel</title>
        <entry><yt:videoId>abcdefghijk</yt:videoId><title>How GPUs work</title><published>2026-11-01T10:00:00+00:00</published>
        <media:group><media:description>A clear explanation.</media:description></media:group></entry>
        <entry><yt:videoId>zyxwvutsrqp</yt:videoId><title>Quick tip #shorts</title><published>2026-11-01T10:00:00+00:00</published></entry>
        </feed>
        """
        let feed = ChannelFeedParser.parse(Data(xml.utf8))
        XCTAssertEqual(feed.channel, "Example Channel")
        XCTAssertEqual(feed.videos.map(\.id), ["abcdefghijk"])
        XCTAssertEqual(feed.videos.first?.summary, "A clear explanation.")
        XCTAssertNotNil(feed.videos.first?.published)
    }
}

// MARK: - Local server

final class LocalServerTests: XCTestCase {
    func testParsesRequests() {
        let get = Data("GET /api/data?x=1 HTTP/1.1\r\nHost: a\r\nAuthorization: Bearer t\r\n\r\n".utf8)
        guard case let .done(r, consumed) = HTTPRequest.parse(get) else { return XCTFail() }
        XCTAssertEqual(r.path, "/api/data")
        XCTAssertEqual(r.query["x"], "1")
        XCTAssertEqual(r.headers["authorization"], "Bearer t")
        XCTAssertEqual(consumed, get.count)

        let partial = Data("POST /api/save HTTP/1.1\r\nContent-Length: 5\r\n\r\nab".utf8)
        guard case .incomplete = HTTPRequest.parse(partial) else { return XCTFail() }
        guard case let .done(post, _) = HTTPRequest.parse(partial + Data("cde".utf8)) else { return XCTFail() }
        XCTAssertEqual(String(decoding: post.body, as: UTF8.self), "abcde")

        guard case .invalid = HTTPRequest.parse(Data("nonsense\r\n\r\n".utf8)) else { return XCTFail() }
    }

    @MainActor
    func testDataNeedsAPairedBrowser() {
        let r = HTTPRequest(method: "GET", path: "/api/data", query: [:], headers: ["authorization": "Bearer nope"], body: Data())
        XCTAssertEqual(LocalServer.shared.handle(r).status, 401)
        let mode = HTTPRequest(method: "GET", path: "/mode.js", query: [:], headers: [:], body: Data())
        XCTAssertTrue(String(decoding: LocalServer.shared.handle(mode).body, as: UTF8.self).contains("local"))
        let escape = HTTPRequest(method: "GET", path: "/../Info.plist", query: [:], headers: [:], body: Data())
        XCTAssertEqual(LocalServer.shared.handle(escape).status, 404)
    }
}
