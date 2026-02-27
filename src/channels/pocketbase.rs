use crate::channels::traits::{Channel, ChannelMessage, SendMessage};
use anyhow::{Context, Result};
use async_trait::async_trait;
use chrono::Utc;
use serde::Deserialize;
use std::time::Duration;

const DEFAULT_CHAT_COLLECTION: &str = "chat_messages";
const DEFAULT_POLL_MS: u64 = 1_500;
const FETCH_PAGE_SIZE: usize = 30;
const MAX_FETCH_PAGES: usize = 5;

#[derive(Clone)]
pub struct PocketBaseChannel {
    client: reqwest::Client,
    base_url: String,
    collection: String,
    token: Option<String>,
    poll_ms: u64,
}

impl PocketBaseChannel {
    pub fn new(base_url: String, collection: String, token: Option<String>) -> Result<Self> {
        let base_url = base_url.trim().trim_end_matches('/').to_string();
        if base_url.is_empty() {
            anyhow::bail!("PocketBase base URL is empty");
        }
        let collection = collection.trim().to_string();
        if collection.is_empty() {
            anyhow::bail!("PocketBase collection is empty");
        }
        Ok(Self {
            client: reqwest::Client::new(),
            base_url,
            collection,
            token: token
                .map(|v| v.trim().to_string())
                .filter(|v| !v.is_empty()),
            poll_ms: std::env::var("ZEROCLAW_POCKETBASE_CHAT_POLL_MS")
                .ok()
                .and_then(|v| v.trim().parse::<u64>().ok())
                .filter(|v| *v >= 250)
                .unwrap_or(DEFAULT_POLL_MS),
        })
    }

    pub fn from_env_defaults() -> Result<Self> {
        let base_url = std::env::var("ZEROCLAW_POCKETBASE_URL")
            .or_else(|_| std::env::var("POCKETBASE_URL"))
            .unwrap_or_else(|_| {
                let host = std::env::var("ZEROCLAW_POCKETBASE_HOST")
                    .ok()
                    .map(|v| v.trim().to_string())
                    .filter(|v| !v.is_empty())
                    .unwrap_or_else(|| "127.0.0.1".to_string());
                let port = std::env::var("ZEROCLAW_POCKETBASE_PORT")
                    .ok()
                    .and_then(|v| v.trim().parse::<u16>().ok())
                    .unwrap_or(8090);
                format!("http://{host}:{port}")
            });
        let collection = std::env::var("ZEROCLAW_POCKETBASE_CHAT_COLLECTION")
            .ok()
            .unwrap_or_else(|| DEFAULT_CHAT_COLLECTION.to_string());
        let token = std::env::var("ZEROCLAW_POCKETBASE_TOKEN")
            .ok()
            .or_else(|| std::env::var("POCKETBASE_TOKEN").ok());

        Self::new(base_url, collection, token)
    }

    pub fn base_url(&self) -> &str {
        &self.base_url
    }

    pub fn collection(&self) -> &str {
        &self.collection
    }

    async fn create_chat_record(
        &self,
        thread_id: &str,
        role: &str,
        content: &str,
        status: &str,
        source: &str,
        reply_to_id: Option<&str>,
        error: Option<&str>,
    ) -> Result<()> {
        let now = Utc::now().to_rfc3339();
        let mut payload = serde_json::json!({
            "threadId": thread_id,
            "role": role,
            "content": content,
            "status": status,
            "source": source,
            "createdAtClient": now.clone(),
            "processedAt": now,
        });
        if let Some(reply_to_id) = reply_to_id {
            payload["replyToId"] = serde_json::Value::String(reply_to_id.to_string());
        }
        if let Some(error_text) = error {
            payload["error"] = serde_json::Value::String(error_text.to_string());
        }
        let url = format!(
            "{}/api/collections/{}/records",
            self.base_url,
            self.collection
        );
        let mut req = self.client.post(url).json(&payload);
        if let Some(token) = self.token.as_deref() {
            req = req.bearer_auth(token);
        }
        let resp = req.send().await.context("PocketBase channel send request failed")?;
        let status = resp.status();
        if !status.is_success() {
            let body = resp.text().await.unwrap_or_default();
            anyhow::bail!("PocketBase channel send failed ({status}): {}", body.trim());
        }
        Ok(())
    }

    async fn patch_record_status(
        &self,
        record_id: &str,
        status_value: &str,
        error: Option<&str>,
    ) -> Result<()> {
        let url = format!(
            "{}/api/collections/{}/records/{}",
            self.base_url, self.collection, record_id
        );
        let mut payload = serde_json::json!({
            "status": status_value,
            "processedAt": Utc::now().to_rfc3339(),
        });
        if let Some(error) = error {
            payload["error"] = serde_json::Value::String(error.to_string());
        } else {
            payload["error"] = serde_json::Value::String(String::new());
        }
        let mut req = self.client.patch(url).json(&payload);
        if let Some(token) = self.token.as_deref() {
            req = req.bearer_auth(token);
        }
        let resp = req
            .send()
            .await
            .context("PocketBase channel patch request failed")?;
        let status = resp.status();
        if !status.is_success() {
            let body = resp.text().await.unwrap_or_default();
            anyhow::bail!("PocketBase channel patch failed ({status}): {}", body.trim());
        }
        Ok(())
    }

