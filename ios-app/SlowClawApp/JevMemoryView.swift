import SwiftUI


struct JevMemoryList: View {
    @EnvironmentObject var state: AppState
    @State private var source: SlowClawMemoryEntry?
    var body: some View {
        Section {
            if state.jevBusy {
                ProgressView("Finding ideas…")
            } else {
                Button("Refresh memory") { state.startJevMemory() }
                    .disabled(!state.jevEnabled || state.readsDecisionBusy)
            }
        }
        Section {
            ForEach(state.jevPassages) { passage in
                VStack(alignment: .leading, spacing: 10) {
                    Text(passage.text.trimmingCharacters(in: .whitespacesAndNewlines))
                    HStack {
                        Button("Source journal") { source = state.memorySource(passage.sourceKey) }
                        Spacer()
                        Button("Forget", role: .destructive) { state.dismissJevPassage(passage.id) }
                    }.font(.caption).buttonStyle(.borderless)
                }.padding(.vertical, 6)
            }
            if state.jevPassages.isEmpty { Text("Your remembered passages will appear here. They become the lens for Reads.").foregroundStyle(.secondary) }
        }
        .sheet(item: $source) { JournalDetailView(entry: $0).environmentObject(state) }
    }
}
