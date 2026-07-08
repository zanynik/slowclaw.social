/**
 * share.ts — Web Share API wrapper with clipboard fallback.
 *
 * Used by the Feed action bar and the Reels action rail to give every post the
 * native share sheet (title + text + url) on mobile, falling back to a silent
 * clipboard copy + toast on desktop / browsers without navigator.share.
 *
 * No network, no secrets. Returns a result the caller can surface to the user.
 */

export interface SharePayload {
  title?: string;
  text?: string;
  url?: string;
}

export type ShareResult =
  | { ok: true; method: "native" }
  | { ok: true; method: "clipboard" }
  | { ok: false; reason: "unavailable" | "aborted" | "error"; message?: string };

/**
 * Try the native share sheet first; fall back to clipboard copy of the url.
 * Never throws — callers get a typed result.
 */
export async function shareContent(payload: SharePayload): Promise<ShareResult> {
  const { title, text, url } = payload;

  // Native Web Share API (iOS Safari, Android Chrome, modern desktop).
  if (typeof navigator !== "undefined" && typeof navigator.share === "function") {
    try {
      await navigator.share({ title, text, url });
      return { ok: true, method: "native" };
    } catch (err) {
      // AbortError is the user dismissing the sheet — not a failure.
      if (err instanceof DOMException && err.name === "AbortError") {
        return { ok: false, reason: "aborted", message: "Share dismissed" };
      }
      // Fall through to clipboard attempt on other errors.
    }
  }

  // Clipboard fallback (needs a url to copy).
  if (url && typeof navigator !== "undefined" && navigator.clipboard) {
    try {
      await navigator.clipboard.writeText(url);
      return { ok: true, method: "clipboard" };
    } catch {
      return { ok: false, reason: "error", message: "Couldn't copy link" };
    }
  }

  return { ok: false, reason: "unavailable", message: "Sharing not available here" };
}

/** True when navigator.share is available (used to show/hide share affordance). */
export function canShareNatively(): boolean {
  return typeof navigator !== "undefined" && typeof navigator.share === "function";
}
