// SpeechTranscriber.swift — on-device audio transcription bridge for the
// SlowClaw iOS app.
//
// Exposes a C-callable function (`slowclaw_transcribe_audio`) that the Rust
// core in `web/src-tauri/src/transcription.rs` calls via the C ABI. The
// implementation uses Apple's SFSpeechRecognizer with
// `requiresOnDeviceRecognition = true`, so audio never leaves the device.
//
// Threading: this function BLOCKS the calling thread. It is intended to be
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