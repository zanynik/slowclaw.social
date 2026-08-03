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
import AVFoundation

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
    @StateObject private var voiceMemoImporter = VoiceMemoImporter()
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
                .environmentObject(voiceMemoImporter)
                .preferredColorScheme(preferredScheme)
                .tint(DS.accentColor)
                // Voice Memos / Files share-sheet entry point: iOS delivers the
                // audio file URL here. enqueue copies it into the Inbox and the
                // serial worker transcribes on-device + auto-stores as a journal.
                .onOpenURL { url in
                    voiceMemoImporter.appState = appState
                    voiceMemoImporter.enqueue(url)
                }
                .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { _ in }
                .onAppear { voiceMemoImporter.appState = appState }
        }
    }
}

// MARK: - App State

@MainActor
final class AppState: ObservableObject {
    let memory: SlowClawSqliteMemory
    var llm: SlowClawLLMProvider?

    // On-device LLM (llama.cpp). `localLLM.loaded` means a GGUF model is in
    // memory and every AI surface (synthesis, interests, drafts, TweetClaw)
    // runs on-device — the local-first path. Download progress is per-preset.
    @Published var localLLM: LocalLLMStatus = LocalLLMStatus(available: false)
    @Published var localModelBusy: Bool = false
    @Published var localModelError: String? = nil
    @Published var localModelProgress: [String: Double] = [:]

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

    // Reads feed cache. Lives on AppState (not ReadsView @State) so switching
    // tabs preserves the list — the view shows cached items instantly and a
    // background refresh merges + re-ranks new content. `readsLoadedOnce`
    // guards the auto-load so we don't refetch on every tab return.
    @Published var readsItems: [RankedFeedItem] = []
    @Published var readsLoading: Bool = false
    @Published var readsError: String? = nil
    @Published var readsRefreshedAt: Date? = nil
    private var readsLoadedOnce: Bool = false
    fileprivate static var cachedCatalog: [SlowClawFeedSource]?
    private static let readsCacheVersion = 1
    private static let readsCacheMaxAge: TimeInterval = 30 * 60
    private static let rssSourceLimit = 24

    private struct ReadsCache: Codable {
        let version: Int
        let refreshedAt: Date
        let items: [RankedFeedItem]
    }

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

        // Hydrate synchronously so relaunches paint the last good Reads list
        // before any network work begins.
        if let cache = Self.loadReadsCache() {
            self.readsItems = cache.items
            self.readsRefreshedAt = cache.refreshedAt
            self.readsLoadedOnce = true
        }

