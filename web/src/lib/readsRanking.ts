/**
 * readsRanking.ts — journal-driven client-side ranking + read-time for Reads.
 *
 * "For You" means *for this user*: their own journals are mined for salient
 * topics (extractJournalTopics, lib/socialFeed.ts), and an article matching one
 * of those topics gets a strong boost that outranks generic recency. This is
 * the "journal is the lens" signal made concrete for the Reads stream.
 *
 * score = topicBoost + recencyDecay + imageBonus + readTimeBonus + lengthTiebreak.
 * With no journal topics (cold start / empty journals) topicBoost is 0 and the
 * ranker degrades gracefully to pure recency/quality.
 *
 * Consumes the existing `UnifiedItem` shape from socialFeed.ts so Nostr
 * articles and RSS items collapse into one ranked stream.
 */

import { matchesTopic, type Topic, type UnifiedItem } from "./socialFeed";

/** A scored item: the unified record plus its computed score + read-time. */
export interface RankedRead {
  item: UnifiedItem;
  /** Higher = more prominent. Range depends on inputs; up to ~2.5 when a strong journal-topic match is present. */
  score: number;
  /** Estimated read time in whole minutes (min 1). */
  readMinutes: number;
  /** Source label for grouping (RSS feed title, "Nostr", etc.). */
  sourceLabel: string;
}

/* ── Read-time estimation ───────────────────────────────────────────────── */

const WORDS_PER_MINUTE = 220;

/** Count words in plain text (HTML already stripped at the UnifiedItem layer). */
export function countWords(text: string): number {
  const t = (text || "").trim();
  if (!t) return 0;
  return t.split(/\s+/).filter(Boolean).length;
}

/** Estimate read time in minutes, floored to 1. */
export function estimateReadMinutes(text: string): number {
  return Math.max(1, Math.round(countWords(text) / WORDS_PER_MINUTE));
}

/* ── Scoring ────────────────────────────────────────────────────────────── */

const RECENCY_HALF_LIFE_HOURS = 36; // fresh wins, but a 3-day piece can still surface
const NOW = () => Date.now() / 1000;

/* ── Journal-driven relevance (the lens) ──────────────────────────────────
 * These weights make journal-topic match the DOMINANT signal: a relevant
 * article outranks a generic-fresh one, and a strong older relevant piece can
 * still surface (the product thesis welcomes evergreen relevant content).
 * Magnitudes:
 *   - matching the user's most-written topic  → +0.8
 *   - each additional matched topic            → +0.3
 *   - total topic boost capped at              → +1.2
 * Recency (≤1.0) + quality (≤0.35) stay as within-relevance tiebreakers.
 * With no topics passed, journalTopicBoost returns 0 (pure-recency fallback).
 */
const TOPIC_MATCH_TOP = 0.8;
const TOPIC_MATCH_EACH = 0.3;
const TOPIC_MATCH_CAP = 1.2;

/**
 * Journal-derived relevance boost. `topics` are the user's own journal topics
 * (label + weight, from extractJournalTopics); the strongest-weighted matched
 * topic counts most, additional matches stack (capped). Uses the same
 * `matchesTopic` predicate as the Feed topic chips so the lens is consistent
 * across surfaces. Returns 0 when there are no topics (cold start).
 */
function journalTopicBoost(item: UnifiedItem, topics: Topic[]): number {
  if (!topics.length) return 0;
  const ranked = [...topics].sort((a, b) => b.weight - a.weight);
  let boost = 0;
  let first = true;
  for (const t of ranked) {
    if (matchesTopic(item, t.label)) {
      boost += first ? TOPIC_MATCH_TOP : TOPIC_MATCH_EACH;
      first = false;
      if (boost >= TOPIC_MATCH_CAP) return TOPIC_MATCH_CAP;
    }
  }
  return boost;
}

/**
 * Score a single item. Components:
 *   topicBoost   — journal-derived relevance (dominant; 0 when no topics given)
 *   recency      — exponential decay (1 at t=now, ~0.5 at 36h, ~0.13 at 3 days)
 *   imageBonus   — +0.15 if a cover/thumbnail is present
 *   readTimeBonus — +0.05..0.15 for a 3..15 min read (the Goldilocks zone)
 *   lengthTiebreak — tiny bonus for substantive summaries (proxy for depth)
 */
