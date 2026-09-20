import SwiftUI

struct PersonalMemoryRow: Identifiable {
    let id: String
    let insight: MemoryInsight
    let date: Date
}

struct PersonalMemoryView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var results: [(String, Double)] = []
    @State private var searching = false
    @State private var source: SlowClawMemoryEntry?
    @State private var searched = false
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Original journals are Kev's memory. Exclude any journal from its source page. Saved corrections below take precedence for Reads.")
                        .font(.callout).foregroundStyle(.secondary)
                    HStack {
                        TextField("Find a thought or experience", text: $query)
                        Button("Find") {
                            let request = query
                            searching = true; searched = true; results = []
                            Task {
                                let matches = await state.searchKevJournals(request)
                                if query == request { results = matches }
                                searching = false
                            }
                        }.disabled(query.isEmpty || searching || state.kevJournalBusy || state.readsDecisionBusy || !state.readsModelEnabled)
                    }
                    if searching { ProgressView("Checking journals with Kev…") }
                    Text("Search checks up to 24 recent journals. Scores are experimental estimates.").font(.caption)
                }
                if searched {
                    Section("Highest relevance first") {
                        ForEach(results, id: \.0) { result in
                            if let entry = state.memorySource(result.0), !state.excludedMemoryKeys.contains(result.0) {
                                Button { source = entry } label: {
                                    VStack(alignment: .leading) {
                                        Text(String(entry.content.prefix(160))).lineLimit(3)
                                        Text("Relevance \(Int(result.1 * 100))").font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                            }
                        }
                        if results.isEmpty && !searching { Text("No results yet. Activate Kev and try when other work finishes.").font(.caption) }
                    }
                }
                Section { NavigationLink("Questions you’re following") { QuestionThreadsView() } }
                if !state.personalMemories.isEmpty {
                    Section("Saved memory notes") { ForEach(state.personalMemories) { row in MemoryInsightRow(row: row) } }
                }
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
                .onChange(of: state.readsDecisionRevision) { _, _ in results = []; searched = false }
                .onChange(of: query) { _, _ in results = []; searched = false }
                .sheet(item: $source) { JournalDetailView(entry: $0).environmentObject(state) }
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
    @State private var kind: MemoryInsight.Kind = .interest
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(row.insight.kind.rawValue.capitalized + " · " + row.date.formatted(date: .abbreviated, time: .omitted))
                .font(.caption).foregroundStyle(.secondary)
            if editing {
                TextField("What should this remember?", text: $summary, axis: .vertical)
                Picker("Kind of note", selection: $kind) {
                    ForEach(MemoryInsight.Kind.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) }
                }
                HStack {
                    Button("Save") { state.correctMemory(key: row.id, summary: summary, kind: kind); editing = false }
                        .disabled(summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Button("Cancel") { editing = false }
                }
            } else {
                Text(row.insight.summary)
                NavigationLink("Explore connections") { ContextExplorer(journalKey: row.id).environmentObject(state) }
                FollowQuestionButton(sourceKey: row.id,
                    suggestion: row.insight.kind == .question ? row.insight.summary : "")
                DisclosureGroup("Source passage") {
                    Text(row.insight.excerpt).font(.callout).foregroundStyle(.secondary)
                    Button("Open journal") { source = state.memorySource(row.id) }
                }
                HStack {
                    Button("Correct") { summary = row.insight.summary; kind = row.insight.kind; editing = true }
                    Spacer()
                    Button("Forget & exclude", role: .destructive) { state.excludeFromMemory(row.id) }
                }.font(.caption)
            }
        }.padding(.vertical, 5).buttonStyle(.borderless)
        .sheet(item: $source) { JournalDetailView(entry: $0).environmentObject(state) }
    }
}
