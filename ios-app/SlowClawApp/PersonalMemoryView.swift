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
        let topics = state.personaTopics
        NavigationStack {
            List {
                if state.jevBusy { ProgressView(state.jevStatus ?? "Updating your interests…") }
                if topics.isEmpty {
                    Text("Record a journal to build your topic profile.")
                } else {
                    Section {
                        ForEach(topics, id: \.name) { topic in
                            VStack(alignment: .leading) {
                                HStack {
                                    Text(topic.name)
                                    Spacer()
                                    Text(topic.weight, format: .percent.precision(.fractionLength(1))).foregroundStyle(.secondary)
                                }
                                ProgressView(value: topic.weight / max(topics.first?.weight ?? 1, 0.001))
                            }
                        }
                    } footer: {
                        Text("Your share of interest across 224 topics, built from journals. Recent journals count more. These weights rank Reads; they are not personality facts.")
                    }
                }
                Button("Update interests") { state.startJevMemory() }.disabled(state.jevBusy)
                if !state.excludedMemoryKeys.isEmpty {
                    Section("Excluded journals") {
                        ForEach(state.excludedMemoryKeys.sorted(), id: \.self) { key in
                            if let entry = state.memorySource(key) {
                                Button("Include: " + String(entry.content.prefix(70))) { state.includeInMemory(key) }
                            }
                        }
                    }
                }
            }.navigationTitle("Your interests")
                .sheet(item: $source) { JournalDetailView(entry: $0).environmentObject(state) }
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}
