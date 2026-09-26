import SwiftUI
import AVFoundation

// Only compiled into the isolated simulator test host. The actual studio view
// and render/export code are exercised; the journal store is a synthetic fixture.
struct SlowClawMemoryEntry { let key: String; let content: String; let mediaURL: String? }
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
    func memorySource(_ key: String) -> SlowClawMemoryEntry? { key == entry.key ? entry : nil }
    static func softDeletedKeys() -> [String: Double] { [:] }
    func prepareStudioTranscript(key: String) async throws -> TimedTranscript { TimedTranscriptStore.load(for: URL(fileURLWithPath: entry.mediaURL!))! }
}
@main struct StudioSmokeHost: App {
    @StateObject private var state = AppState()
    @State private var sourceID = "studio-ui-" + UUID().uuidString
    var body: some Scene {
        WindowGroup {
            if ProcessInfo.processInfo.arguments.contains("--studio-ui-test") {
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
