import type { NostrKeys } from "./secureStorage";

// Nostr key generation using Web Crypto API + manual bech32/schnorr
// We use secp256k1 point multiplication for public key derivation.
// For a lightweight frontend-only approach, we use the noble-secp256k1 algorithm.

const BECH32_CHARSET = "qpzry9x8gf2tvdw0s3jn54khce6mua7l";

function bech32Polymod(values: number[]): number {
  const GEN = [0x3b6a57b2, 0x26508e6d, 0x1ea119fa, 0x3d4233dd, 0x2a1462b3];
  let chk = 1;
  for (const v of values) {
    const b = chk >> 25;
    chk = ((chk & 0x1ffffff) << 5) ^ v;
    for (let i = 0; i < 5; i++) {
      if ((b >> i) & 1) chk ^= GEN[i];
    }
  }
  return chk;
}

function bech32HrpExpand(hrp: string): number[] {
  const ret: number[] = [];
  for (let i = 0; i < hrp.length; i++) ret.push(hrp.charCodeAt(i) >> 5);
  ret.push(0);
  for (let i = 0; i < hrp.length; i++) ret.push(hrp.charCodeAt(i) & 31);
  return ret;
}

function bech32Encode(hrp: string, data: number[]): string {
  const combined = [...data];
  const polymod = bech32Polymod([...bech32HrpExpand(hrp), ...combined, 0, 0, 0, 0, 0, 0]) ^ 1;
  for (let i = 0; i < 6; i++) combined.push((polymod >> (5 * (5 - i))) & 31);
  return hrp + "1" + combined.map((d) => BECH32_CHARSET[d]).join("");
}

function convertBits(data: Uint8Array, fromBits: number, toBits: number, pad: boolean): number[] {
  let acc = 0;
  let bits = 0;
  const ret: number[] = [];
  const maxv = (1 << toBits) - 1;
  for (const value of data) {
    acc = (acc << fromBits) | value;
    bits += fromBits;
    while (bits >= toBits) {
      bits -= toBits;
      ret.push((acc >> bits) & maxv);
    }
  }
  if (pad && bits > 0) {
    ret.push((acc << (toBits - bits)) & maxv);
  }
  return ret;
}

function hexToBytes(hex: string): Uint8Array {
  const bytes = new Uint8Array(hex.length / 2);
  for (let i = 0; i < hex.length; i += 2) {
    bytes[i / 2] = parseInt(hex.substring(i, i + 2), 16);
  }
  return bytes;
}

function bytesToHex(bytes: Uint8Array): string {
  return Array.from(bytes)
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("");
}

function encodeBech32(hrp: string, keyHex: string): string {
  const data = convertBits(hexToBytes(keyHex), 8, 5, true);
  return bech32Encode(hrp, data);
}

// Minimal secp256k1 public key derivation (x-only / Schnorr)
// Using the curve equation y^2 = x^3 + 7 over the prime field p
const P = BigInt("0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEFFFFFC2F");
const N = BigInt("0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141");
const Gx = BigInt("0x79BE667EF9DCBBAC55A06295CE870B07029BFCDB2DCE28D959F2815B16F81798");
const Gy = BigInt("0x483ADA7726A3C4655DA4FBFC0E1108A8FD17B448A68554199C47D08FFB10D4B8");

function mod(a: bigint, m: bigint): bigint {
  return ((a % m) + m) % m;
}

