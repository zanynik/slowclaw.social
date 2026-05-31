/**
 * nostr.ts — Minimal Nostr protocol implementation (NIP-01).
 * 
 * Supports:
 * - Reading notes from public relays (no auth needed)
 * - Key pair generation (random 32-byte private key → secp256k1 public key)
 * - Event signing (Schnorr signatures per BIP-340)
 * - Publishing events to relays
 *
 * Uses only Web Crypto API + inline secp256k1 math (no npm dependencies).
 */

// ─── Constants ───────────────────────────────────────────────────────────────

const DEFAULT_RELAYS = [
  "wss://relay.damus.io",
  "wss://nos.lol",
  "wss://relay.nostr.band",
];

const STORAGE_KEY_NOSTR_PRIVKEY = "slowclaw.nostr.privkey";
const STORAGE_KEY_NOSTR_PUBKEY = "slowclaw.nostr.pubkey";

// secp256k1 curve parameters (all BigInt)
const P = BigInt("0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEFFFFFC2F");
const N = BigInt("0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141");
const Gx = BigInt("0x79BE667EF9DCBBAC55A06295CE870B07029BFCDB2DCE28D959F2815B16F81798");
const Gy = BigInt("0x483ADA7726A3C4655DA4FBFC0E1108A8FD17B448A68554199C47D08FFB10D4B8");

// ─── Modular arithmetic helpers ──────────────────────────────────────────────

function mod(a: bigint, m: bigint): bigint {
  const r = a % m;
  return r >= 0n ? r : r + m;
}

function modPow(base: bigint, exp: bigint, m: bigint): bigint {
  let result = 1n;
  base = mod(base, m);
  while (exp > 0n) {
    if (exp & 1n) result = mod(result * base, m);
    exp >>= 1n;
    base = mod(base * base, m);
  }
  return result;
}

function modInverse(a: bigint, m: bigint): bigint {
  return modPow(a, m - 2n, m);
}

// ─── Elliptic curve point operations ─────────────────────────────────────────

type Point = { x: bigint; y: bigint } | null; // null = point at infinity

function pointAdd(p1: Point, p2: Point): Point {
  if (!p1) return p2;
  if (!p2) return p1;
  if (p1.x === p2.x && p1.y === p2.y) return pointDouble(p1);
  if (p1.x === p2.x) return null;
  const slope = mod((p2.y - p1.y) * modInverse(p2.x - p1.x, P), P);
  const x = mod(slope * slope - p1.x - p2.x, P);
  const y = mod(slope * (p1.x - x) - p1.y, P);
  return { x, y };
}

function pointDouble(p: Point): Point {
  if (!p) return null;
  const slope = mod(3n * p.x * p.x * modInverse(2n * p.y, P), P);
  const x = mod(slope * slope - 2n * p.x, P);
  const y = mod(slope * (p.x - x) - p.y, P);
  return { x, y };
}

function pointMul(k: bigint, p: Point): Point {
  let result: Point = null;
  let addend: Point = p;
  k = mod(k, N);
  while (k > 0n) {
    if (k & 1n) result = pointAdd(result, addend);
    addend = pointDouble(addend);
    k >>= 1n;
  }
  return result;
}

const G: Point = { x: Gx, y: Gy };

// ─── Byte/hex conversion ─────────────────────────────────────────────────────

function bytesToHex(bytes: Uint8Array): string {
  return Array.from(bytes).map((b) => b.toString(16).padStart(2, "0")).join("");
}

function hexToBytes(hex: string): Uint8Array {
  const bytes = new Uint8Array(hex.length / 2);
  for (let i = 0; i < hex.length; i += 2) {
    bytes[i / 2] = parseInt(hex.slice(i, i + 2), 16);
  }
  return bytes;
}

function bigintToBytes32(n: bigint): Uint8Array {
  const hex = n.toString(16).padStart(64, "0");
  return hexToBytes(hex);
}

