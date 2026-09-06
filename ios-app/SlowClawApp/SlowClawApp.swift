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
import UIKit
import AVFoundation
import BackgroundTasks

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
    // Catches URLs delivered during cold launch from a share sheet (Voice Memos
    // → Share → SlowClaw). SwiftUI's .onOpenURL reliably fires for foreground
    // share-sheet deliveries, but on a COLD launch (app not yet running) the URL
    // can arrive before .onOpenURL is wired. The delegate captures it and the
    // App flushes pending URLs on first appear.
    @UIApplicationDelegateAdaptor(ShareURLDelegate.self) private var urlDelegate
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
                .onAppear {
                    voiceMemoImporter.appState = appState
                    urlDelegate.appState = appState
                    // Warm-delivery path for shared files routed through the
                    // app delegate (see ShareURLDelegate.openURLHandler).
                    urlDelegate.openURLHandler = { [weak voiceMemoImporter] url in
                        voiceMemoImporter?.appState = appState
                        voiceMemoImporter?.enqueue(url)
                    }
                    // Flush any URL the delegate captured during cold launch.
                    for pending in urlDelegate.flushPending() {
                        voiceMemoImporter.enqueue(pending)
                    }
                    // Reattach any user-started background model transfer so
                    // its progress bar resumes after a process relaunch.
                    appState.resumePendingLocalModelDownloads()
                    // Load AI only when requested: capture and reading must
                    // remain available even after an inference-related crash.
                    // Resume any pending transcriptions left from a killed-app
                    // session, and reconcile audio journals whose transcript
                    // never landed (queues them newest-first).
                    Task {
                        await appState.resumePendingTranscriptionsOnLaunch()
                        await appState.reconcileMissingTranscripts()
                    }
                }
        }
    }
}

/// A lock-protected once-only flag for sharing completion state between two
/// concurrently-executing (@Sendable) closures — e.g. a BGTask's work task and
/// its expiration handler — where a captured local `var` is not compiler-safe.
/// `claim()` returns true for exactly one caller, guaranteeing the guarded
/// completion (setTaskCompleted / endBackgroundTask) runs exactly once.
private final class OnceBox: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    /// True for the first caller, false for every caller afterwards.
    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        if claimed { return false }
        claimed = true
        return true
    }
}

/// Serializes llama.cpp work and keeps it at utility priority. The Zig engine
/// already protects its model with a mutex; queueing here prevents multiple
/// Swift tasks from occupying cooperative threads while they wait for that
/// mutex. The actual synchronous FFI call runs in a detached task, so the main
/// actor remains free to handle tab changes, scrolling, and taps.
/// Captures share-sheet / file-open URLs delivered during cold launch (before
/// SwiftUI's .onOpenURL is wired). The App flushes them on first appear.
final class ShareURLDelegate: NSObject, UIApplicationDelegate {
    private let pendingLock = NSLock()
    private var pending: [URL] = []
    /// Warm-delivery handler. When the system routes an opened file through
    /// application(_:open:options:) AFTER launch (foreground share), the URL
    /// is dispatched here IMMEDIATELY — the old capture-and-flush design only
    /// flushed on the App's first onAppear, so a warm share was captured and
    /// never imported (the "Preparing… then nothing" symptom).
    var openURLHandler: (@MainActor (URL) -> Void)?
    /// Weak ref to AppState so the BGTask handler can drain pending
    /// transcriptions. Set by the App when appState is wired up.
    weak var appState: AppState?

