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
 *   - "disliked" → locally disliked Reads items (drives 👎 UI state)
 *   - "liked.keywords" / "disliked.keywords" → on-device-AI-extracted phrases
 *     from 👍/👎'd Reads cards, fed into the Reads ranker as positive/negative
 *     steering topics.
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

/* ── Reposted (optimistic local repost) ──────────────────────────────────── */

const REPOSTED_KEY = "slowclaw.reposted.v1";

export function getRepostedIds(): string[] {
  return readJSON<string[]>(REPOSTED_KEY, []);
}

export function isReposted(id: string): boolean {
  return getRepostedIds().includes(id);
}

export function setReposted(id: string, reposted: boolean): void {
  const ids = getRepostedIds();
  const next = reposted ? (ids.includes(id) ? ids : [...ids, id]) : ids.filter((x) => x !== id);
  writeJSON(REPOSTED_KEY, next);
}

export function toggleReposted(id: string): boolean {
  const nowReposted = !isReposted(id);
  setReposted(id, nowReposted);
  return nowReposted;
}

/* ── Disliked (optimistic local dislike → ranking steering) ──────────────── */

const DISLIKED_KEY = "slowclaw.disliked.v1";

export function getDislikedIds(): string[] {
  return readJSON<string[]>(DISLIKED_KEY, []);
}

export function isDisliked(id: string): boolean {
  return getDislikedIds().includes(id);
}

export function setDisliked(id: string, disliked: boolean): void {
  const ids = getDislikedIds();
  const next = disliked
    ? (ids.includes(id) ? ids : [...ids, id])
    : ids.filter((x) => x !== id);
  writeJSON(DISLIKED_KEY, next);
}

export function toggleDisliked(id: string): boolean {
  const nowDisliked = !isDisliked(id);
  setDisliked(id, nowDisliked);
  return nowDisliked;
}

/* ── Steering keyword stores ─────────────────────────────────────────────── */
//
// Keywords extracted (on-device, via nativeAiChat) from 👍'd / 👎'd Reads
// cards. Liked keywords feed the positive ranking lane (surface more like
// this); disliked keywords feed the negative lane (down-rank, don't hide).
// Both are localStorage-only, lowercase phrases. All writes reuse writeJSON
// so onSavedChange listeners (incl. the ranking memos) recompute same-tab.

const LIKED_KEYWORDS_KEY = "slowclaw.liked.keywords.v1";
const DISLIKED_KEYWORDS_KEY = "slowclaw.disliked.keywords.v1";

function readKeywordSet(key: string): string[] {
  const arr = readJSON<string[]>(key, []);
  // Defensive dedupe + lowercase so the stores stay clean regardless of input.
  return Array.from(new Set(arr.map((k) => (k || "").trim().toLowerCase()).filter(Boolean)));
}

export function getLikedKeywords(): string[] {
  return readKeywordSet(LIKED_KEYWORDS_KEY);
}

export function addLikedKeywords(keywords: string[]): void {
  if (!keywords.length) return;
  const next = readKeywordSet(LIKED_KEYWORDS_KEY);
  for (const k of keywords) {
    const clean = k.trim().toLowerCase();
    if (clean && !next.includes(clean)) next.push(clean);
  }
  // Cap so the steering list can't grow unbounded over time.
  writeJSON(LIKED_KEYWORDS_KEY, next.slice(-120));
}

export function removeLikedKeyword(keyword: string): void {
  const clean = keyword.trim().toLowerCase();
  writeJSON(LIKED_KEYWORDS_KEY, readKeywordSet(LIKED_KEYWORDS_KEY).filter((k) => k !== clean));
}

export function getDislikedKeywords(): string[] {
  return readKeywordSet(DISLIKED_KEYWORDS_KEY);
}

export function addDislikedKeywords(keywords: string[]): void {
  if (!keywords.length) return;
  const next = readKeywordSet(DISLIKED_KEYWORDS_KEY);
  for (const k of keywords) {
    const clean = k.trim().toLowerCase();
    if (clean && !next.includes(clean)) next.push(clean);
  }
  writeJSON(DISLIKED_KEYWORDS_KEY, next.slice(-120));
}

export function removeDislikedKeyword(keyword: string): void {
  const clean = keyword.trim().toLowerCase();
  writeJSON(DISLIKED_KEYWORDS_KEY, readKeywordSet(DISLIKED_KEYWORDS_KEY).filter((k) => k !== clean));
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