function bytesToBigint(bytes: Uint8Array): bigint {
  return BigInt("0x" + bytesToHex(bytes));
}

// ─── SHA-256 using Web Crypto ────────────────────────────────────────────────

async function sha256(data: Uint8Array): Promise<Uint8Array> {
  const hash = await crypto.subtle.digest("SHA-256", data as unknown as ArrayBuffer);
  return new Uint8Array(hash);
}

// ─── Key operations ──────────────────────────────────────────────────────────

function getPublicKey(privKeyHex: string): string {
  const k = BigInt("0x" + privKeyHex);
  const point = pointMul(k, G);
  if (!point) throw new Error("Invalid private key");
  return bytesToHex(bigintToBytes32(point.x));
}

function generatePrivateKey(): string {
  const bytes = new Uint8Array(32);
  crypto.getRandomValues(bytes);
  // Ensure key is valid (< N)
  let k = bytesToBigint(bytes);
  while (k >= N || k === 0n) {
    crypto.getRandomValues(bytes);
    k = bytesToBigint(bytes);
  }
  return bytesToHex(bytes);
}

// ─── BIP-340 Schnorr signature ───────────────────────────────────────────────

function liftX(x: bigint): Point {
  const c = mod(modPow(x, 3n, P) + 7n, P);
  const y = modPow(c, (P + 1n) / 4n, P);
  if (modPow(y, 2n, P) !== mod(x * x * x + 7n, P)) return null;
  return { x, y: y & 1n ? P - y : y };
}

function taggedHash(tag: string, data: Uint8Array): Promise<Uint8Array> {
  const tagBytes = new TextEncoder().encode(tag);
  return sha256(tagBytes).then(async (tagHash) => {
    const msg = new Uint8Array(tagHash.length * 2 + data.length);
    msg.set(tagHash, 0);
    msg.set(tagHash, tagHash.length);
    msg.set(data, tagHash.length * 2);
    return sha256(msg);
  });
}

async function schnorrSign(msgHash: Uint8Array, privKeyHex: string): Promise<string> {
  const d = BigInt("0x" + privKeyHex);
  const point = pointMul(d, G);
  if (!point) throw new Error("Invalid key");
  // Negate d if P.y is odd (BIP-340)
  const dk = point.y & 1n ? N - d : d;

  // Aux randomness
  const auxRand = new Uint8Array(32);
  crypto.getRandomValues(auxRand);
  const t = bigintToBytes32(dk);
  const auxHash = await taggedHash("BIP0340/aux", auxRand);
  const tXorAux = new Uint8Array(32);
  for (let i = 0; i < 32; i++) tXorAux[i] = t[i] ^ auxHash[i];

  const nonceInput = new Uint8Array(32 + 32 + 32);
  nonceInput.set(tXorAux, 0);
  nonceInput.set(bigintToBytes32(point.x), 32);
  nonceInput.set(msgHash, 64);
  const kHash = await taggedHash("BIP0340/nonce", nonceInput);
  let k = mod(bytesToBigint(kHash), N);
  if (k === 0n) throw new Error("Nonce is zero");

  const R = pointMul(k, G);
  if (!R) throw new Error("R is infinity");
  if (R.y & 1n) k = N - k;

  const eInput = new Uint8Array(32 + 32 + 32);
  eInput.set(bigintToBytes32(R.x), 0);
  eInput.set(bigintToBytes32(point.x), 32);
  eInput.set(msgHash, 64);
  const eHash = await taggedHash("BIP0340/challenge", eInput);
  const e = mod(bytesToBigint(eHash), N);

  const sig = mod(k + e * dk, N);
  const sigBytes = new Uint8Array(64);
  sigBytes.set(bigintToBytes32(R.x), 0);
  sigBytes.set(bigintToBytes32(sig), 32);
  return bytesToHex(sigBytes);
}

// ─── Nostr Event types ───────────────────────────────────────────────────────

export type NostrEvent = {
  id: string;
  pubkey: string;
  created_at: number;
  kind: number;
  tags: string[][];
  content: string;
  sig: string;
};

