import SwiftUI

struct ReadingHistoryView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var confirmClear = false
    @State private var selected: ReadingVisit?
    var body: some View {
        NavigationStack {
            List {
                if let error = state.readingHistoryError { Text(error).foregroundStyle(.red) }
                if state.readingVisits.isEmpty {
                    ContentUnavailableView("Your reading trail", systemImage: "clock",
                        description: Text("Articles appear after 30 seconds in the foreground reader. Time is an estimate, not proof of reading."))
                }
                ForEach(state.readingVisits.values.sorted { $0.date > $1.date }) { visit in
                    VStack(alignment: .leading, spacing: 6) {
                        if let url = URL(string: visit.url), ["https", "http"].contains(url.scheme ?? "") {
                            Button {
                                state.beginEvidenceReading(EvidenceArticle(id: visit.id, title: visit.title,
                                    excerpt: "", url: url, source: visit.source))
                                selected = visit
                            } label: {
                                Text(visit.title).font(.headline).multilineTextAlignment(.leading)
                            }
                        }
                        Text("\(visit.duration) · \(visit.date.formatted(.dateTime.month(.abbreviated).day())) · \(visit.source)")
                            .font(.caption).foregroundStyle(.secondary)
                    }.padding(.vertical, 4)
                }
            }.navigationTitle("History")
                .sheet(item: $selected, onDismiss: { state.finishReading() }) { visit in
                    if let url = URL(string: visit.url) {
                        InAppBrowserView(url: url) { selected = nil }
                    }
                }
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Clear", role: .destructive) { confirmClear = true } }
                    ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
                }
                .confirmationDialog("Clear reading history on this device?", isPresented: $confirmClear) {
                    Button("Clear history", role: .destructive) { state.clearReadingHistory() }
                }
        }
    }
}
