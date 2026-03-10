use super::traits::{Tool, ToolResult};
use crate::media::{
    ComposeSimpleClipRequest, ContentMediaBackend, MediaCard, RenderTextCardVideoRequest,
    SharedContentMediaBackend, StitchImagesWithAudioRequest,
};
use crate::security::SecurityPolicy;
use async_trait::async_trait;
use serde_json::json;
use std::sync::Arc;

fn parse_media_cards(args: &serde_json::Value) -> anyhow::Result<Vec<MediaCard>> {
    let cards_value = args
        .get("cards")
        .cloned()
        .unwrap_or_else(|| serde_json::Value::Array(Vec::new()));
    serde_json::from_value(cards_value).map_err(Into::into)
}

fn reject_untrusted_path(path: &str) -> Option<String> {
    let trimmed = path.trim();
    if trimmed.is_empty() {
        return Some("Path is required.".to_string());
    }
    if trimmed.starts_with('/') || trimmed.starts_with('\\') {
        return Some("Absolute paths are not allowed.".to_string());
    }
    if trimmed == ".." || trimmed.contains("../") || trimmed.contains("..\\") {
        return Some("Path traversal ('..') is not allowed.".to_string());
    }
    None
}

fn validate_media_paths(
    security: &SecurityPolicy,
    paths: &[String],
    action_name: &str,
) -> Option<ToolResult> {
    if security.is_rate_limited() {
        return Some(ToolResult {
            success: false,
            output: String::new(),
            error: Some("Rate limit exceeded: too many actions in the last hour".into()),
        });
    }

    for path in paths {
        if let Some(error) = reject_untrusted_path(path) {
            return Some(ToolResult {
                success: false,
                output: String::new(),
                error: Some(error),
            });
        }
        if !security.is_path_allowed(path) {
            return Some(ToolResult {
                success: false,
                output: String::new(),
                error: Some(format!("Path not allowed for {action_name}: {path}")),
            });
        }
    }

    if !security.record_action() {
        return Some(ToolResult {
            success: false,
            output: String::new(),
            error: Some("Rate limit exceeded: action budget exhausted".into()),
        });
    }

    None
}

fn json_result<T: serde::Serialize>(value: &T) -> anyhow::Result<ToolResult> {
    Ok(ToolResult {
        success: true,
        output: serde_json::to_string_pretty(value)?,
        error: None,
    })
}

fn error_result(error: impl Into<String>) -> ToolResult {
    ToolResult {
        success: false,
        output: String::new(),
        error: Some(error.into()),
    }
}

struct MediaToolBase {
    security: Arc<SecurityPolicy>,
    backend: Arc<dyn ContentMediaBackend>,
}

impl MediaToolBase {
    fn new(backend: SharedContentMediaBackend, security: Arc<SecurityPolicy>) -> Self {
        Self { security, backend }
    }
}

pub struct TranscribeMediaTool {
    inner: MediaToolBase,
}

impl TranscribeMediaTool {
    pub fn new(backend: SharedContentMediaBackend, security: Arc<SecurityPolicy>) -> Self {
        Self {
            inner: MediaToolBase::new(backend, security),
        }
    }
}

#[async_trait]
impl Tool for TranscribeMediaTool {
    fn name(&self) -> &str {
        "transcribe_media"
    }

    fn description(&self) -> &str {
        "Create or reuse a transcript for a journal media file. Returns transcript paths and text."
    }

    fn parameters_schema(&self) -> serde_json::Value {
        json!({
            "type": "object",
            "properties": {
                "mediaPath": { "type": "string", "description": "Workspace-relative path to journal audio/video media." },
                "force": { "type": "boolean", "default": false, "description": "Re-run transcription even if a transcript already exists." }
            },
            "required": ["mediaPath"]
        })
    }

    async fn execute(&self, args: serde_json::Value) -> anyhow::Result<ToolResult> {
        let media_path = args
            .get("mediaPath")
            .and_then(|value| value.as_str())
            .ok_or_else(|| anyhow::anyhow!("Missing 'mediaPath' parameter"))?;
        if let Some(result) = validate_media_paths(
            &self.inner.security,
            &[media_path.to_string()],
            self.name(),
        ) {
            return Ok(result);
        }

        match self
            .inner
            .backend
            .transcribe_media(media_path, args.get("force").and_then(|value| value.as_bool()).unwrap_or(false))
            .await
        {
            Ok(result) => json_result(&result),
            Err(err) => Ok(error_result(err.to_string())),
        }
    }
}

