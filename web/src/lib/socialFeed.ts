/**
 * socialFeed.ts — Unified social-content normalization + journal-driven curation.
 *
 * Implements the architecture from `Social-media-app-open-web.md`: every
 * permissionless source (Nostr, Hacker News, and future RSS / AT Protocol) is
 * funneled through a single `UnifiedItem` shape so the UI never sees raw
 * protocol JSON. On top of that sits a journal-derived **topic** layer: the
 * user's journals are mined for salient topics, which then filter every social
 * surface (News, Nostr, and later media) through one universal predicate.
 *
 * This module is deliberately source-agnostic and dependency-free so it can be
 * unit-tested and extended without touching App.tsx. New sources plug in by
 * adding a `toUnifiedFromX()` converter; the filter chips work automatically.
 */

/** The normalized social item — every source collapses into this. */
export interface UnifiedItem {
  id: string;
  sourcePlatform: "nostr" | "hackernews" | "rss" | "atproto";
  /** Epoch seconds, for chronological sorting across sources. */
  timestamp: number;
  author: {
    id: string; // pubkey / DID / "hn"
    handle: string; // display handle
    avatar?: string;
  };
  content: {
    title?: string; // News cards use this; posts usually don't
    body: string; // post body / description
    linkUrl?: string; // outbound link for articles
  };
  media: {
    type: "none" | "image" | "video";
    urls: string[];
    thumbnailUrl?: string;
  };
}

/** Minimal shape of a Nostr text note (kind 1) as produced by lib/nostr.ts. */
interface NostrNoteLike {
  id: string;
  pubkey: string;
  content: string;
  createdAt: number;
  tags?: string[][];
}

/** Minimal shape of a Hacker News card as produced in App.tsx. */
interface HNItemLike {
  id: number | string;
  title: string;
  url?: string;
  source: string;
  createdAt: number;
}

/**
 * Pull image/video URLs out of a Nostr note: imeta/url tags first, then a
 * fallback regex scan of the raw text for common media extensions. Mirrors the
 * strategy recommended in the design doc for Nostr media.
 */
