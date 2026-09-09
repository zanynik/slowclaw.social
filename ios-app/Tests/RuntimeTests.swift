import XCTest
@testable import Runtime

final class RuntimeTests: XCTestCase {
    func testQuestionRoundTripPreservesUserEditsAndLifecycle() throws {
        var question = try XCTUnwrap(QuestionThread.make(question: "What helps the garden grow?", sourceKey: "journal_test"))
        question.note = "A small experiment changed my view."
        question.status = .resolved
        question.sourceKeys.append("journal_second")
        XCTAssertEqual(try JSONDecoder().decode(QuestionThread.self, from: JSONEncoder().encode(question)), question)
        XCTAssertNil(QuestionThread.make(question: "   ", sourceKey: "journal_test"))
        XCTAssertNil(QuestionThread.make(question: String(repeating: "x", count: 241), sourceKey: "journal_test"))
    }
    func testDailySelectionIsBoundedDistinctAndSourceDiverse() throws {
        let selection = DailySelection.select([("a", "source_a"), ("a", "source_b"), ("b", "source_a"), ("c", "source_b"), ("d", "source_c"), ("e", "source_d")])
        XCTAssertEqual(selection, ["a", "c", "d"])
        let daily = DailySelection(day: "2026-1-1", readIDs: selection, questionID: "q", dismissed: true)
        XCTAssertEqual(try JSONDecoder().decode(DailySelection.self, from: JSONEncoder().encode(daily)), daily)
    }

    func testLiveEvidenceProviderReturnsPublicSources() async throws {
        guard ProcessInfo.processInfo.environment["SLOWCLAW_TEST_EVIDENCE"] == "1" else { throw XCTSkip("Opt-in live provider smoke") }
        let results = try await EvidenceSearch.search(query: "community gardening")
        XCTAssertFalse(results.isEmpty)
        XCTAssertTrue(results.allSatisfy { $0.url.host == "en.wikipedia.org" && !$0.excerpt.isEmpty })
    }
    func testGroundedReflectionRejectsFabricatedAndUnrelatedCitations() {
        let sources = ["J1": "I felt calmer after walking through the garden.", "E1": "Walking can provide an opportunity for physical activity."]
        let valid = #"{"observation":"Walking appeared to help on this occasion.","question":"What else was different that day?","citations":[{"id":"J1","quote":"felt calmer after walking"}]}"#
        XCTAssertNotNil(GroundedReflection.parse(valid, sources: sources))
        XCTAssertNil(GroundedReflection.parse(valid.replacingOccurrences(of: "felt calmer", with: "felt angry"), sources: sources))
        XCTAssertNil(GroundedReflection.parse(valid.replacingOccurrences(of: "J1", with: "J99"), sources: sources))
        XCTAssertNil(GroundedReflection.parse(valid, sources: [:]))
        let externalOnly = #"{"observation":"Walking appeared to help on this occasion.","question":"What else was different that day?","citations":[{"id":"E1","quote":"Walking can provide an opportunity"}]}"#
        XCTAssertNil(GroundedReflection.parse(externalOnly, sources: sources))
    }

