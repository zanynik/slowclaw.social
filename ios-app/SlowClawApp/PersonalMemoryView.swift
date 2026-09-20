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
                JevMemoryList()
                if !state.excludedMemoryKeys.isEmpty {
                    Section("Excluded journals") {
                        ForEach(state.excludedMemoryKeys.sorted(), id: \.self) { key in
                            if let entry = state.memorySource(key) {
                                Button("Include: " + String(entry.content.prefix(70))) { state.includeInMemory(key) }
                            }
                        }
                    }
                }
            }.navigationTitle("Memory")
                .sheet(item: $source) { JournalDetailView(entry: $0).environmentObject(state) }
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}
