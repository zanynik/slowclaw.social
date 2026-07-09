/**
 * wot.ts — Web-of-Trust (WoT) seed set + feed ranking for the Nostr social feed.
 *
 * The default Nostr feed renders from the local SQLite store purely
 * chronologically (`ORDER BY created_at DESC`) — no relevance or trust signal.
 * This module computes a *trusted-pubkey set* from two sources and exposes a
 * strict "WoT-first" tier sort so notes from trusted authors rise above the
 * firehose, while recency still orders notes within each tier.
 *
 * Two seed sources, composed into one `Set<string>`:
 *
 *   Layer 1 — Follow graph (warm users):
 *     the user's app follows (follows.ts localStorage) + their own kind-3
 *     contact list fetched from relays, optionally 2-hop expanded.
 *
 *   Layer 2 — Cold-start curated seed (new users, or when follows are sparse):
 *     harvest NIP-51 follow sets (kind 30000) + Primal starter packs (39089),
 *     match list title/description against the user's journal keywords
 *     (`extractKeywordsFromJournals` — no client-side embeddings exist yet),
 *     then gate members by a reputation score (kind-7 likes received on a
 *     sample of their notes + kind-9735 zap-receipt COUNT, no bolt11/amount
 *     parsing, no new dependency).
 *
 * Everything runs client-side (the path the iOS Nostr feed actually uses — the
 * desktop-gateway embedding ranker never touches this feed). The set is cached
 * in localStorage (24h TTL) so the first paint is instant and relay fan-out is
 * bounded and backgrounded.
 */

import type { NostrEvent } from "./nostr";
import {
  fetchEventsByFilter,
  fetchNostrFollowSet,
  fetchReactionsForEvents,
  extractKeywordsFromJournals,
} from "./nostr";
import { getFollowedIds } from "./follows";

// ─── Relays ──────────────────────────────────────────────────────────────
// The kind-3/contact-list fetch in nostr.ts uses its own DEFAULT_RELAYS; we
// keep a parallel list here so WoT queries hit high-traffic public relays
// where curated lists (30000/39089) and kind-9735 zap receipts are published.
const WOT_RELAYS = [
  "wss://relay.damus.io",
  "wss://nos.lol",
  "wss://relay.nostr.band",
];

// ─── Bounds (mobile cost control) ────────────────────────────────────────
/** How many Tier-1 pubkeys we 2-hop expand. Caps relay fan-out. */
const MAX_TIER1_EXPANSION = 30;
/** Hard cap on the final WoT set size (bounds memory + lookup cost). */
const MAX_WOT_SET = 5000;
/** How many curated lists to harvest before keyword-matching. */
const LIST_HARVEST_LIMIT = 500;
/** How many keyword-matched lists to keep and read members from. */
const TOP_LISTS = 10;
/** Notes per candidate pulled for reputation scoring (like sampling). */
const REPUTATION_SAMPLE_NOTES = 5;
/** How many candidates we reputation-score at once (relay fan-out width). */
const REPUTATION_CONCURRENCY = 6;
/** Thresholds for a list member to survive reputation gating. */
const REPUTATION_MIN_ZAPS = 1;
const REPUTATION_MIN_LIKES = 2;

// ─── Cache (mirrors follows.ts: localStorage + CustomEvent) ──────────────

const WOT_CACHE_KEY = "slowclaw.wot.v1";
const WOT_EVENT_NAME = "slowclaw:wot-change";
const WOT_CACHE_TTL_MS = 24 * 60 * 60 * 1000; // 24h

interface CachedWoT {
  pubkeys: string[];
  builtAt: number;
}

/** Load the cached WoT set if it is fresher than `ttlMs`, else null. */
export function loadCachedWoTSet(ttlMs = WOT_CACHE_TTL_MS): Set<string> | null {
  if (typeof window === "undefined") return null;
  try {
    const raw = window.localStorage.getItem(WOT_CACHE_KEY);
    if (!raw) return null;
    const parsed = JSON.parse(raw) as Partial<CachedWoT>;
    if (
      !parsed ||
      typeof parsed.builtAt !== "number" ||
      !Array.isArray(parsed.pubkeys)
    ) {
      return null;
    }
    if (Date.now() - parsed.builtAt > ttlMs) return null;
    return new Set(parsed.pubkeys.filter((p) => typeof p === "string"));
  } catch {
    return null;
  }
}

