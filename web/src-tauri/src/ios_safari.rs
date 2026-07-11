// ios_safari.rs — Rust side of the SFSafariViewController bridge.
//
// `open_in_app_webview` (see `commands/desktop.rs`) routes iOS article-link
// opens through this module: instead of creating a second WebviewWindow (which
// Tauri 2 mobile cannot dismiss), we present Apple's native
// `SFSafariViewController`, giving the user a Done button + swipe-to-dismiss.
//
// This mirrors the `transcription.rs` ↔ `SpeechTranscriber.swift` bridge
// pattern: a Swift `@_cdecl("slowclaw_open_safari_vc")` symbol is resolved at
// the final Xcode app link (see `scripts/ios-add-safari-opener.rb`), and the
// Rust crate declares the `extern "C"` counterpart gated to `target_os = "ios"`.
// Unlike transcription, the call is fire-and-forget — the Swift side dispatches
// the presentation onto the main thread and returns immediately.
//
// The symbol is intentionally NOT gated on the `native-inference` feature: the
// in-app reader is a core feature, independent of on-device inference.

#[cfg(target_os = "ios")]
extern "C" {
    fn slowclaw_open_safari_vc(
        url: *const std::os::raw::c_char,
        out_error: *mut std::os::raw::c_char,
        out_error_len: i32,
    ) -> i32;
}

/// Present `url` in a native `SFSafariViewController` over the app's topmost
/// view controller. iOS-only; returns an error on every other target so callers
/// can fall back to the desktop webview path.
///
/// Contract mirrors `transcription::call_ios_transcriber`: returns `Ok(())` when
/// the Swift bridge reports success (status >= 0), or `Err(message)` on failure
/// (status < 0), recovering the diagnostic from the fixed-size error buffer.
#[cfg(target_os = "ios")]
pub(crate) fn ios_open_safari_vc(url: &str) -> Result<(), String> {
    use std::ffi::CString;
    use std::os::raw::c_char;

    const ERROR_BUF_LEN: usize = 1024;

    let c_url = CString::new(url)
        .map_err(|e| format!("url contains an interior NUL byte: {e}"))?;

    let mut error_buf: Vec<u8> = vec![0u8; ERROR_BUF_LEN];

    let status = unsafe {
        slowclaw_open_safari_vc(
            c_url.as_ptr(),
            error_buf.as_mut_ptr() as *mut c_char,
            error_buf.len() as i32,
        )
    };

    if status < 0 {
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
        return Err(format!("iOS Safari presenter failed: {detail}"));
    }

    Ok(())
}

#[cfg(not(target_os = "ios"))]
/// Non-iOS stub. The caller (`open_in_app_webview`) uses the desktop
/// `WebviewWindow` path on these targets and never reaches this helper; the
/// stub exists so the module compiles without `#[cfg]` gymnastics at call sites.
#[allow(dead_code)]
pub(crate) fn ios_open_safari_vc(_url: &str) -> Result<(), String> {
    Err("SFSafariViewController is only available on iOS.".to_string())
}
