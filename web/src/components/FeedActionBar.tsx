/**
 * FeedActionBar.tsx — the uniform reply / repost / like / share / bookmark
 * action row shared by Nostr and Bluesky cards in the Feed tab.
 *
 * Twitter's signature is a consistent 4–5 icon action bar; before this,
 * Nostr cards had a working like + reply toggle while Bluesky cards showed
 * display-only emoji text (💬 🔁 ❤️). This component standardizes the row so
 * both sources feel like one product, while delegating the actual behavior to
 * the parent (which knows whether a reply thread loader, a deep-link URL, or
 * a local save applies).
 *
 * Design notes:
 *   - "Like" and "Bookmark" are optimistic + local-only (lib/savedItems.ts),
 *     so the heart fills and the ribbon toggles instantly with no network.
 *   - "Share" uses the native Web Share sheet with a clipboard fallback.
 *   - Counts are display-only badges under each icon (Twitter-style).
 *   - Icons are inline SVGs sized to match the existing card iconography.
 *
 * Kept self-contained (no App.tsx imports) so it can be unit-tested in isolation.
 */

import { useCallback, useEffect, useState } from "react";
import { isLiked, toggleLiked, onSavedChange } from "../lib/savedItems";
import { isSaved, toggleSaved, type SavedItem } from "../lib/savedItems";
import { shareContent } from "../lib/share";

export interface FeedActionBarProps {
  /** Stable id (post uri / note id). */
  id: string;
  /** Reply count for the badge. */
  replyCount?: number;
  /** Repost count for the badge. */
  repostCount?: number;
  /** Like count from the source (the local optimistic like is layered on top). */
  likeCount?: number;
  /** Title/text used by the share sheet + saved preview. */
  text?: string;
  /** Canonical URL for share / open-on-source. */
  permalink?: string;
  /** Author display name (for the saved-item preview). */
  authorName?: string;
  /** Author handle (for the saved-item preview). */
  authorHandle?: string;
  /** Thumbnail for the saved-item preview (optional). */
  thumbnail?: string;
  /** Which surface this bar lives on — saved items are tagged with it. */
  source: "nostr" | "bluesky";

  /** Called when the reply icon is tapped (parent decides: load thread or open intent). */
  onReply?: () => void;
  /** True while a reply thread is loading (disables the reply button + shows …). */
  replyLoading?: boolean;
  /** Whether a reply thread is currently expanded (toggles the icon's active state). */
  replyExpanded?: boolean;
}