function saveCachedWoTSet(set: Set<string>): void {
  if (typeof window === "undefined") return;
  try {
    const payload: CachedWoT = {
      pubkeys: [...set],
      builtAt: Date.now(),
    };
    window.localStorage.setItem(WOT_CACHE_KEY, JSON.stringify(payload));
    window.dispatchEvent(new CustomEvent(WOT_EVENT_NAME));
  } catch {
    // Quota / serialization errors are non-fatal; in-memory set still works.
  }
}

/** Subscribe to same-tab + cross-tab WoT refreshes. Returns an unsubscribe fn. */
export function onWoTChange(cb: () => void): () => void {
  if (typeof window === "undefined") return () => {};
  const handler = () => cb();
  const storageHandler = (e: StorageEvent) => {
    if (e.key === WOT_CACHE_KEY) handler();
  };
  window.addEventListener(WOT_EVENT_NAME, handler);
  window.addEventListener("storage", storageHandler);
  return () => {
    window.removeEventListener(WOT_EVENT_NAME, handler);
    window.removeEventListener("storage", storageHandler);
  };
}

// ─── Helpers ─────────────────────────────────────────────────────────────

/**
 * Run `task` over `items` with a bounded concurrency window.
 * Chunked `Promise.all` — no extra dependency, deterministic width.
 */
async function mapWithConcurrency<T, R>(
  items: readonly T[],
  width: number,
  task: (item: T) => Promise<R>,
): Promise<R[]> {
  const out: R[] = new Array(items.length);
  for (let i = 0; i < items.length; i += width) {
    const slice = items.slice(i, i + width);
    const results = await Promise.all(slice.map(task));
    for (let j = 0; j < results.length; j++) out[i + j] = results[j];
  }
  return out;
}

/** Extract the `["p", <pubkey>, ...]` member pubkeys from a list event. */
function listMembers(ev: NostrEvent): string[] {
  return (ev.tags || [])
    .filter((t) => t[0] === "p" && typeof t[1] === "string" && t[1])
    .map((t) => t[1] as string);
}

/**
 * Title/description text for a curated list. NIP-51 sets carry a human title
 * in the `name`/`title` tag; some pack formats put it in the content JSON.
 */
function listText(ev: NostrEvent): string {
  const parts: string[] = [];
  for (const t of ev.tags || []) {
    if ((t[0] === "name" || t[0] === "title") && typeof t[1] === "string") {
      parts.push(t[1]);
    }
  }
  if (ev.content) {
    try {
      const raw = JSON.parse(ev.content) as Record<string, unknown>;
      for (const k of ["name", "title", "description", "about"]) {
        if (typeof raw[k] === "string") parts.push(raw[k] as string);
      }
    } catch {
      // Plain-text content (some sets use raw prose) is still useful for keywords.
      parts.push(ev.content);
    }
  }
  return parts.join(" ").toLowerCase();
}

// ─── Cold-start: curated list discovery + reputation gating ──────────────

/** Tokenize a string into lowercase 4+ char words for overlap matching. */
function tokenize(text: string): Set<string> {
  return new Set(text.toLowerCase().match(/\b[a-z0-9]{4,}\b/g) || []);
}

/** Count keyword hits a list has against the user's journal keywords. */
function scoreListByKeywords(list: NostrEvent, journalKeywords: string[]): number {
  if (journalKeywords.length === 0) return 0;
  const tokens = tokenize(listText(list));
  if (tokens.size === 0) return 0;
  let hits = 0;
  for (const kw of journalKeywords) {
    if (tokens.has(kw.toLowerCase())) hits++;
  }
  return hits;
}

interface ReputationScore {
  likes: number;
  zaps: number;
}

/**
 * Reputation for a batch of candidate pubkeys: like-count (kind-7 reactors on
 * a sample of their notes) + zap-count (kind-9735 receipts COUNT).
 *
 * No bolt11/amount parsing — only counts, so no Lightning library dependency.
 * Likes reuse fetchReactionsForEvents (which already skips NIP-25 dislikes).
 */
