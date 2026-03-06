import type {
  ClawChatMessage,
  LibraryItem,
  PostHistoryItem,
  StoredDraft
} from "./types";

const CHAT_GATEWAY_BASE_URL_STORAGE_KEY = "slowclaw.chat.gateway_base_url";

function isTauriDesktopRuntime(): boolean {
  if (typeof window === "undefined") {
    return false;
  }
  return Boolean((window as any).__TAURI_INTERNALS__);
}

function defaultGatewayBaseUrl(): string {
  if (typeof window === "undefined") {
    return "http://127.0.0.1:42617";
  }
  const saved = window.localStorage.getItem(CHAT_GATEWAY_BASE_URL_STORAGE_KEY);
  if (saved && saved.trim()) {
    return saved.trim().replace(/\/+$/, "");
  }
  return "http://127.0.0.1:42617";
}

function resolveGatewayEndpoint(path: string, gatewayBaseUrl?: string): string {
  const configured = gatewayBaseUrl?.trim();
  const base =
    configured && configured.length > 0
      ? configured
      : isTauriDesktopRuntime()
        ? defaultGatewayBaseUrl()
        : "";
  if (!base) {
    return path;
  }
  const normalizedBase = base.replace(/\/+$/, "");
  const suffix = path.startsWith("/") ? path : `/${path}`;
  return `${normalizedBase}${suffix}`;
}

function authHeaders(token?: string, contentType?: string): HeadersInit {
  return {
    ...(contentType ? { "Content-Type": contentType } : {}),
    ...(token ? { Authorization: `Bearer ${token}` } : {})
  };
}

async function parseJsonOrThrow(res: Response) {
  const text = await res.text();
  let data: any = {};
  try {
    data = text ? JSON.parse(text) : {};
  } catch {
    data = { raw: text };
  }
  if (!res.ok) {
    throw new Error(String(data?.error || `Request failed (${res.status})`));
  }
  return data;
}

export type RuntimeConfigSnapshot = {
  defaultProvider: string;
  defaultModel: string;
  transcriptionEnabled: boolean;
  transcriptionModel: string;
  availableTranscriptionModels: string[];
};

export type FeedWorkflowCommentResult = {
  queued: boolean;
  threadId: string;
  workflowKey: string;
  workflowBot: string;
  editableFiles?: string[];
  messageId?: string;
  message?: string;
};

export type FeedWorkflowMode = "date_range" | "random";

export type FeedWorkflowSettingsItem = {
  workflowKey: string;
  workflowBot: string;
  scriptPath: string;
  outputPrefix: string;
  mode: FeedWorkflowMode;
  days: number;
  randomCount: number;
  scheduleEnabled: boolean;
  scheduleCron: string;
  scheduleTz?: string;
  scheduleJobId?: string;
  scheduleNextRun?: string;
  prompt?: string;
  commandPreview: string;
  editableFiles?: string[];
};

export type FeedWorkflowSettingsUpdatePayload = {
  workflowKey: string;
  mode?: FeedWorkflowMode;
  days?: number;
  randomCount?: number;
  scheduleEnabled?: boolean;
  scheduleCron?: string;
  scheduleTz?: string;
  prompt?: string;
};

export type FeedWorkflowSettingsUpdateResult = {
  item: FeedWorkflowSettingsItem;
  runQueued?: boolean;
  runThreadId?: string;
};

export type FeedWorkflowRunResult = {
  queued: boolean;
  threadId: string;
  workflowKey: string;
  workflowBot: string;
};

export type FeedWorkflowTemplateCreatePayload = {
  name: string;
  botName?: string;
  sourceKind?: "text" | "audio";
  prompt?: string;
  mode?: FeedWorkflowMode;
  days?: number;
  randomCount?: number;
  scheduleEnabled?: boolean;
  scheduleCron?: string;
  scheduleTz?: string;
  runNow?: boolean;
};

export type FeedWorkflowTemplateCreateResult = {
  created: boolean;
  queued?: boolean;
  threadId?: string;
  messageId?: string;
  workflowKey: string;
  workflowBot: string;
  scriptPath: string;
  skillPath: string;
  outputDir: string;
  outputPrefix: string;
  commandPreview: string;
  scheduleJobId?: string;
  runQueued?: boolean;
  runThreadId?: string;
  creationSummary?: string;
};

