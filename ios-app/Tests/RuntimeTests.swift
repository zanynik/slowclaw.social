import XCTest
@testable import Runtime

final class RuntimeTests: XCTestCase {
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