export type NostrNote = {
  id: string;
  pubkey: string;
  content: string;
  createdAt: number;
  tags: string[][];
};

// ─── Event creation and signing ──────────────────────────────────────────────

export async function createSignedEvent(
  privKeyHex: string,
  kind: number,
  content: string,
  tags: string[][] = []
): Promise<NostrEvent> {
  const pubkey = getPublicKey(privKeyHex);
  const created_at = Math.floor(Date.now() / 1000);

  // Compute event ID (SHA-256 of serialized event)
  const serialized = JSON.stringify([0, pubkey, created_at, kind, tags, content]);
  const idBytes = await sha256(new TextEncoder().encode(serialized));
  const id = bytesToHex(idBytes);

  // Sign the event ID
  const sig = await schnorrSign(idBytes, privKeyHex);

  return { id, pubkey, created_at, kind, tags, content, sig };
}

// ─── Key management (localStorage) ──────────────────────────────────────────

export function hasNostrKeys(): boolean {
  return !!localStorage.getItem(STORAGE_KEY_NOSTR_PRIVKEY);
}

export function getNostrPubkey(): string | null {
  return localStorage.getItem(STORAGE_KEY_NOSTR_PUBKEY);
}

export function generateAndSaveNostrKeys(): { privkey: string; pubkey: string } {
  const privkey = generatePrivateKey();
  const pubkey = getPublicKey(privkey);
  localStorage.setItem(STORAGE_KEY_NOSTR_PRIVKEY, privkey);
  localStorage.setItem(STORAGE_KEY_NOSTR_PUBKEY, pubkey);
  return { privkey, pubkey };
}

export function importNostrPrivkey(privkeyHex: string): { pubkey: string } | null {
  try {
    const clean = privkeyHex.replace(/^nsec1/, "").trim();
    // Validate it's a valid hex key
    if (!/^[0-9a-f]{64}$/i.test(clean)) return null;
    const pubkey = getPublicKey(clean);
    localStorage.setItem(STORAGE_KEY_NOSTR_PRIVKEY, clean);
    localStorage.setItem(STORAGE_KEY_NOSTR_PUBKEY, pubkey);
    return { pubkey };
  } catch {
    return null;
  }
}

export function clearNostrKeys(): void {
  localStorage.removeItem(STORAGE_KEY_NOSTR_PRIVKEY);
  localStorage.removeItem(STORAGE_KEY_NOSTR_PUBKEY);
}

// ─── Relay communication ─────────────────────────────────────────────────────

/**
 * Fetch recent notes from public relays. No authentication needed.
 * Returns up to `limit` notes from `kinds` (default: kind 1 = text notes).
 */
