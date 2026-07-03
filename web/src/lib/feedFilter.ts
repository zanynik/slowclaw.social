/**
 * feedFilter.ts — content-quality filtering for Nostr (and reuse for RSS/articles).
 *
 * Nostr has NO server-side language or quality filtering: a global firehose or
 * NIP-12 hashtag subscription returns whatever the relay has, including spam,
 * bots, and non-English content. This module applies the filtering strategies
 * used by mature Nostr clients (notably Amethyst / vitorpamplona/amethyst):
 *
 *   1. LANGUAGE filtering — detect the dominant script of each note and drop
 *      notes written in scripts the user hasn't allowed. This catches the bulk
 *      of non-English noise (Japanese/Chinese, Korean, Russian/Cyrillic,
 *      Arabic, Hebrew, Thai, Devanagari) which is the most common complaint on
 *      the global firehose. Latin-script detection deliberately lets through
 *      English + other Latin languages; for exact-language needs we additionally
 *      check the declared `L`/`alt` language tag where present.
 *
 *   2. SPAM / low-quality heuristics — drop:
 *        - URL-only notes (no real text)
 *        - hashtag spam (> 6 hashtags)
 *        - NIP-36 content-warning notes (blurred/NSFW) — hidden from public feed
 *        - very short / empty notes
 *        - repetitive bot templates (testnet "Block found!" etc.)
 *
 *   3. DEDUP by pubkey — a single pubkey flooding a window is a strong spam
 *      signal; keep at most N notes per pubkey (newest first).
 *
 * These are pure functions so they can be unit-tested without a relay.
 */

import type { NostrNote } from "./nostr";

export type Script =
  | "latin"
  | "cjk"
  | "kana"
  | "hangul"
  | "cyrillic"
  | "arabic"
  | "hebrew"
  | "thai"
  | "devanagari"
  | "other";

export type LanguageFilterOptions = {
  /** Scripts allowed through. Defaults to latin-only (English + Latin langs). */
  allowScripts?: Script[];
  /** If true, also accept a note when it declares an allowed `L` language tag. */
  honorLanguageTag?: boolean;
  /** Allowed BCP-47 language codes when honoring the tag (default ["en"]). */
  allowedLanguages?: string[];
};

export const DEFAULT_ALLOWED_SCRIPTS: Script[] = ["latin"];

/**
 * Classify the dominant non-emoji script of a piece of text. Emoji and common
 * symbols/punctuation are ignored so that an English note full of emoji still
 * classifies as "latin" (not "other"). Returns the first strongly-matching
 * script, or "latin" if only Latin/punct/emoji is present.
 */
export function detectScript(text: string): Script {
  if (!text) return "latin";
  const sample = text.slice(0, 400);
  const counts: Record<Script, number> = {
    latin: 0, cjk: 0, kana: 0, hangul: 0, cyrillic: 0,
    arabic: 0, hebrew: 0, thai: 0, devanagari: 0, other: 0,
  };
  for (const ch of sample) {
    const cp = ch.codePointAt(0)!;
    if (cp <= 0x7f) {
      if (/[a-zA-Z]/.test(ch)) counts.latin++;
      continue; // digits/punct/space ignored
    }
    if (cp >= 0x1f000) continue; // emoji & pictographs — neutral
    if (cp >= 0x4e00 && cp <= 0x9fff) counts.cjk++;
    else if (cp >= 0x3040 && cp <= 0x30ff) counts.kana++; // hiragana/katakana
    else if (cp >= 0xac00 && cp <= 0xd7af) counts.hangul++; // korean
    else if (cp >= 0x0400 && cp <= 0x04ff) counts.cyrillic++;
    else if (cp >= 0x0600 && cp <= 0x06ff) counts.arabic++;
    else if (cp >= 0x0590 && cp <= 0x05ff) counts.hebrew++;
    else if (cp >= 0x0e00 && cp <= 0x0e7f) counts.thai++;
    else if (cp >= 0x0900 && cp <= 0x097f) counts.devanagari++;
    else if (cp >= 0x2500) continue; // box drawing / symbols — neutral
    else counts.latin++; // Latin-1 supplement (à, é, ü, etc.) counts as latin
  }
  // Find the dominant non-latin script.
  const order: Script[] = ["kana", "cjk", "hangul", "cyrillic", "arabic", "hebrew", "thai", "devanagari", "other"];
  let best: Script | null = null;
  let bestN = 0;
  for (const s of order) {
    if (counts[s] > bestN) { bestN = counts[s]; best = s; }
  }
  // Treat CJK + kana together as "japanese/chinese" — collapse kana→cjk for the
  // dominant-script decision since they almost always co-occur in Japanese.
  if (best === "kana" || best === "cjk") {
    if (counts.kana > 0) return "kana"; // kana present ⇒ Japanese specifically
    return "cjk";
  }
  return best ?? "latin";
}

/** Declared language on a Nostr note (NIP-style `L` tag, informal). */
export function noteLanguageTag(note: NostrNote): string | null {
  for (const tag of note.tags || []) {
    if (!tag || tag.length < 2) continue;
    if (tag[0] === "L" || tag[0] === "alt") {
      const v = String(tag[1] || "");
      if (/^[a-z]{2}(-[a-z0-9]+)?$/i.test(v)) return v.toLowerCase();
    }
    // content language: ["cl", "en"] (informal, some clients)
    if (tag[0] === "cl") {
      const v = String(tag[1] || "");
      if (/^[a-z]{2}$/i.test(v)) return v.toLowerCase();
    }
  }
  return null;
}

