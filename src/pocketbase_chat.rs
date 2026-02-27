use crate::config::Config;
use crate::memory::traits::{Memory, MemoryCategory};
use anyhow::{Context, Result};
use chrono::{Duration as ChronoDuration, Utc};
use serde::Deserialize;
use std::sync::Arc;
use std::time::Duration;
use uuid::Uuid;

const DEFAULT_CHAT_COLLECTION: &str = "chat_messages";
const DEFAULT_POLL_MS: u64 = 1_500;
const MAX_PENDING_PER_POLL: usize = 8;
const FETCH_PAGE_SIZE: usize = 30;
const MAX_FETCH_PAGES: usize = 5;

pub struct PocketBaseChatWorkerHandle {
    join: tokio::task::JoinHandle<()>,
    pub base_url: String,
    pub collection: String,
}

impl PocketBaseChatWorkerHandle {
    pub fn abort(&self) {
        self.join.abort();
    }
}

pub fn maybe_spawn_gateway_worker(
    config: Config,
    sidecar_url: Option<String>,
) -> Option<PocketBaseChatWorkerHandle> {
    if env_flag("ZEROCLAW_POCKETBASE_CHAT_DISABLE") {
        return None;
    }

    let base_url = resolve_base_url(sidecar_url)?;
    let collection = std::env::var("ZEROCLAW_POCKETBASE_CHAT_COLLECTION")
        .ok()
        .map(|v| v.trim().to_string())
        .filter(|v| !v.is_empty())
        .unwrap_or_else(|| DEFAULT_CHAT_COLLECTION.to_string());
    let poll_ms = std::env::var("ZEROCLAW_POCKETBASE_CHAT_POLL_MS")
        .ok()
        .and_then(|v| v.trim().parse::<u64>().ok())
        .filter(|v| *v >= 250)
        .unwrap_or(DEFAULT_POLL_MS);
    let token = pocketbase_token();
    let auto_save = config.memory.auto_save;
    let mem: Option<Arc<dyn Memory>> = if auto_save {
        match crate::memory::create_memory_with_storage(
            &config.memory,
            Some(&config.storage.provider.config),
            &config.workspace_dir,
            config.api_key.as_deref(),
        ) {
            Ok(m) => Some(Arc::from(m)),
            Err(err) => {
                tracing::warn!("PocketBase chat memory init failed; continuing without memory autosave: {err:#}");
                None
            }
        }
    } else {
        None
    };

    let join = tokio::spawn(run_worker_loop(WorkerCtx {
        client: reqwest::Client::new(),
        config,
        base_url: base_url.clone(),
        collection: collection.clone(),
        token,
        poll_ms,
        auto_save,
        mem,
    }));

    Some(PocketBaseChatWorkerHandle {
        join,
        base_url,
        collection,
    })
}

#[derive(Clone)]
struct WorkerCtx {
    client: reqwest::Client,
    config: Config,
    base_url: String,
    collection: String,
    token: Option<String>,
    poll_ms: u64,
    auto_save: bool,
    mem: Option<Arc<dyn Memory>>,
}

#[derive(Debug, Deserialize)]
struct PocketBaseList<T> {
    items: Vec<T>,
}

#[derive(Debug, Deserialize)]
struct ChatRecord {
    id: String,
    #[serde(rename = "threadId")]
    thread_id: Option<String>,
    role: Option<String>,
    content: Option<String>,
    status: Option<String>,
}

async fn run_worker_loop(ctx: WorkerCtx) {
    let mut interval = tokio::time::interval(Duration::from_millis(ctx.poll_ms));
    interval.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);

    loop {
        interval.tick().await;
        if let Err(err) = poll_once(&ctx).await {
            tracing::warn!("PocketBase chat worker poll failed: {err}");
        }
    }
}

