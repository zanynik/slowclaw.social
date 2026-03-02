import { FormEvent, useEffect, useMemo, useRef, useState } from "react";
import type { AtpAgent } from "@atproto/api";
import { QRCodeCanvas } from "qrcode.react";
import {
  loginBluesky,
  postTextToBluesky,
  postVideoToBluesky,
  type BlueskySession
} from "./lib/bluesky";
import { AppBskyFeedDefs } from "@atproto/api";
import {
  createClawChatUserMessageViaGateway,
  createPocketBaseClient,
  ensurePocketBaseUserFromBluesky,
  getLatestChatThreadViaGateway,
  listClawChatMessagesViaGateway,
  listDraftsFromPocketBase,
  pocketBaseAuthLabel,
  listPostHistoryFromPocketBase,
  saveDraftToPocketBase,
  savePostHistoryToPocketBase
} from "./lib/pocketbase";
import {
  archivePostedLibraryItem,
  createJournalTextViaGateway,
  fetchMediaAsFile,
  listLibraryItems,
  readLibraryText,
  saveLibraryText,
  uploadMediaViaGateway
} from "./lib/gatewayApi";
import {
  deleteCredentialsSecure,
  loadCredentialsFallback,
  loadCredentialsSecure,
  loadGatewayTokenSecure,
  saveBlueskySessionSecure,
  saveCredentialsSecure,
  saveGatewayTokenSecure
} from "./lib/secureStorage";
import type {
  BlueskyCredentials,
  ClawChatMessage,
  GatewayQrPayload,
  LibraryItem,
  OpenAiDeviceCodeStatus,
  PostHistoryItem,
  StoredDraft
} from "./lib/types";

const CHAT_THREAD_STORAGE_KEY = "slowclaw.chat.thread_id";
const CHAT_GATEWAY_TOKEN_STORAGE_KEY = "slowclaw.chat.gateway_token";
const CHAT_GATEWAY_BASE_URL_STORAGE_KEY = "slowclaw.chat.gateway_base_url";
const UI_THEME_STORAGE_KEY = "slowclaw.ui.theme";
const UI_TAB_STORAGE_KEY = "slowclaw.ui.tab";
const FEED_POSTED_PATHS_STORAGE_KEY = "slowclaw.feed.posted_paths";
const DESKTOP_SECRET_SERVICE = "social.slowclaw.gateway";
const PROVIDER_API_KEY_SECRET_ACCOUNT = "provider.api_key";

type MobileTab = "journal" | "feed" | "chat" | "profile";
type ThemeMode = "light" | "dark";
type DesktopGatewayBootstrap = {
  token?: string | null;
  gatewayUrl?: string | null;
};

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
  return saved === "feed" || saved === "chat" || saved === "profile" ? saved : "journal";
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

