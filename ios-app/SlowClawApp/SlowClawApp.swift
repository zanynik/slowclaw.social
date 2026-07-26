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

// MARK: - Design System (from the original app's styles.css, with dark mode)

enum DS {
    // Light mode colors
    private static let bg_l = Color(red: 0.98, green: 0.98, blue: 0.976)      // #fafaf9
    private static let surface_l = Color.white
    private static let surface2_l = Color(red: 0.969, green: 0.969, blue: 0.961) // #f7f7f5
    private static let surface3_l = Color(red: 0.937, green: 0.937, blue: 0.929) // #efefed
    private static let ink_l = Color(red: 0.11, green: 0.11, blue: 0.102)     // #1c1c1a
    private static let ink2_l = Color(red: 0.267, green: 0.267, blue: 0.243)  // #44443e
    private static let muted_l = Color(red: 0.549, green: 0.549, blue: 0.518) // #8c8c84
    private static let line_l = Color(red: 0.91, green: 0.91, blue: 0.894)    // #e8e8e4

    // Dark mode colors (matching the original app's dark theme)
    private static let bg_d = Color(red: 0.094, green: 0.094, blue: 0.106)    // #18181b
    private static let surface_d = Color(red: 0.153, green: 0.153, blue: 0.165) // #27272a
    private static let surface2_d = Color(red: 0.184, green: 0.184, blue: 0.2)  // #2f2f33
    private static let surface3_d = Color(red: 0.227, green: 0.227, blue: 0.243) // #3a3a3e
    private static let ink_d = Color(red: 0.941, green: 0.941, blue: 0.929)   // #f0f0ed
    private static let ink2_d = Color(red: 0.769, green: 0.769, blue: 0.737)  // #c4c4bc
    private static let muted_d = Color(red: 0.471, green: 0.471, blue: 0.478) // #78787a
    private static let line_d = Color(red: 0.227, green: 0.227, blue: 0.243)  // #3a3a3e

    // Accent (same in both modes)
    private static let _accent = Color(red: 0.086, green: 0.639, blue: 0.498) // #16a37f
    private static let _accent2 = Color(red: 0.91, green: 0.365, blue: 0.29)  // #e85d4a
    /// Like-red used in the reference feed action bar (#ff3b5c).
    private static let _like = Color(red: 1.0, green: 0.231, blue: 0.361)

    // Dynamic colors that adapt to light/dark
    static func bg(_ scheme: ColorScheme) -> Color { scheme == .dark ? bg_d : bg_l }
    static func surface(_ scheme: ColorScheme) -> Color { scheme == .dark ? surface_d : surface_l }
    static func surface2(_ scheme: ColorScheme) -> Color { scheme == .dark ? surface2_d : surface2_l }
    static func surface3(_ scheme: ColorScheme) -> Color { scheme == .dark ? surface3_d : surface3_l }
    static func ink(_ scheme: ColorScheme) -> Color { scheme == .dark ? ink_d : ink_l }
    static func ink2(_ scheme: ColorScheme) -> Color { scheme == .dark ? ink2_d : ink2_l }
    static func muted(_ scheme: ColorScheme) -> Color { scheme == .dark ? muted_d : muted_l }
    static func line(_ scheme: ColorScheme) -> Color { scheme == .dark ? line_d : line_l }
    static func accent(_ scheme: ColorScheme) -> Color { _accent }
    static func accentDim(_ scheme: ColorScheme) -> Color { _accent.opacity(scheme == .dark ? 0.18 : 0.12) }

    // Static accent for tinting (tab bars, buttons)
    static let accentColor = _accent
    static let accent2Color = _accent2
    static let likeColor = _like

    // Radii (matching styles.css --r-* tokens)
    static let rSm: CGFloat = 8     // reads-card
    static let rMd: CGFloat = 14    // inputs
    static let rLg: CGFloat = 20    // textareas / nav items
    static let rXl: CGFloat = 28    // primary cards (.card)
    static let rPill: CGFloat = 9999

