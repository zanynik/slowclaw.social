import Foundation

struct WeeklyReflection: Codable {
    let createdAt: Date
    let reflection: GroundedReflection
    let sources: [ContextDocument]
    var dismissed: Bool = false
    static let defaultsKey = "slowclaw.weekly-reflection.v1"
    static func load() -> Self? {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey) else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }
    func save() throws { UserDefaults.standard.set(try JSONEncoder().encode(self), forKey: Self.defaultsKey) }
}

struct DraftEvidence: Codable, Equatable {
    let journalKey: String
    let quote: String
    func matches(_ text: String?) -> Bool { text?.contains(quote) == true && quote.count >= 20 }
    static func load(_ draftKey: String) -> Self? {
        guard let data = UserDefaults.standard.data(forKey: "slowclaw.draft-evidence." + draftKey) else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }
    func save(_ draftKey: String) throws {
        UserDefaults.standard.set(try JSONEncoder().encode(self), forKey: "slowclaw.draft-evidence." + draftKey)
    }
}
