import Foundation

/// Native speech spans: normally words, occasionally a short utterance. Never
/// invent timing inside a span or align rewritten text by a character ratio.
struct TimedTranscript: Codable, Sendable {
    struct Word: Codable, Sendable, Equatable {
        let text: String
        let start: Double
        let end: Double
    }
    var version = 1
    let text: String
    let words: [Word]

    var valid: Bool {
        guard version == 1, !text.isEmpty, !words.isEmpty, words.count <= 100_000 else { return false }
        var previous = -1.0
        for word in words {
            guard !word.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  word.start.isFinite, word.end.isFinite, word.start >= 0,
                  word.end > word.start, word.start >= previous else { return false }
            previous = word.start
        }
        return true
    }

    /// Returns nil for absent or ambiguous text, including repeated quotes.
    func matchingWords(_ excerpt: String) -> ClosedRange<Int>? {
        func tokens(_ text: String) -> [String] {
            text.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
        }
        let query = tokens(excerpt)
        let indexed = words.enumerated().flatMap { index, word in tokens(word.text).map { ($0, index) } }
        guard !query.isEmpty, query.count <= indexed.count else { return nil }
        var found: ClosedRange<Int>?
        for start in 0...(indexed.count - query.count) {
            guard indexed[start..<(start + query.count)].map({ $0.0 }) == query else { continue }
            if found != nil { return nil }
            found = indexed[start].1...indexed[start + query.count - 1].1
        }
        return found
    }

    func clip(_ selection: ClosedRange<Int>, audioDuration: Double) -> Clip? {
        guard valid, words.indices.contains(selection.lowerBound), words.indices.contains(selection.upperBound),
              audioDuration.isFinite, audioDuration > 0 else { return nil }
        let selected = Array(words[selection])
        let start = max(0, selected[0].start - 0.08)
        let end = min(audioDuration, selected.last!.end + 0.12)
        guard end > start, end - start <= 90, selected.last!.end <= audioDuration + 0.1 else { return nil }
        return Clip(start: start, end: end, words: selected.map { Word(text: $0.text, start: $0.start - start, end: min(end, $0.end) - start) })
    }

    struct Clip: Sendable {
        let start: Double
        let end: Double
        let words: [Word]
        var duration: Double { end - start }
        /// Short pages keep captions legible without tiny text or a scrolling wall.
        func page(at time: Double) -> (words: [Word], active: Int?) {
            let index = words.lastIndex(where: { $0.start <= time }) ?? 0
            let pageStart = (index / 6) * 6
            let page = Array(words[pageStart..<min(pageStart + 6, words.count)])
            let active = page.firstIndex { time >= $0.start && time < $0.end }
            return (page, active)
        }
    }
}

enum TimedTranscriptStore {
    struct AudioStamp: Codable, Equatable, Sendable {
        let size: Int
        let modified: Date
    }
    private struct Record: Codable {
        let audio: AudioStamp
        let transcript: TimedTranscript
    }
    static func stamp(_ url: URL) -> AudioStamp? {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
              let size = values.fileSize, let date = values.contentModificationDate else { return nil }
        return .init(size: size, modified: date)
    }
    static func url(for audio: URL) -> URL { audio.appendingPathExtension("words.json") }
    static func load(for audio: URL) -> TimedTranscript? {
        guard let data = try? Data(contentsOf: url(for: audio)), data.count <= 24_000_000,
              let record = try? JSONDecoder().decode(Record.self, from: data),
              record.audio == stamp(audio), record.transcript.valid else { return nil }
        return record.transcript
    }
    static func save(_ transcript: TimedTranscript, for audio: URL, expected: AudioStamp? = nil) throws {
        guard transcript.valid, let current = stamp(audio), expected == nil || expected == current else {
            throw CocoaError(.fileReadCorruptFile)
        }
        try JSONEncoder().encode(Record(audio: current, transcript: transcript))
            .write(to: url(for: audio), options: [.atomic, .completeFileProtection])
    }
    static func remove(for audio: URL) { try? FileManager.default.removeItem(at: url(for: audio)) }
}
