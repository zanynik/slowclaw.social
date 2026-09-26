import XCTest
@testable import Runtime

final class TimedTranscriptTests: XCTestCase {
    func testSourceMatchingRejectsAmbiguityAndKeepsAbsoluteTimes() {
        let value = TimedTranscript(text: "A useful thought. Another useful thought.", words: [
            .init(text: "A", start: 10, end: 10.2), .init(text: "useful", start: 10.3, end: 10.7), .init(text: "thought.", start: 11, end: 11.5),
            .init(text: "Another", start: 20, end: 20.5), .init(text: "useful", start: 20.6, end: 21), .init(text: "thought.", start: 21, end: 21.5)])
        XCTAssertNil(value.matchingWords("useful thought"))
        XCTAssertNil(value.matchingWords("invented words"))
        XCTAssertEqual(value.matchingWords("ANOTHER useful thought!"), 3...5)
        let clip = value.clip(3...5, audioDuration: 25)!
        XCTAssertEqual(clip.start, 19.92, accuracy: 0.001)
        XCTAssertEqual(clip.words[0].start, 0.08, accuracy: 0.001)
        XCTAssertEqual(clip.page(at: 0.4).active, 0)
        XCTAssertNil(clip.page(at: 0).active)
    }
    func testInvalidAndOutOfRecordingTimingIsRejected() {
        for word in [TimedTranscript.Word(text: "word", start: .nan, end: 1), .init(text: "word", start: 2, end: 1), .init(text: "", start: 0, end: 1)] {
            XCTAssertFalse(TimedTranscript(text: "word", words: [word]).valid)
        }
        let value = TimedTranscript(text: "long", words: [.init(text: "long", start: 0, end: 95)])
        XCTAssertNil(value.clip(0...0, audioDuration: 100))
        XCTAssertNil(value.clip(0...0, audioDuration: 5))
    }
    func testCaptionPagesFollowNativeBoundariesAndPauseWithoutHighlight() {
        let value = TimedTranscript(text: "words", words: (0..<9).map { .init(text: "word\($0)", start: Double($0) * 2, end: Double($0) * 2 + 0.8) })
        let clip = value.clip(0...8, audioDuration: 20)!
        XCTAssertEqual(clip.page(at: 12.2).words[0].text, "word6")
        XCTAssertEqual(clip.page(at: 12.2).active, 0)
        XCTAssertNil(clip.page(at: 13.2).active)
    }
    func testAudioReplacementInvalidatesPersistedTiming() throws {
        let audio = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: audio); TimedTranscriptStore.remove(for: audio) }
        try Data([1, 2]).write(to: audio)
        let value = TimedTranscript(text: "word", words: [.init(text: "word", start: 0, end: 1)])
        try TimedTranscriptStore.save(value, for: audio)
        XCTAssertNotNil(TimedTranscriptStore.load(for: audio))
        try Data([3, 4, 5]).write(to: audio)
        XCTAssertNil(TimedTranscriptStore.load(for: audio))
        try TimedTranscriptStore.save(value, for: audio)
        XCTAssertNotNil(TimedTranscriptStore.load(for: audio))
        let stamp = TimedTranscriptStore.stamp(audio)!
        try Data([6, 7, 8]).write(to: audio)
        try FileManager.default.setAttributes([.modificationDate: stamp.modified.addingTimeInterval(1)], ofItemAtPath: audio.path)
        XCTAssertNil(TimedTranscriptStore.load(for: audio), "Same-size replacements also invalidate timings.")
    }
}
