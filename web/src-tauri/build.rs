fn main() {
    tauri_build::build();

    // When building with native inference (llama.cpp), link required Apple frameworks.
    // llama.cpp uses Accelerate for vectorized math (vDSP) and Metal for GPU compute.
    if std::env::var("CARGO_FEATURE_NATIVE_INFERENCE").is_ok() {
        let target_os = std::env::var("CARGO_CFG_TARGET_OS").unwrap_or_default();
        if target_os == "ios" || target_os == "macos" {
            println!("cargo:rustc-link-lib=framework=Accelerate");
            println!("cargo:rustc-link-lib=framework=Metal");
            println!("cargo:rustc-link-lib=framework=MetalKit");
            println!("cargo:rustc-link-lib=framework=Foundation");
        }
    }
}
