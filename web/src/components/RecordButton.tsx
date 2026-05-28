/**
 * RecordButton.tsx — Journal capture buttons with iOS-native haptic feedback.
 *
 * Extracted from the record-btn section of App.tsx. Provides:
 * - Spring-physics press animation
 * - Haptic feedback on iOS devices
 * - Pulse animation during active recording
 * - Accessible labeling
 */

type RecordButtonProps = {
  mode: "audio" | "video";
  isRecording: boolean;
  activeMode: "audio" | "video" | null;
  disabled?: boolean;
  onClick: () => void;
};

function triggerHaptic(intensity: "light" | "medium" | "heavy" = "medium") {
  if (typeof window === "undefined") return;
  if ("vibrate" in navigator) {
    const durations = { light: 5, medium: 10, heavy: 20 };
    navigator.vibrate(durations[intensity]);
  }
}

export function RecordButton({
  mode,
  isRecording,
  activeMode,
  disabled = false,
  onClick,
}: RecordButtonProps) {
  const isActive = isRecording && activeMode === mode;
  const isOtherActive = isRecording && activeMode !== mode && activeMode !== null;

  const label = isActive
    ? `Stop ${mode} recording`
    : `Start ${mode} recording`;

  const icon = mode === "audio" ? (
    <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
      <path d="M12 1a3 3 0 0 0-3 3v8a3 3 0 0 0 6 0V4a3 3 0 0 0-3-3z" />
      <path d="M19 10v2a7 7 0 0 1-14 0v-2" />
      <line x1="12" y1="19" x2="12" y2="23" />
      <line x1="8" y1="23" x2="16" y2="23" />
    </svg>
  ) : (
    <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
      <polygon points="23 7 16 12 23 17 23 7" />
      <rect x="1" y="5" width="15" height="14" rx="2" ry="2" />
    </svg>
  );

  function handleClick() {
    triggerHaptic(isActive ? "heavy" : "medium");
    onClick();
  }

  return (
    <button
      type="button"
      className={`record-btn ${mode}${isActive ? " recording-active" : ""}`}
      onClick={handleClick}
      disabled={disabled || isOtherActive}
      aria-label={label}
      aria-pressed={isActive}
    >
      {isActive ? (
        <svg viewBox="0 0 24 24" fill="currentColor" stroke="none">
          <rect x="6" y="6" width="12" height="12" rx="2" />
        </svg>
      ) : (
        icon
      )}
    </button>
  );
}

export function RecordButtonGroup({
  isRecording,
  activeMode,
  disabled = false,
  onAudioToggle,
  onVideoToggle,
  recordingTime,
  hint,
}: {
  isRecording: boolean;
  activeMode: "audio" | "video" | null;
  disabled?: boolean;
  onAudioToggle: () => void;
  onVideoToggle: () => void;
  recordingTime?: number;
  hint?: string;
}) {
  function formatTime(seconds: number) {
    const m = Math.floor(seconds / 60);
    const s = seconds % 60;
    return `${m}:${s.toString().padStart(2, "0")}`;
  }

  return (
    <div className="stack" style={{ alignItems: "center", gap: "0.65rem" }}>
      {isRecording && recordingTime != null ? (
        <div className="capture-zen-timer">{formatTime(recordingTime)}</div>
      ) : null}
      <div className="record-btn-group">
        <RecordButton
          mode="audio"
          isRecording={isRecording}
          activeMode={activeMode}
          disabled={disabled}
          onClick={onAudioToggle}
        />
        <RecordButton
          mode="video"
          isRecording={isRecording}
          activeMode={activeMode}
          disabled={disabled}
          onClick={onVideoToggle}
        />
      </div>
      {!isRecording && hint ? (
        <p className="text-sm muted text-center" style={{ maxWidth: "22rem" }}>
          {hint}
        </p>
      ) : null}
    </div>
  );
}
