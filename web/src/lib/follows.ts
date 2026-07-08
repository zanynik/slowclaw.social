/**
 * follows.ts — localStorage-backed optimistic follow store.
 *
 * "Follow" is the signature social action, but it's a protocol *write* (Nostr
 * kind-3 contact list / Bluesky graph.follow) that needs identity. To keep the
 * button feeling instant and to work even before keys/session are connected,
 * the local state lives here and is mirrored to the protocol in the background.
 *
 * Keyed by a stable author id: `"nostr:<pubkey>"` / `"bluesky:<did-or-handle>"`.
 * Mirrors the savedItems.ts event pattern so React can subscribe.
 */

const FOLLOWS_KEY = "slowclaw.follows.v1";
const EVENT_NAME = "slowclaw:follows-change";

function readIds(): string[] {
  if (typeof window === "undefined") return [];
  try {
    const raw = window.localStorage.getItem(FOLLOWS_KEY);
    if (!raw) return [];
    const parsed = JSON.parse(raw);
    return Array.isArray(parsed) ? parsed.filter((x) => typeof x === "string") : [];
  } catch {
    return [];
  }
}

function writeIds(ids: string[]): void {
  if (typeof window === "undefined") return;
  try {
    window.localStorage.setItem(FOLLOWS_KEY, JSON.stringify(ids));
    window.dispatchEvent(new CustomEvent(EVENT_NAME, { detail: { key: FOLLOWS_KEY } }));
  } catch {
    /* quota error — non-fatal, local-only feature */
  }

}

/** Helpers to build the stable per-protocol author key. */
export function nostrFollowKey(pubkey: string): string {
  return `nostr:${pubkey}`;
}
export function blueskyFollowKey(actor: string): string {
  return `bluesky:${actor}`;
}

/** All followed author keys. */
export function getFollowedIds(): string[] {
  return readIds();
}

export function isFollowing(id: string): boolean {
  return readIds().includes(id);
}

/** Optimistic toggle. Returns the new followed state. */
export function toggleFollow(id: string): boolean {
  const ids = readIds();
  if (ids.includes(id)) {
    writeIds(ids.filter((x) => x !== id));
    return false;
  }
  writeIds([...ids, id]);
  return true;
}

/** Subscribe to same-tab + cross-tab follow changes. Returns an unsubscribe fn. */
export function onFollowsChange(cb: () => void): () => void {
  if (typeof window === "undefined") return () => {};
  const handler = () => cb();
  window.addEventListener(EVENT_NAME, handler);
  window.addEventListener("storage", handler);
  return () => {
    window.removeEventListener(EVENT_NAME, handler);
    window.removeEventListener("storage", handler);
  };
}
