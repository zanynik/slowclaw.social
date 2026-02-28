import { FormEvent, useEffect, useMemo, useRef, useState } from "react";
import type { AtpAgent } from "@atproto/api";
import {
  loginBluesky,
  postTextToBluesky,
  postVideoToBluesky,
  sendAuthedXrpcRequest,
  type BlueskySession
} from "./lib/bluesky";
import { AppBskyFeedDefs } from "@atproto/api";
import {
  createClawChatUserMessage,
  createClawChatUserMessageViaGateway,
  createPocketBaseClient,
  listClawChatMessagesViaGateway,
  listClawChatMessagesFromPocketBase,
  listDraftsFromPocketBase,
  listPostHistoryFromPocketBase,
  saveDraftToPocketBase,
  savePostHistoryToPocketBase
} from "./lib/pocketbase";
import {
  createJournalTextViaGateway,
  fetchMediaAsFile,
  listLibraryItems,
  pairGatewayClient,
  readLibraryText,
  saveLibraryText,
  uploadMediaViaGateway
} from "./lib/gatewayApi";
import {
  deleteCredentialsSecure,
  loadCredentialsFallback,
  loadCredentialsSecure,
  saveCredentialsSecure
} from "./lib/secureStorage";
import type {
  ApiRequestState,
  BlueskyCredentials,
  ClawChatMessage,
  LibraryItem,
  PostHistoryItem,
  StoredDraft
} from "./lib/types";

const initialApiRequest: ApiRequestState = {
  method: "GET",
  url: "xrpc/com.atproto.server.describeServer",
  headersJson: "{}",
  bodyJson: "{}",
  includeBlueskyAuth: false
};

const CHAT_THREAD_STORAGE_KEY = "slowclaw.chat.thread_id";
const CHAT_GATEWAY_TOKEN_STORAGE_KEY = "slowclaw.chat.gateway_token";
const CHAT_USE_GATEWAY_STORAGE_KEY = "slowclaw.chat.use_gateway";
const UI_THEME_STORAGE_KEY = "slowclaw.ui.theme";
const UI_TAB_STORAGE_KEY = "slowclaw.ui.tab";
const FEED_POSTED_PATHS_STORAGE_KEY = "slowclaw.feed.posted_paths";

type MobileTab = "journal" | "feed" | "chat" | "profile";
type ThemeMode = "light" | "dark";

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
  const saved = window.localStorage.getItem(UI_TAB_STORAGE_KEY);
  return saved === "feed" || saved === "chat" ? saved : "journal";
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

function sidecarCaptionPath(item: LibraryItem) {
  return `${item.path}.caption.txt`;
}

function createThreadId() {
  if (typeof crypto !== "undefined" && typeof crypto.randomUUID === "function") {
    return crypto.randomUUID();
  }
  return `thread-${Date.now()}-${Math.random().toString(36).slice(2, 10)}`;
}

function defaultPocketBaseUrlForUi() {
  if (typeof window === "undefined") {
    return "http://127.0.0.1:8090";
  }
  const protocol = window.location.protocol === "https:" ? "https:" : "http:";
  const host = window.location.hostname || "127.0.0.1";
  return `${protocol}//${host}:8090`;
}

function defaultUseGatewayChatApi() {
  if (typeof window === "undefined") {
    return true;
  }
  const stored = window.localStorage.getItem(CHAT_USE_GATEWAY_STORAGE_KEY);
  if (stored === "true") {
    return true;
  }
  if (stored === "false") {
    return false;
  }
  // Assume gateway-served UI should use gateway API; Vite dev usually runs on 5173.
  return window.location.port !== "5173";
}

