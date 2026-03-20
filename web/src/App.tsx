import { lazy, Suspense, FormEvent, useEffect, useRef, useState } from "react";
import type { AtpAgent, AppBskyFeedDefs } from "@atproto/api";
import type { BlueskySession } from "./lib/bluesky";
import { ViewErrorBoundary } from "./components/ViewErrorBoundary";
// ── Tauri API (replaces HTTP gateway calls) ──────────────────────────────────
import {
  saveJournalText,
  saveJournalMedia,
  listJournals,
  getJournal,
  updateJournalText,
  deleteJournal,
  summarizeJournal,
  listSummaries,
  generateWeeklyDigest,
  saveDraft,
  listDrafts,
  deleteDraft,
  savePostRecord,
  listPostHistory,
  getConfig,
  saveConfig,
  listJobs,
  createJob,
  toggleJob,
  runJobNow,
  checkOllama,
  listOllamaModels,
  startRecording as startNativeAudioRecording,
  stopRecording as stopNativeAudioRecording,
  blobToBase64,
} from "./lib/tauriApi";
import type {
  JournalEntry,
  JournalSummary,
  Draft,
  PostRecord,
  AppConfig,
  SchedulerJob,
  OllamaStatus,
} from "./lib/tauriApi";
// ── Secure storage (keyring wrappers — unchanged) ────────────────────────────
import {
  clearSyncPeerSecure,
  deleteCredentialsSecure,
  loadGatewayTokenSecure,
  loadCredentialsFallback,
  loadCredentialsSecure,
  loadSyncPeerTokenSecure,
  loadSyncPeerUrlSecure,
  saveGatewayTokenSecure,
  saveBlueskySessionSecure,
  saveSyncPeerTokenSecure,
  saveSyncPeerUrlSecure,
  saveCredentialsSecure,
  loadNostrKeysSecure,
  saveNostrKeysSecure,
} from "./lib/secureStorage";
import type { NostrKeys } from "./lib/secureStorage";
import type {
  AnthropicTokenStatus,
  BlueskyCredentials,
  ClawChatMessage,
  GatewayQrPayload,
  LibraryItem,
  OpenAiDeviceCodeStatus,
  PostHistoryItem,
  StoredDraft,
} from "./lib/types";
import {
  archivePostedLibraryItem,
  createWorldFeedDummyInterest,
  createClawChatUserMessage as createClawChatUserMessageViaGateway,
  createFeedContentAgent,
  createJournalTextViaGateway,
  createPostHistory,
  deleteWorldFeedInterest,
  deleteLibraryItem,
  exportWorkspaceSyncSnapshot,
  fetchPersonalizedFeed,
  fetchMediaAsFile,
  getJournalTranscriptionStatus,
  importWorkspaceSyncSnapshot,
  getRuntimeConfig,
  getWorkspaceSynthesizerStatus,
  listWorkspaceSynthSkills,
  listClawChatMessages,
  listDrafts as listDraftsViaGateway,
  listFeedContentAgents,
  listWorldFeedInterests,
  listWorkspaceEvents,
  listWorkspaceTodos,
  listLibraryItems,
  listPostHistory as listPostHistoryViaGateway,
  readLibraryText,
  runWorkspaceSynthesizerNow,
  runFeedContentAgentNow,
  saveDraft as saveDraftViaGateway,
  saveLibraryText,
  streamClawChatMessages,
  streamClawChatResult,
  streamJournalTranscriptionStatus,
  streamWorkspaceSynthesizerStatus,
  submitFeedContentAgentComment,
  transcribeJournalMedia,
  updateWorkspaceSynthSkill,
  updateWorkspaceTodoStatus,
  updateFeedContentAgent,
  updateRuntimeConfig,
  updateWorldFeedInterest,
  uploadMediaViaGateway,
  startOpenRouterOAuth,
  getOpenRouterOAuthStatus,
} from "./lib/gatewayApi";
import type {
  FeedContentAgentItem,
  GatewayEventStreamHandle,
  JournalTranscriptionStatus,
  InterestProfileStats,
  MediaCapabilities,
  PersonalizedFeedItem,
  PersonalizedFeedResponse,
  WorldFeedInterestItem,
  WorkspaceEventItem,
  WorkspaceSynthArtifactState,
  WorkspaceSynthSkillItem,
  WorkspaceSynthSkillRunState,
  WorkspaceSynthesizerStatus,
  WorkspaceTodoItem,
} from "./lib/gatewayApi";
import { ProductivityView } from "./views/ProductivityView";

const CHAT_THREAD_STORAGE_KEY = "slowclaw.chat.thread_id";
const CHAT_GATEWAY_BASE_URL_STORAGE_KEY = "slowclaw.chat.gateway_base_url";
const CHAT_GATEWAY_TOKEN_STORAGE_KEY = "slowclaw.chat.gateway_token";
const SYNC_PEER_GATEWAY_BASE_URL_STORAGE_KEY = "slowclaw.sync.peer.gateway_base_url";
const SYNC_PEER_GATEWAY_TOKEN_STORAGE_KEY = "slowclaw.sync.peer.gateway_token";
const CHAT_PROVIDER_STORAGE_KEY = "slowclaw.settings.provider";
const CHAT_MODEL_STORAGE_KEY = "slowclaw.settings.model";
const LOCAL_JOURNAL_PATH_PREFIX = "journal://";
const UI_THEME_STORAGE_KEY = "slowclaw.ui.theme";
const UI_TAB_STORAGE_KEY = "slowclaw.ui.tab";

const DESKTOP_SECRET_SERVICE = "social.slowclaw.gateway";
const PROVIDER_API_KEY_SECRET_ACCOUNT = "provider.api_key";
const DEFAULT_RECORDING_HINT = "Ready to add a journal note, audio, or video.";
let blueskyModulePromise: Promise<typeof import("./lib/bluesky")> | null = null;
const QRCodeCanvas = lazy(() => import("qrcode.react").then(m => ({ default: m.QRCodeCanvas })));

type MobileTab = "journal" | "feed" | "productivity" | "profile";
type ThemeMode = "light" | "dark";
type DesktopGatewayBootstrap = {
  token?: string | null;
  gatewayUrl?: string | null;
};

async function loadBlueskyModule() {
  if (!blueskyModulePromise) {
    blueskyModulePromise = import("./lib/bluesky");
  }
  return blueskyModulePromise;
}

function defaultThemeMode(): ThemeMode {
  if (typeof window === "undefined") {
    return "light";
  }
  const saved = window.localStorage.getItem(UI_THEME_STORAGE_KEY);
  if (saved === "light" || saved === "dark") {
    return saved;
  }
  return window.matchMedia?.("(prefers-color-scheme: dark)").matches ? "dark" : "light";
}

function defaultMobileTab(): MobileTab {
  if (typeof window === "undefined") {
    return "journal";
  }
  if (window.innerWidth > 900) {
    return "journal";
  }
  const saved = window.localStorage.getItem(UI_TAB_STORAGE_KEY);
  if (saved === "todos" || saved === "events") {
    return "productivity";
  }
  return saved === "feed" || saved === "productivity" || saved === "profile" ? saved : "journal";
}

function useIsLargeScreen() {
  const [isLarge, setIsLarge] = useState(typeof window !== "undefined" ? window.innerWidth > 900 : false);
  useEffect(() => {
    const handleResize = () => setIsLarge(window.innerWidth > 900);
    window.addEventListener("resize", handleResize);
    return () => window.removeEventListener("resize", handleResize);
  }, []);
  return isLarge;
}

function formatBytes(bytes: number) {
  if (!Number.isFinite(bytes) || bytes <= 0) {
    return "0 B";
  }
  const units = ["B", "KB", "MB", "GB"];
  let value = bytes;
  let index = 0;
  while (value >= 1024 && index < units.length - 1) {
    value /= 1024;
    index += 1;
  }
  return `${value.toFixed(value >= 10 || index === 0 ? 0 : 1)} ${units[index]}`;
}

function formatTimestamp(value?: number | string) {
  if (value == null) {
    return "";
  }
  const date =
    typeof value === "number" ? new Date(value * 1000) : new Date(String(value));
  if (Number.isNaN(date.getTime())) {
    return String(value);
  }
  return date.toLocaleString();
}

function parseDateValue(value?: string | null) {
  if (!value) {
    return null;
  }
  const normalized = String(value).trim();
  const localDateOnly = normalized.match(/^(\d{4})-(\d{2})-(\d{2})$/);
  if (localDateOnly) {
    const [, year, month, day] = localDateOnly;
    return new Date(Number(year), Number(month) - 1, Number(day));
  }
  const parsed = new Date(normalized);
  return Number.isNaN(parsed.getTime()) ? null : parsed;
}

function startOfLocalDay(date: Date) {
  return new Date(date.getFullYear(), date.getMonth(), date.getDate());
}

function isSameLocalDay(a: Date, b: Date) {
  return (
    a.getFullYear() === b.getFullYear() &&
    a.getMonth() === b.getMonth() &&
    a.getDate() === b.getDate()
  );
}

function todoPriorityRank(priority: string) {
  if (priority === "high") {
    return 0;
  }
  if (priority === "medium") {
    return 1;
  }
  return 2;
}

function hasExplicitTime(value?: string | null) {
  return Boolean(value && /[T\s]\d{2}:\d{2}/.test(String(value)));
}

function formatTodoDueLabel(value?: string | null) {
  const due = parseDateValue(value);
  if (!due) {
    return "No due date";
  }
  const showTime = hasExplicitTime(value);
  const now = new Date();
  const today = startOfLocalDay(now);
  const tomorrow = new Date(today);
  tomorrow.setDate(today.getDate() + 1);
  const dueDay = startOfLocalDay(due);
  if ((showTime && due.getTime() < now.getTime()) || (!showTime && dueDay.getTime() < today.getTime())) {
    return showTime
      ? `Overdue · ${due.toLocaleDateString()} · ${due.toLocaleTimeString([], { hour: "numeric", minute: "2-digit" })}`
      : `Overdue · ${due.toLocaleDateString()}`;
  }
  if (dueDay.getTime() === today.getTime()) {
    return showTime
      ? `Due today · ${due.toLocaleTimeString([], { hour: "numeric", minute: "2-digit" })}`
      : "Due today";
  }
  if (dueDay.getTime() === tomorrow.getTime()) {
    return showTime
      ? `Due tomorrow · ${due.toLocaleTimeString([], { hour: "numeric", minute: "2-digit" })}`
      : "Due tomorrow";
  }
  return showTime
    ? `Due ${due.toLocaleDateString()} · ${due.toLocaleTimeString([], { hour: "numeric", minute: "2-digit" })}`
    : `Due ${due.toLocaleDateString()}`;
}

function formatEventTiming(
  startAt: string,
  endAt?: string | null,
  allDay?: boolean
) {
  const start = parseDateValue(startAt);
  const end = parseDateValue(endAt);
  if (!start) {
    return "Time unavailable";
  }
  if (allDay) {
    if (end && !isSameLocalDay(start, end)) {
      return `${start.toLocaleDateString()} -> ${end.toLocaleDateString()} · All day`;
    }
    return `${start.toLocaleDateString()} · All day`;
  }
  const startLabel = `${start.toLocaleDateString()} · ${start.toLocaleTimeString([], {
    hour: "numeric",
    minute: "2-digit"
  })}`;
  if (!end) {
    return startLabel;
  }
  if (isSameLocalDay(start, end)) {
    return `${startLabel} -> ${end.toLocaleTimeString([], { hour: "numeric", minute: "2-digit" })}`;
  }
  return `${startLabel} -> ${end.toLocaleDateString()} · ${end.toLocaleTimeString([], {
    hour: "numeric",
    minute: "2-digit"
  })}`;
}

function workspaceSynthArtifactTone(state?: WorkspaceSynthArtifactState) {
  if (state?.status === "error") {
    return "danger";
  }
  if (state?.status === "applied") {
    return "success";
  }
  return "muted";
}

function workspaceSynthArtifactLabel(name: string, state?: WorkspaceSynthArtifactState) {
  const status = state?.status || "skipped";
  if (status === "applied") {
    return `${name} ${state?.itemCount ?? 0}`;
  }
  if (status === "error") {
    return `${name} error`;
  }
  return `${name} skipped`;
}

function sidecarCaptionPath(item: LibraryItem) {
  return `${item.path}.caption.txt`;
}

function fileStemFromPath(path: string) {
  const filename = path.split("/").pop() || path;
  return filename.replace(/\.[^/.]+$/, "");
}

function inferMediaMimeType(path: string, kind: LibraryItem["kind"], currentType?: string) {
  const normalizedType = String(currentType || "").trim().toLowerCase();
  if (normalizedType && normalizedType !== "application/octet-stream") {
    return normalizedType;
  }

  const normalizedPath = path.toLowerCase();
  if (kind === "audio") {
    if (normalizedPath.endsWith(".mp3")) return "audio/mpeg";
    if (normalizedPath.endsWith(".m4a") || normalizedPath.endsWith(".mp4")) return "audio/mp4";
    if (normalizedPath.endsWith(".aac")) return "audio/aac";
    if (normalizedPath.endsWith(".ogg")) return "audio/ogg";
    if (normalizedPath.endsWith(".wav")) return "audio/wav";
    if (normalizedPath.endsWith(".flac")) return "audio/flac";
    return "audio/webm";
  }
  if (kind === "video") {
    if (normalizedPath.endsWith(".mp4") || normalizedPath.endsWith(".m4v")) return "video/mp4";
    if (normalizedPath.endsWith(".mov")) return "video/quicktime";
    if (normalizedPath.endsWith(".mkv")) return "video/x-matroska";
    return "video/webm";
  }
  if (kind === "image") {
    if (normalizedPath.endsWith(".png")) return "image/png";
    if (normalizedPath.endsWith(".gif")) return "image/gif";
    if (normalizedPath.endsWith(".webp")) return "image/webp";
    if (normalizedPath.endsWith(".svg")) return "image/svg+xml";
    return "image/jpeg";
  }
  return normalizedType || "application/octet-stream";
}

function encodeWavFromFloat32(chunks: Float32Array[], sampleRate: number) {
  const totalSamples = chunks.reduce((sum, chunk) => sum + chunk.length, 0);
  const buffer = new ArrayBuffer(44 + totalSamples * 2);
  const view = new DataView(buffer);

  const writeString = (offset: number, value: string) => {
    for (let i = 0; i < value.length; i += 1) {
      view.setUint8(offset + i, value.charCodeAt(i));
    }
  };

  writeString(0, "RIFF");
  view.setUint32(4, 36 + totalSamples * 2, true);
  writeString(8, "WAVE");
  writeString(12, "fmt ");
  view.setUint32(16, 16, true);
  view.setUint16(20, 1, true);
  view.setUint16(22, 1, true);
  view.setUint32(24, sampleRate, true);
  view.setUint32(28, sampleRate * 2, true);
  view.setUint16(32, 2, true);
  view.setUint16(34, 16, true);
  writeString(36, "data");
  view.setUint32(40, totalSamples * 2, true);

  let offset = 44;
  for (const chunk of chunks) {
    for (let i = 0; i < chunk.length; i += 1) {
      const sample = Math.max(-1, Math.min(1, chunk[i]));
      view.setInt16(
        offset,
        sample < 0 ? Math.round(sample * 0x8000) : Math.round(sample * 0x7fff),
        true
      );
      offset += 2;
    }
  }

  return new Blob([buffer], { type: "audio/wav" });
}

function journalTranscriptPathForMedia(item: LibraryItem) {
  const normalized = item.path.replace(/^\/+/, "");
  if (normalized.startsWith("journals/media/")) {
    const relative = normalized.slice("journals/media/".length);
    const stemmed = relative.replace(/\.[^/.]+$/, ".txt");
    return `journals/text/transcriptions/${stemmed}`;
  }
  return `journals/text/transcriptions/${fileStemFromPath(item.path)}.txt`;
}

function legacyJournalTranscriptPathForMedia(item: LibraryItem) {
  return `journals/text/transcript/${fileStemFromPath(item.path)}.txt`;
}

function localJournalPath(id: string) {
  return `${LOCAL_JOURNAL_PATH_PREFIX}${id}`;
}

function localJournalIdFromPath(path: string) {
  if (!path.startsWith(LOCAL_JOURNAL_PATH_PREFIX)) {
    return null;
  }
  const id = path.slice(LOCAL_JOURNAL_PATH_PREFIX.length).trim();
  return id || null;
}

function createThreadId() {
  if (typeof crypto !== "undefined" && typeof crypto.randomUUID === "function") {
    return crypto.randomUUID();
  }
  return `thread-${Date.now()}-${Math.random().toString(36).slice(2, 10)}`;
}

function isTauriDesktopRuntime() {
  if (typeof window === "undefined") {
    return false;
  }
  return Boolean((window as any).__TAURI_INTERNALS__);
}

function isTauriMobileRuntime() {
  if (typeof window === "undefined") {
    return false;
  }
  return (
    Boolean((window as any).__TAURI_MOBILE__) ||
    /iphone|ipad|android/i.test(window.navigator.userAgent || "")
  );
}

function defaultGatewayBaseUrl() {
  if (typeof window === "undefined") {
    return "http://127.0.0.1:42617";
  }
  const saved = window.localStorage.getItem(CHAT_GATEWAY_BASE_URL_STORAGE_KEY);
  if (saved && saved.trim()) {
    return saved.trim().replace(/\/+$/, "");
  }
  const protocol = window.location.protocol === "https:" ? "https:" : "http:";
  const host = window.location.hostname || "127.0.0.1";
  return `${protocol}//${host}:42617`;
}

function normalizeGatewayToken(value: string) {
  const token = value.trim();
  return token === "desktop-local" ? "" : token;
}

function isMissingDesktopCommand(error: unknown, commandName?: string) {
  const message = String(
    error instanceof Error ? error.message : error ?? ""
  ).toLowerCase();
  if (!message) {
    return false;
  }
  if (commandName) {
    return message.includes(`command ${commandName.toLowerCase()} not found`);
  }
  return message.includes("command") && message.includes("not found");
}

function resolveGatewayResourceUrl(resourcePath: string, gatewayBaseUrl: string) {
  if (!resourcePath) {
    return resourcePath;
  }
  if (resourcePath.startsWith("http://") || resourcePath.startsWith("https://")) {
    return resourcePath;
  }
  const base = gatewayBaseUrl.trim().replace(/\/+$/, "");
  const suffix = resourcePath.startsWith("/") ? resourcePath : `/${resourcePath}`;
  return `${base}${suffix}`;
}

type WorkflowBotMeta = {
  key: string;
  name: string;
  avatar: string;
  outputPrefix: string;
  goal: string;
  kind: "workflow" | "synth_skill";
};

type WorkflowSettingsDraft = {
  goal: string;
};

type WorkflowRunStatus = {
  workflowKey: string;
  workflowBot: string;
  status: "pending" | "processing" | "done" | "error";
  summary: string;
  detail: string;
  updatedAt: string;
  runMessageId: string;
};

type WorkflowTemplateDraft = {
  name: string;
  goal: string;
  runNow: boolean;
};

function workflowBotByKey(key: string): WorkflowBotMeta {
  const trimmed = key.trim();
  const name = trimmed
    .split("_")
    .filter(Boolean)
    .map((token) => `${token.slice(0, 1).toUpperCase()}${token.slice(1)}`)
    .join(" ");
  const displayName = name || "Content Agent";
  const avatar = displayName.slice(0, 1).toUpperCase() || "W";
  return {
    key: trimmed,
    name: displayName,
    avatar,
    outputPrefix: `posts/${trimmed}/`,
    goal: "",
    kind: "workflow"
  };
}

function workflowBotMetaFromSettings(item: FeedContentAgentItem): WorkflowBotMeta {
  const fallback = workflowBotByKey(item.workflowKey);
  const workflowBot = String(item.workflowBot || "").trim();
  const outputPrefix = String(item.outputPrefix || "").trim();
  return {
    key: item.workflowKey,
    name: workflowBot || fallback.name,
    avatar: (workflowBot || fallback.name).slice(0, 1).toUpperCase() || fallback.avatar,
    outputPrefix: outputPrefix || fallback.outputPrefix,
    goal: String(item.goal || "").trim(),
    kind: "workflow"
  };
}

function workflowBotMetaFromSynthSkill(item: WorkspaceSynthSkillItem): WorkflowBotMeta {
  const fallback = workflowBotByKey(item.skillKey);
  const name = String(item.name || "").trim();
  const outputPrefix = String(item.outputPrefix || "").trim();
  return {
    key: item.skillKey,
    name: name || fallback.name,
    avatar: (name || fallback.name).slice(0, 1).toUpperCase() || fallback.avatar,
    outputPrefix: outputPrefix || fallback.outputPrefix,
    goal: String(item.goal || "").trim(),
    kind: "synth_skill"
  };
}

const WORKFLOW_RUN_SOURCES = new Set([
  "workflow-settings-save",
  "workflow-run-manual",
  "workflow-template-create",
  "workflow-quickfix"
]);

function defaultWorkflowTemplateDraft(): WorkflowTemplateDraft {
  return {
    name: "",
    goal: "",
    runNow: true
  };
}

function workflowSettingsDraftFromItem(item: FeedContentAgentItem): WorkflowSettingsDraft {
  return {
    goal: String(item.goal || "").trim()
  };
}

function workflowBotForPath(path: string, bots: WorkflowBotMeta[]): WorkflowBotMeta | null {
  const normalized = path.trim().toLowerCase();
  if (normalized.startsWith("posts/workspace_synthesizer/")) {
    const synthInsight =
      bots.find((bot) => bot.kind === "synth_skill" && bot.key === "workspace_insight_extractor") ||
      bots.find((bot) => bot.kind === "synth_skill" && bot.outputPrefix.trim().toLowerCase() === "posts/workspace_synthesizer/");
    if (synthInsight) {
      return synthInsight;
    }
  }
  for (const bot of bots) {
    const prefix = bot.outputPrefix.trim().toLowerCase().replace(/^\/+/, "");
    if (!prefix) {
      continue;
    }
    if (normalized.startsWith(prefix)) {
      return bot;
    }
  }
  return null;
}

function parseWorkflowRunStatus(
  bot: WorkflowBotMeta,
  messages: ClawChatMessage[]
): WorkflowRunStatus | undefined {
  if (!messages.length) {
    return undefined;
  }

  let runMsg: ClawChatMessage | undefined;
  for (let i = messages.length - 1; i >= 0; i -= 1) {
    const msg = messages[i];
    if (
      msg.role === "user" &&
      msg.content.startsWith("[run]") &&
      msg.source &&
      WORKFLOW_RUN_SOURCES.has(msg.source)
    ) {
      runMsg = msg;
      break;
    }
  }
  if (!runMsg) {
    return undefined;
  }

  let replyMsg: ClawChatMessage | undefined;
  for (let i = messages.length - 1; i >= 0; i -= 1) {
    const msg = messages[i];
    if (msg.role === "assistant" && msg.replyToId === runMsg.id) {
      replyMsg = msg;
      break;
    }
  }

  let status: WorkflowRunStatus["status"] = "pending";
  const runStatus = String(runMsg.status || "").toLowerCase();
  const replyStatus = String(replyMsg?.status || "").toLowerCase();
  if (runStatus === "processing") {
    status = "processing";
  } else if (runStatus === "error" || replyStatus === "error" || replyMsg?.error) {
    status = "error";
  } else if (runStatus === "done") {
    status = "done";
  }

  let summary = `${bot.name} run queued`;
  if (status === "processing") {
    summary = `${bot.name} is running...`;
  } else if (status === "error") {
    summary = `${bot.name} run failed`;
  } else if (status === "done") {
    summary = `${bot.name} run completed`;
  }

  const detailSource = replyMsg?.error || replyMsg?.content || runMsg.error || runMsg.content || "";
  const detail = detailSource.trim().slice(0, 1200);
  const updatedAt = replyMsg?.updated || replyMsg?.created || runMsg.updated || runMsg.created || "";

  return {
    workflowKey: bot.key,
    workflowBot: bot.name,
    status,
    summary,
    detail,
    updatedAt,
    runMessageId: runMsg.id
  };
}

