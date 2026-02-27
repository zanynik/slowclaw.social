use super::traits::{Tool, ToolResult};
use crate::security::SecurityPolicy;
use async_trait::async_trait;
use serde_json::json;
use std::path::PathBuf;
use std::sync::Arc;
use std::time::Duration;
use tokio::process::Command;

const DEFAULT_TIMEOUT_SECS: u64 = 3600;
const MAX_OUTPUT_BYTES: usize = 1_048_576;
const DEFAULT_SCRIPT_REL_PATH: &str = "scripts/audio_to_video_skill/slowclaw_audio_to_video_job.py";

pub struct AudioToVideoTool {
    security: Arc<SecurityPolicy>,
}

impl AudioToVideoTool {
    pub fn new(security: Arc<SecurityPolicy>) -> Self {
        Self { security }
    }
}

fn truncate_utf8_to_max_bytes(s: &mut String, max_bytes: usize) {
    if s.len() <= max_bytes {
        return;
    }
    let mut idx = max_bytes.min(s.len());
    while idx > 0 && !s.is_char_boundary(idx) {
        idx -= 1;
    }
    s.truncate(idx);
}

fn resolve_workspace_file(security: &SecurityPolicy, raw_path: &str) -> Result<PathBuf, String> {
    let trimmed = raw_path.trim();
    if trimmed.is_empty() {
        return Err("Path is empty".to_string());
    }
    if !security.is_path_allowed(trimmed) {
        return Err(format!("Path not allowed by security policy: {trimmed}"));
    }

    let full_path = security.workspace_dir.join(trimmed);
    let resolved = std::fs::canonicalize(&full_path)
        .map_err(|e| format!("Failed to resolve path '{}': {e}", full_path.display()))?;

    if !security.is_resolved_path_allowed(&resolved) {
        return Err(security.resolved_path_violation_message(&resolved));
    }

    Ok(resolved)
}

#[async_trait]
impl Tool for AudioToVideoTool {
    fn name(&self) -> &str {
        "audio_to_video"
    }

    fn description(&self) -> &str {
        "Run the audio_to_video processor skill on an audio file in workspace. \
         Executes scripts/audio_to_video_skill/slowclaw_audio_to_video_job.py and returns output. \
         Pipeline artifacts are stored under journals/pipeline/audio_to_video and final feed media is published under journals/processed."
    }

    fn parameters_schema(&self) -> serde_json::Value {
        json!({
            "type": "object",
            "properties": {
                "audio_path": {
                    "type": "string",
                    "description": "Workspace-relative audio path (e.g. journals/media/audio/.../note.m4a)"
                },
                "asset_id": {
                    "type": "string",
                    "description": "Optional PocketBase media_assets record id to patch"
                },
                "python_bin": {
                    "type": "string",
                    "description": "Python interpreter (default: python3)",
                    "default": "python3"
                },
                "gemini_model": {
                    "type": "string",
                    "description": "Optional gemini model override for wrapper script"
                },
                "timeout_secs": {
                    "type": "integer",
                    "description": "Execution timeout seconds (default 3600, max 7200)",
                    "default": 3600
                }
            },
            "required": ["audio_path"]
        })
    }

