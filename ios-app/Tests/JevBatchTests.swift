import XCTest
@testable import Runtime

final class JevBatchTests: XCTestCase {
    func testPersonaIsBoundedAndDeterministic() {
        let weights = Array(repeating: 1.0, count: JevPersona.topics.count)
        let profile = JevBatch.profile(weights)
        XCTAssertEqual(profile.count, 15)
        XCTAssertEqual(profile.first?.topic, JevPersona.topics.first)
        XCTAssertEqual(JevBatch.profileID(profile), JevBatch.profileID(JevBatch.profile(weights.map { $0 * 2 })))
        XCTAssertTrue(JevBatch.profile([]).isEmpty)
        XCTAssertTrue(JevBatch.profile(Array(repeating: .nan, count: weights.count)).isEmpty)
        XCTAssertTrue(JevBatch.profile(Array(repeating: 0, count: weights.count)).isEmpty)
    }
    func testExcerptBoundsWordsAndMultibyteInput() {
        XCTAssertLessThanOrEqual(JevBatch.excerpt(title: "Heading", body: Array(repeating: "word", count: 1000).joined(separator: " ")).split(separator: " ").count, 101)
        for body in [String(repeating: "🌿", count: 10000), String(repeating: "x\u{0301}", count: 20000), String(repeating: "word ", count: 1000)] {
            XCTAssertLessThanOrEqual(JevBatch.excerpt(title: body, body: body).utf8.count, 1200)
        }
    }
    func testBatchBudgetHandlesEscapingWithoutDroppingItems() {
        let plain = (0..<120).map { JevBatch.Candidate(id: String($0), text: String(repeating: "a", count: 1200)) }
        XCTAssertEqual(JevBatch.batches(plain).flatMap { $0 }.map(\.id), plain.map(\.id))
        let escaped = (0..<32).map { JevBatch.Candidate(id: String($0), text: String(repeating: "\u{0001}", count: 1200)) }
        let batches = JevBatch.batches(escaped)
        XCTAssertGreaterThan(batches.count, 1)
        XCTAssertEqual(batches.flatMap { $0 }.map(\.id), escaped.map(\.id))
        XCTAssertTrue(batches.allSatisfy { $0.count <= JevBatch.limit })
    }
    func testMissingDuplicateAndInvalidResponsesFailClosed() {
        let items: [JevBatch.Candidate] = [.init(id: "a", text: "a"), .init(id: "b", text: "b")]
        XCTAssertTrue(JevBatch.valid([.init(id: "b", score: 0.1), .init(id: "a", score: 0.9)], for: items))
        XCTAssertFalse(JevBatch.valid([.init(id: "a", score: 0.9), .init(id: "a", score: 0.9)], for: items))
        XCTAssertFalse(JevBatch.valid([.init(id: "a", score: 0.9)], for: items))
        XCTAssertFalse(JevBatch.valid([.init(id: "a", score: .nan), .init(id: "b", score: 0)], for: items))
    }
    func testCacheInvalidatesOnPersonaContentAndAge() {
        let now = Date(timeIntervalSince1970: 1000000)
        var cache = JevBatch.Cache(profile: "persona")
        cache.entries["content"] = .init(score: 0.8, date: now)
        XCTAssertEqual(cache.score(for: "content", profile: "persona", now: now), 0.8)
        XCTAssertNil(cache.score(for: "edited", profile: "persona", now: now))
        XCTAssertNil(cache.score(for: "content", profile: "changed", now: now))
        XCTAssertNil(cache.score(for: "content", profile: "persona", now: now.addingTimeInterval(7 * 86400)))
        XCTAssertNil(cache.score(for: "content", profile: "persona", now: now.addingTimeInterval(-1)))
        for i in 0..<400 { cache.entries[String(i)] = .init(score: 0.5, date: now) }
        cache.trim(); XCTAssertEqual(cache.entries.count, 300)
    }
}