        setupLLM()
        refreshLocalLLMStatus()
        Task { await refreshJournals() }
    }

    // MARK: - On-device LLM management

    func refreshLocalLLMStatus() {
        localLLM = slowClawLocalLLMStatus()
    }

    /// True when any LLM is usable: a configured remote provider OR a loaded
    /// on-device model. Gates every AI-powered surface.
    var anyLLMAvailable: Bool { llm != nil || localLLM.loaded }

    func downloadLocalModel(_ preset: LocalModelPreset) async {
        localModelBusy = true
        localModelError = nil
        defer { localModelBusy = false }
        do {
            _ = try await LocalModelStore.download(preset) { [weak self] p in
                Task { @MainActor in self?.localModelProgress[preset.id] = p }
            }
            localModelProgress[preset.id] = 1
        } catch {
            localModelError = "Download failed: \(error.localizedDescription)"
            localModelProgress[preset.id] = nil
        }
    }

    /// Load a downloaded model into the on-device engine. Runs off-actor:
    /// mmap-ing a multi-GB GGUF takes seconds and must not block the UI.
    func activateLocalModel(_ preset: LocalModelPreset) async {
        guard let url = try? LocalModelStore.fileURL(for: preset) else { return }
        localModelBusy = true
        localModelError = nil
        defer { localModelBusy = false }
        let err = await Task.detached(priority: .userInitiated) {
            slowClawLocalLLMLoad(path: url.path)
        }.value
        if let err { localModelError = err }
        refreshLocalLLMStatus()
    }

    func unloadLocalModel() {
        slowClawLocalLLMUnload()
        refreshLocalLLMStatus()
    }

    func deleteLocalModel(_ preset: LocalModelPreset) {
        // Unload first if any model is active (frees RAM), then remove the file.
        if localLLM.loaded { unloadLocalModel() }
        try? LocalModelStore.delete(preset)
        localModelProgress[preset.id] = nil
        refreshLocalLLMStatus()
    }

    // MARK: - AI routing (local-first)

    /// Every AI call routes through these helpers: on-device when a local
    /// model is loaded (private, offline), else the configured remote
    /// provider. Local inference runs in a detached task so multi-second
    /// generations never block the main actor.
    func aiExtractInterests(from text: String) async throws -> [String] {
        if localLLM.loaded {
            return try await Task.detached(priority: .utility) {
                try slowClawLocalExtractInterests(journalText: text)
            }.value
        }
        guard let llm else { throw SlowClawFeedError.internalError("no LLM configured") }
        return try llm.extractInterests(journalText: text, model: model)
    }

    func aiDraftPost(from text: String, maxChars: Int = 300) async throws -> String {
        if localLLM.loaded {
            return try await Task.detached(priority: .userInitiated) {
                try slowClawLocalDraftPost(journalText: text, maxChars: maxChars)
            }.value
        }
        guard let llm else { throw SlowClawFeedError.internalError("no LLM configured") }
        return try llm.draftPost(journalText: text, model: model, maxChars: maxChars)
    }

    func aiSynthesize(transcript: String) async throws -> String {
        if localLLM.loaded {
            return try await Task.detached(priority: .userInitiated) {
                try slowClawLocalSynthesizeJournal(transcript: transcript)
            }.value
        }
        guard let llm else { throw SlowClawFeedError.internalError("no LLM configured") }
        return try llm.synthesizeJournal(transcript: transcript, model: model)
    }

    func aiChat(system: String, message: String, temperature: Double) async throws -> String {
        if localLLM.loaded {
            return try await Task.detached(priority: .userInitiated) {
                try slowClawLocalLLMChat(systemPrompt: system, message: message, maxTokens: 512, temperature: temperature)
            }.value
        }
        guard let llm else { throw SlowClawFeedError.internalError("no LLM configured") }
        return try llm.chat(systemPrompt: system, message: message, model: model, temperature: temperature)
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
            // Journals: all entries EXCEPT drafts (sessionID="drafts") and
            // soft-deleted keys. Drafts (TweetClaw-generated posts) belong in
            // the Drafts tab only; soft-deleted entries sit in Recently Deleted
            // for 30 days. recall doesn't support an exclude-session filter, so
            // fetch a wider set and drop both client-side. Order newest-first.
            let all = try memory.recall(query: "the a an of to and", limit: 60)
            let deletedKeys = Set(Self.softDeletedKeys().keys)
            journals = all.filter { ($0.sessionID ?? "") != "drafts" && !deletedKeys.contains($0.key) }
            drafts = try memory.recall(query: "draft post", limit: 20, sessionID: "drafts")
        } catch {
            journals = []
            drafts = []
        }
    }

    // MARK: - Recently Deleted (30-day soft-delete safety net)
    //
    // Voice Memos moves a deleted recording to "Recently Deleted" for 30 days.
    // For an audio journal — often the only record of a private thought — a
    // stray delete being gone forever is a trust killer. Soft-delete keeps the
    // SQLite row untouched (no schema change), tracking deleted keys +
    // timestamps in UserDefaults. Entries auto-expire after 30 days; the user
    // can restore or empty the trash from the Profile screen.

    private static let softDeleteKey = "slowclaw.softdeleted"   // [journalKey: epochTimestamp]
    private static let softDeleteTTL: TimeInterval = 30 * 24 * 3600

    /// The soft-delete map, pruned of entries older than the TTL.
    static func softDeletedKeys() -> [String: Double] {
        let now = Date().timeIntervalSince1970
        guard let raw = UserDefaults.standard.dictionary(forKey: softDeleteKey) as? [String: Double] else {
            return [:]
        }
        let live = raw.filter { now - $0.value < softDeleteTTL }
        if live.count != raw.count {
            UserDefaults.standard.set(live, forKey: softDeleteKey)
        }
        return live
    }

    /// Journals that are currently soft-deleted (for the Profile "Recently
    /// Deleted" list). Fetches each by key from the store (they're excluded
    /// from the main journals list) so the UI can show title + timestamp +
    /// a restore button.
    var recentlyDeleted: [SlowClawMemoryEntry] {
        let timestamps = Self.softDeletedKeys()
        var entries: [SlowClawMemoryEntry] = []
        for key in timestamps.keys {
            if let entry = try? memory.get(key: key) {
                entries.append(entry)
            } else {
                // Row already gone (empty-trash ran, or never existed). Track a
                // stub so the entry's deletion timestamp still shows for prune.
                entries.append(SlowClawMemoryEntry(
                    id: key, key: key, content: "(permanently deleted)",
                    category: "deleted", timestamp: "", sessionID: nil, score: nil))
            }
        }
        // Newest-deleted first.
        return entries.sorted { (timestamps[$0.key] ?? 0) > (timestamps[$1.key] ?? 0) }
    }

    /// Soft-delete a journal entry (moves it to Recently Deleted; the row stays
    /// in the store). Idempotent.
    func softDelete(key: String) {
        var live = Self.softDeletedKeys()
        live[key] = Date().timeIntervalSince1970
        UserDefaults.standard.set(live, forKey: Self.softDeleteKey)
        if selectedJournalKey == key { selectedJournalKey = nil }
        Task { await refreshJournals() }
    }

    /// Restore a soft-deleted entry (removes it from Recently Deleted).
    func restore(key: String) {
        var live = Self.softDeletedKeys()
        live.removeValue(forKey: key)
        UserDefaults.standard.set(live, forKey: Self.softDeleteKey)
        Task { await refreshJournals() }
    }

    /// Permanently delete all soft-deleted entries (empty the trash). Also
    /// removes the underlying rows.
    func emptyTrash() {
        let keys = Array(Self.softDeletedKeys().keys)
        for key in keys { try? memory.forget(key: key) }
        UserDefaults.standard.removeObject(forKey: Self.softDeleteKey)
        Task { await refreshJournals() }
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

    // MARK: - Reads feed (cached + background refresh)

    /// On-disk cache of the last ranked Reads feed, so the list survives app
    /// restarts and shows instantly instead of re-fetching 100+ feeds every
    /// launch. Lives in Caches/reads-feed-v1.json (see readsCacheURL above).

    /// The Reads feed catalog (114 sources), cached on first access.
    fileprivate var catalog: [SlowClawFeedSource] {
        if let cached = AppState.cachedCatalog { return cached }
        if let loaded = slowClawFeedCatalog() {
            AppState.cachedCatalog = loaded
            return loaded
        }
        return [SlowClawFeedSource(title: "Hacker News", domain: "news.ycombinator.com",
                                   htmlURL: "https://news.ycombinator.com",
                                   xmlURL: "https://hnrss.org/frontpage")]
    }

    /// Load the Reads feed. On the first call (or when forced) this replaces the
    /// list; on subsequent calls it background-refreshes and merges new items in
    /// so switching tabs never wipes what's already shown. Pull-to-refresh forces
    /// a foreground refresh (spinner visible).
    func loadReads(force: Bool = false) async {
        // A just-refreshed disk cache is the normal relaunch path. It was
        // hydrated in init, so do not fetch the world again until it is stale;
        // pull-to-refresh is always an explicit bypass.
        if !force,
           !readsItems.isEmpty,
           let refreshedAt = readsRefreshedAt,
           Date().timeIntervalSince(refreshedAt) < Self.readsCacheMaxAge {
            return
        }

        let isFirst = !readsLoadedOnce || readsItems.isEmpty
        if force || isFirst {
            readsLoading = true
            if !force { readsError = nil }
        }
        readsLoadedOnce = true

        let topics = interests.map { SlowClawTopic(label: $0, weight: 1.0) }
        let sources = catalog

        // Snapshot fetch happens off the main actor.
        let fetched = await Task.detached(priority: .userInitiated) {
            async let rssResult = Self.fetchAllRSS(sources: sources, topics: topics)
            async let nostrResult = NostrFetcher.fetchArticles(topics: topics.map(\.label))
            // rssResult is ([RankedFeedItem], Bool); nostrResult is [RankedFeedItem].
            return await (rssResult, nostrResult)
        }.value
        let rss = fetched.0.0
        let reachedAny = fetched.0.1
        let nostr = fetched.1

        var combined = rss + nostr
        combined.sort { $0.score > $1.score }
        // Apply the post-merge production filter the iOS app was missing:
        // quality gate (drop spam/empty), URL dedup (collapse cross-feed
        // reposts), and a per-source cap + round-robin so one feed can't
        // dominate. This is the curation the reference does in the Rust
        // gateway ranker.rs; we do it client-side on the merged batch.
        let capped = slowClawFilterAndDiversify(combined, maxPerSource: 5, limit: 80)

        // Never replace a usable snapshot with an empty failed refresh. A stale
        // local feed is more useful than a blank loading/error state.
        if capped.isEmpty {
            readsError = reachedAny ? nil : "Couldn't reach any feeds. Pull to retry."
            readsLoading = false
            return
        }

        // Merge: keep the existing list visible; replace on force/first load.
        if force || readsItems.isEmpty {
            readsItems = capped
        } else {
            // Background refresh: prepend new items not already present.
            let existing = Set(readsItems.map { $0.id })
            let fresh = capped.filter { !existing.contains($0.id) }
            if !fresh.isEmpty {
                readsItems = (fresh + readsItems).prefix(80).map { $0 }
            }
        }
        readsRefreshedAt = Date()
        Self.saveReadsCache(items: readsItems, refreshedAt: readsRefreshedAt!)
        readsError = nil
        readsLoading = false
    }

    /// Fetch a bounded catalog slice with a per-source timeout, then parse +
    /// rank through Zig. The previous implementation walked all 114 sources in
    /// sequential batches, making a cold launch wait for slow or dead feeds.
    private static func fetchAllRSS(sources: [SlowClawFeedSource], topics: [SlowClawTopic]) async -> ([RankedFeedItem], Bool) {
        let selected = selectRSSSources(sources, topics: topics)
        let results = await withTaskGroup(of: [RankedFeedItem]?.self, returning: [[RankedFeedItem]].self) { group in
            for src in selected {
                group.addTask {
                    guard let url = URL(string: src.xmlURL) else { return nil }
                    var request = URLRequest(url: url)
                    request.timeoutInterval = 6
                    do {
                        let (data, response) = try await URLSession.shared.data(for: request)
                        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                              let xml = String(data: data, encoding: .utf8) else { return nil }
                        return slowClawParseAndRankRSS(xml: xml, sourceLabel: src.displayLabel, topics: topics)
                    } catch {
                        return nil
                    }
                }
            }
            var got: [[RankedFeedItem]] = []
            for await result in group {
                if let result { got.append(result) }
            }
            return got
        }
        let allRanked = results.flatMap { $0 }
        return (allRanked, !allRanked.isEmpty)
    }

    /// The full catalog is intentionally broad, but a refresh should start
    /// with sources whose public title/domain agrees with the journal lens.
    /// The catalog does not yet carry Rust's richer source-topic metadata, so
    /// this is a conservative first-pass and fills any remaining slots in the
    /// stable catalog order for cold starts.
    private static func selectRSSSources(
        _ sources: [SlowClawFeedSource],
        topics: [SlowClawTopic]
    ) -> [SlowClawFeedSource] {
        let labels = topics.map { $0.label.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.count >= 3 }
        guard !labels.isEmpty else { return Array(sources.prefix(rssSourceLimit)) }

        let matching = sources.filter { source in
            let metadata = "\(source.title) \(source.domain)".lowercased()
            return labels.contains { metadata.contains($0) }
        }
        guard matching.count < rssSourceLimit else {
            return Array(matching.prefix(rssSourceLimit))
        }
        let selectedDomains = Set(matching.map(\.domain))
        let fallback = sources.filter { !selectedDomains.contains($0.domain) }
        return Array((matching + fallback).prefix(rssSourceLimit))
    }

    private static var readsCacheURL: URL? {
        guard let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            return nil
        }
        return directory.appendingPathComponent("reads-feed-v1.json")
    }

    private static func loadReadsCache() -> ReadsCache? {
        guard let url = readsCacheURL,
              let data = try? Data(contentsOf: url),
              let cache = try? JSONDecoder().decode(ReadsCache.self, from: data),
              cache.version == readsCacheVersion,
              !cache.items.isEmpty else { return nil }
        return ReadsCache(
            version: cache.version,
            refreshedAt: cache.refreshedAt,
            items: Array(cache.items.prefix(80))
        )
    }

    private static func saveReadsCache(items: [RankedFeedItem], refreshedAt: Date) {
        guard let url = readsCacheURL, !items.isEmpty else { return }
        let cache = ReadsCache(
            version: readsCacheVersion,
            refreshedAt: refreshedAt,
            items: Array(items.prefix(80))
        )
        guard let data = try? JSONEncoder().encode(cache) else { return }
        try? data.write(to: url, options: .atomic)
    }

    func storeJournal(text: String) async {
        await storeJournal(text: text, source: nil, mediaURL: nil)
    }

    /// Store a journal entry with optional provenance (source + media_url).
    /// The audio recorder passes source="audio_recorded" + the m4a path so the
    /// entry links back to its durable audio file for replay.
    func storeJournal(text: String, source: String?, mediaURL: String?) async {
        try? memory.store(key: "journal_\(Date().timeIntervalSince1970)", content: text,
                          category: "daily", sessionID: nil, source: source, mediaURL: mediaURL)
        await refreshJournals()
        guard anyLLMAvailable else { return }
        Task.detached(priority: .utility) {
            if let keywords = try? await self.aiExtractInterests(from: text) {
                await MainActor.run {
                    self.interests.append(contentsOf: keywords.filter { !self.interests.contains($0) })
                }
            }
        }
    }

    func generateDraft(from journal: SlowClawMemoryEntry) async {
        guard anyLLMAvailable else { return }
        Task.detached(priority: .userInitiated) {
            if let draft = try? await self.aiDraftPost(from: journal.content) {
                let key = "draft_\(Date().timeIntervalSince1970)"
                try? self.memory.store(key: key, content: draft, category: "core", sessionID: "drafts")
                await self.refreshJournals()
            }
        }
    }

    // MARK: - TweetClaw (pull-to-generate)

    /// Pull-to-generate: pick the most-recently-modified unprocessed text journal
    /// (or a random one if all are processed) and turn it into one or more posts.
    /// Long entries are chunked at ~3200 chars; each chunk produces its own post.
    /// Mirrors the reference app's handleFeedPullRefresh / generatePostFromJournal.
    func tweetClawGenerateNext() async {
        guard anyLLMAvailable else {
            generateStatus = "Add an LLM API key in Profile, or activate an on-device model, to generate posts."
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
                    if let post = try? await self.aiChat(system: prompt, message: message, temperature: 0.8) {
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
        // The Journal tab is now a Voice Memos-style list with the record +
        // pen buttons at its base; the sidebar drawer is removed.
        .background(DS.bg(scheme).ignoresSafeArea())
        // Voice-memo imports auto-store (transcribe on-device → journal entry),
        // matching the reference app — no review gate. The sidebar shows
        // progress via voiceMemoImporter.status while the serial worker runs.
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
            // Journal tab is now a Voice Memos-style list with its own base
            // record/pen bar; the hamburger drawer and "+" new-entry button are
            // removed. Other tabs keep their wordmark + theme toggle.
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

// MARK: - Journal helpers (shared by the list, detail, and sidebar)

/// First non-empty line of the entry = its display title.
func journalTitleOf(_ entry: SlowClawMemoryEntry) -> String {
    let first = entry.content.split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init) ?? entry.content
    return first.trimmingCharacters(in: .whitespaces).isEmpty ? "Untitled" : first.trimmingCharacters(in: .whitespaces)
}

/// A short single-line preview after the title.
func journalPreviewOf(_ entry: SlowClawMemoryEntry) -> String {
    let lines = entry.content.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    let body = lines.dropFirst().joined(separator: " ")
    let trimmed = body.trimmingCharacters(in: .whitespaces)
    return String(trimmed.prefix(60))
}

/// Coarse relative-time string (now / Nm / Nh / Nd / Nw / Nmo, else MMM d).
func journalRelativeTime(_ entry: SlowClawMemoryEntry) -> String {
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

/// mm:ss for an audio player position/duration.
func audioClock(_ seconds: TimeInterval) -> String {
    guard seconds.isFinite, seconds >= 0 else { return "0:00" }
    let s = Int(seconds)
    return String(format: "%d:%02d", s / 60, s % 60)
}

// MARK: - Journal detail (fullscreen player + transcript)

/// Fullscreen detail for a journal entry. For audio recordings: a player with
/// play / -15 / +15 / scrub / speed, a static waveform, and the transcript
/// below. For text entries: just the title + body. Title is editable (rename)
/// via the existing memory.store upsert. Audio is shared via a system share
/// link.
struct JournalDetailView: View {
    let entry: SlowClawMemoryEntry
    @Environment(\.dismiss) var dismiss
    @Environment(\.colorScheme) var scheme
    @EnvironmentObject var state: AppState

    @State private var player: AVAudioPlayer?
    @State private var isPlaying = false
    @State private var progress: Double = 0
    @State private var speed: Float = 1.0
    @State private var pollTimer: Timer?
    @State private var waveformLevels: [Float] = []
    @State private var editedBody: String
    @State private var isEditingTitle = false
    @State private var titleDraft: String
    @State private var isPolishing = false
    @State private var showShareSheet = false

    /// Absolute URL of the recording, if this is an audio entry with a file.
    private var audioURL: URL? {
        guard entry.source == "audio_recorded" || entry.source == "audio_imported" else { return nil }
        return AudioRecorder.absoluteURL(forMediaRelativePath: entry.mediaURL)
    }

    init(entry: SlowClawMemoryEntry) {
        self.entry = entry
        _editedBody = State(initialValue: entry.content)
        _titleDraft = State(initialValue: journalTitleOf(entry))
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 18) {
                    // ── Title (editable on tap) ──
                    if isEditingTitle {
                        TextField("Title", text: $titleDraft)
                            .font(DS.titleFont)
                            .textFieldStyle(.plain)
                            .foregroundStyle(DS.ink(scheme))
                            .padding(.horizontal, 16)
                            .onSubmit { commitTitle() }
                    } else {
                        Button {
                            isEditingTitle = true
                            titleDraft = journalTitleOf(entry)
                        } label: {
                            HStack {
                                Text(journalTitleOf(entry))
                                    .font(DS.titleFont)
                                    .foregroundStyle(DS.ink(scheme))
                                    .multilineTextAlignment(.leading)
                                Spacer()
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .padding(.horizontal, 16)
                    }

                    // ── Audio player (only for audio entries with a file) ──
                    if let url = audioURL, FileManager.default.fileExists(atPath: url.path) {
                        playerSection(url: url)
                    }

                    // ── Body / transcript ──
                    DS.card(scheme) {
                        VStack(alignment: .leading, spacing: 10) {
                            HStack {
                                Text(entry.source?.hasPrefix("audio") == true ? "Transcript" : "Body")
                                    .font(DS.eyebrowFont)
                                    .foregroundStyle(DS.muted(scheme))
                                    .textCase(.uppercase)
                                Spacer()
                                if state.llm != nil {
                                    Button {
                                        Task { await polish() }
                                    } label: {
                                        Label("Polish", systemImage: "sparkles")
                                            .font(DS.captionFont.weight(.semibold))
                                    }
                                    .buttonStyle(.plain)
                                    .tint(DS.accentColor)
                                    .disabled(isPolishing)
                                }
                            }
                            TextEditor(text: $editedBody)
                                .frame(minHeight: 180)
                                .scrollContentBackground(.hidden)
                                .font(DS.bodyFont)
                                .foregroundStyle(DS.ink(scheme))
                                .onChange(of: editedBody) { scheduleBodyAutosave() }
                        }
                    }
                    .padding(.horizontal, 16)
                }
                .padding(.top, 8)
                .padding(.bottom, 32)
            }
            .background(DS.bg(scheme))
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        player?.stop()
                        pollTimer?.invalidate()
                        commitTitle()
                        commitBody()
                        dismiss()
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 16, weight: .semibold))
                    }
                }
                if audioURL != nil {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            showShareSheet = true
                        } label: {
                            Image(systemName: "square.and.arrow.up")
                        }
                    }
                }
            }
        }
        .onAppear {
            preparePlayerIfNeeded()
            extractWaveformIfNeeded()
        }
        .onDisappear {
            pollTimer?.invalidate()
            player?.stop()
        }
        .sheet(isPresented: $showShareSheet) {
            if let url = audioURL {
                ShareLink(item: url)
            }
        }
    }

    // MARK: - Player section

    @ViewBuilder
    private func playerSection(url: URL) -> some View {
        VStack(spacing: 14) {
            // Static waveform from the decoded file.
            WaveformView(samples: waveformLevels, color: DS.accent2Color)
                .frame(height: 56)
                .padding(.horizontal, 16)

            // Scrubber.
            Slider(value: Binding(
                get: { progress },
                set: { newValue in
                    progress = newValue
                    if let p = player, p.duration > 0 {
                        p.currentTime = newValue * p.duration
                    }
                }
            ), in: 0...1)
            .tint(DS.accent2Color)
            .padding(.horizontal, 20)

            // Time labels.
            HStack {
                Text(audioClock(player?.currentTime ?? 0))
                Spacer()
                Text(audioClock(player?.duration ?? 0))
            }
            .font(DS.microFont.monospacedDigit())
            .foregroundStyle(DS.muted(scheme))
            .padding(.horizontal, 20)

            // Transport: -15 / play-pause / +15.
            HStack(spacing: 40) {
                Button { skip(by: -15) } label: {
                    Image(systemName: "gobackward.15")
                        .font(.system(size: 26))
                        .foregroundStyle(DS.ink(scheme))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Back 15 seconds")

                Button { togglePlayback() } label: {
                    ZStack {
                        Circle()
                            .fill(DS.accent2Color)
                            .frame(width: 64, height: 64)
                        Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 24))
                            .foregroundStyle(.white)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isPlaying ? "Pause" : "Play")

                Button { skip(by: 15) } label: {
                    Image(systemName: "goforward.15")
                        .font(.system(size: 26))
                        .foregroundStyle(DS.ink(scheme))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Forward 15 seconds")
            }
            .padding(.top, 2)

            // Speed toggle.
            Button {
                cycleSpeed()
            } label: {
                Text(String(format: "%g×", speed))
                    .font(DS.captionFont.weight(.semibold))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .background(DS.surface3(scheme), in: Capsule())
            }
            .buttonStyle(.plain)
            .tint(DS.ink(scheme))
        }
        .padding(.vertical, 16)
        .background(DS.surface(scheme), in: RoundedRectangle(cornerRadius: DS.rLg, style: .continuous))
        .padding(.horizontal, 16)
    }

    // MARK: - Player logic

    private func preparePlayerIfNeeded() {
        guard let url = audioURL, FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
            try AVAudioSession.sharedInstance().setActive(true)
            let p = try AVAudioPlayer(contentsOf: url)
            p.enableRate = true
            p.rate = speed
            p.prepareToPlay()
            player = p
        } catch {
            player = nil
        }
    }

    private func extractWaveformIfNeeded() {
        guard let url = audioURL, FileManager.default.fileExists(atPath: url.path) else { return }
        // Decode off the main thread; one-shot on appear.
        Task.detached(priority: .utility) {
            let levels = AudioRecorder.extractLevels(from: url)
            await MainActor.run { waveformLevels = levels }
        }
    }

    private func togglePlayback() {
        guard let p = player else { return }
        if p.isPlaying {
            p.pause()
            isPlaying = false
            pollTimer?.invalidate()
        } else {
            p.rate = speed
            p.play()
            isPlaying = true
            pollTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { _ in
                guard let p = player else { return }
                if p.duration > 0 { progress = p.currentTime / p.duration }
                if !p.isPlaying {
                    isPlaying = false
                    progress = 0
                    pollTimer?.invalidate()
                }
            }
        }
    }

    private func skip(by seconds: TimeInterval) {
        guard let p = player else { return }
        p.currentTime = max(0, min(p.duration, p.currentTime + seconds))
        if p.duration > 0 { progress = p.currentTime / p.duration }
    }

    private func cycleSpeed() {
        // 1.0 → 1.5 → 2.0 → 0.5 → 1.0
        switch speed {
        case 1.0: speed = 1.5
        case 1.5: speed = 2.0
        case 2.0: speed = 0.5
        case 0.5: speed = 1.0
        default: speed = 1.0
        }
        player?.rate = isPlaying ? speed : speed
    }

    // MARK: - Edit persistence

    @State private var bodyAutosaveTask: Task<Void, Never>?

    private func scheduleBodyAutosave() {
        bodyAutosaveTask?.cancel()
        bodyAutosaveTask = Task {
            try? await Task.sleep(nanoseconds: 700_000_000)
            if Task.isCancelled { return }
            await MainActor.run { commitBody() }
        }
    }

    private func commitBody() {
        let trimmed = editedBody.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // Preserve source/mediaURL on edit (upsert by key).
        try? state.memory.store(key: entry.key, content: editedBody, category: entry.category,
                                sessionID: entry.sessionID, source: entry.source, mediaURL: entry.mediaURL)
        Task { await state.refreshJournals() }
    }

    private func commitTitle() {
        guard isEditingTitle else { return }
        isEditingTitle = false
        let newTitle = titleDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !newTitle.isEmpty, newTitle != journalTitleOf(entry) else { return }
        // Rewrite: title becomes the first line, body preserved.
        let lines = entry.content.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        let body = lines.dropFirst().joined(separator: "\n")
        let newContent = body.isEmpty ? newTitle : "\(newTitle)\n\(body)"
        try? state.memory.store(key: entry.key, content: newContent, category: entry.category,
                                sessionID: entry.sessionID, source: entry.source, mediaURL: entry.mediaURL)
        Task { await state.refreshJournals() }
    }

    private func polish() async {
        guard let llm = state.llm else { return }
        isPolishing = true
        defer { isPolishing = false }
        let raw = editedBody
        let model = state.model
        DispatchQueue.global(qos: .userInitiated).async {
            if let polished = try? llm.synthesizeJournal(transcript: raw, model: model) {
                DispatchQueue.main.async { editedBody = polished }
            }
        }
    }
}

