import SwiftUI

struct PersonalMemoryRow: Identifiable {
    let id: String
    let insight: MemoryInsight
    let date: Date
}

struct PersonalMemoryView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var source: SlowClawMemoryEntry?
    var body: some View {
        NavigationStack {
            List {
                Section { JevConnectionCard(showsMemoryLink: false) }
                JevMemoryList()
                Section { NavigationLink("Questions you’re following") { QuestionThreadsView() } }
                Section("Recent source journals") {
                    ForEach(Array(state.liteJournals.prefix(24)), id: \.key) { entry in
                        Button { source = entry } label: { Text(String(entry.content.prefix(100))).lineLimit(2) }
                    }
                }
                if !state.excludedMemoryKeys.isEmpty {
                    Section("Excluded journals") {
                        ForEach(state.excludedMemoryKeys.sorted(), id: \.self) { key in
                            if let entry = state.memorySource(key) {
                                Button("Include: " + String(entry.content.prefix(70))) { state.includeInMemory(key) }
                            }
                        }
                    }
                }
            }.navigationTitle("Personal memory")
                .sheet(item: $source) { JournalDetailView(entry: $0).environmentObject(state) }
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}
