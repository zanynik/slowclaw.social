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

final class BookEngineTests: XCTestCase {
    private func v(_ angleDegrees: Double, plane: Int = 0) -> [Float] {
        var out = [Float](repeating: 0, count: 8)
        let a = angleDegrees * .pi / 180
        out[plane * 2] = Float(cos(a)); out[plane * 2 + 1] = Float(sin(a))
        return out
    }
    private func point(_ id: String, _ vector: [Float], _ text: String, _ pos: Double) -> BookPoint {
        BookPoint(id: id, vector: BookEngine.normalized(vector), text: text, position: pos)
    }
    private let long = "This morning I noticed how much calmer I feel after a slow walk before opening any screens at all."

    func testFirstPassageSeedsTheBook() {
        XCTAssertEqual(BookEngine.decide(vector: v(0), text: long, path: []), .accept(position: 1, attachTo: nil))
    }

    func testShortPassageIsRejected() {
        guard case .reject = BookEngine.decide(vector: v(0), text: "Too short.", path: []) else { return XCTFail() }
    }

    func testRepeatIsRejected() {
        let path = [point("a", v(0), long, 1)]
        guard case let .reject(reason) = BookEngine.decide(vector: v(1), text: long + " Again.", path: path) else { return XCTFail() }
        XCTAssertTrue(reason.hasPrefix("Says nearly"))
    }

    func testPassageWithoutNewWordsIsRejected() {
        let path = [point("a", v(0), long, 1)]
        guard case let .reject(reason) = BookEngine.decide(vector: v(50), text: long, path: path) else { return XCTFail() }
        XCTAssertTrue(reason.hasPrefix("Adds too little"))
    }

    func testFarPassageWaitsOnceTheBookHasThreads() {
        let path = (0..<6).map { point("n\($0)", v(Double($0) * 2), long + " Variation \($0) seashell lantern \($0).", Double($0 + 1)) }
        let far = "Quarterly budgeting spreadsheets, invoices and accountants dominate tomorrow's agenda completely, unfortunately enough again."
        guard case let .reject(reason) = BookEngine.decide(vector: v(0, plane: 2), text: far, path: path) else { return XCTFail() }
        XCTAssertTrue(reason.hasPrefix("Too far"))
    }

    func testRelatedNewPassageAttachesToNearest() {
        let path = (0..<6).map { point("n\($0)", v(Double($0) * 10), long + " Variation \($0) seashell.", Double($0 + 1)) }
        let fresh = "Walking barefoot along the harbour, gulls circling, I decided to write letters to my grandmother every Sunday."
        guard case let .accept(_, attachTo) = BookEngine.decide(vector: v(78), text: fresh, path: path) else { return XCTFail() }
        XCTAssertEqual(attachTo, "n5")
    }

    func testInsertionGoesBetweenClosestNeighbours() {
        let path = [0.0, 30, 60, 90].enumerated().map { point("p\($0.offset)", v($0.element), long, Double($0.offset + 1)) }
        let index = BookEngine.insertionIndex(vector: v(45), path: path)
        XCTAssertEqual(index, 2)
        XCTAssertEqual(BookEngine.position(at: index, in: path), 2.5)
        XCTAssertEqual(BookEngine.position(at: 0, in: path), 0)
        XCTAssertEqual(BookEngine.position(at: 4, in: path), 5)
    }

    func testChaptersBreakWhereTheThreadChanges() {
        let vs = [v(0), v(3), v(6), v(0, plane: 2), v(3, plane: 2)]
        let path = vs.enumerated().map { point("c\($0.offset)", $0.element, long, Double($0.offset)) }
        XCTAssertEqual(BookEngine.chapters(path), [0, 0, 0, 1, 1])
    }

    func testProjectionIsBoundedAndStable() {
        let vs = [v(0), v(40), v(80), v(10, plane: 1), v(70, plane: 2)].map(BookEngine.normalized)
        let first = BookEngine.project(vs)
        let again = BookEngine.project(vs, previousAxes: first.axes)
        XCTAssertEqual(first.points.count, 5)
        for (a, b) in zip(first.points, again.points) {
            XCTAssertTrue((0.049...0.951).contains(a.0) && (0.049...0.951).contains(a.1))
            XCTAssertEqual(a.0, b.0, accuracy: 1e-6)
            XCTAssertEqual(a.1, b.1, accuracy: 1e-6)
        }
    }

    func testNewInformationAndTitles() {
        XCTAssertEqual(BookEngine.newInformation("gardens tomatoes", comparedTo: ["tomatoes"]), 0.5, accuracy: 0.001)
        XCTAssertEqual(BookEngine.keywordTitle(["running shoes", "running trails", "shoes"]), "Running & Shoes")
    }

    func testVectorBytesRoundTrip() {
        let vec: [Float] = [0.25, -1, 3.5]
        XCTAssertEqual(BookVectors.decode(BookVectors.encode(vec)), vec)
    }

    func testFallbackPassagesUseSubstantialParagraphs() {
        let para = Array(repeating: "I keep returning to the idea that small habits shape the whole week.", count: 3).joined(separator: " ")
        let out = BookStore.fallbackPassages("Buy milk.\n\n" + para)
        XCTAssertEqual(out, [para])
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
