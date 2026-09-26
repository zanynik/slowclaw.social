import SwiftUI
import AVKit

struct StudioSource: Identifiable {
    var id: String
    let key: String
    let title: String
    let content: String
    let excerpt: String?
    let audio: URL?
    let mediaPath: String?
    let initialQuote: String
    var segment: CreateIdeas.Candidate? = nil
    var startsWithVideo = false
    @MainActor init(entry: SlowClawMemoryEntry, excerpt: String? = nil) {
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
    var format: String?
    var firstWord: Int?
    var lastWord: Int?
    var timingID: String?
    var selectionConfirmed: Bool?
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
    var compact = false
    @Environment(\.dismiss) private var dismiss
    @State private var editing = false
    @EnvironmentObject var state: AppState
    @Environment(\.scenePhase) private var scenePhase
    @State private var draft: StudioDraft
    @State private var mode = "Quote"
    @State private var preview: UIImage?
    @State private var transcript: TimedTranscript?
    @State private var timingIdentity: String?
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
    init(source: StudioSource, compact: Bool = false) {
        self.source = source; self.compact = compact
        let saved = StudioDraft.load(source)
        _draft = State(initialValue: saved)
        _mode = State(initialValue: saved.format ?? (source.startsWithVideo ? "Video" : "Quote"))
    }
    private var clip: TimedTranscript.Clip? { transcript?.clip(first...max(first, last), audioDuration: duration) }
    private var rangeKey: String { "\(first):\(last):\(transcript?.words.count ?? 0)" }

    var body: some View {
        Group {
            if compact { content }
            else {
                VStack(spacing: 0) {
                    ScrollView { content.padding().padding(.bottom, 20) }.scrollDismissesKeyboard(.interactively)
                    actionBar.controlSize(.large).padding().background(.regularMaterial)
                }
                .navigationTitle("Edit creation").navigationBarTitleDisplayMode(.inline)
            }
        }
        .toolbar {
            if !compact {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() }.disabled(exporting || preparing) }
            }
        }
        .interactiveDismissDisabled(exporting || preparing)
        .sheet(item: $share) { value in StudioShareSheet(url: value.url) }
        .fullScreenCover(isPresented: $editing, onDismiss: reloadDesign) {
            NavigationStack { ShareStudioView(source: source).environmentObject(state) }
        }
        .task {
            refreshPreview()
            if let audio = source.audio, let saved = TimedTranscriptStore.load(for: audio) { await useTiming(saved) }
        }
        .task(id: mode + rangeKey) {
            stopPreview()
            if transcript != nil {
                draft.firstWord = first; draft.lastWord = last; draft.timingID = timingIdentity; draft.selectionConfirmed = !needsSelection
            }
            guard mode == "Video", let audio = source.audio, let clip else { envelope = []; refreshPreview(); return }
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
        .onChange(of: needsSelection) { _, value in draft.selectionConfirmed = !value }
        .onChange(of: state.studioPlayingID) { _, id in if id != source.id { stopPreview() } }
        .onChange(of: state.selectedTab) { _, tab in if tab != .drafts { stopPreview(); work?.cancel() } }
        .onChange(of: mode) { _, value in draft.format = value; stopPreview(); issue = nil; refreshPreview() }
        .onChange(of: scenePhase) { _, phase in if phase == .background { stopPreview(); work?.cancel() } }
        .onReceive(timer) { _ in
            guard playing, let player, let clip else { return }
            elapsed = max(0, player.currentTime().seconds - clip.start)
            if elapsed >= clip.duration - 0.04 { player.pause(); playing = false }
            refreshPreview()
        }
        .onDisappear { stopPreview(); work?.cancel() }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 16) {
            if compact {
                HStack {
                    Label(mode == "Quote" ? "Quote card" : "Audio story", systemImage: mode == "Quote" ? "quote.opening" : "waveform")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Button("Edit", systemImage: "slider.horizontal.3") { stopPreview(); editing = true }
                        .frame(minHeight: 44).disabled(exporting || preparing)
                }
            } else {
                Picker("Format", selection: $mode) {
                    Text("Quote card").tag("Quote")
                    if source.audio != nil { Text("Audio video").tag("Video") }
                }.pickerStyle(.segmented).disabled(exporting || preparing)
            }
            if let preview {
                Image(uiImage: preview).resizable().scaledToFit().frame(maxWidth: .infinity, maxHeight: compact ? 500 : 380)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .accessibilityLabel(mode == "Quote" ? draft.quote : "Captioned audio preview")
            }
            if !compact {
                Picker("Background", selection: $draft.theme) { ForEach(StudioTheme.allCases) { Text($0.rawValue).tag($0) } }
                    .pickerStyle(.segmented).disabled(exporting)
                Group { if mode == "Quote" { quoteControls } else { videoControls } }.disabled(exporting)
            }
            if let issue { Text(issue).font(.callout).foregroundStyle(.orange) }
            if compact { actionBar.controlSize(.large) }
        }
    }

    @ViewBuilder private var actionBar: some View {
        if exporting {
            VStack {
                ProgressView(value: progress) { Text("Rendering · \(Int(progress * 100))%") }
                Button("Cancel export", role: .cancel) { work?.cancel() }.frame(minHeight: 44)
            }
        } else if mode == "Quote" {
            Button("Share quote", systemImage: "square.and.arrow.up") { shareQuote() }
                .buttonStyle(.borderedProminent).frame(maxWidth: .infinity, minHeight: 44).accessibilityIdentifier("studio.shareQuote")
        } else if preparing {
            ProgressView("Preparing captions…").frame(minHeight: 44)
        } else if transcript == nil {
            Button("Prepare audio story", systemImage: "waveform") { prepareTiming() }.buttonStyle(.borderedProminent).frame(minHeight: 44)
        } else if clip != nil {
            VStack(spacing: 8) {
                if let clip { Text("\(clip.duration, specifier: "%.1f") seconds").font(.caption).foregroundStyle(.secondary).accessibilityIdentifier("studio.duration") }
                if needsSelection { Button("Use selected words") { needsSelection = false }.frame(minHeight: 44) }
                HStack(spacing: 14) {
                    Button(playing ? "Pause" : "Play", systemImage: playing ? "pause.fill" : "play.fill") { playPreview() }
                        .buttonStyle(.bordered).frame(minHeight: 44).accessibilityIdentifier("studio.playPause")
                    Button("Share video", systemImage: "square.and.arrow.up") { exportVideo() }
                        .buttonStyle(.borderedProminent).frame(minHeight: 44).disabled(needsSelection).accessibilityIdentifier("studio.shareVideo")
                    Menu {
                        Button("Share audio only", systemImage: "waveform") { exportVideo(audioOnly: true) }
                    } label: { Image(systemName: "ellipsis").frame(width: 44, height: 44) }.disabled(needsSelection)
                }
            }
        } else { Text("Choose a clip of up to 90 seconds.").font(.callout) }
    }
    private func reloadDesign() {
        stopPreview()
        let saved = StudioDraft.load(source)
        // Restore the edited range before changing mode. Otherwise the mode's
        // waveform task could persist the old feed range over the new edit.
        if let transcript, saved.timingID == timingIdentity, saved.selectionConfirmed == true,
           let a = saved.firstWord, let b = saved.lastWord, a <= b,
           transcript.words.indices.contains(a), transcript.words.indices.contains(b) {
            first = a; last = b; needsSelection = false
        }
        draft = saved; mode = saved.format ?? mode
        refreshPreview()
        if transcript == nil, let audio = source.audio, let timing = TimedTranscriptStore.load(for: audio) {
            Task { await useTiming(timing) }
        }
    }
    private func shareQuote() {
        state.studioPlayingID = nil
        do {
            try validateSource()
            let image = try StudioRenderer.quote(text: draft.quote, attribution: draft.attribution, theme: draft.theme, aspect: draft.aspect)
            share = .init(url: try StudioExporter.quote(image)); issue = nil
        } catch { issue = error.localizedDescription }
    }

    private var quoteControls: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Your words, your edit").font(.headline)
            TextEditor(text: $draft.quote).frame(minHeight: 130).overlay(alignment: .bottomTrailing) { Text("\(draft.quote.count)/600").font(.caption).foregroundStyle(.secondary).padding(6).allowsHitTesting(false) }
            TextField("Name or attribution (optional)", text: $draft.attribution).textFieldStyle(.roundedBorder)
            Picker("Shape", selection: $draft.aspect) { ForEach(StudioAspect.allCases) { Text($0.rawValue).tag($0) } }

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
            Slider(value: Binding(get: { Double(last) }, set: { last = max(first, Int($0)); needsSelection = false }), in: 0...Double(max(1, transcript.words.count - 1)), step: 1).disabled(transcript.words.count < 2 || exporting).accessibilityIdentifier("studio.endWord")
            if let clip {
                Text("\(clip.duration, specifier: "%.1f") seconds · original voice").font(.caption).foregroundStyle(.secondary)
                Text(clip.words.map(\.text).joined(separator: " ")).font(.callout).textSelection(.enabled)

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
            let identity = CreateIdeas.timingID(saved); timingIdentity = identity
            needsSelection = false
            if draft.selectionConfirmed == true, draft.timingID == identity, let a = draft.firstWord, let b = draft.lastWord,
               saved.words.indices.contains(a), saved.words.indices.contains(b), a <= b {
                first = a; last = b
            } else if let segment = source.segment, segment.timingID == identity,
               let a = segment.first, let b = segment.last, saved.words.indices.contains(a), saved.words.indices.contains(b), a <= b {
                first = a; last = b
            } else if let excerpt = source.excerpt, let range = saved.matchingWords(excerpt) {
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
        state.studioPlayingID = source.id
        if let player, player.currentTime().seconds < clip.end - 0.04 { playing = true; player.play(); return }
        let next = AVPlayer(url: audio)
        next.currentItem?.forwardPlaybackEndTime = CMTime(seconds: clip.end, preferredTimescale: 600)
        next.seek(to: CMTime(seconds: clip.start, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        player = next; elapsed = 0; playing = true; next.play()
    }
    private func exportVideo(audioOnly: Bool = false) {
        guard let audio = source.audio, let clip, !exporting else { return }
        state.studioPlayingID = nil
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