async fn poll_once(ctx: &WorkerCtx) -> Result<()> {
    let pending = fetch_pending_messages(ctx).await?;
    if pending.is_empty() {
        return Ok(());
    }

    for record in pending {
        // Best-effort claim. In a single gateway instance this is sufficient.
        patch_record(
            ctx,
            &record.id,
            serde_json::json!({
                "status": "processing",
                "error": "",
            }),
        )
        .await?;

        let thread_id = record
            .thread_id
            .as_deref()
            .map(str::trim)
            .filter(|v| !v.is_empty())
            .unwrap_or("default")
            .to_string();
        let content = record.content.unwrap_or_default();
        if content.trim().is_empty() {
            patch_record(
                ctx,
                &record.id,
                serde_json::json!({
                    "status": "error",
                    "error": "Empty message",
                    "processedAt": Utc::now().to_rfc3339(),
                }),
            )
            .await?;
            continue;
        }

        if ctx.auto_save {
            let _ = store_chat_memory(
                ctx,
                &thread_id,
                "user",
                &content,
            )
            .await;
        }

        if let Some(reminder) = parse_reminder_intent(&content) {
            let now = Utc::now().to_rfc3339();
            match schedule_pocketbase_chat_reminder(ctx, &thread_id, &reminder).await {
                Ok((job_id, run_at)) => {
                    let reply = format!(
                        "Scheduled reminder for this chat at {run_at} ({}) [job {}]. Note: reminders run from the scheduler, so start `slowclaw daemon` (not only `slowclaw gateway`).",
                        reminder.delay_human, job_id
                    );
                    if ctx.auto_save {
                        let _ = store_chat_memory(ctx, &thread_id, "assistant", &reply).await;
                    }
                    create_record(
                        ctx,
                        serde_json::json!({
                            "threadId": thread_id,
                            "role": "assistant",
                            "content": reply,
                            "status": "done",
                            "source": "slowclaw-reminder",
                            "replyToId": record.id.clone(),
                            "createdAtClient": now.clone(),
                            "processedAt": now.clone(),
                        }),
                    )
                    .await?;
                    patch_record(
                        ctx,
                        &record.id,
                        serde_json::json!({
                            "status": "done",
                            "processedAt": now,
                        }),
                    )
                    .await?;
                }
                Err(err) => {
                    let error_text = crate::util::truncate_with_ellipsis(&format!("{err:#}"), 2000);
                    let _ = create_record(
                        ctx,
                        serde_json::json!({
                            "threadId": thread_id,
                            "role": "assistant",
                            "content": "",
                            "status": "error",
                            "source": "slowclaw-reminder",
                            "replyToId": record.id.clone(),
                            "error": error_text.clone(),
                            "createdAtClient": now.clone(),
                            "processedAt": now.clone(),
                        }),
                    )
                    .await;
                    patch_record(
                        ctx,
                        &record.id,
                        serde_json::json!({
                            "status": "error",
                            "error": error_text,
                            "processedAt": now,
                        }),
                    )
                    .await?;
                }
            }
            continue;
        }

        let channel_ctx = crate::channels::ChannelExecutionContext::new(
            "pocketbase",
            thread_id.clone(),
            Some(thread_id.clone()),
        );
        match crate::channels::with_channel_execution_context(
            channel_ctx,
            crate::agent::process_message(ctx.config.clone(), &content),
        )
        .await
        {
            Ok(reply) => {
                let now = Utc::now().to_rfc3339();
                if ctx.auto_save {
                    let _ = store_chat_memory(ctx, &thread_id, "assistant", reply.trim()).await;
                }
                create_record(
                    ctx,
                    serde_json::json!({
                        "threadId": thread_id,
                        "role": "assistant",
                        "content": if reply.trim().is_empty() { "(empty response)" } else { reply.trim() },
                        "status": "done",
                        "source": "slowclaw",
                        "replyToId": record.id.clone(),
                        "createdAtClient": now.clone(),
                        "processedAt": now.clone(),
                    }),
                )
                .await?;
                patch_record(
                    ctx,
                    &record.id,
                    serde_json::json!({
                        "status": "done",
                        "processedAt": now.clone(),
                    }),
                )
                .await?;
            }
            Err(err) => {
                let now = Utc::now().to_rfc3339();
                let error_text = crate::util::truncate_with_ellipsis(&format!("{err:#}"), 2000);
                let _ = create_record(
                    ctx,
                    serde_json::json!({
                        "threadId": thread_id,
                        "role": "assistant",
                        "content": "",
                        "status": "error",
                        "source": "slowclaw",
                        "replyToId": record.id.clone(),
                        "error": error_text.clone(),
                        "createdAtClient": now.clone(),
                        "processedAt": now.clone(),
                    }),
                )
                .await;
                patch_record(
                    ctx,
                    &record.id,
                    serde_json::json!({
                        "status": "error",
                        "error": error_text.clone(),
                        "processedAt": now.clone(),
                    }),
                )
                .await?;
            }
        }
    }

    Ok(())
}

