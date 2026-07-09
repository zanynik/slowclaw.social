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
export type NativeLocalAiStatus = {
  provider: string;
  configured: boolean;
  available: boolean;
  running: boolean;
  state: string;
  modelId?: string | null;
  modelPath?: string | null;
  apiUrl: string;
  message: string;
  error?: string | null;
};

export type LocalModelDownloadStatus = {
  model: string;
  available: boolean;
  message: string;
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

/**
 * Import voice memos shared into the app via iOS file hand-off.
 *
 * iOS places share-sheet ("Copy to SlowClaw") files in `Documents/Inbox/` and
 * the user can also drop `.m4a` recordings into the Files-app-visible
 * `Documents/Voice Memos/` folder. This moves every audio file found in either
 * location into the workspace media inbox (`journals/media/audio/inbox/`) and
 * returns the resulting journal entries, ready for on-device transcription.
 * Returns an empty array when nothing new is available.
 */
export async function importVoiceMemos(): Promise<JournalEntry[]> {
  return invoke("import_voice_memos");
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

export async function renameJournal(id: string, newTitle: string): Promise<JournalEntry> {
  return invoke("rename_journal", { id, newTitle });
}

export async function deleteJournal(id: string): Promise<void> {
  return invoke("delete_journal", { id });
}

/**
 * Store AI-extracted interest keywords for a journal entry into the feed's
 * per-source triage-keyword slot, then mark the world feed dirty so the next
 * load re-profiles from these keywords instead of the heuristic extractor.
 * iOS-first; mirrors the journal CRUD command shape.
 */
export async function saveJournalInterestKeywords(
  journalId: string,
  keywords: string[],
  contentHash: string,
): Promise<void> {
  return invoke("save_journal_interest_keywords", { journalId, keywords, contentHash });
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

export async function downloadOllamaModel(model: string): Promise<LocalModelDownloadStatus> {
  return invoke("download_ollama_model", { model });
}

export async function chatWithOllama(prompt: string): Promise<string> {
  return invoke("chat_with_ollama", { prompt });
}

export async function chatWithGeminiCli(prompt: string, model?: string): Promise<string> {
  return invoke("chat_with_gemini_cli", { prompt, model });
}

export async function getNativeLocalAiStatus(): Promise<NativeLocalAiStatus> {
  return invoke("get_native_local_ai_status");
}

export async function configureNativeLocalAi(
  modelId: string,
  modelPath: string
): Promise<NativeLocalAiStatus> {
  return invoke("configure_native_local_ai", { req: { modelId, modelPath } });
}

export type NativeAiEngineStatus = {
  engineAvailable: boolean;
  modelLoaded: boolean;
  loadedModelId: string | null;
};

export type NativeAiChatResponse = {
  text: string;
  modelId: string;
  tokensGenerated: number;
  tokensPerSecond: number;
  stopReason: string;
};

export async function nativeAiLoadModel(): Promise<string> {
  return invoke("native_ai_load_model");
}

/**
 * Clear the configured native local AI model: unloads it from memory, deletes
 * the persisted config, resets status to the unconfigured default. The caller
 * is responsible for deleting the GGUF file separately (so it works for both
 * catalog and sideloaded models). Returns the refreshed status.
 */
export async function clearNativeLocalAi(): Promise<NativeLocalAiStatus> {
  return invoke("clear_native_local_ai");
}

/**
 * Delete an on-device model: unloads it from memory if active, clears the
 * persisted config if it is the configured model, and removes the GGUF file
 * from disk. Returns the refreshed status. Performs the file removal via a
 * Rust command (not the frontend fs plugin) so it works without registering
 * `tauri-plugin-fs` or granting an fs permission scope.
 */
export async function deleteLocalModel(modelId: string): Promise<NativeLocalAiStatus> {
  return invoke("delete_local_model", { modelId });
}

export async function nativeAiChat(
  prompt: string,
  systemPrompt?: string,
  maxTokens?: number,
  temperature?: number
): Promise<NativeAiChatResponse> {
  return invoke("native_ai_chat", {
    prompt,
    systemPrompt: systemPrompt ?? null,
    maxTokens: maxTokens ?? null,
    temperature: temperature ?? null,
  });
}

export async function nativeAiEngineStatus(): Promise<NativeAiEngineStatus> {
  return invoke("native_ai_engine_status");
}

// ─────────────────────────────────────────────
// Audio transcription (iOS Speech.framework)
// ─────────────────────────────────────────────

export type TranscriptionResult = {
  text: string;
  durationSeconds: number;
};

export async function transcribeAudio(audioPath: string): Promise<TranscriptionResult> {
  return invoke("transcribe_audio", { audioPath });
}

/**
 * Transcribe a saved journal audio entry by its workspace-relative id (native).
 *
 * Resolves the id to the on-disk file inside the Tauri host and runs the
 * shared on-device transcriber (Speech.framework on iOS). Use this for the
 * manual "Transcribe" action on native clients, where the gateway reports no
 * CLI media tools but on-device transcription is available.
 */
export async function transcribeJournalMediaNative(id: string): Promise<TranscriptionResult> {
  return invoke("transcribe_journal_media", { id });
}

export type JournalMediaBytes = {
  dataB64: string;
  mimeType: string;
};

/** Read a saved journal media entry's bytes (base64 + MIME) for inline playback. */
export async function readJournalMediaBytes(id: string): Promise<JournalMediaBytes> {
  return invoke("read_journal_media_bytes", { id });
}

export async function setMetalMode(enabled: boolean): Promise<void> {
  return invoke("set_metal_mode", { enabled });
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
// Audio recording helper. Mobile uses the Web API until a native plugin is bundled.
// See: audioRecorder.ts
// ─────────────────────────────────────────────

export {
  startRecording,
  stopRecording,
  getRecordingState,
  blobToBase64,
  base64ToBlob
} from "./audioRecorder";
