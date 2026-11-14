import AppIntents
import SwiftUI

/// Lets Siri, Spotlight, the Action Button and Shortcuts open SlowClaw straight
/// into the recorder ("Record a journal in SlowClaw").
@MainActor
final class RecordRequest: ObservableObject {
    static let shared = RecordRequest()
    @Published var pending = false
}

struct RecordJournalIntent: AppIntent {
    static let title: LocalizedStringResource = "Record a journal"
    static let description = IntentDescription("Opens SlowClaw and starts recording right away.")
    static let openAppWhenRun = true

    @MainActor
    func perform() async throws -> some IntentResult {
        RecordRequest.shared.pending = true
        return .result()
    }
}

struct SlowClawShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: RecordJournalIntent(),
            phrases: [
                "Record a journal in \(.applicationName)",
                "Start \(.applicationName)",
                "New \(.applicationName) entry",
            ],
            shortTitle: "Record journal",
            systemImageName: "mic.fill"
        )
    }
}
