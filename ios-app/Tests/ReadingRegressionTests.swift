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
}
