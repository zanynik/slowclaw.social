fn main() {
    tauri_build::build();

    // When building with native inference (llama.cpp), link required Apple frameworks.
    // llama.cpp uses Accelerate for vectorized math (vDSP) and Metal for GPU compute.
    // Speech.framework is used for on-device audio transcription.
    if std::env::var("CARGO_FEATURE_NATIVE_INFERENCE").is_ok() {
        let target_os = std::env::var("CARGO_CFG_TARGET_OS").unwrap_or_default();
        if target_os == "ios" || target_os == "macos" {
            println!("cargo:rustc-link-lib=framework=Accelerate");
            println!("cargo:rustc-link-lib=framework=Metal");
            println!("cargo:rustc-link-lib=framework=MetalKit");
            println!("cargo:rustc-link-lib=framework=Foundation");
            println!("cargo:rustc-link-lib=framework=Speech");
            println!("cargo:rustc-link-lib=framework=AVFoundation");
        }

        // The SFSpeechRecognizer bridge `slowclaw_transcribe_audio` is a Swift
        // `@_cdecl` symbol compiled into the iOS app target by Xcode at the
        // FINAL app link (see scripts/ios-add-speech-plugin.rb), not during
        // the Rust build. The Rust crate is built as both a `staticlib`
        // (linked into the app by Xcode, where the symbol resolves against the
        // Swift object) and a `cdylib` (built by cargo as a side effect, but
        // not shipped for iOS). The `staticlib` link uses `ar` and never
        // resolves symbols, so it is unaffected. The `cdylib` link uses `cc`
        // and would otherwise fail on the undefined symbol. Allow that
        // vestigial iOS cdylib to link with the symbol resolved lazily; the
        // shipped app resolves it normally from the Swift object at the final
        // Xcode link, so this flag never reaches an App Store binary.
        if target_os == "ios" {
            println!("cargo:rustc-link-arg-cdylib=-Wl,-undefined,dynamic_lookup");
        }
    }
}
