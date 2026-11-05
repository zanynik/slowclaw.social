import Foundation

/// Where a journal is in the capture pipeline. Only `.ready` journals are
/// organized or synced.
enum JournalStatus: String, Codable {
    case transcribing   // audio saved, transcript still being produced
    case cleaning       // transcript ready, cleanup in progress
    case ready
}

struct Journal: Codable, Identifiable, Hashable {
    var id: String
    var title: String
    var body: String
    /// Raw speech transcript before cleanup. Kept on the phone only.
    var transcript: String?
    /// Documents-relative audio path. Audio stays on the phone and is never synced.
    var audioPath: String?
    /// Later recordings that continued this entry (also phone-only).
    var moreAudio: [String]?
    var spaceID: String?
    var createdAt: Date
    var updatedAt: Date
    var status: JournalStatus
    var organized: Bool
    var deleted: Bool
    /// True when this record has local changes the cloud has not seen yet.
    var dirty: Bool

    var displayTitle: String {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !t.isEmpty { return t }
        switch status {
        case .transcribing: return "New recording"
        case .cleaning: return "Cleaning up…"
        case .ready:
            let first = body.split(separator: "\n").first.map(String.init) ?? ""
            return first.isEmpty ? "Untitled" : String(first.prefix(60))
        }
    }
}

struct Space: Codable, Identifiable, Hashable {
    var id: String
    var name: String
    /// SF Symbol name.
    var icon: String
    /// On-device generated overview of what is going on in this space.
    var summary: String
    var sortOrder: Int
    var createdAt: Date
    var updatedAt: Date
    var deleted: Bool
    var dirty: Bool
}

enum ItemKind: String, Codable, CaseIterable, Identifiable {
    case todo, idea, question, note
    var id: String { rawValue }
    var label: String {
        switch self {
        case .todo: return "To-dos"
        case .idea: return "Ideas"
        case .question: return "Questions"
        case .note: return "Notes"
        }
    }
    var singular: String {
        switch self {
        case .todo: return "To-do"
        case .idea: return "Idea"
        case .question: return "Question"
        case .note: return "Note"
        }
    }
    var symbol: String {
        switch self {
        case .todo: return "checkmark.circle"
        case .idea: return "lightbulb"
        case .question: return "questionmark.bubble"
        case .note: return "note.text"
        }
    }
}

struct SpaceItem: Codable, Identifiable, Hashable {
    var id: String
    var spaceID: String
    var journalID: String?
    var kind: ItemKind
    var text: String
    var done: Bool
    var createdAt: Date
    var updatedAt: Date
    var deleted: Bool
    var dirty: Bool
}

enum SpaceIcons {
    static let all = ["briefcase", "house", "heart", "lightbulb", "book", "person.2",
                      "figure.run", "leaf", "airplane", "dollarsign.circle", "music.note",
                      "hammer", "graduationcap", "sparkles", "tray"]

    /// A reasonable symbol for a space name the organizer invented.
    static func guess(for name: String) -> String {
        let n = name.lowercased()
        let table: [(String, String)] = [
            ("work", "briefcase"), ("job", "briefcase"), ("career", "briefcase"),
            ("family", "person.2"), ("friend", "person.2"), ("relation", "person.2"), ("kid", "person.2"),
            ("home", "house"), ("house", "house"),
            ("health", "heart"), ("fitness", "figure.run"), ("sport", "figure.run"),
            ("idea", "lightbulb"), ("project", "hammer"), ("build", "hammer"),
            ("learn", "graduationcap"), ("study", "graduationcap"), ("read", "book"),
            ("money", "dollarsign.circle"), ("finance", "dollarsign.circle"),
            ("travel", "airplane"), ("music", "music.note"), ("nature", "leaf"),
            ("reflect", "sparkles"), ("self", "sparkles"), ("mind", "sparkles"),
        ]
        return table.first { n.contains($0.0) }?.1 ?? "tray"
    }
}

/// Starter spaces created on first launch. The user can rename or delete them.
enum DefaultSpaces {
    static let all: [(String, String)] = [
        ("Work", "briefcase"),
        ("Family & Home", "house"),
        ("Health", "heart"),
        ("Ideas & Projects", "lightbulb"),
        ("Learning", "graduationcap"),
        ("Reflections", "sparkles"),
    ]
}

extension Date {
    var dayLabel: String {
        let cal = Calendar.current
        if cal.isDateInToday(self) { return "Today" }
        if cal.isDateInYesterday(self) { return "Yesterday" }
        let f = DateFormatter()
        f.dateFormat = cal.isDate(self, equalTo: Date(), toGranularity: .year) ? "EEEE, d MMM" : "d MMM yyyy"
        return f.string(from: self)
    }

    var timeLabel: String {
        let f = DateFormatter()
        f.timeStyle = .short
        f.dateStyle = .none
        return f.string(from: self)
    }
}

func newID(_ prefix: String) -> String {
    prefix + "_" + UUID().uuidString.lowercased()
}
