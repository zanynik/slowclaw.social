// SlowClawApp.swift — native SwiftUI app for SlowClaw Social.
//
// Design system ported from the original Tauri/React app (web/src/styles.css):
//   - Warm off-white background (#fafaf9 light / #18181b dark)
//   - Green accent (#16a37f) matching the original brand
//   - Clean card-based layout with subtle shadows
//   - Bottom tab navigation: Reads → Journal → Drafts → Profile
//
// Three product loops:
//   Reads   — journal-ranked feed (RSS articles, ranked by interests)
//   Journal — capture/compose (audio-first, grows interests)
//   Drafts  — AI-distilled post drafts (→ Nostr)
//
// All logic runs in the Zig core via the C ABI. Swift is thin presentation.

import SwiftUI

// MARK: - Design System (from the original app's styles.css)

enum DS {
    // Light mode
    static let bg = Color(red: 0.98, green: 0.98, blue: 0.976)      // #fafaf9
    static let surface = Color.white
    static let surface2 = Color(red: 0.969, green: 0.969, blue: 0.961) // #f7f7f5
    static let ink = Color(red: 0.11, green: 0.11, blue: 0.102)     // #1c1c1a
    static let ink2 = Color(red: 0.267, green: 0.267, blue: 0.243)  // #44443e
    static let muted = Color(red: 0.549, green: 0.549, blue: 0.518) // #8c8c84
    static let line = Color(red: 0.91, green: 0.91, blue: 0.894)    // #e8e8e4

    // Accent (the original brand green)
    static let accent = Color(red: 0.086, green: 0.639, blue: 0.498) // #16a37f
    static let accentDim = Color(red: 0.086, green: 0.639, blue: 0.498, opacity: 0.12)
    static let accent2 = Color(red: 0.91, green: 0.365, blue: 0.29) // #e85d4a

    // Shadows
    static let shadowSm = AnyShapeStyle(Color.black.opacity(0.04))

    // Radii
    static let rSm: CGFloat = 8
    static let rMd: CGFloat = 14
    static let rLg: CGFloat = 20

    // Fonts
    static let titleFont = Font.system(size: 28, weight: .bold)
    static let headlineFont = Font.system(size: 17, weight: .semibold)
    static let bodyFont = Font.system(size: 15)
    static let captionFont = Font.system(size: 13)
    static let microFont = Font.system(size: 11)
}

// MARK: - App

@main
struct SlowClawApp: App {
    @StateObject private var appState = AppState()

    var body: some Scene {
        WindowGroup {
            MainTabView()
                .environmentObject(appState)
                .tint(DS.accent)
        }
    }
}

// MARK: - App State

@MainActor
final class AppState: ObservableObject {
    let memory: SlowClawSqliteMemory
    var llm: SlowClawLLMProvider?

    @Published var journals: [SlowClawMemoryEntry] = []
    @Published var drafts: [SlowClawMemoryEntry] = []
    @Published var interests: [String] = []
    @Published var selectedTab: AppTab = .journal

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
        self.apiKey = UserDefaults.standard.string(forKey: "slowclaw.api_key") ?? ""
        self.model = UserDefaults.standard.string(forKey: "slowclaw.model") ?? "gpt-4o-mini"
        self.baseURL = UserDefaults.standard.string(forKey: "slowclaw.base_url") ?? "https://api.openai.com/v1"

        let urls = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
        let dir = urls.first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let dbPath = dir.appendingPathComponent("slowclaw.sqlite").path
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        do {
            self.memory = try SlowClawSqliteMemory(path: dbPath, embedder: true)
        } catch {
            fatalError("Database error: \(error)")
        }