export function scoreRead(
  item: UnifiedItem,
  topics?: Topic[],
): { score: number; readMinutes: number } {
  const now = NOW();
  const ageHours = Math.max(0, (now - item.timestamp) / 3600);
  const recency = Math.pow(0.5, ageHours / RECENCY_HALF_LIFE_HOURS);

  const hasImage = item.media.type === "image" && !!item.media.thumbnailUrl;
  const imageBonus = hasImage ? 0.15 : 0;

  const readMinutes = estimateReadMinutes(
    item.content.body || item.content.title || "",
  );
  let readTimeBonus = 0;
  if (readMinutes >= 3 && readMinutes <= 15) readTimeBonus = 0.15;
  else if (readMinutes >= 2 && readMinutes <= 20) readTimeBonus = 0.05;

  const lengthTiebreak = Math.min(0.05, item.content.body.length / 5000);
  const topicBoost = topics && topics.length ? journalTopicBoost(item, topics) : 0;

  return {
    score: topicBoost + recency + imageBonus + readTimeBonus + lengthTiebreak,
    readMinutes,
  };
}

/**
 * Rank a list of unified items, highest score first. Stable on ties (keeps
 * input order). Pass the user's journal `topics` to make "For You" journal-
 * driven; omit them for pure recency/quality ranking.
 */
export function rankReads(items: UnifiedItem[], topics?: Topic[]): RankedRead[] {
  const scored = items.map((item) => {
    const { score, readMinutes } = scoreRead(item, topics);
    const sourceLabel =
      item.sourcePlatform === "rss"
        ? item.author.handle
        : item.sourcePlatform === "nostr"
        ? "Nostr"
        : item.author.handle || "Source";
    return { item, score, readMinutes, sourceLabel };
  });
  scored.sort((a, b) => b.score - a.score);
  return scored;
}

/** Chronological (newest-first) variant for the "Latest" toggle. */
export function chronologicalReads(items: UnifiedItem[]): RankedRead[] {
  const out = items.map((item) => {
    const { score, readMinutes } = scoreRead(item);
    const sourceLabel =
      item.sourcePlatform === "rss"
        ? item.author.handle
        : item.sourcePlatform === "nostr"
        ? "Nostr"
        : item.author.handle || "Source";
    return { item, score, readMinutes, sourceLabel };
  });
  out.sort((a, b) => b.item.timestamp - a.item.timestamp);
  return out;
}

/* ── Social quality gate (the reputation pipeline) ──────────────────────────
 *
 * Social content is the noisiest source: spam, bots, drive-by takes. Unlike
 * articles (already curated by an editor/RSS feed) or YouTube (channel-curated),
 * a Nostr/Bluesky firehose needs a quality gate BEFORE it competes for a ranked
 * slot — otherwise noise floods the stream and drowns the journal-relevant
 * signal. This is the "hardest to rank" tier from the product thesis.
 *
 * The gate is an admission filter, not a ranker. A social post earns a slot if
 * its author is trusted (web-of-trust) OR it (or its author) drew real
 * community engagement (likes + zaps). Everything admitted then goes through
 * the same journal-driven `rankReads` as articles — interest match dominates
 * ordering from there. This separates "is this worth a shot" (gate) from "how
 * high" (ranker), which is the right separation for noisy sources.
 */

export interface SocialGateContext {
  /** Trusted author ids (follow graph / WoT seed). Admits their posts outright. */
  wotSet: ReadonlySet<string>;
  /** Per-post engagement: UnifiedItem.id → likes + zaps count. */
  postEngagement: ReadonlyMap<string, number>;
  /** Per-author total engagement: author id → summed likes + zaps in batch. */
  authorEngagement: ReadonlyMap<string, number>;
  /** Author id accessor for a UnifiedItem. */
  authorId: (item: UnifiedItem) => string;
}

export interface SocialGateOptions {
  /** Min per-post engagement to admit on its own (community-vetted post). */
  minPostEngagement?: number;
  /** Min per-author engagement to admit ("reputed profile" by aggregate signal). */
  minAuthorEngagement?: number;
  /** Cold-start floor: if fewer than this pass, top up by engagement then recency
   *  so the stream isn't empty before WoT/reactions are warm. */
  coldStartCap?: number;
}