/** True if the note's declared language is in the allowlist. */
export function passesLanguageTag(
  note: NostrNote,
  allowed: string[] = ["en"],
): boolean {
  const tag = noteLanguageTag(note);
  if (!tag) return false;
  return allowed.includes(tag);
}

export function passesLanguageFilter(
  text: string,
  opts: LanguageFilterOptions = {},
): boolean {
  const allow = opts.allowScripts ?? DEFAULT_ALLOWED_SCRIPTS;
  const script = detectScript(text);
  if (allow.includes(script)) return true;
  return false;
}

/** Spam-reason strings; the matching UI shows why a note was dropped. */
export type SpamReason =
  | "empty"
  | "url-only"
  | "hashtag-spam"
  | "content-warning"
  | "too-short"
  | "bot-template";

const BOT_TEMPLATES = [
  /^block found!/i,
  /^network:\s*testnet/i,
  /^hash:\s*0{6,}/i,
  // Lightning/payment-required spam
  /^lightning address/i,
];

/**
 * Classify a note as spam/low-quality. Returns the reason, or null if clean.
 * Mirrors Amethyst's lightweight spam heuristics (URL-only, hashtag spam,
 * NIP-36 content warnings, repetitive bot templates).
 */
export function classifyNostrSpam(note: NostrNote): SpamReason | null {
  const t = (note.content || "").trim();
  if (!t) return "empty";
  if (t.length < 3) return "too-short";
  // NIP-36 content warning → hide from public discovery feed.
  for (const tag of note.tags || []) {
    if (tag[0] === "content-warning") return "content-warning";
    if (tag[0] === "L" && /content-?warning/i.test(String(tag[1] || ""))) return "content-warning";
  }
  // Hashtag spam: > 6 hashtags is a strong spam signal.
  const hashtags = t.match(/#[a-z0-9_]{2,}/gi) || [];
  if (hashtags.length > 6) return "hashtag-spam";
  // URL-only note: after stripping URLs + hashtags + whitespace, almost nothing.
  const stripped = t
    .replace(/https?:\/\/\S+/gi, "")
    .replace(/#[\w]+/g, "")
    .replace(/[\s\W]/g, "");
  if (stripped.length < 3) return "url-only";
  // Repetitive bot templates (testnet block announces, etc.).
  for (const re of BOT_TEMPLATES) {
    if (re.test(t)) return "bot-template";
  }
  return null;
}

/**
 * Composed Nostr feed filter: language + spam + dedup. Returns the filtered
 * list (preserving order). `opts.stats` (if passed) is filled with drop counts
 * so the UI can show "filtered N spam / M non-English".
 */
export type NostrFeedStats = {
  total: number;
  droppedNonLanguage: number;
  droppedSpam: Partial<Record<SpamReason, number>>;
  droppedDuplicate: number;
};

export type NostrFeedFilterOptions = LanguageFilterOptions & {
  maxPerPubkey?: number;
  stats?: NostrFeedStats;
};

export function filterNostrFeed(
  notes: NostrNote[],
  opts: NostrFeedFilterOptions = {},
): NostrNote[] {
  const allow = opts.allowScripts ?? DEFAULT_ALLOWED_SCRIPTS;
  const allowedLangs = opts.allowedLanguages ?? ["en"];
  const maxPerPubkey = opts.maxPerPubkey ?? 2;
  const stats: NostrFeedStats = {
    total: notes.length,
    droppedNonLanguage: 0,
    droppedSpam: {},
    droppedDuplicate: 0,
  };

  const seen = new Set<string>();
  const pubkeyCount: Record<string, number> = {};
  const out: NostrNote[] = [];

  // Process newest-first for dedup-by-pubkey to keep the freshest per pubkey.
  const ordered = [...notes].sort((a, b) => (b.createdAt ?? 0) - (a.createdAt ?? 0));

  for (const note of ordered) {
    if (seen.has(note.id)) continue;
    seen.add(note.id);

    // 1. Language
    const script = detectScript(note.content || "");
    const tagOk = opts.honorLanguageTag && passesLanguageTag(note, allowedLangs);
    if (!allow.includes(script) && !tagOk) {
      stats.droppedNonLanguage++;
      continue;
    }
    // 2. Spam
    const spam = classifyNostrSpam(note);
    if (spam) {
      stats.droppedSpam[spam] = (stats.droppedSpam[spam] || 0) + 1;
      continue;
    }
    // 3. Dedup by pubkey
    const pk = note.pubkey;
    pubkeyCount[pk] = (pubkeyCount[pk] || 0) + 1;
    if (pubkeyCount[pk] > maxPerPubkey) {
      stats.droppedDuplicate++;
      continue;
    }
    out.push(note);
  }

  // Restore chronological (newest-first) order for display.
  out.sort((a, b) => (b.createdAt ?? 0) - (a.createdAt ?? 0));
  if (opts.stats) Object.assign(opts.stats, stats);
  return out;
}

/**
 * Lightweight Latin-script check reused by RSS/article filters. Returns true
 * when the title/body is predominantly Latin (lets English + most European
 * languages through, drops CJK/Cyrillic/Arabic/etc.).
 */
export function isLatinText(text: string): boolean {
  return passesLanguageFilter(text, { allowScripts: DEFAULT_ALLOWED_SCRIPTS });
}
