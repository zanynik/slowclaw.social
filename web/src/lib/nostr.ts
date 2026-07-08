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

// ─── Bech32 (BIP-173) for npub/nsec encoding ────────────────────────────────
//
// Nostr public/private keys are canonically exchanged as bech32 strings:
//   npub1...  (public key)   nsec1...  (private key)
// The data payload is the 32-byte X-only pubkey / private key. Implemented
// inline (no dependency) consistent with the rest of this module.

const BECH32_CHARSET = "qpzry9x8gf2tvdw0s3jn54khce6mua7l";

function bech32Polymod(values: number[]): number {
  let chk = 1;
  const GEN = [0x3b6a57b2, 0x26508e6d, 0x1ea119fa, 0x3d4233dd, 0x2a1462b3];
  for (const v of values) {
    const top = chk >> 25;
    chk = ((chk & 0x1ffffff) << 5) ^ v;
    for (let i = 0; i < 5; i++) {
      if ((top >> i) & 1) chk ^= GEN[i];
    }
  }
  return chk;
}

function bech32HrpExpand(hrp: string): number[] {
  const ret: number[] = [];
  for (const c of hrp) ret.push(c.charCodeAt(0) >> 5);
  ret.push(0);
  for (const c of hrp) ret.push(c.charCodeAt(0) & 31);
  return ret;
}

function bech32CreateChecksum(hrp: string, data: number[]): number[] {
  const values = [...bech32HrpExpand(hrp), ...data, 0, 0, 0, 0, 0, 0];
  const polymod = bech32Polymod(values) ^ 1;
  const ret: number[] = [];
  for (let i = 0; i < 6; i++) ret.push((polymod >> (5 * (5 - i))) & 31);
  return ret;
}

function bech32VerifyChecksum(hrp: string, data: number[]): boolean {
  return bech32Polymod([...bech32HrpExpand(hrp), ...data]) === 1;
}

function convertBits(data: number[], fromBits: number, toBits: number, pad: boolean): number[] {
  let acc = 0;
  let bits = 0;
  const ret: number[] = [];
  const maxv = (1 << toBits) - 1;
  const maxAcc = (1 << (fromBits + toBits - 1)) - 1;
  for (const value of data) {
    if (value < 0 || value >> fromBits !== 0) throw new Error("bech32: invalid data value");
    acc = ((acc << fromBits) | value) & maxAcc;
    bits += fromBits;
    while (bits >= toBits) {
      bits -= toBits;
      ret.push((acc >> bits) & maxv);
    }
  }
  if (pad) {
    if (bits) ret.push((acc << (toBits - bits)) & maxv);
  } else if (bits >= fromBits || ((acc << (toBits - bits)) & maxv)) {
    throw new Error("bech32: invalid padding");
  }
  return ret;
}

function encodeBech32(hrp: string, hexData: string): string {
  const bytes = hexToBytes(hexData);
  const data = convertBits(Array.from(bytes), 8, 5, true);
  const checksum = bech32CreateChecksum(hrp, data);
  return hrp + "1" + [...data, ...checksum].map((v) => BECH32_CHARSET[v]).join("");
}

