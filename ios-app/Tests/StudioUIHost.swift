import SwiftUI
import AVFoundation
import CryptoKit

// Only compiled into the isolated simulator test host. The actual studio view
// and render/export code are exercised; the journal store is a synthetic fixture.
struct SlowClawMemoryEntry { let key: String; let content: String; let mediaURL: String? }
func journalDate(_ entry: SlowClawMemoryEntry) -> Date? { Date() }
struct WebMemoryFixture {
    func get(key: String) throws -> SlowClawMemoryEntry? { nil }
    func store(key: String, content: String, category: String, sessionID: String?, source: String?, mediaURL: String?) throws {}
}
func journalTitleOf(_ entry: SlowClawMemoryEntry) -> String { "Studio sample" }
func journalBodyOf(_ text: String) -> String { text }
@MainActor final class AudioRecorder {
    var isRecording = false
    var isFinalizing = false
    static func absoluteURL(forMediaRelativePath path: String?) -> URL? { path.map { URL(fileURLWithPath: $0) } }
}
enum AppTab { case drafts, journal }
@MainActor final class AppState: ObservableObject {
    @Published var studioPlayingID: String?
    @Published var selectedTab = AppTab.drafts
    let recorder = AudioRecorder()
    let memory = WebMemoryFixture()
    var journals: [SlowClawMemoryEntry] { liteJournals }
    var excludedMemoryKeys: Set<String> = []
    var createIdeas: [CreateIdeas.Candidate] = []
    var relevantPulse: [RankedFeedItem] = []
    static let transcribingPlaceholder = "Transcribing…"
    static func needsTranscript(_ content: String?) -> Bool { content == nil }
    func refreshJournals() async {}
    func enqueuePendingTranscription(key: String, mediaPath: String, drainNow: Bool) async -> Bool { true }
    func drainPendingTranscriptions() async {}
    let entry: SlowClawMemoryEntry
    var liteJournals: [SlowClawMemoryEntry] { [entry] }
    init() {
        let audio = FileManager.default.temporaryDirectory.appendingPathComponent("studio-ui.caf")
        let text = "A small practice can change how we see things."
        entry = .init(key: "slowclaw_ui_sample", content: text, mediaURL: audio.path)
        let format = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
        do {
            let file = try AVAudioFile(forWriting: audio, settings: format.settings)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 480000)!
            buffer.frameLength = 480000
            for i in 0..<480000 { buffer.floatChannelData![0][i] = Float(sin(Double(i) * 2 * .pi * 440 / 16000)) * 0.1 }
            try file.write(from: buffer)
        } catch { fatalError("Could not prepare synthetic UI audio") }
        let timing = TimedTranscript(text: text, words: text.split(separator: " ").enumerated().map { .init(text: String($0.element), start: Double($0.offset) * 2 + 1, end: Double($0.offset) * 2 + 2) })
        try! TimedTranscriptStore.save(timing, for: audio)
    }
    func loadReads(force: Bool = false) async {}
    func rememberArticle(_ item: RankedFeedItem, preference: Int) {}
    func memorySource(_ key: String) -> SlowClawMemoryEntry? { key == entry.key ? entry : nil }
    static func softDeletedKeys() -> [String: Double] { [:] }
    func prepareStudioTranscript(key: String) async throws -> TimedTranscript { TimedTranscriptStore.load(for: URL(fileURLWithPath: entry.mediaURL!))! }
}
@main struct StudioSmokeHost: App {
    @StateObject private var state = AppState()
    @State private var sourceID = "studio-ui-" + UUID().uuidString
    var body: some Scene {
        WindowGroup {
            if ProcessInfo.processInfo.arguments.contains("--pulse-media-test") {
                NavigationStack { ScrollView {
                    NostrPostContent(content: "Look at this clip https://example.com/clip.mp4 and recording https://example.com/audio.mp3").padding()
                } }
            } else if ProcessInfo.processInfo.arguments.contains("--web-ui-test") {
                NavigationStack { WebCompanionView().environmentObject(state) }
            } else if ProcessInfo.processInfo.arguments.contains("--pulse-ui-test") {
                NavigationStack { ScrollView { PulseRow(item: PulseUIFixture.item).environmentObject(state).padding(.top) } }
            } else if ProcessInfo.processInfo.arguments.contains("--studio-ui-test") {
                VStack(spacing: 0) {
                    NavigationStack {
                        if ProcessInfo.processInfo.arguments.contains("--card") {
                            ScrollView { ShareStudioView(source: source, compact: true).environmentObject(state).padding() }
                        } else { ShareStudioView(source: source).environmentObject(state) }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    Text("Journal · Reads · Create · Profile").frame(maxWidth: .infinity).frame(height: 70)
                        .background(.regularMaterial).accessibilityIdentifier("slowclaw.tabs")
                }.frame(maxHeight: 667)
            } else { Color.black }
        }
    }
    private var source: StudioSource {
        var source = StudioSource(entry: state.entry, excerpt: state.entry.content)
        source.id = sourceID
        source.startsWithVideo = ProcessInfo.processInfo.arguments.contains("--video")
        return source
    }
}

@MainActor enum PulseUIFixture {
    // A globally known test key can already have newer metadata on public
    // relays. Use fresh synthetic identities so profile reads cannot replace
    // the fixture's names or bring unrelated posts into the test timeline.
    private static let session = UUID().uuidString
    static let item: RankedFeedItem = {
        func signed(_ kind: Int, author: UInt8, tags: [[String]] = [], text: String, date: Int = 1) -> PublishedEvent {
            let secret = Array(SHA256.hash(data: Data(("slowclaw-ui-" + session + "-" + String(author)).utf8)))
            let pubkey = try! NostrIdentity.publicKey(secret)
            let bytes = try! JSONSerialization.data(withJSONObject: [0, pubkey, date, kind, tags, text], options: [.withoutEscapingSlashes])
            let hash = Array(SHA256.hash(data: bytes))
            return PublishedEvent(id: NostrIdentity.hex(hash), pubkey: pubkey, created_at: date, kind: kind, tags: tags, content: text, sig: try! NostrIdentity.sign(hash: hash, secret: secret))
        }
        let post = signed(1, author: 1, text: "Small gardens can teach us patience. A little attention every morning changes what we notice.")
        let profile = signed(0, author: 1, text: #"{"name":"slowclaw_agent","display_name":"SlowClawAgent"}"#)
        let replyProfile = signed(0, author: 2, text: #"{"name":"slowclaw_user"}"#)
        let replies = (1...3).map { signed(1, author: 2, tags: [["e", post.id, "", "root"]], text: "Garden reply \($0)", date: $0 + 1) }
        let like = signed(7, author: 2, tags: [["e", post.id]], text: "+")
        NostrSocialStore.shared.mergeProfiles([profile, replyProfile])
        NostrSocialStore.shared.recordAuthor(.init(events: [post], completed: 1, total: 1), key: post.pubkey)
        NostrSocialStore.shared.record(.init(events: replies + [like], completed: 1, total: 1), posts: [post])
        return RankedFeedItem(id: "nostr:" + post.id, title: "Garden", link: "https://example.com/post", description: post.content,
            sourceLabel: "Nostr", score: 1, readMinutes: 1, sourcePlatform: "nostr", thumbnailURL: nil,
            nostrEventJSON: String(decoding: try! JSONEncoder().encode(post), as: UTF8.self))
    }()
}
