import Foundation

/// User-followed questions are distinct from tentative AI memory extractions.
/// Keep source IDs, not copied private passages, so visibility is checked on use.
struct QuestionThread: Codable, Identifiable, Equatable {
    enum Status: String, Codable, CaseIterable { case active, paused, resolved }
    let id: String
    var question: String
    var sourceKeys: [String]
    var status: Status
    let createdAt: Date
    var updatedAt: Date
    var note: String

    static func make(question: String, sourceKey: String, now: Date = Date()) -> Self? {
        let text = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (5...240).contains(text.count), !sourceKey.isEmpty else { return nil }
        return Self(id: UUID().uuidString, question: text, sourceKeys: [sourceKey],
                    status: .active, createdAt: now, updatedAt: now, note: "")
    }
}

/// A stable daily shortlist. Only IDs are persisted; removed/disliked content
/// is filtered at display time. More results require an explicit exploration.
struct DailySelection: Codable, Equatable {
    var day: String
    var readIDs: [String]
    var questionID: String?
    var dismissed: Bool = false

    static func dayKey(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return "\(c.year ?? 0)-\(c.month ?? 0)-\(c.day ?? 0)"
    }

    static func select(_ candidates: [(id: String, source: String)], limit: Int = 3) -> [String] {
        var seen = Set<String>(), sources = Set<String>(), selected: [String] = []
        for item in candidates {
            guard selected.count < limit else { break }
            guard !seen.contains(item.id), sources.insert(item.source).inserted else { continue }
            seen.insert(item.id); selected.append(item.id)
        }
        return selected
    }
}
