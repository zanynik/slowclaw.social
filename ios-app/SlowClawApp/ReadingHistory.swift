import Foundation
import NaturalLanguage

struct ReadingSignal: Codable {
    let topics: [String]
    let date: Date
    var preference: Int // -1 less, 0 read, +1 more, 2 just curious (no topics)

    func weight(at now: Date) -> Double {
        guard preference != 2 else { return 0 }
        let days = max(0, now.timeIntervalSince(date) / 86_400)
        let base = preference < 0 ? -0.5 : preference > 0 ? 0.45 : 0.15
        return base * pow(0.5, days / 14)
    }
}

/// A small local history of feed metadata, never browser contents or URLs.
enum ReadingHistory {
    static let key = "slowclaw.reading-signals.v1"
    static func load() -> [String: ReadingSignal] {
        guard let data = UserDefaults.standard.data(forKey: key) else { return [:] }
        return (try? JSONDecoder().decode([String: ReadingSignal].self, from: data)) ?? [:]
    }
    static func save(_ signals: [String: ReadingSignal]) {
        if let data = try? JSONEncoder().encode(signals) { UserDefaults.standard.set(data, forKey: key) }
    }
    static func topics(title: String, summary: String) -> [String] {
        let text = String((title + ". " + summary).prefix(1800))
        let tagger = NLTagger(tagSchemes: [.lexicalClass])
        tagger.string = text
        var words: [String] = []
        tagger.enumerateTags(in: text.startIndex..<text.endIndex, unit: .word,
                             scheme: .lexicalClass, options: [.omitWhitespace, .omitPunctuation]) { tag, range in
            if tag == .noun {
                let word = text[range].lowercased()
                if word.count >= 4, !words.contains(word) { words.append(word) }
            }
            return words.count < 8
        }
        return words
    }
}

/// Local metadata only. No page contents/cookies; bounded to 200 by the caller.
struct ReadingVisit: Codable, Identifiable {
    static let minimumSeconds: TimeInterval = 30
    let url: String
    let title: String
    let source: String
    let date: Date
    let seconds: TimeInterval
    var id: String { url }
    var duration: String { seconds < 60 ? "<1 min" : "\(Int(seconds / 60)) min" }
    private static var file: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("reading-history-v1.json")
    }
    static func load() -> [String: ReadingVisit] {
        (try? JSONDecoder().decode([String: ReadingVisit].self, from: Data(contentsOf: file))) ?? [:]
    }
    static func save(_ visits: [String: ReadingVisit]) throws {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(visits).write(to: file, options: [.atomic, .completeFileProtection])
    }
}
