//! Minimal channel subsystem for the workspace-only fork.
//!
//! External channel integrations are disabled. This module keeps the CLI channel,
//! channel traits, prompt builders, and small compatibility stubs required by
//! the gateway/config codepaths so the rest of the application can compile.

pub mod cli;
pub mod context;
pub mod pocketbase;
pub mod traits;

use anyhow::Result;
use async_trait::async_trait;
use schemars::JsonSchema;
use serde::{Deserialize, Serialize};

pub use cli::CliChannel;
pub use context::{
    default_cron_delivery_for_current_channel, with_channel_execution_context,
    ChannelExecutionContext,
};
pub use pocketbase::PocketBaseChannel;
pub use traits::{Channel, SendMessage};

pub mod email_channel {
    use schemars::JsonSchema;
    use serde::{Deserialize, Serialize};

    /// Retained config type for backward-compatible config parsing/masking.
    #[derive(Debug, Clone, Default, Serialize, Deserialize, JsonSchema)]
    pub struct EmailConfig {
        pub imap_host: String,
        #[serde(default = "default_imap_port")]
        pub imap_port: u16,
        #[serde(default = "default_imap_folder")]
        pub imap_folder: String,
        pub smtp_host: String,
        #[serde(default = "default_smtp_port")]
        pub smtp_port: u16,
        #[serde(default = "default_true")]
        pub smtp_tls: bool,
        pub username: String,
        pub password: String,
        pub from_address: String,
        #[serde(default = "default_idle_timeout", alias = "poll_interval_secs")]
        pub idle_timeout_secs: u64,
        #[serde(default)]
        pub allowed_senders: Vec<String>,
    }

    impl crate::config::traits::ChannelConfig for EmailConfig {
        fn name() -> &'static str {
            "Email"
        }
        fn desc() -> &'static str {
            "disabled in this fork"
        }
    }

    fn default_imap_port() -> u16 {
        993
    }
    fn default_smtp_port() -> u16 {
        465
    }
    fn default_imap_folder() -> String {
        "INBOX".into()
    }
    fn default_idle_timeout() -> u64 {
        1740
    }
    fn default_true() -> bool {
        true
    }
}

pub mod clawdtalk {
    use schemars::JsonSchema;
    use serde::{Deserialize, Serialize};

    #[derive(Debug, Clone, Serialize, Deserialize, JsonSchema)]
    pub struct ClawdTalkConfig {
        pub api_key: String,
        pub connection_id: String,
        pub from_number: String,
        #[serde(default)]
        pub allowed_destinations: Vec<String>,
        #[serde(default)]
        pub webhook_secret: Option<String>,
    }

    impl crate::config::traits::ChannelConfig for ClawdTalkConfig {
        fn name() -> &'static str {
            "ClawdTalk"
        }
        fn desc() -> &'static str {
            "disabled in this fork"
        }
    }
}

pub mod linq {
    /// External Linq verification is disabled in this fork.
    pub fn verify_linq_signature(_secret: &str, _body: &str, _timestamp: &str, _signature: &str) -> bool {
        false
    }
}

pub mod nextcloud_talk {
    /// External Nextcloud Talk verification is disabled in this fork.
    pub fn verify_nextcloud_talk_signature(
        _secret: &str,
        _random: &str,
        _body: &str,
        _signature: &str,
    ) -> bool {
        false
    }
}

#[derive(Debug, Clone, Default, Serialize, Deserialize, JsonSchema)]
struct DisabledExternalChannelConfigMarker {
    #[serde(default)]
    _disabled: bool,
}

#[derive(Debug, Clone)]
pub struct WhatsAppChannel {
    verify_token: String,
}

impl WhatsAppChannel {
    pub fn new(
        _access_token: String,
        _phone_number_id: String,
        verify_token: String,
        _allowed_numbers: Vec<String>,
    ) -> Self {
        Self { verify_token }
    }

    pub fn verify_token(&self) -> &str {
        &self.verify_token
    }

    pub fn parse_webhook_payload(
        &self,
        _payload: &serde_json::Value,
    ) -> Vec<crate::channels::traits::ChannelMessage> {
        Vec::new()
    }
}

#[derive(Debug, Clone, Default)]
pub struct LinqChannel;

impl LinqChannel {
    pub fn new(_api_token: String, _from_phone: String, _allowed_senders: Vec<String>) -> Self {
        Self
    }

    pub fn parse_webhook_payload(
        &self,
        _payload: &serde_json::Value,
    ) -> Vec<crate::channels::traits::ChannelMessage> {
        Vec::new()
    }
}

#[derive(Debug, Clone, Default)]
pub struct WatiChannel;

impl WatiChannel {
    pub fn new(
        _api_token: String,
        _api_url: String,
        _tenant_id: Option<String>,
        _allowed_numbers: Vec<String>,
    ) -> Self {
        Self
    }

