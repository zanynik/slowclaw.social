// SlowClawApp.swift — native SwiftUI app for SlowClaw Social.
//
// Five tabs matching the product vision (AGENTS.md three loops):
//   Reads   — journal-ranked feed (articles + social, ranked by interests)
//   Journal — capture/compose (audio-first, grows interests)
//   Drafts  — AI-distilled post drafts (→ Bluesky/Nostr)
//   Profile — settings, API keys, interest management
//
// All data flows through the Zig core via the C ABI:
//   - SQLite for persistence (journals, interests, drafts)
//   - LLM provider for synthesis/extraction/drafting
//   - HashEmbedder for interest vectors
//   - Ranker for feed ordering

import SwiftUI

@main
struct SlowClawApp: App {
    @StateObject private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            MainTabView()
                .environmentObject(appState)
                .preferredColorScheme(appState.colorScheme)
        }
    }
}

// MARK: - App State (shared across all views)

@MainActor
final class AppState: ObservableObject {
    // Database
    let memory: SlowClawSqliteMemory

    // LLM (nil until API key is set)
    var llm: SlowClawLLMProvider?

    // Published state
    @Published var journals: [SlowClawMemoryEntry] = []
    @Published var drafts: [SlowClawMemoryEntry] = []
    @Published var interests: [String] = []
    @Published var selectedTab: AppTab = .journal

    // Settings
    @Published var apiKey: String {
        didSet { UserDefaults.standard.set(apiKey, forKey: "slowclaw.api_key"); setupLLM() }
    }
    @Published var model: String {
        didSet { UserDefaults.standard.set(model, forKey: "slowclaw.model") }
    }
    @Published var baseURL: String {
        didSet { UserDefaults.standard.set(baseURL, forKey: "slowclaw.base_url"); setupLLM() }
    }

    init() {
        // Load settings
        self.apiKey = UserDefaults.standard.string(forKey: "slowclaw.api_key") ?? ""
        self.model = UserDefaults.standard.string(forKey: "slowclaw.model") ?? "gpt-4o-mini"
        self.baseURL = UserDefaults.standard.string(forKey: "slowclaw.base_url") ?? "https://api.openai.com/v1"

        // Open the SQLite database in Documents
        let urls = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
        let dir = urls.first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let dbPath = dir.appendingPathComponent("slowclaw.sqlite").path
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        do {
            self.memory = try SlowClawSqliteMemory(path: dbPath, embedder: true)
        } catch {
            fatalError("Failed to open database: \(error)")
        }

        setupLLM()
        Task { await refreshJournals() }
    }

    var colorScheme: ColorScheme? { nil } // system default

    private func setupLLM() {
        guard !apiKey.isEmpty else { llm = nil; return }
        llm = SlowClawLLMProvider(baseURL: baseURL, apiKey: apiKey) { url, authHeader, contentType, body in
            // URLSession-based HTTP transport
            var request = URLRequest(url: URL(string: url)!)
            request.httpMethod = "POST"
            request.setValue(authHeader, forHTTPHeaderField: "Authorization")
            request.setValue(contentType, forHTTPHeaderField: "Content-Type")
            request.httpBody = body
            let semaphore = DispatchSemaphore(value: 0)
            var result: Data?
            URLSession.shared.dataTask(with: request) { data, _, _ in
                result = data
                semaphore.signal()
            }.resume()
            semaphore.wait()
            return result
        }
    }

    // MARK: - Data operations

    func refreshJournals() async {
        do {
            journals = try memory.recall(query: "the a an of to and", limit: 50)
            drafts = try memory.recall(query: "draft post", limit: 20, sessionID: "drafts")
        } catch {
            journals = []
            drafts = []
        }
    }

    func storeJournal(text: String) async {
        try? memory.store(key: "journal_\(Date().timeIntervalSince1970)", content: text,
                          category: "daily", sessionID: nil)
        await refreshJournals()

        // Extract interests if LLM is available
        guard let llm = llm else { return }
        DispatchQueue.global(qos: .utility).async {
            if let keywords = try? llm.extractInterests(journalText: text, model: self.model) {
                Task { @MainActor in
                    self.interests.append(contentsOf: keywords.filter { !self.interests.contains($0) })
                }
            }
        }
    }

    func generateDraft(from journal: SlowClawMemoryEntry) async {
        guard let llm = llm else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            if let draft = try? llm.draftPost(journalText: journal.content, model: self.model) {
                let key = "draft_\(Date().timeIntervalSince1970)"
                try? self.memory.store(key: key, content: draft, category: "core", sessionID: "drafts")
                Task { @MainActor in await self.refreshJournals() }
            }
        }
    }
}