export async function pairGatewayClient(oneTimeCode: string, gatewayBaseUrl?: string) {
  const code = oneTimeCode.trim();
  if (!code) {
    throw new Error("Pairing code is required");
  }
  const res = await fetch(resolveGatewayEndpoint("/pair", gatewayBaseUrl), {
    method: "POST",
    headers: {
      "X-Pairing-Code": code
    }
  });
  const data = await parseJsonOrThrow(res);
  return {
    token: String(data?.token || ""),
    message: String(data?.message || ""),
    paired: Boolean(data?.paired)
  };
}

export async function getRuntimeConfig(
  bearerToken?: string,
  gatewayBaseUrl?: string
): Promise<RuntimeConfigSnapshot> {
  const res = await fetch(resolveGatewayEndpoint("/api/config/runtime", gatewayBaseUrl), {
    headers: authHeaders(bearerToken)
  });
  const data = await parseJsonOrThrow(res);
  return {
    defaultProvider: String(data?.defaultProvider || ""),
    defaultModel: String(data?.defaultModel || ""),
    transcriptionEnabled: Boolean(data?.transcriptionEnabled),
    transcriptionModel: String(data?.transcriptionModel || ""),
    availableTranscriptionModels: Array.isArray(data?.availableTranscriptionModels)
      ? data.availableTranscriptionModels.map((value: unknown) => String(value))
      : []
  };
}

export async function updateRuntimeConfig(
  payload: RuntimeConfigSnapshot,
  bearerToken?: string,
  gatewayBaseUrl?: string
) {
  const res = await fetch(resolveGatewayEndpoint("/api/config/runtime", gatewayBaseUrl), {
    method: "POST",
    headers: authHeaders(bearerToken, "application/json"),
    body: JSON.stringify({
      defaultProvider: payload.defaultProvider,
      defaultModel: payload.defaultModel,
      transcriptionEnabled: payload.transcriptionEnabled,
      transcriptionModel: payload.transcriptionModel
    })
  });
  return parseJsonOrThrow(res);
}

export async function listLibraryItems(
  scope: "all" | "journal" | "feed",
  bearerToken?: string,
  gatewayBaseUrl?: string,
  limit: number = 400
): Promise<LibraryItem[]> {
  const params = new URLSearchParams({ scope, limit: String(Math.max(1, Math.min(2000, limit))) });
  const res = await fetch(resolveGatewayEndpoint(`/api/library/items?${params}`, gatewayBaseUrl), {
    headers: authHeaders(bearerToken)
  });
  const data = await parseJsonOrThrow(res);
  return Array.isArray(data.items) ? (data.items as LibraryItem[]) : [];
}

export async function readLibraryText(
  path: string,
  bearerToken?: string,
  gatewayBaseUrl?: string
): Promise<string> {
  const params = new URLSearchParams({ path });
  const res = await fetch(resolveGatewayEndpoint(`/api/library/text?${params}`, gatewayBaseUrl), {
    headers: authHeaders(bearerToken)
  });
  const data = await parseJsonOrThrow(res);
  return String(data.content || "");
}

export async function saveLibraryText(
  path: string,
  content: string,
  bearerToken?: string,
  gatewayBaseUrl?: string
): Promise<void> {
  const res = await fetch(resolveGatewayEndpoint("/api/library/save-text", gatewayBaseUrl), {
    method: "POST",
    headers: authHeaders(bearerToken, "application/json"),
    body: JSON.stringify({ path, content })
  });
  await parseJsonOrThrow(res);
}

export async function deleteLibraryItem(
  path: string,
  bearerToken?: string,
  gatewayBaseUrl?: string
) {
  const trimmedPath = path.trim();
  if (!trimmedPath) {
    throw new Error("Path is required");
  }
  const res = await fetch(resolveGatewayEndpoint("/api/library/delete", gatewayBaseUrl), {
    method: "POST",
    headers: authHeaders(bearerToken, "application/json"),
    body: JSON.stringify({ path: trimmedPath })
  });
  return parseJsonOrThrow(res);
}

export async function transcribeJournalMedia(
  mediaPath: string,
  bearerToken?: string,
  gatewayBaseUrl?: string
) {
  const trimmedPath = mediaPath.trim();
  if (!trimmedPath) {
    throw new Error("Media path is required");
  }
  const res = await fetch(resolveGatewayEndpoint("/api/journal/transcribe", gatewayBaseUrl), {
    method: "POST",
    headers: authHeaders(bearerToken, "application/json"),
    body: JSON.stringify({ mediaPath: trimmedPath })
  });
  return parseJsonOrThrow(res);
}