async function scoreReputation(
  candidates: string[],
): Promise<Map<string, ReputationScore>> {
  const scores = new Map<string, ReputationScore>();
  if (candidates.length === 0) return scores;

  // 1) Likes: sample each candidate's recent notes, then count reactors.
  // `authors` queries are per-pubkey, so we fan out (bounded) per candidate.
  const perCandidateNotes = await mapWithConcurrency(
    candidates,
    REPUTATION_CONCURRENCY,
    async (pk): Promise<{ pk: string; noteIds: string[] }> => {
      try {
        const notes = await fetchEventsByFilter(
          { kinds: [1], authors: [pk], limit: REPUTATION_SAMPLE_NOTES },
          { relays: WOT_RELAYS, timeoutMs: 6000 },
        );
        return { pk, noteIds: notes.map((n) => n.id) };
      } catch {
        return { pk, noteIds: [] };
      }
    },
  );

  const likeCounts = new Map<string, number>();
  for (const { pk, noteIds } of perCandidateNotes) {
    if (noteIds.length === 0) {
      likeCounts.set(pk, 0);
      continue;
    }
    try {
      const reactors = await fetchReactionsForEvents(noteIds, { relays: WOT_RELAYS });
      const total = [...reactors.values()].reduce((a, b) => a + b, 0);
      likeCounts.set(pk, total);
    } catch {
      likeCounts.set(pk, 0);
    }
  }

  // 2) Zaps: COUNT of kind-9735 receipts tagged with each candidate (#p).
  // Query in one batch by candidate pubkeys; dedupe receipts by reactor so a
  // single zapper can't inflate a member's score.
  const zapCounts = new Map<string, number>();
  try {
    // Relay `#p` filters accept an array; cap the candidate batch to stay sane.
    const batch = candidates.slice(0, 100);
    const receipts = await fetchEventsByFilter(
      { kinds: [9735], "#p": batch, limit: 400 },
      { relays: WOT_RELAYS, timeoutMs: 7000 },
    );
    const perRecipient = new Map<string, Set<string>>(); // pk -> unique zappers
    for (const ev of receipts) {
      for (const t of ev.tags || []) {
        if (t[0] !== "p" || typeof t[1] !== "string") continue;
        const recipient = t[1];
        const set = perRecipient.get(recipient) ?? new Set<string>();
        set.add(ev.pubkey); // the zapper
        perRecipient.set(recipient, set);
      }
    }
    for (const [pk, zappers] of perRecipient) zapCounts.set(pk, zappers.size);
  } catch {
    // Relay may not support kind-9735; zaps just stay 0 (likes still gate).
  }

  for (const pk of candidates) {
    scores.set(pk, {
      likes: likeCounts.get(pk) ?? 0,
      zaps: zapCounts.get(pk) ?? 0,
    });
  }
  return scores;
}

/**
 * Cold-start seed: when the user has few/no follows, discover vetted authors
 * from curated lists matching their journal keywords. Members pass a reputation
 * gate (≥1 zap OR ≥2 likes) so spam-list members can't enter the seed set.
 *
 * Returns an empty set when there are no journal keywords to match against
 * (no signal to rank lists by).
 */
export async function discoverCuratedSeed(
  journalTexts: string[],
): Promise<Set<string>> {
  const journalKeywords = extractKeywordsFromJournals(journalTexts);
  if (journalKeywords.length === 0) return new Set<string>();

  // Harvest curated lists (NIP-51 follow sets + Primal starter packs).
  let lists: NostrEvent[];
  try {
    lists = await fetchEventsByFilter(
      { kinds: [30000, 39089], limit: LIST_HARVEST_LIMIT },
      { relays: WOT_RELAYS, timeoutMs: 9000 },
    );
  } catch {
    return new Set<string>();
  }

  // Keyword-rank lists, keep the top matches.
  const ranked = lists
    .map((ev) => ({ ev, score: scoreListByKeywords(ev, journalKeywords) }))
    .filter((x) => x.score > 0)
    .sort((a, b) => b.score - a.score)
    .slice(0, TOP_LISTS);

  if (ranked.length === 0) return new Set<string>();

  // Collect candidate members across the kept lists.
  const candidateSet = new Set<string>();
  for (const { ev } of ranked) {
    for (const pk of listMembers(ev)) candidateSet.add(pk);
    if (candidateSet.size >= MAX_WOT_SET) break;
  }
  if (candidateSet.size === 0) return new Set<string>();

  // Gate by reputation.
  const candidates = [...candidateSet];
  const scores = await scoreReputation(candidates);
  const seed = new Set<string>();
  for (const pk of candidates) {
    const s = scores.get(pk);
    if (!s) continue;
    if (s.zaps >= REPUTATION_MIN_ZAPS || s.likes >= REPUTATION_MIN_LIKES) {
      seed.add(pk);
      if (seed.size >= MAX_WOT_SET) break;
    }
  }
  return seed;
}

// ─── WoT set builder ─────────────────────────────────────────────────────

