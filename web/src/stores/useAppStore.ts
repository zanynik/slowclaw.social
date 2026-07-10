/**
 * useAppStore.ts — Lightweight reactive store for SlowClaw app-level state.
 *
 * Inspired by Atomic Chat's Zustand store pattern:
 *   - Central state with selectors so components only re-render on their slice
 *   - Actions co-located with state
 *   - No external dependency required (React 18 useSyncExternalStore)
 *
 * This replaces the 100+ useState calls in App.tsx with a structured,
 * debuggable, and testable state layer.
 */

import { useSyncExternalStore, useCallback } from "react";

// ── Types ──────────────────────────────────────────────────────────────────────

export type MobileTab = "reads" | "journal" | "drafts" | "profile";
export type ThemeMode = "light" | "dark";
export type FeedSource = "local" | "bluesky";
export type MeFeedTab = "drafts" | "published";
export type WorldFeedTab = "tweets" | "articles" | "videos";

export type AppState = {
  // Navigation
  mobileTab: MobileTab;
  themeMode: ThemeMode;

  // Feed
  feedSource: FeedSource;
  meFeedTab: MeFeedTab;
  worldFeedTab: WorldFeedTab;
  feedSidebarOpen: boolean;
  feedCreateWorkflowOpen: boolean;

  // Journal
  journalSidebarOpen: boolean;
  journalDesktopSidebarCollapsed: boolean;
  selectedJournalPath: string;
  selectedFeedPath: string;
  isWritingNote: boolean;
  journalSearchQuery: string;

  // Recording
  isRecording: boolean;
  captureMode: "audio" | "video" | null;
  recordingType: "audio" | "video" | null;
  recordingTime: number;
  videoOrientation: "vertical" | "horizontal";

  // Gateway
  gatewayBaseUrl: string;
  chatGatewayToken: string;

  // Sync
  syncPeerGatewayUrl: string;
  syncPeerToken: string;
  syncScannerActive: boolean;
  mobileScannerActive: boolean;

  // UI Feedback
  toasts: Toast[];
};

export type Toast = {
  id: string;
  message: string;
  type: "info" | "success" | "error";
  dismissAfterMs: number;
  createdAt: number;
};

type AppActions = {
  setMobileTab: (tab: MobileTab) => void;
  setThemeMode: (mode: ThemeMode) => void;
  toggleTheme: () => void;
  setFeedSource: (source: FeedSource) => void;
  setMeFeedTab: (tab: MeFeedTab) => void;
  setWorldFeedTab: (tab: WorldFeedTab) => void;
  setFeedSidebarOpen: (open: boolean) => void;
  setFeedCreateWorkflowOpen: (open: boolean) => void;
  setJournalSidebarOpen: (open: boolean) => void;
  setJournalDesktopSidebarCollapsed: (collapsed: boolean) => void;
  setSelectedJournalPath: (path: string) => void;
  setSelectedFeedPath: (path: string) => void;
  setIsWritingNote: (writing: boolean) => void;
  setJournalSearchQuery: (query: string) => void;
  setIsRecording: (recording: boolean) => void;
  setCaptureMode: (mode: "audio" | "video" | null) => void;
  setRecordingType: (type: "audio" | "video" | null) => void;
  setRecordingTime: (time: number) => void;
  setVideoOrientation: (orientation: "vertical" | "horizontal") => void;
  setGatewayBaseUrl: (url: string) => void;
  setChatGatewayToken: (token: string) => void;
  setSyncPeerGatewayUrl: (url: string) => void;
  setSyncPeerToken: (token: string) => void;
  setSyncScannerActive: (active: boolean) => void;
  setMobileScannerActive: (active: boolean) => void;
  addToast: (message: string, type?: Toast["type"], dismissAfterMs?: number) => void;
  dismissToast: (id: string) => void;
  reset: () => void;
};

// ── Storage Keys ───────────────────────────────────────────────────────────────

const UI_THEME_STORAGE_KEY = "slowclaw.ui.theme";
const UI_TAB_STORAGE_KEY = "slowclaw.ui.tab";
const CHAT_GATEWAY_BASE_URL_STORAGE_KEY = "slowclaw.chat.gateway_base_url";
const CHAT_GATEWAY_TOKEN_STORAGE_KEY = "slowclaw.chat.gateway_token";
const SYNC_PEER_GATEWAY_BASE_URL_STORAGE_KEY = "slowclaw.sync.peer.gateway_base_url";
const SYNC_PEER_GATEWAY_TOKEN_STORAGE_KEY = "slowclaw.sync.peer.gateway_token";
const NATIVE_GATEWAY_BASE_URL = "http://127.0.0.1:42617";