    // Fonts (Inter isn't bundled; SF is the on-device equivalent. Sizes track
    // the reference: topbar h1 1.4rem, card h2/h3 1.05rem, body ~0.95rem,
    // caption ~0.84rem, eyebrow ~0.72rem.)
    static let topbarFont = Font.system(size: 22, weight: .bold)              // topbar h1
    static let titleFont = Font.system(size: 28, weight: .bold)
    static let cardTitleFont = Font.system(size: 17, weight: .semibold)       // .card h2/h3
    static let readsTitleFont = Font.system(size: 17, weight: .bold)          // .reads-card-title
    static let headlineFont = Font.system(size: 17, weight: .semibold)
    static let bodyFont = Font.system(size: 15)                               // .text base
    static let captionFont = Font.system(size: 13)                            // .text-sm
    static let eyebrowFont = Font.system(size: 11, weight: .semibold)         // .eyebrow-ish
    static let microFont = Font.system(size: 11)
    static let sourceLabelFont = Font.system(size: 11, weight: .semibold)     // .reads-card-source (uppercased)
}

// MARK: - App

/// Persisted theme preference ("light" | "dark"). Mirrors the reference app's
/// `data-theme` toggle on `<html>`. Defaults to system when unset.
enum AppTheme: String {
    case light, dark
}

@main
struct SlowClawApp: App {
    @StateObject private var appState = AppState()
    @AppStorage("slowclaw.theme") private var themeRaw: String = ""

    private var preferredScheme: ColorScheme? {
        switch AppTheme(rawValue: themeRaw) {
        case .light: return .light
        case .dark: return .dark
        case .none: return nil // follow system
        }
    }

