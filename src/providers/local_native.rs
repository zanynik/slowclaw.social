//! SlowClaw native local inference provider.
//!
//! This provider is the stable Rust-side contract for on-device inference.
//! The first implementation intentionally fails fast until the mobile
//! llama.cpp/TurboQuant engine is linked, so journaling AI paths can select the
//! local provider without silently falling back to a remote model.

use crate::providers::traits::{
    ChatMessage, ChatRequest, ChatResponse, Provider, StreamChunk, StreamOptions, StreamResult,
};
use async_trait::async_trait;
use futures_util::{stream, StreamExt};
use std::path::PathBuf;

pub const ENV_NATIVE_MODEL_ID: &str = "SLOWCLAW_NATIVE_MODEL_ID";
pub const ENV_NATIVE_MODEL_PATH: &str = "SLOWCLAW_NATIVE_MODEL_PATH";

const ENGINE_UNAVAILABLE_MESSAGE: &str = "SlowClaw local AI is selected, but the native iOS inference engine is not bundled yet. Download/select is wired; the next slice must link the llama.cpp/TurboQuant XCFramework behind this provider.";

#[derive(Debug, Clone, Default)]
struct NativeEngineConfig {
    model_id: Option<String>,
    model_path: Option<PathBuf>,
}

impl NativeEngineConfig {
    fn from_env() -> Self {
        Self {
            model_id: std::env::var(ENV_NATIVE_MODEL_ID)
                .ok()
                .map(|value| value.trim().to_string())
                .filter(|value| !value.is_empty()),
            model_path: std::env::var(ENV_NATIVE_MODEL_PATH)
                .ok()
                .map(|value| PathBuf::from(value.trim()))
                .filter(|path| !path.as_os_str().is_empty()),
        }
    }

    fn describe(&self) -> String {
        let mut details = Vec::new();
        if let Some(model_id) = self.model_id.as_deref() {
            details.push(format!("model={model_id}"));
        }
        if let Some(model_path) = self.model_path.as_ref() {
            details.push(format!("path={}", model_path.display()));
        }
        if details.is_empty() {
            "no model has been configured for the native engine".to_string()
        } else {
            details.join(" ")
        }
    }
}

fn native_engine_unavailable(config: &NativeEngineConfig) -> anyhow::Error {
    if let Some(model_path) = config.model_path.as_ref() {
        if !model_path.is_file() {
            return anyhow::anyhow!(
                "SlowClaw local AI model file is missing ({}). Re-download the model before running local AI.",
                model_path.display()
            );
        }
    }

    anyhow::anyhow!("{ENGINE_UNAVAILABLE_MESSAGE} ({})", config.describe())
}

fn infer_text(config: &NativeEngineConfig, _prompt: &str) -> anyhow::Result<String> {
    Err(native_engine_unavailable(config))
}

#[derive(Debug, Default)]
pub struct LocalNativeProvider {
    config: NativeEngineConfig,
}

impl LocalNativeProvider {
    #[must_use]
    pub fn new() -> Self {
        Self {
            config: NativeEngineConfig::from_env(),
        }
    }

    fn unavailable_error(&self) -> anyhow::Error {
        native_engine_unavailable(&self.config)
    }
}

#[async_trait]
impl Provider for LocalNativeProvider {
    async fn chat_with_system(
        &self,
        _system_prompt: Option<&str>,
        message: &str,
        _model: &str,
        _temperature: f64,
    ) -> anyhow::Result<String> {
        infer_text(&self.config, message)
    }

    async fn chat(
        &self,
        _request: ChatRequest<'_>,
        _model: &str,
        _temperature: f64,
    ) -> anyhow::Result<ChatResponse> {
        Err(self.unavailable_error())
    }

    async fn chat_with_tools(
        &self,
        _messages: &[ChatMessage],
        _tools: &[serde_json::Value],
        _model: &str,
        _temperature: f64,
    ) -> anyhow::Result<ChatResponse> {
        Err(self.unavailable_error())
    }

    fn supports_streaming(&self) -> bool {
        true
    }

    fn stream_chat_with_history(
        &self,
        _messages: &[ChatMessage],
        _model: &str,
        _temperature: f64,
        _options: StreamOptions,
    ) -> stream::BoxStream<'static, StreamResult<StreamChunk>> {
        let message = self.unavailable_error().to_string();
        stream::once(async move { Ok(StreamChunk::error(message)) }).boxed()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::{Mutex, OnceLock};

    fn env_lock() -> &'static Mutex<()> {
        static LOCK: OnceLock<Mutex<()>> = OnceLock::new();
        LOCK.get_or_init(|| Mutex::new(()))
    }

    #[test]
    fn native_engine_config_reads_selected_model_from_env() {
        let _guard = env_lock().lock().unwrap();
        let original_model = std::env::var(ENV_NATIVE_MODEL_ID).ok();
        let original_path = std::env::var(ENV_NATIVE_MODEL_PATH).ok();
        std::env::set_var(ENV_NATIVE_MODEL_ID, "gemma-test");
        std::env::set_var(ENV_NATIVE_MODEL_PATH, "/tmp/gemma-test.gguf");

        let config = NativeEngineConfig::from_env();
        assert_eq!(config.model_id.as_deref(), Some("gemma-test"));
        assert_eq!(
            config.model_path.as_ref().map(|path| path.display().to_string()),
            Some("/tmp/gemma-test.gguf".to_string())
        );

        match original_model {
            Some(value) => std::env::set_var(ENV_NATIVE_MODEL_ID, value),
            None => std::env::remove_var(ENV_NATIVE_MODEL_ID),
        }
        match original_path {
            Some(value) => std::env::set_var(ENV_NATIVE_MODEL_PATH, value),
            None => std::env::remove_var(ENV_NATIVE_MODEL_PATH),
        }
    }
}
