/**
 * aiActivityLog.ts — in-memory activity log for on-device AI calls.
 *
 * Dev/debug surface. Every nativeAiChat / nativeAiLoadModel call site in the app
 * pushes structured events here (start / success / error / skipped). The Debug
 * tab subscribes via `useAiLog()` and renders the ring buffer.
 *
 * Scope: the `nativeAiChat` + `nativeAiLoadModel` bridge only (transcription is
 * a separate native bridge and is out of scope for this pass).
 *
 * Designed to be removable: every call site uses additive `logAiEvent(...)`
 * one-liners, so deleting this file + the view + the log lines reverts cleanly.
 *
 * No persistence across app restarts — this is a dev ring buffer, kept small.
 */

import { useSyncExternalStore } from "react";

/** Which on-device AI feature the event concerns. */
export type AiFeature =
  | "title" // journal entry → AI-generated title (handleJournalDone)
  | "tweetclaw" // journal entry → post drafts (Done / manual / pull-to-refresh)
  | "interests" // journal entry → feed steering keywords
  | "card_keywords" // liked/disliked Reads card → keyword extraction
  | "rerank" // background Reads re-rank (useAiFeedRerank)
  | "warm"; // auto-warm the model on launch (nativeAiLoadModel)

/** Lifecycle phase of a single feature invocation. */
export type AiEventKind = "start" | "success" | "error" | "skipped";

export interface AiLogEvent {
  id: number;
  /** Epoch ms. */
  ts: number;
  feature: AiFeature;
  kind: AiEventKind;
  /** Short human-readable summary (shown as the card title). */
  message: string;
  /** Optional longer payload: extracted keywords, generated post count, error detail. */
  detail?: string;
  /** Optional elapsed time for the call, when measurable (start→success/error). */
  durationMs?: number;
}

/** Ring buffer cap. Old events are dropped FIFO. Dev-only, kept modest. */
const MAX_EVENTS = 300;

let events: AiLogEvent[] = [];
let nextId = 1;

// ── pub/sub ────────────────────────────────────────────────────────────────
// useSyncExternalStore needs a stable snapshot reference, so we hand out the
// same array until a mutation replaces it. Listeners are notified on replace.
const listeners = new Set<() => void>();

function emit() {
  for (const cb of listeners) cb();
}

function subscribe(cb: () => void): () => void {
  listeners.add(cb);
  return () => {
    listeners.delete(cb);
  };
}

function getSnapshot(): AiLogEvent[] {
  return events;
}

/**
 * Push an event into the log. Safe to call from anywhere (call sites, hooks).
 * The optional `detail` is truncated to keep the buffer cheap to render.
 */
export function logAiEvent(
  feature: AiFeature,
  kind: AiEventKind,
  message: string,
  detail?: string,
  durationMs?: number,
): void {
  const event: AiLogEvent = {
    id: nextId++,
    ts: Date.now(),
    feature,
    kind,
    message,
    detail: detail ? detail.slice(0, 500) : undefined,
    durationMs,
  };
  events = [event, ...events].slice(0, MAX_EVENTS);
  emit();
}

/** Empty the log (Debug tab "Clear" button). */
export function clearAiLog(): void {
  if (events.length === 0) return;
  events = [];
  emit();
}

/**
 * React hook returning the current (reverse-chronological) event list.
 * Re-renders subscribers on every push/clear via useSyncExternalStore.
 */
export function useAiLog(): AiLogEvent[] {
  return useSyncExternalStore(subscribe, getSnapshot, getSnapshot);
}

/** Stable display label for each feature, for the Debug tab header/cards. */
export const AI_FEATURE_LABELS: Record<AiFeature, string> = {
  title: "Journal title",
  tweetclaw: "TweetClaw posts",
  interests: "Interest keywords",
  card_keywords: "Card keywords",
  rerank: "Reads re-rank",
  warm: "Model warm-up",
};
