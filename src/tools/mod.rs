//! Tool subsystem for agent-callable capabilities.
//!
//! This module implements the tool execution surface exposed to the LLM during
//! agentic loops. Each tool implements the [`Tool`] trait defined in [`traits`],
//! which requires a name, description, JSON parameter schema, and an async
//! `execute` method returning a structured [`ToolResult`].
//!
//! Tools are assembled into registries by [`default_tools`] (shell, file read/write)
//! and [`all_tools`] (full set including memory, browser, cron, HTTP, delegation,
//! and optional integrations). Security policy enforcement is injected via
//! [`SecurityPolicy`](crate::security::SecurityPolicy) at construction time.
//!
//! # Extension
//!
//! To add a new tool, implement [`Tool`] in a new submodule and register it in
//! [`all_tools_with_runtime`]. See `AGENTS.md` §7.3 for the full change playbook.

pub mod cli_discovery;
pub mod content_search;
pub mod cron_add;
pub mod cron_list;
pub mod cron_remove;
pub mod cron_run;
pub mod cron_runs;
pub mod cron_update;
pub mod file_edit;
pub mod file_read;
pub mod file_write;
pub mod git_operations;
pub mod glob_search;
pub mod memory_forget;
pub mod memory_recall;
pub mod memory_store;
pub mod model_routing_config;
pub mod schedule;
pub mod schema;
pub mod shell;
pub mod traits;
pub mod web_search_tool;
pub mod task_plan;

pub use content_search::ContentSearchTool;
pub use cron_add::CronAddTool;
pub use cron_list::CronListTool;
pub use cron_remove::CronRemoveTool;
pub use cron_run::CronRunTool;
pub use cron_runs::CronRunsTool;
pub use cron_update::CronUpdateTool;
pub use file_edit::FileEditTool;
pub use file_read::FileReadTool;
pub use file_write::FileWriteTool;
pub use git_operations::GitOperationsTool;
pub use glob_search::GlobSearchTool;
pub use memory_forget::MemoryForgetTool;
pub use memory_recall::MemoryRecallTool;
pub use memory_store::MemoryStoreTool;
pub use model_routing_config::ModelRoutingConfigTool;
pub use schedule::ScheduleTool;
#[allow(unused_imports)]
pub use schema::{CleaningStrategy, SchemaCleanr};
pub use shell::ShellTool;
pub use traits::Tool;
#[allow(unused_imports)]
pub use traits::{ToolResult, ToolSpec};
pub use web_search_tool::WebSearchTool;
pub use task_plan::TaskPlanTool;

use crate::config::Config;
use crate::memory::Memory;
use crate::runtime::{NativeRuntime, RuntimeAdapter};
use crate::security::SecurityPolicy;
use async_trait::async_trait;
use std::collections::HashMap;
use std::sync::Arc;

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

fn boxed_registry_from_arcs(tools: Vec<Arc<dyn Tool>>) -> Vec<Box<dyn Tool>> {
    tools.into_iter().map(ArcDelegatingTool::boxed).collect()
}

/// Create the default tool registry
pub fn default_tools(security: Arc<SecurityPolicy>) -> Vec<Box<dyn Tool>> {
    default_tools_with_runtime(security, Arc::new(NativeRuntime::new()))
}

/// Create the default tool registry with explicit runtime adapter.
pub fn default_tools_with_runtime(
    security: Arc<SecurityPolicy>,
    runtime: Arc<dyn RuntimeAdapter>,
) -> Vec<Box<dyn Tool>> {
    vec![
        Box::new(ShellTool::new(security.clone(), runtime)),
        Box::new(FileReadTool::new(security.clone())),
        Box::new(FileWriteTool::new(security.clone())),
        Box::new(FileEditTool::new(security.clone())),
        Box::new(GlobSearchTool::new(security.clone())),
        Box::new(ContentSearchTool::new(security)),
    ]
}

/// Create full tool registry including memory tools and optional Composio
#[allow(clippy::implicit_hasher, clippy::too_many_arguments)]
pub fn all_tools(
    config: Arc<Config>,
    security: &Arc<SecurityPolicy>,
    memory: Arc<dyn Memory>,
    composio_key: Option<&str>,
    composio_entity_id: Option<&str>,
    browser_config: &crate::config::BrowserConfig,
    http_config: &crate::config::HttpRequestConfig,
    web_fetch_config: &crate::config::WebFetchConfig,
    workspace_dir: &std::path::Path,
    agents: &HashMap<String, crate::config::DelegateAgentConfig>,
    fallback_api_key: Option<&str>,
    root_config: &crate::config::Config,
) -> Vec<Box<dyn Tool>> {
    all_tools_with_runtime(
        config,
        security,
        Arc::new(NativeRuntime::new()),
        memory,
        composio_key,
        composio_entity_id,
        browser_config,
        http_config,
        web_fetch_config,
        workspace_dir,
        agents,
        fallback_api_key,
        root_config,
    )
}

