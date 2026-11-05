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

// MARK: - Book

final class BookOrganizerTests: XCTestCase {
    private func v(_ angleDegrees: Double, plane: Int = 0) -> [Float] {
        var out = [Float](repeating: 0, count: 8)
        let a = angleDegrees * .pi / 180
        out[plane * 2] = Float(cos(a)); out[plane * 2 + 1] = Float(sin(a))
        return out
    }
    private let long = "This morning I noticed how much calmer I feel after a slow walk before opening any screens at all."

    func testRepeatJournalsAreRecognised() {
        let a = String(repeating: "We talked about the food hub and how profit could be returned to every shopper each month. ", count: 6)
        let b = "Intro. " + a.replacingOccurrences(of: "each month", with: "every month")
        XCTAssertTrue(BookOrganizer.isRepeatJournal(b, of: a))
        XCTAssertFalse(BookOrganizer.isRepeatJournal(long, of: a))
    }

    func testVoiceCheckCatchesParaphrase() {
        let source = "So I clicked the chess app and, um, the urge was so strong, you know, but I paused and just watched it."
        XCTAssertGreaterThanOrEqual(BookOrganizer.voiceKept(edited: "I clicked the chess app and the urge was so strong, but I paused and watched it.", source: source), 0.85)
        XCTAssertLessThan(BookOrganizer.voiceKept(edited: "I realized cravings dissolve when observed with mindful curiosity.", source: source), 0.85)
    }

    func testLightCleanKeepsWords() {
        XCTAssertEqual(BookOrganizer.lightClean("so I I think, um, yeah the food hub matters"), "So I think, the food hub matters.")
    }

    func testExtractStartsWhereAThoughtStarts() {
        let body = "And then it went on. " + Array(repeating: "I think the food hub should return its profits to the people who shop there.", count: 4).joined(separator: " ")
        let out = BookOrganizer.extractPassages(body)
        XCTAssertFalse(out.isEmpty)
        XCTAssertTrue(out.allSatisfy { !$0.hasPrefix("And") })
    }

    func testAdmission() {
        let book = (0..<8).map { v(Double($0) * 50) }
        let texts = (0..<8).map { "Passage \($0) about walking, mornings, attention and the harbour light number \($0)." + long }
        let fresh = "Writing letters to my grandmother every Sunday keeps our family stories alive between visits and phone calls."
        XCTAssertEqual(BookOrganizer.admit(vector: v(25), text: fresh, bookVectors: book, bookTexts: texts, waitingVectors: []), .join)
        guard case .drop = BookOrganizer.admit(vector: v(1), text: texts[0], bookVectors: book, bookTexts: texts, waitingVectors: []) else { return XCTFail() }
        // Unrelated: waits, unless two waiting passages relate to it (a new theme).
        guard case .wait = BookOrganizer.admit(vector: v(0, plane: 2), text: fresh, bookVectors: book, bookTexts: texts, waitingVectors: []) else { return XCTFail() }
        XCTAssertEqual(BookOrganizer.admit(vector: v(0, plane: 2), text: fresh, bookVectors: book, bookTexts: texts,
                                           waitingVectors: [v(2, plane: 2), v(4, plane: 2)]), .join)
    }

    func testOrganiseGroupsThemesAndReadsForward() {
        // Two themes (planes 0 and 2), written on interleaved days.
        var ps: [OrgPassage] = []
        for i in 0..<6 { ps.append(OrgPassage(vector: v(Double(i) * 4), day: 20260901 + i * 2, journal: "j\(i)", seq: 0)) }
        for i in 0..<6 { ps.append(OrgPassage(vector: v(Double(i) * 4, plane: 2), day: 20260902 + i * 2, journal: "k\(i)", seq: 0)) }
        let chapters = BookOrganizer.organize(ps)
        XCTAssertEqual(chapters.count, 2)
        XCTAssertEqual(Set(chapters[0]), Set(0..<6))     // the theme that began first comes first
        XCTAssertEqual(chapters[0], Array(0..<6))        // and reads forward along its thread
        XCTAssertEqual(Set(chapters[1]), Set(6..<12))
    }

    func testBridgesGoWhereTheThreadJumps() {
        let vectors = [v(0), v(5), v(10), v(80), v(85), v(90)]
        XCTAssertEqual(BookOrganizer.bridgeGaps(Array(0..<6), vectors: vectors), [3])
    }

