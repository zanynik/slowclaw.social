/**
 * useReadsThumbnails.ts — lazily resolve cover images for Reads cards.
 *
 * The Reads card already renders `<img className="reads-card-cover">` from
 * `item.media.thumbnailUrl` when present. Many sources fill that field at
 * ingestion (YouTube always; RSS when the feed carries an enclosure/media;
 * Bluesky/Nostr from embeds). But articles pulled through the on-device
 * `content_items` cache arrive WITHOUT a cover: `build_content_preview` in
 * `src/gateway/mod.rs` hardcodes `image_url: None`, so RSS/blog items that
 * didn't carry an inline image at fetch time show a bare card.
 *
 * This hook fills that gap lazily, on the client, by calling the existing
 * `GET /api/feed/web-preview?url=` gateway endpoint for any item that has a
 * `linkUrl` but no `thumbnailUrl`. The endpoint already:
 *   - checks the `feed_web_cache` SQLite table (fresh for 24h), and
 *   - on miss, fetches the page and extracts `og:image` / `twitter:image`.
 *
 * So this adds NO new backend infrastructure — it's the single highest-leverage
 * reuse of the OG pipeline that already exists.
 *
 * Robustness:
 *  - Module-level cache (URL → imageUrl|null) survives re-renders and view
 *    switches; a `null` value is a NEGATIVE cache (we tried, no image) so a
 *    dead URL isn't re-polled on every render.
 *  - Bounded concurrency: at most `MAX_PARALLEL` fetches in flight at once, so
 *    scrolling a long Reads list doesn't fire 50 simultaneous gateway calls.
 *  - Per-item dedupe via an in-flight `Set` so a fast scroll doesn't double-fire.
 *  - Failures are swallowed (return null) — this is best-effort enrichment.
 */

import { useEffect, useRef, useState } from "react";
import type { RankedRead } from "../lib/readsRanking";
import { fetchWebPreview } from "../lib/gatewayApi";

/** Max concurrent OG-preview fetches (keeps the local gateway + network calm). */
const MAX_PARALLEL = 4;
/** Re-poll a URL after this long even if it was a miss (site may have added OG tags). */
const NEGATIVE_CACHE_TTL_MS = 1000 * 60 * 60 * 6; // 6h

type CacheEntry = { imageUrl: string | null; fetchedAt: number };

// Module-level: survives re-renders, view switches, and tab changes within a
// session. Not persisted across app restarts — that's fine, the gateway's own
// feed_web_cache persists the real data; this just avoids re-round-tripping.
const thumbnailCache = new Map<string, CacheEntry>();
// URLs currently being fetched, to dedupe concurrent calls for the same URL.
const inflight = new Set<string>();

export interface UseReadsThumbnailsArgs {
  /** The Reads items currently displayed (already ranked + AI-boosted). */
  items: RankedRead[];
  /** Gateway auth (passed straight through to fetchWebPreview). */
  bearerToken?: string;
  /** Gateway base URL. */
  gatewayBaseUrl?: string;
}

export type ThumbnailMap = Map<string, string>;

/**
 * Resolve cover thumbnails for any Reads item that has a link but no image.
 * Returns a `Map<itemId, imageUrl>` the render loop merges onto each item's
 * `media.thumbnailUrl` before deciding whether to draw the `<img>`.
 */
export function useReadsThumbnails({
  items,
  bearerToken,
  gatewayBaseUrl,
}: UseReadsThumbnailsArgs): ThumbnailMap {
  const [thumbs, setThumbs] = useState<ThumbnailMap>(new Map());
  // Bump to trigger a re-read after async resolutions land.
  const [version, bump] = useState(0);
  // Track which URLs we've already queued in this mount to avoid re-queuing.
  const queuedRef = useRef<Set<string>>(new Set());

  useEffect(() => {
    // Collect the URLs that actually need resolving: items with a linkUrl, no
    // existing thumbnail, and no fresh cache entry.
    const now = Date.now();
    const toResolve: { itemId: string; url: string }[] = [];
    for (const r of items) {
      // Already has a cover from the source — nothing to do.
      if (r.item.media.thumbnailUrl) continue;
      const link = (r.item.content.linkUrl || "").trim();
      if (!link) continue;
      // Only http(s) links — never try to preview at://, note:, etc.
      if (!/^https?:\/\//i.test(link)) continue;

      const cached = thumbnailCache.get(link);
      if (cached) {
        // Negative cache expired → eligible to retry.
        if (cached.imageUrl === null && now - cached.fetchedAt < NEGATIVE_CACHE_TTL_MS) {
          continue;
        }
      }
      if (inflight.has(link)) continue;
      if (queuedRef.current.has(link)) continue;
      toResolve.push({ itemId: r.item.id, url: link });
    }

    if (toResolve.length === 0) return;

    // Queue + fetch with bounded concurrency. Mark each URL queued so a re-run
    // of this effect (items changed) doesn't re-add it.
    let cancelled = false;
    const queue = [...toResolve];
    const cleanupFns: (() => void)[] = [];

    const runNext = (): void => {
      if (cancelled) return;
      const job = queue.shift();
      if (!job) return;
      queuedRef.current.add(job.url);
      inflight.add(job.url);

      fetchWebPreview(job.url, bearerToken, gatewayBaseUrl)
        .then((preview) => {
          if (cancelled) return;
          const imageUrl = preview?.imageUrl?.trim() || null;
          thumbnailCache.set(job.url, { imageUrl, fetchedAt: Date.now() });
          if (imageUrl) {
            setThumbs((prev) => {
              const next = new Map(prev);
              next.set(job.itemId, imageUrl);
              return next;
            });
          }
        })
        .catch(() => {
          if (cancelled) return;
          // Negative cache the failure so we don't retry this session.
          thumbnailCache.set(job.url, { imageUrl: null, fetchedAt: Date.now() });
        })
        .finally(() => {
          inflight.delete(job.url);
          // If there's more work and capacity, keep the pipeline full.
          runNext();
          if (queue.length === 0 && inflight.size === 0) {
            // All done for this batch — nothing to do; the setThumbs calls
            // already triggered re-renders for resolved items.
          }
        });
    };

    // Seed up to MAX_PARALLEL workers.
    const workers = Math.min(MAX_PARALLEL, queue.length);
    for (let i = 0; i < workers; i++) runNext();

    return () => {
      cancelled = true;
      for (const fn of cleanupFns) fn();
      // Drop queued markers for URLs we never started, so a future effect run
      // can retry them. (inflight ones will clean themselves up in finally.)
      for (const job of queue) queuedRef.current.delete(job.url);
    };
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [items, bearerToken, gatewayBaseUrl, version]);

  // Also fold in any cache hits that were resolved on a PRIOR mount (e.g. user
  // navigated away and back) so the covers show immediately without a refetch.
  const merged = new Map<string, string>();
  for (const r of items) {
    if (r.item.media.thumbnailUrl) continue;
    const link = (r.item.content.linkUrl || "").trim();
    if (!link) continue;
    const cached = thumbnailCache.get(link);
    if (cached?.imageUrl) merged.set(r.item.id, cached.imageUrl);
  }
  // Overlay freshly-resolved ones from state.
  for (const [k, v] of thumbs) merged.set(k, v);

  return merged;
}
