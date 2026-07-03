/**
 * ReelsPlayer.tsx — a single full-bleed vertical video tile for the Reels feed.
 *
 * Implements doom-scroll behavior: when a tile scrolls into view (≥60% visible),
 * it autoplays (muted); when it scrolls out, it pauses. Tapping the tile toggles
 * mute. A gradient overlay shows the author + caption + engagement stats, plus
 * an open-on-Bluesky action. This mirrors the TikTok/Reels layout.
 *
 * Bluesky videos are HLS (.m3u8); iOS Safari/WKWebView plays HLS natively in a
 * <video> element, so no hls.js dependency is needed for the iOS-first app.
 */

import { useEffect, useRef, useState } from "react";
import type { BlueskyPublicPost } from "../lib/bluesky";
import { blueskyVideoOf } from "../lib/bluesky";

export type ReelsPlayerProps = {
  post: BlueskyPublicPost;
  active: boolean;
};

export function ReelsPlayer({ post, active }: ReelsPlayerProps) {
  const videoRef = useRef<HTMLVideoElement | null>(null);
  const containerRef = useRef<HTMLDivElement | null>(null);
  const [muted, setMuted] = useState(true);
  const [inView, setInView] = useState(false);
  const [loaded, setLoaded] = useState(false);

  const video = blueskyVideoOf(post);
  const src = video?.playlist || "";
  const poster = video?.thumbnail || "";
  const handle = post.author?.handle || "unknown";
  const name = post.author?.displayName?.trim() || handle;
  const avatar = post.author?.avatar || "";
  const body = post.record?.text || "";
  const profileUrl = `https://bsky.app/profile/${handle}`;

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

  // Drive play/pause from inView + active.
  useEffect(() => {
    const v = videoRef.current;
    if (!v) return;
    if (active && inView) {
      v.play().catch(() => {
        /* autoplay can be blocked until user gesture; muted play is allowed */
      });
    } else {
      v.pause();
    }
  }, [active, inView]);

  if (!src && !poster) return null;

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
        onClick={() => {
          const v = videoRef.current;
          if (!v) return;
          if (v.paused) v.play().catch(() => {});
          else v.pause();
        }}
      />
      {!loaded ? <div className="reels-loading" aria-hidden><span className="btn-spinner" /></div> : null}
      {/* Tap-to-mute toggle */}
      <button
        type="button"
        className="reels-mute-btn"
        onClick={(e) => { e.stopPropagation(); setMuted((m) => !m); }}
        aria-label={muted ? "Unmute" : "Mute"}
        title={muted ? "Unmute" : "Mute"}
      >
        {muted ? "🔇" : "🔊"}
      </button>
      {/* Caption overlay */}
      <div className="reels-overlay">
        <div className="reels-author">
          {avatar ? (
            <img src={avatar} alt="" className="reels-avatar" loading="lazy" />
          ) : (
            <span className="reels-avatar reels-avatar-fallback" aria-hidden>{name.slice(0, 1).toUpperCase()}</span>
          )}
          <span className="reels-name">{name}</span>
          <span className="reels-handle">@{handle}</span>
        </div>
        {body ? <p className="reels-caption">{body.slice(0, 220)}</p> : null}
        <div className="reels-actions">
          <a className="reels-open" href={profileUrl} target="_blank" rel="noreferrer" onClick={(e) => e.stopPropagation()}>Open ↗</a>
          <span className="reels-stats">❤️ {post.likeCount ?? 0} · 💬 {post.replyCount ?? 0}</span>
        </div>
      </div>
    </div>
  );
}
