/**
 * MediaTile.tsx — a single image/video tile in the Media gallery.
 *
 * Renders the first media URL of a UnifiedItem as a square thumbnail (object
 * cover), with a gradient overlay showing the author handle, source badge, and
 * an expand action. Tapping the expand chevron reveals the full caption below
 * the tile. Video thumbnails show a ▶ badge; tapping the tile opens the media
 * URL directly (the webview handles native playback).
 *
 * Kept self-contained (no App.tsx imports) so it can be unit-tested in isolation.
 */

import { useState } from "react";
import type { UnifiedItem } from "../lib/socialFeed";

export type MediaTileProps = {
  unified: UnifiedItem;
  authorName: string;
  authorHandle?: string;
  authorAvatar?: string;
  platform: UnifiedItem["sourcePlatform"];
  body?: string;
};

export function MediaTile({
  unified,
  authorName,
  authorHandle,
  authorAvatar,
  platform,
  body,
}: MediaTileProps) {
  const [expanded, setExpanded] = useState(false);
  const isVideo = unified.media.type === "video";
  const thumb = unified.media.thumbnailUrl || unified.media.urls[0] || "";
  if (!thumb) return null;

  const platformBadge = platform === "atproto" ? "Bluesky" : "Nostr";

  return (
    <figure className="media-tile">
      <a
        className="media-tile-media"
        href={unified.media.urls[0] || thumb}
        target="_blank"
        rel="noopener noreferrer"
        aria-label={`Open ${isVideo ? "video" : "image"} from ${authorName}`}
      >
        <img src={thumb} alt={body ? body.slice(0, 100) : `${platformBadge} media`} loading="lazy" />
        {isVideo ? <span className="media-tile-play" aria-hidden>▶</span> : null}
        <span className="media-tile-platform" aria-hidden>{platformBadge}</span>
      </a>
      <figcaption className="media-tile-caption">
        <div className="media-tile-author">
          {authorAvatar ? (
            <img src={authorAvatar} alt="" className="media-tile-avatar" loading="lazy" />
          ) : (
            <span className="media-tile-avatar media-tile-avatar-fallback" aria-hidden>
              {authorName.slice(0, 1).toUpperCase()}
            </span>
          )}
          <span className="media-tile-name">{authorHandle ? `@${authorHandle}` : authorName}</span>
        </div>
        {body && body.trim() ? (
          <button
            type="button"
            className="media-tile-expand ghost"
            onClick={() => setExpanded((v) => !v)}
            aria-expanded={expanded}
            aria-label={expanded ? "Hide caption" : "Show caption"}
            title={expanded ? "Hide caption" : "Show caption"}
          >
            <svg viewBox="0 0 24 24" width="16" height="16" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" style={{ transform: expanded ? "rotate(180deg)" : "none", transition: "transform 0.15s" }}>
              <polyline points="6 9 12 15 18 9" />
            </svg>
          </button>
        ) : null}
      </figcaption>
      {expanded && body && body.trim() ? (
        <p className="media-tile-body">{body}</p>
      ) : null}
    </figure>
  );
}