    pub fn parse_webhook_payload(
        &self,
        _payload: &serde_json::Value,
    ) -> Vec<crate::channels::traits::ChannelMessage> {
        Vec::new()
    }
}

#[derive(Debug, Clone, Default)]
pub struct NextcloudTalkChannel;

impl NextcloudTalkChannel {
    pub fn new(_base_url: String, _app_token: String, _allowed_users: Vec<String>) -> Self {
        Self
    }

    pub fn parse_webhook_payload(
        &self,
        _payload: &serde_json::Value,
    ) -> Vec<crate::channels::traits::ChannelMessage> {
        Vec::new()
    }
}

macro_rules! impl_disabled_channel {
    ($ty:ty, $name:literal) => {
        #[async_trait]
        impl Channel for $ty {
            fn name(&self) -> &str {
                $name
            }

            async fn send(&self, _message: &SendMessage) -> anyhow::Result<()> {
                anyhow::bail!(concat!($name, " channel integration is disabled in this fork"))
            }

            async fn listen(
                &self,
                _tx: tokio::sync::mpsc::Sender<crate::channels::traits::ChannelMessage>,
            ) -> anyhow::Result<()> {
                Ok(())
            }

            async fn health_check(&self) -> bool {
                false
            }
        }
    };
}

impl_disabled_channel!(WhatsAppChannel, "whatsapp");
impl_disabled_channel!(LinqChannel, "linq");
impl_disabled_channel!(WatiChannel, "wati");
impl_disabled_channel!(NextcloudTalkChannel, "nextcloud-talk");

pub(crate) async fn handle_command(command: crate::ChannelCommands, _config: &crate::config::Config) -> Result<()> {
    match command {
        crate::ChannelCommands::Start => {
            anyhow::bail!("Channel runtime is disabled in this fork")
        }
        crate::ChannelCommands::Doctor => {
            anyhow::bail!("Channel doctor is disabled in this fork")
        }
        crate::ChannelCommands::List => {
            println!("Channels:");
            println!("  ✅ CLI (always available)");
            println!("  ✅ PocketBase (internal app channel via gateway/PocketBase)");
            println!("  🚫 Other external channel integrations are disabled in this fork.");
            println!("  ✅ Cron/script scheduling remains available.");
            Ok(())
        }
        crate::ChannelCommands::Add { channel_type, .. } => {
            anyhow::bail!("External channel integrations are disabled in this fork ({channel_type})")
        }
        crate::ChannelCommands::Remove { name } => {
            anyhow::bail!("External channel integrations are disabled in this fork ({name})")
        }
        crate::ChannelCommands::BindTelegram { .. } => {
            anyhow::bail!("Telegram integration is disabled in this fork")
        }
    }
}

pub async fn doctor_channels(_config: crate::config::Config) -> Result<()> {
    println!("Channel doctor is disabled: external channel integrations were removed in this fork.");
    println!("Use `slowclaw cron ...` and PocketBase delivery instead.");
    Ok(())
}

pub async fn start_channels(_config: crate::config::Config) -> Result<()> {
    crate::health::mark_component_ok("channels");
    println!("Channel runtime is disabled for external providers in this fork.");
    println!("PocketBase chat runs via the gateway-integrated PocketBase channel worker.");
    Ok(())
}

pub fn build_system_prompt(
    workspace_dir: &std::path::Path,
    model_name: &str,
    tools: &[(&str, &str)],
    skills: &[crate::skills::Skill],
    identity_config: Option<&crate::config::IdentityConfig>,
    bootstrap_max_chars: Option<usize>,
) -> String {
    build_system_prompt_with_mode(
        workspace_dir,
        model_name,
        tools,
        skills,
        identity_config,
        bootstrap_max_chars,
        false,
        crate::config::SkillsPromptInjectionMode::Compact,
    )
}

#[allow(clippy::too_many_arguments)]
pub fn build_system_prompt_with_mode(
    workspace_dir: &std::path::Path,
    model_name: &str,
    tools: &[(&str, &str)],
    _skills: &[crate::skills::Skill],
    _identity_config: Option<&crate::config::IdentityConfig>,
    _bootstrap_max_chars: Option<usize>,
    _native_tools: bool,
    _skills_prompt_mode: crate::config::SkillsPromptInjectionMode,
) -> String {
    use std::fmt::Write;

    let mut prompt = String::new();
    let _ = writeln!(prompt, "You are SlowClaw running in a workspace-only fork.");
    let _ = writeln!(prompt, "Current workspace: {}", workspace_dir.display());
    let _ = writeln!(prompt, "Model: {model_name}");
    prompt.push_str("External messaging channels are disabled except the internal PocketBase app channel.\\n");
    prompt.push_str("Prefer workspace-local tools and scheduled tasks.\\n\\n");

    if !tools.is_empty() {
        prompt.push_str("## Tools\\n");
        for (name, desc) in tools {
            let _ = writeln!(prompt, "- {name}: {desc}");
        }
    }

    prompt
}
