// SpeechTranscriber.swift — on-device audio transcription bridge for the
// SlowClaw iOS app.
//
// Exposes a C-callable function (`slowclaw_transcribe_audio`) that the Rust
// core in `web/src-tauri/src/transcription.rs` calls via the C ABI. All
// recognition is on-device; audio never leaves the device.
//
// Two engines are wired, chosen at runtime by iOS version:
//   - iOS 26+:  the modern `SpeechAnalyzer` + `SpeechTranscriber` API
//               (WWDC25 Session 277). Faster, more accurate, no legacy
//               ~1-minute segment quirks, better long-form/distant audio.
//               On a non-fatal failure it falls through to the legacy path
//               so a missing model never leaves the user without a transcript.
//   - iOS < 26: the legacy `SFSpeechRecognizer` with
//               `requiresOnDeviceRecognition = true`.
//
// Threading: the entry point BLOCKS the calling thread. It is intended to be
// called from `tauri::async_runtime::spawn_blocking` (see `lib.rs`), which
// matches the "iOS API uses a sync wait" comment in the Tauri command
// registration. Authorization and the recognition task are bridged from
// their asynchronous callbacks onto a `DispatchSemaphore`.
//
// Return contract (matches the Rust `extern "C"` declaration):
//   status >= 0 : bytes written into `outText` (UTF-8, NUL-terminated).
//                 On success this is the transcript.
//   status == -1: failure. `outError` contains a UTF-8 NUL-terminated
//                 diagnostic (when its capacity permits).
//
// Add this file to the iOS app target once via:
//   ruby scripts/ios-add-speech-plugin.rb
// See docs/ios-speech-plugin.md for the full one-time Mac setup.

import Foundation
import Speech
import AVFoundation
import os