    async fn execute(&self, args: serde_json::Value) -> anyhow::Result<ToolResult> {
        let audio_path = match args.get("audio_path").and_then(serde_json::Value::as_str) {
            Some(value) if !value.trim().is_empty() => value.trim(),
            _ => {
                return Ok(ToolResult {
                    success: false,
                    output: String::new(),
                    error: Some("Missing 'audio_path' parameter".to_string()),
                })
            }
        };

        let python_bin = args
            .get("python_bin")
            .and_then(serde_json::Value::as_str)
            .map(str::trim)
            .filter(|s| !s.is_empty())
            .unwrap_or("python3");
        let gemini_model = args
            .get("gemini_model")
            .and_then(serde_json::Value::as_str)
            .map(str::trim)
            .filter(|s| !s.is_empty())
            .map(ToOwned::to_owned);
        let asset_id = args
            .get("asset_id")
            .and_then(serde_json::Value::as_str)
            .map(str::trim)
            .filter(|s| !s.is_empty())
            .map(ToOwned::to_owned);
        let timeout_secs = args
            .get("timeout_secs")
            .and_then(serde_json::Value::as_u64)
            .map(|v| v.clamp(1, 7200))
            .unwrap_or(DEFAULT_TIMEOUT_SECS);

        if self.security.is_rate_limited() {
            return Ok(ToolResult {
                success: false,
                output: String::new(),
                error: Some("Rate limit exceeded: too many actions in the last hour".to_string()),
            });
        }

        if !self.security.can_act() {
            return Ok(ToolResult {
                success: false,
                output: String::new(),
                error: Some("Security policy: read-only mode".to_string()),
            });
        }

        if !self.security.record_action() {
            return Ok(ToolResult {
                success: false,
                output: String::new(),
                error: Some("Rate limit exceeded: action budget exhausted".to_string()),
            });
        }

        let resolved_audio = match resolve_workspace_file(&self.security, audio_path) {
            Ok(path) => path,
            Err(error) => {
                return Ok(ToolResult {
                    success: false,
                    output: String::new(),
                    error: Some(error),
                })
            }
        };
        if !resolved_audio.is_file() {
            return Ok(ToolResult {
                success: false,
                output: String::new(),
                error: Some(format!(
                    "audio_path is not a file: {}",
                    resolved_audio.display()
                )),
            });
        }

        let resolved_script = match resolve_workspace_file(&self.security, DEFAULT_SCRIPT_REL_PATH) {
            Ok(path) => path,
            Err(error) => {
                return Ok(ToolResult {
                    success: false,
                    output: String::new(),
                    error: Some(format!(
                        "audio_to_video skill script is missing or blocked ({DEFAULT_SCRIPT_REL_PATH}): {error}"
                    )),
                })
            }
        };
        if !resolved_script.is_file() {
            return Ok(ToolResult {
                success: false,
                output: String::new(),
                error: Some(format!(
                    "audio_to_video wrapper script is not a file: {}",
                    resolved_script.display()
                )),
            });
        }

        let audio_arg = resolved_audio
            .strip_prefix(&self.security.workspace_dir)
            .ok()
            .map(|p| p.to_string_lossy().to_string())
            .unwrap_or_else(|| resolved_audio.to_string_lossy().to_string());

        let mut command = Command::new(python_bin);
        command
            .arg(&resolved_script)
            .arg(&audio_arg)
            .current_dir(&self.security.workspace_dir)
            .stdin(std::process::Stdio::null())
            .stdout(std::process::Stdio::piped())
            .stderr(std::process::Stdio::piped())
            .kill_on_drop(true);
        if let Some(asset_id) = asset_id {
            command.arg("--asset-id").arg(asset_id);
        }
        if let Some(gemini_model) = gemini_model {
            command.arg("--gemini-model").arg(gemini_model);
        }

        let result = tokio::time::timeout(Duration::from_secs(timeout_secs), command.output()).await;
        match result {
            Ok(Ok(output)) => {
                let mut stdout = String::from_utf8_lossy(&output.stdout).to_string();
                let mut stderr = String::from_utf8_lossy(&output.stderr).to_string();
                if stdout.len() > MAX_OUTPUT_BYTES {
                    truncate_utf8_to_max_bytes(&mut stdout, MAX_OUTPUT_BYTES);
                    stdout.push_str("\n... [stdout truncated at 1MB]");
                }
                if stderr.len() > MAX_OUTPUT_BYTES {
                    truncate_utf8_to_max_bytes(&mut stderr, MAX_OUTPUT_BYTES);
                    stderr.push_str("\n... [stderr truncated at 1MB]");
                }
                let combined = format!(
                    "script={}\naudio={}\nstatus={}\nstdout:\n{}\nstderr:\n{}",
                    resolved_script.display(),
                    audio_arg,
                    output.status,
                    stdout.trim(),
                    stderr.trim()
                );
                Ok(ToolResult {
                    success: output.status.success(),
                    output: combined,
                    error: if output.status.success() || stderr.trim().is_empty() {
                        None
                    } else {
                        Some(stderr)
                    },
                })
            }
            Ok(Err(e)) => Ok(ToolResult {
                success: false,
                output: String::new(),
                error: Some(format!("Failed to execute audio_to_video wrapper: {e}")),
            }),
            Err(_) => Ok(ToolResult {
                success: false,
                output: String::new(),
                error: Some(format!(
                    "audio_to_video execution timed out after {timeout_secs}s"
                )),
            }),
        }
    }
}
