/**
 * BottomNav.tsx — Mobile tab bar (icons only).
 *
 * Social-first IA: Feed (Nostr) → News (HN) → Journal → Queue → Tasks → Profile.
 * Journals power curation (topic filtering) across the social surfaces; they
 * sit in the middle as the capture/compose surface.
 */

type MobileTab = "feed" | "news" | "journal" | "queue" | "productivity" | "profile";

type BottomNavProps = {
  activeTab: MobileTab;
  onTabChange: (tab: MobileTab) => void;
  productivityBadgeCount?: number;
  /** Unread count for the social Feed tab (e.g. new Nostr notes since last view). */
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
    <nav className="bottom-nav" role="tablist" aria-label="Main navigation">
      {/* Feed — Nostr social stream (the "home" timeline) */}
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

      {/* News — Hacker News tech cards (explore) */}
      <button
        type="button"
        role="tab"
        aria-selected={activeTab === "news"}
        aria-label="News"
        className={activeTab === "news" ? "active" : ""}
        onClick={() => handleTab("news")}
      >
        <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
          <path d="M4 22h16a2 2 0 0 0 2-2V4a2 2 0 0 0-2-2H8a2 2 0 0 0-2 2v16a2 2 0 0 1-2 2zm0 0a2 2 0 0 1-2-2v-9c0-1.1.9-2 2-2h2" />
          <path d="M18 14h-8M15 18h-5M10 6h8v4h-8V6z" />
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

      {/* Queue — AI-generated drafts (sparkles/wand) */}
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
      </button>

      {/* Tasks — productivity (checkbox) */}
      <button
        type="button"
        role="tab"
        aria-selected={activeTab === "productivity"}
        aria-label="Tasks"
        className={activeTab === "productivity" ? "active" : ""}
        onClick={() => handleTab("productivity")}
      >
        <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
          <path d="M9 11l3 3L22 4" />
          <path d="M21 12v7a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h11" />
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