export async function getJournalTranscriptionStatus(
  mediaPath: string,
  bearerToken?: string,
  gatewayBaseUrl?: string
) {
  const trimmedPath = mediaPath.trim();
  if (!trimmedPath) {
    throw new Error("Media path is required");
  }
  const params = new URLSearchParams({ mediaPath: trimmedPath });
  const res = await fetch(
    resolveGatewayEndpoint(`/api/journal/transcribe/status?${params.toString()}`, gatewayBaseUrl),
    { headers: authHeaders(bearerToken) }
  );
  return parseJsonOrThrow(res);
}

export async function archivePostedLibraryItem(
  path: string,
  bearerToken?: string,
  gatewayBaseUrl?: string
) {
  const trimmedPath = path.trim();
  if (!trimmedPath) {
    throw new Error("Path is required");
  }
  const res = await fetch(resolveGatewayEndpoint("/api/library/delete", gatewayBaseUrl), {
    method: "POST",
    headers: authHeaders(bearerToken, "application/json"),
    body: JSON.stringify({ path: trimmedPath })
  });
  return parseJsonOrThrow(res);
}

export async function createJournalTextViaGateway(
  title: string,
  content: string,
  bearerToken?: string,
  gatewayBaseUrl?: string
) {
  const res = await fetch(resolveGatewayEndpoint("/api/journal/text", gatewayBaseUrl), {
    method: "POST",
    headers: authHeaders(bearerToken, "application/json"),
    body: JSON.stringify({ title, content, source: "mobile-ui" })
  });
  return parseJsonOrThrow(res);
}

export async function uploadMediaViaGateway(
  file: Blob,
  options: { kind: "audio" | "video" | "image" | "file"; filename: string; title?: string; entryId?: string },
  bearerToken?: string,
  gatewayBaseUrl?: string
) {
  const params = new URLSearchParams({
    kind: options.kind,
    filename: options.filename
  });
  if (options.title) {
    params.set("title", options.title);
  }
  if (options.entryId) {
    params.set("entry_id", options.entryId);
  }
  const res = await fetch(resolveGatewayEndpoint(`/api/media/upload?${params}`, gatewayBaseUrl), {
    method: "POST",
    headers: authHeaders(bearerToken, file.type || "application/octet-stream"),
    body: file
  });
  return parseJsonOrThrow(res);
}

export async function fetchMediaAsFile(
  mediaUrl: string,
  filename: string,
  bearerToken?: string,
  gatewayBaseUrl?: string
): Promise<File> {
  const target =
    mediaUrl.startsWith("http://") || mediaUrl.startsWith("https://")
      ? mediaUrl
      : resolveGatewayEndpoint(mediaUrl, gatewayBaseUrl);
  const res = await fetch(target, { headers: authHeaders(bearerToken) });
  if (!res.ok) {
    throw new Error(`Failed to fetch media (${res.status})`);
  }
  const blob = await res.blob();
  return new File([blob], filename, { type: blob.type || "application/octet-stream" });
}

function mapChatRecord(item: any, fallbackThreadId: string): ClawChatMessage {
  return {
    id: String(item.id || ""),
    threadId: String(item.threadId || fallbackThreadId),
    role:
      item.role === "assistant" || item.role === "system" ? item.role : "user",
    content: String(item.content || ""),
    status: String(item.status || "done"),
    error: item.error ? String(item.error) : undefined,
    source: item.source ? String(item.source) : undefined,
    replyToId: item.replyToId ? String(item.replyToId) : undefined,
    created: String(item.createdAtClient || item.created || ""),
    updated: String(item.updated || "")
  };
}

export async function listClawChatMessages(
  threadId: string,
  bearerToken?: string,
  gatewayBaseUrl?: string
): Promise<ClawChatMessage[]> {
  const params = new URLSearchParams({ threadId, limit: "200" });
  const res = await fetch(resolveGatewayEndpoint(`/api/chat/messages?${params.toString()}`, gatewayBaseUrl), {
    headers: authHeaders(bearerToken)
  });
  const data = await parseJsonOrThrow(res);
  const items = Array.isArray(data?.items) ? data.items : [];
  return items.map((item: any) => mapChatRecord(item, threadId));
}

export async function createClawChatUserMessage(
  threadId: string,
  content: string,
  bearerToken?: string,
  gatewayBaseUrl?: string
) {
  const res = await fetch(resolveGatewayEndpoint("/api/chat/messages", gatewayBaseUrl), {
    method: "POST",
    headers: authHeaders(bearerToken, "application/json"),
    body: JSON.stringify({ threadId, content })
  });
  return parseJsonOrThrow(res);
}

