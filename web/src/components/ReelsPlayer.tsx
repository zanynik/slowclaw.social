/**
 * ReelsPlayer.tsx — a single full-bleed vertical video tile for the Reels feed.
 *
 * Implements TikTok/Instagram-Reels behavior:
 *   - Snap-paged: the parent `.reels-feed` uses scroll-snap so each tile fills
 *     the viewport; an IntersectionObserver plays the in-view tile and pauses
 *     the rest.
 *   - Global mute: `muted` is lifted to the parent so unmuting one video
 *     unmutes all (and vice versa). Persists via the parent.
 *   - Progress bar: a thin scrub at the tile bottom tracks playback.
 *   - Right action rail: like / comment / share / bookmark stacked vertically.
 *   - Single tap toggles play/pause; double tap fires an optimistic like with
 *     a burst-heart animation.
 *
 * Bluesky videos are HLS (.m3u8); iOS Safari/WKWebView plays HLS natively in a
 * <video> element, so no hls.js dependency is needed for the iOS-first app.
 */

import { useEffect, useRef, useState } from "react";
import type { BlueskyPublicPost } from "../lib/bluesky";
import { blueskyVideoOf } from "../lib/bluesky";
import { toggleLiked, isLiked } from "../lib/savedItems";
import { toggleSaved, isSaved, type SavedItem } from "../lib/savedItems";
import { shareContent } from "../lib/share";

export type ReelsPlayerProps = {
  post: BlueskyPublicPost;
  /** When false the tile never autoplays (e.g. tab hidden). */
  active: boolean;
  /** Global mute state (lifted to parent so all tiles stay in sync). */
  muted: boolean;
  onToggleMute: () => void;
};

/** Build a bsky.app deep-link from a post uri (at://did/app.bsky.feed.post/rkey). */
function postPermalink(uri: string): string {
  // at://did:plc:xyz/app.bsky.feed.post/rkey  →  https://bsky.app/profile/did:plc:xyz/post/rkey
  const m = /^at:\/\/([^/]+)\/app\.bsky\.feed\.post\/(.+)$/.exec(uri);
  if (m) return `https://bsky.app/profile/${m[1]}/post/${m[2]}`;
  return "https://bsky.app";
}

