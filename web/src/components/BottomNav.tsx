/**
 * BottomNav.tsx — Mobile tab bar (icons only).
 *
 * Social-first IA (7 tabs):
 *   Feed → Reels → Media → Reads → Journal → Queue(+Tasks) → Profile
 *
 * - Feed:   Nostr/Bluesky social stream + Tech News toggle (newspaper icon).
 * - Reels:  vertical video doom-scroll (Bluesky HLS videos).
 * - Media:  image/video gallery across Nostr + Bluesky (UnifiedItem media).
 * - Reads:  long-form — Nostr NIP-23 articles (Habla) + RSS/Atom blogs.
 * - Journal: capture/compose — grows the topics that curate the social surfaces.
 * - Queue:  AI drafts + Tasks (productivity) folded together.
 * - Profile.
 *
 * Refresh actions live inside each tab's header (no global refresh icon), so
 * the bar stays icon-only and breathes on small screens.
 */

type MobileTab = "feed" | "reels" | "media" | "reads" | "journal" | "queue" | "profile";

type BottomNavProps = {
  activeTab: MobileTab;
  onTabChange: (tab: MobileTab) => void;
  productivityBadgeCount?: number;
  /** Unread count for the social Feed tab. */
  feedBadgeCount?: number;
};

function triggerHaptic() {
  if (typeof window !== "undefined" && "navigator" in window && "vibrate" in navigator) {
    navigator.vibrate(8);
  }
}

export function BottomNav({
  activeTab,
  onTabChange,
  productivityBadgeCount = 0,
  feedBadgeCount = 0,
}: BottomNavProps) {
  const handleTab = (tab: MobileTab) => {
    if (tab !== activeTab) {
      triggerHaptic();
    }
    onTabChange(tab);
  };

  return (
    <nav className="bottom-nav bottom-nav-7" role="tablist" aria-label="Main navigation">
      {/* Feed — social stream (Nostr/Bluesky) + Tech News toggle */}
      <button
        type="button"
        role="tab"
        aria-selected={activeTab === "feed"}
        aria-label="Feed"
        className={activeTab === "feed" ? "active" : ""}
        onClick={() => handleTab("feed")}
      >
        <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
          <path d="M3 11l18-8-8 18-2-7-8-3z" />
        </svg>
        {feedBadgeCount > 0 ? (
          <span className="bottom-nav-badge">{feedBadgeCount}</span>
        ) : null}
      </button>

      {/* Reels — vertical video doom-scroll */}
      <button
        type="button"
        role="tab"
        aria-selected={activeTab === "reels"}
        aria-label="Reels"
        className={activeTab === "reels" ? "active" : ""}
        onClick={() => handleTab("reels")}
      >
        <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
          <rect x="2" y="5" width="20" height="14" rx="2" />
          <polygon points="10 9 16 12 10 15 10 9" fill="currentColor" stroke="none" />
        </svg>
      </button>

      {/* Media — image/video gallery across sources */}
      <button
        type="button"
        role="tab"
        aria-selected={activeTab === "media"}
        aria-label="Media"
        className={activeTab === "media" ? "active" : ""}
        onClick={() => handleTab("media")}
      >
        <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
          <rect x="3" y="3" width="18" height="18" rx="2" ry="2" />
          <circle cx="8.5" cy="8.5" r="1.5" />
          <path d="M21 15l-5-5L5 21" />
        </svg>
      </button>

      {/* Reads — long-form articles + RSS */}
      <button
        type="button"
        role="tab"
        aria-selected={activeTab === "reads"}
        aria-label="Reads"
        className={activeTab === "reads" ? "active" : ""}
        onClick={() => handleTab("reads")}
      >
        <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
          <path d="M4 19.5A2.5 2.5 0 0 1 6.5 17H20" />
          <path d="M6.5 2H20v20H6.5A2.5 2.5 0 0 1 4 19.5v-15A2.5 2.5 0 0 1 6.5 2z" />
        </svg>
      </button>

      {/* Journal — capture/compose (pen/edit) */}
      <button
        type="button"
        role="tab"
        aria-selected={activeTab === "journal"}
        aria-label="Journal"
        className={activeTab === "journal" ? "active" : ""}
        onClick={() => handleTab("journal")}
      >
        <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
          <path d="M12 20h9" />
          <path d="M16.5 3.5a2.121 2.121 0 0 1 3 3L7 19l-4 1 1-4L16.5 3.5z" />
        </svg>
      </button>

      {/* Queue — AI drafts + Tasks folded together (sparkles/wand) */}
      <button
        type="button"
        role="tab"
        aria-selected={activeTab === "queue"}
        aria-label="Queue"
        className={activeTab === "queue" ? "active" : ""}
        onClick={() => handleTab("queue")}
      >
        <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
          <path d="M12 2l1.09 3.26L16 6l-2.91.74L12 10l-1.09-3.26L8 6l2.91-.74L12 2z" />
          <path d="M5 15l.54 1.63L7 17.17l-1.46.37L5 19.17l-.54-1.63L3 17.17l1.46-.37L5 15z" />
          <path d="M19 11l.54 1.63L21 13.17l-1.46.37L19 15.17l-.54-1.63L17 13.17l1.46-.37L19 11z" />
        </svg>
        {productivityBadgeCount > 0 ? (
          <span className="bottom-nav-badge">{productivityBadgeCount}</span>
        ) : null}
      </button>

      {/* Profile */}
      <button
        type="button"
        role="tab"
        aria-selected={activeTab === "profile"}
        aria-label="Profile"
        className={activeTab === "profile" ? "active" : ""}
        onClick={() => handleTab("profile")}
      >
        <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
          <path d="M20 21v-2a4 4 0 0 0-4-4H8a4 4 0 0 0-4 4v2" />
          <circle cx="12" cy="7" r="4" />
        </svg>
      </button>
    </nav>
  );
}
