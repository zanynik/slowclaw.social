import XCTest
import UIKit
import AVFoundation

@MainActor
final class StudioMediaTests: XCTestCase {
    func testQuoteFitsEveryShapeAndExportsPNG() throws {
        let quote = "A small tool can leave more room for a meaningful thought."
        for aspect in StudioAspect.allCases {
            let image = try StudioRenderer.quote(text: quote, attribution: "SlowClawAgent", theme: .midnight, aspect: aspect)
            XCTAssertEqual(image.size, aspect.size)
            let url = try StudioExporter.quote(image)
            XCTAssertGreaterThan(try Data(contentsOf: url).count, 1000)
            try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
        }
        XCTAssertThrowsError(try StudioRenderer.quote(text: String(repeating: "word ", count: 300), attribution: "", theme: .blue, aspect: .square))
        let evidence = FileManager.default.temporaryDirectory.appendingPathComponent("StudioSmoke", isDirectory: true)
        try FileManager.default.createDirectory(at: evidence, withIntermediateDirectories: true)
        let image = try StudioRenderer.quote(text: quote, attribution: "", theme: .midnight, aspect: .portrait)
        try image.pngData()!.write(to: evidence.appendingPathComponent("quote.png"))
    }
    func testVideoAndAudioContainTheSelectedOriginalTimeRange() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("StudioSmoke", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let audio = folder.appendingPathComponent("source.caf")
        let format = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
        do {
            let file = try AVAudioFile(forWriting: audio, settings: format.settings)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 64000)!
            buffer.frameLength = 64000
            // First second is silent; selected audio has a known nonzero signal.
            for i in 0..<64000 { buffer.floatChannelData![0][i] = i < 16000 ? 0 : Float(sin(Double(i) * 2 * .pi * 440 / 16000)) * 0.2 }
            try file.write(from: buffer)
        }
        let transcript = TimedTranscript(text: "Keep a little room for thought.", words: [
            .init(text: "Keep", start: 1.1, end: 1.3), .init(text: "a", start: 1.35, end: 1.45),
            .init(text: "little", start: 1.5, end: 1.8), .init(text: "room", start: 1.9, end: 2.2),
            .init(text: "for", start: 2.3, end: 2.5), .init(text: "thought.", start: 2.6, end: 3.1)])
        let clip = try XCTUnwrap(transcript.clip(0...5, audioDuration: 4))
        let waveform = try StudioWaveform.read(audio: audio, clip: clip)
        XCTAssertGreaterThan(waveform.count, 80)
        XCTAssertGreaterThan(waveform.max() ?? 0, 0.1)
        let preview = StudioRenderer.videoFrame(clip: clip, time: 0.2, title: "A little room", theme: .blue, envelope: waveform)
        try preview.pngData()!.write(to: folder.appendingPathComponent("video-preview.png"))
        let videoURL = try await StudioExporter.video(audio: audio, clip: clip, title: "A little room", theme: .blue, showWaveform: true) { _ in }
        let video = AVURLAsset(url: videoURL)
        let videoDuration = try await video.load(.duration).seconds
        XCTAssertEqual(videoDuration, clip.duration, accuracy: 0.06)
        let videoTracks = try await video.loadTracks(withMediaType: .video)
        let audioTracks = try await video.loadTracks(withMediaType: .audio)
        XCTAssertEqual(videoTracks.count, 1); XCTAssertEqual(audioTracks.count, 1)
        let size = try await videoTracks[0].load(.naturalSize)
        XCTAssertEqual(size, CGSize(width: 720, height: 1280))
        let generator = AVAssetImageGenerator(asset: video)
        generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = .zero
        let frame = try await generator.image(at: CMTime(value: 5, timescale: 24)).image
        try UIImage(cgImage: frame).pngData()!.write(to: folder.appendingPathComponent("encoded-frame.png"))
        let destination = folder.appendingPathComponent("sample.mp4")
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.copyItem(at: videoURL, to: destination)
        let trimmedURL = try await StudioExporter.audio(audio, clip: clip)
        let trimmed = AVURLAsset(url: trimmedURL)
        let trimmedDuration = try await trimmed.load(.duration).seconds
        XCTAssertEqual(trimmedDuration, clip.duration, accuracy: 0.08)
        let trimmedWaveform = try StudioWaveform.read(audio: trimmedURL, clip: .init(start: 0, end: min(0.5, trimmedDuration), words: clip.words))
        XCTAssertGreaterThan(trimmedWaveform.max() ?? 0, 0.1, "The silent first second must not be included in the cut.")
        try? FileManager.default.removeItem(at: videoURL.deletingLastPathComponent())
        try? FileManager.default.removeItem(at: trimmedURL.deletingLastPathComponent())
    }
}