    async fn fetch_pending_user_messages(&self) -> Result<Vec<PocketBaseChatRecord>> {
        let url = format!("{}/api/collections/{}/records", self.base_url, self.collection);
        let per_page = FETCH_PAGE_SIZE.to_string();
        let mut pending = Vec::new();

        for page in 1..=MAX_FETCH_PAGES {
            let page_str = page.to_string();
            let mut req = self.client.get(&url).query(&[
                ("page", page_str.as_str()),
                ("perPage", per_page.as_str()),
            ]);
            if let Some(token) = self.token.as_deref() {
                req = req.bearer_auth(token);
            }

            let resp = req
                .send()
                .await
                .context("PocketBase channel poll request failed")?;
            let status = resp.status();
            if !status.is_success() {
                let body = resp.text().await.unwrap_or_default();
                anyhow::bail!(
                    "PocketBase channel poll failed ({status}) for collection '{}': {}",
                    self.collection,
                    body.trim()
                );
            }
            let list = resp
                .json::<PocketBaseList<PocketBaseChatRecord>>()
                .await
                .context("PocketBase channel poll decode failed")?;
            let count = list.items.len();
            pending.extend(list.items.into_iter().filter(|r| {
                r.role
                    .as_deref()
                    .is_some_and(|role| role.eq_ignore_ascii_case("user"))
                    && r.status
                        .as_deref()
                        .is_some_and(|status| status.eq_ignore_ascii_case("pending"))
            }));
            if count < FETCH_PAGE_SIZE {
                break;
            }
        }

        Ok(pending)
    }
}

#[async_trait]
impl Channel for PocketBaseChannel {
    fn name(&self) -> &str {
        "pocketbase"
    }

    async fn send(&self, message: &SendMessage) -> anyhow::Result<()> {
        let thread_id = message.recipient.trim();
        if thread_id.is_empty() {
            anyhow::bail!("PocketBase channel recipient (threadId) is required");
        }
        self.create_chat_record(
            thread_id,
            "assistant",
            message.content.trim(),
            "done",
            "slowclaw-channel",
            message.thread_ts.as_deref(),
            None,
        )
        .await
    }

    async fn listen(&self, tx: tokio::sync::mpsc::Sender<ChannelMessage>) -> anyhow::Result<()> {
        let mut interval = tokio::time::interval(Duration::from_millis(self.poll_ms));
        interval.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);

        loop {
            interval.tick().await;
            let records = self.fetch_pending_user_messages().await?;
            for record in records {
                let thread_id = record
                    .thread_id
                    .as_deref()
                    .map(str::trim)
                    .filter(|v| !v.is_empty())
                    .unwrap_or("default")
                    .to_string();
                let content = record.content.unwrap_or_default();
                if content.trim().is_empty() {
                    let _ = self
                        .patch_record_status(&record.id, "error", Some("Empty message"))
                        .await;
                    continue;
                }

                self.patch_record_status(&record.id, "processing", None).await?;
                let msg = ChannelMessage {
                    id: record.id.clone(),
                    sender: record
                        .sender
                        .clone()
                        .unwrap_or_else(|| "pocketbase-user".to_string()),
                    reply_target: thread_id.clone(),
                    content,
                    channel: "pocketbase".to_string(),
                    timestamp: Utc::now().timestamp().max(0) as u64,
                    // For PocketBase, `reply_target` is the thread; keep thread_ts aligned.
                    thread_ts: Some(thread_id),
                };
                tx.send(msg)
                    .await
                    .map_err(|e| anyhow::anyhow!("PocketBase channel listener send failed: {e}"))?;
            }
        }
    }

    async fn health_check(&self) -> bool {
        let url = format!("{}/api/health", self.base_url);
        let mut req = self.client.get(url);
        if let Some(token) = self.token.as_deref() {
            req = req.bearer_auth(token);
        }
        req.send()
            .await
            .map(|resp| resp.status().is_success())
            .unwrap_or(false)
    }
}

#[derive(Debug, Deserialize)]
struct PocketBaseList<T> {
    items: Vec<T>,
}

#[derive(Debug, Deserialize)]
struct PocketBaseChatRecord {
    id: String,
    #[serde(rename = "threadId")]
    thread_id: Option<String>,
    role: Option<String>,
    content: Option<String>,
    status: Option<String>,
    #[serde(rename = "source")]
    sender: Option<String>,
}
