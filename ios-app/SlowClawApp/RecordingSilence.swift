import Foundation
import AVFoundation

/// Removes long gaps between recognized words after a recording is finalized.
/// The transcript is the source of speech boundaries; brief pauses and padding
/// around each word remain audible.
struct RecordingSilencePlan {
    struct Segment: Equatable {
        let start: Double
        let end: Double
        var duration: Double { end - start }
    }

    let segments: [Segment]
    let transcript: TimedTranscript

    static func make(_ transcript: TimedTranscript, duration: Double) -> Self? {
        guard transcript.valid, duration.isFinite, duration > 0,
              transcript.words.allSatisfy({ $0.end <= duration + 0.1 }) else { return nil }
        var segments: [Segment] = []
        for word in transcript.words {
            let start = max(0, word.start - 0.25)
            let end = min(duration, word.end + 0.35)
            guard end > start else { return nil }
            if let last = segments.last, start - last.end <= 1.5 {
                segments[segments.count - 1] = Segment(start: last.start, end: max(last.end, end))
            } else {
                segments.append(Segment(start: start, end: end))
            }
        }
        let retained = segments.reduce(0) { $0 + $1.duration }
        guard duration - retained >= 2 else { return nil }

        var offset = 0.0
        var shifted: [TimedTranscript.Word] = []
        var index = 0
        for word in transcript.words {
            while index < segments.count - 1 && word.start > segments[index].end { offset += segments[index].duration; index += 1 }
            let segment = segments[index]
            guard word.start >= segment.start - 0.1, word.end <= segment.end + 0.1 else { return nil }
            shifted.append(.init(text: word.text,
                                 start: offset + word.start - segment.start,
                                 end: offset + word.end - segment.start))
        }
        let result = TimedTranscript(text: transcript.text, words: shifted)
        guard result.valid else { return nil }
        return Self(segments: segments, transcript: result)
    }
}

@MainActor
enum RecordingSilence {
    /// Returns false when word timing is absent or no substantial silence exists.
    /// A failed export leaves the original recording in place.
    static func trim(_ audioURL: URL, timing: TimedTranscript) async throws -> Bool {
        let asset = AVURLAsset(url: audioURL)
        let duration = CMTimeGetSeconds(try await asset.load(.duration))
        guard let plan = RecordingSilencePlan.make(timing, duration: duration) else { return false }

        let composition = AVMutableComposition()
        var cursor = CMTime.zero
        for segment in plan.segments {
            let start = CMTime(seconds: segment.start, preferredTimescale: 600)
            let length = CMTime(seconds: segment.duration, preferredTimescale: 600)
            try composition.insertTimeRange(CMTimeRange(start: start, duration: length),
                                            of: asset, at: cursor)
            cursor = CMTimeAdd(cursor, length)
        }
        guard let exporter = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetAppleM4A),
              exporter.supportedFileTypes.contains(.m4a) else {
            throw CocoaError(.fileWriteUnsupportedScheme)
        }
        let temporary = audioURL.deletingLastPathComponent()
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("m4a")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try await exporter.export(to: temporary, as: .m4a)
        guard let bytes = TimedTranscriptStore.stamp(temporary)?.size, bytes > 0 else {
            throw CocoaError(.fileReadCorruptFile)
        }
        try FileManager.default.replaceItemAt(audioURL, withItemAt: temporary)
        try TimedTranscriptStore.save(plan.transcript, for: audioURL)
        return true
    }
}
