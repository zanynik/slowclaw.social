import SwiftUI

struct JevConnectionCard: View {
    @EnvironmentObject var state: AppState
    var showsMemoryLink = true
    @State private var consent = false
    @State private var showMemory = false
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Jev · Cloud memory").font(.headline)
                Spacer()
                if state.jevBusy || state.jevConnecting { ProgressView() }
            }
            if state.jevEnabled {
                Text("Useful passages from your journals guide Reads.").font(.caption).foregroundStyle(.secondary)
                HStack {
                    if showsMemoryLink { Button("Personal memory") { showMemory = true } }
                    Spacer()
                    Button("Turn off") { state.disableJev() }.disabled(state.jevConnecting)
                }.font(.caption)
            } else {
                Text("Find lasting ideas and useful context in your own words. No model download needed.").font(.caption).foregroundStyle(.secondary)
                Button("Enable Jev") { consent = true }.disabled(state.jevConnecting)
            }
            if let status = state.jevStatus { Text(status).font(.caption).foregroundStyle(.secondary) }
            if state.jevEnabled, let status = state.readsDecisionStatus { Text(status).font(.caption).foregroundStyle(.secondary) }
        }.padding()
            .alert("Use cloud memory?", isPresented: $consent) {
                Button("Enable and connect") { Task { await state.connectJev() } }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("SlowClaw will send included journal passages and incoming reading content through its service to OpenRouter and Jev. Saved memory stays on your device; the service does not store journal text. Provider data policies apply. Excluded journals are skipped. You can turn this off anytime.")
            }
            .sheet(isPresented: $showMemory) { PersonalMemoryView().environmentObject(state) }
    }
}

struct JevMemoryList: View {
    @EnvironmentObject var state: AppState
    @State private var source: SlowClawMemoryEntry?
    var body: some View {
        Section {
            Text("Jev keeps exact passages with lasting ideas or useful personal context. Routine passages are left out. Edit the source journal to correct a memory.")
                .font(.callout).foregroundStyle(.secondary)
            if state.jevBusy {
                Button("Pause") { state.stopJevMemory() }
            } else {
                Button("Find useful passages") { state.startJevMemory() }
                    .disabled(!state.jevEnabled || state.readsDecisionBusy)
            }
            if let status = state.jevStatus { Text(status).font(.caption).foregroundStyle(.secondary) }
        }
        Section("Remembered passages · \(state.jevPassages.count)") {
            ForEach(state.jevPassages) { passage in
                VStack(alignment: .leading, spacing: 10) {
                    Text(passage.category == "insight" ? "Lasting idea" : "Useful context").font(.caption).foregroundStyle(.secondary)
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
