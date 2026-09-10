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
    @State private var matches: Set<String> = []
    @State private var searching = false
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Your experiences, questions and stated views, with their original passages. These are tentative notes, not facts about who you are. Correct or forget anything.")
                        .font(.callout).foregroundStyle(.secondary)
                    Text("Reads compares meaning on this device where Apple's language model is available. Other languages use topic matching. Similarity doesn't mean agreement or truth.")
                        .font(.caption).foregroundStyle(.secondary)
                    Toggle("Prepare occasional short posts", isOn: $state.automaticDrafts)
                    Toggle("Prepare a weekly reflection", isOn: $state.automaticReflections)
                    Text("At most one per day, from recent journals. Always private until you review and publish.")
                        .font(.caption).foregroundStyle(.secondary)
                    if let status = state.memoryStatus { Text(status).font(.caption) }
                    if !state.localLLM.loaded { Text("A downloaded local model resumes this work when the app is idle enough. Model downloads are managed in Settings.").font(.caption) }
                }
                Section {
                    NavigationLink("Questions you’re following") { QuestionThreadsView() }
                    if let error = state.questionError { Text(error).font(.caption).foregroundStyle(.red) }
                }
                Section { WeeklyReflectionCard() }
                Section("From your journals") {
                    if searching { ProgressView("Searching on this device…") }
                    if state.personalMemories.isEmpty {
                        Text("Source-linked notes will appear after local processing.").foregroundStyle(.secondary)
                    }
                    if !query.isEmpty && !searching && matches.isEmpty {
                        Text("No close matches. Try another word or phrase.").foregroundStyle(.secondary)
                    }
                    ForEach(state.personalMemories.filter { query.isEmpty || matches.contains($0.id) }) { row in
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
            .searchable(text: $query, prompt: "Find a thought or experience")
            .task(id: query + String(state.contextRevision)) {
                guard !query.isEmpty else { matches = []; searching = false; return }
                searching = true
                do { try await Task.sleep(for: .milliseconds(300)) } catch { return }
                let results = await state.searchPersonalContext(query)
                guard !Task.isCancelled else { return }
                matches = Set(results.map(\.id)); searching = false
            }
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
