import UIKit
import AVFoundation

struct StudioError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

enum StudioTheme: String, CaseIterable, Codable, Identifiable {
    case midnight = "Midnight", blue = "Cobalt", paper = "Paper"
    var id: String { rawValue }
    var background: UIColor {
        switch self {
        case .midnight: return UIColor(red: 0.035, green: 0.04, blue: 0.055, alpha: 1)
        case .blue: return UIColor(red: 0.08, green: 0.16, blue: 0.72, alpha: 1)
        case .paper: return UIColor(red: 0.96, green: 0.95, blue: 0.91, alpha: 1)
        }
    }
    var foreground: UIColor { self == .paper ? .black : .white }
    var accent: UIColor { self == .paper ? UIColor(red: 0.08, green: 0.2, blue: 0.65, alpha: 1) : UIColor(red: 0.4, green: 0.95, blue: 0.85, alpha: 1) }
}

enum StudioAspect: String, CaseIterable, Codable, Identifiable {
    case portrait = "Post 4:5", story = "Story 9:16", square = "Square"
    var id: String { rawValue }
    var size: CGSize {
        switch self {
        case .portrait: return CGSize(width: 1080, height: 1350)
        case .story: return CGSize(width: 1080, height: 1920)
        case .square: return CGSize(width: 1080, height: 1080)
        }
    }
}

/// The preview and exported asset use the same native drawing code.
@MainActor
enum StudioRenderer {
    private static func format() -> UIGraphicsImageRendererFormat {
        let value = UIGraphicsImageRendererFormat(); value.scale = 1; value.opaque = true
        return value
    }
    static func fittedFont(text: String, box: CGSize, maximum: CGFloat, minimum: CGFloat) -> UIFont? {
        let paragraph = NSMutableParagraphStyle(); paragraph.lineSpacing = 8
        for size in stride(from: maximum, through: minimum, by: -2) {
            let font = UIFont.systemFont(ofSize: size, weight: .bold)
            let rect = (text as NSString).boundingRect(with: CGSize(width: box.width, height: .greatestFiniteMagnitude), options: [.usesLineFragmentOrigin, .usesFontLeading], attributes: [.font: font, .paragraphStyle: paragraph], context: nil)
            if ceil(rect.height) <= box.height { return font }
        }
        return nil
    }
    static func quote(text: String, attribution: String, theme: StudioTheme, aspect: StudioAspect) throws -> UIImage {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count <= 600, attribution.count <= 80 else { throw StudioError(message: "Use a quote of up to 600 characters and a name of up to 80.") }
        let size = aspect.size
        let box = CGRect(x: 92, y: 245, width: size.width - 184, height: size.height - 440)
        guard let font = fittedFont(text: text, box: box.size, maximum: 88, minimum: 36) else { throw StudioError(message: "Shorten this quote or choose a taller card so the text stays readable.") }
        return UIGraphicsImageRenderer(size: size, format: format()).image { context in
            theme.background.setFill(); context.fill(CGRect(origin: .zero, size: size))
            ("“" as NSString).draw(at: CGPoint(x: 83, y: 65), withAttributes: [.font: UIFont.systemFont(ofSize: 170, weight: .bold), .foregroundColor: theme.accent])
            let paragraph = NSMutableParagraphStyle(); paragraph.lineSpacing = 8
            (text as NSString).draw(in: box, withAttributes: [.font: font, .foregroundColor: theme.foreground, .paragraphStyle: paragraph])
            (attribution as NSString).draw(in: CGRect(x: 92, y: size.height - 130, width: size.width - 184, height: 65), withAttributes: [.font: UIFont.systemFont(ofSize: 30, weight: .medium), .foregroundColor: theme.foreground.withAlphaComponent(0.7)])
        }
    }
    static func videoFrame(clip: TimedTranscript.Clip, time: Double, title: String, theme: StudioTheme, envelope: [Float], width: CGFloat = 720) -> UIImage {
        let scale = width / 720
        return UIGraphicsImageRenderer(size: CGSize(width: width, height: 1280 * scale), format: format()).image { renderer in
            let ctx = renderer.cgContext; ctx.scaleBy(x: scale, y: scale)
            theme.background.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 720, height: 1280))
            (String(title.prefix(80)) as NSString).draw(in: CGRect(x: 60, y: 120, width: 600, height: 160), withAttributes: [.font: UIFont.systemFont(ofSize: 28, weight: .medium), .foregroundColor: theme.foreground.withAlphaComponent(0.7)])
            let page = clip.page(at: time)
            let text = page.words.map(\.text).joined(separator: " ")
            let box = CGRect(x: 60, y: 365, width: 600, height: 500)
            let font = fittedFont(text: text, box: box.size, maximum: 62, minimum: 28) ?? UIFont.systemFont(ofSize: 28, weight: .bold)
            let paragraph = NSMutableParagraphStyle(); paragraph.lineSpacing = 8
            let attributed = NSMutableAttributedString(string: text, attributes: [.font: font, .foregroundColor: theme.foreground, .paragraphStyle: paragraph])
            if let active = page.active {
                let offset = page.words.prefix(active).reduce(0) { $0 + $1.text.utf16.count + 1 }
                attributed.addAttribute(.foregroundColor, value: theme.accent, range: NSRange(location: offset, length: page.words[active].text.utf16.count))
            }
            attributed.draw(in: box)
            let progress = max(0, min(1, time / clip.duration))
            if !envelope.isEmpty {
                let peak = max(0.01, envelope.max() ?? 0.01)
                for bar in 0..<72 {
                    let lower = bar * envelope.count / 72
                    let upper = max(lower + 1, (bar + 1) * envelope.count / 72)
                    let value = envelope[lower..<min(upper, envelope.count)].max() ?? 0
                    let height = max(3, CGFloat(sqrt(value / peak)) * 105)
                    (Double(bar) / 72 <= progress ? theme.accent : theme.foreground.withAlphaComponent(0.25)).setFill()
                    UIBezierPath(roundedRect: CGRect(x: 60 + CGFloat(bar) * 8.33, y: 1020 - height / 2, width: 4, height: height), cornerRadius: 2).fill()
                }
            }
            theme.foreground.withAlphaComponent(0.2).setFill(); ctx.fill(CGRect(x: 60, y: 1140, width: 600, height: 3))
            theme.accent.setFill(); ctx.fill(CGRect(x: 60, y: 1140, width: 600 * progress, height: 3))
        }
    }
}