function decodeBech32(str: string, expectedHrp: string): string | null {
  const clean = str.trim().toLowerCase();
  if (clean.length < 8 || clean.length > 90) return null;
  const pos = clean.lastIndexOf("1");
  if (pos < 1 || pos + 7 > clean.length) return null;
  const hrp = clean.slice(0, pos);
  if (hrp !== expectedHrp) return null;
  const data: number[] = [];
  for (let i = pos + 1; i < clean.length; i++) {
    const v = BECH32_CHARSET.indexOf(clean[i]);
    if (v === -1) return null;
    data.push(v);
  }
  if (!bech32VerifyChecksum(hrp, data)) return null;
  // Strip the 6-char checksum, decode the 5-bit groups back to 8-bit bytes.
  const payload = data.slice(0, -6);
  try {
    const bytes = convertBits(payload, 5, 8, false);
    return bytesToHex(Uint8Array.from(bytes));
  } catch {
    return null;
  }
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

// ─── Bech32 key helpers (npub1... / nsec1...) ───────────────────────────────

export function npubFromHex(pubkeyHex: string): string {
  return encodeBech32("npub", pubkeyHex);
}

export function nsecFromHex(privkeyHex: string): string {
  return encodeBech32("nsec", privkeyHex);
}

export function decodeNpub(npub: string): string | null {
  return decodeBech32(npub, "npub");
}

export function decodeNsec(nsec: string): string | null {
  return decodeBech32(nsec, "nsec");
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

/** NIP-01 kind-0 profile metadata (parsed from the event's content JSON). */
export type NostrProfile = {
  pubkey: string;
  name: string | null;        // handle, e.g. "satoshi"
  displayName: string | null; // human name, e.g. "Satoshi Nakamoto"
  picture: string | null;     // avatar URL
  about: string | null;
  website: string | null;
  nip05: string | null;       // verified identifier, e.g. "satoshi@example.com"
  updatedAt: number;
};

/**
 * Resolve the immediate parent event id for a note, per NIP-10 tagging.
 * Returns null for top-level (root) posts.
 */
export function getReplyParentId(note: NostrNote): string | null {
  const eTags = (note.tags || []).filter((t) => t[0] === "e" && t[1]);
  if (eTags.length === 0) return null;
  // Explicit "reply" marker wins.
  const reply = eTags.find((t) => t[3] === "reply");
  if (reply) return reply[1];
  const hasMarkers = eTags.some((t) => t[3]);
  // Deprecated positional form (no markers): last e-tag is the parent.
  if (!hasMarkers) return eTags[eTags.length - 1][1];
  // A lone "root" marker (single-level reply) is its own parent.
  const root = eTags.find((t) => t[3] === "root");
  if (root) return root[1];
  return eTags[eTags.length - 1][1];
}

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

/**
 * Generate a fresh key pair and persist it. Returns the full NostrKeys shape:
 * secretKeyHex/publicKeyHex (raw hex, used for signing) and nsec/npub
 * (canonical bech32 strings shown to users).
 */
export function generateAndSaveNostrKeys(): {
  nsec: string;
  npub: string;
  secretKeyHex: string;
  publicKeyHex: string;
} {
  const secretKeyHex = generatePrivateKey();
  const publicKeyHex = getPublicKey(secretKeyHex);
  localStorage.setItem(STORAGE_KEY_NOSTR_PRIVKEY, secretKeyHex);
  localStorage.setItem(STORAGE_KEY_NOSTR_PUBKEY, publicKeyHex);
  return {
    nsec: nsecFromHex(secretKeyHex),
    npub: npubFromHex(publicKeyHex),
    secretKeyHex,
    publicKeyHex,
  };
}

/**
 * Import a private key given as bech32 (nsec1...) or raw 64-char hex.
 * Validates and persists. Returns the full NostrKeys shape, or null on bad input.
 */
export function importNostrPrivkey(
  input: string
): { nsec: string; npub: string; secretKeyHex: string; publicKeyHex: string } | null {
  try {
    const trimmed = input.trim();
    let secretKeyHex: string | null = null;
    if (trimmed.startsWith("nsec1")) {
      secretKeyHex = decodeNsec(trimmed);
    } else if (/^[0-9a-f]{64}$/i.test(trimmed)) {
      secretKeyHex = trimmed.toLowerCase();
    }
    if (!secretKeyHex) return null;
    const publicKeyHex = getPublicKey(secretKeyHex);
    localStorage.setItem(STORAGE_KEY_NOSTR_PRIVKEY, secretKeyHex);
    localStorage.setItem(STORAGE_KEY_NOSTR_PUBKEY, publicKeyHex);
    return {
      nsec: nsecFromHex(secretKeyHex),
      npub: npubFromHex(publicKeyHex),
      secretKeyHex,
      publicKeyHex,
    };
  } catch {
    return null;
  }
}

/**
 * Ensure a NostrKeys object carries canonical bech32 nsec/npub. Older builds
 * stored raw hex in those fields; this re-encodes from the hex fields so the UI
 * always shows nsec1.../npub1... Migration is idempotent and lossless.
 */
export function normalizeNostrKeys(keys: {
  nsec: string;
  npub: string;
  secretKeyHex: string;
  publicKeyHex: string;
}): { nsec: string; npub: string; secretKeyHex: string; publicKeyHex: string } {
  const nsec = keys.nsec?.startsWith("nsec1") ? keys.nsec : nsecFromHex(keys.secretKeyHex);
  const npub = keys.npub?.startsWith("npub1") ? keys.npub : npubFromHex(keys.publicKeyHex);
  return { ...keys, nsec, npub };
}

export function clearNostrKeys(): void {
  localStorage.removeItem(STORAGE_KEY_NOSTR_PRIVKEY);
  localStorage.removeItem(STORAGE_KEY_NOSTR_PUBKEY);
}

// ─── Relay communication ─────────────────────────────────────────────────────

/** Map a raw relay event to the lightweight NostrNote view model. */
function eventToNote(ev: NostrEvent): NostrNote {
  return {
    id: ev.id,
    pubkey: ev.pubkey,
    content: ev.content,
    createdAt: ev.created_at,
    tags: ev.tags || [],
  };
}

/**
 * Low-level helper: open REQ subscriptions against `relays` with `filter`, collect
 * unique events until all relays EOSE/close or the timeout elapses. Shared by every
 * higher-level fetch (notes, profiles, reactions, replies). Tolerant of partial
 * relay failures — returns whatever events arrived.
 */
export function fetchEventsByFilter(
  filter: Record<string, unknown>,
  opts: { relays?: string[]; timeoutMs?: number; limit?: number } = {}
): Promise<NostrEvent[]> {
  const { relays = DEFAULT_RELAYS, timeoutMs = 6000, limit = 100 } = opts;
  return new Promise((resolve) => {
    const events: NostrEvent[] = [];
    const seenIds = new Set<string>();
    let resolved = false;
    let closedRelays = 0;
    const sockets: WebSocket[] = [];

    const timer = setTimeout(finish, timeoutMs);

    function finish() {
      if (resolved) return;
      resolved = true;
      clearTimeout(timer);
      sockets.forEach((ws) => { try { ws.close(); } catch {} });
      resolve(events);
    }

    for (const relay of relays) {
      try {
        const ws = new WebSocket(relay);
        sockets.push(ws);

        ws.onopen = () => {
          const subId = "sc_" + Math.random().toString(36).slice(2, 8);
          const reqFilter = { ...filter, limit: Math.min(filter.limit ? Number(filter.limit) : limit, 200) };
          ws.send(JSON.stringify(["REQ", subId, reqFilter]));
        };

        ws.onmessage = (msg) => {
          try {
            const raw = typeof msg.data === "string" ? msg.data : "";
            if (!raw) return;
            const data = JSON.parse(raw);
            if (data[0] === "EVENT" && data[2]) {
              const ev = data[2] as NostrEvent;
              if (ev.id && !seenIds.has(ev.id)) {
                seenIds.add(ev.id);
                events.push(ev);
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
 * Fetch recent notes from public relays. No authentication needed.
 * Returns up to `limit` notes from `kinds` (default: kind 1 = text notes),
 * newest first, deduplicated.
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

  const filter: Record<string, unknown> = { kinds, limit: Math.min(limit, 50) };
  if (authors?.length) filter.authors = authors;
  if (search) filter.search = search;
  if (since) filter.since = since;

  return fetchEventsByFilter(filter, { relays, timeoutMs: 8000 }).then((events) =>
    events
      .filter((ev) => ev.content?.trim())
      .map(eventToNote)
      .sort((a, b) => b.createdAt - a.createdAt)
      .slice(0, limit)
  );
}

/**
 * LEVER: Nostr NIP-12 hashtag subscription. Asks relays to send ONLY notes
 * tagged with one of `tags` (the `#t` filter), so filtering happens at the
 * source rather than client-side. This is the most reliable Nostr content
 * lever for popular tags — relay.nostr.band / nos.lol / damus push constant
 * traffic for #bitcoin, #nostr, #ai, #art, etc. Tags are matched without the
 * leading '#'. Returns up to `limit` notes, newest first, deduped.
 */
export function fetchNotesByHashtag(
  tags: string[],
  opts: { limit?: number; relays?: string[]; timeoutMs?: number; kinds?: number[] } = {}
): Promise<NostrNote[]> {
  const clean = tags.map((t) => t.trim().toLowerCase().replace(/^#/, "")).filter(Boolean);
  if (clean.length === 0) return fetchNotesFromRelays({ limit: opts.limit, relays: opts.relays, kinds: opts.kinds });
  const { limit = 30, relays = DEFAULT_RELAYS, timeoutMs = 7000, kinds = [1] } = opts;
  return fetchEventsByFilter(
    { kinds, "#t": clean, limit: Math.min(limit, 50) },
    { relays, timeoutMs, limit }
  ).then((events) =>
    events
      .filter((ev) => ev.content?.trim())
      .map(eventToNote)
      .sort((a, b) => b.createdAt - a.createdAt)
      .slice(0, limit)
  );
}

/**
 * Fetch NIP-23 long-form articles (kind 30023 — the format Habla News uses).
 * These power the Reads tab. Returns raw events (with `created_at` + tags) so
 * the converter in socialFeed.ts can read title/summary/image/published_at
 * from the NIP-23 tags. Newest first.
 */
export async function fetchLongFormArticles(
  opts: { limit?: number; relays?: string[]; timeoutMs?: number } = {}
): Promise<NostrEvent[]> {
  const { limit = 20, relays = DEFAULT_RELAYS, timeoutMs = 8000 } = opts;
  const events = await fetchEventsByFilter(
    { kinds: [30023], limit: Math.min(limit * 2, 50) },
    { relays, timeoutMs, limit: limit * 2 }
  );
  // Keep only articles with a title tag (well-formed NIP-23) and non-trivial body.
  return events
    .filter((ev) => (ev.tags || []).some((t) => t[0] === "title") && (ev.content || "").length > 200)
    .sort((a, b) => b.created_at - a.created_at)
    .slice(0, limit);
}

/**
 * Fetch NIP-01 kind-0 profile metadata for a set of pubkeys.
 * Returns the newest profile per pubkey. Tolerates malformed content JSON.
 */
export async function fetchProfiles(
  pubkeys: string[],
  opts: { relays?: string[]; timeoutMs?: number } = {}
): Promise<Map<string, NostrProfile>> {
  const result = new Map<string, NostrProfile>();
  const unique = [...new Set(pubkeys.filter(Boolean))];
  if (unique.length === 0) return result;

  const events = await fetchEventsByFilter(
    { kinds: [0], authors: unique, limit: unique.length * 2 },
    { timeoutMs: opts.timeoutMs ?? 6000, relays: opts.relays }
  );

  for (const ev of events) {
    const existing = result.get(ev.pubkey);
    // Keep the most recently created metadata event per pubkey.
    if (existing && existing.updatedAt >= ev.created_at) continue;
    try {
      const raw = JSON.parse(ev.content || "{}") as Record<string, unknown>;
      result.set(ev.pubkey, {
        pubkey: ev.pubkey,
        name: typeof raw.name === "string" ? raw.name : null,
        displayName: typeof raw.display_name === "string" ? raw.display_name : null,
        picture: typeof raw.picture === "string" ? raw.picture : null,
        about: typeof raw.about === "string" ? raw.about : null,
        website: typeof raw.website === "string" ? raw.website : null,
        nip05: typeof raw.nip05 === "string" ? raw.nip05 : null,
        updatedAt: ev.created_at,
      });
    } catch {
      // Malformed metadata — skip silently.
    }
  }
  return result;
}

/**
 * Fetch NIP-25 kind-7 reaction counts for a set of note ids.
 * Returns the number of distinct reactors per note (deduped by reactor pubkey).
 * Negative reactions (content "-") are excluded.
 */
export async function fetchReactionsForEvents(
  eventIds: string[],
  opts: { relays?: string[]; timeoutMs?: number } = {}
): Promise<Map<string, number>> {
  const counts = new Map<string, number>();
  const unique = [...new Set(eventIds.filter(Boolean))];
  if (unique.length === 0) return counts;

  const reactors = new Map<string, Set<string>>(); // eventId -> set of reactor pubkeys
  const events = await fetchEventsByFilter(
    { kinds: [7], "#e": unique, limit: 400 },
    { timeoutMs: opts.timeoutMs ?? 6000, relays: opts.relays }
  );

  for (const ev of events) {
    if (ev.content?.trim() === "-") continue; // skip dislikes
    const targetTag = (ev.tags || []).find((t) => t[0] === "e" && t[1]);
    if (!targetTag) continue;
    const set = reactors.get(targetTag[1]) || new Set<string>();
    set.add(ev.pubkey);
    reactors.set(targetTag[1], set);
  }
  for (const [id, set] of reactors) counts.set(id, set.size);
  return counts;
}

/**
 * Fetch kind-1 notes that reply to `eventId` (tagged via NIP-10).
 * Newest first, excluding the event itself.
 */
export async function fetchRepliesForEvent(
  eventId: string,
  opts: { relays?: string[]; timeoutMs?: number } = {}
): Promise<NostrNote[]> {
  const events = await fetchEventsByFilter(
    { kinds: [1], "#e": [eventId], limit: 50 },
    { timeoutMs: opts.timeoutMs ?? 6000, relays: opts.relays }
  );
  return events
    .filter((ev) => ev.id !== eventId && ev.content?.trim())
    .map(eventToNote)
    .sort((a, b) => b.createdAt - a.createdAt);
}

/**
 * Fetch notes by id (used to resolve the parent of a reply for inline context).
 * Returns a map of id -> note for whichever ids were found.
 */
export async function fetchNotesByIds(
  ids: string[],
  opts: { relays?: string[]; timeoutMs?: number } = {}
): Promise<Map<string, NostrNote>> {
  const result = new Map<string, NostrNote>();
  const unique = [...new Set(ids.filter(Boolean))];
  if (unique.length === 0) return result;
  const events = await fetchEventsByFilter(
    { ids: unique, limit: unique.length },
    { timeoutMs: opts.timeoutMs ?? 6000, relays: opts.relays }
  );
  for (const ev of events) {
    if (ev.content?.trim()) result.set(ev.id, eventToNote(ev));
  }
  return result;
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
 * Publish a kind-0 profile (NIP-01 metadata) to relays. Sets the user's
 * display name, about, and picture so their Nostr identity matches the local
 * profile. Content is the JSON-stringified metadata object per NIP-01.
 */
export async function publishProfile(
  meta: { name?: string; displayName?: string; about?: string; picture?: string; website?: string },
  relays: string[] = DEFAULT_RELAYS
): Promise<{ success: boolean; eventId?: string; error?: string }> {
  const privkey = localStorage.getItem(STORAGE_KEY_NOSTR_PRIVKEY);
  if (!privkey) return { success: false, error: "No Nostr key configured" };
  try {
    // NIP-01 kind-0 content is a JSON metadata object. Omit empty fields.
    const content = JSON.stringify(
      Object.fromEntries(
        Object.entries({
          name: meta.name || undefined,
          display_name: meta.displayName || undefined,
          about: meta.about || undefined,
          picture: meta.picture || undefined,
          website: meta.website || undefined,
        }).filter(([, v]) => v !== undefined)
      )
    );
    const event = await createSignedEvent(privkey, 0, content);
    const results = await Promise.allSettled(
      relays.map(
        (relay) =>
          new Promise<boolean>((resolve) => {
            const ws = new WebSocket(relay);
            const timeout = setTimeout(() => { ws.close(); resolve(false); }, 5000);
            ws.onopen = () => { ws.send(JSON.stringify(["EVENT", event])); };
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
    const anySuccess = results.some((r) => r.status === "fulfilled" && r.value === true);
    return anySuccess
      ? { success: true, eventId: event.id }
      : { success: false, error: "Failed to publish profile to any relay" };
  } catch (e) {
    return { success: false, error: e instanceof Error ? e.message : String(e) };
  }
}

/**
 * Fetch the user's own kind-3 contact list (NIP-02) to count their follows.
 * Each ["p", <pubkey>, ...] tag represents one followed account. Returns 0 if
 * no contact list is found. Followers count isn't reliably available without a
 * reverse index service, so only `following` is returned here.
 */
export async function fetchNostrFollowingCount(
  pubkey: string,
  relays: string[] = DEFAULT_RELAYS,
  timeoutMs = 6000
): Promise<number> {
  try {
    const events = await fetchEventsByFilter(
      { authors: [pubkey], kinds: [3], limit: 1 },
      { relays, timeoutMs }
    );
    if (!events.length) return 0;
    const contact = events[0];
    return (contact.tags || []).filter((t) => t[0] === "p").length;
  } catch {
    return 0;
  }
}

/**
 * Fetch a Nostr author's full kind-3 contact list as the set of followed
 * pubkeys. Anonymous read. Used by publishNostrFollowList to merge a new follow
 * without clobbering the user's existing contacts (NIP-02).
 */
export async function fetchNostrFollowSet(
  pubkey: string,
  relays: string[] = DEFAULT_RELAYS,
  timeoutMs = 6000
): Promise<string[]> {
  try {
    const events = await fetchEventsByFilter(
      { authors: [pubkey], kinds: [3], limit: 1 },
      { relays, timeoutMs }
    );
    if (!events.length) return [];
    const contact = events[0];
    return (contact.tags || [])
      .filter((t) => t[0] === "p" && t[1])
      .map((t) => t[1]);
  } catch {
    return [];
  }
}

/**
 * Publish a kind-3 contact list (NIP-02) to follow a pubkey. Merges with the
 * existing contact list first so we never clobber the user's current follows,
 * then signs + broadcasts. Returns success + event id like publishNote.
 */
export async function publishNostrFollow(
  followPubkey: string,
  relays: string[] = DEFAULT_RELAYS
): Promise<{ success: boolean; eventId?: string; error?: string }> {
  const privkey = localStorage.getItem(STORAGE_KEY_NOSTR_PRIVKEY);
  const pubkey = localStorage.getItem(STORAGE_KEY_NOSTR_PUBKEY);
  if (!privkey || !pubkey) {
    return { success: false, error: "No Nostr key configured" };
  }
  try {
    // Merge into the existing contact list (don't clobber).
    const existing = await fetchNostrFollowSet(pubkey, relays);
    const follows = Array.from(new Set([...existing, followPubkey]));
    const tags = follows.map((pk) => ["p", pk]);
    const event = await createSignedEvent(privkey, 3, "", tags);

    const results = await Promise.allSettled(
      relays.map(
        (relay) =>
          new Promise<boolean>((resolve) => {
            const ws = new WebSocket(relay);
            const timeout = setTimeout(() => { ws.close(); resolve(false); }, 5000);
            ws.onopen = () => { ws.send(JSON.stringify(["EVENT", event])); };
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
    const anySuccess = results.some((r) => r.status === "fulfilled" && r.value === true);
    return anySuccess
      ? { success: true, eventId: event.id }
      : { success: false, error: "Failed to publish follow to any relay" };
  } catch (e) {
    return { success: false, error: e instanceof Error ? e.message : String(e) };
  }
}

/**
 * Unfollow a Nostr pubkey by removing it from the kind-3 contact list and
 * re-publishing. Same merge-then-publish shape as publishNostrFollow.
 */
export async function publishNostrUnfollow(
  unfollowPubkey: string,
  relays: string[] = DEFAULT_RELAYS
): Promise<{ success: boolean; eventId?: string; error?: string }> {
  const privkey = localStorage.getItem(STORAGE_KEY_NOSTR_PRIVKEY);
  const pubkey = localStorage.getItem(STORAGE_KEY_NOSTR_PUBKEY);
  if (!privkey || !pubkey) {
    return { success: false, error: "No Nostr key configured" };
  }
  try {
    const existing = await fetchNostrFollowSet(pubkey, relays);
    const follows = existing.filter((pk) => pk !== unfollowPubkey);
    const tags = follows.map((pk) => ["p", pk]);
    const event = await createSignedEvent(privkey, 3, "", tags);

    const results = await Promise.allSettled(
      relays.map(
        (relay) =>
          new Promise<boolean>((resolve) => {
            const ws = new WebSocket(relay);
            const timeout = setTimeout(() => { ws.close(); resolve(false); }, 5000);
            ws.onopen = () => { ws.send(JSON.stringify(["EVENT", event])); };
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
    const anySuccess = results.some((r) => r.status === "fulfilled" && r.value === true);
    return anySuccess
      ? { success: true, eventId: event.id }
      : { success: false, error: "Failed to publish unfollow to any relay" };
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
  // Delegate to the canonical generator (keeps localStorage + return shape in sync).
  return generateAndSaveNostrKeys();
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