#[derive(Debug, Clone)]
struct ReminderIntent {
    message: String,
    delay: ChronoDuration,
    delay_human: String,
}

async fn schedule_pocketbase_chat_reminder(
    ctx: &WorkerCtx,
    thread_id: &str,
    reminder: &ReminderIntent,
) -> Result<(String, String)> {
    let run_at = Utc::now() + reminder.delay;
    let output_text = format!("Reminder: {}", reminder.message.trim());
    let command = format!("echo {}", shell_single_quote(&output_text));

    let created = crate::cron::add_once_at(&ctx.config, run_at, &command)?;
    let patched = crate::cron::update_job(
        &ctx.config,
        &created.id,
        crate::cron::CronJobPatch {
            name: Some(format!(
                "PB chat reminder: {}",
                crate::util::truncate_with_ellipsis(&reminder.message, 48)
            )),
            delivery: Some(crate::cron::DeliveryConfig {
                mode: "announce".to_string(),
                channel: Some("pocketbase".to_string()),
                to: Some(thread_id.to_string()),
                best_effort: true,
            }),
            ..crate::cron::CronJobPatch::default()
        },
    )?;

    Ok((patched.id, patched.next_run.to_rfc3339()))
}

fn shell_single_quote(text: &str) -> String {
    format!("'{}'", text.replace('\'', "'\"'\"'"))
}

fn parse_reminder_intent(input: &str) -> Option<ReminderIntent> {
    parse_slash_reminder_intent(input)
        .or_else(|| parse_natural_language_reminder_intent(input))
        .or_else(|| parse_set_reminder_intent(input))
}

fn parse_slash_reminder_intent(input: &str) -> Option<ReminderIntent> {
    let trimmed = input.trim();
    let lower = trimmed.to_ascii_lowercase();
    if !lower.starts_with("/remind ") {
        return None;
    }
    let rest = trimmed[8..].trim();
    let (delay, delay_human, remainder) = parse_leading_delay(rest)?;
    let message = normalize_reminder_message(remainder);
    if message.is_empty() {
        return None;
    }
    Some(ReminderIntent {
        message,
        delay,
        delay_human,
    })
}

fn parse_natural_language_reminder_intent(input: &str) -> Option<ReminderIntent> {
    let trimmed = input.trim();
    let lower = trimmed.to_ascii_lowercase();
    let remind_pos = lower.find("remind me")?;
    let remind_phrase_end = remind_pos + "remind me".len();
    if remind_phrase_end > trimmed.len() {
        return None;
    }
    let remind_tail = trimmed[remind_phrase_end..].trim();

    // Use the last " in " to support phrases like "remind me about X in 5 min".
    let in_pos = lower.rfind(" in ")?;
    let head = trimmed[..in_pos].trim();
    let tail = trimmed[in_pos + 4..].trim();
    let (delay, delay_human, tail_after_delay) = parse_leading_delay(tail)?;

    let mut message = if head.len() >= remind_phrase_end {
        normalize_reminder_message(&head[remind_phrase_end..])
    } else {
        normalize_reminder_message(remind_tail)
    };

    if message.is_empty() {
        message = normalize_reminder_message(tail_after_delay);
    }

    if message.is_empty() {
        return None;
    }

    Some(ReminderIntent {
        message,
        delay,
        delay_human,
    })
}

