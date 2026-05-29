/**
 * BottomNav.tsx — Mobile tab bar component.
 *
 * Four tabs: Journal, Feed, Tasks, Profile.
 * Settings is accessed via the gear icon in the top-right header.
 */

type MobileTab = "journal" | "feed" | "productivity" | "profile";

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
    <nav className="bottom-nav" role="tablist" aria-label="Main navigation">
      <button
        type="button"
        role="tab"
        aria-selected={activeTab === "journal"}
        className={activeTab === "journal" ? "active" : ""}
        onClick={() => handleTab("journal")}
      >
        <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
          <path d="M12 20h9" />
          <path d="M16.5 3.5a2.121 2.121 0 0 1 3 3L7 19l-4 1 1-4L16.5 3.5z" />
        </svg>
        Journal
      </button>
      <button
        type="button"
        role="tab"
        aria-selected={activeTab === "feed"}
        className={activeTab === "feed" ? "active" : ""}
        onClick={() => handleTab("feed")}
      >
        <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
          <circle cx="12" cy="12" r="10" />
          <polyline points="12 6 12 12 16 14" />
        </svg>
        Feed
      </button>
      <button
        type="button"
        role="tab"
        aria-selected={activeTab === "productivity"}
        className={activeTab === "productivity" ? "active" : ""}
        onClick={() => handleTab("productivity")}
      >
        <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
          <path d="M9 11l3 3L22 4" />
          <path d="M21 12v7a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2V5a2 2 0 0 1 2-2h11" />
        </svg>
        <span className="bottom-nav-label">
          Tasks
          {productivityBadgeCount > 0 ? (
            <span className="bottom-nav-badge">{productivityBadgeCount}</span>
          ) : null}
        </span>
      </button>
      <button
        type="button"
        role="tab"
        aria-selected={activeTab === "profile"}
        className={activeTab === "profile" ? "active" : ""}
        onClick={() => handleTab("profile")}
      >
        <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
          <path d="M20 21v-2a4 4 0 0 0-4-4H8a4 4 0 0 0-4 4v2" />
          <circle cx="12" cy="7" r="4" />
        </svg>
        Profile
      </button>
    </nav>
  );
}