const DEFAULT_MIN_POST_ENGAGEMENT = 1;
const DEFAULT_MIN_AUTHOR_ENGAGEMENT = 2;
const DEFAULT_COLD_START_CAP = 12;

/** Is a post admitted by the reputation gate (WoT or engagement)? */
export function isSocialPostAdmitted(
  item: UnifiedItem,
  ctx: SocialGateContext,
  minPostEngagement: number,
  minAuthorEngagement: number,
): boolean {
  const author = ctx.authorId(item);
  if (ctx.wotSet.has(author)) return true; // trusted author
  if ((ctx.postEngagement.get(item.id) || 0) >= minPostEngagement) return true; // vetted post
  if ((ctx.authorEngagement.get(author) || 0) >= minAuthorEngagement) return true; // reputed profile
  return false;
}

/**
 * Gate a list of social UnifiedItems through the reputation pipeline. Admits
 * posts whose author is in the WoT, OR which earned engagement (post- or
 * author-level). Applies a cold-start floor so an empty WoT / unloaded
 * reactions don't blank the stream: if too few pass, top up by engagement then
 * recency. Stable on ties.
 */
export function gateSocialItems(
  items: UnifiedItem[],
  ctx: SocialGateContext,
  opts: SocialGateOptions = {},
): UnifiedItem[] {
  const minPost = opts.minPostEngagement ?? DEFAULT_MIN_POST_ENGAGEMENT;
  const minAuthor = opts.minAuthorEngagement ?? DEFAULT_MIN_AUTHOR_ENGAGEMENT;
  const coldCap = opts.coldStartCap ?? DEFAULT_COLD_START_CAP;

  const admitted: UnifiedItem[] = [];
  const dropped: UnifiedItem[] = [];
  for (const item of items) {
    if (isSocialPostAdmitted(item, ctx, minPost, minAuthor)) admitted.push(item);
    else dropped.push(item);
  }

  // Cold-start top-up: keep a modest stream alive before enrichment is warm.
  if (admitted.length < coldCap && dropped.length > 0) {
    const need = coldCap - admitted.length;
    const now = NOW();
    const topup = dropped
      .map((item) => ({
        item,
        key:
          (ctx.postEngagement.get(item.id) || 0) * 1_000_000 +
          (ctx.authorEngagement.get(ctx.authorId(item)) || 0) +
          // tiebreak: recency (newer first) so a cold stream isn't all stale
          (Math.max(0, now - item.timestamp) / 1_000_000),
      }))
      .sort((a, b) => b.key - a.key)
      .slice(0, need)
      .map((x) => x.item);
    admitted.push(...topup);
  }
  return admitted;
}

/* ── Bluesky reply-count admission (parent posts only) ────────────────────────
 *
 * The product intent is to keep the social stream discussion-driven: a lone
 * Bluesky post with no community response adds noise to a journal-ranked Reads
 * feed. Bluesky is the only social source that surfaces a reliable reply count
 * at feed-build time (it's server-supplied on the AppView post object), so this
 * is a Bluesky-specific gate. Nostr reply counts are only known after loading
 * each thread on tap (no native count on the note itself), so pre-fetching them
 * for the whole firehose would be a costly mobile hit; Nostr stays on its
 * reputation gate (`gateSocialItems`) instead.
 *
 * This applies to ANY post (root or reply) whose replyCount meets the floor —
 * a reply that itself sparked a sub-thread is still a discussion worth surfacing.
 */
export const DEFAULT_MIN_BLUESKY_REPLIES = 5;

/**
 * Keep only Bluesky posts whose server-supplied `replyCount` meets the floor.
 * Posts without a replyCount are dropped (treated as 0). Pure + typed so it can
 * be reasoned about independently of the fetch path.
 */
export function filterBlueskyByReplies<T extends { replyCount?: number }>(
  posts: T[],
  minReplies: number = DEFAULT_MIN_BLUESKY_REPLIES,
): T[] {
  return posts.filter((p) => (p.replyCount ?? 0) >= minReplies);
}