/// Bounded PCM reads; values describe the actual selected recording.
enum StudioWaveform {
    static func read(audio: URL, clip: TimedTranscript.Clip) throws -> [Float] {
        let file = try AVAudioFile(forReading: audio, commonFormat: .pcmFormatFloat32, interleaved: false)
        let format = file.processingFormat
        guard format.sampleRate > 0, format.channelCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096) else { throw StudioError(message: "Cannot read the recording waveform.") }
        file.framePosition = AVAudioFramePosition(clip.start * format.sampleRate)
        var remaining = min(file.length - file.framePosition, AVAudioFramePosition(clip.duration * format.sampleRate))
        let binSize = max(1, Int(format.sampleRate / 50))
        var sum: Float = 0; var count = 0; var levels: [Float] = []
        while remaining > 0 {
            try Task.checkCancellation()
            try file.read(into: buffer, frameCount: AVAudioFrameCount(min(4096, remaining)))
            guard buffer.frameLength > 0, let channels = buffer.floatChannelData else { throw StudioError(message: "The recording ended before the selected clip.") }
            for index in 0..<Int(buffer.frameLength) {
                var power: Float = 0
                for channel in 0..<Int(format.channelCount) { power += channels[channel][index] * channels[channel][index] }
                sum += power / Float(format.channelCount); count += 1
                if count == binSize { levels.append(sqrt(sum / Float(count))); sum = 0; count = 0 }
            }
            remaining -= AVAudioFramePosition(buffer.frameLength)
        }
        if count > 0 { levels.append(sqrt(sum / Float(count))) }
        return levels
    }
}