pub struct CleanAudioTool {
    inner: MediaToolBase,
}

impl CleanAudioTool {
    pub fn new(backend: SharedContentMediaBackend, security: Arc<SecurityPolicy>) -> Self {
        Self {
            inner: MediaToolBase::new(backend, security),
        }
    }
}

#[async_trait]
impl Tool for CleanAudioTool {
    fn name(&self) -> &str {
        "clean_audio"
    }

    fn description(&self) -> &str {
        "Apply deterministic speech cleanup to an audio file and write a cleaned output file."
    }

    fn parameters_schema(&self) -> serde_json::Value {
        json!({
            "type": "object",
            "properties": {
                "audioPath": { "type": "string" },
                "preset": { "type": "string", "enum": ["speech_basic"], "default": "speech_basic" },
                "outputPath": { "type": "string" }
            },
            "required": ["audioPath", "outputPath"]
        })
    }

    async fn execute(&self, args: serde_json::Value) -> anyhow::Result<ToolResult> {
        let audio_path = args
            .get("audioPath")
            .and_then(|value| value.as_str())
            .ok_or_else(|| anyhow::anyhow!("Missing 'audioPath' parameter"))?;
        let output_path = args
            .get("outputPath")
            .and_then(|value| value.as_str())
            .ok_or_else(|| anyhow::anyhow!("Missing 'outputPath' parameter"))?;
        if let Some(result) = validate_media_paths(
            &self.inner.security,
            &[audio_path.to_string(), output_path.to_string()],
            self.name(),
        ) {
            return Ok(result);
        }
        match self
            .inner
            .backend
            .clean_audio(
                audio_path,
                args.get("preset")
                    .and_then(|value| value.as_str())
                    .unwrap_or("speech_basic"),
                output_path,
            )
            .await
        {
            Ok(result) => json_result(&result),
            Err(err) => Ok(error_result(err.to_string())),
        }
    }
}

pub struct ExtractAudioSegmentTool {
    inner: MediaToolBase,
}

impl ExtractAudioSegmentTool {
    pub fn new(backend: SharedContentMediaBackend, security: Arc<SecurityPolicy>) -> Self {
        Self {
            inner: MediaToolBase::new(backend, security),
        }
    }
}

#[async_trait]
impl Tool for ExtractAudioSegmentTool {
    fn name(&self) -> &str {
        "extract_audio_segment"
    }

    fn description(&self) -> &str {
        "Extract a precise audio range from an audio file and write it as a new file."
    }

    fn parameters_schema(&self) -> serde_json::Value {
        json!({
            "type": "object",
            "properties": {
                "audioPath": { "type": "string" },
                "startMs": { "type": "integer", "minimum": 0 },
                "endMs": { "type": "integer", "minimum": 1 },
                "outputPath": { "type": "string" }
            },
            "required": ["audioPath", "startMs", "endMs", "outputPath"]
        })
    }

    async fn execute(&self, args: serde_json::Value) -> anyhow::Result<ToolResult> {
        let audio_path = args
            .get("audioPath")
            .and_then(|value| value.as_str())
            .ok_or_else(|| anyhow::anyhow!("Missing 'audioPath' parameter"))?;
        let output_path = args
            .get("outputPath")
            .and_then(|value| value.as_str())
            .ok_or_else(|| anyhow::anyhow!("Missing 'outputPath' parameter"))?;
        if let Some(result) = validate_media_paths(
            &self.inner.security,
            &[audio_path.to_string(), output_path.to_string()],
            self.name(),
        ) {
            return Ok(result);
        }
        let start_ms = args
            .get("startMs")
            .and_then(|value| value.as_u64())
            .ok_or_else(|| anyhow::anyhow!("Missing 'startMs' parameter"))?;
        let end_ms = args
            .get("endMs")
            .and_then(|value| value.as_u64())
            .ok_or_else(|| anyhow::anyhow!("Missing 'endMs' parameter"))?;

        match self
            .inner
            .backend
            .extract_audio_segment(audio_path, start_ms, end_ms, output_path)
            .await
        {
            Ok(result) => json_result(&result),
            Err(err) => Ok(error_result(err.to_string())),
        }
    }
}