export function FeedActionBar({
  id,
  replyCount,
  repostCount,
  likeCount,
  text,
  permalink,
  authorName,
  authorHandle,
  thumbnail,
  source,
  onReply,
  replyLoading,
  replyExpanded,
}: FeedActionBarProps) {
  const [liked, setLiked] = useState<boolean>(() => isLiked(id));
  const [saved, setSaved] = useState<boolean>(() => isSaved(id));
  const [shareToast, setShareToast] = useState<string | null>(null);

  // Re-sync when another tab/button toggles the same id (e.g. double-tap in Reels).
  useEffect(() => onSavedChange(() => {
    setLiked(isLiked(id));
    setSaved(isSaved(id));
  }), [id]);

  const handleLike = useCallback(() => {
    setLiked(toggleLiked(id));
  }, [id]);

  const handleBookmark = useCallback(() => {
    const item: SavedItem = {
      id,
      source,
      savedAt: Date.now(),
      title: text?.slice(0, 160) || authorHandle || "Saved item",
      body: text?.slice(0, 280),
      authorName,
      authorHandle,
      url: permalink,
      thumbnail,
    };
    setSaved(toggleSaved(item));
  }, [id, source, text, authorName, authorHandle, permalink, thumbnail]);

  const handleShare = useCallback(async () => {
    const res = await shareContent({
      title: authorName || "Shared from SlowClaw",
      text: text?.slice(0, 280) || "",
      url: permalink,
    });
    if (res.ok && res.method === "clipboard") {
      setShareToast("Link copied");
    } else if (!res.ok && res.reason !== "aborted") {
      setShareToast(res.message || "Couldn't share");
    } else {
      setShareToast(null);
    }
    if (shareToast !== null) {
      window.setTimeout(() => setShareToast(null), 1800);
    }
  }, [authorName, text, permalink, shareToast]);

  // Display counts: a local like layers on top of the source count.
  const shownLikes = (likeCount ?? 0) + (liked ? 1 : 0);

  return (
    <div className="feed-action-bar" role="group" aria-label="Post actions">
      {/* Reply */}
      <button
        type="button"
        className={`feed-action${replyExpanded ? " active" : ""}`}
        onClick={onReply}
        disabled={!onReply || replyLoading}
        aria-label="Reply"
        title="Reply"
      >
        <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round"><path d="M21 11.5a8.38 8.38 0 0 1-.9 3.8 8.5 8.5 0 0 1-7.6 4.7 8.38 8.38 0 0 1-3.8-.9L3 21l1.9-5.7a8.38 8.38 0 0 1-.9-3.8 8.5 8.5 0 0 1 4.7-7.6 8.38 8.38 0 0 1 3.8-.9h.5a8.48 8.48 0 0 1 8 8v.5z"/></svg>
        <span className="feed-action-count">{replyLoading ? "…" : (replyCount ?? 0) > 0 ? replyCount : ""}</span>
      </button>

      {/* Repost (display-only badge; tap deep-links if a permalink is set). */}
      {permalink ? (
        <a
          className="feed-action"
          href={permalink}
          target="_blank"
          rel="noreferrer"
          aria-label="View original (repost count)"
          title="View on source"
        >
          <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round"><polyline points="17 1 21 5 17 9"/><path d="M3 11V9a4 4 0 0 1 4-4h14"/><polyline points="7 23 3 19 7 15"/><path d="M21 13v2a4 4 0 0 1-4 4H3"/></svg>
          <span className="feed-action-count">{(repostCount ?? 0) > 0 ? repostCount : ""}</span>
        </a>
      ) : (
        <span className="feed-action" aria-label={`Reposts: ${repostCount ?? 0}`}>
          <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round"><polyline points="17 1 21 5 17 9"/><path d="M3 11V9a4 4 0 0 1 4-4h14"/><polyline points="7 23 3 19 7 15"/><path d="M21 13v2a4 4 0 0 1-4 4H3"/></svg>
          <span className="feed-action-count">{(repostCount ?? 0) > 0 ? repostCount : ""}</span>
        </span>
      )}

      {/* Like (optimistic, local-only). */}
      <button
        type="button"
        className={`feed-action${liked ? " liked" : ""}`}
        onClick={handleLike}
        aria-label={liked ? "Unlike" : "Like"}
        aria-pressed={liked}
        title={liked ? "Liked" : "Like"}
      >
        <svg width="18" height="18" viewBox="0 0 24 24" fill={liked ? "currentColor" : "none"} stroke="currentColor" strokeWidth="2"><path d="M20.84 4.61a5.5 5.5 0 0 0-7.78 0L12 5.67l-1.06-1.06a5.5 5.5 0 0 0-7.78 7.78l1.06 1.06L12 21.23l7.78-7.78 1.06-1.06a5.5 5.5 0 0 0 0-7.78z"/></svg>
        <span className="feed-action-count">{shownLikes > 0 ? shownLikes : ""}</span>
      </button>

      {/* Share (native sheet / clipboard). */}
      <button
        type="button"
        className="feed-action"
        onClick={() => { void handleShare(); }}
        aria-label="Share"
        title="Share"
      >
        <svg width="18" height="18" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round"><path d="M4 12v8a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2v-8"/><polyline points="16 6 12 2 8 6"/><line x1="12" y1="2" x2="12" y2="15"/></svg>
      </button>

      {/* Bookmark (local save). */}
      <button
        type="button"
        className={`feed-action${saved ? " saved" : ""}`}
        onClick={handleBookmark}
        aria-label={saved ? "Remove bookmark" : "Bookmark"}
        aria-pressed={saved}
        title={saved ? "Saved" : "Save"}
      >
        <svg width="18" height="18" viewBox="0 0 24 24" fill={saved ? "currentColor" : "none"} stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round"><path d="M19 21l-7-5-7 5V5a2 2 0 0 1 2-2h10a2 2 0 0 1 2 2z"/></svg>
      </button>

      {shareToast ? <span className="feed-action-toast" role="status">{shareToast}</span> : null}
    </div>
  );
}