    var body: some Scene {
        WindowGroup {
            AppShell()
                .environmentObject(appState)
                .preferredColorScheme(preferredScheme)
                .tint(DS.accentColor)
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
    // Reads is the default tab (matches the reference app: the unified "for me"
    // stream is the home surface).
    @Published var selectedTab: AppTab = .reads

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
    /// Line-style SF Symbol matching the reference SVG icons in BottomNav.tsx.
    var icon: String {
        switch self {
        case .reads: return "book"               // closed book (reads stream)
        case .journal: return "square.and.pencil" // capture/compose
        case .drafts: return "sparkles"           // AI-distilled drafts
        case .profile: return "person.crop.circle"
        }
    }
}

// MARK: - App Shell (topbar + active tab + custom bottom nav)
//
// Mirrors the reference layout: one translucent blurred topbar ("SlowClaw"
// wordmark + theme toggle) over the active tab content, with a custom icon-only
// bottom nav. Tabs no longer carry their own NavigationStack title bars, so the
// topbar is the single chrome header — matching web/src/App.tsx.

struct AppShell: View {
    @EnvironmentObject var state: AppState
    @Environment(\.colorScheme) var scheme
    @AppStorage("slowclaw.theme") private var themeRaw: String = ""

    var body: some View {
        Group {
            switch state.selectedTab {
            case .reads: ReadsView()
            case .journal: JournalView()
            case .drafts: DraftsView()
            case .profile: ProfileView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DS.bg(scheme))
        // Pin the top bar above the content's top safe area, extending the
        // translucent material under the status bar (matches the reference).
        .safeAreaInset(edge: .top, spacing: 0) {
            TopBar(scheme: scheme, themeRaw: $themeRaw)
        }
        // Pin the bottom nav above the home indicator.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            BottomNav(selection: $state.selectedTab, scheme: scheme)
        }
        .background(DS.bg(scheme).ignoresSafeArea())
    }
}

/// Translucent blurred top bar: "SlowClaw" wordmark + theme toggle.
/// Matches `.topbar` in styles.css (blur(20px) saturate(1.4), sticky). The bar
/// extends under the status bar; the inner content adds the top safe-area inset.
struct TopBar: View {
    let scheme: ColorScheme
    @Binding var themeRaw: String

    private var isDark: Bool {
        if let t = AppTheme(rawValue: themeRaw) { return t == .dark }
        return scheme == .dark
    }

    var body: some View {
        HStack {
            Text("SlowClaw")
                .font(DS.topbarFont)
                .foregroundStyle(DS.ink(scheme))
                .kerning(-0.4)
            Spacer()
            Button {
                themeRaw = (isDark ? AppTheme.light : AppTheme.dark).rawValue
            } label: {
                Image(systemName: isDark ? "sun.max" : "moon")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(DS.muted(scheme))
                    .frame(width: 36, height: 36)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 10)
        .background(.ultraThinMaterial)
        .overlay(alignment: .bottom) {
            Rectangle().fill(DS.line(scheme)).frame(height: 0.5)
        }
    }
}

/// Icon-only bottom nav matching BottomNav.tsx. Active = accent green + dim
/// capsule background + 1.1× scale. Blurred translucent surface; the bar
/// extends into the bottom safe area.
struct BottomNav: View {
    @Binding var selection: AppTab
    let scheme: ColorScheme

    var body: some View {
        HStack(spacing: 0) {
            ForEach(AppTab.allCases, id: \.self) { tab in
                let active = selection == tab
                Button {
                    if selection != tab {
                        UISelectionFeedbackGenerator().selectionChanged()
                        selection = tab
                    }
                } label: {
                    Image(systemName: tab.icon)
                        .font(.system(size: 22, weight: .regular))
                        .scaleEffect(active ? 1.1 : 1.0)
                        .foregroundStyle(active ? DS.accent(scheme) : DS.muted(scheme))
                        .frame(maxWidth: .infinity)
                        .frame(height: 44)
                        .padding(.vertical, 8)
                        .background(
                            Group {
                                if active {
                                    Capsule().fill(DS.accentDim(scheme))
                                } else {
                                    Color.clear
                                }
                            }
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel(tab.label)
                .accessibilityAddTraits(active ? .isSelected : [])
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 8)
        .padding(.bottom, 8)
        .background(.ultraThinMaterial)
        .overlay(alignment: .top) {
            Rectangle().fill(DS.line(scheme)).frame(height: 0.5)
        }
    }
}

// MARK: - Journal View (Capture loop)

struct JournalView: View {
    @Environment(\.colorScheme) var scheme
    @EnvironmentObject var state: AppState
    @State private var newEntry = ""
    @State private var isSynthesizing = false

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                // Audio capture
                AudioCaptureView()
                    .padding(.horizontal, 16)

                DS.card(scheme) {
                    TextEditor(text: $newEntry)
                        .frame(minHeight: 100)
                        .scrollContentBackground(.hidden)
                        .font(DS.bodyFont)
                        .foregroundStyle(DS.ink(scheme))
                        .padding(.vertical, 4)
                        .overlay(alignment: .topLeading) {
                            if newEntry.isEmpty {
                                Text("What's on your mind?")
                                    .font(DS.bodyFont)
                                    .foregroundStyle(DS.muted(scheme))
                                    .padding(.horizontal, 4)
                                    .padding(.vertical, 8)
                                    .allowsHitTesting(false)
                            }
                        }
                }
                .padding(.horizontal, 16)

                HStack(spacing: 12) {
                    Button {
                        Task { await saveEntry() }
                    } label: {
                        Label("Save", systemImage: "square.and.arrow.down.fill")
                            .font(DS.bodyFont.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(DS.accentColor)
                    .disabled(newEntry.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    if state.llm != nil {
                        Button {
                            Task { await synthesize() }
                        } label: {
                            Label("Polish", systemImage: "sparkles")
                                .font(DS.bodyFont.weight(.semibold))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 10)
                        }
                        .buttonStyle(.bordered)
                        .tint(DS.accentColor)
                        .disabled(newEntry.isEmpty || isSynthesizing)
                    }
                }
                .padding(.horizontal, 16)

                // Interest chips
                if !state.interests.isEmpty {
                    InterestChipsRow(interests: state.interests)
                        .padding(.horizontal, 16)
                }

                // Journal entries
                ForEach(state.journals, id: \.id) { entry in
                    JournalCard(entry: entry)
                        .padding(.horizontal, 16)
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
            .padding(.top, 16)
            .padding(.bottom, 24)
        }
        .background(DS.bg(scheme))
        .task { await state.refreshJournals() }
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
    @Environment(\.colorScheme) var scheme
    @EnvironmentObject var state: AppState
    @State private var feedItems: [RankedFeedItem] = []
    @State private var isLoading = false
    @State private var loadError: String?

    private let defaultFeeds: [(url: String, name: String)] = [
        ("https://hnrss.org/frontpage", "Hacker News"),
        ("https://www.theverge.com/rss/index.xml", "The Verge"),
    ]

    var body: some View {
        Group {
            if isLoading && feedItems.isEmpty {
                VStack(spacing: 10) {
                    ProgressView()
                    Text("Loading…")
                        .font(DS.captionFont)
                        .foregroundStyle(DS.muted(scheme))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if feedItems.isEmpty {
                if let loadError {
                    // Surface the failure instead of silently looking empty.
                    VStack(spacing: 12) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 36))
                            .foregroundStyle(DS.muted(scheme))
                        Text("Couldn't load reads")
                            .font(DS.cardTitleFont)
                            .foregroundStyle(DS.ink(scheme))
                        Text(loadError)
                            .font(DS.captionFont)
                            .foregroundStyle(DS.muted(scheme))
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                        Button("Retry") { Task { await loadFeeds() } }
                            .buttonStyle(.bordered)
                            .tint(DS.accentColor)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: "newspaper")
                            .font(.system(size: 40))
                            .foregroundStyle(DS.muted(scheme))
                        Text("No articles yet")
                            .font(DS.cardTitleFont)
                            .foregroundStyle(DS.ink(scheme))
                        Text("Long-form posts and news — ranked by what you've been writing about. Pull to refresh to load.")
                            .font(DS.captionFont)
                            .foregroundStyle(DS.muted(scheme))
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 32)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        // Subtitle row matching the reference: "{N} stories · ranked by your lens".
                        HStack {
                            Text("\(feedItems.count) stories")
                                .font(DS.captionFont)
                                .foregroundStyle(DS.muted(scheme))
                            Text("·")
                                .font(DS.captionFont)
                                .foregroundStyle(DS.muted(scheme))
                            Text("ranked by your lens")
                                .font(DS.captionFont)
                                .foregroundStyle(DS.muted(scheme))
                            Spacer()
                        }
                        .padding(.horizontal, 4)

                        ForEach(feedItems) { item in
                            FeedCard(item: item, interests: state.interests)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 16)
                    .padding(.bottom, 24)
                }
                .refreshable { await loadFeeds() }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DS.bg(scheme))
        .task {
            if feedItems.isEmpty && !isLoading { await loadFeeds() }
        }
    }

    @MainActor
    private func loadFeeds() async {
        isLoading = true
        loadError = nil

        // Snapshot topics on the main actor, then do all the network + FFI work
        // off the main actor. The Zig parse/rank is synchronous and blocking, so
        // running it on a background task keeps the UI responsive.
        let topics = state.interests.map { SlowClawTopic(label: $0, weight: 1.0) }
        let feeds = defaultFeeds

        let fetched: ([RankedFeedItem], String?) = await Task.detached(priority: .userInitiated) {
            var allRanked: [RankedFeedItem] = []
            var lastError: String?

            for feed in feeds {
                guard let url = URL(string: feed.url) else { continue }
                do {
                    let (data, response) = try await URLSession.shared.data(from: url)
                    guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                        lastError = "Feed \(feed.name) returned an error."
                        continue
                    }
                    guard let xml = String(data: data, encoding: .utf8) else {
                        lastError = "Feed \(feed.name) was not valid UTF-8."
                        continue
                    }

                    // Parse + rank via the Zig core — returns nil on error.
                    if let ranked = slowClawParseAndRankRSS(xml: xml, sourceLabel: feed.name, topics: topics) {
                        allRanked.append(contentsOf: ranked)
                    }
                } catch {
                    lastError = "Couldn't reach \(feed.name)."
                    continue
                }
            }

            allRanked.sort { $0.score > $1.score }
            return (Array(allRanked.prefix(50)), allRanked.isEmpty ? lastError : nil)
        }.value

        // Hop back to the main actor to mutate UI state.
        feedItems = fetched.0
        if feedItems.isEmpty { loadError = fetched.1 ?? "No stories right now. Pull to retry." }
        isLoading = false
    }
}

// MARK: - Drafts View (Share loop) — TweetClaw-style inline editing

struct DraftsView: View {
    @Environment(\.colorScheme) var scheme
    @EnvironmentObject var state: AppState

    var body: some View {
        Group {
            if state.drafts.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 40))
                        .foregroundStyle(DS.muted(scheme))
                    Text("No drafts yet")
                        .font(DS.cardTitleFont)
                        .foregroundStyle(DS.ink(scheme))
                    Text("Long-press a journal entry and tap 'Draft Post' to let AI distill it into a post.")
                        .font(DS.captionFont)
                        .foregroundStyle(DS.muted(scheme))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 32)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 12) {
                        ForEach(state.drafts, id: \.id) { draft in
                            DraftCard(draft: draft, sourceJournalContent: nil)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 16)
                    .padding(.bottom, 24)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DS.bg(scheme))
    }
}

/// TweetClaw-style draft card with inline editing, regenerate, and character count.
/// Mirrors the original app's inline draft editor pattern.
struct DraftCard: View {
    @Environment(\.colorScheme) var scheme
    @EnvironmentObject var state: AppState
    let draft: SlowClawMemoryEntry
    let sourceJournalContent: String? // the journal this was drafted from (for regenerate)

    @State private var editedText = ""
    @State private var isEditing = false
    @State private var isRegenerating = false
    @State private var showCopyAlert = false

    private let maxChars = 300

    var charCount: Int { editedText.count }
    var charCountColor: Color {
        if charCount > maxChars { return .red }
        if charCount > maxChars - 50 { return .orange }
        return DS.muted(scheme)
    }

    var body: some View {
        DS.card(scheme) {
            VStack(alignment: .leading, spacing: 10) {
                // Editable text or display text
                if isEditing {
                    TextEditor(text: $editedText)
                        .font(DS.bodyFont)
                        .frame(minHeight: 80)
                        .scrollContentBackground(.hidden)
                        .padding(8)
                        .background(DS.surface2(scheme), in: RoundedRectangle(cornerRadius: 8))
                } else {
                    Text(editedText.isEmpty ? draft.content : editedText)
                        .font(DS.bodyFont)
                        .foregroundStyle(DS.ink(scheme))
                }

                // Toolbar
                HStack(spacing: 8) {
                    // Character count
                    Text("\(charCount)/\(maxChars)")
                        .font(DS.microFont.monospacedDigit())
                        .foregroundStyle(charCountColor)

                    Spacer()

                    // Edit / Done toggle
                    Button {
                        if isEditing { editedText = editedText.trimmingCharacters(in: .whitespacesAndNewlines) }
                        isEditing.toggle()
                    } label: {
                        Image(systemName: isEditing ? "checkmark.circle.fill" : "pencil")
                            .font(.system(size: 16))
                            .foregroundStyle(DS.accent(scheme))
                    }

                    // Regenerate (if we have the source journal)
                    if sourceJournalContent != nil && state.llm != nil {
                        Button {
                            Task { await regenerate() }
                        } label: {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 16))
                                .foregroundStyle(DS.accent(scheme))
                        }
                        .disabled(isRegenerating)
                    }

                    // Copy
                    Button {
                        UIPasteboard.general.string = editedText.isEmpty ? draft.content : editedText
                        showCopyAlert = true
                    } label: {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 16))
                            .foregroundStyle(DS.muted(scheme))
                    }

                    // Delete
                    Button(role: .destructive) {
                        try? state.memory.forget(key: draft.key)
                        Task { await state.refreshJournals() }
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 16))
                            .foregroundStyle(DS.accent2Color)
                    }
                }
            }
        }
        .alert("Copied", isPresented: $showCopyAlert) {
            Button("OK", role: .cancel) {}
        }
        .onAppear {
            if editedText.isEmpty { editedText = draft.content }
        }
    }

    private func regenerate() async {
        guard let llm = state.llm, let source = sourceJournalContent else { return }
        isRegenerating = true
        defer { isRegenerating = false }
        let model = state.model
        DispatchQueue.global(qos: .userInitiated).async {
            if let newDraft = try? llm.draftPost(journalText: source, model: model) {
                DispatchQueue.main.async { editedText = newDraft }
            }
        }
    }
}

