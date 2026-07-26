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

    // Journal sidebar (matches the reference app's hamburger drawer). The
    // selected journal's content loads into the editor; nil = fresh new entry.
    @Published var journalSidebarOpen: Bool = false
    @Published var selectedJournalKey: String? = nil

    // TweetClaw (post generation). The prompt is editable + persisted; processed
    // journals are tracked so pull-to-generate picks a fresh entry each time.
    @Published var tweetClawPrompt: String {
        didSet { UserDefaults.standard.set(tweetClawPrompt, forKey: "slowclaw.tweetclaw.prompt") }
    }
    @Published var isGeneratingPosts = false
    @Published var generateStatus: String? = nil

    private var processedJournalKeys: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: "slowclaw.tweetclaw.processed") ?? []) }
        set { UserDefaults.standard.set(Array(newValue), forKey: "slowclaw.tweetclaw.processed") }
    }

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
        self.tweetClawPrompt = UserDefaults.standard.string(forKey: "slowclaw.tweetclaw.prompt") ??
            "You are a social media content writer. Turn the following journal entry into a concise, engaging tweet-style post (under 280 characters). Be authentic and conversational. Output ONLY the post text, no hashtags unless they add real value. No quotes around the text."

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

    /// Clear the journal selection so the editor shows a fresh, empty entry.
    /// Mirrors `resetJournalSession` in the reference app (the "+" button).
    func resetJournalSession() {
        selectedJournalKey = nil
    }

    /// The journal entry currently loaded into the editor, or nil for a new entry.
    var selectedJournal: SlowClawMemoryEntry? {
        guard let key = selectedJournalKey else { return nil }
        return journals.first { $0.key == key }
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

    // MARK: - TweetClaw (pull-to-generate)

    /// Pull-to-generate: pick the most-recently-modified unprocessed text journal
    /// (or a random one if all are processed) and turn it into one or more posts.
    /// Long entries are chunked at ~3200 chars; each chunk produces its own post.
    /// Mirrors the reference app's handleFeedPullRefresh / generatePostFromJournal.
    func tweetClawGenerateNext() async {
        guard let llm = llm else {
            generateStatus = "Add an LLM API key in Profile to generate posts."
            return
        }
        guard !journals.isEmpty else {
            generateStatus = "Write a journal entry first."
            return
        }
        isGeneratingPosts = true
        generateStatus = "Generating…"
        defer { isGeneratingPosts = false }

        // Pick the next journal to process.
        var processed = processedJournalKeys
        let candidates = journals.filter { $0.content.trimmingCharacters(in: .whitespacesAndNewlines).count > 10 }
        let unprocessed = candidates.filter { !processed.contains($0.key) }
        let journal = (unprocessed.first ?? candidates.randomElement())
        guard let journal = journal else {
            generateStatus = "No journal entries to process."
            return
        }

        let model = self.model
        let prompt = self.tweetClawPrompt
        // Snapshot the 10 most-recent existing draft texts to discourage repeats.
        let recentDrafts = drafts.prefix(10).map { $0.content }

        await withTaskGroup(of: Void.self) { group in
            for chunk in chunkForPosts(journal.content, limit: 3200) {
                group.addTask { [weak self] in
                    guard let self else { return }
                    var message = chunk
                    if !recentDrafts.isEmpty {
                        let dedupe = recentDrafts.prefix(10).joined(separator: "\n---\n")
                        message += "\n\n(Avoid repeating these posts you already wrote:)\n\(dedupe)"
                    }
                    // chat() honors the editable TweetClaw prompt as the system prompt.
                    if let post = try? llm.chat(systemPrompt: prompt, message: message, model: model, temperature: 0.8) {
                        let cleaned = post.trimmingCharacters(in: .whitespacesAndNewlines)
                            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'`"))
                        // Acceptance gate: 11–399 chars (matches the reference).
                        guard cleaned.count > 10, cleaned.count < 400 else { return }
                        let key = "draft_\(Date().timeIntervalSince1970)_\(UInt.random(in: 0..<1_000_000))"
                        let excerpt = String(chunk.prefix(80))
                        // Store with an excerpt marker so the card can show the source.
                        try? self.memory.store(key: key, content: cleaned, category: "core", sessionID: "drafts")
                        // Stash the source excerpt alongside (encoded in the key's
                        // metadata isn't supported; keep it simple — the draft body
                        // is the post itself, matching the reference).
                        _ = excerpt
                    }
                }
            }
        }

        processed.insert(journal.key)
        processedJournalKeys = processed
        await refreshJournals()
        generateStatus = nil
    }

    /// Split long text into chunks for per-chunk post generation. Mirrors the
    /// reference's CHUNK_CHAR_LIMIT + splitIntoChunks (paragraph boundaries).
    private func chunkForPosts(_ text: String, limit: Int) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > limit else { return [trimmed].filter { !$0.isEmpty } }
        var chunks: [String] = []
        var current = ""
        for para in trimmed.components(separatedBy: "\n\n") {
            if current.count + para.count > limit, !current.isEmpty {
                chunks.append(current)
                current = para
            } else {
                current += (current.isEmpty ? "" : "\n\n") + para
            }
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
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
        // Journal drawer (left-sliding, like the reference app's sidebar).
        .overlay {
            if state.selectedTab == .journal {
                JournalSidebar(scheme: scheme)
                    .transition(.move(edge: .leading).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.25), value: state.journalSidebarOpen)
        .background(DS.bg(scheme).ignoresSafeArea())
    }
}

/// Translucent blurred top bar: "SlowClaw" wordmark + theme toggle, plus — on
/// the Journal tab only — a hamburger (opens the journal drawer) and a "+"
/// (starts a fresh entry). Matches `.topbar` in styles.css (blur(20px)
/// saturate(1.4), sticky). The bar extends under the status bar; the inner
/// content adds the top safe-area inset.
struct TopBar: View {
    let scheme: ColorScheme
    @Binding var themeRaw: String
    @EnvironmentObject var state: AppState

    private var isDark: Bool {
        if let t = AppTheme(rawValue: themeRaw) { return t == .dark }
        return scheme == .dark
    }

    var body: some View {
        HStack(spacing: 10) {
            // Journal-only actions: hamburger (open drawer) + new session.
            if state.selectedTab == .journal {
                Button {
                    state.journalSidebarOpen = true
                } label: {
                    Image(systemName: "line.3.horizontal")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(DS.muted(scheme))
                        .frame(width: 34, height: 34)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Journals list")
            }

            Text("SlowClaw")
                .font(DS.topbarFont)
                .foregroundStyle(DS.ink(scheme))
                .kerning(-0.4)

            Spacer()

            if state.selectedTab == .journal {
                Button {
                    state.resetJournalSession()
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(DS.muted(scheme))
                        .frame(width: 34, height: 34)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("New journal entry")
            }

            Button {
                themeRaw = (isDark ? AppTheme.light : AppTheme.dark).rawValue
            } label: {
                Image(systemName: isDark ? "sun.max" : "moon")
                    .font(.system(size: 18, weight: .medium))
                    .foregroundStyle(DS.muted(scheme))
                    .frame(width: 34, height: 34)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Toggle theme")
        }
        .padding(.horizontal, 12)
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

// MARK: - Journal Sidebar (drawer)
//
// Mirrors the reference app's Journal drawer (web/src App.tsx
// `.sidebar-overlay` + `.sidebar`): a flat, WhatsApp-style list of journal
// entries (title + relative time + preview), a search filter, per-item
// delete, and tap-to-load-into-editor. Opens via the topbar hamburger;
// closes on backdrop tap or item selection.

struct JournalSidebar: View {
    let scheme: ColorScheme
    @EnvironmentObject var state: AppState
    @State private var search = ""

    private var filtered: [SlowClawMemoryEntry] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return state.journals }
        return state.journals.filter { $0.content.lowercased().contains(q) }
    }

    var body: some View {
        ZStack(alignment: .leading) {
            // Backdrop: tap to close.
            if state.journalSidebarOpen {
                Color.black.opacity(0.35)
                    .ignoresSafeArea()
                    .onTapGesture { state.journalSidebarOpen = false }
            }

            // Drawer panel.
            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    // Header.
                    HStack {
                        Text("Journals")
                            .font(DS.cardTitleFont)
                            .foregroundStyle(DS.ink(scheme))
                        Spacer()
                        Button {
                            state.journalSidebarOpen = false
                        } label: {
                            Image(systemName: "chevron.left")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(DS.muted(scheme))
                                .frame(width: 30, height: 30)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 18)
                    .padding(.top, 12)
                    .padding(.bottom, 10)

                    // Search field.
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 13))
                            .foregroundStyle(DS.muted(scheme))
                        TextField("", text: $search, prompt: Text("Search title or content").foregroundColor(DS.muted(scheme)))
                            .font(DS.bodyFont)
                            .textFieldStyle(.plain)
                            .autocorrectionDisabled()
                            .textInputAutocapitalization(.never)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(DS.surface2(scheme), in: RoundedRectangle(cornerRadius: DS.rMd, style: .continuous))
                    .padding(.horizontal, 18)

                    // Count row.
                    HStack {
                        Text("\(filtered.count) of \(state.journals.count)")
                            .font(DS.microFont)
                            .foregroundStyle(DS.muted(scheme))
                        Spacer()
                    }
                    .padding(.horizontal, 22)
                    .padding(.top, 8)
                    .padding(.bottom, 4)

                    // List.
                    if state.journals.isEmpty {
                        Spacer()
                        VStack(spacing: 6) {
                            Image(systemName: "book")
                                .font(.system(size: 28))
                                .foregroundStyle(DS.muted(scheme))
                            Text("No journals yet")
                                .font(DS.captionFont)
                                .foregroundStyle(DS.muted(scheme))
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.bottom, 80)
                    } else if filtered.isEmpty {
                        Spacer()
                        Text("No journals match your search.")
                            .font(DS.captionFont)
                            .foregroundStyle(DS.muted(scheme))
                            .padding(.bottom, 80)
                    } else {
                        ScrollView {
                            LazyVStack(spacing: 2) {
                                ForEach(filtered, id: \.id) { entry in
                                    journalRow(entry)
                                }
                            }
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .frame(width: 300)
                .frame(maxHeight: .infinity)
                .background(DS.surface(scheme))
                .overlay(alignment: .trailing) {
                    Rectangle().fill(DS.line(scheme)).frame(width: 0.5)
                }
                .shadow(color: Color.black.opacity(scheme == .dark ? 0.4 : 0.15), radius: 16, x: 2, y: 0)

                // Push the drawer to the leading edge; the rest is backdrop.
                Spacer(minLength: 0)
            }
            .offset(x: state.journalSidebarOpen ? 0 : -320)
        }
        .allowsHitTesting(state.journalSidebarOpen)
    }

    @ViewBuilder
    private func journalRow(_ entry: SlowClawMemoryEntry) -> some View {
        let active = state.selectedJournalKey == entry.key
        Button {
            state.selectedJournalKey = entry.key
            state.journalSidebarOpen = false
        } label: {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(titleOf(entry))
                            .font(DS.bodyFont.weight(.semibold))
                            .foregroundStyle(DS.ink(scheme))
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        Text(relativeTime(entry))
                            .font(DS.microFont)
                            .foregroundStyle(DS.muted(scheme))
                    }
                    if !previewOf(entry).isEmpty {
                        Text(previewOf(entry))
                            .font(DS.captionFont)
                            .foregroundStyle(DS.muted(scheme))
                            .lineLimit(1)
                    }
                }
                // Delete (appears on row tap in the reference; here always
                // visible as a small ghost button for discoverability).
                Button(role: .destructive) {
                    try? state.memory.forget(key: entry.key)
                    if state.selectedJournalKey == entry.key { state.selectedJournalKey = nil }
                    Task { await state.refreshJournals() }
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 13))
                        .foregroundStyle(DS.muted(scheme))
                        .frame(width: 26, height: 26)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(active ? DS.accentDim(scheme) : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// First non-empty line of the entry = its title.
    private func titleOf(_ entry: SlowClawMemoryEntry) -> String {
        let first = entry.content.split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init) ?? entry.content
        return first.trimmingCharacters(in: .whitespaces).isEmpty ? "Untitled" : first.trimmingCharacters(in: .whitespaces)
    }

    /// A short single-line preview after the title.
    private func previewOf(_ entry: SlowClawMemoryEntry) -> String {
        let lines = entry.content.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        let body = lines.dropFirst().joined(separator: " ")
        let trimmed = body.trimmingCharacters(in: .whitespaces)
        return String(trimmed.prefix(60))
    }

    /// Coarse relative-time string (matches the reference's getRelativeTime
    /// bucketing: now / Nm / Nh / Nd / Nw / Nmo, else a short date).
    private func relativeTime(_ entry: SlowClawMemoryEntry) -> String {
        let formatter = ISO8601DateFormatter()
        let date = formatter.date(from: entry.timestamp)
            ?? Date(timeIntervalSince1970: TimeInterval(entry.id) ?? 0)
        let secs = max(0, Date().timeIntervalSince(date))
        if secs < 60 { return "now" }
        if secs < 3600 { return "\(Int(secs / 60))m" }
        if secs < 86_400 { return "\(Int(secs / 3600))h" }
        if secs < 604_800 { return "\(Int(secs / 86_400))d" }
        if secs < 2_592_000 { return "\(Int(secs / 604_800))w" }
        if secs < 31_536_000 { return "\(Int(secs / 2_592_000))mo" }
        let f = DateFormatter()
        f.locale = Locale.current
        f.dateFormat = "MMM d"
        return f.string(from: date)
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
                // Header: shows whether editing an existing entry or writing new.
                HStack(alignment: .firstTextBaseline) {
                    if let sel = state.selectedJournal {
                        Text(titleOf(sel))
                            .font(DS.cardTitleFont)
                            .foregroundStyle(DS.ink(scheme))
                            .lineLimit(1)
                    } else {
                        Text("New entry")
                            .font(DS.cardTitleFont)
                            .foregroundStyle(DS.ink(scheme))
                    }
                    Spacer()
                    Text(state.selectedJournal == nil ? "draft" : "editing")
                        .font(DS.microFont)
                        .foregroundStyle(DS.muted(scheme))
                        .textCase(.uppercase)
                }
                .padding(.horizontal, 16)

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

                // Recent entries (the sidebar is the primary list; this is a
                // quick inline glance at recent journals).
                ForEach(state.journals.prefix(8), id: \.id) { entry in
                    JournalCard(entry: entry, highlighted: state.selectedJournalKey == entry.key)
                        .padding(.horizontal, 16)
                        .contextMenu {
                            Button {
                                state.selectedJournalKey = entry.key
                            } label: {
                                Label("Open in editor", systemImage: "pencil")
                            }
                            Button {
                                Task { await state.generateDraft(from: entry) }
                            } label: {
                                Label("Draft Post", systemImage: "square.and.pencil")
                            }
                            Button(role: .destructive) {
                                try? state.memory.forget(key: entry.key)
                                if state.selectedJournalKey == entry.key { state.selectedJournalKey = nil }
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
        // Load the selected entry into the editor when the selection changes.
        .onChange(of: state.selectedJournalKey) {
            newEntry = state.selectedJournal?.content ?? ""
        }
        .onAppear {
            // Sync the editor with any pre-existing selection on first show.
            if newEntry.isEmpty { newEntry = state.selectedJournal?.content ?? "" }
        }
    }

    private func titleOf(_ entry: SlowClawMemoryEntry) -> String {
        let first = entry.content.split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init) ?? entry.content
        let t = first.trimmingCharacters(in: .whitespaces)
        return t.isEmpty ? "Untitled" : t
    }

    private func saveEntry() async {
        let text = newEntry.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        // Update the existing entry if one is selected, else create a new one.
        if let key = state.selectedJournalKey {
            try? state.memory.store(key: key, content: text, category: "daily", sessionID: nil)
            await state.refreshJournals()
        } else {
            await state.storeJournal(text: text)
        }
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

    /// The Reads feed catalog. Loaded once from the Zig core (114 sources,
    /// ported 1:1 from src/gateway/feed_web_sources.rs — the same sources the
    /// reference app reads). Falls back to HN if the catalog isn't available.
    /// Read on the main actor only (from loadFeeds, which is @MainActor).
    private var catalog: [SlowClawFeedSource] {
        if let cached = ReadsView.cachedCatalog { return cached }
        if let loaded = slowClawFeedCatalog() {
            ReadsView.cachedCatalog = loaded
            return loaded
        }
        return [SlowClawFeedSource(title: "Hacker News", domain: "news.ycombinator.com",
                                   htmlURL: "https://news.ycombinator.com",
                                   xmlURL: "https://hnrss.org/frontpage")]
    }
    fileprivate static var cachedCatalog: [SlowClawFeedSource]?

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

        // Snapshot topics + catalog on the main actor, then do all the network
        // + FFI work off the main actor. The Zig parse/rank is synchronous and
        // blocking, so running it on background tasks keeps the UI responsive.
        let topics = state.interests.map { SlowClawTopic(label: $0, weight: 1.0) }
        let sources = catalog

        let fetched: ([RankedFeedItem], String?) = await Task.detached(priority: .userInitiated) {
            // Fetch all catalog feeds with bounded concurrency (8 at a time) so
            // we don't open 100+ simultaneous connections. Each feed is fetched,
            // parsed, and ranked independently; results are merged at the end.
            let chunks = stride(from: 0, to: sources.count, by: 8).map {
                Array(sources[$0..<min($0 + 8, sources.count)])
            }
            var allRanked: [RankedFeedItem] = []
            var reachedAny = false

            for batch in chunks {
                let results = await withTaskGroup(of: [RankedFeedItem]?.self, returning: [[RankedFeedItem]].self) { group in
                    for src in batch {
                        group.addTask {
                            guard let url = URL(string: src.xmlURL) else { return nil }
                            let xml: String
                            do {
                                let (data, response) = try await URLSession.shared.data(from: url)
                                guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                                      let s = String(data: data, encoding: .utf8) else { return nil }
                                xml = s
                            } catch { return nil }
                            // Parse + rank via the Zig core (returns nil on error).
                            return slowClawParseAndRankRSS(xml: xml, sourceLabel: src.displayLabel, topics: topics)
                        }
                    }
                    var got: [[RankedFeedItem]] = []
                    for await r in group { if let r { got.append(r) } }
                    return got
                }
                for r in results {
                    if !r.isEmpty { reachedAny = true }
                    allRanked.append(contentsOf: r)
                }
            }

            allRanked.sort { $0.score > $1.score }
            // Cap the displayed list at 60; the reference paginates +12.
            return (Array(allRanked.prefix(60)), reachedAny ? nil : "Couldn't reach any feeds. Pull to retry.")
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
        ScrollView {
            LazyVStack(spacing: 12) {
                // TweetClaw header + status.
                HStack(spacing: 10) {
                    Text("🐾")
                        .font(.system(size: 28))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("TweetClaw")
                            .font(DS.cardTitleFont)
                            .foregroundStyle(DS.ink(scheme))
                        Text("Turns your journals into posts")
                            .font(DS.captionFont)
                            .foregroundStyle(DS.muted(scheme))
                    }
                    Spacer()
                    Button {
                        Task { await state.tweetClawGenerateNext() }
                    } label: {
                        Image(systemName: state.isGeneratingPosts ? "" : "arrow.clockwise")
                            .font(.system(size: 18, weight: .medium))
                            .foregroundStyle(DS.accent(scheme))
                            .frame(width: 36, height: 36)
                            .opacity(state.isGeneratingPosts ? 0 : 1)
                            .overlay {
                                if state.isGeneratingPosts {
                                    ProgressView()
                                }
                            }
                    }
                    .buttonStyle(.plain)
                    .disabled(state.isGeneratingPosts)
                    .accessibilityLabel("Generate a post")
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 8)

                if let status = state.generateStatus {
                    Text(status)
                        .font(DS.captionFont)
                        .foregroundStyle(DS.muted(scheme))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 22)
                }

                if state.drafts.isEmpty {
                    // Empty hero.
                    VStack(spacing: 10) {
                        Image(systemName: "square.and.pencil")
                            .font(.system(size: 36))
                            .foregroundStyle(DS.muted(scheme))
                        Text("Turn journals into posts")
                            .font(DS.cardTitleFont)
                            .foregroundStyle(DS.ink(scheme))
                        Text("Pull down, or tap the arrow above, to let TweetClaw distill a journal entry into a post. Edit, then publish to Nostr.")
                            .font(DS.captionFont)
                            .foregroundStyle(DS.muted(scheme))
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 32)
                    }
                    .padding(.vertical, 40)
                } else {
                    ForEach(state.drafts, id: \.id) { draft in
                        DraftCard(draft: draft, sourceJournalContent: nil)
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 24)
        }
        .background(DS.bg(scheme))
        .refreshable {
            await state.tweetClawGenerateNext()
        }
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
                // TweetClaw byline (🐾 avatar + handle), like the reference.
                HStack(spacing: 8) {
                    Text("🐾")
                        .font(.system(size: 20))
                    VStack(alignment: .leading, spacing: 0) {
                        Text("TweetClaw")
                            .font(DS.captionFont.weight(.semibold))
                            .foregroundStyle(DS.ink(scheme))
                        Text("@tweetclaw")
                            .font(DS.microFont)
                            .foregroundStyle(DS.muted(scheme))
                    }
                    Spacer()
                }

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

/// On-Device AI card. Mirrors the reference app's "On-Device AI" card: lists
/// the Gemma model presets, shows real status from the Zig core, and a Metal
/// (Fast Mode) toggle. The llama.cpp backend is not linked into the build yet,
/// so status reads "not available" — this card is the UI surface that lights
/// up the moment the backend lands.
struct OnDeviceAICard: View {
    let scheme: ColorScheme
    @EnvironmentObject var state: AppState
    @State private var status: LocalLLMStatus = LocalLLMStatus(available: false, reason: nil)
    @AppStorage("slowclaw.localai.metal") private var metalEnabled = true

    var body: some View {
        DS.card(scheme) {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("On-Device AI")
                            .font(DS.cardTitleFont)
                            .foregroundStyle(DS.ink(scheme))
                        Text("Private model on your iPhone. No data leaves your device.")
                            .font(DS.captionFont)
                            .foregroundStyle(DS.muted(scheme))
                    }
                    Spacer()
                    // Availability dot.
                    Circle()
                        .fill(status.available ? DS.accent(scheme) : DS.muted(scheme))
                        .frame(width: 10, height: 10)
                }

                // Status line.
                if !status.available {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 12))
                        Text(status.reason ?? "Not available.")
                            .font(DS.microFont)
                    }
                    .foregroundStyle(DS.muted(scheme))
                } else {
                    Text("Ready")
                        .font(DS.microFont)
                        .foregroundStyle(DS.accent(scheme))
                }

                // Model presets.
                ForEach(LocalModelPreset.presets) { model in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(model.title)
                            .font(DS.bodyFont.weight(.semibold))
                            .foregroundStyle(DS.ink(scheme))
                        Text(model.detail)
                            .font(DS.captionFont)
                            .foregroundStyle(DS.muted(scheme))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(DS.surface2(scheme), in: RoundedRectangle(cornerRadius: DS.rMd, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: DS.rMd, style: .continuous)
                            .stroke(DS.line(scheme), lineWidth: 1)
                    )
                }

                // Metal (Fast Mode) toggle — persists, applied when backend lands.
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Fast Mode")
                            .font(DS.bodyFont.weight(.medium))
                            .foregroundStyle(DS.ink(scheme))
                        Text("Use the Metal GPU")
                            .font(DS.captionFont)
                            .foregroundStyle(DS.muted(scheme))
                    }
                    Spacer()
                    Toggle("", isOn: $metalEnabled)
                        .labelsHidden()
                        .tint(DS.accentColor)
                        .disabled(!status.available)
                }

                Button {
                    refreshStatus()
                } label: {
                    Label("Refresh status", systemImage: "arrow.clockwise")
                        .font(DS.captionFont.weight(.medium))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.bordered)
                .tint(DS.accentColor)
            }
        }
        .onAppear(perform: refreshStatus)
    }

    private func refreshStatus() {
        status = slowClawLocalLLMStatus()
    }
}

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
                // On-Device AI (llama.cpp). Shows honest status from the Zig
                // core: not available until the llama.cpp backend is linked.
                OnDeviceAICard(scheme: scheme)

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

                // TweetClaw prompt (editable; persists to UserDefaults).
                DS.card(scheme) {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(spacing: 8) {
                            Text("🐾")
                                .font(.system(size: 18))
                            Text("TweetClaw")
                                .font(DS.cardTitleFont)
                                .foregroundStyle(DS.ink(scheme))
                        }
                        Text("The system prompt used when turning a journal entry into a post. Pull the Drafts tab to generate.")
                            .font(DS.captionFont)
                            .foregroundStyle(DS.muted(scheme))
                        TextEditor(text: $state.tweetClawPrompt)
                            .font(DS.captionFont)
                            .frame(minHeight: 90)
                            .scrollContentBackground(.hidden)
                            .padding(8)
                            .background(DS.surface2(scheme), in: RoundedRectangle(cornerRadius: DS.rMd, style: .continuous))
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
                        row("Entries", "\(state.journals.count)")
                        Divider().background(DS.line(scheme))
                        row("Drafts", "\(state.drafts.count)")
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

/// Journal entry card. When `highlighted`, renders with an accent ring to show
/// it is the entry currently loaded in the editor.
struct JournalCard: View {
    @Environment(\.colorScheme) var scheme
    let entry: SlowClawMemoryEntry
    var highlighted: Bool = false

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
        .overlay(
            RoundedRectangle(cornerRadius: DS.rXl, style: .continuous)
                .stroke(DS.accent(scheme), lineWidth: highlighted ? 1.5 : 0)
        )
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
