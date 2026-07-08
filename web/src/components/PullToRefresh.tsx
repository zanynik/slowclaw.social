/**
 * PullToRefresh.tsx — Native-feeling pull-to-refresh for mobile views.
 *
 * Implements iOS-style pull-to-refresh with:
 * - Rubber-band overscroll physics
 * - Spinner animation at threshold
 * - Haptic feedback trigger point
 * - Works within Tauri mobile WebView
 */

import { useRef, useState, type ReactNode, type RefObject, type TouchEvent } from "react";

type PullToRefreshProps = {
  children: ReactNode;
  onRefresh: () => Promise<void> | void;
  enabled?: boolean;
  threshold?: number;
  className?: string;
  /**
   * Optional ref to the actual scrolling ancestor. When provided, the
   * "scrolled to top?" check anchors to this element instead of walking the
   * DOM tree — needed for nested scroll containers like the Reels snap feed.
   */
  scrollContainerRef?: RefObject<HTMLElement | null>;
};

export function PullToRefresh({
  children,
  onRefresh,
  enabled = true,
  threshold = 80,
  className = "",
  scrollContainerRef,
}: PullToRefreshProps) {
  const containerRef = useRef<HTMLDivElement>(null);
  const startYRef = useRef(0);
  const pullDistRef = useRef(0);
  const [pullState, setPullState] = useState<"idle" | "pulling" | "threshold" | "refreshing">("idle");
  const [pullOffset, setPullOffset] = useState(0);
  const isTrackingRef = useRef(false);

  if (!enabled) {
    return <div className={className}>{children}</div>;
  }

  function isScrolledToTop(): boolean {
    // Prefer the explicit scroll container when provided (nested scroll case,
    // e.g. the Reels snap feed scrolls inside the page).
    if (scrollContainerRef?.current) {
      return scrollContainerRef.current.scrollTop <= 2;
    }
    if (!containerRef.current) return true;
    // Otherwise walk up the DOM to find the first scrolling ancestor.
    let el: HTMLElement | null = containerRef.current;
    while (el) {
      if (el.scrollTop > 2) return false;
      el = el.parentElement;
    }
    return true;
  }

  function handleTouchStart(e: TouchEvent) {
    if (pullState === "refreshing") return;
    if (!isScrolledToTop()) return;

    startYRef.current = e.touches[0].clientY;
    pullDistRef.current = 0;
    isTrackingRef.current = true;
  }

  function handleTouchMove(e: TouchEvent) {
    if (!isTrackingRef.current || pullState === "refreshing") return;

    const dy = e.touches[0].clientY - startYRef.current;

    if (dy <= 0) {
      setPullOffset(0);
      setPullState("idle");
      return;
    }

    // Rubber-band: diminishing returns past threshold
    const dampened = dy > threshold
      ? threshold + (dy - threshold) * 0.3
      : dy;

    pullDistRef.current = dampened;
    setPullOffset(Math.min(dampened, threshold * 2));

    if (dampened >= threshold) {
      setPullState("threshold");
    } else {
      setPullState("pulling");
    }
  }

  async function handleTouchEnd() {
    if (!isTrackingRef.current) return;
    isTrackingRef.current = false;

    if (pullDistRef.current >= threshold && pullState !== "refreshing") {
      setPullState("refreshing");
      setPullOffset(threshold * 0.6);

      // Haptic
      if ("vibrate" in navigator) navigator.vibrate(12);

      try {
        await onRefresh();
      } catch {
        // Swallow — caller is responsible for error handling
      }
    }

    setPullState("idle");
    setPullOffset(0);
    pullDistRef.current = 0;
  }

  const spinnerRotation = pullState === "refreshing"
    ? "ptr-spinner spinning"
    : pullOffset > 0
    ? "ptr-spinner"
    : "ptr-spinner ptr-hidden";

  const spinnerProgress = Math.min(1, pullOffset / threshold);

  return (
    <div
      ref={containerRef}
      className={`pull-to-refresh-container ${className}`}
      onTouchStart={handleTouchStart}
      onTouchMove={handleTouchMove}
      onTouchEnd={handleTouchEnd}
    >
      <div
        className="ptr-indicator"
        style={{
          height: `${pullOffset}px`,
          opacity: spinnerProgress,
          transition: pullState === "idle" ? "height 0.3s cubic-bezier(0.16, 1, 0.3, 1), opacity 0.3s" : "none",
        }}
      >
        <div
          className={spinnerRotation}
          style={{
            transform: pullState !== "refreshing"
              ? `rotate(${spinnerProgress * 360}deg) scale(${0.5 + spinnerProgress * 0.5})`
              : undefined,
          }}
        >
          <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2.5" strokeLinecap="round">
            <path d="M21 12a9 9 0 1 1-6.219-8.56" />
          </svg>
        </div>
        {pullState === "threshold" && (
          <span className="ptr-label">Release to refresh</span>
        )}
      </div>
      {children}
    </div>
  );
}