function splitUrlAndSuffix(raw: string) {
  const match = raw.match(/^(.*?)([),.!?:;'"]*)$/);
  if (!match) {
    return { url: raw, suffix: "" };
  }
  return { url: match[1], suffix: match[2] };
}

function renderLinkedText(text: string) {
  if (!text) {
    return "";
  }
  const parts = text.split(/(https?:\/\/[^\s]+)/g);
  return parts.map((part, idx) => {
    if (!part) {
      return null;
    }
    if (!/^https?:\/\//i.test(part)) {
      return <span key={`txt-${idx}`}>{part}</span>;
    }
    const { url, suffix } = splitUrlAndSuffix(part);
    if (!/^https?:\/\//i.test(url)) {
      return <span key={`txt-${idx}`}>{part}</span>;
    }
    return (
      <span key={`txt-${idx}`}>
        <a href={url} target="_blank" rel="noreferrer">
          {url}
        </a>
        {suffix}
      </span>
    );
  });
}

function renderBlueskyEmbed(embed: any) {
  if (!embed || !embed.$type) {
    return null;
  }
  if (embed.$type === "app.bsky.embed.images#view") {
    const images = Array.isArray(embed.images) ? embed.images : [];
    if (!images.length) {
      return null;
    }
    return (
      <div className="bluesky-embed-grid">
        {images.map((img: any, i: number) => (
          <img
            key={`img-${i}`}
            src={img.thumb || img.fullsize}
            alt={img.alt || "Embedded image"}
            className="bluesky-embed-image"
          />
        ))}
      </div>
    );
  }
  if (embed.$type === "app.bsky.embed.video#view") {
    const playlist = String(embed.playlist || "").trim();
    const thumbnail = String(embed.thumbnail || "").trim();
    if (!playlist && !thumbnail) {
      return null;
    }
    return (
      <div className="bluesky-embed-video-wrap">
        {playlist ? (
          <video
            className="bluesky-embed-video"
            controls
            preload="metadata"
            playsInline
            poster={thumbnail || undefined}
            src={playlist}
          />
        ) : (
          <img src={thumbnail} alt="Video preview" className="bluesky-embed-image" />
        )}
      </div>
    );
  }
  if (embed.$type === "app.bsky.embed.external#view") {
    const external = embed.external || {};
    const uri = String(external.uri || "").trim();
    if (!uri) {
      return null;
    }
    return (
      <a href={uri} target="_blank" rel="noreferrer" className="bluesky-external-card">
        {external.thumb ? (
          <img src={String(external.thumb)} alt={String(external.title || "Link preview")} className="bluesky-external-thumb" />
        ) : null}
        <div className="bluesky-external-body">
          <div className="bluesky-external-title">{String(external.title || uri)}</div>
          {external.description ? (
            <div className="bluesky-external-desc">{String(external.description)}</div>
          ) : null}
          <div className="bluesky-external-domain">
            {(() => {
              try {
                return new URL(uri).hostname;
              } catch {
                return uri;
              }
            })()}
          </div>
        </div>
      </a>
    );
  }
  if (embed.$type === "app.bsky.embed.recordWithMedia#view") {
    return renderBlueskyEmbed(embed.media);
  }
  return null;
}

function normalizeArticleText(text: string) {
  return text.replace(/\r/g, "").replace(/\n{3,}/g, "\n\n").trim();
}

function summarizeArticleText(text: string, maxLength = 360) {
  const normalized = normalizeArticleText(text).replace(/\s+/g, " ").trim();
  if (!normalized) {
    return "";
  }
  if (normalized.length <= maxLength) {
    return normalized;
  }
  return `${normalized.slice(0, maxLength - 3).trimEnd()}...`;
}

function hasInlineVideoUrl(text: string) {
  return /(https?:\/\/[^\s]+\.(mp4|webm|mov|m3u8))|video\.|youtu\.?be|vimeo/i.test(text);
}

function App() {
  const isDesktopClient = isTauriDesktopRuntime();
  const isLargeScreen = useIsLargeScreen();
  const isDesktopLayout = isDesktopClient || isLargeScreen;
  const [gatewayBaseUrl, setGatewayBaseUrl] = useState(defaultGatewayBaseUrl);
  const [creds, setCreds] = useState<BlueskyCredentials>(() => loadCredentialsFallback());
  const [agent, setAgent] = useState<AtpAgent | null>(null);
  const [session, setSession] = useState<BlueskySession | null>(null);
  const [authMessage, setAuthMessage] = useState<string>("");
  const [secureStoreReady, setSecureStoreReady] = useState(false);
  const [text, setText] = useState("");
  const [videoFile, setVideoFile] = useState<File | null>(null);
  const [videoAlt, setVideoAlt] = useState("");
  const [isPosting, setIsPosting] = useState(false);
  const [status, setStatus] = useState<string>("");
  const [drafts, setDrafts] = useState<StoredDraft[]>([]);
  const [history, setHistory] = useState<PostHistoryItem[]>([]);
  const postedPathsSet = new Set(
    history
      .filter((h) => h.status === "success" && h.sourcePath)
      .map((h) => h.sourcePath as string)
  );
  const isPathPosted = (path: string) => postedPathsSet.has(path);
  const [chatThreadId, setChatThreadId] = useState<string>(() => {
    if (typeof window === "undefined") {
      return "";
    }
    const saved = window.localStorage.getItem(CHAT_THREAD_STORAGE_KEY);
    return saved && saved.trim() ? saved.trim() : "";
  });
  const [chatInput, setChatInput] = useState("");
  const [chatMessages, setChatMessages] = useState<ClawChatMessage[]>([]);
  const [chatStatus, setChatStatus] = useState("Chat idle");
  const [chatSending, setChatSending] = useState(false);
  const [chatGatewayToken, setChatGatewayToken] = useState<string>(() => {
    if (typeof window === "undefined") {
      return "";
    }
    return window.localStorage.getItem(CHAT_GATEWAY_TOKEN_STORAGE_KEY) || "";
  });
  const [syncPeerGatewayUrl, setSyncPeerGatewayUrl] = useState<string>(() => {
    if (typeof window === "undefined") {
      return "";
    }
    return window.localStorage.getItem(SYNC_PEER_GATEWAY_BASE_URL_STORAGE_KEY) || "";
  });
  const [syncPeerToken, setSyncPeerToken] = useState<string>(() => {
    if (typeof window === "undefined") {
      return "";
    }
    return window.localStorage.getItem(SYNC_PEER_GATEWAY_TOKEN_STORAGE_KEY) || "";
  });
  const [syncStatus, setSyncStatus] = useState("");
  const [syncBusy, setSyncBusy] = useState(false);
  const [syncScannerActive, setSyncScannerActive] = useState(false);
  const [desktopQrLoading, setDesktopQrLoading] = useState(false);
  const [desktopQrPayload, setDesktopQrPayload] = useState<GatewayQrPayload | null>(null);
  const [desktopQrStatus, setDesktopQrStatus] = useState("");
  const [themeMode, setThemeMode] = useState<ThemeMode>(defaultThemeMode);
  const [mobileTab, setMobileTab] = useState<MobileTab>(defaultMobileTab);
  const [journalSidebarOpen, setJournalSidebarOpen] = useState(false);
  const [journalDesktopSidebarCollapsed, setJournalDesktopSidebarCollapsed] = useState(false);
  const [feedSidebarOpen, setFeedSidebarOpen] = useState(false);
  const [feedCreateWorkflowOpen, setFeedCreateWorkflowOpen] = useState(false);
  const [journalItems, setJournalItems] = useState<LibraryItem[]>([]);
  const [journalSearchQuery, setJournalSearchQuery] = useState("");
  const [journalSidebarStatus, setJournalSidebarStatus] = useState("");
  const [feedItems, setFeedItems] = useState<LibraryItem[]>([]);
  const [libraryStatus, setLibraryStatus] = useState("Library idle");
  const [selectedJournalPath, setSelectedJournalPath] = useState<string>("");
  const [selectedFeedPath, setSelectedFeedPath] = useState<string>("");
  const [selectedJournalItem, setSelectedJournalItem] = useState<LibraryItem | null>(null);
  const [selectedFeedItem, setSelectedFeedItem] = useState<LibraryItem | null>(null);
  const [selectedJournalText, setSelectedJournalText] = useState("");
  const [selectedFeedText, setSelectedFeedText] = useState("");
  const [journalDraftText, setJournalDraftText] = useState("");
  const [journalSaveStatus, setJournalSaveStatus] = useState("Journal idle");
  const [pendingDeleteJournalItem, setPendingDeleteJournalItem] = useState<LibraryItem | null>(null);
  const [pendingDeleteFeedItem, setPendingDeleteFeedItem] = useState<LibraryItem | null>(null);
  const [journalTranscribing, setJournalTranscribing] = useState(false);
  const [journalTranscriptionStatusByPath, setJournalTranscriptionStatusByPath] = useState<
    Record<string, "idle" | "queued" | "running" | "done" | "error">
  >({});
  const [isWritingNote, setIsWritingNote] = useState(false);
  const [feedCaptionText, setFeedCaptionText] = useState("");
  const [feedCaptionPath, setFeedCaptionPath] = useState<string>("");
  const [feedEditStatus, setFeedEditStatus] = useState("Feed idle");
  const [feedDraftsByPath, setFeedDraftsByPath] = useState<Record<string, string>>({});
  const [feedDraftSourceByPath, setFeedDraftSourceByPath] = useState<Record<string, string>>({});
  const [feedDraftLoadingByPath, setFeedDraftLoadingByPath] = useState<Record<string, boolean>>({});
  const [activeFeedCommentPath, setActiveFeedCommentPath] = useState("");
  const [feedCommentDrafts, setFeedCommentDrafts] = useState<Record<string, string>>({});
  const [feedCommentStatusByPath, setFeedCommentStatusByPath] = useState<Record<string, string>>(
    {}
  );
  const [submittingFeedCommentPath, setSubmittingFeedCommentPath] = useState("");
  const [activeWorkflowBotKey, setActiveWorkflowBotKey] = useState<string>("");
  const [workflowBots, setWorkflowBots] = useState<WorkflowBotMeta[]>([]);
  const [workflowSettingsByKey, setWorkflowSettingsByKey] = useState<
    Record<string, FeedContentAgentItem | undefined>
  >({});
  const [workspaceSynthSkillItems, setWorkspaceSynthSkillItems] = useState<WorkspaceSynthSkillItem[]>([]);
  const [workspaceSynthSkillBots, setWorkspaceSynthSkillBots] = useState<WorkflowBotMeta[]>([]);
  const [workspaceSynthSkillsByKey, setWorkspaceSynthSkillsByKey] = useState<
    Record<string, WorkspaceSynthSkillItem | undefined>
  >({});
  const [activeWorkspaceSynthSkillKey, setActiveWorkspaceSynthSkillKey] = useState("");
  const [workspaceSynthSkillDraftByKey, setWorkspaceSynthSkillDraftByKey] = useState<
    Record<string, string | undefined>
  >({});
  const [workspaceSynthSkillSaveStatusByKey, setWorkspaceSynthSkillSaveStatusByKey] = useState<
    Record<string, string | undefined>
  >({});
  const [workspaceSynthSkillSavingKey, setWorkspaceSynthSkillSavingKey] = useState("");
  const [workflowSettingsDraftByKey, setWorkflowSettingsDraftByKey] = useState<
    Record<string, WorkflowSettingsDraft | undefined>
  >({});
  const [workflowSettingsStatusByKey, setWorkflowSettingsStatusByKey] = useState<
    Record<string, string>
  >({});
  const [workflowSettingsLoading, setWorkflowSettingsLoading] = useState(false);
  const [workflowSettingsSavingKey, setWorkflowSettingsSavingKey] = useState("");
  const [workflowRunStatusByKey, setWorkflowRunStatusByKey] = useState<
    Record<string, WorkflowRunStatus | undefined>
  >({});
  const [workflowTemplateDraft, setWorkflowTemplateDraft] = useState<WorkflowTemplateDraft>(
    defaultWorkflowTemplateDraft
  );
  const [workflowTemplateSubmitting, setWorkflowTemplateSubmitting] = useState(false);
  const [workflowTemplateStatus, setWorkflowTemplateStatus] = useState("");
  const [workflowToggleBusyKey, setWorkflowToggleBusyKey] = useState("");
  const [workspaceSynthSkillToggleBusyKey, setWorkspaceSynthSkillToggleBusyKey] = useState("");
  const [recordingHint, setRecordingHint] = useState(DEFAULT_RECORDING_HINT);
  const [mediaPreviewUrl, setMediaPreviewUrl] = useState<string>("");
  const [mediaPreviewMime, setMediaPreviewMime] = useState<string>("");
  const [mediaPreviewLoading, setMediaPreviewLoading] = useState(false);
  const [postingFeedPath, setPostingFeedPath] = useState<string>("");
  const [feedPostedSectionOpen, setFeedPostedSectionOpen] = useState(false);
  const [postProgress, setPostProgress] = useState<{
    path: string;
    percent: number;
    label: string;
  } | null>(null);
  const [aiSetupStatus, setAiSetupStatus] = useState<OpenAiDeviceCodeStatus | null>(null);
  const [aiSetupBusy, setAiSetupBusy] = useState(false);
  const [aiSetupBrowserStatus, setAiSetupBrowserStatus] = useState("");
  const [claudeToken, setClaudeToken] = useState("");
  const [claudeTokenStatus, setClaudeTokenStatus] = useState<AnthropicTokenStatus | null>(null);
  const [claudeTokenBusy, setClaudeTokenBusy] = useState(false);
  const [openrouterOAuthBusy, setOpenrouterOAuthBusy] = useState(false);
  const [openrouterOAuthStatus, setOpenrouterOAuthStatus] = useState("");
  const [openrouterApiKeyInput, setOpenrouterApiKeyInput] = useState("");
  const [providerApiKey, setProviderApiKey] = useState("");
  const [providerApiKeyStatus, setProviderApiKeyStatus] = useState("");
  const [settingsProvider, setSettingsProvider] = useState("");
  const [settingsModel, setSettingsModel] = useState("");
  const [settingsTranscriptionEnabled, setSettingsTranscriptionEnabled] = useState(false);
  const [settingsTranscriptionModel, setSettingsTranscriptionModel] = useState("");
  const [settingsAvailableTranscriptionModels, setSettingsAvailableTranscriptionModels] = useState<string[]>([]);
  const [runtimeMediaCapabilities, setRuntimeMediaCapabilities] = useState<MediaCapabilities | null>(null);
  const [runtimeMediaSummary, setRuntimeMediaSummary] = useState("");
  const [settingsConfigBusy, setSettingsConfigBusy] = useState(false);
  const [settingsConfigStatus, setSettingsConfigStatus] = useState("");
  const [settingsConfigLoaded, setSettingsConfigLoaded] = useState(false);
  const [mobileScannerActive, setMobileScannerActive] = useState(() => {
    if (typeof window === "undefined") {
      return false;
    }
    if (isTauriDesktopRuntime()) {
      return false;
    }
    const savedToken = window.localStorage.getItem(CHAT_GATEWAY_TOKEN_STORAGE_KEY) || "";
    const savedGateway = window.localStorage.getItem(CHAT_GATEWAY_BASE_URL_STORAGE_KEY) || "";
    return !(savedToken.trim() && savedGateway.trim());
  });
  const [mobileScannerStatus, setMobileScannerStatus] = useState(
    "Scan the desktop QR to connect."
  );
  const [mobileCameraPermissionError, setMobileCameraPermissionError] = useState("");
  const autosaveTimerRef = useRef<number | null>(null);
  const journalAutosaveTimerRef = useRef<number | null>(null);
  const journalStatusTimerRef = useRef<number | null>(null);
  const journalSidebarStatusTimerRef = useRef<number | null>(null);
  const feedAutosaveTimersRef = useRef<Record<string, number>>({});
  const feedDraftLoadingRef = useRef<Record<string, boolean>>({});
  const aiSetupAutoOpenedUrlRef = useRef("");
  const loadedTextPathRef = useRef<string>("");
  const loadedCaptionPathRef = useRef<string>("");
  const activeTranscriptionPollRef = useRef<Record<string, GatewayEventStreamHandle | undefined>>({});
  const selectedJournalPathRef = useRef<string>("");
  const journalLoadRequestRef = useRef(0);
  const openedJournalPathRef = useRef("");
  const mobileScannerVideoRef = useRef<HTMLVideoElement | null>(null);
  const mobileScannerStreamRef = useRef<MediaStream | null>(null);
  const mobileScannerRafRef = useRef<number | null>(null);
  const workflowPollAbortRef = useRef<GatewayEventStreamHandle | null>(null);
  const chatThreadStreamRef = useRef<GatewayEventStreamHandle | null>(null);
  const workspaceSynthStreamRef = useRef<GatewayEventStreamHandle | null>(null);

  // Recording State
  const [isRecording, setIsRecording] = useState(false);
  const [captureMode, setCaptureMode] = useState<"audio" | "video" | null>(null);
  const [recordingType, setRecordingType] = useState<"audio" | "video" | null>(null);
  const [recordingTime, setRecordingTime] = useState(0);
  const [videoOrientation, setVideoOrientation] = useState<"vertical" | "horizontal">("vertical");
  const [audioDevices, setAudioDevices] = useState<MediaDeviceInfo[]>([]);
  const [selectedAudioDeviceId, setSelectedAudioDeviceId] = useState<string>("");
  const mediaRecorderRef = useRef<MediaRecorder | null>(null);
  const mediaStreamRef = useRef<MediaStream | null>(null);
  const recordingChunksRef = useRef<BlobPart[]>([]);
  const recordingTimerRef = useRef<number | null>(null);
  const videoPreviewRef = useRef<HTMLVideoElement | null>(null);
  const audioCanvasRef = useRef<HTMLCanvasElement | null>(null);
  const audioContextRef = useRef<AudioContext | null>(null);
  const audioProcessorRef = useRef<ScriptProcessorNode | null>(null);
  const audioCaptureGainRef = useRef<GainNode | null>(null);
  const audioPcmChunksRef = useRef<Float32Array[]>([]);
  const audioSampleRateRef = useRef(44_100);
  const usingWavAudioCaptureRef = useRef(false);
  const analyserRef = useRef<AnalyserNode | null>(null);
  const syntheticAudioVizRef = useRef<boolean>(false);
  const animationFrameRef = useRef<number | null>(null);

  useEffect(() => {
    selectedJournalPathRef.current = selectedJournalPath;
  }, [selectedJournalPath]);

  // Bluesky Feed State
  const [feedSource, setFeedSource] = useState<"local" | "bluesky">("local");
  const [workspaceTodos, setWorkspaceTodos] = useState<WorkspaceTodoItem[]>([]);
  const [workspaceEvents, setWorkspaceEvents] = useState<WorkspaceEventItem[]>([]);
  const [workspaceSynthStatus, setWorkspaceSynthStatus] = useState<WorkspaceSynthesizerStatus>({
    status: "idle"
  });
  const [workspaceSynthBusy, setWorkspaceSynthBusy] = useState(false);
  const [blueskyFeedItems, setBlueskyFeedItems] = useState<PersonalizedFeedItem[]>([]);
  const [blueskyFeedLoading, setBlueskyFeedLoading] = useState(false);
  const [blueskyFeedStatus, setBlueskyFeedStatus] = useState("");
  const [blueskyFeedSnapshot, setBlueskyFeedSnapshot] = useState<PersonalizedFeedResponse | null>(null);
  const [worldFeedInterests, setWorldFeedInterests] = useState<WorldFeedInterestItem[]>([]);
  const [worldFeedInterestsLoading, setWorldFeedInterestsLoading] = useState(false);
  const [worldFeedInterestStatus, setWorldFeedInterestStatus] = useState("");
  const [worldFeedSampleIndexByProtocol, setWorldFeedSampleIndexByProtocol] = useState({
    rss: 0,
    nostr: 0,
    bluesky: 0
  });
  const [worldFeedDummyLabel, setWorldFeedDummyLabel] = useState(
    "Open protocols, developer tools, startups, AI products"
  );
  const [editingInterestId, setEditingInterestId] = useState<string | null>(null);
  const [editingInterestKeywords, setEditingInterestKeywords] = useState("");
  const [blueskyProfileStats, setBlueskyProfileStats] = useState<InterestProfileStats>({
    interestCount: 0,
    sourceCount: 0,
    refreshedSources: 0,
    mergedCount: 0,
    spawnedCount: 0,
    ignoredCount: 0,
  });
  const workspaceTabActive =
    mobileTab === "productivity" ||
    (mobileTab === "feed" && feedSource === "local");
  const workspaceSynthArtifacts = [
    { key: "posts", label: "Posts", state: workspaceSynthStatus.artifactStates?.insightPosts },
    { key: "todos", label: "Todos", state: workspaceSynthStatus.artifactStates?.todos },
    { key: "events", label: "Events", state: workspaceSynthStatus.artifactStates?.events },
    { key: "clips", label: "Clips", state: workspaceSynthStatus.artifactStates?.clipPlans }
  ];
  const workspaceSynthArtifactBadges = workspaceSynthArtifacts.map((artifact) => ({
    key: artifact.key,
    label: workspaceSynthArtifactLabel(artifact.label, artifact.state),
    toneClassName: workspaceSynthArtifactTone(artifact.state),
    title: artifact.state?.error || artifact.state?.path || ""
  }));
  const workspaceSynthRunning =
    workspaceSynthStatus.status === "pending" || workspaceSynthStatus.status === "processing";
  const workspaceSynthProviderBlockedReason = workspaceSynthStatus.providerBlockedReason?.trim() || "";
  const workspaceSynthProviderReady =
    workspaceSynthStatus.providerReady !== false && !workspaceSynthProviderBlockedReason;
  const workspaceSynthPendingCount = Number(workspaceSynthStatus.pendingSourceCount || 0);
  const workspaceSynthSelectedCount = workspaceSynthStatus.selectedSourcePaths?.length || 0;
  const feedAttributedBots = [...workspaceSynthSkillBots, ...workflowBots];

  // Bluesky interaction state
  const [blueskyLikedUris, setBlueskyLikedUris] = useState<Record<string, string>>({});
  const [expandedThreadUri, setExpandedThreadUri] = useState("");
  const [threadData, setThreadData] = useState<any>(null);
  const [threadLoading, setThreadLoading] = useState(false);
  const [replyDrafts, setReplyDrafts] = useState<Record<string, string>>({});
  const [replyingUri, setReplyingUri] = useState("");

  // World feed sub-tabs & Me feed sub-tabs
  const [worldFeedTab, setWorldFeedTab] = useState<"tweets" | "articles" | "videos">("tweets");
  const [videoFallbackItems, setVideoFallbackItems] = useState<any[]>([]);
  const [videoFallbackLoading, setVideoFallbackLoading] = useState(false);
  const [meFeedTab, setMeFeedTab] = useState<"drafts" | "published">("drafts");
  const [expandedArticleUrl, setExpandedArticleUrl] = useState("");

  // Nostr identity
  const [nostrKeys, setNostrKeys] = useState<NostrKeys | null>(null);
  const [nostrKeysBusy, setNostrKeysBusy] = useState(false);

  // Progressive feed: generation-based polling
  const [feedGeneration, setFeedGeneration] = useState<number | undefined>(undefined);
  const [feedNewPostsBanner, setFeedNewPostsBanner] = useState(false);
  const feedPollTimerRef = useRef<number | undefined>(undefined);
  const pendingFeedItemsRef = useRef<PersonalizedFeedResponse | null>(null);

  useEffect(() => {
    let cancelled = false;
    (async () => {
      const secureCreds = await loadCredentialsSecure();
      if (!cancelled && secureCreds) {
        setCreds(secureCreds);
        if (secureCreds.handle.trim() && secureCreds.appPassword.trim()) {
          try {
            const bluesky = await loadBlueskyModule();
            const { agent: autoAgent, session: autoSession } = await bluesky.loginBluesky(secureCreds);
            if (!cancelled) {
              setAgent(autoAgent);
              setSession(autoSession);
              await saveBlueskySessionSecure(autoSession);
              setAuthMessage(`Signed in as ${autoSession.handle}`);
            }
          } catch {
            // Bluesky login is optional; keep app booting without it.
          }
        }
      }
      // Load Nostr keys
      const storedNostrKeys = await loadNostrKeysSecure();
      if (!cancelled && storedNostrKeys) {
        setNostrKeys(storedNostrKeys);
      }
      if (!cancelled && isDesktopClient) {
        const secureGatewayToken = await loadGatewayTokenSecure();
        if (secureGatewayToken) {
          setChatGatewayToken(secureGatewayToken);
        } else {
          await syncDesktopGatewayBootstrap();
        }
        const secureSyncPeerUrl = await loadSyncPeerUrlSecure();
        const secureSyncPeerToken = await loadSyncPeerTokenSecure();
        if (secureSyncPeerUrl) {
          setSyncPeerGatewayUrl(secureSyncPeerUrl);
        }
        if (secureSyncPeerToken) {
          setSyncPeerToken(secureSyncPeerToken);
        }
        const apiKeySecret = await invokeDesktopCommand<{ value: string | null }>("get_secret", {
          req: { service: DESKTOP_SECRET_SERVICE, account: PROVIDER_API_KEY_SECRET_ACCOUNT }
        });
        if (apiKeySecret?.value) {
          setProviderApiKey(apiKeySecret.value);
          setProviderApiKeyStatus("Loaded saved API key");
        }
      }
      if (!cancelled) {
        setSecureStoreReady(true);
        if (isDesktopClient) {
          invokeDesktopCommand("show_main_window").catch(() => { });
        }
      }
    })();
    return () => {
      cancelled = true;
    };
  }, []);

  useEffect(() => {
    if (!secureStoreReady) {
      return;
    }
    void saveCredentialsSecure(creds);
  }, [creds, secureStoreReady]);

  useEffect(() => {
    if (typeof window === "undefined") {
      return;
    }
    window.localStorage.setItem(CHAT_THREAD_STORAGE_KEY, chatThreadId);
  }, [chatThreadId]);

  useEffect(() => {
    if (typeof window === "undefined") {
      return;
    }
    const normalized = chatGatewayToken.trim();
    window.localStorage.setItem(CHAT_GATEWAY_TOKEN_STORAGE_KEY, normalized);
    if (isDesktopClient && normalized) {
      void saveGatewayTokenSecure(normalized);
    }
  }, [chatGatewayToken, isDesktopClient]);

  useEffect(() => {
    if (typeof window === "undefined") {
      return;
    }
    const normalized = syncPeerGatewayUrl.trim().replace(/\/+$/, "");
    window.localStorage.setItem(SYNC_PEER_GATEWAY_BASE_URL_STORAGE_KEY, normalized);
    if (isDesktopClient && normalized) {
      void saveSyncPeerUrlSecure(normalized);
    }
  }, [syncPeerGatewayUrl, isDesktopClient]);

  useEffect(() => {
    if (typeof window === "undefined") {
      return;
    }
    const normalized = syncPeerToken.trim();
    window.localStorage.setItem(SYNC_PEER_GATEWAY_TOKEN_STORAGE_KEY, normalized);
    if (isDesktopClient && normalized) {
      void saveSyncPeerTokenSecure(normalized);
    }
  }, [syncPeerToken, isDesktopClient]);

  useEffect(() => {
    if (typeof window === "undefined") {
      return;
    }
    const normalized = gatewayBaseUrl.trim().replace(/\/+$/, "");
    window.localStorage.setItem(CHAT_GATEWAY_BASE_URL_STORAGE_KEY, normalized);
  }, [gatewayBaseUrl]);

  useEffect(() => {
    if (!isDesktopClient || chatGatewayToken.trim()) {
      return;
    }
    let cancelled = false;
    const run = async () => {
      if (cancelled) {
        return;
      }
      await syncDesktopGatewayBootstrap();
    };
    void run();
    const timer = window.setInterval(() => {
      void run();
    }, 1200);
    return () => {
      cancelled = true;
      window.clearInterval(timer);
    };
  }, [isDesktopClient, chatGatewayToken]);

  useEffect(() => {
    if (typeof document !== "undefined") {
      document.documentElement.dataset.theme = themeMode;
    }
    if (typeof window !== "undefined") {
      window.localStorage.setItem(UI_THEME_STORAGE_KEY, themeMode);
    }
  }, [themeMode]);

  useEffect(() => {
    if (typeof window !== "undefined") {
      window.localStorage.setItem(UI_TAB_STORAGE_KEY, mobileTab);
    }
  }, [mobileTab]);

  useEffect(() => {
    if (isDesktopLayout && mobileTab === "journal") {
      setJournalSidebarOpen(true);
    }
  }, [isDesktopLayout, mobileTab]);

  useEffect(() => {
    return () => {
      if (mediaPreviewUrl) {
        URL.revokeObjectURL(mediaPreviewUrl);
      }
      if (autosaveTimerRef.current) {
        window.clearTimeout(autosaveTimerRef.current);
      }
      if (journalStatusTimerRef.current) {
        window.clearTimeout(journalStatusTimerRef.current);
      }
      if (journalSidebarStatusTimerRef.current) {
        window.clearTimeout(journalSidebarStatusTimerRef.current);
      }
      workflowPollAbortRef.current?.close();
      chatThreadStreamRef.current?.close();
      workspaceSynthStreamRef.current?.close();
      Object.values(activeTranscriptionPollRef.current).forEach((handle) => handle?.close());
    };
  }, [mediaPreviewUrl]);

  function holdJournalStatus(message: string, holdMs: number = 2500) {
    setJournalSaveStatus(message);
    if (journalStatusTimerRef.current) {
      window.clearTimeout(journalStatusTimerRef.current);
    }
    journalStatusTimerRef.current = window.setTimeout(() => {
      setJournalSaveStatus((current) => (current === message ? "Journal idle" : current));
    }, holdMs);
  }

  function holdJournalSidebarStatus(message: string, holdMs: number = 2500) {
    setJournalSidebarStatus(message);
    if (journalSidebarStatusTimerRef.current) {
      window.clearTimeout(journalSidebarStatusTimerRef.current);
    }
    journalSidebarStatusTimerRef.current = window.setTimeout(() => {
      setJournalSidebarStatus((current) => (current === message ? "" : current));
    }, holdMs);
  }

  async function refreshLibrary(scope: "journal" | "feed" | "all") {
    const refreshLocalJournalLibrary = async () => {
      const entries = await listJournals(300, 0);
      const items: LibraryItem[] = entries.map((entry) => ({
        id: entry.id,
        path: localJournalPath(entry.id),
        title: entry.title || "Journal entry",
        kind: entry.kind,
        sizeBytes: entry.content?.length ?? 0,
        modifiedAt: Math.floor(
          (Number.isFinite(Date.parse(entry.updatedAt))
            ? Date.parse(entry.updatedAt)
            : Date.now()) / 1000
        ),
        previewText: entry.content?.slice(0, 280) || "",
        mediaUrl: null,
        editableText: entry.kind === "text",
        scope: "journal"
      }));
      setJournalItems(items);
      if (items.length > 0 && !selectedJournalPath) {
        setSelectedJournalPath(items[0].path);
      }
    };

    const refreshGatewayJournalLibrary = async (bearerToken: string) => {
      const items = (await listLibraryItems("journal", bearerToken || undefined, gatewayBaseUrl)).filter((item) => {
        const path = item.path.toLowerCase();
        if (!path.startsWith("journals/")) {
          return false;
        }
        if (path.startsWith("journals/media/")) {
          return true;
        }
        if (item.kind !== "text") {
          return false;
        }
        if (path.startsWith("journals/text/transcript/") || path.startsWith("journals/text/transcriptions/")) {
          return false;
        }
        return path.startsWith("journals/text/") && (path.endsWith(".txt") || path.endsWith(".md"));
      });
      setJournalItems(items);
      if (items.length > 0 && !selectedJournalPath) {
        setSelectedJournalPath(items[0].path);
      }
    };

    let token = normalizeGatewayToken(chatGatewayToken);
    if (!token && isDesktopClient) {
      token = normalizeGatewayToken((await syncDesktopGatewayBootstrap()) || "");
    }
    try {
      if (scope === "journal" || scope === "all") {
        if (isDesktopClient) {
          try {
            await refreshGatewayJournalLibrary(token);
          } catch (gatewayError) {
            try {
              await refreshLocalJournalLibrary();
            } catch (localError) {
              if (isMissingDesktopCommand(localError, "list_journals")) {
                throw gatewayError;
              }
              throw localError;
            }
          }
        } else {
          await refreshGatewayJournalLibrary(token);
        }
      }
      if (scope === "feed" || scope === "all") {
        const items = (await listLibraryItems("feed", token || undefined, gatewayBaseUrl)).filter((item) => {
          const path = item.path.toLowerCase();
          if (path.endsWith(".caption.txt")) {
            return false;
          }
          if (path.endsWith(".json") || path.endsWith(".srt")) {
            return false;
          }
          return true;
        });
        setFeedItems(items);
      }
      setLibraryStatus(`Library refreshed (${scope})`);
    } catch (error) {
      setLibraryStatus(
        `Library unavailable (${error instanceof Error ? error.message : String(error)})`
      );
    }
  }

  async function uploadJournalFile(file: File, kind: "audio" | "video") {
    let token = chatGatewayToken.trim();
    if (!gatewayBaseUrl.trim()) {
      setRecordingHint("Upload blocked (gateway URL missing). Pair mobile with desktop QR.");
      return;
    }
    if (!token && isDesktopClient) {
      token = (await syncDesktopGatewayBootstrap())?.trim() || "";
    }
    if (!token) {
      if (isDesktopClient) {
        token = "desktop-local";
      } else {
        setRecordingHint("Upload blocked (gateway token missing). Pair mobile with desktop QR.");
        return;
      }
    }
    setRecordingHint(`Uploading ${file.name}...`);
    try {
      try {
        const result = await uploadMediaViaGateway(
          file,
          {
            kind,
            filename: file.name || `${kind}-${Date.now()}`
          },
          token,
          gatewayBaseUrl
        );
        setRecordingHint(
          `Saved ${kind} to workspace: ${String(result.path || file.name)} (${formatBytes(
            Number(result.bytes || file.size || 0)
          )})`
        );
        await refreshLibrary("journal");
        const uploadedPath = String(result.path || "").trim();
        if (uploadedPath) {
          setSelectedJournalPath(uploadedPath);
          const transcriptionStatus = String(result?.transcription?.status || "").toLowerCase();
          if (kind === "audio" && (transcriptionStatus === "queued" || transcriptionStatus === "running")) {
            setJournalTranscriptionStatusByPath((prev) => ({
              ...prev,
              [uploadedPath]: transcriptionStatus as "queued" | "running"
            }));
            setJournalSaveStatus("Transcription queued...");
            void waitForTranscriptForMedia(uploadedPath, token || undefined);
          }
        }
      } catch (gatewayError) {
        if (!isDesktopClient) {
          throw gatewayError;
        }
        try {
          const dataB64 = await blobToBase64(file);
          const saved = await saveJournalMedia(kind, file.name || `${kind}-${Date.now()}`, dataB64, "Journal entry");
          setRecordingHint(
            `Saved ${kind} locally: ${file.name || `${kind}-${Date.now()}`} (${formatBytes(file.size || 0)})`
          );
          await refreshLibrary("journal");
          setSelectedJournalPath(localJournalPath(saved.id));
        } catch (localError) {
          if (isMissingDesktopCommand(localError, "save_journal_media")) {
            throw gatewayError;
          }
          throw localError;
        }
      }
    } catch (error) {
      setRecordingHint(
        `Upload failed (${error instanceof Error ? error.message : String(error)})`
      );
    }
  }

  async function saveJournalTextDraft() {
    const content = journalDraftText.trim();
    if (!content && !selectedJournalItem) {
      setJournalSaveStatus("Write something first");
      return;
    }
    if (!selectedJournalItem && selectedJournalPath.trim()) {
      return;
    }

    let token = normalizeGatewayToken(chatGatewayToken);
    if (!token && isDesktopClient) {
      token = normalizeGatewayToken((await syncDesktopGatewayBootstrap()) || "");
    }
    if (!token && !isDesktopClient) {
      setJournalSaveStatus("Save blocked (gateway token missing).");
      return;
    }
    setJournalSaveStatus("Saving journal note...");
    const saveOriginPath = selectedJournalPathRef.current.trim();
    const saveWasFreshDraft = !selectedJournalItem && !saveOriginPath;
    try {
      let resultPath = "";
      let nextSelectedPath = selectedJournalPath;
      if (selectedJournalItem && selectedJournalItem.kind === "text") {
        const localId = localJournalIdFromPath(selectedJournalItem.path);
        if (localId) {
          try {
            const updated = await updateJournalText(localId, content);
            resultPath = localJournalPath(updated.id);
            nextSelectedPath = resultPath;
          } catch (localError) {
            if (!isMissingDesktopCommand(localError, "update_journal_text")) {
              throw localError;
            }
            const result = await createJournalTextViaGateway(
              "Journal entry",
              content,
              token || undefined,
              gatewayBaseUrl
            );
            resultPath = String(result.path || "");
            nextSelectedPath = resultPath;
          }
        } else {
          try {
            await saveLibraryText(selectedJournalItem.path, content, token || undefined, gatewayBaseUrl);
            resultPath = selectedJournalItem.path;
            nextSelectedPath = selectedJournalItem.path;
          } catch (gatewayError) {
            if (!isDesktopClient) {
              throw gatewayError;
            }
            try {
              const created = await saveJournalText("Journal entry", content);
              resultPath = localJournalPath(created.id);
              nextSelectedPath = resultPath;
            } catch (localError) {
              if (isMissingDesktopCommand(localError, "save_journal_text")) {
                throw gatewayError;
              }
              throw localError;
            }
          }
        }
      } else if (selectedJournalItem && (selectedJournalItem.kind === "audio" || selectedJournalItem.kind === "video")) {
        const draftPath =
          loadedTextPathRef.current.trim() || journalTranscriptPathForMedia(selectedJournalItem);
        await saveLibraryText(draftPath, content, token || undefined, gatewayBaseUrl);
        resultPath = draftPath;
        nextSelectedPath = selectedJournalItem.path;
      } else {
        try {
          const result = await createJournalTextViaGateway(
            "Journal entry",
            content,
            token || undefined,
            gatewayBaseUrl
          );
          resultPath = String(result.path || "");
          nextSelectedPath = resultPath;
        } catch (gatewayError) {
          if (!isDesktopClient) {
            throw gatewayError;
          }
          try {
            const created = await saveJournalText("Journal entry", content);
            resultPath = localJournalPath(created.id);
            nextSelectedPath = resultPath;
          } catch (localError) {
            if (isMissingDesktopCommand(localError, "save_journal_text")) {
              throw gatewayError;
            }
            throw localError;
          }
        }
      }
      holdJournalStatus("Saved");
      await refreshLibrary("journal");
      const currentSelectionPath = selectedJournalPathRef.current.trim();
      const shouldRestoreSelection =
        (saveWasFreshDraft && !currentSelectionPath) || currentSelectionPath === saveOriginPath;
      if (shouldRestoreSelection && nextSelectedPath) {
        selectedJournalPathRef.current = nextSelectedPath;
        setSelectedJournalPath(nextSelectedPath);
        setSelectedJournalText(content);
      }
      void loadWorkspaceSynthStatus();
    } catch (error) {
      setJournalSaveStatus(
        `Save failed (${error instanceof Error ? error.message : String(error)})`
      );
    }
  }

  async function deleteJournalItem(item: LibraryItem) {
    let token = chatGatewayToken.trim();
    if (!token && isDesktopClient) {
      token = (await syncDesktopGatewayBootstrap())?.trim() || "";
    }
    if (!token) {
      if (isDesktopClient) {
        token = "desktop-local";
      } else {
        setJournalSaveStatus("Delete blocked (gateway token missing).");
        return;
      }
    }

    setJournalSaveStatus(`Deleting ${item.title}...`);
    try {
      await deleteLibraryItem(item.path, token || undefined, gatewayBaseUrl);
      setPendingDeleteJournalItem(null);
      if (selectedJournalPath === item.path) {
        journalLoadRequestRef.current += 1;
        openedJournalPathRef.current = "";
        selectedJournalPathRef.current = "";
        setSelectedJournalPath("");
        setSelectedJournalItem(null);
        setSelectedJournalText("");
        setJournalDraftText("");
        loadedTextPathRef.current = "";
      }
      await refreshLibrary("journal");
      setJournalSaveStatus("Deleted");
    } catch (error) {
      setJournalSaveStatus(
        `Delete failed (${error instanceof Error ? error.message : String(error)})`
      );
    }
  }

  async function deleteFeedItem(item: LibraryItem) {
    let token = chatGatewayToken.trim();
    if (!token && isDesktopClient) {
      token = (await syncDesktopGatewayBootstrap())?.trim() || "";
    }
    if (!token) {
      if (isDesktopClient) {
        token = "desktop-local";
      } else {
        setFeedEditStatus("Delete blocked (gateway token missing).");
        return;
      }
    }

    setFeedEditStatus(`Deleting ${item.title}...`);
    try {
      await deleteLibraryItem(item.path, token || undefined, gatewayBaseUrl);
      setPendingDeleteFeedItem(null);
      setFeedItems((prev) => prev.filter((entry) => entry.path !== item.path));
      setFeedDraftsByPath((prev) =>
        Object.fromEntries(Object.entries(prev).filter(([path]) => path !== item.path))
      );
      setFeedDraftSourceByPath((prev) =>
        Object.fromEntries(Object.entries(prev).filter(([path]) => path !== item.path))
      );
      setFeedDraftLoadingByPath((prev) =>
        Object.fromEntries(Object.entries(prev).filter(([path]) => path !== item.path))
      );
      if (selectedFeedPath === item.path) {
        setSelectedFeedPath("");
        setSelectedFeedItem(null);
        setSelectedFeedText("");
        setFeedCaptionPath("");
        setFeedCaptionText("");
      }
      setFeedEditStatus("Deleted");
    } catch (error) {
      setFeedEditStatus(
        `Delete failed (${error instanceof Error ? error.message : String(error)})`
      );
    }
  }

  function applyJournalTranscriptionStatus(
    mediaPath: string,
    statusResult: JournalTranscriptionStatus
  ) {
    const normalizedPath = mediaPath.trim();
    const status = String(statusResult.status || "").toLowerCase();
    const isStillSelected = () => selectedJournalPathRef.current === mediaPath;

    if (status === "done") {
      setJournalTranscriptionStatusByPath((prev) => ({
        ...prev,
        [normalizedPath]: "done"
      }));
      const transcriptPath = String(statusResult.path || "");
      const transcriptText = String(statusResult.text || "");
      if (isStillSelected()) {
        loadedTextPathRef.current = transcriptPath;
        setSelectedJournalText(transcriptText);
        setJournalDraftText(transcriptText);
        setJournalSaveStatus("Transcription ready");
        setJournalTranscribing(false);
      }
      return;
    }

    if (status === "error") {
      setJournalTranscriptionStatusByPath((prev) => ({
        ...prev,
        [normalizedPath]: "error"
      }));
      if (isStillSelected()) {
        setJournalTranscribing(false);
        setJournalSaveStatus(
          `Transcription failed (${String(statusResult.error || "unknown error")})`
        );
      }
      return;
    }

    if (status === "queued" || status === "running") {
      setJournalTranscriptionStatusByPath((prev) => ({
        ...prev,
        [normalizedPath]: status as "queued" | "running"
      }));
      if (isStillSelected()) {
        setJournalTranscribing(true);
        setJournalSaveStatus(
          status === "queued" ? "Transcription queued..." : "Transcription in progress..."
        );
      }
      return;
    }

    setJournalTranscriptionStatusByPath((prev) => ({
      ...prev,
      [normalizedPath]: "idle"
    }));
    if (isStillSelected()) {
      setJournalTranscribing(false);
    }
  }

  async function waitForTranscriptForMedia(
    mediaPath: string,
    token: string | undefined,
  ) {
    const normalizedPath = mediaPath.trim();
    if (!normalizedPath) {
      return;
    }
    if (activeTranscriptionPollRef.current[normalizedPath]) {
      return;
    }
    const stream = streamJournalTranscriptionStatus(
      mediaPath,
      (statusResult) => {
        applyJournalTranscriptionStatus(mediaPath, statusResult);
      },
      token,
      gatewayBaseUrl,
      () => {
        if (selectedJournalPathRef.current === mediaPath) {
          setJournalTranscribing(false);
        }
      }
    );
    activeTranscriptionPollRef.current[normalizedPath] = stream;
    try {
      await stream.done;
    } finally {
      if (activeTranscriptionPollRef.current[normalizedPath] === stream) {
        delete activeTranscriptionPollRef.current[normalizedPath];
      }
    }
  }

  async function transcribeSelectedJournalMedia() {
    if (!selectedJournalItem || selectedJournalItem.kind !== "audio") {
      return;
    }
    if (runtimeMediaCapabilities && !runtimeMediaCapabilities.transcribeMedia) {
      setJournalSaveStatus(
        runtimeMediaSummary || "Local transcription is unavailable on this device."
      );
      return;
    }
    let token = chatGatewayToken.trim();
    if (!token && isDesktopClient) {
      token = (await syncDesktopGatewayBootstrap())?.trim() || "";
    }
    if (!token && !isDesktopClient) {
      setJournalSaveStatus("Transcription blocked (gateway token missing).");
      return;
    }

    setJournalTranscribing(true);
    setJournalTranscriptionStatusByPath((prev) => ({
      ...prev,
      [selectedJournalItem.path]: "queued"
    }));
    setJournalSaveStatus("Queueing transcription...");
    try {
      const result = await transcribeJournalMedia(
        selectedJournalItem.path,
        token || undefined,
        gatewayBaseUrl
      );
      const status = String(result.status || "").toLowerCase();
      if (status === "done") {
        const transcriptPath = String(result.path || journalTranscriptPathForMedia(selectedJournalItem));
        const transcriptText = String(result.text || "");
        setJournalTranscriptionStatusByPath((prev) => ({
          ...prev,
          [selectedJournalItem.path]: "done"
        }));
        loadedTextPathRef.current = transcriptPath;
        setSelectedJournalText(transcriptText);
        setJournalDraftText(transcriptText);
        setJournalSaveStatus("Transcription ready");
        setJournalTranscribing(false);
        return;
      }
      if (status === "error") {
        setJournalTranscriptionStatusByPath((prev) => ({
          ...prev,
          [selectedJournalItem.path]: "error"
        }));
        throw new Error(String(result.error || "unknown transcription error"));
      }
      if (status === "queued" || status === "running") {
        setJournalTranscriptionStatusByPath((prev) => ({
          ...prev,
          [selectedJournalItem.path]: status as "queued" | "running"
        }));
      }
      await waitForTranscriptForMedia(
        selectedJournalItem.path,
        token || undefined
      );
    } catch (error) {
      setJournalTranscriptionStatusByPath((prev) => ({
        ...prev,
        [selectedJournalItem.path]: "error"
      }));
      setJournalSaveStatus(
        `Transcription failed (${error instanceof Error ? error.message : String(error)})`
      );
      setJournalTranscribing(false);
    }
  }

  async function openLibraryItem(item: LibraryItem, scope: "journal" | "feed") {
    let journalLoadRequestId = 0;
    const isCurrentJournalSelection = () =>
      scope === "journal" &&
      journalLoadRequestRef.current === journalLoadRequestId &&
      selectedJournalPathRef.current === item.path;

    if (scope === "journal") {
      setJournalTranscribing(false);
      journalLoadRequestRef.current += 1;
      journalLoadRequestId = journalLoadRequestRef.current;
      selectedJournalPathRef.current = item.path;
      setSelectedJournalItem(item);
      setSelectedJournalPath(item.path);
      if (item.kind === "text" || item.kind === "image") {
        setRecordingHint(DEFAULT_RECORDING_HINT);
      }
    } else {
      setSelectedFeedItem(item);
      setSelectedFeedPath(item.path);
    }

    const token = chatGatewayToken.trim() || undefined;
    if (item.kind === "text") {
      try {
        const localId = localJournalIdFromPath(item.path);
        const content = localId
          ? (await getJournal(localId)).content || ""
          : await readLibraryText(item.path, token, gatewayBaseUrl);
        if (scope === "journal") {
          if (!isCurrentJournalSelection()) {
            return;
          }
          loadedTextPathRef.current = item.path;
          setSelectedJournalText(content);
          setJournalDraftText(content);
        } else {
          loadedTextPathRef.current = item.path;
          setSelectedFeedText(content);
          setFeedEditStatus(`Loaded ${item.path}`);
        }
      } catch (error) {
        if (scope === "journal") {
          if (!isCurrentJournalSelection()) {
            return;
          }
          setSelectedJournalText("");
          setJournalDraftText("");
        } else {
          setSelectedFeedText("");
          setFeedEditStatus(
            `Read failed (${error instanceof Error ? error.message : String(error)})`
          );
        }
      }
    } else if (item.kind === "video" || item.kind === "audio") {
      const transcriptPath = journalTranscriptPathForMedia(item);
      const legacyTranscriptPath = legacyJournalTranscriptPathForMedia(item);
      const legacyCaptionPath = sidecarCaptionPath(item);
      const candidatePaths =
        scope === "journal"
          ? [transcriptPath, legacyTranscriptPath, legacyCaptionPath]
          : [legacyCaptionPath];

      let loadedContent = "";
      let loadedPath = candidatePaths[0];
      let hasLoadedPath = false;
      for (const candidatePath of candidatePaths) {
        try {
          loadedContent = await readLibraryText(candidatePath, token, gatewayBaseUrl);
          loadedPath = candidatePath;
          hasLoadedPath = true;
          break;
        } catch {
          // Try next candidate path.
        }
      }

      if (scope === "feed") {
        loadedCaptionPathRef.current = loadedPath;
        setFeedCaptionPath(loadedPath);
        if (hasLoadedPath) {
          setFeedCaptionText(loadedContent);
        } else {
          setFeedCaptionText(item.previewText || item.title || "");
        }
      } else {
        if (!isCurrentJournalSelection()) {
          return;
        }
        loadedTextPathRef.current = loadedPath;
        if (hasLoadedPath) {
          setSelectedJournalText(loadedContent);
          setJournalDraftText(loadedContent);
          setJournalTranscriptionStatusByPath((prev) => ({
            ...prev,
            [item.path]: "done"
          }));
          setJournalTranscribing(false);
        } else {
          setSelectedJournalText("");
          setJournalDraftText("");
          setJournalTranscriptionStatusByPath((prev) => ({
            ...prev,
            [item.path]: prev[item.path] || "idle"
          }));
        }

        try {
          const statusResult = await getJournalTranscriptionStatus(item.path, token, gatewayBaseUrl);
          if (!isCurrentJournalSelection()) {
            return;
          }
          const status = String(statusResult.status || "").toLowerCase();
          if (status === "done") {
            setJournalTranscriptionStatusByPath((prev) => ({
              ...prev,
              [item.path]: "done"
            }));
            const transcriptText = String(statusResult.text || "");
            const transcriptPath = String(statusResult.path || loadedPath);
            if (!hasLoadedPath && transcriptText.trim()) {
              loadedTextPathRef.current = transcriptPath;
              setSelectedJournalText(transcriptText);
              setJournalDraftText(transcriptText);
            }
            setJournalTranscribing(false);
          } else if (status === "queued" || status === "running") {
            setJournalTranscriptionStatusByPath((prev) => ({
              ...prev,
              [item.path]: status as "queued" | "running"
            }));
            setJournalTranscribing(true);
            setJournalSaveStatus(
              status === "queued" ? "Transcription queued..." : "Transcription in progress..."
            );
            void waitForTranscriptForMedia(item.path, token);
          } else if (status === "error") {
            setJournalTranscriptionStatusByPath((prev) => ({
              ...prev,
              [item.path]: "error"
            }));
            setJournalTranscribing(false);
          } else {
            setJournalTranscriptionStatusByPath((prev) => ({
              ...prev,
              [item.path]: prev[item.path] || "idle"
            }));
            setJournalTranscribing(false);
          }
        } catch {
          if (isCurrentJournalSelection()) {
            setJournalTranscribing(false);
          }
        }
      }
    }
  }

  function resetJournalSession() {
    journalLoadRequestRef.current += 1;
    openedJournalPathRef.current = "";
    selectedJournalPathRef.current = "";
    setJournalDraftText("");
    setSelectedJournalText("");
    setSelectedJournalItem(null);
    setSelectedJournalPath("");
    setRecordingHint(DEFAULT_RECORDING_HINT);
    loadedTextPathRef.current = "";
    setJournalTranscribing(false);
    setJournalSaveStatus("Journal idle");
    setMediaPreviewUrl((prev) => {
      if (prev) {
        URL.revokeObjectURL(prev);
      }
      return "";
    });
    setMediaPreviewMime("");
  }

  async function loadMediaPreview(item: LibraryItem | null) {
    if (!item || !item.mediaUrl) {
      setMediaPreviewLoading(false);
      if (mediaPreviewUrl) {
        URL.revokeObjectURL(mediaPreviewUrl);
        setMediaPreviewUrl("");
      }
      setMediaPreviewMime("");
      return;
    }
    if (!(item.kind === "audio" || item.kind === "video" || item.kind === "image")) {
      return;
    }
    setMediaPreviewLoading(true);
    try {
      let blob: Blob;
      const localId = localJournalIdFromPath(item.path);
      if (localId) {
        const journal = await getJournal(localId);
        const filePath = String(journal.filePath || "").trim();
        if (!filePath) {
          throw new Error("Local media file path missing");
        }
        const { readFile } = await import("@tauri-apps/plugin-fs");
        const bytes = await readFile(filePath);
        blob = new Blob([bytes], { type: inferMediaMimeType(filePath, item.kind) });
      } else {
        const token = chatGatewayToken.trim() || undefined;
        const mediaUrl = resolveGatewayResourceUrl(item.mediaUrl || "", gatewayBaseUrl);
        const res = await fetch(mediaUrl, {
          headers: token ? { Authorization: `Bearer ${token}` } : undefined
        });
        if (!res.ok) {
          throw new Error(`Preview load failed (${res.status})`);
        }
        const fetchedBlob = await res.blob();
        const resolvedType = inferMediaMimeType(item.path, item.kind, fetchedBlob.type);
        blob =
          resolvedType === fetchedBlob.type
            ? fetchedBlob
            : new Blob([fetchedBlob], { type: resolvedType });
      }
      setMediaPreviewMime(blob.type || inferMediaMimeType(item.path, item.kind));
      const nextUrl = URL.createObjectURL(blob);
      setMediaPreviewUrl((prev) => {
        if (prev) {
          URL.revokeObjectURL(prev);
        }
        return nextUrl;
      });
    } catch (error) {
      setJournalSaveStatus(
        `Preview unavailable (${error instanceof Error ? error.message : String(error)})`
      );
      if (mediaPreviewUrl) {
        URL.revokeObjectURL(mediaPreviewUrl);
        setMediaPreviewUrl("");
      }
      setMediaPreviewMime("");
    } finally {
      setMediaPreviewLoading(false);
    }
  }

  async function ensureFeedDraftLoaded(item: LibraryItem) {
    if (!(item.kind === "text" || item.kind === "audio" || item.kind === "video")) {
      return;
    }
    if (feedDraftSourceByPath[item.path] || feedDraftLoadingRef.current[item.path]) {
      return;
    }

    feedDraftLoadingRef.current[item.path] = true;
    setFeedDraftLoadingByPath((prev) => ({ ...prev, [item.path]: true }));

    const token = chatGatewayToken.trim() || undefined;
    try {
      if (item.kind === "text") {
        const content = await readLibraryText(item.path, token, gatewayBaseUrl);
        setFeedDraftsByPath((prev) => ({ ...prev, [item.path]: content }));
        setFeedDraftSourceByPath((prev) => ({ ...prev, [item.path]: item.path }));
        return;
      }

      const captionPath = sidecarCaptionPath(item);
      let content = item.previewText || item.title || "";
      let sourcePath = captionPath;
      try {
        content = await readLibraryText(captionPath, token, gatewayBaseUrl);
      } catch {
        // Use inline preview text when no caption sidecar exists yet.
      }
      setFeedDraftsByPath((prev) => ({ ...prev, [item.path]: content }));
      setFeedDraftSourceByPath((prev) => ({ ...prev, [item.path]: sourcePath }));
    } catch (error) {
      const fallbackContent = item.previewText || item.title || "";
      setFeedDraftsByPath((prev) => ({
        ...prev,
        [item.path]: fallbackContent
      }));
      if (!fallbackContent.trim()) {
        setFeedEditStatus(
          `Feed load failed (${error instanceof Error ? error.message : String(error)})`
        );
      }
    } finally {
      delete feedDraftLoadingRef.current[item.path];
      setFeedDraftLoadingByPath((prev) => ({ ...prev, [item.path]: false }));
    }
  }

  function scheduleFeedDraftSave(item: LibraryItem, nextValue: string) {
    if (!(item.kind === "text" || item.kind === "audio" || item.kind === "video")) {
      return;
    }
    const savePath = item.kind === "text" ? item.path : feedDraftSourceByPath[item.path] || sidecarCaptionPath(item);
    if (!savePath) {
      return;
    }
    const existingTimer = feedAutosaveTimersRef.current[item.path];
    if (existingTimer) {
      window.clearTimeout(existingTimer);
    }
    feedAutosaveTimersRef.current[item.path] = window.setTimeout(async () => {
      try {
        const token = chatGatewayToken.trim() || undefined;
        await saveLibraryText(savePath, nextValue, token, gatewayBaseUrl);
        setFeedEditStatus(`Autosaved ${savePath}`);
      } catch (error) {
        setFeedEditStatus(
          `Autosave failed (${error instanceof Error ? error.message : String(error)})`
        );
      } finally {
        delete feedAutosaveTimersRef.current[item.path];
      }
    }, 700);
  }

  function updateFeedDraft(item: LibraryItem, nextValue: string) {
    setFeedDraftsByPath((prev) => ({ ...prev, [item.path]: nextValue }));
    setFeedDraftSourceByPath((prev) => ({
      ...prev,
      [item.path]: item.kind === "text" ? item.path : prev[item.path] || sidecarCaptionPath(item)
    }));
    scheduleFeedDraftSave(item, nextValue);
  }

  async function archivePostedFeedSource(sourcePath: string, token?: string) {
    const path = sourcePath.trim();
    if (!path) {
      return { archivedPath: "", archiveError: "Missing source path" };
    }
    try {
      const result = await archivePostedLibraryItem(path, token, gatewayBaseUrl);
      const archivedPath = String(result?.path || "");
      if (selectedFeedPath === path) {
        setSelectedFeedPath("");
        setSelectedFeedItem(null);
        setSelectedFeedText("");
        setFeedCaptionPath("");
        setFeedCaptionText("");
      }
      await refreshLibrary("feed");
      return { archivedPath, archiveError: "" };
    } catch (error) {
      return {
        archivedPath: "",
        archiveError: error instanceof Error ? error.message : String(error)
      };
    }
  }

  function toggleFeedCommentComposer(path: string) {
    setActiveFeedCommentPath((current) => (current === path ? "" : path));
  }

  async function loadWorkspaceSynthStatus() {
    let token = chatGatewayToken.trim();
    if (!token && isDesktopClient) {
      token = (await syncDesktopGatewayBootstrap())?.trim() || "";
    }
    if (!token && !isDesktopClient) {
      return null;
    }
    try {
      const status = await getWorkspaceSynthesizerStatus(token || undefined, gatewayBaseUrl);
      setWorkspaceSynthStatus(status);
      return status;
    } catch (error) {
      setFeedEditStatus(
        `Workspace status unavailable (${error instanceof Error ? error.message : String(error)})`
      );
      return null;
    }
  }

  async function loadWorkspaceTodos() {
    let token = chatGatewayToken.trim();
    if (!token && isDesktopClient) {
      token = (await syncDesktopGatewayBootstrap())?.trim() || "";
    }
    if (!token && !isDesktopClient) {
      return;
    }
    try {
      const items = await listWorkspaceTodos(token || undefined, gatewayBaseUrl);
      setWorkspaceTodos(items);
    } catch (error) {
      setFeedEditStatus(
        `Workspace todos unavailable (${error instanceof Error ? error.message : String(error)})`
      );
    }
  }

  async function loadWorkspaceEvents() {
    let token = chatGatewayToken.trim();
    if (!token && isDesktopClient) {
      token = (await syncDesktopGatewayBootstrap())?.trim() || "";
    }
    if (!token && !isDesktopClient) {
      return;
    }
    try {
      const items = await listWorkspaceEvents(token || undefined, gatewayBaseUrl);
      setWorkspaceEvents(items);
    } catch (error) {
      setFeedEditStatus(
        `Workspace events unavailable (${error instanceof Error ? error.message : String(error)})`
      );
    }
  }

  async function refreshWorkspaceViews(options?: { runSynthIfPending?: boolean }) {
    let token = chatGatewayToken.trim();
    if (!token && isDesktopClient) {
      token = (await syncDesktopGatewayBootstrap())?.trim() || "";
    }
    if (!token && !isDesktopClient) {
      return;
    }
    const status = await loadWorkspaceSynthStatus();
    await Promise.all([
      refreshLibrary("feed"),
      loadWorkspaceSynthSkillSettings(),
      loadFeedWorkflowSettings(),
      loadWorkflowRunStatuses(),
      loadWorkspaceTodos(),
      loadWorkspaceEvents()
    ]);
    if (
      options?.runSynthIfPending &&
      status &&
      status.status !== "pending" &&
      status.status !== "processing" &&
      Number(status.pendingSourceCount || 0) > 0
    ) {
      await runWorkspaceSynthesizerManual({ statusSnapshot: status, quietWhenIdle: true });
    }
  }

  async function runWorkspaceSynthesizerManual(options?: {
    sourcePath?: string;
    force?: boolean;
    statusSnapshot?: WorkspaceSynthesizerStatus | null;
    quietWhenIdle?: boolean;
  }) {
    let token = chatGatewayToken.trim();
    if (!token && isDesktopClient) {
      token = (await syncDesktopGatewayBootstrap())?.trim() || "";
    }
    if (!token && !isDesktopClient) {
      setFeedEditStatus("Run blocked (gateway token missing).");
      return;
    }

    setWorkspaceSynthBusy(true);
    try {
      const status = options?.statusSnapshot ?? (await loadWorkspaceSynthStatus());
      const result = await runWorkspaceSynthesizerNow(
        {
          sourcePath: options?.sourcePath,
          force: options?.force
        },
        token || undefined,
        gatewayBaseUrl
      );
      if (result.queued) {
        const selectedCount =
          options?.sourcePath ? 1 : status?.selectedSourcePaths?.length || 0;
        setFeedEditStatus(
          `Processing ${Math.max(1, selectedCount)} journal entr${Math.max(1, selectedCount) === 1 ? "y" : "ies"}...`
        );
        await loadWorkspaceSynthStatus();
      } else if (result.message && !options?.quietWhenIdle) {
        setFeedEditStatus(result.message);
      }
    } catch (error) {
      setFeedEditStatus(
        `Workspace synth run failed (${error instanceof Error ? error.message : String(error)})`
      );
    } finally {
      setWorkspaceSynthBusy(false);
    }
  }

  async function toggleWorkspaceTodo(item: WorkspaceTodoItem) {
    let token = chatGatewayToken.trim();
    if (!token && isDesktopClient) {
      token = (await syncDesktopGatewayBootstrap())?.trim() || "";
    }
    if (!token && !isDesktopClient) {
      setFeedEditStatus("Todo update blocked (gateway token missing).");
      return;
    }
    const nextStatus = item.status === "done" ? "open" : "done";
    try {
      const updated = await updateWorkspaceTodoStatus(
        item.id,
        nextStatus,
        token || undefined,
        gatewayBaseUrl
      );
      setWorkspaceTodos((prev) =>
        prev.map((entry) => (entry.id === updated.id ? updated : entry))
      );
    } catch (error) {
      setFeedEditStatus(
        `Todo update failed (${error instanceof Error ? error.message : String(error)})`
      );
    }
  }

  async function loadFeedWorkflowSettings() {
    let token = chatGatewayToken.trim();
    if (!token && isDesktopClient) {
      token = (await syncDesktopGatewayBootstrap())?.trim() || "";
    }
    if (!token && !isDesktopClient) {
      return;
    }

    setWorkflowSettingsLoading(true);
    try {
      const items = await listFeedContentAgents(token || undefined, gatewayBaseUrl);
      const byKey: Record<string, FeedContentAgentItem | undefined> = {};
      const drafts: Record<string, WorkflowSettingsDraft | undefined> = {};
      const bots: WorkflowBotMeta[] = [];
      for (const item of items) {
        const key = item.workflowKey.trim();
        if (!key) {
          continue;
        }
        byKey[key] = item;
        if (key !== "workspace_synthesizer") {
          drafts[key] = workflowSettingsDraftFromItem(item);
          bots.push(workflowBotMetaFromSettings(item));
        }
      }

      bots.sort((a, b) => a.name.localeCompare(b.name));
      setWorkflowBots(bots);
      setWorkflowSettingsByKey(byKey);
      setWorkflowSettingsDraftByKey(drafts);
      if (activeWorkflowBotKey && !byKey[activeWorkflowBotKey]) {
        setActiveWorkflowBotKey("");
      }
      void loadWorkflowRunStatuses(bots);
    } catch (error) {
      setFeedEditStatus(
        `Content agents unavailable (${error instanceof Error ? error.message : String(error)})`
      );
    } finally {
      setWorkflowSettingsLoading(false);
    }
  }

  async function loadWorkspaceSynthSkillSettings() {
    let token = chatGatewayToken.trim();
    if (!token && isDesktopClient) {
      token = (await syncDesktopGatewayBootstrap())?.trim() || "";
    }
    if (!token && !isDesktopClient) {
      return;
    }

    try {
      const items = await listWorkspaceSynthSkills(token || undefined, gatewayBaseUrl);
      const byKey: Record<string, WorkspaceSynthSkillItem | undefined> = {};
      const drafts: Record<string, string | undefined> = {};
      const bots: WorkflowBotMeta[] = [];
      for (const item of items) {
        const key = item.skillKey.trim();
        if (!key) {
          continue;
        }
        byKey[key] = item;
        drafts[key] = item.artifactRulesOverride || item.artifactRules || "";
        bots.push(workflowBotMetaFromSynthSkill(item));
      }
      bots.sort((a, b) => a.name.localeCompare(b.name));
      setWorkspaceSynthSkillItems(items);
      setWorkspaceSynthSkillsByKey(byKey);
      setWorkspaceSynthSkillDraftByKey(drafts);
      setWorkspaceSynthSkillBots(bots);
      if (activeWorkspaceSynthSkillKey && !byKey[activeWorkspaceSynthSkillKey]) {
        setActiveWorkspaceSynthSkillKey("");
      }
    } catch (error) {
      setFeedEditStatus(
        `Workspace synth skills unavailable (${error instanceof Error ? error.message : String(error)})`
      );
    }
  }

  async function loadWorkflowRunStatuses(targetBots?: WorkflowBotMeta[]) {
    let token = chatGatewayToken.trim();
    if (!token && isDesktopClient) {
      token = (await syncDesktopGatewayBootstrap())?.trim() || "";
    }
    if (!token && !isDesktopClient) {
      return;
    }

    const bots = targetBots ?? workflowBots;
    if (!bots.length) {
      setWorkflowRunStatusByKey({});
      return;
    }

    const next: Record<string, WorkflowRunStatus | undefined> = {};

    await Promise.all(
      bots.map(async (bot) => {
        try {
          const messages = await listClawChatMessages(
            `workflow:${bot.key}`,
            token || undefined,
            gatewayBaseUrl
          );
          next[bot.key] = parseWorkflowRunStatus(bot, messages);
        } catch {
          next[bot.key] = undefined;
        }
      })
    );

    let shouldRefreshFeed = false;
    for (const bot of bots) {
      const prevStatus = workflowRunStatusByKey[bot.key]?.status;
      const nextStatus = next[bot.key]?.status;
      if (
        (prevStatus === "pending" || prevStatus === "processing") &&
        (nextStatus === "done" || nextStatus === "error")
      ) {
        shouldRefreshFeed = true;
      }
    }
    setWorkflowRunStatusByKey(next);
    if (shouldRefreshFeed) {
      void refreshLibrary("feed");
    }
  }

  async function triggerManualWorkflowRun(botKey: string) {
    const bot = workflowBots.find((item) => item.key === botKey) || workflowBotByKey(botKey);
    const existing = workflowSettingsByKey[botKey];
    if (existing?.supported === false) {
      setFeedEditStatus(
        existing.unsupportedReason || `${bot.name} cannot run on this device.`
      );
      return;
    }
    let token = chatGatewayToken.trim();
    if (!token && isDesktopClient) {
      token = (await syncDesktopGatewayBootstrap())?.trim() || "";
    }
    if (!token && !isDesktopClient) {
      setFeedEditStatus("Run blocked (gateway token missing).");
      return;
    }

    setFeedEditStatus(`Queueing ${bot.name} run...`);
    try {
      const result = await runFeedContentAgentNow(botKey, token || undefined, gatewayBaseUrl);
      setFeedEditStatus(`${result.workflowBot || bot.name} run queued`);
      void loadWorkflowRunStatuses();
    } catch (error) {
      setFeedEditStatus(
        `Run failed to queue (${error instanceof Error ? error.message : String(error)})`
      );
    }
  }

  function openWorkflowSettingsForBot(botKey: string) {
    setFeedSidebarOpen(false);
    setFeedCreateWorkflowOpen(false);
    setActiveWorkflowBotKey(botKey);
    setFeedEditStatus("Feed idle");
    if (!workflowSettingsByKey[botKey]) {
      void loadFeedWorkflowSettings();
    }
  }

  function openFeedBotSettings(bot: WorkflowBotMeta) {
    if (bot.kind === "synth_skill") {
      setFeedCreateWorkflowOpen(false);
      setFeedSidebarOpen(true);
      setActiveWorkflowBotKey("");
      setActiveWorkspaceSynthSkillKey(bot.key);
      setFeedEditStatus("Feed idle");
      return;
    }
    openWorkflowSettingsForBot(bot.key);
  }

  function openWorkflowTemplateForm() {
    setFeedSidebarOpen(false);
    setActiveWorkflowBotKey("");
    setFeedCreateWorkflowOpen(true);
    setWorkflowTemplateDraft(defaultWorkflowTemplateDraft());
    setWorkflowTemplateStatus("");
  }

  async function toggleContentAgentEnabled(botKey: string) {
    let token = chatGatewayToken.trim();
    if (!token && isDesktopClient) {
      token = (await syncDesktopGatewayBootstrap())?.trim() || "";
    }
    if (!token && !isDesktopClient) {
      setWorkflowTemplateStatus("Agent toggle blocked (gateway token missing).");
      return;
    }

    const existing = workflowSettingsByKey[botKey];
    if (!existing) {
      setWorkflowTemplateStatus("Agent settings are not loaded yet.");
      void loadFeedWorkflowSettings();
      return;
    }
    const nextEnabled = !existing.enabled;
    const agentName = existing.workflowBot || workflowBotByKey(botKey).name;
    if (nextEnabled && existing.supported === false) {
      setWorkflowTemplateStatus(
        existing.unsupportedReason || `${agentName} cannot run on this device.`
      );
      return;
    }

    setWorkflowToggleBusyKey(botKey);
    setWorkflowTemplateStatus(
      nextEnabled ? `Enabling ${agentName}...` : `Disabling ${agentName}...`
    );
    try {
      const result = await updateFeedContentAgent(
        {
          workflowKey: botKey,
          enabled: nextEnabled,
          runNow: nextEnabled
        },
        token || undefined,
        gatewayBaseUrl
      );
      setWorkflowSettingsByKey((prev) => ({ ...prev, [botKey]: result.item }));
      setWorkflowSettingsDraftByKey((prev) => ({
        ...prev,
        [botKey]: workflowSettingsDraftFromItem(result.item)
      }));
      setWorkflowTemplateStatus(
        nextEnabled ? `${agentName} enabled and queued to run` : `${agentName} disabled`
      );
      setFeedEditStatus(nextEnabled ? `${agentName} run queued` : `${agentName} disabled`);
      void loadWorkflowRunStatuses();
      void refreshLibrary("feed");
      window.setTimeout(() => {
        void refreshLibrary("feed");
      }, 2000);

      void loadFeedWorkflowSettings();
    } catch (error) {
      setWorkflowTemplateStatus(
        `${nextEnabled ? "Enable" : "Disable"} failed (${error instanceof Error ? error.message : String(error)})`
      );
    } finally {
      setWorkflowToggleBusyKey("");
    }
  }

  async function toggleWorkspaceSynthSkillEnabled(skillKey: string) {
    let token = chatGatewayToken.trim();
    if (!token && isDesktopClient) {
      token = (await syncDesktopGatewayBootstrap())?.trim() || "";
    }
    if (!token && !isDesktopClient) {
      setWorkflowTemplateStatus("Skill toggle blocked (gateway token missing).");
      return;
    }

    const existing = workspaceSynthSkillsByKey[skillKey];
    if (!existing) {
      setWorkflowTemplateStatus("Workspace synth skills are not loaded yet.");
      void loadWorkspaceSynthSkillSettings();
      return;
    }
    const nextEnabled = !existing.enabled;
    const skillName = existing.name || workflowBotByKey(skillKey).name;
    if (nextEnabled && existing.supported === false) {
      setWorkflowTemplateStatus(
        existing.unsupportedReason || `${skillName} cannot run on this device.`
      );
      return;
    }

    setWorkspaceSynthSkillToggleBusyKey(skillKey);
    setWorkflowTemplateStatus(
      nextEnabled ? `Enabling ${skillName}...` : `Disabling ${skillName}...`
    );
    try {
      const result = await updateWorkspaceSynthSkill(
        {
          skillKey,
          enabled: nextEnabled
        },
        token || undefined,
        gatewayBaseUrl
      );
      setWorkspaceSynthSkillsByKey((prev) => ({ ...prev, [skillKey]: result.item }));
      setWorkspaceSynthSkillItems((prev) =>
        prev.map((item) => (item.skillKey === skillKey ? result.item : item))
      );
      setWorkspaceSynthSkillBots((prev) =>
        prev.map((bot) =>
          bot.key === skillKey ? workflowBotMetaFromSynthSkill(result.item) : bot
        )
      );
      setWorkflowTemplateStatus(
        nextEnabled ? `${skillName} will be included in workspace synthesis` : `${skillName} disabled`
      );
      setFeedEditStatus(
        nextEnabled ? `${skillName} enabled for regular workspace synthesis` : `${skillName} disabled`
      );
    } catch (error) {
      setWorkflowTemplateStatus(
        `${nextEnabled ? "Enable" : "Disable"} failed (${error instanceof Error ? error.message : String(error)})`
      );
    } finally {
      setWorkspaceSynthSkillToggleBusyKey("");
    }
  }

  async function saveWorkspaceSynthSkillArtifactRules(skillKey: string, resetToDefault?: boolean) {
    let token = chatGatewayToken.trim();
    if (!token && isDesktopClient) {
      token = (await syncDesktopGatewayBootstrap())?.trim() || "";
    }
    if (!token && !isDesktopClient) {
      setWorkspaceSynthSkillSaveStatusByKey((prev) => ({
        ...prev,
        [skillKey]: "Save blocked (gateway token missing)."
      }));
      return;
    }

    const existing = workspaceSynthSkillsByKey[skillKey];
    if (!existing) {
      void loadWorkspaceSynthSkillSettings();
      return;
    }

    const nextOverride = resetToDefault
      ? ""
      : (workspaceSynthSkillDraftByKey[skillKey] || "").trim();

    setWorkspaceSynthSkillSavingKey(skillKey);
    setWorkspaceSynthSkillSaveStatusByKey((prev) => ({
      ...prev,
      [skillKey]: resetToDefault ? "Restoring default artifact rules..." : "Saving artifact rules..."
    }));
    try {
      const result = await updateWorkspaceSynthSkill(
        {
          skillKey,
          artifactRulesOverride: nextOverride
        },
        token || undefined,
        gatewayBaseUrl
      );
      setWorkspaceSynthSkillsByKey((prev) => ({ ...prev, [skillKey]: result.item }));
      setWorkspaceSynthSkillItems((prev) =>
        prev.map((item) => (item.skillKey === skillKey ? result.item : item))
      );
      setWorkspaceSynthSkillDraftByKey((prev) => ({
        ...prev,
        [skillKey]: result.item.artifactRulesOverride || result.item.artifactRules || ""
      }));
      setWorkspaceSynthSkillSaveStatusByKey((prev) => ({
        ...prev,
        [skillKey]: resetToDefault
          ? "Using built-in artifact rules."
          : "Artifact rules saved for future workspace synthesis runs."
      }));
      setFeedEditStatus(
        resetToDefault
          ? `${existing.name || skillKey} restored to built-in artifact rules`
          : `${existing.name || skillKey} artifact rules updated`
      );
    } catch (error) {
      setWorkspaceSynthSkillSaveStatusByKey((prev) => ({
        ...prev,
        [skillKey]: `Save failed (${error instanceof Error ? error.message : String(error)})`
      }));
    } finally {
      setWorkspaceSynthSkillSavingKey("");
    }
  }

  async function saveWorkflowSettings(botKey: string) {
    const bot = workflowBots.find((item) => item.key === botKey) || workflowBotByKey(botKey);
    const draft = workflowSettingsDraftByKey[botKey];
    if (!draft) {
      return;
    }
    let token = chatGatewayToken.trim();
    if (!token && isDesktopClient) {
      token = (await syncDesktopGatewayBootstrap())?.trim() || "";
    }
    if (!token && !isDesktopClient) {
      setWorkflowSettingsStatusByKey((prev) => ({
        ...prev,
        [botKey]: "Save blocked (gateway token missing)."
      }));
      return;
    }

    setWorkflowSettingsSavingKey(botKey);
    setWorkflowSettingsStatusByKey((prev) => ({
      ...prev,
      [botKey]: "Saving agent goal..."
    }));
    try {
      const result = await updateFeedContentAgent(
        {
          workflowKey: botKey,
          goal: draft.goal.trim() || undefined,
          runNow: true
        },
        token || undefined,
        gatewayBaseUrl
      );
      const item = result.item;
      setWorkflowSettingsByKey((prev) => ({ ...prev, [botKey]: item }));
      setWorkflowSettingsDraftByKey((prev) => ({
        ...prev,
        [botKey]: workflowSettingsDraftFromItem(item)
      }));
      setWorkflowSettingsStatusByKey((prev) => ({
        ...prev,
        [botKey]: result.runQueued
          ? `Saved ${bot.name} goal and queued a run`
          : `Saved ${bot.name} goal`
      }));
      setFeedEditStatus(
        result.runQueued
          ? `${bot.name} run queued with updated goal`
          : `${bot.name} goal saved`
      );
      void loadWorkflowRunStatuses();
      void refreshLibrary("feed");
      window.setTimeout(() => {
        void refreshLibrary("feed");
      }, 2000);
    } catch (error) {
      setWorkflowSettingsStatusByKey((prev) => ({
        ...prev,
        [botKey]: `Save failed (${error instanceof Error ? error.message : String(error)})`
      }));
    } finally {
      setWorkflowSettingsSavingKey("");
    }
  }

  async function submitWorkflowTemplateCreate(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    const draft = workflowTemplateDraft;
    if (!draft.name.trim()) {
      setWorkflowTemplateStatus("Give this agent a name.");
      return;
    }
    if (!draft.goal.trim()) {
      setWorkflowTemplateStatus("Describe what this agent should make.");
      return;
    }

    let token = chatGatewayToken.trim();
    if (!token && isDesktopClient) {
      token = (await syncDesktopGatewayBootstrap())?.trim() || "";
    }
    if (!token && !isDesktopClient) {
      setWorkflowTemplateStatus("Create blocked (gateway token missing).");
      return;
    }

    setWorkflowTemplateSubmitting(true);
    setWorkflowTemplateStatus("Creating content agent...");
    try {
      const result = await createFeedContentAgent(
        {
          name: draft.name.trim(),
          goal: draft.goal.trim(),
          enabled: true,
          runNow: draft.runNow
        },
        token || undefined,
        gatewayBaseUrl
      );
      if (result.queued && result.threadId && result.messageId) {
        const botLabel = result.workflowBot || result.workflowKey || "content agent";
        setWorkflowTemplateStatus(
          `Creating ${botLabel}...${result.creationSummary ? ` ${result.creationSummary}` : ""}`
        );
        setFeedEditStatus(`${botLabel} creation queued`);
        void pollWorkflowTemplateCreateResult(
          result.workflowKey,
          result.workflowBot,
          result.threadId,
          result.messageId
        );
        return;
      }
      if (!result.created) {
        setWorkflowTemplateStatus(
          `Create failed (${result.creationSummary || "content agent was not created"})`
        );
        return;
      }
      setWorkflowTemplateStatus(
        `Created ${result.workflowBot || result.workflowKey}${result.runQueued ? " and queued the first run" : ""
        }.${result.creationSummary ? ` ${result.creationSummary}` : ""}`
      );
      setFeedEditStatus(`${result.workflowBot || result.workflowKey} created`);
      setFeedCreateWorkflowOpen(false);
      setWorkflowTemplateDraft(defaultWorkflowTemplateDraft());
      void loadWorkflowRunStatuses();
      void refreshLibrary("feed");
      void loadFeedWorkflowSettings();
      window.setTimeout(() => {
        void refreshLibrary("feed");
      }, 2000);
    } catch (error) {
      setWorkflowTemplateStatus(
        `Create failed (${error instanceof Error ? error.message : String(error)})`
      );
    } finally {
      setWorkflowTemplateSubmitting(false);
    }
  }

  async function submitWorkflowCommentForFeedItem(item: LibraryItem) {
    const bot = workflowBotForPath(item.path, feedAttributedBots);
    if (!bot) {
      setFeedEditStatus("This feed item is not mapped to an editable workflow yet.");
      return;
    }

    const draft = (feedCommentDrafts[item.path] || "").trim();
    if (!draft) {
      setFeedCommentStatusByPath((prev) => ({
        ...prev,
        [item.path]: "Enter a comment first."
      }));
      return;
    }

    let token = chatGatewayToken.trim();
    if (!token && isDesktopClient) {
      token = (await syncDesktopGatewayBootstrap())?.trim() || "";
    }
    if (!token && !isDesktopClient) {
      setFeedCommentStatusByPath((prev) => ({
        ...prev,
        [item.path]: "Comment blocked (gateway token missing)."
      }));
      return;
    }

    setSubmittingFeedCommentPath(item.path);
    setFeedCommentStatusByPath((prev) => ({
      ...prev,
      [item.path]: `Sending request to ${bot.name}...`
    }));
    try {
      const result = await submitFeedContentAgentComment(
        item.path,
        draft,
        token || undefined,
        gatewayBaseUrl
      );
      setFeedCommentDrafts((prev) => ({ ...prev, [item.path]: "" }));
      setFeedCommentStatusByPath((prev) => ({
        ...prev,
        [item.path]: result.message || `Queued update for ${result.workflowBot || bot.name}`
      }));
      setActiveFeedCommentPath("");
      if (result.queued && result.threadId && result.messageId) {
        setFeedEditStatus(`Workflow update queued for ${result.workflowBot || bot.name}`);
        void loadWorkflowRunStatuses();
        void pollWorkflowCommentResult(item.path, result.threadId, result.messageId);
      } else {
        setFeedEditStatus(result.message || `Update applied for ${result.workflowBot || bot.name}`);
        void loadWorkflowRunStatuses();
      }
    } catch (error) {
      setFeedCommentStatusByPath((prev) => ({
        ...prev,
        [item.path]: `Comment failed (${error instanceof Error ? error.message : String(error)})`
      }));
    } finally {
      setSubmittingFeedCommentPath("");
    }
  }

  async function pollChatResult(opts: {
    threadId: string;
    messageId: string;
    onDone: (reply: ClawChatMessage) => void;
    onError: (errText: string) => void;
    onTimeout?: () => void;
  }) {
    workflowPollAbortRef.current?.close();

    let token = chatGatewayToken.trim();
    if (!token && isDesktopClient) {
      token = (await syncDesktopGatewayBootstrap())?.trim() || "";
    }
    if (!token && !isDesktopClient) {
      return;
    }
    const stream = streamClawChatResult(
      opts.threadId,
      opts.messageId,
      (snapshot) => {
        if (snapshot.status === "error") {
          opts.onError(snapshot.error || snapshot.reply?.content || "operation failed");
          return;
        }
        if (snapshot.status === "done" && snapshot.reply) {
          opts.onDone(snapshot.reply);
        }
      },
      token || undefined,
      gatewayBaseUrl,
      () => {
        opts.onTimeout?.();
      }
    );
    workflowPollAbortRef.current = stream;
    await stream.done;
  }

  async function pollWorkflowTemplateCreateResult(
    workflowKey: string,
    workflowBot: string,
    threadId: string,
    messageId: string
  ) {
    const botLabel = workflowBot || workflowKey || "workflow";
    await pollChatResult({
      threadId,
      messageId,
      onDone: (reply) => {
        const successText = (reply.content || `Created ${botLabel}.`).trim();
        setWorkflowTemplateStatus(successText);
        setFeedEditStatus(`${botLabel} created`);
        setFeedCreateWorkflowOpen(false);
        setWorkflowTemplateDraft(defaultWorkflowTemplateDraft());
        void loadWorkflowRunStatuses();
        void refreshLibrary("feed");
        void loadFeedWorkflowSettings();
        window.setTimeout(() => {
          void refreshLibrary("feed");
        }, 2000);
      },
      onError: (errText) => {
        setWorkflowTemplateStatus(`Create failed (${errText})`);
        setFeedEditStatus(`Content agent creation failed: ${errText}`);
      },
      onTimeout: () => {
        setWorkflowTemplateStatus(
          `Create status pending for ${botLabel}. Open chat thread ${threadId} for details.`
        );
      }
    });
  }

  async function pollWorkflowCommentResult(path: string, threadId: string, messageId: string) {
    await pollChatResult({
      threadId,
      messageId,
      onDone: (reply) => {
        const successText = reply.content || "Workflow modification applied.";
        setFeedCommentStatusByPath((prev) => ({ ...prev, [path]: successText }));
        setFeedEditStatus("Workflow comment applied");
      },
      onError: (errText) => {
        setFeedCommentStatusByPath((prev) => ({
          ...prev,
          [path]: `Modification failed (${errText})`
        }));
        setFeedEditStatus("Workflow comment failed");
      }
    });
  }

  async function postFeedItemToBluesky(item: LibraryItem) {
    if (!agent || !session) {
      setFeedEditStatus("Sign in to Bluesky first");
      return;
    }
    if (isPathPosted(item.path)) {
      setFeedEditStatus(`Already posted: ${item.title}`);
      return;
    }
    setPostingFeedPath(item.path);
    setPostProgress({ path: item.path, percent: 5, label: "Starting post..." });
    setFeedEditStatus(`Posting ${item.title} to Bluesky...`);
    const token = chatGatewayToken.trim() || undefined;
    try {
      if (item.kind === "text") {
        setPostProgress({ path: item.path, percent: 25, label: "Loading text..." });
        const content =
          feedDraftsByPath[item.path]?.trim()
            ? feedDraftsByPath[item.path]
            : await readLibraryText(item.path, token, gatewayBaseUrl);
        setPostProgress({ path: item.path, percent: 70, label: "Publishing text..." });
        const bluesky = await loadBlueskyModule();
        const result = await bluesky.postTextToBluesky(agent, session.did, content.trim());
        await persistHistory({
          provider: "bluesky",
          text: content.trim(),
          sourcePath: item.path,
          created: new Date().toISOString(),
          uri: result.uri,
          cid: result.cid,
          status: "success"
        });
        const { archivedPath, archiveError } = await archivePostedFeedSource(item.path, token);

        setPostProgress({ path: item.path, percent: 100, label: "Posted." });
        setFeedEditStatus(
          archiveError
            ? `Posted text: ${result.uri} (archive failed: ${archiveError})`
            : archivedPath
              ? `Posted text: ${result.uri} (archived: ${archivedPath})`
              : `Posted text: ${result.uri}`
        );
      } else if (item.kind === "video") {
        if (!item.mediaUrl) {
          throw new Error("Missing media URL");
        }
        const filename = item.path.split("/").pop() || "video.mp4";
        setPostProgress({ path: item.path, percent: 12, label: "Fetching video file..." });
        const file = await fetchMediaAsFile(item.mediaUrl, filename, token, gatewayBaseUrl);
        const caption = feedDraftsByPath[item.path] ?? item.previewText ?? item.title;
        const bluesky = await loadBlueskyModule();
        const result = await bluesky.postVideoToBluesky(
          agent,
          creds.serviceUrl,
          session.accessJwt,
          session.did,
          (caption || "").slice(0, 300),
          file,
          item.title,
          (progress) => {
            setPostProgress({
              path: item.path,
              percent: Math.max(10, Math.min(100, Math.round(progress.percent))),
              label: progress.message
            });
          }
        );
        await persistHistory({
          provider: "bluesky",
          text: caption || item.title,
          sourcePath: item.path,
          videoName: filename,
          created: new Date().toISOString(),
          uri: result.uri,
          cid: result.cid,
          status: "success"
        });
        const { archivedPath, archiveError } = await archivePostedFeedSource(item.path, token);

        setPostProgress({ path: item.path, percent: 100, label: "Posted." });
        setFeedEditStatus(
          archiveError
            ? `Posted video: ${result.uri} (archive failed: ${archiveError})`
            : archivedPath
              ? `Posted video: ${result.uri} (archived: ${archivedPath})`
              : `Posted video: ${result.uri}`
        );
      } else {
        throw new Error(`Posting not supported for ${item.kind}`);
      }
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      await persistHistory({
        provider: "bluesky",
        text: item.title,
        videoName: item.kind === "video" ? item.path.split("/").pop() : undefined,
        created: new Date().toISOString(),
        status: "error",
        error: message
      });
      setFeedEditStatus(`Post failed (${message})`);
      setPostProgress({ path: item.path, percent: 0, label: `Failed: ${message}` });
    } finally {
      setPostingFeedPath("");
      window.setTimeout(() => {
        setPostProgress((current) =>
          current && current.path === item.path && current.percent >= 100 ? null : current
        );
      }, 2000);
    }
  }

  async function saveSelectedJournalText() {
    if (!selectedJournalItem || selectedJournalItem.kind !== "text") {
      return;
    }
    const token = normalizeGatewayToken(chatGatewayToken) || undefined;
    setJournalSaveStatus(`Saving ${selectedJournalItem.path}...`);
    try {
      const localId = localJournalIdFromPath(selectedJournalItem.path);
      if (localId) {
        try {
          await updateJournalText(localId, selectedJournalText);
        } catch (localError) {
          if (!isMissingDesktopCommand(localError, "update_journal_text")) {
            throw localError;
          }
          const created = await createJournalTextViaGateway(
            "Journal entry",
            selectedJournalText,
            token,
            gatewayBaseUrl
          );
          const createdPath = String(created.path || "").trim();
          if (createdPath) {
            setSelectedJournalPath(createdPath);
          }
        }
      } else {
        try {
          await saveLibraryText(selectedJournalItem.path, selectedJournalText, token, gatewayBaseUrl);
        } catch (gatewayError) {
          if (!isDesktopClient) {
            throw gatewayError;
          }
          try {
            await saveJournalText("Journal entry", selectedJournalText);
          } catch (localError) {
            if (isMissingDesktopCommand(localError, "save_journal_text")) {
              throw gatewayError;
            }
            throw localError;
          }
        }
      }
      holdJournalStatus(`Saved ${selectedJournalItem.path}`);
      await refreshLibrary("journal");
    } catch (error) {
      setJournalSaveStatus(
        `Save failed (${error instanceof Error ? error.message : String(error)})`
      );
    }
  }

  async function refreshDrafts() {
    try {
      const result = await listDraftsViaGateway(chatGatewayToken.trim() || undefined, gatewayBaseUrl);
      setDrafts(
        result.map((item) => ({
          id: String(item.id || ""),
          text: String(item.text || ""),
          videoName: String(item.videoName || ""),
          created: String(item.created || ""),
          updated: String(item.updated || "")
        }))
      );
    } catch (error) {
      setStatus(
        `Drafts unavailable (${error instanceof Error ? error.message : String(error)})`
      );
    }
  }

  async function refreshClawChat() {
    if (!gatewayBaseUrl.trim()) {
      return;
    }
    try {
      let token = chatGatewayToken.trim();
      if (!token && isDesktopClient) {
        token = (await syncDesktopGatewayBootstrap())?.trim() || "";
      }
      let threadId = chatThreadId.trim();
      if (!threadId) {
        setChatMessages([]);
        setChatStatus("No chat thread yet. Send a message to start.");
        return;
      }

      const items = await listClawChatMessages(threadId, token, gatewayBaseUrl);

      setChatMessages(items);
      setChatStatus(`Chat thread loaded (${items.length} messages)`);
    } catch (error) {
      setChatStatus(
        `Chat unavailable (${error instanceof Error ? error.message : String(error)})`
      );
    }
  }

  async function handleLogin(e: FormEvent) {
    e.preventDefault();
    setAuthMessage("Signing in...");
    try {
      const bluesky = await loadBlueskyModule();
      const { agent: nextAgent, session: nextSession } = await bluesky.loginBluesky(creds);
      setAgent(nextAgent);
      setSession(nextSession);
      await saveBlueskySessionSecure(nextSession);
      if (isDesktopClient) {
        try {
          await restartGatewayDaemonFromDesktop();
          setAuthMessage(`Signed in as ${nextSession.handle}. Gateway restarted with new credentials.`);
        } catch (error) {
          setAuthMessage(
            `Signed in as ${nextSession.handle}, but gateway restart failed (${error instanceof Error ? error.message : String(error)}).`
          );
        }
      } else {
        setAuthMessage(`Signed in as ${nextSession.handle}`);
      }
    } catch (error) {
      setAgent(null);
      setSession(null);
      setAuthMessage(
        `Bluesky login failed: ${error instanceof Error ? error.message : String(error)}`
      );
    }
  }

  async function saveDraft() {
    const draft: StoredDraft = {
      text,
      videoName: videoFile?.name || "",
      created: new Date().toISOString()
    };
    try {
      await saveDraftViaGateway(draft, chatGatewayToken.trim() || undefined, gatewayBaseUrl);
      setStatus("Draft saved");
      await refreshDrafts();
    } catch (error) {
      setStatus(
        `Failed to save draft (${error instanceof Error ? error.message : String(error)})`
      );
    }
  }

  async function persistHistory(item: PostHistoryItem) {
    setHistory((prev) => [item, ...prev].slice(0, 20));
    try {
      await createPostHistory(item, chatGatewayToken.trim() || undefined, gatewayBaseUrl);
    } catch {
      // Local UI history remains available even if history sync fails.
    }
  }

  async function refreshPostHistory() {
    try {
      const items = await listPostHistoryViaGateway(chatGatewayToken.trim() || undefined, gatewayBaseUrl);
      setHistory((prev) => {
        if (prev.length === 0) {
          return items.slice(0, 20);
        }
        return prev;
      });
    } catch {
      // Keep local-only history if backend query fails.
    }
  }

  async function postToBluesky() {
    if (!agent || !session) {
      setStatus("Sign in to Bluesky first");
      return;
    }
    if (!text.trim() && !videoFile) {
      setStatus("Enter post text or choose a video");
      return;
    }

    setIsPosting(true);
    setStatus("Posting to Bluesky...");
    try {
      const result = videoFile
        ? await (await loadBlueskyModule()).postVideoToBluesky(
          agent,
          creds.serviceUrl,
          session.accessJwt,
          session.did,
          text,
          videoFile,
          videoAlt
        )
        : await (await loadBlueskyModule()).postTextToBluesky(agent, session.did, text);

      const item: PostHistoryItem = {
        provider: "bluesky",
        text,
        videoName: videoFile?.name,
        uri: result.uri,
        cid: result.cid,
        created: new Date().toISOString(),
        status: "success"
      };
      await persistHistory(item);
      setStatus(`Posted successfully: ${result.uri}`);
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      await persistHistory({
        provider: "bluesky",
        text,
        videoName: videoFile?.name,
        created: new Date().toISOString(),
        status: "error",
        error: message
      });
      setStatus(`Post failed: ${message}`);
    } finally {
      setIsPosting(false);
    }
  }

  async function sendClawChatMessage() {
    const content = chatInput.trim();
    if (!content) {
      setChatStatus("Enter a message first");
      return;
    }

    setChatSending(true);
    setChatStatus("Sending message...");
    try {
      let token = chatGatewayToken.trim();
      if (!token && isDesktopClient) {
        token = (await syncDesktopGatewayBootstrap())?.trim() || "";
      }
      if (!token) {
        if (isDesktopClient) {
          token = "desktop-local";
        } else {
          setChatStatus("Chat blocked (gateway token missing). Pair mobile with desktop QR.");
          return;
        }
      }
      let threadId = chatThreadId.trim();
      if (!threadId) {
        threadId = createThreadId();
        setChatThreadId(threadId);
      }
      await createClawChatUserMessageViaGateway(threadId, content, token, gatewayBaseUrl);
      setChatInput("");
      setChatStatus("Message queued (waiting for SlowClaw reply)");
    } catch (error) {
      setChatStatus(
        `Failed to queue chat message (${error instanceof Error ? error.message : String(error)})`
      );
    } finally {
      setChatSending(false);
    }
  }

  async function fetchAudioDevices() {
    try {
      const devices = await navigator.mediaDevices.enumerateDevices();
      const audioInputDevices = devices.filter(device => device.kind === 'audioinput');
      setAudioDevices(audioInputDevices);
      if (audioInputDevices.length > 0 && !selectedAudioDeviceId) {
        setSelectedAudioDeviceId(audioInputDevices[0].deviceId);
      }
    } catch (err) {
      console.error("Error enumerating devices", err);
    }
  }

  useEffect(() => {
    void fetchAudioDevices();
  }, []);

  useEffect(() => {
    if (!isRecording || recordingType !== "audio" || !audioCanvasRef.current) {
      return;
    }
    if (animationFrameRef.current) {
      cancelAnimationFrame(animationFrameRef.current);
      animationFrameRef.current = null;
    }
    drawAudioVisualizer();
  }, [isRecording, recordingType, themeMode]);

  useEffect(() => {
    if (!isRecording || recordingType !== "video" || !videoPreviewRef.current || !mediaStreamRef.current) {
      return;
    }
    const video = videoPreviewRef.current;
    if (video.srcObject !== mediaStreamRef.current) {
      video.srcObject = mediaStreamRef.current;
    }
    video.play().catch(() => {
      // Preview can fail silently on some platforms; recording still proceeds.
    });
  }, [isRecording, recordingType, videoOrientation]);

  function drawAudioVisualizer() {
    if (!audioCanvasRef.current) return;
    const canvas = audioCanvasRef.current;
    const ctx = canvas.getContext("2d");
    if (!ctx) return;

    const analyser = analyserRef.current;
    const bg = themeMode === "dark" ? "#121417" : "#f2f6f4";
    const line = themeMode === "dark" ? "#36d3a6" : "#169b79";
    const centerLine = themeMode === "dark" ? "rgba(255,255,255,0.14)" : "rgba(0,0,0,0.12)";
    const dpr = Math.max(1, Math.min(2, window.devicePixelRatio || 1));
    const cssWidth = canvas.clientWidth || 720;
    const cssHeight = canvas.clientHeight || 170;
    const targetWidth = Math.floor(cssWidth * dpr);
    const targetHeight = Math.floor(cssHeight * dpr);
    if (canvas.width !== targetWidth || canvas.height !== targetHeight) {
      canvas.width = targetWidth;
      canvas.height = targetHeight;
    }
    const width = canvas.width;
    const height = canvas.height;
    const bufferLength = analyser ? analyser.frequencyBinCount : 256;
    const dataArray = new Uint8Array(bufferLength);
    let syntheticT = 0;

    function draw() {
      animationFrameRef.current = requestAnimationFrame(draw);
      if (analyser) {
        analyser.getByteTimeDomainData(dataArray);
      } else {
        syntheticT += 0.08;
      }
      if (!ctx) return;

      ctx.fillStyle = bg;
      ctx.fillRect(0, 0, width, height);
      ctx.strokeStyle = centerLine;
      ctx.lineWidth = Math.max(1, dpr);
      ctx.beginPath();
      ctx.moveTo(0, height / 2);
      ctx.lineTo(width, height / 2);
      ctx.stroke();

      ctx.lineWidth = Math.max(2, 2 * dpr);
      ctx.strokeStyle = line;
      ctx.beginPath();

      const sliceWidth = width / bufferLength;
      let x = 0;

      for (let i = 0; i < bufferLength; i++) {
        let y = height / 2;
        if (analyser) {
          const v = dataArray[i] / 128.0;
          y = v * (height / 2);
        } else {
          const amp = Math.sin((i / 16) + syntheticT) * (height * 0.12);
          const wobble = Math.sin((i / 7) + syntheticT * 1.3) * (height * 0.05);
          y = (height / 2) + amp + wobble;
        }

        if (i === 0) {
          ctx.moveTo(x, y);
        } else {
          ctx.lineTo(x, y);
        }
        x += sliceWidth;
      }
      ctx.lineTo(width, height / 2);
      ctx.stroke();
    }
    draw();
  }

  async function startLiveRecording(type: "audio" | "video") {
    if (isRecording) {
      return;
    }
    try {
      const isTauriRuntime =
        typeof window !== "undefined" &&
        (Boolean((window as any).__TAURI_INTERNALS__) || Boolean((window as any).__TAURI_MOBILE__));
      const isMobileRuntime = isTauriMobileRuntime();
      const hasGetUserMedia =
        typeof navigator !== "undefined" &&
        !!navigator.mediaDevices &&
        typeof navigator.mediaDevices.getUserMedia === "function";
      const hasMediaRecorder =
        typeof window !== "undefined" &&
        typeof (window as any).MediaRecorder !== "undefined";
      const insecureContext =
        typeof window !== "undefined" &&
        !window.isSecureContext &&
        !isTauriRuntime &&
        window.location.hostname !== "localhost" &&
        window.location.hostname !== "127.0.0.1";

      if (type === "audio" && isMobileRuntime) {
        setRecordingHint("Starting audio recording...");
        setRecordingType("audio");
        setIsRecording(true);
        setRecordingTime(0);
        recordingChunksRef.current = [];
        syntheticAudioVizRef.current = true;
        analyserRef.current = null;
        await startNativeAudioRecording();
        drawAudioVisualizer();
        recordingTimerRef.current = window.setInterval(() => {
          setRecordingTime((prev) => prev + 1);
        }, 1000);
        setRecordingHint("Recording audio...");
        return;
      }

      // For Tauri runtimes, skip the capability bail-out: WKWebView (macOS) and
      // WebView2 (Windows) lazily expose navigator.mediaDevices depending on
      // entitlements / permissions.  Let the try/catch surface specific, actionable
      // errors (permission denied, device not found, timeout, etc.) rather than a
      // generic "not supported" wall.
      if (!isTauriRuntime && (!hasGetUserMedia || !hasMediaRecorder || insecureContext)) {
        setRecordingHint(
          insecureContext
            ? `Recording requires a secure context (HTTPS or localhost).`
            : `${type === "audio" ? "Microphone" : "Camera"} recording is not supported in this browser.`
        );
        setCaptureMode(null);
        return;
      }

      setRecordingHint(`Starting ${type === "audio" ? "microphone" : "camera"}…`);
      setRecordingType(type);
      setIsRecording(true);
      setRecordingTime(0);
      recordingChunksRef.current = [];

      const constraints: MediaStreamConstraints = {};
      if (type === "audio") {
        constraints.audio = selectedAudioDeviceId ? { deviceId: { exact: selectedAudioDeviceId } } : true;
      } else {
        constraints.audio = true;
        const isVertical = videoOrientation === "vertical";
        constraints.video = {
          facingMode: "user",
          width: { ideal: isVertical ? 720 : 1280 },
          height: { ideal: isVertical ? 1280 : 720 },
          aspectRatio: { ideal: isVertical ? 9 / 16 : 16 / 9 }
        };
      }

      // getUserMedia can hang forever when the OS permission prompt never
      // appears (e.g. missing entitlements on macOS Tauri).  Race it against
      // a timeout so the UI doesn't freeze.
      const gumPromise = navigator.mediaDevices.getUserMedia(constraints);
      const timeoutMs = 15_000;
      const timeoutPromise = new Promise<never>((_resolve, reject) => {
        setTimeout(
          () => reject(new DOMException(
            "Timed out waiting for media access — check system privacy settings.",
            "TimeoutError"
          )),
          timeoutMs
        );
      });

      const stream = await Promise.race([gumPromise, timeoutPromise]);
      mediaStreamRef.current = stream;

      // Re-enumerate now that permission has been granted — labels and deviceIds
      // are only populated after the first getUserMedia call succeeds.
      void fetchAudioDevices();

      if (type === "audio") {
        const audioCtx = new AudioContext();
        audioContextRef.current = audioCtx;
        const source = audioCtx.createMediaStreamSource(stream);
        const analyser = audioCtx.createAnalyser();
        analyser.fftSize = 2048;
        source.connect(analyser);
        analyserRef.current = analyser;
        syntheticAudioVizRef.current = false;
        audioPcmChunksRef.current = [];
        audioSampleRateRef.current = audioCtx.sampleRate;
        usingWavAudioCaptureRef.current = true;

        const processor = audioCtx.createScriptProcessor(4096, 1, 1);
        const captureGain = audioCtx.createGain();
        captureGain.gain.value = 0;
        processor.onaudioprocess = (event) => {
          const input = event.inputBuffer.getChannelData(0);
          audioPcmChunksRef.current.push(new Float32Array(input));
        };
        source.connect(processor);
        processor.connect(captureGain);
        captureGain.connect(audioCtx.destination);
        audioProcessorRef.current = processor;
        audioCaptureGainRef.current = captureGain;
        drawAudioVisualizer();
      } else if (type === "video" && videoPreviewRef.current) {
        videoPreviewRef.current.srcObject = stream;
        videoPreviewRef.current.play().catch(console.error);

        const isMacDesktop = (() => {
          if (typeof navigator === "undefined") {
            return false;
          }
          const platform = String(navigator.platform || "").toLowerCase();
          const userAgent = String(navigator.userAgent || "").toLowerCase();
          return platform.includes("mac") || userAgent.includes("mac os");
        })();

        const pickMimeType = (kind: "audio" | "video"): string => {
          const candidates = kind === "audio"
            ? [
                "audio/webm;codecs=opus",
                "audio/webm",
                "audio/ogg;codecs=opus",
                "audio/ogg",
                "audio/mp4"
              ]
            : isMacDesktop
              ? ["video/mp4;codecs=avc1,mp4a.40.2", "video/mp4", "video/webm;codecs=vp9,opus", "video/webm;codecs=vp8,opus", "video/webm"]
              : ["video/webm;codecs=vp9,opus", "video/webm;codecs=vp8,opus", "video/webm", "video/mp4;codecs=avc1,mp4a.40.2", "video/mp4"];
          return candidates.find((t) => {
            try { return MediaRecorder.isTypeSupported(t); } catch { return false; }
          }) ?? "";
        };
        const mimeType = pickMimeType(type);
        const recorderOptions = mimeType ? { mimeType } : {};
        const mediaRecorder = new MediaRecorder(stream, recorderOptions);
        mediaRecorderRef.current = mediaRecorder;

        mediaRecorder.ondataavailable = (event) => {
          if (event.data.size > 0) {
            recordingChunksRef.current.push(event.data);
          }
        };

        mediaRecorder.onstop = async () => {
          if (recordingChunksRef.current.length > 0) {
            const actualMime = mediaRecorder.mimeType || "video/webm";
            const ext = actualMime.includes("mp4") ? "mp4" : actualMime.includes("ogg") ? "ogg" : "webm";
            const blob = new Blob(recordingChunksRef.current, { type: actualMime });
            const file = new File([blob], `${type}-${Date.now()}.${ext}`, { type: actualMime });
            await uploadJournalFile(file, type);
          }
          cleanupRecording();
        };

        mediaRecorder.start(1000);
      }
      recordingTimerRef.current = window.setInterval(() => {
        setRecordingTime(prev => prev + 1);
      }, 1000);
      setRecordingHint(`Recording ${type}...`);

    } catch (err) {
      const device = type === "audio" ? "Microphone" : "Camera";
      let hint = `Failed to start recording: ${err instanceof Error ? err.message : String(err)}`;

      // TypeError: navigator.mediaDevices is undefined / getUserMedia is not a function
      if (err instanceof TypeError) {
        hint = `${device} API is unavailable. On macOS, open System Settings → Privacy & Security → ${device} and ensure this app is allowed.`;
      } else if (err instanceof DOMException) {
        switch (err.name) {
          case "NotAllowedError":
          case "PermissionDeniedError":
            hint = `${device} access was denied. Please allow ${device.toLowerCase()} permission in System Settings → Privacy & Security.`;
            break;
          case "NotFoundError":
          case "DevicesNotFoundError":
            hint = `No ${device.toLowerCase()} found. Please connect one and try again.`;
            break;
          case "NotReadableError":
          case "TrackStartError":
            hint = `${device} is in use by another application. Please close it and try again.`;
            break;
          case "TimeoutError":
            hint = `Timed out waiting for ${device.toLowerCase()} access. Open System Settings → Privacy & Security → ${device} and ensure this app is allowed, then try again.`;
            break;
          case "OverconstrainedError":
            hint = `The selected ${device.toLowerCase()} couldn't satisfy the requested settings. Retrying with defaults…`;
            try {
              const fallback = await navigator.mediaDevices.getUserMedia(
                type === "audio" ? { audio: true } : { audio: true, video: true }
              );
              fallback.getTracks().forEach((t) => t.stop());
            } catch {
              // Suppress — hint already set
            }
            break;
        }
      }
      setRecordingHint(hint);
      setCaptureMode(null);
      cleanupRecording();
    }
  }

  async function stopLiveRecording() {
    if (!isRecording) {
      return;
    }
    if (recordingTimerRef.current) {
      clearInterval(recordingTimerRef.current);
      recordingTimerRef.current = null;
    }
    setRecordingHint("Processing recording...");
    if (recordingType === "audio" && isTauriMobileRuntime() && !mediaRecorderRef.current) {
      try {
        const blob = await stopNativeAudioRecording();
        const file = new File([blob], `audio-${Date.now()}.m4a`, {
          type: blob.type || "audio/m4a"
        });
        await uploadJournalFile(file, "audio");
      } catch (error) {
        setRecordingHint(
          `Failed to save recording: ${error instanceof Error ? error.message : String(error)}`
        );
      } finally {
        cleanupRecording();
      }
      return;
    }
    if (recordingType === "audio" && usingWavAudioCaptureRef.current && !mediaRecorderRef.current) {
      try {
        const blob = encodeWavFromFloat32(audioPcmChunksRef.current, audioSampleRateRef.current);
        const file = new File([blob], `audio-${Date.now()}.wav`, {
          type: "audio/wav"
        });
        await uploadJournalFile(file, "audio");
      } catch (error) {
        setRecordingHint(
          `Failed to save recording: ${error instanceof Error ? error.message : String(error)}`
        );
      } finally {
        cleanupRecording();
      }
      return;
    }
    if (mediaRecorderRef.current) {
      mediaRecorderRef.current.stop();
      return;
    }
    cleanupRecording();
  }

  async function cancelRecording() {
    if (!isRecording) {
      setCaptureMode(null);
      cleanupRecording();
      return;
    }
    if (recordingTimerRef.current) {
      clearInterval(recordingTimerRef.current);
      recordingTimerRef.current = null;
    }
    if (recordingType === "audio" && isTauriMobileRuntime() && !mediaRecorderRef.current) {
      try {
        await stopNativeAudioRecording();
      } catch {
        // Ignore native stop errors on cancel.
      } finally {
        setRecordingHint("Recording cancelled.");
        cleanupRecording();
      }
      return;
    }
    if (recordingType === "audio" && usingWavAudioCaptureRef.current && !mediaRecorderRef.current) {
      audioPcmChunksRef.current = [];
      setRecordingHint("Recording cancelled.");
      cleanupRecording();
      return;
    }
    if (mediaRecorderRef.current && isRecording) {
      recordingChunksRef.current = [];
      mediaRecorderRef.current.stop();
      setRecordingHint("Recording cancelled.");
    } else {
      setCaptureMode(null);
      cleanupRecording();
    }
  }

  function cleanupRecording() {
    if (mediaStreamRef.current) {
      mediaStreamRef.current.getTracks().forEach(track => track.stop());
      mediaStreamRef.current = null;
    }
    if (audioContextRef.current) {
      void audioContextRef.current.close();
      audioContextRef.current = null;
    }
    if (audioProcessorRef.current) {
      audioProcessorRef.current.disconnect();
      audioProcessorRef.current = null;
    }
    if (audioCaptureGainRef.current) {
      audioCaptureGainRef.current.disconnect();
      audioCaptureGainRef.current = null;
    }
    if (animationFrameRef.current) {
      cancelAnimationFrame(animationFrameRef.current);
      animationFrameRef.current = null;
    }
    syntheticAudioVizRef.current = false;
    analyserRef.current = null;
    audioPcmChunksRef.current = [];
    usingWavAudioCaptureRef.current = false;
    mediaRecorderRef.current = null;
    if (videoPreviewRef.current) {
      videoPreviewRef.current.srcObject = null;
    }
    setIsRecording(false);
    setRecordingType(null);
    setRecordingTime(0);
    setCaptureMode(null);
  }

  function isJwtExpired(jwt: string): boolean {
    try {
      const [, payload] = jwt.split(".");
      if (!payload) return true;
      const normalized = payload.replace(/-/g, "+").replace(/_/g, "/");
      const padded = normalized + "=".repeat((4 - (normalized.length % 4)) % 4);
      const data = JSON.parse(atob(padded)) as { exp?: number };
      if (typeof data.exp !== "number") return false;
      // Consider expired if less than 60 seconds remaining
      return data.exp < Math.floor(Date.now() / 1000) + 60;
    } catch {
      return false;
    }
  }

  async function ensureBlueskySession(): Promise<string | undefined> {
    // Try existing session — but only if token is not expired
    const existingJwt = session?.accessJwt;
    if (existingJwt && !isJwtExpired(existingJwt)) {
      return existingJwt;
    }

    // Token expired or missing — try refresh token first
    const refreshToken = session?.refreshJwt;
    if (refreshToken && creds.serviceUrl) {
      try {
        const bluesky = await loadBlueskyModule();
        const refreshed = await bluesky.refreshBlueskySession(creds.serviceUrl, refreshToken);
        setAgent(refreshed.agent);
        setSession(refreshed.session);
        await saveBlueskySessionSecure(refreshed.session);
        setAuthMessage(`Session refreshed for ${refreshed.session.handle}`);
        return refreshed.session.accessJwt;
      } catch {
        // Refresh token also expired, fall through to re-login
      }
    }

    // Fall back to re-login with stored credentials
    if (creds.handle.trim() && creds.appPassword.trim()) {
      try {
        const bluesky = await loadBlueskyModule();
        const { agent: freshAgent, session: freshSession } = await bluesky.loginBluesky(creds);
        setAgent(freshAgent);
        setSession(freshSession);
        await saveBlueskySessionSecure(freshSession);
        setAuthMessage(`Signed in as ${freshSession.handle}`);
        return freshSession.accessJwt;
      } catch (loginErr) {
        console.warn("Bluesky auto-login failed:", loginErr);
      }
    }

    return undefined;
  }

  function stopFeedPoll() {
    if (feedPollTimerRef.current !== undefined) {
      window.clearInterval(feedPollTimerRef.current);
      feedPollTimerRef.current = undefined;
    }
  }

  function startFeedPoll(knownGeneration: number | undefined) {
    stopFeedPoll();
    let trackedGen = knownGeneration;
    feedPollTimerRef.current = window.setInterval(async () => {
      try {
        const jwt = session?.accessJwt;
        const res = await fetchPersonalizedFeed(
          {
            serviceUrl: creds.serviceUrl.trim() || undefined,
            accessJwt: jwt,
            limit: 50,
          },
          chatGatewayToken,
          gatewayBaseUrl
        );
        if (res.generation !== undefined && res.generation !== trackedGen) {
          // New data available — stash it for the banner
          pendingFeedItemsRef.current = res;
          setFeedNewPostsBanner(true);
          trackedGen = res.generation;
        }
        // Stop polling when refresh is complete
        if (
          res.refreshState !== "refreshing" &&
          res.refreshState !== "warming" &&
          res.refreshStatus !== "ranking" &&
          res.refreshStatus !== "discovering"
        ) {
          stopFeedPoll();
        }
      } catch {
        // Ignore poll errors
      }
    }, 4000);
  }

  async function fetchBlueskyFeed(options?: { force?: boolean }) {
    setBlueskyFeedLoading(true);
    setBlueskyFeedStatus("");

    async function doFetch(jwt: string | undefined) {
      return await fetchPersonalizedFeed(
        {
          serviceUrl: creds.serviceUrl.trim() || undefined,
          accessJwt: jwt,
          limit: 50,
          force: options?.force
        },
        chatGatewayToken,
        gatewayBaseUrl
      );
    }

    async function forceRefreshSession(): Promise<string | undefined> {
      // Force a fresh login regardless of current session state
      if (creds.handle.trim() && creds.appPassword.trim()) {
        try {
          const bluesky = await loadBlueskyModule();
          const { agent: freshAgent, session: freshSession } = await bluesky.loginBluesky(creds);
          setAgent(freshAgent);
          setSession(freshSession);
          await saveBlueskySessionSecure(freshSession);
          setAuthMessage(`Re-authenticated as ${freshSession.handle}`);
          return freshSession.accessJwt;
        } catch (loginErr) {
          console.warn("Bluesky force re-login failed:", loginErr);
        }
      }
      return undefined;
    }

    try {
      let activeJwt = await ensureBlueskySession();
      let res: PersonalizedFeedResponse;
      try {
        res = await doFetch(activeJwt);
      } catch (error) {
        // On expired token error, force re-login and retry once
        const bluesky = await loadBlueskyModule();
        if (bluesky.isExpiredTokenError(error) || (error instanceof Error && /ExpiredToken/i.test(error.message))) {
          activeJwt = await forceRefreshSession();
          res = await doFetch(activeJwt);
        } else {
          throw error;
        }
      }

      // Merge new items on top of existing, dedup by URI/URL
      const existingKeys = new Set(
        blueskyFeedItems.map((item) => {
          if (item.sourceType === "bluesky") {
            return (item.feedItem as any)?.post?.uri || "";
          }
          return item.webPreview?.url || "";
        }).filter(Boolean)
      );
      const newItems = res.items.filter((item) => {
        const key = item.sourceType === "bluesky"
          ? (item.feedItem as any)?.post?.uri || ""
          : item.webPreview?.url || "";
        return key && !existingKeys.has(key);
      });
      if (blueskyFeedItems.length > 0 && newItems.length > 0) {
        setBlueskyFeedItems([...newItems, ...blueskyFeedItems]);
      } else {
        setBlueskyFeedItems(res.items);
      }

      setBlueskyFeedSnapshot(res);
      setBlueskyProfileStats(res.profileStats);
      setFeedGeneration(res.generation);

      // Start polling if a refresh is in progress, stop if done
      if (res.refreshState === "refreshing" || res.refreshState === "warming" || res.refreshStatus === "ranking" || res.refreshStatus === "discovering") {
        startFeedPoll(res.generation);
      } else {
        stopFeedPoll();
        setFeedNewPostsBanner(false);
      }

      const refreshedLabel = res.refreshedAt
        ? ` Last refresh ${formatTimestamp(res.refreshedAt)}.`
        : "";
      const shortlistedLabel = res.selectedSources.length
        ? ` ${res.selectedSources.length} source${res.selectedSources.length === 1 ? "" : "s"} shortlisted.`
        : "";
      const newLabel = newItems.length > 0 ? `${newItems.length} new. ` : "";
      if (res.profileStatus === "embeddingUnavailable") {
        setBlueskyFeedStatus(
          res.message ||
            `Personalized feed needs a configured embedding provider. Ranked matching is disabled until embeddings are available.${refreshedLabel}`
        );
      } else if (res.profileStatus === "noInterests") {
        setBlueskyFeedStatus(
          res.message || `Personalized feed starts after text items exist under posts/ or journals/.${refreshedLabel}`
        );
      } else if (res.refreshState === "refreshing") {
        setBlueskyFeedStatus(
          res.message || `${newLabel}Updating the world feed in the background. Showing the last ranked snapshot.${refreshedLabel}${shortlistedLabel}`
        );
      } else if (res.refreshState === "stale") {
        setBlueskyFeedStatus(
          res.message || `${newLabel}Refresh is overdue. Showing the last ranked snapshot until a new pass completes.${refreshedLabel}${shortlistedLabel}`
        );
      } else if (res.usedFallback) {
        setBlueskyFeedStatus(
          res.message || `${newLabel}Showing fallback content, not a fully ranked world feed yet.${refreshedLabel}${shortlistedLabel}`
        );
      } else {
        setBlueskyFeedStatus(
          res.message ||
            (res.profileStats.interestCount > 0
              ? `${newLabel}Ranked by ${res.profileStats.interestCount} workspace interests.${refreshedLabel}${shortlistedLabel}`
              : `${newLabel}${refreshedLabel.trim()}`)
        );
      }
    } catch (error) {
      console.error("Failed to fetch world feed", error);
      setBlueskyFeedStatus(error instanceof Error ? error.message : "Failed to load world feed.");
      if (blueskyFeedItems.length === 0) {
        setBlueskyFeedItems([]);
        setBlueskyFeedSnapshot(null);
      }
    } finally {
      setBlueskyFeedLoading(false);
    }
  }

  async function handleLikeBlueskyPost(postUri: string, postCid: string) {
    if (!agent || !session) return;
    if (blueskyLikedUris[postUri]) {
      // Unlike
      const likeUri = blueskyLikedUris[postUri];
      try {
        const bluesky = await loadBlueskyModule();
        await bluesky.unlikeBlueskyPost(agent, likeUri);
        setBlueskyLikedUris((prev) => {
          const next = { ...prev };
          delete next[postUri];
          return next;
        });
      } catch (err) {
        console.error("Unlike failed:", err);
      }
    } else {
      // Like
      try {
        const bluesky = await loadBlueskyModule();
        const res = await bluesky.likeBlueskyPost(agent, session.did, postUri, postCid);
        setBlueskyLikedUris((prev) => ({ ...prev, [postUri]: res.uri }));
      } catch (err) {
        console.error("Like failed:", err);
      }
    }
  }

  async function handleExpandThread(postUri: string) {
    if (expandedThreadUri === postUri) {
      setExpandedThreadUri("");
      setThreadData(null);
      return;
    }
    setExpandedThreadUri(postUri);
    setThreadLoading(true);
    setThreadData(null);
    try {
      const bluesky = await loadBlueskyModule();
      const serviceUrl = creds.serviceUrl.trim() || "https://public.api.bsky.app";
      const jwt = session?.accessJwt || "";
      const data = await bluesky.fetchBlueskyThread(serviceUrl, jwt, postUri);
      setThreadData(data);
    } catch (err) {
      console.error("Failed to fetch thread:", err);
      setThreadData({ error: err instanceof Error ? err.message : "Failed to load thread" });
    } finally {
      setThreadLoading(false);
    }
  }

  async function handleReplyToBlueskyPost(parentUri: string, parentCid: string, rootUri: string, rootCid: string) {
    const text = replyDrafts[parentUri]?.trim();
    if (!text || !agent || !session) return;
    setReplyingUri(parentUri);
    try {
      const bluesky = await loadBlueskyModule();
      await bluesky.replyToBlueskyPost(agent, session.did, text, parentUri, parentCid, rootUri, rootCid);
      setReplyDrafts((prev) => {
        const next = { ...prev };
        delete next[parentUri];
        return next;
      });
      // Refresh thread to show new reply
      const serviceUrl = creds.serviceUrl.trim() || "https://public.api.bsky.app";
      const data = await bluesky.fetchBlueskyThread(serviceUrl, session.accessJwt, expandedThreadUri || parentUri);
      setThreadData(data);
    } catch (err) {
      console.error("Reply failed:", err);
    } finally {
      setReplyingUri("");
    }
  }

  async function ensureNostrKeys(): Promise<NostrKeys | null> {
    if (nostrKeys) return nostrKeys;
    setNostrKeysBusy(true);
    try {
      const nostrModule = await import("./lib/nostr");
      const keys = await nostrModule.generateNostrKeys();
      await saveNostrKeysSecure(keys);
      setNostrKeys(keys);
      return keys;
    } catch (err) {
      console.error("Failed to generate Nostr keys:", err);
      return null;
    } finally {
      setNostrKeysBusy(false);
    }
  }

  async function handleNostrReaction(eventId: string, relayUrl: string) {
    const keys = await ensureNostrKeys();
    if (!keys) return;
    try {
      const nostrModule = await import("./lib/nostr");
      const event = await nostrModule.createSignedEvent(keys, 7, "+", [["e", eventId], ["p", ""]]);
      await nostrModule.publishToRelay(relayUrl, event);
    } catch (err) {
      console.error("Nostr reaction failed:", err);
    }
  }

  async function handleNostrReply(eventId: string, relayUrl: string, content: string) {
    const keys = await ensureNostrKeys();
    if (!keys || !content.trim()) return;
    try {
      const nostrModule = await import("./lib/nostr");
      const event = await nostrModule.createSignedEvent(keys, 1, content.trim(), [["e", eventId, relayUrl, "reply"]]);
      await nostrModule.publishToRelay(relayUrl, event);
    } catch (err) {
      console.error("Nostr reply failed:", err);
    }
  }

  async function fetchVideoFallback() {
    if (videoFallbackLoading || videoFallbackItems.length > 0) return;
    setVideoFallbackLoading(true);
    const results: any[] = [];
    try {
      // Fetch from Bluesky "videos" feed generator (whats-hot-video)
      const activeJwt = session?.accessJwt;
      if (activeJwt) {
        try {
          const serviceUrl = (creds.serviceUrl.trim() || "https://bsky.social").replace(/\/+$/, "");
          const feedUri = "at://did:plc:qh3lfd7q24h3fn3pejqr25ct/app.bsky.feed.generator/videos";
          const url = `${serviceUrl}/xrpc/app.bsky.feed.getFeed?feed=${encodeURIComponent(feedUri)}&limit=15`;
          const res = await fetch(url, {
            headers: { Authorization: `Bearer ${activeJwt}` },
            signal: AbortSignal.timeout(10000)
          });
          if (res.ok) {
            const data = await res.json();
            const feed = Array.isArray(data?.feed) ? data.feed : [];
            for (const entry of feed) {
              const post = entry?.post;
              if (!post) continue;
              const embed = post.embed;
              if (embed?.$type === "app.bsky.embed.video#view" ||
                  (embed?.$type === "app.bsky.embed.recordWithMedia#view" && embed?.media?.$type === "app.bsky.embed.video#view")) {
                results.push({ source: "bluesky", post, feedItem: entry });
              }
            }
          }
        } catch (err) {
          console.warn("Bluesky video feed fallback failed:", err);
        }
      }
      // Fetch from Nostr primal relay (filter for video URLs in kind-1 notes)
      try {
        const primalRelayUrl = "wss://relay.primal.net";
        const nostrVideos = await new Promise<any[]>((resolve) => {
          const items: any[] = [];
          const timeout = setTimeout(() => { try { ws.close(); } catch {} resolve(items); }, 6000);
          const ws = new WebSocket(primalRelayUrl);
          ws.onopen = () => {
            const since = Math.floor(Date.now() / 1000) - 7 * 86400;
            ws.send(JSON.stringify(["REQ", "vid", { kinds: [1], since, limit: 40 }]));
          };
          ws.onmessage = (msg) => {
            try {
              const data = JSON.parse(msg.data);
              if (Array.isArray(data) && data[0] === "EVENT" && data[2]) {
                const ev = data[2];
                const content = String(ev.content || "");
                if (/\.(mp4|webm|mov|m3u8)|video\.|youtu\.?be|vimeo/i.test(content)) {
                  items.push(ev);
                }
              }
              if (Array.isArray(data) && data[0] === "EOSE") {
                clearTimeout(timeout);
                ws.close();
                resolve(items);
              }
            } catch {}
          };
          ws.onerror = () => { clearTimeout(timeout); resolve(items); };
        });
        for (const ev of nostrVideos.slice(0, 10)) {
          results.push({ source: "nostr", event: ev, relayUrl: "wss://relay.primal.net" });
        }
      } catch (err) {
        console.warn("Nostr video fallback failed:", err);
      }
    } finally {
      setVideoFallbackItems(results);
      setVideoFallbackLoading(false);
    }
  }

  async function loadWorldFeedInterests() {
    setWorldFeedInterestsLoading(true);
    setWorldFeedInterestStatus("");
    try {
      const items = await listWorldFeedInterests(chatGatewayToken, gatewayBaseUrl);
      setWorldFeedInterests(items);
    } catch (error) {
      console.error("Failed to load world-feed interests", error);
      setWorldFeedInterestStatus(
        error instanceof Error ? error.message : "Failed to load world-feed interests."
      );
      setWorldFeedInterests([]);
    } finally {
      setWorldFeedInterestsLoading(false);
    }
  }

  async function createDiagnosticWorldFeedInterest(event?: FormEvent) {
    event?.preventDefault();
    setWorldFeedInterestStatus("");
    try {
      const created = await createWorldFeedDummyInterest(
        worldFeedDummyLabel,
        chatGatewayToken,
        gatewayBaseUrl
      );
      setWorldFeedInterestStatus(`Added diagnostic interest: ${created.label}`);
      await Promise.all([loadWorldFeedInterests(), fetchBlueskyFeed()]);
    } catch (error) {
      console.error("Failed to create world-feed diagnostic interest", error);
      setWorldFeedInterestStatus(
        error instanceof Error ? error.message : "Failed to create diagnostic interest."
      );
    }
  }

  async function removeWorldFeedInterest(item: WorldFeedInterestItem) {
    setWorldFeedInterestStatus("");
    try {
      await deleteWorldFeedInterest(item.id, chatGatewayToken, gatewayBaseUrl);
      setWorldFeedInterestStatus(`Removed interest: ${item.label}${item.synthetic ? "" : " (will regenerate on next profile refresh)"}`);
      await Promise.all([loadWorldFeedInterests(), fetchBlueskyFeed()]);
    } catch (error) {
      console.error("Failed to delete world-feed interest", error);
      setWorldFeedInterestStatus(
        error instanceof Error ? error.message : "Failed to delete interest."
      );
    }
  }

  async function saveInterestKeywords(interestId: string) {
    setWorldFeedInterestStatus("");
    try {
      const keywords = editingInterestKeywords
        .split(",")
        .map((kw) => kw.trim())
        .filter((kw) => kw.length > 0);
      await updateWorldFeedInterest(
        interestId,
        { keywordsOverride: keywords },
        chatGatewayToken,
        gatewayBaseUrl
      );
      setEditingInterestId(null);
      setEditingInterestKeywords("");
      setWorldFeedInterestStatus("Keywords updated.");
      await Promise.all([loadWorldFeedInterests(), fetchBlueskyFeed()]);
    } catch (error) {
      console.error("Failed to update interest keywords", error);
      setWorldFeedInterestStatus(
        error instanceof Error ? error.message : "Failed to update keywords."
      );
    }
  }

  async function clearInterestKeywordsOverride(interestId: string) {
    setWorldFeedInterestStatus("");
    try {
      await updateWorldFeedInterest(
        interestId,
        { keywordsOverride: [] },
        chatGatewayToken,
        gatewayBaseUrl
      );
      setEditingInterestId(null);
      setWorldFeedInterestStatus("Keywords reset to auto-derived.");
      await Promise.all([loadWorldFeedInterests(), fetchBlueskyFeed()]);
    } catch (error) {
      console.error("Failed to clear interest keywords override", error);
      setWorldFeedInterestStatus(
        error instanceof Error ? error.message : "Failed to reset keywords."
      );
    }
  }

  async function refreshWorldFeedDiagnostics() {
    await Promise.all([fetchBlueskyFeed({ force: true }), loadWorldFeedInterests()]);
  }

  function chooseNextWorldFeedSample(protocol: "rss" | "nostr" | "bluesky", sampleCount: number) {
    if (sampleCount <= 1) {
      return;
    }
    setWorldFeedSampleIndexByProtocol((prev) => {
      const current = prev[protocol];
      let next = current;
      while (next === current) {
        next = Math.floor(Math.random() * sampleCount);
      }
      return {
        ...prev,
        [protocol]: next
      };
    });
  }

  useEffect(() => {
    if (feedSource === "bluesky") {
      void fetchBlueskyFeed();
      void loadWorldFeedInterests();
    } else {
      setWorldFeedInterests([]);
      setWorldFeedInterestStatus("");
      stopFeedPoll();
      setFeedNewPostsBanner(false);
    }
    return () => { stopFeedPoll(); };
  }, [feedSource, session, creds.serviceUrl, chatGatewayToken, gatewayBaseUrl]);

  useEffect(() => {
    setWorldFeedSampleIndexByProtocol({
      rss: 0,
      nostr: 0,
      bluesky: 0
    });
  }, [blueskyFeedSnapshot?.refreshedAt, blueskyFeedSnapshot?.refreshState]);

  useEffect(() => {
    if (mobileTab !== "feed" || feedSource !== "local") {
      setFeedSidebarOpen(false);
      setFeedCreateWorkflowOpen(false);
      return;
    }
    void loadWorkspaceSynthSkillSettings();
    void loadFeedWorkflowSettings();
    void loadWorkspaceSynthStatus();
    void loadWorkspaceTodos();
    void loadWorkspaceEvents();
  }, [feedSource, mobileTab, chatGatewayToken, gatewayBaseUrl]);

  useEffect(() => {
    if (!workspaceTabActive) {
      return;
    }

    void loadWorkspaceSynthStatus();

    const refreshFromForeground = () => {
      if (document.visibilityState === "hidden") {
        return;
      }
      void loadWorkspaceSynthStatus();
    };

    window.addEventListener("focus", refreshFromForeground);
    document.addEventListener("visibilitychange", refreshFromForeground);
    return () => {
      window.removeEventListener("focus", refreshFromForeground);
      document.removeEventListener("visibilitychange", refreshFromForeground);
    };
  }, [workspaceTabActive, chatGatewayToken, gatewayBaseUrl]);

  useEffect(() => {
    if (!workspaceTabActive) {
      return;
    }
    if (
      workspaceSynthStatus.status !== "pending" &&
      workspaceSynthStatus.status !== "processing"
    ) {
      return;
    }

    let cancelled = false;
    let stream: GatewayEventStreamHandle | null = null;
    const start = async () => {
      let token = chatGatewayToken.trim();
      if (!token && isDesktopClient) {
        token = (await syncDesktopGatewayBootstrap())?.trim() || "";
      }
      if (!token && !isDesktopClient) {
        return;
      }

      await Promise.all([
        loadWorkspaceSynthStatus(),
        loadWorkflowRunStatuses(),
        refreshLibrary("feed"),
        loadWorkspaceTodos(),
        loadWorkspaceEvents()
      ]);
      if (cancelled) {
        return;
      }

      workspaceSynthStreamRef.current?.close();
      stream = streamWorkspaceSynthesizerStatus(
        (status) => {
          setWorkspaceSynthStatus(status);
          void Promise.all([
            loadWorkflowRunStatuses(),
            refreshLibrary("feed"),
            loadWorkspaceTodos(),
            loadWorkspaceEvents()
          ]);
          if (status.status === "done" || status.status === "error") {
            void refreshLibrary("journal");
          }
        },
        token || undefined,
        gatewayBaseUrl,
        () => {
          void loadWorkspaceSynthStatus();
        }
      );
      workspaceSynthStreamRef.current = stream;
      await stream.done;
    };

    void start();
    return () => {
      cancelled = true;
      stream?.close();
      if (workspaceSynthStreamRef.current === stream) {
        workspaceSynthStreamRef.current = null;
      }
    };
  }, [
    workspaceTabActive,
    chatGatewayToken,
    gatewayBaseUrl,
    isDesktopClient,
    workflowBots,
    workspaceSynthStatus.status
  ]);

  useEffect(() => {
    const currentPath = selectedJournalPath.trim();
    if (!currentPath) {
      return;
    }
    const renamed = workspaceSynthStatus.renamedSources?.find(
      (item) => item.fromPath === currentPath && item.toPath !== currentPath
    );
    if (!renamed) {
      return;
    }
    loadedTextPathRef.current = renamed.toPath;
    setSelectedJournalPath(renamed.toPath);
  }, [selectedJournalPath, workspaceSynthStatus.renamedSources]);

  useEffect(() => {
    if (!workspaceTabActive) {
      return;
    }
    if (
      workspaceSynthStatus.status !== "done" &&
      workspaceSynthStatus.status !== "error"
    ) {
      return;
    }
    setFeedEditStatus((prev) => {
      if (!prev.startsWith("Processing ")) {
        return prev;
      }
      if (workspaceSynthStatus.status === "error") {
        return workspaceSynthStatus.lastError?.trim()
          ? `Synthesis error: ${workspaceSynthStatus.lastError.trim()}`
          : "Synthesis error";
      }
      return "Feed idle";
    });
    void Promise.all([
      refreshLibrary("journal"),
      refreshLibrary("feed"),
      loadWorkspaceTodos(),
      loadWorkspaceEvents()
    ]);
  }, [workspaceTabActive, workspaceSynthStatus.status, workspaceSynthStatus.lastRunAt]);

  function applyGatewayConnection(gatewayUrl: string, token: string) {
    const normalizedUrl = gatewayUrl.trim().replace(/\/+$/, "");
    const normalizedToken = token.trim();
    if (!normalizedUrl || !normalizedToken) {
      return;
    }
    setGatewayBaseUrl(normalizedUrl);
    setChatGatewayToken(normalizedToken);
    setChatStatus(`Connected to ${normalizedUrl}`);
    setMobileScannerStatus(`Connected to ${normalizedUrl}`);
    void refreshLibrary("all");
    void refreshClawChat();
  }

  function applySyncPeerConnection(gatewayUrl: string, token: string) {
    const normalizedUrl = gatewayUrl.trim().replace(/\/+$/, "");
    const normalizedToken = token.trim();
    if (!normalizedUrl || !normalizedToken) {
      return;
    }
    setSyncPeerGatewayUrl(normalizedUrl);
    setSyncPeerToken(normalizedToken);
    setSyncStatus(`Sync peer saved: ${normalizedUrl}`);
  }

  function parseGatewayQrPayload(rawValue: string): { gatewayUrl: string; token: string } | null {
    const raw = rawValue.trim();
    if (!raw) {
      return null;
    }
    try {
      const parsed = JSON.parse(raw) as any;
      const gatewayUrl = String(parsed.gatewayUrl || parsed.gateway_url || "").trim();
      const token = String(parsed.token || "").trim();
      if (!gatewayUrl || !token) {
        return null;
      }
      return { gatewayUrl, token };
    } catch {
      return null;
    }
  }

  async function syncWithPeerNow() {
    const peerUrl = syncPeerGatewayUrl.trim().replace(/\/+$/, "");
    const peerToken = syncPeerToken.trim();
    if (!peerUrl || !peerToken) {
      setSyncStatus("Sync peer is not configured.");
      return;
    }
    let localToken = normalizeGatewayToken(chatGatewayToken);
    if (!localToken && isDesktopClient) {
      localToken = normalizeGatewayToken((await syncDesktopGatewayBootstrap()) || "");
    }
    setSyncBusy(true);
    setSyncStatus("Syncing workspace...");
    try {
      const snapshot = await exportWorkspaceSyncSnapshot(peerToken, peerUrl);
      const result = await importWorkspaceSyncSnapshot(snapshot, localToken || undefined, gatewayBaseUrl);
      setSyncStatus(
        `Sync complete (${Number(result?.importedFiles || 0)} files${result?.importedDb ? ", local DB updated" : ""}).`
      );
      await Promise.all([refreshLibrary("all"), refreshPostHistory(), refreshDrafts()]);
      void loadFeedWorkflowSettings();
      if (feedSource === "bluesky") {
        void fetchBlueskyFeed();
      }
    } catch (error) {
      setSyncStatus(`Sync failed (${error instanceof Error ? error.message : String(error)})`);
    } finally {
      setSyncBusy(false);
    }
  }

  async function clearSyncPeerConnection() {
    setSyncPeerGatewayUrl("");
    setSyncPeerToken("");
    setSyncStatus("Sync peer cleared.");
    if (isDesktopClient) {
      await clearSyncPeerSecure().catch(() => {});
    }
  }

  async function invokeDesktopCommand<T>(cmd: string, args: Record<string, unknown> = {}) {
    try {
      const core = await import("@tauri-apps/api/core");
      return await core.invoke<T>(cmd, args);
    } catch {
      return null;
    }
  }

  async function invokeDesktopCommandStrict<T>(cmd: string, args: Record<string, unknown> = {}) {
    const core = await import("@tauri-apps/api/core");
    return core.invoke<T>(cmd, args);
  }

  function preferredOpenAiAuthUrl(status?: OpenAiDeviceCodeStatus | null) {
    const fastLink = String(status?.fastLink || "").trim();
    if (fastLink) {
      return fastLink;
    }
    const verificationUrl = String(status?.verificationUrl || "").trim();
    return verificationUrl;
  }

  async function copyTextToClipboard(value: string, successMessage: string) {
    try {
      await navigator.clipboard.writeText(value);
      setAiSetupBrowserStatus(successMessage);
    } catch (error) {
      setAiSetupBrowserStatus(
        `Couldn't copy the link (${error instanceof Error ? error.message : String(error)})`
      );
    }
  }

  async function openExternalUrlInBrowser(url: string, source: "auto" | "manual" = "manual") {
    const trimmed = url.trim();
    if (!trimmed) {
      return false;
    }
    try {
      if (isDesktopClient) {
        await invokeDesktopCommandStrict("open_external_url", { url: trimmed });
      } else {
        const popup = window.open(trimmed, "_blank", "noopener,noreferrer");
        if (!popup) {
          throw new Error("popup blocked");
        }
      }
      setAiSetupBrowserStatus(
        source === "auto"
          ? "Browser opened automatically. Finish login there, then return here."
          : "Opened the login page in your browser."
      );
      return true;
    } catch (error) {
      setAiSetupBrowserStatus(
        source === "auto"
          ? `Couldn't open the browser automatically (${error instanceof Error ? error.message : String(error)}). Use Open in Browser or Copy Link.`
          : `Couldn't open the browser (${error instanceof Error ? error.message : String(error)})`
      );
      return false;
    }
  }

  async function openFeedLink(url: string) {
    const trimmed = url.trim();
    if (!trimmed) return;
    try {
      if (isDesktopClient) {
        await invokeDesktopCommandStrict("open_external_url", { url: trimmed });
      } else {
        window.open(trimmed, "_blank", "noopener,noreferrer");
      }
    } catch {
      // Best-effort fallback
      window.open(trimmed, "_blank", "noopener,noreferrer");
    }
  }

  async function openWorkspaceJournalsFolder() {
    if (!isDesktopClient) {
      return;
    }
    holdJournalSidebarStatus("Opening journals folder...");
    try {
      await invokeDesktopCommandStrict<string>("open_workspace_journals_folder");
      holdJournalSidebarStatus("Opened journals folder.");
    } catch (error) {
      holdJournalSidebarStatus(
        `Couldn't open journals folder (${error instanceof Error ? error.message : String(error)})`,
        4000
      );
    }
  }

  async function syncDesktopGatewayBootstrap(): Promise<string | null> {
    if (!isDesktopClient) {
      return null;
    }
    try {
      const payload = await invokeDesktopCommandStrict<DesktopGatewayBootstrap>(
        "get_desktop_gateway_bootstrap"
      );
      const nextUrl = String(payload.gatewayUrl || "").trim().replace(/\/+$/, "");
      if (nextUrl) {
        setGatewayBaseUrl((current) => {
          const normalized = current.trim().replace(/\/+$/, "");
          return normalized === nextUrl ? current : nextUrl;
        });
      }
      const nextToken = String(payload.token || "").trim();
      if (nextToken) {
        setChatGatewayToken(nextToken);
        return nextToken;
      }
      return null;
    } catch {
      return null;
    }
  }

  async function restartGatewayDaemonFromDesktop() {
    if (!isDesktopClient) {
      return;
    }
    await invokeDesktopCommandStrict<string>("restart_gateway_daemon");
  }

  async function refreshWorkspaceSynthAfterProviderSetup() {
    await Promise.all([
      loadWorkspaceSynthStatus(),
      loadWorkspaceTodos(),
      loadWorkspaceEvents(),
      loadRuntimeMediaCapabilities()
    ]);
  }

  async function loadOpenAiDeviceCodeStatus() {
    if (!isDesktopClient) {
      return;
    }
    try {
      const next = await invokeDesktopCommandStrict<OpenAiDeviceCodeStatus>(
        "get_openai_device_code_status"
      );
      setAiSetupStatus(next);
    } catch (error) {
      setAiSetupStatus({
        state: "error",
        running: false,
        completed: false,
        message: `AI setup status unavailable (${error instanceof Error ? error.message : String(error)})`,
        error: error instanceof Error ? error.message : String(error)
      });
    }
  }

  async function startOpenAiDeviceCodeLogin() {
    if (!isDesktopClient) {
      setAiSetupStatus({
        state: "error",
        running: false,
        completed: false,
        message: "AI setup is desktop-only.",
        error: "desktop-only"
      });
      return;
    }
    aiSetupAutoOpenedUrlRef.current = "";
    setAiSetupBrowserStatus("");
    setAiSetupBusy(true);
    try {
      const next = await invokeDesktopCommandStrict<OpenAiDeviceCodeStatus>(
        "start_openai_device_code_login"
      );
      setAiSetupStatus(next);
    } catch (error) {
      setAiSetupStatus({
        state: "error",
        running: false,
        completed: false,
        message: `Failed to start OpenAI setup (${error instanceof Error ? error.message : String(error)})`,
        error: error instanceof Error ? error.message : String(error)
      });
    } finally {
      setAiSetupBusy(false);
    }
  }

  async function loadAnthropicTokenStatus() {
    if (!isDesktopClient) {
      return;
    }
    try {
      const next = await invokeDesktopCommandStrict<AnthropicTokenStatus>(
        "get_anthropic_token_status"
      );
      setClaudeTokenStatus(next);
    } catch (error) {
      setClaudeTokenStatus({
        isSet: false,
        message: `Unable to check Claude auth status`,
        error: error instanceof Error ? error.message : String(error),
      });
    }
  }

  async function saveAnthropicToken() {
    if (!isDesktopClient) {
      return;
    }
    const trimmed = claudeToken.trim();
    if (!trimmed) {
      return;
    }
    setClaudeTokenBusy(true);
    try {
      const next = await invokeDesktopCommandStrict<AnthropicTokenStatus>(
        "save_anthropic_token",
        { token: trimmed }
      );
      setClaudeTokenStatus(next);
      setClaudeToken("");
    } catch (error) {
      setClaudeTokenStatus({
        isSet: false,
        message: `Failed to save Claude token`,
        error: error instanceof Error ? error.message : String(error),
      });
    } finally {
      setClaudeTokenBusy(false);
    }
  }

  async function clearAnthropicToken() {
    if (!isDesktopClient) {
      return;
    }
    setClaudeTokenBusy(true);
    try {
      const next = await invokeDesktopCommandStrict<AnthropicTokenStatus>(
        "clear_anthropic_token"
      );
      setClaudeTokenStatus(next);
    } catch (error) {
      setClaudeTokenStatus({
        isSet: false,
        message: `Failed to clear Claude token`,
        error: error instanceof Error ? error.message : String(error),
      });
    } finally {
      setClaudeTokenBusy(false);
    }
  }

  async function saveOptionalProviderApiKey() {
    const trimmed = providerApiKey.trim();
    setProviderApiKeyStatus(trimmed ? "Saving API key..." : "Clearing API key...");
    try {
      let token = normalizeGatewayToken(chatGatewayToken);
      if (!token && isDesktopClient) {
        token = normalizeGatewayToken((await syncDesktopGatewayBootstrap()) || "");
      }

      // Send API key via HTTP so the running gateway sees it immediately
      await updateRuntimeConfig(
        {
          defaultProvider: settingsProvider,
          defaultModel: settingsModel,
          transcriptionEnabled: settingsTranscriptionEnabled,
          transcriptionModel: settingsTranscriptionModel || "",
          availableTranscriptionModels: settingsAvailableTranscriptionModels,
          apiKey: trimmed || undefined,
        },
        token || undefined,
        gatewayBaseUrl
      );

      await refreshWorkspaceSynthAfterProviderSetup();

      if (isDesktopClient) {
        // Persist to OS keyring and restart gateway
        invokeDesktopCommandStrict("set_provider_api_key", {
          value: trimmed
        }).catch((err: unknown) => {
          console.warn("Desktop keyring save failed:", err);
        });
      }

      setProviderApiKeyStatus(
        trimmed
          ? "API key saved. Gateway restarted."
          : "API key cleared. Gateway restarted."
      );
    } catch (error) {
      setProviderApiKeyStatus(
        `Failed to apply API key (${error instanceof Error ? error.message : String(error)})`
      );
    }
  }

  async function handleOpenRouterOAuth() {
    let token = normalizeGatewayToken(chatGatewayToken);
    if (!token && isDesktopClient) {
      token = normalizeGatewayToken((await syncDesktopGatewayBootstrap()) || "");
    }

    setOpenrouterOAuthBusy(true);
    setOpenrouterOAuthStatus("Starting OpenRouter login...");
    try {
      const result = await startOpenRouterOAuth(token || undefined, gatewayBaseUrl);
      if (!result.authUrl) {
        setOpenrouterOAuthStatus("Failed to get auth URL from gateway.");
        setOpenrouterOAuthBusy(false);
        return;
      }

      setOpenrouterOAuthStatus("Opening browser — complete login there, then wait...");

      // Open the auth URL in a browser
      await openExternalUrlInBrowser(result.authUrl);

      // Poll for completion (90s timeout)
      const maxAttempts = 90;
      for (let i = 0; i < maxAttempts; i++) {
        await new Promise((r) => setTimeout(r, 1000));
        try {
          const status = await getOpenRouterOAuthStatus(token || undefined, gatewayBaseUrl);
          if (status.status === "complete") {
            setOpenrouterOAuthStatus("OpenRouter connected! AI is ready with a free model.");
            setSettingsProvider("openrouter");
            setSettingsModel("google/gemini-2.5-flash:free");
            window.localStorage.setItem(CHAT_PROVIDER_STORAGE_KEY, "openrouter");
            window.localStorage.setItem(CHAT_MODEL_STORAGE_KEY, "google/gemini-2.5-flash:free");
            await refreshWorkspaceSynthAfterProviderSetup();
            setOpenrouterOAuthBusy(false);
            return;
          }
          if (status.status === "failed") {
            setOpenrouterOAuthStatus(
              `Login failed: ${status.error || "Unknown error"}. Try pasting an API key instead.`
            );
            setOpenrouterOAuthBusy(false);
            return;
          }
        } catch {
          // Polling error — keep trying
        }
      }

      setOpenrouterOAuthStatus(
        "Auto-login timed out. Create a free API key at openrouter.ai/settings/keys and paste it below."
      );
      setOpenrouterOAuthBusy(false);
    } catch (error) {
      setOpenrouterOAuthStatus(
        `Failed: ${error instanceof Error ? error.message : String(error)}. Try pasting an API key instead.`
      );
      setOpenrouterOAuthBusy(false);
    }
  }

  async function saveOpenRouterApiKey() {
    const trimmed = openrouterApiKeyInput.trim();
    if (!trimmed) {
      setOpenrouterOAuthStatus("Please enter an API key.");
      return;
    }
    if (!trimmed.startsWith("sk-or-")) {
      setOpenrouterOAuthStatus("OpenRouter API keys start with 'sk-or-'. Please check your key.");
      return;
    }

    setOpenrouterOAuthBusy(true);
    setOpenrouterOAuthStatus("Saving API key...");

    try {
      let token = normalizeGatewayToken(chatGatewayToken);
      if (!token && isDesktopClient) {
        token = normalizeGatewayToken((await syncDesktopGatewayBootstrap()) || "");
      }

      // Save via runtime config update — set provider, model, and API key
      await updateRuntimeConfig(
        {
          defaultProvider: "openrouter",
          defaultModel: "google/gemini-2.5-flash:free",
          transcriptionEnabled: settingsTranscriptionEnabled,
          transcriptionModel: settingsTranscriptionModel || "",
          availableTranscriptionModels: settingsAvailableTranscriptionModels,
          apiKey: trimmed,
        },
        token || undefined,
        gatewayBaseUrl
      );

      setSettingsProvider("openrouter");
      setSettingsModel("google/gemini-2.5-flash:free");
      setProviderApiKey(trimmed);
      setProviderApiKeyStatus("API key saved. Gateway restarted.");
      window.localStorage.setItem(CHAT_PROVIDER_STORAGE_KEY, "openrouter");
      window.localStorage.setItem(CHAT_MODEL_STORAGE_KEY, "google/gemini-2.5-flash:free");
      setOpenrouterApiKeyInput("");
      // Refresh synth status before desktop gateway restart so the
      // readiness check sees the api_key already in the running gateway.
      await refreshWorkspaceSynthAfterProviderSetup();

      if (isDesktopClient) {
        // Persist to OS keyring and restart gateway for long-term storage.
        // This runs after the synth refresh so the UI updates immediately.
        invokeDesktopCommandStrict("set_provider_api_key", {
          value: trimmed
        }).catch((err: unknown) => {
          console.warn("Desktop keyring save failed:", err);
        });
      }

      setOpenrouterOAuthStatus("API key saved! AI is ready with a free model.");
      setOpenrouterOAuthBusy(false);
    } catch (error) {
      setOpenrouterOAuthStatus(
        `Failed to save key: ${error instanceof Error ? error.message : String(error)}`
      );
      setOpenrouterOAuthBusy(false);
    }
  }

  async function loadRuntimeMediaCapabilities() {
    let token = normalizeGatewayToken(chatGatewayToken);
    if (!token && isDesktopClient) {
      token = normalizeGatewayToken((await syncDesktopGatewayBootstrap()) || "");
    }
    if (!gatewayBaseUrl.trim()) {
      setRuntimeMediaCapabilities(null);
      setRuntimeMediaSummary("");
      return;
    }
    try {
      const cfg = await getRuntimeConfig(token || undefined, gatewayBaseUrl);
      setRuntimeMediaCapabilities(cfg.mediaCapabilities || null);
      setRuntimeMediaSummary(cfg.mediaSummary || "");
    } catch {
      setRuntimeMediaCapabilities(null);
      setRuntimeMediaSummary("");
    }
  }

  async function loadRuntimeConfigForSettings() {
    let token = normalizeGatewayToken(chatGatewayToken);
    if (!token && isDesktopClient) {
      token = normalizeGatewayToken((await syncDesktopGatewayBootstrap()) || "");
    }

    if (isDesktopClient) {
      setSettingsConfigLoaded(false);
      setSettingsConfigStatus("Loading local config...");
      try {
        const cfg = await getConfig();
        const savedProvider = window.localStorage.getItem(CHAT_PROVIDER_STORAGE_KEY);
        const savedModel = window.localStorage.getItem(CHAT_MODEL_STORAGE_KEY);
        setSettingsProvider((savedProvider && savedProvider.trim()) || "ollama");
        setSettingsModel((savedModel && savedModel.trim()) || cfg.ollamaModel || "");
        setSettingsTranscriptionEnabled(Boolean(cfg.transcriptionEnabled));
        setSettingsTranscriptionModel(cfg.ollamaModel || "");
        let models = await listOllamaModels().catch(() => [] as string[]);
        if (!models.length && gatewayBaseUrl.trim()) {
          try {
            const runtimeCfg = await getRuntimeConfig(token || undefined, gatewayBaseUrl);
            setRuntimeMediaCapabilities(runtimeCfg.mediaCapabilities || null);
            setRuntimeMediaSummary(runtimeCfg.mediaSummary || "");
            models =
              runtimeCfg.availableTranscriptionModels && runtimeCfg.availableTranscriptionModels.length > 0
                ? [...runtimeCfg.availableTranscriptionModels]
                : [];
            const runtimeModel = runtimeCfg.transcriptionModel || "";
            if (runtimeModel && !models.includes(runtimeModel)) {
              models.unshift(runtimeModel);
            }
          } catch {
            // Keep local model-only list when gateway runtime config is unavailable.
          }
        }
        if (cfg.ollamaModel && !models.includes(cfg.ollamaModel)) {
          models.unshift(cfg.ollamaModel);
        }
        setSettingsAvailableTranscriptionModels(models);
        setSettingsConfigStatus("Config loaded (local)");
        setSettingsConfigLoaded(true);
        return;
      } catch (localError) {
        if (!isMissingDesktopCommand(localError, "get_config")) {
          setSettingsConfigStatus(
            `Config unavailable (${localError instanceof Error ? localError.message : String(localError)}). You can still edit and save manually.`
          );
          setSettingsConfigLoaded(true);
          return;
        }
      }
    }

    if (!gatewayBaseUrl.trim()) {
      setSettingsConfigStatus("Config unavailable (gateway URL missing). You can still edit and save manually.");
      setSettingsConfigLoaded(true);
      return;
    }

    setSettingsConfigLoaded(false);
    setSettingsConfigStatus("Loading current config...");
    try {
      const cfg = await getRuntimeConfig(token || undefined, gatewayBaseUrl);
      setRuntimeMediaCapabilities(cfg.mediaCapabilities || null);
      setRuntimeMediaSummary(cfg.mediaSummary || "");
      setSettingsProvider(cfg.defaultProvider || "");
      setSettingsModel(cfg.defaultModel || "");
      setSettingsTranscriptionEnabled(Boolean(cfg.transcriptionEnabled));
      const currentTranscriptionModel = cfg.transcriptionModel || "";
      setSettingsTranscriptionModel(currentTranscriptionModel);
      const availableModels =
        cfg.availableTranscriptionModels && cfg.availableTranscriptionModels.length > 0
          ? [...cfg.availableTranscriptionModels]
          : [];
      if (currentTranscriptionModel && !availableModels.includes(currentTranscriptionModel)) {
        availableModels.unshift(currentTranscriptionModel);
      }
      setSettingsAvailableTranscriptionModels(availableModels);
      setSettingsConfigStatus("Config loaded");
      setSettingsConfigLoaded(true);
    } catch (error) {
      setRuntimeMediaCapabilities(null);
      setRuntimeMediaSummary("");
      setSettingsConfigStatus(
        `Config unavailable (${error instanceof Error ? error.message : String(error)}). You can still edit and save manually.`
      );
      setSettingsConfigLoaded(true);
    }
  }

  async function saveRuntimeConfigFromSettings() {
    const provider = settingsProvider.trim();
    const model = settingsModel.trim();
    if (!provider || !model) {
      setSettingsConfigStatus("Provider and model are required.");
      return;
    }
    if (settingsTranscriptionEnabled && !settingsTranscriptionModel.trim()) {
      setSettingsConfigStatus("Pick a transcription model.");
      return;
    }
    let token = normalizeGatewayToken(chatGatewayToken);
    if (!token && isDesktopClient) {
      token = normalizeGatewayToken((await syncDesktopGatewayBootstrap()) || "");
    }

    setSettingsConfigBusy(true);
    setSettingsConfigStatus(isDesktopClient ? "Saving local config..." : "Saving config...");
    try {
      if (isDesktopClient) {
        try {
          const cfg = await getConfig();
          await saveConfig({
            ...cfg,
            ollamaModel: model,
            transcriptionEnabled: settingsTranscriptionEnabled
          });
          window.localStorage.setItem(CHAT_PROVIDER_STORAGE_KEY, provider);
          window.localStorage.setItem(CHAT_MODEL_STORAGE_KEY, model);
          setSettingsConfigLoaded(true);
          if (provider !== "ollama") {
            setSettingsConfigStatus("Saved local config. Note: desktop local chat currently uses Ollama.");
          } else {
            setSettingsConfigStatus("Config saved (local).");
          }
          return;
        } catch (localError) {
          const missingGet = isMissingDesktopCommand(localError, "get_config");
          const missingSave = isMissingDesktopCommand(localError, "save_config");
          if (!missingGet && !missingSave) {
            throw localError;
          }
          setSettingsConfigStatus("Local config command unavailable, saving via gateway...");
        }
      } else if (!token) {
        setSettingsConfigStatus("Save blocked (gateway token missing).");
        return;
      }

      await updateRuntimeConfig(
        {
          defaultProvider: provider,
          defaultModel: model,
          transcriptionEnabled: settingsTranscriptionEnabled,
          transcriptionModel: settingsTranscriptionModel.trim(),
          availableTranscriptionModels: settingsAvailableTranscriptionModels
        },
        token || undefined,
        gatewayBaseUrl
      );
      setSettingsConfigStatus("Config saved. Restarting/applying...");
      if (isDesktopClient) {
        await restartGatewayDaemonFromDesktop();
      }
      window.location.reload();
    } catch (error) {
      setSettingsConfigStatus(
        `Save failed (${error instanceof Error ? error.message : String(error)})`
      );
    } finally {
      setSettingsConfigBusy(false);
    }
  }

  async function generateDesktopPairingQr() {
    setDesktopQrLoading(true);
    setDesktopQrStatus("Generating a new mobile pairing token...");
    try {
      const payload = await invokeDesktopCommandStrict<GatewayQrPayload>(
        "generate_mobile_pairing_qr"
      );
      if (!payload?.qr_value || !payload.gateway_url || !payload.token) {
        throw new Error("Desktop pairing payload was empty");
      }
      setDesktopQrPayload(payload);
      setDesktopQrStatus("QR ready. Scan this from the mobile app.");
    } catch (error) {
      setDesktopQrStatus(
        `QR generation failed (${error instanceof Error ? error.message : String(error)})`
      );
    } finally {
      setDesktopQrLoading(false);
    }
  }

  function stopMobileScanner() {
    if (mobileScannerRafRef.current) {
      cancelAnimationFrame(mobileScannerRafRef.current);
      mobileScannerRafRef.current = null;
    }
    if (mobileScannerStreamRef.current) {
      mobileScannerStreamRef.current.getTracks().forEach((track) => track.stop());
      mobileScannerStreamRef.current = null;
    }
    if (mobileScannerVideoRef.current) {
      mobileScannerVideoRef.current.srcObject = null;
    }
    setMobileScannerActive(false);
    setSyncScannerActive(false);
  }

  useEffect(() => {
    const needsQrLogin = !isDesktopClient && !(chatGatewayToken.trim() && gatewayBaseUrl.trim());
    const shouldScan = syncScannerActive || (needsQrLogin && mobileScannerActive);
    if (!shouldScan) {
      return;
    }
    let cancelled = false;
    const BarcodeDetectorCtor = (window as any).BarcodeDetector;

    const start = async () => {
      if (!BarcodeDetectorCtor) {
        setMobileCameraPermissionError("QR scanning needs BarcodeDetector support in this browser.");
        setMobileScannerActive(false);
        return;
      }
      try {
        const stream = await navigator.mediaDevices.getUserMedia({
          video: { facingMode: "environment" },
          audio: false
        });
        if (cancelled) {
          stream.getTracks().forEach((track) => track.stop());
          return;
        }
        mobileScannerStreamRef.current = stream;
        const video = mobileScannerVideoRef.current;
        if (!video) {
          stream.getTracks().forEach((track) => track.stop());
          return;
        }
        video.srcObject = stream;
        await video.play();
        const detector = new BarcodeDetectorCtor({ formats: ["qr_code"] });
        const scanFrame = async () => {
          if (cancelled) {
            return;
          }
          try {
            if (video.readyState >= 2) {
              const codes = await detector.detect(video);
              if (codes && codes.length > 0) {
              const value = String(codes[0].rawValue || "");
              const parsed = parseGatewayQrPayload(value);
              if (parsed) {
                  if (syncScannerActive && isTauriMobileRuntime()) {
                    applySyncPeerConnection(parsed.gatewayUrl, parsed.token);
                  } else {
                    applyGatewayConnection(parsed.gatewayUrl, parsed.token);
                  }
                  stopMobileScanner();
                  return;
                }
              }
            }
          } catch {
            // ignore decode frame errors
          }
          mobileScannerRafRef.current = requestAnimationFrame(() => {
            void scanFrame();
          });
        };
        setMobileCameraPermissionError("");
        setMobileScannerStatus("Scanner active. Point camera at desktop QR.");
        void scanFrame();
      } catch (error) {
        setMobileCameraPermissionError(
          `Unable to open camera (${error instanceof Error ? error.message : String(error)})`
        );
        setMobileScannerActive(false);
      }
    };
    void start();

    return () => {
      cancelled = true;
      if (mobileScannerRafRef.current) {
        cancelAnimationFrame(mobileScannerRafRef.current);
        mobileScannerRafRef.current = null;
      }
      if (mobileScannerStreamRef.current) {
        mobileScannerStreamRef.current.getTracks().forEach((track) => track.stop());
        mobileScannerStreamRef.current = null;
      }
      if (mobileScannerVideoRef.current) {
        mobileScannerVideoRef.current.srcObject = null;
      }
    };
  }, [isDesktopClient, mobileScannerActive, syncScannerActive, chatGatewayToken, gatewayBaseUrl]);

  useEffect(() => {
    if (!isDesktopClient) {
      return;
    }
    void loadOpenAiDeviceCodeStatus();
    void loadAnthropicTokenStatus();
  }, [isDesktopClient]);

  useEffect(() => {
    if (!isDesktopClient || !aiSetupStatus?.running) {
      return;
    }
    const timer = window.setInterval(() => {
      void loadOpenAiDeviceCodeStatus();
    }, 1200);
    return () => {
      window.clearInterval(timer);
    };
  }, [isDesktopClient, aiSetupStatus?.running]);

  useEffect(() => {
    if (!isDesktopClient) {
      return;
    }
    const authUrl = preferredOpenAiAuthUrl(aiSetupStatus);
    if (!authUrl || aiSetupAutoOpenedUrlRef.current) {
      return;
    }
    if (aiSetupStatus?.state !== "awaiting_user") {
      return;
    }
    aiSetupAutoOpenedUrlRef.current = authUrl;
    void openExternalUrlInBrowser(authUrl, "auto");
  }, [
    aiSetupStatus?.fastLink,
    aiSetupStatus?.state,
    aiSetupStatus?.verificationUrl,
    isDesktopClient
  ]);

  useEffect(() => {
    if (mobileTab !== "profile") {
      return;
    }
    void loadRuntimeConfigForSettings();
  }, [mobileTab, chatGatewayToken, gatewayBaseUrl]);

  useEffect(() => {
    if (mobileTab !== "feed" && mobileTab !== "profile" && mobileTab !== "journal") {
      return;
    }
    void loadRuntimeMediaCapabilities();
  }, [mobileTab, feedSource, chatGatewayToken, gatewayBaseUrl]);

  useEffect(() => {
    let cancelled = false;
    let stream: GatewayEventStreamHandle | null = null;
    const start = async () => {
      let token = chatGatewayToken.trim();
      if (!token && isDesktopClient) {
        token = (await syncDesktopGatewayBootstrap())?.trim() || "";
      }
      const threadId = chatThreadId.trim();
      if (!threadId) {
        setChatMessages([]);
        setChatStatus("No chat thread yet. Send a message to start.");
        return;
      }
      if (!token && !isDesktopClient) {
        setChatStatus("Chat blocked (gateway token missing). Pair mobile with desktop QR.");
        return;
      }

      stream = streamClawChatMessages(
        threadId,
        (snapshot) => {
          setChatMessages(snapshot.items);
          setChatStatus(`Chat thread loaded (${snapshot.items.length} messages)`);
        },
        token || undefined,
        gatewayBaseUrl,
        (error) => {
          if (!cancelled) {
            setChatStatus(
              `Chat unavailable (${error instanceof Error ? error.message : String(error)})`
            );
          }
        }
      );
      chatThreadStreamRef.current = stream;
      await stream.done;
    };

    chatThreadStreamRef.current?.close();
    void start();
    return () => {
      cancelled = true;
      stream?.close();
      if (chatThreadStreamRef.current === stream) {
        chatThreadStreamRef.current = null;
      }
    };
  }, [chatThreadId, chatGatewayToken, gatewayBaseUrl, isDesktopClient]);

  useEffect(() => {
    void refreshLibrary("all");
  }, [chatGatewayToken, gatewayBaseUrl]);

  useEffect(() => {
    void refreshPostHistory();
  }, [chatGatewayToken, gatewayBaseUrl]);

  useEffect(() => {
    const item = journalItems.find((entry) => entry.path === selectedJournalPath) || null;
    setSelectedJournalItem(item);
    if (item) {
      if (openedJournalPathRef.current === item.path) {
        return;
      }
      openedJournalPathRef.current = item.path;
      void openLibraryItem(item, "journal");
    } else {
      openedJournalPathRef.current = "";
      setSelectedJournalText("");
      if (!selectedJournalPath.trim()) {
        setJournalDraftText("");
      }
    }
  }, [journalItems, selectedJournalPath]);

  useEffect(() => {
    const activePaths = new Set(feedItems.map((item) => item.path));
    setFeedDraftsByPath((prev) =>
      Object.fromEntries(Object.entries(prev).filter(([path]) => activePaths.has(path)))
    );
    setFeedDraftSourceByPath((prev) =>
      Object.fromEntries(Object.entries(prev).filter(([path]) => activePaths.has(path)))
    );
    setFeedDraftLoadingByPath((prev) =>
      Object.fromEntries(Object.entries(prev).filter(([path]) => activePaths.has(path)))
    );
    for (const item of feedItems) {
      void ensureFeedDraftLoaded(item);
    }
  }, [feedItems, chatGatewayToken, gatewayBaseUrl]);

  useEffect(() => {
    const item = mobileTab === "journal" ? selectedJournalItem : null;
    if (item && (item.kind === "audio" || item.kind === "video" || item.kind === "image")) {
      void loadMediaPreview(item);
      return;
    }
    void loadMediaPreview(null);
  }, [mobileTab, selectedJournalItem, chatGatewayToken, gatewayBaseUrl]);

  useEffect(() => {
    if (!selectedFeedItem || selectedFeedItem.kind !== "text") {
      return;
    }
    if (loadedTextPathRef.current !== selectedFeedItem.path) {
      return;
    }
    if (autosaveTimerRef.current) {
      window.clearTimeout(autosaveTimerRef.current);
    }
    autosaveTimerRef.current = window.setTimeout(async () => {
      try {
        const token = chatGatewayToken.trim() || undefined;
        await saveLibraryText(selectedFeedItem.path, selectedFeedText, token, gatewayBaseUrl);
        setFeedEditStatus(`Autosaved ${selectedFeedItem.path}`);
      } catch (error) {
        setFeedEditStatus(
          `Autosave failed (${error instanceof Error ? error.message : String(error)})`
        );
      }
    }, 700);
    return () => {
      if (autosaveTimerRef.current) {
        window.clearTimeout(autosaveTimerRef.current);
      }
    };
  }, [selectedFeedText, selectedFeedItem, chatGatewayToken, gatewayBaseUrl]);

  useEffect(() => {
    if (!feedCaptionPath || loadedCaptionPathRef.current !== feedCaptionPath) {
      return;
    }
    if (!selectedFeedItem || !(selectedFeedItem.kind === "audio" || selectedFeedItem.kind === "video")) {
      return;
    }
    const timer = window.setTimeout(async () => {
      try {
        const token = chatGatewayToken.trim() || undefined;
        await saveLibraryText(feedCaptionPath, feedCaptionText, token, gatewayBaseUrl);
        setFeedEditStatus(`Autosaved caption: ${feedCaptionPath}`);
      } catch (error) {
        setFeedEditStatus(
          `Caption autosave failed (${error instanceof Error ? error.message : String(error)})`
        );
      }
    }, 700);
    return () => {
      window.clearTimeout(timer);
    };
  }, [feedCaptionText, feedCaptionPath, selectedFeedItem, chatGatewayToken, gatewayBaseUrl]);

  useEffect(() => {
    if (!selectedJournalItem && !journalDraftText.trim()) return;
    if (!selectedJournalItem && selectedJournalPath.trim()) return;
    if (selectedJournalItem && selectedJournalItem.kind === "text" && loadedTextPathRef.current !== selectedJournalItem.path) return;
    if (selectedJournalItem && journalDraftText === selectedJournalText) return;

    if (journalAutosaveTimerRef.current) window.clearTimeout(journalAutosaveTimerRef.current);
    journalAutosaveTimerRef.current = window.setTimeout(() => {
      void saveJournalTextDraft();
    }, 700);
    return () => {
      if (journalAutosaveTimerRef.current) window.clearTimeout(journalAutosaveTimerRef.current);
    };
  }, [journalDraftText, selectedJournalItem, selectedJournalPath, selectedJournalText, chatGatewayToken, gatewayBaseUrl]);

  useEffect(() => {
    return () => {
      for (const timer of Object.values(feedAutosaveTimersRef.current)) {
        window.clearTimeout(timer);
      }
    };
  }, []);

  const journalList = journalItems;
  const normalizedJournalSearchQuery = journalSearchQuery.trim().toLocaleLowerCase();
  const filteredJournalList = normalizedJournalSearchQuery
    ? journalList.filter((item) => {
        const searchableText = [
          item.title,
          item.previewText || "",
          item.path === selectedJournalPath ? selectedJournalText : ""
        ]
          .join("\n")
          .toLocaleLowerCase();
        return searchableText.includes(normalizedJournalSearchQuery);
      })
    : journalList;
  const feedList = feedItems;
  const postedHistory = history.filter((item) => item.status === "success");
  const needsMobileQrLogin = !isDesktopClient && !(chatGatewayToken.trim() && gatewayBaseUrl.trim());
  const isCaptureZenMode = mobileTab === "journal" && (isRecording || captureMode !== null);
  const hideChrome = isWritingNote || isCaptureZenMode;
  const showDesktopJournalLayout = isDesktopLayout && mobileTab === "journal";
  const showDesktopJournalSidebar =
    showDesktopJournalLayout &&
    !hideChrome &&
    !journalDesktopSidebarCollapsed;
  const isMediaTranscriptMode =
    !!selectedJournalItem &&
    (selectedJournalItem.kind === "audio" || selectedJournalItem.kind === "video");
  const selectedJournalSynthSourcePath =
    selectedJournalItem?.kind === "text" ? selectedJournalItem.path : "";
  const selectedJournalWasProcessed = Boolean(selectedJournalItem?.workspaceSynthProcessed);
  const now = new Date();
  const todayStart = startOfLocalDay(now);
  const tomorrowStart = new Date(todayStart);
  tomorrowStart.setDate(todayStart.getDate() + 1);
  const openTodos = workspaceTodos
    .filter((item) => item.status !== "done")
    .slice()
    .sort((a, b) => {
      const aDue = parseDateValue(a.dueAt);
      const bDue = parseDateValue(b.dueAt);
      const dueScore =
        (aDue ? aDue.getTime() : Number.MAX_SAFE_INTEGER) -
        (bDue ? bDue.getTime() : Number.MAX_SAFE_INTEGER);
      if (dueScore !== 0) {
        return dueScore;
      }
      const priorityScore = todoPriorityRank(a.priority) - todoPriorityRank(b.priority);
      if (priorityScore !== 0) {
        return priorityScore;
      }
      return (parseDateValue(b.updated)?.getTime() || 0) - (parseDateValue(a.updated)?.getTime() || 0);
    });
  const doneTodos = workspaceTodos
    .filter((item) => item.status === "done")
    .slice()
    .sort(
      (a, b) =>
        (parseDateValue(b.updated)?.getTime() || 0) - (parseDateValue(a.updated)?.getTime() || 0)
    );
  const overdueTodoCount = openTodos.filter((item) => {
    const due = parseDateValue(item.dueAt);
    if (!due) {
      return false;
    }
    return hasExplicitTime(item.dueAt)
      ? due.getTime() < now.getTime()
      : startOfLocalDay(due).getTime() < todayStart.getTime();
  }).length;
  const todayEventItems = workspaceEvents
    .filter((item) => {
      const start = parseDateValue(item.startAt);
      return start ? isSameLocalDay(start, now) : false;
    })
    .slice()
    .sort(
      (a, b) =>
        (parseDateValue(a.startAt)?.getTime() || 0) - (parseDateValue(b.startAt)?.getTime() || 0)
    );
  const upcomingEventItems = workspaceEvents
    .filter((item) => {
      const start = parseDateValue(item.startAt);
      return start ? start.getTime() >= tomorrowStart.getTime() : false;
    })
    .slice()
    .sort(
      (a, b) =>
        (parseDateValue(a.startAt)?.getTime() || 0) - (parseDateValue(b.startAt)?.getTime() || 0)
    );
  const pastEventItems = workspaceEvents
    .filter((item) => {
      const start = parseDateValue(item.startAt);
      return start ? start.getTime() < todayStart.getTime() : false;
    })
    .slice()
    .sort(
      (a, b) =>
        (parseDateValue(b.startAt)?.getTime() || 0) - (parseDateValue(a.startAt)?.getTime() || 0)
    );
  const isFreshNoteMode = !selectedJournalItem;
  const selectedJournalTranscriptionStatus =
    selectedJournalItem?.kind === "audio"
      ? journalTranscriptionStatusByPath[selectedJournalItem.path] || "idle"
      : "idle";

  const renderJournalSidebarContent = (closeOnSelect: boolean, mode: "mobile" | "desktop") => (
    <>
      <div className="row-between" style={{ marginBottom: "1.5rem" }}>
        <h2>Journals</h2>
        <div className="row" style={{ gap: "0.5rem", alignItems: "center" }}>
          {isDesktopClient ? (
            <button
              type="button"
              className="ghost text-sm"
              onClick={() => void openWorkspaceJournalsFolder()}
              title="Open the journals folder inside the workspace"
            >
              Open Folder
            </button>
          ) : null}
          {mode === "mobile" ? (
            <button
              type="button"
              className="ghost"
              onClick={() => setJournalSidebarOpen(false)}
              title="Close recent journals"
            >
              <svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round"><polyline points="15 18 9 12 15 6"></polyline></svg>
            </button>
          ) : null}
        </div>
      </div>

      <div className="stack-sm" style={{ marginBottom: "1rem" }}>
        <input
          type="search"
          value={journalSearchQuery}
          onChange={(e) => setJournalSearchQuery(e.target.value)}
          placeholder="Search title or content"
          aria-label="Search journals"
        />
        <div className="row-between text-sm muted" style={{ gap: "0.75rem" }}>
          <span>
            {filteredJournalList.length} of {journalItems.length}
          </span>
          {journalSidebarStatus ? <span>{journalSidebarStatus}</span> : null}
        </div>
      </div>

      {journalItems.length === 0 ? (
        <p className="text-center muted">No journals found.</p>
      ) : filteredJournalList.length === 0 ? (
        <p className="text-center muted">No journals match your search.</p>
      ) : (
        <div className="stack">
          {filteredJournalList.map(item => (
            <div key={item.path} className="row-between" style={{ padding: "0.8rem", background: selectedJournalPath === item.path ? "color-mix(in srgb, var(--line) 40%, transparent)" : "transparent", borderRadius: "12px" }}>
              <div
                className="stack"
                style={{ gap: '4px', flex: 1, cursor: 'pointer' }}
                onClick={() => {
                  setSelectedJournalPath(item.path);
                  if (closeOnSelect) {
                    setJournalSidebarOpen(false);
                  }
                }}
              >
                <div className="feed-title">{item.title}</div>
                <div className="feed-time">{formatTimestamp(item.modifiedAt)} · {item.kind.toUpperCase()}</div>
              </div>
              <button
                type="button"
                className="ghost"
                onClick={() => {
                  setPendingDeleteJournalItem(item);
                }}
                title={`Delete ${item.title}`}
                style={{ padding: "0.35rem" }}
              >
                <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round"><polyline points="3 6 5 6 21 6"></polyline><path d="M19 6l-1 14a2 2 0 0 1-2 2H8a2 2 0 0 1-2-2L5 6"></path><path d="M10 11v6"></path><path d="M14 11v6"></path><path d="M9 6V4a1 1 0 0 1 1-1h4a1 1 0 0 1 1 1v2"></path></svg>
              </button>
            </div>
          ))}
        </div>
      )}
    </>
  );

  const isWorldNostrItem = (item: PersonalizedFeedItem) =>
    item.sourceType === "web" && item.webPreview?.provider === "Nostr";

  const isWorldVideoItem = (item: PersonalizedFeedItem) => {
    if (item.sourceType === "bluesky") {
      const embed = (item.feedItem as any)?.post?.embed;
      return (
        embed?.$type === "app.bsky.embed.video#view" ||
        (embed?.$type === "app.bsky.embed.recordWithMedia#view" &&
          embed?.media?.$type === "app.bsky.embed.video#view")
      );
    }
    if (isWorldNostrItem(item)) {
      const preview = item.webPreview;
      const candidateText = [
        preview?.contentText || "",
        preview?.description || "",
        preview?.title || "",
        preview?.url || "",
      ].join("\n");
      return hasInlineVideoUrl(candidateText);
    }
    return false;
  };

  const worldTweetItems = blueskyFeedItems.filter(
    (item) => !isWorldVideoItem(item) && (item.sourceType === "bluesky" || isWorldNostrItem(item))
  );
  const worldArticleItems = blueskyFeedItems.filter(
    (item) => item.sourceType === "web" && item.webPreview && !isWorldNostrItem(item) && !isWorldVideoItem(item)
  );
  const worldVideoItems = blueskyFeedItems.filter(isWorldVideoItem);

  const worldFeedNewPostsBanner =
    feedNewPostsBanner && pendingFeedItemsRef.current ? (
      <button
        type="button"
        className="feed-new-posts-banner"
        onClick={() => {
          const pending = pendingFeedItemsRef.current;
          if (pending) {
            setBlueskyFeedItems(pending.items);
            setBlueskyFeedSnapshot(pending);
            setBlueskyProfileStats(pending.profileStats);
            setFeedGeneration(pending.generation);
            pendingFeedItemsRef.current = null;
            setFeedNewPostsBanner(false);
          }
        }}
        style={{
          width: "100%",
          padding: "0.55rem 1rem",
          border: "1px solid var(--accent, #4a9eff)",
          borderRadius: "8px",
          backgroundColor: "var(--accent-bg, #e8f0fe)",
          color: "var(--accent, #4a9eff)",
          cursor: "pointer",
          textAlign: "center",
          fontSize: "0.85rem",
          fontWeight: 500,
          marginBottom: "0.5rem",
        }}
      >
        New posts found — tap to load
      </button>
    ) : null;

  const renderWorldVideoFallbackItem = (vItem: any, vi: number) => {
    if (vItem.source === "bluesky" && vItem.post) {
      const post = vItem.post;
      const author = post.author || {};
      const record = post.record as any;
      const vText = String(record?.text || "");
      const embedNode = renderBlueskyEmbed(post.embed as any);
      return (
        <div key={`vfb-${post.cid || vi}`} className="feed-item">
          <div className="feed-header">
            <div className="feed-title" style={{ display: "flex", alignItems: "center", gap: "8px" }}>
              {author.avatar ? (
                <img src={author.avatar} alt="" style={{ width: "36px", height: "36px", borderRadius: "50%", objectFit: "cover" }} />
              ) : null}
              <div className="stack-sm" style={{ gap: "0.05rem" }}>
                <strong>{author.displayName || author.handle}</strong>
                <span className="muted text-sm" style={{ fontWeight: "normal" }}>@{author.handle}</span>
                <span className="muted text-sm" style={{ fontWeight: "normal" }}>via Bluesky Videos</span>
              </div>
            </div>
            <div className="feed-time">{formatTimestamp(post.indexedAt)}</div>
          </div>
          <div className="feed-body" style={{ marginTop: "8px", wordBreak: "break-word", whiteSpace: "pre-wrap" }}>
            {renderLinkedText(vText)}
          </div>
          {embedNode}
          <div className="bsky-actions">
            <button
              type="button"
              className={`bsky-action-btn ${blueskyLikedUris[post.uri] ? "liked" : ""}`}
              onClick={() => void handleLikeBlueskyPost(post.uri, post.cid)}
              disabled={!session}
            >
              <svg width="16" height="16" viewBox="0 0 24 24" fill={blueskyLikedUris[post.uri] ? "#f91880" : "none"} stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round"><path d="M20.84 4.61a5.5 5.5 0 0 0-7.78 0L12 5.67l-1.06-1.06a5.5 5.5 0 0 0-7.78 7.78l1.06 1.06L12 21.23l7.78-7.78 1.06-1.06a5.5 5.5 0 0 0 0-7.78z"></path></svg>
              {post.likeCount || 0}
            </button>
            <button
              type="button"
              className={`bsky-action-btn ${expandedThreadUri === post.uri ? "liked" : ""}`}
              onClick={() => void handleExpandThread(post.uri)}
            >
              <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round"><path d="M21 11.5a8.38 8.38 0 0 1-.9 3.8 8.5 8.5 0 0 1-7.6 4.7 8.38 8.38 0 0 1-3.8-.9L3 21l1.9-5.7a8.38 8.38 0 0 1-.9-3.8 8.5 8.5 0 0 1 4.7-7.6 8.38 8.38 0 0 1 3.8-.9h.5a8.48 8.48 0 0 1 8 8v.5z"></path></svg>
              {post.replyCount || 0}
            </button>
            <span className="bsky-action-btn" style={{ cursor: "default" }}>
              <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round"><path d="M17 1l4 4-4 4"></path><path d="M3 11V9a4 4 0 0 1 4-4h14"></path><path d="M7 23l-4-4 4-4"></path><path d="M21 13v2a4 4 0 0 1-4 4H3"></path></svg>
              {post.repostCount || 0}
            </span>
          </div>
        </div>
      );
    }
    if (vItem.source === "nostr" && vItem.event) {
      const ev = vItem.event;
      const content = String(ev.content || "");
      const npub = ev.pubkey ? `${ev.pubkey.slice(0, 12)}...` : "anon";
      const videoUrlMatch = content.match(/(https?:\/\/[^\s]+\.(mp4|webm|mov|m3u8))/i);
      return (
        <div key={`vfn-${ev.id || vi}`} className="feed-item">
          <div className="feed-header">
            <div className="feed-title" style={{ display: "flex", alignItems: "center", gap: "8px" }}>
              <div className="stack-sm" style={{ gap: "0.05rem" }}>
                <strong>{npub}</strong>
                <span className="muted text-sm" style={{ fontWeight: "normal" }}>via Nostr (primal)</span>
              </div>
            </div>
            <div className="feed-time">{ev.created_at ? formatTimestamp(ev.created_at * 1000) : ""}</div>
          </div>
          <div className="feed-body" style={{ marginTop: "8px", wordBreak: "break-word", whiteSpace: "pre-wrap" }}>
            {renderLinkedText(content)}
          </div>
          {videoUrlMatch ? (
            <div className="bluesky-embed-video-wrap" style={{ marginTop: "0.5rem" }}>
              <video className="bluesky-embed-video" controls preload="metadata" src={videoUrlMatch[1]} />
            </div>
          ) : null}
          <div className="bsky-actions">
            <button type="button" className="bsky-action-btn" onClick={() => void handleNostrReaction(ev.id, vItem.relayUrl)} disabled={nostrKeysBusy}>
              <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round"><path d="M20.84 4.61a5.5 5.5 0 0 0-7.78 0L12 5.67l-1.06-1.06a5.5 5.5 0 0 0-7.78 7.78l1.06 1.06L12 21.23l7.78-7.78 1.06-1.06a5.5 5.5 0 0 0 0-7.78z"></path></svg>
              Like
            </button>
          </div>
        </div>
      );
    }
    return null;
  };

  const renderWorldWebItem = (item: PersonalizedFeedItem, idx: number) => {
    const preview = item.webPreview;
    if (!preview) {
      return null;
    }
    const selectedSource = item.feedSource;
    const isNostr = preview.provider === "Nostr";
    const articleText = normalizeArticleText(preview.contentText || "");
    const articlePreview = summarizeArticleText(articleText || preview.description || "");
    const sourceLabel = selectedSource?.label || (item.feedItem as any)?.sourceTitle || preview.provider;
    const nostrEventId = isNostr ? (preview.url.split("/").pop() || "") : "";
    const nostrRelayUrl = isNostr && selectedSource?.label ? `wss://${selectedSource.label}` : "";
    const isArticleExpanded = expandedArticleUrl === preview.url;

    if (!isNostr) {
      return (
        <div key={`${preview.url}-${idx}`} className="feed-item feed-item-card world-article-card">
          <div className="feed-header">
            <div className="feed-title stack-sm" style={{ gap: "0.18rem" }}>
              <strong>{preview.title || preview.domain || preview.url}</strong>
              <span className="muted text-sm world-feed-source-meta">
                {sourceLabel ? `from ${sourceLabel}` : preview.provider}
                {preview.domain ? ` · ${preview.domain}` : ""}
                {selectedSource?.sourceScore != null ? ` · source relevance ${(selectedSource.sourceScore * 100).toFixed(0)}%` : ""}
                {selectedSource?.matchedInterestLabel
                  ? ` · keyword "${selectedSource.matchedInterestLabel}"${
                      selectedSource.matchedInterestScore != null
                        ? ` (${(selectedSource.matchedInterestScore * 100).toFixed(0)}%)`
                        : ""
                    }`
                  : ""}
              </span>
            </div>
            <div className="feed-time">{preview.discoveredAt ? formatTimestamp(preview.discoveredAt) : "now"}</div>
          </div>
          {preview.imageUrl ? (
            <div className="bluesky-external-card world-article-media" style={{ marginTop: "0.75rem" }}>
              <img src={preview.imageUrl} alt={preview.title || "Article preview"} className="bluesky-external-thumb" />
            </div>
          ) : null}
          <div className="world-article-summary">
            {articlePreview || preview.description || "No article preview available yet."}
          </div>
          <div className="world-article-actions">
            <button type="button" className="ghost text-sm" onClick={() => void openFeedLink(preview.url)}>
              Open in browser
            </button>
            <button
              type="button"
              className="secondary text-sm"
              disabled={!articleText}
              onClick={() => setExpandedArticleUrl(isArticleExpanded ? "" : preview.url)}
            >
              {isArticleExpanded ? "Show less" : "Read more"}
            </button>
          </div>
          {isArticleExpanded ? (
            <div className="world-article-reader">
              <div className="world-article-reader-title">Reading in app</div>
              <div className="world-article-fulltext">
                {articleText || "Full article text is not available for this feed item yet."}
              </div>
            </div>
          ) : null}
          {preview.providerSnippet && preview.providerSnippet !== sourceLabel ? (
            <div className="text-sm muted" style={{ marginTop: "0.6rem" }}>
              Source note: {preview.providerSnippet}
            </div>
          ) : null}
          {item.score != null ? (
            <div className="text-sm muted" style={{ marginTop: "0.6rem" }}>
              Relevance {(item.score * 100).toFixed(0)}%{item.matchedInterestLabel ? ` · closest interest: "${item.matchedInterestLabel}"` : ""}{item.matchedInterestScore != null
                ? ` (${(item.matchedInterestScore * 100).toFixed(0)}% similar)`
                : ""}
            </div>
          ) : null}
        </div>
      );
    }

    return (
      <div key={`${preview.url}-${idx}`} className="feed-item">
        <div className="feed-header">
          <div className="feed-title" style={{ display: "flex", alignItems: "center", gap: "8px" }}>
            <div className="stack-sm" style={{ gap: "0.05rem" }}>
              <strong>{preview.title || preview.domain}</strong>
              <span className="muted text-sm" style={{ fontWeight: "normal" }}>
                {selectedSource?.label ? `from ${selectedSource.label}` : `Web source via ${preview.provider}`}
                {selectedSource?.sourceScore != null ? ` · source relevance ${(selectedSource.sourceScore * 100).toFixed(0)}%` : ""}
                {selectedSource?.matchedInterestLabel
                  ? ` · keyword "${selectedSource.matchedInterestLabel}"${
                      selectedSource.matchedInterestScore != null
                        ? ` (${(selectedSource.matchedInterestScore * 100).toFixed(0)}%)`
                        : ""
                    }`
                  : ""}
              </span>
            </div>
          </div>
          <div className="feed-time">{preview.discoveredAt ? formatTimestamp(preview.discoveredAt) : "now"}</div>
        </div>
        <div className="bluesky-external-card" style={{ marginTop: "0.75rem" }}>
          {preview.imageUrl ? (
            <img src={preview.imageUrl} alt={preview.title || "Web preview"} className="bluesky-external-thumb" />
          ) : null}
          <div className="bluesky-external-body">
            <div className="bluesky-external-title">{preview.title || preview.url}</div>
            {preview.description ? <div className="bluesky-external-desc">{preview.description}</div> : null}
            <div className="bluesky-external-domain">{preview.domain || preview.url}</div>
          </div>
        </div>
        {preview.providerSnippet ? (
          <div className="text-sm muted" style={{ marginTop: "0.6rem" }}>
            Search snippet: {preview.providerSnippet}
          </div>
        ) : null}
        {item.score != null ? (
          <div className="text-sm muted" style={{ marginTop: "0.6rem" }}>
            Matched {item.matchedInterestLabel || "workspace interest"} at {(item.score * 100).toFixed(0)}%
            {item.matchedInterestScore != null
              ? ` (similarity ${(item.matchedInterestScore * 100).toFixed(0)}%)`
              : ""}
          </div>
        ) : null}
        <div className="bsky-actions">
          <button type="button" className="bsky-action-btn" onClick={() => void handleNostrReaction(nostrEventId, nostrRelayUrl)} disabled={nostrKeysBusy}>
            <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round"><path d="M20.84 4.61a5.5 5.5 0 0 0-7.78 0L12 5.67l-1.06-1.06a5.5 5.5 0 0 0-7.78 7.78l1.06 1.06L12 21.23l7.78-7.78 1.06-1.06a5.5 5.5 0 0 0 0-7.78z"></path></svg>
            Like
          </button>
          <button
            type="button"
            className="bsky-action-btn"
            onClick={() => setExpandedThreadUri(expandedThreadUri === preview.url ? "" : preview.url)}
          >
            <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round"><path d="M21 11.5a8.38 8.38 0 0 1-.9 3.8 8.5 8.5 0 0 1-7.6 4.7 8.38 8.38 0 0 1-3.8-.9L3 21l1.9-5.7a8.38 8.38 0 0 1-.9-3.8 8.5 8.5 0 0 1 4.7-7.6 8.38 8.38 0 0 1 3.8-.9h.5a8.48 8.48 0 0 1 8 8v.5z"></path></svg>
            Reply
          </button>
        </div>
        {expandedThreadUri === preview.url ? (
          <div className="bsky-thread-panel">
            {nostrKeys ? (
              <div className="text-sm muted" style={{ marginBottom: "0.4rem" }}>Replying as {nostrKeys.npub.slice(0, 16)}...</div>
            ) : (
              <div className="nostr-identity-banner">
                <span className="text-sm"><strong>Nostr Identity</strong></span>
                <span className="text-sm muted">A new Nostr key pair will be created automatically when you reply.</span>
              </div>
            )}
            <div className="bsky-reply-compose">
              <textarea
                className="bsky-reply-input"
                rows={1}
                placeholder="Reply to this note..."
                value={replyDrafts[preview.url] || ""}
                onChange={(e) => {
                  e.target.style.height = "0px";
                  e.target.style.height = `${e.target.scrollHeight}px`;
                  setReplyDrafts((prev) => ({ ...prev, [preview.url]: e.target.value }));
                }}
              />
              <button
                type="button"
                className="primary bsky-reply-send"
                disabled={!replyDrafts[preview.url]?.trim() || nostrKeysBusy}
                onClick={() => {
                  void handleNostrReply(nostrEventId, nostrRelayUrl, replyDrafts[preview.url] || "");
                  setReplyDrafts((prev) => {
                    const next = { ...prev };
                    delete next[preview.url];
                    return next;
                  });
                }}
              >
                Send
              </button>
            </div>
          </div>
        ) : null}
      </div>
    );
  };

  const renderWorldBlueskyItem = (item: PersonalizedFeedItem, idx: number) => {
    const feedItem = item.feedItem as AppBskyFeedDefs.FeedViewPost;
    const post = feedItem.post;
    const author = post.author;
    const record = post.record as any;
    const text = String(record?.text || "");
    const feedSource = item.feedSource;
    const embedNode = renderBlueskyEmbed(post.embed as any);
    const postUri = post.uri;
    const postCid = post.cid;
    const isLiked = Boolean(blueskyLikedUris[postUri] || (post.viewer as any)?.like);
    const isThreadOpen = expandedThreadUri === postUri;
    const facetLinks = Array.isArray(record?.facets)
      ? record.facets
          .flatMap((facet: any) => (Array.isArray(facet?.features) ? facet.features : []))
          .map((feature: any) => String(feature?.uri || "").trim())
          .filter((uri: string) => uri.startsWith("http://") || uri.startsWith("https://"))
      : [];
    const textLinks = Array.from(text.matchAll(/https?:\/\/[^\s]+/g)).map((match) => String(match[0] || "").trim());
    const fallbackLinks = Array.from(new Set([...facetLinks, ...textLinks]));
    const hasExternalEmbed =
      Boolean(post.embed && (post.embed as any).$type === "app.bsky.embed.external#view") ||
      Boolean(
        post.embed &&
          (post.embed as any).$type === "app.bsky.embed.recordWithMedia#view" &&
          (post.embed as any).media?.$type === "app.bsky.embed.external#view"
      );
    return (
      <div key={`${post.cid}-${idx}`} className="feed-item">
        <div className="feed-header">
          <div className="feed-title" style={{ display: "flex", alignItems: "center", gap: "8px" }}>
            {author.avatar ? <img src={author.avatar} alt="" style={{ width: "36px", height: "36px", borderRadius: "50%", objectFit: "cover" }} /> : null}
            <div className="stack-sm" style={{ gap: "0.05rem" }}>
              <strong>{author.displayName || author.handle}</strong>
              <span className="muted text-sm" style={{ fontWeight: "normal" }}>@{author.handle}</span>
              {feedSource?.label ? (
                <span className="muted text-sm" style={{ fontWeight: "normal" }}>
                  from {feedSource.label}
                  {feedSource.sourceScore != null ? ` · source relevance ${(feedSource.sourceScore * 100).toFixed(0)}%` : ""}
                  {feedSource.matchedInterestLabel
                    ? ` · keyword "${feedSource.matchedInterestLabel}"${
                        feedSource.matchedInterestScore != null
                          ? ` (${(feedSource.matchedInterestScore * 100).toFixed(0)}%)`
                          : ""
                      }`
                    : ""}
                </span>
              ) : null}
            </div>
          </div>
          <div className="feed-time">{formatTimestamp(post.indexedAt)}</div>
        </div>
        <div className="feed-body" style={{ marginTop: "8px", wordBreak: "break-word", whiteSpace: "pre-wrap" }}>
          {renderLinkedText(text)}
        </div>
        {embedNode}
        {item.score != null ? (
          <div className="text-sm muted" style={{ marginTop: "0.6rem" }}>
            Matched {item.matchedInterestLabel || "workspace interest"} at {(item.score * 100).toFixed(0)}%
            {item.matchedInterestScore != null
              ? ` (similarity ${(item.matchedInterestScore * 100).toFixed(0)}%)`
              : ""}
          </div>
        ) : null}
        {!hasExternalEmbed && fallbackLinks.length > 0 ? (
          <div className="stack" style={{ gap: "0.5rem" }}>
            {fallbackLinks.map((url) => (
              <a key={`${post.cid}-${url}`} href={url} target="_blank" rel="noreferrer" className="bluesky-external-card">
                <div className="bluesky-external-body">
                  <div className="bluesky-external-title">{url}</div>
                  <div className="bluesky-external-domain">
                    {(() => {
                      try {
                        return new URL(url).hostname;
                      } catch {
                        return url;
                      }
                    })()}
                  </div>
                </div>
              </a>
            ))}
          </div>
        ) : null}
        <div className="bsky-actions">
          <button type="button" className={`bsky-action-btn ${isLiked ? "liked" : ""}`} onClick={() => void handleLikeBlueskyPost(postUri, postCid)} disabled={!session}>
            <svg width="16" height="16" viewBox="0 0 24 24" fill={isLiked ? "#f91880" : "none"} stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round"><path d="M20.84 4.61a5.5 5.5 0 0 0-7.78 0L12 5.67l-1.06-1.06a5.5 5.5 0 0 0-7.78 7.78l1.06 1.06L12 21.23l7.78-7.78 1.06-1.06a5.5 5.5 0 0 0 0-7.78z"></path></svg>
            {(post.likeCount || 0) + (blueskyLikedUris[postUri] && !(post.viewer as any)?.like ? 1 : 0)}
          </button>
          <button type="button" className={`bsky-action-btn ${isThreadOpen ? "liked" : ""}`} onClick={() => void handleExpandThread(postUri)}>
            <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round"><path d="M21 11.5a8.38 8.38 0 0 1-.9 3.8 8.5 8.5 0 0 1-7.6 4.7 8.38 8.38 0 0 1-3.8-.9L3 21l1.9-5.7a8.38 8.38 0 0 1-.9-3.8 8.5 8.5 0 0 1 4.7-7.6 8.38 8.38 0 0 1 3.8-.9h.5a8.48 8.48 0 0 1 8 8v.5z"></path></svg>
            {post.replyCount || 0}
          </button>
          <span className="bsky-action-btn" style={{ cursor: "default" }}>
            <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round"><path d="M17 1l4 4-4 4"></path><path d="M3 11V9a4 4 0 0 1 4-4h14"></path><path d="M7 23l-4-4 4-4"></path><path d="M21 13v2a4 4 0 0 1-4 4H3"></path></svg>
            {post.repostCount || 0}
          </span>
        </div>
        {isThreadOpen ? (
          <div className="bsky-thread-panel">
            {threadLoading ? (
              <div className="bsky-thread-loading">Loading comments...</div>
            ) : threadData?.error ? (
              <div className="text-sm muted">{threadData.error}</div>
            ) : threadData?.thread?.replies?.length > 0 ? (
              <div className="bsky-thread-replies">
                {threadData.thread.replies.slice(0, 20).map((reply: any, ri: number) => {
                  const rPost = reply?.post;
                  if (!rPost) return null;
                  const rAuthor = rPost.author || {};
                  const rRecord = rPost.record as any;
                  const rText = String(rRecord?.text || "");
                  return (
                    <div key={rPost.cid || ri} className="bsky-thread-reply">
                      {rAuthor.avatar ? <img src={rAuthor.avatar} alt="" className="bsky-reply-avatar" /> : <div className="bsky-reply-avatar" style={{ background: "var(--line)" }} />}
                      <div className="bsky-reply-body">
                        <span className="bsky-reply-author">{rAuthor.displayName || rAuthor.handle}</span>
                        <span className="bsky-reply-handle">@{rAuthor.handle}</span>
                        <div className="bsky-reply-text">{renderLinkedText(rText)}</div>
                        <div className="bsky-reply-time">{formatTimestamp(rPost.indexedAt)}</div>
                      </div>
                    </div>
                  );
                })}
              </div>
            ) : (
              <div className="text-sm muted">No replies yet.</div>
            )}
            {session ? (
              <div className="bsky-reply-compose">
                <textarea
                  className="bsky-reply-input"
                  rows={1}
                  placeholder="Write a reply..."
                  value={replyDrafts[postUri] || ""}
                  onChange={(e) => {
                    e.target.style.height = "0px";
                    e.target.style.height = `${e.target.scrollHeight}px`;
                    setReplyDrafts((prev) => ({ ...prev, [postUri]: e.target.value }));
                  }}
                />
                <button
                  type="button"
                  className="primary bsky-reply-send"
                  disabled={!replyDrafts[postUri]?.trim() || replyingUri === postUri}
                  onClick={() => void handleReplyToBlueskyPost(postUri, postCid, postUri, postCid)}
                >
                  {replyingUri === postUri ? "..." : "Reply"}
                </button>
              </div>
            ) : (
              <div className="text-sm muted" style={{ marginTop: "0.5rem" }}>Sign in to Bluesky to reply.</div>
            )}
          </div>
        ) : null}
      </div>
    );
  };

  const renderWorldFeedItems = () => {
    if (worldFeedTab === "videos") {
      if (worldVideoItems.length > 0) {
        return worldVideoItems.map((item, idx) =>
          item.sourceType === "bluesky" ? renderWorldBlueskyItem(item, idx) : renderWorldWebItem(item, idx)
        );
      }
      if (videoFallbackLoading) {
        return <p className="text-center muted" style={{ padding: "1.5rem" }}>Loading videos...</p>;
      }
      if (videoFallbackItems.length === 0) {
        return <p className="text-center muted" style={{ padding: "1.5rem" }}>No video posts found yet. Try refreshing.</p>;
      }
      return videoFallbackItems.map(renderWorldVideoFallbackItem);
    }

    const selectedItems = worldFeedTab === "articles" ? worldArticleItems : worldTweetItems;
    if (selectedItems.length === 0) {
      return (
        <p className="text-center muted" style={{ padding: "1.5rem" }}>
          {worldFeedTab === "articles"
            ? "No long-form articles found yet."
            : "No Bluesky or Nostr posts found yet."}
        </p>
      );
    }
    return selectedItems.map((item, idx) =>
      item.sourceType === "bluesky" ? renderWorldBlueskyItem(item, idx) : renderWorldWebItem(item, idx)
    );
  };

  if (needsMobileQrLogin) {
    return (
      <div className="app-shell">
        <main className="page-content">
          <div className="stack">
            <div className="card">
              <h2>Connect To Desktop</h2>
              <p className="text-sm muted">
                Scan the QR from the desktop app to sync gateway URL + token.
              </p>
              <div className="stack" style={{ alignItems: "center", gap: "0.8rem" }}>
                <video
                  ref={mobileScannerVideoRef}
                  style={{
                    width: "100%",
                    maxWidth: "360px",
                    borderRadius: "14px",
                    background: "#000",
                    minHeight: "240px"
                  }}
                  playsInline
                  muted
                />
                <div className="row">
                  <button
                    type="button"
                    className="primary"
                    onClick={() => setMobileScannerActive(true)}
                    disabled={mobileScannerActive}
                  >
                    {mobileScannerActive ? "Scanning..." : "Start Scanner"}
                  </button>
                  <button
                    type="button"
                    className="ghost"
                    onClick={stopMobileScanner}
                    disabled={!mobileScannerActive}
                  >
                    Stop
                  </button>
                </div>
                <p className="text-sm muted text-center">{mobileScannerStatus}</p>
                {mobileCameraPermissionError ? (
                  <p className="text-sm text-center" style={{ color: "var(--danger)" }}>
                    {mobileCameraPermissionError}
                  </p>
                ) : null}
              </div>
            </div>
          </div>
        </main>
      </div>
    );
  }

  return (
    <div className="app-shell">
      {!hideChrome && (
        <header className="topbar">
          <div className="row" style={{ alignItems: "center", gap: "1rem" }}>
            {mobileTab === "journal" && !showDesktopJournalLayout && (
              <button type="button" className="ghost" onClick={() => setJournalSidebarOpen(true)} style={{ padding: "0.2rem" }}>
                <svg width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round"><line x1="3" y1="12" x2="21" y2="12"></line><line x1="3" y1="6" x2="21" y2="6"></line><line x1="3" y1="18" x2="21" y2="18"></line></svg>
              </button>
            )}
            {mobileTab === "journal" && (
              <div className="topbar-action-group">
                <button
                  type="button"
                  className="ghost"
                  onClick={resetJournalSession}
                  title="Start a new journal session"
                >
                  <svg width="22" height="22" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round"><line x1="12" y1="5" x2="12" y2="19"></line><line x1="5" y1="12" x2="19" y2="12"></line></svg>
                </button>
                {showDesktopJournalLayout && (
                  <button
                    type="button"
                    className={`ghost ${journalDesktopSidebarCollapsed ? "active-icon-btn" : ""}`}
                    onClick={() => setJournalDesktopSidebarCollapsed((prev) => !prev)}
                    title={journalDesktopSidebarCollapsed ? "Show recent journals" : "Collapse recent journals"}
                  >
                    {journalDesktopSidebarCollapsed ? (
                      <svg width="22" height="22" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round"><rect x="3" y="3" width="18" height="18" rx="2"></rect><path d="M9 3v18"></path><polyline points="14 9 17 12 14 15"></polyline></svg>
                    ) : (
                      <svg width="22" height="22" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round"><rect x="3" y="3" width="18" height="18" rx="2"></rect><path d="M9 3v18"></path><polyline points="17 9 14 12 17 15"></polyline></svg>
                    )}
                  </button>
                )}
              </div>
            )}
            <h1>SlowClaw</h1>
          </div>
          <div className="topbar-actions">
            <button
              type="button"
              className="ghost"
              onClick={() => setThemeMode((prev) => (prev === "light" ? "dark" : "light"))}
              title="Toggle theme"
            >
              {themeMode === "light" ? (
                <svg width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round"><circle cx="12" cy="12" r="5"></circle><line x1="12" y1="1" x2="12" y2="3"></line><line x1="12" y1="21" x2="12" y2="23"></line><line x1="4.22" y1="4.22" x2="5.64" y2="5.64"></line><line x1="18.36" y1="18.36" x2="19.78" y2="19.78"></line><line x1="1" y1="12" x2="3" y2="12"></line><line x1="21" y1="12" x2="23" y2="12"></line><line x1="4.22" y1="19.78" x2="5.64" y2="18.36"></line><line x1="18.36" y1="4.22" x2="19.78" y2="5.64"></line></svg>
              ) : (
                <svg width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round"><path d="M21 12.79A9 9 0 1 1 11.21 3 7 7 0 0 0 21 12.79z"></path></svg>
              )}
            </button>
            <button
              type="button"
              className={`ghost ${mobileTab === "profile" ? "active-icon-btn" : ""}`}
              onClick={() => setMobileTab("profile")}
              title="Settings"
            >
              <svg width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round"><circle cx="12" cy="12" r="3"></circle><path d="M19.4 15a1.65 1.65 0 0 0 .33 1.82l.06.06a2 2 0 0 1 0 2.83 2 2 0 0 1-2.83 0l-.06-.06a1.65 1.65 0 0 0-1.82-.33 1.65 1.65 0 0 0-1 1.51V21a2 2 0 0 1-4 0v-.09a1.65 1.65 0 0 0-1-1.51 1.65 1.65 0 0 0-1.82.33l-.06.06a2 2 0 0 1-2.83 0 2 2 0 0 1 0-2.83l.06-.06a1.65 1.65 0 0 0 .33-1.82 1.65 1.65 0 0 0-1.51-1H3a2 2 0 0 1 0-4h.09a1.65 1.65 0 0 0 1.51-1 1.65 1.65 0 0 0-.33-1.82L4.21 7.1a2 2 0 0 1 0-2.83 2 2 0 0 1 2.83 0l.06.06a1.65 1.65 0 0 0 1.82.33h.01a1.65 1.65 0 0 0 1-1.51V3a2 2 0 0 1 4 0v.09a1.65 1.65 0 0 0 1 1.51h.01a1.65 1.65 0 0 0 1.82-.33l.06-.06a2 2 0 0 1 2.83 0 2 2 0 0 1 0 2.83l-.06.06a1.65 1.65 0 0 0-.33 1.82v.01a1.65 1.65 0 0 0 1.51 1H21a2 2 0 0 1 0 4h-.09a1.65 1.65 0 0 0-1.51 1z"></path></svg>
            </button>
          </div>
        </header>
      )}

      {mobileTab === "journal" && !showDesktopJournalLayout && !hideChrome ? (
        <div className={`sidebar-overlay ${journalSidebarOpen ? 'open' : ''}`} onClick={() => setJournalSidebarOpen(false)}>
          <div className={`sidebar ${journalSidebarOpen ? 'open' : ''}`} onClick={e => e.stopPropagation()}>
            {renderJournalSidebarContent(true, "mobile")}
          </div>
        </div>
      ) : null}

      {pendingDeleteJournalItem ? (
        <div className="confirm-overlay" onClick={() => setPendingDeleteJournalItem(null)}>
          <div className="confirm-dialog card" onClick={(e) => e.stopPropagation()}>
            <div className="stack-sm">
              <h3>Delete Journal?</h3>
              <p className="text-sm muted">
                This will permanently remove "{pendingDeleteJournalItem.title}" from the workspace.
              </p>
            </div>
            <div className="row" style={{ justifyContent: "flex-end" }}>
              <button
                type="button"
                className="ghost"
                onClick={() => setPendingDeleteJournalItem(null)}
              >
                Cancel
              </button>
              <button
                type="button"
                className="danger"
                onClick={() => void deleteJournalItem(pendingDeleteJournalItem)}
              >
                Delete
              </button>
            </div>
          </div>
        </div>
      ) : null}

      {pendingDeleteFeedItem ? (
        <div className="confirm-overlay" onClick={() => setPendingDeleteFeedItem(null)}>
          <div className="confirm-dialog card" onClick={(e) => e.stopPropagation()}>
            <div className="stack-sm">
              <h3>Delete Feed Item?</h3>
              <p className="text-sm muted">
                This will permanently remove "{pendingDeleteFeedItem.title}" from the workspace feed.
              </p>
            </div>
            <div className="row" style={{ justifyContent: "flex-end" }}>
              <button
                type="button"
                className="ghost"
                onClick={() => setPendingDeleteFeedItem(null)}
              >
                Cancel
              </button>
              <button
                type="button"
                className="danger"
                onClick={() => void deleteFeedItem(pendingDeleteFeedItem)}
              >
                Delete
              </button>
            </div>
          </div>
        </div>
      ) : null}

      <main className="page-content">
        {mobileTab === "journal" ? (
          <ViewErrorBoundary title="Journal">
            <div className={showDesktopJournalSidebar ? "journal-desktop-layout" : "stack"}>
              {showDesktopJournalSidebar ? (
                <aside className="sidebar sidebar-desktop open">
                  {renderJournalSidebarContent(false, "desktop")}
                </aside>
              ) : null}
              <div className={`stack journal-main ${isWritingNote ? "journal-main-writing" : ""}`}>
              {!isWritingNote && !isCaptureZenMode && (
                <div className="card">
                  <div className="text-center">
                    <h2>Capture</h2>
                    <p className="text-sm mt-2">{recordingHint || "Record audio or video directly to workspace"}</p>
                  </div>
                  {selectedJournalItem &&
                    (selectedJournalItem.kind === "audio" || selectedJournalItem.kind === "video") ? (
                    <div className="stack" style={{ marginTop: "1rem" }}>
                      {mediaPreviewLoading ? (
                        <p className="text-sm muted text-center">Loading media preview...</p>
                      ) : mediaPreviewUrl ? (
                        <>
                          {selectedJournalItem.kind === "audio" ? (
                            <div className="audio-preview-shell">
                              <div className="audio-preview-meta">
                                <div className="audio-preview-icon" aria-hidden>
                                  <svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round"><path d="M12 1a3 3 0 0 0-3 3v8a3 3 0 0 0 6 0V4a3 3 0 0 0-3-3z"></path><path d="M19 10v2a7 7 0 0 1-14 0v-2"></path><line x1="12" y1="19" x2="12" y2="23"></line><line x1="8" y1="23" x2="16" y2="23"></line></svg>
                                </div>
                                <div className="stack-sm" style={{ gap: "0.2rem" }}>
                                  <span className="section-label">Audio Preview</span>
                                  <span className="text-sm muted">{selectedJournalItem.title || "Recorded audio"}</span>
                                </div>
                              </div>
                              <audio controls style={{ width: "100%" }}>
                                <source src={mediaPreviewUrl} type={mediaPreviewMime || undefined} />
                              </audio>
                            </div>
                          ) : (
                            <video controls src={mediaPreviewUrl} className="media-viewer" style={{ marginTop: 0 }} />
                          )}
                        </>
                      ) : (
                        <p className="text-sm muted text-center">Media preview unavailable.</p>
                      )}
                    </div>
                  ) : (
                    <div className="stack">
                      <div className="record-btn-group">
                        <button
                          type="button"
                          className="record-btn audio"
                          onClick={() => {
                            setCaptureMode("audio");
                            setRecordingHint("Preparing audio capture...");
                            void startLiveRecording("audio");
                          }}
                          title="Record Audio"
                        >
                          <svg viewBox="0 0 24 24"><path d="M12 1a3 3 0 0 0-3 3v8a3 3 0 0 0 6 0V4a3 3 0 0 0-3-3z"></path><path d="M19 10v2a7 7 0 0 1-14 0v-2"></path><line x1="12" y1="19" x2="12" y2="23"></line><line x1="8" y1="23" x2="16" y2="23"></line></svg>
                        </button>
                        <button
                          type="button"
                          className="record-btn video"
                          onClick={() => {
                            setCaptureMode("video");
                            setRecordingHint("Choose orientation and start recording.");
                          }}
                          title="Record Video"
                        >
                          <svg viewBox="0 0 24 24"><polygon points="23 7 16 12 23 17 23 7"></polygon><rect x="1" y="5" width="15" height="14" rx="2" ry="2"></rect></svg>
                        </button>
                      </div>

                      {audioDevices.length > 1 && (
                        <div className="text-center mt-2">
                          <select
                            value={selectedAudioDeviceId}
                            onChange={(e) => setSelectedAudioDeviceId(e.target.value)}
                            className="text-sm"
                            style={{ background: "transparent", border: "1px solid var(--line)", padding: "4px 8px", borderRadius: "12px", color: "var(--muted)" }}
                          >
                            {audioDevices.map(d => (
                              <option key={d.deviceId} value={d.deviceId}>{d.label || 'Microphone'}</option>
                            ))}
                          </select>
                        </div>
                      )}
                    </div>
                  )}
                </div>
              )}

              {isCaptureZenMode && (
                <div className="card capture-zen">
                  <div className="row-between">
                    <button
                      type="button"
                      className="ghost text-sm"
                      onClick={cancelRecording}
                    >
                      Back
                    </button>
                    <div className="capture-zen-timer">
                      {Math.floor(recordingTime / 60)}:{(recordingTime % 60).toString().padStart(2, "0")}
                    </div>
                  </div>
                  <div className="capture-stage">
                    {captureMode === "audio" ? (
                      <div className="capture-audio-shell">
                        <p className="text-sm muted">Audio capture</p>
                        <canvas ref={audioCanvasRef} width={720} height={220} className="audio-zen-canvas" />
                        <div className="capture-audio-feedback">
                          <span className="pulse-dot" />
                          <span>{isRecording ? "Listening" : "Starting microphone..."}</span>
                        </div>
                      </div>
                    ) : null}
                    {captureMode === "video" ? (
                      <div className="capture-video-shell">
                        {!isRecording ? (
                          <div className="stack" style={{ gap: "0.8rem", alignItems: "center" }}>
                            <p className="text-sm muted" style={{ margin: 0 }}>
                              Choose orientation to start video capture
                            </p>
                            <div className="row-center" style={{ gap: "0.6rem" }}>
                              <button
                                type="button"
                                className={videoOrientation === "vertical" ? "primary text-sm" : "ghost text-sm"}
                                onClick={() => setVideoOrientation("vertical")}
                              >
                                Vertical
                              </button>
                              <button
                                type="button"
                                className={videoOrientation === "horizontal" ? "primary text-sm" : "ghost text-sm"}
                                onClick={() => setVideoOrientation("horizontal")}
                              >
                                Horizontal
                              </button>
                            </div>
                            <button
                              type="button"
                              className="primary"
                              onClick={() => void startLiveRecording("video")}
                            >
                              Start Recording
                            </button>
                          </div>
                        ) : (
                          <video
                            ref={videoPreviewRef}
                            className={`video-zen-preview ${videoOrientation === "vertical" ? "vertical" : "horizontal"}`}
                            muted
                            playsInline
                          />
                        )}
                      </div>
                    ) : null}
                  </div>
                  <div className="row-center" style={{ gap: "0.7rem" }}>
                    <button
                      type="button"
                      className="danger"
                      onClick={() => void stopLiveRecording()}
                      disabled={!isRecording}
                    >
                      Stop & Save
                    </button>
                    <button type="button" className="ghost" onClick={cancelRecording}>
                      Cancel
                    </button>
                  </div>
                </div>
              )}

              {!isCaptureZenMode && (
                <div
                  className={`card ${isWritingNote || isMediaTranscriptMode || isFreshNoteMode ? "note-card-expanded" : ""}`}
                  style={{ flex: isWritingNote || isMediaTranscriptMode || isFreshNoteMode ? 1 : undefined }}
                >
                  <div className="row-between">
                    <h2 style={{ margin: 0 }}>Session</h2>
                    <div className="row" style={{ gap: '0.5rem', alignItems: 'center' }}>
                      {selectedJournalSynthSourcePath ? (
                        <button
                          type="button"
                          className="ghost text-sm"
                          onClick={() =>
                            void runWorkspaceSynthesizerManual({
                              sourcePath: selectedJournalSynthSourcePath,
                              force: selectedJournalWasProcessed
                            })
                          }
                          disabled={
                            workspaceSynthBusy || workspaceSynthRunning || !workspaceSynthProviderReady
                          }
                          title={
                            !workspaceSynthProviderReady
                              ? workspaceSynthProviderBlockedReason
                              : selectedJournalWasProcessed
                              ? "Run the synthesizer again for this journal entry"
                              : "Process this journal entry now"
                          }
                        >
                          {selectedJournalWasProcessed ? "Re-process" : "Process"}
                        </button>
                      ) : null}
                      <span className="text-sm muted">{journalSaveStatus !== "Journal idle" ? journalSaveStatus : ""}</span>
                      {isWritingNote && <button type="button" className="ghost" onClick={() => setIsWritingNote(false)}>Done</button>}
                    </div>
                  </div>
                  {selectedJournalItem &&
                    selectedJournalItem.kind === "audio" &&
                    !journalDraftText.trim() && (
                      <div className="row" style={{ marginBottom: "0.6rem" }}>
                        <button
                          type="button"
                          className="primary"
                          onClick={() => void transcribeSelectedJournalMedia()}
                          disabled={
                            journalTranscribing ||
                            selectedJournalTranscriptionStatus === "queued" ||
                            selectedJournalTranscriptionStatus === "running"
                          }
                        >
                          {journalTranscribing ||
                            selectedJournalTranscriptionStatus === "queued" ||
                            selectedJournalTranscriptionStatus === "running" ? (
                            <span className="row" style={{ gap: "0.45rem", alignItems: "center" }}>
                              <span className="btn-spinner" aria-hidden />
                              {selectedJournalTranscriptionStatus === "queued"
                                ? "Queued..."
                                : "Transcribing..."}
                            </span>
                          ) : (
                            "Transcribe audio"
                          )}
                        </button>
                      </div>
                    )}
                  <textarea
                    rows={isWritingNote || isMediaTranscriptMode || isFreshNoteMode ? 15 : 5}
                    value={journalDraftText}
                    onChange={(e) => setJournalDraftText(e.target.value)}
                    onFocus={() => {
                      if (!isMediaTranscriptMode) {
                        setIsWritingNote(true);
                      }
                    }}
                    placeholder="Write your thoughts..."
                    style={{
                      flex: isWritingNote || isMediaTranscriptMode || isFreshNoteMode ? 1 : undefined,
                      resize: "none",
                      minHeight:
                        isWritingNote || isMediaTranscriptMode || isFreshNoteMode
                          ? "100%"
                          : undefined
                    }}
                  />
                </div>
              )}

              </div>
            </div>
          </ViewErrorBoundary>
        ) : null}

        {mobileTab === "feed" ? (
          <ViewErrorBoundary title="Feed">
            <div className="stack">
              <div className="card">
              <div className="row-between">
                <h2>Your Feed</h2>
                <div className="row" style={{ gap: "0.35rem", alignItems: "center" }}>
                  {feedSource === "local" ? (
                    <button
                      type="button"
                      className={`feed-plus-btn ${feedSidebarOpen ? "active" : ""}`}
                      onClick={() => {
                        setFeedSidebarOpen((prev) => !prev);
                        setFeedCreateWorkflowOpen(false);
                      }}
                      title="Open content agent drawer"
                    >
                      +
                    </button>
                  ) : null}
                  <button
                    type="button"
                    className="ghost"
                    onClick={() => {
                      if (feedSource === "bluesky") {
                        void fetchBlueskyFeed({ force: true });
                      } else {
                        void refreshWorkspaceViews({ runSynthIfPending: true });
                      }
                    }}
                  >
                    <svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round"><polyline points="23 4 23 10 17 10"></polyline><polyline points="1 20 1 14 7 14"></polyline><path d="M3.51 9a9 9 0 0 1 14.85-3.36L23 10M1 14l4.64 4.36A9 9 0 0 0 20.49 15"></path></svg>
                  </button>
                </div>
              </div>

              <div className="segmented-control mt-2 mb-2">
                <button
                  type="button"
                  className={feedSource === "local" ? "active" : ""}
                  onClick={() => setFeedSource("local")}
                >
                  Me
                </button>
                <button
                  type="button"
                  className={feedSource === "bluesky" ? "active" : ""}
                  onClick={() => setFeedSource("bluesky")}
                >
                  World
                </button>
              </div>

              {feedSource === "local" && feedSidebarOpen ? (
                <div className="feed-workflow-drawer">
                  <div className="row-between">
                    <h3 style={{ margin: 0 }}>Workspace Synthesizer</h3>
                    <button
                      type="button"
                      className="ghost text-sm"
                      onClick={() => setFeedSidebarOpen(false)}
                    >
                      Close
                    </button>
                  </div>
                  <p className="text-sm muted" style={{ margin: 0 }}>
                    The synthesizer is the main journal extraction agent. Check the skills you want applied regularly, then run the synthesizer to process pending journal entries.
                  </p>
                  <div className="feed-agent-facts">
                    <div>
                      <span className="text-sm muted">Pending journal entries</span>
                      <strong>{workspaceSynthPendingCount}</strong>
                    </div>
                    <div>
                      <span className="text-sm muted">Selected this run</span>
                      <strong>{workspaceSynthSelectedCount}</strong>
                    </div>
                  </div>
                  {runtimeMediaSummary ? (
                    <p className="text-sm muted" style={{ margin: 0 }}>
                      {runtimeMediaSummary}
                    </p>
                  ) : null}
                  {!workspaceSynthProviderReady && workspaceSynthProviderBlockedReason ? (
                    <div className="feed-comment-status">{workspaceSynthProviderBlockedReason}</div>
                  ) : null}
                  <button
                    type="button"
                    className="primary text-sm"
                    style={{ width: "100%", borderRadius: "10px" }}
                    onClick={() => void runWorkspaceSynthesizerManual()}
                    disabled={
                      workspaceSynthBusy || workspaceSynthRunning || !workspaceSynthProviderReady
                    }
                    title={!workspaceSynthProviderReady ? workspaceSynthProviderBlockedReason : undefined}
                  >
                    {workspaceSynthBusy || workspaceSynthRunning ? "Running..." : "Run Workspace Synthesizer"}
                  </button>
                  <div className="row-between" style={{ alignItems: "center", marginTop: "0.2rem" }}>
                    <span className="text-sm muted">Journal skills</span>
                    <span className="text-sm muted">
                      {workspaceSynthSkillItems.filter((item) => item.enabled).length}/{workspaceSynthSkillItems.length} enabled
                    </span>
                  </div>
                  <div className="feed-workflow-bot-list">
                    {workspaceSynthSkillBots.map((bot) => {
                      const saved = workspaceSynthSkillsByKey[bot.key];
                      const isBusy = workspaceSynthSkillToggleBusyKey === bot.key;
                      const enableBlocked = saved?.enabled === false && saved?.supported === false;
                      const isActive = activeWorkspaceSynthSkillKey === bot.key;
                      return (
                        <div key={bot.key} className="feed-workflow-bot-row">
                          <button
                            type="button"
                            className="feed-workflow-bot-open"
                            onClick={() => setActiveWorkspaceSynthSkillKey(bot.key)}
                          >
                            <span className="stack" style={{ gap: "0.2rem", width: "100%" }}>
                              <span className="feed-bot-chip">
                                <span className="feed-bot-avatar">{bot.avatar}</span>
                                <span>{bot.name}</span>
                              </span>
                              {bot.goal ? (
                                <span className="feed-bot-goal text-sm muted">{bot.goal}</span>
                              ) : null}
                              {saved?.unsupportedReason ? (
                                <span className="feed-bot-goal text-sm muted">
                                  {saved.unsupportedReason}
                                </span>
                              ) : null}
                              {isActive ? (
                                <span className="feed-bot-goal text-sm muted">
                                  Editing artifact rules
                                </span>
                              ) : null}
                            </span>
                          </button>
                          <button
                            type="button"
                            className={saved?.enabled === false ? "ghost text-sm" : "primary text-sm"}
                            style={{ minWidth: "72px", borderRadius: "999px" }}
                            onClick={() => void toggleWorkspaceSynthSkillEnabled(bot.key)}
                            disabled={isBusy || enableBlocked}
                            title={enableBlocked ? saved?.unsupportedReason : undefined}
                          >
                            {isBusy ? "..." : saved?.enabled === false ? "Off" : "On"}
                          </button>
                        </div>
                      );
                    })}
                    {!workspaceSynthSkillBots.length ? (
                      <p className="text-sm muted" style={{ margin: 0 }}>
                        No workspace synth skills are available yet.
                      </p>
                    ) : null}
                  </div>
                  {activeWorkspaceSynthSkillKey
                    ? (() => {
                        const activeSkill = workspaceSynthSkillsByKey[activeWorkspaceSynthSkillKey];
                        if (!activeSkill) {
                          return null;
                        }
                        const draft =
                          workspaceSynthSkillDraftByKey[activeWorkspaceSynthSkillKey] ??
                          activeSkill.artifactRulesOverride ??
                          activeSkill.artifactRules ??
                          "";
                        const saveStatus =
                          workspaceSynthSkillSaveStatusByKey[activeWorkspaceSynthSkillKey] || "";
                        const isSaving =
                          workspaceSynthSkillSavingKey === activeWorkspaceSynthSkillKey;
                        const usingOverride = Boolean(
                          activeSkill.artifactRulesOverride &&
                            activeSkill.artifactRulesOverride.trim()
                        );
                        return (
                          <div className="workflow-settings-panel stack">
                            <div className="row-between">
                              <h3 style={{ margin: 0 }}>{activeSkill.name}</h3>
                              <button
                                type="button"
                                className="ghost text-sm"
                                onClick={() => setActiveWorkspaceSynthSkillKey("")}
                              >
                                Close
                              </button>
                            </div>
                            <p className="text-sm muted" style={{ margin: 0 }}>
                              Customize the Artifact Rules section for this skill. These rules are injected into the bundled workspace synthesis prompt.
                            </p>
                            {activeSkill.artifactRules ? (
                              <div className="stack" style={{ gap: "0.3rem" }}>
                                <span className="text-sm muted">Built-in rules</span>
                                <pre className="workflow-run-detail">{activeSkill.artifactRules}</pre>
                              </div>
                            ) : null}
                            <label className="stack" style={{ gap: "0.35rem" }}>
                              <span className="text-sm">
                                {usingOverride ? "Custom artifact rules" : "Artifact rules"}
                              </span>
                              <textarea
                                rows={8}
                                value={draft}
                                onChange={(e) =>
                                  setWorkspaceSynthSkillDraftByKey((prev) => ({
                                    ...prev,
                                    [activeWorkspaceSynthSkillKey]: e.target.value
                                  }))
                                }
                              />
                            </label>
                            <div className="feed-comment-actions">
                              <button
                                type="button"
                                className="primary text-sm"
                                style={{ padding: "0.35rem 0.75rem", borderRadius: "8px" }}
                                onClick={() =>
                                  void saveWorkspaceSynthSkillArtifactRules(activeWorkspaceSynthSkillKey)
                                }
                                disabled={isSaving}
                              >
                                {isSaving ? "Saving..." : "Save Rules"}
                              </button>
                              <button
                                type="button"
                                className="ghost text-sm"
                                style={{ padding: "0.35rem 0.75rem", borderRadius: "8px" }}
                                onClick={() =>
                                  setWorkspaceSynthSkillDraftByKey((prev) => ({
                                    ...prev,
                                    [activeWorkspaceSynthSkillKey]:
                                      activeSkill.artifactRulesOverride ||
                                      activeSkill.artifactRules ||
                                      ""
                                  }))
                                }
                                disabled={isSaving}
                              >
                                Revert Draft
                              </button>
                              <button
                                type="button"
                                className="ghost text-sm"
                                style={{ padding: "0.35rem 0.75rem", borderRadius: "8px" }}
                                onClick={() =>
                                  void saveWorkspaceSynthSkillArtifactRules(
                                    activeWorkspaceSynthSkillKey,
                                    true
                                  )
                                }
                                disabled={isSaving || !usingOverride}
                              >
                                Use Built-in
                              </button>
                            </div>
                            {saveStatus ? <div className="feed-comment-status">{saveStatus}</div> : null}
                          </div>
                        );
                      })()
                    : null}
                  {workspaceSynthStatus.skillRuns?.length ? (
                    <div className="stack" style={{ gap: "0.45rem" }}>
                      <span className="text-sm muted">Recent skill activity</span>
                      {workspaceSynthStatus.skillRuns.slice(0, 6).map((run: WorkspaceSynthSkillRunState) => (
                        <div key={`synth-run-${run.skillKey}`} className="workflow-run-card">
                          <div className="row-between" style={{ gap: "0.6rem", alignItems: "center" }}>
                            <span className="feed-bot-chip">
                              <span className="feed-bot-avatar">
                                {(run.name || run.skillKey || "S").slice(0, 1).toUpperCase()}
                              </span>
                              <span>{run.name || run.skillKey}</span>
                            </span>
                            <span className="text-sm muted">{run.status || "idle"}</span>
                          </div>
                          {run.summary ? (
                            <div className="text-sm muted">{run.summary}</div>
                          ) : null}
                          {typeof run.durationMs === "number" && run.durationMs > 0 ? (
                            <div className="text-sm muted">
                              Duration: {(run.durationMs / 1000).toFixed(run.durationMs >= 10_000 ? 0 : 1)}s
                            </div>
                          ) : null}
                          {run.error ? (
                            <div className="feed-comment-status">{run.error}</div>
                          ) : null}
                        </div>
                      ))}
                    </div>
                  ) : null}
                  {workflowBots.length ? (
                    <div className="stack" style={{ gap: "0.5rem" }}>
                      <div className="row-between" style={{ alignItems: "center" }}>
                        <span className="text-sm muted">Advanced: custom agents</span>
                        <button
                          type="button"
                          className="ghost text-sm"
                          onClick={openWorkflowTemplateForm}
                        >
                          Create
                        </button>
                      </div>
                      <div className="feed-workflow-bot-list">
                        {workflowBots.map((bot) => {
                          const saved = workflowSettingsByKey[bot.key];
                          const isBusy = workflowToggleBusyKey === bot.key;
                          const enableBlocked = saved?.enabled === false && saved?.supported === false;
                          return (
                            <div key={bot.key} className="feed-workflow-bot-row">
                              <button
                                type="button"
                                className="feed-workflow-bot-open"
                                onClick={() => openWorkflowSettingsForBot(bot.key)}
                              >
                                <span className="stack" style={{ gap: "0.2rem", width: "100%" }}>
                                  <span className="feed-bot-chip">
                                    <span className="feed-bot-avatar">{bot.avatar}</span>
                                    <span>{bot.name}</span>
                                  </span>
                                  {bot.goal ? (
                                    <span className="feed-bot-goal text-sm muted">{bot.goal}</span>
                                  ) : null}
                                </span>
                              </button>
                              <button
                                type="button"
                                className={saved?.enabled === false ? "ghost text-sm" : "primary text-sm"}
                                style={{ minWidth: "72px", borderRadius: "999px" }}
                                onClick={() => void toggleContentAgentEnabled(bot.key)}
                                disabled={isBusy || enableBlocked}
                                title={enableBlocked ? saved?.unsupportedReason : undefined}
                              >
                                {isBusy ? "..." : saved?.enabled === false ? "Off" : "On"}
                              </button>
                            </div>
                          );
                        })}
                      </div>
                    </div>
                  ) : (
                    <button
                      type="button"
                      className="primary text-sm"
                      style={{ width: "100%", borderRadius: "10px" }}
                      onClick={openWorkflowTemplateForm}
                    >
                      Create Custom Agent
                    </button>
                  )}
                </div>
              ) : null}

              {feedSource === "local" && feedCreateWorkflowOpen ? (
                <form className="workflow-settings-panel stack" onSubmit={submitWorkflowTemplateCreate}>
                  <div className="row-between">
                    <h3 style={{ margin: 0 }}>Create Content Agent</h3>
                    <button
                      type="button"
                      className="ghost text-sm"
                      onClick={() => setFeedCreateWorkflowOpen(false)}
                    >
                      Close
                    </button>
                  </div>
                  <label className="stack" style={{ gap: "0.35rem" }}>
                    <span className="text-sm">Agent name</span>
                    <input
                      type="text"
                      value={workflowTemplateDraft.name}
                      onChange={(e) =>
                        setWorkflowTemplateDraft((prev) => ({ ...prev, name: e.target.value }))
                      }
                      placeholder="Bluesky Scout"
                    />
                  </label>
                  <label className="stack" style={{ gap: "0.35rem" }}>
                    <span className="text-sm">What should this agent make?</span>
                    <textarea
                      rows={5}
                      value={workflowTemplateDraft.goal}
                      onChange={(e) =>
                        setWorkflowTemplateDraft((prev) => ({ ...prev, goal: e.target.value }))
                      }
                      placeholder="Create interesting Bluesky post drafts from my recent journal notes. Extract standout insights and save each post as a separate file so it appears in the workspace feed."
                    />
                  </label>
                  <div className="feed-agent-facts">
                    <div>
                      <span className="text-sm muted">Source</span>
                      <strong>Text journal notes and available audio/video transcripts</strong>
                    </div>
                    <div>
                      <span className="text-sm muted">Destination</span>
                      <strong>`posts/&lt;agent&gt;/` in Workspace Feed</strong>
                    </div>
                  </div>
                  {runtimeMediaSummary ? (
                    <p className="text-sm muted" style={{ margin: 0 }}>
                      {runtimeMediaSummary}
                    </p>
                  ) : null}
                  <label className="row" style={{ gap: "0.6rem", alignItems: "center" }}>
                    <input
                      type="checkbox"
                      checked={workflowTemplateDraft.runNow}
                      onChange={(e) =>
                        setWorkflowTemplateDraft((prev) => ({ ...prev, runNow: e.target.checked }))
                      }
                    />
                    <span className="text-sm">Run immediately after create</span>
                  </label>
                  <div className="feed-comment-actions">
                    <button
                      type="submit"
                      className="primary text-sm"
                      style={{ padding: "0.35rem 0.75rem", borderRadius: "8px" }}
                      disabled={workflowTemplateSubmitting}
                    >
                      {workflowTemplateSubmitting ? "Creating..." : "Create Agent"}
                    </button>
                    <button
                      type="button"
                      className="ghost text-sm"
                      style={{ padding: "0.35rem 0.75rem", borderRadius: "8px" }}
                      onClick={() => setFeedCreateWorkflowOpen(false)}
                      disabled={workflowTemplateSubmitting}
                    >
                      Cancel
                    </button>
                  </div>
                  {workflowTemplateStatus ? (
                    <div className="feed-comment-status">{workflowTemplateStatus}</div>
                  ) : null}
                </form>
              ) : null}

              {feedSource === "local" && feedEditStatus !== "Feed idle" ? (
                <p className="text-sm muted">{feedEditStatus}</p>
              ) : null}

              {feedSource === "local" ? (
                <div className="stack">
                  {workflowBots.map((bot) => {
                    const run = workflowRunStatusByKey[bot.key];
                    const saved = workflowSettingsByKey[bot.key];
                    if (!run) {
                      return null;
                    }
                    if (run.status === "done") {
                      return null;
                    }
                    return (
                      <div key={`run-${bot.key}`} className="workflow-run-card">
                        <div className="row-between" style={{ gap: "0.6rem", alignItems: "center" }}>
                          <div className="row" style={{ gap: "0.5rem", alignItems: "center" }}>
                            <span className="feed-bot-chip">
                              <span className="feed-bot-avatar">{bot.avatar}</span>
                              <span>{bot.name}</span>
                            </span>
                            {run.status === "pending" || run.status === "processing" ? (
                              <span className="workflow-run-spinner" aria-hidden />
                            ) : null}
                            <span className="text-sm">{run.summary}</span>
                          </div>
                          {run.status === "error" ? (
                            <button
                              type="button"
                              className="ghost text-sm"
                              onClick={() => void triggerManualWorkflowRun(bot.key)}
                              disabled={saved?.supported === false}
                              title={saved?.unsupportedReason}
                            >
                              Retry
                            </button>
                          ) : null}
                        </div>
                        {run.detail ? (
                          <pre className="workflow-run-detail">{run.detail}</pre>
                        ) : null}
                        <div className="text-sm muted">
                          Updated: {run.updatedAt ? formatTimestamp(run.updatedAt) : "just now"}
                        </div>
                      </div>
                    );
                  })}
                </div>
              ) : null}

              {feedSource === "local" && activeWorkflowBotKey
                ? (() => {
                  const bot = workflowBotByKey(activeWorkflowBotKey);
                  const saved = workflowSettingsByKey[activeWorkflowBotKey];
                  const draft =
                    workflowSettingsDraftByKey[activeWorkflowBotKey] ||
                    (saved ? workflowSettingsDraftFromItem(saved) : undefined);
                  const status = workflowSettingsStatusByKey[activeWorkflowBotKey] || "";
                  const isSaving = workflowSettingsSavingKey === activeWorkflowBotKey;
                  const unsupportedReason = saved?.unsupportedReason || "";

                  return (
                    <div className="workflow-settings-panel">
                      <div className="row-between">
                        <h3 style={{ margin: 0 }}>{bot.name}</h3>
                        <button
                          type="button"
                          className="ghost text-sm"
                          onClick={() => setActiveWorkflowBotKey("")}
                        >
                          Close
                        </button>
                      </div>

                      {!draft ? (
                        <p className="text-sm muted" style={{ marginTop: "0.6rem" }}>
                          {workflowSettingsLoading
                            ? "Loading content agent..."
                            : "Content agent details are not available yet."}
                        </p>
                      ) : (
                        <div className="stack" style={{ marginTop: "0.6rem" }}>
                          <label className="stack" style={{ gap: "0.35rem" }}>
                            <span className="text-sm">Agent goal</span>
                            <textarea
                              rows={5}
                              value={draft.goal}
                              onChange={(e) =>
                                setWorkflowSettingsDraftByKey((prev) => ({
                                  ...prev,
                                  [activeWorkflowBotKey]: {
                                    ...draft,
                                    goal: e.target.value
                                  }
                                }))
                              }
                              placeholder="Describe what this agent should create from your journal notes."
                            />
                          </label>
                          <div className="feed-agent-facts">
                            <div>
                              <span className="text-sm muted">Source</span>
                              <strong>Text journal notes and available transcripts</strong>
                            </div>
                            <div>
                              <span className="text-sm muted">Destination</span>
                              <strong>{saved?.outputPrefix || `posts/${activeWorkflowBotKey}/`}</strong>
                            </div>
                          </div>
                          {unsupportedReason ? (
                            <div className="feed-comment-status">{unsupportedReason}</div>
                          ) : null}

                          <div className="feed-comment-actions">
                            <button
                              type="button"
                              className="primary text-sm"
                              style={{ padding: "0.35rem 0.75rem", borderRadius: "8px" }}
                              onClick={() => void saveWorkflowSettings(activeWorkflowBotKey)}
                              disabled={isSaving}
                            >
                              {isSaving ? "Saving..." : "Save Goal & Run"}
                            </button>
                            <button
                              type="button"
                              className="ghost text-sm"
                              style={{ padding: "0.35rem 0.75rem", borderRadius: "8px" }}
                              onClick={() => void loadFeedWorkflowSettings()}
                              disabled={workflowSettingsLoading || isSaving}
                            >
                              Reload
                            </button>
                          </div>

                          {status ? <div className="feed-comment-status">{status}</div> : null}
                        </div>
                      )}
                    </div>
                  );
                })()
                : null}

              {feedSource === "bluesky" ? (
                blueskyFeedLoading ? (
                  <p className="text-center muted" style={{ padding: "2rem" }}>Loading world feed...</p>
                ) : blueskyFeedItems.length === 0 ? (
                  <div className="stack-sm" style={{ padding: "2rem" }}>
                    {blueskyFeedStatus ? (
                      <p className="text-center muted">{blueskyFeedStatus}</p>
                    ) : null}
                    <p className="text-center muted">
                      No world-feed items found yet. Add workspace posts or journals, seed more RSS sources, or connect Bluesky.
                    </p>
                  </div>
                ) : (
                  <div className="stack">
                    {blueskyFeedStatus ? (
                      <p className="text-sm muted" style={{ padding: "0 0.25rem" }}>{blueskyFeedStatus}</p>
                    ) : null}
                    {blueskyFeedSnapshot ? (
                      <div className="workflow-settings-panel stack" style={{ gap: "0.65rem" }}>
                        <div className="row-between" style={{ alignItems: "center", gap: "0.8rem" }}>
                          <h3 style={{ margin: 0 }}>World Feed Signals</h3>
                          <div className="row" style={{ gap: "0.6rem", alignItems: "center" }}>
                            <span className="text-sm muted">
                              {blueskyFeedItems.length} item{blueskyFeedItems.length === 1 ? "" : "s"}
                            </span>
                            <button
                              type="button"
                              className="ghost text-sm"
                              style={{ padding: "0.3rem 0.65rem", borderRadius: "8px" }}
                              onClick={() => void refreshWorldFeedDiagnostics()}
                              disabled={blueskyFeedLoading || worldFeedInterestsLoading}
                            >
                              Refresh diagnostics
                            </button>
                          </div>
                        </div>
                        <div className="feed-agent-facts">
                          <div>
                            <span className="text-sm muted">Mode</span>
                            <strong>{blueskyFeedSnapshot.usedFallback ? "Fallback" : "Ranked"}</strong>
                          </div>
                          <div>
                            <span className="text-sm muted">Refresh state</span>
                            <strong>
                              {blueskyFeedSnapshot.refreshStatus && blueskyFeedSnapshot.refreshStatus !== "idle"
                                ? blueskyFeedSnapshot.refreshStatus
                                : blueskyFeedSnapshot.refreshState || "warming"}
                            </strong>
                          </div>
                          <div>
                            <span className="text-sm muted">Interests</span>
                            <strong>{blueskyProfileStats.interestCount}</strong>
                          </div>
                          <div>
                            <span className="text-sm muted">Shortlisted sources</span>
                            <strong>{blueskyFeedSnapshot.selectedSources.length}</strong>
                          </div>
                        </div>
                        <div className="stack" style={{ gap: "0.45rem" }}>
                          <span className="text-sm muted">Discovery and matching</span>
                          <div className="feed-agent-facts">
                            <div>
                              <span className="text-sm muted">RSS shortlisted</span>
                              <strong>{blueskyFeedSnapshot.diagnostics.rss.shortlistedCount}</strong>
                            </div>
                            <div>
                              <span className="text-sm muted">Nostr relays checked</span>
                              <strong>{blueskyFeedSnapshot.diagnostics.nostr.scannedCount}</strong>
                            </div>
                            <div>
                              <span className="text-sm muted">Bluesky algos checked</span>
                              <strong>{blueskyFeedSnapshot.diagnostics.bluesky.scannedCount}</strong>
                            </div>
                            <div>
                              <span className="text-sm muted">Candidates before ranking</span>
                              <strong>{blueskyFeedSnapshot.diagnostics.ranking.candidateCountBeforeRanking}</strong>
                            </div>
                          </div>
                          <div className="feed-agent-facts">
                            <div>
                              <span className="text-sm muted">RSS posts matched</span>
                              <strong>{blueskyFeedSnapshot.diagnostics.rss.candidateCount}</strong>
                            </div>
                            <div>
                              <span className="text-sm muted">Nostr metadata fetched</span>
                              <strong>{blueskyFeedSnapshot.diagnostics.nostr.metadataFetchedCount}</strong>
                            </div>
                            <div>
                              <span className="text-sm muted">Bluesky posts matched</span>
                              <strong>{blueskyFeedSnapshot.diagnostics.bluesky.candidateCount}</strong>
                            </div>
                            <div>
                              <span className="text-sm muted">Final ranked items</span>
                              <strong>{blueskyFeedSnapshot.diagnostics.ranking.rankedItemCount}</strong>
                            </div>
                          </div>
                          {([
                            {
                              key: "rss" as const,
                              label: "RSS sample",
                              data: blueskyFeedSnapshot.diagnostics.rss,
                              empty: "No RSS source sample yet."
                            },
                            {
                              key: "nostr" as const,
                              label: "Nostr relay sample",
                              data: blueskyFeedSnapshot.diagnostics.nostr,
                              empty: "No Nostr relay sample yet."
                            },
                            {
                              key: "bluesky" as const,
                              label: "Bluesky feed sample",
                              data: blueskyFeedSnapshot.diagnostics.bluesky,
                              empty: "No Bluesky feed sample yet. This usually means auth is missing or discovery has not completed."
                            }
                          ]).map((protocol) => {
                            const samples = protocol.data.sampledSources || [];
                            const sample =
                              samples.length > 0
                                ? samples[worldFeedSampleIndexByProtocol[protocol.key] % samples.length]
                                : null;
                            return (
                              <div key={protocol.key} className="workflow-run-card">
                                <div className="row-between" style={{ gap: "0.6rem", alignItems: "center" }}>
                                  <span className="text-sm muted">{protocol.label}</span>
                                  <div className="row" style={{ gap: "0.45rem", alignItems: "center" }}>
                                    <span className="text-sm muted">
                                      shortlisted {protocol.data.shortlistedCount}
                                    </span>
                                    <button
                                      type="button"
                                      className="ghost text-sm"
                                      style={{ padding: "0.25rem 0.55rem", borderRadius: "8px" }}
                                      onClick={() => chooseNextWorldFeedSample(protocol.key, samples.length)}
                                      disabled={samples.length <= 1}
                                    >
                                      Next sample
                                    </button>
                                  </div>
                                </div>
                                {sample ? (
                                  <div className="stack-sm">
                                    <div className="row-between" style={{ gap: "0.6rem", alignItems: "center" }}>
                                      <span className="feed-bot-chip">
                                        <span className="feed-bot-avatar">
                                          {(sample.protocol || "?").slice(0, 1).toUpperCase()}
                                        </span>
                                        <span>{sample.label}</span>
                                      </span>
                                      <span className="text-sm muted">
                                        {(sample.score * 100).toFixed(0)}%
                                      </span>
                                    </div>
                                    <div className="text-sm muted">
                                      {sample.metadata?.uri
                                        ? `uri ${sample.metadata.uri}`
                                        : sample.metadata?.relayUrl
                                          ? `relay ${sample.metadata.relayUrl}`
                                          : sample.metadata?.domain
                                            ? `domain ${sample.metadata.domain}`
                                            : "No metadata captured yet."}
                                    </div>
                                    {sample.description ? (
                                      <div className="text-sm muted">{sample.description}</div>
                                    ) : null}
                                  </div>
                                ) : (
                                  <p className="text-sm muted" style={{ margin: 0 }}>
                                    {protocol.empty}
                                  </p>
                                )}
                                {protocol.data.error ? (
                                  <div className="feed-comment-status">
                                    Error: {protocol.data.error}
                                  </div>
                                ) : null}
                              </div>
                            );
                          })}
                        </div>
                        {blueskyFeedSnapshot.usedFallback ? (
                          <div className="feed-comment-status">
                            Current items are fallback/recent content, not the final ranked world-feed snapshot.
                          </div>
                        ) : null}
                        {blueskyFeedSnapshot.lastError ? (
                          <div className="feed-comment-status">
                            Last refresh error: {blueskyFeedSnapshot.lastError}
                          </div>
                        ) : null}
                        {blueskyFeedSnapshot.selectedSources.length ? (
                          <div className="stack" style={{ gap: "0.45rem" }}>
                            <span className="text-sm muted">Top shortlisted sources</span>
                            {blueskyFeedSnapshot.selectedSources.slice(0, 6).map((source) => (
                              <div key={source.key} className="workflow-run-card">
                                <div className="row-between" style={{ gap: "0.6rem", alignItems: "center" }}>
                                  <span className="feed-bot-chip">
                                    <span className="feed-bot-avatar">
                                      {(source.protocol || "?").slice(0, 1).toUpperCase()}
                                    </span>
                                    <span>{source.label}</span>
                                  </span>
                                  <span className="text-sm muted">
                                    {(source.score * 100).toFixed(0)}%
                                  </span>
                                </div>
                                <div className="text-sm muted">
                                  {(source.protocol || "source").toUpperCase()}
                                  {source.matchedInterestLabel
                                    ? ` · keyword "${source.matchedInterestLabel}"${
                                        source.matchedInterestScore != null
                                          ? ` (${(source.matchedInterestScore * 100).toFixed(0)}%)`
                                          : ""
                                      }`
                                    : ""}
                                </div>
                                {source.description ? (
                                  <div className="text-sm muted">{source.description}</div>
                                ) : null}
                              </div>
                            ))}
                          </div>
                        ) : (
                          <p className="text-sm muted" style={{ margin: 0 }}>
                            No source shortlist is available yet for this refresh cycle.
                          </p>
                        )}
                        <div className="stack" style={{ gap: "0.45rem" }}>
                          <div className="row-between" style={{ gap: "0.75rem", alignItems: "center" }}>
                            <span className="text-sm muted">Interest vectors</span>
                            <span className="text-sm muted">
                              {worldFeedInterests.length} total
                            </span>
                          </div>
                          <p className="text-sm muted" style={{ margin: 0 }}>
                            Diagnostic approach: adding one broad synthetic interest is reasonable for testing relay/feed discovery.
                            It is useful in development as long as synthetic vectors are clearly marked and removable.
                          </p>
                          <form
                            className="row"
                            style={{ gap: "0.5rem", alignItems: "stretch", flexWrap: "wrap" }}
                            onSubmit={(event) => void createDiagnosticWorldFeedInterest(event)}
                          >
                            <input
                              value={worldFeedDummyLabel}
                              onChange={(event) => setWorldFeedDummyLabel(event.target.value)}
                              placeholder="Diagnostic interest label"
                              style={{ flex: 1, minWidth: "18rem" }}
                            />
                            <button
                              type="submit"
                              className="secondary"
                              disabled={worldFeedInterestsLoading || !worldFeedDummyLabel.trim()}
                            >
                              Add dummy interest
                            </button>
                          </form>
                          {worldFeedInterestStatus ? (
                            <div className="feed-comment-status">{worldFeedInterestStatus}</div>
                          ) : null}
                          {worldFeedInterestsLoading ? (
                            <p className="text-sm muted" style={{ margin: 0 }}>
                              Loading interest vectors...
                            </p>
                          ) : worldFeedInterests.length ? (
                            worldFeedInterests.map((interest) => (
                              <div key={interest.id} className="workflow-run-card">
                                <div className="row-between" style={{ gap: "0.6rem", alignItems: "center" }}>
                                  <span className="feed-bot-chip">
                                    <span className="feed-bot-avatar">
                                      {interest.synthetic ? "D" : "I"}
                                    </span>
                                    <span>{interest.label}</span>
                                  </span>
                                  <span className="text-sm muted">
                                    health {(interest.healthScore * 100).toFixed(0)}%
                                  </span>
                                </div>
                                <div className="text-sm muted">
                                  {interest.synthetic ? "Diagnostic synthetic vector" : "Workspace-derived vector"}
                                  {` · ${interest.embeddingDimensions} dims`}
                                </div>
                                <div className="text-sm muted">
                                  source {interest.sourcePath}
                                </div>
                                <div className="text-sm muted">
                                  updated {formatTimestamp(interest.updatedAt)}
                                  {interest.lastSeenAt ? ` · seen ${formatTimestamp(interest.lastSeenAt)}` : ""}
                                </div>
                                <div className="stack-sm" style={{ gap: "0.3rem" }}>
                                  <div className="row-between" style={{ alignItems: "center" }}>
                                    <span className="text-sm muted">
                                      Keywords{interest.keywordsOverride ? " (custom)" : " (auto)"}
                                    </span>
                                    {editingInterestId !== interest.id ? (
                                      <button
                                        type="button"
                                        className="ghost text-sm"
                                        style={{ padding: "0.2rem 0.5rem", borderRadius: "6px" }}
                                        onClick={() => {
                                          setEditingInterestId(interest.id);
                                          setEditingInterestKeywords(interest.keywords.join(", "));
                                        }}
                                      >
                                        Edit
                                      </button>
                                    ) : null}
                                  </div>
                                  {editingInterestId === interest.id ? (
                                    <div className="stack-sm" style={{ gap: "0.3rem" }}>
                                      <input
                                        value={editingInterestKeywords}
                                        onChange={(e) => setEditingInterestKeywords(e.target.value)}
                                        placeholder="keyword1, keyword2, keyword3"
                                        style={{ fontSize: "0.85rem" }}
                                      />
                                      <div className="row" style={{ gap: "0.4rem", justifyContent: "flex-end" }}>
                                        {interest.keywordsOverride ? (
                                          <button
                                            type="button"
                                            className="ghost text-sm"
                                            style={{ padding: "0.2rem 0.5rem" }}
                                            onClick={() => void clearInterestKeywordsOverride(interest.id)}
                                          >
                                            Reset to auto
                                          </button>
                                        ) : null}
                                        <button
                                          type="button"
                                          className="ghost text-sm"
                                          style={{ padding: "0.2rem 0.5rem" }}
                                          onClick={() => {
                                            setEditingInterestId(null);
                                            setEditingInterestKeywords("");
                                          }}
                                        >
                                          Cancel
                                        </button>
                                        <button
                                          type="button"
                                          className="secondary text-sm"
                                          style={{ padding: "0.2rem 0.5rem" }}
                                          onClick={() => void saveInterestKeywords(interest.id)}
                                        >
                                          Save
                                        </button>
                                      </div>
                                    </div>
                                  ) : (
                                    <div className="row" style={{ gap: "0.3rem", flexWrap: "wrap" }}>
                                      {interest.keywords.length > 0 ? (
                                        interest.keywords.map((kw) => (
                                          <span
                                            key={kw}
                                            className="text-sm"
                                            style={{
                                              background: "var(--color-surface-hover, #2a2a2a)",
                                              padding: "0.15rem 0.45rem",
                                              borderRadius: "4px",
                                              fontSize: "0.78rem",
                                            }}
                                          >
                                            {kw}
                                          </span>
                                        ))
                                      ) : (
                                        <span className="text-sm muted">No keywords derived yet.</span>
                                      )}
                                    </div>
                                  )}
                                </div>
                                <div className="row" style={{ justifyContent: "flex-end", gap: "0.4rem" }}>
                                  <button
                                    type="button"
                                    className="secondary danger text-sm"
                                    style={{ padding: "0.25rem 0.55rem" }}
                                    onClick={() => void removeWorldFeedInterest(interest)}
                                  >
                                    {interest.synthetic ? "Delete" : "Remove"}
                                  </button>
                                </div>
                              </div>
                            ))
                          ) : (
                            <p className="text-sm muted" style={{ margin: 0 }}>
                              No interest vectors exist yet.
                            </p>
                          )}
                        </div>
                      </div>
                    ) : null}
                    <div className="feed-section-tabs world-feed-tabs">
                      <button
                        type="button"
                        className={`feed-section-tab ${worldFeedTab === "tweets" ? "active" : ""}`}
                        onClick={() => setWorldFeedTab("tweets")}
                      >
                        Tweets
                        <span className="feed-section-tab-count">{worldTweetItems.length}</span>
                      </button>
                      <button
                        type="button"
                        className={`feed-section-tab ${worldFeedTab === "articles" ? "active" : ""}`}
                        onClick={() => setWorldFeedTab("articles")}
                      >
                        Articles
                        <span className="feed-section-tab-count">{worldArticleItems.length}</span>
                      </button>
                      <button
                        type="button"
                        className={`feed-section-tab ${worldFeedTab === "videos" ? "active" : ""}`}
                        onClick={() => {
                          setWorldFeedTab("videos");
                          void fetchVideoFallback();
                        }}
                      >
                        Videos
                        <span className="feed-section-tab-count">{worldVideoItems.length}</span>
                      </button>
                    </div>
                    {worldFeedNewPostsBanner}
                    {renderWorldFeedItems()}
                  </div>
                )
              ) : (
                <div className="stack">
                  {/* Me feed profile header */}
                  <div className="me-profile-header">
                    {session ? (
                      <div className="me-profile-avatar-placeholder">{session.handle.charAt(0).toUpperCase()}</div>
                    ) : (
                      <div className="me-profile-avatar-placeholder">?</div>
                    )}
                    <div className="me-profile-info">
                      <div className="me-profile-name">{session?.handle || "Your Profile"}</div>
                      {session ? <div className="me-profile-handle">@{session.handle}</div> : null}
                      <div className="me-profile-stats">
                        <span><strong>{feedItems.length}</strong> draft{feedItems.length === 1 ? "" : "s"}</span>
                        <span><strong>{postedHistory.length}</strong> published</span>
                      </div>
                    </div>
                  </div>

                  {/* Me feed sub-tabs */}
                  <div className="feed-section-tabs me-feed-tabs">
                    <button
                      type="button"
                      className={`feed-section-tab ${meFeedTab === "drafts" ? "active" : ""}`}
                      onClick={() => setMeFeedTab("drafts")}
                    >
                      Drafts
                      <span className="feed-section-tab-count">{feedItems.length}</span>
                    </button>
                    <button
                      type="button"
                      className={`feed-section-tab ${meFeedTab === "published" ? "active" : ""}`}
                      onClick={() => setMeFeedTab("published")}
                    >
                      Published
                      <span className="feed-section-tab-count">{postedHistory.length}</span>
                    </button>
                  </div>

                  {meFeedTab === "published" ? (
                    postedHistory.length === 0 ? (
                      <p className="text-center muted" style={{ padding: "1.5rem" }}>No published posts yet.</p>
                    ) : (
                      <div className="stack">
                        {postedHistory.slice(0, 40).map((item, idx) => (
                          <div key={`${item.uri || item.created}-${idx}`} className="feed-item">
                            <div className="feed-header">
                              <div className="feed-title">
                                {item.videoName || "Text post"}
                                {item.status === "error" ? <span style={{ color: "var(--error)", marginLeft: "0.4rem" }}>(failed)</span> : null}
                              </div>
                              <div className="feed-time">{formatTimestamp(item.created)}</div>
                            </div>
                            {item.text ? (
                              <div className="feed-body" style={{ maxHeight: "6rem", overflow: "hidden" }}>
                                {item.text.slice(0, 300)}{item.text.length > 300 ? "..." : ""}
                              </div>
                            ) : null}
                            <div className="feed-actions">
                              {item.uri ? (
                                <a
                                  href={`https://bsky.app/profile/${session?.handle || ""}/post/${item.uri.split("/").pop()}`}
                                  target="_blank"
                                  rel="noreferrer"
                                  className="ghost text-sm"
                                  style={{ padding: "0.35rem 0.75rem", borderRadius: "8px", textDecoration: "none" }}
                                >
                                  View on Bluesky
                                </a>
                              ) : null}
                              {item.error ? (
                                <span className="text-sm" style={{ color: "var(--error)" }}>{item.error}</span>
                              ) : null}
                            </div>
                          </div>
                        ))}
                      </div>
                    )
                  ) : feedItems.length === 0 ? (
                    <p className="text-center muted" style={{ padding: "1.5rem" }}>No draft items in your workspace feed yet.</p>
                  ) : feedItems.map(item => {
                    const workflowBot = workflowBotForPath(item.path, feedAttributedBots);
                    const isCommentOpen = activeFeedCommentPath === item.path;
                    const commentDraft = feedCommentDrafts[item.path] || "";
                    const commentStatus = feedCommentStatusByPath[item.path] || "";
                    const isCommentSubmitting = submittingFeedCommentPath === item.path;
                    const isDraftLoading = !!feedDraftLoadingByPath[item.path];
                    const inlineDraft = feedDraftsByPath[item.path];
                    const inlineText = inlineDraft ?? item.previewText ?? item.title;
                    const canEditInline = item.kind === "text" || item.kind === "audio" || item.kind === "video";
                    return (
                      <div key={item.path} className="feed-item feed-item-card">
                        <div className="feed-header">
                          <div className="feed-title stack-sm">
                            {workflowBot && (
                              <button
                                type="button"
                                className="feed-bot-chip"
                                onClick={() => {
                                  openFeedBotSettings(workflowBot);
                                }}
                                title={`Open ${workflowBot.name} settings`}
                              >
                                <span className="feed-bot-avatar">{workflowBot.avatar}</span>
                                <span>{workflowBot.name}</span>
                              </button>
                            )}
                            <span>{item.title}</span>
                          </div>
                          <div className="feed-time">{formatTimestamp(item.modifiedAt)}</div>
                        </div>
                        {canEditInline ? (
                          <textarea
                            rows={1}
                            className="feed-inline-editor"
                            value={inlineText}
                            ref={(node) => {
                              if (!node) {
                                return;
                              }
                              node.style.height = "0px";
                              node.style.height = `${node.scrollHeight}px`;
                            }}
                            onChange={(e) => {
                              e.target.style.height = "0px";
                              e.target.style.height = `${e.target.scrollHeight}px`;
                              updateFeedDraft(item, e.target.value);
                            }}
                            placeholder={isDraftLoading ? "Loading post..." : "Write your post"}
                            disabled={isDraftLoading}
                          />
                        ) : (
                          <div className="feed-body">
                            {item.previewText ? item.previewText : <span className="muted">[{item.kind.toUpperCase()} File attached]</span>}
                          </div>
                        )}
                        <div className="feed-actions">
                          {(item.kind === "text" || item.kind === "video") && (
                            <button
                              type="button"
                              className="primary text-sm"
                              style={{ padding: '0.4rem 0.8rem', borderRadius: '8px' }}
                              onClick={() => void postFeedItemToBluesky(item)}
                              disabled={postingFeedPath === item.path || !!isPathPosted(item.path)}
                            >
                              {isPathPosted(item.path)
                                ? "Posted"
                                : postingFeedPath === item.path
                                  ? "Posting..."
                                  : "Like & Post"}
                            </button>
                          )}
                          {workflowBot && (
                            <button
                              type="button"
                              className="ghost text-sm"
                              style={{ padding: '0.4rem 0.8rem', borderRadius: '8px' }}
                              onClick={() => toggleFeedCommentComposer(item.path)}
                            >
                              {isCommentOpen ? "Hide Comment" : "Comment"}
                            </button>
                          )}
                          <button
                            type="button"
                            className="ghost text-sm"
                            style={{ padding: '0.4rem 0.8rem', borderRadius: '8px', color: 'var(--error)' }}
                            onClick={() => setPendingDeleteFeedItem(item)}
                          >
                            Delete
                          </button>
                        </div>

                        <div className={`feed-comment-panel ${isCommentOpen ? "open" : ""}`}>
                          {isCommentOpen && (
                            <>
                              <textarea
                                rows={3}
                                className="feed-comment-input"
                                placeholder={`Comment to modify ${workflowBot?.name || "workflow"}...`}
                                value={commentDraft}
                                onChange={(e) =>
                                  setFeedCommentDrafts((prev) => ({
                                    ...prev,
                                    [item.path]: e.target.value
                                  }))
                                }
                              />
                              <div className="feed-comment-actions">
                                <button
                                  type="button"
                                  className="primary text-sm"
                                  style={{ padding: '0.35rem 0.75rem', borderRadius: '8px' }}
                                  onClick={() => void submitWorkflowCommentForFeedItem(item)}
                                  disabled={isCommentSubmitting}
                                >
                                  {isCommentSubmitting ? "Sending..." : "Send Comment"}
                                </button>
                                <button
                                  type="button"
                                  className="ghost text-sm"
                                  style={{ padding: '0.35rem 0.75rem', borderRadius: '8px' }}
                                  onClick={() => setActiveFeedCommentPath("")}
                                  disabled={isCommentSubmitting}
                                >
                                  Cancel
                                </button>
                              </div>
                            </>
                          )}
                          {commentStatus ? <div className="feed-comment-status">{commentStatus}</div> : null}
                        </div>

                        {postProgress?.path === item.path && (
                          <div className="post-progress-wrap">
                            <div className="post-progress-text">{postProgress.label}</div>
                            <div className="post-progress-track">
                              <div
                                className="post-progress-fill"
                                style={{ width: `${Math.max(0, Math.min(100, postProgress.percent))}%` }}
                              />
                            </div>
                          </div>
                        )}
                      </div>
                    );
                  })}
                </div>
              )}
              </div>
            </div>
          </ViewErrorBoundary>
        ) : null}

        {mobileTab === "productivity" ? (
          <ViewErrorBoundary title="Productivity">
            <ProductivityView
              openTodos={openTodos}
              doneTodos={doneTodos}
              overdueTodoCount={overdueTodoCount}
              todayEventItems={todayEventItems}
              upcomingEventItems={upcomingEventItems}
              pastEventItems={pastEventItems}
              workspaceSynthStatus={workspaceSynthStatus}
              workspaceSynthArtifactBadges={workspaceSynthArtifactBadges}
              formatTodoDueLabel={formatTodoDueLabel}
              formatEventTiming={formatEventTiming}
              formatTimestamp={formatTimestamp}
              onToggleTodo={(item) => void toggleWorkspaceTodo(item)}
            />
          </ViewErrorBoundary>
        ) : null}

        {mobileTab === "profile" ? (
          <ViewErrorBoundary title="Profile">
            <div className="stack">
              <div className="card">
              <div className="row-between">
                <h2>Configuration</h2>
                <button
                  type="button"
                  className="ghost"
                  onClick={() => void loadRuntimeConfigForSettings()}
                  disabled={settingsConfigBusy}
                >
                  Refresh
                </button>
              </div>
              <div className="stack">
                <input
                  value={settingsProvider}
                  onChange={(e) => setSettingsProvider(e.target.value)}
                  placeholder="Default provider (e.g. openrouter, ollama, openai)"
                  disabled={settingsConfigBusy}
                />
                <input
                  value={settingsModel}
                  onChange={(e) => setSettingsModel(e.target.value)}
                  placeholder="Default model"
                  disabled={settingsConfigBusy}
                />
                <label className="row" style={{ gap: "0.6rem", alignItems: "center" }}>
                  <input
                    type="checkbox"
                    checked={settingsTranscriptionEnabled}
                    onChange={(e) => setSettingsTranscriptionEnabled(e.target.checked)}
                    disabled={settingsConfigBusy}
                  />
                  <span className="text-sm">Enable transcription</span>
                </label>
                <label className="stack" style={{ gap: "0.4rem" }}>
                  <span className="text-sm">Transcription model</span>
                  {settingsAvailableTranscriptionModels.length === 0 ? (
                    <p className="text-sm muted">
                      No local transcription models detected yet.
                    </p>
                  ) : null}
                  <select
                    value={settingsTranscriptionModel}
                    onChange={(e) => setSettingsTranscriptionModel(e.target.value)}
                    disabled={
                      settingsConfigBusy ||
                      settingsAvailableTranscriptionModels.length === 0
                    }
                  >
                    {settingsAvailableTranscriptionModels.map((modelName) => (
                      <option key={modelName} value={modelName}>
                        {modelName}
                      </option>
                    ))}
                  </select>
                  <p className="text-sm muted">
                    Only locally available models are listed to avoid downloads.
                  </p>
                </label>
                <button
                  type="button"
                  className="primary"
                  onClick={() => void saveRuntimeConfigFromSettings()}
                  disabled={settingsConfigBusy}
                >
                  {settingsConfigBusy ? "Saving..." : "Save Configuration"}
                </button>
                {settingsConfigStatus ? (
                  <p className="text-sm muted">{settingsConfigStatus}</p>
                ) : null}
                {runtimeMediaSummary ? (
                  <p className="text-sm muted">{runtimeMediaSummary}</p>
                ) : null}
              </div>
            </div>

            <div className="card">
              <h2>Bluesky Login</h2>
              <form className="stack" onSubmit={handleLogin}>
                <p className="text-sm muted">Service: {creds.serviceUrl || "https://bsky.social"}</p>
                <input
                  value={creds.handle}
                  onChange={(e) => setCreds(prev => ({ ...prev, handle: e.target.value }))}
                  placeholder="Bluesky Handle or Email"
                />
                <input
                  type="password"
                  value={creds.appPassword}
                  onChange={(e) => setCreds(prev => ({ ...prev, appPassword: e.target.value }))}
                  placeholder="Bluesky App Password"
                />
                <div className="row">
                  <button type="submit" className="primary" style={{ flex: 1 }}>Sign In</button>
                  <button
                    type="button"
                    className="danger"
                    onClick={async () => {
                      await deleteCredentialsSecure();
                      setCreds({ serviceUrl: "https://bsky.social", handle: "", appPassword: "" });
                      setSession(null);
                      setAgent(null);
                      setAuthMessage("Credentials cleared");
                    }}
                  >
                    Clear
                  </button>
                </div>
                {authMessage && <p className="text-sm text-center muted mt-2">{authMessage}</p>}
                {session && <div className="badge success text-center" style={{ alignSelf: 'center' }}>Signed in as @{session.handle}</div>}
              </form>
            </div>

              {isDesktopClient && (
                <>
                  <div className="card">
                  <h2>Local Runtime & Pairing</h2>
                  <div className="stack">
                    <p className="text-sm muted">
                      This app uses its embedded local gateway automatically. Pairing is used for device sync.
                    </p>

                    <p className="text-sm muted">
                      {chatGatewayToken
                        ? "Local runtime is ready."
                        : "Waiting for local runtime bootstrap."}
                    </p>

                    <div className="stack" style={{ gap: "0.8rem" }}>
                      <div className="row-between">
                        <p><strong>Generate Sync QR</strong></p>
                        <button
                          type="button"
                          onClick={() => void generateDesktopPairingQr()}
                          disabled={desktopQrLoading}
                        >
                          {desktopQrLoading ? "Generating..." : "Generate QR"}
                        </button>
                      </div>
                      {desktopQrPayload && (
                        <div className="stack" style={{ alignItems: "center", gap: "0.6rem" }}>
                          <Suspense fallback={<div className="text-sm muted text-center" style={{ width: 220, height: 220, display: "flex", alignItems: "center", justifyContent: "center" }}>Loading...</div>}>
                            <QRCodeCanvas value={desktopQrPayload.qr_value} size={220} includeMargin />
                          </Suspense>
                          <p className="text-sm muted text-center">
                            Sync peer gateway: {desktopQrPayload.gateway_url}
                          </p>
                        </div>
                      )}
                      {desktopQrStatus ? <p className="text-sm muted">{desktopQrStatus}</p> : null}
                    </div>
                  </div>
                </div>

                  <div className="card">
                  <h2>Sync Peer</h2>
                  <div className="stack">
                    <p className="text-sm muted">
                      Optional remote peer used only for workspace sync. Local journal, feed, and content-agent runtime stay local.
                    </p>
                    <input
                      value={syncPeerGatewayUrl}
                      onChange={(e) => setSyncPeerGatewayUrl(e.target.value)}
                      placeholder="Peer gateway URL"
                    />
                    <input
                      type="password"
                      value={syncPeerToken}
                      onChange={(e) => setSyncPeerToken(e.target.value)}
                      placeholder="Peer sync token"
                    />
                    <div className="row">
                      <button type="button" className="primary" onClick={() => void syncWithPeerNow()} disabled={syncBusy}>
                        {syncBusy ? "Syncing..." : "Sync Now"}
                      </button>
                      {isTauriMobileRuntime() ? (
                        <button
                          type="button"
                          className="ghost"
                          onClick={() => {
                            setSyncScannerActive(true);
                            setMobileScannerActive(true);
                            setSyncStatus("Scanning sync QR...");
                          }}
                          disabled={syncScannerActive}
                        >
                          {syncScannerActive ? "Scanner Active" : "Scan Sync QR"}
                        </button>
                      ) : null}
                      <button type="button" className="ghost" onClick={() => void clearSyncPeerConnection()}>
                        Clear Peer
                      </button>
                    </div>
                    {syncScannerActive ? (
                      <video
                        ref={mobileScannerVideoRef}
                        style={{
                          width: "100%",
                          maxWidth: "360px",
                          borderRadius: "14px",
                          background: "#000",
                          minHeight: "240px"
                        }}
                        playsInline
                        muted
                      />
                    ) : null}
                    {syncStatus ? <p className="text-sm muted">{syncStatus}</p> : null}
                  </div>
                </div>

                  <div className="card">
                  <h2>Free AI (OpenRouter)</h2>
                  <div className="stack">
                    <p className="text-sm muted">
                      Connect via OpenRouter for free AI. No credit card needed.
                      Uses Gemini 2.5 Flash (free) — plenty for daily journal processing.
                    </p>
                    <div className="stack" style={{ gap: "0.5rem" }}>
                      <p className="text-sm"><strong>Option 1: Auto-connect</strong></p>
                      <button
                        type="button"
                        className="primary"
                        onClick={() => void handleOpenRouterOAuth()}
                        disabled={openrouterOAuthBusy}
                        style={{ alignSelf: "flex-start" }}
                      >
                        {openrouterOAuthBusy ? "Connecting..." : "Login with OpenRouter"}
                      </button>
                    </div>
                    <div className="stack" style={{ gap: "0.4rem" }}>
                      <p className="text-sm"><strong>Option 2: Paste API key</strong></p>
                      <p className="text-sm muted">
                        Go to{" "}
                        <span
                          style={{ textDecoration: "underline", cursor: "pointer" }}
                          onClick={() => void openExternalUrlInBrowser("https://openrouter.ai/settings/keys")}
                        >
                          openrouter.ai/settings/keys
                        </span>
                        {" "}to create a free account and API key, then paste it here.
                      </p>
                      <input
                        type="password"
                        value={openrouterApiKeyInput}
                        onChange={(e) => setOpenrouterApiKeyInput(e.target.value)}
                        placeholder="sk-or-..."
                        disabled={openrouterOAuthBusy}
                      />
                      <button
                        type="button"
                        className="ghost"
                        onClick={() => void saveOpenRouterApiKey()}
                        disabled={openrouterOAuthBusy || !openrouterApiKeyInput.trim()}
                      >
                        Save API Key
                      </button>
                    </div>
                    {openrouterOAuthStatus ? (
                      <p
                        className="text-sm"
                        style={{
                          color: openrouterOAuthStatus.includes("ready") || openrouterOAuthStatus.includes("connected")
                            ? "var(--success)"
                            : openrouterOAuthStatus.includes("Failed") || openrouterOAuthStatus.includes("failed") || openrouterOAuthStatus.includes("timed out")
                              ? "var(--danger)"
                              : undefined
                        }}
                      >
                        {openrouterOAuthStatus}
                      </p>
                    ) : null}
                  </div>
                </div>

                  <div className="card">
                  <div className="row-between">
                    <h2>AI Setup</h2>
                    <button
                      type="button"
                      onClick={() => void startOpenAiDeviceCodeLogin()}
                      disabled={aiSetupBusy || !!aiSetupStatus?.running}
                    >
                      {aiSetupBusy
                        ? "Starting..."
                        : aiSetupStatus?.running
                          ? "In Progress..."
                          : "Start OpenAI Device Login"}
                    </button>
                  </div>
                  <div className="stack">
                    <p className="text-sm muted">
                      Starts `slowclaw auth login --provider openai-codex --device-code` and waits for completion.
                    </p>
                    <div className="stack" style={{ gap: "0.4rem" }}>
                      <p className="text-sm"><strong>Provider API Key (Optional)</strong></p>
                      <input
                        type="password"
                        value={providerApiKey}
                        onChange={(e) => setProviderApiKey(e.target.value)}
                        placeholder="Optional: set ZEROCLAW_API_KEY for daemon"
                      />
                      <button
                        type="button"
                        className="ghost"
                        onClick={() => void saveOptionalProviderApiKey()}
                      >
                        Save API Key
                      </button>
                      {providerApiKeyStatus ? (
                        <p className="text-sm muted">{providerApiKeyStatus}</p>
                      ) : null}
                    </div>
                    <div className="badge text-center" style={{ alignSelf: "flex-start" }}>
                      State: {aiSetupStatus?.state || "idle"}
                    </div>
                    <p className="text-sm">{aiSetupStatus?.message || "Not started."}</p>
                    {preferredOpenAiAuthUrl(aiSetupStatus) ? (
                      <div
                        className="stack"
                        style={{
                          gap: "0.5rem",
                          padding: "0.85rem",
                          borderRadius: "14px",
                          border: "1px solid var(--line)",
                          background: "var(--surface-2)"
                        }}
                      >
                        <p className="text-sm">
                          <strong>
                            {aiSetupStatus?.fastLink ? "OpenAI login link" : "OpenAI verification page"}
                          </strong>
                        </p>
                        <div className="row" style={{ gap: "0.5rem", flexWrap: "wrap" }}>
                          <button
                            type="button"
                            className="primary"
                            onClick={() => void openExternalUrlInBrowser(preferredOpenAiAuthUrl(aiSetupStatus))}
                          >
                            Open in Browser
                          </button>
                          <button
                            type="button"
                            className="ghost"
                            onClick={() => void copyTextToClipboard(
                              preferredOpenAiAuthUrl(aiSetupStatus),
                              "Copied the login link."
                            )}
                          >
                            Copy Link
                          </button>
                        </div>
                        <div
                          className="text-sm"
                          style={{
                            fontFamily: "ui-monospace, SFMono-Regular, Menlo, monospace",
                            overflowWrap: "anywhere",
                            wordBreak: "break-word"
                          }}
                        >
                          {preferredOpenAiAuthUrl(aiSetupStatus)}
                        </div>
                        {aiSetupStatus?.fastLink && aiSetupStatus?.verificationUrl ? (
                          <div className="text-sm muted" style={{ overflowWrap: "anywhere", wordBreak: "break-word" }}>
                            Verification page fallback: {aiSetupStatus.verificationUrl}
                          </div>
                        ) : null}
                      </div>
                    ) : null}
                    {aiSetupStatus?.userCode ? (
                      <div className="row" style={{ alignItems: "center" }}>
                        <input value={aiSetupStatus.userCode} readOnly style={{ flex: 1 }} />
                        <button
                          type="button"
                          className="ghost"
                          onClick={() => void copyTextToClipboard(
                            aiSetupStatus.userCode || "",
                            "Copied the OpenAI device code."
                          )}
                        >
                          Copy Code
                        </button>
                      </div>
                    ) : null}
                    {aiSetupBrowserStatus ? (
                      <p className="text-sm muted">{aiSetupBrowserStatus}</p>
                    ) : null}
                    {aiSetupStatus?.completed ? (
                      <p className="text-sm" style={{ color: "var(--success)" }}>
                        OpenAI auth is complete and saved to the app workspace.
                      </p>
                    ) : null}
                    {aiSetupStatus?.error ? (
                      <p className="text-sm" style={{ color: "var(--danger)" }}>
                        {aiSetupStatus.error}
                      </p>
                    ) : null}
                  </div>
                </div>

                  <div className="card">
                  <h2>Claude / Anthropic</h2>
                  <div className="stack">
                    <p className="text-sm muted">
                      Paste your Claude subscription token or Anthropic API key (<code>sk-ant-api…</code>). Runs <code>zeroclaw auth paste-token --provider anthropic</code> internally.
                    </p>
                    {claudeTokenStatus?.isSet ? (
                      <div className="badge success" style={{ alignSelf: "flex-start" }}>
                        Token saved ✓
                      </div>
                    ) : (
                      <div className="badge" style={{ alignSelf: "flex-start" }}>
                        Not configured
                      </div>
                    )}
                    <input
                      type="password"
                      value={claudeToken}
                      onChange={(e) => setClaudeToken(e.target.value)}
                      placeholder="Paste Claude token or sk-ant-api key…"
                      autoComplete="off"
                    />
                    <div className="row">
                      <button
                        type="button"
                        className="primary"
                        onClick={() => void saveAnthropicToken()}
                        disabled={claudeTokenBusy || !claudeToken.trim()}
                        style={{ flex: 1 }}
                      >
                        {claudeTokenBusy ? "Saving..." : "Save Token"}
                      </button>
                      <button
                        type="button"
                        className="danger"
                        onClick={() => void clearAnthropicToken()}
                        disabled={claudeTokenBusy || !claudeTokenStatus?.isSet}
                      >
                        Clear
                      </button>
                    </div>
                    {claudeTokenStatus?.message ? (
                      <p className="text-sm muted">{claudeTokenStatus.message}</p>
                    ) : null}
                    {claudeTokenStatus?.error ? (
                      <p className="text-sm" style={{ color: "var(--danger)" }}>
                        {claudeTokenStatus.error}
                      </p>
                    ) : null}
                  </div>
                </div>
                </>
              )}
            </div>
          </ViewErrorBoundary>
        ) : null}
      </main>

      {!hideChrome && (
        <nav className="bottom-nav">
          <button
            type="button"
            className={mobileTab === "journal" ? "active" : ""}
            onClick={() => setMobileTab("journal")}
          >
            <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round"><path d="M12 20h9"></path><path d="M16.5 3.5a2.121 2.121 0 0 1 3 3L7 19l-4 1 1-4L16.5 3.5z"></path></svg>
            Journal
          </button>
          <button
            type="button"
            className={mobileTab === "feed" ? "active" : ""}
            onClick={() => setMobileTab("feed")}
          >
            <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round"><circle cx="12" cy="12" r="10"></circle><polyline points="12 6 12 12 16 14"></polyline></svg>
            Feed
          </button>
          <button
            type="button"
            className={mobileTab === "productivity" ? "active" : ""}
            onClick={() => setMobileTab("productivity")}
          >
            <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round"><path d="M9 11l3 3L22 4"></path><path d="M21 12v7a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h11"></path><path d="M7 7h6"></path><path d="M7 15h8"></path></svg>
            <span className="bottom-nav-label">
              Productivity
              {openTodos.length + todayEventItems.length + upcomingEventItems.length > 0 ? (
                <span className="bottom-nav-badge">
                  {openTodos.length + todayEventItems.length + upcomingEventItems.length}
                </span>
              ) : null}
            </span>
          </button>
        </nav>
      )}
    </div>
  );
}

export default App;