    func application(_ application: UIApplication,
                     didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        // Register the background transcription task. Must happen before the
        // app finishes launching. iOS fires it (best-effort) to drain pending
        // transcriptions — audio journals saved before their transcript landed.
        let identifier = AppState.backgroundTranscriptionTaskID
        BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: nil) { [weak self] task in
            guard let task = task as? BGProcessingTask else {
                task.setTaskCompleted(success: false)
                return
            }
            Self.handleBackgroundTranscription(task: task, appState: self?.appState)
        }
        // Cold-launch delivery: when iOS launches the app straight from a
        // share ("Copy to SlowClaw" while the app is not running), the URL
        // arrives in launchOptions — under the SwiftUI lifecycle the delegate's
        // application(_:open:options:) is NOT reliably called afterwards, so
        // without this capture the URL (and the import) is silently dropped.
        if let launchURL = launchOptions?[.url] as? URL {
            pendingLock.lock()
            pending.append(launchURL)
            pendingLock.unlock()
        }
        return true
    }

    // On-Device AI model downloads live in a background URLSession
    // ("com.slowclaw.app.model-download") so the multi-GB transfer keeps
    // running while the app is backgrounded/suspended or the phone is locked.
    // When iOS relaunches the app to deliver those session events, this
    // callback reconnects the download coordinator's delegate. Sessions we
    // don't own complete immediately so the system isn't left waiting.
    func application(_ application: UIApplication,
                     handleEventsForBackgroundURLSession identifier: String,
                     completionHandler: @escaping () -> Void) {
        guard slowClawHandleBackgroundModelSession(identifier: identifier,
                                                   completionHandler: completionHandler) else {
            completionHandler()
            return
        }
    }

    func application(_ app: UIApplication, open url: URL,
                     options: [UIApplication.OpenURLOptionsKey: Any] = [:]) -> Bool {
        // Warm delivery: hand it straight to the importer if wired; otherwise
        // capture for the cold-launch flush.
        if let openURLHandler {
            MainActor.assumeIsolated { openURLHandler(url) }
            return true
        }
        pendingLock.lock()
        pending.append(url)
        pendingLock.unlock()
        return true
    }

    /// Returns and clears any URLs captured before SwiftUI was ready.
    func flushPending() -> [URL] {
        pendingLock.lock()
        let out = pending
        pending.removeAll()
        pendingLock.unlock()
        return out
    }

    /// Drain pending transcriptions inside a BGProcessingTask. Requests a
    /// background execution assertion so the work isn't suspended, drains the
    /// queue, then completes the task and schedules the next one if anything
    /// remains. Best-effort — iOS decides when (and whether) to run it.
    private static func handleBackgroundTranscription(task: BGProcessingTask, appState: AppState?) {
        guard let appState else {
            task.setTaskCompleted(success: false)
            return
        }
        // Keep the app alive for the duration of the drain.
        let bgID = UIApplication.shared.beginBackgroundTask(withName: "slowclaw.transcribe.drain")
        // Exactly-once completion, whichever of the work task or the
        // expiration handler gets there first (a double setTaskCompleted
        // raises an exception). OnceBox is a lock-protected reference type
        // because local captured mutable state isn't safe to share across
        // @Sendable closures; each closure below captures only lets.
        let completion = OnceBox()
        let work = Task { @MainActor in
            await appState.drainPendingTranscriptions()
            if completion.claim() {
                task.setTaskCompleted(success: !Task.isCancelled)
                if bgID != .invalid {
                    UIApplication.shared.endBackgroundTask(bgID)
                }
            }
            // If the queue still has items (e.g. a failed segment), reschedule.
            if !Task.isCancelled {
                await appState.scheduleNextBackgroundTranscription()
            }
        }
        // If iOS reclaims the task before the drain finishes: submit the
        // replacement schedule FIRST (once setTaskCompleted runs, the
        // scheduler may treat the app as done and a later submit can be
        // lost), then report the task as failed and release the background
        // assertion. claim() keeps completion exactly-once even if the work
        // task finishes in between.
        task.expirationHandler = {
            Task { @MainActor in
                work.cancel()
                await appState.scheduleNextBackgroundTranscription()
                if completion.claim() {
                    task.setTaskCompleted(success: false)
                    if bgID != .invalid {
                        UIApplication.shared.endBackgroundTask(bgID)
                    }
                }
            }
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
    /// Preset activated in this process. The Zig model metadata does not carry
    /// the quant/file identity, so UI rows must not treat every preset as the
    /// active one merely because some model is loaded.
    @Published var loadedLocalModelPresetID: String? = nil
    /// True only while a model ACTIVATION (load into llama.cpp) is in flight.
    /// Downloads no longer set this — per-preset download state lives in
    /// `activeDownloadIDs`, so a multi-GB download never disables unrelated
    /// Download buttons or other AI surfaces.
    @Published var localModelBusy: Bool = false
    @Published var localModelError: String? = nil
    @Published var localModelProgress: [String: Double] = [:]
    /// Preset IDs with an in-flight download. Per-preset on purpose: the row
    /// actually downloading shows its own determinate bar, and every other
    /// preset's Download button stays enabled. Persisted so a relaunched app
    /// automatically reattaches to the background URLSession task and restores
    /// progress instead of showing a misleading fresh Download button.
    @Published var activeDownloadIDs: Set<String> = []
    private static let activeDownloadDefaultsKey = "slowclaw.model-downloads.active"
    /// Operations attached in this process. Separate from activeDownloadIDs,
    /// which is restored from disk before this process has reattached.
    private var localDownloadOperations: Set<String> = []

    // Apple Speech file transcription status. This is independent of the local
    // text model, so model lifecycle controls never race audio work.
    @Published var audioTranscriptionInFlight: Bool = false
    @Published var audioTranscriptionProgress: String? = nil
    private var audioTranscriptionCount = 0
    /// Last manual transcription route/result, shown beside Re-transcribe.
    @Published var lastTranscriptionStatus: String? = nil

    // 🔬 Locked-phone CPU experiment. When ON, finishRecording keeps the
    // AVAudioSession active past Stop and runs transcription inside that
    // window, logging timings + lock state to experiment_log.jsonl so you can
    // read whether the process got CPU time while the phone was locked.
    // OFF by default — zero behavior change otherwise.
    @AppStorage("lockedPhoneExperiment") var lockedPhoneExperiment: Bool = false
    /// Journal keys whose title is being generated by AI. Drives a small
    /// spinner beside the row title while pending. Cleared when the AI title
    /// lands (or fails).
    @Published var pendingTitleKeys: Set<String> = []

    @Published var journals: [SlowClawMemoryEntry] = []
    @Published var drafts: [SlowClawMemoryEntry] = []
    @Published var interests: [String] = []
    @Published var isIndexingInterests = false
    @Published var interestIndexProgress: String? = nil
    private var interestWeights: [String: Double] = [:]
    private var journalInterestRecords: [String: JournalInterestRecord] = [:]
    private var mutedInterests: Set<String> = []
    private var interestIndexTask: Task<Void, Never>?
    private var interestIndexNeedsAnotherPass = false
    private static let interestIndexDefaultsKey = "slowclaw.interests.index-v1"
    private static let mutedInterestsDefaultsKey = "slowclaw.interests.muted-v1"

    private struct JournalInterestRecord: Codable {
        let fingerprint: String
        let topics: [String]
        let journalDate: Date
    }
    // Reads is the default tab (matches the reference app: the unified "for me"
    // stream is the home surface).
    @Published var selectedTab: AppTab = .journal

    // Journal sidebar (matches the reference app's hamburger drawer). The
    // selected journal's content loads into the editor; nil = fresh new entry.
    @Published var journalSidebarOpen: Bool = false
    @Published var selectedJournalKey: String? = nil

    // In-app browser destination. Set by `openWebLink(_:)` — the single
    // funnel for opening web content — and presented as a sheet by AppShell,
    // so every link (Reads cards, article viewers) opens inside the app
    // instead of bouncing out to Safari.
    @Published var activeWebLink: WebLink? = nil
    @Published var readingSignals = ReadingHistory.load()
    private var readingCandidate: RankedFeedItem?
    private var readingStarted: Date?
    private var readingSeconds: TimeInterval = 0

    func openArticle(_ item: RankedFeedItem) {
        guard let url = URL(string: item.link) else { return }
        readingCandidate = item
        readingSeconds = 0
        readingStarted = Date()
        openWebLink(url)
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(8))
            guard let self, self.readingCandidate?.id == item.id,
                  UIApplication.shared.applicationState == .active,
                  !self.audioTranscriptionInFlight,
                  !ProcessInfo.processInfo.isLowPowerModeEnabled,
                  ProcessInfo.processInfo.thermalState == .nominal else { return }
            await self.ensureLocalModelActivated()
            self.scheduleInterestIndexing()
        }
    }

    func readingActivityChanged(active: Bool) {
        if let started = readingStarted { readingSeconds += Date().timeIntervalSince(started) }
        readingStarted = active && readingCandidate != nil ? Date() : nil
    }

    func finishReading() {
        readingActivityChanged(active: false)
        if let item = readingCandidate, readingSeconds >= 20, readingSignals[item.id] == nil {
            rememberArticle(item, preference: 0)
        }
        readingCandidate = nil
    }

    func rememberArticle(_ item: RankedFeedItem, preference: Int) {
        readingSignals[item.id] = ReadingSignal(
            topics: ReadingHistory.topics(title: item.title, summary: item.description.strippingHTML()),
            date: Date(), preference: preference)
        readingSignals = Dictionary(uniqueKeysWithValues: readingSignals.sorted { $0.value.date > $1.value.date }.prefix(200).map { ($0.key, $0.value) })
        ReadingHistory.save(readingSignals)
        rebuildInterestLens()
        readsRefreshedAt = nil
    }

    func clearReadingHistory() {
        readingSignals = [:]
        ReadingHistory.save(readingSignals)
        rebuildInterestLens()
        readsRefreshedAt = nil
    }

    /// Open a web link inside the app (SFSafariViewController sheet).
    /// Non-http(s) schemes are rejected — the app only ever links articles.
    /// Dead-viewer migration: any cached habla.news/a/* link (the viewer went
    /// offline; every URL 404s) is rewritten to highlighter.com/a/*, which
    /// resolves the same naddr server-side.
    func openWebLink(_ url: URL) {
        guard var comps = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = comps.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = comps.host?.lowercased() else {
            return
        }
        // Only the dead viewer's ARTICLE paths (habla.news/a/*) resolve on
        // highlighter.com via the same naddr. Other habla.news paths are not
        // article links — rewriting them would send unrelated URLs to the
        // wrong host, so they pass through unchanged.
        if host == "habla.news", comps.path.hasPrefix("/a/") {
            comps.host = "highlighter.com"
        }
        guard let final = comps.url else { return }
        activeWebLink = WebLink(url: final)
    }

    // Reads feed cache. Lives on AppState (not ReadsView @State) so switching
    // tabs preserves the list — the view shows cached items instantly and a
    // background refresh merges + re-ranks new content. `readsLoadedOnce`
    // guards the auto-load so we don't refetch on every tab return.
    @Published var readsItems: [RankedFeedItem] = []
    @Published var readsLoading: Bool = false
    @Published var readsError: String? = nil
    @Published var readsRefreshedAt: Date? = nil
    // Session-scoped like/dislike marks for Reads cards. Kept on AppState (not
    // card @State) so recycled LazyVStack rows and list refreshes don't lose
    // the user's taps.
    @Published var likedReadIDs: Set<String> = []
    @Published var dislikedReadIDs: Set<String> = []
    private var readsLoadedOnce: Bool = false
    fileprivate static var cachedCatalog: [SlowClawFeedSource]?
    // v3: ranking now uses the durable, weighted journal lens.
    // The version bump discards older caches wholesale — otherwise hydrated
    // items kept their dead habla.news URLs forever (the persistent-404 bug:
    // the merge path preserves existing items, so old links never aged out).
    private static let readsCacheVersion = 3
    private static let readsCacheMaxAge: TimeInterval = 30 * 60
    private static let rssSourceLimit = 32
    private var readsRefreshInFlight = false

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
    /// Owned by AppState rather than DraftsView, so switching tabs cannot
    /// cancel or orphan an in-progress generation.
    private var postGenerationTask: Task<Void, Never>?

    private var processedJournalKeys: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: "slowclaw.tweetclaw.processed") ?? []) }
        set { UserDefaults.standard.set(Array(newValue), forKey: "slowclaw.tweetclaw.processed") }
    }

    @Published var apiKey: String {
        didSet {
            UserDefaults.standard.set(apiKey, forKey: "slowclaw.api_key")
            setupLLM()
            scheduleInterestIndexing()
        }
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

        // The journal lens is durable. It paints immediately on relaunch and
        // is incrementally refreshed when the local model becomes available.
        journalInterestRecords = Self.loadJournalInterestRecords()
        mutedInterests = Set(UserDefaults.standard.stringArray(
            forKey: Self.mutedInterestsDefaultsKey) ?? [])
        rebuildInterestLens()

        // Hydrate synchronously so relaunches paint the last good Reads list
        // before any network work begins.
        if let cache = Self.loadReadsCache() {
            self.readsItems = cache.items
            self.readsRefreshedAt = cache.refreshedAt
            self.readsLoadedOnce = true
        }

        // Retire the old low-quality quant and the removed MTMD projector
        // before restoring downloads or activating the single supported model.
        LocalModelStore.removeRetiredArtifacts()
        UserDefaults.standard.removeObject(forKey: "experimentalAudioEngine")

        // Restore user-started model downloads before the first screen paints.
        // The URLSession transfer itself is owned by iOS; these IDs let this
        // process reattach its progress handlers after a relaunch. Unknown IDs
        // from an older catalog are discarded rather than retried forever.
        let knownModelIDs = Set(LocalModelPreset.presets.map(\.id))
        activeDownloadIDs = Set(UserDefaults.standard.stringArray(
            forKey: Self.activeDownloadDefaultsKey) ?? []).intersection(knownModelIDs)
        for id in activeDownloadIDs { localModelProgress[id] = 0 }
        persistActiveDownloadIDs()

        setupLLM()
        refreshLocalLLMStatus()
        // A model file can land via the background download coordinator with
        // no in-app awaiter (app relaunched mid-download; the transfer kept
        // running while suspended). Re-read status so the model row re-renders
        // as Downloaded/Activate instead of a stale Download button.
        NotificationCenter.default.addObserver(
            forName: .slowClawModelFileLanded, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refreshLocalLLMStatus() }
        }
        Task { await refreshJournals() }
    }

    // MARK: - On-device LLM management

    func refreshLocalLLMStatus() {
        Task {
            let snapshot = try? await OnDeviceAIExecutor.shared.run { slowClawLocalLLMStatus() }
            if let snapshot {
                localLLM = snapshot
                if !snapshot.loaded { loadedLocalModelPresetID = nil }
            }
        }
    }

    /// True when any LLM is usable: a configured remote provider OR a loaded
    /// on-device model. Gates every AI-powered surface.
    var anyLLMAvailable: Bool { llm != nil || localLLM.loaded }

    func downloadLocalModel(_ preset: LocalModelPreset) async {
        // One waiter/progress pipeline per preset in this process. This also
        // makes repeated onAppear calls harmless while a restored transfer is
        // still running.
        guard localDownloadOperations.insert(preset.id).inserted else { return }
        activeDownloadIDs.insert(preset.id)
        persistActiveDownloadIDs()
        defer {
            localDownloadOperations.remove(preset.id)
            activeDownloadIDs.remove(preset.id)
            persistActiveDownloadIDs()
        }

        localModelError = nil
        // Seed the bar before the first await so the row renders immediately,
        // including 0% while the background session waits for Wi-Fi.
        localModelProgress[preset.id] = LocalModelStore.isDownloaded(preset) ? 1 : 0
        // Track ONLY this preset as downloading. Downloads must not flip the
        // global busy flag — that used to disable every other preset's
        // Download button for the whole multi-GB transfer. The defer above
        // clears both the live and persisted state on every exit path.
        do {
            // Skip the text GGUF when it is already on disk.
            if !LocalModelStore.isDownloaded(preset) {
                _ = try await LocalModelStore.download(preset) { [weak self] p in
                    Task { @MainActor in self?.localModelProgress[preset.id] = p }
                }
            }
            localModelProgress[preset.id] = 1
        } catch {
            localModelError = "Download failed: \(error.localizedDescription)"
            localModelProgress[preset.id] = nil
        }
    }

    /// Reattach progress handlers for downloads the user started before this
    /// process launched. LocalModelStore joins matching background-session
    /// tasks by destination; if a file already landed, it completes instantly.
    /// Stale/cancelled transfers retry on the same unmetered-network policy
    /// rather than remaining stuck forever.
    func resumePendingLocalModelDownloads() {
        let presetsByID = Dictionary(uniqueKeysWithValues: LocalModelPreset.presets.map { ($0.id, $0) })
        for id in activeDownloadIDs {
            guard let preset = presetsByID[id] else { continue }
            Task { await self.downloadLocalModel(preset) }
        }
    }

    private func persistActiveDownloadIDs() {
        UserDefaults.standard.set(activeDownloadIDs.sorted(),
                                  forKey: Self.activeDownloadDefaultsKey)
    }

    /// Load a downloaded model into the on-device engine. Runs off-actor:
    /// mmap-ing a multi-GB GGUF takes seconds and must not block the UI.
    func activateLocalModel(_ preset: LocalModelPreset) async {
        guard let url = try? LocalModelStore.fileURL(for: preset) else { return }
        localModelBusy = true
        localModelError = nil
        defer { localModelBusy = false }
        let err = try? await OnDeviceAIExecutor.shared.run {
            slowClawLocalLLMLoad(path: url.path)
        }
        if let err {
            localModelError = err
            loadedLocalModelPresetID = nil
        } else {
            loadedLocalModelPresetID = preset.id
        }
        if let snapshot = try? await OnDeviceAIExecutor.shared.run({ slowClawLocalLLMStatus() }) {
            localLLM = snapshot
        }
        if localLLM.loaded { scheduleInterestIndexing() }
    }

    func unloadLocalModel() {
        guard !localModelBusy else { return }
        localModelBusy = true
        Task {
            _ = try? await OnDeviceAIExecutor.shared.run { slowClawLocalLLMUnload() }
            loadedLocalModelPresetID = nil
            localModelBusy = false
            refreshLocalLLMStatus()
        }
    }

    func deleteLocalModel(_ preset: LocalModelPreset) {
        guard !localModelBusy else { return }
        localModelBusy = true
        Task {
            defer { localModelBusy = false }
            _ = try? await OnDeviceAIExecutor.shared.run {
                slowClawLocalLLMUnload()
                try LocalModelStore.delete(preset)
            }
            loadedLocalModelPresetID = nil
            localModelProgress[preset.id] = nil
            refreshLocalLLMStatus()
        }
    }

    /// Auto-activate the on-device model when the app is open or AI is needed.
    /// If the llama.cpp backend is compiled in but no model is loaded, picks
    /// the first downloaded preset and loads it. No-op when no preset is
    /// downloaded (won't auto-download a 2GB model without consent) or when a
    /// model is already loaded. Safe to call repeatedly.
    func ensureLocalModelActivated() async {
        guard !audioTranscriptionInFlight else { return }
        // Re-read status in case it changed (e.g. the OS reclaimed the model).
        if let snapshot = try? await OnDeviceAIExecutor.shared.run({ slowClawLocalLLMStatus() }) {
            localLLM = snapshot
        }
        // Also defer while a download is in flight: loading a multi-GB GGUF
        // while another streams to disk is the same RAM/disk conflict the
        // model rows guard against in the UI. Downloads never set
        // localModelBusy, so this check is explicit.
        guard localLLM.available, !localLLM.loaded, !localModelBusy,
              activeDownloadIDs.isEmpty else { return }
        // There is one curated text model. Never auto-download without consent.
        let downloaded = LocalModelPreset.presets.filter { LocalModelStore.isDownloaded($0) }
        let preset = downloaded.first
        guard let preset else { return }
        await activateLocalModel(preset)
    }

    // MARK: - AI routing (local-first)

    /// Every AI call routes through these helpers: on-device when a local
    /// model is loaded (private, offline), else the configured remote
    /// provider. Local inference runs in a detached task so multi-second
    /// generations never block the main actor.
    func aiExtractInterests(from text: String) async throws -> [String] {
        try await waitForSpeechPriority()
        if localLLM.loaded {
            return try await OnDeviceAIExecutor.shared.run {
                try slowClawLocalExtractInterests(journalText: text)
            }
        }
        guard let llm else { throw SlowClawFeedError.internalError("no LLM configured") }
        return try llm.extractInterests(journalText: text, model: model)
    }

    func aiDraftPost(from text: String, maxChars: Int = 300) async throws -> String {
        try await waitForSpeechPriority()
        if localLLM.loaded {
            return try await OnDeviceAIExecutor.shared.run {
                try slowClawLocalDraftPost(journalText: text, maxChars: maxChars)
            }
        }
        guard let llm else { throw SlowClawFeedError.internalError("no LLM configured") }
        return try llm.draftPost(journalText: text, model: model, maxChars: maxChars)
    }

    func aiSynthesize(transcript: String) async throws -> String {
        try await waitForSpeechPriority()
        if localLLM.loaded {
            return try await OnDeviceAIExecutor.shared.run {
                try slowClawLocalSynthesizeJournal(transcript: transcript)
            }
        }
        guard let llm else { throw SlowClawFeedError.internalError("no LLM configured") }
        return try llm.synthesizeJournal(transcript: transcript, model: model)
    }

    /// Generate a concise title for a journal entry from its transcript/text.
    /// Local-first (on-device llama.cpp) with a remote fallback. Returns the
    /// trimmed title or throws if no LLM is available.
    func aiTitle(transcript: String) async throws -> String {
        try await waitForSpeechPriority()
        if localLLM.loaded {
            return try await OnDeviceAIExecutor.shared.run {
                try slowClawLocalGenerateTitle(transcript: transcript)
            }
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let llm else { throw SlowClawFeedError.internalError("no LLM configured") }
        // Remote path: call the provider directly (it's async/network, doesn't
        // block the actor like local inference does — matches aiSynthesize).
        let title = try await llm.chat(
            systemPrompt: "You write a concise, descriptive title for a journal entry. Maximum 8 words. Capture the main topic or moment. No trailing period, no quotes, no preamble. Output ONLY the title text.",
            message: transcript, model: model, temperature: 0.4)
        return title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func aiChat(system: String, message: String, temperature: Double) async throws -> String {
        try await waitForSpeechPriority()
        if localLLM.loaded {
            return try await OnDeviceAIExecutor.shared.run {
                try slowClawLocalLLMChat(systemPrompt: system, message: message, maxTokens: 512, temperature: temperature)
            }
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
        scheduleInterestIndexing()
    }

    // MARK: - Durable journal interest lens
    private func waitForSpeechPriority() async throws {
        while audioTranscriptionInFlight {
            try await Task.sleep(for: .milliseconds(250))
        }
        try Task.checkCancellation()
    }

    /// Start a single background indexing pass. Every successfully analyzed
    /// journal is checkpointed, so suspension or relaunch resumes with only
    /// new/edited entries. Audio placeholders are skipped until their real
    /// transcript is stored.
    func scheduleInterestIndexing() {
        guard anyLLMAvailable else { return }
        guard interestIndexTask == nil else {
            interestIndexNeedsAnotherPass = true
            return
        }
        interestIndexTask = Task { [weak self] in
            guard let self else { return }
            await self.indexJournalInterests()
            self.interestIndexTask = nil
            if self.interestIndexNeedsAnotherPass {
                self.interestIndexNeedsAnotherPass = false
                self.scheduleInterestIndexing()
            }
        }
    }

    private func indexJournalInterests() async {
        guard anyLLMAvailable else { return }
        let candidates = journals.compactMap { entry -> (SlowClawMemoryEntry, String, String)? in
            let body = journalBodyOf(entry.content)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let analysisText = Self.hasMeaningfulBody(body)
                ? body
                : entry.content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard analysisText.count >= 20,
                  !(entry.mediaURL != nil && Self.needsTranscript(entry.content)),
                  Self.hasMeaningfulBody(analysisText) else { return nil }
            return (entry, analysisText, Self.interestFingerprint(analysisText))
        }
        .sorted { (journalDate($0.0) ?? .distantPast) > (journalDate($1.0) ?? .distantPast) }

        let pending = candidates.filter {
            journalInterestRecords[$0.0.key]?.fingerprint != $0.2
        }
        guard !pending.isEmpty else {
            rebuildInterestLens()
            return
        }

        isIndexingInterests = true
        defer {
            isIndexingInterests = false
            interestIndexProgress = nil
        }
        var changed = false
        for (offset, item) in pending.enumerated() {
            if Task.isCancelled { break }
            if Self.softDeletedKeys()[item.0.key] != nil { continue }
            // A user-requested post should win after the current extraction.
            while (isGeneratingPosts || audioTranscriptionInFlight
                   || UIApplication.shared.applicationState != .active
                   || ProcessInfo.processInfo.isLowPowerModeEnabled
                   || ProcessInfo.processInfo.thermalState == .serious
                   || ProcessInfo.processInfo.thermalState == .critical) && !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(300))
            }
            if Task.isCancelled { break }
            interestIndexProgress = "Learning from journal \(offset + 1) of \(pending.count)…"
            guard let raw = try? await aiExtractInterests(from: item.1) else {
                await Task.yield()
                continue
            }
            let topics = Self.sanitizeInterests(raw)
            guard !topics.isEmpty else { continue }
            journalInterestRecords[item.0.key] = JournalInterestRecord(
                fingerprint: item.2,
                topics: topics,
                journalDate: journalDate(item.0) ?? Date())
            Self.saveJournalInterestRecords(journalInterestRecords)
            rebuildInterestLens()
            changed = true
            await Task.yield()
        }

        if changed {
            // The old cache was ranked with another lens. Replace it in a
            // background refresh; the rest of the app stays interactive.
            readsRefreshedAt = nil
            await loadReads(force: true)
        }
    }

    /// Persist a user's removal as a mute, then immediately rebuild and
    /// re-rank. A later journal mentioning the same topic will not silently
    /// re-add it.
    func removeInterest(_ interest: String) {
        mutedInterests.insert(interest.lowercased())
        UserDefaults.standard.set(mutedInterests.sorted(),
                                  forKey: Self.mutedInterestsDefaultsKey)
        rebuildInterestLens()
        readsRefreshedAt = nil
        Task { await loadReads(force: true) }
    }

    private func rebuildInterestLens() {
        let now = Date()
        var scores: [String: Double] = [:]
        for record in journalInterestRecords.values {
            let ageDays = max(0, now.timeIntervalSince(record.journalDate) / 86_400)
            // Recent thoughts lead, but older recurring interests retain a
            // meaningful floor instead of disappearing abruptly.
            let recency = max(0.35, pow(0.5, ageDays / 90))
            for topic in record.topics where !mutedInterests.contains(topic) {
                scores[topic, default: 0] += recency
            }
        }
        var readingScores: [String: Double] = [:]
        for signal in readingSignals.values {
            let age = max(0, now.timeIntervalSince(signal.date) / 86_400)
            let weight = (signal.preference < 0 ? -0.5 : signal.preference > 0 ? 0.45 : 0.15) * pow(0.5, age / 14)
            for topic in signal.topics where !mutedInterests.contains(topic) {
                readingScores[topic, default: 0] += weight
            }
        }
        for (topic, weight) in readingScores { scores[topic, default: 0] += min(0.75, max(-0.75, weight)) }
        scores = scores.filter { $0.value > 0 }
        let ordered = scores.sorted {
            if $0.value == $1.value { return $0.key < $1.key }
            return $0.value > $1.value
        }
        let strongest = ordered.first?.value ?? 1
        interests = ordered.prefix(24).map(\.key)
        interestWeights = Dictionary(uniqueKeysWithValues: ordered.prefix(24).map {
            // 0.75...1.75: frequency/recency influences rank without letting
            // one long-running theme permanently swamp freshness/diversity.
            ($0.key, 0.75 + min(1, $0.value / strongest))
        })
    }

    private static func sanitizeInterests(_ raw: [String]) -> [String] {
        var seen = Set<String>()
        return raw.compactMap { value in
            let topic = value.lowercased()
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'`.-"))
            guard topic.count >= 2, topic.count <= 48,
                  seen.insert(topic).inserted else { return nil }
            return topic
        }.prefix(8).map { $0 }
    }

    nonisolated private static func interestFingerprint(_ text: String) -> String {
        var hash: UInt64 = 14_695_981_039_346_656_037
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1_099_511_628_211
        }
        return String(hash, radix: 16)
    }

    private static func loadJournalInterestRecords() -> [String: JournalInterestRecord] {
        guard let data = UserDefaults.standard.data(forKey: interestIndexDefaultsKey),
              let records = try? JSONDecoder().decode(
                [String: JournalInterestRecord].self, from: data) else { return [:] }
        return records
    }

    private static func saveJournalInterestRecords(_ records: [String: JournalInterestRecord]) {
        guard let data = try? JSONEncoder().encode(records) else { return }
        UserDefaults.standard.set(data, forKey: interestIndexDefaultsKey)
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
        journalInterestRecords.removeValue(forKey: key)
        Self.saveJournalInterestRecords(journalInterestRecords)
        rebuildInterestLens()
        readsRefreshedAt = nil
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
        var pending = Self.pendingTranscriptionsURL.map {
            Self.loadPendingTranscriptions(at: $0)
        } ?? []
        for key in keys {
            if let entry = try? memory.get(key: key),
               let rel = entry.mediaURL,
               let mediaURL = AudioRecorder.absoluteURL(forMediaRelativePath: rel),
               Self.isOwnedDocumentURL(mediaURL) {
                try? FileManager.default.removeItem(at: mediaURL)
            }
            try? memory.forget(key: key)
            pending.removeAll { $0.key == key }
            journalInterestRecords.removeValue(forKey: key)
        }
        if let queueURL = Self.pendingTranscriptionsURL {
            Self.savePendingTranscriptions(pending, at: queueURL)
        }
        UserDefaults.standard.removeObject(forKey: Self.softDeleteKey)
        Self.saveJournalInterestRecords(journalInterestRecords)
        rebuildInterestLens()
        readsRefreshedAt = nil
        Task { await refreshJournals() }
    }

    /// Destructive media cleanup is limited to the app's Documents directory;
    /// a malformed/stale media_url can never make Empty Trash remove an
    /// arbitrary filesystem location.
    private static func isOwnedDocumentURL(_ url: URL) -> Bool {
        guard let docs = FileManager.default.urls(for: .documentDirectory,
                                                  in: .userDomainMask).first else {
            return false
        }
        let root = docs.standardizedFileURL.path + "/"
        return url.standardizedFileURL.path.hasPrefix(root)
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
    /// launch. Lives in Caches/reads-feed-v3.json (see readsCacheURL above).

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
        guard !readsRefreshInFlight else { return }
        readsRefreshInFlight = true
        defer { readsRefreshInFlight = false }

        let isFirst = !readsLoadedOnce || readsItems.isEmpty
        if force || isFirst {
            readsLoading = true
            if !force { readsError = nil }
        }
        readsLoadedOnce = true

        let topics = interests.map {
            SlowClawTopic(label: $0, weight: interestWeights[$0] ?? 1.0)
        }
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

        var combined = (rss + nostr).filter { readingSignals[$0.id]?.preference != -1 }
        combined.sort { $0.score > $1.score }
        // Adult-content gate on the merged batch (RSS + Nostr): the catalog
        // is broad and relays are global; without this, explicit items that
        // carry no content-warning land in the feed.
        combined = combined.filter {
            ReadsContentFilter.isAllowed($0.title, $0.description)
        }
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
            // Background refresh: prepend new items not already present. Dedup
            // on BOTH id and link — ids embed the item's batch index, which
            // shifts as feeds update, so id-only dedup let the same article
            // back in on the next refresh (duplicates in the list).
            let existing = Set(readsItems.map { $0.id })
            let existingLinks = Set(readsItems.map { $0.link }.filter { !$0.isEmpty })
            let fresh = capped.filter {
                !existing.contains($0.id) && ($0.link.isEmpty || !existingLinks.contains($0.link))
            }
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
        let stopWords: Set<String> = [
            "about", "after", "from", "into", "journal", "notes", "that",
            "their", "there", "these", "this", "with", "your"
        ]
        let weightedTerms: [(String, Double)] = topics.flatMap { topic in
            topic.label.lowercased().split { !$0.isLetter && !$0.isNumber }.compactMap { part in
                let term = String(part)
                guard term.count >= 3, !stopWords.contains(term) else { return nil }
                return (term, topic.weight)
            }
        }
        guard !weightedTerms.isEmpty else { return Array(sources.prefix(rssSourceLimit)) }

        let scored = sources.enumerated().map { index, source in
            let metadata = "\(source.title) \(source.domain)".lowercased()
            let score = weightedTerms.reduce(0.0) { total, term in
                total + (metadata.contains(term.0) ? term.1 : 0)
            }
            return (source: source, score: score, index: index)
        }
        .sorted {
            if $0.score == $1.score { return $0.index < $1.index }
            return $0.score > $1.score
        }
        return Array(scored.prefix(rssSourceLimit).map(\.source))
    }

    private static var readsCacheURL: URL? {
        guard let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            return nil
        }
        return directory.appendingPathComponent("reads-feed-v3.json")
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
        _ = await storeJournalNow(text: text, source: source, mediaURL: mediaURL)
    }

    /// Like storeJournal, but returns the generated key so the caller can upsert
    /// the same entry later (used by auto-save-on-stop: the journal is stored
    /// immediately with a placeholder, then the transcript lands and the key is
    /// updated via storeJournalUpdate).
    @discardableResult
    func storeJournalNow(text: String, source: String?, mediaURL: String?) async -> String {
        let key = "journal_\(Date().timeIntervalSince1970)"
        try? memory.store(key: key, content: text,
                          category: "daily", sessionID: nil, source: source, mediaURL: mediaURL)
        await refreshJournals()
        return key
    }

    /// Upsert an existing journal entry's content, preserving its provenance
    /// (source / media_url / category / sessionID). Used to fill in a transcript
    /// after the entry was auto-saved with a placeholder. Returns true when the
    /// row was persisted — callers (drain / re-transcribe) only treat the work
    /// as done, e.g. removing the pending queue item, after a successful store.
    @discardableResult
    func storeJournalUpdate(key: String, content: String) async -> Bool {
        guard let existing = try? memory.get(key: key) else { return false }
        do {
            try memory.store(key: key, content: content, category: existing.category,
                             sessionID: existing.sessionID, source: existing.source, mediaURL: existing.mediaURL)
        } catch {
            return false
        }
        await refreshJournals()
        return true
    }

    /// Generate an AI title for a journal and replace its first line (the
    /// title). Best-effort: on failure the existing title is left untouched.
    /// Marks `key` in pendingTitleKeys while running so the row shows a spinner.
    func generateTitleForJournal(key: String, transcript: String) async {
        let trimmed = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            pendingTitleKeys.remove(key)
            return
        }
        // Ensure the on-device model is active before asking it for a title.
        guard anyLLMAvailable else { return }
        pendingTitleKeys.insert(key)
        defer { pendingTitleKeys.remove(key) }
        guard let title = try? await aiTitle(transcript: trimmed),
              !title.isEmpty else { return }
        // Replace the first line (title) of the entry, keep the rest (body).
        guard let existing = try? memory.get(key: key) else { return }
        let lines = existing.content.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let body = lines.dropFirst().joined(separator: "\n")
        let newContent = body.isEmpty ? title : "\(title)\n\(body)"
        try? memory.store(key: key, content: newContent, category: existing.category,
                          sessionID: existing.sessionID, source: existing.source, mediaURL: existing.mediaURL)
        await refreshJournals()
    }

    /// Shared placeholder body stored when an audio journal is saved before its
    /// transcript has landed. The journal row shows a spinner while the content
    /// equals this; the background drain (or a late final) replaces it.
    /// nonisolated so it's callable from free helpers (journalTitleOf etc.).
    nonisolated static let transcribingPlaceholder = "🎙 Audio journal — transcribing…"

    /// True iff an entry's content is the transcribing placeholder (a journal
    /// saved before its transcript landed). Drives the per-row loader.
    /// nonisolated so it's callable from free helpers (journalTitleOf etc.).
    nonisolated static func isTranscribingPlaceholder(_ content: String?) -> Bool {
        guard let content else { return false }
        return content.trimmingCharacters(in: .whitespacesAndNewlines) == transcribingPlaceholder
    }

    // MARK: - Pending transcription queue

    /// A journal saved before its transcript landed, awaiting on-device
    /// transcription. Persisted to disk so it survives the app being killed
    /// and is drained by a background task or on next launch.
    struct PendingTranscription: Codable, Equatable {
        let key: String
        let mediaPath: String
        /// If true, generate an AI title from the transcript after it lands
        /// and replace the entry's title line.
        var generateTitle: Bool = false
        /// Optional for backward-compatible decoding of queues written by
        /// earlier builds. Failures retry forever with a capped backoff.
        var attemptCount: Int? = nil
        var nextAttemptAt: Date? = nil
    }

    /// File URL of the on-disk pending-transcription queue (Documents).
    static var pendingTranscriptionsURL: URL? {
        guard let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else {
            return nil
        }
        return docs.appendingPathComponent("pending_transcriptions.json")
    }

    /// Add a journal to the pending-transcription queue (persisted to disk).
    /// Called by auto-save for EVERY recording (the on-disk file is the source
    /// of truth for its transcript — the live preview can be partial) and by
    /// the voice-memo importer after its durable store. The queue is drained
    /// by drainPendingTranscriptions() (launch / foreground / BGTask),
    /// newest-first.
    /// Returns true ONLY when the queue file was atomically rewritten — the
    /// durable-handoff contract for callers that promise crash-safe intent.
    /// Drain behavior is unchanged: the BG safety net is scheduled first,
    /// then a foreground drain is attempted either way.
    @discardableResult
    func enqueuePendingTranscription(key: String, mediaPath: String,
                                      generateTitleAfter: Bool = false) async -> Bool {
        guard let url = Self.pendingTranscriptionsURL else { return false }
        var items = Self.loadPendingTranscriptions(at: url)
        let entry = PendingTranscription(key: key, mediaPath: mediaPath,
                                         generateTitle: generateTitleAfter,
                                         attemptCount: 0, nextAttemptAt: nil)
        // Replace any existing entry for the same key so the flag stays fresh.
        items.removeAll { $0.key == key }
        items.append(entry)
        let persisted = Self.savePendingTranscriptions(items, at: url)
        // Schedule the BG safety net FIRST: if the foreground drain below is
        // interrupted (suspension, crash, task expiration), iOS already has a
        // request to finish the remaining items later.
        await scheduleNextBackgroundTranscription()
        // Try to drain immediately (foreground) — usually the asset is warm and
        // the transcript lands within a couple seconds.
        await drainPendingTranscriptions()
        return persisted
    }

    /// Transcribe queued journals one at a time, updating each entry's content
    /// and removing it from the queue as it completes. Newest eligible item
    /// first. Empty/failed recognition stays queued with capped exponential
    /// backoff, so old and imported audio heals without a manual tap. A manual
    /// Re-transcribe remains available for immediate retries. Single-flight —
    /// concurrent callers (launch, foreground,
    /// importer) no-op while a drain is already running. The loop RE-LOADS the
    /// queue file every iteration, so items enqueued while a drain is in
    /// progress are picked up instead of waiting for the next one.
    func drainPendingTranscriptions() async {
        guard let url = Self.pendingTranscriptionsURL else { return }
        guard !transcriptionDrainInFlight else { return }
        transcriptionDrainInFlight = true
        defer { transcriptionDrainInFlight = false }
        // Keys already processed in this drain (loop-break guard, above).
        var handledKeys = Set<String>()

        while !Task.isCancelled {
            let now = Date()
            let snapshot = Self.loadPendingTranscriptions(at: url)
                .filter {
                    !handledKeys.contains($0.key) &&
                    ($0.nextAttemptAt.map { $0 <= now } ?? true)
                }
            guard let newest = snapshot.max(by: { Self.pendingAgeKey($0, memory: memory) < Self.pendingAgeKey($1, memory: memory) })
            else { break }
            // Track handled keys locally: if a queue-file write ever fails
            // silently (try?), the item can't loop back into THIS drain and
            // re-transcribe forever; the next launch's drain retries it.

            guard let absURL = AudioRecorder.absoluteURL(forMediaRelativePath: newest.mediaPath),
                  FileManager.default.fileExists(atPath: absURL.path) else {
                // File gone — drop the pending entry so it doesn't wedge.
                handledKeys.insert(newest.key)
                Self.removeFromPendingQueue(key: newest.key, at: url)
                continue
            }

            let transcript = await performAudioTranscription(
                url: absURL, context: .automatic,
                keepAliveWhileLocked: lockedPhoneExperiment)
            let trimmedTranscript = transcript.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmedTranscript.isEmpty {
                // Never clobber meaningful stored content. Placeholder/marker
                // rows stay queued and retry automatically with a capped
                // backoff; keep the visible body in the transcribing state.
                handledKeys.insert(newest.key)
                let existing = try? memory.get(key: newest.key)
                let titleLine = existing.flatMap { e in
                    e.content.split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init)
                } ?? "New Recording"
                let storedBody = existing.map { journalBodyOf($0.content) } ?? ""
                if AppState.hasMeaningfulBody(storedBody) {
                    // Real content already persisted, so this queued copy is
                    // obsolete and can be removed safely.
                    Self.removeFromPendingQueue(key: newest.key, at: url)
                } else {
                    _ = await storeJournalUpdate(
                        key: newest.key,
                        content: "\(titleLine)\n\n\(Self.transcribingPlaceholder)")
                    Self.deferPendingTranscriptionRetry(newest, at: url)
                }
                continue
            }
            // A real transcript landed: preserve the existing title (first
            // line); replace the body.
            let existing = try? memory.get(key: newest.key)
            let titleLine = existing.flatMap { e in
                e.content.split(separator: "\n", omittingEmptySubsequences: true).first.map(String.init)
            } ?? "New Recording"
            let newContent = "\(titleLine)\n\n\(trimmedTranscript)"
            // Everything after the store depends on it succeeding: the queue
            // item is removed only on success (it stays queued for a retry on
            // failure), and the follow-up AI title never runs on un-persisted
            // content.
            let stored = await storeJournalUpdate(key: newest.key, content: newContent)
            if stored {
                Self.removeFromPendingQueue(key: newest.key, at: url)
                if newest.generateTitle {
                    await generateTitleForJournal(key: newest.key, transcript: trimmedTranscript)
                }
            }
            handledKeys.insert(newest.key)
        }
        await scheduleNextBackgroundTranscription()
    }

    /// True while a transcription drain is running (single-flight guard).
    private var transcriptionDrainInFlight = false

    /// Sort key placing NEWEST pending items first: prefer the journal's
    /// stored RFC3339 timestamp, fall back to the epoch embedded in the key.
    /// Keys are `journal_<epoch>` (optionally `journal_<epoch>_vm`), so ONLY
    /// the numeric component right after `journal_` is parsed — concatenating
    /// every digit in the key would mash a `_vm` suffix (or any UUID-ish
    /// remainder) into the epoch and corrupt the ordering. Unknown key shapes
    /// sort oldest.
    private static func pendingAgeKey(_ entry: PendingTranscription, memory: SlowClawSqliteMemory) -> Double {
        if let existing = try? memory.get(key: entry.key),
           let date = ISO8601DateFormatter().date(from: existing.timestamp) {
            return date.timeIntervalSince1970
        }
        guard entry.key.hasPrefix("journal_") else { return 0 }
        let afterPrefix = entry.key.dropFirst("journal_".count)
        let epochDigits = afterPrefix.prefix { $0.isNumber }
        return Double(UInt64(String(epochDigits)) ?? 0)
    }

    /// Remove one key from the on-disk pending queue (keeps items added
    /// concurrently by other writers).
    private static func removeFromPendingQueue(key: String, at url: URL) {
        let remaining = loadPendingTranscriptions(at: url).filter { $0.key != key }
        savePendingTranscriptions(remaining, at: url)
    }

    /// Checkpoint an automatic retry without losing items appended by another
    /// writer. Delays: 1m, 5m, 30m, 2h, 12h, then daily until success.
    private static func deferPendingTranscriptionRetry(
        _ entry: PendingTranscription,
        at url: URL
    ) {
        var items = loadPendingTranscriptions(at: url)
        guard let index = items.firstIndex(where: { $0.key == entry.key }) else { return }
        let attempt = min((entry.attemptCount ?? 0) + 1, 100_000)
        let delays: [TimeInterval] = [60, 300, 1_800, 7_200, 43_200, 86_400]
        items[index].attemptCount = attempt
        items[index].nextAttemptAt = Date(timeIntervalSinceNow: delays[min(attempt - 1, delays.count - 1)])
        savePendingTranscriptions(items, at: url)
    }

    /// Manually re-transcribe an audio journal from its file, replacing the
    /// entry's body (title line preserved). This is the retry path for
    /// truncated or missing transcripts — the JournalDetailView exposes a
    /// Re-transcribe button that calls this, so a new build's engine can be
    /// re-checked against audio that previously transcribed badly. It is also
    /// also lets the user bypass the automatic retry backoff immediately.
    /// Uses Apple's whole-file, on-device SpeechAnalyzer path. Returns the entry's
    /// full new content, or "" when there is no audio file, recognition came
    /// back empty, the entry row is gone, or the store failed — in every
    /// failure case the existing content is left untouched (never
    /// overwritten).
    func retranscribeJournal(_ entry: SlowClawMemoryEntry) async -> String {
        guard let rel = entry.mediaURL, !rel.isEmpty,
              let url = AudioRecorder.absoluteURL(forMediaRelativePath: rel),
              FileManager.default.fileExists(atPath: url.path) else {
            lastTranscriptionStatus = "Audio file is missing."
            return ""
        }
        lastTranscriptionStatus = "Starting Apple's long-form on-device transcription…"
        let transcript = await performAudioTranscription(
            url: url, context: .retranscribe, keepAliveWhileLocked: false)
        lastTranscriptionStatus = "\(transcript.engine.rawValue): \(transcript.diagnostic ?? "finished")"
        // Data safety: an empty/failed recognition must never overwrite the
        // existing transcript. Bail out so the caller can surface the failure.
        let trimmed = transcript.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        // Reload the latest row by key: the in-memory snapshot can be stale
        // (the user may have renamed or edited since the view was opened), so
        // the preserved title and the body being replaced must come from the
        // current store, not the snapshot.
        guard let latest = try? memory.get(key: entry.key) else { return "" }
        let titleLine = latest.content
            .split(separator: "\n", omittingEmptySubsequences: true)
            .first.map(String.init) ?? journalTitleOf(entry)
        let newContent = "\(titleLine)\n\n\(trimmed)"
        // Same shape the drain path writes. Only report success after the
        // store actually persisted.
        guard await storeJournalUpdate(key: entry.key, content: newContent) else { return "" }
        if let queueURL = Self.pendingTranscriptionsURL {
            Self.removeFromPendingQueue(key: entry.key, at: queueURL)
        }
        return newContent
    }

    /// Single AppState funnel for whole-file Apple Speech transcription.
    private func performAudioTranscription(
        url: URL,
        context: AudioSTTContext,
        keepAliveWhileLocked: Bool
    ) async -> AudioSTTResult {
        audioTranscriptionCount += 1
        audioTranscriptionInFlight = true
        defer {
            audioTranscriptionCount -= 1
            audioTranscriptionInFlight = audioTranscriptionCount > 0
            if audioTranscriptionCount == 0 { audioTranscriptionProgress = nil }
        }
        let report: @Sendable (String) -> Void = { [weak self] message in
            Task { @MainActor [weak self] in
                self?.audioTranscriptionProgress = message
            }
        }
        if keepAliveWhileLocked {
            return await Task.detached(priority: .userInitiated) {
                await LockedPhoneExperiment.run(url: url, progress: report)
            }.value
        }
        return await Task.detached(priority: .userInitiated) {
            await AudioSTT.transcribe(url: url, context: context, progress: report)
        }.value
    }

    // MARK: - Missing-transcript reconciliation

    /// Scan journals for audio entries whose transcript never landed — an
    /// empty body, the transcribing placeholder, or a title-only body — and
    /// (re-)queue them for transcription. This is the guarantee that every
    /// audio the app owns eventually gets a transcript: anything that fell
    /// out of the in-memory queue (import interrupted by suspension, a
    /// crashed drain, or an older build's no-transcript marker) is rediscovered
    /// here and retried. Throttled to at most once per minute per app session.
    func reconcileMissingTranscripts() async {
        let now = Date()
        if let last = lastTranscriptReconcileAt,
           now.timeIntervalSince(last) < 60 { return }
        lastTranscriptReconcileAt = now

        let candidates = journals.filter { entry in
            guard let media = entry.mediaURL, !media.isEmpty,
                  let abs = AudioRecorder.absoluteURL(forMediaRelativePath: media),
                  FileManager.default.fileExists(atPath: abs.path) else { return false }
            return Self.needsTranscript(entry.content)
        }
        guard !candidates.isEmpty, let url = Self.pendingTranscriptionsURL else { return }

        var items = Self.loadPendingTranscriptions(at: url)
        let known = Set(items.map(\.key))
        var added = false
        for c in candidates where !known.contains(c.key) {
            items.append(PendingTranscription(key: c.key, mediaPath: c.mediaURL ?? "", generateTitle: false))
            added = true
        }
        if added { Self.savePendingTranscriptions(items, at: url) }
        await drainPendingTranscriptions()
    }

    private var lastTranscriptReconcileAt: Date? = nil

    /// True when a journal's body still awaits its transcript: an empty body
    /// or the transcribing placeholder. Legacy no-transcript markers are also
    /// candidates so installing this build automatically heals older audio.
    nonisolated static func needsTranscript(_ content: String?) -> Bool {
        guard let content else { return false }
        let lines = content
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard lines.count > 1 else { return true } // title-only (or empty)
        let body = lines.dropFirst().joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return body.isEmpty || body == transcribingPlaceholder
            || body == "🎙 Audio journal (no transcript)"
            || body == "🎙 Imported audio (no transcript)"
    }

    /// True when a stored body is meaningful content — non-empty and not one
    /// of the placeholder / no-transcript markers. The pending drain uses it
    /// to decide whether an empty recognition result can safely leave the row
    /// untouched (content already exists) or should record the no-transcript
    /// marker instead.
    nonisolated static func hasMeaningfulBody(_ body: String) -> Bool {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return trimmed != transcribingPlaceholder
            && trimmed != "🎙 Audio journal (no transcript)"
            && trimmed != "🎙 Imported audio (no transcript)"
    }

    /// Load the pending-transcription queue from disk (empty on any error).
    static func loadPendingTranscriptions(at url: URL) -> [PendingTranscription] {
        guard let data = try? Data(contentsOf: url),
              let items = try? JSONDecoder().decode([PendingTranscription].self, from: data) else {
            return []
        }
        return items
    }

    /// Persist the pending-transcription queue to disk (atomic). Returns true
    /// ONLY when the write succeeded — the on-disk file is the crash-safety
    /// source of truth, so callers handing off durable intent (importer,
    /// auto-save) can prove the entry survived. A false return means the
    /// on-disk queue is stale until the next successful save.
    @discardableResult
    static func savePendingTranscriptions(_ items: [PendingTranscription], at url: URL) -> Bool {
        guard let data = try? JSONEncoder().encode(items) else { return false }
        do {
            try data.write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    /// Background-processing task identifier (must match
    /// BGTaskSchedulerPermittedIdentifiers in Info.plist). Registered in
    /// ShareURLDelegate at launch.
    static let backgroundTranscriptionTaskID = "com.slowclaw.app.transcription"

    /// Submit a BGProcessingRequest so iOS drains the pending-transcription
    /// queue later (best-effort, OS-gated). Called after a drain that left
    /// items behind, and at app launch. No-ops when the queue is empty.
    func scheduleNextBackgroundTranscription() async {
        guard let url = Self.pendingTranscriptionsURL else { return }
        let remaining = Self.loadPendingTranscriptions(at: url)
        guard !remaining.isEmpty else { return }
        let request = BGProcessingTaskRequest(identifier: Self.backgroundTranscriptionTaskID)
        request.requiresNetworkConnectivity = false
        request.requiresExternalPower = false
        let earliestRetry = remaining.map { $0.nextAttemptAt ?? Date() }.min() ?? Date()
        request.earliestBeginDate = Date(
            timeIntervalSinceNow: max(60, earliestRetry.timeIntervalSinceNow))
        try? BGTaskScheduler.shared.submit(request)
    }

    /// Launch-time drain + reschedule. Called once from the App's onAppear so
    /// any pending transcriptions left from a killed-app session are resolved
    /// promptly when the user returns.
    func resumePendingTranscriptionsOnLaunch() async {
        await drainPendingTranscriptions()
        await scheduleNextBackgroundTranscription()
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

    /// Start generation independently of the currently visible tab. Repeated
    /// taps join the existing single flight instead of starting another model
    /// request.
    func startTweetClawGeneration() {
        guard postGenerationTask == nil, !BlogClaw.shared.running else { return }
        postGenerationTask = Task { [weak self] in
            guard let self else { return }
            await self.tweetClawGenerateNext()
            self.postGenerationTask = nil
        }
    }

    /// Pull-to-generate: pick the most-recently-modified unprocessed text journal
    /// (or a random one if all are processed) and turn it into one or more posts.
    /// Long entries are chunked at ~3200 chars; each chunk produces its own post.
    /// Mirrors the reference app's handleFeedPullRefresh / generatePostFromJournal.
    func tweetClawGenerateNext() async {
        isGeneratingPosts = true
        generateStatus = "Preparing your writing space…"
        defer { isGeneratingPosts = false }
        await ensureLocalModelActivated()
        guard anyLLMAvailable else {
            generateStatus = "Add an LLM API key in Profile, or activate an on-device model, to generate posts."
            return
        }
        guard !journals.isEmpty else {
            generateStatus = "Write a journal entry first."
            return
        }
        generateStatus = "Generating…"

        // Pick the next journal to process.
        var processed = processedJournalKeys
        let candidates = journals.filter {
            $0.content.count > 20 && !($0.mediaURL != nil && Self.needsTranscript($0.content))
        }
        let unprocessed = candidates.filter { !processed.contains($0.key) }
        let journal = (unprocessed.first ?? candidates.randomElement())
        guard let journal = journal else {
            generateStatus = "No journal entries to process."
            return
        }

        let prompt = self.tweetClawPrompt
        // Snapshot the 10 most-recent existing draft texts to discourage repeats.
        let recentDrafts = drafts.prefix(10).map { $0.content }

        // llama.cpp is single-model/single-context. Generate chunks in order
        // instead of spawning several tasks that only wait on the same model
        // mutex and compete with SwiftUI for CPU time.
        var savedCount = 0
        for chunk in DraftBudget.chunks(journal.content, limit: 1800).prefix(3) {
            var message = chunk
            if !recentDrafts.isEmpty {
                let dedupe = String(recentDrafts.prefix(2).joined(separator: "\n---\n").prefix(500))
                message += "\n\n(Avoid repeating these posts you already wrote:)\n\(dedupe)"
            }
            // chat() honors the editable TweetClaw prompt as the system prompt.
            if let post = try? await aiChat(system: prompt, message: message, temperature: 0.8) {
                let cleaned = post.trimmingCharacters(in: .whitespacesAndNewlines)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\"'`"))
                // Acceptance gate: 11–399 chars (matches the reference).
                guard cleaned.count > 10, cleaned.count < 400 else { continue }
                let key = "draft_\(Date().timeIntervalSince1970)_\(UInt.random(in: 0..<1_000_000))"
                do {
                    try memory.store(key: key, content: cleaned, category: "core", sessionID: "drafts")
                    savedCount += 1
                } catch { generateStatus = "Could not save the draft. Please try again." }
            }
        }

        if savedCount > 0 {
            processed.insert(journal.key)
            processedJournalKeys = processed
        }
        await refreshJournals()
        generateStatus = savedCount > 0 ? "\(savedCount) draft\(savedCount == 1 ? "" : "s") saved for review." : "The model did not produce a usable short post. Try a shorter journal or adjust the prompt in Profile."
    }

    /// Split long text into chunks for per-chunk post generation. Mirrors the
    /// reference's CHUNK_CHAR_LIMIT + splitIntoChunks (paragraph boundaries).
    private func chunkForPosts(_ text: String, limit: Int) -> [String] {
        DraftBudget.chunks(text, limit: limit)
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
    @Environment(\.scenePhase) private var scenePhase
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
        // In-app browser for ALL web links (Reads cards, article viewers) —
        // presented above every tab, never an external Safari jump.
        .sheet(item: $state.activeWebLink, onDismiss: { state.finishReading() }) { _ in
            InAppBrowserSheet()
        }
        .task {
            // Retry durable pending audio while the user keeps using the app;
            // nextAttemptAt preserves backoff instead of waiting for relaunch.
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(15)) } catch { break }
                if scenePhase == .active {
                    await state.drainPendingTranscriptions()
                }
            }
        }
        // Voice-memo imports auto-store (transcribe on-device → journal entry),
        // matching the reference app — no review gate. The sidebar shows
        // progress via voiceMemoImporter.status while the serial worker runs.
        // Re-activate the on-device model when returning to the foreground (the
        // OS may have reclaimed it), so AI is ready whenever the app is open.
        .onChange(of: scenePhase) { _, phase in
            state.readingActivityChanged(active: phase == .active)
            if phase == .active {
                // Foregrounding must never wait for the inference mutex.
                // Foreground is the retry point for audio that lost its
                // transcript (suspension, crash, failed engine) — reconcile
                // throttled to once a minute.
                Task {
                    await state.reconcileMissingTranscripts()
                    await state.scheduleNextBackgroundTranscription()
                }
            }
        }
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
                    VStack(spacing: 4) {
                    Image(systemName: tab.icon)
                        .font(.system(size: 22, weight: .regular))
                        .scaleEffect(active ? 1.1 : 1.0)
                    Text(tab.label).font(.system(size: 10, weight: active ? .semibold : .regular))
                    }
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