// MARK: - Profile View

struct ProfileView: View {
    @Environment(\.colorScheme) var scheme
    @EnvironmentObject var state: AppState
    @State private var apiKeyInput = ""
    @State private var modelInput = "gpt-4o-mini"
    @State private var baseURLInput = "https://api.openai.com/v1"

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                // LLM Configuration
                DS.card(scheme) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("LLM Configuration")
                            .font(DS.cardTitleFont)
                            .foregroundStyle(DS.ink(scheme))

                        VStack(alignment: .leading, spacing: 6) {
                            Text("API Key")
                                .font(DS.eyebrowFont)
                                .foregroundStyle(DS.muted(scheme))
                                .textCase(.uppercase)
                            SecureField("", text: $apiKeyInput, prompt: Text("sk-…").foregroundColor(DS.muted(scheme)))
                                .textFieldStyle(.plain)
                                .padding(10)
                                .background(DS.surface2(scheme), in: RoundedRectangle(cornerRadius: DS.rMd, style: .continuous))
                                .onChange(of: apiKeyInput) { state.apiKey = apiKeyInput }
                        }

                        VStack(alignment: .leading, spacing: 6) {
                            Text("Model")
                                .font(DS.eyebrowFont)
                                .foregroundStyle(DS.muted(scheme))
                                .textCase(.uppercase)
                            TextField("", text: $modelInput, prompt: Text("gpt-4o-mini").foregroundColor(DS.muted(scheme)))
                                .textFieldStyle(.plain)
                                .padding(10)
                                .background(DS.surface2(scheme), in: RoundedRectangle(cornerRadius: DS.rMd, style: .continuous))
                                .onChange(of: modelInput) { state.model = modelInput }
                        }

