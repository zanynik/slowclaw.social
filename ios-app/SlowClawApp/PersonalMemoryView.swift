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
        let trends = state.personaTrends
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
                                    Text(trends[topic.name] ?? "–")
                                        .accessibilityLabel(trends[topic.name] == "↑" ? "Rising this week" : trends[topic.name] == "↓" ? "Falling this week" : trends[topic.name] == "→" ? "Stable this week" : "Not enough history")
                                }
                                ProgressView(value: topic.weight / max(topics.first?.weight ?? 1, 0.001))
                            }
                        }
                    } footer: {
                        Text("Share of attention across 224 topics, not personality facts. Arrows compare the last seven days with the previous seven; a dash means there is not enough history. Changes within one percentage point count as stable.")
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
