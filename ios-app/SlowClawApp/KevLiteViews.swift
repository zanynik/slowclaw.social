import SwiftUI
import SlowClawFeed

struct DraftsView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.colorScheme) var scheme
    @State private var showPosts = false
    @State private var source: SlowClawMemoryEntry?
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                Text("Your words").font(DS.titleFont)
                Text("Find a thought worth keeping or sharing. Kev selects sentences; your words stay yours.")
                    .font(.subheadline).foregroundStyle(.secondary)
                HStack {
                    Button("Find highlights") { Task { await state.scanKevJournals() } }
                        .buttonStyle(.borderedProminent)
                        .disabled(state.kevJournalBusy || state.readsDecisionBusy || state.readsModelActivating)
                    if state.kevJournalBusy { ProgressView() }
                }
                if let status = state.kevJournalStatus { Text(status).font(.caption).foregroundStyle(.secondary) }
                if !state.readsModelEnabled { ReadsModelCard() }
                ForEach(Array(state.liteJournals.prefix(12)), id: \.key) { entry in
                    VStack(alignment: .leading, spacing: 10) {
                        Button { source = entry } label: {
                            Text(String(entry.content.split(separator: "\n").first ?? "Journal").replacingOccurrences(of: "# ", with: ""))
                                .font(.headline).lineLimit(2)
                        }
                        if let selected = state.kevJournalSelections[entry.key], selected.source == entry.content {
                            if let text = selected.highlight { Text(text).font(.body) }
                            if let question = selected.question {
                                Text(question).font(.subheadline).foregroundStyle(.secondary)
                                Button("Keep this question") {
                                    do { _ = try state.followQuestion(question, sourceKey: entry.key) }
                                    catch { state.kevJournalStatus = error.localizedDescription }
                                }.font(.caption)
                            }
                            if let draft = selected.draft {
                                Text("Words to share").font(.caption).foregroundStyle(.secondary)
                                Text(draft).font(.body)
                                Button("Save private draft") { state.saveKevDraft(selected) }.buttonStyle(.bordered)
                            } else { Text("No short post selected. You can still write your own.").font(.caption).foregroundStyle(.secondary) }
                        } else {
                            Button("Select from this journal") { Task { await state.selectKevJournal(entry) } }
                                .disabled(state.kevJournalBusy || state.readsDecisionBusy || state.readsModelActivating)
                        }
                    }.padding().frame(maxWidth: .infinity, alignment: .leading)
                        .background(DS.surface2(scheme), in: RoundedRectangle(cornerRadius: 12))
                }
                if state.liteJournals.isEmpty { Text("Add a journal to find words worth keeping.").foregroundStyle(.secondary) }
                Text("Private drafts").font(.title2)
                ForEach(state.drafts, id: \.id) { draft in DraftCard(draft: draft, sourceJournalContent: nil) }
                if state.drafts.isEmpty { Text("Nothing is published automatically.").font(.caption).foregroundStyle(.secondary) }
                Button("My published posts & replies") { showPosts = true }
            }.padding(20)
        }.background(DS.bg(scheme))
            .sheet(item: $source) { JournalDetailView(entry: $0).environmentObject(state) }
            .sheet(isPresented: $showPosts) { NostrPostsView() }
            .refreshable { await state.refreshJournals() }
    }
}

struct ProfileView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.colorScheme) var scheme
    @State private var showMemory = false
    @State private var showPosts = false
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text("Settings").font(DS.titleFont)
                Text("SlowClaw Lite · Kev experiment").font(.headline)
                Text("One local judge for reading and finding your words. Recording, transcription and publishing work as before.")
                    .font(.subheadline).foregroundStyle(.secondary)
                ReadsModelCard(showRemove: true)
                Button("Personal memory & followed questions") { showMemory = true }
                Button("My Nostr posts & replies") { showPosts = true }
                DisclosureGroup("Storage") {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("\(state.journals.count) recent journals · \(state.drafts.count) drafts")
                        Text("Existing writing models are not used by Lite. Your files remain available if you return to the full app.").font(.caption)
                        ForEach(LocalModelPreset.presets.filter { LocalModelStore.isDownloaded($0) }) { model in
                            HStack {
                                Text(model.title).font(.caption)
                                Spacer()
                                Button("Remove", role: .destructive) { state.deleteLocalModel(model) }
                                    .disabled(state.localModelBusy || state.kevJournalBusy || state.readsDecisionBusy)
                            }
                        }
                        RecentlyDeletedCard(scheme: scheme)
                    }.padding(.top, 10)
                }
                DisclosureGroup("Transcription troubleshooting") { ExperimentCard(scheme: scheme) }
            }.padding(20)
        }.background(DS.bg(scheme))
            .sheet(isPresented: $showMemory) { PersonalMemoryView().environmentObject(state) }
            .sheet(isPresented: $showPosts) { NostrPostsView() }
    }
}