                        VStack(alignment: .leading, spacing: 6) {
                            Text("Base URL")
                                .font(DS.eyebrowFont)
                                .foregroundStyle(DS.muted(scheme))
                                .textCase(.uppercase)
                            TextField("", text: $baseURLInput, prompt: Text("https://api.openai.com/v1").foregroundColor(DS.muted(scheme)))
                                .textFieldStyle(.plain)
                                .keyboardType(.URL)
                                .autocorrectionDisabled()
                                .textInputAutocapitalization(.never)
                                .padding(10)
                                .background(DS.surface2(scheme), in: RoundedRectangle(cornerRadius: DS.rMd, style: .continuous))
                                .onChange(of: baseURLInput) { state.baseURL = baseURLInput }
                        }
                    }
                }

                // Interests
                DS.card(scheme) {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("Interests")
                                .font(DS.cardTitleFont)
                                .foregroundStyle(DS.ink(scheme))
                            Spacer()
                            Text("\(state.interests.count)")
                                .font(DS.captionFont.monospacedDigit())
                                .foregroundStyle(DS.muted(scheme))
                        }
                        if state.interests.isEmpty {
                            Text("Write journal entries to mine them for interests.")
                                .font(DS.captionFont)
                                .foregroundStyle(DS.muted(scheme))
                        } else {
                            FlowChips(interests: $state.interests, scheme: scheme)
                        }
                    }
                }

                // Database
                DS.card(scheme) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("Database")
                            .font(DS.cardTitleFont)
                            .foregroundStyle(DS.ink(scheme))
                        row("Entries", "\(state.journals.count))
                        Divider().background(DS.line(scheme))
                        row("Drafts", "\(state.drafts.count))
                    }
                }

                // About
                DS.card(scheme) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("About")
                            .font(DS.cardTitleFont)
                            .foregroundStyle(DS.ink(scheme))
                        row("SlowClaw Social", "v0.2.0")
                        Divider().background(DS.line(scheme))
                        row("Engine", "Zig + SQLite")
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 24)
        }
        .background(DS.bg(scheme))
        .onAppear {
            apiKeyInput = state.apiKey
            modelInput = state.model
            baseURLInput = state.baseURL
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label)
                .font(DS.bodyFont)
                .foregroundStyle(DS.ink2(scheme))
            Spacer()
            Text(value)
                .font(DS.bodyFont.monospacedDigit())
                .foregroundStyle(DS.muted(scheme))
        }
    }
}

