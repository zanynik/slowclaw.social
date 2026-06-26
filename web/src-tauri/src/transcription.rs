//! On-device audio transcription for the iOS app.
//!
//! Fills the long-standing TODO with an SFSpeechRecognizer-based implementation
//! on iOS, linked via a Swift `@_cdecl` C-ABI symbol so the Rust core can call
//! it directly without needing the Tauri Swift Plugin runtime.
//!
//! Contract:
//! - `transcribe_audio_file(audio_path)` → `TranscriptionResult` on success.
//! - On iOS (with `native-inference`): delegates to the Swift SFSpeechRecognizer
//!   bridge (`slowclaw_transcribe_audio` C symbol), which enforces
//!   `requiresOnDeviceRecognition = true` so audio never leaves the device.
//! - On all other platforms / feature configurations: returns a clear error
//!   so the frontend can fall back to the existing gateway transcription path.
//!
//! The matching Swift source lives at
//! `web/src-tauri/ios/SpeechTranscriber/SpeechTranscriber.swift` and is added
//! to the Xcode project via `scripts/ios-add-speech-plugin.rb` (one-time
//! `tauri ios init` setup on a Mac). See `docs/ios-speech-plugin.md`.

use serde::Serialize;

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct TranscriptionResult {
    pub text: String,
    pub duration_seconds: f64,
}

// iOS C-ABI bridge to the Swift SFSpeechRecognizer implementation.
//
// The Swift side exports `@_cdecl("slowclaw_transcribe_audio")` with the
// matching signature. Linking succeeds once the Swift file is added to the
// iOS app target (see `scripts/ios-add-speech-plugin.rb`).
//
// Return contract:
//   >= 0 : bytes written to `out_text` (UTF-8, NUL-terminated). On success
//          `out_text` contains the transcript.
//   -1   : failure. `out_error` (when provided and `out_error_len > 0`)
//          contains a UTF-8 NUL-terminated error message.

#[cfg(all(target_os = "ios", feature = "native-inference"))]
extern "C" {
    fn slowclaw_transcribe_audio(
        audio_path: *const std::os::raw::c_char,
        out_text: *mut std::os::raw::c_char,
        out_text_len: i32,
        out_error: *mut std::os::raw::c_char,
        out_error_len: i32,
    ) -> i32;
}

#[cfg(all(target_os = "ios", feature = "native-inference"))]
fn call_ios_transcriber(audio_path: &str) -> Result<TranscriptionResult, String> {
    use std::ffi::CString;
    use std::os::raw::c_char;

    // 2 MiB is comfortably larger than any expected journal transcript.
    const TEXT_BUF_LEN: usize = 2 * 1024 * 1024;
    // 1 KiB error buffer is enough for a clear diagnostic.
    const ERROR_BUF_LEN: usize = 1024;

    let c_path = CString::new(audio_path)
        .map_err(|e| format!("audio path contains an interior NUL byte: {e}"))?;

    let mut text_buf: Vec<u8> = vec![0u8; TEXT_BUF_LEN];
    let mut error_buf: Vec<u8> = vec![0u8; ERROR_BUF_LEN];

    let status = unsafe {
        slowclaw_transcribe_audio(
            c_path.as_ptr(),
            text_buf.as_mut_ptr() as *mut c_char,
            text_buf.len() as i32,
            error_buf.as_mut_ptr() as *mut c_char,
            error_buf.len() as i32,
        )
    };

    if status < 0 {
        // Find the first NUL in the error buffer to recover the message.
        let nul_pos = error_buf
            .iter()
            .position(|&b| b == 0)
            .unwrap_or(error_buf.len());
        let raw = &error_buf[..nul_pos];
        let detail = match std::str::from_utf8(raw) {
            Ok(s) if !s.is_empty() => s.to_string(),
            Ok(_) => "unknown error (no message returned)".to_string(),
            Err(_) => "non-UTF8 error message".to_string(),
        };
        return Err(format!("iOS on-device transcription failed: {detail}"));
    }

    let nul_pos = text_buf
        .iter()
        .position(|&b| b == 0)
        .unwrap_or(text_buf.len());
    let text = std::str::from_utf8(&text_buf[..nul_pos])
        .map_err(|e| format!("transcript was not valid UTF-8: {e}"))?
        .trim()
        .to_string();

    // We don't have the audio duration from SFSpeechRecognizer here without
    // re-reading the file; leave it at 0.0 — the existing JS callers treat it
    // as advisory.
    Ok(TranscriptionResult {
        text,
        duration_seconds: 0.0,
    })
}

pub fn transcribe_audio_file(audio_path: &str) -> Result<TranscriptionResult, String> {
    let path = audio_path.trim();
    if path.is_empty() {
        return Err("audio_path is required".to_string());
    }
    if !std::path::Path::new(path).is_file() {
        return Err(format!("audio file not found: {path}"));
    }

    #[cfg(all(target_os = "ios", feature = "native-inference"))]
    {
        return call_ios_transcriber(path);
    }

    #[cfg(not(all(target_os = "ios", feature = "native-inference")))]
    {
        Err(
            "On-device audio transcription is currently iOS-only. \
             Desktop users can transcribe via the desktop gateway's faster-whisper \
             pipeline (see scripts/transcribe_audio_journal.py)."
                .to_string(),
        )
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn empty_path_is_rejected() {
        let err = transcribe_audio_file("").unwrap_err();
        assert!(err.contains("audio_path is required"));
    }

    #[test]
    fn missing_file_is_rejected() {
        let err = transcribe_audio_file("/nonexistent/path.mp4").unwrap_err();
        assert!(err.contains("audio file not found"));
    }
}