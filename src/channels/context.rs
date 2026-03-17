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

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn channel_context_roundtrips() {
        let ctx = ChannelExecutionContext::new("pocketbase", "thread-123", Some("thread-123".into()));
        let retrieved = with_channel_execution_context(ctx, async {
            current_channel_execution_context()
        })
        .await
        .expect("context should exist");

        assert_eq!(retrieved.channel, "pocketbase");
        assert_eq!(retrieved.recipient, "thread-123");
    }
}
