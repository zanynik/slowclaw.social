/**
 * nostrLocalStore.ts — frontend layer for the on-device Nostr store.
 *
 * Wraps the Tauri IPC commands exposed by the Rust background ingester
 * (`nostr_store_status`, `nostr_query_notes`, etc.). Returns the same shapes
 * the rest of the UI already consumes from `./nostr` (`NostrNote`,
 * `NostrProfile`), so callers switch between the local-store path and the
 * direct-relay path without touching downstream rendering.
 *
 * All calls are no-ops (return null/empty) outside the Tauri runtime, so the
 * standalone web/demo build keeps working unchanged.
 */

import type { NostrNote, NostrProfile } from "./nostr";

// ─────────────────────────────────────────────
// Types (mirror Rust structs, camelCase via serde)
// ─────────────────────────────────────────────

export type NostrStoreStatus = {
  running: boolean;
  relays: string[];
  hashtagChannels: string[];
  eventsIngested: number;
  lastEventAt: string | null;
  dbPath: string | null;
  lastError: string | null;
};

/** Raw record returned by Rust. NoteRecord uses snake_case `created_at`. */
type NoteRecord = {
  id: string;
  pubkey: string;
  npub?: string;
  content: string;
  created_at: number;
  kind: number;
  tags?: string[][];
};

type ProfileRecord = {
  pubkey: string;
  npub?: string;
  name?: string;
  display_name?: string;
  picture?: string;
  about?: string;
  website?: string;
  nip05?: string;
};

export type NostrPublishResult = {
  eventId: string;
  published: boolean;
  error: string | null;
};

export type NostrQueryOptions = {
  authors?: string[];
  hashtags?: string[];
  kinds?: number[];
  since?: number;
  until?: number;
  limit?: number;
};

// ─────────────────────────────────────────────
// Invoke helper (dynamic import keeps this out of the web bundle)
// ─────────────────────────────────────────────

async function invokeTauri<T>(cmd: string, args?: Record<string, unknown>): Promise<T> {
  const core = await import("@tauri-apps/api/core");
  return core.invoke<T>(cmd, args);
}

// ─────────────────────────────────────────────
// Conversions: Rust record → UI shape
// ─────────────────────────────────────────────

function noteRecordToNostrNote(r: NoteRecord): NostrNote {
  return {
    id: r.id,
    pubkey: r.pubkey,
    content: r.content,
    // `NostrNote` uses camelCase `createdAt`; the Rust side stores unix seconds.
    createdAt: r.created_at,
    tags: r.tags ?? [],
  };
}

function profileRecordToNostrProfile(r: ProfileRecord): NostrProfile {
  return {
    pubkey: r.pubkey,
    name: r.name ?? null,
    displayName: r.display_name ?? null,
    picture: r.picture ?? null,
    about: r.about ?? null,
    website: r.website ?? null,
    nip05: r.nip05 ?? null,
    updatedAt: 0,
  };
}

/** Cache of precomputed npub per pubkey (filled from store records). */
const npubCache = new Map<string, string>();

function rememberNpub(pubkey: string, npub: string | undefined): void {
  if (pubkey && npub) npubCache.set(pubkey, npub);
}

/** Read a precomputed npub for a pubkey, if the store has cached it. */
export function cachedNpub(pubkey: string): string | undefined {
  return npubCache.get(pubkey);
}

// ─────────────────────────────────────────────
// Public API
// ─────────────────────────────────────────────

export async function nostrStoreStatus(): Promise<NostrStoreStatus | null> {
  try {
    return await invokeTauri<NostrStoreStatus>("nostr_store_status");
  } catch {
    return null;
  }
}

export async function nostrQueryNotes(opts: NostrQueryOptions = {}): Promise<NostrNote[]> {
  const records = await invokeTauri<NoteRecord[]>("nostr_query_notes", {
    req: {
      authors: opts.authors ?? [],
      hashtags: opts.hashtags ?? [],
      kinds: opts.kinds ?? [],
      since: opts.since ?? null,
      until: opts.until ?? null,
      limit: opts.limit ?? null,
    },
  });
  return records.map((r) => {
    rememberNpub(r.pubkey, r.npub);
    return noteRecordToNostrNote(r);
  });
}

export async function nostrGetNote(eventId: string): Promise<NostrNote | null> {
  try {
    const r = await invokeTauri<NoteRecord | null>("nostr_get_note", { eventId });
    if (!r) return null;
    rememberNpub(r.pubkey, r.npub);
    return noteRecordToNostrNote(r);
  } catch {
    return null;
  }
}

export async function nostrGetProfiles(pubkeys: string[]): Promise<Map<string, NostrProfile>> {
  if (pubkeys.length === 0) return new Map();
  try {
    const records = await invokeTauri<ProfileRecord[]>("nostr_get_profiles", { pubkeys });
    const out = new Map<string, NostrProfile>();
    for (const r of records) {
      rememberNpub(r.pubkey, r.npub);
      out.set(r.pubkey, profileRecordToNostrProfile(r));
    }
    return out;
  } catch {
    return new Map();
  }
}

export async function nostrGetReactions(eventIds: string[]): Promise<Map<string, number>> {
  if (eventIds.length === 0) return new Map();
  try {
    const counts = await invokeTauri<Record<string, number>>("nostr_get_reactions", { eventIds });
    return new Map(Object.entries(counts));
  } catch {
    return new Map();
  }
}

export async function nostrGetReplies(eventId: string): Promise<NostrNote[]> {
  try {
    const records = await invokeTauri<NoteRecord[]>("nostr_get_replies", { eventId });
    return records.map((r) => {
      rememberNpub(r.pubkey, r.npub);
      return noteRecordToNostrNote(r);
    });
  } catch {
    return [];
  }
}

export async function nostrGetArticles(): Promise<NostrNote[]> {
  try {
    const records = await invokeTauri<NoteRecord[]>("nostr_get_articles", { req: { limit: null } });
    return records.map((r) => {
      rememberNpub(r.pubkey, r.npub);
      return noteRecordToNostrNote(r);
    });
  } catch {
    return [];
  }
}

export async function nostrIngestRefresh(): Promise<void> {
  try {
    await invokeTauri<void>("nostr_ingest_refresh");
  } catch {
    // Non-fatal: the UI falls back to relay reads.
  }
}

export async function nostrPublishNote(content: string): Promise<NostrPublishResult | null> {
  try {
    return await invokeTauri<NostrPublishResult>("nostr_publish_note", { content });
  } catch (err) {
    console.error("[nostr] publish note failed", err);
    return null;
  }
}

export async function nostrPublishReaction(
  eventId: string,
  content: string,
): Promise<NostrPublishResult | null> {
  try {
    return await invokeTauri<NostrPublishResult>("nostr_publish_reaction", { eventId, content });
  } catch (err) {
    console.error("[nostr] publish reaction failed", err);
    return null;
  }
}

export async function nostrPublishReply(
  eventId: string,
  relayUrl: string,
  content: string,
): Promise<NostrPublishResult | null> {
  try {
    return await invokeTauri<NostrPublishResult>("nostr_publish_reply", {
      eventId,
      relayUrl,
      content,
    });
  } catch (err) {
    console.error("[nostr] publish reply failed", err);
    return null;
  }
}
