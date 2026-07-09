/**
 * interestProfile.ts — local-first, editable steering layer for the curation lens.
 *
 * The "journal is the lens" signal is derived automatically from journals
 * (extractJournalTopics, lib/socialFeed.ts). This module makes it a DIAL the
 * user controls, on top of the auto-derived topics:
 *
 *   - Mute: drop a journal-derived topic from the lens entirely (multiplier 0).
 *   - Boost: raise a topic's weight so it's prioritized in ranking (multiplier 2).
 *   - Reset: return a topic to its as-derived weight (remove the override).
 *   - Add: introduce a manual interest the journals haven't surfaced yet, so the
 *     lens can follow things the user cares about before they've written about
 *     them (e.g. importing an interest from their old reader).
 *
 * Everything is localStorage-backed and dependency-free, mirroring follows.ts /
 * savedItems.ts. App.tsx subscribes via onInterestChange and recomputes the lens.
 *
 * The weight model feeds the existing journalTopicBoost ranker: a topic's
 * effective weight = derivedWeight * multiplier (overrides) or a default for
 * manual interests. Mute (multiplier 0) removes it; the ranker drops zero-weight
 * topics so muted content stops surfacing in Reads / YouTube / Nostr cold-start.
 */

const OVERRIDES_KEY = "slowclaw.interest.overrides.v1";
const MANUAL_KEY = "slowclaw.interest.manual.v1";
const EVENT_NAME = "slowclaw:interest-change";

/** Discrete multiplier states (kept small + legible rather than a free number). */
export const INTEREST_MULT = {
  MUTE: 0,
  NORMAL: 1,
  BOOST: 2,
} as const;

/** One override: a weight multiplier applied to a topic's derived weight. */
export interface InterestOverride {
  multiplier: number;
}

/** label (lowercased) -> override. */
export type InterestOverrides = Record<string, InterestOverride>;

function readOverrides(): InterestOverrides {
  if (typeof window === "undefined") return {};
  try {
    const raw = window.localStorage.getItem(OVERRIDES_KEY);
    if (!raw) return {};
    const parsed = JSON.parse(raw);
    if (!parsed || typeof parsed !== "object") return {};
    const out: InterestOverrides = {};
    for (const [k, v] of Object.entries(parsed as Record<string, unknown>)) {
      const mult =
        v && typeof v === "object" && "multiplier" in (v as Record<string, unknown>)
          ? Number((v as Record<string, unknown>).multiplier)
          : NaN;
      if (Number.isFinite(mult)) out[String(k).toLowerCase()] = { multiplier: mult };
    }
    return out;
  } catch {
    return {};
  }
}

function writeOverrides(overrides: InterestOverrides): void {
  if (typeof window === "undefined") return;
  try {
    window.localStorage.setItem(OVERRIDES_KEY, JSON.stringify(overrides));
    window.dispatchEvent(new CustomEvent(EVENT_NAME, { detail: { key: OVERRIDES_KEY } }));
  } catch {
    /* quota error — non-fatal, local-only feature */
  }
}

function normalizeLabel(label: string): string {
  return label.trim().toLowerCase();
}

export function getInterestOverrides(): InterestOverrides {
  return readOverrides();
}

/** Current multiplier for a label, or NORMAL (1) when no override is set. */
export function interestMultiplierFor(label: string): number {
  const key = normalizeLabel(label);
  return readOverrides()[key]?.multiplier ?? INTEREST_MULT.NORMAL;
}

/** Set a topic's multiplier (use INTEREST_MULT). Also the mute lever (0). */
export function setInterestMultiplier(label: string, multiplier: number): void {
  const key = normalizeLabel(label);
  if (!key) return;
  const overrides = readOverrides();
  overrides[key] = { multiplier };
  writeOverrides(overrides);
}

/** Remove an override so the topic returns to its as-derived weight. */
export function removeInterestOverride(label: string): void {
  const key = normalizeLabel(label);
  const overrides = readOverrides();
  if (key in overrides) {
    delete overrides[key];
    writeOverrides(overrides);
  }
}

/* ── Manual interests (topics not yet in the journals) ──────────────────── */

function readManual(): string[] {
  if (typeof window === "undefined") return [];
  try {
    const raw = window.localStorage.getItem(MANUAL_KEY);
    if (!raw) return [];
    const parsed = JSON.parse(raw);
    if (!Array.isArray(parsed)) return [];
    const seen = new Set<string>();
    const out: string[] = [];
    for (const v of parsed) {
      if (typeof v !== "string") continue;
      const key = v.trim().toLowerCase();
      if (!key || seen.has(key)) continue;
      seen.add(key);
      out.push(key);
    }
    return out;
  } catch {
    return [];
  }
}

function writeManual(list: string[]): void {
  if (typeof window === "undefined") return;
  try {
    window.localStorage.setItem(MANUAL_KEY, JSON.stringify(list));
    window.dispatchEvent(new CustomEvent(EVENT_NAME, { detail: { key: MANUAL_KEY } }));
  } catch {
    /* quota error — non-fatal */
  }
}

export function getManualInterests(): string[] {
  return readManual();
}

/** Add a manual interest. Returns true if added (was new). Trims/lowercases. */
export function addManualInterest(label: string): boolean {
  const key = normalizeLabel(label);
  if (!key) return false;
  const list = readManual();
  if (list.includes(key)) return false;
  writeManual([...list, key]);
  return true;
}

export function removeManualInterest(label: string): void {
  const key = normalizeLabel(label);
  const list = readManual().filter((x) => x !== key);
  writeManual(list);
}

/** Subscribe to same-tab + cross-tab interest changes. Returns unsubscribe. */
export function onInterestChange(cb: () => void): () => void {
  if (typeof window === "undefined") return () => {};
  const handler = () => cb();
  window.addEventListener(EVENT_NAME, handler);
  window.addEventListener("storage", handler);
  return () => {
    window.removeEventListener(EVENT_NAME, handler);
    window.removeEventListener("storage", handler);
  };
}
