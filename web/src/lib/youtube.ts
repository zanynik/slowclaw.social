/**
 * youtube.ts — keyless YouTube ingestion for the Reads feed.
 *
 * YouTube is treated as a *read-only ingestion source* (per docs/vision-contract.md):
 * videos flow INTO the user's curated feed; the user's own content never depends
 * on YouTube. The curation signal is the user's journals — search terms are
 * derived from `extractJournalTopics`, so the videos surface are "what feeds
 * THIS user's mind", matching the thesis that the journal is the lens.
 *
 * Keyless path: Invidious public instances expose a CORS-friendly JSON search
 * API (`/api/v1/search`). No API key, no Google account — keeps the feature
 * dependency-free and local-first-aligned. Reliability varies across instances
 * (they go up/down and rate-limit), so we try a small list in sequence with a
 * per-instance timeout and tolerate total failure: the Reads stream degrades
 * gracefully (videos simply don't appear), exactly like the best-effort HN path.
 *
 * An optional official YouTube Data API v3 path is structurally supported
 * (`searchYouTubeOfficial`) for callers that supply a user-owned API key; wiring
 * a key into Settings is a deliberate follow-up (no current caller — YAGNI).
 */

/** A normalized YouTube video, source-agnostic (works with the unified feed). */
export type YouTubeVideo = {
  /** YouTube video id (11 chars). */
  id: string;
  title: string;
  /** Description excerpt — kept so the journal-topic lens can match it. */
  description: string;
  /** Channel display name. */
  author: string;
  /** Epoch seconds, when the video was published. */
  publishedAt: number;
  /** Video length in seconds (best-effort; 0 if unknown). */
  durationSeconds: number;
  /** Cover image (hqdefault works for every video id). */
  thumbnailUrl: string;
  /** Watch URL. */
  watchUrl: string;
  /** View count, when available. */
  viewCount?: number;
};

/**
 * Public Invidious instances, tried in order. These are best-effort and rotate
 * over time; the sequential fallback means the feature works as long as ONE is
 * reachable and CORS-permissive. Add/remove instances here as availability shifts.
 */
const INVIDIOUS_INSTANCES = [
  "https://inv.nadeko.net",
  "https://invidious.nerdvpn.de",
  "https://invidious.jing.rocks",
  "https://invidious.private.coffee",
  "https://iv.ggtyler.dev",
  "https://yewtu.be",
];

/** Per-instance timeout. Short enough to fail over quickly on dead instances. */
const INSTANCE_TIMEOUT_MS = 6000;

/** Invidious search result item (video only; channels/playlists are filtered out). */
interface InvidiousSearchItem {
  type?: string;
  videoId?: string;
  title?: string;
  description?: string;
  descriptionHtml?: string;
  author?: string;
  published?: number;
  lengthSeconds?: number;
  viewCount?: number;
  videoThumbnails?: { url: string; quality: string; width: number; height: number }[];
}

function isVideoItem(item: InvidiousSearchItem): item is InvidiousSearchItem {
  return item.type === "video" && typeof item.videoId === "string" && !!item.videoId;
}

/** Strip HTML entities/tags Invidious sometimes returns in description fields. */
function cleanText(value: unknown): string {
  if (typeof value !== "string") return "";
  return value
    .replace(/<[^>]+>/g, " ")
    .replace(/&[a-z]+;/gi, " ")
    .replace(/\s+/g, " ")
    .trim();
}

function pickThumbnail(item: InvidiousSearchItem): string {
  const list = item.videoThumbnails || [];
  // Prefer a mid-quality thumbnail; fall back to hqdefault (always exists).
  const preferred =
    list.find((t) => t.quality === "medium") ||
    list.find((t) => t.quality === "high") ||
    list[0];
  if (preferred?.url) return preferred.url;
  return `https://i.ytimg.com/vi/${item.videoId}/hqdefault.jpg`;
}

function invidiousToVideo(item: InvidiousSearchItem): YouTubeVideo {
  const id = item.videoId as string;
  const description = cleanText(item.description);
  return {
    id,
    title: cleanText(item.title) || "Untitled video",
    // Keep a substantive excerpt so journal-topic matching has text to work
    // with (the lens matches against title + body).
    description: description.slice(0, 500),
    author: cleanText(item.author) || "YouTube",
    publishedAt: Number.isFinite(item.published) && (item.published ?? 0) > 0 ? (item.published as number) : 0,
    durationSeconds: Number.isFinite(item.lengthSeconds) ? Math.max(0, item.lengthSeconds ?? 0) : 0,
    thumbnailUrl: pickThumbnail(item),
    watchUrl: `https://www.youtube.com/watch?v=${id}`,
    viewCount: Number.isFinite(item.viewCount) ? item.viewCount : undefined,
  };
}

/** Race a fetch against a timeout via AbortController; rejects on either firing. */
async function fetchWithTimeout(url: string, timeoutMs: number, externalSignal?: AbortSignal): Promise<Response> {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);
  if (externalSignal) {
    if (externalSignal.aborted) controller.abort();
    else externalSignal.addEventListener("abort", () => controller.abort(), { once: true });
  }
  try {
    return await fetch(url, { signal: controller.signal, headers: { Accept: "application/json" } });
  } finally {
    clearTimeout(timer);
  }
}

/**
 * Keyless YouTube search via Invidious. Tries each instance in order until one
 * returns usable video results. `sortBy`:
 *   - "relevance" (default) surfaces evergreen/high-quality matches by topic —
 *     the user explicitly welcomes "really good old ones".
 *   - "newest" prioritizes fresh uploads.
 * Throws only if EVERY instance fails; callers should tolerate (best-effort).
 */
