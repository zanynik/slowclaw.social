import SwiftUI

struct PersonalMemoryRow: Identifiable {
    let id: String
    let insight: MemoryInsight
    let date: Date
}

struct PersonalMemoryView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Observations from your journals, not a profile of who you are. Correct or forget anything. Long entries are sampled; these notes may miss context.")
                        .font(.callout).foregroundStyle(.secondary)
                    Text("Reads compares meaning on this device where Apple's language model is available. Other languages use topic matching. Similarity doesn't mean agreement or truth.")
                        .font(.caption).foregroundStyle(.secondary)
                    Toggle("Prepare occasional short posts", isOn: $state.automaticDrafts)
                    Text("At most one per day, from recent journals. Always private until you review and publish.")
                        .font(.caption).foregroundStyle(.secondary)
                    if let status = state.memoryStatus { Text(status).font(.caption) }
                    if !state.localLLM.loaded { Text("Activate your downloaded local model in Settings to learn from new journals.").font(.caption) }
                }
                Section("From your journals") {
                    if state.personalMemories.isEmpty {
                        Text("Source-linked notes will appear after local processing.").foregroundStyle(.secondary)
                    }
                    ForEach(state.personalMemories) { row in
                        MemoryInsightRow(row: row)
                    }
                }
                if !state.excludedMemoryKeys.isEmpty {
                    Section("Excluded journals") {
                        ForEach(state.excludedMemoryKeys.sorted(), id: \.self) { key in
                            if let entry = state.memorySource(key) {
                                HStack {
                                    Text(journalTitleOf(entry)).lineLimit(2)
                                    Spacer()
                                    Button("Include") { state.includeInMemory(key) }
                                }
                            }
                        }
                    }
                }
            }
            .navigationTitle("Personal memory")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}

private struct MemoryInsightRow: View {
    @EnvironmentObject var state: AppState
    let row: PersonalMemoryRow
    @State private var editing = false
    @State private var summary = ""
    @State private var source: SlowClawMemoryEntry?
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(row.insight.kind.rawValue.capitalized + " · " + row.date.formatted(date: .abbreviated, time: .omitted))
                .font(.caption).foregroundStyle(.secondary)
            if editing {
                TextField("What should this remember?", text: $summary, axis: .vertical)
                HStack {
                    Button("Save") { state.correctMemory(key: row.id, summary: summary); editing = false }
                        .disabled(summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Button("Cancel") { editing = false }
                }
            } else {
                Text(row.insight.summary)
                DisclosureGroup("Source passage") {
                    Text(row.insight.excerpt).font(.callout).foregroundStyle(.secondary)
                    Button("Open journal") { source = state.memorySource(row.id) }
                }
                HStack {
                    Button("Correct") { summary = row.insight.summary; editing = true }
                    Spacer()
                    Button("Forget & exclude", role: .destructive) { state.excludeFromMemory(row.id) }
                }.font(.caption)
            }
        }.padding(.vertical, 5).buttonStyle(.borderless)
        .sheet(item: $source) { JournalDetailView(entry: $0).environmentObject(state) }
    }
}
