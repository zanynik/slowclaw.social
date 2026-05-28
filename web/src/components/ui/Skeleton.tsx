/**
 * Skeleton.tsx — Loading placeholder components.
 *
 * Inspired by Atomic Chat's shimmer.tsx and skeleton.tsx patterns.
 * Provides animated loading states that match our card/list layouts
 * so the UI feels responsive before data arrives.
 */

import { type CSSProperties } from "react";

type SkeletonProps = {
  width?: string | number;
  height?: string | number;
  borderRadius?: string;
  className?: string;
  style?: CSSProperties;
};

export function Skeleton({
  width = "100%",
  height = "1rem",
  borderRadius = "var(--r-sm)",
  className = "",
  style,
}: SkeletonProps) {
  return (
    <div
      className={`skeleton-pulse ${className}`}
      style={{
        width,
        height,
        borderRadius,
        ...style,
      }}
      aria-hidden="true"
    />
  );
}

export function SkeletonText({
  lines = 3,
  className = "",
}: {
  lines?: number;
  className?: string;
}) {
  return (
    <div className={`stack-sm ${className}`} aria-hidden="true">
      {Array.from({ length: lines }).map((_, i) => (
        <Skeleton
          key={`skel-line-${i}`}
          width={i === lines - 1 ? "60%" : "100%"}
          height="0.85rem"
        />
      ))}
    </div>
  );
}

export function SkeletonCard({ className = "" }: { className?: string }) {
  return (
    <div className={`card skeleton-card ${className}`} aria-hidden="true">
      <div className="row-between">
        <Skeleton width="45%" height="1.1rem" />
        <Skeleton width="4.5rem" height="0.8rem" />
      </div>
      <SkeletonText lines={3} />
      <div className="row" style={{ gap: "0.5rem" }}>
        <Skeleton width="5rem" height="2rem" borderRadius="var(--r-pill)" />
        <Skeleton width="4rem" height="2rem" borderRadius="var(--r-pill)" />
      </div>
    </div>
  );
}

export function SkeletonFeedItem() {
  return (
    <div className="feed-item-card skeleton-card" aria-hidden="true">
      <div className="feed-header">
        <div className="stack-sm" style={{ flex: 1, gap: "0.4rem" }}>
          <div className="row" style={{ gap: "0.45rem" }}>
            <Skeleton width="1.6rem" height="1.6rem" borderRadius="50%" />
            <Skeleton width="6rem" height="0.85rem" />
          </div>
          <Skeleton width="70%" height="0.9rem" />
        </div>
        <Skeleton width="3.5rem" height="0.75rem" />
      </div>
      <SkeletonText lines={4} />
      <div className="feed-actions">
        <Skeleton width="6rem" height="2rem" borderRadius="var(--r-pill)" />
        <Skeleton width="5rem" height="2rem" borderRadius="var(--r-pill)" />
      </div>
    </div>
  );
}

export function SkeletonJournalItem() {
  return (
    <div
      className="sidebar-item skeleton-card"
      style={{ padding: "0.65rem 0.8rem" }}
      aria-hidden="true"
    >
      <div className="row" style={{ gap: "0.5rem" }}>
        <Skeleton width="1.5rem" height="1.5rem" borderRadius="var(--r-sm)" />
        <div className="stack-sm" style={{ flex: 1, gap: "0.3rem" }}>
          <Skeleton width="80%" height="0.8rem" />
          <Skeleton width="50%" height="0.65rem" />
        </div>
      </div>
    </div>
  );
}

export function SkeletonModelCard() {
  return (
    <article className="local-model-card skeleton-card" aria-hidden="true">
      <div className="row-between">
        <Skeleton width="4rem" height="0.7rem" />
        <Skeleton width="5rem" height="1.3rem" borderRadius="var(--r-pill)" />
      </div>
      <Skeleton width="75%" height="1rem" />
      <SkeletonText lines={2} />
      <div className="model-card-meta">
        <Skeleton width="3rem" height="1.5rem" borderRadius="var(--r-pill)" />
        <Skeleton width="3.5rem" height="1.5rem" borderRadius="var(--r-pill)" />
      </div>
      <div className="model-card-actions">
        <Skeleton width="100%" height="2.2rem" borderRadius="var(--r-pill)" />
      </div>
    </article>
  );
}

export function SkeletonList({
  count = 5,
  type = "card",
}: {
  count?: number;
  type?: "card" | "feed" | "journal" | "model";
}) {
  const ItemComponent =
    type === "feed"
      ? SkeletonFeedItem
      : type === "journal"
      ? SkeletonJournalItem
      : type === "model"
      ? SkeletonModelCard
      : SkeletonCard;

  return (
    <div className="stack" role="status" aria-label="Loading">
      {Array.from({ length: count }).map((_, i) => (
        <ItemComponent key={`skel-list-${i}`} />
      ))}
    </div>
  );
}
