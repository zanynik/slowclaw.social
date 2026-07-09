/**
 * useLocalFirstList — Damus-style local-first list hydration.
 *
 * Philosophy: the UI should never wait on the network to show content. On mount
 * the last-good list is read from localStorage synchronously and rendered
 * immediately; a background refresh then fetches fresh data and, on success,
 * both updates the UI and persists the new list back to localStorage so the
 * next open is instant. On refresh failure the cached list is kept (never
 * blanked), mirroring how Nostr/video local stores already behave.
 *
 * This is a thin, dependency-free hook — no global store, no context. Each call
 * site owns its localStorage key and refresh function.
 */
import { useCallback, useEffect, useRef, useState } from "react";

export interface LocalFirstListState<T> {
  /** The list to render: cached on first paint, refreshed after a load. */
  items: T[];
  /** True while the (background) refresh is in flight. */
  loading: boolean;
  /** Set when the most recent refresh failed (cache still shown). */
  error: string | null;
  /** Re-run the refresh. Safe to call from a pull-to-refresh. */
  refresh: () => void;
  /** Replace the cached list immediately (e.g. after an in-place mutation). */
  setItems: (next: T[] | ((prev: T[]) => T[])) => void;
}

function readCache<T>(key: string): T[] {
  if (typeof window === "undefined") return [];
  try {
    const raw = window.localStorage.getItem(key);
    if (!raw) return [];
    const parsed = JSON.parse(raw);
    return Array.isArray(parsed) ? (parsed as T[]) : [];
  } catch {
    return [];
  }
}

function writeCache<T>(key: string, items: T[]): void {
  if (typeof window === "undefined") return;
  try {
    window.localStorage.setItem(key, JSON.stringify(items));
  } catch {
    // Quota / serialization errors are non-fatal — the list still renders
    // from React state for this session; next open just won't be cached.
  }
}

/**
 * @param storageKey  Unique localStorage key for this list.
 * @param refresh     Returns a fresh list. Called on mount + manual refresh.
 * @param deps        When these change, refresh is re-run (like useEffect deps).
 */
export function useLocalFirstList<T>(
  storageKey: string,
  refresh: () => Promise<T[]>,
  deps: ReadonlyArray<unknown> = [],
): LocalFirstListState<T> {
  // Seed from cache synchronously so first paint is instant.
  const [items, setItemsState] = useState<T[]>(() => readCache<T>(storageKey));
  const [loading, setLoading] = useState<boolean>(false);
  const [error, setError] = useState<string | null>(null);

  // Keep the latest refresh fn without retriggering the mount effect.
  const refreshRef = useRef(refresh);
  refreshRef.current = refresh;
  // Avoid clobbering cache with a stale write after unmount.
  const mountedRef = useRef(true);

  const run = useCallback(async () => {
    setLoading(true);
    setError(null);
    try {
      const next = await refreshRef.current();
      if (!mountedRef.current) return;
      setItemsState(next);
      writeCache(storageKey, next);
    } catch (err) {
      if (!mountedRef.current) return;
      setError(err instanceof Error ? err.message : String(err));
      // Cache is intentionally preserved on failure.
    } finally {
      if (mountedRef.current) setLoading(false);
    }
  }, [storageKey]);

  // eslint-disable-next-line react-hooks/exhaustive-deps
  useEffect(() => {
    mountedRef.current = true;
    void run();
    return () => {
      mountedRef.current = false;
    };
    // Re-run when the caller-declared deps change (e.g. topic filter).
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, deps);

  const setItems = useCallback(
    (next: T[] | ((prev: T[]) => T[])) => {
      setItemsState((prev) => {
        const resolved = typeof next === "function" ? (next as (p: T[]) => T[])(prev) : next;
        writeCache(storageKey, resolved);
        return resolved;
      });
    },
    [storageKey],
  );

  return { items, loading, error, refresh: () => void run(), setItems };
}