export async function submitFeedWorkflowComment(
  path: string,
  comment: string,
  bearerToken?: string,
  gatewayBaseUrl?: string
): Promise<FeedWorkflowCommentResult> {
  const trimmedPath = path.trim();
  const trimmedComment = comment.trim();
  if (!trimmedPath || !trimmedComment) {
    throw new Error("Path and comment are required");
  }
  const res = await fetch(resolveGatewayEndpoint("/api/feed/workflow-comment", gatewayBaseUrl), {
    method: "POST",
    headers: authHeaders(bearerToken, "application/json"),
    body: JSON.stringify({ path: trimmedPath, comment: trimmedComment })
  });
  const data = await parseJsonOrThrow(res);
  return {
    queued: Boolean(data?.queued),
    threadId: String(data?.threadId || ""),
    workflowKey: String(data?.workflowKey || ""),
    workflowBot: String(data?.workflowBot || ""),
    editableFiles: Array.isArray(data?.editableFiles)
      ? data.editableFiles.map((value: unknown) => String(value))
      : undefined,
    messageId: data?.messageId ? String(data.messageId) : undefined,
    message: data?.message ? String(data.message) : undefined
  };
}

function mapFeedWorkflowSettingsItem(item: any): FeedWorkflowSettingsItem {
  return {
    workflowKey: String(item?.workflowKey || ""),
    workflowBot: String(item?.workflowBot || ""),
    scriptPath: String(item?.scriptPath || ""),
    outputPrefix: String(item?.outputPrefix || ""),
    mode: item?.mode === "random" ? "random" : "date_range",
    days: Number.isFinite(Number(item?.days)) ? Number(item.days) : 7,
    randomCount: Number.isFinite(Number(item?.randomCount)) ? Number(item.randomCount) : 1,
    scheduleEnabled: Boolean(item?.scheduleEnabled),
    scheduleCron: String(item?.scheduleCron || ""),
    scheduleTz: item?.scheduleTz ? String(item.scheduleTz) : undefined,
    scheduleJobId: item?.scheduleJobId ? String(item.scheduleJobId) : undefined,
    scheduleNextRun: item?.scheduleNextRun ? String(item.scheduleNextRun) : undefined,
    prompt: item?.prompt ? String(item.prompt) : undefined,
    commandPreview: String(item?.commandPreview || ""),
    editableFiles: Array.isArray(item?.editableFiles)
      ? item.editableFiles.map((value: unknown) => String(value))
      : undefined
  };
}

export async function listFeedWorkflowSettings(
  bearerToken?: string,
  gatewayBaseUrl?: string
): Promise<FeedWorkflowSettingsItem[]> {
  const res = await fetch(resolveGatewayEndpoint("/api/feed/workflow-settings", gatewayBaseUrl), {
    headers: authHeaders(bearerToken)
  });
  const data = await parseJsonOrThrow(res);
  const items = Array.isArray(data?.items) ? data.items : [];
  return items.map(mapFeedWorkflowSettingsItem);
}

export async function updateFeedWorkflowSettings(
  payload: FeedWorkflowSettingsUpdatePayload,
  bearerToken?: string,
  gatewayBaseUrl?: string
): Promise<FeedWorkflowSettingsUpdateResult> {
  const res = await fetch(resolveGatewayEndpoint("/api/feed/workflow-settings", gatewayBaseUrl), {
    method: "POST",
    headers: authHeaders(bearerToken, "application/json"),
    body: JSON.stringify(payload)
  });
  const data = await parseJsonOrThrow(res);
  return {
    item: mapFeedWorkflowSettingsItem(data?.item || {}),
    runQueued: data?.runQueued ? Boolean(data.runQueued) : undefined,
    runThreadId: data?.runThreadId ? String(data.runThreadId) : undefined
  };
}

export async function runFeedWorkflowNow(
  workflowKey: string,
  bearerToken?: string,
  gatewayBaseUrl?: string
): Promise<FeedWorkflowRunResult> {
  const key = workflowKey.trim();
  if (!key) {
    throw new Error("workflowKey is required");
  }
  const res = await fetch(resolveGatewayEndpoint("/api/feed/workflow-run", gatewayBaseUrl), {
    method: "POST",
    headers: authHeaders(bearerToken, "application/json"),
    body: JSON.stringify({ workflowKey: key })
  });
  const data = await parseJsonOrThrow(res);
  return {
    queued: Boolean(data?.queued),
    threadId: String(data?.threadId || ""),
    workflowKey: String(data?.workflowKey || ""),
    workflowBot: String(data?.workflowBot || "")
  };
}

