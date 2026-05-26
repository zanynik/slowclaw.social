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

const ENGINE_UNAVAILABLE_MESSAGE: &str = "SlowClaw local AI is selected, but the native iOS inference engine is not bundled yet. Download/select is wired; the next slice must link the llama.cpp/TurboQuant XCFramework and implement this provider.";

#[derive(Debug, Default)]
pub struct LocalNativeProvider;

impl LocalNativeProvider {
    #[must_use]
    pub fn new() -> Self {
        Self
    }
}

#[async_trait]
impl Provider for LocalNativeProvider {
    async fn chat_with_system(
        &self,
        _system_prompt: Option<&str>,
        _message: &str,
        _model: &str,
        _temperature: f64,
    ) -> anyhow::Result<String> {
        anyhow::bail!(ENGINE_UNAVAILABLE_MESSAGE)
    }

    async fn chat(
        &self,
        _request: ChatRequest<'_>,
        _model: &str,
        _temperature: f64,
    ) -> anyhow::Result<ChatResponse> {
        anyhow::bail!(ENGINE_UNAVAILABLE_MESSAGE)
    }

    async fn chat_with_tools(
        &self,
        _messages: &[ChatMessage],
        _tools: &[serde_json::Value],
        _model: &str,
        _temperature: f64,
    ) -> anyhow::Result<ChatResponse> {
        anyhow::bail!(ENGINE_UNAVAILABLE_MESSAGE)
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
        stream::once(async { Ok(StreamChunk::error(ENGINE_UNAVAILABLE_MESSAGE)) }).boxed()
    }
}
