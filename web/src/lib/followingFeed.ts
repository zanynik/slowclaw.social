/**
 * followingFeed.ts — build a merged "Following" home timeline from the local
 * follows store. This is the Twitter/Bluesky home-timeline experience: the
 * newest posts from the authors the user follows, across both Nostr and Bluesky.
 *
 * Sources are read permissionlessly:
 *   - Nostr: a single multi-author relay query (`authors: [pubkey, ...]`).
 *   - Bluesky: N parallel `getAuthorFeed` calls (one per followed actor), since
 *     there is no anonymous batched timeline API. Fan-out + dedupe-by-uri, like
 *     the existing reels feed fan-out.
 *
 * Both are normalized to `UnifiedItem` (from socialFeed.ts) so the caller can
 * interleave them by timestamp and render with the existing card renderers.
 *
 * No writes, no auth needed for reads. Best-effort: relay/API failures are
 * tolerated — whatever arrived is returned.
 */

import type { BlueskyPublicPost } from "./bluesky";
import { getPublicBlueskyAuthorFeed } from "./bluesky";
import { fetchNotesFromRelays, type NostrNote } from "./nostr";
import { toUnifiedFromBluesky, toUnifiedFromNostr, type UnifiedItem } from "./socialFeed";

/** A merged following-feed item: the normalized record + the source protocol. */
export interface FollowingFeedItem {
  unified: UnifiedItem;
  /** Original Nostr note (when source is nostr), for the Nostr card renderer. */
  nostrNote?: NostrNote;
  /** Original Bluesky post (when source is bluesky), for the Bluesky renderer. */
  blueskyPost?: BlueskyPublicPost;
  /** Profile hint for the Nostr card (resolved separately by the caller if needed). */
  authorHandle?: string;
  authorAvatar?: string;
}

export type FollowingFeedResult = {
  items: FollowingFeedItem[];
  nostrCount: number;
  blueskyCount: number;
};

/** Split the follows-store keys into per-protocol id lists. */
export function partitionFollows(
  followedIds: string[]
): { nostrPubkeys: string[]; blueskyActors: string[] } {
  const nostrPubkeys: string[] = [];
  const blueskyActors: string[] = [];
  for (const id of followedIds) {
    if (id.startsWith("nostr:")) nostrPubkeys.push(id.slice("nostr:".length));
    else if (id.startsWith("bluesky:")) blueskyActors.push(id.slice("bluesky:".length));
  }
  return { nostrPubkeys, blueskyActors };
}

/**
 * Build the merged Following timeline. Both fetches run in parallel; partial
 * failures don't block the result. Newest-first by timestamp.
 */
export async function loadFollowingFeed(
  followedIds: string[],
  opts: { nostrLimit?: number; blueskyPerAuthorLimit?: number; nostrProfiles?: Map<string, { name?: string; picture?: string }> } = {}
): Promise<FollowingFeedResult> {
  const { nostrLimit = 40, blueskyPerAuthorLimit = 8, nostrProfiles } = opts;
  const { nostrPubkeys, blueskyActors } = partitionFollows(followedIds);

  const items: FollowingFeedItem[] = [];

  // Nostr: one multi-author relay query (efficient, server-side filtered).
  if (nostrPubkeys.length) {
    try {
      const notes = await fetchNotesFromRelays({ authors: nostrPubkeys, limit: nostrLimit });
      for (const note of notes) {
        const profile = nostrProfiles?.get(note.pubkey);
        items.push({
          unified: toUnifiedFromNostr(note, profile?.name, profile?.picture),
          nostrNote: note,
          authorHandle: profile?.name,
          authorAvatar: profile?.picture,
        });
      }
    } catch {
      /* tolerate — whatever arrived */
    }
  }

  // Bluesky: fan-out per followed actor (no anonymous batched timeline API).
  if (blueskyActors.length) {
    const settled = await Promise.allSettled(
      blueskyActors.map((actor) => getPublicBlueskyAuthorFeed(actor, { limit: blueskyPerAuthorLimit }))
    );
    const seenUris = new Set<string>();
    for (const r of settled) {
      if (r.status !== "fulfilled") continue;
      for (const post of r.value) {
        if (seenUris.has(post.uri)) continue;
        seenUris.add(post.uri);
        items.push({
          unified: toUnifiedFromBluesky(post),
          blueskyPost: post,
        });
      }
    }
  }

  // Interleave newest-first by unified timestamp (epoch seconds).
  items.sort((a, b) => b.unified.timestamp - a.unified.timestamp);

  return {
    items,
    nostrCount: items.filter((i) => i.nostrNote).length,
    blueskyCount: items.filter((i) => i.blueskyPost).length,
  };
}