fn parse_set_reminder_intent(input: &str) -> Option<ReminderIntent> {
    let trimmed = input.trim();
    let lower = trimmed.to_ascii_lowercase();
    if !lower.contains("reminder") {
        return None;
    }
    let in_pos = lower.rfind(" in ")?;
    let head = trimmed[..in_pos].trim();
    let tail = trimmed[in_pos + 4..].trim();
    let (delay, delay_human, tail_after_delay) = parse_leading_delay(tail)?;

    let mut message = head.to_string();
    for marker in [
        "set a reminder to",
        "set a reminder for",
        "set reminder to",
        "set reminder for",
        "reminder to",
        "reminder for",
    ] {
        if let Some(pos) = lower.find(marker) {
            let start = pos + marker.len();
            if start <= head.len() {
                message = head[start..].to_string();
                break;
            }
        }
    }

    let mut message = normalize_reminder_message(&message);
    if message.is_empty() {
        message = normalize_reminder_message(tail_after_delay);
    }
    if message.is_empty() {
        return None;
    }

    Some(ReminderIntent {
        message,
        delay,
        delay_human,
    })
}

fn normalize_reminder_message(raw: &str) -> String {
    let mut text = raw.trim();
    if text.is_empty() {
        return String::new();
    }

    for prefix in ["about ", "to "] {
        if text.len() >= prefix.len() && text[..prefix.len()].eq_ignore_ascii_case(prefix) {
            text = text[prefix.len()..].trim();
            break;
        }
    }

    text.trim_end_matches(|c: char| matches!(c, '.' | '!' | '?' | ',' | ';'))
        .trim()
        .to_string()
}

fn parse_leading_delay(input: &str) -> Option<(ChronoDuration, String, &str)> {
    let s = input.trim_start();
    let digit_len = s.chars().take_while(|ch| ch.is_ascii_digit()).count();
    if digit_len == 0 {
        return None;
    }
    let amount: i64 = s[..digit_len].parse().ok()?;
    if amount <= 0 {
        return None;
    }
    let after_num = s[digit_len..].trim_start();
    let unit_len = after_num
        .chars()
        .take_while(|ch| ch.is_ascii_alphabetic())
        .count();
    if unit_len == 0 {
        return None;
    }
    let unit_raw = &after_num[..unit_len];
    let rest = after_num[unit_len..].trim_start();
    let unit = unit_raw.to_ascii_lowercase();

    let (delay, unit_label) = match unit.as_str() {
        "s" | "sec" | "secs" | "second" | "seconds" => (ChronoDuration::seconds(amount), "second"),
        "m" | "min" | "mins" | "minute" | "minutes" => (ChronoDuration::minutes(amount), "minute"),
        "h" | "hr" | "hrs" | "hour" | "hours" => (ChronoDuration::hours(amount), "hour"),
        "d" | "day" | "days" => (ChronoDuration::days(amount), "day"),
        _ => return None,
    };

    let plural = if amount == 1 { "" } else { "s" };
    let human = format!("{amount} {unit_label}{plural}");
    Some((delay, human, rest))
}

async fn store_chat_memory(ctx: &WorkerCtx, thread_id: &str, role: &str, content: &str) -> Result<()> {
    let Some(mem) = ctx.mem.as_ref() else {
        return Ok(());
    };
    let trimmed = content.trim();
    if trimmed.is_empty() {
        return Ok(());
    }

    let key = format!("pb_chat_{role}_{}", Uuid::new_v4());
    let payload = format!("{role}: {trimmed}");
    mem.store(
        &key,
        &payload,
        MemoryCategory::Conversation,
        Some(thread_id),
    )
    .await
}