@_cdecl("slowclaw_transcribe_audio")
public func slowclaw_transcribe_audio(
    _ audioPath: UnsafePointer<CChar>,
    _ outText: UnsafeMutablePointer<CChar>,
    _ outTextLen: Int32,
    _ outError: UnsafeMutablePointer<CChar>,
    _ outErrorLen: Int32
) -> Int32 {
    func writeError(_ message: String) {
        guard outErrorLen > 0 else { return }
        let nulTerminated = message + "\0"
        let bytes = Array(nulTerminated.utf8)
        let capacity = Int(outErrorLen)
        let copyCount = min(bytes.count, capacity)
        for i in 0..<copyCount {
            outError[i] = CChar(bitPattern: bytes[i])
        }
        // Always NUL-terminate if we have room.
        if copyCount < capacity {
            outError[copyCount] = 0
        } else {
            outError[capacity - 1] = 0
        }
    }

    func writeText(_ text: String) -> Int32 {
        guard outTextLen > 0 else { return 0 }
        let nulTerminated = text + "\0"
        let bytes = Array(nulTerminated.utf8)
        let capacity = Int(outTextLen)
        let copyCount = min(bytes.count, capacity)
        for i in 0..<copyCount {
            outText[i] = CChar(bitPattern: bytes[i])
        }
        if copyCount < capacity {
            outText[copyCount] = 0
        } else {
            // Truncated; ensure NUL termination so callers don't read garbage.
            outText[capacity - 1] = 0
            // If we couldn't even fit the NUL terminator, signal overflow.
            if bytes.count > capacity {
                writeError("transcript exceeded internal buffer (\(capacity) bytes)")
            }
        }
        return Int32(copyCount)
    }

    // 1. Resolve the audio file URL.
    let pathString = String(cString: audioPath)
    let fileURL = URL(fileURLWithPath: pathString)
    guard FileManager.default.fileExists(atPath: fileURL.path) else {
        writeError("audio file does not exist: \(fileURL.path)")
        return -1
    }

    // iOS 26+ path: prefer the modern SpeechAnalyzer API (WWDC25). It removes
    // the legacy ~1-minute segment quirks, uses a newer on-device Apple model,
    // and is faster/more accurate for long-form and distant audio. On any
    // non-fatal failure we write a diagnostic and fall through to the legacy
    // SFSpeechRecognizer path below so iOS 26 users still get a transcript if
    // the new model isn't downloaded/available. Earlier iOS versions skip this
    // branch entirely and use SFSpeechRecognizer as before.
    if #available(iOS 26.0, *) {
        let wroteError = ErrorWrittenFlag()
        let analyzerStatus = slowclaw_transcribe_with_speech_analyzer(
            fileURL,
            outText, outTextLen,
            outError, outErrorLen,
            wroteError
        )
        if analyzerStatus >= 0 {
            return analyzerStatus // success: transcript written to outText
        }
        // Non-fatal fallback: only proceed to the legacy path if the new path
        // did NOT already write a hard error (e.g. permission denied). A hard
        // error means the user must act in Settings; retrying via the legacy
        // path would just produce a duplicate prompt or a confusing second
        // failure.
        if wroteError.value {
            return -1
        }
    }

    // 2. Request speech recognition authorization synchronously.
    let authSemaphore = DispatchSemaphore(value: 0)
    var authStatus: SFSpeechRecognizerAuthorizationStatus = .notDetermined
    SFSpeechRecognizer.requestAuthorization { status in
        authStatus = status
        authSemaphore.signal()
    }
    authSemaphore.wait()

    switch authStatus {
    case .authorized:
        break
    case .denied:
        writeError("Speech recognition permission was denied. Enable it in Settings.")
        return -1
    case .restricted:
        writeError("Speech recognition is restricted on this device.")
        return -1
    case .notDetermined:
        writeError("Speech recognition permission was not determined.")
        return -1
    @unknown default:
        writeError("Speech recognition returned an unknown authorization status.")
        return -1
    }

    // 3. Build a recognizer for the current locale and verify availability
    //    and on-device support. `SFSpeechRecognizer(locale:)` is a failable
    //    initializer returning `SFSpeechRecognizer?` (e.g. when the locale is
    //    unsupported or the recognizer service is unavailable). Unwrap it,
    //    then check `isAvailable` and `supportsOnDeviceRecognition`.
    let localeIdentifier = Locale.preferredLanguages.first ?? "en-US"
    guard let activeRecognizer = SFSpeechRecognizer(locale: Locale(identifier: localeIdentifier)) else {
        writeError("Speech recognizer is unavailable for locale \(localeIdentifier).")
        return -1
    }
    guard activeRecognizer.isAvailable else {
        writeError("Speech recognition is not available right now (network or service issue).")
        return -1
    }
    guard activeRecognizer.supportsOnDeviceRecognition else {
        let localeId = activeRecognizer.locale.identifier
        writeError("On-device speech recognition is not supported for locale \(localeId). Install the dictation language pack in Settings → General → Keyboard → Dictation.")
        return -1
    }

    // 4. Build the URL-backed recognition request and force on-device decoding.
    let request = SFSpeechURLRecognitionRequest(url: fileURL)
    request.shouldReportPartialResults = false
    request.requiresOnDeviceRecognition = true
    if #available(iOS 16.0, *) {
        request.addsPunctuation = true
    }

    // 5. Run the recognition task, bridging the callback onto a semaphore.
    //
    // On-device recognition can deliver LONGER audio in SEGMENTS: the handler
    // is invoked with isFinal=true once per segment, and each result's
    // bestTranscription holds only THAT segment's text. Overwriting on each
    // final left only the last segment (the "only the last line" bug for ~1min
    // recordings). Fix: append every final segment, and signal completion via a
    // short settle timer (0.8s of quiet after the last segment). For normal
    // single-final audio this adds ~0.8s of latency to a background op, which
    // is acceptable; the existing 600s timeout remains the ultimate safety net.
    let resultSemaphore = DispatchSemaphore(value: 0)
    final class ResultBox {
        var text: String?
        var error: Error?
    }
    let box = ResultBox()
    let settleQueue = DispatchQueue.global(qos: .userInitiated)
    let settleTimer = DispatchSource.makeTimerSource(queue: settleQueue)
    var signaled = false
    let signalOnce: () -> Void = {
        if !signaled {
            signaled = true
            resultSemaphore.signal()
        }
    }
    settleTimer.schedule(deadline: .now() + .seconds(600), repeating: .never)
    settleTimer.setEventHandler { signalOnce() }
    settleTimer.activate()
    // Re-arm the settle timer to `delay` seconds from now (debounce: each new
    // final segment pushes "done" out, so we only finish after the recognizer
    // goes quiet).
    func rearmSettle(_ delay: TimeInterval) {
        settleTimer.schedule(deadline: .now() + delay, repeating: .never)
    }

    let task = activeRecognizer.recognitionTask(with: request) { result, error in
        if let error = error {
            box.error = error
            settleTimer.cancel()
            signalOnce()
            return
        }
        guard let result = result else {
            // Completion with no further result and no error: finish now.
            settleTimer.cancel()
            signalOnce()
            return
        }
        if result.isFinal {
            let segment = result.bestTranscription.formattedString
            if let existing = box.text, !existing.isEmpty {
                box.text = existing + " " + segment
            } else {
                box.text = segment
            }
            // Debounce: wait a little in case another segment follows.
            rearmSettle(0.8)
        }
    }

    // Bound the total wait so a misbehaving recognizer can never wedge the
    // Tauri command thread indefinitely. The SDK should always deliver a
    // final result or an error well within this window for normal journal
    // recordings (typically < 60s for a few minutes of audio).
    let waitResult = resultSemaphore.wait(timeout: .now() + .seconds(600))
    switch waitResult {
    case .success:
        break
    case .timedOut:
        task.cancel()
        writeError("Speech recognition timed out after 600 seconds.")
        return -1
    }

    if let error = box.error {
        let nsError = error as NSError
        writeError("SFSpeechRecognizer error: \(nsError.localizedDescription) (domain=\(nsError.domain), code=\(nsError.code))")
        return -1
    }
    guard let transcript = box.text, !transcript.isEmpty else {
        writeError("Speech recognition produced no transcript (silent audio or unrecognized speech).")
        return -1
    }

    return writeText(transcript)
}

