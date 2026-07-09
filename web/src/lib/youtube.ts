/**
 * youtube.ts — YouTube ingestion for the Reads feed (journal-is-the-lens).
 *
 * YouTube is a *read-only ingestion source* (per docs/vision-contract.md):
 * videos flow INTO the user's curated feed; the user's own content never
 * depends on YouTube. The curation signal is the user's journals.
 *
 * ── Two paths, by reliability ───────────────────────────────────────────────
 *
 * 1. CHANNEL FEEDS (default, reliable). YouTube publishes real RSS per channel
 *    and playlist (`/feeds/videos.xml?channel_id=...`). These are fetched via
 *    the SAME `api.rss2json.com` CORS proxy already in production for RSS
 *    blogs (rss.ts) — no new dependency, webview-safe (`Access-Control-Allow-
 *    Origin: *`), and NOT behind YouTube's search bot-wall. This is the robust
 *    keyless path: subscribe to creators whose content feeds your mind, and the
 *    journal-driven ranker surfaces the videos most relevant to what you write.
 *
 * 2. TOPIC SEARCH (best-effort, secondary). Searched by the user's journal
 *    topics via Invidious instances. This is the "discover videos about MY
 *    interests" path. It is intentionally best-effort: Invidious availability,
 *    CORS, and YouTube bot-protection vary widely and rotate over time (as of
 *    2026, keyless Invidious search is broadly degraded). On total failure the
 *    Reads stream simply shows no topic-search videos — channel feeds still
 *    work. An optional user-owned YouTube Data API v3 key (`searchYouTubeOfficial`)
 *    is the reliable topic-discovery path for callers that supply one.
 *
 * Honesty contract: channel feeds are the load-bearing keyless path; topic
 * search is a flaky supplement. loadYouTubeFeed() merges both so the reliable
 * base is always present and the best-effort layer adds when it can.
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
  /** Video length in seconds (0 if unknown — RSS doesn't include it). */
  durationSeconds: number;
  /** Cover image (hqdefault works for every video id). */
  thumbnailUrl: string;
  /** Watch URL. */
  watchUrl: string;
};

/* ── Path 1: Channel feeds (reliable keyless default) ────────────────────── */

export type YouTubeChannel = {
  /** Stable id (React key). */
  id: string;
  /** Display label. */
  label: string;
  /** `channel_id` or `playlist_id` value. */
  value: string;
  /** "channel" (channel_id=) or "playlist" (playlist_id=). */
  kind: "channel" | "playlist";
  /** Emoji for the chip. */
  emoji?: string;
};

/**
 * Default channel catalog. Every entry was verified to return videos via the
 * rss2json proxy before inclusion (no guessed/broken ids). Broadly-valuable
 * educational/tech channels that fit a journaling + learning audience; the
 * user's journal-driven ranking then promotes the videos most relevant to them.
 * Extend by adding verified entries here (chip-editing UI is a follow-up).
 */
export const YOUTUBE_CHANNELS: YouTubeChannel[] = [
  { id: "veritasium", label: "Veritasium", value: "UCHnyfMqiRRG1u-2MsSQLbXA", kind: "channel", emoji: "🔬" },
  { id: "kurzgesagt", label: "Kurzgesagt", value: "UCsXVk37bltHxD1rDPwtNM8Q", kind: "channel", emoji: "🐦" },
  { id: "lex-fridman", label: "Lex Fridman", value: "UCSHZKyawb77ixDdsGog4iWA", kind: "channel", emoji: "🎙️" },
  { id: "linus-tech-tips", label: "Linus Tech Tips", value: "UCXuqSBlHAE6Xw-yeJA0Tunw", kind: "channel", emoji: "💻" },
];

/** Build the YouTube RSS URL for a channel or playlist. */
function youTubeRssUrl(channel: Pick<YouTubeChannel, "value" | "kind">): string {
  const param = channel.kind === "playlist" ? "playlist_id" : "channel_id";
  return `https://www.youtube.com/feeds/videos.xml?${param}=${channel.value}`;
}

const RSS2JSON = "https://api.rss2json.com/v1/api.json";

/** Extract an 11-char YouTube video id from a watch/shorts link. */
function videoIdFromLink(link: string): string | null {
  const m = link.match(/[?&]v=([A-Za-z0-9_-]{11})/);
  if (m) return m[1];
  const shorts = link.match(/\/shorts\/([A-Za-z0-9_-]{11})/);
  if (shorts) return shorts[1];
  return null;
}

/** Strip HTML from descriptions rss2json sometimes returns. */
function cleanText(value: unknown): string {
  if (typeof value !== "string") return "";
  return value.replace(/<[^>]+>/g, " ").replace(/&[a-z]+;/gi, " ").replace(/\s+/g, " ").trim();
}