async fn fetch_pending_messages(ctx: &WorkerCtx) -> Result<Vec<ChatRecord>> {
    let url = format!("{}/api/collections/{}/records", ctx.base_url, ctx.collection);
    let per_page = FETCH_PAGE_SIZE.to_string();
    let mut pending: Vec<ChatRecord> = Vec::new();

    for page in 1..=MAX_FETCH_PAGES {
        let page_str = page.to_string();
        let response = authed_request(ctx, ctx.client.get(&url))
            .query(&[
                ("page", page_str.as_str()),
                ("perPage", per_page.as_str()),
            ])
            .send()
            .await
            .context("PocketBase chat poll request failed")?;

        let status = response.status();
        if !status.is_success() {
            let body = response.text().await.unwrap_or_default();
            anyhow::bail!(
                "PocketBase chat poll failed ({status}) for collection '{}': {}",
                ctx.collection,
                body.trim()
            );
        }

        let list = response
            .json::<PocketBaseList<ChatRecord>>()
            .await
            .context("PocketBase chat poll JSON decode failed")?;

        let page_len = list.items.len();
        pending.extend(list.items.into_iter().filter(|r| {
            r.role
                .as_deref()
                .is_some_and(|role| role.eq_ignore_ascii_case("user"))
                && r.status
                    .as_deref()
                    .is_some_and(|status| status.eq_ignore_ascii_case("pending"))
        }));

        if page_len < FETCH_PAGE_SIZE {
            break;
        }
    }

    // PocketBase typically returns newest-first or created ordering depending on version/config.
    // Reverse to process older pending items first in a best-effort way.
    pending.reverse();
    pending.truncate(MAX_PENDING_PER_POLL);
    Ok(pending)
}

async fn patch_record(ctx: &WorkerCtx, id: &str, payload: serde_json::Value) -> Result<()> {
    let url = format!(
        "{}/api/collections/{}/records/{}",
        ctx.base_url, ctx.collection, id
    );
    let response = authed_request(ctx, ctx.client.patch(url))
        .json(&payload)
        .send()
        .await
        .context("PocketBase chat patch request failed")?;
    ensure_ok_response(response, "patch chat record").await
}

async fn create_record(ctx: &WorkerCtx, payload: serde_json::Value) -> Result<()> {
    let url = format!(
        "{}/api/collections/{}/records",
        ctx.base_url, ctx.collection
    );
    let response = authed_request(ctx, ctx.client.post(url))
        .json(&payload)
        .send()
        .await
        .context("PocketBase chat create request failed")?;
    ensure_ok_response(response, "create chat record").await
}

fn authed_request(
    ctx: &WorkerCtx,
    request: reqwest::RequestBuilder,
) -> reqwest::RequestBuilder {
    if let Some(token) = ctx.token.as_deref() {
        request.bearer_auth(token)
    } else {
        request
    }
}

async fn ensure_ok_response(response: reqwest::Response, op: &str) -> Result<()> {
    let status = response.status();
    if status.is_success() {
        return Ok(());
    }
    let body = response.text().await.unwrap_or_default();
    anyhow::bail!("{op} failed ({status}): {}", body.trim());
}

fn resolve_base_url(sidecar_url: Option<String>) -> Option<String> {
    std::env::var("ZEROCLAW_POCKETBASE_URL")
        .ok()
        .or_else(|| std::env::var("POCKETBASE_URL").ok())
        .or(sidecar_url)
        .map(|v| v.trim().trim_end_matches('/').to_string())
        .filter(|v| !v.is_empty())
}

fn pocketbase_token() -> Option<String> {
    std::env::var("ZEROCLAW_POCKETBASE_TOKEN")
        .ok()
        .or_else(|| std::env::var("POCKETBASE_TOKEN").ok())
        .map(|v| v.trim().to_string())
        .filter(|v| !v.is_empty())
}

fn env_flag(name: &str) -> bool {
    std::env::var(name)
        .ok()
        .map(|v| matches!(v.trim().to_ascii_lowercase().as_str(), "1" | "true" | "yes" | "on"))
        .unwrap_or(false)
}