// MARK: - iOS 26 SpeechAnalyzer path

/// Box so the caller can tell whether a hard error was already written into
/// `outError` (and thus the legacy fallback should not run).
final class ErrorWrittenFlag {
    var value = false
}

/// Transcribes `fileURL` using the iOS 26 `SpeechAnalyzer` + `SpeechTranscriber`
/// API (WWDC25 Session 277). Same return contract as the entry point:
///   >= 0 : bytes written to `outText`
///   -1   : failure, with a diagnostic in `outError` when `wroteError` is set.
///
/// On a NON-fatal failure (engine unavailable, model missing), this returns -1
/// WITHOUT writing an error and WITHOUT setting `wroteError`, so the caller can
/// fall back to the legacy `SFSpeechRecognizer` path. On a fatal failure
/// (permission denied), it writes the error and sets `wroteError = true`.
///
/// The async work runs on a detached `Task`; the C entry point blocks this
/// thread on a `DispatchSemaphore` (it is always called from
/// `tauri::async_runtime::spawn_blocking`). Pointer writes happen here, on the
/// calling thread, after the task completes — never from the async context.
@available(iOS 26.0, *)
func slowclaw_transcribe_with_speech_analyzer(
    _ fileURL: URL,
    _ outText: UnsafeMutablePointer<CChar>,
    _ outTextLen: Int32,
    _ outError: UnsafeMutablePointer<CChar>,
    _ outErrorLen: Int32,
    _ wroteError: ErrorWrittenFlag
) -> Int32 {
    let logger = OSLog(subsystem: "com.slowclaw.app", category: "SpeechAnalyzer")

    // Capture out-pointers in a closure that only the CALLING thread runs, and
    // only after the async work is done. This keeps all C-pointer writes off the
    // concurrent async executor (strict aliasing / Sendable safety).
    func finalize(with result: Result<String, TranscribeFailure>) -> Int32 {
        switch result {
        case .success(let transcript):
            // If the transcript didn't fit, surface a truncation note in the
            // error buffer (mirrors the legacy writeText overflow behavior).
            let byteLen = Int32((transcript + "\0").utf8.count)
            if byteLen > outTextLen {
                writeCString(
                    "transcript exceeded internal buffer (\(outTextLen) bytes)",
                    into: outError,
                    capacity: outErrorLen
                )
            }
            return writeCString(transcript, into: outText, capacity: outTextLen)
        case .failure(let failure):
            if failure.isHard {
                wroteError.value = true
                writeCString(
                    failure.message,
                    into: outError,
                    capacity: outErrorLen
                )
            }
            return -1
        }
    }

    // Bridge async → sync with the same 600s ultimate safety net the legacy
    // path uses, so a misbehaving recognizer can never wedge the command thread.
    let done = DispatchSemaphore(value: 0)
    var outcome: Result<String, TranscribeFailure> = .failure(
        TranscribeFailure(message: "SpeechAnalyzer did not complete.", isHard: false)
    )

    let task = Task.detached(priority: .userInitiated) {
        let result = transcribeFileWithSpeechAnalyzer(fileURL: fileURL, logger: logger)
        outcome = result
        done.signal()
    }

    let waitResult = done.wait(timeout: .now() + .seconds(600))
    if waitResult == .timedOut {
        task.cancel()
        // Soft-fail so the legacy path gets a chance to produce a transcript.
        return finalize(with: .failure(
            TranscribeFailure(message: "SpeechAnalyzer timed out after 600s.", isHard: false)
        ))
    }
    return finalize(with: outcome)
}

