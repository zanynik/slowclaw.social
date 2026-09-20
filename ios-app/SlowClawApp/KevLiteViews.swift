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
    @Environment(\.colorScheme) var scheme
    @State private var showPosts = false
    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                HStack {
                    Text("Create").font(DS.titleFont)
                    Spacer()
                    Button { showPosts = true } label: { Image(systemName: "paperplane") }
                        .accessibilityLabel("Published posts")
                }
                if state.drafts.isEmpty {
                    ContentUnavailableView("Your words, ready to share", systemImage: "text.quote",
                        description: Text("Ideas from your journals become private drafts here."))
                    if state.liteJournals.isEmpty {
                        Button("Record a journal") { state.selectedTab = .journal }.buttonStyle(.borderedProminent)
                    } else {
                        Button("Find ideas") { Task { await state.refreshDraftIdeas() } }.buttonStyle(.borderedProminent)
                            .disabled(state.jevBusy || state.jevFeedsBusy || state.readsDecisionBusy || state.kevJournalBusy)
                    }
                }
                if state.kevJournalBusy { ProgressView("Finding ideas…") }
                ForEach(state.drafts, id: \.id) { draft in DraftCard(draft: draft, sourceJournalContent: nil) }
            }.padding(20)
        }.background(DS.bg(scheme))
            .sheet(isPresented: $showPosts) { NostrPostsView() }
            .refreshable { await state.refreshDraftIdeas() }
    }
}

struct ProfileView: View {
    @EnvironmentObject var state: AppState
    @AppStorage("slowclaw.theme") private var theme = ""
    @State private var showMemory = false
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Button { showMemory = true } label: { Label("Memory", systemImage: "brain") }
                    NavigationLink { JevPrivacyView() } label: { Label("Privacy & connection", systemImage: "lock") }
                    Picker("Appearance", selection: $theme) {
                        Text("System").tag("")
                        Text("Light").tag("light")
                        Text("Dark").tag("dark")
                    }
                    NavigationLink { AdvancedSettingsView() } label: { Label("Advanced", systemImage: "slider.horizontal.3") }
                }
            }.navigationTitle("Settings")
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