// ── Initial State Derivation ───────────────────────────────────────────────────

function isMobileUserAgent() {
  if (typeof window === "undefined") return false;
  return /iphone|ipad|ipod|android/i.test(window.navigator.userAgent || "");
}

function isTauriDesktopRuntime() {
  if (typeof window === "undefined") return false;
  return Boolean((window as any).__TAURI_INTERNALS__) && !isMobileUserAgent();
}

function isTauriMobileRuntime() {
  if (typeof window === "undefined") return false;
  return (
    Boolean((window as any).__TAURI_MOBILE__) ||
    (Boolean((window as any).__TAURI_INTERNALS__) && isMobileUserAgent())
  );
}

function isLoopbackUrl(value: string) {
  try {
    const parsed = new URL(value);
    return ["127.0.0.1", "localhost", "::1", "[::1]"].includes(parsed.hostname);
  } catch {
    return false;
  }
}

function deriveInitialTheme(): ThemeMode {
  if (typeof window === "undefined") return "light";
  const saved = window.localStorage.getItem(UI_THEME_STORAGE_KEY);
  if (saved === "light" || saved === "dark") return saved;
  return window.matchMedia?.("(prefers-color-scheme: dark)").matches ? "dark" : "light";
}

function deriveInitialTab(): MobileTab {
  if (typeof window === "undefined") return "journal";
  if (window.innerWidth > 900) return "journal";
  const saved = window.localStorage.getItem(UI_TAB_STORAGE_KEY);
  // Legacy tabs (feed/productivity/todos/events/queue) collapsed into reads/drafts.
  if (saved === "todos" || saved === "events" || saved === "productivity" || saved === "queue" || saved === "feed") return "reads";
  return saved === "reads" || saved === "journal" || saved === "drafts" || saved === "profile" ? saved as MobileTab : "journal";
}

function deriveInitialGatewayUrl(): string {
  if (typeof window === "undefined") return NATIVE_GATEWAY_BASE_URL;
  const saved = window.localStorage.getItem(CHAT_GATEWAY_BASE_URL_STORAGE_KEY);
  if (saved?.trim()) {
    const normalized = saved.trim().replace(/\/+$/, "");
    if (!isTauriMobileRuntime() || isLoopbackUrl(normalized)) return normalized;
  }
  if (isTauriDesktopRuntime() || isTauriMobileRuntime()) return NATIVE_GATEWAY_BASE_URL;
  const protocol = window.location.protocol === "https:" ? "https:" : "http:";
  const host = window.location.hostname || "127.0.0.1";
  return `${protocol}//${host}:42617`;
}

function createInitialState(): AppState {
  return {
    mobileTab: deriveInitialTab(),
    themeMode: deriveInitialTheme(),
    feedSource: "local",
    meFeedTab: "drafts",
    worldFeedTab: "tweets",
    feedSidebarOpen: false,
    feedCreateWorkflowOpen: false,
    journalSidebarOpen: false,
    journalDesktopSidebarCollapsed: false,
    selectedJournalPath: "",
    selectedFeedPath: "",
    isWritingNote: false,
    journalSearchQuery: "",
    isRecording: false,
    captureMode: null,
    recordingType: null,
    recordingTime: 0,
    videoOrientation: "vertical",
    gatewayBaseUrl: deriveInitialGatewayUrl(),
    chatGatewayToken: typeof window !== "undefined"
      ? window.localStorage.getItem(CHAT_GATEWAY_TOKEN_STORAGE_KEY) || ""
      : "",
    syncPeerGatewayUrl: typeof window !== "undefined"
      ? window.localStorage.getItem(SYNC_PEER_GATEWAY_BASE_URL_STORAGE_KEY) || ""
      : "",
    syncPeerToken: typeof window !== "undefined"
      ? window.localStorage.getItem(SYNC_PEER_GATEWAY_TOKEN_STORAGE_KEY) || ""
      : "",
    syncScannerActive: false,
    mobileScannerActive: (() => {
      if (typeof window === "undefined") return false;
      if (isTauriDesktopRuntime()) return false;
      const savedToken = window.localStorage.getItem(CHAT_GATEWAY_TOKEN_STORAGE_KEY) || "";
      const savedGateway = window.localStorage.getItem(CHAT_GATEWAY_BASE_URL_STORAGE_KEY) || "";
      return !(savedToken.trim() && savedGateway.trim());
    })(),
    toasts: [],
  };
}

// ── Store Implementation ───────────────────────────────────────────────────────

type Listener = () => void;

let state: AppState = createInitialState();
const listeners = new Set<Listener>();

