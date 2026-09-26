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
    @State private var choosingSource = false
    @State private var showingDrafts = false
    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 28) {
                    if state.createIdeas.isEmpty {
                        ContentUnavailableView("Your moments, ready to share", systemImage: "quote.bubble",
                            description: Text("Pull down to find quote cards and audio stories in your journals."))
                        Button("Find moments", systemImage: "sparkles") { Task { await state.refreshCreateIdeas() } }
                            .buttonStyle(.borderedProminent).disabled(state.createBusy)
                            .frame(maxWidth: .infinity)
                    }
                    if state.createBusy { ProgressView(state.createStatus ?? "Finding moments…") }
                    ForEach(state.createIdeas) { idea in
                        if let entry = state.memorySource(idea.key) {
                            VStack(alignment: .leading, spacing: 10) {
                                ShareStudioView(source: studioSource(idea, entry: entry), compact: true)
                                HStack {
                                    Text(journalTitleOf(entry)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                    Spacer()
                                    Button("Dismiss", systemImage: "xmark") { state.dismissCreateIdea(idea.id) }
                                        .font(.caption).frame(minHeight: 44)
                                }
                            }.padding(16).background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 20))
                        }
                    }
                    if !state.createBusy, let status = state.createStatus { Text(status).font(.footnote).foregroundStyle(.secondary) }
                    Color.clear.frame(height: 32)
                }.padding(.horizontal, 16).padding(.top, 12)
            }
            .refreshable { await state.refreshCreateIdeas() }
            .navigationTitle("Create")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        Button("Make your own", systemImage: "plus") { choosingSource = true }
                        Button("Text drafts", systemImage: "text.alignleft") { showingDrafts = true }
                    } label: { Image(systemName: "plus.circle").frame(width: 44, height: 44) }
                }
            }
            .fullScreenCover(isPresented: $choosingSource) {
                NavigationStack { CreationSourcePicker().environmentObject(state)
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { choosingSource = false } } } }
            }
            .sheet(isPresented: $showingDrafts) { TextDraftsView().environmentObject(state) }
            .onChange(of: choosingSource) { _, _ in state.studioPlayingID = nil }
            .onChange(of: showingDrafts) { _, _ in state.studioPlayingID = nil }
        }
    }
    private func studioSource(_ idea: CreateIdeas.Candidate, entry: SlowClawMemoryEntry) -> StudioSource {
        var source = StudioSource(entry: entry, excerpt: idea.text)
        source.id = idea.id; source.segment = idea
        source.startsWithVideo = idea.timingID != nil && !(state.createCache.decisions[idea.id]?.shareableQuote == true && idea.text.count <= 600)
        return source
    }
}

private struct TextDraftsView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss
    @State private var inbox: DraftInboxState = .new
    var body: some View {
        NavigationStack {
            List {
                Picker("Draft inbox", selection: $inbox) { ForEach(DraftInboxState.allCases) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented)
                ForEach(state.drafts.filter { state.draftState($0) == inbox }, id: \.id) { DraftCard(draft: $0, sourceJournalContent: nil) }
            }.navigationTitle("Text drafts")
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
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
