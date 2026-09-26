import SwiftUI
import AVKit

struct StudioSource: Identifiable {
    let id: String
    let key: String
    let title: String
    let content: String
    let excerpt: String?
    let audio: URL?
    let mediaPath: String?
    let initialQuote: String
    init(entry: SlowClawMemoryEntry, excerpt: String? = nil) {
        key = entry.key; title = journalTitleOf(entry); content = entry.content
        self.excerpt = excerpt
        mediaPath = entry.mediaURL
        audio = AudioRecorder.absoluteURL(forMediaRelativePath: entry.mediaURL)
        initialQuote = excerpt ?? JevMemory.chunks(journalBodyOf(entry.content), maximum: 450).first ?? ""
        id = JevBatch.digest(entry.key + "\n" + initialQuote)
    }
}

enum StudioDraftFiles {
    static func directory(key: String) -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("StudioDrafts", isDirectory: true).appendingPathComponent(JevBatch.digest(key), isDirectory: true)
    }
    static func remove(key: String) { try? FileManager.default.removeItem(at: directory(key: key)) }
}

private struct StudioDraft: Codable, Equatable {
    var quote: String
    var attribution = ""
    var title = ""
    var theme = StudioTheme.midnight
    var aspect = StudioAspect.portrait
    var waveform = true
    static func url(_ source: StudioSource) -> URL { StudioDraftFiles.directory(key: source.key).appendingPathComponent(source.id + ".json") }
    static func load(_ source: StudioSource) -> StudioDraft {
        (try? JSONDecoder().decode(Self.self, from: Data(contentsOf: url(source)))) ?? .init(quote: source.initialQuote)
    }
    func save(_ source: StudioSource) throws {
        let destination = Self.url(source)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(self).write(to: destination, options: [.atomic, .completeFileProtection])
    }
}

struct CreationSourcePicker: View {
    @EnvironmentObject var state: AppState
    var body: some View {
        List(state.liteJournals, id: \.key) { entry in
            NavigationLink {
                ShareStudioView(source: StudioSource(entry: entry)).environmentObject(state)
            } label: {
                VStack(alignment: .leading, spacing: 5) {
                    Text(journalTitleOf(entry))
                    Text(entry.mediaURL == nil ? "Quote card" : "Quote card · Audio video").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .overlay { if state.liteJournals.isEmpty { ContentUnavailableView("Start with a journal", systemImage: "quote.bubble", description: Text("Record or write a thought, then turn it into something to share.")) } }
        .navigationTitle("Choose a journal")
    }
}

@MainActor
struct ShareStudioView: View {
    let source: StudioSource
    @EnvironmentObject var state: AppState
    @Environment(\.scenePhase) private var scenePhase
    @State private var draft: StudioDraft
    @State private var mode = "Quote"
    @State private var preview: UIImage?
    @State private var transcript: TimedTranscript?
    @State private var duration = 0.0
    @State private var first = 0
    @State private var last = 0
    @State private var envelope: [Float] = []
    @State private var player: AVPlayer?
    @State private var playing = false
    @State private var elapsed = 0.0
    @State private var preparing = false
    @State private var exporting = false
    @State private var progress = 0.0
    @State private var issue: String?
    @State private var timingNote: String?
    @State private var needsSelection = false
    @State private var work: Task<Void, Never>?
    @State private var share: SharedAsset?
    private let timer = Timer.publish(every: 0.08, on: .main, in: .common).autoconnect()
    init(source: StudioSource) { self.source = source; _draft = State(initialValue: StudioDraft.load(source)) }
    private var clip: TimedTranscript.Clip? { transcript?.clip(first...max(first, last), audioDuration: duration) }
    private var rangeKey: String { "\(first):\(last):\(transcript?.words.count ?? 0)" }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Picker("Format", selection: $mode) {
                    Text("Quote card").tag("Quote")
                    if source.audio != nil { Text("Audio video").tag("Video") }
                }.pickerStyle(.segmented).disabled(exporting || preparing)
                if let preview {
                    Image(uiImage: preview).resizable().scaledToFit().frame(maxWidth: .infinity, maxHeight: 430)
                        .clipShape(RoundedRectangle(cornerRadius: 12)).accessibilityLabel(mode == "Quote" ? draft.quote : "Captioned audio preview")
                }
                Picker("Background", selection: $draft.theme) { ForEach(StudioTheme.allCases) { Text($0.rawValue).tag($0) } }.pickerStyle(.segmented).disabled(exporting)
                Group { if mode == "Quote" { quoteControls } else { videoControls } }.disabled(exporting)
                if let issue { Text(issue).font(.callout).foregroundStyle(.orange) }
                if exporting {
                    ProgressView(value: progress) { Text("Rendering · \(Int(progress * 100))%") }
                    Button("Cancel export", role: .cancel) { work?.cancel() }
                }
            }.padding()
        }
        .navigationTitle("Create studio").navigationBarTitleDisplayMode(.inline)
        .interactiveDismissDisabled(exporting || preparing)
        .sheet(item: $share) { value in StudioShareSheet(url: value.url) }
        .task {
            refreshPreview()
            if let audio = source.audio, let saved = TimedTranscriptStore.load(for: audio) { await useTiming(saved) }
        }
        .task(id: rangeKey) {
            stopPreview()
            guard let audio = source.audio, let clip else { envelope = []; refreshPreview(); return }
            envelope = []; refreshPreview()
            do {
                try await Task.sleep(nanoseconds: 200_000_000)
                let task = Task.detached(priority: .utility) { try StudioWaveform.read(audio: audio, clip: clip) }
                let result = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
                try Task.checkCancellation()
                envelope = result; refreshPreview()
            } catch { /* Export retries waveform reads and reports failures explicitly. */ }
        }
        .onChange(of: draft) { _, _ in
            do { try draft.save(source) } catch { issue = "Could not save this design. Keep the studio open and retry." }
            refreshPreview()
        }
        .onChange(of: mode) { _, _ in stopPreview(); issue = nil; refreshPreview() }
        .onChange(of: scenePhase) { _, phase in if phase == .background { stopPreview(); work?.cancel() } }
        .onReceive(timer) { _ in
            guard playing, let player, let clip else { return }
            elapsed = max(0, player.currentTime().seconds - clip.start)
            if elapsed >= clip.duration - 0.04 { player.pause(); playing = false }
            refreshPreview()
        }
        .onDisappear { stopPreview(); work?.cancel() }
    }