// MARK: - Tab enum

enum AppTab: String, CaseIterable {
    case reads, journal, drafts, profile

    var label: String { rawValue.capitalized }
    var icon: String {
        switch self {
        case .reads: return "newspaper"
        case .journal: return "book"
        case .drafts: return "square.and.pencil"
        case .profile: return "person.circle"
        }
    }
}

// MARK: - Main Tab View

struct MainTabView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        TabView(selection: $state.selectedTab) {
            ReadsView()
                .tabItem { Label(AppTab.reads.label, systemImage: AppTab.reads.icon) }
                .tag(AppTab.reads)

            JournalView()
                .tabItem { Label(AppTab.journal.label, systemImage: AppTab.journal.icon) }
                .tag(AppTab.journal)

            DraftsView()
                .tabItem { Label(AppTab.drafts.label, systemImage: AppTab.drafts.icon) }
                .tag(AppTab.drafts)

            ProfileView()
                .tabItem { Label(AppTab.profile.label, systemImage: AppTab.profile.icon) }
                .tag(AppTab.profile)
        }
    }
}

// MARK: - Journal View (Capture loop)

struct JournalView: View {
    @EnvironmentObject var state: AppState
    @State private var newEntry = ""
    @State private var isSynthesizing = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Audio capture zone (audio-first)
                AudioCaptureView()
                    .padding(.horizontal)
                    .padding(.top)

                Divider()
                    .padding(.vertical, 8)

                // Text capture zone
                VStack(spacing: 12) {
                VStack(spacing: 12) {
                    TextEditor(text: $newEntry)
                        .frame(minHeight: 100)
                        .padding(8)
                        .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
                        .overlay(alignment: .topLeading) {
                            if newEntry.isEmpty {
                                Text("What's on your mind?")
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 16)
                                    .allowsHitTesting(false)
                            }
                        }

                    HStack(spacing: 12) {
                        Button {
                            Task { await saveEntry() }
                        } label: {
                            Label("Save", systemImage: "square.and.arrow.down.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(newEntry.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                        if state.llm != nil {
                            Button {
                                Task { await synthesize() }
                            } label: {
                                Label("Polish", systemImage: "sparkles")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.bordered)
                            .disabled(newEntry.isEmpty || isSynthesizing)
                        }
                    }
                }
                .padding()

                // Interest chips (tap to cycle boost/mute/normal)
                if !state.interests.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(state.interests, id: \.self) { interest in
                                InterestChip(label: interest)
                            }
                        }
                        .padding(.horizontal)
                    }
                    .frame(height: 36)
                    .padding(.bottom, 4)
                }

                // Journal entries
                List {
                    Section {
                        ForEach(state.journals, id: \.id) { entry in
                            JournalCard(entry: entry)
                                .swipeActions(edge: .trailing) {
                                    Button {
                                        Task { await state.generateDraft(from: entry) }
                                    } label: {
                                        Label("Draft", systemImage: "square.and.pencil")
                                    }
                                    .tint(.purple)

                                    Button(role: .destructive) {
                                        try? state.memory.forget(key: entry.key)
                                        Task { await state.refreshJournals() }
                                    } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                }
                        }
                    } header: {
                        HStack {
                            Text("Recent")
                            Spacer()
                            Text("\(state.journals.count)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .listStyle(.insetGrouped)
            }
            .navigationTitle("Journal")
            .navigationBarTitleDisplayMode(.large)
            .task { await state.refreshJournals() }
        }
    }

    private func saveEntry() async {
        let text = newEntry.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        await state.storeJournal(text: text)
        newEntry = ""
    }

    private func synthesize() async {
        guard let llm = state.llm else { return }
        isSynthesizing = true
        defer { isSynthesizing = false }

        let transcript = newEntry
        DispatchQueue.global(qos: .userInitiated).async {
            if let polished = try? llm.synthesizeJournal(transcript: transcript, model: state.model) {
                DispatchQueue.main.async { newEntry = polished }
            }
        }
    }
}

/// Interest chip with visual state (normal=blue, boosted=green, muted=gray).
struct InterestChip: View {
    let label: String
    @State private var state: ChipState = .normal

    enum ChipState { case normal, boosted, muted }
    var color: Color {
        switch state {
        case .normal: return .blue
        case .boosted: return .green
        case .muted: return .gray
        }
    }
    var icon: String {
        switch state {
        case .normal: return ""
        case .boosted: return "arrow.up"
        case .muted: return "speaker.slash"
        }
    }

