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
  mediaCapabilities?: MediaCapabilities;
  mediaSummary?: string;
};

export type MediaCapabilities = {
  transcribeMedia: boolean;
  cleanAudio: boolean;
  extractAudioSegment: boolean;
  renderTextCardVideo: boolean;
  stitchImagesWithAudio: boolean;
  composeSimpleClip: boolean;
};

export type FeedContentAgentCommentResult = {
  queued: boolean;
  threadId: string;
  workflowKey: string;
  workflowBot: string;
  editableFiles?: string[];
  messageId?: string;
  message?: string;
};

export type FeedContentAgentItem = {
  workflowKey: string;
  workflowBot: string;
  skillPath: string;
  outputPrefix: string;
  enabled: boolean;
  supported?: boolean;
  unsupportedReason?: string;
  goal?: string;
  editableFiles?: string[];
};

export type FeedContentAgentUpdatePayload = {
  workflowKey: string;
  goal?: string;
  enabled?: boolean;
  runNow?: boolean;
};

export type FeedContentAgentUpdateResult = {
  item: FeedContentAgentItem;
  runQueued?: boolean;
  runThreadId?: string;
};

export type FeedContentAgentRunResult = {
  queued: boolean;
  threadId: string;
  workflowKey: string;
  workflowBot: string;
};

export type FeedContentAgentAutoRunItem = {
  workflowKey: string;
  workflowBot: string;
  threadId: string;
};

export type FeedContentAgentAutoRunResult = {
  queuedCount: number;
  items: FeedContentAgentAutoRunItem[];
};

export type FeedContentAgentCreatePayload = {
  name: string;
  goal: string;
  enabled?: boolean;
  runNow?: boolean;
};

export type FeedContentAgentCreateResult = {
  created: boolean;
  queued?: boolean;
  threadId?: string;
  messageId?: string;
  workflowKey: string;
  workflowBot: string;
  skillPath: string;
  outputDir: string;
  outputPrefix: string;
  runQueued?: boolean;
  runThreadId?: string;
  creationSummary?: string;
};

export type WorkspaceSynthesizerStatus = {
  status: "idle" | "pending" | "processing" | "done" | "error" | string;
  triggerReason?: string;
  threadId?: string;
  lastRunAt?: string;
  lastSourceUpdatedAt?: number;
  lastSummary?: string;
  lastError?: string;
  lastManifestPath?: string;
  artifactCounts?: {
    insightPosts?: number;
    todos?: number;
    events?: number;
    clipPlans?: number;
  };
  artifactStates?: {
    insightPosts?: WorkspaceSynthArtifactState;
    todos?: WorkspaceSynthArtifactState;
    events?: WorkspaceSynthArtifactState;
    clipPlans?: WorkspaceSynthArtifactState;
  };
};

export type WorkspaceSynthArtifactState = {
  status?: "applied" | "skipped" | "error" | string;
  path?: string;
  itemCount?: number;
  error?: string;
};

export type WorkspaceTodoItem = {
  id: string;
  title: string;
  details?: string | null;
  priority: "low" | "medium" | "high" | string;
  modelStatus?: "open" | "done" | string;
  statusOverride?: "open" | "done" | string | null;
  status: "open" | "done" | string;
  dueAt?: string | null;
  sourcePath?: string | null;
  sourceExcerpt?: string | null;
  metadataJson?: string | null;
  created: string;
  updated: string;
};

export type WorkspaceEventItem = {
  id: string;
  title: string;
  details?: string | null;
  location?: string | null;
  status: "confirmed" | "tentative" | "cancelled" | string;
  startAt: string;
  endAt?: string | null;
  allDay: boolean;
  sourcePath?: string | null;
  sourceExcerpt?: string | null;
  metadataJson?: string | null;
  created: string;
  updated: string;
};

export type PersonalizedFeedRequest = {
  serviceUrl?: string;
  accessJwt?: string;
  limit?: number;
};

export type PersonalizedBlueskyItem = {
  sourceType?: "bluesky" | "web";
  feedItem: any;
  webPreview?: {
    url: string;
    title: string;
    description: string;
    imageUrl?: string | null;
    domain: string;
    provider: string;
    providerSnippet?: string | null;
    discoveredAt: string;
  } | null;
  score?: number | null;
  matchedInterestLabel?: string | null;
  matchedInterestScore?: number | null;
  passedThreshold: boolean;
};

export type InterestProfileStats = {
  interestCount: number;
  sourceCount: number;
  refreshedSources: number;
  mergedCount: number;
  spawnedCount: number;
  ignoredCount: number;
};

