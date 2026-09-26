import XCTest
@testable import Runtime

final class CreateIdeasTests: XCTestCase {
    func testSentenceWindowsIsolateInsightsAndPreserveWhitespace() {
        let insight = "A smaller experiment teaches more than a perfect plan."
        let body = "Today I bought potatoes at the shop.\n\n" + insight + "  Testing one assumption makes failures useful."
        let windows = CreateIdeas.textWindows(body)
        XCTAssertTrue(windows.contains(insight))
        XCTAssertTrue(windows.allSatisfy { body.contains($0) && $0.count <= 550 })
        XCTAssertEqual(Set(windows).count, windows.count)
        let candidates = CreateIdeas.candidates(key: "slowclaw_journal", content: body, body: body, timing: nil)
        var cache = CreateIdeas.Cache(); cache.reconcile(candidates)
        for item in candidates {
            let selected = item.text == insight
            cache.decisions[item.id] = .init(id: item.id, score: selected ? 0.95 : 0.1,
                privateScore: 0, standalone: 0.9, quote: selected ? 0.9 : 0.1)
        }
        XCTAssertEqual(CreateIdeas.selected(cache).map(\.text), [insight])
    }
    private func transcript() -> TimedTranscript {
        let words = (0..<60).map { index in TimedTranscript.Word(text: index % 10 == 9 ? "thought." : "word\(index)", start: Double(index), end: Double(index) + 0.7) }
        return .init(text: words.map(\.text).joined(separator: " "), words: words)
    }
    func testCandidatesRetainNativeRangesAndDifferentRepeatedOccurrences() {
        let timing = transcript()
        let values = CreateIdeas.candidates(key: "slowclaw_journal", content: "source", body: "source", timing: timing)
        XCTAssertFalse(values.isEmpty)
        XCTAssertEqual(Set(values.map(\.id)).count, values.count)
        for item in values {
            XCTAssertEqual(item.text, timing.words[item.first!...item.last!].map(\.text).joined(separator: " "))
            XCTAssertEqual(item.start, timing.words[item.first!].start)
            XCTAssertEqual(item.end, timing.words[item.last!].end)
            XCTAssertLessThanOrEqual(item.duration!, 75)
        }
        let changed = CreateIdeas.candidates(key: "slowclaw_journal", content: "edited source", body: "source", timing: timing)
        XCTAssertTrue(Set(values.map(\.id)).isDisjoint(with: changed.map(\.id)))
    }
    func testSelectionRejectsPrivateAndOverlappingMoments() {
        let values = CreateIdeas.candidates(key: "slowclaw_journal", content: "source", body: "source", timing: transcript())
        var cache = CreateIdeas.Cache(); cache.reconcile(values)
        for (i, item) in values.enumerated() {
            cache.decisions[item.id] = .init(id: item.id, score: 0.95 - Double(i) * 0.001, privateScore: i == 0 ? 0.8 : 0, standalone: 0.9, quote: 0.8)
        }
        let selected = CreateIdeas.selected(cache)
        XCTAssertFalse(selected.contains { $0.id == values[0].id })
        XCTAssertLessThanOrEqual(selected.count, 3)
        for a in selected { for b in selected where a.id != b.id { XCTAssertTrue(a.last! < b.first! || b.last! < a.first!) } }
        cache.dismissed.formUnion(selected.map(\.id))
        XCTAssertTrue(Set(CreateIdeas.selected(cache).map(\.id)).isDisjoint(with: selected.map(\.id)))
    }
    func testCacheKeepsRejectionsAndBatchesAreBounded() {
        let values = CreateIdeas.candidates(key: "slowclaw_journal", content: "source", body: "source", timing: transcript())
        var cache = CreateIdeas.Cache(); cache.reconcile(values)
        let first = values[0]
        cache.decisions[first.id] = .init(id: first.id, score: 0.1, privateScore: 0, standalone: 0.9, quote: 0)
        cache.reconcile(values)
        XCTAssertNotNil(cache.decisions[first.id], "Rejected candidates should not trigger another paid call.")
        for batch in CreateIdeas.batches(values) { XCTAssertLessThanOrEqual(batch.count, 12) }
        cache.reconcile([]); XCTAssertTrue(cache.decisions.isEmpty)
    }
    func testTextFallbackNeverInventsTiming() {
        let values = CreateIdeas.candidates(key: "slowclaw_journal", content: "source", body: "A thoughtful practice leaves room for a different point of view.", timing: nil)
        XCTAssertEqual(values.count, 1)
        XCTAssertNil(values[0].first); XCTAssertNil(values[0].start); XCTAssertNil(values[0].timingID)
    }
}
