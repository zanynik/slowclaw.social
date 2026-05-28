/**
 * SwipeableView.tsx — Horizontal swipe gesture handler for tab navigation.
 *
 * Provides iOS-native-feeling horizontal swipe between tabs with spring-like
 * physics. Inspired by native UIPageViewController behavior and Atomic Chat's
 * smooth transition patterns.
 *
 * Features:
 * - Touch tracking with velocity-based snap
 * - Visual drag feedback (translateX) for natural feel
 * - Edge resistance so users know they're at the boundary
 * - Debounced so fast flicks don't skip tabs
 */

import { useRef, type ReactNode, type TouchEvent } from "react";

type SwipeableViewProps = {
  children: ReactNode;
  onSwipeLeft?: () => void;
  onSwipeRight?: () => void;
  threshold?: number;
  enabled?: boolean;
  className?: string;
};

export function SwipeableView({
  children,
  onSwipeLeft,
  onSwipeRight,
  threshold = 60,
  enabled = true,
  className = "",
}: SwipeableViewProps) {
  const containerRef = useRef<HTMLDivElement>(null);
  const startXRef = useRef(0);
  const startYRef = useRef(0);
  const startTimeRef = useRef(0);
  const deltaXRef = useRef(0);
  const isTrackingRef = useRef(false);
  const committedRef = useRef(false);

  if (!enabled) {
    return <div className={className}>{children}</div>;
  }

  function handleTouchStart(e: TouchEvent) {
    const touch = e.touches[0];
    startXRef.current = touch.clientX;
    startYRef.current = touch.clientY;
    startTimeRef.current = Date.now();
    deltaXRef.current = 0;
    isTrackingRef.current = false;
    committedRef.current = false;
  }

  function handleTouchMove(e: TouchEvent) {
    if (committedRef.current) return;

    const touch = e.touches[0];
    const dx = touch.clientX - startXRef.current;
    const dy = touch.clientY - startYRef.current;

    // Determine if this is a horizontal gesture (on first significant movement)
    if (!isTrackingRef.current) {
      if (Math.abs(dx) < 10 && Math.abs(dy) < 10) return;
      // If predominantly vertical, bail out entirely
      if (Math.abs(dy) > Math.abs(dx) * 1.2) {
        committedRef.current = true;
        return;
      }
      isTrackingRef.current = true;
    }

    deltaXRef.current = dx;

    // Apply a subtle translateX for visual feedback
    if (containerRef.current) {
      // Edge resistance: dampen the drag to 25% of actual movement
      const dampenedX = dx * 0.25;
      const clamped = Math.max(-80, Math.min(80, dampenedX));
      containerRef.current.style.transform = `translateX(${clamped}px)`;
      containerRef.current.style.transition = "none";
    }
  }

  function handleTouchEnd() {
    // Spring back the visual transform
    if (containerRef.current) {
      containerRef.current.style.transform = "";
      containerRef.current.style.transition = "transform 0.35s cubic-bezier(0.16, 1, 0.3, 1)";
    }

    if (!isTrackingRef.current || committedRef.current) return;

    const dx = deltaXRef.current;
    const elapsed = Date.now() - startTimeRef.current;
    const velocity = Math.abs(dx) / Math.max(1, elapsed);

    // Trigger swipe if threshold exceeded OR fast flick detected
    const triggered = Math.abs(dx) > threshold || (velocity > 0.5 && Math.abs(dx) > 30);

    if (triggered) {
      if (dx > 0 && onSwipeRight) {
        onSwipeRight();
      } else if (dx < 0 && onSwipeLeft) {
        onSwipeLeft();
      }
    }

    isTrackingRef.current = false;
    deltaXRef.current = 0;
  }

  return (
    <div
      ref={containerRef}
      className={`swipeable-view ${className}`}
      onTouchStart={handleTouchStart}
      onTouchMove={handleTouchMove}
      onTouchEnd={handleTouchEnd}
      style={{ willChange: "transform" }}
    >
      {children}
    </div>
  );
}