// MARK: - Text compose sheet (pen button)

/// Clean fullscreen compose surface for a text journal. Title + large editor +
/// Save. No autosave complexity — the user is writing fresh.
struct TextComposeSheet: View {
    @Environment(\.dismiss) var dismiss
    @Environment(\.colorScheme) var scheme
    @EnvironmentObject var state: AppState

    @State private var title = ""
    @State private var bodyText = ""

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                TextField("Title (optional)", text: $title)
                    .font(DS.cardTitleFont)
                    .textFieldStyle(.plain)
                    .foregroundStyle(DS.ink(scheme))
                    .padding(.horizontal, 4)

                DS.card(scheme) {
                    TextEditor(text: $bodyText)
                        .frame(minHeight: 240)
                        .scrollContentBackground(.hidden)
                        .font(DS.bodyFont)
                        .foregroundStyle(DS.ink(scheme))
                        .overlay(alignment: .topLeading) {
                            if bodyText.isEmpty {
                                Text("What's on your mind today?")
                                    .font(DS.bodyFont)
                                    .foregroundStyle(DS.muted(scheme))
                                    .padding(.top, 6)
                                    .allowsHitTesting(false)
                            }
                        }
                }
                Spacer()
            }
            .padding(16)
            .background(DS.bg(scheme))
            .navigationTitle("New Entry")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Task { await save() }
                    }
                    .disabled(bodyText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    private func save() async {
        let t = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let b = bodyText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !b.isEmpty else { return }
        let content = t.isEmpty ? b : "\(t)\n\n\(b)"
        await state.storeJournal(text: content, source: "text", mediaURL: nil)
        dismiss()
    }
}

