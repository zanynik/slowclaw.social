/**
 * AiActivityView.tsx — Debug tab: live log of on-device AI activity.
 *
 * Dev/debug surface. Subscribes to the in-memory AI activity log
 * (lib/aiActivityLog) and renders a reverse-chronological list of every
 * on-device AI event — start / success / error / skipped — across the six
 * feature surfaces (title, tweetclaw, interests, card_keywords, rerank, warm).
 *
 * Pure-presentational props-in: App.tsx passes the live nativeLocalAiStatus
 * snapshot so the header shows *why* calls skip (unavailable / not configured /
 * not running) at a glance. The event stream comes from the logger's own hook.
 *
 * Designed to be removable: delete this file, the logger, the nav plumbing in
 * App.tsx, and the additive logAiEvent call lines.
 */

import { useEffect, useState } from "react";
import {
  AI_FEATURE_LABELS,
  clearAiLog,
  useAiLog,
  type AiEventKind,
  type AiFeature,
} from "../lib/aiActivityLog";
import type { NativeLocalAiStatus } from "../lib/tauriApi";

type AiActivityViewProps = {
  status: NativeLocalAiStatus | null;
};

const KIND_DOT_CLASS: Record<AiEventKind, string> = {
  start: "ai-log-dot ai-log-dot-start",
  success: "ai-log-dot ai-log-dot-success",
  error: "ai-log-dot ai-log-dot-error",
  skipped: "ai-log-dot ai-log-dot-skipped",
};

const KIND_LABEL: Record<AiEventKind, string> = {
  start: "started",
  success: "ok",
  error: "failed",
  skipped: "skipped",
};

function formatTime(ts: number): string {
  try {
    const d = new Date(ts);
    return d.toLocaleTimeString([], { hour: "2-digit", minute: "2-digit", second: "2-digit" });
  } catch {
    return String(ts);
  }
}

function formatRelative(ts: number, now: number): string {
  const secs = Math.max(0, Math.round((now - ts) / 1000));
  if (secs < 60) return `${secs}s ago`;
  const mins = Math.round(secs / 60);
  if (mins < 60) return `${mins}m ago`;
  const hrs = Math.round(mins / 60);
  return `${hrs}h ago`;
}

export function AiActivityView({ status }: AiActivityViewProps) {
  const events = useAiLog();
  const [filter, setFilter] = useState<"all" | "errors" | AiFeature>("all");

  // Re-render every 5s so relative timestamps ("3s ago") stay fresh.
  const [, setTick] = useState(0);
  useEffect(() => {
    const id = window.setInterval(() => setTick((n) => n + 1), 5000);
    return () => window.clearInterval(id);
  }, []);

  const visible = events.filter((e) => {
    if (filter === "all") return true;
    if (filter === "errors") return e.kind === "error";
    return e.feature === filter;
  });

  const featureKeys = Object.keys(AI_FEATURE_LABELS) as AiFeature[];

  return (
    <div className="stack" style={{ padding: "0.5rem 0" }}>
      {/* Runtime status snapshot — explains WHY calls skip. */}
      <div className="card">
        <div className="stack-sm">
          <h2 style={{ margin: 0 }}>AI Activity</h2>
          <p className="text-sm muted" style={{ margin: 0 }}>
            On-device AI call log (nativeAiChat / nativeAiLoadModel). Dev/debug only — not persisted.
          </p>
          <div className="ai-log-status-row">
            <span className={`status-pill ${status?.available ? "status-pill-success" : "status-pill-warning"}`}>
              {status?.available ? "available" : "unavailable"}
            </span>
            <span className="status-pill">{status?.configured ? "configured" : "not configured"}</span>
            <span className="status-pill">{status?.running ? "running" : "idle"}</span>
            {status?.modelId ? <span className="status-pill">{status.modelId}</span> : null}
          </div>
          {status?.error ? (
            <p className="text-sm" style={{ margin: 0, color: "var(--danger, #d33)" }}>
              {status.error}
            </p>
          ) : null}
        </div>
      </div>

      {/* Filters + clear. */}
      <div className="ai-log-toolbar">
        <div className="topic-chips">
          <button
            type="button"
            className={`topic-chip small ${filter === "all" ? "active" : ""}`}
            onClick={() => setFilter("all")}
          >
            All ({events.length})
          </button>
          <button
            type="button"
            className={`topic-chip small ${filter === "errors" ? "active" : ""}`}
            onClick={() => setFilter("errors")}
          >
            Errors
          </button>
          {featureKeys.map((f) => (
            <button
              key={f}
              type="button"
              className={`topic-chip small ${filter === f ? "active" : ""}`}
              onClick={() => setFilter(f)}
            >
              {AI_FEATURE_LABELS[f]}
            </button>
          ))}
        </div>
        <button type="button" className="topic-chip small" onClick={clearAiLog} disabled={events.length === 0}>
          Clear
        </button>
      </div>

      {/* Event list. */}
      {visible.length === 0 ? (
        <div className="card">
          <p className="muted text-sm" style={{ margin: 0 }}>
            {events.length === 0
              ? "No AI activity yet. Like/dislike a Reads card or finish a journal entry to see calls appear here."
              : "No events match this filter."}
          </p>
        </div>
      ) : (
        <div className="ai-log-list">
          {visible.map((e) => (
            <div key={e.id} className="ai-log-row">
              <span className={KIND_DOT_CLASS[e.kind]} title={e.kind} />
              <div className="ai-log-row-main">
                <div className="ai-log-row-head">
                  <span className="ai-log-feature">{AI_FEATURE_LABELS[e.feature]}</span>
                  <span className={`ai-log-kind ai-log-kind-${e.kind}`}>{KIND_LABEL[e.kind]}</span>
                  {e.durationMs != null ? (
                    <span className="ai-log-dur">{Math.round(e.durationMs)}ms</span>
                  ) : null}
                </div>
                <div className="ai-log-msg">{e.message}</div>
                {e.detail ? <div className="ai-log-detail">{e.detail}</div> : null}
                <div className="ai-log-ts text-sm muted">
                  {formatRelative(e.ts, Date.now())} · {formatTime(e.ts)}
                </div>
              </div>
            </div>
          ))}
        </div>
      )}
    </div>
  );
}