// MARK: - Shared UI Components (matching the original app's design)

extension DS {
    /// Primary card container matching `.card` in styles.css: large 28px radius,
    /// surface bg, 1px line border, subtle shadow. Dark-mode aware.
    static func card<Content: View>(_ scheme: ColorScheme, @ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(.horizontal, 18)
            .padding(.vertical, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(surface(scheme))
            .overlay(
                RoundedRectangle(cornerRadius: rXl, style: .continuous)
                    .stroke(line(scheme), lineWidth: 1)
            )
            .clipShape(RoundedRectangle(cornerRadius: rXl, style: .continuous))
            .shadow(color: Color.black.opacity(scheme == .dark ? 0.18 : 0.05), radius: 8, y: 2)
    }
}

/// Journal entry card.
struct JournalCard: View {
    @Environment(\.colorScheme) var scheme
    let entry: SlowClawMemoryEntry

    var body: some View {
        DS.card(scheme) {
            VStack(alignment: .leading, spacing: 6) {
                Text(entry.content)
                    .font(DS.bodyFont)
                    .foregroundStyle(DS.ink(scheme))
                    .lineLimit(4)

                if let score = entry.score, score > 0 {
                    HStack {
                        Text(String(format: "%.0f%%", score * 100))
                            .font(DS.microFont.monospacedDigit())
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(DS.accentDim(scheme), in: Capsule())
                            .foregroundStyle(DS.accent(scheme))
                    }
                }
            }
        }
    }
}

/// Interest chips row (horizontal scroll) used on the Journal tab.
struct InterestChipsRow: View {
    @Environment(\.colorScheme) var scheme
    let interests: [String]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(interests, id: \.self) { interest in
                    Text(interest)
                        .font(DS.captionFont.weight(.medium))
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(DS.accentDim(scheme), in: Capsule())
                        .foregroundStyle(DS.accent(scheme))
                }
            }
        }
        .frame(height: 32)
    }
}

