/**
 * savedItems.ts — localStorage-backed saved-items + liked-items store.
 *
 * Provides the "bookmark" and "optimistic like" interactions the Feed and
 * Reels tabs need to feel alive without auth-coupling to a remote service.
 * Pure localStorage: no network, no secrets, no PII. SSR-safe (guards window).
 *
 * Two independent namespaces:
 *   - "saved"  → bookmarked items (Profile tab → Saved list)
 *   - "liked"  → locally liked items (drives filled-heart UI)
 *
 * Each entry is keyed by a stable URI/id (Bluesky post uri, Nostr note id,
 * Reels post uri, Reads link). The stored record is intentionally minimal so
 * the Profile "Saved" list can render a preview without re-fetching.
 */

export interface SavedItem {
  /** Stable id (post uri / note id / article link). */
  id: string;
  /** Where it was saved from, for the icon badge. */
  source: "nostr" | "bluesky" | "reels" | "reads";
  /** Epoch ms when saved, for "recently saved" ordering. */
  savedAt: number;
  /** Best-effort preview fields (all optional). */
  title?: string;
  body?: string;
  authorName?: string;
  authorHandle?: string;
  url?: string;
  thumbnail?: string;
}

const SAVED_KEY = "slowclaw.saved.v1";
const LIKED_KEY = "slowclaw.liked.v1";

function readJSON<T>(key: string, fallback: T): T {
  if (typeof window === "undefined") return fallback;
  try {
    const raw = window.localStorage.getItem(key);
    if (!raw) return fallback;
    const parsed = JSON.parse(raw);
    return Array.isArray(parsed) ? (parsed as T) : fallback;
  } catch {
    return fallback;
  }
}

function writeJSON(key: string, value: unknown): void {
  if (typeof window === "undefined") return;
  try {
    window.localStorage.setItem(key, JSON.stringify(value));
    // Notify same-tab listeners (storage event only fires cross-tab).
    window.dispatchEvent(new CustomEvent("slowclaw:saved-change", { detail: { key } }));
  } catch {
    /* quota or serialization error — non-fatal, local-only feature */
  }
}

/* ── Saved (bookmark) ───────────────────────────────────────────────────── */

export function getSavedItems(): SavedItem[] {
  const items = readJSON<SavedItem[]>(SAVED_KEY, []);
  // Newest-first for the Saved list.
  return [...items].sort((a, b) => b.savedAt - a.savedAt);
}

export function isSaved(id: string): boolean {
  return readJSON<SavedItem[]>(SAVED_KEY, []).some((i) => i.id === id);
}

export function saveItem(item: SavedItem): void {
  const items = readJSON<SavedItem[]>(SAVED_KEY, []);
  if (items.some((i) => i.id === item.id)) return;
  writeJSON(SAVED_KEY, [...items, { ...item, savedAt: Date.now() }]);
}

export function unsaveItem(id: string): void {
  const items = readJSON<SavedItem[]>(SAVED_KEY, []);
  writeJSON(SAVED_KEY, items.filter((i) => i.id !== id));
}

export function toggleSaved(item: SavedItem): boolean {
  if (isSaved(item.id)) {
    unsaveItem(item.id);
    return false;
  }
  saveItem(item);
  return true;
}

/* ── Liked (optimistic local like) ──────────────────────────────────────── */

export function getLikedIds(): string[] {
  return readJSON<string[]>(LIKED_KEY, []);
}

export function isLiked(id: string): boolean {
  return getLikedIds().includes(id);
}

export function setLiked(id: string, liked: boolean): void {
  const ids = getLikedIds();
  const next = liked ? (ids.includes(id) ? ids : [...ids, id]) : ids.filter((x) => x !== id);
  writeJSON(LIKED_KEY, next);
}

export function toggleLiked(id: string): boolean {
  const nowLiked = !isLiked(id);
  setLiked(id, nowLiked);
  return nowLiked;
}

/* ── React subscription helper ──────────────────────────────────────────── */

/**
 * Subscribe to saved/liked changes (same-tab). Returns an unsubscribe fn.
 * Cross-tab changes already fire via the native `storage` event; callers that
 * need those can listen separately — most UIs only care about same-tab.
 */
export function onSavedChange(cb: () => void): () => void {
  if (typeof window === "undefined") return () => {};
  const handler = () => cb();
  window.addEventListener("slowclaw:saved-change", handler);
  window.addEventListener("storage", handler);
  return () => {
    window.removeEventListener("slowclaw:saved-change", handler);
    window.removeEventListener("storage", handler);
  };
}
