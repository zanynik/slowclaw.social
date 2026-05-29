//! On-device audio transcription using iOS Speech.framework.
//!
//! Calls SFSpeechRecognizer via Objective-C runtime from Rust using the
//! `block2` crate for completion handler blocks.
//!
//! On non-iOS/macOS platforms, returns an error.

use serde::Serialize;

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct TranscriptionResult {
    pub text: String,
    pub duration_seconds: f64,
}

// ── iOS / macOS implementation ───────────────────────────────────────────────

#[cfg(any(target_os = "ios", target_os = "macos"))]
#[cfg(feature = "native-inference")]
mod platform {
    use super::*;
    use block2::RcBlock;
    use std::ffi::CStr;
    use std::os::raw::c_char;
    use std::sync::{Arc, Condvar, Mutex};
    use std::time::Duration;

    // Raw ObjC runtime types
    type Id = *mut std::ffi::c_void;
    type Sel = *mut std::ffi::c_void;
    type Class = *mut std::ffi::c_void;

    extern "C" {
        fn objc_getClass(name: *const c_char) -> Class;
        fn sel_registerName(name: *const c_char) -> Sel;
        fn objc_msgSend() -> *mut std::ffi::c_void; // variadic, called via transmute
    }

    unsafe fn get_class(name: &str) -> Id {
        let cname = std::ffi::CString::new(name).unwrap();
        objc_getClass(cname.as_ptr()) as Id
    }

    unsafe fn get_sel(name: &str) -> Sel {
        let cname = std::ffi::CString::new(name).unwrap();
        sel_registerName(cname.as_ptr())
    }

    unsafe fn msg_send_0(obj: Id, sel: Sel) -> Id {
        let f: unsafe extern "C" fn(Id, Sel) -> Id = std::mem::transmute(objc_msgSend as *const ());
        f(obj, sel)
    }

    unsafe fn msg_send_1(obj: Id, sel: Sel, arg1: Id) -> Id {
        let f: unsafe extern "C" fn(Id, Sel, Id) -> Id =
            std::mem::transmute(objc_msgSend as *const ());
        f(obj, sel, arg1)
    }

    unsafe fn msg_send_bool(obj: Id, sel: Sel) -> bool {
        let f: unsafe extern "C" fn(Id, Sel) -> i8 =
            std::mem::transmute(objc_msgSend as *const ());
        f(obj, sel) != 0
    }

    unsafe fn msg_send_set_bool(obj: Id, sel: Sel, val: bool) {
        let f: unsafe extern "C" fn(Id, Sel, i8) =
            std::mem::transmute(objc_msgSend as *const ());
        f(obj, sel, val as i8);
    }

    unsafe fn nsstring_create(s: &str) -> Id {
        let cls = get_class("NSString");
        let sel = get_sel("stringWithUTF8String:");
        let cstr = std::ffi::CString::new(s).unwrap();
        let f: unsafe extern "C" fn(Id, Sel, *const c_char) -> Id =
            std::mem::transmute(objc_msgSend as *const ());
        f(cls, sel, cstr.as_ptr())
    }

    unsafe fn nsstring_to_rust(ns: Id) -> String {
        if ns.is_null() {
            return String::new();
        }
        let sel = get_sel("UTF8String");
        let f: unsafe extern "C" fn(Id, Sel) -> *const c_char =
            std::mem::transmute(objc_msgSend as *const ());
        let ptr = f(ns, sel);
        if ptr.is_null() {
            return String::new();
        }
        CStr::from_ptr(ptr).to_string_lossy().into_owned()
    }

