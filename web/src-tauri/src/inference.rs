//! In-process GGUF model inference engine.
//!
//! When the `native-inference` feature is enabled, this module loads a GGUF
//! model file using `llama-cpp-2` and runs text generation locally on the
//! device. On iOS the build links Metal, but the runtime defaults to CPU-backed
//! inference for stability because TestFlight devices showed uncatchable Metal
//! allocator crashes during repeated context creation.
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

        // Skip if already loaded AND Metal setting hasn't changed
        let metal_changed = std::env::var("SLOWCLAW_METAL_CHANGED").is_ok();
        if let Some(loaded) = &state.model {
            if loaded.model_path == path && !metal_changed {
                return Ok(format!("Model already loaded: {model_id}"));
            }
        }
        // Clear the change flag
        std::env::remove_var("SLOWCLAW_METAL_CHANGED");

        // Drop previous model before loading new one (frees GPU/RAM)
        state.model = None;

        // iOS has tight per-app RAM limits even when device storage is large.
        // Prefer mmap for large models so pages stay file-backed, and fall back
        // through CPU/offload modes when Metal allocation fails.
        let is_ios = cfg!(target_os = "ios");
        let use_metal = std::env::var("SLOWCLAW_USE_METAL")
            .map(|v| v == "1" || v.to_lowercase() == "true")
            .unwrap_or(false);
        let load_attempts: Vec<(u32, bool)> = if is_ios {
            if use_metal {
                // User opted in to Metal acceleration — try limited GPU offload first
                eprintln!("[inference] Metal mode ENABLED by user preference");
                vec![(16, true), (8, true), (0, true), (0, false)]
            } else {
                // Default stable: CPU-first, no Metal offload (avoids uncatchable crashes)
                vec![(0, true), (0, false)]
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

    /// Build a prompt string manually when the model's embedded Jinja2 template
    /// fails (common with Gemma 4's complex multimodal/tool-calling template).
    /// Detects model family from the model_id and uses the correct format.
    fn build_fallback_prompt(system_prompt: &Option<String>, user_prompt: &str, model_id: &str) -> String {
        let id_lower = model_id.to_lowercase();
        if id_lower.contains("gemma-4") || id_lower.contains("gemma4") {
            // Gemma 4 format uses <|turn>role / <turn|> delimiters
            // (NOT <start_of_turn>/<end_of_turn> which was Gemma 3)
            let mut prompt = String::new();
            if let Some(sys) = system_prompt {
                prompt.push_str("<|turn>system\n");
                prompt.push_str(sys);
                prompt.push_str("\n<turn|>\n");
            }
            prompt.push_str("<|turn>user\n");
            prompt.push_str(user_prompt);
            prompt.push_str("<turn|>\n");
            prompt.push_str("<|turn>model\n");
            prompt
        } else if id_lower.contains("gemma") {
            // Gemma 2/3 format
            let mut prompt = String::new();
            if let Some(sys) = system_prompt {
                prompt.push_str("<start_of_turn>user\n");
                prompt.push_str(sys);
                prompt.push_str("\n\n");
                prompt.push_str(user_prompt);
                prompt.push_str("<end_of_turn>\n");
            } else {
                prompt.push_str("<start_of_turn>user\n");
                prompt.push_str(user_prompt);
                prompt.push_str("<end_of_turn>\n");
            }
            prompt.push_str("<start_of_turn>model\n");
            prompt
        } else if id_lower.contains("llama") {
            // Llama 3 format
            let mut prompt = String::new();
            if let Some(sys) = system_prompt {
                prompt.push_str("<|start_header_id|>system<|end_header_id|>\n\n");
                prompt.push_str(sys);
                prompt.push_str("<|eot_id|>");
            }
            prompt.push_str("<|start_header_id|>user<|end_header_id|>\n\n");
            prompt.push_str(user_prompt);
            prompt.push_str("<|eot_id|><|start_header_id|>assistant<|end_header_id|>\n\n");
            prompt
        } else {
            // ChatML fallback (Qwen, Mistral, generic)
            let mut prompt = String::new();
            if let Some(sys) = system_prompt {
                prompt.push_str("<|im_start|>system\n");
                prompt.push_str(sys);
                prompt.push_str("<|im_end|>\n");
            }
            prompt.push_str("<|im_start|>user\n");
            prompt.push_str(user_prompt);
            prompt.push_str("<|im_end|>\n<|im_start|>assistant\n");
            prompt
        }
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
        // Gemma 4 models have complex Jinja2 templates (multimodal, thinking,
        // tool-calling) that can fail in llama.cpp's limited template engine.
        // We try the embedded template first, then fall back to known formats.
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
            Ok(tmpl) => match model.apply_chat_template(&tmpl, &messages, true) {
                Ok(prompt) => prompt,
                Err(e) => {
                    eprintln!("[inference] Embedded chat template failed ({e}), using Gemma/manual fallback");
                    build_fallback_prompt(&req.system_prompt, &req.prompt, &loaded.model_id)
                }
            },
            Err(_) => {
                eprintln!("[inference] No embedded chat template, using manual fallback");
                build_fallback_prompt(&req.system_prompt, &req.prompt, &loaded.model_id)
            }
        };

        // Tokenize the prompt
        let tokens = model
            .str_to_token(&full_prompt, llama_cpp_2::model::AddBos::Always)
            .map_err(|e| format!("tokenization failed: {e}"))?;

        // ── Context sizing & prompt truncation ─────────────────────────
        // iOS has limited RAM; cap the KV-cache to a safe ceiling.
        // The context must fit: prompt_tokens + generation headroom.
        // If the prompt is too long, truncate it (keep start + end).
        let max_ctx: u32 = if cfg!(target_os = "ios") { 1536 } else { 4096 };
        let gen_headroom = req.max_tokens.min(max_ctx / 2);
        let max_prompt_tokens = (max_ctx - gen_headroom - 8) as usize; // 8 for safety margin

        let tokens = if tokens.len() > max_prompt_tokens {
            eprintln!(
                "[inference] Prompt too long ({} tokens), truncating to {} (ctx={})",
                tokens.len(), max_prompt_tokens, max_ctx
            );
            // Keep the first 80% and last 20% of the budget so the model
            // sees both the instruction/system prompt and the tail of the content.
            let keep_start = max_prompt_tokens * 4 / 5;
            let keep_end = max_prompt_tokens - keep_start;
            let mut truncated = tokens[..keep_start].to_vec();
            truncated.extend_from_slice(&tokens[tokens.len() - keep_end..]);
            truncated
        } else {
            tokens
        };

        let n_ctx = (tokens.len() as u32 + gen_headroom + 8).min(max_ctx);
        eprintln!(
            "[inference] Context: n_ctx={} prompt_tokens={} gen_headroom={}",
            n_ctx, tokens.len(), gen_headroom
        );

        let n_batch: usize = if cfg!(target_os = "ios") { 128 } else { 512 };
        let ctx_params = LlamaContextParams::default()
            .with_n_ctx(std::num::NonZeroU32::new(n_ctx))
            .with_n_batch(n_batch as u32);

        let mut ctx = model
            .new_context(&state.backend, ctx_params)
            .map_err(|e| format!("context creation failed: {e}"))?;

        // Decode the prompt in chunks no larger than n_batch. The previous
        // implementation decoded the whole prompt in one batch even when the
        // prompt had >512 tokens while n_batch=512, which can trigger ggml_abort
        // inside llama_context::decode instead of returning a Rust error.
        let mut batch = LlamaBatch::new(n_batch, 1);
        for chunk_start in (0..tokens.len()).step_by(n_batch) {
            batch.clear();
            let chunk_end = (chunk_start + n_batch).min(tokens.len());
            for (offset, &token) in tokens[chunk_start..chunk_end].iter().enumerate() {
                let pos = chunk_start + offset;
                let is_last_prompt_token = pos == tokens.len() - 1;
                batch
                    .add(token, pos as i32, &[0], is_last_prompt_token)
                    .map_err(|e| format!("batch add failed: {e}"))?;
            }
            ctx.decode(&mut batch)
                .map_err(|e| format!("prompt decode failed: {e}"))?;
        }

        // Setup sampler
        let seed = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|d| (d.as_nanos() & 0xffff_ffff) as u32)
            .unwrap_or(42);
        let mut sampler = LlamaSampler::chain_simple([
            LlamaSampler::temp(req.temperature),
            LlamaSampler::dist(seed),
        ]);

        // Generate tokens
        let mut output_tokens = Vec::new();
        let mut n_cur = tokens.len() as i32;
        let start_time = std::time::Instant::now();
        // Limit generation to what fits in the context window
        let max_gen = (gen_headroom as usize).min(req.max_tokens as usize);
        let mut stop_reason = "max_tokens".to_string();

        for _ in 0..max_gen {
            let new_token = sampler.sample(&ctx, batch.n_tokens() - 1);

            // Check for EOS
            if model.is_eog_token(new_token) {
                stop_reason = "eos".to_string();
                break;
            }

            // Guard against overflowing the context window
            if (n_cur + 1) as u32 >= n_ctx {
                stop_reason = "context_full".to_string();
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
            .trim_end_matches("<turn|>")
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