/** Convert an rss2json item to a YouTubeVideo. Returns null if no usable id. */
function rssItemToVideo(
  item: { link?: string; title?: string; description?: string; content?: string; pubDate?: string; thumbnail?: string; author?: string },
  fallbackAuthor: string,
): YouTubeVideo | null {
  const link = String(item.link || "");
  const id = videoIdFromLink(link);
  if (!id) return null;
  const tsMs = item.pubDate ? Date.parse(item.pubDate) : NaN;
  const description = cleanText(item.description || item.content);
  return {
    id,
    title: cleanText(item.title) || "Untitled video",
    description: description.slice(0, 500),
    author: cleanText(item.author) || fallbackAuthor,
    publishedAt: Number.isFinite(tsMs) ? Math.floor(tsMs / 1000) : 0,
    durationSeconds: 0, // Not in YouTube RSS.
    thumbnailUrl: item.thumbnail || `https://i.ytimg.com/vi/${id}/hqdefault.jpg`,
    watchUrl: link || `https://www.youtube.com/watch?v=${id}`,
  };
}

/**
 * Fetch one YouTube channel/playlist via the rss2json CORS proxy (the same
 * proxy RSS blogs use in rss.ts). Throws on non-OK / parse error.
 */
export async function fetchYouTubeChannel(
  channel: YouTubeChannel,
  opts: { limit?: number; signal?: AbortSignal } = {},
): Promise<YouTubeVideo[]> {
  const limit = Math.max(1, opts.limit ?? 10);
  const url = `${RSS2JSON}?rss_url=${encodeURIComponent(youTubeRssUrl(channel))}`;
  const res = await fetch(url, { signal: opts.signal, headers: { Accept: "application/json" } });
  if (!res.ok) throw new Error(`YouTube RSS ${res.status}`);
  const data = await res.json();
  if (data.status !== "ok") throw new Error(`YouTube RSS: ${data.message || "feed error"}`);
  const feedTitle = cleanText(data.feed?.title) || channel.label;
  const items: unknown[] = Array.isArray(data.items) ? data.items : [];
  return items
    .map((it) => rssItemToVideo(it as Record<string, string>, feedTitle))
    .filter((v): v is YouTubeVideo => v !== null)
    .slice(0, limit);
}

/** Fetch multiple channels in parallel; per-channel failures are tolerated. */
export async function fetchYouTubeChannels(
  channels: YouTubeChannel[],
  opts: { limitPerChannel?: number; signal?: AbortSignal } = {},
): Promise<YouTubeVideo[]> {
  const limit = opts.limitPerChannel ?? 8;
  const results = await Promise.allSettled(
    channels.map((c) => fetchYouTubeChannel(c, { limit, signal: opts.signal })),
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

/* ── Path 2: Topic search (best-effort secondary) ────────────────────────── */
//
// Keyless topic search via Invidious public instances. Reliability is poor and
// rotates (CORS, bot-protection, instance churn); this exists to let channel
// feeds be supplemented by interest-driven discovery when an instance happens
// to be reachable. It is NOT load-bearing — callers must tolerate total failure.

const INVIDIOUS_INSTANCES = [
  "https://inv.nadeko.net",
  "https://invidious.private.coffee",
  "https://inv.zoomerville.com",
];

const INSTANCE_TIMEOUT_MS = 5000;

interface InvidiousSearchItem {
  type?: string;
  videoId?: string;
  title?: string;
  description?: string;
  author?: string;
  published?: number;
  lengthSeconds?: number;
  viewCount?: number;
  videoThumbnails?: { url: string; quality: string }[];
}

function isVideoItem(item: InvidiousSearchItem): item is InvidiousSearchItem {
  return item.type === "video" && typeof item.videoId === "string" && !!item.videoId;
}

function pickThumbnail(item: InvidiousSearchItem): string {
  const list = item.videoThumbnails || [];
  const preferred = list.find((t) => t.quality === "medium") || list.find((t) => t.quality === "high") || list[0];
  if (preferred?.url) return preferred.url;
  return `https://i.ytimg.com/vi/${item.videoId}/hqdefault.jpg`;
}

function invidiousToVideo(item: InvidiousSearchItem): YouTubeVideo {
  const id = item.videoId as string;
  return {
    id,
    title: cleanText(item.title) || "Untitled video",
    description: cleanText(item.description).slice(0, 500),
    author: cleanText(item.author) || "YouTube",
    publishedAt: Number.isFinite(item.published) && (item.published ?? 0) > 0 ? (item.published as number) : 0,
    durationSeconds: Number.isFinite(item.lengthSeconds) ? Math.max(0, item.lengthSeconds ?? 0) : 0,
    thumbnailUrl: pickThumbnail(item),
    watchUrl: `https://www.youtube.com/watch?v=${id}`,
    viewCount: Number.isFinite(item.viewCount) ? item.viewCount : undefined,
  } as YouTubeVideo;
}

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
 * Best-effort keyless topic search via Invidious. Tries each instance in order
 * until one returns usable video results. Throws only if every instance fails.
 * Callers MUST tolerate failure (the channel-feed path is the reliable base).
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
      if (!res.ok) { lastError = new Error(`${base} ${res.status}`); continue; }
      const data = await res.json();
      if (!Array.isArray(data)) { lastError = new Error(`${base} non-array`); continue; }
      const videos = data.filter((it): it is InvidiousSearchItem => isVideoItem(it as InvidiousSearchItem)).map(invidiousToVideo);
      if (videos.length > 0) return videos.slice(0, limit);
      lastError = new Error(`${base} no videos`);
    } catch (e) {
      lastError = e;
    }
  }
  throw lastError instanceof Error ? lastError : new Error("YouTube topic search failed");
}

