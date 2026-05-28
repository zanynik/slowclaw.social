/**
 * ToastContainer.tsx — In-app toast notification system.
 *
 * Inspired by Atomic Chat's use of Sonner for toast notifications.
 * Provides non-intrusive feedback for saves, errors, and status changes
 * without blocking the user's workflow.
 */

import { useAppStore, appActions } from "../../stores/useAppStore";

const TOAST_ICONS: Record<string, string> = {
  info: "ℹ️",
  success: "✓",
  error: "✕",
};

export function ToastContainer() {
  const toasts = useAppStore((s) => s.toasts);

  if (toasts.length === 0) return null;

  return (
    <div className="toast-container" role="log" aria-live="polite">
      {toasts.map((toast) => (
        <div
          key={toast.id}
          className={`toast toast-${toast.type}`}
          role="alert"
        >
          <span className={`toast-icon toast-icon-${toast.type}`}>
            {TOAST_ICONS[toast.type] || "ℹ️"}
          </span>
          <span className="toast-message">{toast.message}</span>
          <button
            type="button"
            className="toast-dismiss"
            onClick={() => appActions.dismissToast(toast.id)}
            aria-label="Dismiss"
          >
            ✕
          </button>
        </div>
      ))}
    </div>
  );
}
