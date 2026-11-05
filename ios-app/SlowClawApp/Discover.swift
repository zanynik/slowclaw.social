import Foundation
import NaturalLanguage

// Shared by News and Videos (prototyped on real journals with the same MiniLM; see docs/discover.md).
//
// The book's chapters are the reader's themes. Each theme gets a few searches built from the
// organisations, products and concepts it keeps naming (never people or places). Results from
// all searches are pooled and scored against the theme's own passages; only results that are
// clearly close are kept, and a theme with nothing close shows nothing rather than filler.

enum ThemeSearches {
    private static let notNames: Set<String> = [
        "i", "i'm", "i've", "i'll", "okay", "ok", "yeah", "so", "and", "but", "the", "a", "an", "this", "that", "it", "it's",
        "we", "they", "he", "she", "you", "my", "our", "anyway", "now", "then", "maybe", "because", "when", "what", "why", "how",
        "yes", "no", "hello", "well", "also", "just", "like", "right", "since", "are", "one", "god", "english", "monday",
        "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday", "january", "february", "march", "april", "may",
        "june", "july", "august", "september", "october", "november", "december",
    ]

    /// Organisations (as tagged on the phone), products and acronyms, with counts. Never people or places.
    static func namedThings(in texts: [String]) -> [String: Int] {
        var counts: [String: Int] = [:]
        let tagger = NLTagger(tagSchemes: [.nameType])
        for text in texts {
            tagger.string = text
            var people = Set<String>(), places = Set<String>()
            tagger.enumerateTags(in: text.startIndex..<text.endIndex, unit: .word, scheme: .nameType,
                                 options: [.omitPunctuation, .omitWhitespace, .joinNames]) { tag, range in
                let token = String(text[range])
                switch tag {
                case .personalName?: people.formUnion(token.lowercased().split(separator: " ").map(String.init))
                case .placeName?: places.insert(token.lowercased())
                case .organizationName?: counts[token, default: 0] += 1
                default: break
                }
                return true
            }
            // Products and acronyms (DeepMind, OpenAI, GPU, MCP): mixed or full capitals, which first
            // names never have. Plain capitalised words are never used, so no one's name slips in.
            for sentence in BookOrganizer.sentences(text) {
                for w in sentence.split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "-" }).map(String.init) {
                    let lower = w.lowercased()
                    guard w.count >= 2, w.count <= 20, !notNames.contains(lower), !people.contains(lower), !places.contains(lower),
                          w.first?.isUppercase == true else { continue }
                    let uppers = w.filter(\.isUppercase).count
                    let acronym = uppers == w.count && w.count <= 6
                    let product = uppers >= 2 && w.dropFirst().contains(where: \.isLowercase)
                    if acronym || product { counts[w, default: 0] += 1 }
                }
            }
        }
        return counts
    }

    /// Up to five searches per theme: its most distinctive named things and concept phrases.
    static func searches(for themes: [BookStore.Theme]) -> [[String]] {
        let concepts = BookOrganizer.keyphrases(groups: themes.map(\.texts), perGroup: 6, minCount: 3)
        let named = themes.map { namedThings(in: $0.texts) }
        var spread: [String: Int] = [:]
        for n in named { for k in n.keys { spread[k.lowercased(), default: 0] += 1 } }
        return themes.indices.map { t in
            // Named things this theme mentions at least twice and most other themes do not.
            let names = named[t].filter { $0.value >= 2 && (spread[$0.key.lowercased()] ?? 0) <= max(1, themes.count / 2) }
                .sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }.prefix(3).map(\.key)
            let phrases = concepts[t].filter { $0.contains(" ") }.prefix(3)
            var out: [String] = []
            for q in names + phrases {
                guard let clean = NewsTopics.sanitizeQuery(q) ?? NewsTopics.sanitize(q),
                      !out.contains(where: { $0.caseInsensitiveCompare(clean) == .orderedSame }) else { continue }
                out.append(clean)
            }
            return Array(out.prefix(5))
        }
    }
}

enum Relevance {
    /// How close a result is to a theme: half its nearest passage, half the theme as a whole.
    static func score(_ v: [Float], passages: [[Float]], centroid: [Float]) -> Float {
        let nearest = passages.map { BookEngine.similarity(v, $0) }.max() ?? 0
        return 0.5 * nearest + 0.5 * BookEngine.similarity(v, centroid)
    }

    static func centroid(_ vs: [[Float]]) -> [Float] {
        guard let first = vs.first else { return [] }
        var m = [Float](repeating: 0, count: first.count)
        for v in vs { for i in m.indices { m[i] += v[i] } }
        return BookEngine.normalized(m)
    }

    /// Indices worth showing: above the bar, near the theme's best, at most `limit`.
    static func keep(scores: [Float], minimum: Float, margin: Float = 0.12, limit: Int) -> [Int] {
        guard let best = scores.max() else { return [] }
        let bar = max(minimum, best - margin)
        return scores.indices.filter { scores[$0] >= bar }.sorted { scores[$0] > scores[$1] }.prefix(limit).map { $0 }
    }
}
