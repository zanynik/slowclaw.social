use anyhow::{anyhow, bail, Result as AnyhowResult};
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use std::collections::HashSet;
use std::fs::File;
use std::io::ErrorKind;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex};
use symphonia::core::audio::SampleBuffer;
use symphonia::core::codecs::{DecoderOptions, CODEC_TYPE_NULL};
use symphonia::core::errors::Error as SymphoniaError;
use symphonia::core::formats::FormatOptions;
use symphonia::core::io::MediaSourceStream;
use symphonia::core::meta::MetadataOptions;
use symphonia::core::probe::Hint;
use symphonia::default::{get_codecs, get_probe};
use tauri::{AppHandle, Manager};
use whisper_rs::{FullParams, SamplingStrategy, WhisperContext, WhisperContextParameters};
use zeroclaw::gateway::local_store;
use zeroclaw::providers::openai_codex::OpenAiCodexProvider;
use zeroclaw::providers::traits::Provider;
use zeroclaw::providers::ProviderRuntimeOptions;

const TRANSCRIBE_MEDIA_OPERATION_KEY: &str = "transcribe_media";
const SUMMARIZE_ENTRY_OPERATION_KEY: &str = "summarize_entry";
const EXTRACT_TODOS_OPERATION_KEY: &str = "extract_todos";
const EXTRACT_CALENDAR_CANDIDATES_OPERATION_KEY: &str = "extract_calendar_candidates";
const REWRITE_TEXT_OPERATION_KEY: &str = "rewrite_text";
const RETITLE_ENTRY_OPERATION_KEY: &str = "retitle_entry";
const SELECT_CLIPS_OPERATION_KEY: &str = "select_clips";
const EXTRACT_CLIPS_OPERATION_KEY: &str = "extract_clips";
const POST_BLUESKY_OPERATION_KEY: &str = "post_bluesky";
const DEFAULT_TRANSCRIPTION_MODEL_FILE: &str = "ggml-base.en.bin";
const DEFAULT_EDITORIAL_MODEL: &str = "gpt-5.3-codex";

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct BuiltInOperation {
    pub key: String,
    pub title: String,
    pub description: String,
    pub version: u32,
    pub implemented: bool,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ContentJob {
    pub id: String,
    pub operation_key: String,
    pub target_id: String,
    pub target_path: String,
    pub status: String,
    pub progress_label: String,
    pub error: Option<String>,
    pub output: Option<Value>,
    pub created_at: String,
    pub updated_at: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct TranscribeMediaInput {
    model_path: String,
    transcript_path: String,
    timed_transcript_path: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct TranscribeMediaOutput {
    transcript_path: String,
    timed_transcript_path: String,
    artifact_type: String,
    text_length: usize,
    cue_count: usize,
    duration_seconds: f32,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct TranscriptCue {
    index: usize,
    start: f32,
    end: f32,
    text: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct CanonicalTranscript {
    source_media: String,
    mode: String,
    language: String,
    duration_seconds: f32,
    cues: Vec<TranscriptCue>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct SummaryResult {
    summary: String,
    bullets: Vec<String>,
    source_refs: Vec<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct TodoCandidate {
    title: String,
    details: String,
    priority: String,
    due_hint: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct TodoExtractionResult {
    todos: Vec<TodoCandidate>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct CalendarCandidate {
    title: String,
    date_hint: String,
    time_hint: String,
    details: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct CalendarExtractionResult {
    events: Vec<CalendarCandidate>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct RewriteResult {
    text: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct RetitleResult {
    title: String,
    rationale: String,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct CueRange {
    start: usize,
    end: usize,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct ClipSpec {
    id: String,
    title: String,
    rationale: String,
    cue_ranges: Vec<CueRange>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct ClipSpecResult {
    clips: Vec<ClipSpec>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct ExtractedClip {
    id: String,
    title: String,
    media_file: Option<String>,
    transcript_text_file: String,
    transcript_srt_file: String,
    timed_transcript_json: String,
    source_ranges: Vec<CueRange>,
    output_duration_seconds: f32,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct ClipManifest {
    source_media: String,
    clips: Vec<ExtractedClip>,
}

#[derive(Clone, Default)]
pub struct ContentJobState {
    pub active_job_ids: Arc<Mutex<HashSet<String>>>,
}

fn built_in_operations() -> Vec<BuiltInOperation> {
    vec![
        BuiltInOperation {
            key: TRANSCRIBE_MEDIA_OPERATION_KEY.to_string(),
            title: "Transcribe Media".to_string(),
            description: "Runs on-device Whisper and writes a canonical timed transcript plus plain text.".to_string(),
            version: 1,
            implemented: true,
        },
        BuiltInOperation {
            key: SUMMARIZE_ENTRY_OPERATION_KEY.to_string(),
            title: "Summarize Entry".to_string(),
            description: "Generates a structured summary from local journal text or transcript content.".to_string(),
            version: 1,
            implemented: true,
        },
        BuiltInOperation {
            key: EXTRACT_TODOS_OPERATION_KEY.to_string(),
            title: "Extract Todos".to_string(),
            description: "Extracts structured todo candidates from local journal text or transcripts.".to_string(),
            version: 1,
            implemented: true,
        },
        BuiltInOperation {
            key: EXTRACT_CALENDAR_CANDIDATES_OPERATION_KEY.to_string(),
            title: "Extract Calendar Candidates".to_string(),
            description: "Extracts event candidates without mutating the user calendar.".to_string(),
            version: 1,
            implemented: true,
        },
        BuiltInOperation {
            key: REWRITE_TEXT_OPERATION_KEY.to_string(),
            title: "Rewrite Text".to_string(),
            description: "Creates a cleaned-up rewrite from local journal or transcript text.".to_string(),
            version: 1,
            implemented: true,
        },
        BuiltInOperation {
            key: RETITLE_ENTRY_OPERATION_KEY.to_string(),
            title: "Retitle Entry".to_string(),
            description: "Suggests a clearer title for the current journal entry.".to_string(),
            version: 1,
            implemented: true,
        },
        BuiltInOperation {
            key: SELECT_CLIPS_OPERATION_KEY.to_string(),
            title: "Select Clips".to_string(),
            description: "Uses the timed transcript to choose reusable clip ranges.".to_string(),
            version: 1,
            implemented: true,
        },
        BuiltInOperation {
            key: EXTRACT_CLIPS_OPERATION_KEY.to_string(),
            title: "Extract Clips".to_string(),
            description: "Cuts transcript-derived clips and remapped transcript artifacts. Uses ffmpeg on supported desktop hosts.".to_string(),
            version: 1,
            implemented: !cfg!(target_os = "ios"),
        },
        BuiltInOperation {
            key: POST_BLUESKY_OPERATION_KEY.to_string(),
            title: "Post to Bluesky".to_string(),
            description: "Posting is available through the app UI; a typed native posting operation is still pending.".to_string(),
            version: 1,
            implemented: false,
        },
    ]
}

fn string_field(value: &Value, key: &str) -> String {
    value
        .get(key)
        .and_then(Value::as_str)
        .unwrap_or_default()
        .to_string()
}

fn optional_string_field(value: &Value, key: &str) -> Option<String> {
    let raw = string_field(value, key);
    let trimmed = raw.trim();
    if trimmed.is_empty() {
        None
    } else {
        Some(trimmed.to_string())
    }
}

fn content_job_from_value(value: Value) -> ContentJob {
    let output = value
        .get("outputJson")
        .and_then(Value::as_str)
        .and_then(|raw| serde_json::from_str::<Value>(raw).ok());
    ContentJob {
        id: string_field(&value, "id"),
        operation_key: string_field(&value, "operationKey"),
        target_id: string_field(&value, "targetId"),
        target_path: string_field(&value, "targetPath"),
        status: string_field(&value, "status"),
        progress_label: string_field(&value, "progressLabel"),
        error: optional_string_field(&value, "error"),
        output,
        created_at: optional_string_field(&value, "createdAtClient")
            .or_else(|| optional_string_field(&value, "created"))
            .unwrap_or_default(),
        updated_at: optional_string_field(&value, "updated")
            .or_else(|| optional_string_field(&value, "created"))
            .unwrap_or_default(),
    }
}

fn transcript_rel_path_for_media(media_rel_path: &str) -> Option<String> {
    let normalized = media_rel_path.trim_start_matches('/');
    let relative = normalized.strip_prefix("journals/media/")?;
    let media_rel = Path::new(relative);
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

fn timed_transcript_rel_path_for_media(media_rel_path: &str) -> Option<String> {
    let normalized = media_rel_path.trim_start_matches('/');
    let relative = normalized.strip_prefix("journals/media/")?;
    let media_rel = Path::new(relative);
    let stem = media_rel.file_stem()?.to_str()?.trim();
    if stem.is_empty() {
        return None;
    }
    let mut out = PathBuf::from("artifacts/transcripts");
    if let Some(parent) = media_rel.parent() {
        if !parent.as_os_str().is_empty() {
            out.push(parent);
        }
    }
    out.push(format!("{stem}.timed_transcript.json"));
    Some(out.to_string_lossy().replace('\\', "/"))
}

fn recipe_artifact_rel_path(journal_id: &str, operation_key: &str, extension: &str) -> String {
    format!(
        "artifacts/recipes/{journal_id}/{operation_key}.{extension}",
        journal_id = sanitize_path_component(journal_id),
        operation_key = sanitize_path_component(operation_key),
        extension = extension.trim_start_matches('.')
    )
}

fn clip_output_dir_rel_path(journal_id: &str) -> String {
    format!("artifacts/clips/{}", sanitize_path_component(journal_id))
}

fn sanitize_path_component(value: &str) -> String {
    let mut out = String::new();
    for ch in value.chars() {
        if ch.is_ascii_alphanumeric() || matches!(ch, '-' | '_' | '.') {
            out.push(ch);
        }
    }
    if out.is_empty() {
        "artifact".to_string()
    } else {
        out
    }
}

fn candidate_model_filenames(model_hint: &str) -> Vec<String> {
    let trimmed = model_hint.trim();
    if trimmed.is_empty() {
        return vec![DEFAULT_TRANSCRIPTION_MODEL_FILE.to_string()];
    }
    let mut out = vec![trimmed.to_string()];
    let alias = trimmed.trim_end_matches(".bin");
    match alias {
        "tiny" => out.push("ggml-tiny.bin".to_string()),
        "tiny.en" => out.push("ggml-tiny.en.bin".to_string()),
        "base" => out.push("ggml-base.bin".to_string()),
        "base.en" => out.push("ggml-base.en.bin".to_string()),
        "small" => out.push("ggml-small.bin".to_string()),
        "small.en" => out.push("ggml-small.en.bin".to_string()),
        other if !other.starts_with("ggml-") && !other.ends_with(".bin") => {
            out.push(format!("ggml-{other}.bin"));
            out.push(format!("ggml-{other}.en.bin"));
        }
        _ => {}
    }
    out.sort();
    out.dedup();
    out
}

fn resolve_transcription_model_path(
    app: &AppHandle,
    config: &zeroclaw::Config,
) -> Result<PathBuf, String> {
    let model_hint = config.transcription.model.trim();
    let direct_path = PathBuf::from(model_hint);
    if direct_path.is_absolute() && direct_path.exists() {
        return Ok(direct_path);
    }

    let mut candidate_paths = Vec::new();
    for filename in candidate_model_filenames(model_hint) {
        let file_path = PathBuf::from(&filename);
        if file_path.is_relative() {
            candidate_paths.push(config.workspace_dir.join("models").join(&filename));
            if let Ok(resource_path) = app
                .path()
                .resolve(format!("models/{filename}"), tauri::path::BaseDirectory::Resource)
            {
                candidate_paths.push(resource_path);
            }
        } else {
            candidate_paths.push(file_path);
        }
    }

    for candidate in candidate_paths {
        if candidate.exists() {
            return Ok(candidate);
        }
    }

    Err(format!(
        "No bundled Whisper model was found. Add a ggml Whisper model under web/src-tauri/resources/models/ or workspace/models/ and point transcription.model at it (current hint: {}).",
        if model_hint.is_empty() {
            DEFAULT_TRANSCRIPTION_MODEL_FILE
        } else {
            model_hint
        }
    ))
}

fn resample_to_16khz(samples: &[f32], sample_rate: u32) -> Vec<f32> {
    if sample_rate == 16_000 || samples.is_empty() {
        return samples.to_vec();
    }
    let ratio = 16_000.0f64 / sample_rate as f64;
    let output_len = ((samples.len() as f64) * ratio).round().max(1.0) as usize;
    let mut out = Vec::with_capacity(output_len);
    for index in 0..output_len {
        let source_pos = (index as f64) / ratio;
        let left = source_pos.floor() as usize;
        let right = left.saturating_add(1).min(samples.len().saturating_sub(1));
        let frac = (source_pos - left as f64) as f32;
        let left_sample = samples[left];
        let right_sample = samples[right];
        out.push(left_sample + (right_sample - left_sample) * frac);
    }
    out
}

fn decode_media_to_mono_16khz(media_abs_path: &Path) -> AnyhowResult<Vec<f32>> {
    let mut hint = Hint::new();
    if let Some(ext) = media_abs_path.extension().and_then(|ext| ext.to_str()) {
        hint.with_extension(ext);
    }

    let file = File::open(media_abs_path)
        .map_err(|e| anyhow!("failed to open media {}: {e}", media_abs_path.display()))?;
    let media_source = MediaSourceStream::new(Box::new(file), Default::default());
    let probed = get_probe()
        .format(&hint, media_source, &FormatOptions::default(), &MetadataOptions::default())
        .map_err(|e| anyhow!("failed to probe media {}: {e}", media_abs_path.display()))?;
    let mut format = probed.format;
    let track = format
        .tracks()
        .iter()
        .find(|track| track.codec_params.codec != CODEC_TYPE_NULL)
        .ok_or_else(|| anyhow!("no supported audio track found in {}", media_abs_path.display()))?;
    let sample_rate = track
        .codec_params
        .sample_rate
        .ok_or_else(|| anyhow!("media sample rate missing for {}", media_abs_path.display()))?;
    let channels = track
        .codec_params
        .channels
        .ok_or_else(|| anyhow!("media channel layout missing for {}", media_abs_path.display()))?
        .count();
    let track_id = track.id;
    let mut decoder = get_codecs()
        .make(&track.codec_params, &DecoderOptions::default())
        .map_err(|e| anyhow!("failed to create media decoder: {e}"))?;

    let mut mono_samples = Vec::new();
    loop {
        let packet = match format.next_packet() {
            Ok(packet) => packet,
            Err(SymphoniaError::IoError(err)) if err.kind() == ErrorKind::UnexpectedEof => break,
            Err(err) => return Err(anyhow!("failed to read media packet: {err}")),
        };
        if packet.track_id() != track_id {
            continue;
        }

        let decoded = match decoder.decode(&packet) {
            Ok(decoded) => decoded,
            Err(SymphoniaError::DecodeError(_)) => continue,
            Err(SymphoniaError::IoError(err)) if err.kind() == ErrorKind::UnexpectedEof => break,
            Err(err) => return Err(anyhow!("failed to decode media packet: {err}")),
        };
        let mut sample_buffer = SampleBuffer::<f32>::new(decoded.capacity() as u64, *decoded.spec());
        sample_buffer.copy_interleaved_ref(decoded);
        let interleaved = sample_buffer.samples();

        if channels <= 1 {
            mono_samples.extend_from_slice(interleaved);
        } else {
            for frame in interleaved.chunks(channels) {
                let mut sum = 0.0f32;
                for sample in frame {
                    sum += *sample;
                }
                mono_samples.push(sum / channels as f32);
            }
        }
    }

    Ok(resample_to_16khz(&mono_samples, sample_rate))
}

fn transcribe_audio_with_whisper(
    model_path: &Path,
    pcm_samples: &[f32],
    language: Option<&str>,
    source_media: &str,
) -> AnyhowResult<(CanonicalTranscript, String)> {
    let context = WhisperContext::new_with_params(
        model_path
            .to_str()
            .ok_or_else(|| anyhow!("invalid model path {}", model_path.display()))?,
        WhisperContextParameters::default(),
    )?;
    let mut state = context.create_state()?;
    let mut params = FullParams::new(SamplingStrategy::Greedy { best_of: 1 });
    params.set_n_threads(2);
    params.set_translate(false);
    params.set_print_special(false);
    params.set_print_progress(false);
    params.set_print_realtime(false);
    params.set_print_timestamps(false);
    if let Some(language) = language.map(str::trim).filter(|value| !value.is_empty()) {
        params.set_language(Some(language));
    }

    state.full(params, pcm_samples)?;
    let mut cues = Vec::new();
    let mut plain_lines = Vec::new();
    for (index, segment) in state.as_iter().enumerate() {
        let text = segment.to_str_lossy()?.trim().to_string();
        if text.is_empty() {
            continue;
        }
        let start = (segment.start_timestamp() as f32 / 100.0).max(0.0);
        let end = (segment.end_timestamp() as f32 / 100.0).max(start);
        plain_lines.push(text.clone());
        cues.push(TranscriptCue {
            index,
            start,
            end,
            text,
        });
    }
    if cues.is_empty() {
        bail!("Whisper produced no transcript cues");
    }

    let duration_seconds = (pcm_samples.len() as f32) / 16_000.0;
    let transcript = CanonicalTranscript {
        source_media: source_media.to_string(),
        mode: "transcribe".to_string(),
        language: language.unwrap_or("auto").trim().to_string(),
        duration_seconds,
        cues,
    };
    Ok((transcript, plain_lines.join("\n")))
}

fn canonical_transcript_preview(transcript: &CanonicalTranscript) -> String {
    transcript
        .cues
        .iter()
        .take(3)
        .map(|cue| cue.text.as_str())
        .collect::<Vec<_>>()
        .join(" ")
        .chars()
        .take(280)
        .collect()
}

fn write_pretty_json<T: Serialize>(path: &Path, payload: &T) -> Result<(), String> {
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)
            .map_err(|e| format!("failed to create artifact directory {}: {e}", parent.display()))?;
    }
    let body = serde_json::to_vec_pretty(payload)
        .map_err(|e| format!("failed to serialize JSON artifact {}: {e}", path.display()))?;
    std::fs::write(path, body).map_err(|e| format!("failed to write artifact {}: {e}", path.display()))
}

fn write_text_artifact(path: &Path, content: &str) -> Result<(), String> {
    if let Some(parent) = path.parent() {
        std::fs::create_dir_all(parent)
            .map_err(|e| format!("failed to create artifact directory {}: {e}", parent.display()))?;
    }
    std::fs::write(path, content).map_err(|e| format!("failed to write artifact {}: {e}", path.display()))
}

fn register_artifact(
    workspace_dir: &Path,
    journal_id: &str,
    artifact_type: &str,
    title: &str,
    mime_type: &str,
    workspace_path: &str,
    preview_text: &str,
    metadata_json: &str,
) {
    let _ = local_store::create_artifact_metadata(
        workspace_dir,
        &local_store::ArtifactInput {
            parent_asset_id: String::new(),
            parent_entry_id: journal_id.to_string(),
            artifact_type: artifact_type.to_string(),
            title: title.to_string(),
            status: "ready".to_string(),
            mime_type: mime_type.to_string(),
            workspace_path: workspace_path.to_string(),
            preview_text: preview_text.chars().take(280).collect(),
            metadata_json: metadata_json.to_string(),
            created_at_client: None,
        },
    );
}

fn register_active_job(state: &ContentJobState, job_id: &str) -> bool {
    let Ok(mut guard) = state.active_job_ids.lock() else {
        return true;
    };
    guard.insert(job_id.to_string())
}

fn complete_active_job(state: &ContentJobState, job_id: &str) {
    if let Ok(mut guard) = state.active_job_ids.lock() {
        guard.remove(job_id);
    }
}

fn job_is_active(job: &ContentJob) -> bool {
    matches!(job.status.as_str(), "queued" | "running")
}

fn load_journal_entry(workspace_dir: &Path, journal_id: &str) -> Result<Value, String> {
    local_store::get_journal_entry(workspace_dir, journal_id)
        .map_err(|e| format!("failed to load journal entry: {e}"))?
        .ok_or_else(|| "journal not found".to_string())
}

fn journal_source_text(entry: &Value) -> String {
    string_field(entry, "textBody")
}

fn choose_editorial_model(config: &zeroclaw::Config) -> String {
    let candidate = config
        .default_model
        .as_deref()
        .unwrap_or(DEFAULT_EDITORIAL_MODEL)
        .trim();
    if candidate.is_empty() || candidate.ends_with(".bin") {
        DEFAULT_EDITORIAL_MODEL.to_string()
    } else {
        candidate.to_string()
    }
}

fn provider_options_from_config(config: &zeroclaw::Config) -> ProviderRuntimeOptions {
    ProviderRuntimeOptions {
        zeroclaw_dir: config.config_path.parent().map(PathBuf::from),
        secrets_encrypt: config.secrets.encrypt,
        ..ProviderRuntimeOptions::default()
    }
}

async fn run_editorial_prompt(
    config: &zeroclaw::Config,
    system_prompt: &str,
    user_prompt: &str,
) -> Result<String, String> {
    let provider = OpenAiCodexProvider::new(&provider_options_from_config(config), None)
        .map_err(|e| format!("failed to initialize editorial provider: {e}"))?;
    provider
        .chat_with_system(
            Some(system_prompt),
            user_prompt,
            &choose_editorial_model(config),
            0.2,
        )
        .await
        .map_err(|e| format!("editorial request failed: {e}"))
}

fn strip_code_fences(raw: &str) -> String {
    let trimmed = raw.trim();
    if let Some(stripped) = trimmed.strip_prefix("```") {
        let stripped = stripped
            .strip_prefix("json")
            .or_else(|| stripped.strip_prefix("JSON"))
            .unwrap_or(stripped);
        if let Some(end) = stripped.rfind("```") {
            return stripped[..end].trim().to_string();
        }
    }
    trimmed.to_string()
}

fn parse_json_response<T>(raw: &str) -> Result<T, String>
where
    T: for<'de> Deserialize<'de>,
{
    let trimmed = strip_code_fences(raw);
    if let Ok(parsed) = serde_json::from_str::<T>(&trimmed) {
        return Ok(parsed);
    }

    let start = trimmed.find(['{', '[']).unwrap_or(0);
    let end_obj = trimmed.rfind('}');
    let end_arr = trimmed.rfind(']');
    let end = match (end_obj, end_arr) {
        (Some(obj), Some(arr)) => obj.max(arr),
        (Some(obj), None) => obj,
        (None, Some(arr)) => arr,
        (None, None) => {
            return Err("model response did not contain valid JSON".to_string());
        }
    };
    serde_json::from_str::<T>(&trimmed[start..=end])
        .map_err(|e| format!("failed to parse model JSON: {e}"))
}

fn canonical_transcript_from_job_output(workspace_dir: &Path, journal_id: &str) -> Result<CanonicalTranscript, String> {
    let latest = local_store::find_latest_content_job_for_target(
        workspace_dir,
        TRANSCRIBE_MEDIA_OPERATION_KEY,
        journal_id,
    )
    .map_err(|e| format!("failed to load transcription job: {e}"))?
    .ok_or_else(|| "no transcript job found for this journal".to_string())?;
    let job = content_job_from_value(latest);
    let Some(output) = job.output else {
        return Err("transcript job output missing".to_string());
    };
    let timed_path = output
        .get("timedTranscriptPath")
        .and_then(Value::as_str)
        .map(ToOwned::to_owned)
        .ok_or_else(|| "timed transcript path missing".to_string())?;
    let abs_path = workspace_dir.join(&timed_path);
    let raw = std::fs::read_to_string(&abs_path)
        .map_err(|e| format!("failed to read timed transcript {}: {e}", abs_path.display()))?;
    serde_json::from_str::<CanonicalTranscript>(&raw)
        .map_err(|e| format!("failed to parse timed transcript {}: {e}", abs_path.display()))
}

fn ensure_entry_text_for_editorial(
    workspace_dir: &Path,
    journal_id: &str,
    entry: &Value,
) -> Result<String, String> {
    let direct = journal_source_text(entry);
    if !direct.trim().is_empty() {
        return Ok(direct);
    }
    let transcript = canonical_transcript_from_job_output(workspace_dir, journal_id)?;
    Ok(transcript
        .cues
        .iter()
        .map(|cue| cue.text.as_str())
        .collect::<Vec<_>>()
        .join("\n"))
}

fn create_sync_job(
    workspace_dir: &Path,
    operation_key: &str,
    target_id: &str,
    target_path: &str,
    input_json: Value,
    progress_label: &str,
) -> Result<ContentJob, String> {
    let raw = local_store::create_content_job(
        workspace_dir,
        &local_store::ContentJobInput {
            operation_key: operation_key.to_string(),
            target_id: target_id.to_string(),
            target_path: target_path.to_string(),
            input_json: serde_json::to_string(&input_json)
                .map_err(|e| format!("failed to encode operation input: {e}"))?,
            status: "running".to_string(),
            progress_label: progress_label.to_string(),
            error: String::new(),
            created_at_client: None,
        },
    )
    .map_err(|e| format!("failed to create content job: {e}"))?;
    Ok(content_job_from_value(raw))
}

fn complete_sync_job(
    workspace_dir: &Path,
    job_id: &str,
    progress_label: &str,
    output_json: &Value,
) -> Result<ContentJob, String> {
    let encoded = serde_json::to_string(output_json)
        .map_err(|e| format!("failed to encode job output: {e}"))?;
    let raw = local_store::update_content_job(
        workspace_dir,
        job_id,
        "completed",
        progress_label,
        None,
        Some(&encoded),
    )
    .map_err(|e| format!("failed to complete content job: {e}"))?
    .ok_or_else(|| "content job disappeared while completing".to_string())?;
    Ok(content_job_from_value(raw))
}

fn fail_sync_job(
    workspace_dir: &Path,
    job_id: &str,
    progress_label: &str,
    error: &str,
) -> Result<(), String> {
    local_store::update_content_job(workspace_dir, job_id, "failed", progress_label, Some(error), None)
        .map_err(|e| format!("failed to update failed content job: {e}"))?;
    Ok(())
}

fn write_srt(path: &Path, cues: &[TranscriptCue]) -> Result<(), String> {
    fn ts(secs: f32) -> String {
        let total_ms = (secs.max(0.0) * 1000.0).round() as u64;
        let hours = total_ms / 3_600_000;
        let minutes = (total_ms % 3_600_000) / 60_000;
        let seconds = (total_ms % 60_000) / 1000;
        let millis = total_ms % 1000;
        format!("{hours:02}:{minutes:02}:{seconds:02},{millis:03}")
    }

    let mut out = String::new();
    for cue in cues {
        out.push_str(&(cue.index + 1).to_string());
        out.push('\n');
        out.push_str(&format!("{} --> {}\n", ts(cue.start), ts(cue.end)));
        out.push_str(cue.text.trim());
        out.push_str("\n\n");
    }
    write_text_artifact(path, &out)
}

fn subset_clip_cues(transcript: &CanonicalTranscript, ranges: &[CueRange]) -> Result<Vec<TranscriptCue>, String> {
    let mut selected = Vec::new();
    for range in ranges {
        if range.end < range.start {
            return Err(format!("invalid cue range {}..{}", range.start, range.end));
        }
        for idx in range.start..=range.end {
            let cue = transcript
                .cues
                .get(idx)
                .ok_or_else(|| format!("cue index {idx} out of bounds"))?;
            selected.push(cue.clone());
        }
    }
    if selected.is_empty() {
        return Err("clip contains no cues".to_string());
    }
    Ok(selected)
}

#[cfg(not(target_os = "ios"))]
fn cut_media_clip_ffmpeg(
    source_media: &Path,
    dest_media: &Path,
    start: f32,
    end: f32,
) -> Result<(), String> {
    use std::process::Command;

    if let Some(parent) = dest_media.parent() {
        std::fs::create_dir_all(parent)
            .map_err(|e| format!("failed to create clip directory {}: {e}", parent.display()))?;
    }
    let duration = (end - start).max(0.05);
    let status = Command::new("ffmpeg")
        .arg("-y")
        .arg("-ss")
        .arg(format!("{start:.3}"))
        .arg("-i")
        .arg(source_media)
        .arg("-t")
        .arg(format!("{duration:.3}"))
        .arg("-c")
        .arg("copy")
        .arg(dest_media)
        .status()
        .map_err(|e| format!("failed to start ffmpeg: {e}"))?;
    if status.success() {
        Ok(())
    } else {
        Err(format!("ffmpeg exited with status {status}"))
    }
}

#[cfg(target_os = "ios")]
fn cut_media_clip_ffmpeg(
    _source_media: &Path,
    _dest_media: &Path,
    _start: f32,
    _end: f32,
) -> Result<(), String> {
    Err("clip media extraction is not available on iOS yet; add a native media backend in a future update".to_string())
}

async fn run_transcription_job(
    app: AppHandle,
    state: ContentJobState,
    workspace_dir: PathBuf,
    journal_id: String,
    media_rel_path: String,
    media_abs_path: PathBuf,
    transcript_rel_path: String,
    timed_transcript_rel_path: String,
    transcript_abs_path: PathBuf,
    timed_transcript_abs_path: PathBuf,
    config: zeroclaw::Config,
    job_id: String,
) {
    let update = |status: &str, progress_label: &str, error: Option<&str>, output_json: Option<&str>| {
        let _ = local_store::update_content_job(
            &workspace_dir,
            &job_id,
            status,
            progress_label,
            error,
            output_json,
        );
    };

    update("running", "Decoding local media for Whisper...", None, None);

    let language = config.transcription.language.clone();
    let model_path = match resolve_transcription_model_path(&app, &config) {
        Ok(path) => path,
        Err(error) => {
            update("retryable", "Whisper model missing", Some(&error), None);
            complete_active_job(&state, &job_id);
            return;
        }
    };

    let blocking_media_path = media_abs_path.clone();
    let blocking_model_path = model_path.clone();
    let source_media = media_rel_path.clone();
    let transcript_result = tauri::async_runtime::spawn_blocking(move || -> AnyhowResult<(CanonicalTranscript, String)> {
        let pcm_samples = decode_media_to_mono_16khz(&blocking_media_path)?;
        if pcm_samples.is_empty() {
            bail!("decoded audio was empty");
        }
        transcribe_audio_with_whisper(&blocking_model_path, &pcm_samples, language.as_deref(), &source_media)
    })
    .await;

    let (canonical_transcript, transcript_text) = match transcript_result {
        Ok(Ok(result)) => result,
        Ok(Err(error)) => {
            let message = error.to_string();
            update("failed", "Whisper transcription failed", Some(&message), None);
            complete_active_job(&state, &job_id);
            return;
        }
        Err(error) => {
            let message = format!("transcription worker crashed: {error}");
            update("failed", "Whisper worker failed", Some(&message), None);
            complete_active_job(&state, &job_id);
            return;
        }
    };

    if let Err(error) = write_text_artifact(&transcript_abs_path, &transcript_text) {
        update("failed", "Could not write transcript", Some(&error), None);
        complete_active_job(&state, &job_id);
        return;
    }
    if let Err(error) = write_pretty_json(&timed_transcript_abs_path, &canonical_transcript) {
        update("failed", "Could not write timed transcript", Some(&error), None);
        complete_active_job(&state, &job_id);
        return;
    }

    let _ = local_store::update_journal_entry_text(
        &workspace_dir,
        &journal_id,
        &transcript_text,
        &transcript_text.chars().take(280).collect::<String>(),
    );

    register_artifact(
        &workspace_dir,
        &journal_id,
        "canonical_transcript",
        "Canonical timed transcript",
        "application/json",
        &timed_transcript_rel_path,
        &canonical_transcript_preview(&canonical_transcript),
        &serde_json::to_string(&json!({
            "sourceMedia": media_rel_path,
            "durationSeconds": canonical_transcript.duration_seconds,
            "cueCount": canonical_transcript.cues.len(),
        }))
        .unwrap_or_default(),
    );
    register_artifact(
        &workspace_dir,
        &journal_id,
        "transcript_text",
        "Plain transcript text",
        "text/plain",
        &transcript_rel_path,
        &transcript_text,
        &serde_json::to_string(&json!({
            "sourceMedia": media_rel_path,
            "timedTranscriptPath": timed_transcript_rel_path,
        }))
        .unwrap_or_default(),
    );

    let output_json = serde_json::to_string(&TranscribeMediaOutput {
        transcript_path: transcript_rel_path,
        timed_transcript_path: timed_transcript_rel_path,
        artifact_type: "canonical_transcript".to_string(),
        text_length: transcript_text.chars().count(),
        cue_count: canonical_transcript.cues.len(),
        duration_seconds: canonical_transcript.duration_seconds,
    })
    .ok();

    update("completed", "Transcript ready", None, output_json.as_deref());
    complete_active_job(&state, &job_id);
}

async fn maybe_resume_transcription_job(
    app: AppHandle,
    state: ContentJobState,
    job: ContentJob,
) -> Result<(), String> {
    let config = zeroclaw::Config::load_or_init()
        .await
        .map_err(|e| format!("failed to load config: {e}"))?;
    local_store::initialize(&config.workspace_dir)
        .map_err(|e| format!("failed to initialize local store: {e}"))?;

    let entry = load_journal_entry(&config.workspace_dir, &job.target_id)?;
    let media_rel_path = string_field(&entry, "workspacePath");
    if media_rel_path.is_empty() {
        return Ok(());
    }

    let transcript_rel_path = job
        .output
        .as_ref()
        .and_then(|output| output.get("transcriptPath"))
        .and_then(Value::as_str)
        .map(ToOwned::to_owned)
        .or_else(|| transcript_rel_path_for_media(&media_rel_path))
        .ok_or_else(|| "failed to derive transcript path".to_string())?;
    let timed_transcript_rel_path = job
        .output
        .as_ref()
        .and_then(|output| output.get("timedTranscriptPath"))
        .and_then(Value::as_str)
        .map(ToOwned::to_owned)
        .or_else(|| timed_transcript_rel_path_for_media(&media_rel_path))
        .ok_or_else(|| "failed to derive timed transcript path".to_string())?;

    let media_abs_path = config.workspace_dir.join(&media_rel_path);
    let transcript_abs_path = config.workspace_dir.join(&transcript_rel_path);
    let timed_transcript_abs_path = config.workspace_dir.join(&timed_transcript_rel_path);
    if !media_abs_path.exists() {
        let _ = local_store::update_content_job(
            &config.workspace_dir,
            &job.id,
            "failed",
            "Source media missing",
            Some("source media file not found"),
            None,
        );
        return Ok(());
    }
    if !register_active_job(&state, &job.id) {
        return Ok(());
    }

    let state_for_task = state.clone();
    tauri::async_runtime::spawn(async move {
        run_transcription_job(
            app,
            state_for_task,
            config.workspace_dir.clone(),
            job.target_id,
            media_rel_path,
            media_abs_path,
            transcript_rel_path,
            timed_transcript_rel_path,
            transcript_abs_path,
            timed_transcript_abs_path,
            config,
            job.id,
        )
        .await;
    });
    Ok(())
}

pub async fn resume_pending_content_jobs(app: AppHandle, state: ContentJobState) {
    let config = match zeroclaw::Config::load_or_init().await {
        Ok(config) => config,
        Err(err) => {
            eprintln!("failed to load config for content job resume: {err}");
            return;
        }
    };
    if let Err(err) = local_store::initialize(&config.workspace_dir) {
        eprintln!("failed to initialize local store for content job resume: {err}");
        return;
    }
    let jobs = match local_store::list_content_jobs(&config.workspace_dir, 200) {
        Ok(jobs) => jobs,
        Err(err) => {
            eprintln!("failed to load content jobs for resume: {err}");
            return;
        }
    };

    let mut seen_targets = HashSet::new();
    for raw in jobs {
        let job = content_job_from_value(raw);
        if job.operation_key != TRANSCRIBE_MEDIA_OPERATION_KEY {
            continue;
        }
        if !matches!(job.status.as_str(), "queued" | "running" | "retryable") {
            continue;
        }
        if !seen_targets.insert(job.target_id.clone()) {
            continue;
        }
        let _ = maybe_resume_transcription_job(app.clone(), state.clone(), job).await;
    }
}

#[tauri::command]
pub fn list_builtin_operations() -> Vec<BuiltInOperation> {
    built_in_operations()
}

#[tauri::command]
pub async fn list_content_jobs(limit: Option<usize>) -> Result<Vec<ContentJob>, String> {
    let config = zeroclaw::Config::load_or_init()
        .await
        .map_err(|e| format!("failed to load config: {e}"))?;
    local_store::initialize(&config.workspace_dir)
        .map_err(|e| format!("failed to initialize local store: {e}"))?;
    let jobs = local_store::list_content_jobs(&config.workspace_dir, limit.unwrap_or(100))
        .map_err(|e| format!("failed to list content jobs: {e}"))?;
    Ok(jobs.into_iter().map(content_job_from_value).collect())
}

#[tauri::command]
pub async fn get_content_job(id: String) -> Result<Option<ContentJob>, String> {
    let config = zeroclaw::Config::load_or_init()
        .await
        .map_err(|e| format!("failed to load config: {e}"))?;
    local_store::initialize(&config.workspace_dir)
        .map_err(|e| format!("failed to initialize local store: {e}"))?;
    let job = local_store::get_content_job(&config.workspace_dir, &id)
        .map_err(|e| format!("failed to load content job: {e}"))?;
    Ok(job.map(content_job_from_value))
}

#[tauri::command]
pub async fn get_latest_content_job_for_target(
    operation_key: String,
    target_id: String,
) -> Result<Option<ContentJob>, String> {
    let config = zeroclaw::Config::load_or_init()
        .await
        .map_err(|e| format!("failed to load config: {e}"))?;
    local_store::initialize(&config.workspace_dir)
        .map_err(|e| format!("failed to initialize local store: {e}"))?;
    let job = local_store::find_latest_content_job_for_target(
        &config.workspace_dir,
        &operation_key,
        &target_id,
    )
    .map_err(|e| format!("failed to load latest content job: {e}"))?;
    Ok(job.map(content_job_from_value))
}

#[tauri::command]
pub async fn transcribe_media(
    app: AppHandle,
    state: tauri::State<'_, ContentJobState>,
    journal_id: String,
) -> Result<ContentJob, String> {
    let config = zeroclaw::Config::load_or_init()
        .await
        .map_err(|e| format!("failed to load config: {e}"))?;
    local_store::initialize(&config.workspace_dir)
        .map_err(|e| format!("failed to initialize local store: {e}"))?;

    let entry = load_journal_entry(&config.workspace_dir, &journal_id)?;
    let entry_type = string_field(&entry, "entryType");
    if !matches!(entry_type.as_str(), "audio" | "video") {
        return Err("transcription is only supported for audio or video journal entries".to_string());
    }

    let media_rel_path = string_field(&entry, "workspacePath");
    if media_rel_path.is_empty() {
        return Err("journal media path missing".to_string());
    }
    let transcript_rel_path = transcript_rel_path_for_media(&media_rel_path)
        .ok_or_else(|| "failed to derive transcript path".to_string())?;
    let timed_transcript_rel_path = timed_transcript_rel_path_for_media(&media_rel_path)
        .ok_or_else(|| "failed to derive timed transcript path".to_string())?;
    let media_abs_path = config.workspace_dir.join(&media_rel_path);
    let transcript_abs_path = config.workspace_dir.join(&transcript_rel_path);
    let timed_transcript_abs_path = config.workspace_dir.join(&timed_transcript_rel_path);
    if !media_abs_path.exists() {
        return Err("journal media file is missing".to_string());
    }

    if let Some(existing) = local_store::find_latest_content_job_for_target(
        &config.workspace_dir,
        TRANSCRIBE_MEDIA_OPERATION_KEY,
        &journal_id,
    )
    .map_err(|e| format!("failed to load existing transcription job: {e}"))?
    {
        let existing_job = content_job_from_value(existing);
        if job_is_active(&existing_job) {
            return Ok(existing_job);
        }
    }

    let model_path = resolve_transcription_model_path(&app, &config)?;
    let input_json = serde_json::to_string(&TranscribeMediaInput {
        model_path: model_path.display().to_string(),
        transcript_path: transcript_rel_path.clone(),
        timed_transcript_path: timed_transcript_rel_path.clone(),
    })
    .map_err(|e| format!("failed to encode transcription input: {e}"))?;

    let job = local_store::create_content_job(
        &config.workspace_dir,
        &local_store::ContentJobInput {
            operation_key: TRANSCRIBE_MEDIA_OPERATION_KEY.to_string(),
            target_id: journal_id.clone(),
            target_path: media_rel_path.clone(),
            input_json,
            status: "queued".to_string(),
            progress_label: "Queued for on-device Whisper".to_string(),
            error: String::new(),
            created_at_client: None,
        },
    )
    .map_err(|e| format!("failed to create transcription job: {e}"))?;
    let job = content_job_from_value(job);

    if register_active_job(&state, &job.id) {
        let job_id = job.id.clone();
        let state_for_task = state.inner().clone();
        tauri::async_runtime::spawn(async move {
            run_transcription_job(
                app,
                state_for_task,
                config.workspace_dir.clone(),
                journal_id,
                media_rel_path,
                media_abs_path,
                transcript_rel_path,
                timed_transcript_rel_path,
                transcript_abs_path,
                timed_transcript_abs_path,
                config,
                job_id,
            )
            .await;
        });
    }

    Ok(job)
}

async fn run_summary_like_operation<T>(
    operation_key: &str,
    journal_id: &str,
    system_prompt: &str,
    user_prompt: String,
    artifact_type: &str,
    artifact_extension: &str,
) -> Result<ContentJob, String>
where
    T: Serialize + for<'de> Deserialize<'de>,
{
    let config = zeroclaw::Config::load_or_init()
        .await
        .map_err(|e| format!("failed to load config: {e}"))?;
    local_store::initialize(&config.workspace_dir)
        .map_err(|e| format!("failed to initialize local store: {e}"))?;
    let entry = load_journal_entry(&config.workspace_dir, journal_id)?;
    let target_path = string_field(&entry, "workspacePath");
    let job = create_sync_job(
        &config.workspace_dir,
        operation_key,
        journal_id,
        &target_path,
        json!({ "journalId": journal_id }),
        "Running editorial recipe...",
    )?;

    let raw = match run_editorial_prompt(&config, system_prompt, &user_prompt).await {
        Ok(raw) => raw,
        Err(error) => {
            fail_sync_job(&config.workspace_dir, &job.id, "Editorial recipe failed", &error)?;
            return Err(error);
        }
    };
    let parsed: T = match parse_json_response(&raw) {
        Ok(parsed) => parsed,
        Err(error) => {
            fail_sync_job(&config.workspace_dir, &job.id, "Model output was not valid JSON", &error)?;
            return Err(error);
        }
    };

    let rel_path = recipe_artifact_rel_path(journal_id, operation_key, artifact_extension);
    let abs_path = config.workspace_dir.join(&rel_path);
    if artifact_extension == "txt" {
        let content = serde_json::to_value(&parsed)
            .ok()
            .and_then(|value| value.get("text").and_then(Value::as_str).map(ToOwned::to_owned))
            .unwrap_or_default();
        write_text_artifact(&abs_path, &content)?;
        register_artifact(
            &config.workspace_dir,
            journal_id,
            artifact_type,
            operation_key,
            "text/plain",
            &rel_path,
            &content,
            &serde_json::to_string(&json!({ "operationKey": operation_key })).unwrap_or_default(),
        );
    } else {
        write_pretty_json(&abs_path, &parsed)?;
        register_artifact(
            &config.workspace_dir,
            journal_id,
            artifact_type,
            operation_key,
            "application/json",
            &rel_path,
            &raw,
            &serde_json::to_string(&json!({ "operationKey": operation_key })).unwrap_or_default(),
        );
    }

    complete_sync_job(
        &config.workspace_dir,
        &job.id,
        "Recipe ready",
        &json!({
            "artifactType": artifact_type,
            "artifactPath": rel_path,
            "result": parsed,
        }),
    )
}

#[tauri::command]
pub async fn summarize_entry(journal_id: String) -> Result<ContentJob, String> {
    let config = zeroclaw::Config::load_or_init()
        .await
        .map_err(|e| format!("failed to load config: {e}"))?;
    let entry = load_journal_entry(&config.workspace_dir, &journal_id)?;
    let source_text = ensure_entry_text_for_editorial(&config.workspace_dir, &journal_id, &entry)?;
    let user_prompt = format!(
        "Return JSON only.\n\nSchema:\n{{\"summary\":\"string\",\"bullets\":[\"string\"],\"sourceRefs\":[\"string\"]}}\n\nSummarize this journal or transcript faithfully:\n\n{}",
        source_text
    );
    run_summary_like_operation::<SummaryResult>(
        SUMMARIZE_ENTRY_OPERATION_KEY,
        &journal_id,
        "You create concise structured summaries. Never invent facts. Keep output terse and useful.",
        user_prompt,
        "summary_json",
        "json",
    )
    .await
}

#[tauri::command]
pub async fn extract_todos(journal_id: String) -> Result<ContentJob, String> {
    let config = zeroclaw::Config::load_or_init()
        .await
        .map_err(|e| format!("failed to load config: {e}"))?;
    let entry = load_journal_entry(&config.workspace_dir, &journal_id)?;
    let source_text = ensure_entry_text_for_editorial(&config.workspace_dir, &journal_id, &entry)?;
    let user_prompt = format!(
        "Return JSON only.\n\nSchema:\n{{\"todos\":[{{\"title\":\"string\",\"details\":\"string\",\"priority\":\"low|medium|high\",\"dueHint\":\"string\"}}]}}\n\nExtract actionable todos from this text. Do not include speculative tasks.\n\n{}",
        source_text
    );
    run_summary_like_operation::<TodoExtractionResult>(
        EXTRACT_TODOS_OPERATION_KEY,
        &journal_id,
        "You extract actionable todo candidates from notes. Prefer omission over hallucination.",
        user_prompt,
        "todo_candidates_json",
        "json",
    )
    .await
}

#[tauri::command]
pub async fn extract_calendar_candidates(journal_id: String) -> Result<ContentJob, String> {
    let config = zeroclaw::Config::load_or_init()
        .await
        .map_err(|e| format!("failed to load config: {e}"))?;
    let entry = load_journal_entry(&config.workspace_dir, &journal_id)?;
    let source_text = ensure_entry_text_for_editorial(&config.workspace_dir, &journal_id, &entry)?;
    let user_prompt = format!(
        "Return JSON only.\n\nSchema:\n{{\"events\":[{{\"title\":\"string\",\"dateHint\":\"string\",\"timeHint\":\"string\",\"details\":\"string\"}}]}}\n\nExtract possible calendar events from this text. These are only candidates, not confirmed events.\n\n{}",
        source_text
    );
    run_summary_like_operation::<CalendarExtractionResult>(
        EXTRACT_CALENDAR_CANDIDATES_OPERATION_KEY,
        &journal_id,
        "You identify calendar-worthy events conservatively. Do not invent dates or commitments.",
        user_prompt,
        "calendar_candidates_json",
        "json",
    )
    .await
}

#[tauri::command]
pub async fn rewrite_text(
    journal_id: String,
    recipe_key: Option<String>,
    style: Option<String>,
) -> Result<ContentJob, String> {
    let config = zeroclaw::Config::load_or_init()
        .await
        .map_err(|e| format!("failed to load config: {e}"))?;
    let entry = load_journal_entry(&config.workspace_dir, &journal_id)?;
    let source_text = ensure_entry_text_for_editorial(&config.workspace_dir, &journal_id, &entry)?;
    let recipe_key = recipe_key.unwrap_or_else(|| "clear_and_polished".to_string());
    let style = style.unwrap_or_else(|| "clear, concise, and publishable".to_string());
    let user_prompt = format!(
        "Return JSON only.\n\nSchema:\n{{\"text\":\"string\"}}\n\nRewrite the following text using recipe `{}` with style `{}`. Preserve meaning, remove filler, and keep it readable.\n\n{}",
        recipe_key, style, source_text
    );
    run_summary_like_operation::<RewriteResult>(
        REWRITE_TEXT_OPERATION_KEY,
        &journal_id,
        "You rewrite content for clarity and polish without changing the core meaning.",
        user_prompt,
        "rewrite_text",
        "txt",
    )
    .await
}

#[tauri::command]
pub async fn retitle_entry(journal_id: String) -> Result<ContentJob, String> {
    let config = zeroclaw::Config::load_or_init()
        .await
        .map_err(|e| format!("failed to load config: {e}"))?;
    let entry = load_journal_entry(&config.workspace_dir, &journal_id)?;
    let source_text = ensure_entry_text_for_editorial(&config.workspace_dir, &journal_id, &entry)?;
    let current_title = string_field(&entry, "title");
    let user_prompt = format!(
        "Return JSON only.\n\nSchema:\n{{\"title\":\"string\",\"rationale\":\"string\"}}\n\nSuggest a better title for this journal. Current title: {:?}\n\nText:\n{}",
        current_title, source_text
    );
    run_summary_like_operation::<RetitleResult>(
        RETITLE_ENTRY_OPERATION_KEY,
        &journal_id,
        "You suggest short, concrete titles for journals. Avoid clickbait.",
        user_prompt,
        "retitle_suggestion_json",
        "json",
    )
    .await
}

#[tauri::command]
pub async fn select_clips(journal_id: String, objective: Option<String>) -> Result<ContentJob, String> {
    let config = zeroclaw::Config::load_or_init()
        .await
        .map_err(|e| format!("failed to load config: {e}"))?;
    local_store::initialize(&config.workspace_dir)
        .map_err(|e| format!("failed to initialize local store: {e}"))?;
    let transcript = canonical_transcript_from_job_output(&config.workspace_dir, &journal_id)?;
    let cues_json = serde_json::to_string_pretty(&transcript.cues)
        .map_err(|e| format!("failed to encode transcript cues: {e}"))?;
    let editorial_objective = objective.unwrap_or_else(|| {
        "Select short, self-contained highlights that would make good reusable social clips.".to_string()
    });
    let user_prompt = format!(
        "Return JSON only.\n\nSchema:\n{{\"clips\":[{{\"id\":\"clip-01\",\"title\":\"string\",\"rationale\":\"string\",\"cueRanges\":[{{\"start\":0,\"end\":2}}]}}]}}\n\nObjective:\n{}\n\nUse zero-based cue indices from this canonical transcript:\n{}",
        editorial_objective, cues_json
    );
    run_summary_like_operation::<ClipSpecResult>(
        SELECT_CLIPS_OPERATION_KEY,
        &journal_id,
        "You select clip ranges from a transcript. Only return valid, non-overlapping cue ranges that can stand alone.",
        user_prompt,
        "clip_specs_json",
        "json",
    )
    .await
}

#[tauri::command]
pub async fn extract_clips(journal_id: String) -> Result<ContentJob, String> {
    let config = zeroclaw::Config::load_or_init()
        .await
        .map_err(|e| format!("failed to load config: {e}"))?;
    local_store::initialize(&config.workspace_dir)
        .map_err(|e| format!("failed to initialize local store: {e}"))?;
    let entry = load_journal_entry(&config.workspace_dir, &journal_id)?;
    let source_media = string_field(&entry, "workspacePath");
    if source_media.trim().is_empty() {
        return Err("source media path missing".to_string());
    }
    let source_media_abs = config.workspace_dir.join(&source_media);
    if !source_media_abs.exists() {
        return Err("source media file is missing".to_string());
    }

    let latest_specs_job = local_store::find_latest_content_job_for_target(
        &config.workspace_dir,
        SELECT_CLIPS_OPERATION_KEY,
        &journal_id,
    )
    .map_err(|e| format!("failed to load clip selection job: {e}"))?
    .ok_or_else(|| "no clip selection found for this journal".to_string())?;
    let latest_specs_job = content_job_from_value(latest_specs_job);
    let specs_output = latest_specs_job
        .output
        .ok_or_else(|| "clip selection output missing".to_string())?;
    let clip_spec_path = specs_output
        .get("artifactPath")
        .and_then(Value::as_str)
        .ok_or_else(|| "clip spec artifact path missing".to_string())?;
    let clip_spec_raw = std::fs::read_to_string(config.workspace_dir.join(clip_spec_path))
        .map_err(|e| format!("failed to read clip spec artifact: {e}"))?;
    let clip_specs: ClipSpecResult = serde_json::from_str(&clip_spec_raw)
        .map_err(|e| format!("failed to parse clip specs: {e}"))?;
    if clip_specs.clips.is_empty() {
        return Err("clip selection returned no clips".to_string());
    }

    let transcript = canonical_transcript_from_job_output(&config.workspace_dir, &journal_id)?;
    let job = create_sync_job(
        &config.workspace_dir,
        EXTRACT_CLIPS_OPERATION_KEY,
        &journal_id,
        &source_media,
        json!({ "journalId": journal_id, "clipSpecPath": clip_spec_path }),
        "Extracting transcript-derived clips...",
    )?;

    let mut extracted = Vec::new();
    let clips_rel_dir = clip_output_dir_rel_path(&journal_id);
    let source_ext = Path::new(&source_media)
        .extension()
        .and_then(|ext| ext.to_str())
        .unwrap_or("mp4");

    for (index, clip) in clip_specs.clips.iter().enumerate() {
        let selected_cues = match subset_clip_cues(&transcript, &clip.cue_ranges) {
            Ok(cues) => cues,
            Err(error) => {
                let _ = fail_sync_job(&config.workspace_dir, &job.id, "Clip range validation failed", &error);
                return Err(error);
            }
        };
        let clip_start = selected_cues.first().map(|cue| cue.start).unwrap_or_default();
        let clip_end = selected_cues.last().map(|cue| cue.end).unwrap_or(clip_start);
        let base_name = format!("{:02}_{}", index + 1, sanitize_path_component(&clip.title));
        let media_rel_path = format!("{clips_rel_dir}/{base_name}.{source_ext}");
        let text_rel_path = format!("{clips_rel_dir}/{base_name}.txt");
        let srt_rel_path = format!("{clips_rel_dir}/{base_name}.srt");
        let timed_rel_path = format!("{clips_rel_dir}/{base_name}.timed_transcript.json");

        let rebased_cues = selected_cues
            .iter()
            .enumerate()
            .map(|(cue_index, cue)| TranscriptCue {
                index: cue_index,
                start: (cue.start - clip_start).max(0.0),
                end: (cue.end - clip_start).max(0.0),
                text: cue.text.clone(),
            })
            .collect::<Vec<_>>();
        let clip_transcript = CanonicalTranscript {
            source_media: media_rel_path.clone(),
            mode: "extract".to_string(),
            language: transcript.language.clone(),
            duration_seconds: (clip_end - clip_start).max(0.0),
            cues: rebased_cues.clone(),
        };
        let plain_text = rebased_cues
            .iter()
            .map(|cue| cue.text.as_str())
            .collect::<Vec<_>>()
            .join("\n");

        write_text_artifact(&config.workspace_dir.join(&text_rel_path), &plain_text)?;
        write_pretty_json(&config.workspace_dir.join(&timed_rel_path), &clip_transcript)?;
        write_srt(&config.workspace_dir.join(&srt_rel_path), &rebased_cues)?;

        let media_rel_output = match cut_media_clip_ffmpeg(
            &source_media_abs,
            &config.workspace_dir.join(&media_rel_path),
            clip_start,
            clip_end,
        ) {
            Ok(()) => Some(media_rel_path.clone()),
            Err(error) => {
                let _ = fail_sync_job(&config.workspace_dir, &job.id, "Clip extraction failed", &error);
                return Err(error);
            }
        };

        if let Some(ref media_path) = media_rel_output {
            register_artifact(
                &config.workspace_dir,
                &journal_id,
                "extracted_clip_media",
                &clip.title,
                "application/octet-stream",
                media_path,
                &clip.rationale,
                &serde_json::to_string(&json!({ "sourceMedia": source_media, "clipId": clip.id })).unwrap_or_default(),
            );
        }
        register_artifact(
            &config.workspace_dir,
            &journal_id,
            "clip_transcript_text",
            &clip.title,
            "text/plain",
            &text_rel_path,
            &plain_text,
            &serde_json::to_string(&json!({ "clipId": clip.id })).unwrap_or_default(),
        );
        register_artifact(
            &config.workspace_dir,
            &journal_id,
            "clip_transcript_json",
            &clip.title,
            "application/json",
            &timed_rel_path,
            &clip.rationale,
            &serde_json::to_string(&json!({ "clipId": clip.id })).unwrap_or_default(),
        );
        register_artifact(
            &config.workspace_dir,
            &journal_id,
            "subtitle_srt",
            &clip.title,
            "application/x-subrip",
            &srt_rel_path,
            &plain_text,
            &serde_json::to_string(&json!({ "clipId": clip.id })).unwrap_or_default(),
        );

        extracted.push(ExtractedClip {
            id: clip.id.clone(),
            title: clip.title.clone(),
            media_file: media_rel_output,
            transcript_text_file: text_rel_path,
            transcript_srt_file: srt_rel_path,
            timed_transcript_json: timed_rel_path,
            source_ranges: clip.cue_ranges.clone(),
            output_duration_seconds: clip_transcript.duration_seconds,
        });
    }

    let manifest = ClipManifest {
        source_media,
        clips: extracted,
    };
    let manifest_rel_path = format!("{clips_rel_dir}/clip_manifest.json");
    write_pretty_json(&config.workspace_dir.join(&manifest_rel_path), &manifest)?;
    register_artifact(
        &config.workspace_dir,
        &journal_id,
        "clip_manifest_json",
        "Clip manifest",
        "application/json",
        &manifest_rel_path,
        "Extracted clips",
        &serde_json::to_string(&json!({
            "clipCount": manifest.clips.len(),
            "sourceMedia": manifest.source_media,
        }))
        .unwrap_or_default(),
    );

    complete_sync_job(
        &config.workspace_dir,
        &job.id,
        "Clips extracted",
        &json!({
            "artifactType": "clip_manifest_json",
            "artifactPath": manifest_rel_path,
            "result": manifest,
        }),
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn timed_transcript_path_derives_expected_location() {
        let path = timed_transcript_rel_path_for_media("journals/media/audio/example.m4a").unwrap();
        assert_eq!(path, "artifacts/transcripts/audio/example.timed_transcript.json");
    }

    #[test]
    fn parse_json_response_handles_fenced_payloads() {
        let parsed: RewriteResult = parse_json_response("```json\n{\"text\":\"hello\"}\n```").unwrap();
        assert_eq!(parsed.text, "hello");
    }

    #[test]
    fn subset_clip_cues_validates_ranges() {
        let transcript = CanonicalTranscript {
            source_media: "journals/media/audio/test.m4a".to_string(),
            mode: "transcribe".to_string(),
            language: "en".to_string(),
            duration_seconds: 3.0,
            cues: vec![
                TranscriptCue { index: 0, start: 0.0, end: 1.0, text: "one".to_string() },
                TranscriptCue { index: 1, start: 1.0, end: 2.0, text: "two".to_string() },
            ],
        };
        assert_eq!(
            subset_clip_cues(&transcript, &[CueRange { start: 0, end: 1 }])
                .unwrap()
                .len(),
            2
        );
        assert!(subset_clip_cues(&transcript, &[CueRange { start: 3, end: 4 }]).is_err());
    }
}
