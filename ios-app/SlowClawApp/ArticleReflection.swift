import Foundation

struct ArticleReflection: Codable, Equatable {
    let title: String
    let url: URL

    static let storageKey = "slowclaw.reflection-sources.v1"
    static func load() -> [String: ArticleReflection] {
        guard let data = UserDefaults.standard.data(forKey: storageKey) else { return [:] }
        return (try? JSONDecoder().decode([String: ArticleReflection].self, from: data)) ?? [:]
    }
    static func save(_ sources: [String: ArticleReflection]) {
        if let data = try? JSONEncoder().encode(sources) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
    }
}
