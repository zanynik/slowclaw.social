import { lazy, Suspense, FormEvent, useEffect, useMemo, useRef, useState } from "react";
import type { AtpAgent, AppBskyFeedDefs } from "@atproto/api";
import { blueskyImagesOf, blueskyVideoOf, blueskyExternalOf, blueskyQuotedRecordOf, fetchBlueskyReelsFeed, REELS_VIDEO_TOPICS, getBlueskyProfileCounts, getBlueskyProfile, getPublicBlueskyAuthorFeed, followBlueskyAuthor, unfollowBlueskyAuthor, repostBlueskyPost, unrepostBlueskyPost, quoteBlueskyPost } from "./lib/bluesky";
import type { BlueskySession, BlueskyPublicPost, BlueskyProfileCounts, BlueskyProfile } from "./lib/bluesky";
import { ViewErrorBoundary } from "./components/ViewErrorBoundary";
import { BottomNav } from "./components/BottomNav";
import { SwipeableView } from "./components/SwipeableView";
import { PullToRefresh } from "./components/PullToRefresh";
import { ReelsPlayer } from "./components/ReelsPlayer";
import { FeedActionBar } from "./components/FeedActionBar";
import { ToastContainer } from "./components/ui/ToastContainer";
import { appActions } from "./stores/useAppStore";
import { useIsKeyboardOpen } from "./hooks/useKeyboardHeight";
import { useScrollDirection } from "./hooks/useScrollDirection";
import {
  fetchNotesFromRelays,
  fetchProfiles,
  fetchReactionsForEvents,
  fetchRepliesForEvent,
  fetchNotesByIds,
  fetchNotesByHashtag,
  fetchLongFormArticles,
  getReplyParentId,
  npubFromHex,
  publishNote,
  publishProfile,
  publishNostrFollow,
  publishNostrUnfollow,
  publishNostrRepost,
  publishNostrReply,
  fetchNostrFollowingCount,
  type NostrNote,
  type NostrProfile,
  type NostrEvent,
} from "./lib/nostr";
// ── On-device Nostr store (Tauri-only; null outside the native runtime) ──────
import {
  cachedNpub,
  nostrGetNote,
  nostrGetProfiles,
  nostrGetReactions,
  nostrGetReplies,
  nostrPublishReaction,
  nostrPublishReply,
  nostrQueryNotes,
  nostrStoreStatus,
  type NostrStoreStatus,
} from "./lib/nostrLocalStore";
import {
  videoStoreStatus,
  videoQueryBluesky,
  videoQueryRaw,
  videoUpsertBluesky,
  type VideoStoreStatus,
} from "./lib/videoLocalStore";
// ── Nostr content-quality filter (language + spam + dedup) ───────────────────
import { filterNostrFeed, type NostrFeedStats } from "./lib/feedFilter";
// ── RSS/Atom feeds (Reads tab) ────────────────────────────────────────────────
import { fetchRssFeeds, RSS_FEEDS, type RssFeed, type RssItem } from "./lib/rss";
// ── YouTube ingestion (keyless; journal-topic-driven) ─────────────────────
import { loadYouTubeFeed, YOUTUBE_CHANNELS, type YouTubeVideo } from "./lib/youtube";
// ── Unified social feed: normalization + journal-driven topic curation ───────
import {
  toUnifiedFromNostr,
  toUnifiedFromHN,
  toUnifiedFromBluesky,
  toUnifiedFromNostrArticle,
  toUnifiedFromRss,
  toUnifiedFromYouTube,
  extractJournalTopics,
  matchesTopic,
  channelsForSource,
  type UnifiedItem,
  type ContentChannel,
  type SocialSource,
} from "./lib/socialFeed";
// ── Local-first interactions: saved/liked/reposted items + native share ────
import { getSavedItems, onSavedChange, type SavedItem, isReposted, toggleReposted, getRepostedIds } from "./lib/savedItems";
// ── Local-first profile (name / bio / avatar) ──────────────────────────────
import { getProfile, saveProfile, onProfileChange, fileToAvatarDataUrl, setAvatar, type LocalProfile } from "./lib/profile";
// ── Editable interest profile (steers the journal-is-the-lens signal) ──────
import {
  getInterestOverrides,
  getManualInterests,
  setInterestMultiplier,
  removeInterestOverride,
  addManualInterest,
  removeManualInterest,
  onInterestChange,
  INTEREST_MULT,
} from "./lib/interestProfile";
// ── Local-first optimistic follows ─────────────────────────────────────────
import { getFollowedIds, onFollowsChange, toggleFollow, nostrFollowKey, blueskyFollowKey } from "./lib/follows";
// ── Following home timeline (merged Nostr + Bluesky) ───────────────────────
import { loadFollowingFeed, type FollowingFeedItem } from "./lib/followingFeed";
// ── Reads ranking + read-time (Google News / Substack-style "For You") ──────
import { rankReads, chronologicalReads, type RankedRead } from "./lib/readsRanking";
import {
  loadCachedWoTSet,
  refreshWoTSet,
  onWoTChange,
  sortByWoTFirst,
} from "./lib/wot";
// ── Tauri API (replaces HTTP gateway calls) ──────────────────────────────────
import {
  saveJournalText,
  saveJournalTextFile,
  saveJournalMedia,
  importVoiceMemos,
  listJournals,
  getJournal,
  updateJournalText,
  renameJournal,
  deleteJournal,
  saveJournalInterestKeywords,
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
  configureNativeLocalAi,
  getNativeLocalAiStatus,
  nativeAiChat,
  nativeAiEngineStatus,
  clearNativeLocalAi,
  deleteLocalModel,
  transcribeAudio,
  transcribeJournalMediaNative,
  readJournalMediaBytes,
  setMetalMode as setMetalModeBackend,
  startRecording as startNativeAudioRecording,
  stopRecording as stopNativeAudioRecording,
  blobToBase64,
  base64ToBlob,
} from "./lib/tauriApi";
import type {
  JournalEntry,
  JournalSummary,
  Draft,
  PostRecord,
  AppConfig,
  NativeLocalAiStatus,
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
  DesktopGatewayInfo,
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
  getLocalModels,
  getLocalModelRuntime,
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
  startLocalModelRuntime,
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
  downloadLocalModel,
  getOpenRouterOAuthStatus,
  stopLocalModelRuntime,
  useLocalModel,
  fetchWebPreview,
} from "./lib/gatewayApi";
import type {
  FeedContentAgentItem,
  GatewayEventStreamHandle,
  JournalTranscriptionStatus,
  InterestProfileStats,
  LocalModelCatalogItem,
  LocalModelRuntimeStatus,
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
// ProductivityView removed — tasks now rendered inline with local persistence

const CHAT_THREAD_STORAGE_KEY = "slowclaw.chat.thread_id";
const CHAT_GATEWAY_BASE_URL_STORAGE_KEY = "slowclaw.chat.gateway_base_url";
const CHAT_GATEWAY_TOKEN_STORAGE_KEY = "slowclaw.chat.gateway_token";
const SYNC_PEER_GATEWAY_BASE_URL_STORAGE_KEY = "slowclaw.sync.peer.gateway_base_url";
const SYNC_PEER_GATEWAY_TOKEN_STORAGE_KEY = "slowclaw.sync.peer.gateway_token";
const CHAT_PROVIDER_STORAGE_KEY = "slowclaw.settings.provider";
const CHAT_MODEL_STORAGE_KEY = "slowclaw.settings.model";
const PERSISTED_POSTS_KEY = "slowclaw.generated_posts";
const PERSISTED_TODOS_KEY = "slowclaw.extracted_todos";
const PROCESSED_JOURNALS_KEY = "slowclaw.processed_journals";
const CHUNK_CHAR_LIMIT = 3200;

// Track which journal paths have been processed for feed/tasks
function loadProcessedJournals(): Set<string> {
  try {
    const raw = localStorage.getItem(PROCESSED_JOURNALS_KEY);
    return raw ? new Set(JSON.parse(raw)) : new Set();
  } catch { return new Set(); }
}
function saveProcessedJournals(paths: Set<string>) {
  try { localStorage.setItem(PROCESSED_JOURNALS_KEY, JSON.stringify([...paths])); } catch {}
}
function markJournalProcessed(path: string) {
  const set = loadProcessedJournals();
  set.add(path);
  saveProcessedJournals(set);
}

type PersistedPost = {
  id: string;
  text: string;
  sourceExcerpt: string;
  createdAt: number;
  liked?: boolean;
  /** When successfully pushed to Nostr/Bluesky (epoch ms). Absent on legacy data = assume published if liked. */
  publishedAt?: number;
  /** Nostr event id of the published note, for deep-linking + verification. */
  eventId?: string;
};

type TechNewsItem = {
  id: number;
  title: string;
  url: string;
  source: string;
  score: number;
  comments: number;
  createdAt: number;
  thumbnailUrl?: string;
};

type PersistedTodo = {
  id: string;
  title: string;
  details: string;
  done: boolean;
  createdAt: number;
};

// ── Dev-mode sample data ─────────────────────────────────────────────────────
const DEV_SAMPLE_POSTS: PersistedPost[] = [
  {
    id: "dev-post-1",
    text: "Just discovered that running AI models locally on your phone is actually possible now. No cloud, no API keys, full privacy. The future of personal computing is local-first. \ud83e\udde0\ud83d\udcf1",
    sourceExcerpt: "journal entry about local AI",
    createdAt: Date.now() - 1000 * 60 * 23,
  },
  {
    id: "dev-post-2",
    text: "Hot take: The best social media posts come from journaling first, then distilling. Write for yourself, then share the best parts with the world.",
    sourceExcerpt: "reflection on content creation",
    createdAt: Date.now() - 1000 * 60 * 60 * 2,
  },
  {
    id: "dev-post-3",
    text: "Shipped a fix today where the app was crashing because Metal GPU on iPhone tried to allocate more memory than the system allows. Solution: CPU-only inference with a graceful fallback. Stability > speed. ✅",
    sourceExcerpt: "debugging session notes",
    createdAt: Date.now() - 1000 * 60 * 60 * 5,
  },
  {
    id: "dev-post-4",
    text: "Three things I learned building a journaling app:\n\n1. Privacy is a feature, not a constraint\n2. Small models (2B params) are surprisingly good\n3. People write more when they know no one is watching",
    sourceExcerpt: "weekly reflection",
    createdAt: Date.now() - 1000 * 60 * 60 * 24,
  },
  {
    id: "dev-post-5",
    text: "The trick to making AI-generated tweets sound natural: give it your raw journal entry as context, not a polished prompt. Authenticity in, authenticity out.",
    sourceExcerpt: "AI prompt engineering notes",
    createdAt: Date.now() - 1000 * 60 * 60 * 48,
  },
];

const DEV_SAMPLE_TODOS: PersistedTodo[] = [
  {
    id: "dev-todo-1",
    title: "Test Q3_K_M model on iPhone",
    details: "Download the smaller quantization and verify stable CPU-only inference",
    done: false,
    createdAt: Date.now() - 1000 * 60 * 60,
  },
  {
    id: "dev-todo-2",
    title: "Write blog post about local-first AI",
    details: "Cover the journey from cloud API to on-device inference",
    done: false,
    createdAt: Date.now() - 1000 * 60 * 60 * 3,
  },
  {
    id: "dev-todo-3",
    title: "Fix auto-transcription for audio journals",
    details: "Speech.framework via Swift plugin instead of Rust ObjC FFI",
    done: true,
    createdAt: Date.now() - 1000 * 60 * 60 * 24,
  },
  {
    id: "dev-todo-4",
    title: "Design feed algorithm for Bluesky discovery",
    details: "Interest-weighted ranking with local vector similarity",
    done: false,
    createdAt: Date.now() - 1000 * 60 * 60 * 48,
  },
  {
    id: "dev-todo-5",
    title: "Update TestFlight build with crash fixes",
    details: "CPU-only inference, chunked decode, smaller context window",
    done: true,
    createdAt: Date.now() - 1000 * 60 * 60 * 72,
  },
];
// ── End dev-mode sample data ─────────────────────────────────────────────────

const DEV_SAMPLE_JOURNALS: LibraryItem[] = [
  {
    id: "dev-journal-1",
    path: "journal://dev-journal-1",
    title: "Thoughts on local AI",
    kind: "text",
    sizeBytes: 1200,
    modifiedAt: (Date.now() - 1000 * 60 * 30) / 1000,
    previewText: "Today I finally got the Gemma 4 model running on my iPhone. It's incredible that a 2B parameter model can run locally with decent speed. The key insight was keeping Metal GPU off and using CPU-only inference — it's slower but doesn't crash. I've been thinking about how this changes the privacy equation for personal AI assistants. No data leaves your device, ever. That's a fundamentally different trust model than cloud AI.",
    editableText: true,
    scope: "journal",
  },
  {
    id: "dev-journal-2",
    path: "journal://dev-journal-2",
    title: "Content creation workflow",
    kind: "text",
    sizeBytes: 800,
    modifiedAt: (Date.now() - 1000 * 60 * 60 * 4) / 1000,
    previewText: "My new workflow: write raw thoughts in the journal, then pull down in the Feed tab to turn them into tweet-ready content. The AI does a surprisingly good job of distilling long rambling thoughts into punchy social posts. I'm getting 3-4 usable tweets from a single journal session.",
    editableText: true,
    scope: "journal",
  },
  {
    id: "dev-journal-3",
    path: "journal://dev-journal-3",
    title: "Debugging Metal crashes",
    kind: "text",
    sizeBytes: 2400,
    modifiedAt: (Date.now() - 1000 * 60 * 60 * 24) / 1000,
    previewText: "Spent all day debugging why the app crashes on some iPhones but not others. The crash logs show SIGSEGV in ggml_metal_buffer_is_shared. This is an uncatchable signal — there's no way to gracefully handle it in Rust. The only safe approach is to avoid Metal GPU entirely for context creation on iOS. CPU-only is the answer for now.",
    editableText: true,
    scope: "journal",
  },
  {
    id: "dev-journal-4",
    path: "journal://dev-journal-4",
    title: "Morning reflection",
    kind: "text",
    sizeBytes: 600,
    modifiedAt: (Date.now() - 1000 * 60 * 60 * 48) / 1000,
    previewText: "Woke up early today and had a clear head about the product direction. SlowClaw should be the anti-Twitter — write slow, publish deliberately. The journal is the creative sandbox, the feed is your curated output. No infinite scroll, no engagement metrics, just thoughtful content creation.",
    editableText: true,
    scope: "journal",
  },
  {
    id: "dev-journal-5",
    path: "journal://dev-journal-5",
    title: "Audio recording test",
    kind: "audio",
    sizeBytes: 45000,
    modifiedAt: (Date.now() - 1000 * 60 * 60 * 72) / 1000,
    previewText: "",
    editableText: false,
    scope: "journal",
  },
];

function loadPersistedPosts(): PersistedPost[] {
  try {
    const raw = localStorage.getItem(PERSISTED_POSTS_KEY);
    if (raw) return JSON.parse(raw);
  } catch {}
  // Seed with sample posts in local dev / public demo so the UI is visible immediately
  if (isDemoContext()) {
    return DEV_SAMPLE_POSTS;
  }
  return [];
}

function savePersistedPosts(posts: PersistedPost[]) {
  try { localStorage.setItem(PERSISTED_POSTS_KEY, JSON.stringify(posts)); } catch {}
}

function loadPersistedTodos(): PersistedTodo[] {
  try {
    const raw = localStorage.getItem(PERSISTED_TODOS_KEY);
    if (raw) return JSON.parse(raw);
  } catch {}
  if (isDemoContext()) {
    return DEV_SAMPLE_TODOS;
  }
  return [];
}

function savePersistedTodos(todos: PersistedTodo[]) {
  try { localStorage.setItem(PERSISTED_TODOS_KEY, JSON.stringify(todos)); } catch {}
}
const LOCAL_JOURNAL_PATH_PREFIX = "journal://";
const UI_THEME_STORAGE_KEY = "slowclaw.ui.theme";
const UI_TAB_STORAGE_KEY = "slowclaw.ui.tab";
const AI_METAL_MODE_KEY = "slowclaw.settings.metalMode";
// First-run capture-first onboarding: a one-time welcome overlay that routes
// new users to the Journal composer (not the empty Feed). Once seen, the user
// is considered onboarded and their tab choice wins thereafter.
const ONBOARDING_SEEN_KEY = "slowclaw.onboarding.seen";

const DESKTOP_SECRET_SERVICE = "social.slowclaw.gateway";
const PROVIDER_API_KEY_SECRET_ACCOUNT = "provider.api_key";
const OPENROUTER_API_KEY_SECRET_ACCOUNT = "openrouter.api_key";
const DEFAULT_RECORDING_HINT = "Ready to add a journal note, audio, or video.";
const NATIVE_GATEWAY_BASE_URL = "http://127.0.0.1:42617";
const ATOMIC_LOCAL_PROVIDER = "osaurus";
const ATOMIC_LOCAL_API_URL = "http://127.0.0.1:1337/v1";
const ATOMIC_LOCAL_MODEL = "gemma-3n-e4b-it";
let blueskyModulePromise: Promise<typeof import("./lib/bluesky")> | null = null;
const QRCodeCanvas = lazy(() => import("qrcode.react").then(m => ({ default: m.QRCodeCanvas })));

type MobileTab = "feed" | "reads" | "journal" | "queue" | "profile";
const TAB_ORDER: MobileTab[] = ["feed", "reads", "journal", "queue", "profile"];
// Rotating seed prompts shown above the composer during first-run onboarding.
// Indexed by the day-of-month so a returning first-time user sees variety.
const FIRST_ENTRY_PROMPTS = [
  "What made today different?",
  "Something you're figuring out right now…",
  "A moment worth keeping.",
  "What's been on your mind lately?",
  "One small thing that went well.",
];
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
    return "feed";
  }
  const saved = window.localStorage.getItem(UI_TAB_STORAGE_KEY);
  // Migration: fold removed tabs into their successors.
  //   productivity / todos / events  → queue (Tasks now lives in Queue)
  //   news                            → feed   (Tech News is now a Feed toggle)
  //   reels / media                   → feed   (video + images merged into the unified Feed)
  if (saved === "todos" || saved === "events" || saved === "productivity") {
    return "queue";
  }
  if (saved === "news" || saved === "reels" || saved === "media") {
    return "feed";
  }
  if (saved === "feed" || saved === "reads" || saved === "journal" || saved === "queue" || saved === "profile") {
    return saved;
  }
  // Capture-first onboarding: a brand-new user (no saved tab, onboarding not
  // yet seen) lands on the Journal composer. The Feed is non-functional until
  // the first entry seeds an interest profile, so it makes a poor landing
  // surface. Once the welcome overlay has been seen (dismissed) the user is
  // routed to the Feed like a returning user.
  const onboardingSeen = window.localStorage.getItem(ONBOARDING_SEEN_KEY);
  if (!onboardingSeen) {
    return "journal";
  }
  return "feed";
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

function getRelativeTime(dateVal: string | number): string {
  const now = Date.now();
  const then = typeof dateVal === "number" ? dateVal : new Date(dateVal).getTime();
  const diffSec = Math.round((now - then) / 1000);
  if (diffSec < 60) return "now";
  if (diffSec < 3600) return `${Math.floor(diffSec / 60)}m`;
  if (diffSec < 86400) return `${Math.floor(diffSec / 3600)}h`;
  if (diffSec < 604800) return `${Math.floor(diffSec / 86400)}d`;
  return new Date(then).toLocaleDateString([], { month: "short", day: "numeric" });
}

