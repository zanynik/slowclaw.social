/**
 * useKeyboardHeight.ts — Tracks virtual keyboard height on iOS.
 *
 * Mobile WebViews don't reliably report keyboard presence.
 * This hook uses visualViewport API to detect and report the
 * keyboard height, so we can adjust bottom nav positioning
 * and input scroll behavior.
 */

import { useState, useEffect } from "react";

export function useKeyboardHeight(): number {
  const [keyboardHeight, setKeyboardHeight] = useState(0);

  useEffect(() => {
    if (typeof window === "undefined") return;

    const vv = window.visualViewport;
    if (!vv) return;

    function handleResize() {
      if (!vv) return;
      // When the keyboard opens, visualViewport.height shrinks
      const viewportDiff = window.innerHeight - vv.height;
      // Only report as keyboard if diff is significant (> 100px)
      setKeyboardHeight(viewportDiff > 100 ? viewportDiff : 0);
    }

    vv.addEventListener("resize", handleResize);
    vv.addEventListener("scroll", handleResize);

    return () => {
      vv.removeEventListener("resize", handleResize);
      vv.removeEventListener("scroll", handleResize);
    };
  }, []);

  return keyboardHeight;
}

/**
 * Returns true when the on-screen keyboard is likely visible.
 */
export function useIsKeyboardOpen(): boolean {
  return useKeyboardHeight() > 0;
}
