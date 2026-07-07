/**
 * videoLocalStore.ts — frontend layer for the on-device video metadata store.
 *
 * Wraps the Tauri IPC commands exposed by the Rust video store
 * (`video_store_status`, `video_query`, `video_upsert_bluesky`). This mirrors
 * `nostrLocalStore.ts`: same dynamic-import pattern, same no-op-outside-Tauri
 * behavior, same shape-conversion approach so downstream renderers
 * (`ReelsPlayer`) need no changes.
 *
 * Only post *metadata* is cached here — never video bytes. The `<video>`
 * element still streams from the source CDN; this store exists so the Reels
 * tab renders instantly from local data on tab-open instead of waiting on the
 * 12-way Bluesky search fan-out every time.
 *
 * All calls are no-ops (return null/empty) outside the Tauri runtime, so the
 * standalone web/demo build keeps working unchanged.
 */

import type { BlueskyPublicPost } from "./bluesky";

// ─────────────────────────────────────────────
// Types (mirror Rust structs, camelCase via serde)
// ─────────────────────────────────────────────

export type VideoStoreStatus = {
  initialized: boolean;
  totalCount: number;
  blueskyCount: number;
  nostrCount: number;
  lastReceivedAt: string | null;
  dbPath: string | null;
};

/** Raw record returned by Rust. VideoRecord uses snake_case `created_at`. */
type VideoRecord = {
  id: string;
  source: string;
  created_at: number;
  received_at: string;
  author_id: string;
  author_handle: string;
  author_name: string;
  author_avatar: string;
  caption: string;
  video_url: string;
  thumbnail_url: string;
  aspect_w?: number | null;
  aspect_h?: number | null;
  like_count?: number | null;
  reply_count?: number | null;
  /** Full original post/event JSON. Parsed back into a BlueskyPublicPost for Bluesky rows. */
  raw_json: string;
};

export type VideoQueryOptions = {
  source?: string;
  since?: number;
  limit?: number;
};

// ─────────────────────────────────────────────
// Invoke helper (dynamic import keeps this out of the web bundle)
// ─────────────────────────────────────────────

async function invokeTauri<T>(cmd: string, args?: Record<string, unknown>): Promise<T> {
  const core = await import("@tauri-apps/api/core");
  return core.invoke<T>(cmd, args);
}

/** A normalized video record (raw shape from Rust, snake_case). Exposed so the
 * Media tab can reconstruct both Bluesky and Nostr render shapes from cache. */
export type VideoItemRecord = VideoRecord;

// ─────────────────────────────────────────────
// Conversions: Rust record → UI shape
// ─────────────────────────────────────────────

/**
 * Reconstruct a `BlueskyPublicPost` from a stored Bluesky video row's
 * `raw_json`. The Rust side persists the full AppView post JSON, so this is a
 * straight parse + shape-check. Returns null if the JSON is missing or
 * malformed (the row is then silently dropped — the network refresh will
 * re-fill it).
 */
function videoRecordToBlueskyPost(rec: VideoRecord): BlueskyPublicPost | null {
  if (rec.source !== "bluesky") return null;
  if (!rec.raw_json || rec.raw_json === "{}") return null;
  try {
    const parsed = JSON.parse(rec.raw_json) as BlueskyPublicPost;
    // Minimal shape guard: a usable post has a uri + author.
    if (!parsed.uri || !parsed.author?.handle) return null;
    return parsed;
  } catch {
    return null;
  }
}

// ─────────────────────────────────────────────
// Public API
// ─────────────────────────────────────────────

export async function videoStoreStatus(): Promise<VideoStoreStatus | null> {
  try {
    return await invokeTauri<VideoStoreStatus>("video_store_status");
  } catch {
    return null;
  }
}

/**
 * Query cached video items. When `source === "bluesky"`, returns reconstructed
 * `BlueskyPublicPost[]` (rows whose raw_json parsed cleanly). For Nostr rows
 * or mixed sources, the caller should use `videoQueryRaw` to access the
 * normalized fields directly.
 */
export async function videoQueryBluesky(opts: VideoQueryOptions = {}): Promise<BlueskyPublicPost[]> {
  try {
    const records = await invokeTauri<VideoRecord[]>("video_query", {
      req: {
        source: opts.source ?? "bluesky",
        since: opts.since ?? null,
        limit: opts.limit ?? null,
      },
    });
    return records
      .map(videoRecordToBlueskyPost)
      .filter((p): p is BlueskyPublicPost => p !== null);
  } catch {
    return [];
  }
}

/**
 * Query raw normalized video records across all sources (or a single source).
 * Used by the Media tab, which renders both Bluesky and Nostr videos in a
 * mixed list. Each record carries `source` + `raw_json` so the caller can
 * reconstruct the source-specific render shape.
 */
export async function videoQueryRaw(opts: VideoQueryOptions = {}): Promise<VideoItemRecord[]> {
  try {
    return await invokeTauri<VideoRecord[]>("video_query", {
      req: {
        source: opts.source ?? null,
        since: opts.since ?? null,
        limit: opts.limit ?? null,
      },
    });
  } catch {
    return [];
  }
}

/** Persist freshly-fetched Bluesky posts so the next tab-open is instant. */
export async function videoUpsertBluesky(posts: BlueskyPublicPost[]): Promise<number> {
  if (posts.length === 0) return 0;
  try {
    return await invokeTauri<number>("video_upsert_bluesky", { posts });
  } catch (err) {
    console.warn("[video] upsert bluesky failed", err);
    return 0;
  }
}