function domainFromUrl(url: string): string {
  try {
    return new URL(url).hostname.replace(/^www\./, "");
  } catch {
    return "news.ycombinator.com";
  }
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

function journalTranscriptPathForMediaPath(mediaPath: string) {
  const normalized = mediaPath.replace(/^\/+/, "");
  if (normalized.startsWith("journals/media/")) {
    const relative = normalized.slice("journals/media/".length);
    const stemmed = relative.replace(/\.[^/.]+$/, ".txt");
    return `journals/text/transcriptions/${stemmed}`;
  }
  return `journals/text/transcriptions/${fileStemFromPath(mediaPath)}.txt`;
}

function journalTranscriptPathForMedia(item: LibraryItem) {
  return journalTranscriptPathForMediaPath(item.path);
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

function isMobileUserAgent() {
  if (typeof window === "undefined") {
    return false;
  }
  return /iphone|ipad|ipod|android/i.test(window.navigator.userAgent || "");
}

function isTauriDesktopRuntime() {
  if (typeof window === "undefined") {
    return false;
  }
  return Boolean((window as any).__TAURI_INTERNALS__) && !isMobileUserAgent();
}

function isTauriMobileRuntime() {
  if (typeof window === "undefined") {
    return false;
  }
  return (
    Boolean((window as any).__TAURI_MOBILE__) ||
    (Boolean((window as any).__TAURI_INTERNALS__) && isMobileUserAgent())
  );
}

// True when running as the public in-browser demo (build-time flag) or on a local
// dev host. In this context the app seeds sample journals/posts/todos for UI
// preview and never expects a reachable gateway backend.
function isDemoContext() {
  if (typeof __SLOWCLAW_DEMO_BUILD__ !== "undefined" && __SLOWCLAW_DEMO_BUILD__) {
    return true;
  }
  if (typeof window === "undefined") {
    return false;
  }
  return /^localhost$|^127\.0\.0\.1$/.test(window.location.hostname);
}

function isLoopbackUrl(value: string) {
  try {
    const parsed = new URL(value);
    return ["127.0.0.1", "localhost", "::1", "[::1]"].includes(parsed.hostname);
  } catch {
    return false;
  }
}

function hasNativeAudioRecorderPlugin() {
  if (typeof window === "undefined") {
    return false;
  }
  return Boolean((window as any).__SLOWCLAW_NATIVE_AUDIO_RECORDER__);
}

function defaultGatewayBaseUrl() {
  if (typeof window === "undefined") {
    return NATIVE_GATEWAY_BASE_URL;
  }
  const saved = window.localStorage.getItem(CHAT_GATEWAY_BASE_URL_STORAGE_KEY);
  if (saved && saved.trim()) {
    const normalized = saved.trim().replace(/\/+$/, "");
    if (!isTauriMobileRuntime() || isLoopbackUrl(normalized)) {
      return normalized;
    }
  }
  if (isTauriDesktopRuntime() || isTauriMobileRuntime()) {
    return NATIVE_GATEWAY_BASE_URL;
  }
  const protocol = window.location.protocol === "https:" ? "https:" : "http:";
  const host = window.location.hostname || "127.0.0.1";
  return `${protocol}//${host}:42617`;
}

function normalizeGatewayToken(value: string) {
  const token = value.trim();
  return token === "desktop-local" ? "" : token;
}

function normalizeProviderId(value: string) {
  const trimmed = value.trim();
  if (!trimmed) {
    return "";
  }
  const lowered = trimmed.toLowerCase();
  if (lowered.startsWith("custom:") || lowered.startsWith("anthropic-custom:")) {
    return trimmed;
  }
  switch (lowered) {
    case "openai_codex":
    case "codex":
    case "openai-codex":
      return "openai-codex";
    case "google":
    case "google-gemini":
    case "gemini":
      return "gemini";
    case "grok":
    case "xai":
      return "xai";
    case "together":
    case "together-ai":
      return "together-ai";
    default:
      return lowered;
  }
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
  const isNativeClient = isDesktopClient || isTauriMobileRuntime();
  // When true, Nostr read/publish routes through the on-device store (Tauri
  // IPC). When false (web/demo), falls back to direct browser WebSocket reads.
  // Default to the native path so the store is preferred from first paint;
  // a status poll below downgrades this if the ingester isn't actually running.
  const [nostrLocalStoreStatus, setNostrLocalStoreStatus] = useState<NostrStoreStatus | null>(null);
  const useNostrLocalStore = isNativeClient && nostrLocalStoreStatus?.running !== false;
  // Video local store gate. Unlike Nostr, there's no long-lived ingester task
  // — the store is populated lazily by `videoUpsertBluesky` after each network
  // fetch, and by the Nostr ingester's video hook. "initialized" just means the
  // store file exists, so cached Reels render instantly on tab-open.
  const [videoLocalStoreStatus, setVideoLocalStoreStatus] = useState<VideoStoreStatus | null>(null);
  const useVideoLocalStore = isNativeClient && videoLocalStoreStatus?.initialized !== false;
  const isLargeScreen = useIsLargeScreen();
  const scrollDirection = useScrollDirection(8);
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
  const [showSettings, setShowSettings] = useState(false);
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
  const [audioPlaybackUrl, setAudioPlaybackUrl] = useState("");
  const [audioPlaybackLoading, setAudioPlaybackLoading] = useState(false);
  const audioPlaybackUrlRef = useRef("");
  const [selectedFeedItem, setSelectedFeedItem] = useState<LibraryItem | null>(null);
  const [selectedJournalText, setSelectedJournalText] = useState("");
  const [selectedFeedText, setSelectedFeedText] = useState("");
  const [journalDraftText, setJournalDraftText] = useState("");
  const [journalSaveStatus, setJournalSaveStatus] = useState("Journal idle");
  const [pendingDeleteJournalItem, setPendingDeleteJournalItem] = useState<LibraryItem | null>(null);
  const [pendingDeleteFeedItem, setPendingDeleteFeedItem] = useState<LibraryItem | null>(null);
  const [journalTranscribing, setJournalTranscribing] = useState(false);
  const [importingVoiceMemos, setImportingVoiceMemos] = useState(false);
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
  const [settingsApiUrl, setSettingsApiUrl] = useState("");
  const [settingsTranscriptionEnabled, setSettingsTranscriptionEnabled] = useState(false);
  const [settingsTranscriptionModel, setSettingsTranscriptionModel] = useState("");
  const [settingsAvailableTranscriptionModels, setSettingsAvailableTranscriptionModels] = useState<string[]>([]);
  const [localModelNames, setLocalModelNames] = useState<string[]>([]);
  const [metalMode, setMetalMode] = useState<boolean>(() => {
    try { return localStorage.getItem(AI_METAL_MODE_KEY) === "true"; } catch { return false; }
  });
  const [runtimeMediaCapabilities, setRuntimeMediaCapabilities] = useState<MediaCapabilities | null>(null);
  const [runtimeMediaSummary, setRuntimeMediaSummary] = useState("");
  const [settingsConfigBusy, setSettingsConfigBusy] = useState(false);
  const [settingsConfigStatus, setSettingsConfigStatus] = useState("");
  const [settingsConfigLoaded, setSettingsConfigLoaded] = useState(false);
  const [localModels, setLocalModels] = useState<LocalModelCatalogItem[]>([]);
  const [localModelsStatus, setLocalModelsStatus] = useState("");
  const [localModelsEngineStatus, setLocalModelsEngineStatus] = useState("");
  const [localModelRuntime, setLocalModelRuntime] = useState<LocalModelRuntimeStatus | null>(null);
  const [nativeLocalAiStatus, setNativeLocalAiStatus] = useState<NativeLocalAiStatus | null>(null);
  const [localModelBusyId, setLocalModelBusyId] = useState("");
  const [generatedPost, setGeneratedPost] = useState("");
  const [generatePostBusy, setGeneratePostBusy] = useState(false);
  const [generatePostStatus, setGeneratePostStatus] = useState("");
  const [persistedPosts, setPersistedPosts] = useState<PersistedPost[]>(loadPersistedPosts);
  const [persistedTodos, setPersistedTodos] = useState<PersistedTodo[]>(loadPersistedTodos);
  const [extractingLocalTasks, setExtractingLocalTasks] = useState(false);
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
  // First-run onboarding: a one-time welcome overlay + the post-entry reveal
  // of the interests the on-device AI extracted from the user's first journal.
  const [showWelcome, setShowWelcome] = useState<boolean>(() => {
    if (typeof window === "undefined") return false;
    if (window.localStorage.getItem(ONBOARDING_SEEN_KEY)) return false;
    // Returning users (a saved tab choice or the legacy welcome-seed flag) are
    // already onboarded — mark them seen and never show the overlay.
    const hasSavedTab = Boolean(window.localStorage.getItem(UI_TAB_STORAGE_KEY));
    const legacySeed = window.localStorage.getItem("slowclaw_welcome_seeded");
    if (hasSavedTab || legacySeed) {
      window.localStorage.setItem(ONBOARDING_SEEN_KEY, "1");
      return false;
    }
    return true;
  });
  // Transient: warms up the composer copy right after the welcome CTA.
  const [showFirstEntryPrompt, setShowFirstEntryPrompt] = useState(false);
  // The most recently extracted interests (for the inline reveal card) and the
  // journal id they came from (so chip removals can be persisted back).
  const [lastExtractedInterests, setLastExtractedInterests] = useState<string[]>([]);
  const [lastInterestJournalId, setLastInterestJournalId] = useState<string | null>(null);
  const [dismissedInterestReveal, setDismissedInterestReveal] = useState(false);
  const [blueskyProfileStats, setBlueskyProfileStats] = useState<InterestProfileStats>({
    interestCount: 0,
    sourceCount: 0,
    refreshedSources: 0,
    mergedCount: 0,
    spawnedCount: 0,
    ignoredCount: 0,
  });
  const workspaceTabActive = mobileTab === "queue";
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
  // Reply success/failure toast for the social Feed reply compose boxes.
  const [replyToast, setReplyToast] = useState<string | null>(null);
  // Which Bluesky posts have their inline reply compose expanded.
  const [blueskyReplyExpanded, setBlueskyReplyExpanded] = useState<Set<string>>(new Set());

  // World feed sub-tabs & Me feed sub-tabs
  const [videoFallbackItems, setVideoFallbackItems] = useState<any[]>([]);
  const [videoFallbackLoading, setVideoFallbackLoading] = useState(false);
  const [meFeedTab, setMeFeedTab] = useState<"drafts" | "published">("drafts");
  const [expandedArticleUrl, setExpandedArticleUrl] = useState("");

  // Nostr identity
  const [nostrKeys, setNostrKeys] = useState<NostrKeys | null>(null);
  const [nostrKeysBusy, setNostrKeysBusy] = useState(false);
  const [nostrFeedNotes, setNostrFeedNotes] = useState<NostrNote[]>([]);
  const [nostrFeedLoading, setNostrFeedLoading] = useState(false);
  // Web-of-Trust trusted-pubkey set for ranking the Nostr feed. Initialized
  // synchronously from the localStorage cache so the first paint already
  // tier-orders the feed; the background effect refreshes it from relays.
  // Empty set (no graph / cold start) leaves the chronological feed unchanged.
  const [wotSet, setWotSet] = useState<Set<string>>(() => loadCachedWoTSet() ?? new Set<string>());
  // Enrichment state for a richer Nostr feed/profile: profile metadata (kind 0),
  // reaction counts (kind 7), resolved parent notes (for reply context), and
  // expandable reply threads. Each keyed by pubkey / event id.
  const [nostrProfiles, setNostrProfiles] = useState<Record<string, NostrProfile>>({});
  const [nostrReactions, setNostrReactions] = useState<Record<string, number>>({});
  const [nostrParentNotes, setNostrParentNotes] = useState<Record<string, NostrNote>>({});
  const [nostrReplyThreads, setNostrReplyThreads] = useState<Record<string, NostrNote[]>>({});
  const [nostrRepliesLoading, setNostrRepliesLoading] = useState<Record<string, boolean>>({});
  const [nostrProfileOverlay, setNostrProfileOverlay] = useState<NostrProfile | null>(null);
  const [nostrRevealPrivkey, setNostrRevealPrivkey] = useState(false);
  const [nostrCopiedKey, setNostrCopiedKey] = useState<"" | "npub" | "nsec">("");
  const [techNewsItems, setTechNewsItems] = useState<TechNewsItem[]>([]);

  // ── Journal-driven topic curation (applies across News + Nostr tabs) ────────
  // Topics are mined from journal entries; the user picks one to filter every
  // social surface through a single universal predicate (lib/socialFeed.ts).
  const [activeSocialTopic, setActiveSocialTopic] = useState<string>("");

  // ── Social source + channel state (validated source-level filter levers) ────
  // `socialSource` picks the open-protocol source: Nostr (NIP-12 hashtags) or
  // Bluesky (anonymous searchPosts). `activeChannel` is the preset lever (or
  // "" for firehose/discover). Switching a channel re-fetches from the SOURCE
  // so content is guaranteed for popular terms (see lib/socialFeed.ts catalog).
  const [socialSource, setSocialSource] = useState<SocialSource>("nostr");
  const [activeChannelId, setActiveChannelId] = useState<string>("");
  const [feedView, setFeedView] = useState<"social" | "news">("social");
  // Following home timeline (merged Nostr + Bluesky from the follows store).
  const [followingItems, setFollowingItems] = useState<FollowingFeedItem[]>([]);
  const [followingLoading, setFollowingLoading] = useState(false);
  const [followingError, setFollowingError] = useState("");
  // Reposted-set (mirrors localStorage so FeedActionBar reflects optimistic state).
  const [repostedIds, setRepostedIds] = useState<string[]>(() => getRepostedIds());
  // Bluesky public posts cache + loading (separate from the authed blueskyFeedItems).
  const [blueskyPublicPosts, setBlueskyPublicPosts] = useState<import("./lib/bluesky").BlueskyPublicPost[]>([]);
  const [blueskyPublicLoading, setBlueskyPublicLoading] = useState(false);
  const [blueskyPublicError, setBlueskyPublicError] = useState("");
  const [socialFeedError, setSocialFeedError] = useState("");
  // Nostr quality-filter stats (how many notes were dropped as spam/non-EN).
  const [nostrFeedStats, setNostrFeedStats] = useState<NostrFeedStats | null>(null);
  // Bluesky video posts for the unified Feed's inline videos + the
  // tap-to-fullscreen overlay (the dedicated Reels tab was removed).
  const [reelsPosts, setReelsPosts] = useState<BlueskyPublicPost[]>([]);
  const [reelsLoading, setReelsLoading] = useState(false);
  // Reads tab (long-form: Nostr NIP-23 articles + RSS/Atom blogs).
  const [readsArticles, setReadsArticles] = useState<NostrEvent[]>([]);
  const [readsRssItems, setReadsRssItems] = useState<{ feed: RssFeed; items: RssItem[] }[]>([]);
  const [readsLoading, setReadsLoading] = useState(false);
  const [readsError, setReadsError] = useState("");
  const [readsSource, setReadsSource] = useState<"nostr" | "rss">("nostr");
  // YouTube (keyless) folds into the ranked Reads stream when toggled on,
  // searched by the user's journal topics — the lens applied to video.
  const [readsYouTubeEnabled, setReadsYouTubeEnabled] = useState(false);
  const [readsYouTubeItems, setReadsYouTubeItems] = useState<YouTubeVideo[]>([]);
  const [activeRssFeedIds, setActiveRssFeedIds] = useState<string[]>(["hackernews", "stratechery", "verge"]);
  // Reads ranking mode: "foryou" (scored merge) vs "latest" (chronological).
  const [readsRankMode, setReadsRankMode] = useState<"foryou" | "latest">(() => {
    if (typeof window === "undefined") return "foryou";
    return window.localStorage.getItem("slowclaw.reads.rank") === "latest" ? "latest" : "foryou";
  });
  // Feed/Reels "Show more" pagination (replaces the silent 40-item cliff).
  const [feedVisibleCount, setFeedVisibleCount] = useState(20);
  const [readsVisibleCount, setReadsVisibleCount] = useState(12);
  // Local-first cache for Reads: the last-good ranked stream is persisted so
  // the Reads tab paints instantly on open (Damus-style), then refreshes in
  // the background. Stores the UnifiedItem[] (not the RankedRead wrapper) so
  // the cache survives changes to scoring weights / rank mode.
  const READS_CACHE_KEY = "slowclaw.reads.unified.v1";
  const [cachedReads, setCachedReads] = useState<UnifiedItem[]>(() => {
    if (typeof window === "undefined") return [];
    try {
      const raw = window.localStorage.getItem(READS_CACHE_KEY);
      const parsed = raw ? JSON.parse(raw) : [];
      return Array.isArray(parsed) ? (parsed as UnifiedItem[]) : [];
    } catch {
      return [];
    }
  });
  // Reels global mute — lifted out of ReelsPlayer so unmuting one unmutes all.
  const [reelsMuted, setReelsMuted] = useState<boolean>(() => {
    if (typeof window === "undefined") return true;
    return window.localStorage.getItem("slowclaw.reels.muted") !== "false";
  });
  // Fullscreen video overlay: tapping an inline video in the unified Feed opens
  // a reels-style fullscreen player. Holds the list of video posts available in
  // the current feed plus the index to start at, so the user can swipe through
  // all videos — not just the one tapped. null = hidden.
  type FullscreenVideo = { posts: BlueskyPublicPost[]; startIndex: number } | null;
  const [fullscreenVideo, setFullscreenVideo] = useState<FullscreenVideo>(null);
  const fullscreenVideoScrollRef = useRef<HTMLDivElement>(null);
  // When the fullscreen video overlay opens, jump to the tapped post's index so
  // the user lands on the video they tapped (not the first in the list).
  useEffect(() => {
    if (!fullscreenVideo) return;
    const root = fullscreenVideoScrollRef.current;
    if (!root) return;
    const tile = root.querySelectorAll<HTMLElement>(".reels-tile")[fullscreenVideo.startIndex];
    if (tile) tile.scrollIntoView({ behavior: "auto" });
  }, [fullscreenVideo]);
  // Saved items (Profile tab) — mirrored from the localStorage store so the
  // Profile list re-renders when Feed/Reels/Reads save or unsave an item.
  const [savedItems, setSavedItems] = useState<SavedItem[]>(() => getSavedItems());
  // Local profile (name / bio / avatar) — persisted to localStorage, mirrored here.
  const [localProfile, setLocalProfile] = useState<LocalProfile | null>(() => getProfile());
  // Editable interest overrides + manual interests steer the curation lens.
  // Kept in state so the journalTopics memo recomputes when the user edits them.
  const [interestOverrides, setInterestOverrides] = useState<Record<string, { multiplier: number }>>(() => getInterestOverrides());
  const [manualInterests, setManualInterests] = useState<string[]>(() => getManualInterests());
  const [interestDraft, setInterestDraft] = useState("");
  // Profile content tab: Posted | Drafts | Saved (Twitter/Instagram-style segmented control).
  const [profileContentTab, setProfileContentTab] = useState<"posted" | "drafts" | "saved">("posted");
  // Profile follower/following counts (Bluesky via public AppView, Nostr via kind-3).
  const [blueskyCounts, setBlueskyCounts] = useState<BlueskyProfileCounts | null>(null);
  const [nostrFollowingCount, setNostrFollowingCount] = useState<number | null>(null);
  const [profilePublishing, setProfilePublishing] = useState(false);
  const [profilePublishToast, setProfilePublishToast] = useState<string | null>(null);
  // Profile avatar picker (hidden file input, triggered by tapping the avatar).
  const profileAvatarInputRef = useRef<HTMLInputElement | null>(null);
  // Refresh toast (#5): a tiny "Updated" confirmation shown after pull-to-refresh.
  const [refreshToast, setRefreshToast] = useState<string | null>(null);
  // New-posts pill (#4): count of fresh social-feed items arrived since the user
  // last viewed the top. Resets on tap (scrolls to top) or tab switch.
  const [newPostsCount, setNewPostsCount] = useState(0);
  const lastSeenTopPostIdRef = useRef<string | null>(null);
  const [techNewsLoading, setTechNewsLoading] = useState(false);
  const [techNewsError, setTechNewsError] = useState("");
  const [nostrPostConfirmPost, setNostrPostConfirmPost] = useState<PersistedPost | null>(null);
  const [nostrPostConfirmStep, setNostrPostConfirmStep] = useState<"confirm" | "account" | null>(null);

  // Profile overlay (view Nostr / Bluesky user or TweetClaw skill)
  type ProfileView =
    | { kind: "nostr"; pubkey: string }
    | { kind: "bluesky"; actor: string }
    | { kind: "skill"; skillId: string }
    | null;
  const [profileView, setProfileView] = useState<ProfileView>(null);
  const [profileViewNotes, setProfileViewNotes] = useState<NostrNote[]>([]);
  const [profileViewBlueskyPosts, setProfileViewBlueskyPosts] = useState<BlueskyPublicPost[]>([]);
  const [profileViewBlueskyProfile, setProfileViewBlueskyProfile] = useState<BlueskyProfile | null>(null);
  const [profileViewNostrFollowing, setProfileViewNostrFollowing] = useState<number | null>(null);
  const [profileViewLoading, setProfileViewLoading] = useState(false);
  // Local optimistic follow state (mirrors lib/follows store; re-renders modal + cards).
  const [followedIds, setFollowedIds] = useState<string[]>(() => getFollowedIds());

  // TweetClaw prompt (editable)
  const TWEETCLAW_PROMPT_KEY = "slowclaw.skill.tweetclaw.prompt";
  const defaultTweetClawPrompt = "You are a social media content writer. Turn the following journal entry into a concise, engaging tweet-style post (under 280 characters). Be authentic and conversational. Output ONLY the post text, no hashtags unless they add real value. No quotes around the text.";
  const [tweetClawPrompt, setTweetClawPrompt] = useState(() => localStorage.getItem(TWEETCLAW_PROMPT_KEY) || defaultTweetClawPrompt);

  // Progressive feed: generation-based polling
  const [feedGeneration, setFeedGeneration] = useState<number | undefined>(undefined);
  const [feedNewPostsBanner, setFeedNewPostsBanner] = useState(false);
  const feedPollTimerRef = useRef<number | undefined>(undefined);
  const pendingFeedItemsRef = useRef<PersonalizedFeedResponse | null>(null);

  // Persist Reels global mute + Reads rank mode (survive tab switches / reloads).
  useEffect(() => {
    if (typeof window === "undefined") return;
    window.localStorage.setItem("slowclaw.reels.muted", reelsMuted ? "true" : "false");
  }, [reelsMuted]);
  useEffect(() => {
    if (typeof window === "undefined") return;
    window.localStorage.setItem("slowclaw.reads.rank", readsRankMode);
  }, [readsRankMode]);

  // Mirror the localStorage saved-items store into state for the Profile list,
  // and re-sync when Feed/Reels/Reads mutate it (same-tab custom event + cross-tab storage).
  useEffect(() => onSavedChange(() => setSavedItems(getSavedItems())), []);
  // Mirror local profile store into state (re-renders Profile on edits).
  useEffect(() => onProfileChange(() => setLocalProfile(getProfile())), []);
  // Interest overrides / manual interests are local-first; re-sync on edit
  // (same-tab event) and cross-tab so the lens updates instantly everywhere.
  useEffect(() => onInterestChange(() => {
    setInterestOverrides(getInterestOverrides());
    setManualInterests(getManualInterests());
  }), []);
  // Mirror the localStorage follows store so the modal + cards re-render on toggle.
  useEffect(() => onFollowsChange(() => setFollowedIds(getFollowedIds())), []);
  // Mirror the reposted store so FeedActionBar re-renders on toggle.
  useEffect(() => onSavedChange(() => setRepostedIds(getRepostedIds())), []);

  // Fetch follower/following counts when the Profile tab opens (or accounts change).
  // Bluesky: anonymous public AppView getProfile. Nostr: kind-3 contact-list count.
  // Both best-effort — failures leave the stat hidden rather than blocking the UI.
  useEffect(() => {
    if (mobileTab !== "profile") return;
    let cancelled = false;
    if (session?.handle) {
      void getBlueskyProfileCounts(session.handle).then((c) => {
        if (!cancelled) setBlueskyCounts(c);
      });
    } else {
      setBlueskyCounts(null);
    }
    if (nostrKeys?.publicKeyHex) {
      void fetchNostrFollowingCount(nostrKeys.publicKeyHex).then((n) => {
        if (!cancelled) setNostrFollowingCount(n);
      });
    } else {
      setNostrFollowingCount(null);
    }
    return () => { cancelled = true; };
  }, [mobileTab, session?.handle, nostrKeys?.publicKeyHex]);

  // ── Web-of-Trust refresh ──────────────────────────────────────────────────
  // Build the trusted-pubkey set in the background so the Nostr feed can be
  // tier-sorted (WoT authors first). Fire-and-forget: never blocks the feed.
  // The cached set seeds `wotSet` synchronously on mount; this refreshes it
  // from relays (follow graph + optional cold-start curated seed) and updates
  // state when a fresh set lands. `onWoTChange` propagates cross-tab refreshes.
  useEffect(() => {
    const ownPubkey = nostrKeys?.publicKeyHex;
    if (!ownPubkey) return;
    // Journal text feeds the cold-start keyword matching for new users.
    // Include media transcripts (surfaced in previewText) so voice journals
    // shape the same lens as written ones.
    const journalTexts = journalItems
      .filter((item) => (item.previewText || "").trim().length > 10)
      .slice(0, 60)
      .map((item) => item.previewText || "");
    let cancelled = false;
    void refreshWoTSet({ ownPubkey, journalTexts }).then((set) => {
      if (!cancelled) setWotSet(set);
    }).catch(() => {
      // Best-effort: keep the cached set; the feed stays chronological.
    });
    const off = onWoTChange(() => {
      const cached = loadCachedWoTSet();
      if (cached && cached.size > 0) setWotSet(cached);
    });
    return () => { cancelled = true; off(); };
    // journalItems is intentionally a dep so cold-start keywords refresh when
    // journals change; refreshWoTSet itself respects a 24h cache window.
  }, [nostrKeys?.publicKeyHex, journalItems]);

  // Publish the local profile (name/bio/avatar) to Nostr as a kind-0 event so
  // the user's relay identity matches what they see in-app.
  async function handlePublishProfileToNostr() {
    if (profilePublishing || !nostrKeys) return;
    setProfilePublishing(true);
    setProfilePublishToast(null);
    try {
      const result = await publishProfile({
        name: localProfile?.name?.trim() || undefined,
        displayName: localProfile?.name?.trim() || undefined,
        about: localProfile?.bio?.trim() || undefined,
        picture: localProfile?.avatar || undefined,
      });
      setProfilePublishToast(result.success ? "Profile published to Nostr" : (result.error || "Publish failed"));
    } catch {
      setProfilePublishToast("Publish failed");
    } finally {
      setProfilePublishing(false);
      window.setTimeout(() => setProfilePublishToast(null), 2600);
    }
  }

  // Wrap any refresh handler with a tiny "Updated" toast (#5). Returns a fn the
  // PullToRefresh onRefresh prop can consume directly.
  function withRefreshToast(label: string, fn: () => Promise<void> | void) {
    return async () => {
      try {
        await fn();
      } finally {
        setRefreshToast(label);
        window.setTimeout(() => setRefreshToast((cur) => (cur === label ? null : cur)), 1800);
      }
    };
  }

  // Reset feed pagination when the source/topic changes (so the list isn't empty).
  useEffect(() => { setFeedVisibleCount(20); }, [socialSource, activeChannelId, activeSocialTopic, feedView]);
  // Reset Reads pagination when the rank mode / RSS filter changes.
  useEffect(() => { setReadsVisibleCount(12); }, [readsRankMode, activeRssFeedIds]);

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
      // Load Nostr keys (normalize legacy hex-in-nsec/npub storage to bech32)
      const storedNostrKeys = await loadNostrKeysSecure();
      if (!cancelled && storedNostrKeys) {
        const { normalizeNostrKeys } = await import("./lib/nostr");
        setNostrKeys(normalizeNostrKeys(storedNostrKeys));
      }
      if (!cancelled && isDesktopClient) {
        const secureGatewayToken = await loadGatewayTokenSecure();
        if (secureGatewayToken) {
          setChatGatewayToken(secureGatewayToken);
        }
        await syncDesktopGatewayBootstrap();
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
        const openrouterKeySecret = await invokeDesktopCommand<{ value: string | null }>("get_secret", {
          req: { service: DESKTOP_SECRET_SERVICE, account: OPENROUTER_API_KEY_SECRET_ACCOUNT }
        });
        let openrouterKey = String(openrouterKeySecret?.value || "").trim();
        const genericProviderKey = String(apiKeySecret?.value || "").trim();
        if (!openrouterKey && genericProviderKey.startsWith("sk-or-")) {
          await invokeDesktopCommandStrict("set_secret", {
            req: {
              service: DESKTOP_SECRET_SERVICE,
              account: OPENROUTER_API_KEY_SECRET_ACCOUNT,
              value: genericProviderKey,
            },
          });
          await invokeDesktopCommandStrict("delete_secret", {
            req: {
              service: DESKTOP_SECRET_SERVICE,
              account: PROVIDER_API_KEY_SECRET_ACCOUNT,
            },
          });
          openrouterKey = genericProviderKey;
        }
        if (genericProviderKey && !genericProviderKey.startsWith("sk-or-")) {
          setProviderApiKey(genericProviderKey);
          setProviderApiKeyStatus("Loaded saved API key");
        } else {
          setProviderApiKey("");
          setProviderApiKeyStatus("");
        }
        if (openrouterKey) {
          setOpenrouterOAuthStatus("Loaded saved OpenRouter API key.");
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

  // Poll the on-device Nostr + video store status so the UI knows whether the
  // background ingester is running and whether cached videos are available.
  // Outside Tauri this is a no-op. The video poll rides the same interval — no
  // extra timer.
  useEffect(() => {
    if (!isNativeClient) return;
    let cancelled = false;
    const poll = async () => {
      const [ns, vs] = await Promise.all([nostrStoreStatus(), videoStoreStatus()]);
      if (!cancelled) {
        setNostrLocalStoreStatus(ns);
        setVideoLocalStoreStatus(vs);
      }
    };
    void poll();
    const id = window.setInterval(poll, 15_000);
    return () => {
      cancelled = true;
      window.clearInterval(id);
    };
  }, [isNativeClient]);

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
    if (!isNativeClient || chatGatewayToken.trim()) {
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
  }, [isNativeClient, chatGatewayToken]);

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
    if (!token && isNativeClient) {
      token = normalizeGatewayToken((await syncDesktopGatewayBootstrap()) || "");
    }
    try {
      if (scope === "journal" || scope === "all") {
        if (isNativeClient) {
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

  /**
   * Persist a media-journal transcript to the workspace. Native-first on iOS
   * (the desktop gateway HTTP save-text endpoint isn't reliably reachable from
   * the mobile runtime and caused "Save failed (Load failed)"). Falls back to
   * the gateway path on desktop / web. Writes to the same path the transcript
   * loader and the journal-as-lens ranker read from.
   */
  async function persistTranscript(
    transcriptPath: string,
    text: string,
    token: string,
  ): Promise<boolean> {
    if (isNativeClient) {
      try {
        await saveJournalTextFile(transcriptPath, text);
        return true;
      } catch (nativeError) {
        // Native unavailable (older build) — fall through to gateway.
        if (!isMissingDesktopCommand(nativeError, "save_journal_text_file")) {
          // A genuine native write failure shouldn't be masked.
          return false;
        }
      }
    }
    try {
      await saveLibraryText(transcriptPath, text, token || undefined, gatewayBaseUrl);
      return true;
    } catch {
      return false;
    }
  }

  async function transcribeAfterSave(audioPath: string, entryId: string, token: string) {
    if (!audioPath) return;
    setJournalSaveStatus("Transcribing audio...");
    try {
      const result = await transcribeAudio(audioPath);
      if (result.text.trim()) {
        const transcriptText = result.text.trim();
        setJournalDraftText(transcriptText);
        // Persist the transcript to the workspace so it survives navigation
        // and reload. On-device Speech.framework only returns text (unlike the
        // server transcribe path, which writes this file internally), so write
        // it ourselves to the same path the loader reads from.
        const transcriptPath = journalTranscriptPathForMediaPath(audioPath);
        let persisted = false;
        try {
          persisted = await persistTranscript(transcriptPath, transcriptText, token);
        } catch {
          persisted = false;
        }
        setJournalSaveStatus(
          persisted
            ? `Transcribed: ${transcriptText.length} chars`
            : `Transcribed (not saved): ${transcriptText.length} chars`
        );
        setRecordingHint(`\u{1F3A4} Transcript ready (${transcriptText.split(/\s+/).length} words)`);
      } else {
        setJournalSaveStatus("No speech detected in recording.");
      }
    } catch (error) {
      const msg = error instanceof Error ? error.message : String(error);
      // Don't show error for non-iOS or when Speech is unavailable
      if (!msg.includes("only available on iOS")) {
        setJournalSaveStatus(`Transcription: ${msg}`);
      }
    }
  }

  // Import voice memos shared into the app via iOS file hand-off ("Copy to
  // SlowClaw" share sheet, or files dropped into the Files-app-visible
  // `Voice Memos` folder). Each imported memo is moved into the workspace
  // media inbox by the Rust side, then transcribed on-device and persisted as
  // a journal transcript — exactly like an in-app recording. Returns true when
  // one or more memos were imported (so callers can stay silent on foreground
  // auto-runs that find nothing new).
  async function importAndTranscribeVoiceMemos(
    options?: { silentIfEmpty?: boolean }
  ): Promise<boolean> {
    if (importingVoiceMemos) return false;
    setImportingVoiceMemos(true);
    try {
      const entries = await importVoiceMemos();
      if (entries.length === 0) {
        if (!options?.silentIfEmpty) {
          setJournalSaveStatus(
            "No new voice memos found. Share recordings from Voice Memos via “Copy to SlowClaw”, or drop .m4a files into SlowClaw → Voice Memos in the Files app."
          );
        }
        return false;
      }
      setJournalSaveStatus(
        `Imported ${entries.length} voice memo${entries.length > 1 ? "s" : ""}. Transcribing…`
      );
      let transcribed = 0;
      for (const entry of entries) {
        const audioPath = entry.filePath || "";
        if (!audioPath) continue;
        try {
          const result = await transcribeAudio(audioPath);
          const text = result.text.trim();
          if (text) {
            await persistTranscript(
              journalTranscriptPathForMediaPath(audioPath),
              text,
              chatGatewayToken,
            );
            transcribed += 1;
          }
        } catch {
          // Keep going: a single transcription failure shouldn't abort the
          // whole import. The audio entry still exists and can be retried.
        }
      }
      await refreshLibrary("journal");
      setJournalSaveStatus(
        `Imported ${entries.length} voice memo${entries.length > 1 ? "s" : ""} · transcribed ${transcribed}`
      );
      return true;
    } catch (error) {
      const msg = error instanceof Error ? error.message : String(error);
      setJournalSaveStatus(`Voice memo import failed: ${msg}`);
      return false;
    } finally {
      setImportingVoiceMemos(false);
    }
  }

  async function uploadJournalFile(file: File, kind: "audio" | "video") {
    let token = chatGatewayToken.trim();
    if (!gatewayBaseUrl.trim()) {
      setRecordingHint("Upload blocked (gateway URL missing). Pair mobile with desktop QR.");
      return;
    }
    if (!token && isNativeClient) {
      token = (await syncDesktopGatewayBootstrap())?.trim() || "";
    }
    if (!token) {
      if (isNativeClient) {
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
          } else if (kind === "audio" && isTauriMobileRuntime()) {
            // No server-side transcription — use on-device Speech.framework
            void transcribeAfterSave(uploadedPath, "", token || "");
          }
        }
      } catch (gatewayError) {
        if (!isNativeClient) {
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
          // Auto-transcribe audio on iOS
          if (kind === "audio" && isTauriMobileRuntime()) {
            void transcribeAfterSave(saved.filePath || "", saved.id, token || "");
          }
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
    if (!token && isNativeClient) {
      token = normalizeGatewayToken((await syncDesktopGatewayBootstrap()) || "");
    }
    if (!token && !isNativeClient) {
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
            if (!isNativeClient) {
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
        // Native-first (iOS): the gateway save-text endpoint isn't reliably
        // reachable from the mobile runtime and produced "Save failed (Load
        // failed)". persistTranscript handles native-first + gateway fallback.
        await persistTranscript(draftPath, content, token);
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
          if (!isNativeClient) {
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

  // ── Done button handler: save → AI title → rename → generate posts → extract tasks ──
  async function handleJournalDone() {
    // 1. Save first (in case autosave hasn't fired)
    await saveJournalTextDraft();

    const content = journalDraftText.trim();
    if (!content || content.length < 10) {
      setIsWritingNote(false);
      return;
    }

    const currentPath = selectedJournalPathRef.current.trim();
    const localId = currentPath ? localJournalIdFromPath(currentPath) : null;

    // 2. Generate AI title
    if (isTauriMobileRuntime() && nativeLocalAiStatus?.available && localId) {
      try {
        holdJournalStatus("Generating title...");
        const titleResult = await nativeAiChat(
          content.slice(0, 1500),
          "Generate a short, descriptive title (3-7 words) for this journal entry. Output ONLY the title text, nothing else. No quotes, no punctuation at start/end.",
          32,
          0.3
        );
        const aiTitle = titleResult.text
          .replace(/^["'`]+|["'`]+$/g, "")
          .replace(/\n.*/s, "")
          .trim();
        if (aiTitle && aiTitle.length >= 3 && aiTitle.length <= 80) {
          try {
            const renamed = await renameJournal(localId, aiTitle);
            selectedJournalPathRef.current = `local://journals/${renamed.id}`;
            setSelectedJournalPath(`local://journals/${renamed.id}`);
            holdJournalStatus(`Titled: ${aiTitle}`);
          } catch {
            // Rename failed — non-fatal, continue with processing
          }
        }
      } catch (error) {
        // AI title generation failed — surface the real reason. The Rust
        // native_ai_chat command returns load/inference failures as Err, which
        // used to be silently swallowed here (the user saw "nothing happened").
        const detail = error instanceof Error ? error.message : String(error);
        holdJournalStatus(`AI title failed: ${detail.slice(0, 140)}`, 8000);
      }
    }

    // 3. Generate posts from this entry
    if (isTauriMobileRuntime() && nativeLocalAiStatus?.available) {
      try {
        setGeneratePostBusy(true);
        setGeneratePostStatus("✨ Generating posts...");
        const existingTexts = persistedPosts.slice(0, 10).map((p) => p.text);
        const dedupeInstruction = existingTexts.length > 0
          ? `\nDo NOT generate anything similar to these existing posts:\n${existingTexts.map((t, i) => `${i + 1}. ${t}`).join("\n")}\n`
          : "";
        const chunks = splitIntoChunks(content, CHUNK_CHAR_LIMIT);
        const posts: string[] = [];
        for (const chunk of chunks) {
          for (let attempt = 0; attempt < 3; attempt++) {
            const result = await nativeAiChat(
              chunk,
              `${tweetClawPrompt} Turn this into 1-2 posts. Output a JSON array of strings. Output ONLY valid JSON, no markdown fences.${dedupeInstruction}`,
              512,
              0.3 + attempt * 0.1
            );
            const parsed = tryParseJsonArray<string>(result.text);
            if (parsed && parsed.length > 0) {
              posts.push(...parsed.filter((t) => typeof t === "string" && t.trim()));
              break;
            }
          }
        }
        if (posts.length > 0) {
          const newPosts: PersistedPost[] = posts.map((t) => ({
            id: `post_${Date.now()}_${Math.random().toString(36).slice(2, 8)}`,
            text: t.trim(),
            sourceExcerpt: content.slice(0, 100),
            createdAt: Date.now(),
          }));
          setPersistedPosts((prev) => { const next = [...newPosts, ...prev]; savePersistedPosts(next); return next; });
          setGeneratePostStatus(`✨ Generated ${posts.length} post${posts.length > 1 ? 's' : ''}`);
        } else {
          // Model ran but produced no usable output — surface it instead of silence.
          setGeneratePostStatus("Model produced no output. It may need re-downloading (Settings → Delete Model).");
        }
      } catch (error) {
        // Post generation failed — surface the real reason instead of swallowing.
        const detail = error instanceof Error ? error.message : String(error);
        setGeneratePostStatus(`Generation failed: ${detail.slice(0, 200)}`);
      } finally {
        setGeneratePostBusy(false);
      }
    }

    // 4. Extract tasks from this entry
    if (isTauriMobileRuntime() && nativeLocalAiStatus?.available) {
      try {
        setExtractingLocalTasks(true);
        const existingTitles = persistedTodos.slice(0, 10).map((t) => t.title);
        const dedupeInstruction = existingTitles.length > 0
          ? `\nDo NOT extract tasks similar to these existing ones:\n${existingTitles.map((t, i) => `${i + 1}. ${t}`).join("\n")}\n`
          : "";
        const taskPrompt = `You extract action items and tasks from journal entries. Output a JSON array of objects with "title" and "details" fields. Only real actionable tasks. Output ONLY valid JSON, no markdown fences. Example: [{"title":"Buy groceries","details":"Need milk and eggs"}]${dedupeInstruction}`;
        const chunks = splitIntoChunks(content, CHUNK_CHAR_LIMIT);
        const allParsed: Array<{ title: string; details?: string }> = [];
        for (const chunk of chunks) {
          for (let attempt = 0; attempt < 3; attempt++) {
            const result = await nativeAiChat(chunk, taskPrompt, 512, 0.2 + attempt * 0.1);
            const parsed = tryParseJsonArray<{ title: string; details?: string }>(result.text);
            if (parsed && parsed.length > 0) { allParsed.push(...parsed); break; }
            if (attempt === 2) {
              const lines = result.text.split("\n").filter((l) => /^\s*[-*\d.]/.test(l));
              allParsed.push(...lines.map((l) => ({ title: l.replace(/^\s*[-*\d.]+\s*/, "").trim() })));
            }
          }
        }
        if (allParsed.length > 0) {
          const newTodos: PersistedTodo[] = allParsed
            .filter((t) => t.title?.trim())
            .map((t) => ({
              id: `todo_${Date.now()}_${Math.random().toString(36).slice(2, 8)}`,
              title: t.title.trim(),
              details: (t.details || "").trim(),
              done: false,
              createdAt: Date.now(),
            }));
          setPersistedTodos((prev) => {
            const existingSet = new Set(prev.map((t) => t.title.toLowerCase()));
            const unique = newTodos.filter((t) => !existingSet.has(t.title.toLowerCase()));
            const next = [...unique, ...prev]; savePersistedTodos(next); return next;
          });
        }
      } catch (error) {
        // Task extraction failed — surface the real reason instead of swallowing.
        const detail = error instanceof Error ? error.message : String(error);
        setGeneratePostStatus(`Task extraction failed: ${detail.slice(0, 200)}`);
      } finally {
        setExtractingLocalTasks(false);
      }
    }

    // 4.5. Extract interest keywords → feed (aggressive register bridge)
    if (isTauriMobileRuntime() && nativeLocalAiStatus?.available && localId) {
      try {
        holdJournalStatus("Extracting interests...");
        const interestPrompt = `You extract the author's interests from a personal journal entry.
Translate the author's private, personal phrasing into PUBLIC vocabulary that news feeds, hashtags, and search engines actually use (e.g. "should move somewhere quieter near water" → "urbanism, slow living"; "third places like the corner cafe" → "third places, cafe culture, morning rituals"; "read the Medici book" → "Renaissance history, history of banking"). Bridge aggressively so the keywords can match real feed content.
Rules:
- Output a JSON array of short lowercase keyword phrases (1-3 words each).
- 4-10 keywords. Prefer concrete subject-matter topics over moods.
- DO NOT infer emotional, mental-health, or wellness framings (depression, burnout, anxiety, insomnia, self-care) UNLESS the entry substantively engages with that topic as a named interest — a single mention of poor sleep or feeling low is not a mental-health interest.
- No generic filler ("life", "thoughts", "journal"). No quotes. Output ONLY valid JSON, no markdown fences.`;
        const interestResult = await nativeAiChat(content.slice(0, 2400), interestPrompt, 160, 0.3);
        const interestKeywords = tryParseJsonArray<string>(interestResult.text)
          ?.filter((k) => typeof k === "string" && k.trim())
          .map((k) => k.trim().toLowerCase())
          .slice(0, 10);
        if (interestKeywords && interestKeywords.length > 0) {
          // Short stable fingerprint of the text at extraction time. A fresh
          // hash defeats the feed's profile_input_hash cache short-circuit so
          // the new keywords always take effect on the next feed load.
          const hash = String(
            content
              .slice(0, 2400)
              .split("")
              .reduce((h, c) => (h * 31 + c.charCodeAt(0)) >>> 0, 7),
          );
          await saveJournalInterestKeywords(localId, interestKeywords, hash);
          holdJournalStatus(
            `Added ${interestKeywords.length} interest${interestKeywords.length > 1 ? "s" : ""} to feed`,
          );
          // Surface the magic: reveal the extracted keywords inline so the user
          // can see — and correct — what the on-device AI inferred from their
          // writing. Drives the interest-reveal card in the Journal tab.
          setLastExtractedInterests(interestKeywords);
          setLastInterestJournalId(localId);
          setDismissedInterestReveal(false);
        }
      } catch (error) {
        // Interest extraction failed — surface the real reason instead of
        // swallowing. This is especially important because nativeAiChat can
        // fail at model load / inference time even when Settings says "ready".
        const detail = error instanceof Error ? error.message : String(error);
        holdJournalStatus(`Interests failed: ${detail.slice(0, 140)}`, 8000);
      }
    }

    // 5. Mark as processed and close
    if (currentPath) {
      markJournalProcessed(currentPath);
    }
    setIsWritingNote(false);
    setShowFirstEntryPrompt(false);
    await refreshLibrary("journal");
  }

  async function deleteJournalItem(item: LibraryItem) {
    const localId = localJournalIdFromPath(item.path);
    if (localId && isNativeClient) {
      setJournalSaveStatus(`Deleting ${item.title}...`);
      try {
        await deleteJournal(localId);
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
      return;
    }

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

  // Load a saved journal audio recording's bytes for inline playback.
  // Native clients only: recordings live on the device; the browser/preview
  // client has no local file access. The object URL is revoked on change to
  // avoid leaks.
  useEffect(() => {
    const prevUrl = audioPlaybackUrlRef.current;
    if (prevUrl) {
      URL.revokeObjectURL(prevUrl);
      audioPlaybackUrlRef.current = "";
    }
    setAudioPlaybackUrl("");
    const item = selectedJournalItem;
    if (!isNativeClient || !item || item.kind !== "audio") {
      setAudioPlaybackLoading(false);
      return;
    }
    const journalId = localJournalIdFromPath(item.path) || item.path;
    let cancelled = false;
    setAudioPlaybackLoading(true);
    readJournalMediaBytes(journalId)
      .then(({ dataB64, mimeType }) => {
        if (cancelled) return;
        const mime = mimeType || inferMediaMimeType(item.path, "audio");
        const url = URL.createObjectURL(base64ToBlob(dataB64, mime));
        audioPlaybackUrlRef.current = url;
        setAudioPlaybackUrl(url);
      })
      .catch(() => {
        // Reading failed (e.g. file moved) — player simply stays hidden.
      })
      .finally(() => {
        if (!cancelled) setAudioPlaybackLoading(false);
      });
    return () => {
      cancelled = true;
    };
  }, [selectedJournalItem?.path, selectedJournalItem?.kind, isNativeClient]);

  async function transcribeSelectedJournalMedia() {
    if (!selectedJournalItem || selectedJournalItem.kind !== "audio") {
      return;
    }
    // On iOS (native mobile), the gateway reports no CLI-based media tools, but
    // on-device Speech.framework transcription is available. Transcribe the
    // selected entry by its workspace-relative id instead of the gateway path,
    // which would otherwise be blocked with "No local media tools...".
    if (isTauriMobileRuntime()) {
      let token = chatGatewayToken.trim();
      if (!token && isNativeClient) {
        token = normalizeGatewayToken((await syncDesktopGatewayBootstrap()) || "");
      }
      const journalId =
        localJournalIdFromPath(selectedJournalItem.path) || selectedJournalItem.path;
      setJournalTranscribing(true);
      setJournalTranscriptionStatusByPath((prev) => ({
        ...prev,
        [selectedJournalItem.path]: "running"
      }));
      setJournalSaveStatus("Transcribing audio...");
      try {
        const result = await transcribeJournalMediaNative(journalId);
        const transcriptText = (result.text || "").trim();
        if (transcriptText) {
          const transcriptPath = journalTranscriptPathForMedia(selectedJournalItem);
          // Persist the transcript to the workspace so it survives navigation
          // and reload (see transcribeAfterSave for rationale).
          let persisted = true;
          try {
            await saveLibraryText(transcriptPath, transcriptText, token || undefined, gatewayBaseUrl);
          } catch {
            persisted = false;
          }
          setJournalTranscriptionStatusByPath((prev) => ({
            ...prev,
            [selectedJournalItem.path]: "done"
          }));
          loadedTextPathRef.current = transcriptPath;
          setSelectedJournalText(transcriptText);
          setJournalDraftText(transcriptText);
          setJournalSaveStatus(
            persisted
              ? `Transcribed: ${transcriptText.length} chars`
              : `Transcribed (not saved): ${transcriptText.length} chars`
          );
        } else {
          setJournalTranscriptionStatusByPath((prev) => ({
            ...prev,
            [selectedJournalItem.path]: "error"
          }));
          setJournalSaveStatus("No speech detected in recording.");
        }
      } catch (error) {
        const msg = error instanceof Error ? error.message : String(error);
        setJournalTranscriptionStatusByPath((prev) => ({
          ...prev,
          [selectedJournalItem.path]: "error"
        }));
        setJournalSaveStatus(`Transcription: ${msg}`);
      } finally {
        setJournalTranscribing(false);
      }
      return;
    }
    if (runtimeMediaCapabilities && !runtimeMediaCapabilities.transcribeMedia) {
      setJournalSaveStatus(
        runtimeMediaSummary || "Local transcription is unavailable on this device."
      );
      return;
    }
    let token = chatGatewayToken.trim();
    if (!token && isNativeClient) {
      token = (await syncDesktopGatewayBootstrap())?.trim() || "";
    }
    if (!token && !isNativeClient) {
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
        let content: string;
        if (localId && localId.startsWith("dev-journal-")) {
          // Dev/demo sample journals aren't backed by storage — use their in-memory
          // preview text so clicking a sample note shows content (not an empty editor).
          content = item.previewText || "";
        } else if (localId) {
          content = (await getJournal(localId)).content || "";
        } else {
          content = await readLibraryText(item.path, token, gatewayBaseUrl);
        }
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

  async function importFromGallery() {
    try {
      const input = document.createElement("input");
      input.type = "file";
      input.accept = "image/*,video/*";
      input.multiple = false;
      input.style.display = "none";
      document.body.appendChild(input);

      const file = await new Promise<File | null>((resolve) => {
        input.onchange = () => resolve(input.files?.[0] ?? null);
        input.oncancel = () => resolve(null);
        input.click();
        // Fallback timeout for when oncancel doesn't fire
        setTimeout(() => {
          if (!input.files?.length) resolve(null);
        }, 120_000);
      });
      document.body.removeChild(input);

      if (!file) return;

      const kind = file.type.startsWith("video/") ? "video"
        : file.type.startsWith("image/") ? "image"
        : file.type.startsWith("audio/") ? "audio"
        : null;
      if (!kind) {
        setRecordingHint("Unsupported file type. Choose a photo or video.");
        return;
      }

      setRecordingHint("Importing from gallery...");
      const reader = new FileReader();
      const dataUrl: string = await new Promise((resolve, reject) => {
        reader.onload = () => resolve(reader.result as string);
        reader.onerror = () => reject(reader.error);
        reader.readAsDataURL(file);
      });

      const base64 = dataUrl.split(",")[1] || "";
      const saved = await saveJournalMedia(
        kind as "audio" | "video" | "image",
        file.name,
        base64,
        file.name.replace(/\.[^.]+$/, "")
      );
      setRecordingHint(`Imported ${saved.title || file.name}`);
      await refreshLibrary("journal");
    } catch (error) {
      setRecordingHint(
        `Import failed: ${error instanceof Error ? error.message : String(error)}`
      );
    }
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

      if (type === "audio" && isMobileRuntime && hasNativeAudioRecorderPlugin()) {
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
        hint = isTauriMobileRuntime()
          ? `${device} API is unavailable in this iOS WebView. A native recorder plugin is needed for reliable mobile recording.`
          : `${device} API is unavailable. On macOS, open System Settings → Privacy & Security → ${device} and ensure this app is allowed.`;
      } else if (err instanceof DOMException) {
        switch (err.name) {
          case "NotAllowedError":
          case "PermissionDeniedError":
            hint = isTauriMobileRuntime()
              ? `${device} access was denied. Open iPhone Settings → SlowClaw and allow ${device.toLowerCase()} access.`
              : `${device} access was denied. Please allow ${device.toLowerCase()} permission in System Settings → Privacy & Security.`;
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
    if (recordingType === "audio" && isTauriMobileRuntime() && hasNativeAudioRecorderPlugin() && !mediaRecorderRef.current) {
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
    if (recordingType === "audio" && isTauriMobileRuntime() && hasNativeAudioRecorderPlugin() && !mediaRecorderRef.current) {
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
      const keys = nostrModule.generateNostrKeys();
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
    if (useNostrLocalStore) {
      // Sign + publish via the Rust ingester's persistent client. The ingester
      // also ingests our own event so the like count updates instantly.
      const result = await nostrPublishReaction(eventId, "+");
      if (result?.published) {
        // Optimistically bump the local reaction count.
        setNostrReactions((prev) => ({ ...prev, [eventId]: (prev[eventId] ?? 0) + 1 }));
      }
      return;
    }
    const keys = await ensureNostrKeys();
    if (!keys) return;
    try {
      const nostrModule = await import("./lib/nostr");
      const event = await nostrModule.createSignedEvent(keys.secretKeyHex, 7, "+", [["e", eventId], ["p", ""]]);
      await nostrModule.publishToRelay(relayUrl, event);
    } catch (err) {
      console.error("Nostr reaction failed:", err);
    }
  }

  async function handleNostrReply(eventId: string, relayUrl: string, content: string) {
    if (!content.trim()) return;
    if (useNostrLocalStore) {
      const result = await nostrPublishReply(eventId, relayUrl, content.trim());
      if (result?.published) {
        // Optimistically show the reply inline.
        setNostrReplyThreads((prev) => ({
          ...prev,
          [eventId]: [...(prev[eventId] ?? [])],
        }));
      }
      return;
    }
    const keys = await ensureNostrKeys();
    if (!keys) return;
    try {
      const nostrModule = await import("./lib/nostr");
      const event = await nostrModule.createSignedEvent(keys.secretKeyHex, 1, content.trim(), [["e", eventId, relayUrl, "reply"]]);
      await nostrModule.publishToRelay(relayUrl, event);
    } catch (err) {
      console.error("Nostr reply failed:", err);
    }
  }

  async function fetchVideoFallback() {
    if (videoFallbackLoading || videoFallbackItems.length > 0) return;
    setVideoFallbackLoading(true);
    const results: any[] = [];

    // Local-first: render cached videos instantly before the network fan-out.
    // The Media tab mixes Bluesky + Nostr, so we read both sources from the
    // store and reconstruct the per-source item shapes the renderer expects.
    if (useVideoLocalStore) {
      try {
        const cached = await videoQueryRaw({ limit: 40 });
        for (const rec of cached) {
          if (rec.source === "bluesky" && rec.raw_json && rec.raw_json !== "{}") {
            try {
              const post = JSON.parse(rec.raw_json);
              if (post?.uri) results.push({ source: "bluesky", post, feedItem: { post } });
            } catch {}
          } else if (rec.source === "nostr" && rec.raw_json && rec.raw_json !== "{}") {
            try {
              const event = JSON.parse(rec.raw_json);
              results.push({ source: "nostr", event, relayUrl: "wss://relay.primal.net" });
            } catch {}
          }
        }
        // Show cached items immediately; the network refresh below will replace.
        if (results.length > 0) setVideoFallbackItems(results);
      } catch {
        // Non-fatal: fall through to the network fetch.
      }
    }

    const fresh: any[] = [];
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
            const blueskyPosts: any[] = [];
            for (const entry of feed) {
              const post = entry?.post;
              if (!post) continue;
              const embed = post.embed;
              if (embed?.$type === "app.bsky.embed.video#view" ||
                  (embed?.$type === "app.bsky.embed.recordWithMedia#view" && embed?.media?.$type === "app.bsky.embed.video#view")) {
                fresh.push({ source: "bluesky", post, feedItem: entry });
                blueskyPosts.push(post);
              }
            }
            // Persist fresh Bluesky posts for the next tab-open.
            if (useVideoLocalStore && blueskyPosts.length > 0) {
              void videoUpsertBluesky(blueskyPosts);
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
          fresh.push({ source: "nostr", event: ev, relayUrl: "wss://relay.primal.net" });
        }
      } catch (err) {
        console.warn("Nostr video fallback failed:", err);
      }
    } finally {
      // Prefer the fresh network results when available; otherwise keep cache.
      setVideoFallbackItems(fresh.length > 0 ? fresh : results);
      setVideoFallbackLoading(false);
    }
  }

  // ── First-run onboarding handlers ─────────────────────────────────────────
  // dismissWelcome closes the one-time overlay. When goToJournal is true (the
  // primary CTA), it routes the user into the Journal composer with warm copy.
  function dismissWelcome(goToJournal: boolean) {
    if (typeof window !== "undefined") {
      window.localStorage.setItem(ONBOARDING_SEEN_KEY, "1");
    }
    setShowWelcome(false);
    if (goToJournal) {
      setMobileTab("journal");
      setShowFirstEntryPrompt(true);
    } else if (mobileTab === "journal") {
      // They dismissed while already on the Journal tab (the capture-first
      // default): still warm the composer copy so the first run feels guided.
      setShowFirstEntryPrompt(true);
    }
  }

  // removeRevealedInterest drops one chip from the inline reveal card and
  // persists the trimmed keyword set back to the journal's triage keywords,
  // then refreshes the world-feed interest profile. Non-fatal on failure.
  //
  // v1 edge case (noted, accepted): removing *every* keyword leaves the source
  // with no triage keywords, so the feed's heuristic text extractor will
  // refill the profile from the raw journal text on the next rebuild. The
  // common case — removing one or two of several — persists correctly.
  async function removeRevealedInterest(keyword: string) {
    const journalId = lastInterestJournalId;
    if (!journalId) return;
    const remaining = lastExtractedInterests.filter((k) => k !== keyword);
    setLastExtractedInterests(remaining);
    if (remaining.length === 0) {
      setDismissedInterestReveal(true);
    }
    try {
      // Fresh hash defeats the feed's profile_input_hash cache short-circuit so
      // the trimmed keywords take effect on the next feed load.
      const hash = String(
        remaining.join(",").split("").reduce((h, c) => (h * 31 + c.charCodeAt(0)) >>> 0, 7),
      );
      await saveJournalInterestKeywords(journalId, remaining, hash);
      await loadWorldFeedInterests();
    } catch {
      // Non-fatal: the chip is already removed from the UI; the persisted
      // keyword set will reconcile on the next journal save.
    }
  }

  // seePersonalizedFeed dismisses the reveal and jumps to the Feed. Nostr works
  // account-free and is interest-matchable, so it gives the best shot at a
  // populated, personalized first Feed even before the user links Bluesky.
  function seePersonalizedFeed() {
    setDismissedInterestReveal(true);
    setShowFirstEntryPrompt(false);
    setMobileTab("feed");
    setSocialSource("nostr");
    void loadNostrFeed();
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
    if (mobileTab !== "queue") {
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
      // On iOS, a return-to-foreground is the moment shared voice memos land in
      // the app's Inbox. Import + transcribe them silently when new files exist.
      if (isTauriMobileRuntime()) {
        void importAndTranscribeVoiceMemos({ silentIfEmpty: true });
      }
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
    if (!isNativeClient) {
      return null;
    }
    try {
      const info = await invokeDesktopCommandStrict<DesktopGatewayInfo>("get_embedded_gateway_info");
      if (!info.running) {
        await restartGatewayDaemonFromDesktop();
      }
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
    if (!isNativeClient) {
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
    const normalizedProvider = normalizeProviderId(settingsProvider);
    setProviderApiKeyStatus(trimmed ? "Saving API key..." : "Clearing API key...");
    try {
      if (isDesktopClient) {
        if (trimmed) {
          await invokeDesktopCommandStrict("set_secret", {
            req: {
              service: DESKTOP_SECRET_SERVICE,
              account: PROVIDER_API_KEY_SECRET_ACCOUNT,
              value: trimmed,
            },
          });
        } else {
          await invokeDesktopCommandStrict("delete_secret", {
            req: {
              service: DESKTOP_SECRET_SERVICE,
              account: PROVIDER_API_KEY_SECRET_ACCOUNT,
            },
          });
        }
      }

      let token = normalizeGatewayToken(chatGatewayToken);
      if (!token && isDesktopClient) {
        token = normalizeGatewayToken((await syncDesktopGatewayBootstrap()) || "");
      }

      // Send API key via HTTP so the running gateway sees it immediately
      await updateRuntimeConfig(
        {
          defaultProvider: normalizedProvider,
          defaultModel: settingsModel,
          apiUrl: settingsApiUrl.trim(),
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
        await restartGatewayDaemonFromDesktop();
      }

      setProviderApiKeyStatus(
        trimmed
          ? "API key saved."
          : "API key cleared."
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
            setSettingsModel("openrouter/free");
            setSettingsApiUrl("");
            window.localStorage.setItem(CHAT_PROVIDER_STORAGE_KEY, "openrouter");
            window.localStorage.setItem(CHAT_MODEL_STORAGE_KEY, "openrouter/free");
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
      if (isDesktopClient) {
        await invokeDesktopCommandStrict("set_secret", {
          req: {
            service: DESKTOP_SECRET_SERVICE,
            account: OPENROUTER_API_KEY_SECRET_ACCOUNT,
            value: trimmed,
          },
        });
        const existingGenericSecret = await invokeDesktopCommand<{ value: string | null }>("get_secret", {
          req: { service: DESKTOP_SECRET_SERVICE, account: PROVIDER_API_KEY_SECRET_ACCOUNT }
        });
        if (String(existingGenericSecret?.value || "").trim().startsWith("sk-or-")) {
          await invokeDesktopCommandStrict("delete_secret", {
            req: {
              service: DESKTOP_SECRET_SERVICE,
              account: PROVIDER_API_KEY_SECRET_ACCOUNT,
            },
          });
        }
      }

      let token = normalizeGatewayToken(chatGatewayToken);
      if (!token && isDesktopClient) {
        token = normalizeGatewayToken((await syncDesktopGatewayBootstrap()) || "");
      }

      await updateRuntimeConfig(
        {
          defaultProvider: "openrouter",
          defaultModel: "openrouter/free",
          apiUrl: "",
          transcriptionEnabled: settingsTranscriptionEnabled,
          transcriptionModel: settingsTranscriptionModel || "",
          availableTranscriptionModels: settingsAvailableTranscriptionModels,
        },
        token || undefined,
        gatewayBaseUrl
      );

      setSettingsProvider("openrouter");
      setSettingsModel("openrouter/free");
      setProviderApiKey("");
      setProviderApiKeyStatus("");
      window.localStorage.setItem(CHAT_PROVIDER_STORAGE_KEY, "openrouter");
      window.localStorage.setItem(CHAT_MODEL_STORAGE_KEY, "openrouter/free");
      setOpenrouterApiKeyInput("");
      if (isDesktopClient) {
        await restartGatewayDaemonFromDesktop();
      }
      await refreshWorkspaceSynthAfterProviderSetup();

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

  async function resolveRuntimeGatewayToken() {
    let token = normalizeGatewayToken(chatGatewayToken);
    if (!token && isDesktopClient) {
      token = normalizeGatewayToken((await syncDesktopGatewayBootstrap()) || "");
    }
    return token;
  }

  async function loadLocalModels() {
    // On iOS native, the model catalog lives on the gateway (localhost:42617).
    // After app resume, the gateway may need a moment to restart.
    // Always check native AI status independently of gateway availability.
    if (isTauriMobileRuntime()) {
      try {
        const status = await getNativeLocalAiStatus();
        setNativeLocalAiStatus(status);
      } catch {
        // Non-fatal — native status unavailable but don't wipe
      }
    }
    if (!gatewayBaseUrl.trim()) {
      // Even without gateway, native AI status was already checked above
      if (!nativeLocalAiStatus?.configured) {
        setLocalModels([]);
        setLocalModelsStatus("Local model catalog unavailable (gateway URL missing).");
        setLocalModelsEngineStatus("");
      }
      return;
    }
    try {
      const token = await resolveRuntimeGatewayToken();
      const response = await getLocalModels(token || undefined, gatewayBaseUrl);
      setLocalModels(response.models);
      setLocalModelsEngineStatus(response.engineStatus || "");
      setLocalModelRuntime(response.runtime || null);
      if (isTauriMobileRuntime()) {
        try {
          setNativeLocalAiStatus(await getNativeLocalAiStatus());
        } catch {
          // Already set above, keep existing value
        }
      }
      setLocalModelsStatus(response.models.length ? "" : "No local models are available yet.");
    } catch (error) {
      // Gateway unreachable — but don't wipe native AI status if it was already set
      setLocalModels([]);
      setLocalModelsEngineStatus("");
      setLocalModelRuntime(null);
      // Only wipe native status if we don't already have a valid one
      if (!nativeLocalAiStatus?.configured) {
        setLocalModelsStatus(
          `Local models unavailable (${error instanceof Error ? error.message : String(error)})`
        );
      } else {
        // Native AI is configured but gateway is down — still usable for inference
        setLocalModelsStatus("");
      }
    }
  }

  async function startLocalModelDownload(modelId: string) {
    setLocalModelBusyId(modelId);
    setLocalModelsStatus("Starting model download...");
    try {
      const token = await resolveRuntimeGatewayToken();
      await downloadLocalModel(modelId, token || undefined, gatewayBaseUrl);
      setLocalModelsStatus("Download started. Keep the app open while the model downloads.");
      await loadLocalModels();
    } catch (error) {
      setLocalModelsStatus(
        `Download failed to start (${error instanceof Error ? error.message : String(error)})`
      );
    } finally {
      setLocalModelBusyId("");
    }
  }

  async function selectLocalModel(modelId: string) {
    setLocalModelBusyId(modelId);
    setLocalModelsStatus("Selecting local model...");
    try {
      const token = await resolveRuntimeGatewayToken();
      const result = await useLocalModel(modelId, token || undefined, gatewayBaseUrl);
      setSettingsProvider(String(result.defaultProvider || "llamacpp"));
      setSettingsModel(String(result.defaultModel || modelId));
      setSettingsApiUrl(String(result.apiUrl || "http://127.0.0.1:8080/v1"));
      if (isNativeClient) {
        await restartGatewayDaemonFromDesktop();
      }
      setLocalModelsStatus("Local model selected. Runtime engine integration is the next step.");
      await loadLocalModels();
    } catch (error) {
      setLocalModelsStatus(
        `Could not select model (${error instanceof Error ? error.message : String(error)})`
      );
    } finally {
      setLocalModelBusyId("");
    }
  }

  async function refreshLocalModelRuntime() {
    try {
      const token = await resolveRuntimeGatewayToken();
      const runtime = await getLocalModelRuntime(token || undefined, gatewayBaseUrl);
      setLocalModelRuntime(runtime);
      if (runtime.error) {
        setLocalModelsStatus(runtime.error);
      }
    } catch (error) {
      setLocalModelsStatus(
        `Runtime status unavailable (${error instanceof Error ? error.message : String(error)})`
      );
    }
  }

  async function startDownloadedLocalModel(modelId: string) {
    setLocalModelBusyId(modelId);
    setLocalModelsStatus("Starting local model runtime...");
    try {
      if (isTauriMobileRuntime()) {
        const model = localModels.find((item) => item.id === modelId);
        if (!model?.path) {
          throw new Error("Downloaded model path is missing. Refresh the model list and try again.");
        }
        const status = await configureNativeLocalAi(modelId, model.path);
        setNativeLocalAiStatus(status);
        setSettingsProvider(status.provider || "slowclaw-local");
        setSettingsModel(status.modelId || modelId);
        setSettingsApiUrl(status.apiUrl || "slowclaw-native://local");
        setLocalModelsStatus(status.message || "Native local AI bridge configured.");
        await loadLocalModels();
        return;
      }

      const token = await resolveRuntimeGatewayToken();
      const runtime = await startLocalModelRuntime(modelId, token || undefined, gatewayBaseUrl);
      setLocalModelRuntime(runtime);
      setSettingsProvider("llamacpp");
      setSettingsModel(runtime.modelId || modelId);
      setSettingsApiUrl(runtime.apiUrl || "http://127.0.0.1:8080/v1");
      setLocalModelsStatus(
        runtime.running
          ? "Local model runtime is running. SlowClaw saved it as the active local model."
          : runtime.error || "Runtime is not available yet."
      );
      await loadLocalModels();
    } catch (error) {
      setLocalModelsStatus(
        `Could not start runtime (${error instanceof Error ? error.message : String(error)})`
      );
    } finally {
      setLocalModelBusyId("");
    }
  }

  async function stopDownloadedLocalModel() {
    setLocalModelsStatus("Stopping local model runtime...");
    try {
      const token = await resolveRuntimeGatewayToken();
      const runtime = await stopLocalModelRuntime(token || undefined, gatewayBaseUrl);
      setLocalModelRuntime(runtime);
      setLocalModelsStatus("Local model runtime stopped.");
      await loadLocalModels();
    } catch (error) {
      setLocalModelsStatus(
        `Could not stop runtime (${error instanceof Error ? error.message : String(error)})`
      );
    }
  }

  // ── AI inference helpers ──────────────────────────────────────────────────
  // Context ~1536 tokens on iPhone. System prompt ~150 tokens, gen ~256–512.
  // ~800-1000 user tokens ≈ ~3200 chars. Chunk longer notes.
  // (CHUNK_CHAR_LIMIT moved to module scope for hoisting)

  function splitIntoChunks(text: string, limit: number): string[] {
    if (text.length <= limit) return [text];
    const chunks: string[] = [];
    let remaining = text;
    while (remaining.length > 0) {
      if (remaining.length <= limit) { chunks.push(remaining); break; }
      let splitAt = remaining.lastIndexOf('\n\n', limit);
      if (splitAt < limit * 0.3) splitAt = remaining.lastIndexOf('. ', limit);
      if (splitAt < limit * 0.3) splitAt = remaining.lastIndexOf(' ', limit);
      if (splitAt < limit * 0.3) splitAt = limit;
      chunks.push(remaining.slice(0, splitAt + 1).trim());
      remaining = remaining.slice(splitAt + 1).trim();
    }
    return chunks;
  }

  /** Try to parse JSON from AI output with multiple format recovery attempts */
  function tryParseJsonArray<T>(raw: string): T[] | null {
    // Strip markdown fences
    let cleaned = raw.replace(/^```(?:json)?\s*\n?/i, "").replace(/\n?```\s*$/m, "").trim();
    // Try direct parse
    try { const r = JSON.parse(cleaned); if (Array.isArray(r)) return r; } catch {}
    // Try extracting first [...] block
    const bracketMatch = cleaned.match(/\[\s*\{[\s\S]*\}\s*\]/);
    if (bracketMatch) {
      try { const r = JSON.parse(bracketMatch[0]); if (Array.isArray(r)) return r; } catch {}
    }
    // Try line-by-line JSON objects  {"title":...}
    const objLines = cleaned.split('\n').filter((l) => l.trim().startsWith('{'));
    if (objLines.length > 0) {
      const arr: T[] = [];
      for (const line of objLines) {
        try { arr.push(JSON.parse(line.replace(/,\s*$/, ''))); } catch {}
      }
      if (arr.length > 0) return arr;
    }
    return null;
  }

  function requireModel(): boolean {
    const hasModel = localModels.some((m) => m.installed) || nativeLocalAiStatus?.configured;
    if (!hasModel) {
      setGeneratePostStatus("No AI model downloaded. Tap the \u2699\uFE0F gear icon to download one.");
      return false;
    }
    return true;
  }

  async function generatePostFromJournal() {
    const content = journalDraftText.trim();
    if (!content) { setGeneratePostStatus("Write or select a journal entry first."); return; }
    if (!requireModel()) return;
    setGeneratePostBusy(true);
    setGeneratePostStatus("Generating posts with local AI...");
    setGeneratedPost("");
    try {
      let posts: string[] = [];
      if (isTauriMobileRuntime()) {
        const chunks = splitIntoChunks(content, CHUNK_CHAR_LIMIT);
        // Each chunk generates its own tweet-style post (multiple posts from long notes)
        for (let i = 0; i < chunks.length; i++) {
          if (chunks.length > 1) setGeneratePostStatus(`Generating post ${i + 1}/${chunks.length}...`);
          // Retry up to 3 times for each chunk
          let postText = "";
          for (let attempt = 0; attempt < 3; attempt++) {
            const result = await nativeAiChat(
              chunks[i],
              tweetClawPrompt,
              256,
              0.8 + attempt * 0.1 // slightly vary temperature on retry
            );
            postText = result.text.replace(/^["']|["']$/g, '').trim();
            if (postText.length > 10 && postText.length < 400) break; // good output
          }
          if (postText) posts.push(postText);
        }
        setGeneratePostStatus(`Generated ${posts.length} post${posts.length > 1 ? 's' : ''}`);
      } else {
        const token = await resolveRuntimeGatewayToken();
        const response = await fetch(`${gatewayBaseUrl || ""}/api/chat/messages`, {
          method: "POST",
          headers: { "Content-Type": "application/json", ...(token ? { Authorization: `Bearer ${token}` } : {}) },
          body: JSON.stringify({ threadId: createThreadId(), content: `Turn this journal entry into a concise tweet-style post (under 280 chars). Output ONLY the post:\n\n${content}` }),
        });
        if (!response.ok) throw new Error(`Gateway returned ${response.status}`);
        const data = await response.json();
        posts = [(data.content || data.text || "").trim()];
        setGeneratePostStatus("Generated via gateway.");
      }
      setGeneratedPost(posts[0] || "");
      // Persist all generated posts to Feed > Create
      const newPosts: PersistedPost[] = posts.filter((t) => t.trim()).map((t) => ({
        id: `post_${Date.now()}_${Math.random().toString(36).slice(2, 8)}`,
        text: t.trim(),
        sourceExcerpt: content.slice(0, 120),
        createdAt: Date.now(),
      }));
      if (newPosts.length > 0) {
        setPersistedPosts((prev) => { const next = [...newPosts, ...prev]; savePersistedPosts(next); return next; });
      }
    } catch (error) {
      setGeneratePostStatus(`Generation failed: ${error instanceof Error ? error.message : String(error)}`);
    } finally {
      setGeneratePostBusy(false);
    }
  }

  async function extractTasksFromJournals() {
    if (!requireModel()) return;
    const allJournalText = journalItems
      .slice(0, 20)
      .map((item) => item.previewText || item.title || "")
      .filter((t) => t.trim().length > 10)
      .join("\n---\n")
      .trim();
    if (!allJournalText) { setGeneratePostStatus("No journal entries to extract tasks from."); return; }
    setExtractingLocalTasks(true);
    try {
      const taskPrompt = `You extract action items and tasks from journal entries. Output a JSON array of objects with "title" and "details" fields. Only real actionable tasks. Output ONLY valid JSON, no markdown fences. Example: [{"title":"Buy groceries","details":"Need milk and eggs"}]`;
      const chunks = splitIntoChunks(allJournalText, CHUNK_CHAR_LIMIT);
      const allParsed: Array<{ title: string; details?: string }> = [];

      for (let i = 0; i < chunks.length; i++) {
        if (chunks.length > 1) setGeneratePostStatus(`Extracting tasks ${i + 1}/${chunks.length}...`);
        // Retry up to 3 times for JSON output
        for (let attempt = 0; attempt < 3; attempt++) {
          const result = await nativeAiChat(chunks[i], taskPrompt, 512, 0.2 + attempt * 0.1);
          const parsed = tryParseJsonArray<{ title: string; details?: string }>(result.text);
          if (parsed && parsed.length > 0) {
            allParsed.push(...parsed);
            break;
          }
          // Fallback: try bullet-point parsing on last attempt
          if (attempt === 2) {
            const lines = result.text.split("\n").filter((l) => /^\s*[-*\d.]/.test(l));
            allParsed.push(...lines.map((l) => ({ title: l.replace(/^\s*[-*\d.]+\s*/, "").trim() })));
          }
        }
      }

      if (allParsed.length > 0) {
        const newTodos: PersistedTodo[] = allParsed
          .filter((t) => t.title?.trim())
          .map((t) => ({
            id: `todo_${Date.now()}_${Math.random().toString(36).slice(2, 8)}`,
            title: t.title.trim(),
            details: (t.details || "").trim(),
            done: false,
            createdAt: Date.now(),
          }));
        setPersistedTodos((prev) => {
          const existingTitles = new Set(prev.map((t) => t.title.toLowerCase()));
          const unique = newTodos.filter((t) => !existingTitles.has(t.title.toLowerCase()));
          const next = [...unique, ...prev]; savePersistedTodos(next); return next;
        });
        setGeneratePostStatus(`Extracted ${allParsed.length} tasks from ${chunks.length} chunk${chunks.length > 1 ? 's' : ''}`);
      } else {
        setGeneratePostStatus("No tasks found in journal entries.");
      }
    } catch (error) {
      setGeneratePostStatus(`Task extraction failed: ${error instanceof Error ? error.message : String(error)}`);
    } finally {
      setExtractingLocalTasks(false);
    }
  }

  // ── Pull-to-refresh handlers for Feed and Tasks ───────────────────────────
  // Finds the latest unprocessed journal and uses it for generation/extraction.
  // If all journals are processed, picks a random one for reprocessing.
  function getNextJournalForProcessing(): { path: string; text: string } | null {
    const textItems = journalItems.filter((item) => item.kind === "text" && (item.previewText || "").trim().length > 10);
    if (textItems.length === 0) return null;
    const processed = loadProcessedJournals();
    // Find the most recently modified unprocessed entry
    const unprocessed = textItems.filter((item) => !processed.has(item.path));
    if (unprocessed.length > 0) {
      const newest = unprocessed[0]; // already sorted by modifiedAt desc
      return { path: newest.path, text: newest.previewText || newest.title };
    }
    // All processed — pick a random one for reprocessing
    const random = textItems[Math.floor(Math.random() * textItems.length)];
    return { path: random.path, text: random.previewText || random.title };
  }

  // ── Nostr Feed ────────────────────────────────────────────────────────────

  /**
   * Journal-derived topics drive curation across every social surface. They're
   * memoized on the journal set so the chip row only recomputes when journals
   * change. Topics feed the shared `matchesTopic` predicate (lib/socialFeed.ts).
   */
  const journalTopics = useMemo(
    () => {
      // Voice/video journals carry their transcript in `previewText` (the Rust
      // host surfaces the sidecar transcript as `content`), so feed every
      // entry with substantive text into the lens — not just written notes.
      // This makes audio-first capture actually shape the curation signal.
      const derived = extractJournalTopics(
        journalItems
          .filter((item) => (item.previewText || "").trim().length > 10)
          .slice(0, 60)
          .map((item) => item.previewText || ""),
        10,
      );
      // Apply editable overrides (mute/boost) so the user can steer the lens.
      // Mute (multiplier 0) drops a topic entirely; boost raises its weight so
      // it's prioritized in the Reads/YouTube/Nostr rankers.
      const adjusted = derived
        .map((t) => {
          const mult = interestOverrides[t.label.toLowerCase()]?.multiplier ?? INTEREST_MULT.NORMAL;
          return { label: t.label, weight: t.weight * mult };
        })
        .filter((t) => t.weight > 0);
      // Merge manual interests the user added by hand (not yet in journals), so
      // the lens can follow a topic before the user has written about it. A
      // muted manual interest is dropped here too.
      const existing = new Set(adjusted.map((t) => t.label.toLowerCase()));
      const MANUAL_WEIGHT = 3; // comparable to a strong journal-derived topic
      for (const label of manualInterests) {
        const key = label.toLowerCase();
        if (existing.has(key)) continue;
        const mult = interestOverrides[key]?.multiplier ?? INTEREST_MULT.NORMAL;
        if (mult <= 0) continue;
        adjusted.push({ label, weight: MANUAL_WEIGHT * mult });
      }
      return adjusted.sort((a, b) => b.weight - a.weight).slice(0, 12);
    },
    [journalItems, interestOverrides, manualInterests],
  );

  /**
   * Raw journal-derived topic labels (NO overrides applied) — display-only, used
   * by the Profile interest editor so muted topics stay visible and restorable.
   * The effective lens is `journalTopics` above (which applies overrides);
   * these two are intentionally separate.
   */
  const derivedTopicLabels = useMemo(
    () => extractJournalTopics(
      journalItems
        .filter((item) => (item.previewText || "").trim().length > 10)
        .slice(0, 60)
        .map((item) => item.previewText || ""),
      12,
    ).map((t) => t.label),
    [journalItems],
  );


  /** Nostr notes for the active channel (source-level filter, not client-side). */
  const visibleNostrNotes = useMemo(() => {
    // Channels filter at the SOURCE (loadNostrFeed already applied the NIP-12
    // subscription), so here we only apply the optional journal-derived topic
    // refinement on top. Empty topic = show everything the channel returned.
    const t = activeSocialTopic.trim().toLowerCase();
    const afterTopic = t
      ? nostrFeedNotes.filter((note) => {
          const profile = nostrProfiles[note.pubkey];
          const handle = profile?.name ?? profile?.displayName ?? undefined;
          const avatar = profile?.picture ?? undefined;
          const unified = toUnifiedFromNostr(note, handle, avatar);
          return matchesTopic(unified, t);
        })
      : nostrFeedNotes;
    // Web-of-Trust tier sort: trusted authors first, recency within each tier.
    // An empty wotSet (no graph / cold start) leaves the chronological order
    // unchanged.
    return sortByWoTFirst(afterTopic, wotSet, {
      pubkey: (n) => n.pubkey,
      createdAt: (n) => n.createdAt,
    });
  }, [nostrFeedNotes, nostrProfiles, activeSocialTopic, wotSet]);

  /**
   * Bluesky public posts for the text Feed, optionally filtered by the active
   * journal topic. The Feed tab is text-first by product vision (it mirrors a
   * Twitter timeline), so we also **prioritize text posts above media posts**:
   * posts with no image/video/external embed sort first, then posts with media.
   * This compensates for `searchPosts` returning image-heavy results for
   * generic terms (Bluesky has no reliable server-side text-only filter).
   */
  const visibleBlueskyItems = useMemo(() => {
    const t = activeSocialTopic.trim().toLowerCase();
    const filtered = t
      ? blueskyPublicPosts.filter((p) => matchesTopic(toUnifiedFromBluesky(p), t))
      : blueskyPublicPosts;
    const hasMedia = (p: BlueskyPublicPost) =>
      blueskyImagesOf(p).length > 0 || !!blueskyVideoOf(p) || !!blueskyExternalOf(p);
    // Stable text-first sort: preserve server order (top/relevance) within each bucket.
    return [...filtered].sort((a, b) => {
      const am = hasMedia(a) ? 1 : 0;
      const bm = hasMedia(b) ? 1 : 0;
      return am - bm;
    });
  }, [blueskyPublicPosts, activeSocialTopic]);

  // New-posts pill (#4): when the social feed gains items newer than the last
  // top item the user saw, surface a count. Snapshots the top id on first load;
  // counts how many new ids land above that snapshot on subsequent loads.
  useEffect(() => {
    if (mobileTab !== "feed" || feedView !== "social") return;
    const topId = (socialSource === "nostr" ? visibleNostrNotes[0]?.id : visibleBlueskyItems[0]?.uri) || null;
    if (topId === null) return;
    if (lastSeenTopPostIdRef.current === null) {
      lastSeenTopPostIdRef.current = topId;
      return;
    }
    if (topId === lastSeenTopPostIdRef.current) return;
    // New top item arrived — count how many sit above the last-seen snapshot.
    const list: ReadonlyArray<{ id?: string; uri?: string }> =
      socialSource === "nostr" ? visibleNostrNotes : visibleBlueskyItems;
    const keyOf = (i: { id?: string; uri?: string }) =>
      (socialSource === "nostr" ? i.id : i.uri) || "";
    const idx = list.findIndex((i) => keyOf(i) === lastSeenTopPostIdRef.current);
    const fresh = idx === -1 ? list.length : idx;
    if (fresh > 0) setNewPostsCount((c) => c + fresh);
    lastSeenTopPostIdRef.current = topId;
  }, [mobileTab, feedView, socialSource, visibleNostrNotes, visibleBlueskyItems]);

  // Reset the new-posts pill + snapshot when leaving/switching the social feed.
  useEffect(() => {
    if (mobileTab !== "feed" || feedView !== "social") {
      setNewPostsCount(0);
      lastSeenTopPostIdRef.current = null;
    }
  }, [mobileTab, feedView, socialSource, activeChannelId, activeSocialTopic]);

  /** Hacker News items normalized to UnifiedItem and filtered by the active topic. */
  const visibleTechNews = useMemo(() => {
    const t = activeSocialTopic.trim().toLowerCase();
    if (!t) return techNewsItems;
    return techNewsItems.filter((item) => matchesTopic(toUnifiedFromHN(item), t));
  }, [techNewsItems, activeSocialTopic]);

  /**
   * Reads tab unified stream: merges Nostr articles + RSS items into one
   * `UnifiedItem[]`, then ranks ("For You") or sorts chronologically ("Latest").
   * The existing Nostr/RSS toggle becomes an *additive source filter* on top of
   * this unified stream, instead of a hard either/or.
   */
  const rankedReads = useMemo<RankedRead[]>(() => {
    const unified: UnifiedItem[] = [];
    for (const a of readsArticles) {
      unified.push(toUnifiedFromNostrArticle(a));
    }
    for (const group of readsRssItems) {
      for (const item of group.items) unified.push(toUnifiedFromRss(item, group.feed.label));
    }
    // Hacker News top stories fold into the same ranked stream so the Reads
    // tab is the single home for all article / news / link content.
    for (const hn of techNewsItems) {
      unified.push(toUnifiedFromHN(hn, hn.thumbnailUrl));
    }
    // YouTube videos (keyless, journal-topic-driven) fold into the same stream.
    // The journal-topic ranker promotes videos relevant to the user's writing.
    for (const v of readsYouTubeItems) {
      unified.push(toUnifiedFromYouTube(v));
    }
    return readsRankMode === "latest"
      ? chronologicalReads(unified)
      : rankReads(unified, journalTopics);
  }, [readsArticles, readsRssItems, techNewsItems, readsYouTubeItems, readsRankMode, journalTopics]);

  // Persist the ranked Reads stream so the next open paints instantly from
  // cache (local-first). Only the UnifiedItem[] is cached; ranking re-runs on
  // load so the current rank mode / scoring always applies.
  useEffect(() => {
    if (rankedReads.length === 0) return;
    try {
      window.localStorage.setItem(
        READS_CACHE_KEY,
        JSON.stringify(rankedReads.map((r) => r.item)),
      );
      setCachedReads(rankedReads.map((r) => r.item));
    } catch {
      // Quota / serialization errors are non-fatal; in-memory state still works.
    }
  }, [rankedReads, READS_CACHE_KEY]);

  // What the Reads tab actually renders: the live ranked stream once it has
  // loaded, otherwise the cached stream so the tab is never blank on open.
  const displayReads: RankedRead[] =
    rankedReads.length > 0
      ? rankedReads
      : readsRankMode === "latest"
      ? chronologicalReads(cachedReads)
      : rankReads(cachedReads, journalTopics);

  async function loadNostrFeed() {
    if (nostrFeedLoading) return;
    setNostrFeedLoading(true);
    setSocialFeedError("");
    try {
      // LEVER selection: if an active Nostr channel is a hashtag, scope the
      // query to that tag. Otherwise read broadly.
      const channel = activeChannelId
        ? channelsForSource("nostr").find((c) => c.id === activeChannelId)
        : undefined;
      const hashtag = channel && channel.lever === "nostr-hashtag" && channel.query
        ? channel.query.toLowerCase()
        : undefined;

      let notes: NostrNote[];
      if (useNostrLocalStore) {
        // On-device store path: query the local SQLite store populated by the
        // background ingester. The ingester subscribes to the configured
        // hashtag channels continuously, so this is a local lookup — no relay
        // round-trip per load.
        notes = await nostrQueryNotes({
          kinds: [1],
          ...(hashtag ? { hashtags: [hashtag] } : {}),
          limit: 60,
        });
      } else if (hashtag) {
        notes = await fetchNotesByHashtag([hashtag], { limit: 40 });
      } else {
        notes = await fetchNotesFromRelays({ limit: 40 });
      }
      // QUALITY FILTER (Amethyst-style): drop non-English (non-Latin script),
      // spam, content-warnings, and dedupe flooding pubkeys. Validated live:
      // this roughly halves firehose noise (58 → ~26 usable English notes) and
      // removes testnet bot spam. Stats surface in the feed header.
      const stats: NostrFeedStats = { total: 0, droppedNonLanguage: 0, droppedSpam: {}, droppedDuplicate: 0 };
      const filtered = filterNostrFeed(notes, { maxPerPubkey: 2, stats });
      setNostrFeedStats(stats);
      setNostrFeedNotes(filtered);
      // Enrich the feed in the background: real names/avatars (kind 0),
      // like counts (kind 7), and parent notes for reply context. Fire and
      // forget so the notes render immediately; enrichment fills in as it lands.
      void enrichNostrFeed(filtered);
    } catch {
      // Fallback to generic notes
      try {
        const notes = await fetchNotesFromRelays({ limit: 40 });
        setNostrFeedNotes(notes);
        void enrichNostrFeed(notes);
      } catch {
        setNostrFeedNotes([]);
        setSocialFeedError("Couldn't reach Nostr relays. Try another channel.");
      }
    } finally {
      setNostrFeedLoading(false);
    }
  }

  /**
   * LEVER: Bluesky anonymous searchPosts. The most reliable content lever —
   * returns ~20 posts for any term. "Discover" (empty query) falls back to a
   * broad search. No auth needed (public AppView). On error we surface a clear
   * message rather than silently clearing the feed.
   */
  async function loadBlueskyPublicFeed() {
    if (blueskyPublicLoading) return;
    setBlueskyPublicLoading(true);
    setBlueskyPublicError("");
    setSocialFeedError("");
    try {
      const mod = await loadBlueskyModule();
      const channel = activeChannelId
        ? channelsForSource("bluesky").find((c) => c.id === activeChannelId)
        : undefined;
      // Empty/discover channel → a broad, ever-green query so the feed is never empty.
      const query = channel?.query || "tech";
      // Text Feed tuning: sort "top" (engagement-weighted, favors discussion over
      // fresh image reposts) within a 48h window. The Feed tab is text-first by
      // product vision; `sort:"latest"` returned mostly image-heavy posts for
      // generic terms. (Media tab keeps latest via its own loader.)
      const posts = await mod.searchPublicBlueskyPosts(query, {
        limit: 30,
        sort: "top",
        sinceHours: 48,
      });
      setBlueskyPublicPosts(posts);
    } catch (e) {
      setBlueskyPublicPosts([]);
      const msg = e instanceof Error ? e.message : String(e);
      setBlueskyPublicError(`Couldn't reach Bluesky: ${msg.slice(0, 120)}`);
    } finally {
      setBlueskyPublicLoading(false);
    }
  }

  /** Dispatcher: load whichever source is active. */
  async function loadSocialFeed() {
    if (socialSource === "following") {
      await loadFollowingFeedApp();
    } else if (socialSource === "bluesky") {
      await loadBlueskyPublicFeed();
    } else {
      await loadNostrFeed();
    }
  }

  /**
   * Following home timeline: the newest posts from authors the user follows,
   * merged across Nostr (one multi-author relay query) and Bluesky (per-author
   * fan-out). This is the Twitter/Bluesky home-timeline experience.
   */
  async function loadFollowingFeedApp() {
    if (followingLoading) return;
    setFollowingLoading(true);
    setFollowingError("");
    try {
      const result = await loadFollowingFeed(getFollowedIds(), {
        nostrProfiles: useNostrLocalStore ? undefined : undefined, // profiles resolve lazily via card render
      });
      setFollowingItems(result.items);
      if (result.items.length === 0 && getFollowedIds().length === 0) {
        setFollowingError(""); // empty state handled in UI, not as error
      }
    } catch (e) {
      setFollowingItems([]);
      const msg = e instanceof Error ? e.message : String(e);
      setFollowingError(`Couldn't load following feed: ${msg.slice(0, 100)}`);
    } finally {
      setFollowingLoading(false);
    }
  }

  /**
   * Reels feed: assemble Bluesky videos by merging several visually-rich topics
   * (single-topic searches return only 1-3 videos each, so we merge ~12).
   * Validated live: this yields ~20 unique videos. No auth needed.
   *
   * Local-first: when the on-device video store has cached posts, render them
   * instantly before the network fan-out completes. The network fetch then
   * refreshes the list and upserts the fresh posts back into the store, so the
   * next tab-open is instant. Mirrors the `useNostrLocalStore` pattern.
   */
  async function loadReelsFeed() {
    if (reelsLoading) return;
    setReelsLoading(true);

    // 1. Instant render from the local store (no network round-trip).
    if (useVideoLocalStore) {
      try {
        const cached = await videoQueryBluesky({ limit: 50 });
        if (cached.length > 0) setReelsPosts(cached);
      } catch {
        // Non-fatal: fall through to the network fetch.
      }
    }

    // 2. Network refresh — always runs so the list stays fresh. Upserts back
    //    into the local store for the next feed-open. This is now a background
    //    loader for the unified Feed's inline videos + tap-to-fullscreen overlay
    //    (no dedicated tab), so failures are silent — the Feed surfaces its own
    //    errors and the overlay falls back to the tapped post alone.
    try {
      const posts = await fetchBlueskyReelsFeed({ limit: 50 });
      setReelsPosts(posts);
      if (useVideoLocalStore && posts.length > 0) {
        void videoUpsertBluesky(posts);
      }
    } catch {
      // Keep the cached posts on screen if we have them; only clear on a cold
      // failure (no cache + network error).
      if (reelsPosts.length === 0) setReelsPosts([]);
    } finally {
      setReelsLoading(false);
    }
  }

  /**
   * Reads feed: long-form content. Nostr NIP-23 articles (Habla-style, kind
   * 30023) and RSS/Atom blogs. Each source is fetched independently and merged.
   * Both pass through the language filter so non-English articles are dropped.
   */
  async function loadReadsFeed() {
    if (readsLoading) return;
    setReadsLoading(true);
    setReadsError("");
    try {
      // Fetch the primary reads source (Nostr articles OR RSS) and Hacker News
      // in parallel. HN folds into the same ranked stream so the Reads tab is
      // one unified surface for all article/news/link content.
      const primaryPromise =
        readsSource === "nostr"
          ? fetchLongFormArticles({ limit: 20 }).then((articles) => {
              // Language-filter the articles (drop non-Latin titles/bodies).
              return articles.filter((a) => {
                const title = (a.tags || []).find((t) => t[0] === "title")?.[1] || "";
                return filterNostrFeed([{ id: a.id, pubkey: a.pubkey, content: title + " " + a.content.slice(0, 200), createdAt: a.created_at, tags: a.tags || [] }], { maxPerPubkey: 99 }).length > 0;
              });
            })
          : (() => {
              const selected = RSS_FEEDS.filter((f) => activeRssFeedIds.includes(f.id));
              const feeds = selected.length > 0 ? selected : RSS_FEEDS.slice(0, 3);
              return fetchRssFeeds(feeds, { limitPerFeed: 8 });
            })();
      // Kick off HN alongside; it sets its own state and is best-effort, so we
      // don't await it — it folds into the ranked stream as it lands.
      if (techNewsItems.length === 0) void loadTechNews();
      // YouTube (keyless) is likewise best-effort: searched by the user's
      // journal topics so the videos are "what feeds this user's mind".
      if (readsYouTubeEnabled) void loadYouTubeReads();
      const primary = await primaryPromise;
      if (readsSource === "nostr") {
        setReadsArticles(primary as NostrEvent[]);
      } else {
        setReadsRssItems(primary as { feed: RssFeed; items: RssItem[] }[]);
      }
    } catch (e) {
      const msg = e instanceof Error ? e.message : String(e);
      setReadsError(`Couldn't load reads: ${msg.slice(0, 120)}`);
    } finally {
      setReadsLoading(false);
    }
  }

  /**
   * Load YouTube videos into the Reads stream. The reliable base is the
   * curated channel catalog (YouTube RSS via the same rss2json proxy RSS blogs
   * use — robust, keyless, webview-safe). On top of that, a best-effort
   * topic search (Invidious) adds interest-driven discovery using the user's
   * journal topics. Channel videos always load; topic search degrades to
   * nothing on failure without dropping the channels. The journal-driven
   * ranker then promotes the most relevant videos of either kind.
   */
  async function loadYouTubeReads() {
    if (!readsYouTubeEnabled) {
      setReadsYouTubeItems([]);
      return;
    }
    try {
      const videos = await loadYouTubeFeed({
        channels: YOUTUBE_CHANNELS,
        topics: journalTopics.map((t) => t.label),
        perTopic: 4,
        limitPerChannel: 6,
      });
      setReadsYouTubeItems(videos);
    } catch {
      // Total failure (network down): keep the tab empty of videos; the rest
      // of the Reads stream (articles/HN) is unaffected.
      setReadsYouTubeItems([]);
    }
  }
  /** Resolve profiles + reactions + reply-parents for a set of notes. */
  async function enrichNostrFeed(notes: NostrNote[]) {
    if (notes.length === 0) return;
    try {
      const pubkeys = [...new Set(notes.map((n) => n.pubkey))];
      const ids = notes.map((n) => n.id);
      const parentIds = [...new Set(
        notes.map((n) => getReplyParentId(n)).filter((p): p is string => !!p)
      )];

      if (useNostrLocalStore) {
        // Local-store path: the ingester keeps profiles/reactions/parents fresh,
        // so this is three cheap local lookups — no relay round-trips on a warm
        // cache. We still issue relay fetches below only for genuine cache
        // misses (pubkeys/parents the ingester hasn't seen yet).
        const [profiles, reactions, parents] = await Promise.all([
          nostrGetProfiles(pubkeys),
          nostrGetReactions(ids),
          parentIds.length
            ? Promise.all(parentIds.map((id) => fetchLocalNote(id))).then((arr) => {
                const m = new Map<string, NostrNote>();
                arr.forEach((n) => { if (n) m.set(n.id, n); });
                return m;
              })
            : Promise.resolve(new Map<string, NostrNote>()),
        ]);
        setNostrProfiles((prev) => ({ ...prev, ...Object.fromEntries(profiles) }));
        setNostrReactions((prev) => ({ ...prev, ...Object.fromEntries(reactions) }));
        setNostrParentNotes((prev) => ({ ...prev, ...Object.fromEntries(parents) }));
        // Backfill any pubkeys the store didn't have.
        const missingPubs = pubkeys.filter((p) => !profiles.has(p));
        if (missingPubs.length) {
          const pm = await fetchProfiles(missingPubs);
          setNostrProfiles((prev) => ({ ...prev, ...Object.fromEntries(pm) }));
        }
        return;
      }

      const [profiles, reactions, parents] = await Promise.all([
        fetchProfiles(pubkeys),
        fetchReactionsForEvents(ids),
        parentIds.length ? fetchNotesByIds(parentIds) : Promise.resolve(new Map<string, NostrNote>()),
      ]);
      setNostrProfiles((prev) => ({ ...prev, ...Object.fromEntries(profiles) }));
      setNostrReactions((prev) => ({ ...prev, ...Object.fromEntries(reactions) }));
      setNostrParentNotes((prev) => ({ ...prev, ...Object.fromEntries(parents) }));
      // Parent authors' profiles may also be missing — fetch them too.
      const parentPubs = [...parents.values()].map((n) => n.pubkey).filter((p) => !profiles.has(p));
      if (parentPubs.length) {
        const pm = await fetchProfiles(parentPubs);
        setNostrProfiles((prev) => ({ ...prev, ...Object.fromEntries(pm) }));
      }
    } catch (e) {
      console.warn("[nostr] feed enrichment failed", e);
    }
  }

  /** Local-store lookup of a single note by id (used for reply-parent enrichment). */
  async function fetchLocalNote(eventId: string): Promise<NostrNote | null> {
    return nostrGetNote(eventId);
  }

  /** Lazy-load the replies (kind 1) for a single note and expand them inline. */
  async function loadNostrReplies(eventId: string) {
    setNostrRepliesLoading((prev) => ({ ...prev, [eventId]: true }));
    try {
      const replies = useNostrLocalStore
        ? await nostrGetReplies(eventId)
        : await fetchRepliesForEvent(eventId);
      setNostrReplyThreads((prev) => ({ ...prev, [eventId]: replies }));
      // Expand only if there are replies to show (keeps the UI tidy when empty).
      setNostrRepliesLoading((prev) => ({ ...prev, [eventId]: false }));
      if (replies.length) {
        const pubs = [...new Set(replies.map((r) => r.pubkey))];
        const pm = useNostrLocalStore
          ? await nostrGetProfiles(pubs)
          : await fetchProfiles(pubs);
        setNostrProfiles((prev) => ({ ...prev, ...Object.fromEntries(pm) }));
      }
    } catch {
      setNostrReplyThreads((prev) => ({ ...prev, [eventId]: [] }));
      setNostrRepliesLoading((prev) => ({ ...prev, [eventId]: false }));
    }
  }

  /**
   * Source + channel + journal chip system. This is the filtering control panel:
   *   1. SOURCE row: Nostr | Bluesky (picks the open-protocol source)
   *   2. CHANNEL row: preset source-level levers (validated to return content).
   *      Switching a channel RE-FETCHES from the source — content is guaranteed
   *      for popular terms (NIP-12 hashtags on Nostr, searchPosts on Bluesky).
   *   3. JOURNAL refinement (optional): narrows the channel's results using
   *      journal-derived topics via the client-side matchesTopic predicate.
   */
  function renderSourceAndChannels() {
    const channels = channelsForSource(socialSource);
    return (
      <div className="filter-panel">
        <div className="source-toggle" role="group" aria-label="Content source">
          <button
            type="button"
            className={`source-pill${socialSource === "following" ? " active" : ""}`}
            onClick={() => { if (socialSource !== "following") { setSocialSource("following"); setActiveChannelId(""); } }}
            title="Home timeline — newest posts from people you follow"
          >Following</button>
          <button
            type="button"
            className={`source-pill${socialSource === "nostr" ? " active" : ""}`}
            onClick={() => { if (socialSource !== "nostr") { setSocialSource("nostr"); setActiveChannelId(""); } }}
          >Nostr</button>
          <button
            type="button"
            className={`source-pill${socialSource === "bluesky" ? " active" : ""}`}
            onClick={() => { if (socialSource !== "bluesky") { setSocialSource("bluesky"); setActiveChannelId(""); } }}
          >Bluesky</button>
        </div>

        <div className="topic-chips" role="group" aria-label="Content channels">
          {channels.map((ch) => (
            <button
              key={ch.id}
              type="button"
              className={`topic-chip${activeChannelId === ch.id ? " active" : ""}`}
              onClick={() => {
                const next = activeChannelId === ch.id ? "" : ch.id;
                setActiveChannelId(next);
                // Immediately fetch the newly-selected channel.
                // Defer via microtask so state is committed first.
                queueMicrotask(() => {
                  if (next) {
                    void (socialSource === "bluesky" ? loadBlueskyPublicFeed() : loadNostrFeed());
                  } else {
                    void loadSocialFeed();
                  }
                });
              }}
              title={`${ch.lever}: ${ch.query || ch.label}`}
            >{ch.emoji ? <span aria-hidden>{ch.emoji}</span> : null}{ch.label}</button>
          ))}
        </div>

        {/* Optional journal refinement — narrows channel results further. */}
        {journalTopics.length > 0 ? (
          <div className="topic-chips journal-refine" role="group" aria-label="Refine by journal topic">
            <span className="topic-chips-label">From journals:</span>
            {journalTopics.slice(0, 6).map((topic) => (
              <button
                key={topic.label}
                type="button"
                className={`topic-chip small${activeSocialTopic === topic.label ? " active" : ""}`}
                onClick={() => setActiveSocialTopic(activeSocialTopic === topic.label ? "" : topic.label)}
                title={`${topic.weight} mentions in your journals`}
              >{topic.label}</button>
            ))}
          </div>
        ) : null}
      </div>
    );
  }

  /** Resolve the best display name for a pubkey (profile name, else truncated npub). */
  function nostrDisplayName(pubkey: string, profile?: NostrProfile | null): string {
    if (profile?.displayName?.trim()) return profile.displayName.trim();
    if (profile?.name?.trim()) return profile.name.trim();
    // Prefer the npub precomputed at ingest (in the local store) over a
    // per-render bech32 encode. Only fall back to npubFromHex when the store
    // hasn't cached this pubkey yet (e.g. web/demo build).
    const cached = cachedNpub(pubkey);
    if (cached) return cached.slice(0, 12) + "…" + cached.slice(-6);
    try {
      const npub = npubFromHex(pubkey);
      return npub.slice(0, 12) + "…" + npub.slice(-6);
    } catch {
      return pubkey.slice(0, 12) + "…";
    }
  }

  /** Avatar for a Nostr author: profile picture if available, else a fallback initial. */
  function renderNostrAvatar(pubkey: string, profile?: NostrProfile | null) {
    const name = nostrDisplayName(pubkey, profile);
    if (profile?.picture) {
      return (
        <img
          src={profile.picture}
          alt=""
          className="tweet-avatar nostr-avatar-img"
          style={{ cursor: 'pointer', objectFit: 'cover' }}
          onClick={() => void openNostrProfile(pubkey)}
          onError={(e) => {
            // Hide broken avatars so the CSS fallback initial shows instead.
            (e.currentTarget as HTMLImageElement).style.display = 'none';
          }}
          aria-hidden
          loading="lazy"
        />
      );
    }
    const initial = name.replace(/^@/, "").charAt(0).toUpperCase() || "?";
    return (
      <div className="tweet-avatar" style={{ cursor: 'pointer' }} onClick={() => void openNostrProfile(pubkey)} aria-hidden>{initial}</div>
    );
  }

  /**
   * Render a single Nostr note as a rich card: avatar + name, optional
   * "replying to @parent" context, content, and a footer with like count and
   * an expandable reply thread. Reused by both the Feed tab and profile overlay.
   */
  function renderNostrNoteCard(note: NostrNote) {
    const timeAgo = getRelativeTime(note.createdAt * 1000);
    const profile = nostrProfiles[note.pubkey];
    const name = nostrDisplayName(note.pubkey, profile);
    const parentId = getReplyParentId(note);
    const parent = parentId ? nostrParentNotes[parentId] : undefined;
    const parentProfile = parent ? nostrProfiles[parent.pubkey] : undefined;
    const parentName = parent ? nostrDisplayName(parent.pubkey, parentProfile) : null;
    const reactionCount = nostrReactions[note.id] || 0;
    const replies = nostrReplyThreads[note.id];
    const repliesLoading = nostrRepliesLoading[note.id];
    return (
      <div key={note.id} className="tweet-card">
        {renderNostrAvatar(note.pubkey, profile)}
        <div className="tweet-body">
          <div className="tweet-header">
            <span className="tweet-name" style={{ cursor: 'pointer' }} onClick={() => void openNostrProfile(note.pubkey)}>{name}</span>
            {profile?.nip05 ? <span className="tweet-handle">✅ {profile.nip05}</span> : null}
            <span className="tweet-dot">·</span>
            <span className="tweet-time">{timeAgo}</span>
          </div>
          {parent ? (
            <p className="nostr-reply-context text-sm muted" style={{ margin: '0.1rem 0 0.35rem' }}>
              Replying to <span className="nostr-reply-context-name" onClick={() => void openNostrProfile(parent.pubkey)} aria-hidden>{parentName}</span>
            </p>
          ) : null}
          {parent ? (
            <blockquote className="nostr-parent-quote">{parent.content.slice(0, 160)}{parent.content.length > 160 ? "…" : ""}</blockquote>
          ) : null}
          <p className="tweet-text">{note.content}</p>
          <FeedActionBar
            id={note.id}
            source="nostr"
            text={note.content}
            likeCount={reactionCount}
            replyCount={replies?.length || 0}
            permalink={`https://nostrapp.co#${note.id}`}
            authorName={name}
            authorHandle={profile?.nip05 || profile?.name || note.pubkey.slice(0, 10)}
            thumbnail={profile?.picture ?? undefined}
            onReply={() => {
              if (repliesLoading) return;
              if (!replies) {
                void loadNostrReplies(note.id);
              } else if (replies.length) {
                // Toggle collapse when already loaded.
                setNostrReplyThreads((prev) => {
                  const next = { ...prev };
                  delete next[note.id];
                  return next;
                });
              }
            }}
            replyLoading={!!repliesLoading}
            replyExpanded={!!replies?.length}
            reposted={repostedIds.includes(note.id)}
            onRepost={() => void handleRepost("nostr", note.id, note.pubkey)}
          />
          {/* Inline reply compose (shown when the thread is expanded). */}
          {replies ? (
            <div className="reply-compose">
              <textarea
                className="reply-compose-input"
                rows={1}
                placeholder={nostrKeys ? "Reply on Nostr…" : "Connect your Nostr key to reply…"}
                value={replyDrafts[note.id] || ""}
                onChange={(e) => setReplyDrafts((prev) => ({ ...prev, [note.id]: e.target.value }))}
              />
              <button
                type="button"
                className="primary reply-compose-send"
                disabled={!replyDrafts[note.id]?.trim()}
                onClick={() => { void handleNostrReplyFromCard(note.id, replyDrafts[note.id] || ""); }}
              >Reply</button>
            </div>
          ) : null}
          {repliesLoading ? <p className="text-sm muted nostr-reply-meta">Loading replies…</p> : null}
          {replies && replies.length > 0 ? (
            <div className="nostr-reply-thread">
              {replies.slice(0, 10).map((reply) => (
                <div key={reply.id} className="nostr-reply-item">
                  {renderNostrAvatar(reply.pubkey, nostrProfiles[reply.pubkey])}
                  <div className="nostr-reply-item-body">
                    <div className="tweet-header">
                      <span className="tweet-name" style={{ cursor: 'pointer', fontSize: '0.85rem' }} onClick={() => void openNostrProfile(reply.pubkey)}>{nostrDisplayName(reply.pubkey, nostrProfiles[reply.pubkey])}</span>
                      <span className="tweet-dot">·</span>
                      <span className="tweet-time">{getRelativeTime(reply.createdAt * 1000)}</span>
                    </div>
                    <p className="tweet-text" style={{ fontSize: '0.88rem' }}>{reply.content}</p>
                  </div>
                </div>
              ))}
            </div>
          ) : null}
        </div>
      </div>
    );
  }

  /**
   * Render a Bluesky public post as a card. Mirrors renderNostrNoteCard's
   * visual language (avatar, name, body, engagement footer). Rich features
   * (reply threads, in-app reply/like) are follow-ups; this v1 surfaces the
   * post, author, optional images, and like/repost counts from the AppView.
   */
  function renderBlueskyCard(post: BlueskyPublicPost) {
    const handle = post.author?.handle || "unknown";
    const name = post.author?.displayName?.trim() || handle;
    const avatar = post.author?.avatar || "";
    const body = post.record?.text || "";
    const images = blueskyImagesOf(post);
    const video = blueskyVideoOf(post);
    const external = blueskyExternalOf(post);
    const quote = blueskyQuotedRecordOf(post);
    const tsMs = Date.parse(post.indexedAt || post.record?.createdAt || "");
    const ts = Number.isFinite(tsMs) ? Math.floor(tsMs / 1000) : 0;
    const profileUrl = `https://bsky.app/profile/${handle}`;
    return (
      <article className="nostr-note-card bluesky-note-card" key={post.uri}>
        <div className="nostr-note-head">
          {avatar
            ? <img src={avatar} alt="" className="nostr-avatar clickable" loading="lazy" onClick={() => void openBlueskyProfile(handle)} />
            : <div className="nostr-avatar nostr-avatar-fallback clickable" aria-hidden onClick={() => void openBlueskyProfile(handle)}>{name.slice(0, 1).toUpperCase()}</div>}
          <div className="nostr-note-author clickable" onClick={() => void openBlueskyProfile(handle)}>
            <span className="nostr-note-name">{name}</span>
            <span className="nostr-note-handle">@{handle}</span>
          </div>
          <a className="nostr-note-source" href={profileUrl} target="_blank" rel="noreferrer" title="Open on Bluesky">🌐</a>
        </div>
        {/* Text is always rendered first and prominently. */}
        {body ? <p className="nostr-note-text">{body}</p> : null}
        {/* Video embed (HLS playlist). Tapping opens a reels-style fullscreen
            player (tap-to-fullscreen); a poster + play affordance shows inline
            so the feed stays scannable without autoplaying heavy video. */}
        {video && (video.playlist || video.thumbnail) ? (
          <button
            type="button"
            className="bluesky-video-wrap"
            aria-label="Open video fullscreen"
            onClick={() => {
              // Build the swipeable video list from the currently loaded Bluesky
              // video posts, starting at this post. Falls back to just this post
              // if no broader feed is loaded.
              const videoPosts = [
                ...blueskyPublicPosts.filter((p) => !!blueskyVideoOf(p)),
                ...reelsPosts,
              ];
              const deduped: BlueskyPublicPost[] = [];
              const seen = new Set<string>();
              for (const p of videoPosts) {
                if (seen.has(p.uri)) continue;
                seen.add(p.uri);
                deduped.push(p);
              }
              const list = deduped.length > 0 ? deduped : [post];
              const startIndex = Math.max(0, list.findIndex((p) => p.uri === post.uri));
              setFullscreenVideo({ posts: list, startIndex });
            }}
          >
            {video.thumbnail ? <img src={video.thumbnail} alt="" className="bluesky-video-poster" loading="lazy" /> : null}
            <span className="bluesky-video-play" aria-hidden>▶</span>
          </button>
        ) : null}
        {/* Image grid (1-4 images, fullsize for quality). */}
        {images.length > 0 ? (
          <div className={`bluesky-image-grid count-${Math.min(images.length, 4)}`}>
            {images.slice(0, 4).map((img, i) => (
              img.thumb ? <img key={i} src={img.fullsize || img.thumb} alt={img.alt || ""} className="bluesky-grid-image" loading="lazy" /> : null
            ))}
          </div>
        ) : null}
        {/* External link card. */}
        {external ? (
          <a className="bluesky-external-card" href={external.uri} target="_blank" rel="noreferrer">
            {external.thumb ? <img src={external.thumb} alt="" className="bluesky-external-thumb" loading="lazy" /> : null}
            <div className="bluesky-external-meta">
              <span className="bluesky-external-title">{external.title || external.uri}</span>
              {external.description ? <span className="bluesky-external-desc">{external.description.slice(0, 140)}</span> : null}
              <span className="bluesky-external-host">{(() => { try { return new URL(external.uri).hostname.replace(/^www\./, ""); } catch { return external.uri; } })()}</span>
            </div>
          </a>
        ) : null}
        {/* Quoted/parent record. */}
        {quote && (quote.text || quote.handle) ? (
          <div className="bluesky-quote">
            {quote.handle ? <span className="bluesky-quote-author">@{quote.handle}</span> : null}
            {quote.text ? <p className="bluesky-quote-text">{quote.text.slice(0, 200)}</p> : null}
          </div>
        ) : null}
        <div className="nostr-note-time-row">
          <span className="nostr-note-time">{getRelativeTime(ts * 1000)}</span>
        </div>
        <FeedActionBar
          id={post.uri}
          source="bluesky"
          text={body}
          likeCount={post.likeCount}
          repostCount={post.repostCount}
          replyCount={post.replyCount}
          permalink={(() => { const rkey = post.uri.split("/").pop(); return rkey ? `${profileUrl}/post/${rkey}` : profileUrl; })()}
          authorName={name}
          authorHandle={handle}
          thumbnail={avatar}
          reposted={repostedIds.includes(post.uri)}
          onRepost={() => void handleRepost("bluesky", post.uri, post.author.did, post.cid)}
          onReply={() => setBlueskyReplyExpanded((prev) => {
            const next = new Set(prev);
            if (next.has(post.uri)) next.delete(post.uri); else next.add(post.uri);
            return next;
          })}
          replyExpanded={blueskyReplyExpanded.has(post.uri)}
        />
        {blueskyReplyExpanded.has(post.uri) ? (
          <div className="reply-compose">
            <textarea
              className="reply-compose-input"
              rows={1}
              placeholder={session ? "Reply on Bluesky…" : "Sign in to Bluesky to reply…"}
              value={replyDrafts[post.uri] || ""}
              onChange={(e) => setReplyDrafts((prev) => ({ ...prev, [post.uri]: e.target.value }))}
            />
            <button
              type="button"
              className="primary reply-compose-send"
              disabled={!replyDrafts[post.uri]?.trim() || !session}
              onClick={() => void handleBlueskyReplyFromCard(post.uri, post.cid)}
            >Reply</button>
          </div>
        ) : null}
      </article>
    );
  }

  /**
   * Reusable Tasks section (extracted from the former standalone Tasks tab so it
   * can be folded into the Queue tab). Same UI + behavior; an explicit "Extract"
   * button replaces the old tab-level pull-to-refresh (the Queue tab's pull is
   * wired to post generation, so Tasks needs its own trigger).
   */
  function renderTasksSection() {
    return (
      <div className="stack" style={{ marginTop: '0.75rem' }}>
        <div className="tasks-header-card">
          <div className="row-between" style={{ alignItems: 'center' }}>
            <h2 style={{ margin: 0 }}>Tasks</h2>
            <div className="row" style={{ gap: '0.5rem', alignItems: 'center' }}>
              {extractingLocalTasks ? (
                <span className="row" style={{ gap: '0.3rem', alignItems: 'center' }}>
                  <span className="btn-spinner" aria-hidden />
                  <span className="text-sm muted">Extracting...</span>
                </span>
              ) : (
                <button type="button" className="ghost text-sm" onClick={() => void handleTasksPullRefresh()} title="Extract tasks from journals">Extract</button>
              )}
            </div>
          </div>
          <p className="text-sm muted" style={{ margin: '0.15rem 0 0' }}>
            Extracted from your journals
          </p>
        </div>

        {persistedTodos.filter((t) => !t.done).length > 0 ? (
          <div className="tasks-section">
            <h3 className="tasks-section-title">Open · {persistedTodos.filter((t) => !t.done).length}</h3>
            {persistedTodos.filter((t) => !t.done).map((todo) => (
              <div key={todo.id} className="task-item">
                <button
                  type="button"
                  className="task-checkbox"
                  onClick={() => {
                    setPersistedTodos((prev) => {
                      const next = prev.map((t) => t.id === todo.id ? { ...t, done: true } : t);
                      savePersistedTodos(next);
                      return next;
                    });
                  }}
                  aria-label="Mark done"
                />
                <div className="task-item-content">
                  <input
                    type="text"
                    value={todo.title}
                    className="task-title-input"
                    onChange={(e) => {
                      const val = e.target.value;
                      setPersistedTodos((prev) => {
                        const next = prev.map((t) => t.id === todo.id ? { ...t, title: val } : t);
                        savePersistedTodos(next);
                        return next;
                      });
                    }}
                  />
                  {todo.details && (
                    <input
                      type="text"
                      value={todo.details}
                      className="task-detail-input"
                      onChange={(e) => {
                        const val = e.target.value;
                        setPersistedTodos((prev) => {
                          const next = prev.map((t) => t.id === todo.id ? { ...t, details: val } : t);
                          savePersistedTodos(next);
                          return next;
                        });
                      }}
                    />
                  )}
                </div>
                <span className="task-time">{getRelativeTime(todo.createdAt)}</span>
              </div>
            ))}
          </div>
        ) : null}

        {persistedTodos.filter((t) => t.done).length > 0 ? (
          <div className="tasks-section">
            <h3 className="tasks-section-title" style={{ color: 'var(--muted)' }}>Completed · {persistedTodos.filter((t) => t.done).length}</h3>
            {persistedTodos.filter((t) => t.done).map((todo) => (
              <div key={todo.id} className="task-item task-item-done">
                <button
                  type="button"
                  className="task-checkbox checked"
                  onClick={() => {
                    setPersistedTodos((prev) => {
                      const next = prev.map((t) => t.id === todo.id ? { ...t, done: false } : t);
                      savePersistedTodos(next);
                      return next;
                    });
                  }}
                  aria-label="Reopen"
                >
                  <svg width="12" height="12" viewBox="0 0 24 24" fill="none" stroke="#fff" strokeWidth="3" strokeLinecap="round" strokeLinejoin="round"><polyline points="20 6 9 17 4 12"/></svg>
                </button>
                <div className="task-item-content">
                  <span className="task-title-done">{todo.title}</span>
                </div>
                <button
                  type="button"
                  className="ghost task-delete-btn"
                  onClick={() => {
                    setPersistedTodos((prev) => {
                      const next = prev.filter((t) => t.id !== todo.id);
                      savePersistedTodos(next);
                      return next;
                    });
                  }}
                  title="Delete"
                >
                  <svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round"><line x1="18" y1="6" x2="6" y2="18"/><line x1="6" y1="6" x2="18" y2="18"/></svg>
                </button>
              </div>
            ))}
          </div>
        ) : null}

        {persistedTodos.length === 0 ? (
          <div className="tasks-empty">
            <div className="tasks-empty-icon">✅</div>
            <p className="text-sm muted" style={{ margin: 0 }}>
              No tasks yet. Tap Extract to pull them from your journals.
            </p>
          </div>
        ) : null}
      </div>
    );
  }

  async function loadTechNews() {
    if (techNewsLoading) return;
    setTechNewsLoading(true);
    setTechNewsError("");
    try {
      const res = await fetch("https://hacker-news.firebaseio.com/v0/topstories.json", { cache: "no-store" });
      if (!res.ok) throw new Error(`Tech news service responded ${res.status}.`);
      const ids: number[] = await res.json();
      type HnItem = {
        id: number; title?: string; url?: string;
        score?: number; descendants?: number;
        time?: number; type?: string;
      } | null;
      // Fetch a few more than 5 so the strongest stories survive even when
      // some are job posts or missing fields.
      const fetched: HnItem[] = await Promise.all(
        ids.slice(0, 12).map(async (id) => {
          try {
            const r = await fetch(`https://hacker-news.firebaseio.com/v0/item/${id}.json`, { cache: "no-store" });
            return r.ok ? ((await r.json()) as HnItem) : null;
          } catch {
            return null;
          }
        })
      );
      const stories: TechNewsItem[] = fetched
        .filter((it): it is NonNullable<HnItem> =>
          Boolean(it && it.type === "story" && typeof it.title === "string")
        )
        .map((it) => {
          const url: string = it.url || `https://news.ycombinator.com/item?id=${it.id}`;
          return {
            id: it.id,
            title: it.title as string,
            url,
            source: domainFromUrl(url),
            score: typeof it.score === "number" ? it.score : 0,
            comments: typeof it.descendants === "number" ? it.descendants : 0,
            createdAt: typeof it.time === "number" ? it.time : 0,
          };
        })
        .slice(0, 5);
      setTechNewsItems(stories);

      // Best-effort thumbnail enrichment for external article URLs. HN stories
      // carry no images, so derive an OG image via the gateway preview route.
      // Self-links (news.ycombinator.com) have nothing useful to preview.
      const token = chatGatewayToken.trim() || undefined;
      Promise.allSettled(
        stories.map(async (story) => {
          if (!story.url || story.source === "news.ycombinator.com") return null;
          const preview = await fetchWebPreview(story.url, token, gatewayBaseUrl);
          if (!preview?.imageUrl) return null;
          return { id: story.id, thumbnailUrl: preview.imageUrl } as const;
        })
      )
        .then((results) => {
          const updates = new Map<number, string>();
          for (const r of results) {
            if (r.status === "fulfilled" && r.value) {
              updates.set(r.value.id, r.value.thumbnailUrl);
            }
          }
          if (updates.size === 0) return;
          setTechNewsItems((prev) =>
            prev.map((item) =>
              updates.has(item.id) ? { ...item, thumbnailUrl: updates.get(item.id) } : item
            )
          );
        })
        .catch(() => {
          // Enrichment is best-effort; ignore failures.
        });
    } catch (error) {
      setTechNewsError(error instanceof Error ? error.message : "Failed to load tech news.");
    } finally {
      setTechNewsLoading(false);
    }
  }

  async function openNostrProfile(pubkey: string) {
    setProfileView({ kind: "nostr", pubkey });
    setProfileViewLoading(true);
    setNostrProfileOverlay(null);
    setProfileViewNostrFollowing(null);
    try {
      const profileMap = useNostrLocalStore
        ? await nostrGetProfiles([pubkey])
        : await fetchProfiles([pubkey]);
      const notes = useNostrLocalStore
        ? await nostrQueryNotes({ authors: [pubkey], limit: 20 })
        : await fetchNotesFromRelays({ authors: [pubkey], limit: 20 });
      setNostrProfileOverlay(profileMap.get(pubkey) || null);
      setProfileViewNotes(notes);
      // Best-effort following count for the stats row (anonymous read).
      void fetchNostrFollowingCount(pubkey).then((n) => setProfileViewNostrFollowing(n));
    } catch {
      setProfileViewNotes([]);
    } finally {
      setProfileViewLoading(false);
    }
  }

  /**
   * Open an in-app Bluesky author profile (auth-free read). Mirrors
   * openNostrProfile: fetches the full profile + recent posts in parallel and
   * surfaces them in the shared profile modal.
   */
  async function openBlueskyProfile(actor: string) {
    const clean = actor.trim().replace(/^@/, "");
    if (!clean) return;
    setProfileView({ kind: "bluesky", actor: clean });
    setProfileViewLoading(true);
    setProfileViewBlueskyProfile(null);
    setProfileViewBlueskyPosts([]);
    try {
      const [profile, posts] = await Promise.all([
        getBlueskyProfile(clean),
        getPublicBlueskyAuthorFeed(clean, { limit: 20 }),
      ]);
      setProfileViewBlueskyProfile(profile);
      setProfileViewBlueskyPosts(posts);
    } catch {
      setProfileViewBlueskyPosts([]);
    } finally {
      setProfileViewLoading(false);
    }
  }

  /**
   * Toggle follow on an author. Optimistic local state flips instantly; the
   * protocol write fires in the background. If the user has no keys/session,
   * route to Settings instead (smart-degrade, mirrors the Nostr-publish flow).
   */
  async function handleToggleFollow(kind: "nostr" | "bluesky", id: string) {
    const key = kind === "nostr" ? nostrFollowKey(id) : blueskyFollowKey(id);
    const nowFollowing = toggleFollow(key);
    setFollowedIds(getFollowedIds());

    if (kind === "nostr") {
      if (!nostrKeys) { setShowSettings(true); return; }
      void (nowFollowing
        ? publishNostrFollow(id)
        : publishNostrUnfollow(id)
      ).catch(() => { /* local state already reflects intent */ });
    } else {
      if (!session || !agent) { setShowSettings(true); return; }
      const profile = profileViewBlueskyProfile;
      if (!profile?.did) return;
      try {
        if (nowFollowing) {
          await followBlueskyAuthor(agent, session.did, profile.did);
        } else {
          // Without a stored followUri we can't delete by URI. Best-effort:
          // we keep the local "unfollowed" state; the server-side record may
          // linger until a future getFollows-driven cleanup. Acceptable for v1.
        }
      } catch {
        /* local state already reflects intent */
      }
    }
  }

  function openSkillProfile(skillId: string) {
    setProfileView({ kind: "skill", skillId });
    setProfileViewNotes([]);
    setProfileViewLoading(false);
  }

  /**
   * Repost a post. Optimistic local toggle flips the icon instantly; the
   * protocol write fires in the background. Smart-degrades to Settings when no
   * keys/session are connected (mirrors the follow/publish flows).
   *   - Nostr: kind-6 repost event (NIP-18).
   *   - Bluesky: app.bsky.feed.repost createRecord.
   */
  async function handleRepost(kind: "nostr" | "bluesky", postId: string, authorId?: string, blueskyCid?: string) {
    const nowReposted = toggleReposted(postId);
    setRepostedIds(getRepostedIds());
    if (kind === "nostr") {
      if (!nostrKeys) { setShowSettings(true); return; }
      void publishNostrRepost(postId, authorId || "").catch(() => { /* local state reflects intent */ });
    } else {
      if (!session || !agent) { setShowSettings(true); return; }
      try {
        if (nowReposted) {
          await repostBlueskyPost(agent, session.did, postId, blueskyCid || "");
        } else {
          // Without a stored repostUri we can't delete by URI. Best-effort for v1:
          // local "unreposted" state is correct; server record may linger.
        }
      } catch {
        /* local state reflects intent */
      }
    }
  }

  /**
   * Reply to a Bluesky post from the social Feed / Following / profile surfaces.
   * For a direct reply to a top-level post, root = parent = the post itself.
   * Mirrors handleReplyToBlueskyPost (the World-tab path) but reads the draft
   * from replyDrafts keyed by post uri.
   */
  async function handleBlueskyReplyFromCard(postUri: string, postCid: string) {
    const text = replyDrafts[postUri]?.trim();
    if (!text || !agent || !session) return;
    try {
      const bluesky = await loadBlueskyModule();
      await bluesky.replyToBlueskyPost(agent, session.did, text, postUri, postCid, postUri, postCid);
      setReplyDrafts((prev) => { const next = { ...prev }; delete next[postUri]; return next; });
      setReplyToast("Reply posted");
      window.setTimeout(() => setReplyToast((c) => (c === "Reply posted" ? null : c)), 2200);
    } catch {
      setReplyToast("Reply failed");
      window.setTimeout(() => setReplyToast((c) => (c === "Reply failed" ? null : c)), 2200);
    }
  }

  /**
   * Reply to a Nostr note from the social Feed / Following surfaces. Mirrors
   * handleNostrReply but uses the shared replyDrafts store keyed by note id.
   */
  async function handleNostrReplyFromCard(noteId: string, content: string) {
    if (!content.trim()) return;
    if (!nostrKeys) { setShowSettings(true); return; }
    try {
      const result = await publishNostrReply(noteId, content.trim());
      if (result.success) {
        // Refresh the thread so the new reply shows.
        void loadNostrReplies(noteId);
        setReplyDrafts((prev) => { const next = { ...prev }; delete next[noteId]; return next; });
        setReplyToast("Reply posted");
      } else {
        setReplyToast("Reply failed");
      }
      window.setTimeout(() => setReplyToast((c) => (c === "Reply posted" || c === "Reply failed" ? null : c)), 2200);
    } catch {
      setReplyToast("Reply failed");
      window.setTimeout(() => setReplyToast((c) => (c === "Reply failed" ? null : c)), 2200);
    }
  }

  function handleLikePost(post: PersistedPost) {
    if (post.liked) {
      // Unlike — just toggle off
      setPersistedPosts((prev) => {
        const next = prev.map((p) => p.id === post.id ? { ...p, liked: false } : p);
        savePersistedPosts(next);
        return next;
      });
      return;
    }
    // If user has posted to Nostr before (has keys + has posted), skip popup and post directly
    const hasPostedBefore = localStorage.getItem("slowclaw.nostr.hasPosted") === "true";
    if (hasPostedBefore && nostrKeys) {
      // Direct post without popup
      setPersistedPosts((prev) => {
        const next = prev.map((p) => p.id === post.id ? { ...p, liked: true } : p);
        savePersistedPosts(next);
        return next;
      });
      // Capture the Nostr event id so the Profile "Posted" tab can deep-link + verify.
      void publishNote(post.text).then((result) => {
        if (result.success && result.eventId) {
          setPersistedPosts((prev) => {
            const next = prev.map((p) => p.id === post.id ? { ...p, publishedAt: Date.now(), eventId: result.eventId } : p);
            savePersistedPosts(next);
            return next;
          });
        }
      });
      return;
    }
    // First time — show confirm dialog
    setNostrPostConfirmPost(post);
    setNostrPostConfirmStep("confirm");
  }

  async function handleNostrPostConfirm(wantsToPost: boolean) {
    if (!wantsToPost || !nostrPostConfirmPost) {
      // Just like locally, don't post
      if (nostrPostConfirmPost) {
        setPersistedPosts((prev) => {
          const next = prev.map((p) => p.id === nostrPostConfirmPost.id ? { ...p, liked: true } : p);
          savePersistedPosts(next);
          return next;
        });
      }
      setNostrPostConfirmPost(null);
      setNostrPostConfirmStep(null);
      return;
    }
    // User wants to post to Nostr — check if they have keys
    setNostrPostConfirmStep("account");
  }

  async function handleNostrAccountChoice(choice: "has_account" | "create" | "cancel") {
    if (choice === "cancel") {
      // Like locally but don't post
      if (nostrPostConfirmPost) {
        setPersistedPosts((prev) => {
          const next = prev.map((p) => p.id === nostrPostConfirmPost.id ? { ...p, liked: true } : p);
          savePersistedPosts(next);
          return next;
        });
      }
      setNostrPostConfirmPost(null);
      setNostrPostConfirmStep(null);
      return;
    }
    if (choice === "has_account") {
      // Like locally, prompt to enter key in Profile
      if (nostrPostConfirmPost) {
        setPersistedPosts((prev) => {
          const next = prev.map((p) => p.id === nostrPostConfirmPost.id ? { ...p, liked: true } : p);
          savePersistedPosts(next);
          return next;
        });
      }
      setNostrPostConfirmPost(null);
      setNostrPostConfirmStep(null);
      setShowSettings(true);
      return;
    }
    // choice === "create" — auto-generate keys and post
    if (nostrPostConfirmPost) {
      try {
        const { generateAndSaveNostrKeys } = await import("./lib/nostr");
        const keys = generateAndSaveNostrKeys();
        // Save to secure storage too
        await saveNostrKeysSecure(keys);
        setNostrKeys(keys);
        // Post to Nostr
        const result = await publishNote(nostrPostConfirmPost.text);
        if (result.success) {
          localStorage.setItem("slowclaw.nostr.hasPosted", "true");
          setPersistedPosts((prev) => {
            const next = prev.map((p) => p.id === nostrPostConfirmPost!.id ? { ...p, liked: true, publishedAt: Date.now(), eventId: result.eventId } : p);
            savePersistedPosts(next);
            return next;
          });
        }
      } catch {
        // Still like locally even if post fails
        setPersistedPosts((prev) => {
          const next = prev.map((p) => p.id === nostrPostConfirmPost!.id ? { ...p, liked: true } : p);
          savePersistedPosts(next);
          return next;
        });
      }
    }
    setNostrPostConfirmPost(null);
    setNostrPostConfirmStep(null);
  }

  async function handleFeedPullRefresh() {
    // Guard against concurrent calls
    if (generatePostBusy) return;
    const entry = getNextJournalForProcessing();
    if (!entry) {
      setGeneratePostStatus("Write a journal entry first, then pull to generate posts.");
      return;
    }
    if (!requireModel()) return;
    setGeneratePostBusy(true);
    setGeneratePostStatus("✨ Generating posts from your journal...");
    try {
      const posts: string[] = [];
      if (isTauriMobileRuntime()) {
        const existingTexts = persistedPosts.slice(0, 10).map((p) => p.text);
        const dedupeNote = existingTexts.length > 0
          ? `\nIMPORTANT: Do NOT generate anything similar to these existing posts:\n${existingTexts.map((t, i) => `${i + 1}. ${t}`).join("\n")}\n`
          : "";
        const chunks = splitIntoChunks(entry.text, CHUNK_CHAR_LIMIT);
        for (let i = 0; i < chunks.length; i++) {
          if (chunks.length > 1) setGeneratePostStatus(`Generating post ${i + 1}/${chunks.length}...`);
          let postText = "";
          for (let attempt = 0; attempt < 3; attempt++) {
            const result = await nativeAiChat(
              chunks[i],
              tweetClawPrompt + dedupeNote,
              256,
              0.8 + attempt * 0.1
            );
            postText = result.text.replace(/^["']|["']$/g, '').trim();
            if (postText.length > 10 && postText.length < 400) break;
          }
          if (postText) posts.push(postText);
        }
      } else {
        const token = await resolveRuntimeGatewayToken();
        const response = await fetch(`${gatewayBaseUrl || ""}/api/chat/messages`, {
          method: "POST",
          headers: { "Content-Type": "application/json", ...(token ? { Authorization: `Bearer ${token}` } : {}) },
          body: JSON.stringify({ threadId: createThreadId(), content: `Turn this journal entry into a concise tweet-style post (under 280 chars). Output ONLY the post:\n\n${entry.text}` }),
        });
        if (!response.ok) throw new Error(`Gateway returned ${response.status}`);
        const data = await response.json();
        posts.push((data.content || data.text || "").trim());
      }
      const newPosts: PersistedPost[] = posts.filter((t) => t.trim()).map((t) => ({
        id: `post_${Date.now()}_${Math.random().toString(36).slice(2, 8)}`,
        text: t.trim(),
        sourceExcerpt: entry.text.slice(0, 120),
        createdAt: Date.now(),
      }));
      if (newPosts.length > 0) {
        setPersistedPosts((prev) => { const next = [...newPosts, ...prev]; savePersistedPosts(next); return next; });
      }
      // Mark this journal as processed
      markJournalProcessed(entry.path);
      if (posts.length === 0) {
        // The model ran without throwing but produced no usable output. This is
        // the "generating then nothing" symptom: nativeAiChat resolved with
        // empty/garbage text (model emitted EOS immediately, wrong chat template,
        // or output outside the length gate across all 3 retries). Surface it as
        // an actionable message instead of silent "Generated 0 posts".
        setGeneratePostStatus(
          "Model produced no output. The model may need re-downloading, or its chat template may not match this build. Try Settings → Delete Model, then re-download.",
        );
      } else {
        setGeneratePostStatus(`✨ Generated ${posts.length} post${posts.length > 1 ? 's' : ''} from your journal`);
      }
    } catch (error) {
      setGeneratePostStatus(`Generation failed: ${error instanceof Error ? error.message : String(error)}`);
    } finally {
      setGeneratePostBusy(false);
    }
  }

  async function handleTasksPullRefresh() {
    // Guard against concurrent calls
    if (extractingLocalTasks) return;
    const entry = getNextJournalForProcessing();
    if (!entry) {
      setGeneratePostStatus("Write a journal entry first, then pull to extract tasks.");
      return;
    }
    if (!requireModel()) return;
    setExtractingLocalTasks(true);
    setGeneratePostStatus("🧠 Extracting tasks from your journal...");
    try {
      const existingTitles = persistedTodos.slice(0, 10).map((t) => t.title);
      const dedupeNote = existingTitles.length > 0
        ? `\nDo NOT extract tasks similar to these existing ones:\n${existingTitles.map((t, i) => `${i + 1}. ${t}`).join("\n")}\n`
        : "";
      const taskPrompt = `You extract action items and tasks from journal entries. Output a JSON array of objects with "title" and "details" fields. Only real actionable tasks. Output ONLY valid JSON, no markdown fences. Example: [{"title":"Buy groceries","details":"Need milk and eggs"}]${dedupeNote}`;
      const chunks = splitIntoChunks(entry.text, CHUNK_CHAR_LIMIT);
      const allParsed: Array<{ title: string; details?: string }> = [];
      for (let i = 0; i < chunks.length; i++) {
        for (let attempt = 0; attempt < 3; attempt++) {
          const result = await nativeAiChat(chunks[i], taskPrompt, 512, 0.2 + attempt * 0.1);
          const parsed = tryParseJsonArray<{ title: string; details?: string }>(result.text);
          if (parsed && parsed.length > 0) { allParsed.push(...parsed); break; }
          if (attempt === 2) {
            const lines = result.text.split("\n").filter((l) => /^\s*[-*\d.]/.test(l));
            allParsed.push(...lines.map((l) => ({ title: l.replace(/^\s*[-*\d.]+\s*/, "").trim() })));
          }
        }
      }
      if (allParsed.length > 0) {
        const newTodos: PersistedTodo[] = allParsed
          .filter((t) => t.title?.trim())
          .map((t) => ({
            id: `todo_${Date.now()}_${Math.random().toString(36).slice(2, 8)}`,
            title: t.title.trim(),
            details: (t.details || "").trim(),
            done: false,
            createdAt: Date.now(),
          }));
        setPersistedTodos((prev) => {
          const existingTitles = new Set(prev.map((t) => t.title.toLowerCase()));
          const unique = newTodos.filter((t) => !existingTitles.has(t.title.toLowerCase()));
          const next = [...unique, ...prev]; savePersistedTodos(next); return next;
        });
      }
      markJournalProcessed(entry.path);
      setGeneratePostStatus(allParsed.length > 0
        ? `✅ Extracted ${allParsed.length} task${allParsed.length > 1 ? 's' : ''} from your journal`
        : "No tasks found in this journal entry. Try pulling again."
      );
    } catch (error) {
      setGeneratePostStatus(`Task extraction failed: ${error instanceof Error ? error.message : String(error)}`);
    } finally {
      setExtractingLocalTasks(false);
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
        const savedProvider = normalizeProviderId(window.localStorage.getItem(CHAT_PROVIDER_STORAGE_KEY) || "");
        const savedModel = window.localStorage.getItem(CHAT_MODEL_STORAGE_KEY);
        let runtimeCfg: Awaited<ReturnType<typeof getRuntimeConfig>> | null = null;
        if (gatewayBaseUrl.trim()) {
          runtimeCfg = await getRuntimeConfig(token || undefined, gatewayBaseUrl).catch(() => null);
        }
        setSettingsProvider(
          normalizeProviderId(runtimeCfg?.defaultProvider || "") || savedProvider || "ollama"
        );
        setSettingsModel(runtimeCfg?.defaultModel || (savedModel && savedModel.trim()) || cfg.ollamaModel || "");
        setSettingsApiUrl(runtimeCfg?.apiUrl || "");
        setSettingsTranscriptionEnabled(Boolean(cfg.transcriptionEnabled));
        setSettingsTranscriptionModel(runtimeCfg?.transcriptionModel || cfg.ollamaModel || "");
        let models = await listOllamaModels().catch(() => [] as string[]);
        if (runtimeCfg) {
          setRuntimeMediaCapabilities(runtimeCfg.mediaCapabilities || null);
          setRuntimeMediaSummary(runtimeCfg.mediaSummary || "");
        }
        if (!models.length && runtimeCfg) {
          models =
            runtimeCfg.availableTranscriptionModels && runtimeCfg.availableTranscriptionModels.length > 0
              ? [...runtimeCfg.availableTranscriptionModels]
              : [];
          const runtimeModel = runtimeCfg.transcriptionModel || "";
          if (runtimeModel && !models.includes(runtimeModel)) {
            models.unshift(runtimeModel);
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
      setSettingsProvider(normalizeProviderId(cfg.defaultProvider || ""));
      setSettingsModel(cfg.defaultModel || "");
      setSettingsApiUrl(cfg.apiUrl || "");
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

  function applyLocalAiPreset(provider: string, model: string, apiUrl: string) {
    setSettingsProvider(provider);
    setSettingsModel(model);
    setSettingsApiUrl(apiUrl);
    setProviderApiKey("");
    setSettingsConfigStatus(`Selected ${provider} local runtime. Save configuration to apply it.`);
  }

  async function saveRuntimeConfigFromSettings() {
    const provider = normalizeProviderId(settingsProvider);
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
          setSettingsConfigStatus("Saved local desktop config. Applying runtime config...");
        } catch (localError) {
          const missingGet = isMissingDesktopCommand(localError, "get_config");
          const missingSave = isMissingDesktopCommand(localError, "save_config");
          if (!missingGet && !missingSave) {
            throw localError;
          }
          setSettingsConfigStatus("Local config command unavailable, saving via gateway...");
        }
      }
      if (!token) {
        setSettingsConfigStatus("Save blocked (gateway token missing).");
        return;
      }

      await updateRuntimeConfig(
        {
          defaultProvider: provider,
          defaultModel: model,
          apiUrl: settingsApiUrl.trim(),
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
    if (!showSettings) {
      return;
    }
    void loadRuntimeConfigForSettings();
    void loadLocalModels();
  }, [showSettings, chatGatewayToken, gatewayBaseUrl]);

  useEffect(() => {
    if (!showSettings) {
      return;
    }
    const hasActiveDownload = localModels.some((model) => model.download?.status === "downloading");
    if (!hasActiveDownload && !localModelRuntime?.running) {
      return;
    }
    const timer = window.setInterval(() => {
      if (hasActiveDownload) {
        void loadLocalModels();
      }
      if (localModelRuntime?.running) {
        void refreshLocalModelRuntime();
      }
    }, 2000);
    return () => window.clearInterval(timer);
  }, [mobileTab, localModels, localModelRuntime?.running]);

  // Load local model catalog on app startup
  useEffect(() => {
    void loadLocalModels();
    // Sync Metal mode preference to backend on startup
    if (metalMode && isTauriMobileRuntime()) {
      void setMetalModeBackend(true).catch(() => {});
    }
  }, [chatGatewayToken, gatewayBaseUrl]);

  // Seed journal items in local dev / public demo for UI preview (delayed to run after refresh attempts)
  useEffect(() => {
    if (!isDemoContext()) return;
    const timer = setTimeout(() => {
      // Only seed if journals are still empty (refresh didn't find anything)
      setJournalItems((prev) => {
        if (prev.length > 0) return prev;
        setSelectedJournalPath(DEV_SAMPLE_JOURNALS[0].path);
        setSelectedJournalText(DEV_SAMPLE_JOURNALS[0].previewText || "");
        setJournalDraftText(DEV_SAMPLE_JOURNALS[0].previewText || "");
        return DEV_SAMPLE_JOURNALS;
      });
    }, 500);
    return () => clearTimeout(timer);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  // Re-check model status when app comes back to foreground (after screen lock/unlock)
  // iOS suspends the gateway when the app is backgrounded. On resume, the gateway
  // needs a moment to restart, so we retry with increasing delays.
  useEffect(() => {
    let t1: ReturnType<typeof setTimeout> | undefined;
    let t2: ReturnType<typeof setTimeout> | undefined;
    function handleVisibility() {
      if (document.visibilityState !== "visible") return;
      // Clear any pending retries from a previous resume cycle
      clearTimeout(t1); clearTimeout(t2);
      // Immediate check (picks up native AI status even if gateway is slow)
      void loadLocalModels();
      // Retry after 1.5s — gateway usually restarts within this window
      t1 = setTimeout(() => void loadLocalModels(), 1500);
      // Final retry at 4s for slow restarts
      t2 = setTimeout(() => void loadLocalModels(), 4000);
    }
    document.addEventListener("visibilitychange", handleVisibility);
    return () => {
      document.removeEventListener("visibilitychange", handleVisibility);
      clearTimeout(t1); clearTimeout(t2);
    };
  }, [chatGatewayToken, gatewayBaseUrl]);

  useEffect(() => {
    if (mobileTab !== "feed" && mobileTab !== "profile" && mobileTab !== "journal") {
      return;
    }
    void loadRuntimeMediaCapabilities();
  }, [mobileTab, feedSource, chatGatewayToken, gatewayBaseUrl]);

  // Auto-load social feed (Nostr / Bluesky / Following) when the Feed tab is shown and empty.
  useEffect(() => {
    if (mobileTab === "feed" && feedView === "social") {
      if (socialSource === "following") {
        if (followingItems.length === 0 && !followingLoading) void loadFollowingFeedApp();
      } else if (socialSource === "bluesky") {
        if (blueskyPublicPosts.length === 0 && !blueskyPublicLoading) void loadBlueskyPublicFeed();
      } else if (nostrFeedNotes.length === 0 && !nostrFeedLoading) {
        void loadNostrFeed();
      }
    }
  }, [mobileTab, feedView, socialSource]);

  // Auto-load tech news when the Feed's News view is shown and empty.
  useEffect(() => {
    if (mobileTab === "feed" && feedView === "news" && techNewsItems.length === 0 && !techNewsLoading) {
      void loadTechNews();
    }
  }, [mobileTab, feedView]);

  // Load Bluesky video posts when the Feed tab opens, so the inline videos and
  // the tap-to-fullscreen overlay have content to show. (The dedicated Reels tab
  // was removed; video now lives in the unified Feed.)
  useEffect(() => {
    if (mobileTab === "feed" && reelsPosts.length === 0 && !reelsLoading) {
      void loadReelsFeed();
    }
  }, [mobileTab]);

  // Auto-load Reads when the Reads tab is shown and empty (or when source/feed selection changes).
  useEffect(() => {
    if (mobileTab === "reads") {
      if (readsSource === "nostr" && readsArticles.length === 0 && !readsLoading) void loadReadsFeed();
      else if (readsSource === "rss" && readsRssItems.length === 0 && !readsLoading) void loadReadsFeed();
      // YouTube (keyless) fetches by journal topics when toggled on; clear on off.
      if (readsYouTubeEnabled && readsYouTubeItems.length === 0) void loadYouTubeReads();
      if (!readsYouTubeEnabled && readsYouTubeItems.length > 0) setReadsYouTubeItems([]);
    }
  }, [mobileTab, readsSource, activeRssFeedIds, readsYouTubeEnabled]);

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

  // Periodic auto-save every 60s while writing (catches long idle sessions)
  useEffect(() => {
    if (!isWritingNote && !selectedJournalItem) return;
    const timer = window.setInterval(() => {
      if (journalDraftText.trim() && (selectedJournalItem || !selectedJournalPath.trim())) {
        void saveJournalTextDraft();
      }
    }, 60_000);
    return () => window.clearInterval(timer);
  }, [isWritingNote, selectedJournalItem]);

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
  const installedLocalModelCount = localModels.filter((model) => model.installed).length;
  const activeLocalModel =
    localModels.find((model) => model.active) ||
    localModels.find((model) => nativeLocalAiStatus?.modelId === model.id) ||
    localModels.find((model) => localModelRuntime?.modelId === model.id) ||
    null;
  const localAiReady = Boolean(
    localModelRuntime?.running || nativeLocalAiStatus?.configured || activeLocalModel
  );
  const localAiStateLabel = localModelRuntime?.running
    ? "Running"
    : nativeLocalAiStatus?.configured
    ? "Configured"
    : installedLocalModelCount > 0
    ? "Downloaded"
    : "Setup needed";
  // The mobile->desktop pairing scanner is irrelevant in the public demo build and on
  // localhost (no desktop to pair with); isDemoContext() covers both. Bypassing it keeps
  // the real app UI visible in the in-browser demo.
  const needsMobileQrLogin = !isNativeClient && !isDemoContext() && !(chatGatewayToken.trim() && gatewayBaseUrl.trim());
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
  const isTextEntrySelected =
    !!selectedJournalItem && selectedJournalItem.kind === "text";
  const isFreshNoteMode = !selectedJournalItem;
  const showCaptureCard =
    !isWritingNote && !isCaptureZenMode && !isTextEntrySelected;
  const expandSession =
    isWritingNote || isMediaTranscriptMode || isFreshNoteMode || isTextEntrySelected;

  // Swipe navigation between tabs
  const swipeToNextTab = () => {
    const idx = TAB_ORDER.indexOf(mobileTab);
    if (idx < TAB_ORDER.length - 1) setMobileTab(TAB_ORDER[idx + 1]);
  };
  const swipeToPrevTab = () => {
    const idx = TAB_ORDER.indexOf(mobileTab);
    if (idx > 0) setMobileTab(TAB_ORDER[idx - 1]);
  };
  const enableSwipe = !isDesktopLayout && !isRecording && !isWritingNote;
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

      {isTauriMobileRuntime() ? (
        <button
          type="button"
          className="ghost"
          style={{ marginBottom: "0.75rem", width: "100%" }}
          onClick={() => void importAndTranscribeVoiceMemos()}
          disabled={importingVoiceMemos}
        >
          {importingVoiceMemos ? (
            <span className="row" style={{ gap: "0.45rem", alignItems: "center" }}>
              <span className="btn-spinner" aria-hidden />
              Importing voice memos…
            </span>
          ) : (
            "Import Voice Memos"
          )}
        </button>
      ) : null}

      {journalItems.length === 0 ? (
        <p className="text-center muted">No journals found.</p>
      ) : filteredJournalList.length === 0 ? (
        <p className="text-center muted">No journals match your search.</p>
      ) : (
        <div className="journal-list">
          {filteredJournalList.map(item => {
            const isActive = selectedJournalPath === item.path;
            const preview = item.previewText?.slice(0, 60) || (item.kind !== "text" ? `${item.kind} recording` : "");
            return (
              <div
                key={item.path}
                className={`journal-list-item${isActive ? " active" : ""}`}
                onClick={() => {
                  setSelectedJournalPath(item.path);
                  if (closeOnSelect) setJournalSidebarOpen(false);
                }}
              >
                <div className="journal-list-item-content">
                  <div className="journal-list-item-top">
                    <span className="journal-list-item-title">{item.title}</span>
                    <span className="journal-list-item-time">{getRelativeTime(item.modifiedAt * 1000)}</span>
                  </div>
                  {preview && <p className="journal-list-item-preview">{preview}</p>}
                </div>
                <button
                  type="button"
                  className="ghost journal-list-item-delete"
                  onClick={(e) => {
                    e.stopPropagation();
                    setPendingDeleteJournalItem(item);
                  }}
                  title={`Delete ${item.title}`}
                >
                  <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round"><polyline points="3 6 5 6 21 6"/><path d="M19 6l-1 14a2 2 0 0 1-2 2H8a2 2 0 0 1-2-2L5 6"/></svg>
                </button>
              </div>
            );
          })}
        </div>
      )}
    </>
  );

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
      {isDemoContext() && (
        <div className="demo-banner" role="status">
          <span>
            <strong>Demo mode</strong> — exploring with sample data. Nothing is saved to a server.
          </span>
          <a className="demo-banner-link" href="/">Back to site ↑</a>
        </div>
      )}
      {!hideChrome && (
        <header className={`topbar${scrollDirection === "down" ? " topbar-hidden" : ""}`}>
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
              className={`ghost ${showSettings ? "active-icon-btn" : ""}`}
              onClick={() => setShowSettings((prev) => !prev)}
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

      <SwipeableView
        onSwipeLeft={swipeToNextTab}
        onSwipeRight={swipeToPrevTab}
        enabled={enableSwipe}
      >
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

              {showCaptureCard && !isMediaTranscriptMode && (
                <div className="card">
                  <div className="text-center">
                    <h2>Capture</h2>
                    <p className="text-sm" style={{ marginTop: "0.5rem" }}>
                      {recordingHint || "Record audio or video directly to workspace"}
                    </p>
                  </div>
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
                      <div className="text-center" style={{ marginTop: "0.5rem" }}>
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
                </div>
              )}

              {!isCaptureZenMode && (
                <div
                  className={`card ${expandSession ? "note-card-expanded" : ""}`}
                  style={{ flex: expandSession ? 1 : undefined }}
                >
                  <div className="row-between" style={{ padding: isWritingNote ? '0.5rem 0' : undefined }}>
                    <div className="row" style={{ gap: '0.5rem', alignItems: 'center' }}>
                      <h2 style={{ margin: 0 }}>{isTextEntrySelected ? selectedJournalItem?.title || "Journal" : "Journal"}</h2>
                    </div>
                    <div className="row" style={{ gap: '0.5rem', alignItems: 'center' }}>
                      <span className="text-sm muted">{journalSaveStatus !== "Journal idle" ? journalSaveStatus : ""}</span>
                      {(isWritingNote || isTextEntrySelected) && <button type="button" className="primary" style={{ padding: '0.5rem 1.2rem', fontSize: '0.95rem' }} onClick={() => void handleJournalDone()}>Done</button>}
                    </div>
                  </div>
                  {selectedJournalItem && selectedJournalItem.kind === "audio" && (
                    <div className="row" style={{ marginBottom: "0.6rem", alignItems: "center", gap: "0.5rem" }}>
                      {audioPlaybackUrl ? (
                        <audio
                          controls
                          preload="metadata"
                          src={audioPlaybackUrl}
                          style={{ width: "100%", maxWidth: "26rem" }}
                        />
                      ) : audioPlaybackLoading ? (
                        <span className="text-sm muted">Loading recording…</span>
                      ) : null}
                    </div>
                  )}
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
                  {showFirstEntryPrompt && !journalDraftText.trim() ? (
                    <div className="first-entry-prompt" aria-hidden={Boolean(journalDraftText.trim())}>
                      {FIRST_ENTRY_PROMPTS[new Date().getDate() % FIRST_ENTRY_PROMPTS.length]}
                    </div>
                  ) : null}
                  <textarea
                    className="journal-textarea-autoexpand"
                    value={journalDraftText}
                    onChange={(e) => {
                      setJournalDraftText(e.target.value);
                      // Auto-expand: reset height then set to scrollHeight
                      const el = e.target;
                      el.style.height = "auto";
                      el.style.height = el.scrollHeight + "px";
                    }}
                    onFocus={(e) => {
                      if (!isMediaTranscriptMode) {
                        setIsWritingNote(true);
                      }
                      // Expand to content on focus
                      const el = e.target;
                      el.style.height = "auto";
                      el.style.height = el.scrollHeight + "px";
                    }}
                    placeholder={showFirstEntryPrompt ? "What's on your mind today?" : "Write your thoughts..."}
                  />
                </div>
              )}

              {/* Interest reveal: shows what the on-device AI inferred from the
                  just-saved entry, with removable chips + a jump to the Feed. */}
              {!isCaptureZenMode && lastExtractedInterests.length > 0 && !dismissedInterestReveal ? (
                <div className="card interest-reveal-card">
                  <div className="interest-reveal-header">
                    <span className="interest-reveal-icon" aria-hidden>✨</span>
                    <div>
                      <h3 style={{ margin: 0, fontSize: '1rem' }}>Tuned your feed from this entry</h3>
                      <p className="text-sm muted" style={{ margin: '0.15rem 0 0' }}>Tap ✕ to remove one, or see your personalized feed.</p>
                    </div>
                  </div>
                  <div className="topic-chips interest-reveal-chips">
                    {lastExtractedInterests.map((keyword) => (
                      <button
                        key={keyword}
                        type="button"
                        className="topic-chip interest-reveal-chip"
                        onClick={() => void removeRevealedInterest(keyword)}
                        title={`Remove "${keyword}"`}
                      >
                        {keyword} <span className="interest-reveal-x" aria-hidden>✕</span>
                      </button>
                    ))}
                  </div>
                  <div className="row" style={{ marginTop: '0.75rem', gap: '0.5rem' }}>
                    <button type="button" className="primary" onClick={() => seePersonalizedFeed()}>See your feed →</button>
                    <button type="button" className="ghost text-sm" onClick={() => setDismissedInterestReveal(true)}>Dismiss</button>
                  </div>
                </div>
              ) : null}

              </div>
            </div>
          </ViewErrorBoundary>
        ) : null}

        {mobileTab === "queue" ? (
          <ViewErrorBoundary title="Queue">
            <PullToRefresh onRefresh={handleFeedPullRefresh} enabled={!generatePostBusy}>
            <div className="stack">
              <div className="feed-tab-container">
              <div className="row-between" style={{ padding: '0 0.25rem' }}>
                <h2>Queue</h2>
                {generatePostBusy && (
                  <span className="row" style={{ gap: '0.3rem', alignItems: 'center' }}>
                    <span className="btn-spinner" aria-hidden />
                    <span className="text-sm muted">Generating...</span>
                  </span>
                )}
              </div>

              {persistedPosts.length === 0 && (
                <div className="feed-create-hero">
                  <div className="feed-create-hero-icon">✨</div>
                  <h3>Turn journals into posts</h3>
                  <p className="text-sm muted">Write in your journal, then pull down here to generate tweet-ready posts using on-device AI.</p>
                  <button
                    type="button"
                    className="primary"
                    onClick={() => setMobileTab("journal")}
                  >
                    Open Journal
                  </button>
                </div>
              )}

              {persistedPosts.length > 0 && (
                <div className="feed-posts-list">
                  {persistedPosts.map((post) => {
                    const timeAgo = getRelativeTime(post.createdAt);
                    return (
                      <div key={post.id} className="tweet-card">
                        <div className="tweet-avatar" style={{ cursor: 'pointer' }} onClick={() => openSkillProfile("tweetclaw")} aria-hidden>🐾</div>
                        <div className="tweet-body">
                          <div className="tweet-header">
                            <span className="tweet-name" style={{ cursor: 'pointer' }} onClick={() => openSkillProfile("tweetclaw")}>TweetClaw</span>
                            <span className="tweet-handle" style={{ cursor: 'pointer' }} onClick={() => openSkillProfile("tweetclaw")}>@tweetclaw</span>
                            <span className="tweet-dot">·</span>
                            <span className="tweet-time">{timeAgo}</span>
                          </div>
                          <textarea
                            className="tweet-text-edit"
                            value={post.text}
                            onChange={(e) => {
                              const newText = e.target.value;
                              setPersistedPosts((prev) => {
                                const next = prev.map((p) => p.id === post.id ? { ...p, text: newText } : p);
                                savePersistedPosts(next);
                                return next;
                              });
                              // Auto-expand for iOS 18 which lacks field-sizing: content
                              const el = e.target;
                              el.style.height = 'auto';
                              el.style.height = el.scrollHeight + 'px';
                            }}
                            onFocus={(e) => { const el = e.target; el.style.height = 'auto'; el.style.height = el.scrollHeight + 'px'; }}
                            ref={(el) => { if (el) { el.style.height = 'auto'; el.style.height = el.scrollHeight + 'px'; } }}
                          />
                          <div className="tweet-actions">
                            <button type="button" className={`tweet-action${post.liked ? " liked" : ""}`} onClick={() => handleLikePost(post)} title="Like">
                              <svg viewBox="0 0 24 24" fill={post.liked ? "currentColor" : "none"} stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round"><path d="M20.84 4.61a5.5 5.5 0 0 0-7.78 0L12 5.67l-1.06-1.06a5.5 5.5 0 0 0-7.78 7.78l1.06 1.06L12 21.23l7.78-7.78 1.06-1.06a5.5 5.5 0 0 0 0-7.78z"/></svg>
                            </button>
                            <button type="button" className="tweet-action" onClick={() => {
                              setPersistedPosts((prev) => { const next = prev.filter((p) => p.id !== post.id); savePersistedPosts(next); return next; });
                            }} title="Delete">
                              <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round"><polyline points="3 6 5 6 21 6"/><path d="M19 6v14a2 2 0 0 1-2 2H7a2 2 0 0 1-2-2V6m3 0V4a2 2 0 0 1 2-2h4a2 2 0 0 1 2 2v2"/></svg>
                            </button>
                          </div>
                        </div>
                      </div>
                    );
                  })}
                </div>
              )}

              {generatePostStatus && (
                <p className="text-sm muted" style={{ padding: '0.5rem 0.25rem' }}>{generatePostStatus}</p>
              )}

              {/* Tasks folded into Queue (was its own tab). */}
              {renderTasksSection()}
              </div>
            </div>
            </PullToRefresh>
          </ViewErrorBoundary>
        ) : null}

        {mobileTab === "feed" ? (
          <ViewErrorBoundary title="Feed">
            {/* New-posts pill (#4): surfaces when fresh social items arrive. */}
            {newPostsCount > 0 ? (
              <button
                type="button"
                className="new-posts-pill"
                onClick={() => { window.scrollTo({ top: 0, behavior: "smooth" }); setNewPostsCount(0); }}
              >
                ↑ {newPostsCount} new {newPostsCount === 1 ? "post" : "posts"}
              </button>
            ) : null}
            <PullToRefresh onRefresh={withRefreshToast("Feed updated", () => loadSocialFeed())} enabled={!(nostrFeedLoading || blueskyPublicLoading || followingLoading)}>
            <div className="stack">
              <div className="feed-tab-container">
                <div className="row-between" style={{ padding: '0 0.25rem', alignItems: 'center' }}>
                  <h2>Feed</h2>
                  {/* News lives in the Reads tab now — Feed is social-only (your follows + open-protocol channels). */}
                </div>

                {feedView === "news" ? (
                  <>
                    <div className="social-section-label">Hacker News · top stories</div>
                    {techNewsLoading && techNewsItems.length === 0 ? (
                      <div className="tech-news-list">
                        {[0, 1, 2, 3, 4].map((i) => (
                          <div key={i} className="tech-news-skeleton-card">
                            <div className="tech-news-skeleton">
                              <div className="tech-news-skeleton-row short" />
                              <div className="tech-news-skeleton-row" />
                            </div>
                          </div>
                        ))}
                      </div>
                    ) : techNewsError && techNewsItems.length === 0 ? (
                      <div>
                        <p className="tech-news-error">{techNewsError}</p>
                        <button type="button" className="ghost text-sm" onClick={() => void loadTechNews()}>Retry</button>
                      </div>
                    ) : techNewsItems.length > 0 ? (
                      <div className="tech-news-list">
                        {techNewsItems.map((item, idx) => (
                          <a
                            key={item.id}
                            className="tech-news-card"
                            href={item.url}
                            target="_blank"
                            rel="noopener noreferrer"
                            onClick={(e) => {
                              e.preventDefault();
                              void openFeedLink(item.url);
                            }}
                          >
                            {item.thumbnailUrl ? (
                              <img src={item.thumbnailUrl} alt="" className="tech-news-card-thumb" loading="lazy" />
                            ) : null}
                            <div className="tech-news-card-rank">#{idx + 1} · <span className="tech-news-card-source">{item.source}</span></div>
                            <p className="tech-news-card-title">{item.title}</p>
                            <div className="tech-news-card-meta">
                              <span className="tech-news-card-stat">▲ {item.score}</span>
                              <span className="tech-news-card-dot">·</span>
                              <span className="tech-news-card-stat">💬 {item.comments}</span>
                              <span className="tech-news-card-dot">·</span>
                              <span>{getRelativeTime(item.createdAt * 1000)}</span>
                            </div>
                          </a>
                        ))}
                      </div>
                    ) : (
                      <p className="text-sm muted" style={{ padding: '0.4rem 0' }}>No tech news right now.</p>
                    )}
                  </>
                ) : (
                  <>
                    <div className="social-section-label">{socialSource === "following" ? "Home · your follows" : "Channels · open-protocol feeds"}</div>
                    {renderSourceAndChannels()}
                    {/* Show how many notes the quality filter dropped (language/spam/dedup). */}
                    {socialSource === "nostr" && nostrFeedStats && nostrFeedNotes.length > 0 ? (
                      <p className="text-sm muted" style={{ padding: '0.2rem 0.25rem 0', fontSize: '0.72rem' }}>
                        Filtered {nostrFeedStats.droppedNonLanguage + Object.values(nostrFeedStats.droppedSpam).reduce((a, b) => a + b, 0) + nostrFeedStats.droppedDuplicate} of {nostrFeedStats.total} (non-English, spam, duplicates)
                      </p>
                    ) : null}

                    {socialSource === "following" ? (
                      followingLoading && followingItems.length === 0 ? (
                        <div style={{ padding: '2rem', textAlign: 'center' }}>
                          <span className="btn-spinner" aria-hidden />
                          <p className="text-sm muted" style={{ marginTop: '0.5rem' }}>Loading your timeline…</p>
                        </div>
                      ) : followingError ? (
                        <div className="feed-empty-filtered">
                          <p className="text-sm muted" style={{ margin: 0 }}>{followingError}</p>
                          <button type="button" className="ghost text-sm" style={{ marginTop: '0.5rem' }} onClick={() => void loadFollowingFeedApp()}>Retry</button>
                        </div>
                      ) : getFollowedIds().length === 0 ? (
                        <div className="feed-create-hero">
                          <div className="feed-create-hero-icon">👥</div>
                          <h3>Follow people to build your timeline</h3>
                          <p className="text-sm muted">Tap any author's name in the Nostr or Bluesky feeds, then Follow. Their newest posts will appear here — your home timeline, across both protocols.</p>
                          <button type="button" className="primary" onClick={() => { setSocialSource("nostr"); setActiveChannelId(""); }}>Discover on Nostr</button>
                          <button type="button" className="ghost text-sm" style={{ marginTop: '0.5rem' }} onClick={() => setMobileTab("journal")}>✍️ Write a journal entry</button>
                        </div>
                      ) : followingItems.length === 0 ? (
                        <div className="feed-empty-filtered">
                          <p className="text-sm muted" style={{ margin: 0 }}>No recent posts from the {getFollowedIds().length} {getFollowedIds().length === 1 ? "person" : "people"} you follow.</p>
                          <button type="button" className="ghost text-sm" style={{ marginTop: '0.5rem' }} onClick={() => void loadFollowingFeedApp()}>Refresh</button>
                        </div>
                      ) : (
                        <div className="feed-posts-list">
                          {followingItems.slice(0, feedVisibleCount).map((item) =>
                            item.nostrNote ? renderNostrNoteCard(item.nostrNote)
                            : item.blueskyPost ? renderBlueskyCard(item.blueskyPost)
                            : null
                          )}
                          {followingItems.length > feedVisibleCount ? (
                            <button type="button" className="load-more-btn" onClick={() => setFeedVisibleCount((c) => c + 20)}>Show more</button>
                          ) : null}
                        </div>
                      )
                    ) : socialSource === "nostr" ? (
                      nostrFeedLoading && nostrFeedNotes.length === 0 ? (
                        <div style={{ padding: '2rem', textAlign: 'center' }}>
                          <span className="btn-spinner" aria-hidden />
                          <p className="text-sm muted" style={{ marginTop: '0.5rem' }}>Loading Nostr…</p>
                        </div>
                      ) : socialFeedError ? (
                        <div className="feed-empty-filtered">
                          <p className="text-sm muted" style={{ margin: 0 }}>{socialFeedError}</p>
                          <button type="button" className="ghost text-sm" style={{ marginTop: '0.5rem' }} onClick={() => void loadNostrFeed()}>Retry</button>
                        </div>
                      ) : nostrFeedNotes.length === 0 ? (
                        <div className="feed-create-hero">
                          <div className="feed-create-hero-icon">🌐</div>
                          <h3>Discover on Nostr</h3>
                          <p className="text-sm muted">Pick a channel above to subscribe to a Nostr topic. Hashtags stream live from relays — try #nostr or #bitcoin.</p>
                          <button type="button" className="primary" onClick={() => void loadNostrFeed()}>Load Feed</button>
                        </div>
                      ) : visibleNostrNotes.length === 0 ? (
                        <div className="feed-empty-filtered">
                          <p className="text-sm muted" style={{ margin: 0 }}>No notes match “{activeSocialTopic}” right now.</p>
                          <button type="button" className="ghost text-sm" style={{ marginTop: '0.5rem' }} onClick={() => setActiveSocialTopic("")}>Clear filter</button>
                        </div>
                      ) : (
                        <div className="feed-posts-list">
                          {visibleNostrNotes.slice(0, feedVisibleCount).map((note) => renderNostrNoteCard(note))}
                          {visibleNostrNotes.length > feedVisibleCount ? (
                            <button type="button" className="load-more-btn" onClick={() => setFeedVisibleCount((c) => c + 20)}>Show more</button>
                          ) : null}
                        </div>
                      )
                    ) : (
                      // Bluesky source
                      blueskyPublicLoading && blueskyPublicPosts.length === 0 ? (
                        <div style={{ padding: '2rem', textAlign: 'center' }}>
                          <span className="btn-spinner" aria-hidden />
                          <p className="text-sm muted" style={{ marginTop: '0.5rem' }}>Searching Bluesky…</p>
                        </div>
                      ) : blueskyPublicError ? (
                        <div className="feed-empty-filtered">
                          <p className="text-sm muted" style={{ margin: 0 }}>{blueskyPublicError}</p>
                          <button type="button" className="ghost text-sm" style={{ marginTop: '0.5rem' }} onClick={() => void loadBlueskyPublicFeed()}>Retry</button>
                        </div>
                      ) : blueskyPublicPosts.length === 0 ? (
                        <div className="feed-create-hero">
                          <div className="feed-create-hero-icon">✨</div>
                          <h3>Discover on Bluesky</h3>
                          <p className="text-sm muted">Pick a channel above to search public Bluesky posts. Works for any term — try tech, art, or photography.</p>
                          <button type="button" className="primary" onClick={() => void loadBlueskyPublicFeed()}>Search Bluesky</button>
                        </div>
                      ) : visibleBlueskyItems.length === 0 ? (
                        <div className="feed-empty-filtered">
                          <p className="text-sm muted" style={{ margin: 0 }}>No posts match “{activeSocialTopic}” right now.</p>
                          <button type="button" className="ghost text-sm" style={{ marginTop: '0.5rem' }} onClick={() => setActiveSocialTopic("")}>Clear filter</button>
                        </div>
                      ) : (
                        <div className="feed-posts-list">
                          {visibleBlueskyItems.slice(0, feedVisibleCount).map((post) => renderBlueskyCard(post))}
                          {visibleBlueskyItems.length > feedVisibleCount ? (
                            <button type="button" className="load-more-btn" onClick={() => setFeedVisibleCount((c) => c + 20)}>Show more</button>
                          ) : null}
                        </div>
                      )
                    )}
                  </>
                )}
              </div>
            </div>
            </PullToRefresh>
          </ViewErrorBoundary>
        ) : null}

        {mobileTab === "reads" ? (
          <ViewErrorBoundary title="Reads">
            <PullToRefresh onRefresh={withRefreshToast("Reads updated", () => loadReadsFeed())} enabled={!readsLoading}>
            <div className="stack">
              <div className="feed-tab-container">
                <div className="row-between" style={{ padding: '0 0.25rem', alignItems: 'center' }}>
                  <h2>Reads</h2>
                  <span className="text-sm muted">{displayReads.length} stories · Nostr + RSS + Hacker News{readsYouTubeEnabled ? " + YouTube" : ""}</span>
                </div>

                {/* Rank mode toggle: "For You" (scored) vs "Latest" (chronological),
                    plus a YouTube (keyless) on/off — videos are searched by the
                    user's journal topics and fold into the same ranked stream. */}
                <div className="source-toggle">
                  <button type="button" className={`source-pill${readsRankMode === "foryou" ? " active" : ""}`} onClick={() => setReadsRankMode("foryou")}>✨ For You</button>
                  <button type="button" className={`source-pill${readsRankMode === "latest" ? " active" : ""}`} onClick={() => setReadsRankMode("latest")}>🕒 Latest</button>
                  <button type="button" className={`source-pill${readsYouTubeEnabled ? " active" : ""}`} onClick={() => setReadsYouTubeEnabled((v) => !v)} title="Include YouTube: your subscribed channels (reliable) plus best-effort topic discovery from your journals">▶ Videos</button>
                </div>

                {/* RSS feed chips now act as an additive filter on the unified stream. */}
                <div className="topic-chips" style={{ paddingBottom: '0.4rem' }}>
                  {RSS_FEEDS.map((f) => (
                    <button
                      key={f.id}
                      type="button"
                      className={`topic-chip small${activeRssFeedIds.includes(f.id) ? " active" : ""}`}
                      onClick={() => {
                        setActiveRssFeedIds((prev) => prev.includes(f.id) ? prev.filter((x) => x !== f.id) : [...prev, f.id]);
                        setReadsRssItems([]);
                      }}
                    >
                      {f.emoji ? `${f.emoji} ` : ""}{f.label}
                    </button>
                  ))}
                </div>

                {/* Subtle refresh indicator when content is already showing from cache. */}
                {readsLoading && displayReads.length > 0 ? (
                  <div className="text-sm muted" style={{ padding: '0.25rem 0.25rem 0', fontSize: '0.72rem' }}>
                    <span className="btn-spinner" aria-hidden style={{ width: '0.7rem', height: '0.7rem', marginRight: '0.3rem', verticalAlign: 'middle' }} />Refreshing…
                  </div>
                ) : null}

                {readsLoading && displayReads.length === 0 ? (
                  <div style={{ padding: '2rem', textAlign: 'center' }}>
                    <span className="btn-spinner" aria-hidden />
                    <p className="text-sm muted" style={{ marginTop: '0.5rem' }}>Loading…</p>
                  </div>
                ) : readsError && displayReads.length === 0 ? (
                  <div className="feed-empty-filtered">
                    <p className="text-sm muted" style={{ margin: 0 }}>{readsError}</p>
                    <button type="button" className="ghost text-sm" style={{ marginTop: '0.5rem' }} onClick={() => void loadReadsFeed()}>Retry</button>
                  </div>
                ) : displayReads.length === 0 ? (
                  <div className="feed-create-hero">
                    <div className="feed-create-hero-icon">📰</div>
                    <h3>No articles yet</h3>
                    <p className="text-sm muted">Long-form posts from Nostr (NIP-23), RSS blogs, and Hacker News. Pull to refresh, or toggle sources above.</p>
                  </div>
                ) : (() => {
                  // Apply pagination first, then split hero from the rest.
                  const visible = displayReads.slice(0, readsVisibleCount);
                  const [hero, ...rest] = visible;
                  const heroUrl = hero.item.content.linkUrl || "#";
                  const heroHost = (() => { try { return heroUrl !== "#" ? new URL(heroUrl).hostname.replace(/^www\./, "") : ""; } catch { return ""; } })();
                  // Group the remainder by sourceLabel, preserving rank order.
                  const groups: { label: string; items: RankedRead[] }[] = [];
                  for (const r of rest) {
                    const last = groups[groups.length - 1];
                    if (last && last.label === r.sourceLabel) last.items.push(r);
                    else groups.push({ label: r.sourceLabel, items: [r] });
                  }
                  return (
                    <>
                      {/* Top story (hero) card. */}
                      <a
                        className="reads-hero"
                        href={heroUrl}
                        target="_blank"
                        rel="noreferrer"
                        onClick={(e) => { if (heroUrl === "#") { e.preventDefault(); return; } e.preventDefault(); void openFeedLink(heroUrl); }}
                      >
                        {hero.item.media.thumbnailUrl ? <img src={hero.item.media.thumbnailUrl} alt="" className="reads-hero-cover" loading="lazy" /> : null}
                        <div className="reads-hero-body">
                          <div className="reads-card-source-row">
                            <span className="reads-card-source">{hero.sourceLabel}{heroHost ? ` · ${heroHost}` : ""}</span>
                            <span className="reads-readtime">{hero.item.sourcePlatform === "youtube" ? "▶ Video" : `⏱ ${hero.readMinutes} min`}</span>
                          </div>
                          <h3 className="reads-hero-title">{hero.item.content.title || "Untitled"}</h3>
                          {hero.item.content.body ? <p className="reads-hero-summary">{hero.item.content.body.slice(0, 220)}</p> : null}
                        </div>
                      </a>

                      {/* Source-grouped compact cards (Google News "by source" pattern). */}
                      <div className="reads-list">
                        {groups.map((g) => (
                          <div key={g.label} className="reads-group">
                            <div className="reads-group-header">{g.label} <span className="reads-group-count">· {g.items.length}</span></div>
                            {g.items.map(({ item, readMinutes }) => {
                              const url = item.content.linkUrl || "#";
                              const host = (() => { try { return url !== "#" ? new URL(url).hostname.replace(/^www\./, "") : ""; } catch { return ""; } })();
                              return (
                                <a
                                  key={item.id}
                                  className="reads-card"
                                  href={url}
                                  target="_blank"
                                  rel="noreferrer"
                                  onClick={(e) => { if (url === "#") { e.preventDefault(); return; } e.preventDefault(); void openFeedLink(url); }}
                                >
                                  {item.media.thumbnailUrl ? <img src={item.media.thumbnailUrl} alt="" className="reads-card-cover" loading="lazy" /> : null}
                                  <div className="reads-card-body">
                                    <div className="reads-card-source-row">
                                      <span className="reads-card-source">{host || item.sourcePlatform}</span>
                                      <span className="reads-readtime">{item.sourcePlatform === "youtube" ? "▶ Video" : `⏱ ${readMinutes} min`}</span>
                                    </div>
                                    <h3 className="reads-card-title">{item.content.title || "Untitled"}</h3>
                                    {item.content.body ? <p className="reads-card-summary">{item.content.body.slice(0, 200)}</p> : null}
                                  </div>
                                </a>
                              );
                            })}
                          </div>
                        ))}
                        {displayReads.length > readsVisibleCount ? (
                          <button type="button" className="load-more-btn" onClick={() => setReadsVisibleCount((c) => c + 12)}>Show more</button>
                        ) : null}
                      </div>
                    </>
                  );
                })()}
              </div>
            </div>
            </PullToRefresh>
          </ViewErrorBoundary>
        ) : null}

        {mobileTab === "profile" ? (
          <ViewErrorBoundary title="Profile">
            <div className="stack" style={{ padding: '0.5rem 0' }}>
              {/* Hidden avatar file picker (triggered by tapping the avatar). */}
              <input
                ref={profileAvatarInputRef}
                type="file"
                accept="image/*"
                style={{ display: 'none' }}
                onChange={async (e) => {
                  const file = e.target.files?.[0];
                  if (!file) return;
                  const dataUrl = await fileToAvatarDataUrl(file);
                  if (dataUrl) {
                    // setAvatar returns false if the (downscaled) image still exceeds quota;
                    // fileToAvatarDataUrl already downscale so this rarely trips.
                    setAvatar(dataUrl);
                    setLocalProfile(getProfile());
                  }
                  // Reset so picking the same file again re-triggers onChange.
                  e.target.value = "";
                }}
              />

              {/* Profile header: avatar + name + handles + settings gear. */}
              <div className="profile-header">
                <button
                  type="button"
                  className="profile-avatar-btn"
                  onClick={() => profileAvatarInputRef.current?.click()}
                  aria-label="Change profile picture"
                  title="Change profile picture"
                >
                  {localProfile?.avatar
                    ? <img src={localProfile.avatar} alt="" className="profile-avatar-img" />
                    : <span className="profile-avatar-placeholder" aria-hidden>{(localProfile?.name || "S").trim().charAt(0).toUpperCase()}</span>}
                  <span className="profile-avatar-edit" aria-hidden>✎</span>
                </button>
                <div className="profile-header-info">
                  <input
                    className="profile-name-input"
                    defaultValue={localProfile?.name || ""}
                    placeholder="Your name"
                    onBlur={(e) => {
                      const v = e.target.value.trim();
                      if (v !== (localProfile?.name || "")) {
                        saveProfile({ name: v });
                        setLocalProfile(getProfile());
                      }
                    }}
                  />
                  <div className="profile-handles">
                    {session ? <span className="profile-handle">Bluesky · @{session.handle}</span> : null}
                    {nostrKeys ? <span className="profile-handle">Nostr · npub:{nostrKeys.publicKeyHex.slice(0, 8)}…</span> : null}
                    {!session && !nostrKeys ? <span className="profile-handle muted">No accounts connected</span> : null}
                  </div>
                </div>
                <button
                  type="button"
                  className="profile-settings-btn"
                  onClick={() => setShowSettings(true)}
                  aria-label="Open settings"
                  title="Settings"
                >⚙️</button>
              </div>

              {/* Editable bio (persists on blur). */}
              <textarea
                className="profile-bio-input"
                defaultValue={localProfile?.bio || ""}
                placeholder="Add a short bio…"
                rows={2}
                onBlur={(e) => {
                  const v = e.target.value.trim();
                  if (v !== (localProfile?.bio || "")) {
                    saveProfile({ bio: v });
                    setLocalProfile(getProfile());
                  }
                }}
              />

              {/* Editable interest profile — steer the curation lens. */}
              {(() => {
                // Union of journal-derived labels (pre-override) + manual interests,
                // so muted topics stay visible and restorable.
                const seen = new Set<string>();
                const displayTopics: { label: string; manual: boolean }[] = [];
                for (const label of derivedTopicLabels) {
                  const key = label.toLowerCase();
                  if (seen.has(key)) continue;
                  seen.add(key);
                  displayTopics.push({ label, manual: false });
                }
                for (const label of manualInterests) {
                  if (seen.has(label)) continue;
                  seen.add(label);
                  displayTopics.push({ label, manual: true });
                }
                return (
                  <div className="interest-profile-card">
                    <p className="eyebrow">What feeds your mind</p>
                    <p className="text-sm muted" style={{ marginTop: '0.15rem', marginBottom: '0.6rem' }}>
                      These topics are mined from your journals and steer your Reads, YouTube, and Nostr feed. Boost what you want more of, mute what you don't.
                    </p>
                    {displayTopics.length === 0 ? (
                      <p className="text-sm muted" style={{ padding: '0.5rem 0' }}>
                        Nothing here yet. Write or record a journal entry to seed your interests.
                      </p>
                    ) : (
                      <div className="interest-profile-list">
                        {displayTopics.map(({ label, manual }) => {
                          const key = label.toLowerCase();
                          const mult = interestOverrides[key]?.multiplier ?? INTEREST_MULT.NORMAL;
                          const isMuted = mult === INTEREST_MULT.MUTE;
                          const isBoosted = mult === INTEREST_MULT.BOOST;
                          const setState = (next: number) => {
                            if (next === INTEREST_MULT.NORMAL) removeInterestOverride(label);
                            else setInterestMultiplier(label, next);
                          };
                          return (
                            <div key={key} className="interest-profile-row">
                              <span className={`interest-profile-label${isMuted ? " muted" : ""}`}>{label}{manual ? <span className="interest-profile-tag" aria-hidden>added</span> : null}</span>
                              <div className="interest-profile-controls" role="group" aria-label={`Steer topic ${label}`}>
                                <button type="button" className={`interest-pill${isMuted ? " active danger" : ""}`} onClick={() => setState(INTEREST_MULT.MUTE)} title="Mute this topic">Mute</button>
                                <button type="button" className={`interest-pill${!isMuted && !isBoosted ? " active" : ""}`} onClick={() => setState(INTEREST_MULT.NORMAL)} title="Use as-derived weight">Normal</button>
                                <button type="button" className={`interest-pill${isBoosted ? " active success" : ""}`} onClick={() => setState(INTEREST_MULT.BOOST)} title="Boost this topic">Boost</button>
                                {manual ? (
                                  <button type="button" className="interest-pill ghost" onClick={() => removeManualInterest(label)} title="Remove this interest">✕</button>
                                ) : null}
                              </div>
                            </div>
                          );
                        })}
                      </div>
                    )}
                    <form
                      className="interest-profile-add"
                      onSubmit={(e) => {
                        e.preventDefault();
                        const v = interestDraft.trim();
                        if (!v) return;
                        addManualInterest(v);
                        setInterestDraft("");
                      }}
                    >
                      <input
                        className="interest-profile-input"
                        value={interestDraft}
                        onChange={(e) => setInterestDraft(e.target.value)}
                        placeholder="Add an interest (e.g. philosophy)…"
                        aria-label="Add a manual interest"
                      />
                      <button type="submit" className="primary" disabled={!interestDraft.trim()}>Add</button>
                    </form>
                  </div>
                );
              })()}


              {/* Network follower/following counts (Bluesky via public AppView, Nostr via kind-3).
                  Best-effort — omitted entirely if both lookups fail/are unavailable. */}
              {(blueskyCounts || nostrFollowingCount !== null) ? (
                <div className="profile-network-counts">
                  {blueskyCounts ? (
                    <>
                      <span className="profile-network-stat"><strong>{blueskyCounts.followers}</strong> followers</span>
                      <span className="profile-network-sep">·</span>
                      <span className="profile-network-stat"><strong>{blueskyCounts.following}</strong> following</span>
                    </>
                  ) : null}
                  {nostrFollowingCount !== null ? (
                    <>
                      {blueskyCounts ? <span className="profile-network-sep">·</span> : null}
                      <span className="profile-network-stat">Nostr · <strong>{nostrFollowingCount}</strong> following</span>
                    </>
                  ) : null}
                </div>
              ) : null}

              {/* Publish local profile to Nostr (kind-0) so the relay identity matches. */}
              {nostrKeys ? (
                <div className="profile-publish-row">
                  <button
                    type="button"
                    className="ghost profile-publish-btn"
                    onClick={() => void handlePublishProfileToNostr()}
                    disabled={profilePublishing}
                  >
                    {profilePublishing ? "Publishing…" : "Sync profile to Nostr"}
                  </button>
                  {profilePublishToast ? <span className="profile-publish-toast" role="status">{profilePublishToast}</span> : null}
                </div>
              ) : null}

              {/* Stats row (Twitter/Instagram signature) — tappable to switch tabs. */}
              {(() => {
                const postedCount = persistedPosts.filter((p) => p.liked).length;
                const draftsCount = persistedPosts.filter((p) => !p.liked).length;
                const savedCount = savedItems.length;
                return (
                  <div className="profile-stats">
                    <button type="button" className={`profile-stat${profileContentTab === "posted" ? " active" : ""}`} onClick={() => setProfileContentTab("posted")}>
                      <strong>{postedCount}</strong> Posts
                    </button>
                    <button type="button" className={`profile-stat${profileContentTab === "drafts" ? " active" : ""}`} onClick={() => setProfileContentTab("drafts")}>
                      <strong>{draftsCount}</strong> Drafts
                    </button>
                    <button type="button" className={`profile-stat${profileContentTab === "saved" ? " active" : ""}`} onClick={() => setProfileContentTab("saved")}>
                      <strong>{savedCount}</strong> Saved
                    </button>
                  </div>
                );
              })()}

              {/* Content tabs (segmented control). */}
              <div className="profile-tabs" role="tablist">
                <button role="tab" type="button" className={`profile-tab${profileContentTab === "posted" ? " active" : ""}`} onClick={() => setProfileContentTab("posted")}>Posts</button>
                <button role="tab" type="button" className={`profile-tab${profileContentTab === "drafts" ? " active" : ""}`} onClick={() => setProfileContentTab("drafts")}>Drafts</button>
                <button role="tab" type="button" className={`profile-tab${profileContentTab === "saved" ? " active" : ""}`} onClick={() => setProfileContentTab("saved")}>Saved</button>
              </div>

              {/* Tab content. */}
              {profileContentTab === "posted" ? (
                persistedPosts.filter((p) => p.liked).length === 0 ? (
                  <p className="text-sm muted" style={{ padding: '1rem', textAlign: 'center' }}>No posts yet. Tap the heart on a draft in the Queue tab to publish it to Nostr.</p>
                ) : (
                  <div className="feed-posts-list">
                    {persistedPosts.filter((p) => p.liked).map((post) => {
                      const timeAgo = getRelativeTime(post.createdAt);
                      const nostrLink = post.eventId ? `https://njump.at/${post.eventId}` : null;
                      return (
                        <div key={post.id} className="tweet-card">
                          {localProfile?.avatar
                            ? <img src={localProfile.avatar} alt="" className="tweet-avatar" />
                            : <div className="tweet-avatar" aria-hidden>🐾</div>}
                          <div className="tweet-body">
                            <div className="tweet-header">
                              <span className="tweet-name">{localProfile?.name?.trim() || "You"}</span>
                              {nostrLink ? (
                                <a className="profile-verified-badge" href={nostrLink} target="_blank" rel="noreferrer" title="View on Nostr" onClick={(e) => { e.preventDefault(); void openFeedLink(nostrLink); }}>🔗</a>
                              ) : null}
                              <span className="tweet-dot">·</span>
                              <span className="tweet-time">{timeAgo}</span>
                            </div>
                            <p className="tweet-text">{post.text}</p>
                          </div>
                        </div>
                      );
                    })}
                  </div>
                )
              ) : profileContentTab === "drafts" ? (
                persistedPosts.filter((p) => !p.liked).length === 0 ? (
                  <p className="text-sm muted" style={{ padding: '1rem', textAlign: 'center' }}>No drafts. Generate one from a journal in the Queue tab.</p>
                ) : (
                  <div className="feed-posts-list">
                    {persistedPosts.filter((p) => !p.liked).map((post) => {
                      const timeAgo = getRelativeTime(post.createdAt);
                      return (
                        <div key={post.id} className="tweet-card">
                          <div className="tweet-avatar" aria-hidden>📝</div>
                          <div className="tweet-body">
                            <div className="tweet-header">
                              <span className="tweet-name">Draft</span>
                              <span className="tweet-dot">·</span>
                              <span className="tweet-time">{timeAgo}</span>
                            </div>
                            <p className="tweet-text">{post.text}</p>
                            <p className="text-sm muted" style={{ margin: '0.3rem 0 0', fontSize: '0.75rem' }}>Open Queue to review & publish →</p>
                          </div>
                        </div>
                      );
                    })}
                  </div>
                )
              ) : (
                savedItems.length === 0 ? (
                  <p className="text-sm muted" style={{ padding: '1rem', textAlign: 'center' }}>Bookmark posts, videos, or articles from any tab to save them here.</p>
                ) : (
                  <div className="saved-list">
                    {savedItems.map((s) => (
                      <a
                        key={s.id}
                        className="saved-item"
                        href={s.url || "#"}
                        target="_blank"
                        rel="noreferrer"
                        onClick={(e) => { if (!s.url) { e.preventDefault(); return; } e.preventDefault(); void openFeedLink(s.url); }}
                      >
                        {s.thumbnail ? <img src={s.thumbnail} alt="" className="saved-item-thumb" loading="lazy" /> : null}
                        <div className="saved-item-body">
                          <div className="saved-item-top">
                            <span className="saved-item-source">{s.source}{s.authorHandle ? ` · @${s.authorHandle}` : ""}</span>
                            <span className="saved-item-time">{getRelativeTime(s.savedAt)}</span>
                          </div>
                          {s.title ? <p className="saved-item-title">{s.title}</p> : null}
                        </div>
                      </a>
                    ))}
                  </div>
                )
              )}
            </div>
          </ViewErrorBoundary>
        ) : null}
      </main>
      </SwipeableView>

        {showSettings ? (
          <div className="settings-overlay view-enter">
            <div className="settings-header">
              <button type="button" className="ghost settings-back" onClick={() => setShowSettings(false)}>
                ← Back
              </button>
              <h2>Settings</h2>
              <div style={{ width: '60px' }} />
            </div>

            <div className="stack">
              <div className="card">
                <h3 style={{ margin: 0 }}>On-Device AI</h3>
                <p className="text-sm muted" style={{ margin: '0.25rem 0 0.75rem' }}>
                  Private AI model on your iPhone. No data leaves your device.
                </p>

                {localModels.map((model) => {
                  const download = model.download;
                  const isDownloading = download?.status === "downloading";
                  const transferred = download?.transferredBytes || 0;
                  const total = download?.totalBytes || model.sizeBytes || 0;
                  const progress = total > 0 ? Math.min(100, Math.round((transferred / total) * 100)) : 0;
                  const isConfigured = nativeLocalAiStatus?.modelId === model.id;
                  const isInCatalog = ["unsloth/gemma-4-E2B-it-qat-UD-Q2_K_XL", "unsloth/gemma-4-E2B-it-qat-UD-Q4_K_XL"].includes(model.id);
                  return (
                    <div key={model.id} className="card" style={{ margin: '0.5rem 0' }}>
                      <div className="row-between">
                        <strong>{model.title}</strong>
                        <span className={model.installed ? "local-model-pill installed" : "local-model-pill"}>
                          {isConfigured ? "Ready" : model.installed ? "Downloaded" : model.sizeLabel}
                        </span>
                      </div>
                      <p className="text-sm muted" style={{ margin: '0.25rem 0' }}>{model.description}</p>
                      {isDownloading ? (
                        <div className="local-model-progress">
                          <div className="local-model-progress-track">
                            <div className="local-model-progress-fill" style={{ width: `${progress}%` }} />
                          </div>
                          <span className="text-sm muted">{progress}%</span>
                        </div>
                      ) : null}
                      {download?.status === "failed" && download.error ? (
                        <p className="text-sm local-model-error">{download.error}</p>
                      ) : null}
                      {!model.installed && isInCatalog ? (
                        <button
                          type="button" className="primary"
                          style={{ width: '100%', borderRadius: '10px', padding: '0.75rem', marginTop: '0.5rem' }}
                          onClick={() => void startLocalModelDownload(model.id)}
                          disabled={Boolean(localModelBusyId) || isDownloading}
                        >
                          {isDownloading ? "Downloading..." : download?.status === "failed" && transferred > 0 ? `Resume Download (${Math.round((transferred / total) * 100)}%)` : `Download (${model.sizeLabel})`}
                        </button>
                      ) : model.installed && !isConfigured ? (
                        <button
                          type="button" className="primary"
                          style={{ width: '100%', borderRadius: '10px', padding: '0.75rem', marginTop: '0.5rem' }}
                          onClick={() => void startDownloadedLocalModel(model.id)}
                          disabled={Boolean(localModelBusyId)}
                        >
                          Activate Model
                        </button>
                      ) : model.installed && isConfigured ? (
                        <div className="row" style={{ gap: '0.5rem', alignItems: 'center', marginTop: '0.5rem' }}>
                          <span className="model-hub-orb ready" />
                          <span className="text-sm">AI is ready</span>
                        </div>
                      ) : null}
                      {model.installed ? (
                        <button
                          type="button" className="ghost text-sm"
                          style={{ marginTop: '0.5rem', color: 'var(--danger, #e55)' }}
                          onClick={async () => {
                            if (!confirm(`Delete ${model.title}? The file will be removed and the model deselected.`)) return;
                            setLocalModelBusyId(model.id);
                            try {
                              // deleteLocalModel unloads the model from memory if
                              // active, clears the config if it's the configured one,
                              // and removes the GGUF file from disk — all server-side,
                              // so it works without the fs plugin or an fs permission
                              // scope (the previous frontend `plugin-fs` path silently
                              // no-op'd because that plugin isn't registered here).
                              const refreshed = await deleteLocalModel(model.id);
                              setNativeLocalAiStatus(refreshed);
                              await loadLocalModels();
                            } catch (err) {
                              setLocalModelsStatus(`Delete failed: ${err instanceof Error ? err.message : String(err)}`);
                            } finally {
                              setLocalModelBusyId("");
                            }
                          }}
                        >
                          Delete Model
                        </button>
                      ) : null}
                    </div>
                  );
                })}

                {localModels.length === 0 && !nativeLocalAiStatus?.configured ? (
                  <div className="stack-sm" style={{ textAlign: 'center', padding: '1rem 0' }}>
                    <p className="text-sm muted">Loading model info...</p>
                    <button type="button" className="ghost" onClick={() => void loadLocalModels()}>Refresh</button>
                  </div>
                ) : localModels.length === 0 && nativeLocalAiStatus?.configured ? (
                  <div className="stack-sm" style={{ padding: '0.75rem 0' }}>
                    <div className="row" style={{ gap: '0.5rem', alignItems: 'center' }}>
                      <span style={{ fontSize: '1.2rem' }}>✅</span>
                      <div>
                        <strong className="text-sm">{nativeLocalAiStatus.modelId || "AI Model"}</strong>
                        <p className="text-sm muted" style={{ margin: '0.1rem 0 0' }}>AI is ready for on-device inference</p>
                      </div>
                    </div>
                    <button
                      type="button" className="ghost text-sm"
                      style={{ marginTop: '0.5rem', color: 'var(--danger, #e55)' }}
                      onClick={async () => {
                        if (!confirm("Clear the configured model? You can re-download and select it again later.")) return;
                        try {
                          const refreshed = await clearNativeLocalAi();
                          setNativeLocalAiStatus(refreshed);
                          await loadLocalModels();
                        } catch (err) {
                          setLocalModelsStatus(`Failed to clear model config: ${err instanceof Error ? err.message : String(err)}`);
                        }
                      }}
                    >
                      Clear Model Config
                    </button>
                  </div>
                ) : null}

                {localModelsStatus ? (
                  <p className="text-sm muted" style={{ margin: '0.5rem 0 0' }}>{localModelsStatus}</p>
                ) : null}

                {/* Metal GPU toggle */}
                <div style={{ marginTop: '1rem', padding: '0.75rem', borderRadius: '10px', background: 'var(--surface-2, #f5f5f5)' }}>
                  <div className="row-between" style={{ alignItems: 'center' }}>
                    <div>
                      <strong className="text-sm">⚡ Fast Mode (Metal GPU)</strong>
                      <p className="text-sm muted" style={{ margin: '0.15rem 0 0' }}>
                        Faster generation, may be unstable on some devices.
                      </p>
                    </div>
                    <label style={{ position: 'relative', display: 'inline-block', width: '50px', height: '28px' }}>
                      <input
                        type="checkbox"
                        checked={metalMode}
                        onChange={async (e) => {
                          const enabled = e.target.checked;
                          setMetalMode(enabled);
                          localStorage.setItem(AI_METAL_MODE_KEY, String(enabled));
                          try {
                            await setMetalModeBackend(enabled);
                            setLocalModelsStatus(enabled ? "Metal GPU enabled. Model will reload on next generation." : "Metal GPU disabled. Using stable CPU mode.");
                          } catch { /* non-native env */ }
                        }}
                        style={{ opacity: 0, width: 0, height: 0 }}
                      />
                      <span style={{
                        position: 'absolute', cursor: 'pointer', inset: 0,
                        background: metalMode ? 'var(--accent, #007aff)' : '#ccc',
                        borderRadius: '28px', transition: 'background 0.2s',
                      }}>
                        <span style={{
                          position: 'absolute', height: '22px', width: '22px',
                          left: metalMode ? '25px' : '3px', bottom: '3px',
                          background: '#fff', borderRadius: '50%', transition: 'left 0.2s',
                        }} />
                      </span>
                    </label>
                  </div>
                </div>
              </div>
            </div>

            {/* ── Accounts (collapsible) ── */}
            <div className="card" style={{ marginTop: '1rem' }}>
              <details>
                <summary style={{ cursor: 'pointer', fontWeight: 600, fontSize: '1rem' }}>Bluesky</summary>
                <div style={{ paddingTop: '0.75rem' }}>
                  {session ? (
                    <div className="stack-sm">
                      <span className="badge success">Signed in as @{session.handle}</span>
                      <button type="button" className="ghost text-sm" onClick={async () => {
                        await deleteCredentialsSecure();
                        setCreds({ serviceUrl: "https://bsky.social", handle: "", appPassword: "" });
                        setSession(null); setAgent(null); setAuthMessage("Signed out");
                      }}>Sign Out</button>
                    </div>
                  ) : (
                    <form className="stack-sm" onSubmit={handleLogin}>
                      <input value={creds.handle} onChange={(e) => setCreds(prev => ({ ...prev, handle: e.target.value }))} placeholder="Handle or Email" />
                      <input type="password" value={creds.appPassword} onChange={(e) => setCreds(prev => ({ ...prev, appPassword: e.target.value }))} placeholder="App Password" />
                      <button type="submit" className="primary">Sign In</button>
                      {authMessage && <p className="text-sm muted">{authMessage}</p>}
                    </form>
                  )}
                </div>
              </details>
            </div>

            <div className="card" style={{ marginTop: '0.5rem' }}>
              <details>
                <summary style={{ cursor: 'pointer', fontWeight: 600, fontSize: '1rem' }}>Nostr</summary>
                <div style={{ paddingTop: '0.75rem' }}>
                  {nostrKeys ? (
                    <div className="stack-sm">
                      <span className="badge success">Connected</span>
                      {/* Public key — always visible, copyable (npub1...) */}
                      <div className="nostr-key-row">
                        <div className="nostr-key-row-head">
                          <span className="text-sm" style={{ fontWeight: 600 }}>Public key</span>
                          <button type="button" className="nostr-copy-btn" onClick={() => {
                            void navigator.clipboard?.writeText(nostrKeys.npub).then(() => {
                              setNostrCopiedKey("npub"); setTimeout(() => setNostrCopiedKey(""), 1500);
                            });
                          }} aria-label="Copy public key">{nostrCopiedKey === "npub" ? "Copied" : "Copy"}</button>
                        </div>
                        <p className="nostr-key-value" style={{ wordBreak: 'break-all' }}>{nostrKeys.npub}</p>
                      </div>
                      {/* Private key — hidden by default, reveal + copy gated behind a warning */}
                      <div className="nostr-key-row">
                        <div className="nostr-key-row-head">
                          <span className="text-sm" style={{ fontWeight: 600 }}>Private key (secret)</span>
                          <div className="row" style={{ gap: '0.4rem' }}>
                            <button type="button" className="nostr-copy-btn" onClick={() => setNostrRevealPrivkey((v) => !v)} aria-label={nostrRevealPrivkey ? "Hide private key" : "Reveal private key"}>{nostrRevealPrivkey ? "Hide" : "Reveal"}</button>
                            {nostrRevealPrivkey ? (
                              <button type="button" className="nostr-copy-btn" onClick={() => {
                                void navigator.clipboard?.writeText(nostrKeys.nsec).then(() => {
                                  setNostrCopiedKey("nsec"); setTimeout(() => setNostrCopiedKey(""), 1500);
                                });
                              }} aria-label="Copy private key">{nostrCopiedKey === "nsec" ? "Copied" : "Copy"}</button>
                            ) : null}
                          </div>
                        </div>
                        {nostrRevealPrivkey ? (
                          <>
                            <p className="nostr-key-value" style={{ wordBreak: 'break-all' }}>{nostrKeys.nsec}</p>
                            <p className="text-sm" style={{ color: 'var(--danger)', margin: 0 }}>Never share your private key. Anyone with it can post as you.</p>
                          </>
                        ) : (
                          <p className="text-sm muted" style={{ margin: 0 }}>Hidden. Reveal to view or copy your nsec1... key.</p>
                        )}
                      </div>
                      <button type="button" className="ghost text-sm" onClick={() => {
                        setNostrKeys(null);
                        setNostrRevealPrivkey(false);
                        localStorage.removeItem("slowclaw.nostr.privkey");
                        localStorage.removeItem("slowclaw.nostr.pubkey");
                      }}>Disconnect</button>
                    </div>
                  ) : (
                    <div className="stack-sm">
                      <p className="text-sm muted" style={{ margin: 0 }}>Create a Nostr identity, or import an existing private key (nsec1... or 64-char hex).</p>
                      <input id="settings-nostr-key" type="password" placeholder="Private key (nsec1... or hex)" autoComplete="off" />
                      <div className="row" style={{ gap: '0.5rem' }}>
                        <button type="button" className="primary" style={{ flex: 1 }} onClick={async () => {
                          const input = (document.getElementById('settings-nostr-key') as HTMLInputElement)?.value?.trim();
                          if (!input) return;
                          const { importNostrPrivkey } = await import("./lib/nostr");
                          const keys = importNostrPrivkey(input);
                          if (keys) {
                            await saveNostrKeysSecure(keys);
                            setNostrKeys(keys);
                          }
                        }}>Import Key</button>
                        <button type="button" className="ghost" style={{ flex: 1 }} onClick={async () => {
                          const { generateAndSaveNostrKeys } = await import("./lib/nostr");
                          const keys = generateAndSaveNostrKeys();
                          await saveNostrKeysSecure(keys);
                          setNostrKeys(keys);
                        }}>Create New</button>
                      </div>
                    </div>
                  )}
                </div>
              </details>
            </div>

          </div>
        ) : null}

      {!hideChrome && (
        <BottomNav
          activeTab={mobileTab}
          onTabChange={setMobileTab}
          productivityBadgeCount={openTodos.length + todayEventItems.length + upcomingEventItems.length}
        />
      )}
      {/* First-run welcome overlay: capture-first onboarding */}
      {showWelcome ? (
        <div className="modal-overlay">
          <div className="modal-dialog welcome-dialog" onClick={(e) => e.stopPropagation()}>
            <div className="welcome-icon" aria-hidden>✍️</div>
            <h3 style={{ margin: '0 0 0.5rem', textAlign: 'center' }}>Welcome to SlowClaw</h3>
            <p className="text-sm" style={{ margin: '0 0 1.25rem', textAlign: 'center', color: 'var(--muted)' }}>
              We learn what you care about from <strong style={{ color: 'var(--text)' }}>what you write</strong> — not from a list of checkboxes. Write one entry and watch your feed tune itself to your actual interests.
            </p>
            <div className="stack" style={{ gap: '0.5rem' }}>
              <button type="button" className="primary" onClick={() => dismissWelcome(true)}>Write your first entry →</button>
              <button type="button" className="ghost text-sm" onClick={() => dismissWelcome(false)}>Maybe later</button>
            </div>
          </div>
        </div>
      ) : null}
      {/* Nostr post confirm dialog */}
      {nostrPostConfirmStep === "confirm" && nostrPostConfirmPost && (
        <div className="modal-overlay" onClick={() => { setNostrPostConfirmPost(null); setNostrPostConfirmStep(null); }}>
          <div className="modal-dialog" onClick={(e) => e.stopPropagation()}>
            <h3 style={{ margin: '0 0 0.75rem' }}>Post to Nostr?</h3>
            <p className="text-sm" style={{ margin: '0 0 1rem', color: 'var(--muted)' }}>Do you want to publish this post to the Nostr social network?</p>
            <p className="text-sm" style={{ margin: '0 0 1.25rem', fontStyle: 'italic', color: 'var(--text)' }}>"{nostrPostConfirmPost.text.slice(0, 100)}{nostrPostConfirmPost.text.length > 100 ? '...' : ''}"</p>
            <div className="row" style={{ gap: '0.5rem', justifyContent: 'flex-end' }}>
              <button type="button" className="ghost" onClick={() => void handleNostrPostConfirm(false)}>No</button>
              <button type="button" className="primary" onClick={() => void handleNostrPostConfirm(true)}>Yes</button>
            </div>
          </div>
        </div>
      )}
      {nostrPostConfirmStep === "account" && nostrPostConfirmPost && (
        <div className="modal-overlay" onClick={() => { setNostrPostConfirmPost(null); setNostrPostConfirmStep(null); }}>
          <div className="modal-dialog" onClick={(e) => e.stopPropagation()}>
            <h3 style={{ margin: '0 0 0.75rem' }}>Nostr Account</h3>
            <p className="text-sm" style={{ margin: '0 0 1.25rem', color: 'var(--muted)' }}>Do you have a Nostr account?</p>
            <div className="stack-sm">
              <button type="button" className="ghost" style={{ width: '100%', textAlign: 'left' }} onClick={() => void handleNostrAccountChoice("has_account")}>Yes \u2014 I'll enter my key in Settings</button>
              <button type="button" className="primary" style={{ width: '100%', textAlign: 'left' }} onClick={() => void handleNostrAccountChoice("create")}>No \u2014 Create one for me</button>
              <button type="button" className="ghost" style={{ width: '100%', textAlign: 'left', color: 'var(--muted)' }} onClick={() => void handleNostrAccountChoice("cancel")}>Cancel</button>
            </div>
          </div>
        </div>
      )}
      {/* Fullscreen video overlay (tap-to-fullscreen from an inline Feed video).
          Reuses the ReelsPlayer + reels-feed snap container so the UX matches
          the Reels tab; swipe through all videos in the current feed. */}
      {fullscreenVideo ? (
        <div className="modal-overlay reels-fullscreen-overlay" onClick={() => setFullscreenVideo(null)}>
          <div
            className="reels-feed"
            ref={fullscreenVideoScrollRef}
            tabIndex={0}
            role="dialog"
            aria-label="Video player"
            onClick={(e) => e.stopPropagation()}
            onKeyDown={(e) => {
              if (e.key !== "ArrowDown" && e.key !== "ArrowUp") return;
              e.preventDefault();
              const root = fullscreenVideoScrollRef.current;
              if (!root) return;
              const tiles = Array.from(root.querySelectorAll<HTMLElement>(".reels-tile"));
              if (!tiles.length) return;
              const idx = Math.round(root.scrollTop / root.clientHeight);
              const next = e.key === "ArrowDown" ? Math.min(tiles.length - 1, idx + 1) : Math.max(0, idx - 1);
              tiles[next]?.scrollIntoView({ behavior: "smooth" });
            }}
          >
            {fullscreenVideo.posts.slice(0, 40).map((post, i) => (
              <ReelsPlayer
                key={post.uri}
                post={post}
                active={i === fullscreenVideo.startIndex}
                muted={reelsMuted}
                onToggleMute={() => setReelsMuted((m) => !m)}
              />
            ))}
          </div>
          <button
            type="button"
            className="reels-fullscreen-close"
            aria-label="Close video"
            onClick={() => setFullscreenVideo(null)}
          >✕</button>
        </div>
      ) : null}
      {/* Profile overlay (Nostr user or Skill) */}
      {profileView && (
        <div className="modal-overlay" onClick={() => setProfileView(null)}>
          <div className="modal-dialog" style={{ maxWidth: '400px', maxHeight: '80vh', overflow: 'auto' }} onClick={(e) => e.stopPropagation()}>
            <div style={{ display: 'flex', justifyContent: 'space-between', alignItems: 'center', marginBottom: '0.75rem' }}>
              <h3 style={{ margin: 0 }}>{profileView.kind === "skill" ? "Skill" : profileView.kind === "bluesky" ? "Bluesky profile" : "Nostr profile"}</h3>
              <button type="button" className="ghost" style={{ padding: '0.3rem' }} onClick={() => setProfileView(null)}>✕</button>
            </div>

            {profileView.kind === "nostr" && (
              <div className="stack-sm">
                <div className="nostr-profile-head">
                  {nostrProfileOverlay?.picture ? (
                    <img
                      src={nostrProfileOverlay.picture}
                      alt=""
                      className="profile-pic-circle nostr-profile-avatar"
                      onError={(e) => { (e.currentTarget as HTMLImageElement).style.display = 'none'; }}
                    />
                  ) : (
                    <div className="profile-pic-circle">👤</div>
                  )}
                  <div style={{ minWidth: 0, flex: 1 }}>
                    <p style={{ fontWeight: 700, margin: 0, fontSize: '1.05rem' }}>
                      {nostrProfileOverlay?.displayName || nostrProfileOverlay?.name || "Nostr user"}
                    </p>
                    {nostrProfileOverlay?.name && nostrProfileOverlay.displayName ? (
                      <p className="text-sm muted" style={{ margin: '0.05rem 0 0' }}>@{nostrProfileOverlay.name}</p>
                    ) : null}
                    {nostrProfileOverlay?.nip05 ? (
                      <p className="text-sm" style={{ margin: '0.05rem 0 0', color: 'var(--accent)' }}>✅ {nostrProfileOverlay.nip05}</p>
                    ) : null}
                    {(() => { try { return <p className="text-sm muted nostr-profile-npub" style={{ margin: '0.1rem 0 0', wordBreak: 'break-all' }}>{npubFromHex(profileView.pubkey)}</p>; } catch { return null; } })()}
                  </div>
                </div>
                {nostrProfileOverlay?.about ? (
                  <p className="text-sm" style={{ margin: '0.25rem 0 0', whiteSpace: 'pre-wrap' }}>{nostrProfileOverlay.about}</p>
                ) : null}
                {/* Stats row + Follow button */}
                <div className="profile-modal-stats">
                  {profileViewNostrFollowing !== null ? (
                    <span className="profile-modal-stat"><strong>{profileViewNostrFollowing}</strong> following</span>
                  ) : null}
                  <span className="profile-modal-stat"><strong>{profileViewNotes.length}</strong> notes</span>
                  <button
                    type="button"
                    className={`profile-modal-follow-btn${followedIds.includes(nostrFollowKey(profileView.pubkey)) ? " following" : ""}`}
                    onClick={() => void handleToggleFollow("nostr", profileView.pubkey)}
                  >
                    {followedIds.includes(nostrFollowKey(profileView.pubkey)) ? "Following" : (nostrKeys ? "Follow" : "Follow · connect key")}
                  </button>
                </div>
                <div style={{ borderTop: '1px solid var(--line)', paddingTop: '0.75rem', marginTop: '0.25rem' }}>
                  <p className="text-sm" style={{ fontWeight: 600, marginBottom: '0.5rem' }}>Recent notes</p>
                  {profileViewLoading ? (
                    <p className="text-sm muted">Loading...</p>
                  ) : profileViewNotes.length === 0 ? (
                    <p className="text-sm muted">No notes found.</p>
                  ) : (
                    <div className="nostr-profile-notes">
                      {profileViewNotes.slice(0, 10).map((note) => renderNostrNoteCard(note))}
                    </div>
                  )}
                </div>
              </div>
            )}

            {profileView.kind === "bluesky" && (
              <div className="stack-sm">
                <div className="nostr-profile-head">
                  {profileViewBlueskyProfile?.avatar ? (
                    <img
                      src={profileViewBlueskyProfile.avatar}
                      alt=""
                      className="profile-pic-circle nostr-profile-avatar"
                      onError={(e) => { (e.currentTarget as HTMLImageElement).style.display = 'none'; }}
                    />
                  ) : (
                    <div className="profile-pic-circle">🌐</div>
                  )}
                  <div style={{ minWidth: 0, flex: 1 }}>
                    <p style={{ fontWeight: 700, margin: 0, fontSize: '1.05rem' }}>
                      {profileViewBlueskyProfile?.displayName || profileViewBlueskyProfile?.handle || profileView.actor}
                    </p>
                    <p className="text-sm muted" style={{ margin: '0.05rem 0 0' }}>@{profileViewBlueskyProfile?.handle || profileView.actor}</p>
                  </div>
                </div>
                {profileViewBlueskyProfile?.description ? (
                  <p className="text-sm" style={{ margin: '0.25rem 0 0', whiteSpace: 'pre-wrap' }}>{profileViewBlueskyProfile.description}</p>
                ) : null}
                {/* Stats row + Follow button */}
                <div className="profile-modal-stats">
                  {profileViewBlueskyProfile ? (
                    <>
                      <span className="profile-modal-stat"><strong>{profileViewBlueskyProfile.followers}</strong> followers</span>
                      <span className="profile-modal-stat"><strong>{profileViewBlueskyProfile.following}</strong> following</span>
                      <span className="profile-modal-stat"><strong>{profileViewBlueskyProfile.posts}</strong> posts</span>
                    </>
                  ) : null}
                  <button
                    type="button"
                    className={`profile-modal-follow-btn${followedIds.includes(blueskyFollowKey(profileView.actor)) ? " following" : ""}`}
                    onClick={() => void handleToggleFollow("bluesky", profileView.actor)}
                  >
                    {followedIds.includes(blueskyFollowKey(profileView.actor)) ? "Following" : (session ? "Follow" : "Follow · sign in")}
                  </button>
                </div>
                <div style={{ borderTop: '1px solid var(--line)', paddingTop: '0.75rem', marginTop: '0.25rem' }}>
                  <p className="text-sm" style={{ fontWeight: 600, marginBottom: '0.5rem' }}>Recent posts</p>
                  {profileViewLoading ? (
                    <p className="text-sm muted">Loading...</p>
                  ) : profileViewBlueskyPosts.length === 0 ? (
                    <p className="text-sm muted">No posts found.</p>
                  ) : (
                    <div className="nostr-profile-notes">
                      {profileViewBlueskyPosts.slice(0, 10).map((post) => renderBlueskyCard(post))}
                    </div>
                  )}
                </div>
              </div>
            )}

            {profileView.kind === "skill" && profileView.skillId === "tweetclaw" && (
              <div className="stack-sm">
                <div style={{ display: 'flex', gap: '0.75rem', alignItems: 'center' }}>
                  <div className="profile-pic-circle">🐾</div>
                  <div>
                    <p style={{ fontWeight: 700, margin: 0 }}>TweetClaw</p>
                    <p className="text-sm muted" style={{ margin: '0.1rem 0 0' }}>@tweetclaw</p>
                  </div>
                </div>
                <p className="text-sm" style={{ color: 'var(--muted)', margin: '0.5rem 0' }}>AI skill that transforms journal entries into tweet-style social media posts. Powered by on-device inference.</p>
                <div style={{ borderTop: '1px solid var(--line)', paddingTop: '0.75rem' }}>
                  <p className="text-sm" style={{ fontWeight: 600, marginBottom: '0.4rem' }}>Prompt</p>
                  <textarea
                    className="tweet-text-edit"
                    style={{ border: '1px solid var(--line)', borderRadius: '8px', padding: '0.5rem', minHeight: '5rem', background: 'var(--surface-3)' }}
                    value={tweetClawPrompt}
                    onChange={(e) => {
                      setTweetClawPrompt(e.target.value);
                      localStorage.setItem(TWEETCLAW_PROMPT_KEY, e.target.value);
                      const el = e.target; el.style.height = 'auto'; el.style.height = el.scrollHeight + 'px';
                    }}
                    onFocus={(e) => { const el = e.target; el.style.height = 'auto'; el.style.height = el.scrollHeight + 'px'; }}
                    ref={(el) => { if (el) { el.style.height = 'auto'; el.style.height = el.scrollHeight + 'px'; } }}
                  />
                  {tweetClawPrompt !== defaultTweetClawPrompt && (
                    <button type="button" className="ghost text-sm" style={{ marginTop: '0.4rem' }} onClick={() => {
                      setTweetClawPrompt(defaultTweetClawPrompt);
                      localStorage.removeItem(TWEETCLAW_PROMPT_KEY);
                    }}>Reset to default</button>
                  )}
                </div>
              </div>
            )}
          </div>
        </div>
      )}
      <ToastContainer />
      {/* Refresh toast (#5): confirms a pull-to-refresh completed. */}
      {refreshToast ? (
        <div className="refresh-toast" role="status" aria-live="polite">{refreshToast}</div>
      ) : null}
      {/* Reply toast: confirms a reply posted (or failed) from a compose box. */}
      {replyToast ? (
        <div className="refresh-toast" role="status" aria-live="polite">{replyToast}</div>
      ) : null}
    </div>
  );
}

export default App;
