/**
 * BottomNav.tsx — Mobile tab bar (icons only).
 *
 * Minimal IA (5 tabs):
 *   Reads → Journal → Drafts → Profile → Debug
 *
 * The social Feed was folded INTO Reads: social posts (Nostr / Bluesky) pass a
 * reputation gate (WoT / engagement) then rank alongside articles, news, and
 * video by the journal lens. There is no free "Following" timeline — every
 * item earns its slot through ranking.
 *
 * - Reads:  the unified "for me" stream — articles + news + video + gated
 *           social, all ranked by what you've been writing about.
 * - Journal: capture/compose (OUT) — grows the topics that curate Reads.
 * - Drafts: AI post drafts (distill journals → publish to Nostr/Bluesky).
 * - Profile.
 * - Debug:  AI activity log (dev/debug; removable).
 */

type MobileTab = "reads" | "journal" | "drafts" | "profile" | "debug";

type BottomNavProps = {
  activeTab: MobileTab;
  onTabChange: (tab: MobileTab) => void;
  productivityBadgeCount?: number;
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
}: BottomNavProps) {
  const handleTab = (tab: MobileTab) => {
    if (tab !== activeTab) {
      triggerHaptic();
    }
    onTabChange(tab);
  };

  return (
    <nav className="bottom-nav bottom-nav-5" role="tablist" aria-label="Main navigation">
      {/* Reads — the unified "for me" stream (articles + news + video + gated social) */}
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

      {/* Drafts — AI post drafts (sparkles/wand) */}
      <button
        type="button"
        role="tab"
        aria-selected={activeTab === "drafts"}
        aria-label="Drafts"
        className={activeTab === "drafts" ? "active" : ""}
        onClick={() => handleTab("drafts")}
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

      {/* Debug — AI activity log (dev/debug; removable) */}
      <button
        type="button"
        role="tab"
        aria-selected={activeTab === "debug"}
        aria-label="AI Activity"
        className={activeTab === "debug" ? "active" : ""}
        onClick={() => handleTab("debug")}
      >
        <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
          <path d="M8 2l1.5 2.5" />
          <path d="M16 2l-1.5 2.5" />
          <path d="M9.5 4.5h5" />
          <rect x="6" y="6" width="12" height="12" rx="6" />
          <path d="M12 10v4" />
          <path d="M10 18l-1 4" />
          <path d="M14 18l1 4" />
        </svg>
      </button>
    </nav>
  );
}
