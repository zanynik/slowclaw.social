import SwiftUI
import SlowClawFeed

/// Lite revisits exact source passages. It does not invent a reflection.
struct ContextExplorer: View {
    @EnvironmentObject var state: AppState
    let journalKey: String
    @State private var source: SlowClawMemoryEntry?
    @State private var related: [ContextDocument] = []
    @State private var busy = false
    var body: some View {
        List {
            if let current = state.contextDocument(journalKey), let entry = state.memorySource(journalKey) {
                Section("Original words") {
                    Text(current.text)
                    Button("Open journal") { source = entry }
                    FollowQuestionButton(sourceKey: journalKey, suggestion: "")
                }
                Section("Keep a thought") {
                    Button("Find a highlight & question") { Task { await state.selectKevJournal(entry) } }
                        .disabled(state.kevJournalBusy || state.readsDecisionBusy)
                    if let selection = state.kevJournalSelections[journalKey], selection.source == entry.content {
                        if let highlight = selection.highlight { Text(highlight) }
                        if let question = selection.question {
                            Text(question)
                            FollowQuestionButton(sourceKey: journalKey, suggestion: question)
                        }
                        if selection.draft != nil {
                            Button("Save words as a private draft") { state.saveKevDraft(selection) }
                        }
                    }
                    if let status = state.kevJournalStatus { Text(status).font(.caption).foregroundStyle(.secondary) }
                }
                Section("Related journals") {
                    Button("Find connections with Kev") {
                        busy = true
                        Task {
                            related = await state.searchPersonalContext(current.text, excluding: journalKey)
                            busy = false
                        }
                    }.disabled(busy || state.kevJournalBusy || state.readsDecisionBusy)
                    if busy { ProgressView() }
                    ForEach(related.filter { state.contextDocument($0.id)?.text == $0.text }) { doc in
                        Button { source = state.memorySource(doc.id) } label: { Text(doc.text).lineLimit(4) }
                    }
                }
            } else { Text("This source changed or was excluded. Return to your journals.") }
        }.navigationTitle("Revisit")
            .onChange(of: state.readsDecisionRevision) { _, _ in related = [] }
            .sheet(item: $source) { JournalDetailView(entry: $0).environmentObject(state) }
    }
}