    func testTitleReuse() {
        let cache: [(ids: Set<String>, title: String)] = [(["a", "b", "c", "d"], "Letters Home")]
        XCTAssertEqual(BookOrganizer.reuseTitle(for: ["a", "b", "c", "d", "e"], cache: cache), "Letters Home")
        XCTAssertNil(BookOrganizer.reuseTitle(for: ["a", "x", "y", "z"], cache: cache))
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

    func testVectorBytesRoundTrip() {
        let vec: [Float] = [0.25, -1, 3.5]
        XCTAssertEqual(BookVectors.decode(BookVectors.encode(vec)), vec)
    }

    func testOldBookNodesStillDecode() throws {
        let json = #"{"id":"n1","journalID":null,"text":"t","vectorData":"","language":"en","attachedTo":null,"position":1,"chapter":0,"chapterTitle":"","x":0.5,"y":0.5,"createdAt":0,"updatedAt":0,"deleted":false,"dirty":false}"#
        let d = JSONDecoder(); d.dateDecodingStrategy = .secondsSince1970
        let node = try d.decode(BookNode.self, from: Data(json.utf8))
        XCTAssertEqual(node.kind, .passage)
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

    func testStoriesGroupSameHeadline() {
        let a = NewsArticle(title: "Apple unveils new iPhone camera", source: "A", url: "https://example.com/1", published: nil)
        let b = NewsArticle(title: "New iPhone camera unveiled by Apple", source: "B", url: "https://example.com/2", published: nil)
        let c = NewsArticle(title: "Marathon record broken in Berlin", source: "C", url: "https://example.com/3", published: nil)
        let stories = NewsClustering.stories([a, c, b])
        XCTAssertEqual(stories.count, 2)
        XCTAssertEqual(stories[0].map(\.source), ["A", "B"])
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

// MARK: - Discover (news queries, videos)

final class DiscoverTests: XCTestCase {
    func testQueriesAreSpecificButPrivate() {
        XCTAssertEqual(NewsTopics.sanitizeQuery("cooperative supermarkets returning profits to shoppers"),
                       "cooperative supermarkets returning profits to shoppers")
        XCTAssertNil(NewsTopics.sanitizeQuery("food"))                                   // one word is a topic, not a search
        XCTAssertNil(NewsTopics.sanitizeQuery("call me on 0151 2345678 about the hub"))   // digits
        XCTAssertNil(NewsTopics.sanitizeQuery("mail user_a@example.com the zero profit plan"))
    }

    func testOldTopicsGainAQuery() throws {
        let t = try JSONDecoder().decode(NewsTopic.self, from: Data(#"{"name":"Sailing","fromJournal":true,"enabled":true}"#.utf8))
        XCTAssertEqual(t.query, "Sailing")
    }

    func testFrequentPhrases() {
        let text = "The community supermarket returns profits. A community supermarket is rare. Every community supermarket matters."
        XCTAssertEqual(NewsTopics.frequentPhrases(in: [text]).first, "community supermarket")
    }

    func testYouTubeResultsParsing() {
        let data = #"{"contents":{"list":[{"videoRenderer":{"videoId":"abcdefghijk","title":{"runs":[{"text":"How GPUs work"}]},"ownerText":{"runs":[{"text":"Example Channel"}]},"lengthText":{"simpleText":"12:34"},"publishedTimeText":{"simpleText":"1 year ago"}}},{"videoRenderer":{"videoId":"short","title":{"runs":[{"text":"bad id"}]}}},{"videoRenderer":{"videoId":"zyxwvutsrqp","title":{"simpleText":"Shorts clip"},"lengthText":{"simpleText":"0:45"}}}]}}"#
        let html = "<html><script>var ytInitialData = \(data);</script></html>"
        let items = YouTubeResults.parse(html: html)
        XCTAssertEqual(items.map(\.id), ["abcdefghijk", "zyxwvutsrqp"])
        XCTAssertEqual(items[0].title, "How GPUs work")
        XCTAssertEqual(items[0].channel, "Example Channel")
        XCTAssertEqual(items.filter(YouTubeResults.worthWatching).map(\.id), ["abcdefghijk"])
        XCTAssertEqual(YouTubeResults.seconds("1:02:03"), 3723)
        XCTAssertTrue(YouTubeResults.parse(html: "<html>consent page</html>").isEmpty)
    }

    func testQuestionsBecomeSearches() {
        let out = VideoStore.questions(in: ["Something else. How does a stateless protocol handle sessions? Fine."])
        XCTAssertEqual(out.first, "stateless protocol handle sessions explained")
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
