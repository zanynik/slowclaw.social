//! On-device audio transcription placeholder.
//!
//! iOS Speech.framework transcription requires a Tauri Swift plugin to call
//! SFSpeechRecognizer properly (ObjC blocks from Rust are fragile). This module
//! provides the API surface so the frontend can call `transcribe_audio` — on iOS
//! it returns a helpful message directing the user to use the AI model for
//! summarization instead.
//!
//! A future version will add a proper Swift plugin for high-quality on-device
//! transcription via SFSpeechRecognizer.

use serde::Serialize;

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct TranscriptionResult {
    pub text: String,
    pub duration_seconds: f64,
}

pub fn transcribe_audio_file(_audio_path: &str) -> Result<TranscriptionResult, String> {
    // On iOS, SFSpeechRecognizer requires ObjC block callbacks which need a
    // Swift plugin bridge. For now, return a clear message so the frontend can
    // fall back to using the AI model for text processing.
    Err(
        "On-device audio transcription is coming soon. \
         For now, use the AI model to generate posts from your journal text."
            .to_string(),
    )
}