// MARK: - Journal View (Voice Memos-style list)

struct JournalView: View {
    @Environment(\.colorScheme) var scheme
    @EnvironmentObject var state: AppState
    @EnvironmentObject var voiceMemoImporter: VoiceMemoImporter

    // The recorder is owned here so the base record button + the recording
    // controls + the post-finish TranscriptSheet all share one state machine.
    @StateObject private var recorder = AudioRecorder()

    @State private var search = ""
    @State private var selectedDetail: SlowClawMemoryEntry?
    @State private var showCompose = false
    @State private var showTranscript = false

    /// First-entry rotating prompts (one per day-of-month). Shown in the empty
    /// state hero.
    private let firstEntryPrompts = [
        "What made today different?",
        "Something you're figuring out right now…",
        "A moment worth keeping.",
        "What's been on your mind lately?",
        "One small thing that went well.",
    ]
    private var firstEntryPrompt: String {
        let day = Calendar.current.component(.day, from: Date())
        return firstEntryPrompts[day % firstEntryPrompts.count]
    }

    private var filtered: [SlowClawMemoryEntry] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return state.journals }
        return state.journals.filter { $0.content.lowercased().contains(q) }
    }

    var body: some View {
        Group {
            if recorder.isRecording || recorder.isPaused {
                // ── Recording zen screen (replaces the list while recording) ──
                recordingScreen
            } else if recorder.isTranscribing {
                transcribingState
            } else {
                journalList
            }
        }
        .background(DS.bg(scheme))
        .task { await state.refreshJournals() }
        // Present the recording transcript review when transcription finishes.
        .onChange(of: recorder.isTranscribing) { _, now in
            if !now && recorder.recordedFileURL != nil { showTranscript = true }
        }
        .sheet(isPresented: $showCompose) {
            TextComposeSheet()
                .environmentObject(state)
        }
        .sheet(isPresented: $showTranscript) {
            TranscriptSheet(
                transcript: recorder.transcript.isEmpty
                    ? "🎙 Audio journal (no transcript)"
                    : recorder.transcript,
                audioURL: recorder.recordedFileURL
            ) { polished in
                let mediaURL = recorder.recordedFileURL.flatMap(AudioRecorder.documentsRelativePath(for:))
                let title = recorder.title.trimmingCharacters(in: .whitespacesAndNewlines)
                let body = title.isEmpty ? polished : "\(title)\n\n\(polished)"
                Task {
                    await state.storeJournal(text: body, source: "audio_recorded", mediaURL: mediaURL)
                }
                recorder.title = ""
                recorder.transcript = ""
                recorder.recordedFileURL = nil
                showTranscript = false
            }
            .environmentObject(state)
        }
    }

    // MARK: - List

    private var journalList: some View {
        VStack(spacing: 0) {
            // Search + import status (migrated from the sidebar).
            VStack(spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 13))
                        .foregroundStyle(DS.muted(scheme))
                    TextField("", text: $search, prompt: Text("Search journals").foregroundColor(DS.muted(scheme)))
                        .font(DS.bodyFont)
                        .textFieldStyle(.plain)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(DS.surface2(scheme), in: RoundedRectangle(cornerRadius: DS.rMd, style: .continuous))
                .padding(.horizontal, 16)

                if let status = voiceMemoImporter.status {
                    HStack(spacing: 6) {
                        if voiceMemoImporter.isImporting {
                            ProgressView().scaleEffect(0.6).frame(width: 12, height: 12)
                        }
                        Text(status)
                            .font(DS.microFont)
                            .foregroundStyle(DS.muted(scheme))
                        Spacer()
                    }
                    .padding(.horizontal, 22)
                }

                HStack(spacing: 6) {
                    Image(systemName: "waveform").font(.system(size: 11))
                    Text("Import voice memos via the share sheet → SlowClaw.")
                        .font(DS.microFont)
                    Spacer()
                }
                .foregroundStyle(DS.muted(scheme))
                .padding(.horizontal, 22)
            }
            .padding(.top, 10)

            // The list.
            if filtered.isEmpty && search.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        if filtered.isEmpty {
                            Text("No journals match your search.")
                                .font(DS.captionFont)
                                .foregroundStyle(DS.muted(scheme))
                                .padding(.top, 40)
                        } else {
                            ForEach(filtered, id: \.key) { entry in
                                journalRow(entry)
                                    .contentShape(Rectangle())
                                    .onTapGesture { selectedDetail = entry }
                                    .contextMenu {
                                        Button(role: .destructive) {
                                            state.softDelete(key: entry.key)
                                        } label: { Label("Delete", systemImage: "trash") }
                                    }
                            }
                        }
                    }
                    .padding(.bottom, 120) // clearance for the base bar.
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) { baseBar }
        // Fullscreen detail.
        .fullScreenCover(item: $selectedDetail) { entry in
            JournalDetailView(entry: entry)
                .environmentObject(state)
        }
    }

    /// One list row: waveform glyph (audio) + title + time + preview.
    private func journalRow(_ entry: SlowClawMemoryEntry) -> some View {
        let isAudio = entry.source?.hasPrefix("audio") == true
        return HStack(alignment: .top, spacing: 12) {
            // Audio glyph / waveform mini.
            Image(systemName: isAudio ? "waveform" : "text.alignleft")
                .font(.system(size: 16))
                .foregroundStyle(isAudio ? DS.accent2Color : DS.muted(scheme))
                .frame(width: 24, height: 24)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline) {
                    Text(journalTitleOf(entry))
                        .font(DS.bodyFont.weight(.semibold))
                        .foregroundStyle(DS.ink(scheme))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text(journalRelativeTime(entry))
                        .font(DS.microFont)
                        .foregroundStyle(DS.muted(scheme))
                }
                let preview = journalPreviewOf(entry)
                if !preview.isEmpty {
                    Text(preview)
                        .font(DS.captionFont)
                        .foregroundStyle(DS.muted(scheme))
                        .lineLimit(1)
                }
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()
            Image(systemName: "waveform")
                .font(.system(size: 36))
                .foregroundStyle(DS.muted(scheme))
            Text(firstEntryPrompt)
                .font(DS.captionFont.italic())
                .foregroundStyle(DS.muted(scheme))
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Text("Tap the red button to record, or the pen to write.")
                .font(DS.microFont)
                .foregroundStyle(DS.muted(scheme))
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Base bar (record + pen, or recording controls)

    private var baseBar: some View {
        VStack(spacing: 0) {
            Divider().opacity(0.4)
            HStack(spacing: 28) {
                // Pen → text compose.
                Button {
                    showCompose = true
                } label: {
                    Image(systemName: "square.and.pencil")
                        .font(.system(size: 24, weight: .medium))
                        .foregroundStyle(DS.ink(scheme))
                        .frame(width: 56, height: 56)
                        .background(DS.surface3(scheme), in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Write a text journal")

                Spacer()

                // Big red record button.
                Button {
                    Task {
                        recorder.title = ""
                        recorder.transcript = ""
                        await recorder.startRecording()
                    }
                } label: {
                    ZStack {
                        Circle()
                            .fill(DS.accent2Color)
                            .frame(width: 70, height: 70)
                            .shadow(color: DS.accent2Color.opacity(0.35), radius: 8, y: 3)
                        Image(systemName: "mic.fill")
                            .font(.system(size: 26))
                            .foregroundStyle(.white)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Record an audio journal")
            }
            .padding(.horizontal, 36)
            .padding(.top, 12)
            .padding(.bottom, 12)
            .background(.ultraThinMaterial)
        }
    }

    // MARK: - Recording zen screen

    private var recordingScreen: some View {
        VStack {
            Spacer()
            VStack(spacing: 18) {
                // Title field.
                HStack {
                    TextField("Recording title (optional)", text: $recorder.title)
                        .font(DS.bodyFont)
                        .textFieldStyle(.plain)
                        .foregroundStyle(DS.ink(scheme))
                    Spacer()
                    Text(recorder.elapsedLabel)
                        .font(.system(size: 15, weight: .semibold, design: .monospaced))
                        .foregroundStyle(DS.muted(scheme))
                }
                .padding(.horizontal, 24)

                WaveformView(samples: recorder.samples, color: DS.accent2Color)
                    .frame(height: 72)
                    .padding(.horizontal, 16)

                Text(recorder.isPaused ? "Paused" : "Recording…")
                    .font(DS.bodyFont)
                    .foregroundStyle(DS.ink(scheme))

                HStack(spacing: 28) {
                    Button {
                        if recorder.isPaused {
                            Task { await recorder.resumeRecording() }
                        } else {
                            recorder.pauseRecording()
                        }
                    } label: {
                        ZStack {
                            Circle()
                                .fill(DS.surface3(scheme))
                                .frame(width: 58, height: 58)
                            Image(systemName: recorder.isPaused ? "play.fill" : "pause.fill")
                                .font(.system(size: 22))
                                .foregroundStyle(DS.ink(scheme))
                        }
                    }
                    .buttonStyle(.plain)

                    Button {
                        recorder.finishRecording()
                    } label: {
                        ZStack {
                            Circle()
                                .fill(DS.accent2Color)
                                .frame(width: 70, height: 70)
                                .shadow(color: DS.accent2Color.opacity(0.35), radius: 8, y: 3)
                            Image(systemName: "stop.fill")
                                .font(.system(size: 26))
                                .foregroundStyle(.white)
                        }
                    }
                    .buttonStyle(.plain)
                }

                if let err = recorder.errorMessage {
                    Text(err)
                        .font(DS.captionFont)
                        .foregroundStyle(DS.accent2Color)
                        .padding(.horizontal, 24)
                }
            }
            Spacer()
        }
    }

    private var transcribingState: some View {
        VStack(spacing: 10) {
            Spacer()
            ProgressView().scaleEffect(0.9)
            Text("Transcribing…")
                .font(DS.captionFont)
                .foregroundStyle(DS.muted(scheme))
            Spacer()
        }
    }
}

// MARK: - Reads View (Feed loop) — crash-safe

struct ReadsView: View {
    @Environment(\.colorScheme) var scheme
    @EnvironmentObject var state: AppState


    var body: some View {
        Group {
            if state.readsLoading && state.readsItems.isEmpty {
                VStack(spacing: 10) {
                    ProgressView()
                    Text("Loading…")
                        .font(DS.captionFont)
                        .foregroundStyle(DS.muted(scheme))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if state.readsItems.isEmpty {
                if let err = state.readsError {
                    // Surface the failure instead of silently looking empty.
                    VStack(spacing: 12) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 36))
                            .foregroundStyle(DS.muted(scheme))
                        Text("Couldn't load reads")
                            .font(DS.cardTitleFont)
                            .foregroundStyle(DS.ink(scheme))
                        Text(err)
                            .font(DS.captionFont)
                            .foregroundStyle(DS.muted(scheme))
                            .multilineTextAlignment(.center)
                            .padding(.horizontal)
                        Button("Retry") { Task { await state.loadReads(force: true) } }
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
                            Text("\(state.readsItems.count) stories")
                                .font(DS.captionFont)
                                .foregroundStyle(DS.muted(scheme))
                            Text("·")
                                .font(DS.captionFont)
                                .foregroundStyle(DS.muted(scheme))
                            Text("ranked by your lens")
                                .font(DS.captionFont)
                                .foregroundStyle(DS.muted(scheme))
                            Spacer()
                            if state.readsLoading {
                                // Background refresh in progress — keep the
                                // cached list visible (no spinner swap).
                                ProgressView().scaleEffect(0.7).frame(width: 14, height: 14)
                            }
                        }
                        .padding(.horizontal, 4)

                        ForEach(state.readsItems) { item in
                            FeedCard(item: item, interests: state.interests)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 16)
                    .padding(.bottom, 24)
                }
                .refreshable { await state.loadReads(force: true) }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(DS.bg(scheme))
        .task {
            // Cached list is shown instantly if present; otherwise load. A
            // background refresh (merge, no wipe) runs when returning to the tab.
            await state.loadReads(force: false)
        }
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
                    if sourceJournalContent != nil && state.anyLLMAvailable {
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
        guard state.anyLLMAvailable, let source = sourceJournalContent else { return }
        isRegenerating = true
        defer { isRegenerating = false }
        if let newDraft = try? await state.aiDraftPost(from: source) {
            editedText = newDraft
        }
    }
}

// MARK: - Profile View

/// On-Device AI card. Lists the Gemma model presets with download → activate
/// → ready lifecycle, driven by real status from the Zig core (llama.cpp CPU
/// backend). When a model is loaded, every AI surface (Polish, interests,
/// drafts, TweetClaw) runs on-device — nothing leaves the iPhone.
struct OnDeviceAICard: View {
    let scheme: ColorScheme
    @EnvironmentObject var state: AppState

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
                    // Availability dot: accent when a model is loaded.
                    Circle()
                        .fill(state.localLLM.loaded ? DS.accent(scheme) : DS.muted(scheme))
                        .frame(width: 10, height: 10)
                }

                // Status line.
                if state.localLLM.loaded {
                    Text("Ready — \(state.localLLM.modelId ?? "model") is running on-device")
                        .font(DS.microFont)
                        .foregroundStyle(DS.accent(scheme))
                } else if !state.localLLM.available {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.system(size: 12))
                        Text(state.localLLM.reason ?? "Not available.")
                            .font(DS.microFont)
                    }
                    .foregroundStyle(DS.muted(scheme))
                } else {
                    Text("Download a model to enable on-device AI.")
                        .font(DS.microFont)
                        .foregroundStyle(DS.muted(scheme))
                }

                if let error = state.localModelError {
                    Text(error)
                        .font(DS.microFont)
                        .foregroundStyle(DS.accent2Color)
                }

                // Model presets with lifecycle actions.
                ForEach(LocalModelPreset.presets) { model in
                    modelRow(model)
                }

                Button {
                    state.refreshLocalLLMStatus()
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
        .onAppear { state.refreshLocalLLMStatus() }
    }

    @ViewBuilder
    private func modelRow(_ model: LocalModelPreset) -> some View {
        let downloaded = LocalModelStore.isDownloaded(model)
        let progress = state.localModelProgress[model.id]
        let isLoaded = state.localLLM.loaded

        VStack(alignment: .leading, spacing: 6) {
            Text(model.title)
                .font(DS.bodyFont.weight(.semibold))
                .foregroundStyle(DS.ink(scheme))
            Text(model.detail)
                .font(DS.captionFont)
                .foregroundStyle(DS.muted(scheme))

            if let progress, progress < 1, !downloaded {
                // Download in progress.
                ProgressView(value: progress)
                    .tint(DS.accentColor)
                Text("\(Int(progress * 100))% of \(model.sizeLabel)")
                    .font(DS.microFont)
                    .foregroundStyle(DS.muted(scheme))
            } else if !downloaded {
                Button {
                    Task { await state.downloadLocalModel(model) }
                } label: {
                    Label("Download (\(model.sizeLabel))", systemImage: "arrow.down.circle")
                        .font(DS.captionFont.weight(.medium))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.bordered)
                .tint(DS.accentColor)
                .disabled(state.localModelBusy)
            } else if !isLoaded {
                HStack(spacing: 8) {
                    Button {
                        Task { await state.activateLocalModel(model) }
                    } label: {
                        Label(state.localModelBusy ? "Loading…" : "Activate", systemImage: "bolt.circle")
                            .font(DS.captionFont.weight(.medium))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(DS.accentColor)
                    .disabled(state.localModelBusy)

                    Button(role: .destructive) {
                        state.deleteLocalModel(model)
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 13))
                            .padding(6)
                    }
                    .buttonStyle(.bordered)
                    .tint(DS.accent2Color)
                    .disabled(state.localModelBusy)
                }
            } else {
                HStack(spacing: 8) {
                    Button {
                        state.unloadLocalModel()
                    } label: {
                        Label("Unload", systemImage: "eject.circle")
                            .font(DS.captionFont.weight(.medium))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 6)
                    }
                    .buttonStyle(.bordered)
                    .tint(DS.accentColor)

                    Button(role: .destructive) {
                        state.deleteLocalModel(model)
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 13))
                            .padding(6)
                    }
                    .buttonStyle(.bordered)
                    .tint(DS.accent2Color)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(DS.surface2(scheme), in: RoundedRectangle(cornerRadius: DS.rMd, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: DS.rMd, style: .continuous)
                .stroke(DS.line(scheme), lineWidth: 1)
        )
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

                // Recently Deleted (30-day soft-delete, like Voice Memos).
                // Shows entries the user deleted from Journals, with restore +
                // empty-trash. Auto-expire after 30 days.
                RecentlyDeletedCard(scheme: scheme)
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

/// "Recently Deleted" card for the Profile screen. Lists soft-deleted journals
/// (kept for 30 days, like Voice Memos), with per-entry restore and an
/// empty-trash action. Auto-expires entries older than 30 days on read.
struct RecentlyDeletedCard: View {
    let scheme: ColorScheme
    @EnvironmentObject var state: AppState

    private var deleted: [SlowClawMemoryEntry] { state.recentlyDeleted }

    var body: some View {
        DS.card(scheme) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Recently Deleted")
                        .font(DS.cardTitleFont)
                        .foregroundStyle(DS.ink(scheme))
                    Spacer()
                    if !deleted.isEmpty {
                        Button(role: .destructive) {
                            state.emptyTrash()
                        } label: {
                            Text("Empty")
                                .font(DS.captionFont.weight(.semibold))
                                .foregroundStyle(DS.accent2Color)
                        }
                        .buttonStyle(.plain)
                    }
                }

                if deleted.isEmpty {
                    Text("Deleted journals stay here for 30 days.")
                        .font(DS.captionFont)
                        .foregroundStyle(DS.muted(scheme))
                } else {
                    ForEach(deleted, id: \.key) { entry in
                        HStack(spacing: 10) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(entry.content.split(separator: "\n").first.map(String.init) ?? entry.content)
                                    .font(DS.captionFont.weight(.semibold))
                                    .foregroundStyle(DS.ink(scheme))
                                    .lineLimit(1)
                                Text(deletedAt(entry))
                                    .font(DS.microFont)
                                    .foregroundStyle(DS.muted(scheme))
                            }
                            Spacer()
                            Button("Restore") {
                                state.restore(key: entry.key)
                            }
                            .font(DS.captionFont.weight(.semibold))
                            .foregroundStyle(DS.accentColor)
                            .buttonStyle(.plain)
                        }
                        .padding(.vertical, 4)
                        if entry.key != deleted.last?.key {
                            Divider().opacity(0.4)
                        }
                    }
                }
            }
        }
    }

    /// "Deleted 3d ago" / "Deleted just now" from the soft-delete timestamp.
    private func deletedAt(_ entry: SlowClawMemoryEntry) -> String {
        let ts = AppState.softDeletedKeys()[entry.key] ?? 0
        let interval = Date().timeIntervalSince1970 - ts
        if interval < 60 { return "Deleted just now" }
        if interval < 3600 { return "Deleted \(Int(interval / 60))m ago" }
        if interval < 86400 { return "Deleted \(Int(interval / 3600))h ago" }
        return "Deleted \(Int(interval / 86400))d ago"
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
            // Optional cover image (YouTube thumbnail / Nostr article image).
            if let thumb = item.thumbnailURL, let url = URL(string: thumb) {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .empty:
                        Rectangle().fill(DS.surface2(scheme))
                            .frame(height: 160)
                    case .success(let image):
                        image.resizable().scaledToFill().frame(height: 160).clipped()
                    case .failure:
                        Color.clear.frame(height: 0)
                    @unknown default:
                        Color.clear.frame(height: 0)
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: 160)
                .background(DS.surface2(scheme))
                .clipped()
            }

            VStack(alignment: .leading, spacing: 6) {
                // Source row: accent-green uppercase host + read time / video badge.
                HStack(spacing: 8) {
                    Text(host.uppercased())
                        .font(DS.sourceLabelFont)
                        .foregroundStyle(DS.accent(scheme))
                        .kerning(0.3)
                    Spacer()
                    if item.sourcePlatform == "youtube" {
                        Text("▶ Video")
                            .font(DS.captionFont)
                            .foregroundStyle(DS.muted(scheme))
                    } else {
                        Text("⏱ \(item.readMinutes) min")
                            .font(DS.captionFont)
                            .foregroundStyle(DS.muted(scheme))
                    }
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
