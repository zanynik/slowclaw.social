/**
 * useLensProfile — hydrate the unified curation lens from SQLite.
 *
 * The single store for the lens lives in state/local_data.db (journal +
 * liked-card keywords as positives, disliked-card keywords as negatives,
 * mute/boost overrides, and manual interests). This hook reads it in one
 * `getInterestProfile()` Tauri call on mount and whenever the lens changes
 * (same-tab `slowclaw:lens-change` event fired by the lens mutators).
 *
 * On non-Tauri runtimes (web/dev) it returns `null` so callers fall back to
 * the localStorage path — the SQLite store only exists behind the Tauri host.
 *
 * Returned shape mirrors the TS ranker's needs: overrides as a label→multiplier
 * map, manual interests as a string[], and positive/negative LensTerm lists.
 */
import { useCallback, useEffect, useState } from "react";
import {
  getInterestProfile,
  type InterestProfileSnapshot,
  type LensTerm,
} from "../lib/tauriApi";

export type { LensTerm };

// Inlined minimal Tauri-mobile detection (mirrors App.tsx's isTauriMobileRuntime)
// to avoid importing from App.tsx, which would create a circular dependency.
// The SQLite lens store only exists behind the Tauri mobile host.
function isTauriMobileRuntime(): boolean {
  if (typeof window === "undefined") return false;
  return Boolean((window as unknown as { __TAURI_MOBILE__?: boolean }).__TAURI_MOBILE__);
}

export interface LensProfileState {
  /** label (lowercase) → multiplier, for the TS ranker + lens UI. */
  overrides: Record<string, number>;
  /** Manual interests (lowercase). */
  manual: string[];
  /** Positive terms with lens multipliers applied (positives from snapshot). */
  positives: LensTerm[];
  /** Negative (disliked) terms. */
  negatives: LensTerm[];
  /** Monotonic counter that bumps after every successful re-hydration, so
   *  dependent memos can list it as a dependency without depending on the
   *  array contents (which would over-trigger). */
  seed: number;
}

const EVENT_NAME = "slowclaw:lens-change";

function isBrowser(): boolean {
  return typeof window !== "undefined";
}

/**
 * Fire the same-tab lens-change event so this hook (and any other listener)
 * re-hydrates after a lens mutation. Cross-tab updates are out of scope: the
 * SQLite store is per-device and the Tauri app is single-window on mobile.
 */
export function notifyLensChange(): void {
  if (!isBrowser()) return;
  window.dispatchEvent(new CustomEvent(EVENT_NAME));
}

/**
 * Subscribe to lens changes (same-tab). Returns an unsubscribe fn.
 */
export function onLensChange(cb: () => void): () => void {
  if (!isBrowser()) return () => {};
  const handler = () => cb();
  window.addEventListener(EVENT_NAME, handler);
  return () => window.removeEventListener(EVENT_NAME, handler);
}

function snapshotToState(snapshot: InterestProfileSnapshot, seed: number): LensProfileState {
  const overrides: Record<string, number> = {};
  for (const entry of snapshot.overrides) {
    overrides[entry.term.toLowerCase()] = entry.multiplier;
  }
  return {
    overrides,
    manual: snapshot.manual.map((m) => m.toLowerCase()),
    positives: snapshot.positives,
    negatives: snapshot.negatives,
    seed,
  };
}

export function useLensProfile(): { state: LensProfileState | null; refresh: () => void } {
  const [state, setState] = useState<LensProfileState | null>(null);
  const [seed, setSeed] = useState(0);

  const refresh = useCallback(() => {
    if (!isTauriMobileRuntime()) return;
    getInterestProfile()
      .then((snapshot) => {
        setSeed((n) => n + 1);
        setState(snapshotToState(snapshot, seed + 1));
      })
      .catch((err) => {
        // Non-fatal: the lens falls back to the localStorage path. Logged so
        // a broken SQLite read doesn't silently degrade ranking.
        console.warn("[useLensProfile] getInterestProfile failed", err);
      });
  }, [seed]);

  // Hydrate on mount + whenever refresh identity changes (it captures seed).
  useEffect(() => {
    refresh();
  }, [refresh]);

  // Re-hydrate on same-tab lens mutations.
  useEffect(() => onLensChange(refresh), [refresh]);

  return { state, refresh };
}