        setupLLM()
        Task { await refreshJournals() }
    }

    private func setupLLM() {
        guard !apiKey.isEmpty else { llm = nil; return }
        llm = SlowClawLLMProvider(baseURL: baseURL, apiKey: apiKey) { url, authHeader, contentType, body in
            guard let req = URL(string: url).map({ url in
                var r = URLRequest(url: url)
                r.httpMethod = "POST"
                r.setValue(authHeader, forHTTPHeaderField: "Authorization")
                r.setValue(contentType, forHTTPHeaderField: "Content-Type")
                r.httpBody = body
                r.timeoutInterval = 60
                return r
            }) else { return nil }
            let semaphore = DispatchSemaphore(value: 0)
            var result: Data?
            URLSession.shared.dataTask(with: req) { data, _, _ in
                result = data
                semaphore.signal()
            }.resume()
            semaphore.wait()
            return result
        }
    }

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
        guard let llm = llm else { return }
        let model = self.model
        DispatchQueue.global(qos: .utility).async {
            if let keywords = try? llm.extractInterests(journalText: text, model: model) {
                Task { @MainActor in
                    self.interests.append(contentsOf: keywords.filter { !self.interests.contains($0) })
                }
            }
        }
    }

    func generateDraft(from journal: SlowClawMemoryEntry) async {
        guard let llm = llm else { return }
        let model = self.model
        DispatchQueue.global(qos: .userInitiated).async {
            if let draft = try? llm.draftPost(journalText: journal.content, model: model) {
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
            ScrollView {
                VStack(spacing: 16) {
                    // Audio capture
                    AudioCaptureView()
                        .padding(.horizontal)

                    DS.card {
                        TextEditor(text: $newEntry)
                            .frame(minHeight: 100)
                            .scrollContentBackground(.hidden)
                            .padding(12)
                            .overlay(alignment: .topLeading) {
                                if newEntry.isEmpty {
                                    Text("What's on your mind?")
                                        .foregroundStyle(DS.muted)
                                        .padding(.horizontal, 16)
                                        .padding(.vertical, 20)
                                        .allowsHitTesting(false)
                                }
                            }
                    }
                    .padding(.horizontal)

                    HStack(spacing: 12) {
                        Button {
                            Task { await saveEntry() }
                        } label: {
                            Label("Save", systemImage: "square.and.arrow.down.fill")
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 6)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(DS.accent)
                        .disabled(newEntry.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                        if state.llm != nil {
                            Button {
                                Task { await synthesize() }
                            } label: {
                                Label("Polish", systemImage: "sparkles")
                                    .frame(maxWidth: .infinity)
                                    .padding(.vertical, 6)
                            }
                            .buttonStyle(.bordered)
                            .tint(DS.accent)
                            .disabled(newEntry.isEmpty || isSynthesizing)
                        }
                    }
                    .padding(.horizontal)

                    // Interest chips
                    if !state.interests.isEmpty {
                        InterestChipsRow(interests: state.interests)
                            .padding(.horizontal)
                    }

                    // Journal entries
                    ForEach(state.journals, id: \.id) { entry in
                        JournalCard(entry: entry)
                            .padding(.horizontal)
                            .contextMenu {
                                Button {
                                    Task { await state.generateDraft(from: entry) }
                                } label: {
                                    Label("Draft Post", systemImage: "square.and.pencil")
                                }
                                Button(role: .destructive) {
                                    try? state.memory.forget(key: entry.key)
                                    Task { await state.refreshJournals() }
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                    }
                }
                .padding(.vertical)
            }
            .background(DS.bg)
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
        let model = state.model
        DispatchQueue.global(qos: .userInitiated).async {
            if let polished = try? llm.synthesizeJournal(transcript: transcript, model: model) {
                DispatchQueue.main.async { newEntry = polished }
            }
        }
    }
}

// MARK: - Reads View (Feed loop) — crash-safe

struct ReadsView: View {
    @EnvironmentObject var state: AppState
    @State private var feedItems: [RankedFeedItem] = []
    @State private var isLoading = false
    @State private var loadError: String?

    private let defaultFeeds: [(url: String, name: String)] = [
        ("https://hnrss.org/frontpage", "Hacker News"),
        ("https://www.theverge.com/rss/index.xml", "The Verge"),
    ]

    var body: some View {
        NavigationStack {
            Group {
                if isLoading && feedItems.isEmpty {
                    VStack(spacing: 12) {
                        ProgressView()
                        Text("Fetching feeds…")
                            .font(DS.captionFont)
                            .foregroundStyle(DS.muted)
                    }
                } else if feedItems.isEmpty {
                    ContentUnavailableView(
                        "No reads yet",
                        systemImage: "newspaper",
                        description: Text("Pull down to fetch RSS feeds.\nWrite journals to steer the ranking by your interests.")
                    )
                } else {
                    ScrollView {
                        LazyVStack(spacing: 12) {
                            ForEach(feedItems) { item in
                                FeedCard(item: item, interests: state.interests)
                            }
                        }
                        .padding()
                    }
                }
            }
            .background(DS.bg)
            .navigationTitle("Reads")
            .navigationBarTitleDisplayMode(.large)
            .refreshable { await loadFeeds() }
            .task {
                if feedItems.isEmpty && !isLoading { await loadFeeds() }
            }
        }
    }

    private func loadFeeds() async {
        isLoading = true
        loadError = nil

        let topics = state.interests.map { SlowClawTopic(label: $0, weight: 1.0) }
        var allRanked: [RankedFeedItem] = []

        for feed in defaultFeeds {
            guard let url = URL(string: feed.url) else { continue }
            do {
                let (data, response) = try await URLSession.shared.data(from: url)
                guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { continue }
                guard let xml = String(data: data, encoding: .utf8) else { continue }

                // Parse + rank via the Zig core — crash-safe (returns nil on error)
                if let ranked = slowClawParseAndRankRSS(xml: xml, sourceLabel: feed.name, topics: topics) {
                    allRanked.append(contentsOf: ranked)
                }
            } catch {
                continue // Skip failed feeds
            }
        }

        allRanked.sort { $0.score > $1.score }
        feedItems = Array(allRanked.prefix(50))
        isLoading = false
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
                        description: Text("Long-press a journal entry and tap 'Draft Post' to let AI distill it into a shareable post.")
                    )
                } else {
                    ScrollView {
                        LazyVStack(spacing: 12) {
                            ForEach(state.drafts, id: \.id) { draft in
                                DS.card {
                                    VStack(alignment: .leading, spacing: 8) {
                                        Text(draft.content)
                                            .font(DS.bodyFont)
                                        HStack {
                                            Text("Draft")
                                                .font(DS.microFont)
                                                .foregroundStyle(DS.muted)
                                            Spacer()
                                        }
                                    }
                                }
                                .contextMenu {
                                    Button(role: .destructive) {
                                        try? state.memory.forget(key: draft.key)
                                        Task { await state.refreshJournals() }
                                    } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                }
                            }
                        }
                        .padding()
                    }
                }
            }
            .background(DS.bg)
            .navigationTitle("Drafts")
            .navigationBarTitleDisplayMode(.large)
        }
    }
}