pub struct RenderTextCardVideoTool {
    inner: MediaToolBase,
}

impl RenderTextCardVideoTool {
    pub fn new(backend: SharedContentMediaBackend, security: Arc<SecurityPolicy>) -> Self {
        Self {
            inner: MediaToolBase::new(backend, security),
        }
    }
}

#[async_trait]
impl Tool for RenderTextCardVideoTool {
    fn name(&self) -> &str {
        "render_text_card_video"
    }

    fn description(&self) -> &str {
        "Render white text cards on a black vertical video background, optionally timed to audio."
    }

    fn parameters_schema(&self) -> serde_json::Value {
        json!({
            "type": "object",
            "properties": {
                "cards": {
                    "type": "array",
                    "items": {
                        "type": "object",
                        "properties": {
                            "text": { "type": "string" },
                            "startMs": { "type": "integer" },
                            "endMs": { "type": "integer" }
                        },
                        "required": ["text"]
                    }
                },
                "audioPath": { "type": "string" },
                "width": { "type": "integer", "default": 1080 },
                "height": { "type": "integer", "default": 1920 },
                "fps": { "type": "integer", "default": 30 },
                "theme": { "type": "string", "enum": ["black_white"], "default": "black_white" },
                "outputPath": { "type": "string" }
            },
            "required": ["cards", "outputPath"]
        })
    }

    async fn execute(&self, args: serde_json::Value) -> anyhow::Result<ToolResult> {
        let output_path = args
            .get("outputPath")
            .and_then(|value| value.as_str())
            .ok_or_else(|| anyhow::anyhow!("Missing 'outputPath' parameter"))?;
        let mut paths = vec![output_path.to_string()];
        if let Some(audio_path) = args.get("audioPath").and_then(|value| value.as_str()) {
            paths.push(audio_path.to_string());
        }
        if let Some(result) = validate_media_paths(&self.inner.security, &paths, self.name()) {
            return Ok(result);
        }
        let request = RenderTextCardVideoRequest {
            cards: parse_media_cards(&args)?,
            audio_path: args.get("audioPath").and_then(|value| value.as_str()).map(str::to_string),
            width: args.get("width").and_then(|value| value.as_u64()).map(|value| value as u32),
            height: args.get("height").and_then(|value| value.as_u64()).map(|value| value as u32),
            fps: args.get("fps").and_then(|value| value.as_u64()).map(|value| value as u32),
            theme: args.get("theme").and_then(|value| value.as_str()).map(str::to_string),
            output_path: output_path.to_string(),
        };
        match self.inner.backend.render_text_card_video(&request).await {
            Ok(result) => json_result(&result),
            Err(err) => Ok(error_result(err.to_string())),
        }
    }
}

pub struct StitchImagesWithAudioTool {
    inner: MediaToolBase,
}

impl StitchImagesWithAudioTool {
    pub fn new(backend: SharedContentMediaBackend, security: Arc<SecurityPolicy>) -> Self {
        Self {
            inner: MediaToolBase::new(backend, security),
        }
    }
}

#[async_trait]
impl Tool for StitchImagesWithAudioTool {
    fn name(&self) -> &str {
        "stitch_images_with_audio"
    }

    fn description(&self) -> &str {
        "Create a simple slideshow video from still images and one audio track."
    }

    fn parameters_schema(&self) -> serde_json::Value {
        json!({
            "type": "object",
            "properties": {
                "imagePaths": { "type": "array", "items": { "type": "string" } },
                "audioPath": { "type": "string" },
                "durationsMs": { "type": "array", "items": { "type": "integer" } },
                "width": { "type": "integer", "default": 1080 },
                "height": { "type": "integer", "default": 1920 },
                "fps": { "type": "integer", "default": 30 },
                "outputPath": { "type": "string" }
            },
            "required": ["imagePaths", "audioPath", "outputPath"]
        })
    }

