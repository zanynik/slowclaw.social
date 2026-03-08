use anyhow::{anyhow, bail, Result as AnyhowResult};
use serde::{Deserialize, Serialize};
use serde_json::Value;
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

const TRANSCRIBE_MEDIA_OPERATION_KEY: &str = "transcribe_media";
const DEFAULT_TRANSCRIPTION_MODEL_FILE: &str = "ggml-base.en.bin";

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
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
struct TranscribeMediaOutput {
    transcript_path: String,
    text_length: usize,
}

#[derive(Clone, Default)]
pub struct ContentJobState {
    pub active_job_ids: Arc<Mutex<HashSet<String>>>,
}

fn built_in_operations() -> Vec<BuiltInOperation> {
    vec![
        BuiltInOperation {
            key: "transcribe_media".to_string(),
            title: "Transcribe Media".to_string(),
            description: "Runs on-device Whisper transcription for local journal audio or video.".to_string(),
            version: 1,
            implemented: true,
        },
        BuiltInOperation {
            key: "trim_media".to_string(),
            title: "Trim Media".to_string(),
            description: "Reserved for future built-in local media editing.".to_string(),
            version: 1,
            implemented: false,
        },
        BuiltInOperation {
            key: "clean_transcript".to_string(),
            title: "Clean Transcript".to_string(),
            description: "Reserved for future text cleanup built on local content operations.".to_string(),
            version: 1,
            implemented: false,
        },
        BuiltInOperation {
            key: "rewrite_text".to_string(),
            title: "Rewrite Text".to_string(),
            description: "Reserved for future AI-assisted text rewrite flows.".to_string(),
            version: 1,
            implemented: false,
        },
        BuiltInOperation {
            key: "retitle_entry".to_string(),
            title: "Retitle Entry".to_string(),
            description: "Reserved for future AI-assisted journal retitling.".to_string(),
            version: 1,
            implemented: false,
        },
        BuiltInOperation {
            key: "summarize_entry".to_string(),
            title: "Summarize Entry".to_string(),
            description: "Reserved for future AI-assisted summarization.".to_string(),
            version: 1,
            implemented: false,
        },
        BuiltInOperation {
            key: "post_bluesky".to_string(),
            title: "Post to Bluesky".to_string(),
            description: "Reserved for future typed Bluesky posting operation.".to_string(),
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
            if let Ok(resource_path) = app.path().resolve(format!("models/{filename}"), tauri::path::BaseDirectory::Resource) {
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
) -> AnyhowResult<String> {
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
    let mut out = String::new();
    for segment in state.as_iter() {
        let trimmed = segment.to_str_lossy()?.trim().to_string();
        if trimmed.is_empty() {
            continue;
        }
        if !out.is_empty() {
            out.push('\n');
        }
        out.push_str(&trimmed);
    }
    Ok(out)
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

async fn run_transcription_job(
    app: AppHandle,
    state: ContentJobState,
    workspace_dir: PathBuf,
    journal_id: String,
    media_rel_path: String,
    media_abs_path: PathBuf,
    transcript_rel_path: String,
    transcript_abs_path: PathBuf,
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
    let transcript_result = tauri::async_runtime::spawn_blocking(move || -> AnyhowResult<String> {
        let pcm_samples = decode_media_to_mono_16khz(&blocking_media_path)?;
        if pcm_samples.is_empty() {
            bail!("decoded audio was empty");
        }
        transcribe_audio_with_whisper(&blocking_model_path, &pcm_samples, language.as_deref())
    })
    .await;

    let transcript_text = match transcript_result {
        Ok(Ok(text)) if !text.trim().is_empty() => text,
        Ok(Ok(_)) => {
            update("failed", "Whisper produced an empty transcript", Some("empty transcript"), None);
            complete_active_job(&state, &job_id);
            return;
        }
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

    if let Some(parent) = transcript_abs_path.parent() {
        if let Err(error) = std::fs::create_dir_all(parent) {
            let message = format!("failed to create transcript directory: {error}");
            update("failed", "Could not write transcript", Some(&message), None);
            complete_active_job(&state, &job_id);
            return;
        }
    }

    if let Err(error) = std::fs::write(&transcript_abs_path, &transcript_text) {
        let message = format!("failed to write transcript: {error}");
        update("failed", "Could not write transcript", Some(&message), None);
        complete_active_job(&state, &job_id);
        return;
    }

    let _ = local_store::update_journal_entry_text(
        &workspace_dir,
        &journal_id,
        &transcript_text,
        &transcript_text.chars().take(280).collect::<String>(),
    );

    let output_json = serde_json::to_string(&TranscribeMediaOutput {
        transcript_path: transcript_rel_path,
        text_length: transcript_text.chars().count(),
    })
    .ok();

    update(
        "completed",
        "Transcript ready",
        None,
        output_json.as_deref(),
    );

    let _ = media_rel_path;
    complete_active_job(&state, &job_id);
}

fn job_is_active(job: &ContentJob) -> bool {
    matches!(job.status.as_str(), "queued" | "running")
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

    let Some(entry) = local_store::get_journal_entry(&config.workspace_dir, &job.target_id)
        .map_err(|e| format!("failed to load journal for job {}: {e}", job.id))?
    else {
        return Ok(());
    };
    let media_rel_path = string_field(&entry, "workspacePath");
    if media_rel_path.is_empty() {
        return Ok(());
    }
    let transcript_rel_path = if let Some(output) = job.output.as_ref() {
        output
            .get("transcriptPath")
            .and_then(Value::as_str)
            .map(ToOwned::to_owned)
            .or_else(|| transcript_rel_path_for_media(&media_rel_path))
    } else {
        transcript_rel_path_for_media(&media_rel_path)
    }
    .ok_or_else(|| "failed to derive transcript path".to_string())?;
    let media_abs_path = config.workspace_dir.join(&media_rel_path);
    let transcript_abs_path = config.workspace_dir.join(&transcript_rel_path);

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
            transcript_abs_path,
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

    let Some(entry) = local_store::get_journal_entry(&config.workspace_dir, &journal_id)
        .map_err(|e| format!("failed to load journal entry: {e}"))?
    else {
        return Err("journal not found".to_string());
    };

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
    let media_abs_path = config.workspace_dir.join(&media_rel_path);
    let transcript_abs_path = config.workspace_dir.join(&transcript_rel_path);
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
                transcript_abs_path,
                config,
                job_id,
            )
            .await;
        });
    }

    Ok(job)
}
