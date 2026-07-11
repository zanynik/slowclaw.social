/**
 * useAiFeedRerank.ts — continuous on-device re-rank of the Reads stream.
 *
 * The base Reads ranker (lib/readsRanking.ts `rankReads`) is journal-driven but
 * keyword-only; it can't read a post and judge semantic relevance. When the
 * on-device model is available, this hook runs a background pass: it sends the
 * top N Reads items + the user's journal topics to the model, asks for a 0..1
 * relevance score per item, and returns the scores as a Map keyed by item id.
 * The caller blends them via `applyAiRankBoost`.
 *
 * This mirrors the background interest-extraction pattern in App.tsx (gate on
 * isTauriMobileRuntime() && nativeLocalAiStatus?.available; single nativeAiChat
 * call requesting JSON; defensive parse via tryParseJsonArray; surface real
 * errors; degrade gracefully). It is iOS on-device only per AGENTS.md §1.
 *
 * FOREGROUND PREFERENCE (not preemption):
 * The Rust inference engine (inference.rs) is a single process-wide Mutex with
 * NO queue, priority, or abort — concurrent nativeAiChat calls serialize. True
 * preemption of a running background call is impossible without Rust changes.
 * "User request gets preference" is therefore enforced TS-side: a background
 * pass is only *started* when `busy` is false (foreground AI work like TweetClaw
 * pull-to-generate). Passes are also a single short nativeAiChat call with a
 * tight token cap so any in-flight pass finishes quickly and unblocks a queued
 * user request. See the TODO at the bottom for the engine-level follow-up.
 */

import { useEffect, useRef, useState } from "react";
import type { RankedRead } from "../lib/readsRanking";
import type { Topic } from "../lib/socialFeed";
import { tryParseJsonArray } from "../lib/json";
import { nativeAiChat } from "../lib/tauriApi";

export type AiRerankStatus = "idle" | "running" | "done" | "error" | "skipped";

export interface AiRerankResult {
  /** item id → relevance score in [0,1]. Empty until a pass completes. */
  boost: Map<string, number>;
  status: AiRerankStatus;
  error?: string;
}

/** Max items scored per pass (keeps prompt small on a ~1536-token iPhone ctx). */
const RERANK_BATCH_SIZE = 10;
/** Min seconds between completed passes (continuous, not wasteful on a phone). */
const RERANK_COOLDOWN_SECS = 60;
/** Max chars of each item's text carried into the prompt. */
const RERANK_ITEM_CHAR_LIMIT = 160;

export interface UseAiFeedRerankArgs {
  /** The current ranked Reads stream (already journal-ranked). */
  items: RankedRead[];
  /** The user's journal topics (the lens). */
  topics: Topic[];
  /** True when the on-device model is present and available. */
  enabled: boolean;
  /** True when a foreground AI call is active or queued (user request). */
  busy: boolean;
  /** Injected so tests / non-Tauri runtimes can stub it. Defaults to nativeAiChat. */
  chat?: typeof nativeAiChat;
}

/**
 * Run a continuous, throttled background AI re-rank over the Reads stream.
 * Re-runs when `items`/`topics` change (debounced by the cooldown), skips while
 * `busy`, and no-ops when `enabled` is false. Stale passes are discarded when a
 * newer pass starts (token guard).
 */
export function useAiFeedRerank({
  items,
  topics,
  enabled,
  busy,
  chat = nativeAiChat,
}: UseAiFeedRerankArgs): AiRerankResult {
  const [result, setResult] = useState<AiRerankResult>({ boost: new Map(), status: "idle" });
  const lastRunRef = useRef<number>(0);
  const passTokenRef = useRef<number>(0);

  useEffect(() => {
    // Hard gate: on-device model unavailable → never run, reset to idle.
    if (!enabled) {
      setResult((prev) => (prev.status === "idle" ? prev : { boost: new Map(), status: "idle" }));
      return;
    }
    // Nothing to rank.
    if (items.length === 0 || topics.length === 0) return;
    // Foreground preference: never start a background pass while a user-initiated
    // AI request is in flight. (A pass already running can't be preempted — see
    // header — but it finishes fast thanks to the tight token cap.)
    if (busy) {
      setResult((prev) => (prev.status === "running" ? prev : { ...prev, status: "skipped" }));
      return;
    }
    // Throttle: don't re-run more often than the cooldown.
    const now = Date.now();
    if (now - lastRunRef.current < RERANK_COOLDOWN_SECS * 1000) return;

    const myToken = ++passTokenRef.current;
    lastRunRef.current = now;
    setResult((prev) => ({ ...prev, status: "running" }));

    void (async () => {
      try {
        const batch = items.slice(0, RERANK_BATCH_SIZE);
        const payload = batch.map((r, i) => {
          const c = r.item.content;
          // Articles/video carry title + description; social parent posts carry
          // the full body (title is usually absent there).
          const title = (c.title || "").trim();
          const body = (c.body || "").trim().slice(0, RERANK_ITEM_CHAR_LIMIT);
          const text = title ? `${title} — ${body}` : body;
          return { id: r.item.id, i, text };
        });
        const topicList = topics.slice(0, 10).map((t) => t.label).join(", ");

        const system =
          "You rank a personal reading feed by relevance to the user's journal topics. " +
          "For each item, output a relevance score from 0.0 (irrelevant) to 1.0 (highly relevant). " +
          'Output ONLY a JSON array of objects: [{"id": "<id>", "score": <number>}]. No prose, no markdown fences.';
        const prompt =
          `Journal topics: ${topicList}\n\n` +
          `Items:\n${JSON.stringify(payload)}\n\n` +
          `Return the JSON array of {id, score} now.`;

        // Single short call so a queued user request isn't blocked for long.
        const res = await chat(prompt, system, 220, 0.2);
        if (myToken !== passTokenRef.current) return; // stale — a newer pass won

        const parsed = tryParseJsonArray<{ id?: string; score?: number }>(res.text);
        const boost = new Map<string, number>();
        if (parsed) {
          for (const entry of parsed) {
            if (!entry || typeof entry.id !== "string") continue;
            const s = Number(entry.score);
            if (Number.isFinite(s)) boost.set(entry.id, s < 0 ? 0 : s > 1 ? 1 : s);
          }
        }
        setResult({ boost, status: "done" });
      } catch (e) {
        if (myToken !== passTokenRef.current) return;
        const detail = e instanceof Error ? e.message : String(e);
        setResult((prev) => ({ ...prev, status: "error", error: detail.slice(0, 160) }));
      }
    })();
    // topics.join() keeps referential changes meaningful without deep-compare.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [enabled, busy, items, topics]);

  return result;
}

// TODO(engine): a Rust-side priority/abort queue in inference.rs would let a
// foreground user request preempt an in-flight background pass instead of
// waiting for it to finish. Today preference is enforced TS-side (busy gate),
// which is correct for KISS but not true preemption. Tracked separately — do
// not bundle native changes into a frontend feature.
