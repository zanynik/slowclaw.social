//! In-process GGUF model inference engine.
//!
//! When the `native-inference` feature is enabled, this module loads a GGUF
//! model file using `llama-cpp-2` and runs text generation locally on the
//! device. On iOS this uses Metal acceleration via Apple's GPU.
//!
//! When the feature is disabled, all functions return a clear error explaining
//! that the native inference engine was not compiled into this build.

use serde::{Deserialize, Serialize};

#[allow(unused_imports)]
use std::path::PathBuf;
#[allow(unused_imports)]
use std::sync::{Arc, Mutex, OnceLock};

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct InferenceRequest {
    pub prompt: String,
    #[serde(default = "default_max_tokens")]
    pub max_tokens: u32,
    #[serde(default = "default_temperature")]
    pub temperature: f32,
    pub system_prompt: Option<String>,
}

fn default_max_tokens() -> u32 {
    512
}

fn default_temperature() -> f32 {
    0.7
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct InferenceResponse {
    pub text: String,
    pub model_id: String,
    pub tokens_generated: u32,
    pub tokens_per_second: f64,
    pub stop_reason: String,
}

// ── Feature-gated implementation ─────────────────────────────────────────────

#[cfg(feature = "native-inference")]
mod engine {
    use super::*;
    use llama_cpp_2::context::params::LlamaContextParams;
    use llama_cpp_2::llama_backend::LlamaBackend;
    use llama_cpp_2::llama_batch::LlamaBatch;
    use llama_cpp_2::model::params::LlamaModelParams;
    use llama_cpp_2::model::{LlamaChatMessage, LlamaModel};
    use llama_cpp_2::sampling::LlamaSampler;

    /// Singleton inference engine state.
    struct EngineState {
        backend: LlamaBackend,
        model: Option<LoadedModel>,
    }

    struct LoadedModel {
        model: LlamaModel,
        model_id: String,
        model_path: PathBuf,
    }

    static ENGINE: OnceLock<Arc<Mutex<EngineState>>> = OnceLock::new();

    fn get_engine() -> &'static Arc<Mutex<EngineState>> {
        ENGINE.get_or_init(|| {
            let backend = LlamaBackend::init().expect("failed to initialize llama.cpp backend");
            Arc::new(Mutex::new(EngineState {
                backend,
                model: None,
            }))
        })
    }

    pub fn load_model(model_id: &str, model_path: &str) -> Result<String, String> {
        let path = PathBuf::from(model_path);
        if !path.is_file() {
            return Err(format!(
                "Model file not found: {}. Re-download the model.",
                path.display()
            ));
        }

        // Pre-check: validate file is readable and has reasonable size
        let file_meta = std::fs::metadata(&path)
            .map_err(|e| format!("Cannot read model file metadata: {e} — path: {}", path.display()))?;
        let file_size = file_meta.len();
        if file_size < 1024 {
            return Err(format!(
                "Model file is too small ({file_size} bytes). File may be corrupted. Re-download the model."
            ));
        }

        // Pre-check: validate GGUF magic number (first 4 bytes = "GGUF")
        let mut magic = [0u8; 4];
        std::fs::File::open(&path)
            .and_then(|mut f| {
                use std::io::Read;
                f.read_exact(&mut magic)
            })
            .map_err(|e| format!("Cannot read model file header: {e}"))?;
        if &magic != b"GGUF" {
            return Err(format!(
                "File is not a valid GGUF model (magic: {:?}). Re-download the model.",
                magic
            ));
        }

        let engine = get_engine();
        let mut state = engine
            .lock()
            .map_err(|e| format!("engine lock poisoned: {e}"))?;

        // Skip if already loaded
        if let Some(loaded) = &state.model {
            if loaded.model_path == path {
                return Ok(format!("Model already loaded: {model_id}"));
            }
        }

        // Drop previous model before loading new one (frees GPU/RAM)
        state.model = None;

        // iOS has tight per-app RAM limits even when device storage is large.
        // Prefer mmap for large models so pages stay file-backed, and fall back
        // through CPU/offload modes when Metal allocation fails.
        let is_ios = cfg!(target_os = "ios");
        let load_attempts: Vec<(u32, bool)> = if is_ios {
            if file_size > 2_500_000_000 {
                vec![(0, true), (16, true), (0, false)]
            } else {
                vec![(99, true), (0, true), (99, false), (0, false)]
            }
        } else {
            vec![(99, true)]
        };

        let mut last_error = String::new();
        let mut loaded_model = None;
        for (gpu_layers, use_mmap) in load_attempts {
            eprintln!(
                "[inference] Loading model '{}' ({:.1} GB) mmap={} gpu_layers={} path={}",
                model_id,
                file_size as f64 / 1_073_741_824.0,
                use_mmap,
                gpu_layers,
                path.display()
            );

            let model_params = LlamaModelParams::default()
                .with_n_gpu_layers(gpu_layers)
                .with_use_mmap(use_mmap);

            match LlamaModel::load_from_file(&state.backend, &path, &model_params) {
                Ok(model) => {
                    eprintln!(
                        "[inference] Model loaded successfully: {} mmap={} gpu_layers={}",
                        model_id, use_mmap, gpu_layers
                    );
                    loaded_model = Some(model);
                    break;
                }
                Err(err) => {
                    last_error = format!("mmap={use_mmap} gpu_layers={gpu_layers}: {err}");
                    eprintln!("[inference] Model load attempt failed: {last_error}");
                }
            }
        }

        let model = loaded_model.ok_or_else(|| {
            format!(
                "Failed to load GGUF model '{}' ({:.1} GB): {last_error}. \
                 This usually means the model is too large for this iPhone's available RAM, \
                 or the GGUF architecture is not supported by this build. \
                 Try the recommended 1.5B iPhone model first.",
                model_id,
                file_size as f64 / 1_073_741_824.0
            )
        })?;

        state.model = Some(LoadedModel {
            model,
            model_id: model_id.to_string(),
            model_path: path,
        });

        Ok(format!("Model loaded: {model_id}"))
    }

    pub fn run_inference(req: &InferenceRequest) -> Result<InferenceResponse, String> {
        let engine = get_engine();
        let state = engine
            .lock()
            .map_err(|e| format!("engine lock poisoned: {e}"))?;

        let loaded = state
            .model
            .as_ref()
            .ok_or("No model loaded. Configure a model first.")?;

        let model = &loaded.model;

        // Build the prompt using the model's built-in chat template.
        // This handles Gemma (<start_of_turn>), Llama, ChatML, etc. automatically.
        let mut messages: Vec<LlamaChatMessage> = Vec::new();
        if let Some(sys) = &req.system_prompt {
            messages.push(
                LlamaChatMessage::new("system".to_string(), sys.clone())
                    .map_err(|e| format!("system message error: {e}"))?,
            );
        }
        messages.push(
            LlamaChatMessage::new("user".to_string(), req.prompt.clone())
                .map_err(|e| format!("user message error: {e}"))?,
        );

        let full_prompt = match model.chat_template(None) {
            Ok(tmpl) => model
                .apply_chat_template(&tmpl, &messages, true)
                .map_err(|e| format!("chat template failed: {e}"))?,
            Err(_) => {
                // Fallback to ChatML if model has no embedded template
                if let Some(sys) = &req.system_prompt {
                    format!(
                        "<|im_start|>system\n{sys}<|im_end|>\n<|im_start|>user\n{}<|im_end|>\n<|im_start|>assistant\n",
                        req.prompt
                    )
                } else {
                    format!(
                        "<|im_start|>user\n{}<|im_end|>\n<|im_start|>assistant\n",
                        req.prompt
                    )
                }
            }
        };

        // Tokenize the prompt
        let tokens = model
            .str_to_token(&full_prompt, llama_cpp_2::model::AddBos::Always)
            .map_err(|e| format!("tokenization failed: {e}"))?;

        let n_ctx = 2048u32.min(req.max_tokens + tokens.len() as u32 + 64);
        let ctx_params = LlamaContextParams::default()
            .with_n_ctx(std::num::NonZeroU32::new(n_ctx))
            .with_n_batch(512);

        let mut ctx = model
            .new_context(&state.backend, ctx_params)
            .map_err(|e| format!("context creation failed: {e}"))?;

        // Create a batch and add prompt tokens
        let mut batch = LlamaBatch::new(n_ctx as usize, 1);

        for (i, &token) in tokens.iter().enumerate() {
            let is_last = i == tokens.len() - 1;
            batch
                .add(token, i as i32, &[0], is_last)
                .map_err(|e| format!("batch add failed: {e}"))?;
        }

        // Decode the prompt
        ctx.decode(&mut batch)
            .map_err(|e| format!("prompt decode failed: {e}"))?;

        // Setup sampler
        let mut sampler = LlamaSampler::chain_simple([
            LlamaSampler::temp(req.temperature),
            LlamaSampler::dist(42),
        ]);

        // Generate tokens
        let mut output_tokens = Vec::new();
        let mut n_cur = tokens.len() as i32;
        let start_time = std::time::Instant::now();
        let max_tokens = req.max_tokens as usize;
        let mut stop_reason = "max_tokens".to_string();

        for _ in 0..max_tokens {
            let new_token = sampler.sample(&ctx, batch.n_tokens() - 1);

            // Check for EOS
            if model.is_eog_token(new_token) {
                stop_reason = "eos".to_string();
                break;
            }

            output_tokens.push(new_token);

            // Prepare next batch
            batch.clear();
            batch
                .add(new_token, n_cur, &[0], true)
                .map_err(|e| format!("batch add failed: {e}"))?;
            n_cur += 1;

            ctx.decode(&mut batch)
                .map_err(|e| format!("decode failed: {e}"))?;
        }

        let elapsed = start_time.elapsed().as_secs_f64();
        let tokens_generated = output_tokens.len() as u32;
        let tokens_per_second = if elapsed > 0.0 {
            tokens_generated as f64 / elapsed
        } else {
            0.0
        };

        // Detokenize output
        let text: String = output_tokens
            .iter()
            .map(|&t| {
                match model.token_to_piece_bytes(t, 128, true, None) {
                    Ok(bytes) => String::from_utf8_lossy(&bytes).into_owned(),
                    Err(_) => String::new(),
                }
            })
            .collect();

        // Clean up chat template end tokens from output
        let cleaned = text
            .trim_end_matches("<|im_end|>")
            .trim_end_matches("<|endoftext|>")
            .trim_end_matches("<end_of_turn>")
            .trim()
            .to_string();

        Ok(InferenceResponse {
            text: cleaned,
            model_id: loaded.model_id.clone(),
            tokens_generated,
            tokens_per_second,
            stop_reason,
        })
    }

    pub fn is_model_loaded() -> bool {
        let engine = get_engine();
        engine
            .lock()
            .map(|state| state.model.is_some())
            .unwrap_or(false)
    }

    pub fn loaded_model_id() -> Option<String> {
        let engine = get_engine();
        engine
            .lock()
            .ok()
            .and_then(|state| state.model.as_ref().map(|m| m.model_id.clone()))
    }
}

#[cfg(not(feature = "native-inference"))]
mod engine {
    use super::*;

    pub fn load_model(_model_id: &str, _model_path: &str) -> Result<String, String> {
        Err(
            "Native local inference engine is not compiled into this build. \
             Rebuild with the `native-inference` feature to enable on-device AI."
                .to_string(),
        )
    }

    pub fn run_inference(_req: &InferenceRequest) -> Result<InferenceResponse, String> {
        Err(
            "Native local inference engine is not compiled into this build. \
             Rebuild with the `native-inference` feature to enable on-device AI."
                .to_string(),
        )
    }

    pub fn is_model_loaded() -> bool {
        false
    }

    pub fn loaded_model_id() -> Option<String> {
        None
    }
}

// ── Public API ───────────────────────────────────────────────────────────────

pub use engine::{is_model_loaded, load_model, loaded_model_id, run_inference};