function isTauriDesktopRuntime() {
  if (typeof window === "undefined") {
    return false;
  }
  return Boolean((window as any).__TAURI_INTERNALS__);
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

function derivePocketBaseUrlFromGateway(gatewayBaseUrl: string) {
  try {
    const parsed = new URL(gatewayBaseUrl);
    parsed.port = "8090";
    parsed.pathname = "";
    parsed.search = "";
    parsed.hash = "";
    return parsed.toString().replace(/\/+$/, "");
  } catch {
    return defaultPocketBaseUrlForUi();
  }
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

function App() {
  const isDesktopClient = isTauriDesktopRuntime();
  const isLargeScreen = useIsLargeScreen();
  const isDesktopLayout = isDesktopClient || isLargeScreen;
  const [gatewayBaseUrl, setGatewayBaseUrl] = useState(defaultGatewayBaseUrl);
  const [pbUrl, setPbUrl] = useState(() =>
    derivePocketBaseUrlFromGateway(defaultGatewayBaseUrl())
  );
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
  const [desktopQrLoading, setDesktopQrLoading] = useState(false);
  const [desktopQrPayload, setDesktopQrPayload] = useState<GatewayQrPayload | null>(null);
  const [desktopQrStatus, setDesktopQrStatus] = useState("");
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
  const [journalDraftText, setJournalDraftText] = useState("");
  const [journalSaveStatus, setJournalSaveStatus] = useState("Journal idle");
  const [isWritingNote, setIsWritingNote] = useState(false);
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
  const [aiSetupStatus, setAiSetupStatus] = useState<OpenAiDeviceCodeStatus | null>(null);
  const [aiSetupBusy, setAiSetupBusy] = useState(false);
  const [pbAuthMessage, setPbAuthMessage] = useState("");
  const [pbAuthLabel, setPbAuthLabel] = useState("");
  const [providerApiKey, setProviderApiKey] = useState("");
  const [providerApiKeyStatus, setProviderApiKeyStatus] = useState("");
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
  const audioCaptureRef = useRef<HTMLInputElement | null>(null);
  const videoCaptureRef = useRef<HTMLInputElement | null>(null);
  const autosaveTimerRef = useRef<number | null>(null);
  const journalAutosaveTimerRef = useRef<number | null>(null);
  const loadedTextPathRef = useRef<string>("");
  const loadedCaptionPathRef = useRef<string>("");
  const chatThreadHydratedRef = useRef(false);
  const mobileScannerVideoRef = useRef<HTMLVideoElement | null>(null);
  const mobileScannerStreamRef = useRef<MediaStream | null>(null);
  const mobileScannerRafRef = useRef<number | null>(null);

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
    const label = pocketBaseAuthLabel(pb);
    setPbAuthLabel(label);
    if (pb.authStore.isValid) {
      setPbAuthMessage(label ? `PocketBase signed in as ${label}` : "PocketBase signed in");
    } else {
      setPbAuthMessage("PocketBase not signed in");
    }
  }, [pb]);

  useEffect(() => {
    let cancelled = false;
    (async () => {
      const secureCreds = await loadCredentialsSecure();
      if (!cancelled && secureCreds) {
        setCreds(secureCreds);
        if (secureCreds.handle.trim() && secureCreds.appPassword.trim()) {
          try {
            const { agent: autoAgent, session: autoSession } = await loginBluesky(secureCreds);
            if (!cancelled) {
              setAgent(autoAgent);
              setSession(autoSession);
              setAuthMessage(`Signed in as ${autoSession.handle}`);
            }
            try {
              const pbSync = await ensurePocketBaseUserFromBluesky(
                pb,
                secureCreds.handle,
                secureCreds.appPassword,
                autoSession.handle
              );
              if (!cancelled) {
                const label = pocketBaseAuthLabel(pb);
                setPbAuthLabel(label);
                setPbAuthMessage(
                  pbSync.created
                    ? `PocketBase user provisioned and signed in (${label || pbSync.identity})`
                    : `PocketBase signed in as ${label || pbSync.identity}`
                );
              }
            } catch (error) {
              if (!cancelled) {
                setPbAuthMessage(
                  `PocketBase auto-login failed (${error instanceof Error ? error.message : String(error)})`
                );
              }
            }
          } catch {
            // Keep login-gated flow; user can sign in explicitly.
          }
        }
      }
      if (!cancelled && isDesktopClient) {
        const secureGatewayToken = await loadGatewayTokenSecure();
        if (secureGatewayToken) {
          setChatGatewayToken(secureGatewayToken);
        } else {
          await syncDesktopGatewayBootstrap();
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
    const normalized = gatewayBaseUrl.trim().replace(/\/+$/, "");
    window.localStorage.setItem(CHAT_GATEWAY_BASE_URL_STORAGE_KEY, normalized);
    if (normalized) {
      setPbUrl(derivePocketBaseUrlFromGateway(normalized));
    }
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
    let token = chatGatewayToken.trim();
    if (!token && isDesktopClient) {
      token = (await syncDesktopGatewayBootstrap())?.trim() || "";
    }
    try {
      if (scope === "journal" || scope === "all") {
        const items = (await listLibraryItems("journal", token || undefined, gatewayBaseUrl)).filter((item) => {
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
          return path.startsWith("journals/text/") && path.endsWith(".txt");
        });
        setJournalItems(items);
        if (items.length > 0 && !selectedJournalPath) {
          setSelectedJournalPath(items[0].path);
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
    let token = chatGatewayToken.trim();
    if (!gatewayBaseUrl.trim()) {
      setRecordingHint("Upload blocked (gateway URL missing). Pair mobile with desktop QR.");
      return;
    }
    if (!token && isDesktopClient) {
      token = (await syncDesktopGatewayBootstrap())?.trim() || "";
    }
    if (!token) {
      setRecordingHint(
        isDesktopClient
          ? "Upload blocked (desktop gateway token not ready). Wait 2-3s or restart app."
          : "Upload blocked (gateway token missing). Pair mobile with desktop QR."
      );
      return;
    }
    setRecordingHint(`Uploading ${file.name}...`);
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
      }
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
      let resultPath = "";
      if (selectedJournalItem && selectedJournalItem.kind === "text") {
        await saveLibraryText(selectedJournalItem.path, content, token, gatewayBaseUrl);
        resultPath = selectedJournalItem.path;
      } else if (selectedJournalItem && (selectedJournalItem.kind === "audio" || selectedJournalItem.kind === "video")) {
        const captionPath = sidecarCaptionPath(selectedJournalItem);
        await saveLibraryText(captionPath, content, token, gatewayBaseUrl);
        resultPath = captionPath;
      } else {
        const result = await createJournalTextViaGateway(
          "Journal entry",
          content,
          token,
          gatewayBaseUrl
        );
        resultPath = String(result.path || "");
      }
      setJournalSaveStatus(`Saved`);
      if (!selectedJournalItem) {
        await refreshLibrary("journal");
        if (resultPath) setSelectedJournalPath(resultPath);
      }
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
        const content = await readLibraryText(item.path, token, gatewayBaseUrl);
        if (scope === "journal") {
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
          setSelectedJournalText("");
        } else {
          setSelectedFeedText("");
          setFeedEditStatus(
            `Read failed (${error instanceof Error ? error.message : String(error)})`
          );
        }
      }
    } else if (item.kind === "video" || item.kind === "audio") {
      const captionPath = sidecarCaptionPath(item);
      const token = chatGatewayToken.trim() || undefined;
      try {
        const content = await readLibraryText(captionPath, token, gatewayBaseUrl);
        if (scope === "feed") {
          loadedCaptionPathRef.current = captionPath;
          setFeedCaptionPath(captionPath);
          setFeedCaptionText(content);
        } else {
          loadedTextPathRef.current = captionPath;
          setSelectedJournalText(content);
          setJournalDraftText(content);
        }
      } catch {
        if (scope === "feed") {
          loadedCaptionPathRef.current = captionPath;
          setFeedCaptionPath(captionPath);
          setFeedCaptionText(item.previewText || item.title || "");
        } else {
          loadedTextPathRef.current = captionPath;
          setSelectedJournalText("");
          setJournalDraftText("");
        }
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
      const mediaUrl = resolveGatewayResourceUrl(item.mediaUrl, gatewayBaseUrl);
      const res = await fetch(mediaUrl, {
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
            : await readLibraryText(item.path, token, gatewayBaseUrl);
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
        const { archivedPath, archiveError } = await archivePostedFeedSource(item.path, token);
        setPostedPaths((prev) => ({ ...prev, [item.path]: true }));
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
        const { archivedPath, archiveError } = await archivePostedFeedSource(item.path, token);
        setPostedPaths((prev) => ({ ...prev, [item.path]: true }));
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
    const token = chatGatewayToken.trim() || undefined;
    setJournalSaveStatus(`Saving ${selectedJournalItem.path}...`);
    try {
      await saveLibraryText(selectedJournalItem.path, selectedJournalText, token, gatewayBaseUrl);
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
    if (!gatewayBaseUrl.trim()) {
      return;
    }
    try {
      let token = chatGatewayToken.trim();
      if (!token && isDesktopClient) {
        token = (await syncDesktopGatewayBootstrap())?.trim() || "";
      }
      let threadId = chatThreadId.trim();
      if (!threadId && token) {
        const latest = await getLatestChatThreadViaGateway(token, gatewayBaseUrl).catch(() => null);
        if (latest) {
          threadId = latest;
          setChatThreadId(latest);
          chatThreadHydratedRef.current = true;
        }
      }
      if (!threadId) {
        setChatMessages([]);
        setChatStatus("No chat thread yet. Send a message to start.");
        return;
      }

      const items = await listClawChatMessagesViaGateway(threadId, token, gatewayBaseUrl);
      if (items.length === 0 && token && !chatThreadHydratedRef.current) {
        const latest = await getLatestChatThreadViaGateway(token, gatewayBaseUrl).catch(() => null);
        chatThreadHydratedRef.current = true;
        if (latest && latest !== threadId) {
          setChatThreadId(latest);
          setChatStatus(`Loaded latest chat thread: ${latest}`);
          return;
        }
      }

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
      const { agent: nextAgent, session: nextSession } = await loginBluesky(creds);
      setAgent(nextAgent);
      setSession(nextSession);
      await saveBlueskySessionSecure(nextSession);
      try {
        const pbSync = await ensurePocketBaseUserFromBluesky(
          pb,
          creds.handle,
          creds.appPassword,
          nextSession.handle
        );
        const label = pocketBaseAuthLabel(pb);
        setPbAuthLabel(label);
        setPbAuthMessage(
          pbSync.created
            ? `PocketBase user provisioned and signed in (${label || pbSync.identity})`
            : `PocketBase signed in as ${label || pbSync.identity}`
        );
      } catch (error) {
        setPbAuthMessage(
          `PocketBase auto-login failed (${error instanceof Error ? error.message : String(error)})`
        );
      }
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
        setChatStatus(
          isDesktopClient
            ? "Chat blocked (desktop gateway token not ready). Wait 2-3s or restart app."
            : "Chat blocked (gateway token missing). Pair mobile with desktop QR."
        );
        return;
      }
      let threadId = chatThreadId.trim();
      if (!threadId) {
        threadId = createThreadId();
        setChatThreadId(threadId);
      }
      await createClawChatUserMessageViaGateway(threadId, content, token, gatewayBaseUrl);
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

  async function saveOptionalProviderApiKey() {
    if (!isDesktopClient) {
      setProviderApiKeyStatus("API key storage is desktop-only.");
      return;
    }
    const trimmed = providerApiKey.trim();
    setProviderApiKeyStatus(trimmed ? "Saving API key..." : "Clearing API key...");
    try {
      if (trimmed) {
        await invokeDesktopCommandStrict("set_secret", {
          req: {
            service: DESKTOP_SECRET_SERVICE,
            account: PROVIDER_API_KEY_SECRET_ACCOUNT,
            value: trimmed
          }
        });
      } else {
        await invokeDesktopCommandStrict("delete_secret", {
          req: {
            service: DESKTOP_SECRET_SERVICE,
            account: PROVIDER_API_KEY_SECRET_ACCOUNT
          }
        });
      }
      await restartGatewayDaemonFromDesktop();
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
  }

  useEffect(() => {
    if (isDesktopClient) {
      return;
    }
    const needsQrLogin = !(chatGatewayToken.trim() && gatewayBaseUrl.trim());
    if (!needsQrLogin || !mobileScannerActive) {
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
                  applyGatewayConnection(parsed.gatewayUrl, parsed.token);
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
  }, [isDesktopClient, mobileScannerActive, chatGatewayToken, gatewayBaseUrl]);

  useEffect(() => {
    if (!isDesktopClient) {
      return;
    }
    void loadOpenAiDeviceCodeStatus();
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
    void refreshClawChat();
    const timer = window.setInterval(() => {
      void refreshClawChat();
    }, 1500);
    return () => {
      window.clearInterval(timer);
    };
  }, [chatThreadId, chatGatewayToken, gatewayBaseUrl]);

  useEffect(() => {
    void refreshLibrary("all");
  }, [chatGatewayToken, gatewayBaseUrl]);

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
  }, [mobileTab, selectedFeedItem, selectedJournalItem, chatGatewayToken, gatewayBaseUrl]);

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
    if (!journalDraftText.trim()) return;
    if (selectedJournalItem && selectedJournalItem.kind === "text" && loadedTextPathRef.current !== selectedJournalItem.path) return;
    if (selectedJournalItem && journalDraftText === selectedJournalText) return;

    if (journalAutosaveTimerRef.current) window.clearTimeout(journalAutosaveTimerRef.current);
    journalAutosaveTimerRef.current = window.setTimeout(() => {
      void saveJournalTextDraft();
    }, 700);
    return () => {
      if (journalAutosaveTimerRef.current) window.clearTimeout(journalAutosaveTimerRef.current);
    };
  }, [journalDraftText, selectedJournalItem, selectedJournalText, chatGatewayToken, gatewayBaseUrl]);

  const journalList = journalItems;
  const feedList = feedItems;
  const postedHistory = history.filter((item) => item.status === "success");
  const needsMobileQrLogin = !isDesktopClient && !(chatGatewayToken.trim() && gatewayBaseUrl.trim());
  const needsBlueskyLogin = !session;
  const showDesktopJournalLayout = isDesktopLayout && mobileTab === "journal";

  const renderJournalSidebarContent = (closeOnSelect: boolean) => (
    <>
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
              <div
                className="stack"
                style={{ gap: '4px', flex: 1, cursor: 'pointer' }}
                onClick={() => {
                  void openLibraryItem(item, "journal");
                  if (closeOnSelect) {
                    setJournalSidebarOpen(false);
                  }
                }}
              >
                <div className="feed-title">{item.title}</div>
                <div className="feed-time">{formatTimestamp(item.modifiedAt)} · {item.kind.toUpperCase()}</div>
              </div>
            </div>
          ))}
        </div>
      )}
    </>
  );

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

  if (needsBlueskyLogin) {
    return (
      <div className="app-shell">
        <main className="page-content">
          <div className="stack">
            <div className="card">
              <h2>Sign In To Continue</h2>
              <p className="text-sm muted">
                Bluesky is the primary account login for this app.
              </p>
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
                <button type="submit" className="primary">
                  Sign In
                </button>
                {authMessage ? <p className="text-sm muted">{authMessage}</p> : null}
                {pbAuthMessage ? <p className="text-sm muted">{pbAuthMessage}</p> : null}
              </form>
            </div>
          </div>
        </main>
      </div>
    );
  }

  return (
    <div className="app-shell">
      {(!isWritingNote && !isRecording) && (
        <header className="topbar">
          <div className="row" style={{ alignItems: "center", gap: "1rem" }}>
            {mobileTab === "journal" && !showDesktopJournalLayout && (
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
      )}

      {mobileTab === "journal" && !showDesktopJournalLayout && !isWritingNote && !isRecording ? (
        <div className={`sidebar-overlay ${journalSidebarOpen ? 'open' : ''}`} onClick={() => setJournalSidebarOpen(false)}>
          <div className={`sidebar ${journalSidebarOpen ? 'open' : ''}`} onClick={e => e.stopPropagation()}>
            {renderJournalSidebarContent(true)}
          </div>
        </div>
      ) : null}

      <main className="page-content">
        {mobileTab === "journal" ? (
          <div className={showDesktopJournalLayout ? "journal-desktop-layout" : "stack"}>
            {showDesktopJournalLayout && !isWritingNote && !isRecording ? (
              <aside className="sidebar sidebar-desktop open">
                {renderJournalSidebarContent(false)}
              </aside>
            ) : null}
            <div className="stack journal-main">
              {!isWritingNote && (
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
                </div>
              )}

              {!isRecording && (
                <div className="card" style={{ flex: isWritingNote ? 1 : undefined, minHeight: isWritingNote ? '60vh' : undefined }}>
                  <div className="row-between">
                    <div className="row" style={{ gap: '0.5rem', alignItems: 'center' }}>
                      <button
                        type="button"
                        className="ghost"
                        onClick={() => { setJournalDraftText(""); setSelectedJournalItem(null); setMediaPreviewUrl(""); setJournalSaveStatus("Journal idle"); }}
                        title="New Note"
                        style={{ padding: '0.2rem 0.5rem', fontSize: '1.2rem' }}
                      >
                        +
                      </button>
                      <h2 style={{ margin: 0 }}>Note</h2>
                    </div>
                    <div className="row" style={{ gap: '0.5rem', alignItems: 'center' }}>
                      <span className="text-sm muted">{journalSaveStatus !== "Journal idle" ? journalSaveStatus : ""}</span>
                      {isWritingNote && <button type="button" className="ghost" onClick={() => setIsWritingNote(false)}>Done</button>}
                    </div>
                  </div>
                  {selectedJournalItem && mediaPreviewUrl && (selectedJournalItem.kind === "audio" || selectedJournalItem.kind === "video") && (
                    <div className="stack" style={{ marginBottom: '1rem' }}>
                      {selectedJournalItem.kind === "audio" && <audio controls src={mediaPreviewUrl} style={{ width: '100%' }} />}
                      {selectedJournalItem.kind === "video" && <video controls src={mediaPreviewUrl} className="media-viewer" style={{ marginTop: 0 }} />}
                    </div>
                  )}
                  <textarea
                    rows={isWritingNote ? 15 : 5}
                    value={journalDraftText}
                    onChange={(e) => setJournalDraftText(e.target.value)}
                    onFocus={() => setIsWritingNote(true)}
                    placeholder="Write your thoughts..."
                    style={{ flex: isWritingNote ? 1 : undefined, resize: 'none' }}
                  />
                </div>
              )}

            </div>
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
                          {post.embed && post.embed.$type === "app.bsky.embed.images#view" && (
                            <div className="feed-embed-images mt-2" style={{ display: 'grid', gridTemplateColumns: 'repeat(auto-fit, minmax(150px, 1fr))', gap: '0.5rem' }}>
                              {(post.embed as any).images?.map((img: any, i: number) => (
                                <img key={i} src={img.thumb || img.fullsize} alt={img.alt || "Embedded image"} style={{ width: '100%', height: '100%', maxHeight: '300px', objectFit: 'cover', borderRadius: '12px' }} />
                              ))}
                            </div>
                          )}
                          <div className="feed-stats row text-sm muted mt-2" style={{ gap: '1rem', marginTop: '0.8rem' }}>
                            <span style={{ display: 'flex', alignItems: 'center', gap: '0.3rem' }}>
                              <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round"><path d="M21 11.5a8.38 8.38 0 0 1-.9 3.8 8.5 8.5 0 0 1-7.6 4.7 8.38 8.38 0 0 1-3.8-.9L3 21l1.9-5.7a8.38 8.38 0 0 1-.9-3.8 8.5 8.5 0 0 1 4.7-7.6 8.38 8.38 0 0 1 3.8-.9h.5a8.48 8.48 0 0 1 8 8v.5z"></path></svg>
                              {post.replyCount || 0}
                            </span>
                            <span style={{ display: 'flex', alignItems: 'center', gap: '0.3rem' }}>
                              <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round"><path d="M17 1l4 4-4 4"></path><path d="M3 11V9a4 4 0 0 1 4-4h14"></path><path d="M7 23l-4-4 4-4"></path><path d="M21 13v2a4 4 0 0 1-4 4H3"></path></svg>
                              {post.repostCount || 0}
                            </span>
                            <span style={{ display: 'flex', alignItems: 'center', gap: '0.3rem' }}>
                              <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round"><path d="M20.84 4.61a5.5 5.5 0 0 0-7.78 0L12 5.67l-1.06-1.06a5.5 5.5 0 0 0-7.78 7.78l1.06 1.06L12 21.23l7.78-7.78 1.06-1.06a5.5 5.5 0 0 0 0-7.78z"></path></svg>
                              {post.likeCount || 0}
                            </span>
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
              <h2>Bluesky Login (Desktop)</h2>
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

            <div className="card">
              <h2>Gateway & App Settings</h2>
              <div className="stack">
                <p className="text-sm muted">
                  Chat and journal upload use desktop gateway auth automatically.
                </p>

                <p className="text-sm muted">
                  {chatGatewayToken
                    ? "Gateway auth is ready for chat + journal uploads."
                    : "Waiting for desktop gateway auth bootstrap."}
                </p>

                {isDesktopClient && (
                  <div className="stack" style={{ gap: "0.8rem" }}>
                    <div className="row-between">
                      <p><strong>Pair Mobile With QR</strong></p>
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
                        <QRCodeCanvas value={desktopQrPayload.qr_value} size={220} includeMargin />
                        <p className="text-sm muted text-center">
                          Mobile gateway: {desktopQrPayload.gateway_url}
                        </p>
                      </div>
                    )}
                    {desktopQrStatus ? <p className="text-sm muted">{desktopQrStatus}</p> : null}
                  </div>
                )}
                <p className="text-sm muted">
                  {pbAuthMessage}
                </p>
                {pb.authStore.isValid && pbAuthLabel ? (
                  <div className="badge success text-center" style={{ alignSelf: "flex-start" }}>
                    PocketBase: {pbAuthLabel}
                  </div>
                ) : null}
              </div>
            </div>

            <div className="card">
              <div className="row-between">
                <h2>AI Setup</h2>
                <button
                  type="button"
                  onClick={() => void startOpenAiDeviceCodeLogin()}
                  disabled={aiSetupBusy || !!aiSetupStatus?.running || !isDesktopClient}
                >
                  {aiSetupBusy
                    ? "Starting..."
                    : aiSetupStatus?.running
                      ? "In Progress..."
                      : "Start OpenAI Device Login"}
                </button>
              </div>
              {!isDesktopClient ? (
                <p className="text-sm muted">AI setup runs on desktop only. Use the desktop app for this step.</p>
              ) : (
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
                  {aiSetupStatus?.verificationUrl ? (
                    <p className="text-sm">
                      URL:{" "}
                      <a href={aiSetupStatus.verificationUrl} target="_blank" rel="noreferrer">
                        {aiSetupStatus.verificationUrl}
                      </a>
                    </p>
                  ) : null}
                  {aiSetupStatus?.fastLink ? (
                    <p className="text-sm">
                      Fast Link:{" "}
                      <a href={aiSetupStatus.fastLink} target="_blank" rel="noreferrer">
                        {aiSetupStatus.fastLink}
                      </a>
                    </p>
                  ) : null}
                  {aiSetupStatus?.userCode ? (
                    <div className="row" style={{ alignItems: "center" }}>
                      <input value={aiSetupStatus.userCode} readOnly style={{ flex: 1 }} />
                      <button
                        type="button"
                        className="ghost"
                        onClick={() => void navigator.clipboard.writeText(aiSetupStatus.userCode || "")}
                      >
                        Copy Code
                      </button>
                    </div>
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
              )}
            </div>
          </div>
        ) : null}
      </main>

      {(!isWritingNote && !isRecording) && (
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
      )}
    </div>
  );
}

export default App;
