import XCTest
@testable import Runtime

@MainActor final class ReadingRegressionTests: XCTestCase {
    private func item(_ id: String, url: String? = nil) -> RankedFeedItem {
        .init(id: id, title: "Composting experiment", link: url ?? "https://example.com/\(id)",
              description: "Small garden experiments", sourceLabel: "Garden journal", score: 0,
              readMinutes: 2, sourcePlatform: "web", thumbnailURL: nil)
    }
    func testFinishingOneArticleKeepsOtherApprovedReads() {
        let state = ReadingRegression(), first = item("first"), second = item("second")
        state.approve([first, second, item("duplicate", url: first.link)])
        state.record(first, seconds: 120)
        XCTAssertEqual(state.relevantReads.map(\.id), [second.id])
        XCTAssertEqual(state.readsDecisions.count, 3)
        XCTAssertEqual(state.memoryRevision, 1)
        XCTAssertNotNil(state.readingVisits[first.link])
        state.clearReadingHistory()
        XCTAssertEqual(state.relevantReads.count, 3, "Clearing history restores read articles without losing ranking.")
    }
    func testQuickVisitAndFeedbackDoNotClearOtherArticles() {
        let state = ReadingRegression(), first = item("first"), second = item("second")
        state.approve([first, second])
        state.record(first, seconds: 5)
        XCTAssertEqual(state.relevantReads.count, 2)
        state.rememberArticle(first, preference: -1)
        XCTAssertEqual(state.relevantReads.map(\.id), [second.id])
        state.rememberArticle(first, preference: 1)
        XCTAssertEqual(state.relevantReads.count, 2)
        state.clearReadingHistory()
    }
    func testTransportRefreshKeepsApprovedReadsAndUnchangedIDs() {
        let state = ReadingRegression(), kept = item("kept"), recycled = item("old")
        state.approve([kept, recycled])
        state.merge([item("new-id", url: recycled.link), item("fresh")])
        XCTAssertEqual(Set(state.relevantReads.map(\.id)), Set([kept.id, recycled.id]))
        XCTAssertTrue(state.readsItems.contains { $0.id == "fresh" })
        XCTAssertEqual(state.readsItems.filter { $0.link == recycled.link }.count, 1)
    }
    func testRefreshCapPreservesApprovedReadsButEditedContentNeedsNewDecision() {
        let state = ReadingRegression(), kept = item("kept")
        state.approve([kept])
        state.merge((0..<120).map { item("fresh-\($0)") })
        XCTAssertEqual(state.readsItems.count, 120)
        XCTAssertEqual(state.relevantReads.map(\.id), [kept.id])
        let edited = RankedFeedItem(id: kept.id, title: "Changed content", link: kept.link,
            description: "A different subject", sourceLabel: "Garden journal", score: 0, readMinutes: 2)
        state.merge([edited])
        XCTAssertFalse(state.relevantReads.contains { $0.link == kept.link })
    }
    func testRelaunchRestoresOnlyExactContentAndCurrentProfile() async {
        let state = ReadingRegression(), kept = item("kept")
        state.readsItems = [kept]
        state.cacheApproval(kept)
        state.readsRefreshedAt = Date()
        await state.loadReads()
        XCTAssertEqual(state.relevantReads.map(\.id), [kept.id])
        XCTAssertEqual(state.fetchCount, 0)
        state.memoryRevision += 1
        state.readsDecisions = [:]
        state.personaWeights[0] = 0; state.personaWeights[1] = 1
        await state.loadReads()
        XCTAssertTrue(state.relevantReads.isEmpty, "A different journal profile must not reuse the old score.")
    }
    func testCancellingReadsGestureDoesNotCancelRefreshAndRepeatedCallsJoin() async {
        let state = ReadingRegression()
        let pull = Task { await state.loadReads(force: true) }
        while state.fetchCount == 0 { await Task.yield() }
        pull.cancel()
        await state.loadReads(force: true)
        await pull.value
        XCTAssertTrue(state.fetchCompleted)
        XCTAssertEqual(state.fetchCount, 1)
        XCTAssertNil(state.readsRefreshTask)
    }
    func testCancellingCreateGestureDoesNotCancelScanAndNextPullStartsNewPage() async {
        let state = CreateRefreshRegression()
        let pull = Task { await state.refreshCreateIdeas() }
        while state.scanCount == 0 { await Task.yield() }
        pull.cancel()
        await state.refreshCreateIdeas()
        await pull.value
        XCTAssertTrue(state.scanCompleted)
        XCTAssertEqual(state.scanCount, 1)
        XCTAssertFalse(state.createBusy)
        await state.refreshCreateIdeas()
        XCTAssertEqual(state.scanCount, 2)
    }

}