// MARK: - Profile View

struct ProfileView: View {
    @EnvironmentObject var state: AppState
    @State private var apiKeyInput = ""
    @State private var modelInput = "gpt-4o-mini"
    @State private var baseURLInput = "https://api.openai.com/v1"

    var body: some View {
        NavigationStack {
            Form {
                Section("LLM Configuration") {
                    SecureField("API Key", text: $apiKeyInput)
                        .onChange(of: apiKeyInput) { state.apiKey = apiKeyInput }
                    TextField("Model", text: $modelInput)
                        .onChange(of: modelInput) { state.model = modelInput }
                    TextField("Base URL", text: $baseURLInput)
                        .onChange(of: baseURLInput) { state.baseURL = baseURLInput }
                }

                Section("Interests") {
                    if state.interests.isEmpty {
                        Text("Write journal entries to mine them for interests.")
                            .font(DS.captionFont)
                            .foregroundStyle(DS.muted)
                    } else {
                        ForEach(state.interests, id: \.self) { interest in
                            Text(interest)
                        }
                        .onDelete { state.interests.remove(atOffsets: $0) }
                    }
                }

                Section("Database") {
                    LabeledContent("Entries") { Text("\(state.journals.count)") }
                    LabeledContent("Drafts") { Text("\(state.drafts.count)") }
                }

                Section("About") {
                    LabeledContent("SlowClaw Social") { Text("v0.2.0") }
                    LabeledContent("Engine") { Text("Zig + SQLite") }
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

// MARK: - Shared UI Components (matching the original app's design)

extension DS {
    /// A card container with the original app's surface styling.
    static func card<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(16)
            .background(surface)
            .clipShape(RoundedRectangle(cornerRadius: rMd, style: .continuous))
            .shadow(color: Color.black.opacity(0.04), radius: 6, y: 1)
    }
}

/// Journal entry card.
struct JournalCard: View {
    let entry: SlowClawMemoryEntry

    var body: some View {
        DS.card {
            VStack(alignment: .leading, spacing: 6) {
                Text(entry.content)
                    .font(DS.bodyFont)
                    .foregroundStyle(DS.ink)
                    .lineLimit(4)

                if let score = entry.score, score > 0 {
                    HStack {
                        Text(String(format: "%.0f%%", score * 100))
                            .font(DS.microFont.monospacedDigit())
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(DS.accentDim, in: Capsule())
                            .foregroundStyle(DS.accent)
                    }
                }
            }
        }
    }
}

/// Interest chips row (horizontal scroll, tap to cycle boost/mute).
struct InterestChipsRow: View {
    let interests: [String]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(interests, id: \.self) { interest in
                    Text(interest)
                        .font(DS.captionFont.weight(.medium))
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(DS.accentDim, in: Capsule())
                        .foregroundStyle(DS.accent)
                }
            }
        }
        .frame(height: 32)
    }
}

/// Ranked feed card matching the original app's feed card aesthetic.
struct FeedCard: View {
    let item: RankedFeedItem
    let interests: [String]

