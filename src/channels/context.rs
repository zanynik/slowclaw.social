use crate::cron::DeliveryConfig;
use std::future::Future;

#[derive(Debug, Clone)]
pub struct ChannelExecutionContext {
    pub channel: String,
    pub recipient: String,
    pub thread_ts: Option<String>,
}

impl ChannelExecutionContext {
    pub fn new(
        channel: impl Into<String>,
        recipient: impl Into<String>,
        thread_ts: Option<String>,
    ) -> Self {
        Self {
            channel: channel.into(),
            recipient: recipient.into(),
            thread_ts,
        }
    }
}

tokio::task_local! {
    static CHANNEL_EXECUTION_CONTEXT: ChannelExecutionContext;
}

pub async fn with_channel_execution_context<F>(ctx: ChannelExecutionContext, fut: F) -> F::Output
where
    F: Future,
{
    CHANNEL_EXECUTION_CONTEXT.scope(ctx, fut).await
}

pub fn current_channel_execution_context() -> Option<ChannelExecutionContext> {
    CHANNEL_EXECUTION_CONTEXT.try_with(Clone::clone).ok()
}

/// Default cron delivery for jobs created while handling a channel message.
///
/// This allows generic scheduling tools (`cron_add`, `schedule`) to inherit the
/// originating channel/thread without provider- or reminder-specific patches.
pub fn default_cron_delivery_for_current_channel() -> Option<DeliveryConfig> {
    let ctx = current_channel_execution_context()?;
    let channel = ctx.channel.trim().to_ascii_lowercase();
    let recipient = ctx.recipient.trim();
    if recipient.is_empty() {
        return None;
    }

    match channel.as_str() {
        "pocketbase" => Some(DeliveryConfig {
            mode: "announce".to_string(),
            channel: Some("pocketbase".to_string()),
            to: Some(recipient.to_string()),
            best_effort: true,
        }),
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn no_context_returns_none() {
        assert!(default_cron_delivery_for_current_channel().is_none());
    }

    #[tokio::test]
    async fn pocketbase_context_maps_to_announce_delivery() {
        let ctx = ChannelExecutionContext::new("pocketbase", "thread-123", Some("thread-123".into()));
        let delivery = with_channel_execution_context(ctx, async {
            default_cron_delivery_for_current_channel()
        })
        .await
        .expect("delivery should exist");

        assert_eq!(delivery.mode, "announce");
        assert_eq!(delivery.channel.as_deref(), Some("pocketbase"));
        assert_eq!(delivery.to.as_deref(), Some("thread-123"));
        assert!(delivery.best_effort);
    }
}