    func testEvidenceSearchOnlySendsExplicitQueryToFixedPublicEndpoint() throws {
        let request = try EvidenceSearch.request(query: "gardens & wellbeing")
        let url = try XCTUnwrap(request.url)
        XCTAssertEqual(url.host, "en.wikipedia.org")
        let items = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(items.first { $0.name == "gsrsearch" }?.value, "gardens & wellbeing")
        XCTAssertThrowsError(try EvidenceSearch.request(query: "slowclaw_user@example.com"))
        XCTAssertThrowsError(try EvidenceSearch.request(query: "https://example.com/private"))
        XCTAssertThrowsError(try EvidenceSearch.request(query: String(repeating: "a", count: 81)))
        let result = try EvidenceSearch.decode(Data(#"{"query":{"pages":[{"pageid":42,"title":"Gardening","extract":"Gardening is cultivating plants.","index":1}]}}"#.utf8))
        XCTAssertEqual(result.first?.url.absoluteString, "https://en.wikipedia.org/?curid=42")
        XCTAssertEqual(result.first?.excerpt, "Gardening is cultivating plants.")
    }

    func testSinglePassSourceSamplesEveryJournalWithinUTF8Budget() {
        let source = "Beginning " + String(repeating: "園🐾 ", count: 3000) + " Ending"
        let result = DraftBudget.source([source, "Second source", "Third source"], miniCPM: true)
        XCTAssertTrue(result.contains("Beginning"))
        XCTAssertTrue(result.contains("Ending"))
        XCTAssertTrue(result.contains("Second source"))
        XCTAssertTrue(result.contains("Third source"))
        XCTAssertLessThan(result.utf8.count, 6100)
        XCTAssertLessThan(DraftBudget.source([source], miniCPM: false).utf8.count, 1650)
        XCTAssertEqual(DraftBudget.source([], miniCPM: true), "")
    }

    func testRetrievalWordsDoNotConfuseRelevanceWithAgreement() {
        XCTAssertEqual(ContextTools.lexicalMatch(query: "gardens", text: "Gardens are not useful."), 1)
        XCTAssertEqual(ContextTools.lexicalMatch(query: "the and", text: "the and"), 0)
        XCTAssertEqual(ContextTools.lexicalMatch(query: "gardens", text: "Traffic and roads"), 0)
    }

    func testMemoryKindsRemainEditableWithoutTurningClaimsIntoFacts() throws {
        for kind in MemoryInsight.Kind.allCases {
            let memory = MemoryInsight(summary: "An explicitly stated view.", excerpt: "I think this might be helpful.", kind: kind)
            XCTAssertEqual(try JSONDecoder().decode(MemoryInsight.self, from: JSONEncoder().encode(memory)), memory)
        }
    }
    func testMemoryRejectsInventedSourcePassagesAndUnsupportedKinds() {
        let source = "SlowClaw journals explore ways to grow a community garden."
        let valid = #"{"summary":"Exploring a community garden project.","excerpt":"explore ways to grow a community garden","kind":"project","topics":["gardens"],"post":null}"#
        XCTAssertNotNil(MemoryInsight.parse(valid, source: source))
        XCTAssertNil(MemoryInsight.parse(valid, source: "A different source entirely."))
        XCTAssertNil(MemoryInsight.parse(valid.replacingOccurrences(of: "\"project\"", with: "\"personality\""), source: source))
        XCTAssertNil(MemoryInsight.parse("{broken", source: source))
    }

    func testMemorySamplesLongJournalsAcrossBeginningMiddleAndEnd() {
        let source = "Beginning " + String(repeating: "a", count: 2500) + " middle " + String(repeating: "b", count: 2500) + " ending"
        let sample = MemoryInsight.sample(source)
        XCTAssertTrue(sample.contains("Beginning"))
        XCTAssertTrue(sample.contains("middle"))
        XCTAssertTrue(sample.contains("ending"))
        XCTAssertLessThan(sample.count, 1850)
        XCTAssertEqual(MemoryInsight.sample("Short source"), "Short source")
    }

    func testAutomaticPostRejectsOverlongAndContactBearingCandidates() {
        XCTAssertNil(MemoryInsight.validPost(String(repeating: "a", count: 301)))
        XCTAssertNil(MemoryInsight.validPost("Please contact slowclaw_user@example.com to learn more."))
        XCTAssertNil(MemoryInsight.validPost(nil))
        XCTAssertNotNil(MemoryInsight.validPost("I wonder how shared gardens could help a community learn together."))
    }

    func testCorrectedMemoryPreservesOriginalEvidenceAcrossRelaunch() throws {
        let insight = MemoryInsight(summary: "An open question, not a firm belief.", excerpt: "I wonder whether this would work.", kind: .question, corrected: true)
        XCTAssertEqual(try JSONDecoder().decode(MemoryInsight.self, from: JSONEncoder().encode(insight)), insight)
    }
    func testCasualReadingDecaysAndCuriosityDoesNotTrain() {
        let now = Date(timeIntervalSince1970: 1000000)
        let casual = ReadingSignal(topics: ["gardens"], date: now, preference: 0)
        let explicit = ReadingSignal(topics: ["gardens"], date: now, preference: 1)
        let curious = ReadingSignal(topics: ["gardens"], date: now, preference: 2)
        XCTAssertEqual(curious.weight(at: now), 0)
        XCTAssertLessThan(casual.weight(at: now), explicit.weight(at: now))
        XCTAssertEqual(casual.weight(at: now.addingTimeInterval(14 * 86400)), casual.weight(at: now) / 2, accuracy: 0.0001)
        XCTAssertLessThan(ReadingSignal(topics: [], date: now, preference: -1).weight(at: now), 0)
    }

    func testArticleSourceRoundTripKeepsLinkSeparateFromTranscript() throws {
        let source = ArticleReflection(title: "SlowClaw reading", url: URL(string: "https://example.com/article")!)
        let data = try JSONEncoder().encode(["journal_test": source])
        let decoded = try JSONDecoder().decode([String: ArticleReflection].self, from: data)
        XCTAssertEqual(decoded["journal_test"], source)
    }
    func testTranscriptReplacementPreservesEditsAndRejectsShorterResults() {
        XCTAssertFalse(TranscriptSafety.canReplace(original: "original", current: "edited", candidate: "longer result"))
        XCTAssertFalse(TranscriptSafety.canReplace(original: "complete transcript", current: "complete transcript", candidate: "partial"))
        XCTAssertFalse(TranscriptSafety.canReplace(original: "", current: "", candidate: "  "))
        XCTAssertTrue(TranscriptSafety.canReplace(original: "", current: "", candidate: "Recovered speech"))
        XCTAssertTrue(TranscriptSafety.canReplace(original: "first", current: "first", candidate: "first and last"))
    }
    func testReadingTopicsAreBoundedAndDeduplicated() {
        let topics = ReadingHistory.topics(title: "Gardens and gardens", summary: "Soil, vegetables, forests and agriculture support communities.")
        XCTAssertLessThanOrEqual(topics.count, 8)
        XCTAssertEqual(topics.count, Set(topics).count)
        XCTAssertFalse(topics.isEmpty)
    }
    func testUnbrokenTranscriptStaysWithinBudget() {
        let text = String(repeating: "journal 🐾 ", count: 1500)
        let parts = DraftBudget.chunks(text, limit: 1800)
        XCTAssertTrue(parts.allSatisfy { $0.count <= 1800 })
        XCTAssertEqual(parts.joined(), text.trimmingCharacters(in: .whitespacesAndNewlines))
        XCTAssertTrue(DraftBudget.chunks("   ", limit: 1800).isEmpty)
    }
    func testBIP340VectorZero() throws {
        // Published BIP-340 test key, never used as an app identity.
        let key = Array(repeating: UInt8(0), count: 31) + [3]
        XCTAssertEqual(try NostrIdentity.publicKey(key),
            "f9308a019258c31049344f85f89d5229b531c845836f99b08601f113bce036f9")
        // sign() independently verifies every generated signature with libsecp256k1.
        XCTAssertEqual(try NostrIdentity.sign(hash: Array(repeating: 0, count: 32), secret: key).count, 128)
        XCTAssertThrowsError(try NostrIdentity.publicKey(Array(repeating: 0, count: 32)))
    }

    func testSecretRoundTripRejectsCorruption() {
        let key = Array(repeating: UInt8(7), count: 32)
        let encoded = Nip19.encodeKey(key, prefix: "nsec")
        XCTAssertEqual(Nip19.decodeSecret(encoded), key)
        XCTAssertEqual(Nip19.decodeSecret(encoded.uppercased()), key)
        XCTAssertNil(Nip19.decodeSecret(String(encoded.dropLast()) + (encoded.last == "q" ? "p" : "q")))
        XCTAssertNil(Nip19.decodeSecret("N" + encoded.dropFirst()))
    }

    func testExecutorDoesNotOverlapOrBlockMain() async throws {
        final class Counter: @unchecked Sendable {
            let lock = NSLock()
            var active = 0
            var maximum = 0
            func work() -> Bool {
                lock.lock(); active += 1; maximum = max(maximum, active); lock.unlock()
                Thread.sleep(forTimeInterval: 0.03)
                let offMain = !Thread.isMainThread
                lock.lock(); active -= 1; lock.unlock()
                return offMain
            }
        }
        let counter = Counter()
        let executor = OnDeviceAIExecutor()
        try await withThrowingTaskGroup(of: Bool.self) { group in
            for _ in 0..<8 { group.addTask { try await executor.run { counter.work() } } }
            for try await offMain in group { XCTAssertTrue(offMain) }
        }
        XCTAssertEqual(counter.maximum, 1)
    }
}