export interface BuildWoTSetOptions {
  /** The user's own Nostr pubkey (hex). Required for the kind-3 fetch. */
  ownPubkey: string;
  /** Journal texts to derive cold-start keywords from. */
  journalTexts?: string[];
  /** Skip the cold-start layer (warm users who already have follows). */
  skipColdStart?: boolean;
}

/**
 * Build the trusted-pubkey set.
 *
 *   Tier 1 — user's app follows + own kind-3 contact list.
 *   Cold-start — curated-list members (only when Tier 1 is sparse and journal
 *     keywords exist).
 *   Tier 2 — 2-hop expansion of a capped Tier-1 subset (only if still sparse).
 *
 * Returns the union, capped at MAX_WOT_SET.
 */
export async function buildWoTSet(
  opts: BuildWoTSetOptions,
): Promise<Set<string>> {
  const wot = new Set<string>();

  // Tier 1a: app follows (localStorage, optimistic follow store).
  for (const id of getFollowedIds()) {
    if (id.startsWith("nostr:")) wot.add(id.slice("nostr:".length));
  }

  // Tier 1b: own kind-3 contact list (captures follows made outside the app).
  try {
    const ownFollows = await fetchNostrFollowSet(opts.ownPubkey, WOT_RELAYS);
    for (const pk of ownFollows) wot.add(pk);
  } catch {
    // No kind-3 reachable — proceed with whatever Tier 1a gave us.
  }

  // Cold-start seed: only when the follow graph is sparse, and not disabled.
  const COLD_START_THRESHOLD = 10;
  const needsColdStart =
    !opts.skipColdStart &&
    wot.size < COLD_START_THRESHOLD &&
    (opts.journalTexts?.length ?? 0) > 0;
  if (needsColdStart) {
    try {
      const seed = await discoverCuratedSeed(opts.journalTexts ?? []);
      for (const pk of seed) {
        wot.add(pk);
        if (wot.size >= MAX_WOT_SET) return wot;
      }
    } catch {
      // Cold-start is best-effort; the graph still ranks if it failed.
    }
  }

  // Tier 2: 2-hop expansion of a capped Tier-1 subset, only if still sparse.
  const TWO_HOP_THRESHOLD = 25;
  if (wot.size > 0 && wot.size < TWO_HOP_THRESHOLD) {
    const roots = [...wot].slice(0, MAX_TIER1_EXPANSION);
    const expansions = await mapWithConcurrency(
      roots,
      REPUTATION_CONCURRENCY,
      async (pk): Promise<string[]> => {
        try {
          return await fetchNostrFollowSet(pk, WOT_RELAYS);
        } catch {
          return [];
        }
      },
    );
    for (const follows of expansions) {
      for (const pk of follows) {
        wot.add(pk);
        if (wot.size >= MAX_WOT_SET) return wot;
      }
    }
  }

  return wot;
}

/**
 * Build → cache → notify. Returns the fresh set so the caller can apply it
 * without waiting for the cache-read + event round-trip.
 */
export async function refreshWoTSet(
  opts: BuildWoTSetOptions,
): Promise<Set<string>> {
  const set = await buildWoTSet(opts);
  saveCachedWoTSet(set);
  return set;
}

// ─── Ranking (pure) ──────────────────────────────────────────────────────

export interface WoTAccessors<T> {
  pubkey: (item: T) => string;
  createdAt: (item: T) => number;
}

/**
 * Strict WoT-first tier sort: notes from authors in `wotSet` sort first
 * (newest-first within the tier), then non-members (newest-first). Stable on
 * ties. An empty `wotSet` leaves order unchanged (cold-start safe — a user
 * with no graph keeps the chronological feed they have today).
 *
 * Generic with accessors so it applies to both `NostrNote` (createdAt field)
 * and any future unified shape without ad-hoc remapping at the call site.
 */
export function sortByWoTFirst<T>(
  items: readonly T[],
  wotSet: ReadonlySet<string>,
  accessors: WoTAccessors<T>,
): T[] {
  if (wotSet.size === 0) return [...items];
  const { pubkey: pkOf, createdAt: tsOf } = accessors;
  // Two-bucket stable sort: WoT members above non-members, recency within each.
  const members = items.filter((n) => wotSet.has(pkOf(n)));
  const others = items.filter((n) => !wotSet.has(pkOf(n)));
  const byRecency = (a: T, b: T) => tsOf(b) - tsOf(a);
  members.sort(byRecency);
  others.sort(byRecency);
  return [...members, ...others];
}