export function fetchNotesFromRelays(
  opts: {
    limit?: number;
    kinds?: number[];
    authors?: string[];
    search?: string;
    relays?: string[];
    since?: number;
  } = {}
): Promise<NostrNote[]> {
  const {
    limit = 30,
    kinds = [1],
    authors,
    search,
    relays = DEFAULT_RELAYS,
    since,
  } = opts;

  return new Promise((resolve) => {
    const notes: NostrNote[] = [];
    const seenIds = new Set<string>();
    let resolved = false;
    let connectedRelays = 0;
    let closedRelays = 0;
    const sockets: WebSocket[] = [];

    const timer = setTimeout(() => finish(), 8000); // 8s timeout

    function finish() {
      if (resolved) return;
      resolved = true;
      clearTimeout(timer);
      sockets.forEach((ws) => { try { ws.close(); } catch {} });
      // Sort by newest first, deduplicate
      notes.sort((a, b) => b.createdAt - a.createdAt);
      resolve(notes.slice(0, limit));
    }

    for (const relay of relays) {
      try {
        const ws = new WebSocket(relay);
        sockets.push(ws);

        ws.onopen = () => {
          connectedRelays++;
          const subId = "sc_" + Math.random().toString(36).slice(2, 8);
          const filter: Record<string, unknown> = { kinds, limit: Math.min(limit, 50) };
          if (authors?.length) filter.authors = authors;
          if (search) filter.search = search;
          if (since) filter.since = since;
          ws.send(JSON.stringify(["REQ", subId, filter]));
        };

        ws.onmessage = (msg) => {
          try {
            const raw = typeof msg.data === "string" ? msg.data : "";
            if (!raw) return;
            const data = JSON.parse(raw);
            if (data[0] === "EVENT" && data[2]) {
              const ev = data[2] as NostrEvent;
              if (!seenIds.has(ev.id) && ev.content?.trim()) {
                seenIds.add(ev.id);
                notes.push({
                  id: ev.id,
                  pubkey: ev.pubkey,
                  content: ev.content,
                  createdAt: ev.created_at,
                  tags: ev.tags || [],
                });
              }
            }
            if (data[0] === "EOSE") {
              try { ws.close(); } catch {}
            }
          } catch {}
        };

        ws.onerror = (e) => {
          console.warn(`[nostr] relay error: ${relay}`, e);
          try { ws.close(); } catch {}
        };
        ws.onclose = () => {
          closedRelays++;
          if (closedRelays >= relays.length) finish();
        };
      } catch {
        closedRelays++;
        if (closedRelays >= relays.length) finish();
      }
    }
  });
}

/**
 * Fetch notes matching keywords (used for personalized feed).
 * Tries relay.nostr.band which supports NIP-50 search.
 */
export function fetchPersonalizedNotes(
  keywords: string[],
  limit = 20
): Promise<NostrNote[]> {
  if (!keywords.length) return fetchNotesFromRelays({ limit });
  // NIP-50 search: relay.nostr.band supports text search
  const searchQuery = keywords.slice(0, 5).join(" ");
  return fetchNotesFromRelays({
    limit,
    search: searchQuery,
    relays: ["wss://relay.nostr.band", "wss://nos.lol"],
  });
}

/**
 * Publish a text note (kind 1) to relays.
 */
export async function publishNote(
  content: string,
  relays: string[] = DEFAULT_RELAYS
): Promise<{ success: boolean; eventId?: string; error?: string }> {
  const privkey = localStorage.getItem(STORAGE_KEY_NOSTR_PRIVKEY);
  if (!privkey) return { success: false, error: "No Nostr key configured" };

  try {
    const event = await createSignedEvent(privkey, 1, content);

    // Publish to all relays
    const results = await Promise.allSettled(
      relays.map(
        (relay) =>
          new Promise<boolean>((resolve) => {
            const ws = new WebSocket(relay);
            const timeout = setTimeout(() => { ws.close(); resolve(false); }, 5000);
            ws.onopen = () => {
              ws.send(JSON.stringify(["EVENT", event]));
            };
            ws.onmessage = (msg) => {
              try {
                const data = JSON.parse(msg.data as string);
                if (data[0] === "OK" && data[1] === event.id) {
                  clearTimeout(timeout);
                  ws.close();
                  resolve(data[2] === true);
                }
              } catch {}
            };
            ws.onerror = () => { clearTimeout(timeout); ws.close(); resolve(false); };
          })
      )
    );

    const anySuccess = results.some(
      (r) => r.status === "fulfilled" && r.value === true
    );
    return anySuccess
      ? { success: true, eventId: event.id }
      : { success: false, error: "Failed to publish to any relay" };
  } catch (e) {
    return { success: false, error: e instanceof Error ? e.message : String(e) };
  }
}

/**
 * Extract keywords from journal entries for personalized feed.
 */