@MainActor
enum StudioExporter {
    static func directory() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("SlowClaw-Studio", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        // Keep completed shares alive for receiving apps, then expire after a day.
        for url in (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [] {
            if let date = try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate, date < Date().addingTimeInterval(-86400) { try? FileManager.default.removeItem(at: url) }
        }
        let folder = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }
    static func quote(_ image: UIImage) throws -> URL {
        let url = try directory().appendingPathComponent("Quote.png")
        guard let data = image.pngData() else { throw StudioError(message: "Could not render the quote card.") }
        try data.write(to: url, options: [.atomic, .completeFileProtection])
        return url
    }
    static func audio(_ source: URL, clip: TimedTranscript.Clip) async throws -> URL {
        guard clip.duration > 0, clip.duration <= 90 else { throw StudioError(message: "Choose up to 90 seconds of audio.") }
        let folder = try directory()
        var succeeded = false
        defer { if !succeeded { try? FileManager.default.removeItem(at: folder) } }
        let url = folder.appendingPathComponent("Voice-clip.m4a")
        guard let export = AVAssetExportSession(asset: AVURLAsset(url: source), presetName: AVAssetExportPresetAppleM4A) else { throw StudioError(message: "Cannot export this audio recording.") }
        export.timeRange = CMTimeRange(start: CMTime(seconds: clip.start, preferredTimescale: 600), duration: CMTime(seconds: clip.duration, preferredTimescale: 600))
        try await withTaskCancellationHandler {
            try await export.export(to: url, as: .m4a)
        } onCancel: { export.cancelExport() }
        try Task.checkCancellation()
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: url.path)
        succeeded = true
        return url
    }
    static func video(audio: URL, clip: TimedTranscript.Clip, title: String, theme: StudioTheme, showWaveform: Bool, progress: @escaping (Double) -> Void) async throws -> URL {
        guard clip.duration > 0, clip.duration <= 90, !clip.words.isEmpty else { throw StudioError(message: "Choose a clip of up to 90 seconds.") }
        let folder = try directory()
        var succeeded = false
        defer { if !succeeded { try? FileManager.default.removeItem(at: folder) } }
        let silentURL = folder.appendingPathComponent("frames.mp4")
        let finalURL = folder.appendingPathComponent("Audio-story.mp4")
        let waveform = showWaveform ? try await Task.detached(priority: .userInitiated) { try StudioWaveform.read(audio: audio, clip: clip) }.value : []
        try Task.checkCancellation()
        let writer = try AVAssetWriter(outputURL: silentURL, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 720, AVVideoHeightKey: 1280, AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 3_000_000, AVVideoAllowFrameReorderingKey: false, AVVideoExpectedSourceFrameRateKey: 24, AVVideoMaxKeyFrameIntervalKey: 24]])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey as String: 720, kCVPixelBufferHeightKey as String: 1280, kCVPixelBufferCGImageCompatibilityKey as String: true, kCVPixelBufferCGBitmapContextCompatibilityKey as String: true, kCVPixelBufferIOSurfacePropertiesKey as String: [:]])
        guard writer.canAdd(input) else { throw StudioError(message: "Video export is unavailable.") }
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? StudioError(message: "Could not start video export.") }
        writer.startSession(atSourceTime: .zero)
        let pump = StudioFramePump(writer: writer, input: input, adaptor: adaptor, clip: clip, title: title, theme: theme, waveform: waveform, progress: progress)
        try await pump.run()
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? StudioError(message: "Video encoding failed.") }
        try Task.checkCancellation()
        let source = AVURLAsset(url: audio), video = AVURLAsset(url: silentURL)
        let composition = AVMutableComposition()
        guard let videoTrack = try await video.loadTracks(withMediaType: .video).first,
              let audioTrack = try await source.loadTracks(withMediaType: .audio).first,
              let v = composition.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid),
              let a = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else { throw StudioError(message: "The original recording has no usable audio track.") }
        let duration = CMTime(seconds: clip.duration, preferredTimescale: 600)
        try v.insertTimeRange(CMTimeRange(start: .zero, duration: duration), of: videoTrack, at: .zero)
        try a.insertTimeRange(CMTimeRange(start: CMTime(seconds: clip.start, preferredTimescale: 600), duration: duration), of: audioTrack, at: .zero)
        guard let export = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetHighestQuality) else { throw StudioError(message: "Cannot prepare the final video.") }
        export.shouldOptimizeForNetworkUse = true
        try await withTaskCancellationHandler {
            try await export.export(to: finalURL, as: .mp4)
        } onCancel: { export.cancelExport() }
        try Task.checkCancellation()
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: finalURL.path)
        try? FileManager.default.removeItem(at: silentURL)
        progress(1); succeeded = true
        return finalURL
    }
}

