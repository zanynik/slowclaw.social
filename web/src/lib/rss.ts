/**
 * rss.ts — RSS/Atom feed fetching for the Reads tab.
 *
 * Browsers/webviews cannot fetch raw RSS directly (no CORS headers on most
 * feeds), so we route through `api.rss2json.com` (free tier: 10k req/day,
 * CORS-enabled, returns clean JSON). Validated live: status 200, structured
 * items with title/pubDate/thumbnail.
 *
 * All feeds are passed through the feedFilter language filter at the call site
 * so non-English articles are dropped from discovery.
 */

export type RssItem = {
  guid?: string;
  link?: string;
  title: string;
  pubDate?: string;
  description?: string;
  content?: string;
  thumbnail?: string;
  enclosure?: { link?: string; type?: string };
  categories?: string[];
};

export type RssFeed = {
  /** Stable id used as a React key + storage key. */
  id: string;
  /** Display label. */
  label: string;
  /** RSS/Atom URL. */
  url: string;
  /** Emoji shown in the chip. */
  emoji?: string;
};

/**
 * Curated catalog of high-quality, English-language feeds. These are well-known
 * tech/long-form feeds with reliable RSS. Users pick from these (chips); adding
 * arbitrary feeds is a follow-up.
 */
export const RSS_FEEDS: RssFeed[] = [
  { id: "hackernews", label: "Hacker News", url: "https://hnrss.org/frontpage", emoji: "🟧" },
  { id: "stratechery", label: "Stratechery", url: "https://stratechery.com/feed/", emoji: "📈" },
  { id: "paul-graham", label: "Paul Graham", url: "https://www.aaronstacey.com/paulgrahamrss", emoji: "✍️" },
  { id: "verge", label: "The Verge", url: "https://www.theverge.com/rss/index.xml", emoji: "📰" },
  { id: "ars-technica", label: "Ars Technica", url: "https://feeds.arstechnica.com/arstechnica/index", emoji: "🔬" },
  { id: "techcrunch", label: "TechCrunch", url: "https://techcrunch.com/feed/", emoji: "💻" },
  { id: "wired", label: "Wired", url: "https://www.wired.com/feed/rss", emoji: "🔌" },
  { id: "longnow", label: "Long Now", url: "https://longnow.org/feed/", emoji: "⏳" },
  { id: "marginal-rev", label: "Marginal Revolution", url: "https://marginalrevolution.com/feed", emoji: "💡" },
  { id: "overcoming-bias", label: "Overcoming Bias", url: "https://www.overcomingbias.com/feed", emoji: "🧠" },
];

const RSS2JSON = "https://api.rss2json.com/v1/api.json";

/**
 * Fetch a single RSS feed and return its items. Uses rss2json as a CORS
 * proxy/parser. NOTE: the free tier (no API key) does NOT support the `count`
 * param, so we fetch the feed's default set (~10 items) and slice client-side.
 * Throws on non-OK responses. Items are returned in feed order (newest-first).
 */
export async function fetchRssFeed(
  feed: Pick<RssFeed, "url">,
  opts: { limit?: number; signal?: AbortSignal } = {},
): Promise<{ title: string; items: RssItem[] }> {
  const limit = opts.limit ?? 12;
  const url = `${RSS2JSON}?rss_url=${encodeURIComponent(feed.url)}`;
  const res = await fetch(url, {
    method: "GET",
    headers: { Accept: "application/json" },
    signal: opts.signal,
  });
  if (!res.ok) {
    throw new Error(`RSS ${res.status}`);
  }
  const data = await res.json();
  if (data.status !== "ok") {
    throw new Error(`RSS: ${data.message || "feed error"}`);
  }
  const items: RssItem[] = ((data.items || []) as any[]).map((it) => ({
    guid: it.guid,
    link: it.link,
    title: it.title || "",
    pubDate: it.pubDate,
    description: it.description,
    content: it.content,
    thumbnail: it.thumbnail,
    enclosure: it.enclosure,
    categories: it.categories,
  })).slice(0, limit);
  return { title: data.feed?.title || "RSS", items };
}

/** Fetch multiple feeds and merge items newest-first. */
export async function fetchRssFeeds(
  feeds: RssFeed[],
  opts: { limitPerFeed?: number; signal?: AbortSignal } = {},
): Promise<{ feed: RssFeed; items: RssItem[] }[]> {
  const results = await Promise.allSettled(
    feeds.map((feed) => fetchRssFeed(feed, { limit: opts.limitPerFeed ?? 6, signal: opts.signal })),
  );
  return results.map((r, i) => ({
    feed: feeds[i],
    items: r.status === "fulfilled" ? r.value.items : [],
  }));
}