    var matchedInterests: [String] {
        let title = item.title.lowercased()
        let desc = item.description.lowercased()
        return interests.filter { title.contains($0) || desc.contains($0) }
    }

    var body: some View {
        DS.card {
            VStack(alignment: .leading, spacing: 10) {
                // Title
                Text(item.title)
                    .font(DS.headlineFont)
                    .foregroundStyle(DS.ink)
                    .lineLimit(3)

                // Description
                if !item.description.isEmpty {
                    Text(item.description.strippingHTML())
                        .font(DS.captionFont)
                        .foregroundStyle(DS.ink2)
                        .lineLimit(2)
                }

                // Interest match badges
                if !matchedInterests.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(matchedInterests.prefix(3), id: \.self) { interest in
                            Text(interest)
                                .font(DS.microFont.weight(.semibold))
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(DS.accentDim, in: Capsule())
                                .foregroundStyle(DS.accent)
                        }
                    }
                }

                // Footer
                HStack(spacing: 12) {
                    Label(item.sourceLabel, systemImage: "globe")
                        .font(DS.microFont)
                        .foregroundStyle(DS.muted)

                    Label("\(item.readMinutes) min", systemImage: "book")
                        .font(DS.microFont)
                        .foregroundStyle(DS.muted)

                    Spacer()

                    Text(String(format: "%.2f", item.score))
                        .font(DS.microFont.monospacedDigit())
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(scoreColor.opacity(0.12), in: Capsule())
                        .foregroundStyle(scoreColor)
                }
            }
        }
    }

    private var scoreColor: Color {
        if item.score > 1.5 { return DS.accent }
        if item.score > 1.0 { return Color.blue }
        return DS.muted
    }
}

// MARK: - HTML stripping helper

extension String {
    /// Strip HTML tags (RSS descriptions often contain HTML).
    func strippingHTML() -> String {
        guard self.contains("<") else { return self }
        var result = ""
        var inside = false
        for ch in self {
            if ch == "<" { inside = true }
            else if ch == ">" { inside = false }
            else if !inside { result.append(ch) }
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