export function ReelsPlayer({ post, active, muted, onToggleMute }: ReelsPlayerProps) {
  const videoRef = useRef<HTMLVideoElement | null>(null);
  const containerRef = useRef<HTMLDivElement | null>(null);
  const lastTapRef = useRef(0);
  const [inView, setInView] = useState(false);
  const [loaded, setLoaded] = useState(false);
  const [progress, setProgress] = useState(0); // 0..1
  const [liked, setLiked] = useState<boolean>(() => isLiked(post.uri));
  const [saved, setSaved] = useState<boolean>(() => isSaved(post.uri));
  const [burst, setBurst] = useState(false);

  const video = blueskyVideoOf(post);
  const src = video?.playlist || "";
  const poster = video?.thumbnail || "";
  const handle = post.author?.handle || "unknown";
  const name = post.author?.displayName?.trim() || handle;
  const avatar = post.author?.avatar || "";
  const body = post.record?.text || "";
  const profileUrl = `https://bsky.app/profile/${handle}`;
  const permalink = postPermalink(post.uri);

  // IntersectionObserver: play when ≥60% visible, pause otherwise.
  useEffect(() => {
    const el = containerRef.current;
    if (!el) return;
    const observer = new IntersectionObserver(
      (entries) => {
        for (const entry of entries) {
          setInView(entry.intersectionRatio >= 0.6);
        }
      },
      { threshold: [0, 0.6, 1] },
    );
    observer.observe(el);
    return () => observer.disconnect();
  }, []);

  // Drive play/pause from inView + active + muted.
  useEffect(() => {
    const v = videoRef.current;
    if (!v) return;
    v.muted = muted;
    if (active && inView) {
      v.play().catch(() => {
        /* autoplay can be blocked until user gesture; muted play is allowed */
      });
    } else {
      v.pause();
    }
  }, [active, inView, muted]);

  if (!src && !poster) return null;

  function handleVideoTap() {
    // Double-tap → like burst; single tap → play/pause (resolved on a short
    // timer so we can distinguish the two). 280ms feels instant on mobile.
    const now = Date.now();
    if (now - lastTapRef.current < 280) {
      lastTapRef.current = 0;
      if (!liked) setLiked(toggleLiked(post.uri));
      setBurst(true);
      window.setTimeout(() => setBurst(false), 700);
      return;
    }
    lastTapRef.current = now;
    window.setTimeout(() => {
      if (lastTapRef.current && Date.now() - lastTapRef.current >= 270) {
        lastTapRef.current = 0;
        const v = videoRef.current;
        if (!v) return;
        if (v.paused) v.play().catch(() => {});
        else v.pause();
      }
    }, 290);
  }

  function handleLike() {
    setLiked(toggleLiked(post.uri));
    setBurst(true);
    window.setTimeout(() => setBurst(false), 700);
  }

  function handleBookmark() {
    const item: SavedItem = {
      id: post.uri,
      source: "reels",
      savedAt: Date.now(),
      title: body.slice(0, 160) || `Reel by @${handle}`,
      body: body.slice(0, 280),
      authorName: name,
      authorHandle: handle,
      url: permalink,
      thumbnail: poster || avatar,
    };
    setSaved(toggleSaved(item));
  }

  async function handleShare() {
    await shareContent({
      title: `Reel by @${handle}`,
      text: body.slice(0, 200),
      url: permalink,
    });
  }

  const shownLikes = (post.likeCount ?? 0) + (liked ? 1 : 0);

  return (
    <div className="reels-tile" ref={containerRef}>
      <video
        ref={videoRef}
        className="reels-video"
        src={src || undefined}
        poster={poster || undefined}
        muted={muted}
        loop
        playsInline
        preload="metadata"
        onLoadedData={() => setLoaded(true)}
        onClick={handleVideoTap}
        onTimeUpdate={(e) => {
          const v = e.currentTarget;
          if (v.duration > 0) setProgress(v.currentTime / v.duration);
        }}
      />
      {!loaded ? <div className="reels-loading" aria-hidden><span className="btn-spinner" /></div> : null}

      {/* Pause indicator (shown briefly when paused mid-view). */}
      {inView && loaded && videoRef.current?.paused ? (
        <div className="reels-paused" aria-hidden>⏸</div>
      ) : null}

      {/* Double-tap-to-like burst. */}
      {burst ? (
        <div className="reels-dbltap-heart" aria-hidden>
          <svg viewBox="0 0 24 24" fill="currentColor"><path d="M12 21.35l-1.45-1.32C5.4 15.36 2 12.28 2 8.5 2 5.42 4.42 3 7.5 3c1.74 0 3.41.81 4.5 2.09C13.09 3.81 14.76 3 16.5 3 19.58 3 22 5.42 22 8.5c0 3.78-3.4 6.86-8.55 11.54L12 21.35z"/></svg>
        </div>
      ) : null}

      {/* Tap-to-mute toggle (global). */}
      <button
        type="button"
        className="reels-mute-btn"
        onClick={(e) => { e.stopPropagation(); onToggleMute(); }}
        aria-label={muted ? "Unmute all" : "Mute all"}
        title={muted ? "Unmute all" : "Mute all"}
      >
        {muted ? "🔇" : "🔊"}
      </button>

      {/* Right action rail (Instagram/Reels signature). */}
      <div className="reels-rail" role="group" aria-label="Video actions">
        <button type="button" className={`reels-rail-btn${liked ? " liked" : ""}`} onClick={handleLike} aria-label={liked ? "Unlike" : "Like"} aria-pressed={liked}>
          <svg viewBox="0 0 24 24" width="28" height="28" fill={liked ? "currentColor" : "none"} stroke="currentColor" strokeWidth="2"><path d="M20.84 4.61a5.5 5.5 0 0 0-7.78 0L12 5.67l-1.06-1.06a5.5 5.5 0 0 0-7.78 7.78l1.06 1.06L12 21.23l7.78-7.78 1.06-1.06a5.5 5.5 0 0 0 0-7.78z"/></svg>
          <span className="reels-rail-count">{shownLikes > 0 ? shownLikes : ""}</span>
        </button>
        <a className="reels-rail-btn" href={permalink} target="_blank" rel="noreferrer" aria-label="Comments" onClick={(e) => e.stopPropagation()}>
          <svg viewBox="0 0 24 24" width="28" height="28" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round"><path d="M21 11.5a8.38 8.38 0 0 1-.9 3.8 8.5 8.5 0 0 1-7.6 4.7 8.38 8.38 0 0 1-3.8-.9L3 21l1.9-5.7a8.38 8.38 0 0 1-.9-3.8 8.5 8.5 0 0 1 4.7-7.6 8.38 8.38 0 0 1 3.8-.9h.5a8.48 8.48 0 0 1 8 8v.5z"/></svg>
          <span className="reels-rail-count">{(post.replyCount ?? 0) > 0 ? post.replyCount : ""}</span>
        </a>
        <button type="button" className="reels-rail-btn" onClick={() => { void handleShare(); }} aria-label="Share" onClickCapture={(e) => e.stopPropagation()}>
          <svg viewBox="0 0 24 24" width="28" height="28" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round"><path d="M4 12v8a2 2 0 0 0 2 2h12a2 2 0 0 0 2-2v-8"/><polyline points="16 6 12 2 8 6"/><line x1="12" y1="2" x2="12" y2="15"/></svg>
        </button>
        <button type="button" className={`reels-rail-btn${saved ? " saved" : ""}`} onClick={handleBookmark} aria-label={saved ? "Remove bookmark" : "Bookmark"} aria-pressed={saved}>
          <svg viewBox="0 0 24 24" width="28" height="28" fill={saved ? "currentColor" : "none"} stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round"><path d="M19 21l-7-5-7 5V5a2 2 0 0 1 2-2h10a2 2 0 0 1 2 2z"/></svg>
        </button>
        {avatar ? (
          <a className="reels-rail-avatar-link" href={profileUrl} target="_blank" rel="noreferrer" onClick={(e) => e.stopPropagation()} aria-label={`Open @${handle}`}>
            <img src={avatar} alt="" className="reels-rail-avatar" loading="lazy" />
          </a>
        ) : null}
      </div>

      {/* Caption overlay (bottom-left, author + caption only). */}
      <div className="reels-overlay">
        <div className="reels-author">
          <span className="reels-name">{name}</span>
          <span className="reels-handle">@{handle}</span>
        </div>
        {body ? <p className="reels-caption">{body.slice(0, 220)}</p> : null}
      </div>

      {/* Progress bar (very bottom edge). */}
      <div className="reels-progress" aria-hidden>
        <div className="reels-progress-fill" style={{ width: `${Math.min(100, progress * 100)}%` }} />
      </div>
    </div>
  );
}
