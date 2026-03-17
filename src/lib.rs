#![warn(clippy::all, clippy::pedantic)]
#![allow(
    clippy::assigning_clones,
    clippy::bool_to_int_with_if,
    clippy::case_sensitive_file_extension_comparisons,
    clippy::cast_possible_wrap,
    clippy::doc_markdown,
    clippy::field_reassign_with_default,
    clippy::float_cmp,
    clippy::implicit_clone,
    clippy::items_after_statements,
    clippy::map_unwrap_or,
    clippy::manual_let_else,
    clippy::missing_errors_doc,
    clippy::missing_panics_doc,
    clippy::module_name_repetitions,
    clippy::must_use_candidate,
    clippy::new_without_default,
    clippy::needless_pass_by_value,
    clippy::needless_raw_string_hashes,
    clippy::redundant_closure_for_method_calls,
    clippy::return_self_not_must_use,
    clippy::similar_names,
    clippy::single_match_else,
    clippy::struct_field_names,
    clippy::too_many_lines,
    clippy::uninlined_format_args,
    clippy::unnecessary_cast,
    clippy::unnecessary_lazy_evaluations,
    clippy::unnecessary_literal_bound,
    clippy::unnecessary_map_or,
    clippy::unused_self,
    clippy::cast_precision_loss,
    clippy::unnecessary_wraps,
    dead_code
)]

use clap::Subcommand;
use serde::{Deserialize, Serialize};

pub mod agent;
pub(crate) mod approval;
pub(crate) mod auth;
pub mod channels;
pub mod config;
pub(crate) mod cost;
pub(crate) mod daemon;
pub(crate) mod doctor;
pub mod feed;
pub mod gateway;
pub(crate) mod health;
pub(crate) mod heartbeat;
pub mod hooks;
pub(crate) mod identity;
pub(crate) mod integrations;
pub mod media;
pub mod memory;
pub(crate) mod migration;
pub(crate) mod multimodal;
pub mod observability;
pub(crate) mod onboard;
pub mod providers;
pub mod runtime;
pub(crate) mod security;
pub(crate) mod service;
pub(crate) mod skills;
pub mod tools;
pub(crate) mod util;
pub(crate) mod workflow_assets;

pub use config::Config;

pub async fn has_openai_codex_auth(profile_override: Option<&str>) -> anyhow::Result<bool> {
    let config = Config::load_or_init().await?;
    let auth_service = auth::AuthService::from_config(&config);
    Ok(auth_service
        .get_valid_openai_access_token(profile_override)
        .await?
        .is_some())
}

pub async fn has_anthropic_auth(profile_override: Option<&str>) -> anyhow::Result<bool> {
    let config = Config::load_or_init().await?;
    let auth_service = auth::AuthService::from_config(&config);
    Ok(auth_service
        .get_provider_bearer_token("anthropic", profile_override)
        .await?
        .is_some())
}

pub async fn save_anthropic_token(token: String) -> anyhow::Result<()> {
    let config = Config::load_or_init().await?;
    let auth_service = auth::AuthService::from_config(&config);
    let kind = auth::anthropic_token::detect_auth_kind(&token, None);
    let mut metadata = std::collections::HashMap::new();
    metadata.insert(
        "auth_kind".to_string(),
        kind.as_metadata_value().to_string(),
    );
    auth_service
        .store_provider_token("anthropic", "default", &token, metadata, true)
        .await?;
    Ok(())
}

pub async fn clear_anthropic_token() -> anyhow::Result<()> {
    let config = Config::load_or_init().await?;
    let auth_service = auth::AuthService::from_config(&config);
    auth_service.remove_profile("anthropic", "default").await?;
    Ok(())
}

/// Service management subcommands
#[derive(Subcommand, Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub enum ServiceCommands {
    /// Install daemon service unit for auto-start and restart
    Install,
    /// Start daemon service
    Start,
    /// Stop daemon service
    Stop,
    /// Restart daemon service to apply latest config
    Restart,
    /// Check daemon service status
    Status,
    /// Uninstall daemon service unit
    Uninstall,
}