    async fn execute(&self, args: serde_json::Value) -> anyhow::Result<ToolResult> {
        let output_path = args
            .get("outputPath")
            .and_then(|value| value.as_str())
            .ok_or_else(|| anyhow::anyhow!("Missing 'outputPath' parameter"))?;
        let audio_path = args
            .get("audioPath")
            .and_then(|value| value.as_str())
            .ok_or_else(|| anyhow::anyhow!("Missing 'audioPath' parameter"))?;
        let image_paths: Vec<String> = args
            .get("imagePaths")
            .cloned()
            .map(serde_json::from_value)
            .transpose()?
            .unwrap_or_default();
        let mut paths = vec![output_path.to_string(), audio_path.to_string()];
        paths.extend(image_paths.clone());
        if let Some(result) = validate_media_paths(&self.inner.security, &paths, self.name()) {
            return Ok(result);
        }
        let request = StitchImagesWithAudioRequest {
            image_paths,
            audio_path: audio_path.to_string(),
            durations_ms: args.get("durationsMs").cloned().map(serde_json::from_value).transpose()?,
            width: args.get("width").and_then(|value| value.as_u64()).map(|value| value as u32),
            height: args.get("height").and_then(|value| value.as_u64()).map(|value| value as u32),
            fps: args.get("fps").and_then(|value| value.as_u64()).map(|value| value as u32),
            output_path: output_path.to_string(),
        };
        match self.inner.backend.stitch_images_with_audio(&request).await {
            Ok(result) => json_result(&result),
            Err(err) => Ok(error_result(err.to_string())),
        }
    }
}

pub struct ComposeSimpleClipTool {
    inner: MediaToolBase,
}

impl ComposeSimpleClipTool {
    pub fn new(backend: SharedContentMediaBackend, security: Arc<SecurityPolicy>) -> Self {
        Self {
            inner: MediaToolBase::new(backend, security),
        }
    }
}

#[async_trait]
impl Tool for ComposeSimpleClipTool {
    fn name(&self) -> &str {
        "compose_simple_clip"
    }

    fn description(&self) -> &str {
        "Create a feed-ready vertical clip from one audio source plus either text cards or still images."
    }

    fn parameters_schema(&self) -> serde_json::Value {
        json!({
            "type": "object",
            "properties": {
                "audioPath": { "type": "string" },
                "cards": {
                    "type": "array",
                    "items": {
                        "type": "object",
                        "properties": {
                            "text": { "type": "string" },
                            "startMs": { "type": "integer" },
                            "endMs": { "type": "integer" }
                        },
                        "required": ["text"]
                    }
                },
                "imagePaths": { "type": "array", "items": { "type": "string" } },
                "title": { "type": "string" },
                "preset": { "type": "string", "enum": ["audio_insight_basic"], "default": "audio_insight_basic" },
                "outputPath": { "type": "string" }
            },
            "required": ["audioPath", "outputPath"]
        })
    }

    async fn execute(&self, args: serde_json::Value) -> anyhow::Result<ToolResult> {
        let output_path = args
            .get("outputPath")
            .and_then(|value| value.as_str())
            .ok_or_else(|| anyhow::anyhow!("Missing 'outputPath' parameter"))?;
        let audio_path = args
            .get("audioPath")
            .and_then(|value| value.as_str())
            .ok_or_else(|| anyhow::anyhow!("Missing 'audioPath' parameter"))?;
        let image_paths: Option<Vec<String>> =
            args.get("imagePaths").cloned().map(serde_json::from_value).transpose()?;
        let mut paths = vec![output_path.to_string(), audio_path.to_string()];
        if let Some(images) = image_paths.as_ref() {
            paths.extend(images.clone());
        }
        if let Some(result) = validate_media_paths(&self.inner.security, &paths, self.name()) {
            return Ok(result);
        }

        let request = ComposeSimpleClipRequest {
            audio_path: audio_path.to_string(),
            cards: args.get("cards").cloned().map(serde_json::from_value).transpose()?,
            image_paths,
            title: args.get("title").and_then(|value| value.as_str()).map(str::to_string),
            preset: args.get("preset").and_then(|value| value.as_str()).map(str::to_string),
            output_path: output_path.to_string(),
        };
        match self.inner.backend.compose_simple_clip(&request).await {
            Ok(result) => json_result(&result),
            Err(err) => Ok(error_result(err.to_string())),
        }
    }
}
