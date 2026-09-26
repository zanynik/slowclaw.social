import XCTest
@testable import Runtime

final class JournalPolishTests: XCTestCase {
    func testCleanupIsReversibleAndConservative() {
        let original = "Um, I think this helps. Uh, I-I am not sure."
        XCTAssertEqual(TranscriptCleanup.clean(original), "I think this helps. I am not sure.")
        XCTAssertEqual(original, "Um, I think this helps. Uh, I-I am not sure.")
        XCTAssertEqual(TranscriptCleanup.clean("No, no. Very very important."), "No, no. Very very important.")
        XCTAssertEqual(TranscriptCleanup.clean("I do not agree"), "I do not agree.")
        XCTAssertEqual(TranscriptCleanup.clean("विचार जतन करणे महत्त्वाचे आहे।"), "विचार जतन करणे महत्त्वाचे आहे।")
        XCTAssertEqual(TranscriptCleanup.clean(""), "")
        let cleaned = TranscriptCleanup.clean(original)
        XCTAssertEqual(TranscriptCleanup.clean(cleaned), cleaned)
    }
    func testTrendRequiresBothPeriodsAndComparesTopicShare() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        func record(_ topic: Int, days: Double) -> JevPersona.Record {
            var scores = Array(repeating: 0.0, count: JevPersona.topics.count)
            scores[topic] = 1
            return .init(fingerprint: "source", date: now.addingTimeInterval(-days * 86400), scores: scores)
        }
        XCTAssertTrue(JevPersona.trends([record(0, days: 1)], now: now).isEmpty)
        let trends = JevPersona.trends([record(0, days: 8), record(1, days: 1)], now: now)
        XCTAssertEqual(trends[JevPersona.topics[0]], "↓")
        XCTAssertEqual(trends[JevPersona.topics[1]], "↑")
        XCTAssertEqual(trends[JevPersona.topics[2]], "→")
        XCTAssertTrue(JevPersona.trends([record(0, days: -1), record(1, days: 8)], now: now).isEmpty)
        XCTAssertEqual(JevPersona.trends([record(0, days: 7), record(0, days: 0)], now: now)[JevPersona.topics[0]], "→")
    }
    func testDraftInboxCannotInventPublicationAndDiscardIsReversible() {
        XCTAssertEqual(DraftInbox.state(for: "draft", states: [:], confirmed: false), .new)
        XCTAssertEqual(DraftInbox.state(for: "draft", states: ["draft": "Published"], confirmed: false), .new)
        XCTAssertEqual(DraftInbox.state(for: "draft", states: ["draft": "Kept"], confirmed: true), .published)
        XCTAssertEqual(DraftInbox.state(for: "draft", states: ["draft": "Archived"], confirmed: true), .archived)
        XCTAssertEqual(DraftInbox.state(for: "draft", states: ["draft": "Kept"], confirmed: false), .kept)
    }
    func testTextImportBoundsAndPreservesUnicode() {
        XCTAssertEqual(JournalTextImport.decode(Data("\u{FEFF}My notes 🌿".utf8)), "My notes 🌿")
        XCTAssertNil(JournalTextImport.decode(Data([0xff])))
        XCTAssertNil(JournalTextImport.decode(Data("a\0b".utf8)))
        XCTAssertNil(JournalTextImport.decode(Data(" \n".utf8)))
        XCTAssertNil(JournalTextImport.decode(Data(repeating: 65, count: JournalTextImport.maximumBytes + 1)))
    }
    func testSharingIdeasFailClosedWithoutConflatingImportanceAndUsefulness() {
        let passage = JevMemory.Passage(id: "source", sourceKey: "journal", text: "A thought.", category: "insight", score: 1)
        XCTAssertTrue(JevIdeas.select([passage], decisions: [:]).isEmpty)
        for decision in [JevIdeas.Decision(id: "source", score: 0.69, privateScore: 0, standalone: 1, quote: 1),
                         .init(id: "source", score: 1, privateScore: 0.3, standalone: 1, quote: 1),
                         .init(id: "source", score: 1, privateScore: 0, standalone: 0.59, quote: 1),
                         .init(id: "source", score: .nan, privateScore: 0, standalone: 1, quote: 1)] {
            XCTAssertTrue(JevIdeas.select([passage], decisions: ["source": decision]).isEmpty)
        }
        let decision = JevIdeas.Decision(id: "source", score: 0.8, privateScore: 0.1, standalone: 0.8, quote: 0.8)
        XCTAssertEqual(JevIdeas.select([passage], decisions: ["source": decision]).count, 1)
        XCTAssertTrue(decision.shareableQuote)
    }
    func testReadingHistoryDurationIsMeasuredNotArticleEstimate() {
        let visit = ReadingVisit(url: "https://example.com", title: "Article", source: "Web", date: Date(), seconds: 425)
        XCTAssertEqual(visit.duration, "7 min")
        XCTAssertEqual(ReadingVisit.minimumSeconds, 30)
    }
}
