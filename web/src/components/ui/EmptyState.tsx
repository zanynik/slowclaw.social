/**
 * EmptyState.tsx — Contextual empty state illustrations.
 *
 * Instead of plain "No items yet" text, provides warm, branded empty states
 * with icons, descriptions, and optional action buttons. This matches the
 * polished feel of Atomic Chat's onboarding and empty-state patterns.
 */

type EmptyStateProps = {
  icon?: string;
  title: string;
  description?: string;
  actionLabel?: string;
  onAction?: () => void;
  compact?: boolean;
};

export function EmptyState({
  icon,
  title,
  description,
  actionLabel,
  onAction,
  compact = false,
}: EmptyStateProps) {
  return (
    <div className={`empty-state ${compact ? "empty-state-compact" : ""}`}>
      {icon && <div className="empty-state-icon">{icon}</div>}
      <h3 className="empty-state-title">{title}</h3>
      {description && <p className="empty-state-desc">{description}</p>}
      {actionLabel && onAction && (
        <button
          type="button"
          className="primary"
          onClick={onAction}
          style={{ marginTop: "0.5rem" }}
        >
          {actionLabel}
        </button>
      )}
    </div>
  );
}

// ── Pre-built empty states for common views ────────────────────────────────────

export function JournalEmptyState({ onWrite }: { onWrite?: () => void }) {
  return (
    <EmptyState
      icon="📝"
      title="Your journal is empty"
      description="Tap the mic to record a voice note, or start writing. Your thoughts are private and stored locally."
      actionLabel={onWrite ? "Write a note" : undefined}
      onAction={onWrite}
    />
  );
}

export function FeedEmptyState({ onCreateAgent }: { onCreateAgent?: () => void }) {
  return (
    <EmptyState
      icon="✨"
      title="No drafts yet"
      description="Create a content agent to turn your journal notes into social posts, insights, and clips."
      actionLabel={onCreateAgent ? "Create Content Agent" : undefined}
      onAction={onCreateAgent}
    />
  );
}

export function ProductivityEmptyState() {
  return (
    <EmptyState
      icon="📋"
      title="Nothing on your plate"
      description="Add journal notes and your AI workspace synthesizer will extract todos and events automatically."
    />
  );
}

export function WorldFeedEmptyState() {
  return (
    <EmptyState
      icon="🌍"
      title="World feed is warming up"
      description="Add interests, connect Bluesky, or seed RSS sources to discover content matched to your taste."
    />
  );
}

export function ModelsEmptyState() {
  return (
    <EmptyState
      icon="🧠"
      title="No models downloaded"
      description="Download a compact AI model to run everything locally and privately on your device."
    />
  );
}
