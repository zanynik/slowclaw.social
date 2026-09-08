import Foundation

/// A source-backed observation, never an inferred personality or moral judgement.
struct MemoryInsight: Codable, Equatable {
    enum Kind: String, Codable, CaseIterable { case interest, project, question }
    var summary: String
    let excerpt: String
    let kind: Kind
    var corrected: Bool = false

    struct Extraction: Decodable {
        let summary: String
        let excerpt: String
        let kind: Kind
        let topics: [String]
        let post: String?
    }

    static func parse(_ text: String, source: String) -> Extraction? {
        guard let first = text.firstIndex(of: "{"), let last = text.lastIndex(of: "}"),
              first < last, let data = String(text[first...last]).data(using: .utf8),
              let value = try? JSONDecoder().decode(Extraction.self, from: data),
              (12...240).contains(value.summary.count),
              (20...500).contains(value.excerpt.count),
              source.contains(value.excerpt), !value.topics.isEmpty else { return nil }
        return value
    }

    /// Samples the beginning, middle and ending without silently treating a
    /// long recording's introduction as its complete meaning.
    static func sample(_ text: String) -> String {
        let chars = Array(text)
        guard chars.count > 1800 else { return text }
        let middle = chars.count / 2 - 300
        return String(chars.prefix(600)) + "\n[…]\n"
            + String(chars[middle..<(middle + 600)]) + "\n[…]\n" + String(chars.suffix(600))
    }

    static func validPost(_ text: String?) -> String? {
        guard let post = text?.trimmingCharacters(in: .whitespacesAndNewlines),
              (30...300).contains(post.count),
              !post.contains("http"), !post.contains("@") else { return nil }
        return post
    }
}