/**
 * Fan topic search across the user's top journal topics (best-effort). Per-topic
 * failures are tolerated; total failure returns []. Caps at 3 topics.
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

/**
 * Official YouTube Data API v3 search — the RELIABLE topic-discovery path, but
 * requires a user-owned API key (local-first-aligned) and consumes quota
 * (default 100 units/day; search costs 100). Provided for a future Settings-
 * driven caller; NOT wired by default.
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
    key: apiKey.trim(), q, part: "snippet", type: "video", maxResults: String(limit), order: "relevance",
  });
  const res = await fetchWithTimeout(
    `https://www.googleapis.com/youtube/v3/search?${params.toString()}`,
    INSTANCE_TIMEOUT_MS * 2, opts.signal,
  );
  if (!res.ok) throw new Error(`YouTube API ${res.status}`);
  const data = await res.json();
  const raw: unknown[] = Array.isArray(data.items) ? data.items : [];
  const mapped: (YouTubeVideo | null)[] = raw.map((it: any): YouTubeVideo | null => {
    const id = it?.id?.videoId;
    const sn = it?.snippet || {};
    if (!id) return null;
    const thumbs = sn.thumbnails || {};
    const thumb = (thumbs.medium || thumbs.high || thumbs.default || {}).url;
    return {
      id, title: cleanText(sn.title) || "Untitled video",
      description: cleanText(sn.description).slice(0, 500),
      author: cleanText(sn.channelTitle) || "YouTube",
      publishedAt: sn.publishedAt ? Math.floor(Date.parse(sn.publishedAt) / 1000) : 0,
      durationSeconds: 0,
      thumbnailUrl: thumb || `https://i.ytimg.com/vi/${id}/hqdefault.jpg`,
      watchUrl: `https://www.youtube.com/watch?v=${id}`,
    };
  });
  return mapped.filter((v): v is YouTubeVideo => v !== null).slice(0, limit);
}

/* ── Combined loader (reliable base + best-effort supplement) ─────────────── */

/**
 * Load the YouTube stream for the Reads feed. Merges the two paths and dedupes
 * by video id:
 *   - Channel feeds (reliable, keyless): always attempted; these are the base.
 *   - Topic search (best-effort, keyless): searched by the user's journal
 *     topics; adds interest-driven discovery when an Invidious instance is up.
 * Channel feeds are NOT silently dropped on topic-search failure, so the user
 * always gets their subscribed creators' videos even when discovery is down.
 */
export async function loadYouTubeFeed(
  opts: { channels?: YouTubeChannel[]; topics?: string[]; perTopic?: number; limitPerChannel?: number; signal?: AbortSignal } = {},
): Promise<YouTubeVideo[]> {
  const channels = opts.channels && opts.channels.length > 0 ? opts.channels : YOUTUBE_CHANNELS;
  const topics = (opts.topics || []).map((t) => t.trim()).filter(Boolean).slice(0, 3);
  const [channelVideos, topicVideos] = await Promise.all([
    fetchYouTubeChannels(channels, { limitPerChannel: opts.limitPerChannel ?? 6, signal: opts.signal }).catch(() => [] as YouTubeVideo[]),
    topics.length > 0
      ? searchYouTubeByTopics(topics, { perTopic: opts.perTopic ?? 4, signal: opts.signal }).catch(() => [] as YouTubeVideo[])
      : Promise.resolve([] as YouTubeVideo[]),
  ]);
  const merged: YouTubeVideo[] = [];
  const seen = new Set<string>();
  for (const v of [...channelVideos, ...topicVideos]) {
    if (seen.has(v.id)) continue;
    seen.add(v.id);
    merged.push(v);
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
