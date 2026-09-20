import SwiftUI

struct JevSourcesView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        let selectedURLs = state.jevSelectedFeedURLs
        NavigationStack {
            List {
                Section {
                    Text("Jev compares recent stories from the catalog with your saved journal passages. Selected sources are refreshed weekly when you use Reads; each incoming item still needs its own strong match.")
                        .font(.subheadline)
                    Button("Recheck sources now") { state.startJevFeedSelection(force: true) }
                        .disabled(!state.jevEnabled || state.jevFeedsBusy || state.jevBusy || state.readsDecisionBusy || state.kevJournalBusy)
                    if state.jevFeedsBusy {
                        ProgressView()
                        Button("Pause source selection") { state.pauseJevFeedSelection() }
                    }
                    if let status = state.jevFeedsStatus { Text(status).font(.caption) }
                    if let status = state.readsTransportStatus { Text(status).font(.caption) }
                }
                ForEach([true, false], id: \.self) { selected in
                    Section(selected ? "Selected" : "Unselected") {
                        ForEach(state.jevFeedCatalog.filter { selectedURLs.contains($0.xmlURL) == selected }, id: \.xmlURL) { source in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(source.title)
                                Text(source.domain).font(.caption).foregroundStyle(.secondary)
                                if let score = state.jevFeedScore(source) {
                                    Text("Memory match \(Int(score * 100))% — an estimate").font(.caption2).foregroundStyle(.secondary)
                                } else {
                                    Text("Not checked yet, or feed unavailable").font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }.navigationTitle("Sources")
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}