/// First non-empty line of the entry = its display title. A lone transcribing
/// placeholder (no user title) shows "New Recording" (Voice Memos style).
func journalTitleOf(_ entry: SlowClawMemoryEntry) -> String {
    let lines = entry.content.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
    let first = lines.first ?? entry.content
    let title = first.trimmingCharacters(in: .whitespaces)
    // Placeholder-only entry (no user title) → Voice-Memos-style default.
    if AppState.isTranscribingPlaceholder(title) {
        return "New Recording"
    }
    return title.isEmpty ? "Untitled" : title
}

/// Body text under a stored entry's title line. Consumes the title line and
/// the blank separator line(s) immediately after it — without leaving a
/// synthetic leading blank line for normal "title\n\nbody" content — while
/// preserving body paragraphs verbatim. Shared by the journal editor and the
/// pending-transcription drain.
func journalBodyOf(_ content: String) -> String {
    var lines = content.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    guard !lines.isEmpty else { return "" }
    lines.removeFirst() // the title line
    while let first = lines.first, first.trimmingCharacters(in: .whitespaces).isEmpty {
        lines.removeFirst()
    }
    return lines.joined(separator: "\n")
}

/// Resolve a journal entry's creation Date. Tries, in order: the `timestamp`
/// field as ISO8601/RFC3339 (lenient — with and without fractional seconds),
/// then the epoch embedded in the `key` (e.g. `journal_<epoch>`). Returns nil
/// only if none parse. The old code fell back to `entry.id`, which is a UUID
/// (not epoch) and silently produced Jan 1, 1970 — hence the "Jan 1" bug.
func journalDate(_ entry: SlowClawMemoryEntry) -> Date? {
    // 1) ISO8601 / RFC3339 from the timestamp column.
    let iso = ISO8601DateFormatter()
    iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if !entry.timestamp.isEmpty, let d = iso.date(from: entry.timestamp) { return d }
    iso.formatOptions = [.withInternetDateTime]
    if !entry.timestamp.isEmpty, let d = iso.date(from: entry.timestamp) { return d }
    // 2) Epoch from the key ("journal_<epoch>" or "draft_<epoch>...").
    let prefix = entry.key.split(separator: "_").first.map(String.init) ?? ""
    let rest = entry.key.hasPrefix(prefix + "_")
        ? String(entry.key.dropFirst(prefix.count + 1))
        : entry.key
    // The draft key can have a trailing "_<rand>"; take the leading numeric run.
    let numeric = rest.split(separator: "_").first.map(String.init) ?? rest
    if let secs = TimeInterval(numeric), secs > 0 {
        return Date(timeIntervalSince1970: secs)
    }
    return nil
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
    @State private var isRetranscribing = false
    @State private var showRetranscribeFailedAlert = false
    @State private var showSaveErrorAlert = false
    @State private var showDeleteConfirmation = false
    /// Last successfully persisted title/body — the baseline the combined
    /// save compares against and updates after each successful store, so a
    /// no-change open→back (or a repeated back) can never overwrite content
    /// a background transcription persisted after this view was opened.
    @State private var savedTitle: String
    @State private var savedBody: String

    /// Absolute URL of the recording, if this entry has a linked audio file.
    /// Treat any entry with a non-empty mediaURL as playable (don't require a
    /// specific source string — older entries or imports may carry a path
    /// without a matching source tag). The player is gated on file existence
    /// at render time so a stale path just hides the player rather than erroring.
    private var audioURL: URL? {
        guard let rel = entry.mediaURL, !rel.isEmpty else { return nil }
        return AudioRecorder.absoluteURL(forMediaRelativePath: rel)
    }

    /// True when this entry has a linked audio file on disk — gates the
    /// Re-transcribe button (the manual retry for truncated transcripts).
    private var hasAudioFile: Bool {
        guard let url = audioURL else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }

    init(entry: SlowClawMemoryEntry) {
        self.entry = entry
        // Title and body are SEPARATE state: `titleDraft` owns the title,
        // `editedBody` owns only the body text under it. The stored row keeps
        // the "title\nbody" shape; every save merges the two at field
        // granularity (persistCombined), so a title edit can never stomp body
        // edits and vice versa. savedTitle/savedBody start at what the row
        // actually contains.
        _editedBody = State(initialValue: journalBodyOf(entry.content))
        _titleDraft = State(initialValue: journalTitleOf(entry))
        _savedTitle = State(initialValue: journalTitleOf(entry))
        _savedBody = State(initialValue: journalBodyOf(entry.content)
            .trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// First line (the title) of a stored "title\nbody" row.
    private static func titleLine(of content: String) -> String {
        content.split(separator: "\n", omittingEmptySubsequences: false)
            .first.map(String.init) ?? content
    }

    /// The working title for display. `titleDraft` is the single title state —
    /// journalTitleOf(entry) would show the stale entry snapshot after a
    /// rename or a concurrent title change.
    private var displayTitle: String {
        let trimmed = titleDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "Untitled" : trimmed
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
                            .disabled(isRetranscribing)
                            .onSubmit { commitTitle() }
                    } else {
                        Button {
                            isEditingTitle = true
                            // titleDraft is the single title state — don't
                            // re-seed it from the stale `entry` snapshot.
                        } label: {
                            HStack {
                                Text(displayTitle)
                                    .font(DS.titleFont)
                                    .foregroundStyle(DS.ink(scheme))
                                    .multilineTextAlignment(.leading)
                                Spacer()
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(isRetranscribing)
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
                                if hasAudioFile {
                                    Button {
                                        Task { await retranscribe() }
                                    } label: {
                                        if isRetranscribing {
                                            HStack(spacing: 5) {
                                                ProgressView()
                                                    .controlSize(.small)
                                                Text("Transcribing…")
                                            }
                                            .font(DS.captionFont.weight(.semibold))
                                        } else {
                                            Label("Re-transcribe", systemImage: "arrow.clockwise")
                                                .font(DS.captionFont.weight(.semibold))
                                        }
                                    }
                                    .buttonStyle(.plain)
                                    .tint(DS.accentColor)
                                    .disabled(isRetranscribing)
                                }
                                if state.llm != nil {
                                    Button {
                                        Task { await polish() }
                                    } label: {
                                        Label("Polish", systemImage: "sparkles")
                                            .font(DS.captionFont.weight(.semibold))
                                    }
                                    .buttonStyle(.plain)
                                    .tint(DS.accentColor)
                                    .disabled(isPolishing || isRetranscribing)
                                }
                            }
                            TextEditor(text: $editedBody)
                                .frame(minHeight: 180)
                                .scrollContentBackground(.hidden)
                                .font(DS.bodyFont)
                                .foregroundStyle(DS.ink(scheme))
                                // Editing is locked while a re-transcription is
                                // in flight so it can't replace user edits
                                // mid-write (the fresh transcript syncs the
                                // editor on success instead).
                                .disabled(isRetranscribing)
                                .onChange(of: editedBody) { scheduleBodyAutosave() }
                            if let status = state.lastTranscriptionStatus {
                                Text(status)
                                    .font(DS.microFont)
                                    .foregroundStyle(status.contains("failed")
                                                     || status.contains("no transcript")
                                                     ? DS.accent2Color
                                                     : DS.muted(scheme))
                            }
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
                        // Cancel the debounced autosave so the final save
                        // happens exactly once, combining the latest title +
                        // body (no stale title/body double-commit race).
                        bodyAutosaveTask?.cancel()
                        // Dismiss only after the save persisted; on failure the
                        // save-error alert keeps the view open with edits intact.
                        if persistCombined() {
                            dismiss()
                        }
                    } label: {
                        Image(systemName: "chevron.left")
                            .font(.system(size: 16, weight: .semibold))
                    }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    if let url = audioURL {
                        ShareLink(item: url) {
                            Image(systemName: "square.and.arrow.up")
                        }
                        .accessibilityLabel("Share recording")
                    }
                    Button(role: .destructive) {
                        showDeleteConfirmation = true
                    } label: {
                        Image(systemName: "trash")
                    }
                    .accessibilityLabel("Delete journal")
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
        .alert("Re-transcription failed", isPresented: $showRetranscribeFailedAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(state.lastTranscriptionStatus
                 ?? "No speech was recognized. Your transcript was left unchanged.")
        }
        .alert("Couldn't save", isPresented: $showSaveErrorAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Your changes could not be saved. The entry stays open — try again.")
        }
        .alert("Move to Recently Deleted?", isPresented: $showDeleteConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                bodyAutosaveTask?.cancel()
                pollTimer?.invalidate()
                player?.stop()
                state.softDelete(key: entry.key)
                dismiss()
            }
        } message: {
            Text(audioURL == nil
                 ? "This journal can be restored for 30 days."
                 : "The audio and transcript can be restored for 30 days.")
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
            await MainActor.run { _ = persistCombined() }
        }
    }

    /// The SINGLE save path for the editor. Reloads the LATEST stored row and
    /// merges at field granularity: a field the user changed locally (working
    /// value ≠ saved baseline) overwrites the row; an untouched field keeps
    /// whatever is currently stored — so a title-only edit can never clobber
    /// a background transcript that landed after this view opened, and vice
    /// versa. Upserts with the latest row's provenance. After a successful
    /// store, working state and saved baselines sync to the merged persisted
    /// content. Returns true when the row persisted (or there was nothing to
    /// change); on a store failure it surfaces the save-error alert and
    /// returns false — errors are never swallowed.
    @discardableResult
    private func persistCombined() -> Bool {
        let title = titleDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = editedBody.trimmingCharacters(in: .whitespacesAndNewlines)
        // Working values still match the last successful save → no-op. The
        // comparison is against the SAVED baseline (never the entry snapshot),
        // so open→back and repeated backs are safe and never touch the row.
        guard title != savedTitle || body != savedBody else { return true }
        // Nothing at all to store → no-op, never wipe the row to empty.
        guard !title.isEmpty || !body.isEmpty else { return true }

        // Latest stored row: locally-untouched fields merge from here, and
        // its provenance is preserved on the upsert. Falls back to the entry
        // snapshot when the row can't be read.
        let latest = try? state.memory.get(key: entry.key)
        let storedTitle = latest.map {
            Self.titleLine(of: $0.content).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let storedBody = latest.map {
            journalBodyOf($0.content).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        // Field-granular merge: only fields the user actually changed locally
        // take the working value; untouched fields keep the stored value.
        let mergedTitle = title != savedTitle ? title : (storedTitle ?? title)
        let mergedBody = body != savedBody ? body : (storedBody ?? body)
        let mergedContent: String
        if mergedTitle.isEmpty {
            mergedContent = mergedBody
        } else if mergedBody.isEmpty {
            mergedContent = mergedTitle
        } else {
            mergedContent = "\(mergedTitle)\n\(mergedBody)"
        }
        do {
            try state.memory.store(key: entry.key, content: mergedContent,
                                   category: latest?.category ?? entry.category,
                                   sessionID: latest?.sessionID ?? entry.sessionID,
                                   source: latest?.source ?? entry.source,
                                   mediaURL: latest?.mediaURL ?? entry.mediaURL)
        } catch {
            showSaveErrorAlert = true
            return false
        }
        // Working state + baselines sync to exactly what was persisted. (The
        // editor change triggers an autosave pass that no-ops: values now
        // equal the baselines.)
        titleDraft = mergedTitle
        editedBody = mergedBody
        savedTitle = mergedTitle
        savedBody = mergedBody
        Task { await state.refreshJournals() }
        return true
    }

    /// Commit the title field (onSubmit). The save itself is the shared
    /// combined path — it stores titleDraft + current body in one write.
    private func commitTitle() {
        guard isEditingTitle else { return }
        isEditingTitle = false
        persistCombined()
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

    /// Re-run on-device transcription of this entry's audio file and replace
    /// the transcript body in place (title preserved). The manual retry path
    /// for truncated/incomplete transcripts — lets each new build's engine be
    /// re-checked against the same audio. Editing (body/title/polish) is
    /// locked while it runs so user edits can't be silently replaced; on an
    /// empty/failed recognition the stored content is untouched and a concise
    /// alert is shown; on success the editor syncs to the fresh transcript.
    private func retranscribe() async {
        guard hasAudioFile, !isRetranscribing else { return }
        // Flush any pending body autosave first so the latest stored row —
        // which retranscribeJournal reloads by key — includes the user's
        // edits before the transcript body is replaced. If the flush cannot
        // persist, ABORT before transcribing: running it would silently
        // replace unsaved edits. (persistCombined already showed the
        // save-error alert and kept the view editable.)
        bodyAutosaveTask?.cancel()
        guard persistCombined() else { return }
        isRetranscribing = true
        defer { isRetranscribing = false }
        let newContent = await state.retranscribeJournal(entry)
        guard !newContent.isEmpty else {
            showRetranscribeFailedAlert = true
            return
        }
        // Sync the editor AND the saved baselines to exactly what is now
        // persisted. retranscribeJournal preserves the row's current title
        // (it may have changed while this view was open), so the title state
        // tracks the persisted value rather than the stale snapshot.
        let body = journalBodyOf(newContent)
        editedBody = body
        savedBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
        let persistedTitle = Self.titleLine(of: newContent)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !persistedTitle.isEmpty {
            // Match journalTitleOf's display semantics: a still-pending
            // placeholder title line shows as the default title, not raw text.
            let display = AppState.isTranscribingPlaceholder(persistedTitle)
                ? "New Recording" : persistedTitle
            titleDraft = display
            savedTitle = display
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
    // screen + the post-stop auto-save all share one state machine.
    @StateObject private var recorder = AudioRecorder()

    @State private var search = ""
    /// Selected list order. `newestFirst` is the Voice-Memos default.
    @State private var sortOrder: JournalSort = .newestFirst
    @State private var selectedDetail: SlowClawMemoryEntry?
    @State private var showCompose = false
    @State private var isSelectingAudio = false
    @State private var selectedAudioKeys = Set<String>()
    /// Best-effort audio durations by journal key, filled asynchronously from
    /// AVAudioFile header metadata (frame count ÷ sample rate — no PCM
    /// decode), so `body` never blocks on file I/O. A key is reserved with 0
    /// while its one-shot lookup runs; 0 renders as "no duration" and marks
    /// failures done (one read attempt per key per session).
    @State private var audioDurations: [String: TimeInterval] = [:]

    /// Deterministic sort orders for the journal list.
    enum JournalSort: Hashable {
        case newestFirst, oldestFirst, title
    }

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

    /// The journals actually shown: search filter composed with the selected
    /// deterministic sort. Every branch ends in a `key` tiebreak so equal
    /// timestamps/titles can't jitter between renders.
    private var visibleJournals: [SlowClawMemoryEntry] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        let base = q.isEmpty
            ? state.journals
            : state.journals.filter { $0.content.lowercased().contains(q) }
        switch sortOrder {
        case .newestFirst, .oldestFirst:
            // journalDate parses a formatter-backed timestamp; compute once
            // per entry instead of per comparison.
            let dated = base.map { ($0, journalDate($0) ?? .distantPast) }
            let newestFirst = sortOrder == .newestFirst
            return dated.sorted { lhs, rhs in
                if lhs.1 != rhs.1 { return newestFirst ? lhs.1 > rhs.1 : lhs.1 < rhs.1 }
                return newestFirst ? lhs.0.key > rhs.0.key : lhs.0.key < rhs.0.key
            }
            .map { $0.0 }
        case .title:
            return base.sorted { lhs, rhs in
                let cmp = journalTitleOf(lhs).localizedCaseInsensitiveCompare(journalTitleOf(rhs))
                if cmp != .orderedSame { return cmp == .orderedAscending }
                return lhs.key < rhs.key
            }
        }
    }

    private func audioURL(for entry: SlowClawMemoryEntry) -> URL? {
        guard entry.source?.hasPrefix("audio") == true,
              let relativePath = entry.mediaURL, !relativePath.isEmpty,
              let url = AudioRecorder.absoluteURL(forMediaRelativePath: relativePath),
              FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    private var selectableAudioKeys: Set<String> {
        Set(visibleJournals.compactMap { audioURL(for: $0) == nil ? nil : $0.key })
    }

    private var selectedAudioURLs: [URL] {
        visibleJournals.compactMap { entry in
            selectedAudioKeys.contains(entry.key) ? audioURL(for: entry) : nil
        }
    }

    /// Kick off the one-shot async duration read for an audio row. Cached
    /// (or already-reserved) keys no-op, so calling this on row appear is
    /// cheap. MainActor for the state read/reserve; the metadata read itself
    /// runs in a detached utility task and lands back via MainActor.run.
    @MainActor
    private func loadAudioDurationIfNeeded(_ entry: SlowClawMemoryEntry) {
        guard audioDurations[entry.key] == nil else { return }
        guard entry.source?.hasPrefix("audio") == true,
              let rel = entry.mediaURL, !rel.isEmpty,
              let url = AudioRecorder.absoluteURL(forMediaRelativePath: rel) else { return }
        audioDurations[entry.key] = 0 // reserve: one read per key per session
        Task.detached(priority: .utility) {
            let seconds = Self.audioDuration(fromFileAt: url) ?? 0
            await MainActor.run { audioDurations[entry.key] = seconds }
        }
    }

    /// Duration from AVAudioFile HEADER metadata only (frame count ÷ sample
    /// rate). The m4a frame count comes from the container atom, so this
    /// never decodes audio.
    private static func audioDuration(fromFileAt url: URL) -> TimeInterval? {
        guard let file = try? AVAudioFile(forReading: url),
              file.length > 0, file.processingFormat.sampleRate > 0 else { return nil }
        return Double(file.length) / file.processingFormat.sampleRate
    }

    /// Cached localized date/time formatter for row metadata (DateFormatter
    /// allocation is expensive; rows re-render often).
    private static let rowDateTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale.current
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    private static func localizedDateTime(_ date: Date) -> String {
        rowDateTimeFormatter.string(from: date)
    }

    var body: some View {
        Group {
            if recorder.isRecording || recorder.isPaused {
                // ── Recording zen screen (replaces the list while recording) ──
                recordingScreen
            } else {
                journalList
            }
        }
        .background(DS.bg(scheme))
        .task { await state.refreshJournals() }
        // Voice-Memos flow: the moment a recording finishes, auto-save the
        // journal with the transcript-so-far (or a "transcribing…" placeholder
        // when the live transcript produced nothing yet) and return to the
        // list. No review gate. The row shows a spinner until the transcript
        // lands; the user edits from the list afterward.
        .onChange(of: recorder.isRecording) { _, nowRecording in
            if !nowRecording, let url = recorder.recordedFileURL {
                autoSaveRecording(fileURL: url)
            }
        }
        .sheet(isPresented: $showCompose) {
            TextComposeSheet()
                .environmentObject(state)
        }
    }

    /// Auto-save a finished recording as a journal immediately (Voice Memos).
    /// The transcript-so-far is used if present; otherwise a placeholder is
    /// stored and the entry is enqueued for background transcription, so the
    /// row shows a spinner and fills in when the transcript lands. The
    /// "New Recording" default title is set; if AI is available an AI title is
    /// generated from the transcript (once it has landed) and replaces it.
    private func autoSaveRecording(fileURL: URL) {
        let mediaURL = AudioRecorder.documentsRelativePath(for: fileURL)
        let userTitle = recorder.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let transcript = recorder.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasTranscript = !transcript.isEmpty

        // Title: user-typed wins; otherwise a Voice-Memos-style date-time default.
        let title = userTitle.isEmpty ? Self.defaultRecordingTitle() : userTitle

        // Body = title on the first line, then transcript/placeholder.
        let body = hasTranscript
            ? "\(title)\n\n\(transcript)"
            : "\(title)\n\n\(AppState.transcribingPlaceholder)"

        // Snapshot recorder state before clearing it.
        let recordedURL = recorder.recordedFileURL

        Task {
            let key = await state.storeJournalNow(text: body,
                                                  source: "audio_recorded",
                                                  mediaURL: mediaURL)
            let shouldGenTitle = (userTitle.isEmpty && state.anyLLMAvailable)
            // A successfully finalized live SpeechAnalyzer session is the
            // Voice Memos-style source of truth: it already consumed the whole
            // recording as one continuous stream, so do not slice and
            // re-transcribe the saved file. Only failed/unavailable live
            // sessions enqueue the durable offline fallback.
            if !hasTranscript, let mediaPath = mediaURL, recordedURL != nil {
                await state.enqueuePendingTranscription(key: key, mediaPath: mediaPath,
                                                        generateTitleAfter: shouldGenTitle)
            } else if hasTranscript && shouldGenTitle {
                await state.generateTitleForJournal(key: key, transcript: transcript)
            }
            // Reset recorder state for the next recording.
            await MainActor.run {
                recorder.recordedFileURL = nil
                recorder.transcript = ""
                recorder.title = ""
            }
        }
    }

    /// Voice-Memos-style default recording title. Plain on purpose: the list
    /// row already shows the localized date/time next to the title, and the
    /// user renames from the detail view.
    private static func defaultRecordingTitle() -> String {
        "New Recording"
    }

    // MARK: - List

    private var journalList: some View {
        VStack(spacing: 0) {
            VStack(spacing: 8) {
                // Header: "Journals" + compact sort menu.
                HStack(alignment: .firstTextBaseline) {
                    Text("Journals")
                        .font(DS.titleFont)
                        .foregroundStyle(DS.ink(scheme))
                        .kerning(-0.4)
                    Spacer()
                    if !isSelectingAudio { sortMenu }
                    Button(isSelectingAudio ? "Done" : "Select") {
                        withAnimation(.easeInOut(duration: 0.18)) {
                            isSelectingAudio.toggle()
                            if !isSelectingAudio { selectedAudioKeys.removeAll() }
                        }
                    }
                    .font(DS.captionFont.weight(.semibold))
                    .foregroundStyle(DS.accentColor)
                    .disabled(!isSelectingAudio && selectableAudioKeys.isEmpty)
                }
                .padding(.horizontal, 16)

                // Search + import status (migrated from the sidebar).
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 13))
                        .foregroundStyle(DS.muted(scheme))
                    TextField("", text: $search, prompt: Text("Search journals").foregroundColor(DS.muted(scheme)))
                        .font(DS.bodyFont)
                        .textFieldStyle(.plain)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    if !search.isEmpty {
                        Button {
                            search = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .font(.system(size: 14))
                                .foregroundStyle(DS.muted(scheme))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Clear search")
                    }
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
            }
            .padding(.top, 10)

            // The list.
            if visibleJournals.isEmpty && search.isEmpty {
                emptyState
            } else {
                ScrollView {
                    LazyVStack(spacing: 2) {
                        if visibleJournals.isEmpty {
                            VStack(spacing: 8) {
                                Text("No journals match your search.")
                                    .font(DS.captionFont)
                                    .foregroundStyle(DS.muted(scheme))
                                Button("Clear Search") {
                                    search = ""
                                }
                                .font(DS.captionFont.weight(.semibold))
                                .tint(DS.accentColor)
                            }
                            .padding(.top, 40)
                        } else {
                            ForEach(visibleJournals, id: \.key) { entry in
                                // Semantic button: the whole row opens the
                                // detail (player + transcript + edit).
                                Button {
                                    if isSelectingAudio {
                                        guard audioURL(for: entry) != nil else { return }
                                        if selectedAudioKeys.contains(entry.key) {
                                            selectedAudioKeys.remove(entry.key)
                                        } else {
                                            selectedAudioKeys.insert(entry.key)
                                        }
                                    } else {
                                        selectedDetail = entry
                                    }
                                } label: {
                                    journalRow(entry)
                                }
                                .buttonStyle(.plain)
                                .disabled(isSelectingAudio && audioURL(for: entry) == nil)
                                .accessibilityLabel(journalRowAccessibilityLabel(entry))
                                .contextMenu {
                                    Button(role: .destructive) {
                                        state.softDelete(key: entry.key)
                                    } label: { Label("Delete", systemImage: "trash") }
                                }
                                .task { loadAudioDurationIfNeeded(entry) }
                            }
                        }
                    }
                    .padding(.bottom, 120) // clearance for the base bar.
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            isSelectingAudio ? AnyView(selectionBar) : AnyView(baseBar)
        }
        // Fullscreen detail.
        .fullScreenCover(item: $selectedDetail) { entry in
            JournalDetailView(entry: entry)
                .environmentObject(state)
        }
    }

    /// Compact sort menu: newest-first (default), oldest-first, title.
    private var sortMenu: some View {
        Menu {
            Picker("Sort journals", selection: $sortOrder) {
                Label("Newest First", systemImage: "arrow.down")
                    .tag(JournalSort.newestFirst)
                Label("Oldest First", systemImage: "arrow.up")
                    .tag(JournalSort.oldestFirst)
                Label("Title", systemImage: "textformat.abc")
                    .tag(JournalSort.title)
            }
        } label: {
            Image(systemName: "arrow.up.arrow.down")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(DS.muted(scheme))
                .frame(width: 32, height: 32)
                .background(DS.surface2(scheme), in: Circle())
        }
        .accessibilityLabel("Sort journals")
    }

    /// One list row (Voice Memos style): leading glyph — spinner while
    /// transcribing, waveform for audio, text glyph otherwise — then the
    /// title over a metadata line (localized date/time + audio duration, or
    /// the transcribing status), and a trailing chevron. The transcript
    /// preview is gone: the detail view owns the transcript.
    private func journalRow(_ entry: SlowClawMemoryEntry) -> some View {
        let isAudio = entry.source?.hasPrefix("audio") == true
        let transcribing = AppState.isTranscribingPlaceholder(entry.content)
        let canSelect = audioURL(for: entry) != nil
        return HStack(alignment: .center, spacing: 12) {
            // Leading glyph / spinner.
            if isSelectingAudio {
                Image(systemName: selectedAudioKeys.contains(entry.key) ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 21, weight: .medium))
                    .foregroundStyle(selectedAudioKeys.contains(entry.key) ? DS.accentColor : DS.muted(scheme))
                    .frame(width: 24, height: 24)
            } else if transcribing {
                ProgressView()
                    .scaleEffect(0.7)
                    .frame(width: 24, height: 24)
            } else {
                Image(systemName: isAudio ? "waveform" : "text.alignleft")
                    .font(.system(size: 16))
                    .foregroundStyle(isAudio ? DS.accent2Color : DS.muted(scheme))
                    .frame(width: 24, height: 24)
            }

            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline) {
                    Text(journalTitleOf(entry))
                        .font(DS.bodyFont.weight(.semibold))
                        .foregroundStyle(DS.ink(scheme))
                        .lineLimit(1)
                    // Small spinner while an AI title is being generated.
                    if state.pendingTitleKeys.contains(entry.key) {
                        ProgressView()
                            .scaleEffect(0.5)
                            .frame(width: 12, height: 12)
                    }
                }

                HStack(spacing: 6) {
                    if transcribing {
                        Text("Transcribing…")
                            .foregroundStyle(DS.accent2Color)
                    } else if let date = journalDate(entry) {
                        Text(Self.localizedDateTime(date))
                    }
                    // Audio duration (best-effort; hidden until it lands).
                    if isAudio, let duration = audioDurations[entry.key], duration > 0 {
                        Text(audioClock(duration))
                    }
                }
                .font(DS.microFont)
                .foregroundStyle(DS.muted(scheme))
            }

            Spacer(minLength: 4)

            if !isSelectingAudio {
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(DS.muted(scheme).opacity(0.6))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .contentShape(Rectangle())
        .opacity(isSelectingAudio && !canSelect ? 0.4 : 1)
    }

    /// VoiceOver label for a row: title, then either the transcribing status
    /// or the localized date/time, plus the duration when known.
    private func journalRowAccessibilityLabel(_ entry: SlowClawMemoryEntry) -> String {
        var parts = [journalTitleOf(entry)]
        if AppState.isTranscribingPlaceholder(entry.content) {
            parts.append("Transcribing")
        } else if let date = journalDate(entry) {
            parts.append(Self.localizedDateTime(date))
        }
        if let duration = audioDurations[entry.key], duration > 0 {
            parts.append(audioClock(duration))
        }
        return parts.joined(separator: ", ")
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
            // The import hint lives ONLY here (empty state) — never as a
            // persistent instruction above a populated list.
            Text("Import voice memos via the share sheet → SlowClaw.")
                .font(DS.microFont)
                .foregroundStyle(DS.muted(scheme))
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Base bar (record + pen, or recording controls)

    private var selectionBar: some View {
        VStack(spacing: 0) {
            Divider().opacity(0.4)
            HStack {
                Button(selectedAudioKeys == selectableAudioKeys ? "Deselect All" : "Select All") {
                    if selectedAudioKeys == selectableAudioKeys {
                        selectedAudioKeys.removeAll()
                    } else {
                        selectedAudioKeys = selectableAudioKeys
                    }
                }
                .font(DS.captionFont.weight(.semibold))
                .foregroundStyle(DS.accentColor)

                Spacer()

                Text("\(selectedAudioKeys.count) selected")
                    .font(DS.captionFont)
                    .foregroundStyle(DS.muted(scheme))

                Spacer()

                ShareLink(items: selectedAudioURLs) {
                    Label("Export", systemImage: "square.and.arrow.up")
                        .font(DS.captionFont.weight(.semibold))
                }
                .disabled(selectedAudioURLs.isEmpty)
            }
            .padding(.horizontal, 18)
            .frame(height: 64)
            .background(.ultraThinMaterial)
        }
    }

    private var baseBar: some View {
        VStack(spacing: 0) {
            Divider().opacity(0.4)
            HStack(spacing: 0) {
                // Leading: text compose (the secondary action).
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

                // Center: the big red record button.
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
                        if recorder.isTranscribing {
                            ProgressView()
                                .tint(.white)
                        } else {
                            Image(systemName: "mic.fill")
                                .font(.system(size: 26))
                                .foregroundStyle(.white)
                        }
                    }
                }
                .buttonStyle(.plain)
                .disabled(recorder.isTranscribing || recorder.isFinalizing)
                .accessibilityLabel("Record an audio journal")

                Spacer()

                // Trailing balance — same 56pt footprint as the leading pen
                // button so the record button sits exactly centered.
                Color.clear
                    .frame(width: 56, height: 56)
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

                Text(recorder.isFinalizing
                     ? "Finishing transcript…"
                     : (recorder.isPaused ? "Paused" : "Recording…"))
                    .font(DS.bodyFont)
                    .foregroundStyle(DS.ink(scheme))

                if !recorder.transcript.isEmpty {
                    Text(recorder.transcript)
                        .font(DS.captionFont)
                        .foregroundStyle(DS.muted(scheme))
                        .lineLimit(4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 24)
                        .accessibilityLabel("Live transcript: \(recorder.transcript)")
                }

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
                    .disabled(recorder.isFinalizing)
                    .accessibilityLabel(recorder.isPaused ? "Resume recording" : "Pause recording")

                    Button {
                        Task { await recorder.finishRecording() }
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
                    .disabled(recorder.isFinalizing)
                    .accessibilityLabel("Stop recording")
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
    @StateObject private var blog = BlogClaw.shared
    @State private var showBlogPicker = false

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 12) {
                // TweetClaw header + status.
                HStack(spacing: 10) {
                    Text("🐾")
                        .font(.system(size: 28))
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Your writing studio")
                            .font(DS.cardTitleFont)
                            .foregroundStyle(DS.ink(scheme))
                        Text("Private thoughts. Something worth sharing.")
                            .font(DS.captionFont)
                            .foregroundStyle(DS.muted(scheme))
                    }
                    Spacer()
                    Button {
                        state.startTweetClawGeneration()
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

                HStack(spacing: 12) {
                    Button { state.startTweetClawGeneration() } label: {
                        Label("Short post", systemImage: "quote.bubble")
                            .frame(maxWidth: .infinity).padding(.vertical, 10)
                    }
                    Button { showBlogPicker = true } label: {
                        Label("BlogClaw", systemImage: "doc.richtext")
                            .frame(maxWidth: .infinity).padding(.vertical, 10)
                    }
                }
                .buttonStyle(.bordered).tint(DS.accent(scheme))
                .disabled(state.isGeneratingPosts || blog.running || state.localModelBusy)

                if let progress = blog.progress {
                    HStack {
                        if blog.running { ProgressView().controlSize(.small) }
                        Text(progress).font(DS.captionFont)
                        Spacer()
                        if blog.running { Button("Stop") { blog.stop() } }
                    }.padding(12).background(DS.surface2(scheme), in: RoundedRectangle(cornerRadius: 12))
                }

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
        .sheet(isPresented: $showBlogPicker) { BlogClawPicker().environmentObject(state) }
        .refreshable {
            state.startTweetClawGeneration()
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
    @State private var showPublish = false
    @State private var saveError: String?

    private var isArticle: Bool { draft.source == "blogclaw" }
    private var maxChars: Int { isArticle ? 60_000 : 300 }

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
                        Text(isArticle ? "BlogClaw" : "TweetClaw")
                            .font(DS.captionFont.weight(.semibold))
                            .foregroundStyle(DS.ink(scheme))
                        Text(isArticle ? "Article draft · private until published" : "Short post · private until published")
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
                    Text(isArticle ? "\(editedText.split { $0.isWhitespace }.count) words" : "\(charCount) characters")
                        .font(DS.microFont.monospacedDigit())
                        .foregroundStyle(charCountColor)

                    Spacer()

                    // Edit / Done toggle
                    Button {
                        if isEditing {
                            editedText = editedText.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard saveDraft() else { return }
                        }
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
                if let saveError { Text(saveError).font(.caption).foregroundStyle(.red) }
                HStack {
                    Button {
                        guard saveDraft() else { return }
                        isEditing = false
                        showPublish = true
                    } label: {
                        Label("Review & publish", systemImage: "paperplane")
                            .frame(maxWidth: .infinity)
                    }.buttonStyle(.borderedProminent).tint(DS.accent(scheme))
                    ShareLink(item: editedText) { Image(systemName: "square.and.arrow.up") }
                        .accessibilityLabel("Export draft")
                }
            }
        }
        .sheet(isPresented: $showPublish) {
            PublishDraftSheet(draftKey: draft.key, content: editedText, article: isArticle)
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

    private func saveDraft() -> Bool {
        guard !editedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            saveError = "Write something before saving or publishing."
            return false
        }
        do {
            try state.memory.store(key: draft.key, content: editedText,
                category: draft.category, sessionID: "drafts", source: draft.source, mediaURL: draft.mediaURL)
            saveError = nil
            Task { await state.refreshJournals() }
            return true
        } catch { saveError = "Could not save your edits. Please try again."; return false }
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
                    let activeTitle = LocalModelPreset.presets.first {
                        $0.id == state.loadedLocalModelPresetID
                    }?.title ?? state.localLLM.modelId ?? "model"
                    Text("Ready — \(activeTitle) is running on-device")
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
            && state.loadedLocalModelPresetID == model.id
        // Per-preset download tracking: only the row actually downloading is
        // gated. `localModelBusy` means ACTIVATION now, so other presets'
        // Download buttons stay enabled during a transfer.
        let isDownloading = state.activeDownloadIDs.contains(model.id)
        let anyDownloadActive = !state.activeDownloadIDs.isEmpty
        // Activation-conflicting controls: loading a model while a multi-GB
        // download streams (or vice versa) fights for RAM/disk, and deleting
        // files mid-transfer/activation corrupts state — block those, and
        // ONLY those, while work is in flight.
        let conflictControlsDisabled = state.localModelBusy || anyDownloadActive

        VStack(alignment: .leading, spacing: 6) {
            Text(model.title)
                .font(DS.bodyFont.weight(.semibold))
                .foregroundStyle(DS.ink(scheme))
            Text(model.detail)
                .font(DS.captionFont)
                .foregroundStyle(DS.muted(scheme))

            if isDownloading, let progress {
                // Determinate bar from the first tick — including 0%, while
                // the background session still waits for unmetered Wi-Fi
                // before the first byte moves.
                ProgressView(value: min(max(progress, 0), 1))
                    .tint(DS.accentColor)
                Text(progress <= 0
                     ? "Preparing / waiting for Wi-Fi"
                     : "\(Int(progress * 100))% of \(model.sizeLabel)")
                    .font(DS.microFont)
                    .foregroundStyle(DS.muted(scheme))
            } else if !downloaded {
                Button {
                    Task { await state.downloadLocalModel(model) }
                } label: {
                    Label("Download (\(model.sizeLabel))",
                          systemImage: "arrow.down.circle")
                        .font(DS.captionFont.weight(.medium))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.bordered)
                .tint(DS.accentColor)
                .disabled(isDownloading || state.localModelBusy)
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
                    .disabled(conflictControlsDisabled)

                    Button(role: .destructive) {
                        state.deleteLocalModel(model)
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 13))
                            .padding(6)
                    }
                    .buttonStyle(.bordered)
                    .tint(DS.accent2Color)
                    .disabled(conflictControlsDisabled)
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
                    .disabled(conflictControlsDisabled)

                    Button(role: .destructive) {
                        state.deleteLocalModel(model)
                    } label: {
                        Image(systemName: "trash")
                            .font(.system(size: 13))
                            .padding(6)
                    }
                    .buttonStyle(.bordered)
                    .tint(DS.accent2Color)
                    .disabled(conflictControlsDisabled)
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

/// Apple Speech readiness and a live audit of every file transcription.
/// No transcript text is logged—only routing, lengths, errors, and timings.
struct ExperimentCard: View {
    let scheme: ColorScheme
    @EnvironmentObject var state: AppState
    @State private var runs: [TranscriptionRun] = []

    var body: some View {
        DS.card(scheme) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 6) {
                    Image(systemName: "waveform.badge.magnifyingglass")
                        .font(.system(size: 14))
                    Text("Audio Transcription")
                        .font(DS.cardTitleFont)
                        .foregroundStyle(DS.ink(scheme))
                }

                Text("Apple Speech transcribes recordings and imports automatically on-device.")
                    .font(DS.captionFont)
                    .foregroundStyle(DS.muted(scheme))

                Toggle(isOn: $state.lockedPhoneExperiment) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Keep transcription alive while locked")
                            .font(DS.bodyFont.weight(.medium))
                        Text("Keeps the audio session active after recording while file transcription finishes.")
                            .font(DS.microFont)
                            .foregroundStyle(DS.muted(scheme))
                    }
                }
                .tint(DS.accentColor)

                Divider().overlay(DS.line(scheme))

                if state.audioTranscriptionInFlight {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text(state.audioTranscriptionProgress ?? "Transcribing on-device…")
                            .font(DS.microFont)
                            .foregroundStyle(DS.accent(scheme))
                    }
                }

                Text("Recent runs (newest last)")
                    .font(DS.captionFont.weight(.semibold))
                    .foregroundStyle(DS.ink(scheme))
                if runs.isEmpty {
                    Text("No runs yet. Record or re-transcribe an audio journal.")
                        .font(DS.microFont)
                        .foregroundStyle(DS.muted(scheme))
                } else {
                    ForEach(runs) { run in transcriptionRow(run) }
                    Button(role: .destructive) {
                        TranscriptionLogger.clear()
                        runs = []
                    } label: {
                        Label("Clear runs", systemImage: "trash")
                            .font(DS.microFont)
                    }
                    .buttonStyle(.bordered)
                    .tint(DS.accent2Color)
                }
            }
        }
        .onAppear {
            runs = TranscriptionLogger.loadRecent()
        }
        .onReceive(NotificationCenter.default.publisher(
            for: .slowClawTranscriptionRunAdded)) { _ in
                runs = TranscriptionLogger.loadRecent()
            }
    }

    @ViewBuilder
    private func transcriptionRow(_ run: TranscriptionRun) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Image(systemName: run.succeeded
                      ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(run.succeeded
                                     ? DS.accent(scheme) : DS.accent2Color)
                Text(run.engine)
                    .font(DS.microFont.weight(.medium))
                Spacer()
                Text(run.context.rawValue)
                    .font(.system(size: 9))
                    .foregroundStyle(DS.muted(scheme))
            }
            if run.requestedEngine != run.engine {
                Text("Requested: \(run.requestedEngine)")
                    .font(.system(size: 9))
                    .foregroundStyle(DS.accent2Color)
            }
            Text("\(audioClock(run.audioSeconds)) audio · \(run.segmentCount) segment\(run.segmentCount == 1 ? "" : "s") · \(run.transcriptLen) chars · \(run.totalMs)ms")
                .font(.system(size: 9))
                .foregroundStyle(DS.muted(scheme))
            if !run.detail.isEmpty {
                Text(run.detail)
                    .font(.system(size: 9))
                    .foregroundStyle(run.succeeded
                                     ? DS.muted(scheme) : DS.accent2Color)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(DS.surface2(scheme),
                    in: RoundedRectangle(cornerRadius: DS.rSm,
                                         style: .continuous))
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

                // Apple Speech diagnostics + optional locked-phone test.
                ExperimentCard(scheme: scheme)

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
                            FlowChips(interests: state.interests, scheme: scheme) {
                                state.removeInterest($0)
                            }
                        }
                        Text("Reads learns from article titles and summaries after 20 seconds in the reader. Likes count more. History stays on this iPhone; journals remain the strongest signal.")
                            .font(DS.captionFont)
                            .foregroundStyle(DS.muted(scheme))
                        Button("Reset reading history", role: .destructive) { state.clearReadingHistory() }
                            .disabled(state.readingSignals.isEmpty)
                        Button {
                            Task {
                                await state.ensureLocalModelActivated()
                                state.scheduleInterestIndexing()
                            }
                        } label: {
                            Label("Refresh from my journals", systemImage: "sparkles")
                        }.disabled(state.isIndexingInterests || state.localModelBusy)
                        if state.isIndexingInterests {
                            HStack(spacing: 8) {
                                ProgressView()
                                    .controlSize(.small)
                                Text(state.interestIndexProgress ?? "Learning from journals…")
                                    .font(DS.captionFont)
                                    .foregroundStyle(DS.muted(scheme))
                            }
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
    let interests: [String]
    let scheme: ColorScheme
    let onRemove: (String) -> Void

    var body: some View {
        FlowLayout(spacing: 6, lineSpacing: 6) {
            ForEach(interests, id: \.self) { tag in
                Button {
                    onRemove(tag)
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
    @EnvironmentObject var state: AppState
    let item: RankedFeedItem
    let interests: [String]

    // Backed by AppState sets (session-stable) instead of @State, which the
    // LazyVStack recycles on scroll — likes used to reset silently.
    private var liked: Bool { state.readingSignals[item.id]?.preference == 1 }
    private var disliked: Bool { state.readingSignals[item.id]?.preference == -1 }

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
            // Optional cover image (RSS media cover / YouTube thumbnail /
            // Nostr article image). Failed loads render NOTHING — a dead
            // image URL must not leave a reserved gray block on the card.
            if let thumb = item.thumbnailURL, let url = URL(string: thumb) {
                AsyncImage(url: url) { phase in
                    switch phase {
                    case .empty:
                        Rectangle().fill(DS.surface2(scheme))
                            .frame(height: 160)
                    case .success(let image):
                        image.resizable().scaledToFill().frame(height: 160).clipped()
                    case .failure:
                        EmptyView()
                    @unknown default:
                        EmptyView()
                    }
                }
                .frame(maxWidth: .infinity)
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
                Text(item.title.isEmpty ? "Untitled" : item.title.decodingHTMLEntities())
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
                        state.rememberArticle(item, preference: liked ? 0 : 1)
                        UISelectionFeedbackGenerator().selectionChanged()
                    } label: {
                        Image(systemName: liked ? "hand.thumbsup.fill" : "hand.thumbsup")
                            .font(.system(size: 16))
                            .foregroundStyle(liked ? DS.likeColor : DS.muted(scheme))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("More like this")

                    Button {
                        state.rememberArticle(item, preference: disliked ? 0 : -1)
                        UISelectionFeedbackGenerator().selectionChanged()
                    } label: {
                        Image(systemName: disliked ? "hand.thumbsdown.fill" : "hand.thumbsdown")
                            .font(.system(size: 16))
                            .foregroundStyle(disliked ? DS.accent2Color : DS.muted(scheme))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Less like this")

                    Spacer()

                    if !item.link.isEmpty, URL(string: item.link) != nil {
                        // In-app reader affordance (SFSafariViewController).
                        Image(systemName: "safari")
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
            guard URL(string: item.link) != nil, !item.link.isEmpty else { return }
            // All web links open inside the app (SFSafariViewController),
            // never an external Safari window.
            state.openArticle(item)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(host), \(item.title), \(item.readMinutes) minute read")
        .accessibilityAddTraits(.isButton)
    }
}

// MARK: - HTML stripping helper

extension String {
    /// Strip HTML tags (RSS descriptions often contain HTML), then decode the
    /// common XML/HTML entities so Reads cards render "A &amp; B" as "A & B".
    func strippingHTML() -> String {
        guard self.contains("<") else { return self.decodingHTMLEntities() }
        var result = ""
        var inside = false
        for ch in self {
            if ch == "<" { inside = true }
            else if ch == ">" { inside = false }
            else if !inside { result.append(ch) }
        }
        return result.decodingHTMLEntities()
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Decode the handful of entities real feeds emit: the five XML
    /// predefined ones plus numeric (&#8212; / &#x2014;) references.
    func decodingHTMLEntities() -> String {
        guard contains("&") else { return self }
        var out = ""
        var i = startIndex
        while i < endIndex {
            let ch = self[i]
            if ch == "&", let semi = self[i...].firstIndex(of: ";"),
               distance(from: i, to: semi) <= 10 {
                let entity = String(self[self.index(after: i)..<semi])
                if let decoded = Self.decodeEntity(entity) {
                    out.append(decoded)
                    i = index(after: semi)
                    continue
                }
            }
            out.append(ch)
            i = index(after: i)
        }
        return out
    }

    private static func decodeEntity(_ entity: String) -> Character? {
        switch entity {
        case "amp": return "&"
        case "lt": return "<"
        case "gt": return ">"
        case "quot": return "\""
        case "apos": return "'"
        case "nbsp": return " "
        case "#39", "#x27": return "'"
        case "#8217", "rsquo": return "’"
        case "lsquo": return "‘"
        case "ldquo": return "“"
        case "rdquo": return "”"
        case "#8212", "#x2014", "mdash": return "—"
        case "#8211", "#x2013", "ndash": return "–"
        case "#8230", "#x2026", "hellip": return "…"
        default:
            // Numeric decimal (&#8220) or hex (&#x201C) scalar references.
            if entity.hasPrefix("#") {
                let value: UInt32?
                if entity.hasPrefix("#x") || entity.hasPrefix("#X") {
                    value = UInt32(String(entity.dropFirst(2)), radix: 16)
                } else {
                    value = UInt32(String(entity.dropFirst()))
                }
                if let value, value > 0, !(0xD800...0xDFFF).contains(value),
                   let scalar = Unicode.Scalar(value) {
                    return Character(scalar)
                }
            }
            return nil
        }
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