export async function createFeedWorkflowTemplate(
  payload: FeedWorkflowTemplateCreatePayload,
  bearerToken?: string,
  gatewayBaseUrl?: string
): Promise<FeedWorkflowTemplateCreateResult> {
  const name = String(payload?.name || "").trim();
  if (!name) {
    throw new Error("name is required");
  }
  const res = await fetch(resolveGatewayEndpoint("/api/feed/workflow-template", gatewayBaseUrl), {
    method: "POST",
    headers: authHeaders(bearerToken, "application/json"),
    body: JSON.stringify(payload)
  });
  const data = await parseJsonOrThrow(res);
  return {
    created: Boolean(data?.created),
    queued: data?.queued ? Boolean(data.queued) : undefined,
    threadId: data?.threadId ? String(data.threadId) : undefined,
    messageId: data?.messageId ? String(data.messageId) : undefined,
    workflowKey: String(data?.workflowKey || ""),
    workflowBot: String(data?.workflowBot || ""),
    scriptPath: String(data?.scriptPath || ""),
    skillPath: String(data?.skillPath || ""),
    outputDir: String(data?.outputDir || ""),
    outputPrefix: String(data?.outputPrefix || ""),
    commandPreview: String(data?.commandPreview || ""),
    scheduleJobId: data?.scheduleJobId ? String(data.scheduleJobId) : undefined,
    runQueued: data?.runQueued ? Boolean(data.runQueued) : undefined,
    runThreadId: data?.runThreadId ? String(data.runThreadId) : undefined,
    creationSummary: data?.creationSummary ? String(data.creationSummary) : undefined
  };
}

export async function listDrafts(
  bearerToken?: string,
  gatewayBaseUrl?: string
): Promise<StoredDraft[]> {
  const res = await fetch(resolveGatewayEndpoint("/api/drafts?limit=20", gatewayBaseUrl), {
    headers: authHeaders(bearerToken)
  });
  const data = await parseJsonOrThrow(res);
  const items = Array.isArray(data?.items) ? data.items : [];
  return items.map((item: any) => ({
    id: String(item.id || ""),
    text: String(item.text || ""),
    videoName: item.videoName ? String(item.videoName) : "",
    created: String(item.createdAtClient || item.created || ""),
    updated: String(item.updatedAtClient || item.updated || "")
  }));
}

export async function saveDraft(
  draft: StoredDraft,
  bearerToken?: string,
  gatewayBaseUrl?: string
): Promise<StoredDraft> {
  const res = await fetch(resolveGatewayEndpoint("/api/drafts", gatewayBaseUrl), {
    method: "POST",
    headers: authHeaders(bearerToken, "application/json"),
    body: JSON.stringify({
      id: draft.id,
      text: draft.text,
      videoName: draft.videoName || "",
      createdAtClient: draft.created,
      updatedAtClient: draft.updated || new Date().toISOString()
    })
  });
  const data = await parseJsonOrThrow(res);
  return {
    id: String(data.id || ""),
    text: String(data.text || ""),
    videoName: data.videoName ? String(data.videoName) : "",
    created: String(data.createdAtClient || data.created || ""),
    updated: String(data.updatedAtClient || data.updated || "")
  };
}

export async function listPostHistory(
  bearerToken?: string,
  gatewayBaseUrl?: string
): Promise<PostHistoryItem[]> {
  const res = await fetch(resolveGatewayEndpoint("/api/post-history?limit=50", gatewayBaseUrl), {
    headers: authHeaders(bearerToken)
  });
  const data = await parseJsonOrThrow(res);
  const items = Array.isArray(data?.items) ? data.items : [];
  return items.map((item: any) => ({
    id: String(item.id || ""),
    provider: "bluesky",
    text: String(item.text || ""),
    videoName: item.videoName ? String(item.videoName) : undefined,
    sourcePath: item.sourcePath ? String(item.sourcePath) : undefined,
    uri: item.uri ? String(item.uri) : undefined,
    cid: item.cid ? String(item.cid) : undefined,
    created: String(item.createdAtClient || item.created || ""),
    status: item.status === "success" ? "success" : "error",
    error: item.error ? String(item.error) : undefined
  }));
}

export async function createPostHistory(
  item: PostHistoryItem,
  bearerToken?: string,
  gatewayBaseUrl?: string
) {
  const res = await fetch(resolveGatewayEndpoint("/api/post-history", gatewayBaseUrl), {
    method: "POST",
    headers: authHeaders(bearerToken, "application/json"),
    body: JSON.stringify({
      provider: item.provider,
      text: item.text,
      videoName: item.videoName || "",
      sourcePath: item.sourcePath || "",
      uri: item.uri || "",
      cid: item.cid || "",
      status: item.status,
      error: item.error || "",
      createdAtClient: item.created
    })
  });
  return parseJsonOrThrow(res);
}