export function extractKeywordsFromJournals(texts: string[]): string[] {
  const stopWords = new Set([
    "the", "a", "an", "is", "are", "was", "were", "be", "been", "being",
    "have", "has", "had", "do", "does", "did", "will", "would", "could",
    "should", "may", "might", "shall", "can", "need", "dare", "ought",
    "used", "to", "of", "in", "for", "on", "with", "at", "by", "from",
    "as", "into", "through", "during", "before", "after", "above", "below",
    "between", "out", "off", "over", "under", "again", "further", "then",
    "once", "here", "there", "when", "where", "why", "how", "all", "each",
    "every", "both", "few", "more", "most", "other", "some", "such", "no",
    "nor", "not", "only", "own", "same", "so", "than", "too", "very",
    "just", "because", "but", "and", "or", "if", "while", "about", "this",
    "that", "these", "those", "it", "its", "i", "me", "my", "we", "our",
    "you", "your", "he", "him", "his", "she", "her", "they", "them",
    "their", "what", "which", "who", "whom", "think", "know", "get",
    "make", "go", "see", "come", "take", "want", "look", "use", "find",
    "give", "tell", "work", "call", "try", "ask", "feel", "seem", "leave",
    "put", "mean", "keep", "let", "begin", "show", "hear", "play", "run",
    "move", "like", "live", "believe", "hold", "bring", "happen", "write",
    "provide", "sit", "stand", "lose", "pay", "meet", "include", "continue",
    "set", "learn", "change", "lead", "understand", "watch", "follow",
    "stop", "create", "speak", "read", "allow", "add", "spend", "grow",
    "open", "walk", "win", "offer", "remember", "love", "consider",
    "appear", "buy", "wait", "serve", "die", "send", "expect", "build",
    "stay", "fall", "cut", "reach", "kill", "remain", "today", "yesterday",
    "tomorrow", "really", "already", "also", "still", "going", "something",
    "nothing", "everything", "anything", "much", "many", "well", "even",
    "new", "good", "great", "old", "big", "long", "little", "right",
    "don", "didn", "doesn", "won", "isn", "aren", "wasn", "weren",
    "haven", "hasn", "hadn", "couldn", "wouldn", "shouldn", "mustn",
  ]);

  const wordFreq = new Map<string, number>();
  const combined = texts.join(" ").toLowerCase();
  const words = combined.match(/\b[a-z]{4,}\b/g) || [];

  for (const w of words) {
    if (!stopWords.has(w)) {
      wordFreq.set(w, (wordFreq.get(w) || 0) + 1);
    }
  }

  // Return top 8 most frequent words as keywords
  return [...wordFreq.entries()]
    .sort((a, b) => b[1] - a[1])
    .slice(0, 8)
    .map(([word]) => word);
}

/**
 * Generate Nostr keys in a format compatible with secureStorage's NostrKeys type.
 */
export function generateNostrKeys(): {
  nsec: string;
  npub: string;
  secretKeyHex: string;
  publicKeyHex: string;
} {
  const privkey = generatePrivateKey();
  const pubkey = getPublicKey(privkey);
  // Save to localStorage as well for quick access
  localStorage.setItem(STORAGE_KEY_NOSTR_PRIVKEY, privkey);
  localStorage.setItem(STORAGE_KEY_NOSTR_PUBKEY, pubkey);
  return { nsec: privkey, npub: pubkey, secretKeyHex: privkey, publicKeyHex: pubkey };
}

/**
 * Publish a signed event to a single relay.
 */
export async function publishToRelay(relayUrl: string, event: NostrEvent): Promise<boolean> {
  return new Promise((resolve) => {
    try {
      const ws = new WebSocket(relayUrl);
      const timeout = setTimeout(() => { ws.close(); resolve(false); }, 5000);
      ws.onopen = () => {
        ws.send(JSON.stringify(["EVENT", event]));
      };
      ws.onmessage = (msg) => {
        try {
          const data = JSON.parse(msg.data as string);
          if (data[0] === "OK" && data[1] === event.id) {
            clearTimeout(timeout);
            ws.close();
            resolve(data[2] === true);
          }
        } catch {}
      };
      ws.onerror = () => { clearTimeout(timeout); ws.close(); resolve(false); };
    } catch {
      resolve(false);
    }
  });
}
