import Foundation
import NaturalLanguage

struct ReadingSignal: Codable {
    let topics: [String]
    let date: Date
    var preference: Int // -1 less, 0 read, +1 more
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