/// Wrapping interest chips with delete-on-tap, used on the Profile tab.
struct FlowChips: View {
    @Binding var interests: [String]
    let scheme: ColorScheme

    var body: some View {
        FlowLayout(spacing: 6, lineSpacing: 6) {
            ForEach(interests, id: \.self) { tag in
                Button {
                    interests.removeAll { $0 == tag }
                } label: {
                    HStack(spacing: 4) {
                        Text(tag)
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .bold))
                    }
                    .font(DS.captionFont.weight(.medium))
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(DS.accentDim(scheme), in: Capsule())
                    .foregroundStyle(DS.accent(scheme))
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// Ranked feed card mirroring the reference `.reads-card`:
/// 8px radius, 1px border, accent-green uppercase source + read time, title,
/// 3-line summary, 👍/👎 actions, and a "✨ {topic}" rationale chip.
struct FeedCard: View {
    @Environment(\.colorScheme) var scheme
    let item: RankedFeedItem
    let interests: [String]

    @State private var liked = false
    @State private var disliked = false

    private var host: String {
        guard let url = URL(string: item.link), let h = url.host else {
            return item.sourceLabel
        }
        return h.replacingOccurrences(of: "^www\\.", with: "", options: .regularExpression)
    }

    /// First journal topic the item matches — surfaces as the "why it's here" chip.
    private var rationaleTopic: String? {
        let title = item.title.lowercased()
        let desc = item.description.lowercased()
        return interests.first { title.contains($0) || desc.contains($0) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                // Source row: accent-green uppercase host + read time.
                HStack(spacing: 8) {
                    Text(host.uppercased())
                        .font(DS.sourceLabelFont)
                        .foregroundStyle(DS.accent(scheme))
                        .kerning(0.3)
                    Spacer()
                    Text("⏱ \(item.readMinutes) min")
                        .font(DS.captionFont)
                        .foregroundStyle(DS.muted(scheme))
                }

                // Title
                Text(item.title.isEmpty ? "Untitled" : item.title)
                    .font(DS.readsTitleFont)
                    .foregroundStyle(DS.ink(scheme))
                    .lineLimit(3)
                    .padding(.top, 2)

                // Summary (3-line clamp, like -webkit-line-clamp:3).
                if !item.description.isEmpty {
                    Text(item.description.strippingHTML())
                        .font(DS.captionFont)
                        .foregroundStyle(DS.muted(scheme))
                        .lineLimit(3)
                        .padding(.top, 2)
                }

                // Rationale chip ("✨ {topic}").
                if let topic = rationaleTopic {
                    Text("✨ \(topic)")
                        .font(DS.microFont.weight(.semibold))
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(DS.accentDim(scheme), in: Capsule())
                        .foregroundStyle(DS.accent(scheme))
                        .padding(.top, 6)
                }

                // Like / dislike actions.
                HStack(spacing: 18) {
                    Button {
                        liked.toggle()
                        if liked { disliked = false }
                        UISelectionFeedbackGenerator().selectionChanged()
                    } label: {
                        Image(systemName: liked ? "hand.thumbsup.fill" : "hand.thumbsup")
                            .font(.system(size: 16))
                            .foregroundStyle(liked ? DS.likeColor : DS.muted(scheme))
                    }
                    .buttonStyle(.plain)

                    Button {
                        disliked.toggle()
                        if disliked { liked = false }
                        UISelectionFeedbackGenerator().selectionChanged()
                    } label: {
                        Image(systemName: disliked ? "hand.thumbsdown.fill" : "hand.thumbsdown")
                            .font(.system(size: 16))
                            .foregroundStyle(disliked ? DS.accent2Color : DS.muted(scheme))
                    }
                    .buttonStyle(.plain)

                    Spacer()

                    if let url = URL(string: item.link), !item.link.isEmpty {
                        Image(systemName: "arrow.up.right.square")
                            .font(.system(size: 14))
                            .foregroundStyle(DS.muted(scheme))
                    }
                }
                .padding(.top, 8)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DS.surface(scheme))
        .overlay(
            RoundedRectangle(cornerRadius: DS.rSm, style: .continuous)
                .stroke(DS.line(scheme), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: DS.rSm, style: .continuous))
        .contentShape(Rectangle())
        .onTapGesture {
            guard let url = URL(string: item.link), !item.link.isEmpty else { return }
            UIApplication.shared.open(url)
        }
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

// MARK: - Flow layout (wrapping chips)

/// A simple wrapping flow layout for chips. Greedily packs subviews into rows
/// that fit the proposed width, then stacks the rows. iOS 16+ `Layout` protocol.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6
    var lineSpacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var totalHeight: CGFloat = 0
        var rowHeight: CGFloat = 0
        var rowWidth: CGFloat = 0
        var maxUsedWidth: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            let extra: CGFloat = rowWidth == 0 ? 0 : spacing
            if rowWidth + extra + size.width > maxWidth, rowWidth > 0 {
                // Flush the current row.
                maxUsedWidth = max(maxUsedWidth, rowWidth)
                totalHeight += rowHeight + lineSpacing
                rowWidth = size.width
                rowHeight = size.height
            } else {
                rowWidth += extra + size.width
                rowHeight = max(rowHeight, size.height)
            }
        }
        if rowWidth > 0 {
            maxUsedWidth = max(maxUsedWidth, rowWidth)
            totalHeight += rowHeight
        }
        return CGSize(width: min(maxWidth, maxUsedWidth), height: totalHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let maxX = bounds.minX + bounds.width
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x + size.width > maxX, x > bounds.minX {
                // Wrap to the next row.
                x = bounds.minX
                y += rowHeight + lineSpacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), anchor: .topLeading, proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
