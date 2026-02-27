use crate::config::Config;
use anyhow::{Context, Result};
use std::path::{Path, PathBuf};
use std::process::Stdio;
use tokio::process::{Child, Command};

const DEFAULT_POCKETBASE_HOST: &str = "127.0.0.1";
const DEFAULT_POCKETBASE_PORT: u16 = 8090;

pub struct PocketBaseSidecar {
    child: Child,
    pub url: String,
    pub bin_path: PathBuf,
}

impl PocketBaseSidecar {
    pub fn pid(&self) -> Option<u32> {
        self.child.id()
    }
}

impl Drop for PocketBaseSidecar {
    fn drop(&mut self) {
        let _ = self.child.start_kill();
    }
}

pub async fn maybe_start(config: &Config) -> Result<Option<PocketBaseSidecar>> {
    if env_flag("ZEROCLAW_POCKETBASE_DISABLE") {
        return Ok(None);
    }

    let Some(bin_path) = resolve_binary(&config.workspace_dir) else {
        return Ok(None);
    };

    let host = std::env::var("ZEROCLAW_POCKETBASE_HOST")
        .ok()
        .map(|v| v.trim().to_string())
        .filter(|v| !v.is_empty())
        .unwrap_or_else(|| DEFAULT_POCKETBASE_HOST.to_string());
    let port = std::env::var("ZEROCLAW_POCKETBASE_PORT")
        .ok()
        .and_then(|v| v.trim().parse::<u16>().ok())
        .unwrap_or(DEFAULT_POCKETBASE_PORT);
    let url = format!("http://{host}:{port}");

    let data_dir = config.workspace_dir.join("pb_data");
    tokio::fs::create_dir_all(&data_dir)
        .await
        .with_context(|| format!("Failed to create PocketBase data dir {}", data_dir.display()))?;

    let mut cmd = Command::new(&bin_path);
    cmd.arg("serve")
        .arg(format!("--http={host}:{port}"))
        .arg("--dir")
        .arg(&data_dir)
        .current_dir(&config.workspace_dir)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .kill_on_drop(false);

    let child = cmd.spawn().with_context(|| {
        format!(
            "Failed to start PocketBase sidecar using '{}'",
            bin_path.display()
        )
    })?;

    Ok(Some(PocketBaseSidecar {
        child,
        url,
        bin_path,
    }))
}

fn env_flag(name: &str) -> bool {
    std::env::var(name)
        .ok()
        .map(|v| matches!(v.trim().to_ascii_lowercase().as_str(), "1" | "true" | "yes" | "on"))
        .unwrap_or(false)
}

fn resolve_binary(workspace_dir: &Path) -> Option<PathBuf> {
    if let Some(path) = std::env::var("ZEROCLAW_POCKETBASE_BIN")
        .ok()
        .map(|v| v.trim().to_string())
        .filter(|v| !v.is_empty())
    {
        let pb = PathBuf::from(path);
        if pb.exists() {
            return Some(pb);
        }
    }

    let workspace_candidates = [
        workspace_dir.join("pocketbase").join("pocketbase"),
        workspace_dir.join("pocketbase").join("pocketbase.exe"),
    ];
    for candidate in workspace_candidates {
        if candidate.exists() {
            return Some(candidate);
        }
    }

    which::which("pocketbase").ok()
}
