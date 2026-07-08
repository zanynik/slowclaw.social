/**
 * readsRanking.ts — lightweight client-side ranking + read-time for the Reads tab.
 *
 * Mirrors the "For You" idea from Google News / Substack without any backend:
 * score = recencyDecay + imageBonus + readTimeBonus + lengthTiebreak. Fresh,
 * illustrated, medium-length articles win; nothing is buried purely on age.
 *
 * Consumes the existing `UnifiedItem` shape from socialFeed.ts so Nostr
 * articles and RSS items collapse into one ranked stream.
 */

import type { UnifiedItem } from "./socialFeed";

/** A scored item: the unified record plus its computed score + read-time. */
export interface RankedRead {
  item: UnifiedItem;
  /** Higher = more prominent. Roughly 0..1.3 range with current weights. */
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

/**
 * Score a single item. Components:
 *   recency      — exponential decay (1 at t=now, ~0.5 at 36h, ~0.13 at 3 days)
 *   imageBonus   — +0.15 if a cover/thumbnail is present
 *   readTimeBonus — +0.05..0.15 for a 3..15 min read (the Goldilocks zone)
 *   lengthTiebreak — tiny bonus for substantive summaries (proxy for depth)
 */
export function scoreRead(item: UnifiedItem): { score: number; readMinutes: number } {
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

  return { score: recency + imageBonus + readTimeBonus + lengthTiebreak, readMinutes };
}

/** Rank a list of unified items, highest score first. Stable on ties (keeps input order). */
export function rankReads(items: UnifiedItem[]): RankedRead[] {
  const scored = items.map((item) => {
    const { score, readMinutes } = scoreRead(item);
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