/// AVFoundation pulls offline frames when its encoder can accept them. All
/// state and UIKit drawing stay on the main queue; waiting never blocks it.
@MainActor
private final class StudioFramePump {
    let writer: AVAssetWriter
    let input: AVAssetWriterInput
    let adaptor: AVAssetWriterInputPixelBufferAdaptor
    let clip: TimedTranscript.Clip
    let title: String
    let theme: StudioTheme
    let waveform: [Float]
    let progress: (Double) -> Void
    var frame = 0
    var lastAdvance = Date()
    var continuation: CheckedContinuation<Void, Error>?
    var watchdog: Task<Void, Never>?
    var frames: Int { Int(ceil(clip.duration * 24)) }
    init(writer: AVAssetWriter, input: AVAssetWriterInput, adaptor: AVAssetWriterInputPixelBufferAdaptor, clip: TimedTranscript.Clip, title: String, theme: StudioTheme, waveform: [Float], progress: @escaping (Double) -> Void) {
        self.writer = writer; self.input = input; self.adaptor = adaptor
        self.clip = clip; self.title = title; self.theme = theme
        self.waveform = waveform; self.progress = progress
    }
    func run() async throws {
        try Task.checkCancellation()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                input.requestMediaDataWhenReady(on: .main) { [weak self] in
                    MainActor.assumeIsolated { self?.pump() }
                }
                watchdog = Task { [self] in
                    while !Task.isCancelled {
                        do { try await Task.sleep(nanoseconds: 1_000_000_000) } catch { return }
                        if Date().timeIntervalSince(lastAdvance) > 30 {
                            finish(StudioError(message: "Video export stalled at frame \(frame) of \(frames). Please retry.")); return
                        }
                    }
                }
            }
        } onCancel: {
            Task { @MainActor [self] in finish(CancellationError()) }
        }
    }
    private func finish(_ error: Error? = nil) {
        guard let pending = continuation else { return }
        continuation = nil; watchdog?.cancel(); watchdog = nil
        if let error { writer.cancelWriting(); pending.resume(throwing: error) }
        else {
            writer.endSession(atSourceTime: CMTime(seconds: clip.duration, preferredTimescale: 600))
            input.markAsFinished(); pending.resume()
        }
    }
    private func pump() {
        guard continuation != nil else { return }
        do {
            while input.isReadyForMoreMediaData, frame < frames {
                try appendFrame()
                frame += 1; lastAdvance = Date()
                if frame % 6 == 0 { progress(Double(frame) / Double(frames) * 0.85) }
            }
            if frame == frames { finish() }
            else if writer.status != .writing { finish(writer.error ?? StudioError(message: "Video encoding failed.")) }
        } catch { finish(error) }
    }
    private func appendFrame() throws {
        try autoreleasepool {
            let image = StudioRenderer.videoFrame(clip: clip, time: Double(frame) / 24, title: title, theme: theme, envelope: waveform)
            var optional: CVPixelBuffer?
            guard let pool = adaptor.pixelBufferPool, CVPixelBufferPoolCreatePixelBuffer(nil, pool, &optional) == kCVReturnSuccess, let buffer = optional else { throw StudioError(message: "Not enough memory to render video.") }
            do {
                CVPixelBufferLockBaseAddress(buffer, [])
                defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
                guard let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: 720, height: 1280, bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue), let cgImage = image.cgImage else { throw StudioError(message: "Could not draw a video frame.") }
                context.draw(cgImage, in: CGRect(x: 0, y: 0, width: 720, height: 1280))
            }
            guard adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(frame), timescale: 24)) else { throw writer.error ?? StudioError(message: "Could not encode a video frame.") }
        }
    }
}
