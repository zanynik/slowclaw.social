use super::{
    CleanAudioTool, ComposeSimpleClipTool, ContentSearchTool, ExtractAudioSegmentTool,
    FileEditTool, FileReadTool, FileWriteTool, GitOperationsTool, GlobSearchTool,
    MemoryForgetTool, MemoryRecallTool, MemoryStoreTool, ModelRoutingConfigTool,
    RenderTextCardVideoTool, ShellTool, StitchImagesWithAudioTool, TaskPlanTool, Tool,
    ToolResult, TranscribeMediaTool, WebSearchTool,
};
use crate::config::Config;
use crate::media::command_media_backend;
use crate::memory::Memory;
use crate::runtime::RuntimeAdapter;
use crate::security::SecurityPolicy;
use async_trait::async_trait;
use std::path::Path;
use std::sync::Arc;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ToolProfile {
    Full,
    UiRestricted,
}

pub(crate) struct ToolRegistryBuilder {
    tools: Vec<Arc<dyn Tool>>,
}

impl ToolRegistryBuilder {
    pub(crate) fn new() -> Self {
        Self { tools: Vec::new() }
    }

    pub(crate) fn with_tool(mut self, tool: Arc<dyn Tool>) -> Self {
        self.tools.push(tool);
        self
    }

    pub(crate) fn build(self, profile: ToolProfile) -> Vec<Box<dyn Tool>> {
        self.tools
            .into_iter()
            .filter(|tool| tool_allowed_in_profile(tool.name(), profile))
            .map(ArcDelegatingTool::boxed)
            .collect()
    }
}

impl Default for ToolRegistryBuilder {
    fn default() -> Self {
        Self::new()
    }
}

pub(crate) fn build_default_tools(
    security: Arc<SecurityPolicy>,
    runtime: Arc<dyn RuntimeAdapter>,
) -> Vec<Box<dyn Tool>> {
    ToolRegistryBuilder::new()
        .with_tool(Arc::new(ShellTool::new(security.clone(), runtime)))
        .with_tool(Arc::new(FileReadTool::new(security.clone())))
        .with_tool(Arc::new(FileWriteTool::new(security.clone())))
        .with_tool(Arc::new(FileEditTool::new(security.clone())))
        .with_tool(Arc::new(GlobSearchTool::new(security.clone())))
        .with_tool(Arc::new(ContentSearchTool::new(security)))
        .build(ToolProfile::Full)
}

pub(crate) struct FullToolRegistryConfig<'a> {
    pub(crate) config: Arc<Config>,
    pub(crate) security: &'a Arc<SecurityPolicy>,
    pub(crate) runtime: Arc<dyn RuntimeAdapter>,
    pub(crate) profile: ToolProfile,
    pub(crate) memory: Arc<dyn Memory>,
    pub(crate) workspace_dir: &'a Path,
    pub(crate) root_config: &'a Config,
}

pub(crate) fn build_full_tools(args: FullToolRegistryConfig<'_>) -> Vec<Box<dyn Tool>> {
    let media_backend = command_media_backend(
        args.config.workspace_dir.clone(),
        args.config.transcription.clone(),
    );
    let media_capabilities = media_backend.capabilities();
    let mut builder = ToolRegistryBuilder::new()
        .with_tool(Arc::new(ShellTool::new(
            args.security.clone(),
            args.runtime,
        )))
        .with_tool(Arc::new(FileReadTool::new(args.security.clone())))
        .with_tool(Arc::new(FileWriteTool::new(args.security.clone())))
        .with_tool(Arc::new(FileEditTool::new(args.security.clone())))
        .with_tool(Arc::new(GlobSearchTool::new(args.security.clone())))
        .with_tool(Arc::new(ContentSearchTool::new(args.security.clone())))
        .with_tool(Arc::new(MemoryStoreTool::new(
            args.memory.clone(),
            args.security.clone(),
        )))
        .with_tool(Arc::new(MemoryRecallTool::new(args.memory.clone())))
        .with_tool(Arc::new(MemoryForgetTool::new(
            args.memory,
            args.security.clone(),
        )))
        .with_tool(Arc::new(ModelRoutingConfigTool::new(
            args.config.clone(),
            args.security.clone(),
        )))
        .with_tool(Arc::new(TaskPlanTool::new(args.security.clone())))
        .with_tool(Arc::new(GitOperationsTool::new(
            args.security.clone(),
            args.workspace_dir.to_path_buf(),
        )));

    if media_capabilities.transcribe_media {
        builder = builder.with_tool(Arc::new(TranscribeMediaTool::new(
            media_backend.clone(),
            args.security.clone(),
        )));
    }
    if media_capabilities.clean_audio {
        builder = builder.with_tool(Arc::new(CleanAudioTool::new(
            media_backend.clone(),
            args.security.clone(),
        )));
    }
    if media_capabilities.extract_audio_segment {
        builder = builder.with_tool(Arc::new(ExtractAudioSegmentTool::new(
            media_backend.clone(),
            args.security.clone(),
        )));
    }
    if media_capabilities.render_text_card_video {
        builder = builder.with_tool(Arc::new(RenderTextCardVideoTool::new(
            media_backend.clone(),
            args.security.clone(),
        )));
    }
    if media_capabilities.stitch_images_with_audio {
        builder = builder.with_tool(Arc::new(StitchImagesWithAudioTool::new(
            media_backend.clone(),
            args.security.clone(),
        )));
    }
    if media_capabilities.compose_simple_clip {
        builder = builder.with_tool(Arc::new(ComposeSimpleClipTool::new(
            media_backend,
            args.security.clone(),
        )));
    }

    if args.root_config.web_search.enabled {
        builder = builder.with_tool(Arc::new(WebSearchTool::new(
            args.root_config.web_search.max_results,
            args.root_config.web_search.timeout_secs,
        )));
    }

    builder.build(args.profile)
}

#[derive(Clone)]
struct ArcDelegatingTool {
    inner: Arc<dyn Tool>,
}

impl ArcDelegatingTool {
    fn boxed(inner: Arc<dyn Tool>) -> Box<dyn Tool> {
        Box::new(Self { inner })
    }
}

#[async_trait]
impl Tool for ArcDelegatingTool {
    fn name(&self) -> &str {
        self.inner.name()
    }

    fn description(&self) -> &str {
        self.inner.description()
    }

    fn parameters_schema(&self) -> serde_json::Value {
        self.inner.parameters_schema()
    }

    async fn execute(&self, args: serde_json::Value) -> anyhow::Result<ToolResult> {
        self.inner.execute(args).await
    }
}

fn tool_allowed_in_profile(name: &str, profile: ToolProfile) -> bool {
    match profile {
        ToolProfile::Full => true,
        ToolProfile::UiRestricted => !matches!(name, "shell" | "git_operations"),
    }
}
