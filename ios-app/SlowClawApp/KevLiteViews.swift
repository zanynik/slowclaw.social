import SwiftUI

struct WelcomeView: View {
    let start: () -> Void
    let offline: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Spacer()
            Image(systemName: "waveform").font(.system(size: 48, weight: .light)).foregroundStyle(DS.accentColor)
            Text("Start with a thought.").font(.largeTitle.bold())
            Text("Record your first journal. SlowClaw finds ideas worth keeping, things worth reading, and words you might share.")
                .font(.title3).foregroundStyle(.secondary)
            Spacer()
            Text("Journal text is processed by Jev through OpenRouter. Audio stays on this iPhone. You can turn cloud processing off in Settings.")
                .font(.footnote).foregroundStyle(.secondary)
            Button(action: start) { Text("Start journaling").frame(maxWidth: .infinity).padding(.vertical, 8) }
                .buttonStyle(.borderedProminent).tint(DS.accentColor)
            Button("Use offline", action: offline).frame(maxWidth: .infinity)
        }.padding(28)
    }
}

struct DraftsView: View {
    @EnvironmentObject var state: AppState
    @State private var inbox: DraftInboxState = .new
    @State private var source: SlowClawMemoryEntry?
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("Draft inbox", selection: $inbox) {
                        ForEach(DraftInboxState.allCases) { Text($0.rawValue).tag($0) }
                    }.pickerStyle(.segmented)
                }
                if inbox == .new && state.jevEnabled {
                    Section("Ideas worth sharing") {
                        if state.jevBusy { ProgressView("Finding ideas…") }
                        ForEach(Array(state.sharingIdeas.prefix(5))) { passage in
                            VStack(alignment: .leading, spacing: 10) {
                                HStack {
                                    Text(state.ideaCache.decisions[passage.id]?.shareableQuote == true ? "A quote in your words" : "An idea in your words")
                                        .font(.caption).foregroundStyle(.secondary)
                                    Spacer()
                                    CopyTextButton(text: passage.text)
                                }
                                Text(passage.text).textSelection(.enabled)
                                HStack {
                                    Button("Make draft") { state.makePassageDraft(passage) }
                                    if state.ideaCache.decisions[passage.id]?.shareableQuote == true {
                                        ShareLink("Share quote", item: passage.text.trimmingCharacters(in: .whitespacesAndNewlines))
                                    }
                                    Spacer()
                                    Button("Source") { source = state.memorySource(passage.sourceKey) }
                                }.font(.caption).buttonStyle(.borderless)
                            }.padding(.vertical, 8)
                                .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                    Button("Dismiss") { state.dismissJevPassage(passage.id) }.tint(.orange)
                                }
                        }
                        if state.sharingIdeas.isEmpty && !state.jevBusy {
                            Text("Journal first. Thoughts that may help someone else will appear here.").foregroundStyle(.secondary)
                        }
                    }
                }
                Section(inbox.rawValue) {
                    let items = state.drafts.filter { state.draftState($0) == inbox }
                    ForEach(items, id: \.id) { DraftCard(draft: $0, sourceJournalContent: nil) }
                    if items.isEmpty {
                        Text(inbox == .new ? "Choose an idea to start a draft." : "No \(inbox.rawValue.lowercased()) drafts yet.")
                            .foregroundStyle(.secondary)
                    }
                }
                if let status = state.kevJournalStatus {
                    Section { Text(status).font(.caption).foregroundStyle(.secondary) }
                }
            }
            .navigationTitle("Create")
            .sheet(item: $source) { JournalDetailView(entry: $0).environmentObject(state) }
            .refreshable { await state.refreshDraftIdeas() }
            .toolbar {
                Button("Find ideas", systemImage: "arrow.clockwise") { state.startJevMemory() }
                    .disabled(state.jevBusy || state.jevFeedsBusy || state.readsDecisionBusy || state.kevJournalBusy)
            }
        }
    }
}

struct ProfileView: View {
    @EnvironmentObject var state: AppState
    @AppStorage("slowclaw.theme") private var theme = ""
    @State private var showMemory = false
    var body: some View {
        NavigationStack {
            Form {
                Section("What's on your mind") {
                    let topics = Array(state.personaTopics.prefix(8))
                    let trends = state.personaTrends
                    if topics.isEmpty { Text("Start with a journal.").foregroundStyle(.secondary) }
                    ForEach(topics, id: \.name) { topic in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(topic.name)
                                Spacer()
                                Text(topic.weight, format: .percent.precision(.fractionLength(1)))
                                Text(trends[topic.name] ?? "–")
                            }.font(.subheadline)
                            ProgressView(value: topic.weight / max(topics.first?.weight ?? 1, 0.001))
                        }.padding(.vertical, 4)
                    }
                    Button("All interests") { showMemory = true }
                }
                Section {
                    NavigationLink { JevPrivacyView() } label: { Label("Privacy & connection", systemImage: "lock") }
                    Picker("Appearance", selection: $theme) {
                        Text("System").tag("")
                        Text("Light").tag("light")
                        Text("Dark").tag("dark")
                    }
                    NavigationLink { AdvancedSettingsView() } label: { Label("Advanced", systemImage: "slider.horizontal.3") }
                }
            }.navigationTitle("Profile")
                .sheet(isPresented: $showMemory) { PersonalMemoryView().environmentObject(state) }
        }
    }
}

struct JevPrivacyView: View {
    @EnvironmentObject var state: AppState
    var body: some View {
        Form {
            Section {
                Toggle("Cloud processing", isOn: Binding(get: { state.jevEnabled }, set: { enabled in
                    if enabled { Task { await state.enableTesterJev() } } else { state.disableJev() }
                }))
                Text("Included journal text and reading content are processed by Jev through OpenRouter. Audio and saved memories stay on this iPhone. The SlowClaw service does not save journal text.")
                    .font(.footnote).foregroundStyle(.secondary)
                Text("Access is included during testing. No account or API key is needed.").font(.footnote).foregroundStyle(.secondary)
                if state.jevConnecting { ProgressView("Connecting…") }
                if let problem = state.jevProblem {
                    Text(problem).font(.footnote)
                    Button("Retry connection") { Task { await state.enableTesterJev() } }
                }
            }
        }.navigationTitle("Privacy & connection")
    }
}

struct AdvancedSettingsView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.colorScheme) var scheme
    var body: some View {
        List {
            DisclosureGroup("On-device models") {
                ReadsModelCard(showRemove: true)
                ForEach(LocalModelPreset.presets.filter { LocalModelStore.isDownloaded($0) }) { model in
                    HStack {
                        Text(model.title)
                        Spacer()
                        Button("Remove", role: .destructive) { state.deleteLocalModel(model) }
                            .disabled(state.localModelBusy || state.kevJournalBusy || state.readsDecisionBusy)
                    }
                }
            }
            DisclosureGroup("Recently deleted") { RecentlyDeletedCard(scheme: scheme) }
            DisclosureGroup("Transcription") { ExperimentCard(scheme: scheme) }
            DisclosureGroup("Activity") {
                if let text = state.jevStatus { Text(text) }
                if let text = state.readsDecisionStatus { Text(text) }
                if let text = state.jevFeedsStatus { Text(text) }
                if let text = state.kevJournalStatus { Text(text) }
            }
        }.navigationTitle("Advanced")
    }
}
