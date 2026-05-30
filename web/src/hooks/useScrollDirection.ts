import { useState, useEffect, useRef } from "react";

/**
 * useScrollDirection — returns "up" | "down" | null based on scroll direction.
 * Used to auto-hide the topbar on scroll down (like Bluesky/Twitter).
 * 
 * @param threshold Minimum scroll delta (px) before triggering direction change
 */
export function useScrollDirection(threshold = 10): "up" | "down" | null {
  const [direction, setDirection] = useState<"up" | "down" | null>(null);
  const lastY = useRef(0);
  const ticking = useRef(false);

  useEffect(() => {
    lastY.current = window.scrollY;

    const handleScroll = () => {
      if (ticking.current) return;
      ticking.current = true;

      requestAnimationFrame(() => {
        const currentY = window.scrollY;
        const diff = currentY - lastY.current;

        if (Math.abs(diff) >= threshold) {
          setDirection(diff > 0 ? "down" : "up");
          lastY.current = currentY;
        }

        // Always show topbar when at the very top
        if (currentY <= 10) {
          setDirection("up");
        }

        ticking.current = false;
      });
    };

    window.addEventListener("scroll", handleScroll, { passive: true });
    return () => window.removeEventListener("scroll", handleScroll);
  }, [threshold]);

  return direction;
}