export type PersonalizedBlueskyFeedResponse = {
  items: PersonalizedBlueskyItem[];
  profileStatus: string;
  profileStats: InterestProfileStats;
  usedFallback: boolean;
  message?: string;
};

export type WorkspaceSyncFile = {
  path: string;
  modifiedAt: number;
  contentBase64: string;
};

export type LocalStoreSyncBlob = {
  modifiedAt: number;
  contentBase64: string;
};

export type WorkspaceSyncSnapshot = {
  exportedAt: number;
  files: WorkspaceSyncFile[];
  localStore?: LocalStoreSyncBlob | null;
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
      : [],
    mediaCapabilities: {
      transcribeMedia: Boolean(data?.mediaCapabilities?.transcribeMedia),
      cleanAudio: Boolean(data?.mediaCapabilities?.cleanAudio),
      extractAudioSegment: Boolean(data?.mediaCapabilities?.extractAudioSegment),
      renderTextCardVideo: Boolean(data?.mediaCapabilities?.renderTextCardVideo),
      stitchImagesWithAudio: Boolean(data?.mediaCapabilities?.stitchImagesWithAudio),
      composeSimpleClip: Boolean(data?.mediaCapabilities?.composeSimpleClip)
    },
    mediaSummary: String(data?.mediaSummary || "")
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

export async function fetchPersonalizedFeed(
  payload: PersonalizedFeedRequest,
  bearerToken?: string,
  gatewayBaseUrl?: string
): Promise<PersonalizedBlueskyFeedResponse> {
  const res = await fetch(resolveGatewayEndpoint("/api/feed/personalized", gatewayBaseUrl), {
    method: "POST",
    headers: authHeaders(bearerToken, "application/json"),
    body: JSON.stringify({
      serviceUrl: payload.serviceUrl,
      accessJwt: payload.accessJwt,
      limit: payload.limit
    })
  });
  const data = await parseJsonOrThrow(res);
  return {
    items: Array.isArray(data.items)
      ? data.items.map((item: any) => ({
          sourceType: item?.sourceType === "bluesky" ? "bluesky" : "web",
          feedItem: item?.feedItem || {},
          webPreview: item?.webPreview
            ? {
                url: String(item.webPreview.url || ""),
                title: String(item.webPreview.title || ""),
                description: String(item.webPreview.description || ""),
                imageUrl: item.webPreview.imageUrl ? String(item.webPreview.imageUrl) : null,
                domain: String(item.webPreview.domain || ""),
                provider: String(item.webPreview.provider || ""),
                providerSnippet: item.webPreview.providerSnippet
                  ? String(item.webPreview.providerSnippet)
                  : null,
                discoveredAt: String(item.webPreview.discoveredAt || "")
              }
            : null,
          score: item?.score == null ? null : Number(item.score),
          matchedInterestLabel: item?.matchedInterestLabel ? String(item.matchedInterestLabel) : null,
          matchedInterestScore:
            item?.matchedInterestScore == null ? null : Number(item.matchedInterestScore),
          passedThreshold: Boolean(item?.passedThreshold)
        }))
      : [],
    profileStatus: String(data.profileStatus || ""),
    profileStats: {
      interestCount: Number(data.profileStats?.interestCount || 0),
      sourceCount: Number(data.profileStats?.sourceCount || 0),
      refreshedSources: Number(data.profileStats?.refreshedSources || 0),
      mergedCount: Number(data.profileStats?.mergedCount || 0),
      spawnedCount: Number(data.profileStats?.spawnedCount || 0),
      ignoredCount: Number(data.profileStats?.ignoredCount || 0)
    },
    usedFallback: Boolean(data.usedFallback),
    message: typeof data.message === "string" ? data.message : undefined
  };
}

export async function exportWorkspaceSyncSnapshot(
  bearerToken?: string,
  gatewayBaseUrl?: string
): Promise<WorkspaceSyncSnapshot> {
  const res = await fetch(resolveGatewayEndpoint("/api/sync/export", gatewayBaseUrl), {
    headers: authHeaders(bearerToken)
  });
  const data = await parseJsonOrThrow(res);
  return {
    exportedAt: Number(data.exportedAt || 0),
    files: Array.isArray(data.files)
      ? data.files.map((item: any) => ({
          path: String(item?.path || ""),
          modifiedAt: Number(item?.modifiedAt || 0),
          contentBase64: String(item?.contentBase64 || "")
        }))
      : [],
    localStore: data.localStore
      ? {
          modifiedAt: Number(data.localStore.modifiedAt || 0),
          contentBase64: String(data.localStore.contentBase64 || "")
        }
      : null
  };
}

export async function importWorkspaceSyncSnapshot(
  snapshot: WorkspaceSyncSnapshot,
  bearerToken?: string,
  gatewayBaseUrl?: string
) {
  const res = await fetch(resolveGatewayEndpoint("/api/sync/import", gatewayBaseUrl), {
    method: "POST",
    headers: authHeaders(bearerToken, "application/json"),
    body: JSON.stringify(snapshot)
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

export async function submitFeedContentAgentComment(
  path: string,
  comment: string,
  bearerToken?: string,
  gatewayBaseUrl?: string
): Promise<FeedContentAgentCommentResult> {
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

function mapFeedContentAgentItem(item: any): FeedContentAgentItem {
  return {
    workflowKey: String(item?.workflowKey || ""),
    workflowBot: String(item?.workflowBot || ""),
    skillPath: String(item?.skillPath || ""),
    outputPrefix: String(item?.outputPrefix || ""),
    enabled: item?.enabled !== false,
    supported: item?.supported !== false,
    unsupportedReason: item?.unsupportedReason
      ? String(item.unsupportedReason)
      : undefined,
    goal: item?.goal ? String(item.goal) : undefined,
    editableFiles: Array.isArray(item?.editableFiles)
      ? item.editableFiles.map((value: unknown) => String(value))
      : undefined
  };
}

export async function listFeedContentAgents(
  bearerToken?: string,
  gatewayBaseUrl?: string
): Promise<FeedContentAgentItem[]> {
  const res = await fetch(resolveGatewayEndpoint("/api/feed/workflow-settings", gatewayBaseUrl), {
    headers: authHeaders(bearerToken)
  });
  const data = await parseJsonOrThrow(res);
  const items = Array.isArray(data?.items) ? data.items : [];
  return items.map(mapFeedContentAgentItem);
}

export async function updateFeedContentAgent(
  payload: FeedContentAgentUpdatePayload,
  bearerToken?: string,
  gatewayBaseUrl?: string
): Promise<FeedContentAgentUpdateResult> {
  const res = await fetch(resolveGatewayEndpoint("/api/feed/workflow-settings", gatewayBaseUrl), {
    method: "POST",
    headers: authHeaders(bearerToken, "application/json"),
    body: JSON.stringify(payload)
  });
  const data = await parseJsonOrThrow(res);
  return {
    item: mapFeedContentAgentItem(data?.item || {}),
    runQueued: data?.runQueued ? Boolean(data.runQueued) : undefined,
    runThreadId: data?.runThreadId ? String(data.runThreadId) : undefined
  };
}

export async function runFeedContentAgentNow(
  workflowKey: string,
  bearerToken?: string,
  gatewayBaseUrl?: string
): Promise<FeedContentAgentRunResult> {
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

export async function autoRunEligibleFeedContentAgents(
  reason: "app-open" | "journal-save" | "transcript-ready" = "app-open",
  bearerToken?: string,
  gatewayBaseUrl?: string
): Promise<FeedContentAgentAutoRunResult> {
  const res = await fetch(resolveGatewayEndpoint("/api/feed/workflow-auto-run", gatewayBaseUrl), {
    method: "POST",
    headers: authHeaders(bearerToken, "application/json"),
    body: JSON.stringify({ reason })
  });
  const data = await parseJsonOrThrow(res);
  const items = Array.isArray(data?.items) ? data.items : [];
  return {
    queuedCount: Number(data?.queuedCount || 0),
    items: items.map((item: any) => ({
      workflowKey: String(item?.workflowKey || ""),
      workflowBot: String(item?.workflowBot || ""),
      threadId: String(item?.threadId || "")
    }))
  };
}

export async function getWorkspaceSynthesizerStatus(
  bearerToken?: string,
  gatewayBaseUrl?: string
): Promise<WorkspaceSynthesizerStatus> {
  const res = await fetch(
    resolveGatewayEndpoint("/api/workspace/synthesizer/status", gatewayBaseUrl),
    {
      headers: authHeaders(bearerToken)
    }
  );
  const data = await parseJsonOrThrow(res);
  return {
    status: String(data?.status || "idle"),
    triggerReason: data?.triggerReason ? String(data.triggerReason) : undefined,
    threadId: data?.threadId ? String(data.threadId) : undefined,
    lastRunAt: data?.lastRunAt ? String(data.lastRunAt) : undefined,
    lastSourceUpdatedAt:
      typeof data?.lastSourceUpdatedAt === "number" ? data.lastSourceUpdatedAt : undefined,
    lastSummary: data?.lastSummary ? String(data.lastSummary) : undefined,
    lastError: data?.lastError ? String(data.lastError) : undefined,
    lastManifestPath: data?.lastManifestPath ? String(data.lastManifestPath) : undefined,
    artifactCounts: data?.artifactCounts
      ? {
          insightPosts: Number(data.artifactCounts.insightPosts || 0),
          todos: Number(data.artifactCounts.todos || 0),
          events: Number(data.artifactCounts.events || 0),
          clipPlans: Number(data.artifactCounts.clipPlans || 0)
        }
      : undefined,
    artifactStates: data?.artifactStates
      ? {
          insightPosts: data.artifactStates.insightPosts
            ? {
                status: String(data.artifactStates.insightPosts.status || ""),
                path: data.artifactStates.insightPosts.path
                  ? String(data.artifactStates.insightPosts.path)
                  : undefined,
                itemCount: Number(data.artifactStates.insightPosts.itemCount || 0),
                error: data.artifactStates.insightPosts.error
                  ? String(data.artifactStates.insightPosts.error)
                  : undefined
              }
            : undefined,
          todos: data.artifactStates.todos
            ? {
                status: String(data.artifactStates.todos.status || ""),
                path: data.artifactStates.todos.path
                  ? String(data.artifactStates.todos.path)
                  : undefined,
                itemCount: Number(data.artifactStates.todos.itemCount || 0),
                error: data.artifactStates.todos.error
                  ? String(data.artifactStates.todos.error)
                  : undefined
              }
            : undefined,
          events: data.artifactStates.events
            ? {
                status: String(data.artifactStates.events.status || ""),
                path: data.artifactStates.events.path
                  ? String(data.artifactStates.events.path)
                  : undefined,
                itemCount: Number(data.artifactStates.events.itemCount || 0),
                error: data.artifactStates.events.error
                  ? String(data.artifactStates.events.error)
                  : undefined
              }
            : undefined,
          clipPlans: data.artifactStates.clipPlans
            ? {
                status: String(data.artifactStates.clipPlans.status || ""),
                path: data.artifactStates.clipPlans.path
                  ? String(data.artifactStates.clipPlans.path)
                  : undefined,
                itemCount: Number(data.artifactStates.clipPlans.itemCount || 0),
                error: data.artifactStates.clipPlans.error
                  ? String(data.artifactStates.clipPlans.error)
                  : undefined
              }
            : undefined
        }
      : undefined
  };
}

export async function runWorkspaceSynthesizerNow(
  bearerToken?: string,
  gatewayBaseUrl?: string
): Promise<{ queued: boolean; threadId?: string }> {
  const res = await fetch(resolveGatewayEndpoint("/api/workspace/synthesizer/run", gatewayBaseUrl), {
    method: "POST",
    headers: authHeaders(bearerToken)
  });
  const data = await parseJsonOrThrow(res);
  return {
    queued: Boolean(data?.queued),
    threadId: data?.threadId ? String(data.threadId) : undefined
  };
}

export async function autoRunWorkspaceSynthesizer(
  reason: "app-open" | "journal-save" | "transcript-ready" = "app-open",
  bearerToken?: string,
  gatewayBaseUrl?: string
): Promise<{ queued: boolean; threadId?: string }> {
  const res = await fetch(
    resolveGatewayEndpoint("/api/workspace/synthesizer/auto-run", gatewayBaseUrl),
    {
      method: "POST",
      headers: authHeaders(bearerToken, "application/json"),
      body: JSON.stringify({ reason })
    }
  );
  const data = await parseJsonOrThrow(res);
  return {
    queued: Boolean(data?.queued),
    threadId: data?.threadId ? String(data.threadId) : undefined
  };
}

export async function listWorkspaceTodos(
  bearerToken?: string,
  gatewayBaseUrl?: string
): Promise<WorkspaceTodoItem[]> {
  const res = await fetch(resolveGatewayEndpoint("/api/workspace/todos?limit=100", gatewayBaseUrl), {
    headers: authHeaders(bearerToken)
  });
  const data = await parseJsonOrThrow(res);
  const items = Array.isArray(data?.items) ? data.items : [];
  return items.map((item: any) => ({
    id: String(item?.id || ""),
    title: String(item?.title || ""),
    details: item?.details ? String(item.details) : undefined,
    priority: String(item?.priority || "medium"),
    modelStatus: item?.modelStatus ? String(item.modelStatus) : undefined,
    statusOverride: item?.statusOverride ? String(item.statusOverride) : undefined,
    status: String(item?.status || "open"),
    dueAt: item?.dueAt ? String(item.dueAt) : undefined,
    sourcePath: item?.sourcePath ? String(item.sourcePath) : undefined,
    sourceExcerpt: item?.sourceExcerpt ? String(item.sourceExcerpt) : undefined,
    metadataJson: item?.metadataJson ? String(item.metadataJson) : undefined,
    created: String(item?.created || ""),
    updated: String(item?.updated || "")
  }));
}

export async function updateWorkspaceTodoStatus(
  todoId: string,
  status: "open" | "done",
  bearerToken?: string,
  gatewayBaseUrl?: string
): Promise<WorkspaceTodoItem> {
  const id = todoId.trim();
  if (!id) {
    throw new Error("todoId is required");
  }
  const res = await fetch(
    resolveGatewayEndpoint(`/api/workspace/todos/${encodeURIComponent(id)}`, gatewayBaseUrl),
    {
      method: "PATCH",
      headers: authHeaders(bearerToken, "application/json"),
      body: JSON.stringify({ status })
    }
  );
  const data = await parseJsonOrThrow(res);
  const item = data?.item || {};
  return {
    id: String(item?.id || ""),
    title: String(item?.title || ""),
    details: item?.details ? String(item.details) : undefined,
    priority: String(item?.priority || "medium"),
    modelStatus: item?.modelStatus ? String(item.modelStatus) : undefined,
    statusOverride: item?.statusOverride ? String(item.statusOverride) : undefined,
    status: String(item?.status || "open"),
    dueAt: item?.dueAt ? String(item.dueAt) : undefined,
    sourcePath: item?.sourcePath ? String(item.sourcePath) : undefined,
    sourceExcerpt: item?.sourceExcerpt ? String(item.sourceExcerpt) : undefined,
    metadataJson: item?.metadataJson ? String(item.metadataJson) : undefined,
    created: String(item?.created || ""),
    updated: String(item?.updated || "")
  };
}

export async function listWorkspaceEvents(
  bearerToken?: string,
  gatewayBaseUrl?: string
): Promise<WorkspaceEventItem[]> {
  const res = await fetch(resolveGatewayEndpoint("/api/workspace/events?limit=100", gatewayBaseUrl), {
    headers: authHeaders(bearerToken)
  });
  const data = await parseJsonOrThrow(res);
  const items = Array.isArray(data?.items) ? data.items : [];
  return items.map((item: any) => ({
    id: String(item?.id || ""),
    title: String(item?.title || ""),
    details: item?.details ? String(item.details) : undefined,
    location: item?.location ? String(item.location) : undefined,
    status: String(item?.status || "confirmed"),
    startAt: String(item?.startAt || ""),
    endAt: item?.endAt ? String(item.endAt) : undefined,
    allDay: Boolean(item?.allDay),
    sourcePath: item?.sourcePath ? String(item.sourcePath) : undefined,
    sourceExcerpt: item?.sourceExcerpt ? String(item.sourceExcerpt) : undefined,
    metadataJson: item?.metadataJson ? String(item.metadataJson) : undefined,
    created: String(item?.created || ""),
    updated: String(item?.updated || "")
  }));
}

export async function createFeedContentAgent(
  payload: FeedContentAgentCreatePayload,
  bearerToken?: string,
  gatewayBaseUrl?: string
): Promise<FeedContentAgentCreateResult> {
  const name = String(payload?.name || "").trim();
  const goal = String(payload?.goal || "").trim();
  if (!name) {
    throw new Error("name is required");
  }
  if (!goal) {
    throw new Error("goal is required");
  }
  const res = await fetch(resolveGatewayEndpoint("/api/feed/workflow-template", gatewayBaseUrl), {
    method: "POST",
    headers: authHeaders(bearerToken, "application/json"),
    body: JSON.stringify({
      ...payload,
      name,
      goal
    })
  });
  const data = await parseJsonOrThrow(res);
  return {
    created: Boolean(data?.created),
    queued: data?.queued ? Boolean(data.queued) : undefined,
    threadId: data?.threadId ? String(data.threadId) : undefined,
    messageId: data?.messageId ? String(data.messageId) : undefined,
    workflowKey: String(data?.workflowKey || ""),
    workflowBot: String(data?.workflowBot || ""),
    skillPath: String(data?.skillPath || ""),
    outputDir: String(data?.outputDir || ""),
    outputPrefix: String(data?.outputPrefix || ""),
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
