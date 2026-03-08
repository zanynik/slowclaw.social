use std::env;
use std::fs;
#[cfg(unix)]
use std::os::unix::fs::PermissionsExt;
use std::path::PathBuf;

fn main() {
    ensure_sidecar_placeholder();
    tauri_build::build()
}

fn ensure_sidecar_placeholder() {
    let manifest_dir = match env::var("CARGO_MANIFEST_DIR") {
        Ok(value) => PathBuf::from(value),
        Err(_) => return,
    };
    let target = match env::var("TARGET") {
        Ok(value) => value,
        Err(_) => return,
    };
    let sidecar_name = if target.contains("windows") {
        format!("slowclaw-{target}.exe")
    } else {
        format!("slowclaw-{target}")
    };
    let sidecar_path = manifest_dir.join("binaries").join(sidecar_name);
    if sidecar_path.exists() {
        return;
    }

    if let Some(parent) = sidecar_path.parent() {
        let _ = fs::create_dir_all(parent);
    }

    if target.contains("windows") {
        let _ = fs::write(&sidecar_path, []);
        return;
    }

    let _ = fs::write(
        &sidecar_path,
        "#!/bin/sh\nprintf '%s\\n' 'slowclaw sidecar not prepared; run npm run package:macos from web/' >&2\nexit 1\n",
    );
    #[cfg(unix)]
    {
        let _ = fs::set_permissions(&sidecar_path, fs::Permissions::from_mode(0o755));
    }
}