    var body: some View {
        Button {
            switch state {
            case .normal: state = .boosted
            case .boosted: state = .muted
            case .muted: state = .normal
            }
        } label: {
            HStack(spacing: 3) {
                Text(label)
                if !icon.isEmpty { Image(systemName: icon).font(.system(size: 9)) }
            }
            .font(.caption.weight(.medium))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(color.opacity(0.15), in: Capsule())
            .foregroundStyle(color)
        }
        .buttonStyle(.plain)
    }
}

/// Journal entry card — richer than the old JournalRow.
struct JournalCard: View {
    let entry: SlowClawMemoryEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(entry.content)
                .font(.body)
                .lineLimit(4)
                .multilineTextAlignment(.leading)

            HStack(spacing: 8) {
                Image(systemName: "clock")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Text(formatTimestamp(entry.timestamp))
                    .font(.caption2)
                    .foregroundStyle(.secondary)

                if let score = entry.score, score > 0 {
                    Spacer()
                    Text(String(format: "%.0f%%", score * 100))
                        .font(.caption2.monospaced())
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(.green.opacity(0.12), in: Capsule())
                        .foregroundStyle(.green)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private func formatTimestamp(_ ts: String) -> String {
        // The timestamp from SQLite is epoch-seconds or RFC3339; just show it short.
        if ts.count > 10 {
            return String(ts.prefix(10))
        }
        return ts
    }
}

// MARK: - Reads View (Feed loop)

struct ReadsView: View {
    @EnvironmentObject var state: AppState
    @State private var sampleItems: [SampleFeedItem] = SampleFeedItem.examples

    var body: some View {
        NavigationStack {
            List(sampleItems) { item in
                FeedCard(item: item, interests: state.interests)
            }
            .listStyle(.plain)
            .refreshable {
                // Pull-to-refresh: in production this would trigger RSS/Bluesky
                // ingestion via the Zig ranker. For now just keep the samples.
            }
            .navigationTitle("Reads")
            .navigationBarTitleDisplayMode(.large)
            .overlay {
                if state.journals.isEmpty {
                    ContentUnavailableView(
                        "Start writing",
                        systemImage: "newspaper",
                        description: Text("Write journal entries to grow your interests. Articles ranked by your interests appear here.")
                    )
                }
            }
        }
    }
}

/// Sample feed item for demonstrating the ranking UI.
/// In production these come from RSS/Bluesky ingestion through the Zig ranker.
struct SampleFeedItem: Identifiable {
    let id: String
    let title: String
    let source: String
    let readMinutes: Int
    let hasImage: Bool
    let matchedInterests: [String]
    let timestamp: Double

    static let examples: [SampleFeedItem] = [
        .init(id: "1", title: "Why Rust's borrow checker makes systems programming safer", source: "rust-blog.org", readMinutes: 8, hasImage: true, matchedInterests: ["rust"], timestamp: Date().timeIntervalSince1970 - 3600),
        .init(id: "2", title: "The science of sourdough fermentation", source: "kingarthurbaking.com", readMinutes: 5, hasImage: true, matchedInterests: ["baking"], timestamp: Date().timeIntervalSince1970 - 7200),
        .init(id: "3", title: "Urban cycling infrastructure in European cities", source: "citylab.com", readMinutes: 12, hasImage: false, matchedInterests: ["cycling"], timestamp: Date().timeIntervalSince1970 - 14400),
        .init(id: "4", title: "Climate tech investments doubled in 2026", source: "techcrunch.com", readMinutes: 3, hasImage: true, matchedInterests: ["climate"], timestamp: Date().timeIntervalSince1970 - 18000),
        .init(id: "5", title: "The minimalist Mac setup for developers", source: "macstories.net", readMinutes: 15, hasImage: true, matchedInterests: [], timestamp: Date().timeIntervalSince1970 - 28800),
    ]
}

/// Rich feed card with interest match badges + read time.
struct FeedCard: View {
    let item: SampleFeedItem
    let interests: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Title
            Text(item.title)
                .font(.headline)
                .lineLimit(2)
                .multilineTextAlignment(.leading)

            // Interest match badges
            if !item.matchedInterests.isEmpty {
                HStack(spacing: 4) {
                    ForEach(item.matchedInterests, id: \.self) { interest in
                        Text(interest)
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.blue.opacity(0.15), in: Capsule())
                            .foregroundStyle(.blue)
                    }
                }
            }

            HStack(spacing: 12) {
                // Source
                Label(item.source, systemImage: "globe")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                // Read time
                Label("\(item.readMinutes) min", systemImage: "book")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer()

                // Image indicator
                if item.hasImage {
                    Image(systemName: "photo")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                // Time ago
                Text(timeAgo(item.timestamp))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 6)
    }

    private func timeAgo(_ ts: Double) -> String {
        let diff = Date().timeIntervalSince1970 - ts
        if diff < 3600 { return "\(Int(diff/60))m" }
        if diff < 86400 { return "\(Int(diff/3600))h" }
        return "\(Int(diff/86400))d"
    }
}

// MARK: - Drafts View (Share loop)

struct DraftsView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        NavigationStack {
            Group {
                if state.drafts.isEmpty {
                    ContentUnavailableView(
                        "No drafts yet",
                        systemImage: "square.and.pencil",
                        description: Text("Swipe a journal entry and tap 'Draft Post' to let AI distill it into a shareable post.")
                    )
                } else {
                    List {
                        ForEach(state.drafts, id: \.id) { draft in
                            DraftRow(draft: draft)
                                .swipeActions(edge: .trailing) {
                                    Button("Delete", role: .destructive) {
                                        try? state.memory.forget(key: draft.key)
                                        Task { await state.refreshJournals() }
                                    }
                                }
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle("Drafts")
            .navigationBarTitleDisplayMode(.large)
        }
    }
}

struct DraftRow: View {
    let draft: SlowClawMemoryEntry

    var body: some View {
        Text(draft.content)
            .font(.body)
            .lineLimit(5)
            .padding(.vertical, 4)
    }
}

// MARK: - Profile View

struct ProfileView: View {
    @EnvironmentObject var state: AppState
    @AppStorage("slowclaw.api_key") private var apiKeyInput = ""
    @AppStorage("slowclaw.model") private var modelInput = "gpt-4o-mini"
    @AppStorage("slowclaw.base_url") private var baseURLInput = "https://api.openai.com/v1"

    var body: some View {
        NavigationStack {
            Form {
                Section("LLM Configuration") {
                    TextField("API Key", text: $apiKeyInput)
                        .textContentType(.password)
                        .onChange(of: apiKeyInput) { state.apiKey = apiKeyInput }

                    TextField("Model", text: $modelInput)
                        .onChange(of: modelInput) { state.model = modelInput }

                    TextField("Base URL", text: $baseURLInput)
                        .onChange(of: baseURLInput) { state.baseURL = baseURLInput }
                }

                Section("Interests") {
                    if state.interests.isEmpty {
                        Text("Write journal entries to mine them for interests. Tap chips in the Journal tab to boost or mute.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(state.interests, id: \.self) { interest in
                            HStack {
                                Text(interest)
                                Spacer()
                                InterestMultiplierControl(label: interest)
                            }
                        }
                        .onDelete { indices in
                            state.interests.remove(atOffsets: indices)
                        }
                    }
                }

                Section("Database") {
                    LabeledContent("Entries") {
                        Text("\(state.journals.count)")
                    }
                    LabeledContent("Drafts") {
                        Text("\(state.drafts.count)")
                    }
                }

                Section("About") {
                    LabeledContent("SlowClaw Social") {
                        Text("Zig Core v0.1")
                    }
                    LabeledContent("Engine") {
                        Text("Zig + SQLite + FTS5")
                    }
                }
            }
            .navigationTitle("Profile")
            .navigationBarTitleDisplayMode(.large)
            .onAppear {
                apiKeyInput = state.apiKey
                modelInput = state.model
                baseURLInput = state.baseURL
            }
        }
    }
}

/// Multiplier control for interests — tap to cycle Normal → Boost → Mute.
/// Visual: colored badge matching the state.
struct InterestMultiplierControl: View {
    let label: String
    @State private var state: MultiplierState = .normal

    enum MultiplierState { case normal, boost, mute }
    var color: Color {
        switch state {
        case .normal: return .secondary
        case .boost: return .green
        case .mute: return .red
        }
    }
    var text: String {
        switch state {
        case .normal: return "1×"
        case .boost: return "2×"
        case .mute: return "0×"
        }
    }

    var body: some View {
        Button {
            switch state {
            case .normal: state = .boost
            case .boost: state = .mute
            case .mute: state = .normal
            }
        } label: {
            Text(text)
                .font(.caption.monospaced().weight(.bold))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(color.opacity(0.15), in: Capsule())
                .foregroundStyle(color)
        }
        .buttonStyle(.plain)
    }
}
