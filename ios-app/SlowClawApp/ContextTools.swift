import Foundation

/// Immutable tool results. IDs and passages come from storage, never the LLM.
struct ContextDocument: Identifiable, Sendable, Codable {
    let id: String
    let title: String
    let text: String
    let date: Date
}

struct ContextCitation: Codable, Equatable {
    let id: String
    let quote: String
}

struct GroundedReflection: Codable, Equatable {
    let observation: String
    let question: String
    let citations: [ContextCitation]

    static func parse(_ raw: String, sources: [String: String]) -> GroundedReflection? {
        guard let first = raw.firstIndex(of: "{"), let last = raw.lastIndex(of: "}"), first < last,
              let data = String(raw[first...last]).data(using: .utf8),
              let value = try? JSONDecoder().decode(Self.self, from: data),
              (15...500).contains(value.observation.count),
              (10...240).contains(value.question.count),
              (1...3).contains(value.citations.count),
              value.citations.contains(where: { $0.id.hasPrefix("J") }),
              Set(value.citations.map(\.id)).count == value.citations.count,
              value.citations.allSatisfy({ citation in
                  (12...300).contains(citation.quote.count)
                      && sources[citation.id]?.contains(citation.quote) == true
              }) else { return nil }
        return value
    }
}

enum ContextTools {
    static func words(_ text: String) -> Set<String> {
        let stop: Set<String> = ["the", "and", "that", "this", "with", "from", "have", "was", "are", "for", "but", "not", "you", "your", "about", "would", "could", "should", "into", "they", "them", "what", "when", "how", "some", "been", "more", "than"]
        return Set(text.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 3 && !stop.contains($0) })
    }

    static func lexicalMatch(query: String, text: String) -> Double {
        let queryWords = words(query)
        guard !queryWords.isEmpty else { return 0 }
        return Double(queryWords.intersection(words(text)).count) / Double(queryWords.count)
    }
}

struct EvidenceArticle: Identifiable, Sendable {
    let id: String
    let title: String
    let excerpt: String
    let url: URL
    let source: String
}

/// User-triggered public background reading. Never accepts a model-generated
/// host or forwards journal text automatically. No cookies or persisted cache.
enum EvidenceSearch {
    enum Failure: LocalizedError {
        case query, unavailable, tooLarge
        var errorDescription: String? {
            switch self {
            case .query: return "Enter a short public topic without names or private details."
            case .unavailable: return "Wikipedia couldn't be reached. Your local reading suggestions are still available."
            case .tooLarge: return "The source returned too much data. Try a narrower topic."
            }
        }
    }

    static func request(query: String) throws -> URLRequest {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (3...80).contains(query.count), !query.contains("@"),
              !query.contains("://"), !query.contains("\n") else { throw Failure.query }
        var url = URLComponents(string: "https://en.wikipedia.org/w/api.php")!
        url.queryItems = ["action": "query", "format": "json", "formatversion": "2",
            "generator": "search", "gsrsearch": query, "gsrnamespace": "0", "gsrlimit": "5",
            "prop": "extracts", "exintro": "1", "explaintext": "1", "exchars": "1200"].sorted { $0.key < $1.key }
            .map { URLQueryItem(name: $0.key, value: $0.value) }
        var request = URLRequest(url: url.url!)
        request.timeoutInterval = 20
        request.setValue("SlowClaw/1.0 (https://github.com/zanynik/slowclaw.social)", forHTTPHeaderField: "User-Agent")
        return request
    }

    static func decode(_ data: Data) throws -> [EvidenceArticle] {
        struct Response: Decodable {
            struct Query: Decodable {
                struct Page: Decodable { let pageid: Int; let title: String; let extract: String?; let index: Int? }
                let pages: [Page]?
            }
            let query: Query?
        }
        let response = try JSONDecoder().decode(Response.self, from: data)
        return (response.query?.pages ?? []).sorted { ($0.index ?? 99) < ($1.index ?? 99) }.prefix(5).compactMap { page in
            guard page.pageid > 0, let text = page.extract, !text.isEmpty else { return nil }
            return EvidenceArticle(id: "wiki:\(page.pageid)", title: String(page.title.prefix(200)),
                excerpt: String(text.prefix(1200)),
                url: URL(string: "https://en.wikipedia.org/?curid=\(page.pageid)")!, source: "Wikipedia introduction")
        }
    }

    static func search(query: String) async throws -> [EvidenceArticle] {
        let request = try request(query: query)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { throw Failure.unavailable }
        var data = Data()
        for try await byte in bytes {
            try Task.checkCancellation()
            guard data.count < 100_000 else { throw Failure.tooLarge }
            data.append(byte)
        }
        return try decode(data)
    }
}