    private var quoteControls: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Your words, your edit").font(.headline)
            TextEditor(text: $draft.quote).frame(minHeight: 130).overlay(alignment: .bottomTrailing) { Text("\(draft.quote.count)/600").font(.caption).foregroundStyle(.secondary).padding(6).allowsHitTesting(false) }
            TextField("Name or attribution (optional)", text: $draft.attribution).textFieldStyle(.roundedBorder)
            Picker("Shape", selection: $draft.aspect) { ForEach(StudioAspect.allCases) { Text($0.rawValue).tag($0) } }
            Button("Share quote image", systemImage: "square.and.arrow.up") {
                do {
                    try validateSource()
                    let image = try StudioRenderer.quote(text: draft.quote, attribution: draft.attribution, theme: draft.theme, aspect: draft.aspect)
                    share = .init(url: try StudioExporter.quote(image))
                    issue = nil
                } catch { issue = error.localizedDescription }
            }.buttonStyle(.borderedProminent).disabled(exporting)
        }
    }

    @ViewBuilder private var videoControls: some View {
        if preparing { ProgressView("Preparing word timings on this iPhone…") }
        else if transcript == nil {
            Text("Prepare captions from the original recording. Your journal edits are kept.").foregroundStyle(.secondary)
            Button("Prepare captions", systemImage: "waveform") { prepareTiming() }.buttonStyle(.borderedProminent)
        } else if let transcript {
            TextField("Video heading (optional)", text: $draft.title).textFieldStyle(.roundedBorder)
            Toggle("Show waveform", isOn: $draft.waveform)
            if let timingNote { Text(timingNote).font(.caption).foregroundStyle(.secondary) }
            Text("Choose the spoken words").font(.headline)
            Text("Start · \(transcript.words[first].text)").font(.subheadline)
            Slider(value: Binding(get: { Double(first) }, set: { first = Int($0); last = max(first, last); needsSelection = false }), in: 0...Double(max(1, transcript.words.count - 1)), step: 1).disabled(transcript.words.count < 2 || exporting)
            Text("End · \(transcript.words[last].text)").font(.subheadline)
            Slider(value: Binding(get: { Double(last) }, set: { last = max(first, Int($0)); needsSelection = false }), in: 0...Double(max(1, transcript.words.count - 1)), step: 1).disabled(transcript.words.count < 2 || exporting)
            if let clip {
                Text("\(clip.duration, specifier: "%.1f") seconds · original voice").font(.caption).foregroundStyle(.secondary)
                Text(clip.words.map(\.text).joined(separator: " ")).font(.callout).textSelection(.enabled)
                Button(playing ? "Pause preview" : "Play this clip", systemImage: "play.circle") { playPreview() }.disabled(exporting)
                if needsSelection { Button("Use the words shown above") { needsSelection = false } }
                HStack {
                    Button("Share video", systemImage: "film") { exportVideo() }.buttonStyle(.borderedProminent)
                    Button("Audio only", systemImage: "waveform") { exportVideo(audioOnly: true) }.buttonStyle(.bordered)
                }.disabled(exporting || needsSelection)
            } else { Text("Choose up to 90 seconds, with the last word after the first.").foregroundStyle(.secondary) }
        }
    }

    private func validateSource() throws {
        guard let current = state.memorySource(source.key), current.content == source.content, current.mediaURL == source.mediaPath,
              AppState.softDeletedKeys()[source.key] == nil else { throw StudioError(message: "This journal changed or was removed. Reopen it in Create to use the current version.") }
    }
    private func refreshPreview() {
        if mode == "Quote" {
            do { preview = try StudioRenderer.quote(text: draft.quote, attribution: draft.attribution, theme: draft.theme, aspect: draft.aspect) }
            catch { preview = nil }
        } else if let clip { preview = StudioRenderer.videoFrame(clip: clip, time: elapsed, title: draft.title, theme: draft.theme, envelope: draft.waveform ? envelope : [], width: 360) }
        else { preview = nil }
    }
    private func useTiming(_ saved: TimedTranscript) async {
        guard let audio = source.audio else { return }
        do {
            duration = try await AVURLAsset(url: audio).load(.duration).seconds
            guard duration.isFinite, duration > 0, saved.valid, saved.words.last!.end <= duration + 0.1 else { throw StudioError(message: "Word timings do not match this recording. Prepare captions again.") }
            transcript = saved
            if let excerpt = source.excerpt, let range = saved.matchingWords(excerpt) {
                first = range.lowerBound; last = range.upperBound
            } else {
                first = 0; last = saved.words.lastIndex(where: { $0.end - saved.words[0].start <= 59 }) ?? 0
                needsSelection = source.excerpt != nil
                timingNote = needsSelection ? "The excerpt differs from these captions or appears more than once. Choose and preview the words you want." : "The opening minute is selected. Move the handles to choose another moment."
            }
            refreshPreview()
        } catch { issue = error.localizedDescription }
    }
    private func prepareTiming() {
        preparing = true; issue = nil
        work = Task {
            defer { preparing = false }
            do {
                try validateSource()
                let saved = try await state.prepareStudioTranscript(key: source.key)
                try Task.checkCancellation(); try validateSource()
                await useTiming(saved)
            } catch is CancellationError { issue = "Caption preparation cancelled. You can try again." }
            catch { issue = error.localizedDescription }
        }
    }
    private func stopPreview() { player?.pause(); player = nil; playing = false; elapsed = 0 }
    private func playPreview() {
        if let player, playing { player.pause(); playing = false; return }
        guard let audio = source.audio, let clip else { return }
        guard !state.recorder.isRecording, !state.recorder.isFinalizing else { issue = "Finish recording before playing this clip."; return }
        do { try validateSource(); try AVAudioSession.sharedInstance().setCategory(.playback); try AVAudioSession.sharedInstance().setActive(true) }
        catch { issue = error.localizedDescription; return }
        let next = AVPlayer(url: audio)
        next.currentItem?.forwardPlaybackEndTime = CMTime(seconds: clip.end, preferredTimescale: 600)
        next.seek(to: CMTime(seconds: clip.start, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        player = next; elapsed = 0; playing = true; next.play()
    }
    private func exportVideo(audioOnly: Bool = false) {
        guard let audio = source.audio, let clip, !exporting else { return }
        stopPreview(); exporting = true; progress = 0; issue = nil
        let title = draft.title, theme = draft.theme, waveform = draft.waveform
        work = Task {
            defer { exporting = false }
            do {
                try validateSource()
                let url: URL
                guard TimedTranscriptStore.load(for: audio) != nil else { throw StudioError(message: "The recording changed. Reopen the studio to prepare new captions.") }
                if audioOnly { url = try await StudioExporter.audio(audio, clip: clip) }
                else { url = try await StudioExporter.video(audio: audio, clip: clip, title: title, theme: theme, showWaveform: waveform) { progress = $0 } }
                do { try Task.checkCancellation(); try validateSource() }
                catch { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()); throw error }
                share = .init(url: url)
            } catch is CancellationError { issue = "Export cancelled." }
            catch { issue = error.localizedDescription }
        }
    }
}

private struct SharedAsset: Identifiable { let id = UUID(); let url: URL }
struct StudioShareSheet: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIActivityViewController { UIActivityViewController(activityItems: [url], applicationActivities: nil) }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