/* ── Unified feed ranking (social: text / image / video) ──────────────────── */
//
// The Reads scorer above favors long-form (read-time Goldilocks). The unified
// social feed wants a different bias: keep recency dominant, reward media
// richness so images/video surface, but lightly nudge text posts above equally
// fresh media posts (text drives discussion; a pure media sort buries it). This
// is the ranker behind the merged Feed tab (text + image + video interleaved).

/** A scored social item: the unified record plus its computed score. */
export interface RankedFeedItem {
  item: UnifiedItem;
  /** Higher = more prominent. */
  score: number;
}

/**
 * Media weight for the unified feed. Video and image posts get a small boost so
 * the merged feed stays visually varied; text stays competitive via recency.
 */
function mediaBonus(item: UnifiedItem): number {
  switch (item.media.type) {
    case "video":
      return 0.12;
    case "image":
      return 0.08;
    default:
      return 0;
  }
}

/**
 * Light text bias: posts with no media get a tiny nudge so a flood of image
 * posts doesn't bury discussion. Combined with mediaBonus, a fresh text post
 * ranks above an equally-fresh image post, but a video post can still overtake
 * a stale text post via recency decay.
 */
const TEXT_BIAS = 0.03;

/**
 * Score a unified item for the social feed. Components:
 *   recency  — exponential decay (same 36h half-life as reads)
 *   media    — +0.12 video, +0.08 image
 *   textBias — +0.03 for media-less posts (discussion-first)
 *   length   — tiny tiebreak against near-empty posts
 */
export function scoreUnifiedItem(item: UnifiedItem): number {
  const now = NOW();
  const ageHours = Math.max(0, (now - item.timestamp) / 3600);
  const recency = Math.pow(0.5, ageHours / RECENCY_HALF_LIFE_HOURS);
  const media = mediaBonus(item);
  const text = item.media.type === "none" ? TEXT_BIAS : 0;
  // Discourage near-empty / spammy one-liners: small positive bias for
  // substantive bodies, no penalty floor so genuinely empty items still score.
  const length = Math.min(0.04, (item.content.body || "").length / 1000);
  return recency + media + text + length;
}

/** Rank social items by score, highest first. Stable on ties. */
export function rankFeed(items: UnifiedItem[]): RankedFeedItem[] {
  const scored = items.map((item) => ({ item, score: scoreUnifiedItem(item) }));
  scored.sort((a, b) => b.score - a.score);
  return scored;
}

/** Chronological (newest-first) variant of the unified feed. */
export function chronologicalFeed(items: UnifiedItem[]): RankedFeedItem[] {
  const out = items.map((item) => ({ item, score: scoreUnifiedItem(item) }));
  out.sort((a, b) => b.item.timestamp - a.item.timestamp);
  return out;
}

/* ── On-device AI re-rank blend ──────────────────────────────────────────────
 *
 * The base ranker (rankReads) is journal-driven but operates on keyword/topic
 * matching alone — it can't read a post and judge semantic relevance. When the
 * on-device model is available, a background pass scores each Reads item's
 * relevance to the user's journals and produces a 0..1 boost per item id. This
 * pure function blends that boost into the already-ranked list and re-sorts.
 *
 * Weight is tuned so a top AI score (1.0) can lift a stale-but-relevant item
 * above a fresh-but-generic one (recency contributes ≤1.0), but cannot bury a
 * strong journal-topic match (which contributes up to ~1.2). Items without a
 * boost keep their base score untouched.
 */
export const AI_BOOST_WEIGHT = 0.6;

/**
 * Blend an async AI relevance boost (0..1 per item id) into a ranked list.
 * Returns a new array, re-sorted by blended score descending, stable on ties.
 * Items whose id isn't in `boost` keep their original score.
 */
export function applyAiRankBoost(
  ranked: RankedRead[],
  boost: ReadonlyMap<string, number>,
  weight: number = AI_BOOST_WEIGHT,
): RankedRead[] {
  if (boost.size === 0) return ranked;
  const blended = ranked.map((r) => ({
    ...r,
    score: r.score + weight * clamp01(boost.get(r.item.id) ?? 0),
  }));
  blended.sort((a, b) => b.score - a.score);
  return blended;
}

function clamp01(n: number): number {
  if (!Number.isFinite(n)) return 0;
  return n < 0 ? 0 : n > 1 ? 1 : n;
}

