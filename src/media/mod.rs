use crate::config::TranscriptionConfig;
use crate::util::truncate_with_ellipsis;
use anyhow::{Context, Result};
use async_trait::async_trait;
use serde::{Deserialize, Serialize};
use std::path::{Path as StdPath, PathBuf};
use std::process::Stdio;
use std::sync::Arc;
use std::time::Duration;
use tokio::process::Command;

const MEDIA_COMMAND_TIMEOUT_SECS: u64 = 300;
const DEFAULT_CARD_DURATION_MS: u64 = 3_000;

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MediaTranscriptResult {
    pub status: String,
    pub media_path: String,
    pub transcript_path: String,
    pub json_path: String,
    pub srt_path: String,
    pub text: Option<String>,
    pub updated_at: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct AudioTransformResult {
    pub output_path: String,
    pub duration_ms: Option<u64>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct MediaCard {
    pub text: String,
    pub start_ms: Option<u64>,
    pub end_ms: Option<u64>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct RenderTextCardVideoRequest {
    pub cards: Vec<MediaCard>,
    pub audio_path: Option<String>,
    pub width: Option<u32>,
    pub height: Option<u32>,
    pub fps: Option<u32>,
    pub theme: Option<String>,
    pub output_path: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct StitchImagesWithAudioRequest {
    pub image_paths: Vec<String>,
    pub audio_path: String,
    pub durations_ms: Option<Vec<u64>>,
    pub width: Option<u32>,
    pub height: Option<u32>,
    pub fps: Option<u32>,
    pub output_path: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ComposeSimpleClipRequest {
    pub audio_path: String,
    pub cards: Option<Vec<MediaCard>>,
    pub image_paths: Option<Vec<String>>,
    pub title: Option<String>,
    pub preset: Option<String>,
    pub output_path: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct ComposeSimpleClipResult {
    pub output_path: String,
    pub artifacts: Vec<String>,
    pub duration_ms: Option<u64>,
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, Default)]
#[serde(rename_all = "camelCase")]
pub struct MediaToolCapabilities {
    pub transcribe_media: bool,
    pub clean_audio: bool,
    pub extract_audio_segment: bool,
    pub render_text_card_video: bool,
    pub stitch_images_with_audio: bool,
    pub compose_simple_clip: bool,
}

impl MediaToolCapabilities {
    pub fn available_tool_names(self) -> Vec<&'static str> {
        let mut names = Vec::new();
        if self.transcribe_media {
            names.push("transcribe_media");
        }
        if self.clean_audio {
            names.push("clean_audio");
        }
        if self.extract_audio_segment {
            names.push("extract_audio_segment");
        }
        if self.render_text_card_video {
            names.push("render_text_card_video");
        }
        if self.stitch_images_with_audio {
            names.push("stitch_images_with_audio");
        }
        if self.compose_simple_clip {
            names.push("compose_simple_clip");
        }
        names
    }

    pub fn summary(self) -> String {
        let names = self.available_tool_names();
        if names.is_empty() {
            "No local media tools are currently available on this device.".to_string()
        } else {
            format!("Local media tools available on this device: {}.", names.join(", "))
        }
    }
}

#[async_trait]
pub trait ContentMediaBackend: Send + Sync {
    fn capabilities(&self) -> MediaToolCapabilities;
    async fn transcribe_media(&self, media_path: &str, force: bool) -> Result<MediaTranscriptResult>;
    async fn clean_audio(
        &self,
        audio_path: &str,
        preset: &str,
        output_path: &str,
    ) -> Result<AudioTransformResult>;
    async fn extract_audio_segment(
        &self,
        audio_path: &str,
        start_ms: u64,
        end_ms: u64,
        output_path: &str,
    ) -> Result<AudioTransformResult>;
    async fn render_text_card_video(
        &self,
        request: &RenderTextCardVideoRequest,
    ) -> Result<AudioTransformResult>;
    async fn stitch_images_with_audio(
        &self,
        request: &StitchImagesWithAudioRequest,
    ) -> Result<AudioTransformResult>;
    async fn compose_simple_clip(
        &self,
        request: &ComposeSimpleClipRequest,
    ) -> Result<ComposeSimpleClipResult>;
}

pub type SharedContentMediaBackend = Arc<dyn ContentMediaBackend>;

pub fn command_media_backend(
    workspace_dir: PathBuf,
    transcription: TranscriptionConfig,
) -> SharedContentMediaBackend {
    Arc::new(CommandContentMediaBackend::new(workspace_dir, transcription))
}

pub struct CommandContentMediaBackend {
    workspace_dir: PathBuf,
    transcription: TranscriptionConfig,
}

impl CommandContentMediaBackend {
    pub fn new(workspace_dir: PathBuf, transcription: TranscriptionConfig) -> Self {
        Self {
            workspace_dir,
            transcription,
        }
    }

    fn resolve_rel_path(&self, rel_path: &str) -> Result<PathBuf> {
        let normalized = rel_path.trim().trim_start_matches('/');
        if normalized.is_empty() {
            anyhow::bail!("Path is required");
        }
        if StdPath::new(normalized).is_absolute()
            || normalized == ".."
            || normalized.contains("../")
            || normalized.contains("..\\")
        {
            anyhow::bail!("Absolute paths and traversal are not allowed");
        }
        Ok(self.workspace_dir.join(normalized))
    }

    fn ensure_parent_dir(&self, abs_path: &StdPath) -> Result<()> {
        let Some(parent) = abs_path.parent() else {
            anyhow::bail!("Output path must have a parent directory");
        };
        std::fs::create_dir_all(parent)
            .with_context(|| format!("failed to create {}", parent.display()))
    }

    async fn run_command(&self, program: &str, args: &[String]) -> Result<String> {
        let output = tokio::time::timeout(
            Duration::from_secs(MEDIA_COMMAND_TIMEOUT_SECS),
            Command::new(program)
                .args(args)
                .current_dir(&self.workspace_dir)
                .stdin(Stdio::null())
                .stdout(Stdio::piped())
                .stderr(Stdio::piped())
                .kill_on_drop(true)
                .output(),
        )
        .await
        .with_context(|| format!("{program} timed out"))?
        .with_context(|| format!("failed to execute {program}"))?;

        if !output.status.success() {
            let stderr = String::from_utf8_lossy(&output.stderr).to_string();
            let stdout = String::from_utf8_lossy(&output.stdout).to_string();
            anyhow::bail!(
                "{program} failed ({}): {}",
                output.status,
                truncate_with_ellipsis(
                    &(if stderr.trim().is_empty() { stdout } else { stderr }),
                    320
                )
            );
        }

        Ok(String::from_utf8_lossy(&output.stdout).trim().to_string())
    }

    async fn ensure_helper_scripts(&self) -> Result<()> {
        let scripts_dir = self.workspace_dir.join("scripts");
        tokio::fs::create_dir_all(&scripts_dir).await?;
        tokio::fs::write(
            scripts_dir.join("transcribe_audio_journal.py"),
            include_str!("../../scripts/transcribe_audio_journal.py"),
        )
        .await?;
        Ok(())
    }
}

#[async_trait]
impl ContentMediaBackend for CommandContentMediaBackend {
    fn capabilities(&self) -> MediaToolCapabilities {
        let ffmpeg_available = which::which("ffmpeg").is_ok();
        let ffprobe_available = which::which("ffprobe").is_ok();
        let python_available = which::which(self.transcription.python_bin.trim()).is_ok();
        let transcribe_available = self.transcription.enabled && python_available;
        let media_ops_available = ffmpeg_available && ffprobe_available;

        MediaToolCapabilities {
            transcribe_media: transcribe_available,
            clean_audio: media_ops_available,
            extract_audio_segment: media_ops_available,
            render_text_card_video: media_ops_available,
            stitch_images_with_audio: media_ops_available,
            compose_simple_clip: media_ops_available,
        }
    }

    async fn transcribe_media(&self, media_path: &str, force: bool) -> Result<MediaTranscriptResult> {
        let media_abs = self.resolve_rel_path(media_path)?;
        if !media_abs.exists() || !media_abs.is_file() {
            anyhow::bail!("Media file not found: {media_path}");
        }
        if !self.transcription.enabled {
            anyhow::bail!("Transcription is disabled in config");
        }
        let transcript_rel = transcript_rel_path_for_media(media_path)
            .ok_or_else(|| anyhow::anyhow!("Could not derive transcript path"))?;
        let transcript_abs = self.resolve_rel_path(&transcript_rel)?;
        let json_rel = transcript_json_rel_path(&transcript_rel);
        let srt_rel = transcript_srt_rel_path(&transcript_rel);

        if !force && transcript_abs.exists() && transcript_abs.is_file() {
            let existing = tokio::fs::read_to_string(&transcript_abs)
                .await
                .unwrap_or_default();
            if !existing.trim().is_empty() {
                return Ok(MediaTranscriptResult {
                    status: "done".to_string(),
                    media_path: media_path.trim().trim_start_matches('/').to_string(),
                    transcript_path: transcript_rel,
                    json_path: json_rel,
                    srt_path: srt_rel,
                    text: Some(existing),
                    updated_at: chrono::Utc::now().to_rfc3339(),
                });
            }
        }

        self.ensure_helper_scripts().await?;
        self.ensure_parent_dir(&transcript_abs)?;

        let script_path = self.workspace_dir.join("scripts/transcribe_audio_journal.py");
        let mut args = vec![
            script_path.to_string_lossy().to_string(),
            "--input".to_string(),
            media_abs.to_string_lossy().to_string(),
            "--output".to_string(),
            transcript_abs.to_string_lossy().to_string(),
            "--model".to_string(),
            self.transcription.model.trim().to_string(),
            "--device".to_string(),
            self.transcription.device.trim().to_string(),
            "--compute-type".to_string(),
            self.transcription.compute_type.trim().to_string(),
            "--beam-size".to_string(),
            self.transcription.beam_size.max(1).to_string(),
        ];
        if let Some(language) = self
            .transcription
            .language
            .as_deref()
            .map(str::trim)
            .filter(|value| !value.is_empty())
        {
            args.push("--language".to_string());
            args.push(language.to_string());
        }
        self.run_command(self.transcription.python_bin.trim(), &args).await?;

        let text = tokio::fs::read_to_string(&transcript_abs).await.unwrap_or_default();
        Ok(MediaTranscriptResult {
            status: "done".to_string(),
            media_path: media_path.trim().trim_start_matches('/').to_string(),
            transcript_path: transcript_rel,
            json_path: json_rel,
            srt_path: srt_rel,
            text: (!text.trim().is_empty()).then_some(text),
            updated_at: chrono::Utc::now().to_rfc3339(),
        })
    }

    async fn clean_audio(
        &self,
        audio_path: &str,
        preset: &str,
        output_path: &str,
    ) -> Result<AudioTransformResult> {
        if preset.trim() != "speech_basic" {
            anyhow::bail!("Unsupported clean_audio preset `{preset}`");
        }
        let input_abs = self.resolve_rel_path(audio_path)?;
        let output_abs = self.resolve_rel_path(output_path)?;
        self.ensure_parent_dir(&output_abs)?;
        self.run_command(
            "ffmpeg",
            &vec![
                "-y".to_string(),
                "-i".to_string(),
                input_abs.to_string_lossy().to_string(),
                "-af".to_string(),
                "highpass=f=120,lowpass=f=7000,afftdn,loudnorm".to_string(),
                "-ar".to_string(),
                "48000".to_string(),
                "-ac".to_string(),
                "1".to_string(),
                output_abs.to_string_lossy().to_string(),
            ],
        )
        .await?;
        Ok(AudioTransformResult {
            output_path: output_path.trim().trim_start_matches('/').to_string(),
            duration_ms: ffprobe_duration_ms(&output_abs).await.ok(),
        })
    }

    async fn extract_audio_segment(
        &self,
        audio_path: &str,
        start_ms: u64,
        end_ms: u64,
        output_path: &str,
    ) -> Result<AudioTransformResult> {
        if end_ms <= start_ms {
            anyhow::bail!("endMs must be greater than startMs");
        }
        let input_abs = self.resolve_rel_path(audio_path)?;
        let output_abs = self.resolve_rel_path(output_path)?;
        self.ensure_parent_dir(&output_abs)?;
        self.run_command(
            "ffmpeg",
            &vec![
                "-y".to_string(),
                "-ss".to_string(),
                format_seconds_ms(start_ms),
                "-to".to_string(),
                format_seconds_ms(end_ms),
                "-i".to_string(),
                input_abs.to_string_lossy().to_string(),
                "-vn".to_string(),
                "-ac".to_string(),
                "1".to_string(),
                "-ar".to_string(),
                "48000".to_string(),
                output_abs.to_string_lossy().to_string(),
            ],
        )
        .await?;
        Ok(AudioTransformResult {
            output_path: output_path.trim().trim_start_matches('/').to_string(),
            duration_ms: ffprobe_duration_ms(&output_abs).await.ok(),
        })
    }

    async fn render_text_card_video(
        &self,
        request: &RenderTextCardVideoRequest,
    ) -> Result<AudioTransformResult> {
        if request.cards.is_empty() {
            anyhow::bail!("At least one card is required");
        }
        let theme = request.theme.as_deref().unwrap_or("black_white");
        if theme != "black_white" {
            anyhow::bail!("Unsupported render_text_card_video theme `{theme}`");
        }
        let width = request.width.unwrap_or(1080);
        let height = request.height.unwrap_or(1920);
        let fps = request.fps.unwrap_or(30);
        let output_abs = self.resolve_rel_path(&request.output_path)?;
        self.ensure_parent_dir(&output_abs)?;
        let sidecar_srt = output_abs.with_extension("cards.srt");
        tokio::fs::write(&sidecar_srt, build_srt(&request.cards)).await?;

        let duration_ms = if let Some(audio_path) = request.audio_path.as_deref() {
            let audio_abs = self.resolve_rel_path(audio_path)?;
            ffprobe_duration_ms(&audio_abs)
                .await
                .unwrap_or_else(|_| infer_card_duration_ms(&request.cards))
        } else {
            infer_card_duration_ms(&request.cards)
        };
        let duration_secs = format_seconds_ms(duration_ms);

        let mut args = vec![
            "-y".to_string(),
            "-f".to_string(),
            "lavfi".to_string(),
            "-i".to_string(),
            format!("color=c=black:s={}x{}:r={fps}:d={duration_secs}", width, height),
        ];
        if let Some(audio_path) = request.audio_path.as_deref() {
            let audio_abs = self.resolve_rel_path(audio_path)?;
            args.push("-i".to_string());
            args.push(audio_abs.to_string_lossy().to_string());
        }
        args.extend_from_slice(&[
            "-vf".to_string(),
            format!(
                "subtitles={}:force_style='FontSize=22,PrimaryColour=&H00FFFFFF,Outline=0,Alignment=10,MarginV=220'",
                escape_ffmpeg_filter_path(&sidecar_srt)
            ),
            "-pix_fmt".to_string(),
            "yuv420p".to_string(),
            "-c:v".to_string(),
            "libx264".to_string(),
        ]);
        if request.audio_path.is_some() {
            args.extend_from_slice(&[
                "-c:a".to_string(),
                "aac".to_string(),
                "-shortest".to_string(),
            ]);
        }
        args.push(output_abs.to_string_lossy().to_string());
        self.run_command("ffmpeg", &args).await?;

        Ok(AudioTransformResult {
            output_path: request.output_path.trim().trim_start_matches('/').to_string(),
            duration_ms: Some(duration_ms),
        })
    }

    async fn stitch_images_with_audio(
        &self,
        request: &StitchImagesWithAudioRequest,
    ) -> Result<AudioTransformResult> {
        if request.image_paths.is_empty() {
            anyhow::bail!("At least one image path is required");
        }
        let width = request.width.unwrap_or(1080);
        let height = request.height.unwrap_or(1920);
        let fps = request.fps.unwrap_or(30);
        let output_abs = self.resolve_rel_path(&request.output_path)?;
        self.ensure_parent_dir(&output_abs)?;
        let concat_abs = output_abs.with_extension("images.ffconcat");

        let durations = request
            .durations_ms
            .clone()
            .unwrap_or_else(|| vec![DEFAULT_CARD_DURATION_MS; request.image_paths.len()]);
        let mut concat = String::from("ffconcat version 1.0\n");
        for (index, rel_path) in request.image_paths.iter().enumerate() {
            let image_abs = self.resolve_rel_path(rel_path)?;
            let duration = durations
                .get(index)
                .copied()
                .unwrap_or(DEFAULT_CARD_DURATION_MS);
            concat.push_str(&format!("file '{}'\n", image_abs.to_string_lossy().replace('\'', "'\\''")));
            concat.push_str(&format!("duration {}\n", duration as f64 / 1000.0));
        }
        let last_image = self.resolve_rel_path(request.image_paths.last().expect("checked above"))?;
        concat.push_str(&format!("file '{}'\n", last_image.to_string_lossy().replace('\'', "'\\''")));
        tokio::fs::write(&concat_abs, concat).await?;

        let audio_abs = self.resolve_rel_path(&request.audio_path)?;
        self.run_command(
            "ffmpeg",
            &vec![
                "-y".to_string(),
                "-f".to_string(),
                "concat".to_string(),
                "-safe".to_string(),
                "0".to_string(),
                "-i".to_string(),
                concat_abs.to_string_lossy().to_string(),
                "-i".to_string(),
                audio_abs.to_string_lossy().to_string(),
                "-vf".to_string(),
                format!(
                    "scale={}:{}:force_original_aspect_ratio=decrease,pad={}:{}:(ow-iw)/2:(oh-ih)/2:black,fps={fps}",
                    width, height, width, height
                ),
                "-pix_fmt".to_string(),
                "yuv420p".to_string(),
                "-c:v".to_string(),
                "libx264".to_string(),
                "-c:a".to_string(),
                "aac".to_string(),
                "-shortest".to_string(),
                output_abs.to_string_lossy().to_string(),
            ],
        )
        .await?;

        Ok(AudioTransformResult {
            output_path: request.output_path.trim().trim_start_matches('/').to_string(),
            duration_ms: ffprobe_duration_ms(&output_abs).await.ok(),
        })
    }

    async fn compose_simple_clip(
        &self,
        request: &ComposeSimpleClipRequest,
    ) -> Result<ComposeSimpleClipResult> {
        if request.preset.as_deref().unwrap_or("audio_insight_basic") != "audio_insight_basic" {
            anyhow::bail!("Unsupported compose_simple_clip preset");
        }

        if let Some(image_paths) = request.image_paths.as_ref().filter(|items| !items.is_empty()) {
            let stitched = self
                .stitch_images_with_audio(&StitchImagesWithAudioRequest {
                    image_paths: image_paths.clone(),
                    audio_path: request.audio_path.clone(),
                    durations_ms: None,
                    width: Some(1080),
                    height: Some(1920),
                    fps: Some(30),
                    output_path: request.output_path.clone(),
                })
                .await?;
            return Ok(ComposeSimpleClipResult {
                output_path: stitched.output_path.clone(),
                artifacts: vec![stitched.output_path],
                duration_ms: stitched.duration_ms,
            });
        }

        let mut cards = request.cards.clone().unwrap_or_default();
        if cards.is_empty() {
            let title = request
                .title
                .as_deref()
                .map(str::trim)
                .filter(|value| !value.is_empty())
                .ok_or_else(|| anyhow::anyhow!("compose_simple_clip needs cards or title"))?;
            cards.push(MediaCard {
                text: title.to_string(),
                start_ms: Some(0),
                end_ms: Some(DEFAULT_CARD_DURATION_MS),
            });
        }
        let rendered = self
            .render_text_card_video(&RenderTextCardVideoRequest {
                cards,
                audio_path: Some(request.audio_path.clone()),
                width: Some(1080),
                height: Some(1920),
                fps: Some(30),
                theme: Some("black_white".to_string()),
                output_path: request.output_path.clone(),
            })
            .await?;

        Ok(ComposeSimpleClipResult {
            output_path: rendered.output_path.clone(),
            artifacts: vec![rendered.output_path],
            duration_ms: rendered.duration_ms,
        })
    }
}

pub fn transcript_rel_path_for_media(media_rel_path: &str) -> Option<String> {
    let normalized = media_rel_path.trim_start_matches('/');
    let relative = normalized.strip_prefix("journals/media/")?;
    let media_rel = StdPath::new(relative);
    let stem = media_rel.file_stem()?.to_str()?.trim();
    if stem.is_empty() {
        return None;
    }

    let mut out = PathBuf::from("journals/text/transcriptions");
    if let Some(parent) = media_rel.parent() {
        if !parent.as_os_str().is_empty() {
            out.push(parent);
        }
    }
    out.push(format!("{stem}.txt"));
    Some(out.to_string_lossy().replace('\\', "/"))
}

pub fn transcript_json_rel_path(transcript_rel_path: &str) -> String {
    match transcript_rel_path.rsplit_once('.') {
        Some((base, _)) => format!("{base}.json"),
        None => format!("{transcript_rel_path}.json"),
    }
}

pub fn transcript_srt_rel_path(transcript_rel_path: &str) -> String {
    match transcript_rel_path.rsplit_once('.') {
        Some((base, _)) => format!("{base}.srt"),
        None => format!("{transcript_rel_path}.srt"),
    }
}

fn format_seconds_ms(duration_ms: u64) -> String {
    format!("{:.3}", duration_ms as f64 / 1000.0)
}

fn infer_card_duration_ms(cards: &[MediaCard]) -> u64 {
    cards
        .iter()
        .filter_map(|card| card.end_ms)
        .max()
        .unwrap_or_else(|| cards.len() as u64 * DEFAULT_CARD_DURATION_MS)
}

fn build_srt(cards: &[MediaCard]) -> String {
    let mut current_start = 0;
    let mut out = String::new();
    for (idx, card) in cards.iter().enumerate() {
        let text = card.text.trim();
        if text.is_empty() {
            continue;
        }
        let start = card.start_ms.unwrap_or(current_start);
        let end = card
            .end_ms
            .unwrap_or_else(|| start.saturating_add(DEFAULT_CARD_DURATION_MS));
        current_start = end;
        out.push_str(&format!(
            "{}\n{} --> {}\n{}\n\n",
            idx + 1,
            format_srt_timestamp(start),
            format_srt_timestamp(end),
            text
        ));
    }
    out
}

fn format_srt_timestamp(ms: u64) -> String {
    let hours = ms / 3_600_000;
    let minutes = (ms % 3_600_000) / 60_000;
    let seconds = (ms % 60_000) / 1_000;
    let millis = ms % 1_000;
    format!("{hours:02}:{minutes:02}:{seconds:02},{millis:03}")
}

fn escape_ffmpeg_filter_path(path: &StdPath) -> String {
    path.to_string_lossy()
        .replace('\\', "/")
        .replace(':', "\\:")
}

async fn ffprobe_duration_ms(path: &StdPath) -> Result<u64> {
    let output = tokio::time::timeout(
        Duration::from_secs(30),
        Command::new("ffprobe")
            .arg("-v")
            .arg("error")
            .arg("-show_entries")
            .arg("format=duration")
            .arg("-of")
            .arg("default=noprint_wrappers=1:nokey=1")
            .arg(path)
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .kill_on_drop(true)
            .output(),
    )
    .await
    .context("ffprobe timed out")?
    .context("failed to execute ffprobe")?;

    if !output.status.success() {
        anyhow::bail!(
            "ffprobe failed: {}",
            String::from_utf8_lossy(&output.stderr).trim()
        );
    }

    let raw = String::from_utf8_lossy(&output.stdout).trim().to_string();
    let seconds: f64 = raw.parse().context("failed to parse ffprobe duration")?;
    Ok((seconds * 1000.0).round() as u64)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn transcript_paths_follow_media_tree() {
        assert_eq!(
            transcript_rel_path_for_media("journals/media/audio/day/clip.m4a").as_deref(),
            Some("journals/text/transcriptions/audio/day/clip.txt")
        );
    }

    #[test]
    fn srt_builder_uses_defaults() {
        let srt = build_srt(&[MediaCard {
            text: "hello".to_string(),
            start_ms: None,
            end_ms: None,
        }]);
        assert!(srt.contains("00:00:00,000 --> 00:00:03,000"));
        assert!(srt.contains("hello"));
    }
}