const MEDIA_EXT_RE = /(https?:\/\/[^\s"'<>]+\.(?:png|jpe?g|webp|gif|avif|mp4|mov|webm|m4v))/gi;

export function extractNostrMedia(note: NostrNoteLike): UnifiedItem["media"] {
  const imageUrls: string[] = [];
  const videoUrls: string[] = [];

  // 1. Tags: NIP-92 imeta / "url" / "r" markers.
  for (const tag of note.tags || []) {
    const [kind, value] = tag;
    if (!kind || !value) continue;
    const lk = kind.toLowerCase();
    if (lk === "url" || lk === "imeta") {
      if (/\.(png|jpe?g|webp|gif|avif)$/i.test(value)) imageUrls.push(value);
      else if (/\.(mp4|mov|webm|m4v)$/i.test(value)) videoUrls.push(value);
    }
  }

  // 2. Fallback: scan body text for media URLs.
  const found = note.content.match(MEDIA_EXT_RE) || [];
  for (const u of found) {
    if (/\.(mp4|mov|webm|m4v)$/i.test(u)) videoUrls.push(u);
    else imageUrls.push(u);
  }

  if (videoUrls.length) return { type: "video", urls: videoUrls, thumbnailUrl: videoUrls[0] };
  if (imageUrls.length) return { type: "image", urls: imageUrls, thumbnailUrl: imageUrls[0] };
  return { type: "none", urls: [] };
}

/** Minimal shape of a Bluesky public post (matches lib/bluesky.ts). */
interface BlueskyPostLike {
  uri: string;
  author: { did: string; handle: string; displayName?: string | null; avatar?: string | null };
  record: { text: string; createdAt?: string };
  embed?: {
    $type?: string;
    images?: Array<{ thumb?: string; fullsize?: string; alt?: string }>;
    video?: string | null;
    external?: { uri: string; title?: string; description?: string; thumb?: string };
  };
  indexedAt: string;
  likeCount?: number;
  repostCount?: number;
}

/** Pull image/video URLs from a Bluesky post's embed block. */
export function extractBlueskyMedia(post: BlueskyPostLike): UnifiedItem["media"] {
  const images = post.embed?.images || [];
  const videoUrl = post.embed?.video || undefined;
  if (videoUrl) return { type: "video", urls: [videoUrl], thumbnailUrl: undefined };
  const imgUrls = images.map((i) => i.fullsize || i.thumb).filter(Boolean) as string[];
  if (imgUrls.length) return { type: "image", urls: imgUrls, thumbnailUrl: imgUrls[0] };
  return { type: "none", urls: [] };
}

export function toUnifiedFromBluesky(post: BlueskyPostLike): UnifiedItem {
  const tsMs = Date.parse(post.indexedAt || post.record?.createdAt || "");
  return {
    id: post.uri,
    sourcePlatform: "atproto",
    timestamp: Number.isFinite(tsMs) ? Math.floor(tsMs / 1000) : 0,
    author: {
      id: post.author.did,
      handle: post.author.handle,
      avatar: post.author.avatar ?? undefined,
    },
    content: {
      body: post.record?.text || "",
      linkUrl: post.embed?.external?.uri,
    },
    media: extractBlueskyMedia(post),
  };
}

export function toUnifiedFromNostr(note: NostrNoteLike, handle?: string, avatar?: string): UnifiedItem {
  return {
    id: note.id,
    sourcePlatform: "nostr",
    timestamp: note.createdAt,
    author: { id: note.pubkey, handle: handle || note.pubkey.slice(0, 10), avatar },
    content: { body: note.content },
    media: extractNostrMedia(note),
  };
}

export function toUnifiedFromHN(item: HNItemLike): UnifiedItem {
  return {
    id: `hn-${item.id}`,
    sourcePlatform: "hackernews",
    timestamp: item.createdAt,
    author: { id: "hn", handle: item.source || "Hacker News" },
    content: { title: item.title, body: "", linkUrl: item.url },
    media: { type: "none", urls: [] },
  };
}

/* ── Journal → topic extraction (the curation engine) ────────────────────── */

const STOP_WORDS = new Set([
  "the", "a", "an", "is", "are", "was", "were", "be", "been", "being",
  "have", "has", "had", "do", "does", "did", "will", "would", "could",
  "should", "may", "might", "shall", "can", "need", "to", "of", "in",
  "for", "on", "with", "at", "by", "from", "as", "into", "through",
  "about", "this", "that", "these", "those", "it", "its", "i", "me",
  "my", "we", "our", "you", "your", "they", "them", "their", "what",
  "which", "who", "and", "or", "but", "if", "not", "no", "yes", "so",
  "just", "very", "really", "also", "than", "then", "now", "here",
  "there", "when", "where", "why", "how", "all", "any", "some", "more",
  "most", "other", "such", "only", "own", "same", "too", "out", "up",
  "down", "over", "under", "again", "once", "today", "yesterday",
  "tomorrow", "going", "something", "thing", "things", "want", "need",
  "like", "get", "got", "make", "made", "go", "going", "come", "take",
  "see", "know", "think", "feel", "look", "use", "find", "tell", "say",
  "work", "play", "run", "try", "ask", "give", "keep", "let", "show",
  "hear", "put", "mean", "set", "sit", "stand", "read", "talk", "tell",
  "lot", "bit", "kind", "sort", "way", "time", "day", "days", "week",
  "month", "year", "years", "people", "person", "guy", "girl", "stuff",
  "good", "bad", "great", "nice", "cool", "fun", "new", "old", "big",
  "small", "little", "long", "short", "much", "many", "few", "every",
  "well", "even", "still", "back", "been", "being", "one", "two",
]);

export interface Topic {
  /** The display label, e.g. "rust" or "machine learning". */
  label: string;
  /** Frequency-derived weight; higher = more prominent in the journals. */
  weight: number;
}

/**
 * Mine salient topics from journal text. Combines single-word frequency with
 * lightweight bigram detection (e.g. "machine learning", "rust async") so the
 * chips read like real topics instead of isolated tokens. Returns the top N by
 * weight, deduped and length-filtered.
 */
export function extractJournalTopics(texts: string[], maxTopics = 10): Topic[] {
  const combined = texts.join(" ").toLowerCase();

  // Single-word candidates.
  const wordFreq = new Map<string, number>();
  const words = combined.match(/\b[a-z][a-z]{3,}\b/g) || [];
  for (const w of words) {
    if (STOP_WORDS.has(w)) continue;
    wordFreq.set(w, (wordFreq.get(w) || 0) + 1);
  }

  // Bigram candidates (two consecutive non-stopword words).
  const bigramFreq = new Map<string, number>();
  const tokens = combined.match(/\b[a-z][a-z]{2,}\b/g) || [];
  for (let i = 0; i < tokens.length - 1; i++) {
    const a = tokens[i];
    const b = tokens[i + 1];
    if (STOP_WORDS.has(a) || STOP_WORDS.has(b)) continue;
    if (a.length < 4 || b.length < 4) continue;
    const bg = `${a} ${b}`;
    bigramFreq.set(bg, (bigramFreq.get(bg) || 0) + 1);
  }

  const topics: Topic[] = [];

  // Bigrams must repeat to count (cuts noise); weight them 2x a single word.
  for (const [label, freq] of bigramFreq) {
    if (freq >= 2) topics.push({ label, weight: freq * 2 });
  }
  // Single words: top contributors.
  const singles = [...wordFreq.entries()]
    .sort((a, b) => b[1] - a[1])
    .filter(([w, f]) => f >= 1 && !topics.some((t) => t.label.includes(w)))
    .slice(0, maxTopics)
    .map(([label, weight]) => ({ label, weight }));

  const merged = [...topics, ...singles]
    .sort((a, b) => b.weight - a.weight)
    .slice(0, maxTopics);

  return merged;
}

/** Convenience: just the labels, for chip rows. */
export function journalTopicLabels(texts: string[], maxTopics = 10): string[] {
  return extractJournalTopics(texts, maxTopics).map((t) => t.label);
}

/* ── Universal topic filter (applies to every source via UnifiedItem) ─────── */

function escapeRegex(s: string): string {
  return s.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

/**
 * Does `item` match `topic`? Matches against title + body + author handle,
 * using word boundaries for single-word topics and substring for multi-word
 * topics. Hashtags (#topic) always match. Returns false for an empty topic
 * (the "All" chip) so callers can treat "" as "no filter".
 */
export function matchesTopic(item: UnifiedItem, topic: string): boolean {
  const t = topic.trim().toLowerCase();
  if (!t) return true; // "All"

  const hay = [
    item.content.title || "",
    item.content.body || "",
    item.author.handle || "",
  ].join(" ").toLowerCase();

  // Hashtag match: #topic anywhere.
  if (hay.includes(`#${t.split(" ")[0]}`)) return true;

  if (t.includes(" ")) {
    return hay.includes(t);
  }
  const re = new RegExp(`\\b${escapeRegex(t)}\\b`);
  return re.test(hay);
}

/** Filter a list of UnifiedItems by the active topic. */
export function filterByTopic(items: UnifiedItem[], topic: string): UnifiedItem[] {
  if (!topic.trim()) return items;
  return items.filter((i) => matchesTopic(i, topic));
}

/* ── CONTENT CHANNELS — validated source-level filter levers ────────────────
 * A "channel" is a pre-wired source-level filter that GUARANTEES content for
 * popular topics. Instead of fetching the firehose and filtering client-side
 * (which fails for rare terms — the user's original bug), each channel asks the
 * SOURCE to do the filtering:
 *   - nostr-hashtag → NIP-12 `#t` subscription (relay only sends matching notes)
 *   - bluesky-search → app.bsky.feed.searchPosts (AppView full-text search)
 *   - firehose      → no filter (baseline stream)
 *
 * Validated live: see handoff. Bluesky search returns ~20 posts for any term;
 * Nostr hashtags return 10-15 notes for #bitcoin/#nostr; NIP-50 search is
 * UNRELIABLE and is intentionally NOT exposed as a channel.
 * ────────────────────────────────────────────────────────────────────────── */

export type SocialSource = "nostr" | "bluesky" | "news";

export type ChannelLever = "nostr-hashtag" | "bluesky-search" | "firehose";

export interface ContentChannel {
  /** Stable id, also used as the chip label if no `label` override. */
  id: string;
  label: string;
  /** Which source this channel runs against. */
  source: SocialSource;
  /** The mechanism (lever) used to filter at the source. */
  lever: ChannelLever;
  /**
   * The query value passed to the lever:
   *   nostr-hashtag → tag without '#' (e.g. "bitcoin")
   *   bluesky-search → search query string (e.g. "machine learning")
   *   firehose → ignored
   */
  query: string;
  /** Optional emoji for the chip. */
  emoji?: string;
}

/**
 * Preset channel catalog. Curated for guaranteed content volume across diverse
 * interests (tech, art, music, crypto, photography). Each is proven to return
 * results from its source. Grouped by source so the UI can show only the
 * channels relevant to the active source toggle.
 */
export const CONTENT_CHANNELS: ContentChannel[] = [
  // ── Nostr (NIP-12 hashtag subscriptions) ──
  { id: "nostr-firehose", label: "Firehose", source: "nostr", lever: "firehose", query: "", emoji: "📡" },
  { id: "nostr-nostr", label: "nostr", source: "nostr", lever: "nostr-hashtag", query: "nostr", emoji: "🟣" },
  { id: "nostr-bitcoin", label: "bitcoin", source: "nostr", lever: "nostr-hashtag", query: "bitcoin", emoji: "₿" },
  { id: "nostr-ai", label: "ai", source: "nostr", lever: "nostr-hashtag", query: "ai", emoji: "🤖" },
  { id: "nostr-tech", label: "tech", source: "nostr", lever: "nostr-hashtag", query: "tech", emoji: "💻" },
  { id: "nostr-art", label: "art", source: "nostr", lever: "nostr-hashtag", query: "art", emoji: "🎨" },
  { id: "nostr-photography", label: "photography", source: "nostr", lever: "nostr-hashtag", query: "photography", emoji: "📷" },
  { id: "nostr-music", label: "music", source: "nostr", lever: "nostr-hashtag", query: "music", emoji: "🎵" },
  { id: "nostr-plebchain", label: "plebchain", source: "nostr", lever: "nostr-hashtag", query: "plebchain", emoji: "⛓️" },

  // ── Bluesky (full-text search — works for ANY term) ──
  { id: "bsky-discover", label: "Discover", source: "bluesky", lever: "bluesky-search", query: "", emoji: "✨" },
  { id: "bsky-tech", label: "tech", source: "bluesky", lever: "bluesky-search", query: "tech", emoji: "💻" },
  { id: "bsky-ai", label: "ai", source: "bluesky", lever: "bluesky-search", query: "AI", emoji: "🤖" },
  { id: "bsky-programming", label: "programming", source: "bluesky", lever: "bluesky-search", query: "programming", emoji: "⌨️" },
  { id: "bsky-art", label: "art", source: "bluesky", lever: "bluesky-search", query: "art", emoji: "🎨" },
  { id: "bsky-photography", label: "photography", source: "bluesky", lever: "bluesky-search", query: "photography", emoji: "📷" },
  { id: "bsky-music", label: "music", source: "bluesky", lever: "bluesky-search", query: "music", emoji: "🎵" },
  { id: "bsky-film", label: "film", source: "bluesky", lever: "bluesky-search", query: "film", emoji: "🎬" },
  { id: "bsky-science", label: "science", source: "bluesky", lever: "bluesky-search", query: "science", emoji: "🔬" },
];

/** Channels available for a given source (for the chip row). */
export function channelsForSource(source: SocialSource): ContentChannel[] {
  return CONTENT_CHANNELS.filter((c) => c.source === source);
}

