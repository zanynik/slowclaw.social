/**
 * tauriApi.ts — frontend command layer.
 * Replaces gatewayApi.ts HTTP calls with Tauri IPC invoke() calls.
 * Function signatures deliberately mirror gatewayApi.ts so App.tsx
 * can switch imports with minimal changes.
 */

import { invoke } from "@tauri-apps/api/core";

// ─────────────────────────────────────────────
// Types (mirror Rust structs, camelCase via serde)
// ─────────────────────────────────────────────

export type JournalEntry = {
  id: string;
  title: string;
  content: string;
  kind: "text" | "audio" | "video" | "image";
  filePath?: string | null;
  createdAt: string;
  updatedAt: string;
};

export type JournalSummary = {
  id: string;
  journalId: string;
  content: string;
  kind: "summary" | "weekly_digest";
  model: string;
  createdAt: string;
};

export type Draft = {
  id: string;
  text: string;
  videoName?: string | null;
  createdAt: string;
  updatedAt: string;
};

export type PostRecord = {
  id: string;
  provider: string;
  text: string;
  sourceJournalId?: string | null;
  uri?: string | null;
  cid?: string | null;
  status: "success" | "error";
  error?: string | null;
  createdAt: string;
};

export type AppConfig = {
  ollamaBaseUrl: string;
  ollamaModel: string;
  blueskyHandle: string;
  blueskyServiceUrl: string;
  transcriptionEnabled: boolean;
  transcriptionModel: string;
  availableTranscriptionModels: string[];
};

export type BuiltInOperation = {
  key: string;
  title: string;
  description: string;
  version: number;
  implemented: boolean;
};

export type ContentJob = {
  id: string;
  operationKey: string;
  targetId: string;
  targetPath: string;
  status: "queued" | "running" | "paused" | "retryable" | "completed" | "failed" | "canceled" | string;
  progressLabel: string;
  error?: string | null;
  output?: Record<string, unknown> | null;
  createdAt: string;
  updatedAt: string;
};

export type SchedulerJob = {
  id: string;
  name: string;
  kind: string;
  cron: string;
  enabled: boolean;
  lastRunAt?: string | null;
  nextRunAt?: string | null;
  lastStatus?: string | null;
  createdAt: string;
};

export type OllamaStatus = {
  available: boolean;
  baseUrl: string;
  model: string;
  models: string[];
};

// ─────────────────────────────────────────────
// Journal commands
// ─────────────────────────────────────────────

export async function saveJournalText(title: string, content: string): Promise<JournalEntry> {
  return invoke("save_journal_text", { title, content });
}

export async function saveJournalMedia(
  kind: "audio" | "video" | "image",
  filename: string,
  dataB64: string,
  title?: string
): Promise<JournalEntry> {
  return invoke("save_journal_media", { kind, filename, dataB64, title });
}

export async function listJournals(limit?: number, offset?: number): Promise<JournalEntry[]> {
  return invoke("list_journals", { limit, offset });
}

export async function getJournal(id: string): Promise<JournalEntry> {
  return invoke("get_journal", { id });
}

export async function updateJournalText(id: string, content: string): Promise<JournalEntry> {
  return invoke("update_journal_text", { id, content });
}

export async function deleteJournal(id: string): Promise<void> {
  return invoke("delete_journal", { id });
}

// ─────────────────────────────────────────────
// Summary / AI commands
// ─────────────────────────────────────────────

export async function summarizeJournal(journalId: string): Promise<JournalSummary> {
  return invoke("summarize_journal", { journalId });
}

export async function listSummaries(journalId?: string): Promise<JournalSummary[]> {
  return invoke("list_summaries", { journalId });
}

export async function generateWeeklyDigest(): Promise<JournalSummary> {
  return invoke("generate_weekly_digest");
}

// ─────────────────────────────────────────────
// Draft commands
// ─────────────────────────────────────────────

export async function saveDraft(draft: {
  id?: string;
  text: string;
  videoName?: string;
}): Promise<Draft> {
  return invoke("save_draft", { draft });
}

export async function listDrafts(): Promise<Draft[]> {
  return invoke("list_drafts");
}

export async function deleteDraft(id: string): Promise<void> {
  return invoke("delete_draft", { id });
}

// ─────────────────────────────────────────────
// Post history commands
// ─────────────────────────────────────────────