/// Create full tool registry including memory tools and optional Composio.
#[allow(clippy::implicit_hasher, clippy::too_many_arguments)]
pub fn all_tools_with_runtime(
    config: Arc<Config>,
    security: &Arc<SecurityPolicy>,
    runtime: Arc<dyn RuntimeAdapter>,
    memory: Arc<dyn Memory>,
    _composio_key: Option<&str>,
    _composio_entity_id: Option<&str>,
    _browser_config: &crate::config::BrowserConfig,
    _http_config: &crate::config::HttpRequestConfig,
    _web_fetch_config: &crate::config::WebFetchConfig,
    workspace_dir: &std::path::Path,
    _agents: &HashMap<String, crate::config::DelegateAgentConfig>,
    _fallback_api_key: Option<&str>,
    root_config: &crate::config::Config,
) -> Vec<Box<dyn Tool>> {
    let mut tool_arcs: Vec<Arc<dyn Tool>> = vec![
        Arc::new(ShellTool::new(security.clone(), runtime)),
        Arc::new(FileReadTool::new(security.clone())),
        Arc::new(FileWriteTool::new(security.clone())),
        Arc::new(FileEditTool::new(security.clone())),
        Arc::new(GlobSearchTool::new(security.clone())),
        Arc::new(ContentSearchTool::new(security.clone())),
        Arc::new(CronAddTool::new(config.clone(), security.clone())),
        Arc::new(CronListTool::new(config.clone())),
        Arc::new(CronRemoveTool::new(config.clone(), security.clone())),
        Arc::new(CronUpdateTool::new(config.clone(), security.clone())),
        Arc::new(CronRunTool::new(config.clone(), security.clone())),
        Arc::new(CronRunsTool::new(config.clone())),
        Arc::new(MemoryStoreTool::new(memory.clone(), security.clone())),
        Arc::new(MemoryRecallTool::new(memory.clone())),
        Arc::new(MemoryForgetTool::new(memory, security.clone())),
        Arc::new(ScheduleTool::new(security.clone(), root_config.clone())),
        Arc::new(ModelRoutingConfigTool::new(
            config.clone(),
            security.clone(),
        )),
        Arc::new(TaskPlanTool::new(security.clone())),
        Arc::new(GitOperationsTool::new(
            security.clone(),
            workspace_dir.to_path_buf(),
        )),
    ];

    // Web search tool (enabled by default for GLM and other models)
    if root_config.web_search.enabled {
        tool_arcs.push(Arc::new(WebSearchTool::new(
            root_config.web_search.provider.clone(),
            root_config.web_search.brave_api_key.clone(),
            root_config.web_search.max_results,
            root_config.web_search.timeout_secs,
        )));
    }

    boxed_registry_from_arcs(tool_arcs)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::config::{BrowserConfig, Config, MemoryConfig};
    use tempfile::TempDir;

    fn test_config(tmp: &TempDir) -> Config {
        Config {
            workspace_dir: tmp.path().join("workspace"),
            config_path: tmp.path().join("config.toml"),
            ..Config::default()
        }
    }

    #[test]
    fn default_tools_has_expected_count() {
        let security = Arc::new(SecurityPolicy::default());
        let tools = default_tools(security);
        assert_eq!(tools.len(), 6);
    }

    #[test]
    fn all_tools_includes_workspace_and_scheduler_tools() {
        let tmp = TempDir::new().unwrap();
        let security = Arc::new(SecurityPolicy::default());
        let mem_cfg = MemoryConfig {
            backend: "markdown".into(),
            ..MemoryConfig::default()
        };
        let mem: Arc<dyn Memory> =
            Arc::from(crate::memory::create_memory(&mem_cfg, tmp.path(), None).unwrap());

        let browser = BrowserConfig {
            enabled: false,
            allowed_domains: vec!["example.com".into()],
            session_name: None,
            ..BrowserConfig::default()
        };
        let http = crate::config::HttpRequestConfig::default();
        let cfg = test_config(&tmp);

        let tools = all_tools(
            Arc::new(Config::default()),
            &security,
            mem,
            None,
            None,
            &browser,
            &http,
            &crate::config::WebFetchConfig::default(),
            tmp.path(),
            &HashMap::new(),
            None,
            &cfg,
        );
        let names: Vec<&str> = tools.iter().map(|t| t.name()).collect();
        assert!(names.contains(&"schedule"));
        assert!(names.contains(&"model_routing_config"));
        assert!(names.contains(&"content_search"));
    }

    #[test]
    fn default_tools_names() {
        let security = Arc::new(SecurityPolicy::default());
        let tools = default_tools(security);
        let names: Vec<&str> = tools.iter().map(|t| t.name()).collect();
        assert!(names.contains(&"shell"));
        assert!(names.contains(&"file_read"));
        assert!(names.contains(&"file_write"));
        assert!(names.contains(&"file_edit"));
        assert!(names.contains(&"glob_search"));
        assert!(names.contains(&"content_search"));
    }

    #[test]
    fn default_tools_all_have_descriptions() {
        let security = Arc::new(SecurityPolicy::default());
        let tools = default_tools(security);
        for tool in &tools {
            assert!(
                !tool.description().is_empty(),
                "Tool {} has empty description",
                tool.name()
            );
        }
    }

    #[test]
    fn default_tools_all_have_schemas() {
        let security = Arc::new(SecurityPolicy::default());
        let tools = default_tools(security);
        for tool in &tools {
            let schema = tool.parameters_schema();
            assert!(
                schema.is_object(),
                "Tool {} schema is not an object",
                tool.name()
            );
            assert!(
                schema["properties"].is_object(),
                "Tool {} schema has no properties",
                tool.name()
            );
        }
    }

    #[test]
    fn tool_spec_generation() {
        let security = Arc::new(SecurityPolicy::default());
        let tools = default_tools(security);
        for tool in &tools {
            let spec = tool.spec();
            assert_eq!(spec.name, tool.name());
            assert_eq!(spec.description, tool.description());
            assert!(spec.parameters.is_object());
        }
    }

    #[test]
    fn tool_result_serde() {
        let result = ToolResult {
            success: true,
            output: "hello".into(),
            error: None,
        };
        let json = serde_json::to_string(&result).unwrap();
        let parsed: ToolResult = serde_json::from_str(&json).unwrap();
        assert!(parsed.success);
        assert_eq!(parsed.output, "hello");
        assert!(parsed.error.is_none());
    }

    #[test]
    fn tool_result_with_error_serde() {
        let result = ToolResult {
            success: false,
            output: String::new(),
            error: Some("boom".into()),
        };
        let json = serde_json::to_string(&result).unwrap();
        let parsed: ToolResult = serde_json::from_str(&json).unwrap();
        assert!(!parsed.success);
        assert_eq!(parsed.error.as_deref(), Some("boom"));
    }

    #[test]
    fn tool_spec_serde() {
        let spec = ToolSpec {
            name: "test".into(),
            description: "A test tool".into(),
            parameters: serde_json::json!({"type": "object"}),
        };
        let json = serde_json::to_string(&spec).unwrap();
        let parsed: ToolSpec = serde_json::from_str(&json).unwrap();
        assert_eq!(parsed.name, "test");
        assert_eq!(parsed.description, "A test tool");
    }

    #[test]
    fn all_tools_omits_removed_integrations() {
        let tmp = TempDir::new().unwrap();
        let security = Arc::new(SecurityPolicy::default());
        let mem_cfg = MemoryConfig {
            backend: "markdown".into(),
            ..MemoryConfig::default()
        };
        let mem: Arc<dyn Memory> =
            Arc::from(crate::memory::create_memory(&mem_cfg, tmp.path(), None).unwrap());

        let browser = BrowserConfig::default();
        let http = crate::config::HttpRequestConfig::default();
        let cfg = test_config(&tmp);

        let tools = all_tools(
            Arc::new(Config::default()),
            &security,
            mem,
            None,
            None,
            &browser,
            &http,
            &crate::config::WebFetchConfig::default(),
            tmp.path(),
            &HashMap::new(),
            None,
            &cfg,
        );
        let names: Vec<&str> = tools.iter().map(|t| t.name()).collect();
        assert!(!names.contains(&"browser_open"));
        assert!(!names.contains(&"browser"));
        assert!(!names.contains(&"http_request"));
        assert!(!names.contains(&"web_fetch"));
        assert!(!names.contains(&"delegate"));
        assert!(!names.contains(&"composio"));
    }
}