function getState(): AppState {
  return state;
}

function setState(partial: Partial<AppState>) {
  state = { ...state, ...partial };
  listeners.forEach((listener) => listener());
}

function subscribe(listener: Listener): () => void {
  listeners.add(listener);
  return () => listeners.delete(listener);
}

let toastCounter = 0;

export const appActions: AppActions = {
  setMobileTab(tab) {
    setState({ mobileTab: tab });
    if (typeof window !== "undefined") {
      window.localStorage.setItem(UI_TAB_STORAGE_KEY, tab);
    }
  },
  setThemeMode(mode) {
    setState({ themeMode: mode });
    if (typeof window !== "undefined") {
      window.localStorage.setItem(UI_THEME_STORAGE_KEY, mode);
      document.documentElement.setAttribute("data-theme", mode);
    }
  },
  toggleTheme() {
    appActions.setThemeMode(state.themeMode === "dark" ? "light" : "dark");
  },
  setFeedSource(source) { setState({ feedSource: source }); },
  setMeFeedTab(tab) { setState({ meFeedTab: tab }); },
  setWorldFeedTab(tab) { setState({ worldFeedTab: tab }); },
  setFeedSidebarOpen(open) { setState({ feedSidebarOpen: open }); },
  setFeedCreateWorkflowOpen(open) { setState({ feedCreateWorkflowOpen: open }); },
  setJournalSidebarOpen(open) { setState({ journalSidebarOpen: open }); },
  setJournalDesktopSidebarCollapsed(collapsed) { setState({ journalDesktopSidebarCollapsed: collapsed }); },
  setSelectedJournalPath(path) { setState({ selectedJournalPath: path }); },
  setSelectedFeedPath(path) { setState({ selectedFeedPath: path }); },
  setIsWritingNote(writing) { setState({ isWritingNote: writing }); },
  setJournalSearchQuery(query) { setState({ journalSearchQuery: query }); },
  setIsRecording(recording) { setState({ isRecording: recording }); },
  setCaptureMode(mode) { setState({ captureMode: mode }); },
  setRecordingType(type) { setState({ recordingType: type }); },
  setRecordingTime(time) { setState({ recordingTime: time }); },
  setVideoOrientation(orientation) { setState({ videoOrientation: orientation }); },
  setGatewayBaseUrl(url) { setState({ gatewayBaseUrl: url }); },
  setChatGatewayToken(token) {
    setState({ chatGatewayToken: token });
    if (typeof window !== "undefined") {
      window.localStorage.setItem(CHAT_GATEWAY_TOKEN_STORAGE_KEY, token.trim());
    }
  },
  setSyncPeerGatewayUrl(url) {
    setState({ syncPeerGatewayUrl: url });
    if (typeof window !== "undefined") {
      window.localStorage.setItem(SYNC_PEER_GATEWAY_BASE_URL_STORAGE_KEY, url.trim().replace(/\/+$/, ""));
    }
  },
  setSyncPeerToken(token) {
    setState({ syncPeerToken: token });
    if (typeof window !== "undefined") {
      window.localStorage.setItem(SYNC_PEER_GATEWAY_TOKEN_STORAGE_KEY, token);
    }
  },
  setSyncScannerActive(active) { setState({ syncScannerActive: active }); },
  setMobileScannerActive(active) { setState({ mobileScannerActive: active }); },
  addToast(message, type = "info", dismissAfterMs = 3500) {
    const id = `toast-${++toastCounter}-${Date.now()}`;
    const toast: Toast = { id, message, type, dismissAfterMs, createdAt: Date.now() };
    setState({ toasts: [...state.toasts, toast] });
    if (dismissAfterMs > 0) {
      setTimeout(() => appActions.dismissToast(id), dismissAfterMs);
    }
  },
  dismissToast(id) {
    setState({ toasts: state.toasts.filter((t) => t.id !== id) });
  },
  reset() {
    state = createInitialState();
    listeners.forEach((l) => l());
  },
};

// ── React Hook ─────────────────────────────────────────────────────────────────

export function useAppStore(): AppState;
export function useAppStore<T>(selector: (s: AppState) => T): T;
export function useAppStore(selector?: (s: AppState) => unknown): unknown {
  return useSyncExternalStore(
    subscribe,
    selector ? () => selector(getState()) : getState,
    selector ? () => selector(getState()) : getState,
  );
}

/**
 * Select a single field from the store. Re-renders only when that field changes.
 */
export function useAppField<K extends keyof AppState>(key: K): AppState[K] {
  return useAppStore(useCallback((s: AppState) => s[key], [key]));
}
