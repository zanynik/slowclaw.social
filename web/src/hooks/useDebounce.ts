/**
 * useDebounce.ts — Debounced value and callback hooks.
 *
 * Extracted from the autosave timer patterns in App.tsx.
 * Cleans up the manual setTimeout/clearTimeout ref management
 * into a reusable, tested pattern.
 */

import { useState, useEffect, useRef, useCallback } from "react";

/**
 * Returns a debounced version of `value` that only updates after `delay` ms
 * of inactivity. Useful for search inputs and autosave triggers.
 */
export function useDebounce<T>(value: T, delay: number): T {
  const [debounced, setDebounced] = useState(value);

  useEffect(() => {
    const timer = setTimeout(() => setDebounced(value), delay);
    return () => clearTimeout(timer);
  }, [value, delay]);

  return debounced;
}

/**
 * Returns a debounced callback that fires after `delay` ms of inactivity.
 * The callback always sees the latest closure values.
 */
export function useDebouncedCallback<Args extends unknown[]>(
  callback: (...args: Args) => void,
  delay: number,
): (...args: Args) => void {
  const timerRef = useRef<ReturnType<typeof setTimeout> | null>(null);
  const callbackRef = useRef(callback);
  callbackRef.current = callback;

  useEffect(() => {
    return () => {
      if (timerRef.current) clearTimeout(timerRef.current);
    };
  }, []);

  return useCallback(
    (...args: Args) => {
      if (timerRef.current) clearTimeout(timerRef.current);
      timerRef.current = setTimeout(() => callbackRef.current(...args), delay);
    },
    [delay],
  );
}

/**
 * Runs a callback on the debounced value change.
 * Perfect for autosave: `useAutosave(text, 700, (val) => saveToBackend(val))`
 */
export function useAutosave<T>(
  value: T,
  delay: number,
  save: (value: T) => void | Promise<void>,
  enabled: boolean = true,
) {
  const debouncedValue = useDebounce(value, delay);
  const savedValueRef = useRef(value);
  const saveRef = useRef(save);
  saveRef.current = save;

  useEffect(() => {
    if (!enabled) return;
    // Skip the first render (don't save the initial loaded value)
    if (debouncedValue === savedValueRef.current) return;
    savedValueRef.current = debouncedValue;
    void saveRef.current(debouncedValue);
  }, [debouncedValue, enabled]);
}
