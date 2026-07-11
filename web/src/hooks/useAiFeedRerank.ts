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
 * This mirrors the TweetClaw pattern in App.tsx: gate on
 * isTauriMobileRuntime() && nativeLocalAiStatus?.available; nativeAiChat call
 * requesting JSON; defensive parse via tryParseJsonArray; retry on parse
 * failure with a temperature nudge; surface real errors; degrade gracefully.
 * iOS on-device only per AGENTS.md §1.
 *
 * ROBUSTNESS NOTES (small-model hardening):
 * - Position-based keys: the model sees and echoes a short 1-based numeric
 *   index `i`, never the long `at://` URI / note hex (which small quantized
 *   models garble). We map i → real item id locally.
 * - Retry on parse failure: up to RERANK_MAX_ATTEMPTS calls per pass, with
 *   temperature nudged up on each retry — the same tactic TweetClaw uses to
 *   recover fenced / truncated / prose-prefixed output.
 * - Empty-item filter: items with neither title nor body are dropped before
 *   sending (nothing to score); they keep their base score implicitly.
 *
 * FOREGROUND PREFERENCE (not preemption):
 * The Rust inference engine (inference.rs) is a single process-wide Mutex with
 * NO queue, priority, or abort — concurrent nativeAiChat calls serialize. True
 * preemption of a running background call is impossible without Rust changes.
 * "User request gets preference" is therefore enforced TS-side: a background
 * pass is only *started* when `busy` is false (foreground AI work like TweetClaw
 * pull-to-generate). Passes are kept short (tight token cap, ≤2 attempts) so
 * any in-flight pass finishes quickly and unblocks a queued user request. See
 * the TODO at the bottom for the engine-level follow-up.
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
/** Max generation tokens for the score array. ~28 chars/object × N items + slack. */
const RERANK_MAX_TOKENS = 260;
/** Max nativeAiChat attempts per pass before giving up (retry on parse failure). */
const RERANK_MAX_ATTEMPTS = 2;

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
        // Build the payload, DROPPING items with no text (nothing to score —
        // they keep their base score by simply not appearing in the boost map).
        // Use a short 1-based numeric index `i` as the key the model echoes back
        // (small models mangle long `at://` URIs / note hex; a number is robust),
        // then map back to the real item id below.
        const indexToId: string[] = [];
        const payload: { i: number; text: string }[] = [];
        for (const r of batch) {
          const c = r.item.content;
          // Articles/video carry title + description; social parent posts carry
          // the full body (title is usually absent there). Either is optional,
          // but at least one must be present to score.
          const title = (c.title || "").trim();
          const body = (c.body || "").trim().slice(0, RERANK_ITEM_CHAR_LIMIT);
          const text = title && body ? `${title} — ${body}` : title || body;
          if (!text) continue;
          const i = indexToId.push(r.item.id); // 1-based
          payload.push({ i, text });
        }
        // If nothing survived filtering, there's nothing to rank.
        if (payload.length === 0) {
          if (myToken !== passTokenRef.current) return;
          setResult({ boost: new Map(), status: "done" });
          return;
        }
        const topicList = topics.slice(0, 10).map((t) => t.label).join(", ");

        const system =
          "You rank a personal reading feed by relevance to the user's journal topics. " +
          "For each item, output a relevance score from 0.0 (irrelevant) to 1.0 (highly relevant). " +
          'Output ONLY a JSON array of objects: [{"i": <number>, "score": <number>}]. No prose, no markdown fences.';
        const prompt =
          `Journal topics: ${topicList}\n\n` +
          `Items:\n${JSON.stringify(payload)}\n\n` +
          `Return the JSON array of {i, score} now.`;

        // Retry on parse failure (small quantized models often fence/truncate
        // on the first try). Up to RERANK_MAX_ATTEMPTS calls, temp nudged up on
        // each retry — mirrors the TweetClaw retry pattern. Each call is short
        // so a queued user request still isn't blocked for long.
        let parsed: { i?: number; score?: number }[] | null = null;
        let lastText = "";
        for (let attempt = 0; attempt < RERANK_MAX_ATTEMPTS && !parsed; attempt++) {
          const temp = attempt === 0 ? 0.2 : 0.3 + attempt * 0.1;
          const res = await chat(prompt, system, RERANK_MAX_TOKENS, temp);
          if (myToken !== passTokenRef.current) return; // stale — a newer pass won
          lastText = res.text;
          parsed = tryParseJsonArray<{ i?: number; score?: number }>(res.text);
        }

        const boost = new Map<string, number>();
        if (parsed) {
          for (const entry of parsed) {
            if (!entry || typeof entry.i !== "number") continue;
            const realId = indexToId[entry.i - 1]; // back to the real item id
            if (!realId) continue;
            const s = Number(entry.score);
            if (Number.isFinite(s)) boost.set(realId, s < 0 ? 0 : s > 1 ? 1 : s);
          }
        }
        if (myToken !== passTokenRef.current) return;
        // Empty boost after a (nominal) parse usually means the model emitted
        // garbage that tryParseJsonArray accepted but with no usable rows.
        // Treat that as a soft error so the status pip reflects it.
        const status = boost.size > 0 ? "done" : "error";
        setResult({
          boost,
          status,
          error: status === "error" ? `No scores parsed from model output (${lastText.length} chars)` : undefined,
        });
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