function App() {
  const [pbUrl, setPbUrl] = useState(defaultPocketBaseUrlForUi);
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
  const [apiRequest, setApiRequest] = useState<ApiRequestState>(initialApiRequest);
  const [apiResponse, setApiResponse] = useState<string>("");
  const [drafts, setDrafts] = useState<StoredDraft[]>([]);
  const [history, setHistory] = useState<PostHistoryItem[]>([]);
  const [postedPaths, setPostedPaths] = useState<Record<string, true>>(() => {
    if (typeof window === "undefined") {
      return {};
    }
    const raw = window.localStorage.getItem(FEED_POSTED_PATHS_STORAGE_KEY);
    if (!raw) {
      return {};
    }
    try {
      const arr = JSON.parse(raw);
      if (!Array.isArray(arr)) {
        return {};
      }
      return arr
        .filter((v): v is string => typeof v === "string" && !!v.trim())
        .reduce<Record<string, true>>((acc, path) => {
          acc[path] = true;
          return acc;
        }, {});
    } catch {
      return {};
    }
  });
  const [chatThreadId, setChatThreadId] = useState<string>(() => {
    if (typeof window === "undefined") {
      return createThreadId();
    }
    const saved = window.localStorage.getItem(CHAT_THREAD_STORAGE_KEY);
    return saved && saved.trim() ? saved.trim() : createThreadId();
  });
  const [chatInput, setChatInput] = useState("");
  const [chatMessages, setChatMessages] = useState<ClawChatMessage[]>([]);
  const [chatStatus, setChatStatus] = useState("Chat idle");
  const [chatSending, setChatSending] = useState(false);
  const [chatUseGatewayApi, setChatUseGatewayApi] = useState<boolean>(defaultUseGatewayChatApi);
  const [chatGatewayToken, setChatGatewayToken] = useState<string>(() => {
    if (typeof window === "undefined") {
      return "";
    }
    return window.localStorage.getItem(CHAT_GATEWAY_TOKEN_STORAGE_KEY) || "";
  });
  const [chatPairCode, setChatPairCode] = useState("");
  const [chatPairing, setChatPairing] = useState(false);
  const [showGatewayToken, setShowGatewayToken] = useState(false);
  const [gatewayTokenCopyStatus, setGatewayTokenCopyStatus] = useState("");
  const [themeMode, setThemeMode] = useState<ThemeMode>(defaultThemeMode);
  const [mobileTab, setMobileTab] = useState<MobileTab>(defaultMobileTab);
  const [journalSidebarOpen, setJournalSidebarOpen] = useState(false);
  const [feedSidebarOpen, setFeedSidebarOpen] = useState(false);
  const [journalItems, setJournalItems] = useState<LibraryItem[]>([]);
  const [feedItems, setFeedItems] = useState<LibraryItem[]>([]);
  const [libraryStatus, setLibraryStatus] = useState("Library idle");
  const [selectedJournalPath, setSelectedJournalPath] = useState<string>("");
  const [selectedFeedPath, setSelectedFeedPath] = useState<string>("");
  const [selectedJournalItem, setSelectedJournalItem] = useState<LibraryItem | null>(null);
  const [selectedFeedItem, setSelectedFeedItem] = useState<LibraryItem | null>(null);
  const [selectedJournalText, setSelectedJournalText] = useState("");
  const [selectedFeedText, setSelectedFeedText] = useState("");
  const [journalDraftTitle, setJournalDraftTitle] = useState("");
  const [journalDraftText, setJournalDraftText] = useState("");
  const [journalSaveStatus, setJournalSaveStatus] = useState("Journal idle");
  const [feedCaptionText, setFeedCaptionText] = useState("");
  const [feedCaptionPath, setFeedCaptionPath] = useState<string>("");
  const [feedEditStatus, setFeedEditStatus] = useState("Feed idle");
  const [recordingHint, setRecordingHint] = useState("Ready to add a journal note, audio, or video.");
  const [mediaPreviewUrl, setMediaPreviewUrl] = useState<string>("");
  const [mediaPreviewLoading, setMediaPreviewLoading] = useState(false);
  const [postingFeedPath, setPostingFeedPath] = useState<string>("");
  const [feedPostedSectionOpen, setFeedPostedSectionOpen] = useState(false);
  const [postProgress, setPostProgress] = useState<{
    path: string;
    percent: number;
    label: string;
  } | null>(null);
  const audioCaptureRef = useRef<HTMLInputElement | null>(null);
  const videoCaptureRef = useRef<HTMLInputElement | null>(null);
  const autosaveTimerRef = useRef<number | null>(null);
  const loadedTextPathRef = useRef<string>("");
  const loadedCaptionPathRef = useRef<string>("");

  // Recording State
  const [isRecording, setIsRecording] = useState(false);
  const [recordingType, setRecordingType] = useState<"audio" | "video" | null>(null);
  const [recordingTime, setRecordingTime] = useState(0);
  const [audioDevices, setAudioDevices] = useState<MediaDeviceInfo[]>([]);
  const [selectedAudioDeviceId, setSelectedAudioDeviceId] = useState<string>("");
  const mediaRecorderRef = useRef<MediaRecorder | null>(null);
  const mediaStreamRef = useRef<MediaStream | null>(null);
  const recordingChunksRef = useRef<BlobPart[]>([]);
  const recordingTimerRef = useRef<number | null>(null);
  const videoPreviewRef = useRef<HTMLVideoElement | null>(null);
  const audioCanvasRef = useRef<HTMLCanvasElement | null>(null);
  const audioContextRef = useRef<AudioContext | null>(null);
  const analyserRef = useRef<AnalyserNode | null>(null);
  const animationFrameRef = useRef<number | null>(null);

  // Bluesky Feed State
  const [feedSource, setFeedSource] = useState<"local" | "bluesky">("local");
  const [blueskyFeedItems, setBlueskyFeedItems] = useState<AppBskyFeedDefs.FeedViewPost[]>([]);
  const [blueskyFeedLoading, setBlueskyFeedLoading] = useState(false);

  const pb = useMemo(() => createPocketBaseClient(pbUrl), [pbUrl]);

  useEffect(() => {
    let cancelled = false;
    (async () => {
      const secureCreds = await loadCredentialsSecure();
      if (!cancelled && secureCreds) {
        setCreds(secureCreds);
      }
      if (!cancelled) {
        setSecureStoreReady(true);
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
    window.localStorage.setItem(
      CHAT_GATEWAY_TOKEN_STORAGE_KEY,
      chatGatewayToken.trim()
    );
  }, [chatGatewayToken]);

  useEffect(() => {
    if (typeof window === "undefined") {
      return;
    }
    window.localStorage.setItem(
      CHAT_USE_GATEWAY_STORAGE_KEY,
      chatUseGatewayApi ? "true" : "false"
    );
  }, [chatUseGatewayApi]);

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
    if (typeof window === "undefined") {
      return;
    }
    const paths = Object.keys(postedPaths);
    window.localStorage.setItem(FEED_POSTED_PATHS_STORAGE_KEY, JSON.stringify(paths));
  }, [postedPaths]);

  useEffect(() => {
    return () => {
      if (mediaPreviewUrl) {
        URL.revokeObjectURL(mediaPreviewUrl);
      }
      if (autosaveTimerRef.current) {
        window.clearTimeout(autosaveTimerRef.current);
      }
    };
  }, [mediaPreviewUrl]);

  async function refreshLibrary(scope: "journal" | "feed" | "all") {
    const token = chatGatewayToken.trim() || undefined;
    try {
      if (scope === "journal" || scope === "all") {
        const items = await listLibraryItems("journal", token);
        setJournalItems(items);
        if (items.length > 0 && !selectedJournalPath) {
          setSelectedJournalPath(items[0].path);
        }
      }
      if (scope === "feed" || scope === "all") {
        const items = (await listLibraryItems("feed", token)).filter((item) => {
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
        if (items.length > 0 && !selectedFeedPath) {
          setSelectedFeedPath(items[0].path);
        }
      }
      setLibraryStatus(`Library refreshed (${scope})`);
    } catch (error) {
      setLibraryStatus(
        `Library unavailable (${error instanceof Error ? error.message : String(error)})`
      );
    }
  }

  async function uploadJournalFile(file: File, kind: "audio" | "video") {
    const token = chatGatewayToken.trim() || undefined;
    setRecordingHint(`Uploading ${file.name}...`);
    try {
      const result = await uploadMediaViaGateway(
        file,
        {
          kind,
          filename: file.name || `${kind}-${Date.now()}`,
          title: journalDraftTitle.trim() || undefined
        },
        token
      );
      setRecordingHint(
        `Saved ${kind} to workspace: ${String(result.path || file.name)} (${formatBytes(
          Number(result.bytes || file.size || 0)
        )})`
      );
      await refreshLibrary("journal");
    } catch (error) {
      setRecordingHint(
        `Upload failed (${error instanceof Error ? error.message : String(error)})`
      );
    }
  }

  async function saveJournalTextDraft() {
    const content = journalDraftText.trim();
    if (!content) {
      setJournalSaveStatus("Write something first");
      return;
    }
    const token = chatGatewayToken.trim() || undefined;
    setJournalSaveStatus("Saving journal note...");
    try {
      const result = await createJournalTextViaGateway(
        journalDraftTitle.trim() || "Journal entry",
        content,
        token
      );
      setJournalSaveStatus(`Saved: ${String(result.path || "journal entry")}`);
      setJournalDraftText("");
      if (!journalDraftTitle.trim()) {
        setJournalDraftTitle("");
      }
      await refreshLibrary("journal");
    } catch (error) {
      setJournalSaveStatus(
        `Save failed (${error instanceof Error ? error.message : String(error)})`
      );
    }
  }

  async function openLibraryItem(item: LibraryItem, scope: "journal" | "feed") {
    if (scope === "journal") {
      setSelectedJournalItem(item);
      setSelectedJournalPath(item.path);
    } else {
      setSelectedFeedItem(item);
      setSelectedFeedPath(item.path);
    }

    if (item.kind === "text") {
      const token = chatGatewayToken.trim() || undefined;
      try {
        const content = await readLibraryText(item.path, token);
        if (scope === "journal") {
          loadedTextPathRef.current = item.path;
          setSelectedJournalText(content);
        } else {
          loadedTextPathRef.current = item.path;
          setSelectedFeedText(content);
          setFeedEditStatus(`Loaded ${item.path}`);
        }
      } catch (error) {
        if (scope === "journal") {
          setSelectedJournalText("");
        } else {
          setSelectedFeedText("");
          setFeedEditStatus(
            `Read failed (${error instanceof Error ? error.message : String(error)})`
          );
        }
      }
    } else if (scope === "feed" && (item.kind === "video" || item.kind === "audio")) {
      const captionPath = sidecarCaptionPath(item);
      const token = chatGatewayToken.trim() || undefined;
      try {
        const content = await readLibraryText(captionPath, token);
        loadedCaptionPathRef.current = captionPath;
        setFeedCaptionPath(captionPath);
        setFeedCaptionText(content);
      } catch {
        loadedCaptionPathRef.current = captionPath;
        setFeedCaptionPath(captionPath);
        setFeedCaptionText(item.previewText || item.title || "");
      }
    }
  }

  async function loadMediaPreview(item: LibraryItem | null) {
    if (!item || !item.mediaUrl) {
      setMediaPreviewLoading(false);
      if (mediaPreviewUrl) {
        URL.revokeObjectURL(mediaPreviewUrl);
        setMediaPreviewUrl("");
      }
      return;
    }
    if (!(item.kind === "audio" || item.kind === "video" || item.kind === "image")) {
      return;
    }
    setMediaPreviewLoading(true);
    try {
      const token = chatGatewayToken.trim() || undefined;
      const res = await fetch(item.mediaUrl, {
        headers: token ? { Authorization: `Bearer ${token}` } : undefined
      });
      if (!res.ok) {
        throw new Error(`Preview load failed (${res.status})`);
      }
      const blob = await res.blob();
      const nextUrl = URL.createObjectURL(blob);
      setMediaPreviewUrl((prev) => {
        if (prev) {
          URL.revokeObjectURL(prev);
        }
        return nextUrl;
      });
    } catch (error) {
      setFeedEditStatus(
        `Preview unavailable (${error instanceof Error ? error.message : String(error)})`
      );
      if (mediaPreviewUrl) {
        URL.revokeObjectURL(mediaPreviewUrl);
        setMediaPreviewUrl("");
      }
    } finally {
      setMediaPreviewLoading(false);
    }
  }

  async function postFeedItemToBluesky(item: LibraryItem) {
    if (!agent || !session) {
      setFeedEditStatus("Sign in to Bluesky first");
      return;
    }
    if (postedPaths[item.path]) {
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
          selectedFeedItem?.path === item.path && selectedFeedText.trim()
            ? selectedFeedText
            : await readLibraryText(item.path, token);
        setPostProgress({ path: item.path, percent: 70, label: "Publishing text..." });
        const result = await postTextToBluesky(agent, session.did, content.trim());
        await persistHistory({
          provider: "bluesky",
          text: content.trim(),
          sourcePath: item.path,
          created: new Date().toISOString(),
          uri: result.uri,
          cid: result.cid,
          status: "success"
        });
        setPostedPaths((prev) => ({ ...prev, [item.path]: true }));
        setPostProgress({ path: item.path, percent: 100, label: "Posted." });
        setFeedEditStatus(`Posted text: ${result.uri}`);
      } else if (item.kind === "video") {
        if (!item.mediaUrl) {
          throw new Error("Missing media URL");
        }
        const filename = item.path.split("/").pop() || "video.mp4";
        setPostProgress({ path: item.path, percent: 12, label: "Fetching video file..." });
        const file = await fetchMediaAsFile(item.mediaUrl, filename, token);
        const caption =
          selectedFeedItem?.path === item.path ? feedCaptionText : item.previewText || item.title;
        const result = await postVideoToBluesky(
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
        setPostedPaths((prev) => ({ ...prev, [item.path]: true }));
        setPostProgress({ path: item.path, percent: 100, label: "Posted." });
        setFeedEditStatus(`Posted video: ${result.uri}`);
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
    const token = chatGatewayToken.trim() || undefined;
    setJournalSaveStatus(`Saving ${selectedJournalItem.path}...`);
    try {
      await saveLibraryText(selectedJournalItem.path, selectedJournalText, token);
      setJournalSaveStatus(`Saved ${selectedJournalItem.path}`);
      await refreshLibrary("journal");
    } catch (error) {
      setJournalSaveStatus(
        `Save failed (${error instanceof Error ? error.message : String(error)})`
      );
    }
  }

  async function refreshDrafts() {
    try {
      const result = await listDraftsFromPocketBase(pb);
      setDrafts(
        result.items.map((item) => ({
          id: item.id,
          text: String(item.text || ""),
          videoName: String(item.videoName || ""),
          created: String(item.createdAtClient || item.created || ""),
          updated: String(item.updatedAtClient || item.updated || "")
        }))
      );
    } catch (error) {
      setStatus(
        `PocketBase drafts unavailable (${error instanceof Error ? error.message : String(error)})`
      );
    }
  }

  async function refreshClawChat() {
    if (!chatThreadId.trim()) {
      return;
    }
    try {
      const threadId = chatThreadId.trim();
      const token = chatGatewayToken.trim() || undefined;
      const items = chatUseGatewayApi
        ? await listClawChatMessagesViaGateway(threadId, token)
        : await listClawChatMessagesFromPocketBase(pb, threadId);
      setChatMessages(items);
      setChatStatus(
        `Chat thread loaded (${items.length} messages) via ${chatUseGatewayApi ? "gateway" : "pocketbase"
        }`
      );
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
      const { agent: nextAgent, session: nextSession } = await loginBluesky(creds);
      setAgent(nextAgent);
      setSession(nextSession);
      setAuthMessage(`Signed in as ${nextSession.handle}`);
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
      await saveDraftToPocketBase(pb, draft);
      setStatus("Draft saved to PocketBase");
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
      await savePostHistoryToPocketBase(pb, item);
    } catch {
      // Local UI history remains available even if PocketBase write fails.
    }
  }

  async function refreshPostHistory() {
    try {
      const items = await listPostHistoryFromPocketBase(pb);
      setHistory((prev) => {
        if (prev.length === 0) {
          return items.slice(0, 20);
        }
        return prev;
      });
    } catch {
      // Keep local-only history if PocketBase query fails.
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
        ? await postVideoToBluesky(
          agent,
          creds.serviceUrl,
          session.accessJwt,
          session.did,
          text,
          videoFile,
          videoAlt
        )
        : await postTextToBluesky(agent, session.did, text);

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

  async function sendApiRequest() {
    setApiResponse("Sending...");
    try {
      const headers = JSON.parse(apiRequest.headersJson || "{}") as Record<string, string>;
      const hasBody = apiRequest.method !== "GET";
      const body = hasBody ? JSON.parse(apiRequest.bodyJson || "{}") : undefined;

      let result: unknown;
      if (apiRequest.includeBlueskyAuth && session) {
        result = await sendAuthedXrpcRequest({
          serviceUrl: creds.serviceUrl,
          accessJwt: session.accessJwt,
          method: apiRequest.method,
          url: apiRequest.url,
          headers,
          body
        });
      } else {
        const target = apiRequest.url.startsWith("http")
          ? apiRequest.url
          : `${creds.serviceUrl.replace(/\/+$/, "")}/${apiRequest.url.replace(/^\/+/, "")}`;

        const res = await fetch(target, {
          method: apiRequest.method,
          headers,
          body: hasBody ? JSON.stringify(body) : undefined
        });
        const textRes = await res.text();
        let parsed: unknown = textRes;
        try {
          parsed = JSON.parse(textRes);
        } catch {
          // keep text
        }
        result = {
          ok: res.ok,
          status: res.status,
          statusText: res.statusText,
          data: parsed
        };
      }

      setApiResponse(JSON.stringify(result, null, 2));
    } catch (error) {
      setApiResponse(
        JSON.stringify(
          {
            error: error instanceof Error ? error.message : String(error)
          },
          null,
          2
        )
      );
    }
  }

  async function sendClawChatMessage() {
    const content = chatInput.trim();
    const threadId = chatThreadId.trim();
    if (!threadId) {
      setChatStatus("Set a thread ID first");
      return;
    }
    if (!content) {
      setChatStatus("Enter a message first");
      return;
    }

    setChatSending(true);
    setChatStatus(
      `Sending message via ${chatUseGatewayApi ? "gateway" : "PocketBase"}...`
    );
    try {
      const token = chatGatewayToken.trim() || undefined;
      if (chatUseGatewayApi) {
        await createClawChatUserMessageViaGateway(threadId, content, token);
      } else {
        await createClawChatUserMessage(pb, threadId, content);
      }
      setChatInput("");
      setChatStatus("Message queued (waiting for SlowClaw reply)");
      await refreshClawChat();
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

  function drawAudioVisualizer() {
    if (!analyserRef.current || !audioCanvasRef.current) return;
    const canvas = audioCanvasRef.current;
    const ctx = canvas.getContext("2d");
    if (!ctx) return;

    const analyser = analyserRef.current;
    const bufferLength = analyser.frequencyBinCount;
    const dataArray = new Uint8Array(bufferLength);

    function draw() {
      animationFrameRef.current = requestAnimationFrame(draw);
      analyser.getByteTimeDomainData(dataArray);
      if (!ctx) return;

      ctx.fillStyle = "rgb(30, 30, 30)"; // Fit minimal theme
      ctx.fillRect(0, 0, canvas.width, canvas.height);

      ctx.lineWidth = 2;
      ctx.strokeStyle = "rgb(0, 200, 100)";
      ctx.beginPath();

      const sliceWidth = canvas.width * 1.0 / bufferLength;
      let x = 0;

      for (let i = 0; i < bufferLength; i++) {
        const v = dataArray[i] / 128.0;
        const y = v * canvas.height / 2;

        if (i === 0) {
          ctx.moveTo(x, y);
        } else {
          ctx.lineTo(x, y);
        }
        x += sliceWidth;
      }
      ctx.lineTo(canvas.width, canvas.height / 2);
      ctx.stroke();
    }
    draw();
  }

  async function startRecording(type: "audio" | "video") {
    try {
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
        window.location.hostname !== "localhost" &&
        window.location.hostname !== "127.0.0.1";

      if (!hasGetUserMedia || !hasMediaRecorder || insecureContext) {
        setRecordingHint(
          `${type === "audio" ? "Audio" : "Video"} live recording is unavailable in this browser context. Using upload/capture picker instead.`
        );
        if (type === "audio") {
          audioCaptureRef.current?.click();
        } else {
          videoCaptureRef.current?.click();
        }
        return;
      }

      setRecordingHint(`Starting ${type} recording...`);
      setRecordingType(type);
      setIsRecording(true);
      setRecordingTime(0);
      recordingChunksRef.current = [];

      const constraints: MediaStreamConstraints = {};
      if (type === "audio") {
        constraints.audio = selectedAudioDeviceId ? { deviceId: { exact: selectedAudioDeviceId } } : true;
      } else {
        constraints.audio = true;
        constraints.video = { facingMode: "user" };
      }

      const stream = await navigator.mediaDevices.getUserMedia(constraints);
      mediaStreamRef.current = stream;

      if (type === "audio") {
        const audioCtx = new AudioContext();
        audioContextRef.current = audioCtx;
        const source = audioCtx.createMediaStreamSource(stream);
        const analyser = audioCtx.createAnalyser();
        analyser.fftSize = 2048;
        source.connect(analyser);
        analyserRef.current = analyser;
        drawAudioVisualizer();
      } else if (type === "video" && videoPreviewRef.current) {
        videoPreviewRef.current.srcObject = stream;
        videoPreviewRef.current.play().catch(console.error);
      }

      const mediaRecorder = new MediaRecorder(stream);
      mediaRecorderRef.current = mediaRecorder;

      mediaRecorder.ondataavailable = (event) => {
        if (event.data.size > 0) {
          recordingChunksRef.current.push(event.data);
        }
      };

      mediaRecorder.onstop = async () => {
        if (recordingChunksRef.current.length > 0) {
          const blob = new Blob(recordingChunksRef.current, { type: type === "audio" ? "audio/webm" : "video/webm" });
          const file = new File([blob], `${type}-${Date.now()}.webm`, { type: blob.type });
          await uploadJournalFile(file, type);
        }
        cleanupRecording();
      };

      mediaRecorder.start(1000);
      recordingTimerRef.current = window.setInterval(() => {
        setRecordingTime(prev => prev + 1);
      }, 1000);
      setRecordingHint(`Recording ${type}...`);

    } catch (err) {
      setRecordingHint(`Failed to start recording: ${err instanceof Error ? err.message : String(err)}`);
      cleanupRecording();
    }
  }

  function stopRecording() {
    if (mediaRecorderRef.current && isRecording) {
      mediaRecorderRef.current.stop();
      if (recordingTimerRef.current) {
        clearInterval(recordingTimerRef.current);
        recordingTimerRef.current = null;
      }
      setRecordingHint("Processing recording...");
    }
  }

  function cancelRecording() {
    if (mediaRecorderRef.current && isRecording) {
      recordingChunksRef.current = [];
      mediaRecorderRef.current.stop();
      if (recordingTimerRef.current) {
        clearInterval(recordingTimerRef.current);
        recordingTimerRef.current = null;
      }
      setRecordingHint("Recording cancelled.");
    } else {
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
    if (animationFrameRef.current) {
      cancelAnimationFrame(animationFrameRef.current);
      animationFrameRef.current = null;
    }
    if (videoPreviewRef.current) {
      videoPreviewRef.current.srcObject = null;
    }
    setIsRecording(false);
    setRecordingType(null);
    setRecordingTime(0);
  }

  async function fetchBlueskyFeed() {
    if (!agent || !session) {
      setBlueskyFeedLoading(false);
      return;
    }
    setBlueskyFeedLoading(true);
    try {
      const res = await agent.getTimeline({ limit: 30 });
      setBlueskyFeedItems(res.data.feed);
    } catch (error) {
      console.error("Failed to fetch Bluesky feed", error);
    } finally {
      setBlueskyFeedLoading(false);
    }
  }

  useEffect(() => {
    if (feedSource === "bluesky") {
      void fetchBlueskyFeed();
    }
  }, [feedSource, agent, session]);

  async function pairGatewayFromUi() {
    const code = chatPairCode.trim();
    if (!code) {
      setChatStatus("Enter the one-time pairing code shown in the daemon terminal");
      return;
    }
    setChatPairing(true);
    setChatStatus("Pairing with gateway...");
    try {
      const result = await pairGatewayClient(code);
      if (!result.token) {
        throw new Error("Gateway returned no token");
      }
      setChatGatewayToken(result.token);
      setChatPairCode("");
      setChatStatus(result.message || "Paired. Token saved in browser storage.");
      await refreshClawChat();
    } catch (error) {
      setChatStatus(
        `Pairing failed (${error instanceof Error ? error.message : String(error)})`
      );
    } finally {
      setChatPairing(false);
    }
  }

  async function copyGatewayToken() {
    const token = chatGatewayToken.trim();
    if (!token) {
      setGatewayTokenCopyStatus("No token to copy");
      return;
    }
    try {
      await navigator.clipboard.writeText(token);
      setGatewayTokenCopyStatus("Token copied");
    } catch {
      setGatewayTokenCopyStatus("Copy failed");
    }
  }

  useEffect(() => {
    void refreshClawChat();
    const timer = window.setInterval(() => {
      void refreshClawChat();
    }, 1500);
    return () => {
      window.clearInterval(timer);
    };
  }, [pb, chatThreadId, chatUseGatewayApi, chatGatewayToken]);

  useEffect(() => {
    void refreshLibrary("all");
  }, [chatGatewayToken]);

  useEffect(() => {
    void refreshPostHistory();
  }, [pbUrl]);

  useEffect(() => {
    const item = journalItems.find((entry) => entry.path === selectedJournalPath) || null;
    setSelectedJournalItem(item);
    if (item) {
      void openLibraryItem(item, "journal");
    } else {
      setSelectedJournalText("");
    }
  }, [journalItems, selectedJournalPath]);

  useEffect(() => {
    const item = feedItems.find((entry) => entry.path === selectedFeedPath) || null;
    setSelectedFeedItem(item);
    if (item) {
      void openLibraryItem(item, "feed");
    } else {
      setSelectedFeedText("");
      setFeedCaptionText("");
      setFeedCaptionPath("");
    }
  }, [feedItems, selectedFeedPath]);

  useEffect(() => {
    const item = mobileTab === "feed" ? selectedFeedItem : selectedJournalItem;
    if (item && (item.kind === "audio" || item.kind === "video" || item.kind === "image")) {
      void loadMediaPreview(item);
      return;
    }
    void loadMediaPreview(null);
  }, [mobileTab, selectedFeedItem, selectedJournalItem, chatGatewayToken]);

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
        await saveLibraryText(selectedFeedItem.path, selectedFeedText, token);
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
  }, [selectedFeedText, selectedFeedItem, chatGatewayToken]);

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
        await saveLibraryText(feedCaptionPath, feedCaptionText, token);
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
  }, [feedCaptionText, feedCaptionPath, selectedFeedItem, chatGatewayToken]);

  const journalList = journalItems;
  const feedList = feedItems;
  const postedHistory = history.filter((item) => item.status === "success");

  return (
    <div className="app-shell">
      <header className="topbar">
        <div className="row" style={{ alignItems: "center", gap: "1rem" }}>
          {mobileTab === "journal" && (
            <button type="button" className="ghost" onClick={() => setJournalSidebarOpen(true)} style={{ padding: "0.2rem" }}>
              <svg width="24" height="24" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round"><line x1="3" y1="12" x2="21" y2="12"></line><line x1="3" y1="6" x2="21" y2="6"></line><line x1="3" y1="18" x2="21" y2="18"></line></svg>
            </button>
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
        </div>
      </header>

      <div className={`sidebar-overlay ${journalSidebarOpen ? 'open' : ''}`} onClick={() => setJournalSidebarOpen(false)}>
        <div className={`sidebar ${journalSidebarOpen ? 'open' : ''}`} onClick={e => e.stopPropagation()}>
          <div className="row-between" style={{ marginBottom: "1.5rem" }}>
            <h2>Recent Journals</h2>
            <button type="button" className="ghost" onClick={() => void refreshLibrary("journal")}>
              <svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round"><polyline points="23 4 23 10 17 10"></polyline><polyline points="1 20 1 14 7 14"></polyline><path d="M3.51 9a9 9 0 0 1 14.85-3.36L23 10M1 14l4.64 4.36A9 9 0 0 0 20.49 15"></path></svg>
            </button>
          </div>

          {journalItems.length === 0 ? (
            <p className="text-center muted">No journals found.</p>
          ) : (
            <div className="stack">
              {journalItems.map(item => (
                <div key={item.path} className="row-between" style={{ padding: "0.8rem", background: selectedJournalPath === item.path ? "color-mix(in srgb, var(--line) 40%, transparent)" : "transparent", borderRadius: "12px" }}>
                  <div className="stack" style={{ gap: '4px', flex: 1, cursor: 'pointer' }} onClick={() => { void openLibraryItem(item, "journal"); setJournalSidebarOpen(false); }}>
                    <div className="feed-title">{item.title}</div>
                    <div className="feed-time">{formatTimestamp(item.modifiedAt)} · {item.kind.toUpperCase()}</div>
                  </div>
                </div>
              ))}
            </div>
          )}
        </div>
      </div>

      <main className="page-content">
        {mobileTab === "journal" ? (
          <div className="stack">
            <div className="card">
              <div className="text-center">
                <h2>Capture</h2>
                <p className="text-sm mt-2">{recordingHint || "Record audio or video directly to workspace"}</p>
              </div>
              {isRecording ? (
                <div className="stack" style={{ alignItems: "center", padding: "1rem" }}>
                  {recordingType === "audio" && (
                    <canvas ref={audioCanvasRef} width={300} height={100} style={{ width: "100%", maxWidth: "400px", borderRadius: "8px", background: "rgb(30, 30, 30)" }} />
                  )}
                  {recordingType === "video" && (
                    <video ref={videoPreviewRef} style={{ width: "100%", maxWidth: "400px", borderRadius: "8px", background: "#000" }} muted playsInline />
                  )}
                  <div className="text-lg" style={{ fontWeight: 600, color: "var(--danger)" }}>
                    {Math.floor(recordingTime / 60)}:{(recordingTime % 60).toString().padStart(2, '0')}
                  </div>
                  <div className="row">
                    <button type="button" className="danger" onClick={stopRecording}>Stop & Save</button>
                    <button type="button" className="ghost" onClick={cancelRecording}>Cancel</button>
                  </div>
                </div>
              ) : (
                <div className="stack">
                  <div className="record-btn-group">
                    <button
                      type="button"
                      className="record-btn audio"
                      onClick={() => void startRecording("audio")}
                      title="Record Audio"
                    >
                      <svg viewBox="0 0 24 24"><path d="M12 1a3 3 0 0 0-3 3v8a3 3 0 0 0 6 0V4a3 3 0 0 0-3-3z"></path><path d="M19 10v2a7 7 0 0 1-14 0v-2"></path><line x1="12" y1="19" x2="12" y2="23"></line><line x1="8" y1="23" x2="16" y2="23"></line></svg>
                    </button>
                    <button
                      type="button"
                      className="record-btn video"
                      onClick={() => void startRecording("video")}
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

                  <div className="row-center mt-2" style={{ gap: '1rem' }}>
                    <button type="button" className="ghost text-sm" onClick={() => audioCaptureRef.current?.click()}>Upload Audio</button>
                    <button type="button" className="ghost text-sm" onClick={() => videoCaptureRef.current?.click()}>Upload Video</button>
                  </div>

                  <input
                    ref={audioCaptureRef}
                    type="file"
                    accept="audio/*"
                    className="visually-hidden"
                    onChange={(e) => {
                      const file = e.target.files?.[0];
                      if (file) void uploadJournalFile(file, "audio");
                      e.currentTarget.value = "";
                    }}
                  />
                  <input
                    ref={videoCaptureRef}
                    type="file"
                    accept="video/*"
                    capture="environment"
                    className="visually-hidden"
                    onChange={(e) => {
                      const file = e.target.files?.[0];
                      if (file) void uploadJournalFile(file, "video");
                      e.currentTarget.value = "";
                    }}
                  />
                </div>
              )}

              <input
                value={journalDraftTitle}
                onChange={(e) => setJournalDraftTitle(e.target.value)}
                placeholder="Title (used for uploads & notes)"
              />
            </div>

            <div className="card">
              <div className="row-between">
                <h2>Note</h2>
                <button type="button" className="ghost" onClick={saveJournalTextDraft}>Save</button>
              </div>
              <textarea
                rows={5}
                value={journalDraftText}
                onChange={(e) => setJournalDraftText(e.target.value)}
                placeholder="Write your thoughts..."
              />
              {journalSaveStatus !== "Journal idle" && (
                <p className="text-sm text-center muted">{journalSaveStatus}</p>
              )}
            </div>

            {selectedJournalItem && mediaPreviewUrl && (
              <div className="card">
                <h3>Preview: {selectedJournalItem.title}</h3>
                {selectedJournalItem.kind === "audio" && (
                  <audio controls src={mediaPreviewUrl} style={{ width: '100%' }} />
                )}
                {selectedJournalItem.kind === "video" && (
                  <video controls src={mediaPreviewUrl} className="media-viewer" />
                )}
                {selectedJournalItem.kind === "image" && (
                  <img src={mediaPreviewUrl} alt="" className="media-viewer" />
                )}
              </div>
            )}
          </div>
        ) : null}

        {mobileTab === "feed" ? (
          <div className="stack">
            <div className="card">
              <div className="row-between">
                <h2>Your Feed</h2>
                <button type="button" className="ghost" onClick={() => feedSource === "bluesky" ? void fetchBlueskyFeed() : void refreshLibrary("feed")}>
                  <svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round"><polyline points="23 4 23 10 17 10"></polyline><polyline points="1 20 1 14 7 14"></polyline><path d="M3.51 9a9 9 0 0 1 14.85-3.36L23 10M1 14l4.64 4.36A9 9 0 0 0 20.49 15"></path></svg>
                </button>
              </div>

              <div className="segmented-control mt-2 mb-2">
                <button
                  type="button"
                  className={feedSource === "local" ? "active" : ""}
                  onClick={() => setFeedSource("local")}
                >
                  Workspace
                </button>
                <button
                  type="button"
                  className={feedSource === "bluesky" ? "active" : ""}
                  onClick={() => setFeedSource("bluesky")}
                >
                  Bluesky
                </button>
              </div>

              {feedSource === "bluesky" ? (
                blueskyFeedLoading ? (
                  <p className="text-center muted" style={{ padding: "2rem" }}>Loading Bluesky timeline...</p>
                ) : blueskyFeedItems.length === 0 ? (
                  <p className="text-center muted" style={{ padding: "2rem" }}>No Bluesky posts found, or not logged in. Check Settings.</p>
                ) : (
                  <div className="stack">
                    {blueskyFeedItems.map((feedItem, idx) => {
                      const post = feedItem.post;
                      const author = post.author;
                      const record = post.record as any;
                      return (
                        <div key={`${post.cid}-${idx}`} className="feed-item">
                          <div className="feed-header">
                            <div className="feed-title" style={{ display: 'flex', alignItems: 'center', gap: '8px' }}>
                              {author.avatar && <img src={author.avatar} alt="" style={{ width: '24px', height: '24px', borderRadius: '50%', objectFit: "cover" }} />}
                              <strong>{author.displayName || author.handle}</strong> <span className="muted text-sm" style={{ fontWeight: 'normal' }}>@{author.handle}</span>
                            </div>
                            <div className="feed-time">{formatTimestamp(post.indexedAt)}</div>
                          </div>
                          <div className="feed-body" style={{ marginTop: '8px', wordBreak: "break-word", whiteSpace: "pre-wrap" }}>
                            {record.text}
                          </div>
                          <div className="feed-actions">
                            <a href={`https://bsky.app/profile/${author.handle}/post/${post.uri.split("/").pop()}`} target="_blank" rel="noreferrer" className="ghost text-sm" style={{ textDecoration: "none", padding: "0.2rem 0.5rem" }}>View on Bluesky</a>
                          </div>
                        </div>
                      );
                    })}
                  </div>
                )
              ) : feedItems.length === 0 ? (
                <p className="text-center muted">No items in your workspace feed yet.</p>
              ) : (
                <div className="stack">
                  {feedItems.map(item => (
                    <div key={item.path} className="feed-item">
                      <div className="feed-header">
                        <div className="feed-title">{item.title}</div>
                        <div className="feed-time">{formatTimestamp(item.modifiedAt)}</div>
                      </div>
                      <div className="feed-body">
                        {item.previewText ? item.previewText : <span className="muted">[{item.kind.toUpperCase()} File attached]</span>}
                      </div>
                      <div className="feed-actions">
                        {(item.kind === "text" || item.kind === "video") && (
                          <button
                            type="button"
                            className="primary text-sm"
                            style={{ padding: '0.4rem 0.8rem', borderRadius: '8px' }}
                            onClick={() => void postFeedItemToBluesky(item)}
                            disabled={postingFeedPath === item.path || !!postedPaths[item.path]}
                          >
                            {postedPaths[item.path]
                              ? "Posted"
                              : postingFeedPath === item.path
                                ? "Posting..."
                                : "Like & Post"}
                          </button>
                        )}
                        <button
                          type="button"
                          className="ghost text-sm"
                          style={{ padding: '0.4rem 0.8rem', borderRadius: '8px' }}
                          onClick={() => void openLibraryItem(item, "feed")}
                        >
                          View Details
                        </button>
                      </div>

                      {selectedFeedItem?.path === item.path && mediaPreviewUrl && (
                        <div className="stack mt-2">
                          {selectedFeedItem.kind === "video" && (
                            <video controls src={mediaPreviewUrl} className="media-viewer" />
                          )}
                          {selectedFeedItem.kind === "audio" && (
                            <audio controls src={mediaPreviewUrl} style={{ width: '100%' }} />
                          )}
                          {selectedFeedItem.kind === "image" && (
                            <img src={mediaPreviewUrl} alt="" className="media-viewer" />
                          )}
                        </div>
                      )}

                      {selectedFeedItem?.path === item.path && selectedFeedItem.kind === "text" && (
                        <textarea
                          rows={6}
                          value={selectedFeedText}
                          onChange={(e) => setSelectedFeedText(e.target.value)}
                          style={{ marginTop: '0.5rem' }}
                        />
                      )}
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
                  ))}
                  {postedHistory.length > 0 && (
                    <div className="posted-history">
                      <button
                        type="button"
                        className="ghost posted-history-toggle"
                        onClick={() => setFeedPostedSectionOpen((prev) => !prev)}
                      >
                        {feedPostedSectionOpen ? "Hide Posted" : `Show Posted (${postedHistory.length})`}
                      </button>
                      {feedPostedSectionOpen && (
                        <div className="posted-history-list">
                          {postedHistory.slice(0, 20).map((item, idx) => (
                            <div key={`${item.uri || item.created}-${idx}`} className="posted-history-item">
                              <div className="feed-title">{item.videoName || "Text post"}</div>
                              <div className="feed-time">{formatTimestamp(item.created)}</div>
                              {item.uri ? (
                                <a
                                  href={`https://bsky.app/profile/${session?.handle || ""}/post/${item.uri.split("/").pop()}`}
                                  target="_blank"
                                  rel="noreferrer"
                                  className="text-sm"
                                >
                                  Open on Bluesky
                                </a>
                              ) : null}
                            </div>
                          ))}
                        </div>
                      )}
                    </div>
                  )}
                </div>
              )}
            </div>
          </div>
        ) : null}

        {mobileTab === "chat" ? (
          <div className="stack" style={{ paddingBottom: '20px' }}>
            <div className="card" style={{ flex: 1, marginBottom: '60px' }}>
              <div className="row-between">
                <h2>Assistant</h2>
                <button type="button" className="ghost" onClick={refreshClawChat}>
                  <svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round"><polyline points="23 4 23 10 17 10"></polyline><polyline points="1 20 1 14 7 14"></polyline><path d="M3.51 9a9 9 0 0 1 14.85-3.36L23 10M1 14l4.64 4.36A9 9 0 0 0 20.49 15"></path></svg>
                </button>
              </div>

              <div className="stack" style={{ minHeight: '300px', overflowY: 'auto', flex: 1 }}>
                {chatMessages.length === 0 ? (
                  <p className="text-center muted">Send a message to start chatting with SlowClaw.</p>
                ) : (
                  chatMessages.map(msg => (
                    <div key={msg.id} className={`stack`} style={{ alignItems: msg.role === 'user' ? 'flex-end' : 'flex-start' }}>
                      <div className={`chat-bubble ${msg.role}`}>
                        {msg.content || (msg.error ? `(error) ${msg.error}` : "(empty)")}
                      </div>
                      <small className="muted text-sm">{msg.status}</small>
                    </div>
                  ))
                )}
              </div>
            </div>

            <div style={{ position: 'fixed', bottom: '85px', left: 0, right: 0, padding: '1rem 1.5rem', background: 'var(--bg)', zIndex: 45, display: 'flex', gap: '0.5rem', maxWidth: '680px', margin: '0 auto' }}>
              <input
                value={chatInput}
                onChange={(e) => setChatInput(e.target.value)}
                placeholder="Message SlowClaw..."
                style={{ borderRadius: '24px', flex: 1 }}
                onKeyDown={(e) => {
                  if (e.key === 'Enter' && !e.shiftKey) {
                    e.preventDefault();
                    void sendClawChatMessage();
                  }
                }}
              />
              <button
                type="button"
                className="primary"
                style={{ borderRadius: '50%', width: '48px', height: '48px', padding: 0, display: 'flex', alignItems: 'center', justifyContent: 'center' }}
                onClick={sendClawChatMessage}
                disabled={chatSending || !chatInput.trim()}
              >
                <svg width="20" height="20" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round"><line x1="22" y1="2" x2="11" y2="13"></line><polygon points="22 2 15 22 11 13 2 9 22 2"></polygon></svg>
              </button>
            </div>
          </div>
        ) : null}

        {mobileTab === "profile" ? (
          <div className="stack">
            <div className="card">
              <h2>Bluesky Login</h2>
              <form className="stack" onSubmit={handleLogin}>
                <input
                  value={creds.serviceUrl}
                  onChange={(e) => setCreds(prev => ({ ...prev, serviceUrl: e.target.value }))}
                  placeholder="https://bsky.social"
                />
                <input
                  value={creds.handle}
                  onChange={(e) => setCreds(prev => ({ ...prev, handle: e.target.value }))}
                  placeholder="Handle or Email"
                />
                <input
                  type="password"
                  value={creds.appPassword}
                  onChange={(e) => setCreds(prev => ({ ...prev, appPassword: e.target.value }))}
                  placeholder="App Password"
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

            <div className="card">
              <h2>Gateway & App Settings</h2>
              <div className="stack">
                <p><strong>Gateway Pairing Token</strong></p>
                <div className="row">
                  <input
                    value={chatPairCode}
                    onChange={(e) => setChatPairCode(e.target.value)}
                    placeholder="Pairing Code"
                    style={{ flex: 1 }}
                  />
                  <button type="button" onClick={pairGatewayFromUi} disabled={chatPairing}>Pair</button>
                </div>
                {chatGatewayToken && (
                  <div className="stack" style={{ gap: "0.4rem" }}>
                    <div className="row">
                      <input
                        type={showGatewayToken ? "text" : "password"}
                        value={chatGatewayToken}
                        readOnly
                        style={{ flex: 1 }}
                      />
                    </div>
                    <div className="row">
                      <button
                        type="button"
                        className="ghost"
                        onClick={() => setShowGatewayToken((prev) => !prev)}
                      >
                        {showGatewayToken ? "Hide Token" : "Show Token"}
                      </button>
                      <button type="button" className="ghost" onClick={() => void copyGatewayToken()}>
                        Copy Token
                      </button>
                    </div>
                    <p className="text-sm muted">
                      {gatewayTokenCopyStatus || "Token synced and ready to use for `slowclaw pair new-code`."}
                    </p>
                  </div>
                )}

                <p className="mt-2"><strong>PocketBase Server Link</strong></p>
                <input value={pbUrl} onChange={(e) => setPbUrl(e.target.value)} placeholder="http://127.0.0.1:8090" />

                <p className="mt-2"><strong>Chat Thread ID</strong></p>
                <div className="row">
                  <input value={chatThreadId} onChange={(e) => setChatThreadId(e.target.value)} style={{ flex: 1 }} />
                  <button type="button" onClick={() => setChatThreadId(createThreadId())}>New</button>
                </div>
              </div>
            </div>

            <div className="card">
              <div className="row-between">
                <h2>API Requests Box</h2>
                <button type="button" className="ghost" onClick={sendApiRequest}>Send</button>
              </div>
              <input value={apiRequest.url} onChange={(e) => setApiRequest(prev => ({ ...prev, url: e.target.value }))} placeholder="URL" />
              <textarea rows={3} value={apiRequest.bodyJson} onChange={(e) => setApiRequest(prev => ({ ...prev, bodyJson: e.target.value }))} placeholder="JSON Body (if POST)" />
              {apiResponse && <pre style={{ fontSize: '0.8rem', whiteSpace: 'pre-wrap', background: 'var(--bg)', padding: '1rem', borderRadius: '12px' }}>{apiResponse.slice(0, 500)}{apiResponse.length > 500 ? '...' : ''}</pre>}
            </div>
          </div>
        ) : null}
      </main>

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
          className={mobileTab === "chat" ? "active" : ""}
          onClick={() => setMobileTab("chat")}
        >
          <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round"><path d="M21 15a2 2 0 0 1-2 2H7l-4 4V5a2 2 0 0 1 2-2h14a2 2 0 0 1 2 2z"></path></svg>
          Chat
        </button>
        <button
          type="button"
          className={mobileTab === "profile" ? "active" : ""}
          onClick={() => setMobileTab("profile")}
        >
          <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round"><path d="M20 21v-2a4 4 0 0 0-4-4H8a4 4 0 0 0-4 4v2"></path><circle cx="12" cy="7" r="4"></circle></svg>
          Settings
        </button>
      </nav>
    </div>
  );
}

export default App;