export async function searchYouTube(
  query: string,
  opts: { limit?: number; sortBy?: "relevance" | "newest"; signal?: AbortSignal } = {},
): Promise<YouTubeVideo[]> {
  const q = query.trim();
  if (!q) return [];
  const limit = Math.max(1, opts.limit ?? 8);
  const sortBy = opts.sortBy === "newest" ? "upload_date" : "relevance";
  const params = new URLSearchParams({ q, type: "video", sort_by: sortBy });

  let lastError: unknown;
  for (const base of INVIDIOUS_INSTANCES) {
    try {
      const res = await fetchWithTimeout(`${base}/api/v1/search?${params.toString()}`, INSTANCE_TIMEOUT_MS, opts.signal);
      if (!res.ok) {
        lastError = new Error(`${base} responded ${res.status}`);
        continue;
      }
      const data = await res.json();
      if (!Array.isArray(data)) {
        lastError = new Error(`${base} returned non-array payload`);
        continue;
      }
      const videos = data
        .filter((item): item is InvidiousSearchItem => isVideoItem(item as InvidiousSearchItem))
        .map(invidiousToVideo);
      if (videos.length > 0) return videos.slice(0, limit);
      lastError = new Error(`${base} returned no videos`);
    } catch (e) {
      // AbortError from our timeout, network failure, or JSON parse error —
      // fall through to the next instance.
      lastError = e;
    }
  }
  throw lastError instanceof Error ? lastError : new Error("YouTube search failed");
}

/**
 * Official YouTube Data API v3 search. Reliable (Google's own API) but requires
 * a user-owned API key and counts against quota (default 100 units/day; search
 * costs 100 units). Provided for a future Settings-driven caller; NOT wired by
 * default to honor the local-first / no-Google-account dependency invariant.
 */
export async function searchYouTubeOfficial(
  query: string,
  apiKey: string,
  opts: { limit?: number; signal?: AbortSignal } = {},
): Promise<YouTubeVideo[]> {
  const q = query.trim();
  if (!q || !apiKey.trim()) return [];
  const limit = Math.max(1, opts.limit ?? 8);
  const params = new URLSearchParams({
    key: apiKey.trim(),
    q,
    part: "snippet",
    type: "video",
    maxResults: String(limit),
    order: "relevance",
  });
  const res = await fetchWithTimeout(
    `https://www.googleapis.com/youtube/v3/search?${params.toString()}`,
    INSTANCE_TIMEOUT_MS * 2,
    opts.signal,
  );
  if (!res.ok) throw new Error(`YouTube API ${res.status}`);
  const data = await res.json();
  const raw: unknown[] = Array.isArray(data.items) ? data.items : [];
  const mapped: (YouTubeVideo | null)[] = raw
    .map((it: any): YouTubeVideo | null => {
      const id = it?.id?.videoId;
      const sn = it?.snippet || {};
      if (!id) return null;
      const thumbs = sn.thumbnails || {};
      const thumb = (thumbs.medium || thumbs.high || thumbs.default || {}).url;
      return {
        id,
        title: cleanText(sn.title) || "Untitled video",
        description: cleanText(sn.description).slice(0, 500),
        author: cleanText(sn.channelTitle) || "YouTube",
        publishedAt: sn.publishedAt ? Math.floor(Date.parse(sn.publishedAt) / 1000) : 0,
        durationSeconds: 0, // Not returned by search; needs a videos.list call.
        thumbnailUrl: thumb || `https://i.ytimg.com/vi/${id}/hqdefault.jpg`,
        watchUrl: `https://www.youtube.com/watch?v=${id}`,
      };
    });
  return mapped.filter((v): v is YouTubeVideo => v !== null).slice(0, limit);
}

/**
 * Fetch videos for several journal topics in parallel and dedupe by video id.
 * Best-effort: per-topic failures are tolerated (Promise.allSettled), so one
 * flaky search doesn't blank the others. Caps at 3 topics to bound network use.
 */
export async function searchYouTubeByTopics(
  topics: string[],
  opts: { perTopic?: number; signal?: AbortSignal } = {},
): Promise<YouTubeVideo[]> {
  const perTopic = Math.max(1, opts.perTopic ?? 5);
  const queries = topics.map((t) => t.trim()).filter(Boolean).slice(0, 3);
  if (queries.length === 0) return [];
  const results = await Promise.allSettled(
    queries.map((q) => searchYouTube(q, { limit: perTopic, sortBy: "relevance", signal: opts.signal })),
  );
  const merged: YouTubeVideo[] = [];
  const seen = new Set<string>();
  for (const r of results) {
    if (r.status !== "fulfilled") continue;
    for (const v of r.value) {
      if (seen.has(v.id)) continue;
      seen.add(v.id);
      merged.push(v);
    }
  }
  return merged;
}

/** Format a duration in seconds as M:SS or H:MM:SS (for future display use). */
export function formatDuration(totalSeconds?: number): string {
  if (!totalSeconds || totalSeconds <= 0) return "";
  const s = Math.floor(totalSeconds);
  const h = Math.floor(s / 3600);
  const m = Math.floor((s % 3600) / 60);
  const sec = s % 60;
  if (h > 0) return `${h}:${String(m).padStart(2, "0")}:${String(sec).padStart(2, "0")}`;
  return `${m}:${String(sec).padStart(2, "0")}`;
}