function modInverse(a: bigint, m: bigint): bigint {
  return modPow(a, m - 2n, m);
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

type Point = { x: bigint; y: bigint } | null;

function pointAdd(p1: Point, p2: Point): Point {
  if (!p1) return p2;
  if (!p2) return p1;
  if (p1.x === p2.x && p1.y === p2.y) {
    const s = mod(3n * p1.x * p1.x * modInverse(2n * p1.y, P), P);
    const x = mod(s * s - 2n * p1.x, P);
    const y = mod(s * (p1.x - x) - p1.y, P);
    return { x, y };
  }
  if (p1.x === p2.x) return null;
  const s = mod((p2.y - p1.y) * modInverse(p2.x - p1.x, P), P);
  const x = mod(s * s - p1.x - p2.x, P);
  const y = mod(s * (p1.x - x) - p1.y, P);
  return { x, y };
}

function pointMul(k: bigint, point: Point): Point {
  let result: Point = null;
  let addend: Point = point;
  let scalar = mod(k, N);
  while (scalar > 0n) {
    if (scalar & 1n) result = pointAdd(result, addend);
    addend = pointAdd(addend, addend);
    scalar >>= 1n;
  }
  return result;
}

function getPublicKeyHex(secretKeyHex: string): string {
  const sk = BigInt("0x" + secretKeyHex);
  const pub = pointMul(sk, { x: Gx, y: Gy });
  if (!pub) throw new Error("Invalid secret key");
  return pub.x.toString(16).padStart(64, "0");
}

export async function generateNostrKeys(): Promise<NostrKeys> {
  const secretBytes = new Uint8Array(32);
  crypto.getRandomValues(secretBytes);
  const secretKeyHex = bytesToHex(secretBytes);
  const publicKeyHex = getPublicKeyHex(secretKeyHex);
  const nsec = encodeBech32("nsec", secretKeyHex);
  const npub = encodeBech32("npub", publicKeyHex);
  return { nsec, npub, secretKeyHex, publicKeyHex };
}

// Nostr event creation and signing (NIP-01)
export type NostrEvent = {
  id: string;
  pubkey: string;
  created_at: number;
  kind: number;
  tags: string[][];
  content: string;
  sig: string;
};

async function sha256(data: Uint8Array): Promise<Uint8Array> {
  const hash = await crypto.subtle.digest("SHA-256", data as ArrayBufferView<ArrayBuffer>);
  return new Uint8Array(hash);
}

function serializeEvent(
  pubkey: string,
  created_at: number,
  kind: number,
  tags: string[][],
  content: string
): string {
  return JSON.stringify([0, pubkey, created_at, kind, tags, content]);
}

async function computeEventId(
  pubkey: string,
  created_at: number,
  kind: number,
  tags: string[][],
  content: string
): Promise<string> {
  const serialized = serializeEvent(pubkey, created_at, kind, tags, content);
  const encoded = new TextEncoder().encode(serialized);
  const hash = await sha256(encoded);
  return bytesToHex(hash);
}

// BIP-340 Schnorr signature (simplified for Nostr)
async function schnorrSign(messageHex: string, secretKeyHex: string): Promise<string> {
  const sk = BigInt("0x" + secretKeyHex);
  const pubPoint = pointMul(sk, { x: Gx, y: Gy });
  if (!pubPoint) throw new Error("Invalid key");

  // If y is odd, negate secret key
  let d = sk;
  if (pubPoint.y & 1n) d = N - d;

  // Deterministic nonce: aux = sha256(sk) for simplicity
  const skBytes = hexToBytes(secretKeyHex);
  const aux = await sha256(skBytes);
  const msgBytes = hexToBytes(messageHex);

  // t = d XOR sha256(aux)
  const dBytes = hexToBytes(d.toString(16).padStart(64, "0"));
  const auxHash = await sha256(aux);
  const t = new Uint8Array(32);
  for (let i = 0; i < 32; i++) t[i] = dBytes[i] ^ auxHash[i];

  // nonce = sha256(t || pubx || msg)
  const pubxBytes = hexToBytes(pubPoint.x.toString(16).padStart(64, "0"));
  const nonceInput = new Uint8Array(32 + 32 + msgBytes.length);
  nonceInput.set(t, 0);
  nonceInput.set(pubxBytes, 32);
  nonceInput.set(msgBytes, 64);
  const nonceHash = await sha256(nonceInput);
  let k = BigInt("0x" + bytesToHex(nonceHash));
  k = mod(k, N);
  if (k === 0n) throw new Error("Nonce is zero");

  const R = pointMul(k, { x: Gx, y: Gy });
  if (!R) throw new Error("R is infinity");
  if (R.y & 1n) k = N - k;

  // e = sha256(R.x || pubx || msg)
  const Rx = hexToBytes(R.x.toString(16).padStart(64, "0"));
  const eInput = new Uint8Array(32 + 32 + msgBytes.length);
  eInput.set(Rx, 0);
  eInput.set(pubxBytes, 32);
  eInput.set(msgBytes, 64);
  const eHash = await sha256(eInput);
  const e = BigInt("0x" + bytesToHex(eHash));

  const s = mod(k + e * d, N);
  return bytesToHex(Rx) + s.toString(16).padStart(64, "0");
}

export async function createSignedEvent(
  keys: NostrKeys,
  kind: number,
  content: string,
  tags: string[][]
): Promise<NostrEvent> {
  const created_at = Math.floor(Date.now() / 1000);
  const id = await computeEventId(keys.publicKeyHex, created_at, kind, tags, content);
  const sig = await schnorrSign(id, keys.secretKeyHex);
  return {
    id,
    pubkey: keys.publicKeyHex,
    created_at,
    kind,
    tags,
    content,
    sig
  };
}

// Publish an event to a Nostr relay via WebSocket
export function publishToRelay(relayUrl: string, event: NostrEvent): Promise<boolean> {
  return new Promise((resolve) => {
    const timeout = setTimeout(() => {
      try { ws.close(); } catch { /* ignore */ }
      resolve(false);
    }, 8000);

    const ws = new WebSocket(relayUrl);
    ws.onopen = () => {
      ws.send(JSON.stringify(["EVENT", event]));
    };
    ws.onmessage = (msg) => {
      try {
        const data = JSON.parse(msg.data);
        if (Array.isArray(data) && data[0] === "OK") {
          clearTimeout(timeout);
          ws.close();
          resolve(Boolean(data[2]));
          return;
        }
      } catch { /* ignore parse errors */ }
    };
    ws.onerror = () => {
      clearTimeout(timeout);
      resolve(false);
    };
  });
}