/// Distinguishes failures that should abort (hard) from those that should fall
/// back to the legacy path (soft). Permission denial is hard; engine/model/
/// decode availability issues are soft.
struct TranscribeFailure {
    let message: String
    let isHard: Bool
}

/// Reference type so a `Task` can write a thrown error out for the caller to
/// inspect after the task completes.
final class ErrorBox {
    var error: Error?
}

/// The actual iOS 26 transcription engine. Reads the audio file as PCM buffers,
/// feeds them to a `SpeechAnalyzer` via an `AsyncStream`, accumulates finalized
/// transcript segments, and finalizes the session. Mirrors the proven pattern
/// from the Swift Scribe reference app, adapted for whole-file input.
@available(iOS 26.0, *)
private func transcribeFileWithSpeechAnalyzer(
    fileURL: URL,
    logger: OSLog
) async -> Result<String, TranscribeFailure> {
    // Authorization: SpeechAnalyzer reuses the shared Speech-framework
    // authorization (see developer.apple.com/documentation/speech/asking-
    // permission-to-use-speech-recognition). Request it once up front.
    let authStatus = await withCheckedContinuation {
        (continuation: CheckedContinuation<SFSpeechRecognizerAuthorizationStatus, Never>) in
        SFSpeechRecognizer.requestAuthorization { status in
            continuation.resume(returning: status)
        }
    }
    switch authStatus {
    case .authorized:
        break
    case .denied:
        return .failure(TranscribeFailure(
            message: "Speech recognition permission was denied. Enable it in Settings.",
            isHard: true
        ))
    case .restricted:
        return .failure(TranscribeFailure(
            message: "Speech recognition is restricted on this device.",
            isHard: true
        ))
    case .notDetermined:
        return .failure(TranscribeFailure(
            message: "Speech recognition permission was not determined.",
            isHard: true
        ))
    @unknown default:
        return .failure(TranscribeFailure(
            message: "Speech recognition returned an unknown authorization status.",
            isHard: true
        ))
    }

    let localeIdentifier = Locale.preferredLanguages.first ?? "en-US"
    let locale = Locale(identifier: localeIdentifier)

    // Build the SpeechTranscriber module + the analyzer that owns it.
    let transcriber = SpeechTranscriber(
        locale: locale,
        transcriptionOptions: [],
        reportingOptions: [.volatileResults],
        attributeOptions: [.audioTimeRange]
    )

    // Ensure the on-device model is available. First use for a locale may
    // download it (later runs are fully local). Treat unavailable/unsupported
    // as a SOFT failure so the legacy SFSpeechRecognizer path can try instead.
    do {
        if let installer = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            os_log("Downloading SpeechAnalyzer on-device model…", log: logger)
            try await installer.downloadAndInstall()
        }
        try await AssetInventory.reserve(locale: locale)
    } catch {
        return .failure(TranscribeFailure(
            message: "SpeechAnalyzer model unavailable for \(locale.identifier): \(error.localizedDescription)",
            isHard: false
        ))
    }

    let analyzer = SpeechAnalyzer(modules: [transcriber])

    guard let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else {
        return .failure(TranscribeFailure(
            message: "SpeechAnalyzer reported no compatible audio format.",
            isHard: false
        ))
    }

    // Open the file and prepare conversion into the analyzer's expected format.
    let audioFile: AVAudioFile
    do {
        audioFile = try AVAudioFile(forReading: fileURL)
    } catch {
        return .failure(TranscribeFailure(
            message: "Could not open audio file: \(error.localizedDescription)",
            isHard: false
        ))
    }

    let converter = AVAudioConverter(from: audioFile.processingFormat, to: analyzerFormat)

    // AsyncStream the converted PCM buffers into the analyzer.
    let (inputStream, inputContinuation) = AsyncStream<AnalyzerInput>.makeStream()

    // Accumulate finalized transcript segments on a single actor to avoid data
    // races across the async result stream. Volatile (non-final) results are
    // ignored — we only want the committed text, matching the legacy contract.
    actor TranscriptAccumulator {
        var parts: [String] = []
        func append(_ text: String) { parts.append(text) }
        func joined() -> String { parts.joined(separator: " ") }
    }
    let accumulator = TranscriptAccumulator()

    // Capture any error thrown from the result stream so a mid-stream
    // recognition failure surfaces as a real diagnostic rather than an
    // empty-transcript failure.
    let errorBox = ErrorBox()
    let collectTask = Task {
        do {
            for try await result in transcriber.results {
                if result.isFinal {
                    await accumulator.append(String(result.text))
                }
            }
        } catch {
            errorBox.error = error
        }
    }

    do {
        try await analyzer.start(inputSequence: inputStream)
    } catch {
        inputContinuation.finish()
        collectTask.cancel()
        return .failure(TranscribeFailure(
            message: "SpeechAnalyzer failed to start: \(error.localizedDescription)",
            isHard: false
        ))
    }

    // Read the whole file and pump converted buffers into the stream.
    let readFrameCapacity = AVAudioFrameCount(audioFile.length)
    guard readFrameCapacity > 0,
          let readBuffer = AVAudioPCMBuffer(pcmFormat: audioFile.processingFormat, frameCapacity: readFrameCapacity)
    else {
        inputContinuation.finish()
        return .failure(TranscribeFailure(
            message: "Audio file appears empty or unreadable.",
            isHard: false
        ))
    }

    do {
        try audioFile.read(into: readBuffer)
    } catch {
        inputContinuation.finish()
        return .failure(TranscribeFailure(
            message: "Failed reading audio samples: \(error.localizedDescription)",
            isHard: false
        ))
    }

    if let converter {
        // Convert the single read buffer into the analyzer format, then yield.
        // (Journal recordings are short; a single whole-file conversion is fine.
        // If this ever needs to stream very long files, switch to chunked reads
        // feeding AVAudioConverter's render callback — same as the reference.)
        let ratio = analyzerFormat.sampleRate / audioFile.processingFormat.sampleRate
        let outFrames = AVAudioFrameCount((Double(readBuffer.frameLength) * ratio).rounded(.up))
        guard outFrames > 0,
              let outBuffer = AVAudioPCMBuffer(pcmFormat: analyzerFormat, frameCapacity: outFrames)
        else {
            inputContinuation.finish()
            return .failure(TranscribeFailure(message: "Audio format conversion produced no samples.", isHard: false))
        }
        var conversionError: NSError?
        var consumed = false
        let convStatus = converter.convert(to: outBuffer, error: &conversionError) { _, status in
            if consumed {
                status.pointee = .noDataNow
                return nil
            }
            consumed = true
            status.pointee = .haveData
            return readBuffer
        }
        if convStatus == .error {
            inputContinuation.finish()
            return .failure(TranscribeFailure(
                message: "Audio format conversion failed: \(conversionError?.localizedDescription ?? "unknown")",
                isHard: false
            ))
        }
        inputContinuation.yield(AnalyzerInput(buffer: outBuffer))
    } else {
        // Processing format already matches the analyzer format.
        inputContinuation.yield(AnalyzerInput(buffer: readBuffer))
    }

    // Signal end-of-input, then finalize so the last segment is committed.
    inputContinuation.finish()
    do {
        try await analyzer.finalizeAndFinishThroughEndOfInput()
    } catch {
        collectTask.cancel()
        return .failure(TranscribeFailure(
            message: "SpeechAnalyzer failed to finalize: \(error.localizedDescription)",
            isHard: false
        ))
    }

    // Drain any remaining results.
    await collectTask.value

    if let streamError = errorBox.error {
        return .failure(TranscribeFailure(
            message: "SpeechAnalyzer result stream failed: \(streamError.localizedDescription)",
            isHard: false
        ))
    }

    let transcript = await accumulator.joined().trimmingCharacters(in: .whitespacesAndNewlines)
    if transcript.isEmpty {
        return .failure(TranscribeFailure(
            message: "SpeechAnalyzer produced no transcript (silent audio or unrecognized speech).",
            isHard: false
        ))
    }
    return .success(transcript)
}

// MARK: - C-buffer write helpers (shared)

/// Writes a NUL-terminated UTF-8 string into a C char buffer.
/// Returns the byte count written (excluding the NUL), or 0 if the buffer has
/// no capacity. Always NUL-terminates if there is room (truncating safely).
@inline(__always)
private func writeCString(
    _ text: String,
    into buffer: UnsafeMutablePointer<CChar>,
    capacity: Int32
) -> Int32 {
    guard capacity > 0 else { return 0 }
    let nulTerminated = text + "\0"
    let bytes = Array(nulTerminated.utf8)
    let cap = Int(capacity)
    let copyCount = min(bytes.count, cap)
    for i in 0..<copyCount {
        buffer[i] = CChar(bitPattern: bytes[i])
    }
    if copyCount < cap {
        buffer[copyCount] = 0
    } else {
        buffer[cap - 1] = 0
    }
    return Int32(copyCount)
}