    pub fn transcribe_audio_file(audio_path: &str) -> Result<TranscriptionResult, String> {
        if !std::path::Path::new(audio_path).is_file() {
            return Err(format!("Audio file not found: {audio_path}"));
        }
        eprintln!("[transcription] Starting: {audio_path}");

        unsafe {
            // NSURL *fileURL = [NSURL fileURLWithPath:@"..."];
            let ns_path = nsstring_create(audio_path);
            let file_url = msg_send_1(
                get_class("NSURL") as Id,
                get_sel("fileURLWithPath:"),
                ns_path,
            );
            if file_url.is_null() {
                return Err("Failed to create NSURL".to_string());
            }

            // SFSpeechRecognizer *recognizer = [[SFSpeechRecognizer alloc] init];
            let recognizer = msg_send_0(
                msg_send_0(get_class("SFSpeechRecognizer") as Id, get_sel("alloc")),
                get_sel("init"),
            );
            if recognizer.is_null() {
                return Err("SFSpeechRecognizer not available".to_string());
            }

            if !msg_send_bool(recognizer, get_sel("isAvailable")) {
                return Err(
                    "Speech recognition unavailable. Check Settings > Privacy > Speech Recognition."
                        .to_string(),
                );
            }

            // SFSpeechURLRecognitionRequest *request = [[... alloc] initWithURL:fileURL];
            let request = msg_send_1(
                msg_send_0(
                    get_class("SFSpeechURLRecognitionRequest") as Id,
                    get_sel("alloc"),
                ),
                get_sel("initWithURL:"),
                file_url,
            );
            if request.is_null() {
                return Err("Failed to create recognition request".to_string());
            }

            // request.shouldReportPartialResults = NO;
            msg_send_set_bool(request, get_sel("setShouldReportPartialResults:"), false);

            // Use on-device recognition for privacy and to avoid server limits.
            // iOS 17+ has high-quality on-device models for many languages.
            msg_send_set_bool(request, get_sel("setRequiresOnDeviceRecognition:"), true);

            // Enable punctuation for better readability (iOS 16+)
            msg_send_set_bool(request, get_sel("setAddsPunctuation:"), true);

            // Synchronization for the async callback
            let shared: Arc<(Mutex<Option<Result<String, String>>>, Condvar)> =
                Arc::new((Mutex::new(None), Condvar::new()));
            let shared_block = Arc::clone(&shared);

            // Create the completion handler block:
            // ^(SFSpeechRecognitionResult *result, NSError *error) { ... }
            let block = RcBlock::new(move |result: Id, error: Id| {
                let (lock, cvar) = &*shared_block;
                // Only process when we get a final result or error
                if !error.is_null() {
                    let desc = nsstring_to_rust(msg_send_0(error, get_sel("localizedDescription")));
                    let mut guard = lock.lock().unwrap();
                    if guard.is_none() {
                        *guard = Some(Err(desc));
                        cvar.notify_one();
                    }
                    return;
                }
                if !result.is_null() {
                    let is_final = msg_send_bool(result, get_sel("isFinal"));
                    if is_final {
                        // result.bestTranscription.formattedString
                        let transcription =
                            msg_send_0(result, get_sel("bestTranscription"));
                        let formatted =
                            msg_send_0(transcription, get_sel("formattedString"));
                        let text = nsstring_to_rust(formatted);
                        let mut guard = lock.lock().unwrap();
                        if guard.is_none() {
                            *guard = Some(Ok(text));
                            cvar.notify_one();
                        }
                    }
                }
            });

            // [recognizer recognitionTaskWithRequest:request resultHandler:block];
            let sel = get_sel("recognitionTaskWithRequest:resultHandler:");
            let f: unsafe extern "C" fn(Id, Sel, Id, &RcBlock<dyn Fn(Id, Id)>) -> Id =
                std::mem::transmute(objc_msgSend as *const ());
            let _task = f(recognizer, sel, request, &block);

            // Wait for completion (10-min audio can take 2-3 min to process)
            let (lock, cvar) = &*shared;
            let guard = lock.lock().unwrap();
            let result = cvar
                .wait_timeout_while(guard, Duration::from_secs(600), |r| r.is_none())
                .unwrap();

            match result.0.as_ref() {
                Some(Ok(text)) => {
                    eprintln!("[transcription] Done: {} chars", text.len());
                    Ok(TranscriptionResult {
                        text: text.clone(),
                        duration_seconds: 0.0, // TODO: extract from audio metadata
                    })
                }
                Some(Err(e)) => Err(format!("Transcription failed: {e}")),
                None => Err("Transcription timed out (10 min limit). Try a shorter recording.".to_string()),
            }
        }
    }
}

// ── Fallback for non-Apple or non-native-inference builds ────────────────────

#[cfg(not(all(
    any(target_os = "ios", target_os = "macos"),
    feature = "native-inference"
)))]
mod platform {
    use super::*;

    pub fn transcribe_audio_file(_audio_path: &str) -> Result<TranscriptionResult, String> {
        Err("Audio transcription is only available on iOS with native-inference enabled.".to_string())
    }
}

pub use platform::transcribe_audio_file;