/// Channel management subcommands
#[derive(Subcommand, Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub enum ChannelCommands {
    /// List all configured channels
    List,
    /// Start all configured channels (handled in main.rs for async)
    Start,
    /// Run health checks for configured channels (handled in main.rs for async)
    Doctor,
    /// Add a new channel configuration
    #[command(long_about = "\
Add a new channel configuration.

Provide the channel type and a JSON object with the required \
configuration keys for that channel type.

Supported types: telegram, discord, slack, whatsapp, matrix, imessage, email.

Examples:
  slowclaw channel add telegram '{\"bot_token\":\"...\",\"name\":\"my-bot\"}'
  slowclaw channel add discord '{\"bot_token\":\"...\",\"name\":\"my-discord\"}'")]
    Add {
        /// Channel type (telegram, discord, slack, whatsapp, matrix, imessage, email)
        channel_type: String,
        /// Optional configuration as JSON
        config: String,
    },
    /// Remove a channel configuration
    Remove {
        /// Channel name to remove
        name: String,
    },
    /// Bind a Telegram identity (username or numeric user ID) into allowlist
    #[command(long_about = "\
Bind a Telegram identity into the allowlist.

Adds a Telegram username (without the '@' prefix) or numeric user \
ID to the channel allowlist so the agent will respond to messages \
from that identity.

Examples:
  slowclaw channel bind-telegram slowclaw_user
  slowclaw channel bind-telegram 123456789")]
    BindTelegram {
        /// Telegram identity to allow (username without '@' or numeric user ID)
        identity: String,
    },
}

/// Skills management subcommands
#[derive(Subcommand, Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub enum SkillCommands {
    /// List all installed skills
    List,
    /// Audit a skill source directory or installed skill name
    Audit {
        /// Skill path or installed skill name
        source: String,
    },
    /// Install a new skill from a URL or local path
    Install {
        /// Source URL or local path
        source: String,
    },
    /// Remove an installed skill
    Remove {
        /// Skill name to remove
        name: String,
    },
}

/// Migration subcommands
#[derive(Subcommand, Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub enum MigrateCommands {
    /// Import memory from an `OpenClaw` workspace into this `SlowClaw` workspace
    Openclaw {
        /// Optional path to `OpenClaw` workspace (defaults to ~/.openclaw/workspace)
        #[arg(long)]
        source: Option<std::path::PathBuf>,

        /// Validate and preview migration without writing any data
        #[arg(long)]
        dry_run: bool,
    },
}

/// Memory management subcommands
#[derive(Subcommand, Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub enum MemoryCommands {
    /// List memory entries with optional filters
    List {
        /// Filter by category (core, daily, conversation, or custom name)
        #[arg(long)]
        category: Option<String>,
        /// Filter by session ID
        #[arg(long)]
        session: Option<String>,
        /// Maximum number of entries to display
        #[arg(long, default_value = "50")]
        limit: usize,
        /// Number of entries to skip (for pagination)
        #[arg(long, default_value = "0")]
        offset: usize,
    },
    /// Get a specific memory entry by key
    Get {
        /// Memory key to look up
        key: String,
    },
    /// Show memory backend statistics and health
    Stats,
    /// Clear memories by category, by key, or clear all
    Clear {
        /// Delete a single entry by key (supports prefix match)
        #[arg(long)]
        key: Option<String>,
        /// Only clear entries in this category
        #[arg(long)]
        category: Option<String>,
        /// Skip confirmation prompt
        #[arg(long)]
        yes: bool,
    },
}

/// Integration subcommands
#[derive(Subcommand, Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
pub enum IntegrationCommands {
    /// Show details about a specific integration
    Info {
        /// Integration name
        name: String,
    },
}