export async function savePostRecord(record: {
  provider: string;
  text: string;
  sourceJournalId?: string;
  uri?: string;
  cid?: string;
  status: "success" | "error";
  error?: string;
}): Promise<PostRecord> {
  return invoke("save_post_record", { record });
}

export async function listPostHistory(): Promise<PostRecord[]> {
  return invoke("list_post_history");
}

// ─────────────────────────────────────────────
// Config commands
// ─────────────────────────────────────────────

export async function getConfig(): Promise<AppConfig> {
  return invoke("get_config");
}

export async function saveConfig(config: AppConfig): Promise<void> {
  return invoke("save_config", { config });
}

export async function listBuiltInOperations(): Promise<BuiltInOperation[]> {
  return invoke("list_builtin_operations");
}

export async function listContentJobs(limit?: number): Promise<ContentJob[]> {
  return invoke("list_content_jobs", { limit });
}

export async function getContentJob(id: string): Promise<ContentJob | null> {
  return invoke("get_content_job", { id });
}

export async function getLatestContentJobForTarget(
  operationKey: string,
  targetId: string
): Promise<ContentJob | null> {
  return invoke("get_latest_content_job_for_target", { operationKey, targetId });
}

export async function transcribeMedia(journalId: string): Promise<ContentJob> {
  return invoke("transcribe_media", { journalId });
}

export async function summarizeEntry(journalId: string): Promise<ContentJob> {
  return invoke("summarize_entry", { journalId });
}

export async function extractTodos(journalId: string): Promise<ContentJob> {
  return invoke("extract_todos", { journalId });
}

export async function extractCalendarCandidates(journalId: string): Promise<ContentJob> {
  return invoke("extract_calendar_candidates", { journalId });
}

export async function rewriteEntryText(
  journalId: string,
  recipeKey?: string,
  style?: string
): Promise<ContentJob> {
  return invoke("rewrite_text", { journalId, recipeKey, style });
}

export async function retitleEntry(journalId: string): Promise<ContentJob> {
  return invoke("retitle_entry", { journalId });
}

export async function selectClips(journalId: string, objective?: string): Promise<ContentJob> {
  return invoke("select_clips", { journalId, objective });
}

export async function extractClips(journalId: string): Promise<ContentJob> {
  return invoke("extract_clips", { journalId });
}

// ─────────────────────────────────────────────
// Scheduler commands
// ─────────────────────────────────────────────

export async function listJobs(): Promise<SchedulerJob[]> {
  return invoke("list_jobs");
}

export async function createJob(job: {
  name: string;
  kind: string;
  cron: string;
  enabled: boolean;
}): Promise<SchedulerJob> {
  return invoke("create_job", { job });
}

export async function toggleJob(id: string, enabled: boolean): Promise<SchedulerJob> {
  return invoke("toggle_job", { id, enabled });
}

export async function runJobNow(id: string): Promise<string> {
  return invoke("run_job_now", { id });
}

// ─────────────────────────────────────────────
// AI / Ollama commands
// ─────────────────────────────────────────────

export async function checkOllama(): Promise<OllamaStatus> {
  return invoke("check_ollama");
}

export async function listOllamaModels(): Promise<string[]> {
  return invoke("list_ollama_models");
}

export async function chatWithOllama(prompt: string): Promise<string> {
  return invoke("chat_with_ollama", { prompt });
}

export async function chatWithGeminiCli(prompt: string, model?: string): Promise<string> {
  return invoke("chat_with_gemini_cli", { prompt, model });
}

// ─────────────────────────────────────────────
// Keyring / secrets (existing commands, kept for Bluesky credentials)
// ─────────────────────────────────────────────

export async function getSecret(service: string, account: string): Promise<string | null> {
  return invoke("get_secret", { service, account });
}

export async function setSecret(service: string, account: string, value: string): Promise<void> {
  return invoke("set_secret", { service, account, value });
}

export async function deleteSecret(service: string, account: string): Promise<void> {
  return invoke("delete_secret", { service, account });
}

// ─────────────────────────────────────────────
// Audio recording helper (desktop uses Web API; mobile uses native plugin)
// See: audioRecorder.ts
// ─────────────────────────────────────────────

export { startRecording, stopRecording, getRecordingState, blobToBase64 } from "./audioRecorder";
